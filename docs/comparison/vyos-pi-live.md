# vyos-pi as the live home router: throughput, latency, load, Suricata IDS/IPS and ntopng

Measured on 2026-11-16, 21:43 to 22:08 UTC (15:43 to 16:08 CST), on the live home router, about
20 minutes after VyOS (vyos-pi 2026.11.16-2) replaced OPNsense on it. It uses the same scripts,
client, public servers, run length and probes as the
[opnsense-pi baseline](opnsense-pi-baseline.md), so the two can be read side by side. The
scripts in `scripts/bench/` now handle VyOS too (see [Re-running](#re-running)).

**Read these numbers with three caveats:**

1. **WAN throughput is limited by the public servers, not by the router.** No single public
   iperf3 server fills 1 GbE from here, and the same state repeated on OPNsense varied by about
   ±25 %. The router CPU columns, and the IPS state where the router really is the limit, say
   more than the Mbit/s column.
2. **Both routers were carrying live household traffic** (about 70 DHCP clients) during the runs.
3. **VyOS was also running ntopng and AdGuard Home**, which OPNsense was not. ntopng alone costs
   about 0.5 to 0.7 of a core under load (see [ntopng overhead](#ntopng-overhead)), and that is
   included in every VyOS CPU figure except state B2.

## Setup

| | opnsense-pi (baseline, pi5-2) | vyos-pi (this run, pi5-1) |
|---|---|---|
| Board | Raspberry Pi 5, 16 GB, 4x Cortex-A76 | the same model, a **different physical board** |
| OS | OPNsense 26.7.9_1, FreeBSD 15.1-RELEASE-p6 | vyos-pi 2026.11.16-2 (VyOS rolling), Linux 6.18.62 |
| WAN | onboard RP1 GbE `rp1eth0`, public DHCP address (redacted) | onboard RP1 GbE `eth0` (`macb`), the same AT&T lease |
| LAN | `ue1`, USB RTL8156, 192.168.68.1/22, at 1 Gb/s | `eth2`, USB RTL8156 (`r8152`), 192.168.68.1/22, at 1 Gb/s. **A different adapter unit:** OPNsense's LAN adapter (80:3f:5d:f9:e1:bd) is now VyOS's LAN2 port |
| LAN2 (Deco Wi-Fi) | `ue0`, USB 2.5 GbE, 192.168.72.1/22 | `eth1`, USB RTL8156 (80:3f:5d:f9:e1:bd), 192.168.72.1/22, at 2.5 Gb/s |
| Suricata | 8.0.8, pcap on the WAN | 7.0.10, af-packet on `eth0` (VyOS's `service suricata`) |
| Also running | | ntopng 7.1 Community (capture on eth0/eth1/eth2, capped at 1 CPU and 768 MB), AdGuard Home (DNS), WireGuard |
| Wired client | Mac `en7` 1 GbE on LAN, 192.168.68.250 | the same Mac, port and address |
| Wi-Fi client | the same Mac, `en0` on LAN2 through the Deco | the same |
| LAN peer | nixtop (192.168.68.158, wired LAN) | the same |
| WAN servers | Leaseweb Chicago and Dallas iperf3 servers, parallel runs split across both | the same |

All NIC interrupts on VyOS (eth0, and both USB controllers that carry eth1 and eth2) are handled
by **core 0**. That is why core 0 is the busiest core in every VyOS row.

## States

| ID | Suricata state | Matches baseline state |
|---|---|---|
| A0 | **As found after the swap**: IDS (af-packet on eth0), **0 rules loaded** (`update suricata` had not run yet). Detection probes only | A (OPNsense had 0 rules too) |
| A | **As deployed**: IDS after `update suricata`, ET Open, **53,439 rules loaded** (69,409 in the file, 0 failed), HOME_NET = RFC1918 | C (OPNsense: 33,175 active rules, HOME_NET RFC1918) |
| C2 | A plus the WAN /32 in HOME_NET. Detection probes only | C2 |
| B | Suricata stopped (ntopng running) | B |
| B2 | Suricata stopped and **ntopng stopped** | none (shows ntopng's cost) |
| C | **IPS on the WAN only**: vyos-pi IPS mode (`vyos-pi-suricata-mode ips open`, NFQUEUE, fail open), same 53,439 rules, drop policy on 5 rulesets. Ran 3 min 17 s (22:03:53 to 22:07:10Z), guarded by a 6-minute restore watchdog on the router | D |

Differences from the baseline's IPS run, both deliberate:

- **WAN only.** The vyos-pi IPS mode queues *every* forwarded packet, on all interfaces.
  `vyos-ids.sh ips-wan` narrows the queue to packets entering or leaving `eth0` right after
  switching the mode, so LAN to LAN2 traffic was not inspected, as on OPNsense (netmap on the WAN
  only).
- **Drop policy on 5 rulesets, not 6:** emerging-attack_response, -scan, -dns, -dyn_dns and
  -coinminer. emerging-user_agents was left out, because in the baseline it blocked a household
  device's Go HTTP client. ET INFO stayed alert-only, as before, because household STUN traffic
  matches it hundreds of times a minute.

## WAN throughput through NAT, side by side (wired client, 15 s per run)

Pings run at 5 Hz during each run (WAN = 1.1.1.1). CPU is the router's average busy % over the
run across 4 cores, and the busiest single core in any 2 s sample. Suricata CPU is in % of one core.
Generated with `scripts/bench/compare.py` from the two `summary.json` files.

| Suricata state (OPNsense / VyOS) | Test | OPNsense Mbit/s | VyOS Mbit/s | OPNsense WAN ping p50 / p95 ms | VyOS WAN ping p50 / p95 ms | OPNsense CPU avg / busiest core % | VyOS CPU avg / busiest core % | OPNsense Suricata CPU % | VyOS Suricata CPU % |
|---|---|---:|---:|---|---|---|---|---:|---:|
| Stopped (B / B) | down x1 | 230 | 319 ¹ | 7.2 / 8.4 | 6.4 / 7.3 | 16 / 39 | 20 / 72 | 0 | 0 |
| Stopped (B / B) | down x8 | 664 | 591 | 7.4 / 19.7 | 6.4 / 11.0 | 26 / 51 | 30 / 83 | 0 | 0 |
| Stopped (B / B) | up x1 | 338 | 516 | 7.4 / 16.5 | 6.7 / 7.9 | 15 / 30 | 32 / 77 | 0 | 0 |
| Stopped (B / B) | up x8 | 441 | 718 | 7.7 / 13.5 | 10.4 / 14.0 | 22 / 45 | 34 / 82 | 0 | 0 |
| IDS with ET Open rules (C / A) | down x1 | 184 | 264 | 7.2 / 9.5 | 6.5 / 8.1 | 24 / 46 | 37 / 85 | 27 | 92 |
| IDS with ET Open rules (C / A) | down x8 | 478 | 544 | 7.3 / 15.4 | 6.6 / 13.0 | 56 / 95 | 58 / 99 | 62 | 136 |
| IDS with ET Open rules (C / A) | up x1 | 268 | 530 | 7.4 / 14.7 | 6.7 / 11.9 | 33 / 47 | 50 / 100 | 61 | 109 |
| IDS with ET Open rules (C / A) | up x8 | 340 | 635 | 7.5 / 14.8 | 7.1 / 12.4 | 38 / 56 | 78 / 99 | 70 | 224 |
| **IPS on WAN (D / C)** | down x1 | 209 | 232 | 13.6 / 62.4 | 6.6 / 16.8 | 35 / 64 | 38 / 85 | 53 | 139 |
| **IPS on WAN (D / C)** | down x8 | **264** | **363** | 26.6 / 59.3 | 8.6 / 49.2 | 40 / 57 | 62 / 98 | 77 | 196 |
| **IPS on WAN (D / C)** | up x1 | **161** | **225** | 21.9 / 57.7 | 6.9 / 19.5 | 39 / 65 | 56 / 100 | 72 | 186 |
| **IPS on WAN (D / C)** | up x8 | **192** | **374** | 34.9 / 54.0 | **35.4 / 119.4** | 41 / 71 | 76 / 98 | 79 | 272 |

¹ The first VyOS B "down x1" run measured 50 Mbit/s: its Chicago server was busy and the script
fell back to another port on it. It was rerun straight away (319 Mbit/s); both are in
`data/vyos-pi-live/B-suricata-stopped/wan.jsonl`, and the 50 Mbit/s run is left out here.

Highest WAN NIC rate the router itself counted during a run (household traffic included):

| State | OPNsense rx / tx peak Mbit/s | VyOS rx / tx peak Mbit/s | VyOS NIC drops |
|---|---|---|---:|
| Stopped (B) | 954 / 556 | 838 / 876 | 0 |
| Stopped, ntopng off (B2) | | **975** / 848 | 0 |
| IDS with rules (C / A) | 722 / 439 | 685 / 866 | 0 |
| IPS on WAN (D / C) | 359 / 237 | 495 / 489 | 0 |

### Idle (no test traffic)

| State | WAN ping p50 / p95 ms | LAN ping p50 / p95 ms | CPU avg % | Temp °C | Free mem MB | Suricata RSS MB |
|---|---|---|---:|---:|---:|---:|
| A0 (0 rules) | | | 6.7 | 53.0 | 14,217 | 95 |
| A (53k rules) | 6.8 / 7.7 | 0.85 / 1.67 | 5.9 | 54.7 | 13,083 | 1,218 |
| B (stopped) | 6.9 / 10.6 | 1.19 / 1.98 | 11.9 | 58.5 | 14,269 | 0 |
| B2 (stopped, ntopng off) | 7.1 / 8.0 | 0.83 / 1.59 | 1.2 | 57.2 | 14,682 | 0 |
| C (IPS) | 7.1 / 9.3 | 1.04 / 1.69 | 9.2 | 57.9 | 13,184 | 1,207 |

Memory is never a constraint: at least 12.8 GB of 16 GB was free in every state, with Suricata
(1.2 GB with the rules), ntopng (about 430 MB) and AdGuard (about 460 MB) all running. The CPU
temperature (`cpu-thermal` zone) peaked at 67 °C, in the IPS state; OPNsense on the other board
peaked at 76 °C. The boards and their placement differ, so the temperatures are not a fair
comparison. There was no sign of throttling.

### What the WAN numbers show

- **Without Suricata, VyOS forwards with one core.** With ntopng off (B2), cores 1 to 3 are
  about 1 % busy and core 0 does all of it: 71 % average and 87 % at peak at 790 Mbit/s, with the
  WAN NIC counting 975 Mbit/s received. OPNsense spread the same load across all four cores. The
  forwarding ceiling on VyOS is therefore one core, until interrupts or RPS are spread across
  cores (not changed for this test).
- **IDS with real rules: VyOS keeps up better but uses more CPU.** Throughput stayed at about the
  Suricata-stopped level (544 to 635 Mbit/s with 8 streams against 478 and 340 on OPNsense), and
  latency did not change. But Suricata's 4 af-packet workers used up to 2.2 cores, and the router
  averaged 78 % CPU at the highest load. Like OPNsense's (13 %), the IDS missed packets under load:
  **366,298 kernel drops out of 3.65 million packets (10 %)** during the A runs.
- **IPS is the bottleneck on both, and VyOS's NFQUEUE IPS is faster than OPNsense's netmap IPS.**
  8-stream throughput fell from 590 to 790 Mbit/s (stopped) to **363 down / 374 up**, against
  264 / 192 on OPNsense. Single-stream latency stayed low (p95 17 to 20 ms, against 58 to 62 ms on
  OPNsense). But the 8-stream upload had the worst tail of any run: **p50 35 ms, p95 119 ms**.
  Suricata used up to 2.7 cores, and the busiest core was at 98 to 100 %, so this time the CPU is
  the limit (OPNsense's IPS was limited by netmap's emulated mode instead, at 41 % CPU).

## ntopng overhead

The same Suricata-stopped runs with ntopng running (B) and stopped (B2). ntopng captures eth0,
eth1 and eth2 directly (no nProbe) and is capped at 1 CPU by its container.

| Test | Mbit/s, ntopng on | Mbit/s, ntopng off | CPU avg / busiest, on | CPU avg / busiest, off | Cores 1-3 avg, on | Cores 1-3 avg, off | ntopng CPU (% of one core) |
|---|---:|---:|---|---|---|---|---:|
| down x1 | 319 | 256 | 20 / 72 | 10 / 50 | 12 % | 1 % | 36 |
| down x8 | 591 | 790 | 30 / 83 | 19 / 87 | 17 % | 1 % | 55 |
| up x1 | 516 | 517 | 32 / 77 | 18 / 74 | 19 % | 1 % | 56 |
| up x8 | 718 | 714 | 34 / 82 | 18 / 78 | 20 % | 1 % | 61 |

- **ntopng costs about 0.4 to 0.7 of a core under load**, and 8 to 37 % of a core when idle.
  Its RSS was 310 to 440 MB of its 768 MB cap.
- It runs on cores 1 to 3, so it does not compete with forwarding on core 0. Throughput with and
  without it is within the public-server variance (the 591 against 790 Mbit/s is one pair of
  runs; the other three pairs match within 1 %).

## LAN to LAN2 routed forwarding (iperf3, nixtop wired <-> Mac on Deco Wi-Fi)

**This test is limited by Wi-Fi.** It measures the Deco radio hop at least as much as the router.
Suricata only watches the WAN, so it is not in this path. ntopng captures both ports.

| State | Direction | Streams | OPNsense Mbit/s | VyOS Mbit/s | VyOS retransmits | VyOS router CPU avg % | VyOS busiest core % |
|---|---|---:|---:|---:|---:|---:|---:|
| A / A | LAN -> LAN2 | 1 | 236 | 290 | 0 | 20 | 52 |
| A / A | LAN -> LAN2 | 4 | 278 | 297 | 113 | 16 | 30 |
| A / A | LAN2 -> LAN | 1 | 321 | 319 | 0 | 23 | 62 |
| A / A | LAN2 -> LAN | 4 | 316 | 249 | 1 | 20 | 59 |
| B / B | LAN -> LAN2 | 1 | 265 | 297 | 28 | 18 | 39 |
| B / B | LAN -> LAN2 | 4 | 262 | 292 | 183 | 16 | 33 |
| B / B | LAN2 -> LAN | 1 | 411 | 310 | 0 | 23 | 65 |
| B / B | LAN2 -> LAN | 4 | 411 | 300 | 0 | 25 | 64 |

The OPNsense "A" rows were OPNsense's 0-rule state; Suricata is not in this path on either
router, so that does not matter here. Both routers land at 250 to 410 Mbit/s, the range of this
Wi-Fi link.

## LAN port, host-terminated (iperf3 to the router itself)

The like-for-like row that the [Pi 5 iperf comparison](pi5-iperf-vyos-vs-opnsense.md) was
missing: VyOS on a USB RTL8156 LAN port against OPNsense on its USB RTL8156 LAN port, same Mac,
same switch, both live routers. Two runs each, shown as "first / repeat".

| Test | OPNsense LAN `ue1` (RTL8156) | VyOS LAN `eth2` (RTL8156) |
|---|---:|---:|
| TCP Mac → router, 1 stream | 591 / 594 | **911 / 916** |
| TCP Mac → router, 4 streams | 600 / 612 | **862 / 871** |
| TCP router → Mac, 1 stream | 928 / 922 | 911 / 923 |
| TCP router → Mac, 4 streams | 932 / 931 | 927 / 928 |
| UDP Mac → router @1G (loss %) | 953 (0.78 %) | 952 (0.72 %) / 952 (0.80 %) |
| UDP router → Mac @1G (loss %) | 930 (0.04 %) | 922 (0.32 %) / 944 (0.02 %) |
| Router CPU avg, TCP runs | 22 to 33 % | 25 to 38 % (ntopng included) |

**Receiving on the router**, where OPNsense stopped at about 600 Mbit/s with thousands of TCP
retransmits, VyOS gets 862 to 916 Mbit/s with almost none (0 with 1 stream). Sending is at line
rate on both. The adapters are different units of the same chip (USB ID 0bda:8156); the one
OPNsense's LAN used (80:3f:5d:f9:e1:bd) is now VyOS's LAN2/Deco port. Details and every run:
[pi5-iperf-vyos-vs-opnsense.md](pi5-iperf-vyos-vs-opnsense.md#vyos-as-the-live-router-lan-port-eth2).

## Suricata capture and IPS counters

From Suricata's own counters over its unix socket (`suricatasc -c dump-counters`), saved in each
state's `router-before*.txt` and `router-after*.txt`:

| Instance | Packets | Kernel drops | Notes |
|---|---:|---:|---|
| A0: af-packet, 0 rules (21:20 to 21:44Z) | 1,133,307 | 0 | capture only, nothing to inspect |
| A: af-packet, 53,439 rules (21:44 to 21:49Z, A runs) | 3,646,068 | **366,298 (10 %)** | under load the IDS misses about 1 packet in 10 |
| C2: af-packet, rules + WAN in HOME_NET (light traffic) | 31,892 | 0 | |
| C: NFQUEUE IPS (22:04 to 22:07Z) | 2,483,557 | n/a | `ips.accepted` 2,481,007, `ips.blocked` 2,549: rules 6, flow_drop 2,058, stream_error 341, stream_midstream 134, applayer_error 10; 1,016 alerts |

**Collateral damage in IPS mode:** none from the rules. All 6 rule drops were the test probes.
But two things did touch household traffic:

- **Connections open before the switch got dropped.** Suricata dropped 134 packets as
  `stream_midstream`, from TCP connections that were already open when it attached to the queue,
  and 341 more as `stream_error`.
- **One check timed out.** The first HTTPS check right after the rules loaded (`curl` to
  `www.google.com/generate_204`) timed out after 8 s. Everything after it worked.

Keeping IPS on would need `stream.midstream` handling decided first.

## Detection probes

All probes run from the wired client and go out through NAT, the same ones as the baseline
(`scripts/bench/detection.sh`). `alert` = an alert was logged, `blocked` = the alert's action was
drop and the client timed out, `-` = nothing logged.

| Probe | OPNsense C (rules, HOME_NET RFC1918) | VyOS A0 (0 rules) | **VyOS A (rules, HOME_NET RFC1918)** | OPNsense C2 / VyOS C2 (WAN /32 added) | OPNsense D IPS | **VyOS C IPS** |
|---|---|---|---|---|---|---|
| `uid=0(root)` response via httpbin | not run | - | **alert 2100498** | alert 2100498 / alert 2100498 | blocked | **blocked** 2100498 (client timed out) |
| EICAR over plain HTTP (httpbin) | - | - | - | - / - | - | - (file delivered) |
| User-Agent "Nikto" | - | - | - | - / - | - | - |
| User-Agent "Nmap Scripting Engine" (curl) | - | - | - | alert 2024364 / alert 2024364 | blocked | **blocked** 2024364 |
| `nmap -sT -sV --script http-title -p 22,80,9929 scanme.nmap.org` | - | - | - | alert 2024364 / alert 2024364 | blocked | **blocked** 2024364: ports found, `http-title` request dropped |
| DNS `test.duckdns.org` / `duckdns.org` | - | - | - | alert 2022918 + 2042936 / same | blocked | **blocked** `test.duckdns.org` (bare `duckdns.org` matches no rule and resolved) |
| DNS `example.ddns.net` | - | - | - | alert 2028675 / same | blocked | **blocked** |
| DNS `onion.to` | - | - | - | alert 2027757 / same | blocked | **blocked** |
| DNS `facebookcorewwwi.onion` | - | - | - | alert 2014939 / same | alert | alert (ET INFO, not in the drop policy) |
| DNS `example.onion.ws` | - | - | - | alert 2026810 / same | alert | alert |
| DNS `pool.minexmr.com` (Monero pool) | - | - | - | alert 2024789 / same | alert | alert (ET INFO) |
| DNS `api.ipify.org` | - | - | - | alert 2047702 / same | alert | alert |

`testmynids.org/uid/index.html` is still a parked page and triggers nothing in any state, as in
the baseline.

**HOME_NET on VyOS has the same problem as on OPNsense, in IDS mode only.**

- **IDS mode.** VyOS's `service suricata` captures `eth0` with af-packet, after NAT, so every
  outbound flow is public-to-public. With HOME_NET set to the RFC1918 ranges (the deployed
  config), no `$HOME_NET -> $EXTERNAL_NET` rule can match.
  - In state A, with 53,439 rules, only 2100498 fired. That rule is written `any -> any`.
  - Adding the WAN /32 to HOME_NET (C2) made every probe class alert, exactly as on OPNsense.
- **IPS mode needs no change.** The vyos-pi IPS mode queues packets at the nftables forward hook,
  which runs before source NAT on the way out and after it is undone on the way back. Suricata
  sees the LAN addresses (192.168.68.250 and 192.168.69.20 in the alerts), so the RFC1918
  HOME_NET matches.

So to make the IDS useful, do one of these:
- run it on the LAN interfaces (`set service suricata interface eth1` and `eth2`, also pre-NAT);
- or add the WAN address to `home-net`. It is a DHCP lease, so it has to follow lease changes;
- or use the IPS mode, alert-only (no `drop.conf`).

## Boot time

Not re-measured: the live router was not rebooted for this. pi5-1's VyOS boots were already
measured (see [pi5-iperf-vyos-vs-opnsense.md](pi5-iperf-vyos-vs-opnsense.md#pi5-1-vyos)): **eth0 up
with a lease, SSH listening and the config loaded at 47 to 49 s from the reboot command**, against
64 to 68 s for network and SSH on opnsense-pi. Those boots ran a small test config. The full
router config, with containers, Suricata and a 1,577-line config.boot, will take longer to load.
Its boot time is still to be measured.

## Not tested

- **WireGuard throughput**: it needs a client outside the LAN on a wired link. Skipped.
- **The forwarding ceiling**: the public servers top out below 1 GbE (the router counted
  975 Mbit/s at most).

## Restore and safety record

- The Suricata state was snapshotted before anything changed
  (`data/vyos-pi-live/ids-original/`: 0 rules), and again after `update suricata`
  (`ids-deployed-with-rules/`). That second state is the one restored: the cutover plan asks for
  `update suricata` once after the swap, and a daily task runs it anyway.
- C2 changed `service suricata address-group home-net` with a commit and then removed it again.
- IPS ran only for traffic entering or leaving `eth0`, for 3 min 17 s. A systemd timer on the
  router was armed first to put IDS back after 6 minutes. It was cancelled after the manual
  restore, so it never fired.
- After the restore, `vyos-ids.sh diff` reports **IDENTICAL** for all of these:
  - the `service suricata` config, by hash and line count;
  - no mode file;
  - no `drop.conf`;
  - no IPS nftables table;
  - Suricata active with af-packet;
  - 53,439 rules loaded;
  - the watchdog inactive.

  Saved as `data/vyos-pi-live/restore-diff.txt`.
- ntopng was stopped and started once for B2. Its login and data survived the restart.
- The house checks (`verify-cutover.sh post`: DHCP, DNS, AdGuard, the tunnel, k3s, router services;
  26 checks) passed before and after: 26/26.
- Total load: about 10 minutes of 15 s runs with 5 s gaps (17 WAN, 8 LAN to LAN2, 12
  host-terminated), plus 6 Suricata restarts and one stop.

## Re-running

```sh
cd scripts/bench
cp bench.env.example bench.env   # ROUTER_KIND=vyos, ROUTER_SSH=vyos@<router>, ROUTER_WAN_IF=eth0,
                                 # ROUTER_SSH_OPTS="-o UserKnownHostsFile=...", SRC_IP=<the Mac's LAN address>
D=../../docs/comparison/data/vyos-pi-live
./vyos-ids.sh snapshot $D/ids-deployed-with-rules
./run-state.sh A-ids-deployed $D                 # wan lan detect
./vyos-ids.sh stop;  ./run-state.sh B-suricata-stopped $D wan lan
./vyos-ids.sh drop-policy emerging-attack_response,emerging-scan,emerging-dns,emerging-dyn_dns,emerging-coinminer
./vyos-ids.sh watchdog 360; ./vyos-ids.sh ips-wan
./run-state.sh C-ips-nfqueue-wan $D wan detect
./vyos-ids.sh restore; ./vyos-ids.sh cancel-watchdog; ./vyos-ids.sh diff $D/ids-deployed-with-rules
./summarize.py $D > $D/summary-tables.md
./compare.py ../../docs/comparison/data/opnsense-pi $D "Stopped=B-suricata-stopped:B-suricata-stopped" ...
```

What changed in the scripts for VyOS:

| Script | Change |
|---|---|
| `router-poll.sh` | On Linux, Suricata's and ntopng's CPU come from `/proc/<pid>/stat` deltas per poll interval (Linux `ps %CPU` is a lifetime average); ntopng is a 9th field. Appends, so parts run separately share one file |
| `run-state.sh` | On VyOS, Suricata counters come from `suricatasc -c dump-counters` (VyOS writes no `stats.log`). A later part run into the same state keeps the earlier files |
| `vyos-ids.sh` | New: the VyOS counterpart of `opnsense-ids.sh` (snapshot, diff, update, drop policy, WAN-only IPS, router-side watchdog, restore, HOME_NET + WAN) |
| `compare.py` | New: the side-by-side WAN table from two `summary.json` files |
| `common.sh`, `lan-forward.sh` | `ROUTER_SSH_OPTS` for the router only (for example a separate known_hosts file); `SRC_IP` to pin the Mac's address |

Raw data is in `data/vyos-pi-live/<state>/`, laid out as in the baseline. The aggregate is in
`summary.json` and `summary-tables.md`, and the side-by-side table is in `compare-wan.md`. The
public IPv4 and IPv6 addresses are redacted in all of it.
