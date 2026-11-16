#!/usr/bin/env bash
# Host-terminated iperf3 between this Mac and the router itself (measures the
# router's NIC + stack + CPU, not forwarding/NAT).
#
# The iperf3 CLIENT runs on the router (over ssh) and the server on this Mac,
# because macOS "Local Network" privacy blocks the Homebrew iperf3 binary from
# opening connections to LAN hosts ("No route to host"), while it may accept
# them. Direction labels are about the data: "up" = Mac -> router (client -R),
# "down" = router -> Mac. Nothing listens on the router.
# Router CPU/temp/NIC counters are polled over ssh with the same read-only
# loop as router-poll.sh while the runs happen.
#
# Usage: iperf-host.sh TARGET_IP ROUTER_SSH POLL_IF OUTDIR
#   TARGET_IP  router address the client binds to (selects the NIC under test)
#   ROUTER_SSH ssh target (root@192.168.68.1, vyos@pi5-1, ...); needs iperf3
#   POLL_IF    router NIC whose counters are recorded (the one under test)
# Env: DUR (15, keep <= 30), GAP (5), PORT (5201), UDP_BW (1G), SRC (this
#      Mac's server address, default: en7's IPv4), IPERF (router iperf3 command),
#      RUNS (see below).
# Output: OUTDIR/iperf.jsonl, OUTDIR/raw/*.json, OUTDIR/poll.raw
set -uo pipefail
TARGET=${1:?target ip}; POLL_SSH=${2:?router ssh}; POLL_IF=${3:?poll if}; OUT=${4:?outdir}
DUR=${DUR:-15}; GAP=${GAP:-5}; PORT=${PORT:-5201}; UDP_BW=${UDP_BW:-1G}; POLL_INT=${POLL_INT:-2}
SRC=${SRC:-$(ipconfig getifaddr en7 2>/dev/null)}; IPERF=${IPERF:-iperf3}
RUNS=${RUNS:-tcp:up:1 tcp:down:1 tcp:up:4 tcp:down:4 udp:up:1 udp:down:1}
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR)
mkdir -p "$OUT/raw"
log() { echo "$(date '+%F %T') $*" >&2; }

# Reuse the remote polling loop from router-poll.sh verbatim.
REMOTE=$(sed -n "/<<'REMOTE'/,/^REMOTE$/p" "$(dirname "$0")/router-poll.sh" | sed '1d;$d')
# Each sample is re-stamped with this Mac's clock on arrival, so a router whose
# clock is wrong (no RTC, NTP not synced yet) still lines up with the runs.
ssh "${SSH_OPTS[@]}" "$POLL_SSH" "env WANIF=$POLL_IF INT=$POLL_INT sh -s" <<<"$REMOTE" 2>/dev/null |
  while IFS= read -r l; do echo "$(date +%s)|${l#*|}"; done >> "$OUT/poll.raw" &
poller=$!
trap 'kill $poller 2>/dev/null' EXIT
sleep 3

for spec in $RUNS; do
  IFS=: read -r proto dir n <<<"$spec"
  args=(-c "$SRC" -B "$TARGET" -p "$PORT" -t "$DUR" -P "$n" -J)
  [ "$dir" = up ] && args+=(-R)
  [ "$proto" = udp ] && args+=(-u -b "$UDP_BW")
  name="$proto-$dir-x$n"
  log "$name -> $TARGET (${DUR}s)"
  iperf3 -s -B "$SRC" -p "$PORT" -1 >/dev/null 2>&1 & srv=$!
  sleep 1
  t0=$(date +%s)
  ssh "${SSH_OPTS[@]}" "$POLL_SSH" "$IPERF ${args[*]}" > "$OUT/raw/$name.json" 2>&1
  t1=$(date +%s)
  kill $srv 2>/dev/null; wait $srv 2>/dev/null
  python3 - "$proto" "$dir" "$n" "$t0" "$t1" "$OUT/raw/$name.json" >> "$OUT/iperf.jsonl" <<'PY'
import json, sys
proto, d, n, t0, t1, f = sys.argv[1:]
r = {"proto": proto, "dir": d, "streams": int(n), "t0": int(t0), "t1": int(t1)}
try:
    e = json.load(open(f))["end"]
    if proto == "tcp":
        r.update(recv_mbps=round(e["sum_received"]["bits_per_second"] / 1e6, 1),
                 sent_mbps=round(e["sum_sent"]["bits_per_second"] / 1e6, 1),
                 retransmits=e["sum_sent"].get("retransmits"))
    else:
        s = e["sum"]
        # client-side "sum" carries the receiver's loss/jitter for UDP
        recv = e.get("sum_received", s)
        r.update(sent_mbps=round(e.get("sum_sent", s)["bits_per_second"] / 1e6, 1),
                 recv_mbps=round(recv["bits_per_second"] / 1e6, 1),
                 jitter_ms=round(recv.get("jitter_ms", s.get("jitter_ms", 0)), 3),
                 lost_pct=round(recv.get("lost_percent", s.get("lost_percent", 0)), 2),
                 lost=recv.get("lost_packets", s.get("lost_packets")),
                 packets=recv.get("packets", s.get("packets")))
    r["cpu_local"] = e.get("cpu_utilization_percent")
except Exception as ex:
    r["error"] = str(ex)
print(json.dumps(r))
PY
  tail -1 "$OUT/iperf.jsonl" >&2
  sleep "$GAP"
done
