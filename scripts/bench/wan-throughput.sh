#!/usr/bin/env bash
# WAN throughput through the router's NAT from the wired client, with latency
# under load, single + parallel streams.
#   WAN_METHOD=iperf3 (default): public iperf3 servers (IPERF_SERVERS, ports
#     5201-5210 tried in turn); parallel runs are split across all servers at
#     once so one busy/slow server does not cap the result.
#   WAN_METHOD=cloudflare: speed.cloudflare.com __down/__up (rate-limits
#     repeated parallel downloads with HTTP 429, so only use it sparingly).
# Each run lasts DUR seconds (<=60); GAP seconds between runs.
# Usage: wan-throughput.sh OUTDIR    -> OUTDIR/wan.jsonl + ping-*.txt
set -uo pipefail
. "$(dirname "$0")/common.sh"
OUT=${1:?outdir}; mkdir -p "$OUT"
[ "$DUR" -le 60 ] || { echo "DUR must be <= 60" >&2; exit 1; }
CF=https://speed.cloudflare.com
CHUNK=90000000   # __down refuses >= 100 MB per request

dl_stream() {  # repeat 90 MB GETs until the deadline; print bytes
  local end=$1 total=0 left b
  while :; do
    left=$(python3 -c "print(max(0.0,$end-__import__('time').time()))")
    python3 -c "import sys;sys.exit(0 if $left>0.3 else 1)" || break
    b=$(curl --interface "$WIRED_IF" -s -o /dev/null --max-time "$left" \
          -w '%{size_download}' "$CF/__down?bytes=$CHUNK" || true)
    total=$((total + ${b%.*}))
  done
  echo "$total"
}
ul_stream() {  # one chunked POST streamed from /dev/zero for the whole window
  local end=$1 left
  left=$(python3 -c "print(max(1.0,$end-__import__('time').time()))")
  head -c 4000000000 /dev/zero | curl --interface "$WIRED_IF" -s -o /dev/null \
    --max-time "$left" -X POST -T - -H 'Content-Type: application/octet-stream' \
    -w '%{size_upload}' "$CF/__up" 2>/dev/null || true
}
ping_run() {   # ping $PING_TARGET (WAN) and the router (LAN) at 5 Hz for $1 s
  local secs=$1 tag=$2
  ping -b "$WIRED_IF" -i 0.2 -c $((secs * 5)) "$PING_TARGET" > "$OUT/ping-$tag-wan.txt" 2>&1 &
  ping -b "$WIRED_IF" -i 0.2 -c $((secs * 5)) "$ROUTER_IP" > "$OUT/ping-$tag-lan.txt" 2>&1 &
}
IPERF_SERVERS=${IPERF_SERVERS:-speedtest.chi11.us.leaseweb.net speedtest.dal13.us.leaseweb.net}
SRC_IP=$(ipconfig getifaddr "$WIRED_IF" 2>/dev/null || ip -4 -o addr show "$WIRED_IF" | awk '{print $4}' | cut -d/ -f1)
iperf_stream() {  # server streams dir end -> prints received bytes (download: -R)
  local srv=$1 n=$2 dir=$3 end=$4 p secs o flag=; [ "$dir" = down ] && flag=-R
  for p in $(seq 5201 5210); do
    secs=$(python3 -c "print(max(2,int($end-__import__('time').time())))")
    o=$(iperf3 -c "$srv" -p "$p" -B "$SRC_IP" -t "$secs" -P "$n" $flag -J --connect-timeout 1500 2>/dev/null)
    echo "$o" | grep -q '"error"' && continue
    echo "$o" | python3 -c 'import json,sys;print(int(json.load(sys.stdin)["end"]["sum_received"]["bytes"]))' 2>/dev/null && { echo "$srv:$p" >&2; return; }
  done
  echo 0
}
en7_bytes() { netstat -ib -I "$WIRED_IF" | awk 'NR==2{print $7, $10}'; }

