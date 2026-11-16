vyos-pi first-boot settings (read at every boot, before VyOS loads its config)

config.boot           Put a VyOS config.boot here (for example one made with
                      scripts/seed-config.py from config.boot.default, or a
                      backup from another VyOS) and it is installed on the next
                      boot, once, then renamed to config.boot.applied. It must
                      end with the version footer ("// vyos-config-version:")
                      of the VyOS it came from; VyOS migrates it from there.
                      Pin NIC names by MAC with "hw-id" under each
                      "interfaces ethernet ethN" (see the README).
reboot-after-minutes  A number of minutes: reboot that long after every boot.
                      A safety net for remote installs. Delete it to stop.
                      These boots save diagnostics here as diag-boot.txt,
                      diag-running.txt (3 minutes in) and diag-reboot.txt.

boot-log/             Boot logs, one file per boot and stage (<boot>-<stage>.txt:
                      initramfs-top, initramfs, initramfs-panic, initramfs-done,
                      early, running, shutdown), the 10 latest boots. Read
                      them here when the Pi does not come up on the network.
                      (Raspberry Pi 5; cmdline.txt's vyos-pi.bootlog= names
                      this folder.)

Raspberry Pi 5 only: boot/ holds the kernel and initrd the Pi starts directly
(config.txt and cmdline.txt are one folder up). vyos-pi-bootsync rewrites them
from VyOS's default image at every boot and shutdown; don't edit them by hand
unless you are recovering a system that no longer boots.

The boot hook logs to /var/log/vyos-pi.log.
https://github.com/itpick/vyos-pi
