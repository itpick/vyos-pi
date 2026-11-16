# opnsense-pi baseline: throughput, latency, load and Suricata IDS/IPS

> The same tests with VyOS as the live router, side by side with these: [vyos-pi-live.md](vyos-pi-live.md).

Measured on 2026-11-16, 14:09 to 14:51 UTC (08:09 to 08:51 CST), on the live home router. The
goal is a baseline that the same scripts (`scripts/bench/`) can reproduce later against VyOS on
an identical Pi 5 (pi5-1).

## Setup

| | |
|---|---|
| Router | Raspberry Pi 5, 16 GB, 4x Cortex-A76 (r4p1). OPNsense 26.7.9_1, FreeBSD 15.1-RELEASE-p6 |
| WAN | `rp1eth0` (on-board RP1 GbE, custom `rp1_eth.ko`), public DHCP address (redacted) |
| LAN | `ue1` USB 1 GbE, 192.168.68.1/22 |
| LAN2 | `ue0` USB 2.5 GbE, 192.168.72.1/22, goes to TP-Link Deco Wi-Fi |
| Suricata | 8.0.8 |
| Wired client | Mac `en7` 1 GbE on LAN (192.168.68.250). All WAN tests are bound to `en7` (scoped route via 192.168.68.1) |
| Wi-Fi client | the same Mac, `en0` on LAN2 (192.168.72.22) through the Deco |
| LAN peer | nixtop (192.168.68.158, wired LAN), load average about 2 of 16 cores during the tests |
| WAN servers | public iperf3 servers: Leaseweb Chicago (`speedtest.chi11.us.leaseweb.net`) and Dallas (`speedtest.dal13.us.leaseweb.net`). Parallel runs are split across both at once |

**WAN numbers are limited by the internet servers, not by the router.** No single public server
fills 1 GbE from here, and Cloudflare's `__down` answered HTTP 429 after a few parallel runs (one
attempt was thrown away for that reason). Repeating the same state gave results that varied by
about ±25 % (compare A with E). The router's own WAN NIC counter peaked at 954 Mbit/s receive with
Suricata stopped, so the forwarding path can handle close to line rate. To compare the router
itself, look at the router CPU columns and at the IPS state, where the router clearly is the limit.

## States

| ID | Suricata state | Notes |
|---|---|---|
| A | **Original**: IDS, pcap on WAN, rulesets botcc + emerging-exploit + emerging-malware enabled | **0 rules actually loaded** (see findings) |
| B | Suricata stopped | |
| C | IDS (pcap) on WAN with 8 extra test rulesets downloaded: 42,351 installed, 33,175 active rules | HOME_NET as configured (RFC1918 only) |
| C2 | C plus the WAN /32 added to HOME_NET | detection probes only |
| D | **IPS: netmap on WAN only** (`rp1eth0`), same rules, temporary drop policy on 6 rulesets | ran for 3 min 18 s (14:44:31 to 14:47:49Z), guarded by a 6-minute restore watchdog |
| E | Original settings restored (same as A) | repeat run, to show run-to-run variance |

The temporary rulesets were emerging-attack_response, -scan, -dns, -dyn_dns, -user_agents, -info,
-coinminer and -policy (the -policy file is empty in current ET Open). The IPS drop policy covered
attack_response, scan, dns, dyn_dns, coinminer and user_agents. ET INFO was deliberately left as
alert-only, because household STUN traffic (video calls) matches ET INFO rules about 100 times a
minute.

## WAN throughput through NAT (wired client, 15 s per run)

Pings run at 5 Hz during each run: WAN = 1.1.1.1 and LAN = the router. Router CPU is the average
busy % over the run window, sampled every 2 s from `kern.cp_times`.

