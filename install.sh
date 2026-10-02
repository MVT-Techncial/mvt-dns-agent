[[ $READY == 1 ]] || die 'AdGuard first-run API did not start on port 3000.'

# Credentials are generated locally; never printed and never committed to git.
ADGUARD_USERNAME='admin'
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

# Never print the MVT appliance API key.  The temporary AdGuard password is
# deliberately shown once at the end so the onsite engineer can log in.
unset API_KEY
printf '\n================================================\n'
printf ' MVT DNS ONBOARDING COMPLETE - TESTING BASELINE\n'
printf '================================================\n'
printf ' Customer:   %s\n Site:       %s\n Hostname:   %s\n Pi IP:      %s\n' "$CUSTOMER" "$SITE" "$HOSTNAME" "$LAN_IP"
printf ' AdGuard:    %s (Protection Enabled)\n Agent:      %s\n' "$AGH_VERSION" "$AGENT_VERSION"
printf ' Portal:     Heartbeat OK\n Filtering:  Initial sync OK\n Timer:      Active\n'
printf '\n ADGUARD LOGIN\n'
printf ' URL:        http://%s\n' "$LAN_IP"
printf ' Username:   %s\n' "$ADGUARD_USERNAME"
printf ' Temp Pass:  %s\n' "$ADGUARD_PASSWORD"
printf '\n IMPORTANT AFTER LOGIN:\n'
printf ' 1. Change the temporary AdGuard password.\n'
printf ' 2. Update ADGUARD_PASSWORD in /opt/mvt-dns-agent/config.env\n'
printf '    to the same new password. Keep ADGUARD_USERNAME=admin.\n'
printf ' 3. Run: sudo chmod 600 /opt/mvt-dns-agent/config.env\n'
printf ' 4. Run: sudo systemctl restart AdGuardHome\n'
printf ' 5. Run: sudo /opt/mvt-dns-agent/collector.py\n'
printf '    Confirm Heartbeat OK and Protection Enabled.\n'
printf '\n NETWORK NEXT STEP:\n'
printf ' Reserve %s on the site router, then set DHCP DNS\n' "$LAN_IP"
printf ' to %s and validate a test client.\n' "$LAN_IP"
printf '================================================\n'
unset ADGUARD_PASSWORD
