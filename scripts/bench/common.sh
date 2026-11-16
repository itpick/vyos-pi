# shellcheck shell=bash
# Shared helpers. Source from the other bench scripts.
BENCH_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ -f "$BENCH_DIR/bench.env" ] && . "$BENCH_DIR/bench.env" || . "$BENCH_DIR/bench.env.example"
: "${ROUTER_IP:?}" "${ROUTER_SSH:?}" "${ROUTER_WAN_IF:?}" "${WIRED_IF:?}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5)
log() { echo "$(date '+%F %T') $*" >&2; }
now() { python3 -c 'import time;print(f"{time.time():.3f}")'; }
# Redact the current public IPv4/IPv6 from a file in place (called on every raw file).
public_ips() {
  [ -n "${_PUB4:-}" ] || _PUB4=$(curl -s --interface "$WIRED_IF" --max-time 5 https://1.1.1.1/cdn-cgi/trace | sed -n 's/^ip=//p')
  echo "$_PUB4"
}
redact() {
  local ip; ip=$(public_ips)
  for f in "$@"; do
    [ -f "$f" ] || continue
    [ -n "$ip" ] && sed -i '' "s/${ip//./\\.}/<WAN-IP>/g" "$f"
    # public IPv6 (global unicast 2000::/3) and the ISP's /24 gateway range
    sed -E -i '' 's/\b2[0-9a-f]{3}:[0-9a-f:]{4,}/<WAN-IPv6>/g' "$f"
  done
}
