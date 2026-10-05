#!/usr/bin/env bash
set -Eeuo pipefail

# =========================================================
# MVT DNS Appliance Installer
# Testing baseline
# =========================================================

API_BASE="https://adguard.security.mvt-systems.co.za"
REPO_RAW="https://raw.githubusercontent.com/MVT-Techncial/mvt-dns-agent"
ADGUARD_VERSION="v0.107.79"

WORK=""
AGH_PID=""
API_KEY=""
ADGUARD_PASSWORD=""

say() {
    printf '\n==> %s\n' "$*"
}

warn() {
    printf '\nWARNING: %s\n' "$*" >&2
}

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${AGH_PID:-}" ]] && kill -0 "$AGH_PID" 2>/dev/null; then
        kill "$AGH_PID" 2>/dev/null || true
        wait "$AGH_PID" 2>/dev/null || true
    fi

    if [[ -n "${WORK:-}" && -d "$WORK" ]]; then
        rm -rf "$WORK"
    fi
}

trap cleanup EXIT

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || \
        die "Run this installer with sudo: sudo bash /tmp/mvt-install.sh"
}

validate_hostname() {
    local name="$1"

    [[ ${#name} -le 63 ]] || return 1
    [[ "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

require_root

printf '\n================================================\n'
printf ' MVT DNS APPLIANCE INSTALLER\n'
printf '================================================\n\n'

# =========================================================
# Platform validation
# =========================================================

ARCH="$(uname -m)"

case "$ARCH" in
    aarch64|arm64)
        ADGUARD_ARCH="arm64"
        ;;
    *)
        die "This deployment standard requires Raspberry Pi OS Lite 64-bit (ARM64). Detected architecture: $ARCH"
        ;;
esac

# Do not overwrite a working appliance.
if [[ -x /opt/AdGuardHome/AdGuardHome ]] || \
   [[ -e /opt/mvt-dns-agent/collector.py ]]; then

    die "An existing AdGuard Home or MVT DNS Agent installation was detected. Use a clean/pre-imaged Pi for onboarding."
fi

WORK="$(mktemp -d /tmp/mvt-dns-install.XXXXXX)"
BOOTSTRAP_JSON="$WORK/bootstrap.json"

# =========================================================
# Appliance key
# =========================================================

read -r -s -p "Enter MVT Appliance API Key: " API_KEY
printf '\n'

[[ -n "$API_KEY" ]] || die "No appliance API key was entered."

# =========================================================
# Bootstrap
# =========================================================

say "Validating appliance with the MVT Portal..."

HTTP_CODE="$(
    curl -sS \
        --max-time 20 \
        -o "$BOOTSTRAP_JSON" \
        -w '%{http_code}' \
        -H "X-MVT-API-Key: $API_KEY" \
        "$API_BASE/api/public/bootstrap"
)" || die "Could not reach the MVT bootstrap API. Check Internet/DNS connectivity."

case "$HTTP_CODE" in
    200)
        ;;
    401)
        die "Bootstrap rejected the appliance key (HTTP 401). Check the generated key."
        ;;
    403)
        die "Bootstrap rejected this appliance (HTTP 403). Confirm the appliance is enabled."
        ;;
    *)
        printf 'Bootstrap response:\n'
        cat "$BOOTSTRAP_JSON" 2>/dev/null || true
        die "Bootstrap failed with HTTP $HTTP_CODE."
        ;;
esac

read_json_field() {
    python3 - "$BOOTSTRAP_JSON" "$1" <<'PY'
import json
import sys

path, key = sys.argv[1], sys.argv[2]

with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

value = data.get(key)

if value is None:
    raise SystemExit(1)

print(value)
PY
}

CUSTOMER="$(read_json_field customer_name)" || \
    die "Bootstrap response is missing customer_name."

SITE="$(read_json_field site_name)" || \
    die "Bootstrap response is missing site_name."

APPLIANCE_NAME="$(read_json_field appliance_name)" || \
    die "Bootstrap response is missing appliance_name."

