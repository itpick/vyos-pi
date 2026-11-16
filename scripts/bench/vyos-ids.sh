#!/usr/bin/env bash
# VyOS (vyos-pi) Suricata control over ssh, the counterpart of opnsense-ids.sh.
# Everything it changes is put back by "restore" (or by the router-side watchdog).
# Usage:
#   vyos-ids.sh snapshot DIR       Suricata config, mode file, drop.conf, rules, nft, status -> DIR
#   vyos-ids.sh diff DIR           compare the live state with DIR/normalized.txt (exit 1 if different)
#   vyos-ids.sh status | rulecount | counters
#   vyos-ids.sh update             "update suricata": suricata-update (ET Open) + restart
#   vyos-ids.sh stop | start       systemctl stop/start suricata
#   vyos-ids.sh drop-policy G1,G2  write /etc/suricata/drop.conf (group:<file>.rules per entry) and
#                                  rebuild the rules offline (no restart). Leave ET INFO and
#                                  USER_AGENTS out on a household router (STUN, Go clients)
#   vyos-ids.sh ips-wan            vyos-pi IPS mode (NFQUEUE, fail open), then narrow the queue
#                                  to traffic entering or leaving ROUTER_WAN_IF only
#   vyos-ids.sh watchdog SECS      router-side systemd timer: run "restore" after SECS seconds
#   vyos-ids.sh cancel-watchdog
#   vyos-ids.sh restore            drop.conf removed, rules rebuilt offline, mode file removed (IDS,
#                                  af-packet, VyOS's own mode), Suricata restarted
#   vyos-ids.sh homenet-add-wan | homenet-del-wan
#                                  add/remove the current WAN /32 in "service suricata address-group
#                                  home-net" (commit + save; Suricata on a NATed WAN needs it)
set -euo pipefail
. "$(dirname "$0")/common.sh"
rsh() { ssh "${SSH_OPTS[@]}" "$ROUTER_SSH" "$@"; }
CMD=${1:-}; shift || true
SURI_UPDATE='suricata-update --suricata-conf /run/suricata/suricata.yaml'
RESTORE_SH="rm -f /etc/suricata/drop.conf; $SURI_UPDATE --offline --no-test -q; rm -f /config/vyos-pi/suricata.conf; systemctl restart suricata"

normalized() {
  rsh 'sh -s' <<'R'
echo "service-suricata-config-sha256 $(/opt/vyatta/bin/vyatta-op-cmd-wrapper show configuration commands | grep '^set service suricata ' | sort | sha256sum | cut -c1-16)"
echo "service-suricata-config-lines $(/opt/vyatta/bin/vyatta-op-cmd-wrapper show configuration commands | grep -c '^set service suricata ')"
echo "mode-file $( [ -f /config/vyos-pi/suricata.conf ] && tr '\n' ' ' < /config/vyos-pi/suricata.conf || echo absent)"
echo "config-vyos-pi-dir $( [ -d /config/vyos-pi ] && ls -A /config/vyos-pi | tr '\n' ' ' || echo absent)"
echo "drop-conf $( [ -f /etc/suricata/drop.conf ] && sha256sum < /etc/suricata/drop.conf | cut -c1-16 || echo absent)"
echo "ips-nft-table $(sudo nft list table inet vyos_pi_ips >/dev/null 2>&1 && echo present || echo absent)"
echo "service $(systemctl is-active suricata)"
echo "capture-mode $(tr '\0' ' ' < /proc/$(pgrep -f '^/usr/bin/suricata' | head -1)/cmdline 2>/dev/null | grep -oE -- '--af-packet|-q [0-9]+' || echo none)"
echo "rules-drop-action $(grep -c '^drop ' /var/lib/suricata/rules/suricata.rules 2>/dev/null || echo 0)"
echo "watchdog-timer $(systemctl is-active bench-ips-restore.timer 2>/dev/null || true)"
R
}
case "$CMD" in
snapshot)
  d=${1:?dir}; mkdir -p "$d"
  rsh "/opt/vyatta/bin/vyatta-op-cmd-wrapper show configuration commands | grep '^set service suricata '" > "$d/service-suricata.cmds"
  rsh 'cat /config/vyos-pi/suricata.conf 2>/dev/null || echo "(absent)"' > "$d/mode-file.txt"
  "$0" rulecount > "$d/rulecount.txt" || true
  normalized > "$d/normalized.txt"; cat "$d/normalized.txt" ;;
