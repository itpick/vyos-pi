#!/usr/bin/env bash
# Poll router CPU (per core), load, memory, temperature, WAN NIC counters and
# Suricata CPU/RSS every POLL_INT seconds over one ssh session (read-only).
# Works on FreeBSD (OPNsense) and Linux (VyOS). Runs until killed.
# Usage: router-poll.sh OUT.raw
set -euo pipefail
. "$(dirname "$0")/common.sh"
OUT=${1:?out file}
exec ssh "${SSH_OPTS[@]}" "$ROUTER_SSH" "env WANIF=$ROUTER_WAN_IF INT=$POLL_INT sh -s" > "$OUT" <<'REMOTE'
os=$(uname -s)
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
  sur=$(ps -axo pcpu,rss,comm 2>/dev/null | awk '$3 ~ /^(suricata|Suricata-Main|W#)/{c+=$1;r+=$2}END{print c+0, r+0}')
  echo "$ts|$cp|$la|$t|$fq|$mem|$nic|$sur" || exit 0
  sleep "$INT"
done
REMOTE