AGENT_VERSION="$(read_json_field agent_version)" || \
    die "Bootstrap response is missing agent_version."

# =========================================================
# Validate Portal appliance name
# =========================================================

validate_hostname "$APPLIANCE_NAME" || \
    die "Portal Appliance Name '$APPLIANCE_NAME' is not hostname-safe. Use only letters, numbers and hyphens, maximum 63 characters, with no leading/trailing hyphen. Correct it in the Portal and rerun the installer."

[[ "$AGENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    die "Portal returned an invalid agent version: $AGENT_VERSION"

printf '\n================================================\n'
printf ' APPLIANCE CONFIRMATION\n'
printf '================================================\n'

printf ' Customer:   %s\n' "$CUSTOMER"
printf ' Site:       %s\n' "$SITE"
printf ' Appliance:  %s\n' "$APPLIANCE_NAME"
printf ' Agent:      v%s\n' "$AGENT_VERSION"

printf '\n'
printf 'This appliance name will become the Raspberry Pi hostname.\n'
printf '\n'

read -r -p "Continue? [Y/n]: " CONFIRM

case "${CONFIRM:-Y}" in
    Y|y)
        ;;
    *)
        printf '\nInstallation cancelled. No appliance software was installed.\n'
        exit 0
        ;;
esac

# =========================================================
# Hostname
# =========================================================

say "Setting Raspberry Pi hostname to $APPLIANCE_NAME..."

hostnamectl set-hostname "$APPLIANCE_NAME"

printf '%s\n' "$APPLIANCE_NAME" > /etc/hostname

# Ensure sudo/system services can resolve the new local hostname.
if grep -qE '^127\.0\.1\.1([[:space:]]|$)' /etc/hosts; then

    sed -i -E \
        "s/^127\.0\.1\.1.*/127.0.1.1\t$APPLIANCE_NAME/" \
        /etc/hosts

else

    printf '127.0.1.1\t%s\n' "$APPLIANCE_NAME" >> /etc/hosts

fi

# =========================================================
# Packages
# =========================================================

say "Installing required packages..."

export DEBIAN_FRONTEND=noninteractive

apt-get update -y

apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    dnsutils \
    python3 \
    sqlite3 \
    tar \
    gzip

# =========================================================
# Download approved MVT Agent
# =========================================================

say "Downloading approved MVT DNS Agent v$AGENT_VERSION..."

AGENT_BASE="$REPO_RAW/v$AGENT_VERSION"

curl -fsSL \
    "$AGENT_BASE/agent/collector.py" \
    -o "$WORK/collector.py" || \
    die "Could not download collector.py for v$AGENT_VERSION."

curl -fsSL \
    "$AGENT_BASE/systemd/mvt-dns-agent.service" \
    -o "$WORK/mvt-dns-agent.service" || \
    die "Could not download the MVT systemd service."

curl -fsSL \
    "$AGENT_BASE/systemd/mvt-dns-agent.timer" \
    -o "$WORK/mvt-dns-agent.timer" || \
    die "Could not download the MVT systemd timer."

[[ -s "$WORK/collector.py" ]] || \
    die "Downloaded collector.py is empty."

[[ -s "$WORK/mvt-dns-agent.service" ]] || \
    die "Downloaded MVT service file is empty."

[[ -s "$WORK/mvt-dns-agent.timer" ]] || \
    die "Downloaded MVT timer file is empty."

# =========================================================
# Download AdGuard Home
# =========================================================

say "Downloading AdGuard Home $ADGUARD_VERSION..."

ADGUARD_FILE="AdGuardHome_linux_${ADGUARD_ARCH}.tar.gz"

ADGUARD_RELEASE="https://github.com/AdguardTeam/AdGuardHome/releases/download/$ADGUARD_VERSION"

ARCHIVE="$WORK/$ADGUARD_FILE"

