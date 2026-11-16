# vyos-pi

Flashable [VyOS](https://vyos.io/) images for the Raspberry Pi 4 and 5,
plus QEMU tests that boot them on a Pi-shaped VM.

**Download page:** https://itpick.github.io/vyos-pi/

The sibling project for OPNsense is [opnsense-pi](https://github.com/itpick/opnsense-pi).

> Unofficial. VyOS publishes no arm64 builds for the Pi; these are built here
> from VyOS's public sources (vyos-build, rolling branch) with a Raspberry Pi
> kernel configuration. Not affiliated with or supported by VyOS Networks.
> **Tested in QEMU only: nothing here has booted on a real Pi yet.** Use it for
> labs and learning. Keep a working router nearby.

## Board status

| | Raspberry Pi 4 | Raspberry Pi 5 |
|---|---|---|
| Boot chain | EEPROM → [pftf/RPi4](https://github.com/pftf/RPi4) UEFI v1.54-rc (RAM limit preset off) → GRUB → VyOS | EEPROM → VyOS kernel + initrd straight from the FAT partition, mainline device tree; no UEFI ([why](#pi-5-boot-path)) |
| Kernel | VyOS's 6.18.62 arm64 kernel plus [`kernel/raspberrypi.config`](kernel/raspberrypi.config) | same kernel |
| Onboard Ethernet | `bcmgenet` (matched over ACPI); built, not yet seen on a board | RP1 GEM: `macb` + mainline RP1 driver (`MISC_RP1`); built, not yet seen on a board |
| SD card | `sdhci-iproc` (ACPI), built in | `sdhci-brcmstb`, built in |
| USB NICs | RTL8153/RTL8156 (`r8152`), AX88179 (`ax88179_178a`): VyOS's own kernel modules | same |
| AES in hardware | No (BCM2711 has no ARMv8 crypto), so VPNs are CPU-bound | Yes (Cortex-A76) |
| Fan | n/a | Not driven: mainline 6.18 has no driver for the RP1 PWM the fan hangs off |
| Verdict | Boots and routes in QEMU; untested on hardware | Boots and routes in QEMU, both through GRUB and the direct path; untested on hardware |

VyOS here is the rolling train: a snapshot of VyOS development on the day of
the build, not an LTS release.

## Flash it

```sh
# Pi 5. Replace /dev/sdX with your SD card or USB SSD. This erases it.
curl -fL https://github.com/itpick/vyos-pi/releases/latest/download/vyos-pi-pi5.img.xz \
  | xz -dc | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

Or in Raspberry Pi Imager, choose **Use custom** and pick the downloaded `.img.xz`.

Each image is one disk: partition 1 is the FAT32 EFI system partition (Pi
firmware and boot files, GRUB, the `vyos-pi/` settings folder), partition 2 is
VyOS's root (ext4, `/boot/<image>/` with the squashfs and its persistence).
The image is 3 GiB; the root partition grows to fill the card on first boot.

### Pi 5 boot path

The Pi 4 boots the way opnsense-pi does: UEFI firmware on the FAT partition,
then GRUB, which VyOS manages. The Pi 5 does not, for a reason specific to
Linux:

- The Pi 5's Ethernet and USB sit behind RP1, a PCIe chip. Mainline Linux's
  RP1 driver (`drivers/misc/rp1`, `macb`'s `raspberrypi,rp1-gem`) only finds
  RP1 through the mainline device tree (`bcm2712-rpi-5-b.dts`: an
  `rp1_nexus` under `pcie2`, `pci1de4,1`); ACPI does not describe it.
- [rpi5-uefi](https://github.com/NumberOneGit/rpi5-uefi) (what opnsense-pi uses)
  offers ACPI, or a device tree that comes from the Pi firmware: the
  downstream Raspberry Pi kernel's tree, whose RP1, PCIe and clock bindings
  differ from mainline's. With ACPI the VyOS kernel would get no Ethernet or
  USB; with the downstream tree, mainline drivers bind to the wrong layout
  (opnsense-pi gets away with it because FreeBSD's out-of-tree `rp1_eth` was
  written against the downstream tree).
- So the Pi 5 image skips UEFI: `config.txt` has the EEPROM bootloader load
  `vyos-pi/boot/Image` (the VyOS kernel, unwrapped from its EFI zboot file),
  `vyos-pi/boot/initrd.img` and the mainline device trees from the kernel
  package (`bcm2712-rpi-5-b.dtb`, and `bcm2712-d-rpi-5-b.dtb` as
  `bcm2712d0-rpi-5-b.dtb` for D0 boards), with `cmdline.txt` holding what
  GRUB would pass.

VyOS's image management only knows GRUB, so
[`vyos-pi-bootsync`](overlay/usr/libexec/vyos-pi/vyos-pi-bootsync) copies GRUB's
default image's kernel, initrd and device trees to the FAT partition and writes
`cmdline.txt`, at every boot and at shutdown. `add system image`,
`set system image default-boot` and the automatic fallback after a failed
upgrade (`reboot-on-upgrade-failure`) therefore keep working: the reboot
starts whatever GRUB would have started. What does not carry over:

- No boot menu. You cannot pick an older image or the password-recovery entry
  at boot; from a running system, `set system image default-boot <image>` and
  reboot. Offline, edit `cmdline.txt` on another computer (for example append
  `init=/usr/libexec/vyos/system/standalone_root_pw_reset` for a password
  reset), but only the default image's kernel is on the FAT partition.
- The device tree comes from the image's kernel package; the Pi firmware
  applies its usual fixups (memory, MAC address, serial numbers) to it.
- GRUB stays installed on the FAT partition (the VM tests boot it, and it would
  serve a Pi 5 UEFI that some day passes a mainline device tree), but the Pi 5
  never runs it.

### First-boot settings

The FAT32 partition (the one that shows up when you plug the card into any
computer) has a `vyos-pi/` folder. A boot hook
([`vyos-pi-boot`](overlay/usr/libexec/vyos-pi/vyos-pi-boot)) reads it at every
boot, before VyOS loads its configuration:

| File | Effect |
|---|---|
| `config.boot` | Installed as `/config/config.boot` once, then renamed to `config.boot.applied` (the old one is kept in `/config/vyos-pi/`). It must end with the version footer of a VyOS config; VyOS migrates it from that version when it loads it. Start from `config.boot.default` next to it. |
| `reboot-after-minutes` | Reboot that many minutes after every boot: a safety net for remote installs. These boots save diagnostics (`diag-boot.txt`, `diag-running.txt`, `diag-reboot.txt`) to the same folder. Delete the file to stop. |

[`scripts/seed-config.py`](scripts/seed-config.py) makes a `config.boot` for a
small home router from the default: hostname, SSH key, WAN (DHCP client,
masquerade), LAN (192.168.1.1/24, Kea DHCP server, DNS forwarding to the
WAN's resolvers), an optional management port, and a stateful firewall
(nothing in from the WAN; forward LAN → anywhere):

```sh
scripts/seed-config.py vyos-pi.config.boot.default config.boot \
  --hostname router --ssh-key ~/.ssh/id_ed25519.pub \
  --wan eth1=d8:3a:dd:00:00:01 --lan eth0=00:e0:4c:00:00:02
```

**NIC names by MAC.** `--wan eth1=<mac>` writes a `hw-id` under that
interface. VyOS rolling no longer names NICs by `hw-id` itself (since
vyos-1x [T3871], Nov 2026): it keeps a name-to-slot map in
`/config/interface-mapping.json` (a USB NIC's slot is the USB port it is in),
and its config migration (`interfaces/34-to-35`) turns the `hw-id` bindings of
an older config into entries of that map. So when MACs are given,
`seed-config.py` marks the seed's interfaces section as version 34 and VyOS
pins the names on the first load. After that, a NIC keeps its name as long as it
stays in the same port; this is what keeps two USB NICs from swapping names
between boots, which opnsense-pi needed a boot hook for.

The hook logs to `/var/log/vyos-pi.log`.

[T3871]: https://vyos.dev/T3871

**Coming from OPNsense?** [`scripts/opnsense-to-vyos.py`](scripts/opnsense-to-vyos.py)
turns an OPNsense `config.xml` into a `config.boot` to start from: interfaces,
aliases, firewall rules, NAT, DHCP reservations, DNS, WireGuard, NetFlow and
Suricata, with a notes file listing what it could not carry over.
[`examples/`](examples/) has a worked example (an opnsense-pi-shaped home
router) and a table of OPNsense features and their VyOS equivalents.

### IDS and IPS (Suricata)

VyOS rolling ships [Suricata](https://suricata.io/) (7.0.10, from Debian
bookworm-backports) and suricata-update, and configures them with
`service suricata`. It is off until configured. In VyOS's own mode it is an
IDS: af-packet capture on the listed interfaces, alerts only.

IDS on the WAN with the ET Open rules (or seed it: `seed-config.py ... --ids eth1`,
which also sets every address and port group the ET Open rules use):

```
configure
set service suricata interface eth1
set service suricata address-group home-net address 192.168.1.0/24
set service suricata address-group external-net group '!home-net'
set service suricata port-group http-ports port 80
# ... the other groups ET Open references: see scripts/seed-config.py --ids
set service suricata log eve filename eve.json
set service suricata log eve type alert
commit; save; exit
update suricata        # fetch ET Open with suricata-update, restart Suricata
```

Alerts go to `/var/log/suricata/eve.json`. The classic check,
`curl http://testmynids.org/uid/index.html`, no longer works (the domain is
parked as of November 2026); serve a page containing
`uid=0(root) gid=0(root) groups=0(root)` from any web server beyond the
router and fetch it: sid 2100498 ("GPL ATTACK_RESPONSE id check returned
root") fires. `vm/test.sh ids` does exactly that.

**IPS** (vyos-pi addition). VyOS starts Suricata with af-packet only; vyos-pi's
drop-in ([`suricata-start`](overlay/usr/libexec/vyos-pi/suricata-start)) can
run it on NFQUEUE instead, with every packet the router forwards (all
interfaces) queued to it from an nftables table that sits ahead of VyOS's
firewall:

```
sudo /usr/libexec/vyos-pi/vyos-pi-suricata-mode ips          # fail open (default)
sudo /usr/libexec/vyos-pi/vyos-pi-suricata-mode ips closed   # drop traffic while Suricata is down
sudo /usr/libexec/vyos-pi/vyos-pi-suricata-mode ids          # back to VyOS's af-packet IDS
```

The mode is kept in `/config/vyos-pi/suricata.conf`, so it survives reboots and
upgrades. ET Open rules only alert; list the ones to enforce in
`/etc/suricata/drop.conf` (sids or `re:` patterns, suricata-update's syntax)
and run `update suricata` again. The router's own traffic is not queued (only
forwarded traffic is); "service suricata interface" still has to name at least
one interface for VyOS to start the service. Throughput on a Pi is untested:
the VM says nothing about it (see below).

### First boot

1. Update the Pi's EEPROM bootloader first (from Raspberry Pi OS: `sudo rpi-eeprom-update -a`).
2. Pi 4: the UEFI comes preset with *Limit RAM to 3 GB* off, so there is
   nothing to change at its splash screen.
3. Log in on HDMI or the serial console (Pi 5: the 3-pin debug UART, `ttyAMA10`;
   Pi 4: GPIO 14/15, `ttyAMA0`) as `vyos` / `vyos`, and change the password.
   Or skip the console: seed a `config.boot` (above) and SSH in.
4. Without a seed, VyOS starts unconfigured: see the
   [VyOS quick start](https://docs.vyos.io/en/latest/quick-start.html).

Upgrades: `add system image https://github.com/itpick/vyos-pi/releases/download/<tag>/vyos-pi-arm64.iso`,
then reboot. VyOS's own arm64 images would not drive the Pi's hardware.

## Build it

```sh
make iso                  # docker, arm64 host: out/vyos-pi-arm64.iso + .raw (an hour or two)
make image BOARD=pi5      # -> out/vyos-pi-pi5.img.xz (+ .sha256)
make images               # both boards
```

`make iso` runs [`scripts/build-iso.sh`](scripts/build-iso.sh) in VyOS's own
build container, built from vyos-build's `docker/` at the pinned commit
([`scripts/container.sh`](scripts/container.sh)). It needs an arm64 machine
(Linux, or an Apple Silicon Mac with Docker Desktop or OrbStack): building
arm64 VyOS on amd64 under emulation is slow and known to be flaky. Steps:

1. **Kernel.** VyOS's kernel (version from vyos-build's `data/defaults.toml`),
   with [`kernel/raspberrypi.config`](kernel/raspberrypi.config) merged after
   VyOS's own fragments: GENET and RP1/MACB Ethernet, the SD controllers, the
   BCM2712 PCIe MSI controller, RP1, firmware/clock/power/watchdog drivers,
   sensors. The build fails if any line of it does not reach the final
   `.config`. VyOS signs and enforces kernel modules, and checks their symbol
   versions, so the out-of-tree modules VyOS needs (`accel-ppp-ng`, `jool`,
   `nat-rtsp`, `ipt-netflow`) are rebuilt against this kernel too.
2. **ISO.** vyos-build's `build-vyos-image`, flavor
   [`vyos/raspberrypi.toml`](vyos/raspberrypi.toml), plus [`overlay/`](overlay/)
   (boot hook, Pi 5 boot sync, diagnostics) and
   [`vyos/hooks/`](vyos/hooks/) (enables them, replaces the branding: see Licences).
3. **Raw image.** vyos-build's raw image target installs the ISO onto a disk
   image the way `install image` does.
4. **Board images** ([`scripts/build-image.sh`](scripts/build-image.sh), any
   Linux, no root): ESP first, Pi 4 UEFI or Pi 5 boot files onto it, the
   `vyos-pi/` folder; [`scripts/compress.sh`](scripts/compress.sh) xz's it.

[CI](.github/workflows/release.yml) runs all of it on GitHub's native arm64
runners for every pull request and tag. Inputs are pinned in
[`versions.env`](versions.env) (vyos-build commit, kernel tarball sha256, UEFI
zip sha256). VyOS's own packages come from its rolling repository on the day of
the build, which cannot be pinned (and the build fails while that repository
is down, as it was for an hour on 2026-11-16); each image's manifest
(`vyos-pi-<board>.manifest.txt`, also `/usr/share/vyos-pi/manifest.txt`) lists
what went in.

## Test it in a VM

QEMU's `virt` machine, shaped like the boards: Pi 5 is 4× Cortex-A76 with 16 GiB,
Pi 4 is 4× Cortex-A72 with 8 GiB. Three NICs: WAN (QEMU user-mode NAT), LAN
(an L2 wire a CirrOS client VM plugs into), MGMT (user-mode NAT with SSH
forwarded from the host).

```sh
make vm BOARD=pi5            # serial console here; Ctrl-a x quits
make test-image BOARD=pi4    # seed applied, NICs named by MAC, root grown, Pi kernel,
                             # drivers load; a LAN client gets a DHCP lease, resolves
                             # through VyOS, reaches the WAN through source NAT
make test-trial BOARD=pi5    # reboot-after-minutes reboots by itself, diagnostics on the ESP
make test-direct             # boot the pi5 disk like a Pi 5 does: kernel, initrd and
                             # cmdline.txt from the FAT partition, no UEFI or GRUB
make test-upgrade BOARD=pi5 ISO=other.iso  # add system image, reboot into it; pi5: the
                             # FAT partition follows and a direct boot starts it
make test                    # image + trial for both boards, direct for pi5
```

| | Pi 5 profile | Pi 4 profile |
|---|---|---|
| SSH (MGMT, once a seed enables it) | `ssh -p 2322 vyos@127.0.0.1` | `ssh -p 2323 vyos@127.0.0.1` |
| Serial console | `.work/vm/pi5/console.sock` | `.work/vm/pi4/console.sock` |
| LAN wire (vm/client.sh) | `127.0.0.1:2342` | `127.0.0.1:2343` |

Every boot is logged to `.work/vm/<profile>/console.log` (`VYOS_PI_VM_DIR`
moves `.work/vm`). Attach to a headless VM's console:
`socat -,raw,echo=0,escape=0x1d UNIX-CONNECT:.work/vm/pi5/console.sock` (Ctrl-] detaches).

Last runs (nixtop: x86_64 host, aarch64 under TCG; local builds 2026.11.16-dev1 to -dev4, the same pipeline as CI; release 2026.11.16-1's images passed `image` (both) and `direct`):

| Check | Pi 4 profile | Pi 5 profile |
|---|---|---|
| Boot through QEMU's UEFI and VyOS's GRUB to a loaded config | pass (~6 min) | pass (~6 min) |
| Seed `config.boot` from the FAT partition: hostname, SSH key | pass | pass |
| eth0/eth1/eth2 follow the seed's `hw-id`s, not PCI order (VyOS's `interface-mapping.json`) | pass | pass |
| Root grows from 3 to 32 GiB on first boot | pass | pass |
| `show version`: vyos-pi, flavor raspberrypi; running kernel has the Pi options | pass | pass |
| `macb`, `genet` and the rebuilt out-of-tree modules load (signed, symbol versions match) | pass | pass |
| Login prompt on tty1 (HDMI) | pass | pass |
| LAN client: DHCP lease from Kea, DNS through the forwarder, HTTP to the WAN side through SNAT (conntrack `src=192.168.1.100 … dst=10.0.2.15`) | pass | pass |
| `reboot-after-minutes` reboots by itself (12 min), diagnostics on the FAT partition | pass | pass |
| Suricata installed (7.0.10) and not running until configured | pass | pass |
| IDS: `service suricata` on the WAN, `update suricata` (ET Open, 53,439 rules enabled), alert 2100498 for the id-check page | pass | pass |
| IPS: NFQUEUE mode, 2100498 made a drop rule: the LAN client's fetch is blocked (`action: blocked`), other traffic flows | pass | pass |
| Direct boot, as on a Pi 5: kernel, initrd and `cmdline.txt` from the FAT partition, no UEFI/GRUB | n/a | pass |
| `add system image` of another vyos-pi ISO, reboot into it with the config, FAT boot files follow, direct boot starts it | not run | pass (dev1 → dev2) |


A boot takes about 6 minutes under TCG, so `reboot-after-minutes` is tested
with 12. Once, QEMU's UEFI spun before reaching GRUB; the tests restart a VM
that has not started a kernel after 8 minutes.

What the VM can and can't tell you:

- **Shape only.** On an x86 host the ARM CPU is emulated (TCG), so throughput
  and latency numbers mean nothing. For rough Pi 5 CPU numbers, use a Neoverse
  N1 cloud VM (AWS Graviton2, GCP T2A).
- **No Pi hardware.** The VM's NICs, disk and serial port are virtio/PL011 on
  QEMU's own device tree or UEFI. GENET, RP1, the SD controllers, the BCM2712
  PCIe controller and the Pi firmware interface are compiled and their modules
  load, but nothing attaches to them; whether they work is only answered on a
  board. In particular, whether the mainline RP1 driver brings up the Pi 5's
  Ethernet and USB from the firmware-loaded mainline device tree, and whether
  GENET and the SD card work under the Pi 4 UEFI's ACPI tables.
- **Boot chain.** The Pi EEPROM bootloader and pftf UEFI only run on real
  boards. The Pi 4 test boots the same disk through QEMU's UEFI and VyOS's
  GRUB. The Pi 5 direct test has QEMU load the kernel, initrd and
  `cmdline.txt` from the FAT partition, which checks those files and the
  command line, but not the Pi firmware reading `config.txt`, decompressing,
  or patching the device tree.
- **Pi 4 crypto.** QEMU's `cortex-a72` exposes AES/SHA, but a real BCM2711 does not.

## Licences

The scripts in this repo are BSD-2-Clause. The images contain VyOS and Debian
(GPL-2.0 and others: `/usr/share/doc/*/copyright` in the image; sources at
[github.com/vyos](https://github.com/vyos) and Debian), the Linux kernel
(GPL-2.0), TianoCore EDK2 in the Pi 4 UEFI (BSD-2-Clause-Patent) and Raspberry
Pi/Broadcom firmware blobs (redistributable; see `firmware/LICENCE.txt` on the
Pi 4 image's FAT partition).

VyOS® is a registered trademark of Sentrium S.L. (VyOS Networks). This project
is not affiliated with VyOS Networks or Raspberry Pi Ltd. VyOS's
[artwork licence](https://github.com/vyos/vyos-build/blob/rolling/LICENSE.artwork)
allows redistributing self-built images if the VyOS branding is replaced, so
the build replaces the logo artwork (boot splash images) with a plain image and
renames the product where a user first meets it (`show version`, the login
banner and the pre-login issue line) to vyos-pi. The VyOS name remains inside
the software itself (package names, the `vyos` user, CLI help, documentation
links), and in this project's name, which describes what it builds.
