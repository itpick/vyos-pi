# Pi 5 iperf3 and boot time: VyOS (pi5-1) vs OPNsense (opnsense-pi)

Measured on 2026-11-16 on two Raspberry Pi 5 boards: pi5-1 (the VyOS test board) and the live
opnsense-pi home router. Both are Pi 5, 16 GB, 4x Cortex-A76.

> **Which OS ran when.** pi5-1 was on its SD-card Ubuntu 24.04 for the first part of the day,
> while another job changed its default boot to VyOS. Those runs are kept as a
> **Linux-on-the-same-board reference (Ubuntu 24.04, kernel 6.8.0-1068-raspi)**, clearly labelled.
> The VyOS rows were measured the same way after pi5-1 came up on VyOS
> 2026.11.16-ci-4ad9055 (rolling, kernel 6.18.62).

## What these tests measure

They are **host-terminated** tests: the iperf3 traffic starts or ends on the router itself. They
measure the router's NIC, driver, network stack and CPU. They do **not** measure forwarding, NAT
or the firewall path. For that, see the forwarding/NAT and Suricata baseline in
[opnsense-pi-baseline.md](opnsense-pi-baseline.md), and the same tests with VyOS as the live
router in [vyos-pi-live.md](vyos-pi-live.md).

## Setup

| | pi5-1, VyOS | pi5-1, Ubuntu reference | opnsense-pi (live router) |
|---|---|---|---|
| OS | VyOS 2026.11.16-ci-4ad9055 (rolling), Linux 6.18.62 | Ubuntu 24.04.5, Linux 6.8.0-1068-raspi | OPNsense 26.7.9_1, FreeBSD 15.1-RELEASE-p6 |
| Port under test | `eth0`, onboard RP1 GbE (`macb`), 1 Gb/s | same port | LAN `ue1`, USB RTL8156 2.5 GbE (FreeBSD `ure`), linked at 1 Gb/s |
| Other load | idle (eth0 DHCP client only, default config) | idle | live home router: pf, NAT, Suricata IDS (pcap on WAN), household traffic |
| Client | this Mac, `en7` wired 1 GbE, same switch, 192.168.68.250 | same | same |

The Mac's 1 GbE link caps everything at about 940 Mbit/s of TCP payload, so "line rate" here
means about 930 to 950 Mbit/s.

### Method

`scripts/bench/iperf-host.sh` runs 6 tests of 15 s each, with a 5 s gap:
TCP with 1 and 4 streams in each direction, and UDP at 1 Gbit/s offered load in each direction.
While they run, the router is polled every 2 s over ssh (the same read-only loop as
`router-poll.sh`) for per-core CPU, temperature and the tested NIC's byte counters.
`scripts/bench/iperf-host-summary.py` turns that into the tables below (CPU maths shared with
`summarize.py`). Each poll sample is stamped with the Mac's clock when it arrives, because
pi5-1 has no RTC and its clock is wrong until NTP syncs; for the same reason, its NIC-counter
peaks can read high when two samples arrive close together (one UDP run shows 2012 Mbit/s,
which is impossible on 1 GbE). Averages over a run are not affected.

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

| Test | pi5-1 eth0, VyOS | pi5-1 eth0, Ubuntu reference | pi5-1 LAN eth2 (USB RTL8156), VyOS as the live router ⁴ | opnsense-pi LAN ue1 (USB RTL8156) |
|---|---:|---:|---:|---:|
| TCP Mac → router, 1 stream | 789 / 818 | 770 | **911 / 916** | 591 / 594 |
| TCP Mac → router, 4 streams | 727 / 739 | 789 | **862 / 871** | 600 / 612 |
| TCP router → Mac, 1 stream | 911 / 583 ¹ | 925 | 911 / 923 | 928 / 922 |
| TCP router → Mac, 4 streams | 927 / 910 | 924 | 927 / 928 | 932 / 931 |
| UDP Mac → router @1G (loss %) | 954 (0.66 %) | 954 (0.53 %) | 952 (0.72 %) / 952 (0.80 %) | 953 (0.78 %) |
| UDP router → Mac @1G (loss %) | 955 (0.11 %) | 954 (0.28 %) | 922 (0.32 %) / 944 (0.02 %) | 930 (0.04 %) |
| Router CPU avg, TCP runs | 4 to 23 % | 9 to 29 % | 25 to 38 % | 22 to 33 % |
| Busiest core, TCP runs | 11 to 47 % | 25 to 63 % | 52 to 79 % | 38 to 78 % |
| Temperature max | n/a ² | 67 °C | 62 °C | 76 °C |

