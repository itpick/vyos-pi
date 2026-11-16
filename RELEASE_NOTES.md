VyOS rolling (arm64) for Raspberry Pi, built from VyOS's public sources with a Raspberry Pi kernel. Unofficial; not affiliated with or supported by VyOS Networks. **Tested in QEMU only, not yet on a real Pi.**

| Asset | Board | Status |
|---|---|---|
| `vyos-pi-pi4.img.xz` | Raspberry Pi 4 (pftf/RPi4 UEFI v1.54-rc, RAM limit off, then GRUB) | Boots and routes in a Pi 4-shaped QEMU VM; untested on hardware |
| `vyos-pi-pi5.img.xz` | Raspberry Pi 5 (EEPROM boots the VyOS kernel directly, mainline device tree) | Boots and routes in a Pi 5-shaped QEMU VM (GRUB and direct paths); untested on hardware |
| `vyos-pi-arm64.iso` | both | `add system image` upgrades of an installed vyos-pi |

Flash (erases the target):

```sh
curl -fL https://github.com/itpick/vyos-pi/releases/latest/download/vyos-pi-pi5.img.xz | xz -dc | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

Log in as `vyos` / `vyos`. Each image's contents: `vyos-pi-<board>.manifest.txt`. The default config, to seed from (`vyos-pi/config.boot` on the FAT partition, see `scripts/seed-config.py`): `vyos-pi.config.boot.default`.

First-boot settings, the Pi 5 boot path and the VM tests: see the [README](https://github.com/itpick/vyos-pi#readme).
