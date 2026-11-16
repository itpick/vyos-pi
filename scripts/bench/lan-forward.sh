#!/usr/bin/env bash
# LAN -> LAN2 routed forwarding: iperf3 from LAN_PEER (wired LAN) to this Mac's
# Wi-Fi address on LAN2. WI-FI LIMITED: measures the Deco Wi-Fi hop as much as
# the router. Both directions, single + 4 streams, DUR s each.
# Usage: lan-forward.sh OUTDIR   -> OUTDIR/lan.jsonl
set -uo pipefail
. "$(dirname "$0")/common.sh"
OUT=${1:?outdir}; mkdir -p "$OUT"
PORT=5299
IPERF="nix shell nixpkgs#iperf3 -c iperf3"
log "LAN peer load: $(ssh "${SSH_OPTS[@]}" "$LAN_PEER" uptime)"
for spec in ${LAN_RUNS:-fwd:1 fwd:4 rev:1 rev:4}; do
  dir=${spec%%:*}; n=${spec##*:}; flag=; [ "$dir" = rev ] && flag=-R
  iperf3 -s -B "$WIFI_IP" -p $PORT -1 >/dev/null 2>&1 & srv=$!
  sleep 1
  log "LAN->LAN2 $dir x$n ${DUR}s"
  t0=$(now)
  ssh "${SSH_OPTS[@]}" "$LAN_PEER" "$IPERF -c $WIFI_IP -p $PORT -t $DUR -P $n $flag -J" > "$OUT/.iperf.json" 2>/dev/null
  t1=$(now); kill $srv 2>/dev/null; wait $srv 2>/dev/null
  python3 - "$dir" "$n" "$t0" "$t1" "$OUT/.iperf.json" >> "$OUT/lan.jsonl" <<'PY'
import json,sys
d,n,t0,t1,f=sys.argv[1:]
try:
    j=json.load(open(f)); e=j["end"]
    r={"recv_mbps":round(e["sum_received"]["bits_per_second"]/1e6,1),
       "sent_mbps":round(e["sum_sent"]["bits_per_second"]/1e6,1),
       "retransmits":e["sum_sent"].get("retransmits")}
except Exception as ex: r={"error":str(ex)}
r.update({"dir":"LAN->LAN2" if d=="fwd" else "LAN2->LAN","streams":int(n),"t0":float(t0),"t1":float(t1),"wifi_limited":True})
print(json.dumps(r))
PY
  tail -1 "$OUT/lan.jsonl" >&2
  rm -f "$OUT/.iperf.json"; sleep "$GAP"
done