| State | Test | Mbit/s | WAN ping p50 / p95 / max ms | WAN ping loss % | LAN ping p95 ms | Router CPU avg % (cores 0/1/2/3) | Busiest core % | Suricata CPU % | Temp max °C |
|---|---|---:|---|---:|---:|---|---:|---:|---:|
| A original | down x1 | 242 | 6.9 / 7.8 / 9.4 | 0 | 0.9 | 16 (14/18/18/16) | 25 | 2 | 71.6 |
| A original | down x8 | 497 | 7.2 / 13.7 / 20.2 | 1.3 | 2.3 | 30 (24/36/36/23) | 46 | 6 | 72.2 |
| A original | up x1 | 209 | 7.5 / 14.2 / 28.7 | 0 | 1.9 | 19 (19/19/22/16) | 45 | 5 | 71.6 |
| A original | up x8 | 331 | 7.5 / 12.0 / 41.6 | 0 | 3.0 | 21 (21/23/23/16) | 32 | 6 | 72.2 |
| B stopped | down x1 | 230 | 7.2 / 8.4 / 13.7 | 0 | 1.2 | 16 (13/18/17/15) | 39 | 0 | 72.2 |
| B stopped | down x8 | 664 | 7.4 / 19.7 / 22.8 | 0 | 4.9 | 26 (16/35/37/18) | 51 | 0 | 73.3 |
| B stopped | up x1 | 338 | 7.4 / 16.5 / 21.2 | 0 | 1.7 | 15 (12/20/18/11) | 30 | 0 | 72.7 |
| B stopped | up x8 | 441 | 7.7 / 13.5 / 37.6 | 0 | 4.2 | 23 (21/27/27/14) | 45 | 0 | 72.7 |
| C IDS + 33k rules | down x1 | 184 | 7.2 / 9.5 / 14.2 | 0 | 1.5 | 24 (27/24/24/23) | 46 | 27 | 72.7 |
| C IDS + 33k rules | down x8 | 478 | 7.3 / 15.4 / 26.4 | 1.3 | 2.1 | **56** (57/55/57/54) | **95** | 62 | 76.0 |
| C IDS + 33k rules | up x1 | 268 | 7.4 / 14.7 / 29.9 | 0 | 1.6 | 33 (35/33/30/34) | 47 | 61 | 73.8 |
| C IDS + 33k rules | up x8 | 340 | 7.5 / 14.8 / 36.3 | 0 | 1.8 | 38 (40/35/39/38) | 56 | 70 | 73.8 |
| **D IPS netmap WAN** | down x1 | 209 | **13.6 / 62.4 / 74.5** | 1.3 | 0.7 | 35 (40/34/34/33) | 64 | 53 | 74.4 |
| **D IPS netmap WAN** | down x8 | **264** | **26.6 / 59.3 / 118.8** | 1.3 | 6.7 | 40 (44/40/37/39) | 57 | 77 | 75.5 |
| **D IPS netmap WAN** | up x1 | **161** | 21.9 / 57.7 / 167.3 | 2.7 | 4.7 | 39 (40/39/38/38) | 65 | 72 | 74.9 |
| **D IPS netmap WAN** | up x8 | **192** | 34.9 / 54.0 / 98.9 | 0 | 4.6 | 41 (46/41/42/34) | 71 | 79 | 75.5 |
| E restored | down x1 | 150 | 7.3 / 9.8 / 14.3 | 0 | 1.3 | 19 (18/19/20/18) | 44 | 1 | 73.3 |
| E restored | down x8 | 505 | 7.4 / 11.5 / 13.8 | 0 | 1.8 | 35 (28/43/41/28) | 54 | 7 | 74.4 |
| E restored | up x1 | 240 | 7.4 / 9.7 / 13.2 | 0 | 1.2 | 18 (20/18/19/15) | 32 | 5 | 73.8 |
| E restored | up x8 | 349 | 7.7 / 11.5 / 38.0 | 0 | 1.9 | 27 (28/27/29/22) | 51 | 7 | 74.4 |

Highest WAN NIC rate the router itself counted during a run (all household traffic included):

| State | rx peak Mbit/s | tx peak Mbit/s | NIC input drops |
|---|---:|---:|---:|
| A | 687 | 413 | 0 |
| B | 954 | 556 | 0 |
| C | 722 | 439 | 0 |
| D | **359** | **237** | 444 |
| E | 735 | 424 | 0 |

### Idle (no test traffic)

| State | WAN ping p50 / p95 ms | LAN ping p50 / p95 ms | CPU avg % | Temp °C | Free mem MB | Suricata RSS MB |
|---|---|---|---:|---:|---:|---:|
| A | 6.5 / 7.3 | 0.30 / 0.63 | 3.4 | 70.0 | 13,376 | 97 |
| B | 7.3 / 7.8 | 0.67 / 0.85 | 3.0 | 71.3 | 13,459 | 0 |
| C | 7.3 / 8.6 | 0.71 / 0.83 | 3.6 | 71.7 | 12,368 | 1,000 |
| D | 7.3 / 9.3 | 0.65 / 0.82 | 5.2 | 73.0 | 12,037 | 999 |
| E | 7.0 / 7.5 | 0.66 / 0.87 | 3.8 | 72.7 | 12,982 | 72 |

