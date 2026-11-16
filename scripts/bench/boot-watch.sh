#!/usr/bin/env bash
# External boot watcher, run from a LAN host. About once a second it sends
# one ping (1 s timeout) and probes TCP/22 for an SSH banner, and prints a
# line only when either state changes:  epoch.ms ping=0|1 ssh=<banner|->
# The probes take ~1 s, so the default INT=0 gives about one sample a second.
# Usage: boot-watch.sh HOST >> boot-watch.log
H=${1:?host}; INT=${INT:-0}
prev=
while :; do
  t=$(python3 -c 'import time;print(f"{time.time():.1f}")')
  # ping and the banner probe run in parallel so one sample takes ~1 s
  f=$(mktemp); (nc -G1 -w1 "$H" 22 </dev/null 2>/dev/null | head -1 | tr -d '\r' > "$f") & np=$!
  if ping -c1 -t1 "$H" >/dev/null 2>&1; then p=1; else p=0; fi
  wait $np; b=$(cat "$f"); rm -f "$f"; [ -n "$b" ] || b=-
  cur="ping=$p ssh=$b"
  [ "$cur" != "$prev" ] && { echo "$t $(date -r ${t%.*} +%T) $cur"; prev=$cur; }
  sleep "$INT"   # sample period is INT + ~1 s probe time
done
