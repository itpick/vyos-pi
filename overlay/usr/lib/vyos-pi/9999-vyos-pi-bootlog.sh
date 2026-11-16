#!/bin/sh
# vyos-pi (initramfs, sourced by live-boot after its own components): when
# live-boot gives up ("Unable to find a medium containing a live file system",
# and its other panics), save a boot log to the FAT partition(s) named by
# vyos-pi.bootlog= first. Then live-boot's own panic() runs, which with panic=N
# on the command line reboots after N seconds instead of starting a shell.
panic()
{
	if [ -x /bin/vyos-pi-bootlog ]; then
		/bin/vyos-pi-bootlog initramfs-panic "$*" </dev/null || true
	fi
	# live-boot's panic() (9990-initramfs-tools.sh defines nothing else that
	# changes state), then call it
	. /lib/live/boot/9990-initramfs-tools.sh
	panic "$@"
}