Memory is never a constraint: 16 GB, at least 11.9 GB free in every state. The CPU frequency
sysctl is not exposed on this build (it reads 0). The temperature rose from about 70 °C idle to
76 °C at peak; there was no sign of throttling.

## LAN to LAN2 routed forwarding (iperf3, nixtop wired <-> Mac on Deco Wi-Fi)

**This test is limited by Wi-Fi.** It measures the Deco radio hop at least as much as the router.
Suricata only watches the WAN, so it is not in this path. IPS state D skipped this test to keep the
IPS window short.

| State | Direction | Streams | Mbit/s | Retransmits | Router CPU avg % | Busiest core % |
|---|---|---:|---:|---:|---:|---:|
| A | LAN -> LAN2 | 1 | 236 | 719 | 13 | 31 |
| A | LAN -> LAN2 | 4 | 278 | 1706 | 15 | 41 |
| A | LAN2 -> LAN | 1 | 321 | 1 | 19 | 27 |
| A | LAN2 -> LAN | 4 | 316 | 1952 | 29 | 54 |
| B | LAN -> LAN2 | 1 | 265 | 517 | 9 | 17 |
| B | LAN -> LAN2 | 4 | 262 | 932 | 10 | 20 |
| B | LAN2 -> LAN | 1 | 411 | 3 | 32 | 73 |
| B | LAN2 -> LAN | 4 | 411 | 842 | 24 | 34 |

The A/B difference here (320 vs 410 Mbit/s for LAN2 -> LAN) is Wi-Fi variance. Suricata does not
touch this path.

## Suricata capture and IPS counters

From Suricata's own engine-stop summaries and `stats.log` (`data/opnsense-pi/suricata-capture-stats.txt`):

| Instance | Packets | Kernel drops | Notes |
|---|---:|---:|---|
| A: pcap, 0 rules (13:10 to 14:34Z, including the A runs) | 13,188,493 | 3,723 (0.03 %) | capture only, nothing to inspect |
| C: pcap, 33k rules (14:38 to 14:42Z, C runs) | 2,555,589 | **330,976 (13 %)** | under load the IDS misses about 1 in 7 packets |
| C2: pcap, rules + WAN in HOME_NET (light traffic) | 106,019 | 0 | |
| D: netmap IPS (14:44 to 14:47Z) | 1,808,717 | n/a | `ips.accepted` 1,808,214, `ips.blocked` 503 (rules 20, stream_error 365, flow_drop 118); 1,234 alerts |

## Detection probes

All probes run from the wired client and go out through NAT. Results for each state:
`alert` = an alert was logged, `blocked` = the alert's action was drop and the client timed out,
`-` = nothing logged.

| Probe | A original (0 rules) | C rules, HOME_NET RFC1918 | C2 rules + WAN /32 in HOME_NET | D IPS (drop policy) |
|---|---|---|---|---|
| `curl http://testmynids.org/uid/index.html` | - | - | - | - |
| `uid=0(root)` response via `http://httpbin.org/base64/…` | not run | not run | alert 2100498 GPL ATTACK_RESPONSE id check returned root | **blocked** 2100498 (client timed out) |
| EICAR over plain HTTP (httpbin) | - | - | - | - (file delivered) |
| User-Agent "Nikto" | - | - | - | - |
| User-Agent "Nmap Scripting Engine" (curl) | - | - | alert 2024364 ET SCAN Possible Nmap User-Agent | **blocked** 2024364 |
| `nmap -sT -sV --script http-title -p 22,80,9929 scanme.nmap.org` | - | - | alert 2024364 (NSE HTTP request) | **blocked** 2024364: ports found, `http-title` request dropped |
| DNS `test.duckdns.org` / `duckdns.org` | - | - | alert 2022918 + 2042936 ET DYN_DNS | **blocked** (`test.duckdns.org` timed out; bare `duckdns.org` matches no rule and resolved) |
| DNS `example.ddns.net` | - | - | alert 2028675 ET DYN_DNS | **blocked** |
| DNS `onion.to` | - | - | alert 2027757 ET DNS Query for .to TLD | **blocked** |
| DNS `facebookcorewwwi.onion` | - | - | alert 2014939 ET INFO .onion | alert (ET INFO not in the drop policy) |
| DNS `example.onion.ws` | - | - | alert 2026810 ET INFO onion proxy | alert |
| DNS `pool.minexmr.com` | - | - | alert 2024789 ET INFO Monero pool | alert |
| DNS `api.ipify.org` | - | - | alert 2047702 ET INFO external IP lookup | alert |