¹ The repeat run stalled at 0 Mbit/s for its first 5 s, then ran at 930 to 947 Mbit/s; the first
run held 850 to 933 Mbit/s for all 15 s. ² VyOS exposes no CPU temperature: there is no
`/sys/class/thermal` zone and no `vcgencmd`; the only hwmon sensors are the NVMe drive and
`rpi_volt`. (vyos-pi 2026.11.16-2 has a `cpu-thermal` zone; the live-router column uses it.)
⁴ Measured later the same day, with pi5-1 as the live home router (vyos-pi 2026.11.16-2, Linux
6.18.62), carrying household traffic and running Suricata (IDS on the WAN), ntopng (capturing
this port too) and AdGuard. See [VyOS as the live router](#vyos-as-the-live-router-lan-port-eth2).

VyOS and opnsense-pi were run twice (shown as "first / repeat"). The opnsense-pi runs agree within
3 %; the VyOS runs within 4 %, apart from the stall in ¹. A first VyOS run started 1 minute after
boot was slower and erratic (486 to 807 Mbit/s); it is kept in the data as `pi5-vyos-eth0-just-booted`
but not used here.

What it shows:

- **Sending from the router** reaches the Mac's line rate on all three, with plenty of CPU left.
  VyOS uses the least CPU here (4 to 6 % average).
- **Receiving on the router** is where they differ. VyOS on the onboard RP1 port gets 727 to
  818 Mbit/s, about the same as Ubuntu on the same port (770 to 789). Both put most of the
  receive work on one core (core 0). OPNsense on the USB RTL8156 tops out at about 600 Mbit/s with
  thousands of TCP retransmits (the sender sees drops), with the load spread over the cores and no
  core saturated (busiest 2 s sample 38 to 61 %). None of them reaches line rate when receiving,
  so the inbound path is the one to watch.
- UDP at 1 Gbit/s offered: all receive at about line rate with under 1 % loss and jitter under
  0.02 ms.
- The eth0 columns are **not a NIC-for-NIC comparison** with OPNsense: there the OPNsense port is a
  USB adapter on a busy live router, and the pi5-1 port is the onboard RP1 on an idle board. VyOS
  against Ubuntu on pi5-1 is fair (same port, same board, both idle).
- **The like-for-like row is the live-router column:** VyOS's USB RTL8156 LAN port on a live
  router, against OPNsense's USB RTL8156 LAN port on a live router. VyOS receives at 862 to
  916 Mbit/s, OPNsense at 591 to 612.

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
| pi5-vyos-eth0 | TCP Mac → router x1 | 789 | 0 |  | 15.6 (27/15/13/8) | 46 | 877 / 16 | n/a |
| pi5-vyos-eth0 | TCP router → Mac x1 | 911 | 6594 |  | 3.7 (6/4/1/4) | 11 | 3 / 952 | n/a |
| pi5-vyos-eth0 | TCP Mac → router x4 | 727 | 443 |  | 10.0 (17/9/4/9) | 34 | 788 / 16 | n/a |
| pi5-vyos-eth0 | TCP router → Mac x4 | 927 | 4556 |  | 6.2 (7/5/6/6) | 14 | 6 / 960 | n/a |
| pi5-vyos-eth0 | UDP Mac → router x1 @1G | 954 |  | 0.66 / 0.011 | 20.7 (32/13/19/19) | 44 | 998 / 0 | n/a |
| pi5-vyos-eth0 | UDP router → Mac x1 @1G | 955 |  | 0.11 / 0.019 | 20.3 (17/28/20/17) | 44 | 0 / 2012 | n/a |
| pi5-vyos-eth0-repeat | TCP Mac → router x1 | 818 | 232 |  | 22.8 (40/20/17/14) | 47 | 894 / 16 | n/a |
| pi5-vyos-eth0-repeat | TCP router → Mac x1 | 583 | 817 |  | 5.5 (10/4/6/2) | 17 | 4 / 957 | n/a |
| pi5-vyos-eth0-repeat | TCP Mac → router x4 | 739 | 356 |  | 13.5 (24/12/10/8) | 45 | 819 / 17 | n/a |
| pi5-vyos-eth0-repeat | TCP router → Mac x4 | 910 | 24682 |  | 4.7 (9/3/4/3) | 12 | 6 / 959 | n/a |

TCP retransmits are counted by whichever side sends (the Mac for "Mac → router"). The NIC
column is the tested port's own counter and on opnsense-pi includes household traffic. Raw iperf3
JSON, poll samples and `summary.json` are in [data/pi5-iperf/](data/pi5-iperf/).

### VyOS as the live router: LAN port eth2

Measured on 2026-11-16 at 21:50 to 21:54 UTC, after pi5-1 replaced opnsense-pi as the house
router. `eth2` is a USB RTL8156 2.5 GbE adapter (USB ID 0bda:8156, driver `r8152`,
80:3f:5d:fb:63:ce) on the house switch, linked at 1 Gb/s. It was tested from the wired Mac
exactly as above: `iperf-host.sh 192.168.68.1 vyos@192.168.68.1 eth2`, 6 runs of 15 s with 5 s
gaps, run twice.

**The physical adapter differs from OPNsense's.** OPNsense's LAN test used the RTL8156 adapter
80:3f:5d:f9:e1:bd (`ue1`). That adapter moved with the router role and is now VyOS's LAN2 port
(`eth1`, to the Deco Wi-Fi, linked at 2.5 Gb/s), where a wired test is not possible. The two
adapters are the same chip and model; the OS, the driver (`r8152` against FreeBSD's `ure`) and
the board are what differ.

Both routers were live: household traffic, pf or nftables with NAT, and Suricata IDS on the WAN.
VyOS was also running ntopng, which captures this port and uses cores 1 to 3, so its CPU figures
include ntopng.

| Setup | Test | Mbit/s | TCP retransmits | UDP loss % / jitter ms | Router CPU avg % (per core) | Busiest core % | NIC rx/tx peak Mbit/s | Temp max °C |
|---|---|---:|---:|---|---|---:|---|---:|
| vyos-live-lan-eth2 | TCP Mac → router x1 | 911 | 0 |  | 34.7 (65/24/24/25) | 69 | 1011 / 14 | 60.05 |
| vyos-live-lan-eth2 | TCP router → Mac x1 | 911 | 45 |  | 33.9 (56/24/29/26) | 79 | 7 / 1050 | 61.15 |
| vyos-live-lan-eth2 | TCP Mac → router x4 | 862 | 663 |  | 35.3 (64/25/25/28) | 68 | 960 / 18 | 60.6 |
| vyos-live-lan-eth2 | TCP router → Mac x4 | 927 | 500 |  | 27.0 (51/19/23/15) | 67 | 10 / 1040 | 60.6 |
| vyos-live-lan-eth2 | UDP Mac → router x1 @1G | 952 |  | 0.72 / 0.024 | 27.7 (48/20/19/24) | 54 | 1037 / 4 | 61.15 |
| vyos-live-lan-eth2 | UDP router → Mac x1 @1G | 922 |  | 0.32 / 0.022 | 36.8 (41/43/29/35) | 63 | 3 / 1030 | 61.15 |
| vyos-live-lan-eth2-repeat | TCP Mac → router x1 | 916 | 0 |  | 37.9 (62/29/30/29) | 66 | 1028 / 14 | 61.15 |
| vyos-live-lan-eth2-repeat | TCP router → Mac x1 | 923 | 62 |  | 25.0 (48/17/19/16) | 52 | 7 / 1034 | 59.5 |
| vyos-live-lan-eth2-repeat | TCP Mac → router x4 | 871 | 449 |  | 34.4 (60/26/22/30) | 71 | 977 / 20 | 60.6 |
| vyos-live-lan-eth2-repeat | TCP router → Mac x4 | 928 | 675 |  | 30.4 (57/20/24/21) | 73 | 10 / 1046 | 61.7 |
| vyos-live-lan-eth2-repeat | UDP Mac → router x1 @1G | 952 |  | 0.8 / 0.29 | 27.9 (45/22/20/24) | 48 | 1031 / 4 | 61.15 |
| vyos-live-lan-eth2-repeat | UDP router → Mac x1 @1G | 944 |  | 0.02 / 0.019 | 30.6 (32/28/31/32) | 50 | 2 / 1028 | 62.25 |

- **Receiving on the router**: 911 to 916 Mbit/s with 1 stream and **0 retransmits**, 862 to
  871 with 4 streams. OPNsense on its RTL8156 got 591 to 612 with 2,000 to 6,000 retransmits.
  So the inbound limit seen on opnsense-pi is the FreeBSD side (`ure` and the stack), not the chip.
- **Sending**: line rate on both (911 to 928 against 922 to 932).
- UDP at 1 Gbit/s offered: both receive at line rate with under 1 % loss.
- Core 0 takes all the NIC interrupts on VyOS, so it is the busiest core (48 to 65 % average).
- Both runs agree within 2 %. The NIC peak column reads a little above 1,000 Mbit/s because two
  poll samples sometimes arrive close together (see Method); the averages are not affected.

Raw data: [data/pi5-iperf/vyos-live-lan-eth2/](data/pi5-iperf/vyos-live-lan-eth2/) and
`vyos-live-lan-eth2-repeat/`. NAT forwarding, Suricata IDS/IPS and ntopng on the same live router
are in [vyos-pi-live.md](vyos-pi-live.md).

### Not tested, and why

| Port | Why |
|---|---|
| pi5-1 `eth1`, USB RTL8156 2.5 GbE (`r8152`), in the bench setup | **No peer** at the time: it was cabled to an isolated switch. Now that pi5-1 is the live router, its USB RTL8156 LAN port (`eth2`) has been tested instead: see [VyOS as the live router](#vyos-as-the-live-router-lan-port-eth2). Its `eth1` is LAN2 (Deco Wi-Fi only), so a wired test there would be Wi-Fi-limited. |
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

Three VyOS boots on 2026-11-16, watched from this Mac with `scripts/bench/boot-watch.sh` (one
ping plus an SSH-banner probe, about once a second). Boot 3 was started by this test with
`sudo systemctl reboot`; boots 1 and 2 were started by another job, so their start is taken as
the moment the SSH banner disappeared, minus 0.7 s (the gap measured in boot 3). Kernel start =
the Mac's clock minus `/proc/uptime`, read right after boot (pi5-1 has no RTC, so its own clock
is not usable). Milestones on the box come from `journalctl -b -o short-monotonic`.

| Boot | reboot → kernel | kernel → SSH listening | kernel → config loaded ³ | kernel → eth0 up + DHCP lease | reboot → SSH | reboot → config loaded | reboot → eth0 up | reboot → first reply on the LAN (watcher) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1, first VyOS boot of this install † | 14.1 | 41.9 | 42.6 | 42.9 | 56.0 | 56.7 | 57.0 | 69.2 |
| 2 | 14.1 | 32.9 | 33.6 | 34.3 | 47.0 | 47.7 | 48.4 | 48.7 |
| 3 | 14.2 | 33.3 | 34.6 | 34.2 | 47.5 | 48.8 | 48.4 | 56.6 |

† Boot 1 came straight from Ubuntu: it generated SSH host keys and named new hardware, so it is
slower and is not used for the typical range. ³ "Config loaded" = the last `vyos-router` line,
`migrate activate configure.`. `systemd-analyze` reports 13.4 s in the kernel (this includes
VyOS's live-boot initramfs) and 6.3 to 6.4 s in userspace before `multi-user.target`; the config
load then runs on top of that.

**Typical VyOS reboot (boots 2 and 3): reboot → kernel 14 s; eth0 up with a lease, SSH listening
and the config loaded all at 47 to 49 s.** Against opnsense-pi's typical reboot that is 16 to
19 s sooner to network up, 18 to 21 s sooner to SSH, and about 33 s sooner to "ready" (OPNsense
keeps starting services until 81 to 85 s). Most of the difference is before the kernel:
the firmware and loader stage is 36 to 38 s on opnsense-pi against 14 s for VyOS (Pi firmware boots the
VyOS kernel directly, with no UEFI), while kernel → network up is similar (OPNsense 28 to 29 s,
VyOS 34 s).

The first reply seen from the LAN varied: 0.5 s after the lease in boot 2, but 8 s (boot 3) and
12 s (boot 1) later in the others. The box had its address and SSH was listening, so this looks
like the path (switch port or ARP on the Mac), not VyOS; the cause has not been pinned down.

Every boot logged a commit error from `system_option.py`: `kexec -l /boot/vmlinuz ...` exited 255.
The rest of the configuration loaded. pi5-1 has no HTTP API configured, so management here means
SSH.

Data: [data/boot/pi5-1-vyos-boots.md](data/boot/pi5-1-vyos-boots.md) and the watcher log next to it.

## Still to do

- **VyOS HTTP API**: not configured on pi5-1, so its "API ready" time is not measured yet.
- **The 8 to 12 s reachability gap** after some VyOS boots, and the `kexec` commit error.
- ~~eth1 (USB RTL8156B) needs a peer~~: done on the live router's USB RTL8156 LAN port (`eth2`), above.
- ~~NAT forwarding A/B~~: done with pi5-1 as the live router, using the same scripts as the
  opnsense-pi baseline: [vyos-pi-live.md](vyos-pi-live.md).
