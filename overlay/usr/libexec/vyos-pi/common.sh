# vyos-pi shell helpers (sourced).

LOG=/var/log/vyos-pi.log
ESP_TYPE=c12a7328-f81f-11d2-ba4b-00a0c93ec93b

log() {
	echo "vyos-pi: $*"
	echo "$(date '+%Y-%m-%dT%H:%M:%S') $*" >> "$LOG"
}

# The partition VyOS runs from (the persistence partition: /boot/<image>/ on it).
root_part() {
	local p
	p=$(/opt/vyatta/sbin/vyos-persistpath 2>/dev/null) || return 1
	[ -n "$p" ] && findmnt -no SOURCE "$p" 2>/dev/null | head -1
}

# The EFI system partition (FAT) on the same disk as the root partition.
find_esp() {
	local part disk
	part=$(root_part) || return 1
	disk=$(lsblk -no PKNAME "$part" 2>/dev/null | head -1)
	[ -n "$disk" ] || return 1
	lsblk -lnpo NAME,PARTTYPE "/dev/$disk" | awk -v t="$ESP_TYPE" 'tolower($2) == t { print $1; exit }'
}

# Mount the ESP read-write, or reuse an existing mount. Sets ESP_MNT, and
# ESP_OWN_MOUNT=1 if this call mounted it (umount_esp undoes that).
mount_esp() {
	local esp
	ESP_MNT='' ESP_OWN_MOUNT=''
	esp=$(find_esp) && [ -n "$esp" ] || return 1
	ESP_MNT=$(findmnt -no TARGET "$esp" 2>/dev/null | head -1)
	if [ -z "$ESP_MNT" ]; then
		ESP_MNT=/run/vyos-pi/esp.$$
		mkdir -p "$ESP_MNT"
		mount -t vfat -o rw,noatime,umask=0022 "$esp" "$ESP_MNT" || { rmdir "$ESP_MNT"; ESP_MNT=; return 1; }
		ESP_OWN_MOUNT=1
	fi
}

umount_esp() {
	if [ -n "$ESP_OWN_MOUNT" ]; then
		umount "$ESP_MNT" && rmdir "$ESP_MNT"
	fi
	ESP_MNT='' ESP_OWN_MOUNT=''
}