curl -fL \
    --retry 3 \
    --connect-timeout 15 \
    "$ADGUARD_RELEASE/$ADGUARD_FILE" \
    -o "$ARCHIVE" || \
    die "Could not download the AdGuard Home archive."

curl -fL \
    --retry 3 \
    --connect-timeout 15 \
    "$ADGUARD_RELEASE/checksums.txt" \
    -o "$WORK/checksums.txt" || \
    die "Could not download AdGuard Home checksums."

# =========================================================
# Verify AdGuard checksum
# =========================================================

EXPECTED_SHA="$(
    awk -v file="$ADGUARD_FILE" \
        '$2 ~ file"$" {print $1; exit}' \
        "$WORK/checksums.txt"
)"

[[ "$EXPECTED_SHA" =~ ^[A-Fa-f0-9]{64}$ ]] || \
    die "Could not find a valid SHA-256 checksum for $ADGUARD_FILE."

printf '%s  %s\n' \
    "$EXPECTED_SHA" \
    "$ARCHIVE" | \
    sha256sum -c - >/dev/null || \
    die "AdGuard Home archive checksum validation failed."

# =========================================================
# Verify archive
# =========================================================

tar -tzf "$ARCHIVE" > "$WORK/archive-list.txt" || \
    die "Downloaded AdGuard archive is not readable."

if ! sed 's#^\./##' "$WORK/archive-list.txt" | \
    grep -qx 'AdGuardHome/AdGuardHome'; then

    printf '\n'
    printf 'AdGuard archive layout validation failed.\n'
    printf 'First 20 archive entries:\n'
    printf '%s\n' '----------------------------------------'

    head -n 20 "$WORK/archive-list.txt" || true

    printf '%s\n' '----------------------------------------'

    die "AdGuard archive layout unexpected."
fi

mkdir -p "$WORK/extract"

tar -xzf \
    "$ARCHIVE" \
    -C "$WORK/extract"

[[ -x "$WORK/extract/AdGuardHome/AdGuardHome" ]] || \
    die "AdGuard binary was not found after extraction."

# =========================================================
# Install AdGuard files
# =========================================================

say "Installing AdGuard Home..."

rm -rf /opt/AdGuardHome

cp -a \
    "$WORK/extract/AdGuardHome" \
    /opt/AdGuardHome

chmod 755 \
    /opt/AdGuardHome/AdGuardHome

# =========================================================
# Generate local AdGuard credentials
# =========================================================

ADGUARD_USERNAME="admin"

ADGUARD_PASSWORD="$(
    python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
)"

# =========================================================
# Create MVT configuration
# =========================================================

install -d \
    -m 700 \
    /opt/mvt-dns-agent

cat > /opt/mvt-dns-agent/config.env <<EOF_CONFIG
MVT_API_BASE="$API_BASE"
MVT_API_KEY="$API_KEY"
ADGUARD_URL="http://127.0.0.1"
ADGUARD_USERNAME="$ADGUARD_USERNAME"
ADGUARD_PASSWORD="$ADGUARD_PASSWORD"
EOF_CONFIG

chmod 600 \
    /opt/mvt-dns-agent/config.env

# =========================================================
# Start AdGuard first-run API
# =========================================================

say "Starting AdGuard Home first-run API..."

 /opt/AdGuardHome/AdGuardHome \
    -w /opt/AdGuardHome \
    -c /opt/AdGuardHome/AdGuardHome.yaml \
    > "$WORK/adguard-first-run.log" 2>&1 &

AGH_PID=$!

READY=0

for _ in $(seq 1 30); do

    if curl -fsS \
        --max-time 3 \
        "http://127.0.0.1:3000/control/install/get_addresses" \
        -o "$WORK/addresses.json" \
        2>/dev/null; then

        READY=1
        break

    fi

    sleep 1

done

if [[ $READY != 1 ]]; then

    printf '\nAdGuard first-run log:\n'

    tail -n 50 \
        "$WORK/adguard-first-run.log" \
        2>/dev/null || true

    die "AdGuard first-run API did not start on port 3000."
fi