**Collateral damage in IPS mode:** in 3 minutes the drop policy also blocked 8 flows from a
household device for **2024897 "ET USER_AGENTS Go HTTP Client User-Agent"**. On a household
router, ET USER_AGENTS (and ET INFO) should not get a blanket drop policy.

## Findings

1. **The router's IDS has never inspected anything.** Three rulesets are enabled, but the
   "ids rule updates" cron job is **disabled** (`enabled=0`), so the rules were never downloaded.
   Every Suricata start since logs begin (2026-11-14) says *"No rule files match the pattern
   …/opnsense.rules/suricata.rules"* and *"1 rule files specified, but no rules were loaded!"*.
   Suricata only captures packets (about 90 MB RSS, about 5 % CPU under load).
2. **The HOME_NET setting makes most rules useless on the WAN.** Suricata runs on `rp1eth0` after
   NAT, so every flow is public-to-public. HOME_NET is RFC1918 only, which means no
   `$HOME_NET -> $EXTERNAL_NET` rule can match. In C, with 33k rules loaded, the probes raised
   **zero** alerts. Adding the WAN /32 to HOME_NET (C2) made 10 of the 15 probes alert. If IDS on
   WAN is kept, HOME_NET needs the WAN address. The other options are running IDS (pcap only) on
   the LAN interfaces, or using a VyOS setup that inspects before NAT.
3. **IPS (netmap on the RP1 WAN) is the bottleneck.** Downloads drop from 500 to 660 Mbit/s to
   **about 260 Mbit/s**. Uploads drop to **160 to 190 Mbit/s**. Latency under load climbs from
   about 7 ms p50 / 12 to 20 ms p95 to **14 to 35 ms p50 / 55 to 62 ms p95**. The CPU is not
   saturated (40 % average, busiest core at most 71 %, Suricata 2 worker threads at about 77 %).
   The limit looks like the netmap path itself: `rp1_eth` has no native netmap, so it runs in
   emulated or generic mode. During single-stream upload the Mac pushed 846 Mbit/s into LAN while
   the WAN sent only about 233 Mbit/s, so the excess was dropped and retransmitted inside the
   netmap host ring. The WAN NIC also logged 444 input drops, and `ips.drop_reason.stream_error`
   was 365. Netmap attach and detach did **not** wedge `rp1eth0` this time: the WAN stayed up
   throughout, and the router's `rp1eth0-watchdog` never fired.
4. **IDS with a real ruleset costs CPU and misses packets under load.** In pcap mode with 33k
   rules, the busiest core reached 95 % and the average 56 % at about 500 Mbit/s. Suricata
   (1 worker) dropped 13 % of packets, but throughput was not limited (pcap is passive). RSS grew
   from 0.1 GB to 1.0 GB, and loading the rules took about 10 s at 360 % CPU, during which capture
   stopped.
5. **Without Suricata, or with the 0-rule original, the router has plenty of headroom.** At
   500 to 660 Mbit/s the average CPU is 26 to 35 % and the busiest core about 50 %. Most of the
   load is interrupt and network stack time, and the WAN NIC peaked at 954 Mbit/s. The WAN test
   cannot show the true forwarding ceiling because no public server fills 1 GbE.
6. EICAR passes in every state, because no enabled ET Open ruleset has a generic EICAR rule.
   testmynids.org is now a parked domain and no longer serves the `uid=0(root)` payload, so the
   probe uses httpbin. The Nikto UA rule (2002677) only matches inbound requests to `$HTTP_SERVERS`
   with a threshold of 5, so an outbound curl can never trigger it.

## Reboot investigation (report only, nothing changed)

Evidence is in `data/opnsense-pi/reboot-investigation.txt`.

- **No reboots, WAN bounces or router-watch DOWN events during this test window.** Uptime ran
  continuously from 13:10Z.
- **Most of the reboots are deliberate.** 9 of the 12 boots logged on 11-15/16 were orderly
  shutdowns (rc stop scripts ran). They line up with an `rp1_eth.ko` driver test cycle
  (`rp1eth-rollback: WAN up with new rp1_eth.ko, keeping it` after each one), a test kernel
  (`urex-check`), and config pushes through `/tmp/*.php`. These were done by **root SSH from
  192.168.69.20**, a second address on this Mac's `en7`, which means other automation sessions on
  this Mac (1,995 root SSH logins in 3 days). This morning's reboot (07:09 CST) came about 50 s
  after `/tmp/a.php` changed the config.
