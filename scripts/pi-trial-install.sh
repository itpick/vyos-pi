#!/usr/bin/env bash
# pi-trial-install.sh: try vyos-pi on a Raspberry Pi 5 that already runs another
# OS (Raspberry Pi OS, Ubuntu), without risking that OS or needing anyone at the
# board if vyos-pi does not come up.
#
# It writes the vyos-pi image to another disk (NVMe or USB) and leaves the
# running OS as the default boot. The trial uses the Pi firmware's one-time
# "tryboot" flag (https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#fail-safe-os-updates-tryboot):
# after `reboot '0 tryboot'` the firmware reads tryboot.txt instead of
# config.txt from the boot partition, once. It clears the flag before it starts
# the OS, so any reset after that - a reboot, a panic, the watchdog, a power
# cycle - boots config.txt, the OS you have now, again.
#
# This puts on the current boot partition (the FAT one, /boot/firmware):
#   tryboot.txt        os_prefix=vyos-pi-trial/: the VyOS kernel, initrd and
#                      device trees, copied from the target disk
#   vyos-pi-trial/     those files; cmdline.txt (VyOS's root on the target
#                      disk, panic=10, consoles, the boot log); trial.env;
#                      boot-log/ (vyos-pi-bootlog writes here during the trial,
#                      so a failed trial is readable from the old OS)
# and on the target disk's FAT partition, vyos-pi/reboot-after-minutes (VyOS
# reboots - back to the old OS - after that long, until --commit).
#
# usage (as root):
#   pi-trial-install.sh [options] IMAGE TARGET   write IMAGE (.img, .img.xz, or
#                                                an https URL of one) to TARGET
#                                                (/dev/nvme0n1, /dev/sda), arm
#                                                the trial
#   pi-trial-install.sh [options] --no-write TARGET
#                                                arm a trial of what TARGET has
#   pi-trial-install.sh --reboot                 reboot into the trial (once)
#   pi-trial-install.sh --reboot-target          after a good trial: boot the
#                                                target once the way it will
#                                                boot when committed (its own
#                                                config.txt, kernel, cmdline),
#                                                through a one-time boot order;
#                                                the next reset of any kind
#                                                comes back here
#   pi-trial-install.sh --status                 trial state, boot logs
#   pi-trial-install.sh --cancel                 remove the trial (old OS)
#   pi-trial-install.sh --commit                 from the trial VyOS, once you
#                                                are happy with it: make VyOS
#                                                the default (the boot
#                                                partition's config.txt is
#                                                renamed, so the bootloader
#                                                moves on to TARGET)
#   pi-trial-install.sh --uncommit               undo --commit (from VyOS, or
#                                                any Linux with the card)
# options:
#   --boot DIR           the boot partition of the OS you have now
#                        (default: /boot/firmware, else /boot)
#   --config FILE        a VyOS config.boot to seed (scripts/seed-config.py):
#                        with an SSH key in it you can log in remotely
#   --trial-minutes N    VyOS reboots after N minutes, every boot, until
#                        --commit (default 30; 0: no timer, only panic=10 and
#                        the watchdog bring the old OS back)
#   --watchdog-seconds N kernel_watchdog_timeout in tryboot.txt (default 300;
#                        0: off)
#   --yes                do not ask before erasing TARGET
#   --reboot             reboot into the trial when done
#   --initrd FILE        use this initrd for the trial instead of the target's
#                        (scripts/bootlog-initrd.py: an older image's initrd
#                        with the boot log added)
#   --force              skip the board and boot order checks
# test hooks (vm/test.sh trialboot): TARGET may be a disk image file (its FAT
# partition is then read and written with mtools); --boot-partuuid ID sets the
# boot partition's PARTUUID when --boot is a plain directory.
set -euo pipefail
PROG=$(basename "$0")
PREFIX=vyos-pi-trial
MARK="# vyos-pi-trial"
die() { echo "$PROG: $*" >&2; exit 1; }
say() { echo ">> $*"; }
warn() { echo "$PROG: warning: $*" >&2; }

action=install boot_dir="" boot_partuuid="" config="" initrd="" trial_minutes=30 watchdog=300
yes=0 do_reboot=0 force=0 no_write=0
args=()
while (( $# )); do
  case "$1" in
    --boot) boot_dir=$2; shift ;;
    --boot-partuuid) boot_partuuid=$2; shift ;;
    --config) config=$2; shift ;;
    --initrd) initrd=$2; shift ;;
    --trial-minutes) trial_minutes=$2; shift ;;
    --watchdog-seconds) watchdog=$2; shift ;;
    --yes|-y) yes=1 ;;
    --reboot) do_reboot=1 ;;
    --force) force=1 ;;
    --no-write) no_write=1 ;;
    --reboot-target) action=reboot-target ;;
    --status) action=status ;;
    --cancel) action=cancel ;;
    --commit) action=commit ;;
    --uncommit) action=uncommit ;;
    -h|--help) sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
    -*) die "unknown option $1 (--help)" ;;
    *) args+=("$1") ;;
  esac
  shift