diff)
  d=${1:?dir}; if diff <(cat "$d/normalized.txt") <(normalized); then echo IDENTICAL; else echo DIFFERENT; exit 1; fi ;;
status) normalized ;;
rulecount)
  rsh 'sh -s' <<'R'
f=/var/lib/suricata/rules/suricata.rules
echo "rules-file-lines-active $(grep -cE '^(alert|drop|pass|reject) ' $f 2>/dev/null || echo 0)"
echo "rules-file-lines-commented $(grep -cE '^# ?(alert|drop) ' $f 2>/dev/null || echo 0)"
sudo suricatasc -c dump-counters /run/suricata/suricata.socket 2>/dev/null | python3 -c 'import json,sys;[print("engine rules_loaded",e["rules_loaded"],"rules_failed",e["rules_failed"],"last_reload",e["last_reload"]) for e in json.load(sys.stdin)["message"]["detect"]["engines"]]'  2>/dev/null || echo "engine not answering"
R
  ;;
counters) rsh "sudo suricatasc -c dump-counters /run/suricata/suricata.socket" ;;
update) rsh 'sudo /usr/libexec/vyos/op_mode/update_suricata.sh 2>&1 | tail -15' ;;
stop) rsh 'sudo systemctl stop suricata; systemctl is-active suricata || true' ;;
start) rsh 'sudo systemctl start suricata; systemctl is-active suricata' ;;
drop-policy)
  g=${1:?groups}; conf=$(tr ',' '\n' <<<"$g" | sed 's/^/group:/; s/$/.rules/')
  printf '%s\n' "$conf" | rsh "sudo tee /etc/suricata/drop.conf >/dev/null && sudo $SURI_UPDATE --offline --no-test -q && grep -c '^drop ' /var/lib/suricata/rules/suricata.rules" ;;
ips-wan)
  rsh "sudo /usr/libexec/vyos-pi/vyos-pi-suricata-mode ips open && sudo nft -f - <<NFT
flush chain inet vyos_pi_ips forward
add rule inet vyos_pi_ips forward iifname \"$ROUTER_WAN_IF\" queue num 0 bypass
add rule inet vyos_pi_ips forward oifname \"$ROUTER_WAN_IF\" queue num 0 bypass
NFT
sudo nft list table inet vyos_pi_ips" ;;
watchdog)
  s=${1:?secs}
  rsh "sudo systemd-run --quiet --unit=bench-ips-restore --on-active=${s}s /bin/sh -c '$RESTORE_SH; logger -t bench-ips-restore restored-by-watchdog' && systemctl list-timers bench-ips-restore.timer --no-pager | sed -n 2p" ;;
cancel-watchdog) rsh 'sudo systemctl stop bench-ips-restore.timer 2>/dev/null; systemctl is-active bench-ips-restore.timer || true' ;;
restore) rsh "sudo sh -c '$RESTORE_SH'; systemctl is-active suricata" ;;
homenet-add-wan|homenet-del-wan)
  ip=$(public_ips); [ -n "$ip" ] || { echo "no public IP" >&2; exit 1; }
  verb=set; [ "$CMD" = homenet-del-wan ] && verb=delete
  printf '%s\n' '#!/bin/vbash' 'source /opt/vyatta/etc/functions/script-template' configure \
    "$verb service suricata address-group home-net address '$ip/32'" commit save exit |
    rsh 'cat > /tmp/bench-homenet.vbash; vbash /tmp/bench-homenet.vbash 2>&1 | tail -3; rm -f /tmp/bench-homenet.vbash' | sed "s/${ip//./\\.}/<WAN-IP>/g"
  echo "home-net: $verb <WAN-IP>/32" ;;
*) sed -n '2,25p' "$0"; exit 2 ;;
esac
