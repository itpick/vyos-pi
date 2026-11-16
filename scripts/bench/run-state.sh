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
  if [ "$ROUTER_KIND" = vyos ]; then
    # VyOS writes no stats.log: read the engine counters over Suricata's unix socket
    rsh 'sh -s' <<'R'
uptime; free -m | sed -n 2p
echo "== suricata: $(systemctl is-active suricata), mode file: $(cat /config/vyos-pi/suricata.conf 2>/dev/null | tr '\n' ' ')"
sudo nft list table inet vyos_pi_ips 2>/dev/null | grep -E 'queue|iifname|oifname' | sed 's/^/== ips nft: /'
sudo suricatasc -c dump-counters /run/suricata/suricata.socket 2>/dev/null | python3 -c '
import json,sys
m=json.load(sys.stdin)["message"]
flat={}
def walk(p,v):
    if isinstance(v,dict):
        for k,x in v.items(): walk(p+[k],x)
    elif not isinstance(v,list): flat[".".join(p)]=v
walk([],m)
keep=("uptime","capture.","ips.","nfq.","decoder.pkts","decoder.bytes","detect.alert","flow.memuse","tcp.reassembly_gap","detect.engines")
for k,v in sorted(flat.items()):
    if k.startswith("threads."): continue
    if k.startswith(keep) or "drop" in k: print(k, v)
for e in m.get("detect",{}).get("engines",[]): print("detect.rules_loaded", e.get("rules_loaded"), "failed", e.get("rules_failed"), "last_reload", e.get("last_reload"))
' || echo "suricata not answering on its socket"
R
    return
  fi
  rsh 'sh -s' <<'R'
uptime
for f in /var/log/suricata/stats.log /var/log/suricata/stats.json; do [ -f $f ] && { echo "== $f (last block)"; tail -120 $f | awk '/^Date:/{b=""} {b=b $0 "\n"} END{printf "%s", b}' | grep -E 'Date|capture|decoder.pkts|decoder.bytes|ips\.|drop|flow.memuse|detect.alert |tcp.reassembly_gap' ; }; done
ls /var/log/suricata/ 2>/dev/null | head
R
}
# a later part run into the same state keeps the earlier files (router-before-<parts>.txt)
sfx=; [ -f "$OUT/t_start" ] && sfx=-$(echo "$PARTS" | tr ' ' '-')
[ -z "$sfx" ] && date +%s > "$OUT/t_start"
suri_info > "$OUT/router-before$sfx.txt" 2>&1
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
suri_info > "$OUT/router-after$sfx.txt" 2>&1
redact "$OUT"/*.txt "$OUT"/*.jsonl "$OUT"/poll.raw
log "state $STATE done -> $OUT"