done
[[ "$trial_minutes" =~ ^[0-9]+$ ]] || die "--trial-minutes: a number"
[[ "$watchdog" =~ ^[0-9]+$ ]] || die "--watchdog-seconds: a number"
if [[ $action == install && $do_reboot == 1 && ${#args[@]} == 0 && $no_write == 0 ]]; then
  action=reboot
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/pi-trial.XXXXXX")
mounts=()
cleanup() {
  local m
  for m in "${mounts[@]+"${mounts[@]}"}"; do umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT

# --- the Pi firmware's view (/proc/device-tree/chosen/bootloader) ---
dt_u32() {
  local f=/proc/device-tree/chosen/bootloader/$1
  [[ -r $f ]] || { echo ""; return; }
  printf '%d' "0x$(od -v -An -t x1 "$f" | tr -d ' \n')"
}
in_vyos() { [[ -e /opt/vyatta/etc/version || -d /usr/libexec/vyos ]]; }

# --- the current boot partition (the SD card's FAT, normally) ---
find_boot_dir() {
  local d
  if [[ -n $boot_dir ]]; then
    [[ -d $boot_dir ]] || die "--boot $boot_dir: not a directory"
    echo "$boot_dir"; return
  fi
  for d in /boot/firmware /boot; do
    [[ -f $d/config.txt ]] && { echo "$d"; return; }
  done
  die "no boot partition with a config.txt at /boot/firmware or /boot (--boot DIR)"
}
partuuid_of_dir() {
  local src
  [[ -n $boot_partuuid ]] && { echo "${boot_partuuid,,}"; return; }
  src=$(findmnt -no SOURCE --target "$1" 2>/dev/null | head -1)
  [[ -b $src ]] || die "$1 is not a mounted partition (--boot-partuuid for tests)"
  lsblk -no PARTUUID "$src" | head -1 | tr 'A-Z' 'a-z'
}

# --- the target disk: a block device (mounted) or an image file (mtools) ---
T_MODE="" T_DIR="" T_IMG=""
target_open() {
  local target=$1 p1="" p
  if [[ -b $target ]]; then
    for p in "${target}p1" "${target}1"; do [[ -b $p ]] && { p1=$p; break; }; done
    [[ -n $p1 ]] || die "$target has no partition 1"
    T_MODE=dev T_DIR=$tmp/target
    mkdir -p "$T_DIR"
    mount -t vfat -o rw,noatime "$p1" "$T_DIR" || die "cannot mount $p1"
    mounts+=("$T_DIR")
  elif [[ -f $target ]]; then
    local off
    off=$(sfdisk -J "$target" | python3 -c 'import json,sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][0]["start"] * 512)')
    T_MODE=img T_IMG="$target@@$off"
    export MTOOLS_SKIP_CHECK=1
  else
    die "$target: not a block device or an image file"
  fi
}
t_get() {  # REL DEST
  if [[ $T_MODE == dev ]]; then cp "$T_DIR/$1" "$2"; else mcopy -n -o -i "$T_IMG" "::/$1" "$2"; fi
}
t_put() {  # SRC REL
  if [[ $T_MODE == dev ]]; then mkdir -p "$(dirname "$T_DIR/$2")"; cp "$1" "$T_DIR/$2"; else mcopy -o -i "$T_IMG" "$1" "::/$2"; fi
}
t_has() {
  if [[ $T_MODE == dev ]]; then [[ -e $T_DIR/$1 ]]; else mdir -i "$T_IMG" "::/$1" >/dev/null 2>&1; fi
}
t_rm() {
  if [[ $T_MODE == dev ]]; then rm -f "$T_DIR/$1"; else mdel -i "$T_IMG" "::/$1" 2>/dev/null || true; fi
}
t_close() {
  if [[ $T_MODE == dev ]]; then sync; umount "$T_DIR"; mounts=("${mounts[@]/$T_DIR}"); fi
}

# GPT/MBR partition UUIDs (= PARTUUID) of a disk or image: "1 <uuid>" lines
part_uuids() {
  sfdisk -J "$1" 2>/dev/null | python3 -c '
import json, sys
t = json.load(sys.stdin)["partitiontable"]
for i, p in enumerate(t["partitions"], 1):
    u = p.get("uuid")
    if not u and t.get("id"):  # MBR: <disk id>-<nn>
        u = "%s-%02x" % (t["id"].lower().replace("0x", ""), i)
    print(i, (u or "").lower())'
}

# BOOT_ORDER from the EEPROM config (rpi-eeprom-config), if it can be read
boot_order() {
  command -v rpi-eeprom-config >/dev/null || return 1
  rpi-eeprom-config 2>/dev/null | sed -n 's/^BOOT_ORDER=//p' | tail -1
}

write_trial_files() {  # BOOTDIR TARGET ROOT_UUID ESP_UUID BOOT_UUID
  local b=$1 target=$2 root_uuid=$3 esp_uuid=$4 boot_uuid=$5 d=$1/$PREFIX f n opts=()
  mkdir -p "$d" "$d/boot-log"
  say "copying the VyOS kernel, initrd and device trees to $d/"
  t_get vyos-pi/boot/Image "$tmp/Image"
  if [[ -n $initrd ]]; then
    [[ -f $initrd ]] || die "--initrd $initrd: no such file"
    cp "$initrd" "$tmp/initrd.img"
  else
    t_get vyos-pi/boot/initrd.img "$tmp/initrd.img"
  fi
  t_get cmdline.txt "$tmp/cmdline.target"
  t_get vyos-pi/boot/version "$tmp/version" 2>/dev/null || echo unknown >"$tmp/version"
  for f in bcm2712-rpi-5-b.dtb bcm2712d0-rpi-5-b.dtb bcm2712-d-rpi-5-b.dtb; do
    t_has "$f" && t_get "$f" "$tmp/$f"
  done
  [[ -f $tmp/bcm2712-rpi-5-b.dtb ]] || die "no bcm2712-rpi-5-b.dtb on the target's FAT partition"
  # D0 boards (2 GB, 16 GB, most since late 2024): the firmware loads
  # bcm2712-rpi-5-b.dtb and applies the overlay bcm2712d0 to it, from
  # $PREFIX/overlays/ when $PREFIX/overlays/README exists (else from the old
  # OS's overlays/, whose bcm2712d0.dtbo is for Raspberry Pi's own tree and
  # leaves the mainline one with the C1 pin controller: SError at boot).
  # vyos-pi-thermal: the temperature sensor (tryboot.txt dtoverlay=).
  mkdir -p "$tmp/overlays"
  local ov src
  for ov in bcm2712d0 vyos-pi-thermal; do
    if t_has "overlays/$ov.dtbo"; then
      t_get "overlays/$ov.dtbo" "$tmp/overlays/$ov.dtbo"
      continue
    fi
    src=$(dirname "$0")/../firmware/pi5/$ov-overlay.dts
    [[ -f $src ]] && command -v dtc >/dev/null \
      || die "the target has no overlays/$ov.dtbo (images up to 2026.11.16-1); run this from a vyos-pi checkout with dtc installed (apt install device-tree-compiler)"
    dtc -q -@ -I dts -O dtb -o "$tmp/overlays/$ov.dtbo" "$src"
  done
  # The firmware only starts the watchdog (kernel_watchdog_timeout) for a
  # device tree with a "watchdog" alias to a node with "early-watchdog";
  # images from this version on have it, older ones get it here if
  # vyos-pi-bootsync is at hand (a vyos-pi checkout, or VyOS).
  local bs
  for bs in "$(dirname "$0")/../overlay/usr/libexec/vyos-pi/vyos-pi-bootsync" /usr/libexec/vyos-pi/vyos-pi-bootsync ""; do
    [[ -n $bs && -f $bs ]] && grep -q -- '--patch-dtb' "$bs" && break
  done
  if [[ -n $bs ]]; then
    for f in "$tmp"/*.dtb; do python3 -I "$bs" --patch-dtb "$f" "$f" || die "could not patch $f"; done
  else
    warn "no vyos-pi-bootsync with --patch-dtb here: device trees copied as they are (the firmware may not start the watchdog)"
  fi
  # free space on the boot partition (kernel + initrd + device trees, x1.1)
  n=$(du -cb "$tmp"/Image "$tmp"/initrd.img "$tmp"/*.dtb | tail -1 | cut -f1)
  local avail
  avail=$(df -B1 --output=avail "$b" | tail -1 | tr -d ' ')
  local have=0
  [[ -f $d/Image ]] && have=$(du -cb "$d"/Image "$d"/initrd.img 2>/dev/null | tail -1 | cut -f1)
  (( avail + have > n * 11 / 10 )) || die "$b has $((avail / 1048576)) MiB free; the trial needs $((n / 1048576)) MiB"
  for f in Image initrd.img "$tmp"/*.dtb; do
    cp "$tmp/${f##*/}" "$d/${f##*/}.new" && mv "$d/${f##*/}.new" "$d/${f##*/}"
  done
  mkdir -p "$d/overlays"
  cp "$tmp/overlays/"*.dtbo "$d/overlays/"
  echo "vyos-pi trial: overlays for the trial's mainline device tree (this README makes the firmware use this folder)" >"$d/overlays/README"

  # VyOS's command line from the target, for the trial:
  # - live-media=: VyOS's root is the target's partition 2, nothing else
  # - persistence-storage=filesystem: find VyOS's persistence partition by
  #   its label only; live-boot otherwise mounts every partition (the old
  #   OS's root too, read-write) looking for persistence files
  # - panic=10: kernel panics, and an initramfs that cannot find the root,
  #   reboot (to the old OS) after 10 s instead of waiting at a shell
  # - earlycon on the debug UART, consoles on HDMI and the UART (last: gets
  #   the initramfs's and systemd's messages)
  # - vyos-pi.bootlog=: boot logs to this partition and the target's
  # - log_buf_len=8M: the kernel log in its own buffer at the top of RAM,
  #   where scripts/pi-find-kernel-log.py finds it after a failed boot
  # - vyos-pi.trial=: where --commit finds this partition
  for f in $(cat "$tmp/cmdline.target"); do
    case "$f" in
      console=*|earlycon*|panic=*|live-media=*|persistence-storage=*|log_buf_len=*|vyos-pi.*) ;;
      *) opts+=("$f") ;;
    esac
  done
  [[ " ${opts[*]} " == *" vyos-union=/boot/"* ]] || die "the target's cmdline.txt has no vyos-union= (not a vyos-pi Pi 5 image?)"
  opts+=("live-media=/dev/disk/by-partuuid/$root_uuid" persistence-storage=filesystem panic=10
    earlycon=pl011,0x107d001000,115200n8 console=tty1 console=ttyAMA10,115200 log_buf_len=8M
    "vyos-pi.bootlog=PARTUUID=$boot_uuid:/$PREFIX/boot-log,PARTUUID=$esp_uuid:/vyos-pi/boot-log"
    "vyos-pi.trial=PARTUUID=$boot_uuid")
  echo "${opts[*]}" >"$d/cmdline.txt"

  cat >"$tmp/trial.env" <<EOF
# written by $PROG $(date -u +%Y-%m-%dT%H:%M:%SZ)
VERSION=$(cat "$tmp/version")
TARGET=$target
TARGET_ROOT_PARTUUID=$root_uuid
TARGET_ESP_PARTUUID=$esp_uuid
BOOT_PARTUUID=$boot_uuid
TRIAL_MINUTES=$trial_minutes
STATE=armed
EOF
  cp "$tmp/trial.env" "$d/trial.env"
  # and on the target, where --commit finds the boot partition when VyOS was
  # not started by the trial (--reboot-target)
  t_put "$tmp/trial.env" vyos-pi/trial.env
  [[ -f $0 ]] && cp "$0" "$d/pi-trial-install.sh"
  cat >"$d/README.txt" <<EOF
vyos-pi trial boot (https://github.com/itpick/vyos-pi#try-it-on-a-pi-that-runs-another-os)

tryboot.txt (one folder up) boots VyOS from these files, once, after
"reboot '0 tryboot'"; every other boot uses config.txt, the OS installed here.

  Image, initrd.img, *.dtb   VyOS's kernel, initrd and device trees ($(cat "$tmp/version"))
  cmdline.txt                its kernel command line: root on $target
  trial.env                  what was set up
  boot-log/                  boot logs of the trial boots, newest last
                             (<boot>-initramfs.txt, -initramfs-panic.txt,
                             -initramfs-done.txt, -early.txt, -running.txt)
  pi-trial-install.sh        --status, --cancel; --commit from VyOS

Remove tryboot.txt to disarm the trial.
EOF

  # tryboot.txt: a whole config of its own (the firmware reads it *instead of*
  # config.txt). Keep someone else's (Ubuntu's piboot) for --cancel.
  if [[ -f $b/tryboot.txt ]] && ! grep -q "^$MARK" "$b/tryboot.txt"; then
    say "keeping the existing tryboot.txt as $PREFIX/tryboot.txt.orig"
    cp -p "$b/tryboot.txt" "$d/tryboot.txt.orig"
  fi
  {
    echo "$MARK: one-time trial boot of vyos-pi $(cat "$tmp/version") from $target"
    echo "# Written by $PROG. The Pi firmware reads this instead of config.txt only"
    echo "# after \"reboot '0 tryboot'\" and only for that boot; see $PREFIX/README.txt."
    echo "[all]"
    echo "arm_64bit=1"
    echo "os_prefix=$PREFIX/"
    echo "kernel=Image"
    echo "initramfs initrd.img followkernel"
    echo "cmdline=cmdline.txt"
    echo "# the device tree: bcm2712-rpi-5-b.dtb or bcm2712d0-rpi-5-b.dtb (D0 boards),"
    echo "# picked by the firmware from $PREFIX/ (mainline, from VyOS's kernel)"
    echo "os_check=0"
    echo "# debug UART (3-pin header): firmware and kernel messages from the start"
    echo "enable_uart=1"
    echo "uart_2ndstage=1"
    echo "# the SoC temperature sensor (the mainline tree has none)"
    echo "dtoverlay=vyos-pi-thermal"
    if (( watchdog > 0 )); then
      echo "# hardware watchdog through to systemd: a boot that hangs resets the"
      echo "# board, and that boots config.txt again"
      echo "kernel_watchdog_timeout=$watchdog"
    fi
  } >"$b/tryboot.txt.new"
  mv "$b/tryboot.txt.new" "$b/tryboot.txt"
  sync
}

do_install() {
  local image="" target
  if (( no_write )); then
    (( ${#args[@]} == 1 )) || die "usage: $PROG [options] --no-write TARGET"
    target=${args[0]}
  else
    (( ${#args[@]} == 2 )) || die "usage: $PROG [options] IMAGE TARGET (--help)"
    image=${args[0]} target=${args[1]}
  fi
  local b
  b=$(find_boot_dir)
  [[ -f $b/config.txt ]] || die "$b has no config.txt"
  local real=0
  [[ -b $target ]] && real=1
  if (( real )); then
    [[ $(id -u) == 0 ]] || die "run as root"
    if (( ! force )); then
      local model
      model=$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)
      [[ $model == *"Raspberry Pi 5"* || $model == *"Raspberry Pi Compute Module 5"* || $model == *"Raspberry Pi 500"* ]] \
        || die "this is \"${model:-not a Pi}\"; the trial boot is for the Pi 5 (the Pi 4 image boots through UEFI) (--force)"
    fi
  fi
  [[ -f $b/autoboot.txt ]] && die "$b/autoboot.txt exists: with A/B partitions the firmware may not read tryboot.txt from here; not supported"
  if [[ -d $b/new ]] && [[ -n $(ls -A "$b/new" 2>/dev/null) ]] && (( ! force )); then
    die "$b/new/ exists: Ubuntu's own tryboot (piboot-try) has a kernel waiting to be tried. Reboot normally first, then run this again (--force to ignore)"
  fi
  local boot_uuid
  boot_uuid=$(partuuid_of_dir "$b")
  [[ -n $boot_uuid ]] || die "no PARTUUID for the partition at $b"

  if (( real )); then
    local tdisk bdisk rdisk
    tdisk=$(lsblk -dno NAME "$target")
    [[ $(lsblk -no TYPE "$target" | head -1) == disk ]] || die "$target: give the whole disk (/dev/nvme0n1, /dev/sda), not a partition"
    bdisk=$(lsblk -no PKNAME "$(findmnt -no SOURCE --target "$b" | head -1)" 2>/dev/null | head -1)
    rdisk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -1)
    [[ $tdisk != "$bdisk" && $tdisk != "$rdisk" ]] || die "$target holds the running OS"
    if lsblk -lnpo MOUNTPOINT "$target" | grep -q .; then
      die "$target has mounted partitions: $(lsblk -lnpo NAME,MOUNTPOINT "$target" | awk '$2 != ""' | tr '\n' ' ')"
    fi
    # The trial only falls back if the boot partition's device is tried before
    # the target: SD (1) before NVMe (6) / USB (4) in BOOT_ORDER (read right to left).
    local order kind ttype
    order=$(boot_order || true)
    ttype=$( [[ $target == /dev/nvme* ]] && echo 6 || echo 4 )
    kind=$( [[ $(findmnt -no SOURCE --target "$b") == /dev/mmcblk* ]] && echo 1 || echo "" )
    if [[ -n $order && -n $kind ]]; then
      local digits=${order#0x} i first=""
      for (( i=${#digits}-1; i>=0; i-- )); do
        case "${digits:i:1}" in "$kind") first=boot; break ;; "$ttype") first=target; break ;; esac
      done
      if [[ $first != boot ]] && (( ! force )); then
        die "BOOT_ORDER=$order tries $target before the SD card, so a plain reboot would start VyOS with no way back. Set it back first: sudo rpi-eeprom-config --edit -> BOOT_ORDER=0xf461 (--force to ignore)"
      fi
      say "BOOT_ORDER=$order: the SD card boots before $target"
    else
      warn "could not read BOOT_ORDER (rpi-eeprom-config); it must try this boot partition's device before $target (SD first: 0xf461)"
    fi
  fi

  if [[ -n $image ]]; then
    local reader=(cat)
    case "$image" in *.xz) reader=(xz -dc) ;; esac
    if [[ $image == https://* || $image == http://* ]]; then
      say "downloading and writing $image to $target"
    else
      [[ -f $image ]] || die "$image: no such file"
      say "writing $image to $target"
    fi
    if (( real )); then
      lsblk -o NAME,SIZE,MODEL,SERIAL "$target"
      if (( ! yes )); then
        read -r -p "Erase $target and write vyos-pi to it? Type yes: " ans
        [[ $ans == yes ]] || die "not confirmed"
      fi
    fi
    local dd_opts=(bs=4M conv=fsync status=progress)
    (( real )) || dd_opts=(bs=4M conv=notrunc,fsync status=none)
    if [[ $image == http* ]]; then
      curl -fL --retry 3 "$image" | "${reader[@]}" | dd of="$target" "${dd_opts[@]}"
    else
      "${reader[@]}" "$image" | dd of="$target" "${dd_opts[@]}"
    fi
    if (( real )); then
      # the image's backup GPT is at 3 GiB, not at the end of the disk
      sfdisk --relocate gpt-bak-std "$target" >/dev/null 2>&1 || true
      partprobe "$target" 2>/dev/null || blockdev --rereadpt "$target" 2>/dev/null || true
      udevadm settle 2>/dev/null || sleep 3
    fi
  fi

  local root_uuid esp_uuid
  esp_uuid=$(part_uuids "$target" | awk '$1 == 1 { print $2 }')
  root_uuid=$(part_uuids "$target" | awk '$1 == 2 { print $2 }')
  [[ -n $esp_uuid && -n $root_uuid ]] || die "$target: no partitions 1 and 2 (not a vyos-pi image?)"
  [[ $esp_uuid != "$boot_uuid" ]] || die "the target's FAT partition has the same PARTUUID as $b ($boot_uuid): is it a copy of this disk?"

  target_open "$target"
  t_has vyos-pi/boot/Image || die "$target has no vyos-pi/boot/Image: not a vyos-pi Pi 5 image"
  write_trial_files "$b" "$target" "$root_uuid" "$esp_uuid" "$boot_uuid"
  if [[ -n $config ]]; then
    [[ -f $config ]] || die "--config $config: no such file"
    t_put "$config" vyos-pi/config.boot
    say "seeded vyos-pi/config.boot on $target"
  fi
  if (( trial_minutes > 0 )); then
    echo "$trial_minutes" >"$tmp/reboot-after-minutes"
    echo "set by $PROG; --commit removes it with reboot-after-minutes" >"$tmp/trial-armed"
    t_put "$tmp/reboot-after-minutes" vyos-pi/reboot-after-minutes
    t_put "$tmp/trial-armed" vyos-pi/trial-armed
    say "VyOS will reboot (back to this OS) $trial_minutes minutes after it starts, until --commit"
  fi
  t_close
  sync
  say "trial armed: $b/tryboot.txt -> $b/$PREFIX/ (root: PARTUUID=$root_uuid on $target)"
  echo
  echo "Next: $PROG --reboot   (or: sudo reboot '0 tryboot')"
  echo "VyOS starts once. Any reset or power cycle brings this OS back; so do a"
  echo "kernel panic or a missing root (10 s), a hang (watchdog), and the"
  echo "${trial_minutes}-minute timer. Back here: $PROG --status shows the boot logs."
  echo "Happy with VyOS: run $PROG --commit on it (/usr/libexec/vyos-pi/pi-trial-install,"
  echo "or this script from $b/$PREFIX/)."
  if (( do_reboot && real )); then do_tryboot; fi
}

do_tryboot() {
  local b
  b=$(find_boot_dir)
  grep -q "^$MARK" "$b/tryboot.txt" 2>/dev/null || die "no vyos-pi trial armed in $b (tryboot.txt)"
  [[ $(id -u) == 0 ]] || die "run as root"
  sync
  say "rebooting into the trial: reboot '0 tryboot'"
  reboot '0 tryboot'
}

env_get() { sed -n "s/^$1=//p" "$2" | tail -1; }

# One boot of the target through its own config.txt: the boot order for the
# next reboot only (Pi 5 firmware: "set_reboot_order", mailbox tag 0x0003808b,
# https://www.raspberrypi.com/documentation/computers/config_txt.html#set_reboot_order).
# The target's device first, then the SD card, so a failure there lands back
# here on the next reset.
do_reboot_target() {
  local b env target order
  [[ $(id -u) == 0 ]] || die "run as root"
  in_vyos && die "run this on the old OS"
  b=$(find_boot_dir)
  env=$b/$PREFIX/trial.env
  [[ -f $env ]] || die "no trial set up on $b"
  target=$(env_get TARGET "$env")
  [[ -b $target ]] || die "$target (the trial's target) is not here"
  command -v vcmailbox >/dev/null || die "needs vcmailbox (Ubuntu: libraspberrypi-bin; Pi OS: raspi-utils)"
  case "$target" in /dev/nvme*) order=0xf416 ;; *) order=0xf614 ;; esac
  say "next boot only: BOOT_ORDER=$order (the target first); any later reset boots from here again"
  vcmailbox 0x0003808b 4 4 "$order" >/dev/null || die "vcmailbox failed"
  sync
  reboot
}

# The trial's boot partition: from the kernel command line (in VyOS), or --boot.
# Sets B (not a $(...) subshell: the mount must be undone by this shell).
open_trial_boot() {
  local id="" dev
  if [[ -n $boot_dir ]]; then B=$boot_dir; return; fi
  for a in $(cat /proc/cmdline); do
    case "$a" in vyos-pi.trial=PARTUUID=*) id=${a#vyos-pi.trial=PARTUUID=} ;; esac
  done
  if [[ -z $id ]]; then
    if ! in_vyos; then B=$(find_boot_dir); return; fi
    # VyOS started from the target itself (--reboot-target): the installer
    # left trial.env on the target's FAT partition
    local esp
    esp=$(bash -c '. /usr/libexec/vyos-pi/common.sh; find_esp' 2>/dev/null)
    if [[ -n $esp ]]; then
      mkdir -p "$tmp/esp"
      if mount -t vfat -o ro "$esp" "$tmp/esp" 2>/dev/null; then
        id=$(env_get BOOT_PARTUUID "$tmp/esp/vyos-pi/trial.env" 2>/dev/null)
        umount "$tmp/esp"
      fi
    fi
    [[ -n $id ]] || die "no vyos-pi.trial= on the kernel command line and no vyos-pi/trial.env on this disk's FAT partition; give the card's boot partition with --boot DIR"
  fi
  dev=/dev/disk/by-partuuid/$id
  [[ -b $dev ]] || die "the trial's boot partition (PARTUUID=$id) is not here"
  mkdir -p "$tmp/boot"
  mount -t vfat -o rw,noatime "$dev" "$tmp/boot" || die "cannot mount $dev"
  mounts+=("$tmp/boot")
  B=$tmp/boot
}

# The target's FAT partition: by PARTUUID from trial.env, mounted.
open_target_esp() {
  local id=$1 dev
  dev=/dev/disk/by-partuuid/$id
  [[ -b $dev ]] || return 1
  T_MODE=dev T_DIR=$tmp/target
  mkdir -p "$T_DIR"
  if findmnt -no TARGET "$dev" >/dev/null 2>&1; then
    T_DIR=$(findmnt -no TARGET "$dev" | head -1)
    T_MODE=dev-mounted
    return 0
  fi
  mount -t vfat -o rw,noatime "$dev" "$T_DIR" || return 1
  mounts+=("$T_DIR")
}


do_commit() {
  local b env
  [[ $(id -u) == 0 ]] || die "run as root (sudo)"
  open_trial_boot; b=$B
  env=$b/$PREFIX/trial.env
  [[ -f $env ]] || die "no $PREFIX/trial.env on $b: not a vyos-pi trial boot partition"
  if in_vyos && (( ! force )); then
    [[ $(dt_u32 tryboot) == 1 ]] || warn "this boot is not a tryboot (the firmware's flag is not set)"
  fi
  [[ -f $b/config.txt ]] || die "$b/config.txt is already gone (committed?)"
  # The target must boot on its own: its config.txt, and the overlays the
  # trial used (images up to 2026.11.16-1 lack them: D0 boards need bcm2712d0).
  local esp
  esp=$(env_get TARGET_ESP_PARTUUID "$env")
  [[ -n $esp ]] && open_target_esp "$esp" || die "cannot open the target's FAT partition (PARTUUID=$esp); not committing"
  [[ -f $T_DIR/config.txt && -f $T_DIR/vyos-pi/boot/Image && -f $T_DIR/cmdline.txt ]] \
    || die "the target's FAT partition lacks config.txt, cmdline.txt or vyos-pi/boot/Image; not committing"
  local ov
  for ov in "$b/$PREFIX/overlays/"*.dtbo; do
    [[ -f $ov ]] || continue
    if [[ ! -f $T_DIR/overlays/${ov##*/} ]]; then
      mkdir -p "$T_DIR/overlays"
      cp "$ov" "$T_DIR/overlays/"
      say "copied overlays/${ov##*/} to the target (its image predates it)"
    fi
  done
  sync
  say "making VyOS the default: the bootloader will find no config.txt on $b and go on to the next BOOT_ORDER device"
  mv "$b/config.txt" "$b/config.txt.vyos-pi-committed"
  if grep -q "^$MARK" "$b/tryboot.txt" 2>/dev/null; then rm -f "$b/tryboot.txt"; fi
  if [[ -f $b/tryboot.txt ]]; then mv "$b/tryboot.txt" "$b/tryboot.txt.vyos-pi-committed"; fi
  sed -i 's/^STATE=.*/STATE=committed/' "$env"
  if [[ -f $T_DIR/vyos-pi/trial-armed ]]; then
    rm -f "$T_DIR/vyos-pi/reboot-after-minutes" "$T_DIR/vyos-pi/trial-armed"
    say "removed the trial's reboot-after-minutes timer from the target"
  fi
  sync
  echo
  echo "Committed. The next boot skips $b (config.txt is now config.txt.vyos-pi-committed)"
  echo "and starts VyOS from $(env_get TARGET "$env"), if BOOT_ORDER has that device after the"
  echo "SD card (0xf461: SD, NVMe, USB). To go back: $PROG --uncommit, or rename"
  echo "config.txt.vyos-pi-committed to config.txt on the card from any computer."
}

do_uncommit() {
  local b
  [[ $(id -u) == 0 ]] || die "run as root (sudo)"
  open_trial_boot; b=$B
  [[ -f $b/config.txt.vyos-pi-committed ]] || die "nothing to undo on $b"
  mv "$b/config.txt.vyos-pi-committed" "$b/config.txt"
  [[ -f $b/tryboot.txt.vyos-pi-committed ]] && mv "$b/tryboot.txt.vyos-pi-committed" "$b/tryboot.txt"
  [[ -f $b/$PREFIX/trial.env ]] && sed -i 's/^STATE=.*/STATE=uncommitted/' "$b/$PREFIX/trial.env"
  sync
  say "config.txt restored on $b: the next boot starts the OS installed there again"
}

do_cancel() {
  local b
  b=$(find_boot_dir)
  if grep -q "^$MARK" "$b/tryboot.txt" 2>/dev/null; then
    rm -f "$b/tryboot.txt"
    say "removed $b/tryboot.txt"
  fi
  if [[ -f $b/$PREFIX/tryboot.txt.orig ]]; then
    mv "$b/$PREFIX/tryboot.txt.orig" "$b/tryboot.txt"
    say "restored the previous tryboot.txt"
  fi
  rm -f "$b/$PREFIX"/Image "$b/$PREFIX"/initrd.img "$b/$PREFIX"/*.dtb
  [[ -f $b/$PREFIX/trial.env ]] && sed -i 's/^STATE=.*/STATE=cancelled/' "$b/$PREFIX/trial.env"
  sync
  say "trial removed (the boot logs stay in $b/$PREFIX/boot-log)"
}

do_status() {
  local b env tb
  b=$(find_boot_dir)
  env=$b/$PREFIX/trial.env
  tb=$(dt_u32 tryboot)
  echo "boot partition: $b"
  echo "this boot: tryboot=${tb:-?} partition=$(dt_u32 partition) boot-mode=$(dt_u32 boot-mode)"
  local order; order=$(boot_order || true)
  [[ -n $order ]] && echo "BOOT_ORDER=$order"
  if grep -q "^$MARK" "$b/tryboot.txt" 2>/dev/null; then
    echo "trial: armed ($(head -1 "$b/tryboot.txt" | sed "s/^$MARK: //"))"
  elif [[ -f $b/config.txt.vyos-pi-committed ]]; then
    echo "trial: committed (config.txt renamed; VyOS boots from the target)"
  else
    echo "trial: not armed"
  fi
  [[ -f $env ]] && sed 's/^/  /' "$env"
  if [[ -d $b/$PREFIX/boot-log ]]; then
    echo "boot logs ($b/$PREFIX/boot-log):"
    ls -1tr "$b/$PREFIX/boot-log" | grep -v '^last$' | tail -12 | sed 's/^/  /'
    local last
    last=$(ls -1t "$b/$PREFIX/boot-log"/*-*.txt 2>/dev/null | head -1)
    if [[ -n $last ]]; then
      echo "latest: ${last##*/}"
      grep -m3 -E 'stage|tryboot|cmdline' "$last" | sed 's/^/  /'
      echo "  ... (last kernel lines)"
      tail -15 "$last" | sed 's/^/  /'
    fi
  fi
}

case "$action" in
  install) do_install ;;
  reboot) do_tryboot ;;
  reboot-target) do_reboot_target ;;
  status) do_status ;;
  cancel) do_cancel ;;
  commit) do_commit ;;
  uncommit) do_uncommit ;;
esac
