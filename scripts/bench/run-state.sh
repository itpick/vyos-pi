#!/usr/bin/env bash
# Run the whole measurement set for one router/IDS state.
# Usage: run-state.sh STATE OUTROOT [wan] [lan] [detect]   (default: all three)
#   -> OUTROOT/STATE/{poll.raw,wan.jsonl,lan.jsonl,detect.jsonl,alerts.jsonl,router-*.txt}
set -uo pipefail
. "$(dirname "$0")/common.sh"
STATE=${1:?state}; OUT=${2:?outroot}/$STATE; shift 2
PARTS=${*:-wan lan detect}
mkdir -p "$OUT"; H=$(dirname "$0")
rsh() { ssh "${SSH_OPTS[@]}" "$ROUTER_SSH" "$@"; }
suri_info() {
  rsh 'sh -s' <<'R'
uptime
for f in /var/log/suricata/stats.log /var/log/suricata/stats.json; do [ -f $f ] && { echo "== $f (last block)"; tail -120 $f | awk '/^Date:/{b=""} {b=b $0 "\n"} END{printf "%s", b}' | grep -E 'Date|capture|decoder.pkts|decoder.bytes|ips\.|drop|flow.memuse|detect.alert |tcp.reassembly_gap' ; }; done
ls /var/log/suricata/ 2>/dev/null | head
R
}
date +%s > "$OUT/t_start"
suri_info > "$OUT/router-before.txt" 2>&1
"$H/router-poll.sh" "$OUT/poll.raw" & POLL=$!
trap 'kill $POLL 2>/dev/null' EXIT
sleep 6   # idle baseline samples
for p in $PARTS; do
  case $p in
    wan) "$H/wan-throughput.sh" "$OUT" ;;
    lan) "$H/lan-forward.sh" "$OUT" ;;
    detect)
      t0=$(date +%s); "$H/detection.sh" "$OUT"; sleep 8
      if [ "$ROUTER_KIND" = opnsense ]; then "$H/opnsense-ids.sh" alerts "$t0" > "$OUT/alerts.jsonl" || true
      else rsh "grep -h '\"event_type\":\"alert\"' /var/log/suricata/eve.json 2>/dev/null" | python3 -c '
import json,sys,datetime
t0=float(sys.argv[1])
for l in sys.stdin:
    try: e=json.loads(l)
    except Exception: continue
    if datetime.datetime.strptime(e["timestamp"][:19],"%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc).timestamp()>=t0-60:
        a=e.get("alert",{}); print(json.dumps({"timestamp":e["timestamp"],"alert_sid":a.get("signature_id"),"alert":a.get("signature"),"alert_action":a.get("action"),"src_ip":e.get("src_ip"),"dest_ip":e.get("dest_ip"),"proto":e.get("proto")}))' "$t0" > "$OUT/alerts.jsonl"; fi
      redact "$OUT/alerts.jsonl"
      log "alerts: $(wc -l < "$OUT/alerts.jsonl")"
      python3 -c 'import json,sys,collections;c=collections.Counter((json.loads(l)["alert_sid"],json.loads(l)["alert"],json.loads(l)["alert_action"]) for l in open(sys.argv[1]));[print(" ",n,*k) for k,n in c.most_common()]' "$OUT/alerts.jsonl" >&2 ;;
  esac
done
sleep 4
kill $POLL 2>/dev/null; wait $POLL 2>/dev/null
date +%s > "$OUT/t_end"
suri_info > "$OUT/router-after.txt" 2>&1
redact "$OUT"/*.txt "$OUT"/*.jsonl "$OUT"/poll.raw
log "state $STATE done -> $OUT"