run() {  # run DIR STREAMS
  local dir=$1 n=$2 tag="$1-x$2" end i nf t0 t1 sum
  log "WAN $dir x$n for ${DUR}s"
  ping_run "$DUR" "$tag"
  read -r ib0 ob0 < <(en7_bytes); t0=$(now)
  end=$(python3 -c "print($t0+$DUR)")
  if [ "${WAN_METHOD:-iperf3}" = iperf3 ]; then
    set -- $IPERF_SERVERS; local ns=$#; [ "$n" -lt "$ns" ] && ns=$n
    for i in $(seq 1 "$ns"); do
      eval "srv=\${$i}"; iperf_stream "$srv" $(( (n + ns - i) / ns )) "$dir" "$end" > "$OUT/.s$i" 2>>"$OUT/servers.log" &
    done; nf=$ns
  else
    nf=$n
    for i in $(seq 1 "$n"); do
      if [ "$dir" = down ]; then dl_stream "$end" > "$OUT/.s$i" & else ul_stream "$end" > "$OUT/.s$i" & fi
    done
  fi
  wait
  t1=$(now); read -r ib1 ob1 < <(en7_bytes)
  sum=0; for i in $(seq 1 "$nf"); do b=$(cat "$OUT/.s$i"); sum=$((sum + ${b%.*})); rm -f "$OUT/.s$i"; done
  python3 - "$dir" "$n" "$t0" "$t1" "$sum" "$ib0" "$ib1" "$ob0" "$ob1" "$OUT/ping-$tag-wan.txt" "$OUT/ping-$tag-lan.txt" >> "$OUT/wan.jsonl" <<'PY'
import json,re,sys
d,n,t0,t1,s,ib0,ib1,ob0,ob1,pw,pl=sys.argv[1:]
t0,t1=float(t0),float(t1); el=t1-t0
def pst(f):
    rt=[float(x) for x in re.findall(r'time=([\d.]+) ms',open(f).read())]
    sent=re.search(r'(\d+) packets transmitted, (\d+) packets received',open(f).read())
    if not rt: return {"n":0}
    rt.sort(); q=lambda p: rt[min(len(rt)-1,int(p*len(rt)))]
    loss=None
    if sent: loss=round(100*(1-int(sent.group(2))/int(sent.group(1))),1)
    return {"n":len(rt),"min":rt[0],"p50":q(.5),"p95":q(.95),"max":rt[-1],"loss_pct":loss}
nic=(int(ib1)-int(ib0)) if d=="down" else (int(ob1)-int(ob0))
print(json.dumps({"dir":d,"streams":int(n),"t0":t0,"t1":t1,"secs":round(el,2),
  "app_bytes":int(s),"app_mbps":round(int(s)*8/el/1e6,1),"nic_mbps":round(nic*8/el/1e6,1),
  "ping_wan":pst(pw),"ping_lan":pst(pl)}))
PY
  tail -1 "$OUT/wan.jsonl" | python3 -c 'import json,sys;d=json.load(sys.stdin);w=d["ping_wan"];print("  ->",d["app_mbps"],"Mbit/s (nic",d["nic_mbps"],") WAN ping p50",w.get("p50"),"p95",w.get("p95"),"ms")' >&2
  sleep "$GAP"
}

log "idle latency ${GAP}s"; ping_run 10 idle; sleep 11
python3 - "$OUT" >> "$OUT/wan.jsonl" <<'PY'
import json,re,sys
o=sys.argv[1]
for k in ("wan","lan"):
    rt=sorted(float(x) for x in re.findall(r'time=([\d.]+) ms',open(f"{o}/ping-idle-{k}.txt").read()))
    q=lambda p: rt[min(len(rt)-1,int(p*len(rt)))] if rt else None
    print(json.dumps({"dir":"idle","target":k,"n":len(rt),"min":rt[0] if rt else None,"p50":q(.5),"p95":q(.95),"max":rt[-1] if rt else None}))
PY
for spec in ${WAN_RUNS:-down:1 down:$STREAMS up:1 up:$STREAMS}; do run "${spec%%:*}" "${spec##*:}"; done
redact "$OUT"/ping-*.txt "$OUT/wan.jsonl"