# =========================================================
# Build AdGuard first-run configuration
# =========================================================

python3 - \
    "$WORK" \
    "$ADGUARD_USERNAME" \
    "$ADGUARD_PASSWORD" <<'PY'

import json
import pathlib
import sys

work, username, password = sys.argv[1:]

path = pathlib.Path(work)

check = {
    "web": {
        "ip": "0.0.0.0",
        "port": 80
    },
    "dns": {
        "ip": "0.0.0.0",
        "port": 53,
        "autofix": False
    },
    "language": "en"
}

configure = {
    "web": {
        "ip": "0.0.0.0",
        "port": 80
    },
    "dns": {
        "ip": "0.0.0.0",
        "port": 53
    },
    "username": username,
    "password": password,
    "language": "en"
}

(path / "adguard-check.json").write_text(
    json.dumps(check),
    encoding="utf-8"
)

(path / "adguard-install.json").write_text(
    json.dumps(configure),
    encoding="utf-8"
)
PY

# =========================================================
# Check ports
# =========================================================

say "Checking AdGuard DNS/Web ports..."

curl -fsS \
    --max-time 15 \
    -H 'Content-Type: application/json' \
    --data-binary "@$WORK/adguard-check.json" \
    "http://127.0.0.1:3000/control/install/check_config" \
    -o "$WORK/check-result.json" || \
    die "AdGuard rejected installation port checks."

CHECK_RESULT="$(
    python3 - "$WORK/check-result.json" <<'PY'

import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)

web = data.get("web") or {}
dns = data.get("dns") or {}

print(
    (web.get("status") or "")
    .replace("\n", " ")
)

print(
    (dns.get("status") or "")
    .replace("\n", " ")
)

print(
    "1"
    if dns.get("can_autofix")
    else "0"
)
PY
)"

WEB_STATUS="$(
    printf '%s\n' "$CHECK_RESULT" |
    sed -n '1p'
)"

DNS_STATUS="$(
    printf '%s\n' "$CHECK_RESULT" |
    sed -n '2p'
)"

DNS_CAN_AUTOFIX="$(
    printf '%s\n' "$CHECK_RESULT" |
    sed -n '3p'
)"

[[ -z "$WEB_STATUS" ]] || \
    die "AdGuard cannot use web port 80: $WEB_STATUS"

# =========================================================
# DNS port autofix
# =========================================================

if [[ -n "$DNS_STATUS" && "$DNS_CAN_AUTOFIX" == "1" ]]; then

    say "AdGuard detected a DNS port conflict it can safely fix; applying the official autofix..."

    cat > "$WORK/adguard-autofix.json" <<'EOF_AUTOFIX'
{"dns":{"ip":"0.0.0.0","port":53,"autofix":true},"language":"en"}
EOF_AUTOFIX

    curl -fsS \
        --max-time 20 \
        -H 'Content-Type: application/json' \
        --data-binary "@$WORK/adguard-autofix.json" \
        "http://127.0.0.1:3000/control/install/check_config" \
        -o "$WORK/autofix-result.json" || \
        die "AdGuard DNS port autofix failed."

    sleep 2

    curl -fsS \
        --max-time 15 \
        -H 'Content-Type: application/json' \
        --data-binary "@$WORK/adguard-check.json" \
        "http://127.0.0.1:3000/control/install/check_config" \
        -o "$WORK/check-result-after-fix.json" || \
        die "Could not recheck AdGuard ports after autofix."

    DNS_STATUS="$(
        python3 - "$WORK/check-result-after-fix.json" <<'PY'

import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)

print(
    (
        (data.get("dns") or {})
        .get("status") or ""
    ).replace("\n", " ")
)
PY
)"

fi

[[ -z "$DNS_STATUS" ]] || \
    die "AdGuard cannot use DNS port 53: $DNS_STATUS"

# =========================================================
# Configure AdGuard
# =========================================================

say "Configuring AdGuard Home..."

