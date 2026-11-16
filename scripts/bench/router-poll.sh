#!/usr/bin/env bash
# Poll router CPU (per core), load, memory, temperature, WAN NIC counters and
# Suricata CPU/RSS (and ntopng's on Linux) every POLL_INT seconds over one ssh session (read-only).
# Works on FreeBSD (OPNsense) and Linux (VyOS). Runs until killed.
# Usage: router-poll.sh OUT.raw   (appends, so parts run separately share one file)
set -euo pipefail
. "$(dirname "$0")/common.sh"
OUT=${1:?out file}
exec ssh "${SSH_OPTS[@]}" "$ROUTER_SSH" "env WANIF=$ROUTER_WAN_IF INT=$POLL_INT sh -s" >> "$OUT" <<'REMOTE'
os=$(uname -s)
HZ=$(getconf CLK_TCK 2>/dev/null || echo 100)
pst() { # PID -> "cpu_ticks rss_kb" (0 0 if not running)
  [ -n "$1" ] && [ -r "/proc/$1/stat" ] || { echo "0 0"; return; }
  t=$(sed 's/.*) //' "/proc/$1/stat" | awk '{print $12+$13}')
  r=$(awk '/^VmRSS/{print $2}' "/proc/$1/status")
  echo "$t ${r:-0}"
}
pct() { # ticks prev_ticks rss -> "pct rss"
  d=$(( $1 - $2 )); [ "$d" -lt 0 ] && d=0
  awk -v d="$d" -v hz="$HZ" -v i="$INT" -v r="$3" 'BEGIN{printf "%.1f %d\n", 100*d/(hz*i), r}'
}
while :; do
  ts=$(date +%s)
  if [ "$os" = FreeBSD ]; then
    cp=$(sysctl -n kern.cp_times)                         # per cpu: user nice sys intr idle
    la=$(sysctl -n vm.loadavg | tr -d '{}')
    t=$(sysctl -n hw.rpi5.fan.cpu_temp 2>/dev/null || sysctl -n hw.bcm2712.thermal.cpu_temp 2>/dev/null || echo 0)
    fq=$(sysctl -n dev.cpu.0.freq 2>/dev/null || echo 0)
    mem="$(sysctl -n hw.physmem) $(( $(sysctl -n vm.stats.vm.v_free_count) * $(sysctl -n hw.pagesize) ))"
    nic=$(netstat -ibn -I "$WANIF" | awk 'NR==2{print $5,$6,$7,$8,$9,$10,$11}')
  else
    cp=$(awk '/^cpu[0-9]/{printf "%s %s %s %s %s ", $2, $3, $4, $7+$8, $5+$6}' /proc/stat)
    la=$(cut -d' ' -f1-3 /proc/loadavg)
    t=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)
    fq=$(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo 0) / 1000 ))
    mem="$(awk '/MemTotal/{t=$2*1024}/MemAvailable/{a=$2*1024}END{print t, a}' /proc/meminfo)"
    s=/sys/class/net/$WANIF/statistics
    nic="$(cat $s/rx_packets) $(cat $s/rx_errors) $(cat $s/rx_dropped) $(cat $s/rx_bytes) $(cat $s/tx_packets) $(cat $s/tx_errors) $(cat $s/tx_bytes)"
  fi
  if [ "$os" = FreeBSD ]; then
    sur=$(ps -axo pcpu,rss,comm 2>/dev/null | awk '$3 ~ /^(suricata|Suricata-Main|W#)/{c+=$1;r+=$2}END{print c+0, r+0}')
    ntop="0 0"
  else
    # Linux ps %CPU is a lifetime average, so take utime+stime deltas from /proc
    # instead: % of one core over the poll interval, plus RSS in KB.
    set -- $(pst "$(pgrep -f '^/usr/bin/suricata' | head -1)"); sur=$(pct "$1" "${s_prev:-$1}" "$2"); s_prev=$1
    set -- $(pst "$(pgrep -x ntopng | head -1)"); ntop=$(pct "$1" "${n_prev:-$1}" "$2"); n_prev=$1
  fi
  echo "$ts|$cp|$la|$t|$fq|$mem|$nic|$sur|$ntop" || exit 0
  sleep "$INT"
done
REMOTE
