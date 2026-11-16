#!/usr/bin/env python3
"""Summarize bench state directories into markdown tables + summary.json.

Usage: summarize.py DATA_ROOT [STATE ...]   (default: every sub-directory)
For each throughput run, router samples whose timestamp falls inside the run
window are aggregated: per-core busy % (from kern.cp_times / /proc/stat
deltas), load average, temperature, memory, WAN NIC drops, Suricata CPU/RSS, and ntopng CPU/RSS when the poller recorded it (Linux).
"""
import json, os, sys

def load_poll(path):
    rows = []
    if not os.path.exists(path):
        return rows
    for line in open(path):
        p = line.strip().split("|")
        if len(p) < 8:
            continue
        try:
            ts = int(p[0]); cp = list(map(int, p[1].split()))
            la = list(map(float, p[2].split())); temp = int(p[3]); fq = int(p[4])
            mem = list(map(int, p[5].split())); nic = list(map(int, p[6].split()))
            sur = list(map(float, p[7].split()))
            ntop = list(map(float, p[8].split())) if len(p) > 8 else [0.0, 0.0]
        except ValueError:
            continue
        rows.append(dict(ts=ts, cp=cp, la=la, temp=temp / 1000 if temp > 1000 else temp,
                         fq=fq, mem=mem, nic=nic, sur=sur, ntop=ntop))
    # per-core busy % between consecutive samples (5 counters/core: user nice sys intr idle)
    rows.sort(key=lambda r: r["ts"])
    for a, b in zip(rows, rows[1:]):
        if b["ts"] - a["ts"] > 10:   # gap between separately-run parts: no delta
            continue
        n = len(b["cp"]) // 5; cores = []; intr = []
        for c in range(n):
            d = [b["cp"][c * 5 + i] - a["cp"][c * 5 + i] for i in range(5)]
            tot = sum(d) or 1
            cores.append(100 * (tot - d[4]) / tot); intr.append(100 * d[3] / tot)
        b["cores"] = cores; b["intr"] = intr
        dt = (b["ts"] - a["ts"]) or 1
        b["rx_mbps"] = (b["nic"][3] - a["nic"][3]) * 8 / dt / 1e6
        b["tx_mbps"] = (b["nic"][6] - a["nic"][6]) * 8 / dt / 1e6
        b["idrop"] = b["nic"][2] - a["nic"][2]
    return [r for r in rows if "cores" in r]

def window(poll, t0, t1):
    w = [r for r in poll if t0 + 2 <= r["ts"] <= t1 + 1]
    if not w:
        return {}
    n = len(w[0]["cores"])
    avg = [sum(r["cores"][c] for r in w) / len(w) for c in range(n)]
    return {
        "samples": len(w),
        "cpu_avg_per_core": [round(x) for x in avg],
        "cpu_avg_total": round(sum(avg) / n, 1),
        "cpu_max_core": round(max(max(r["cores"]) for r in w)),
        "intr_avg_total": round(sum(sum(r["intr"]) / n for r in w) / len(w), 1),
        "load1_max": max(r["la"][0] for r in w),
        "temp_max_c": max(r["temp"] for r in w),
        "temp_avg_c": round(sum(r["temp"] for r in w) / len(w), 1),
        "mem_free_min_mb": round(min(r["mem"][1] for r in w) / 2**20),
        "wan_nic_rx_mbps_max": round(max(r["rx_mbps"] for r in w)),
        "wan_nic_tx_mbps_max": round(max(r["tx_mbps"] for r in w)),
        "wan_nic_idrops": sum(r["idrop"] for r in w),
        "suricata_cpu_max_pct": max(r["sur"][0] for r in w),
        "suricata_rss_mb": round(max(r["sur"][1] for r in w) / 1024),
        "suricata_cpu_avg_pct": round(sum(r["sur"][0] for r in w) / len(w), 1),
        "ntopng_cpu_avg_pct": round(sum(r["ntop"][0] for r in w) / len(w), 1),
        "ntopng_rss_mb": round(max(r["ntop"][1] for r in w) / 1024),
    }