curl -fsS \
    --max-time 30 \
    -H 'Content-Type: application/json' \
    --data-binary "@$WORK/adguard-install.json" \
    "http://127.0.0.1:3000/control/install/configure" \
    -o /dev/null || \
    die "AdGuard initial configuration failed."

# =========================================================
# Wait for configured AdGuard
# =========================================================

READY=0

for _ in $(seq 1 30); do

    if curl -fsS \
        --max-time 3 \
        -u "$ADGUARD_USERNAME:$ADGUARD_PASSWORD" \
        "http://127.0.0.1/control/status" \
        -o "$WORK/status-pre-service.json" \
        2>/dev/null; then

        READY=1
        break

    fi

    sleep 1

done

[[ $READY == 1 ]] || \
    die "AdGuard did not become ready after initial configuration."

# =========================================================
# Stop temporary process
# =========================================================

if [[ -n "$AGH_PID" ]] && \
    kill -0 "$AGH_PID" 2>/dev/null; then

    kill "$AGH_PID" 2>/dev/null || true
    wait "$AGH_PID" 2>/dev/null || true

fi

AGH_PID=""

sleep 1

# =========================================================
# Install AdGuard service
# =========================================================

say "Installing AdGuard Home system service..."

(
    cd /opt/AdGuardHome
    ./AdGuardHome -s install
) >/dev/null || \
    die "Could not install the AdGuardHome system service."

systemctl enable AdGuardHome \
    >/dev/null 2>&1 || true

systemctl restart AdGuardHome

# =========================================================
# Wait for AdGuard service
# =========================================================

READY=0

for _ in $(seq 1 30); do

    if systemctl is-active --quiet AdGuardHome && \
       curl -fsS \
           --max-time 3 \
           -u "$ADGUARD_USERNAME:$ADGUARD_PASSWORD" \
           "http://127.0.0.1/control/status" \
           -o "$WORK/status.json" \
           2>/dev/null; then

        READY=1
        break

    fi

    sleep 1

done

[[ $READY == 1 ]] || \
    die "AdGuardHome service did not become healthy."

# =========================================================
# Enable protection
# =========================================================

say "Ensuring AdGuard Protection is enabled..."

curl -fsS \
    --max-time 15 \
    -u "$ADGUARD_USERNAME:$ADGUARD_PASSWORD" \
    -H 'Content-Type: application/json' \
    --data '{"enabled":true}' \
    "http://127.0.0.1/control/protection" \
    -o /dev/null || \
    die "Could not enable AdGuard Protection."

sleep 1

curl -fsS \
    --max-time 10 \
    -u "$ADGUARD_USERNAME:$ADGUARD_PASSWORD" \
    "http://127.0.0.1/control/status" \
    -o "$WORK/status.json" || \
    die "Could not re-read AdGuard status."

PROTECTION_ENABLED="$(
    python3 - "$WORK/status.json" <<'PY'

import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)

print(
    "true"
    if data.get("protection_enabled")
    else "false"
)
PY
)"

[[ "$PROTECTION_ENABLED" == "true" ]] || \
    die "AdGuard Protection is not enabled."

# =========================================================
# Install MVT Agent
# =========================================================

say "Installing MVT collector and systemd timer..."

install -m 750 \
    "$WORK/collector.py" \
    /opt/mvt-dns-agent/collector.py

install -m 644 \
    "$WORK/mvt-dns-agent.service" \
    /etc/systemd/system/mvt-dns-agent.service

install -m 644 \
    "$WORK/mvt-dns-agent.timer" \
    /etc/systemd/system/mvt-dns-agent.timer

systemctl daemon-reload

# =========================================================
# DNS test
# =========================================================

say "Verifying DNS resolution through AdGuard..."

dig \
    @127.0.0.1 \
    example.org \
    A \
    +time=5 \
    +tries=2 \
    +short |
    grep -qE '^[0-9]+\.' || \
    die "DNS upstream resolution failed. Do not update DHCP yet."

# =========================================================
# Run agent
# =========================================================

