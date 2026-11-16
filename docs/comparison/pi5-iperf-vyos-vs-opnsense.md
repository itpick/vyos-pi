# Pi 5 iperf3 and boot time: VyOS (pi5-1) vs OPNsense (opnsense-pi)

Measured on 2026-11-16 on two Raspberry Pi 5 boards: pi5-1 (the VyOS test board) and the live
opnsense-pi home router. Both are Pi 5, 16 GB, 4x Cortex-A76.

> **Status of the VyOS rows.** pi5-1 was booted into its SD-card Ubuntu 24.04 for the whole test
> window, while another job changed its default boot to VyOS. So the pi5-1 numbers below are a
> **Linux-on-the-same-board reference (Ubuntu 24.04, kernel 6.8.0-1068-raspi), not VyOS.** They
> show what the board, the RP1 NIC and a Linux stack can do. The VyOS rows will be added when
> pi5-1 is back on VyOS, measured the same way with the same scripts.

## What these tests measure

They are **host-terminated** tests: the iperf3 traffic starts or ends on the router itself. They
measure the router's NIC, driver, network stack and CPU. They do **not** measure forwarding, NAT
or the firewall path. For that, see the forwarding/NAT and Suricata baseline in
[opnsense-pi-baseline.md](opnsense-pi-baseline.md). The same comparison for VyOS needs a wired
client *behind* pi5-1 (see [Still to do](#still-to-do)).

## Setup

| | pi5-1 (reference: Ubuntu) | opnsense-pi (live router) |
|---|---|---|
| OS | Ubuntu 24.04.5, Linux 6.8.0-1068-raspi (VyOS rows pending) | OPNsense 26.7.9_1, FreeBSD 15.1-RELEASE-p6 |
| Port under test | `eth0`, onboard RP1 GbE (`macb`), 1 Gb/s | LAN `ue1`, USB RTL8156 2.5 GbE (FreeBSD `ure`), linked at 1 Gb/s |
| Other load | idle | live home router: pf, NAT, Suricata IDS (pcap on WAN), household traffic |
| Client | this Mac, `en7` wired 1 GbE, same switch, 192.168.68.250 | same |

The Mac's 1 GbE link caps everything at about 940 Mbit/s of TCP payload, so "line rate" here
means about 930 to 950 Mbit/s.

### Method

`scripts/bench/iperf-host.sh` runs 6 tests of 15 s each, with a 5 s gap:
TCP with 1 and 4 streams in each direction, and UDP at 1 Gbit/s offered load in each direction.
While they run, the router is polled every 2 s over ssh (the same read-only loop as
`router-poll.sh`) for per-core CPU, temperature and the tested NIC's byte counters.
`scripts/bench/iperf-host-summary.py` turns that into the tables below (CPU maths shared with
`summarize.py`).

The iperf3 **client runs on the router** and the server runs on the Mac. macOS "Local Network"
privacy blocks the Homebrew iperf3 binary from opening connections to LAN hosts ("No route to
host"), but it can accept them. Each direction is still tested: "Mac → router" uses `-R`. So
nothing had to listen on the router, and no firewall rule was needed on either box.

On opnsense-pi, the official `os-iperf` plugin was installed through the API
(`core/firmware/install/os-iperf`) as planned. Its server job listens on every interface and has
no bind option, so it was not used; a test server bound only to the LAN address was started
briefly and then stopped, and the final runs used the client-on-router method above. The plugin
was then removed through the API (`core/firmware/remove/os-iperf`). The plugin list afterwards is
`os-isc-dhcp`, `os-realtek-re`, the same as before. (`iperf3` 3.22 itself was already installed
before the test, and is still there.)

## Results

Mbit/s is the receiver's goodput. CPU is the router's average busy % across 4 cores over the run,
with per-core averages in brackets. "Busiest core" is the highest single-core 2 s sample.

### Headline

| Test | pi5-1 eth0, Ubuntu reference | pi5-1 eth0, VyOS | pi5-1 eth1 (USB RTL8156B), VyOS | opnsense-pi LAN ue1 (USB RTL8156) |
|---|---:|---:|---:|---:|
| TCP Mac → router, 1 stream | 770 | pending | not tested | 591 / 594 |
| TCP Mac → router, 4 streams | 789 | pending | not tested | 600 / 612 |
| TCP router → Mac, 1 stream | 925 | pending | not tested | 928 / 922 |
| TCP router → Mac, 4 streams | 924 | pending | not tested | 932 / 931 |
| UDP Mac → router @1G (loss %) | 954 (0.53 %) | pending | not tested | 953 (0.78 %) |
| UDP router → Mac @1G (loss %) | 954 (0.28 %) | pending | not tested | 930 (0.04 %) |
| Router CPU avg, TCP runs | 9 to 29 % | pending | | 22 to 33 % |
| Busiest core, TCP runs | 25 to 63 % | pending | | 38 to 78 % |
| Temperature max | 67 °C | pending | | 76 °C |

opnsense-pi was run twice (both shown as "first / repeat"); the runs agree within 3 %.

What it shows:

- **Sending from the router** reaches the Mac's line rate on both boards, with plenty of CPU left.
- **Receiving on the router** is where they differ. OPNsense on the USB RTL8156 tops out at about
  600 Mbit/s with thousands of TCP retransmits (the sender sees drops), with the load spread over
  the cores and no core saturated (busiest 2 s sample 38 to 61 %). Linux on the onboard RP1 port
  reaches about 780 Mbit/s, with one core doing most of the receive work (60 % on core 0 with
  4 streams). Neither reaches line rate when
  receiving, so the inbound path is the one to watch on both.
- UDP at 1 Gbit/s offered: both receive at about line rate with under 1 % loss and jitter under
  0.02 ms.
- This is **not a fair NIC-for-NIC comparison yet**: the OPNsense port is a USB adapter on a busy
  live router, while the pi5-1 port is the onboard RP1 on an idle board. The fair rows are the
  VyOS eth1 rows (same RTL8156 chip family) once eth1 has a peer.

### All runs

| Setup | Test | Mbit/s | TCP retransmits | UDP loss % / jitter ms | Router CPU avg % (per core) | Busiest core % | NIC rx/tx peak Mbit/s | Temp max °C |
|---|---|---:|---:|---|---|---:|---|---:|
| opnsense-lan-ue1 | TCP Mac → router x1 | 591 | 1977 |  | 23.3 (22/26/32/13) | 42 | 633 / 30 | 73.8 |
| opnsense-lan-ue1 | TCP router → Mac x1 | 928 | 99 |  | 23.2 (19/28/25/21) | 44 | 5 / 993 | 73.8 |
| opnsense-lan-ue1 | TCP Mac → router x4 | 600 | 6059 |  | 28.5 (28/34/34/17) | 61 | 641 / 30 | 73.8 |
| opnsense-lan-ue1 | TCP router → Mac x4 | 932 | 337 |  | 24.0 (18/28/30/20) | 46 | 6 / 988 | 73.8 |
| opnsense-lan-ue1 | UDP Mac → router x1 @1G | 953 |  | 0.78 / 0.004 | 20.2 (23/24/21/13) | 52 | 990 / 2 | 73.8 |
| opnsense-lan-ue1 | UDP router → Mac x1 @1G | 930 |  | 0.04 / 0.016 | 40.1 (34/41/45/40) | 77 | 1 / 993 | 76.0 |
| opnsense-lan-ue1-repeat | TCP Mac → router x1 | 594 | 2034 |  | 21.8 (21/29/26/13) | 44 | 708 / 32 | 74.35 |
| opnsense-lan-ue1-repeat | TCP router → Mac x1 | 922 | 87 |  | 33.1 (31/37/37/28) | 78 | 4 / 985 | 74.35 |
| opnsense-lan-ue1-repeat | TCP Mac → router x4 | 612 | 4552 |  | 23.6 (24/29/28/14) | 38 | 656 / 30 | 72.7 |
| opnsense-lan-ue1-repeat | TCP router → Mac x4 | 931 | 326 |  | 23.0 (21/27/25/19) | 43 | 6 / 993 | 72.7 |
| pi5-ubuntu-eth0 | TCP Mac → router x1 | 770 | 231 |  | 21.6 (37/19/14/17) | 56 | 829 / 16 | 66.65 |
| pi5-ubuntu-eth0 | TCP router → Mac x1 | 925 | 796 |  | 11.1 (10/14/12/9) | 37 | 4 / 953 | 65.0 |
| pi5-ubuntu-eth0 | TCP Mac → router x4 | 789 | 293 |  | 29.1 (60/20/20/17) | 63 | 849 / 17 | 65.0 |
| pi5-ubuntu-eth0 | TCP router → Mac x4 | 924 | 2665 |  | 9.3 (15/6/9/6) | 25 | 7 / 957 | 63.9 |
| pi5-ubuntu-eth0 | UDP Mac → router x1 @1G | 954 |  | 0.53 / 0.008 | 20.3 (28/22/19/12) | 35 | 1000 / 0 | 66.1 |
| pi5-ubuntu-eth0 | UDP router → Mac x1 @1G | 954 |  | 0.28 / 0.019 | 14.6 (19/13/16/10) | 39 | 0 / 1007 | 65.0 |

TCP retransmits are counted by whichever side sends (the Mac for "Mac → router"). The NIC
column is the tested port's own counter and on opnsense-pi includes household traffic. Raw iperf3
JSON, poll samples and `summary.json` are in [data/pi5-iperf/](data/pi5-iperf/).

### Not tested, and why

| Port | Why |
|---|---|
| pi5-1 `eth1`, USB RTL8156B 2.5 GbE (`r8152`) | **No peer**: it is cabled to an isolated switch with no other hosts. The adapter is verified on VyOS: linked at 1 Gb/s, `r8152` driver, 0 errors. |
| opnsense-pi onboard `rp1eth0` | It is the **WAN** port. Testing it from the LAN side would mean exposing an iperf server on the WAN, which was not done. |
| opnsense-pi LAN2 `ue0`, USB 2.5 GbE | Only Wi-Fi clients sit behind it (TP-Link Deco), so any result would be **Wi-Fi-limited**. Skipped. |

## Boot time

Same definitions on both boards, all measured from the moment the reboot starts:

- **reboot → kernel start**: shutdown, Pi firmware and boot loader. The kernel does not count
  this part, so it is taken from wall-clock logs.
- **→ network up**: the LAN address answers ping, or the OS logs the LAN interface as configured.
- **→ management up**: SSH (and the web GUI on OPNsense) is listening.
- **→ ready**: the OS reports that boot finished (OPNsense: the last boot script and console
  banner; VyOS: the configuration has been loaded).

### opnsense-pi (measured from its own logs, not rebooted for this)

The live router was **not** rebooted for this test. Its system log already holds 10 reboots from
2026-11-15 and 2026-11-16, after it went live on OPNsense 26.7.9_1. For each one:

- reboot start = the first shutdown script (`Invoking stop script 'beep'`), to 1 s;
- kernel start = the console banner's wall-clock time minus the uptime that `rc` prints in front
  of every boot message (`[46] Mon Nov 16 02:09:33 UTC 2026`), to 1 s;
- LAN, SSH, web GUI and ready = the uptime printed on `Configuring LAN interface`,
  `Configuring OpenSSH`, `Starting web GUI` and `Invoking start script 'beep'`;
- first ping = the external watcher on this Mac (`~/workspace/opnsense/router-watch.sh`), which
  pings every 5 s. It declares DOWN after 3 misses and logs `UP after Ns down` counted from that
  DOWN, so first reply = DOWN time + N. It has about **+0 to 7 s** of lag (5 s interval, 2 s ping
  timeout), so its numbers are upper bounds.

| Boot (kernel start, UTC) | reboot → kernel | kernel → LAN up | kernel → SSH | kernel → web GUI | kernel → ready | reboot → first ping (watcher) | reboot → ready |
|---|---:|---:|---:|---:|---:|---:|---:|
| 11-15 15:21:38 | 37 | 29 | 30 | 30 | 48 | 74 | 85 |
| 11-16 01:43:32 | 37 | 29 | 30 | 30 | 45 | 73 | 82 |
| 11-16 01:50:40 | 36 | 29 | 29 | 29 | 46 | 72 | 82 |
| 11-16 02:08:47 | 38 | 29 | 30 | 30 | 46 | 73 | 84 |
| 11-16 02:24:16 | 37 | 29 | 30 | 30 | 47 | 72 | 84 |
| 11-16 02:30:32 | 36 | 28 | 29 | 29 | 45 | 73 | 81 |
| 11-16 02:36:53 | 36 | 28 | 29 | 29 | 45 | 73 | 81 |
| 11-16 03:48:42 † | n/a | 41 | 42 | 42 | 59 | n/a | n/a |
| 11-16 04:00:59 ‡ | 46 | 28 | 29 | 29 | 46 | 81 | 92 |
| 11-16 13:09:51 ‡ | 39 | 28 | 29 | 29 | 63 | 79 | 102 |

† no clean shutdown before this boot (crash or power loss), and a slower boot: excluded.
‡ outliers, kept but outside the typical range: a slower firmware stage (46 s) and a slower final
boot stage (63 s).

**Typical opnsense-pi reboot (7 of 10 boots): reboot → kernel 36 to 38 s; network up at kernel
+28 to 29 s; SSH and web GUI at +29 to 30 s; ready at +45 to 48 s. End to end, from the reboot
starting: network up 64 to 67 s, SSH and web GUI 65 to 68 s, ready 81 to 85 s.** The external
watcher saw the first ping reply at 72 to 74 s, 6 to 9 s later; its sampling lag alone is 0 to 7 s,
and pf may answer ping a little after the LAN interface is configured. The firmware and loader stage (Pi EEPROM, UEFI,
FreeBSD loader) is about half of that.

The watcher's `UP after 47 to 49 s down` figure is shorter because it counts from when it
declared the router down (about 15 to 20 s after the last reply), not from the reboot command.

Data: [data/boot/](data/boot/).

### pi5-1, VyOS

Pending: pi5-1 was on Ubuntu for the whole window. When it boots VyOS, the external watcher
(`scripts/bench/boot-watch.sh`: one ping plus an SSH-banner probe about once a second) will record
reboot → last ping, → first ping and → SSH banner. `systemd-analyze` and the time
`vyos-router.service` finishes will give kernel → userspace and → configuration loaded.

## Still to do

- **VyOS rows**: rerun `iperf-host.sh` against pi5-1 eth0 on VyOS, and the boot-time watcher.
- **eth1 (USB RTL8156B)**: needs a peer. Once its cable is on the house switch, it is already set
  to take a DHCP lease (client only).
- **NAT forwarding A/B**: the comparison that matters for a router. It needs a **wired client
  behind pi5-1** (on a LAN port that pi5-1 routes and NATs to the house LAN), running
  `wan-throughput.sh` and `lan-forward.sh` the same way as the opnsense-pi baseline. These
  host-terminated tests cannot stand in for that.
