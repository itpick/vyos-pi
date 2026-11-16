#!/usr/bin/env bash
# A LAN client for the test VM: Alpine Linux's virt ISO (x86_64, KVM when
# available), its only NIC plugged into the VyOS VM's LAN segment
# (vm/run.sh). It boots to a root login prompt; vm/test.sh asks for the
# DHCP lease itself (udhcpc), so the test sees it happen.
#
#   vm/client.sh [pi5|pi4] [stop]
#
# Console: <vmdir>/client.sock (log in as root, no password), transcript in
# client.log. Start it after the VyOS VM, which listens on the LAN socket.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=versions.env
source "$root/versions.env"
profile=${1:-pi5}
case "$profile" in pi5) lan=2342 mac=01 ;; pi4) lan=2343 mac=02 ;; *) echo "bad profile: $profile" >&2; exit 2 ;; esac
dir="${VYOS_PI_VM_DIR:-$root/.work/vm}/$profile"
mkdir -p "$dir" "$root/.work/cache"
cd "$dir"
if [[ -f client.pid ]] && kill -0 "$(cat client.pid)" 2>/dev/null; then
  kill "$(cat client.pid)"; sleep 1
fi
[[ "${2:-}" == stop ]] && exit 0
iso=$root/.work/cache/${CLIENT_ISO_URL##*/}
if [[ ! -f "$iso" ]]; then
  curl -fSL --retry 3 -o "$iso.part" "$CLIENT_ISO_URL" && mv "$iso.part" "$iso"
fi
echo "$CLIENT_ISO_SHA256  $iso" | sha256sum -c --quiet -
rm -f client.sock client.log
accel=tcg; [[ -w /dev/kvm ]] && accel=kvm
# shellcheck disable=SC2054
exec qemu-system-x86_64 -name "vyos-$profile-client" -machine q35 -accel "$accel" -m 512 -smp 1 \
  -cdrom "$iso" -boot d \
  -netdev "stream,id=lan,server=off,addr.type=inet,addr.host=127.0.0.1,addr.port=$lan" \
  -device "virtio-net-pci,netdev=lan,mac=52:54:00:c1:1e:$mac" \
  -display none \
  -chardev socket,id=ser0,path=client.sock,server=on,wait=off,logfile=client.log \
  -serial chardev:ser0 -daemonize -pidfile client.pid