say "Running the MVT DNS Agent once..."

 /opt/mvt-dns-agent/collector.py \
    > "$WORK/agent-test.log" \
    2>&1 || true

cat "$WORK/agent-test.log"

grep -q \
    'Heartbeat OK' \
    "$WORK/agent-test.log" || \
    die "Agent heartbeat failed. Do not update DHCP yet."

grep -Eq \
    'Filtering config version .* applied successfully|Filtering config already current' \
    "$WORK/agent-test.log" || \
    die "Initial filtering sync failed. Do not update DHCP yet."

# =========================================================
# Enable timer
# =========================================================

say "Enabling the one-minute MVT DNS Agent timer..."

systemctl enable \
    --now \
    mvt-dns-agent.timer \
    >/dev/null

systemctl is-active \
    --quiet \
    mvt-dns-agent.timer || \
    die "MVT DNS Agent timer is not active."

# =========================================================
# Determine Pi IP
# =========================================================

LAN_IP="$(
    hostname -I 2>/dev/null |
    awk '{print $1}'
)"

if [[ -z "$LAN_IP" ]]; then

    LAN_IP="$(
        ip -4 route get 1.1.1.1 2>/dev/null |
        awk '
            /src/ {
                for (i=1; i<=NF; i++) {
                    if ($i=="src") {
                        print $(i+1)
                        exit
                    }
                }
            }
        '
    )"

fi

[[ -n "$LAN_IP" ]] || \
    LAN_IP="<check with: hostname -I>"

AGH_INSTALLED_VERSION="$(
    /opt/AdGuardHome/AdGuardHome \
        --version \
        2>/dev/null |
    head -n 1 || true
)"

# Never print the MVT appliance API key.
unset API_KEY

# =========================================================
# Completion
# =========================================================

printf '\n================================================\n'
printf ' MVT DNS APPLIANCE ONBOARDING COMPLETE\n'
printf '================================================\n\n'

printf 'Customer:        %s\n' "$CUSTOMER"
printf 'Site:            %s\n' "$SITE"
printf 'Hostname:        %s\n' "$APPLIANCE_NAME"
printf 'IP Address:      %s\n' "$LAN_IP"

printf '\n'

printf 'AdGuard:         Healthy\n'
printf 'Protection:      Enabled\n'
printf 'AdGuard Version: %s\n' "${AGH_INSTALLED_VERSION:-$ADGUARD_VERSION}"
printf 'MVT Agent:       v%s\n' "$AGENT_VERSION"
printf 'Portal:          Connected\n'
printf 'Config:          Synced\n'
printf 'Timer:           Active\n'

printf '\n------------------------------------------------\n'
printf ' ADGUARD LOGIN\n'
printf '%s\n' '------------------------------------------------'

printf 'URL:             http://%s\n' "$LAN_IP"
printf 'Username:        %s\n' "$ADGUARD_USERNAME"
printf 'Temp Password:   %s\n' "$ADGUARD_PASSWORD"

printf '\n'
printf 'Log into AdGuard and change the temporary password.\n'
printf '\n'
printf 'After changing it, update ADGUARD_PASSWORD in:\n'
printf '  /opt/mvt-dns-agent/config.env\n'

printf '\nThen run:\n'
printf '  sudo chmod 600 /opt/mvt-dns-agent/config.env\n'
printf '  sudo systemctl restart AdGuardHome\n'
printf '  sudo /opt/mvt-dns-agent/collector.py\n'

printf '\n'
printf 'Confirm the collector ends with Heartbeat OK and Protection Enabled.\n'

printf '\n------------------------------------------------\n'
printf ' NETWORK NEXT STEP\n'
printf '%s\n' '------------------------------------------------'

printf '1. Reserve the Pi IP on the site router/DHCP server:\n'
printf '   %s\n' "$LAN_IP"

printf '2. Configure DHCP DNS to use:\n'
printf '   %s\n' "$LAN_IP"

printf '3. Renew a test client lease and verify DNS/reporting.\n'

printf '\n================================================\n'
