#!/usr/bin/env python3
"""Side-by-side WAN table for two routers measured with run-state.sh/summarize.py.

Usage: compare.py A_ROOT B_ROOT "LABEL=A_STATE:B_STATE" ... [--names A,B] [--skip B_STATE:IDX ...]
Each root holds the summary.json written by summarize.py. Each pair names one
Suricata state on each router; the four WAN runs (down/up x1/xN) are matched
by direction and stream count. --skip drops a run from B by its index within
that state's wan list (a run thrown away, e.g. a busy public server).
"""
import json, os, sys

def main():
    args = sys.argv[1:]
    names, skip, pairs = ["A", "B"], set(), []
    while args:
        a = args.pop(0)
        if a == "--names": names = args.pop(0).split(",")
        elif a == "--skip": skip.add(args.pop(0))
        else: pairs.append(a)
    ra, rb = pairs.pop(0), pairs.pop(0)
    sa = json.load(open(os.path.join(ra, "summary.json")))
    sb = json.load(open(os.path.join(rb, "summary.json")))
    na, nb = names
    print(f"| Suricata state ({na} / {nb}) | Test | {na} Mbit/s | {nb} Mbit/s | {na} WAN ping p50 / p95 ms | {nb} WAN ping p50 / p95 ms "
          f"| {na} CPU avg / busiest core % | {nb} CPU avg / busiest core % | {na} Suricata CPU % | {nb} Suricata CPU % |")
    print("|---|---|---:|---:|---|---|---|---|---:|---:|")
    for p in pairs:
        label, st = p.split("=", 1); a_st, b_st = st.split(":")
        runs_b = [r for i, r in enumerate(sb[b_st]["wan"]) if f"{b_st}:{i}" not in skip]
        for r in sa[a_st]["wan"]:
            m = [x for x in runs_b if x["dir"] == r["dir"] and x["streams"] == r["streams"]]
            if not m: continue
            b = m[-1]
            def ping(x): w = x["ping_wan"]; return f"{w.get('p50', 0):.1f} / {w.get('p95', 0):.1f}"
            def cpu(x): R = x["router"]; return f"{R.get('cpu_avg_total', 0):.0f} / {R.get('cpu_max_core', 0)}"
            def sur(x): return f"{x['router'].get('suricata_cpu_max_pct', 0):.0f}"
            print(f"| {label} | {r['dir']} x{r['streams']} | {r['app_mbps']:.0f} | {b['app_mbps']:.0f} | {ping(r)} | {ping(b)} "
                  f"| {cpu(r)} | {cpu(b)} | {sur(r)} | {sur(b)} |")

if __name__ == "__main__":
    main()
