# pi5-1 VyOS boot timings, 2026-11-16 (Mac clock, CST)

VyOS 2026.11.16-ci-4ad9055 (rolling), kernel 6.18.62-1-vyos, Pi 5 16 GB, NVMe, Pi firmware direct boot.

Sources per boot:
- reboot start: boot 3 = the time this Mac sent `sudo systemctl reboot` (its SSH banner went away 0.7 s later);
  boots 1 and 2 were started by another job, so start = "SSH banner gone" in the watcher log minus 0.7 s.
- kernel start: Mac clock minus `/proc/uptime`, read over ssh right after boot (2 to 3 reads, agree within 0.2 s).
- SSH listening, config loaded, eth0 link up, DHCP lease: `journalctl -b -o short-monotonic` on the box
  (`sshd: Server listening on 0.0.0.0 port 22`, `vyos-router: migrate activate configure.`, `macb ... eth0: Link is Up`, `dhclient: DHCPACK`).
- first reply on the LAN: `boot-watch.sh` on this Mac (ping + SSH banner probe about once a second); it matches sshd's
  first "Connection closed by <Mac>" log line to within 0.2 s.

| Boot | reboot start (epoch) | kernel start (epoch) | reboot → kernel s | kernel → SSH listening s | kernel → config loaded s | kernel → eth0 link up / DHCP lease s | kernel → first LAN reply s | reboot → SSH listening | reboot → config loaded | reboot → eth0 up | reboot → first LAN reply | systemd-analyze |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 1 (Ubuntu SD → first VyOS boot of this install) | 1794854292.7 (est.) | 1794854306.8 | 14.1 | 41.9 | 42.6 | 42.9 / 42.7 | 55.1 | 56.0 | 56.7 | 57.0 | 69.2 | 13.46 s kernel + 14.54 s userspace |
| 2 (VyOS → VyOS) | 1794854407.7 (est.) | 1794854421.8 | 14.1 | 32.9 | 33.6 | 34.0 / 34.3 | 34.6 | 47.0 | 47.7 | 48.4 | 48.7 | 13.37 s + 6.30 s |
| 3 (VyOS → VyOS, rebooted by this test) | 1794854911.2 | 1794854925.4 | 14.2 | 33.3 | 34.6 | 34.2 / 34.0 | 42.4 | 47.5 | 48.8 | 48.4 | 56.6 | 13.35 s + 6.44 s |

Boot 1 is the first boot of this install after coming from Ubuntu: it generated SSH host keys and named new
hardware, so it is slower and is shown separately. In boots 1 and 3 the LAN could not reach the box for 8 to
12 s after eth0 was up with a lease; in boot 2 it could within 0.5 s. The cause is not known yet (switch port
or ARP on the Mac are the likely suspects); the "first LAN reply" column is reported as measured.

Every boot logged a commit error in `system_option.py`: `kexec -l /boot/vmlinuz ...` exited 255. The rest of the
configuration loaded.

pi5-1 has no HTTP API configured, so management = SSH.