def jl(path):
    return [json.loads(l) for l in open(path)] if os.path.exists(path) else []

def main():
    root = sys.argv[1]
    states = sys.argv[2:] or sorted(d for d in os.listdir(root)
                                    if os.path.isdir(os.path.join(root, d)) and not d.startswith("."))
    out = {}
    for st in states:
        d = os.path.join(root, st); poll = load_poll(os.path.join(d, "poll.raw"))
        s = {"wan": [], "lan": [], "idle": {}, "detect": jl(os.path.join(d, "detect.jsonl")),
             "alerts": jl(os.path.join(d, "alerts.jsonl"))}
        if poll:
            s["idle"] = window(poll, poll[0]["ts"] - 3, poll[0]["ts"] + 6)
        for r in jl(os.path.join(d, "wan.jsonl")):
            if r["dir"] == "idle":
                s.setdefault("idle_ping", {})[r["target"]] = r; continue
            r["router"] = window(poll, r["t0"], r["t1"]); s["wan"].append(r)
        for r in jl(os.path.join(d, "lan.jsonl")):
            r["router"] = window(poll, r["t0"], r["t1"]); s["lan"].append(r)
        out[st] = s
    json.dump(out, open(os.path.join(root, "summary.json"), "w"), indent=1)

    p = print
    p("### WAN throughput (wired client, through NAT; internet-server limited)\n")
    p("| State | Test | Mbit/s (app) | Mbit/s (NIC) | WAN ping p50/p95/max ms | loss % | LAN ping p95 ms | CPU avg % (per core) | busiest core % | load1 max | temp max °C | Suricata CPU % |")
    p("|---|---|---:|---:|---|---:|---:|---|---:|---:|---:|---:|")
    for st, s in out.items():
        for r in s["wan"]:
            w, l, R = r["ping_wan"], r["ping_lan"], r["router"]
            p(f"| {st} | {r['dir']} x{r['streams']} | {r['app_mbps']} | {r['nic_mbps']} | "
              f"{w.get('p50')}/{w.get('p95')}/{w.get('max')} | {w.get('loss_pct')} | {l.get('p95')} | "
              f"{R.get('cpu_avg_total')} ({'/'.join(map(str, R.get('cpu_avg_per_core', [])))}) | {R.get('cpu_max_core')} | "
              f"{R.get('load1_max')} | {R.get('temp_max_c')} | {R.get('suricata_cpu_max_pct')} |")
    p("\n### Idle baseline\n")
    p("| State | WAN ping p50/p95 ms | LAN ping p50/p95 ms | CPU avg % | temp °C | free mem MB | Suricata RSS MB |")
    p("|---|---|---|---:|---:|---:|---:|")
    for st, s in out.items():
        ip, I = s.get("idle_ping", {}), s["idle"]
        w, l = ip.get("wan", {}), ip.get("lan", {})
        p(f"| {st} | {w.get('p50')}/{w.get('p95')} | {l.get('p50')}/{l.get('p95')} | {I.get('cpu_avg_total')} | "
          f"{I.get('temp_avg_c')} | {I.get('mem_free_min_mb')} | {I.get('suricata_rss_mb')} |")
    if any(s["lan"] for s in out.values()):
        p("\n### LAN -> LAN2 forwarding (iperf3, wired LAN host <-> Mac on Deco Wi-Fi: WI-FI LIMITED)\n")
        p("| State | Direction | Streams | Mbit/s | Retransmits | Router CPU avg % | busiest core % |")
        p("|---|---|---:|---:|---:|---:|---:|")
        for st, s in out.items():
            for r in s["lan"]:
                R = r["router"]
                p(f"| {st} | {r['dir']} | {r['streams']} | {r.get('recv_mbps')} | {r.get('retransmits')} | "
                  f"{R.get('cpu_avg_total')} | {R.get('cpu_max_core')} |")

if __name__ == "__main__":
    main()