- **3 resets were unclean** ("/ was not properly dismounted", no shutdown logged): 11-15 at about
  08:24 and 08:26 CST, and 11-15 21:48 CST (03:49Z). These look like crashes, hangs or power loss.
  No dumps exist (`/var/crash` is empty), so the cause can't be determined. Suggestions: enable a
  dump device, and check the PSU and the fan/thermal state. Idle temperature is already about
  70 °C.
- **Not every DOWN in router-watch is a reboot.** 3 of the 14 DOWNs on 11-15 (08:35, 08:37,
  08:49 CST) kept counting uptime, so those were LAN reachability losses, not reboots.
- After an unclean boot the router comes up with its clock at 2025-06-11 (no RTC, NTP not yet
  synced), so logs from those boots end up in `system_20250611.log`.

## Restore and safety record

- Full config backup taken first: `~/workspace/opnsense/config-backup-20261116-080916-pre-ids-test.xml`
  (mode 600, not in any repo).
- The original IDS settings were snapshotted through the API and restored from that snapshot
  (`opnsense-ids.sh restore`). `opnsense-ids.sh diff` reports **IDENTICAL**: settings, enabled
  rulesets (botcc, emerging-exploit, emerging-malware), no policies, service running, pcap on WAN,
  HOME_NET RFC1918.
- The rule files downloaded for the test were moved (not deleted) to
  `/root/bench-moved-suricata-rules-20261116/` on the router. This brings the runtime back to the
  original "no rules were loaded" state. `rules.sqlite` (the rule metadata cache) was regenerated
  by the download. **Owner's decision:** to make the IDS actually work, enable the rule-update cron
  job (or click Download in the GUI) and fix HOME_NET (finding 2).
- IPS ran only on WAN (`rp1eth0`), for 3 min 18 s. The 6-minute API restore watchdog was armed
  beforehand and cancelled after a manual restore at 14:47:31Z. LAN and LAN2 (USB NICs) were never
  put in netmap mode.
- Total disruption: about 14 min of throughput runs (each 15 s, with 5 s gaps), plus about 6
  Suricata restarts.

## Re-running (and running against VyOS)

```sh
cd scripts/bench
cp bench.env.example bench.env        # set ROUTER_KIND/ROUTER_IP/ROUTER_SSH/ROUTER_WAN_IF etc.
./run-state.sh <STATE> ../../docs/comparison/data/<router> [wan] [lan] [detect]
./summarize.py ../../docs/comparison/data/<router> > ../../docs/comparison/data/<router>/summary-tables.md
```

| Script | What it does |
|---|---|
| `router-poll.sh` | 2 s read-only polling over one SSH session: per-core CPU, load, temperature, memory, WAN NIC counters, Suricata CPU and RSS. Works on FreeBSD (`kern.cp_times`) and Linux (`/proc/stat`), so it covers VyOS as is |
| `wan-throughput.sh` | iperf3 down/up, 1 and N streams, split across `IPERF_SERVERS`, with 5 Hz WAN and LAN pings. `WAN_METHOD=cloudflare` is the alternative |
| `lan-forward.sh` | iperf3 from `LAN_PEER` to the Wi-Fi address (Wi-Fi limited) |
| `detection.sh` | the probes in the detection table |
| `run-state.sh` | runs all of the above, collects alerts (OPNsense API, or `eve.json` over SSH when `ROUTER_KIND=vyos`) and redacts the public IP |
| `opnsense-ids.sh` | OPNsense-only Suricata control: snapshot, restore, diff, IPS on WAN, rulesets, drop policy, watchdog. VyOS will need its own equivalent |

For VyOS: set `ROUTER_KIND=vyos`, `ROUTER_SSH=vyos@<pi5-1>`, `ROUTER_WAN_IF=eth0`, and use
`vyos-ids.sh` in place of `opnsense-ids.sh`. These scripts were run against VyOS as the live
router on the same day: [vyos-pi-live.md](vyos-pi-live.md) has the results side by side with this
baseline.
Raw data lives in `data/opnsense-pi/<state>/`: `poll.raw`, `wan.jsonl`, `lan.jsonl`,
`detect.jsonl`, `alerts.jsonl`, `ping-*.txt` and `router-*.txt`. The aggregate is in
`summary.json` and `summary-tables.md`.
