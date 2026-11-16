#!/usr/bin/env python3
"""Summarize iperf-host.sh output directories into one markdown table.

Usage: iperf-host-summary.py DIR [DIR ...]
Each DIR holds iperf.jsonl + poll.raw. Router CPU per run is taken from the
poll samples inside the run window (same maths as summarize.py).
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from summarize import load_poll, window  # noqa: E402

def main():
    print("| Setup | Test | Mbit/s | TCP retransmits | UDP loss % / jitter ms | Router CPU avg % (per core) | Busiest core % | NIC rx/tx peak Mbit/s | Temp max °C |")
    print("|---|---|---:|---:|---|---|---:|---|---:|")
    out = {}
    for d in sys.argv[1:]:
        poll = load_poll(os.path.join(d, "poll.raw"))
        label = os.path.basename(d.rstrip("/"))
        out[label] = []
        for r in map(json.loads, open(os.path.join(d, "iperf.jsonl"))):
            w = window(poll, r["t0"], r["t1"])
            r["router"] = w
            out[label].append(r)
            arrow = "Mac → router" if r["dir"] == "up" else "router → Mac"
            test = f"{r['proto'].upper()} {arrow} x{r['streams']}"
            if r["proto"] == "udp":
                test += " @1G"
            if "error" in r:
                print(f"| {label} | {test} | error: {r['error']} | | | | | | |")
                continue
            udp = f"{r['lost_pct']} / {r['jitter_ms']}" if r["proto"] == "udp" else ""
            rt = r.get("retransmits") if r["proto"] == "tcp" else ""
            cpu = (f"{w['cpu_avg_total']} ({'/'.join(map(str, w['cpu_avg_per_core']))})" if w else "n/a")
            nic = f"{w.get('wan_nic_rx_mbps_max')} / {w.get('wan_nic_tx_mbps_max')}" if w else ""
            print(f"| {label} | {test} | {r['recv_mbps']:.0f} | {rt} | {udp} | {cpu} | "
                  f"{w.get('cpu_max_core', '')} | {nic} | {w.get('temp_max_c', '')} |")
    json.dump(out, open(os.environ.get("SUMMARY_JSON", "/dev/null"), "w"), indent=1)

if __name__ == "__main__":
    main()
