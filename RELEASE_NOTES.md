VyOS rolling (arm64) for Raspberry Pi, built from VyOS's public sources with a Raspberry Pi kernel. Unofficial; not affiliated with or supported by VyOS Networks. **The Pi 5 image has booted on one real board (16 GB, D0, from NVMe); the Pi 4 image has only run in QEMU.**

| Asset | Board | Status |
|---|---|---|
| `vyos-pi-pi4.img.xz` | Raspberry Pi 4 (pftf/RPi4 UEFI v1.54-rc, RAM limit off, then GRUB) | Boots and routes in a Pi 4-shaped QEMU VM; untested on hardware |
| `vyos-pi-pi5.img.xz` | Raspberry Pi 5 (EEPROM boots the VyOS kernel directly, mainline device tree) | **Boots on a real Pi 5** (16 GB, D0, from NVMe): onboard RP1 Ethernet (`macb`) at 1 Gb/s with DHCP and SSH, USB RTL8156B (`r8152`) at 1 Gb/s, SD card, NVMe root. Also boots and routes in a Pi 5-shaped QEMU VM |
| `vyos-pi-arm64.iso` | both | `add system image` upgrades of an installed vyos-pi |

**On a Pi 5 that already runs Raspberry Pi OS or Ubuntu, use the trial boot** (recommended): it writes vyos-pi to an NVMe or USB disk and boots it once through the firmware's `tryboot`, keeping the old OS as the default; any failure brings the old OS back by itself, with boot logs on its boot partition. Then `--commit` from VyOS makes it the default.

```sh
curl -fLO https://raw.githubusercontent.com/itpick/vyos-pi/main/scripts/pi-trial-install.sh && chmod +x pi-trial-install.sh
sudo ./pi-trial-install.sh --config config.boot https://github.com/itpick/vyos-pi/releases/latest/download/vyos-pi-pi5.img.xz /dev/nvme0n1
sudo ./pi-trial-install.sh --reboot
```

A fresh card or disk, nothing else to keep (erases the target; or Raspberry Pi Imager, **Use custom**):

```sh
curl -fL https://github.com/itpick/vyos-pi/releases/latest/download/vyos-pi-pi5.img.xz | xz -dc | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

Pi 5: the console is the 3-pin debug UART (115200); HDMI shows only the firmware's screens. Boots that fail reboot instead of hanging (`panic=10`, the hardware watchdog from the firmware on), and leave boot logs in `vyos-pi/boot-log/` on the FAT partition.

Log in as `vyos` / `vyos`. Each image's contents: `vyos-pi-<board>.manifest.txt`. The default config, to seed from (`vyos-pi/config.boot` on the FAT partition, see `scripts/seed-config.py`): `vyos-pi.config.boot.default`.

First-boot settings, the trial boot, recovering a Pi 5 that does not come up, the Pi 5 boot path and the VM tests: see the [README](https://github.com/itpick/vyos-pi#readme).
