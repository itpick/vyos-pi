#!/usr/bin/env bash
# VyOS arm64 test VM on QEMU "virt", shaped like a Raspberry Pi.
# Shape only: under TCG on an x86 host, CPU speed is not comparable, and the
# NICs are virtio rather than the Pi's GENET / RP1 GEM / USB.
#
#   vm/run.sh [--pi5|--pi4] [--headless] [--reset] [--direct] --image FILE
#     --pi5         Pi 5 16GB: 4x Cortex-A76, 16 GiB (default)
#     --pi4         Pi 4 8GB:  4x Cortex-A72, 8 GiB. A real BCM2711 lacks the
#                   ARMv8 crypto extensions; QEMU's cortex-a72 still exposes AES/SHA.
#     --headless    run in the background; console on <vmdir>/console.sock
#     --reset       discard the profile's overlay and start from the base image
#     --direct      boot the way a Pi 5 does: no UEFI or GRUB; QEMU loads the
#                   kernel, initrd and cmdline.txt from the image's FAT
#                   partition (vyos-pi/boot/), as the Pi 5 firmware would
#                   (with QEMU's device tree, and console ttyAMA0 for ttyAMA10)
#     --image FILE  base image (raw or qcow2): out/vyos-pi-<board>.img
#
# Each profile has its own overlay disk and ports, so both can run at once.
# VM dir: $VYOS_PI_VM_DIR/<profile> (default .work/vm/<profile>).
# NICs (virtio, in PCI order, so eth0/eth1/eth2 unless names are pinned):
#   WAN   52:54:00:57:41:0N  QEMU user-mode NAT (DHCP 10.0.2.15, gateway and host 10.0.2.2)
#   LAN   52:54:00:4c:41:0N  an empty L2 segment: a TCP socket on 127.0.0.1:<lan port>
#                            that vm/client.sh plugs a LAN client into
#   MGMT  52:54:00:4d:47:0N  QEMU user-mode NAT 10.0.3.0/24 (DHCP 10.0.3.15),
#                            ssh forwarded from the host
# Host ports (pi5 / pi4):
#   ssh       ssh -p 2322 / -p 2323 vyos@127.0.0.1 (MGMT, once SSH is configured)
#   LAN wire  127.0.0.1:2342 / :2343
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)

profile=pi5 headless=0 reset=0 direct=0 base=""
while (( $# )); do
  case "$1" in
    --pi5) profile=pi5 ;;
    --pi4) profile=pi4 ;;
    --reset) reset=1 ;;
    --headless) headless=1 ;;
    --direct) direct=1 ;;
    --image) base=$(realpath "$2"); shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$base" ]] || base=$root/out/vyos-pi-$profile.img
[[ -f "$base" ]] || { echo "no image $base (make image BOARD=$profile)" >&2; exit 1; }

case "$profile" in
  pi5) cpu=cortex-a76 mem=16384 ssh=2322 lan=2342 mac=01 ;;
  pi4) cpu=cortex-a72 mem=8192 ssh=2323 lan=2343 mac=02 ;;
esac
fmt=$(qemu-img info --output=json "$base" | python3 -c 'import json,sys; print(json.load(sys.stdin)["format"])')

QEMU_SHARE="$(dirname "$(dirname "$(readlink -f "$(command -v qemu-system-aarch64)")")")/share/qemu"
fw="$QEMU_SHARE/edk2-aarch64-code.fd"
[[ -f "$fw" ]] || fw=/usr/share/qemu-efi-aarch64/QEMU_EFI.fd   # Debian/Ubuntu qemu-efi-aarch64

dir="${VYOS_PI_VM_DIR:-$root/.work/vm}/$profile"
mkdir -p "$dir"
cd "$dir"
if [[ -f qemu.pid ]] && kill -0 "$(cat qemu.pid)" 2>/dev/null; then
  echo "$profile VM already running (pid $(cat qemu.pid)); stop it first: kill \$(cat $dir/qemu.pid)" >&2
  exit 1
fi
DISK=vyos.qcow2
# A new base image means a new overlay.
if [[ -f "$DISK" ]] && [[ "$(cat base 2>/dev/null)" != "$base" ]]; then reset=1; fi
(( reset )) && rm -f "$DISK"
if [[ ! -f "$DISK" ]]; then
  qemu-img create -q -f qcow2 -b "$base" -F "$fmt" "$DISK" 32G
  echo "$base" >base
fi

boot=(-bios "$fw")
if (( direct )); then
  # What the Pi 5 firmware reads, from the FAT partition of the current disk.
  # The GPT and the 256 MiB ESP sit in the first 300 MiB.
  qemu-img dd -f qcow2 -O raw bs=1M count=300 if="$DISK" of=disk.raw.tmp
  # partition 1's start, from the primary GPT (the backup is not in the copy)
  off=$(python3 -c '
import struct, sys
d = open(sys.argv[1], "rb").read(64 * 1024)
assert d[512:520] == b"EFI PART", "no GPT"
lba = struct.unpack_from("<Q", d, 512 + 72)[0]
print(struct.unpack_from("<Q", d, lba * 512 + 32)[0] * 512)' disk.raw.tmp)
  rm -f Image initrd.img cmdline.txt
  for f in vyos-pi/boot/Image vyos-pi/boot/initrd.img cmdline.txt; do
    MTOOLS_SKIP_CHECK=1 mcopy -n -i "disk.raw.tmp@@$off" "::/$f" "${f##*/}"
  done
  rm -f disk.raw.tmp
  cmdline=$(tr -d '\n' < cmdline.txt | sed 's/console=ttyAMA10/console=ttyAMA0/')
  echo "direct boot: $cmdline"
  boot=(-kernel Image -initrd initrd.img -append "$cmdline")
fi

# shellcheck disable=SC2054 # commas are QEMU option syntax
args=(
  -name "vyos-$profile"
  -machine virt -cpu "$cpu" -smp 4 -m "$mem"
  -accel tcg,thread=multi,tb-size=512
  "${boot[@]}"
  -drive if=virtio,file="$DISK",cache=writeback,discard=unmap
  -netdev user,id=wan
  -device "virtio-net-pci,netdev=wan,mac=52:54:00:57:41:$mac"
  -netdev "stream,id=lan,server=on,addr.type=inet,addr.host=127.0.0.1,addr.port=$lan"
  -device "virtio-net-pci,netdev=lan,mac=52:54:00:4c:41:$mac"
  -netdev "user,id=mgmt,net=10.0.3.0/24,hostfwd=tcp:127.0.0.1:$ssh-10.0.3.15:22"
  -device "virtio-net-pci,netdev=mgmt,mac=52:54:00:4d:47:$mac"
  -device virtio-rng-pci
  -display none
)

if (( headless )); then
  rm -f console.sock monitor.sock
  # console.log keeps the whole serial transcript for debugging.
  exec qemu-system-aarch64 "${args[@]}" \
    -chardev socket,id=ser0,path=console.sock,server=on,wait=off,logfile=console.log,logappend=on \
    -serial chardev:ser0 \
    -monitor unix:monitor.sock,server=on,wait=off \
    -daemonize -pidfile qemu.pid
else
  exec qemu-system-aarch64 "${args[@]}" -serial mon:stdio
fi
