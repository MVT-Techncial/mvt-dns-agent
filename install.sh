#!/usr/bin/env bash
# MVT DNS Appliance Installer - testing release 0.1
# Fresh Raspberry Pi OS Lite 64-bit only. DO NOT run on an existing appliance.
set -Eeuo pipefail
umask 077

API_BASE='https://adguard.security.mvt-systems.co.za'
REPO='MVT-Techncial/mvt-dns-agent'
AGENT_VERSION='0.2.1'
AGH_VERSION='v0.107.79'
RAW="https://raw.githubusercontent.com/${REPO}/v${AGENT_VERSION}"
AGH_RELEASE="https://github.com/AdguardTeam/AdGuardHome/releases/download/${AGH_VERSION}"
AGH_ASSET='AdGuardHome_linux_arm64.tar.gz'

say() { printf '\n[MVT] %s\n' "$*"; }
die() { printf '\n[MVT] ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die 'Run with sudo: sudo bash install.sh'
[[ -r /dev/tty ]] || die 'Interactive SSH terminal required.'
[[ $(uname -m) == 'aarch64' ]] || die 'This installer requires Raspberry Pi OS Lite 64-bit (arm64).'
command -v apt-get >/dev/null || die 'Requires Raspberry Pi OS / Debian with apt-get.'
command -v curl >/dev/null || die 'curl missing: install curl on the pre-imaged Pi.'
command -v python3 >/dev/null || die 'python3 missing: install python3 on the pre-imaged Pi.'
command -v hostnamectl >/dev/null || die 'hostnamectl is required.'

# Never overwrite a deployed or partially deployed appliance.
[[ ! -e /opt/mvt-dns-agent/config.env && ! -e /opt/mvt-dns-agent/collector.py ]] || \
  die 'MVT agent already exists. This installer is for clean Pis only.'
[[ ! -e /opt/AdGuardHome && ! -e /etc/systemd/system/AdGuardHome.service ]] || \
  die 'AdGuard is already installed or partially installed. Nothing overwritten.'

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
trap 'die "Installation stopped near line $LINENO. Do not change router DHCP until resolved."' ERR

say 'MVT DNS Appliance - Guided Onboarding'
printf 'Paste your MVT Appliance API key (input hidden): ' >/dev/tty
IFS= read -r -s API_KEY </dev/tty
printf '\n' >/dev/tty
[[ $API_KEY =~ ^mvt_dns_[A-Za-z0-9_-]+$ ]] || die 'Invalid key format.'

say 'Validating appliance key and retrieving site details...'
HTTP_CODE=$(curl -sS --connect-timeout 10 --max-time 25 --retry 2 \
  -o "$WORK/bootstrap.json" -w '%{http_code}' \
  -H "X-MVT-API-Key: $API_KEY" "$API_BASE/api/public/bootstrap") || \
  die 'Cannot reach the MVT bootstrap API.'
[[ $HTTP_CODE == 200 ]] || die "Bootstrap rejected request (HTTP $HTTP_CODE). Check the appliance key/status."

python3 - "$WORK/bootstrap.json" "$AGENT_VERSION" > "$WORK/bootstrap.fields" <<'PY' || die 'Unexpected bootstrap response.'
import json, re, sys
p, approved = sys.argv[1:]
d = json.load(open(p, encoding='utf8'))
name = d.get('appliance_name', '')
if not d.get('success') or not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', name):
    sys.exit('Invalid bootstrap appliance hostname')
if d.get('agent_version') != approved:
    sys.exit('Portal version differs from tested installer version; stop and review release')
for k in ('customer_name', 'site_name', 'appliance_name'):
    s = d.get(k, '')
    if not isinstance(s, str) or not s.strip() or any(ord(c) < 32 for c in s):
        sys.exit('Missing or invalid bootstrap field: ' + k)
    print(s)
PY
mapfile -t DETAILS < "$WORK/bootstrap.fields"
CUSTOMER=${DETAILS[0]}
SITE=${DETAILS[1]}
HOSTNAME=${DETAILS[2]}
printf '[MVT] Customer: %s | Site: %s | Hostname: %s\n' "$CUSTOMER" "$SITE" "$HOSTNAME"

say 'Fetching approved v0.2.1 files BEFORE installing anything...'
curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 \
  "$RAW/agent/collector.py" -o "$WORK/collector.py" || \
  die 'Approved collector not found. Confirm GitHub release tag v0.2.1 exists.'
curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 \
  "$RAW/systemd/mvt-dns-agent.service" -o "$WORK/mvt-dns-agent.service" || \
  die 'Approved systemd service not found under v0.2.1.'
curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 \
  "$RAW/systemd/mvt-dns-agent.timer" -o "$WORK/mvt-dns-agent.timer" || \
  die 'Approved timer not found under v0.2.1.'
grep -q 'AGENT_VERSION = "0.2.1"' "$WORK/collector.py" || \
  die 'Downloaded collector does not declare agent 0.2.1.'
python3 -m py_compile "$WORK/collector.py" || die 'Downloaded collector is not valid Python.'
grep -q '^\[Service\]' "$WORK/mvt-dns-agent.service" || die 'Invalid systemd service file.'
grep -q '^\[Timer\]' "$WORK/mvt-dns-agent.timer" || die 'Invalid systemd timer file.'

say "Downloading verified upstream AdGuard Home ${AGH_VERSION} for arm64..."
curl -fsSL --connect-timeout 10 --retry 3 "$AGH_RELEASE/$AGH_ASSET" -o "$WORK/$AGH_ASSET" || \
  die 'Failed to download pinned AdGuard Home release.'
curl -fsSL --connect-timeout 10 --retry 3 "$AGH_RELEASE/checksums.txt" -o "$WORK/checksums.txt" || \
  die 'Failed to download official AdGuard checksums.'
EXPECTED=$(awk -v f="$AGH_ASSET" '$NF == f || $NF == "*" f || $NF == "./" f {print $1; exit}' "$WORK/checksums.txt")
[[ $EXPECTED =~ ^[0-9a-fA-F]{64}$ ]] || die 'Could not locate AdGuard archive checksum.'
printf '%s  %s\n' "$EXPECTED" "$WORK/$AGH_ASSET" | sha256sum -c - >/dev/null || \
  die 'AdGuard download checksum mismatch.'
tar -tzf "$WORK/$AGH_ASSET" > "$WORK/archive-list.txt" || die 'AdGuard archive is unreadable.'
if ! sed 's#^\./##' "$WORK/archive-list.txt" | \
  grep -qx 'AdGuardHome/AdGuardHome'; then

    echo
    echo "AdGuard archive layout validation failed."
    echo "First 20 archive entries:"
    echo "----------------------------------------"
    head -n 20 "$WORK/archive-list.txt"
    echo "----------------------------------------"

    die 'AdGuard archive layout unexpected.'
fi

say 'Checking standard AdGuard ports (53/TCP+UDP, 80/TCP, 3000/TCP)...'
python3 - <<'PY' || die 'Resolve local port conflicts before onboarding.'
import socket, sys
for port, kind in [(53,socket.SOCK_DGRAM),(53,socket.SOCK_STREAM),(80,socket.SOCK_STREAM),(3000,socket.SOCK_STREAM)]:
    s=socket.socket(socket.AF_INET,kind)
    try: s.bind(('0.0.0.0',port))
    except OSError as e:
        sys.exit(f'Port {port}/{"UDP" if kind == socket.SOCK_DGRAM else "TCP"} unavailable: {e}')
    finally: s.close()
PY

LAN_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
[[ -n $LAN_IP ]] || die 'Cannot identify the Pi LAN IP address. Check Ethernet connectivity.'

say 'Installing prerequisites...'
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl python3 sqlite3 dnsutils iproute2 tar

say "Setting hostname to $HOSTNAME..."
hostnamectl set-hostname "$HOSTNAME"

say 'Installing pinned AdGuard Home...'
tar -xzf "$WORK/$AGH_ASSET" -C /opt
( cd /opt/AdGuardHome && ./AdGuardHome -s install )
READY=0
for i in $(seq 1 30); do
    if curl -fsS --max-time 3 'http://127.0.0.1:3000/control/install/get_addresses' -o /dev/null 2>/dev/null; then
        READY=1; break
    fi
    sleep 1
done
[[ $READY == 1 ]] || die 'AdGuard first-run API did not start on port 3000.'

# Credentials are generated locally; never printed and never committed to git.
ADGUARD_USERNAME='mvtadmin'
ADGUARD_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
# Persist credentials before initial configuration, so they survive any later failure.
install -d -m 700 /opt/mvt-dns-agent
printf 'MVT_API_BASE="%s"\nMVT_API_KEY="%s"\nADGUARD_URL="http://127.0.0.1"\nADGUARD_USERNAME="%s"\nADGUARD_PASSWORD="%s"\n' \
  "$API_BASE" "$API_KEY" "$ADGUARD_USERNAME" "$ADGUARD_PASSWORD" > /opt/mvt-dns-agent/config.env
chmod 600 /opt/mvt-dns-agent/config.env
python3 - "$WORK" "$ADGUARD_USERNAME" "$ADGUARD_PASSWORD" <<'PY'
import json, pathlib, sys
work, username, password = sys.argv[1:]
config = {
  'web': {'ip': '0.0.0.0', 'port': 80},
  'dns': {'ip': '0.0.0.0', 'port': 53},
  'username': username, 'password': password, 'language': 'en',
}
check = {
  'web': {'ip': '0.0.0.0', 'port': 80, 'autofix': False},
  'dns': {'ip': '0.0.0.0', 'port': 53, 'autofix': False},
}
p=pathlib.Path(work)
(p/'adguard-install.json').write_text(json.dumps(config))
(p/'adguard-check.json').write_text(json.dumps(check))
PY
curl -fsS --max-time 15 -H 'Content-Type: application/json' \
  --data-binary "@$WORK/adguard-check.json" \
  'http://127.0.0.1:3000/control/install/check_config' -o "$WORK/check-result.json" || \
  die 'AdGuard rejected installation port checks.'
python3 - "$WORK/check-result.json" <<'PY' || die 'AdGuard reports a conflicting port/configuration.'
import json,sys
d=json.load(open(sys.argv[1]))
errors=[f'{k}: {d.get(k,{}).get("status")}' for k in ('web','dns') if d.get(k,{}).get('status')]
if errors: sys.exit('; '.join(errors))
PY
curl -fsS --max-time 30 -H 'Content-Type: application/json' \
  --data-binary "@$WORK/adguard-install.json" \
  'http://127.0.0.1:3000/control/install/configure' -o /dev/null || \
  die 'AdGuard initial configuration failed.'

READY=0
for i in $(seq 1 20); do
    if curl -fsS --max-time 3 -u "$ADGUARD_USERNAME:$ADGUARD_PASSWORD" \
       'http://127.0.0.1/control/status' -o "$WORK/status.json" 2>/dev/null; then
        READY=1; break
    fi
    sleep 1
done
[[ $READY == 1 ]] || die 'AdGuard did not become ready after configuration.'
# Protection is deliberately enabled for the appliance.
curl -fsS --max-time 15 -u "$ADGUARD_USERNAME:$ADGUARD_PASSWORD" \
  -H 'Content-Type: application/json' --data '{"enabled":true}' \
  'http://127.0.0.1/control/protection' -o /dev/null || \
  die 'Could not enable AdGuard Protection.'

say 'Installing MVT collector, configuration and timer...'
install -m 750 "$WORK/collector.py" /opt/mvt-dns-agent/collector.py
install -m 644 "$WORK/mvt-dns-agent.service" /etc/systemd/system/mvt-dns-agent.service
install -m 644 "$WORK/mvt-dns-agent.timer" /etc/systemd/system/mvt-dns-agent.timer
systemctl daemon-reload

say 'Verifying AdGuard can resolve through upstream DNS...'
dig @127.0.0.1 example.org A +time=5 +tries=2 +short | grep -qE '^[0-9]+\.' || \
  die 'DNS upstream resolution failed. Do not update DHCP yet.'

say 'Running MVT collector once and checking heartbeat/config results...'
/opt/mvt-dns-agent/collector.py > "$WORK/agent-test.log" 2>&1 || true
cat "$WORK/agent-test.log"
grep -q 'Heartbeat OK' "$WORK/agent-test.log" || \
  die 'Agent heartbeat failed. Do not update DHCP yet.'
grep -q 'Filtering config version .* applied successfully\|Filtering config already current' "$WORK/agent-test.log" || \
  die 'Initial filtering sync failed. Do not update DHCP yet.'

systemctl enable --now mvt-dns-agent.timer >/dev/null
systemctl is-active --quiet mvt-dns-agent.timer || die 'MVT agent timer is not active.'

# Do not display secrets in logs or success summary.
unset API_KEY ADGUARD_PASSWORD
printf '\n================================================\n'
printf ' MVT DNS ONBOARDING COMPLETE - TESTING BASELINE\n'
printf '================================================\n'
printf ' Customer:   %s\n Site:       %s\n Hostname:   %s\n Pi IP:      %s\n' "$CUSTOMER" "$SITE" "$HOSTNAME" "$LAN_IP"
printf ' AdGuard:    %s (Protection Enabled)\n Agent:      %s\n' "$AGH_VERSION" "$AGENT_VERSION"
printf ' Portal:     Heartbeat OK\n Filtering:  Initial sync OK\n Timer:      Active\n'
printf '\n NEXT: Reserve %s on the site router.\n' "$LAN_IP"
printf ' Then set DHCP DNS to %s and validate a test client.\n' "$LAN_IP"
printf ' Local AdGuard admin credentials are in root-only\n /opt/mvt-dns-agent/config.env; transfer to an\n approved credential vault before site handover.\n'
printf '================================================\n'
