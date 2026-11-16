#!/usr/bin/env bash
# End-to-end VM tests of a built image (out/vyos-pi-<board>.img).
#
#   vm/test.sh image   [pi5|pi4]  seed a config.boot through the FAT partition
#                                 (hostname, SSH key, WAN/LAN/MGMT with the
#                                 names swapped against PCI order by hw-id),
#                                 boot, and check over SSH: the seed was
#                                 applied, NICs are named by MAC, the root
#                                 grew to fill the disk, show version reports
#                                 vyos-pi and the Pi kernel, the Pi drivers and
#                                 the rebuilt out-of-tree modules load; then a
#                                 LAN client (vm/client.sh) gets a DHCP lease,
#                                 resolves through the DNS forwarder and
#                                 fetches a page from the WAN side through
#                                 source NAT (seen in conntrack). pi5: the
#                                 direct-boot files on the FAT partition match
#                                 the running image.
#   vm/test.sh trial   [pi5|pi4]  reboot-after-minutes=3: it reboots by itself,
#                                 with diagnostics saved to the FAT partition
#   vm/test.sh direct  [pi5]      after "image": boot the same disk the way a
#                                 Pi 5 does (kernel, initrd and cmdline.txt from
#                                 the FAT partition, no UEFI or GRUB) and check
#                                 VyOS comes up with its config
#   vm/test.sh upgrade [pi5|pi4] ISO
#                                 after "image": "add system image" another
#                                 vyos-pi ISO (a different version), reboot into
#                                 it with the config kept; pi5: the FAT
#                                 partition follows (vyos-pi-bootsync at
#                                 shutdown), then a direct boot starts the new
#                                 image too
#
# "image" starts from a clean overlay; the others reuse it (direct, upgrade)
# or make their own (trial). Each stops its VMs at the end.
set -euo pipefail
# shellcheck disable=SC2016 # remote commands are single-quoted on purpose
root=$(cd "$(dirname "$0")/.." && pwd)
test=${1:-} profile=${2:-pi5}
case "$profile" in pi5) ssh=2322 mac=01 ;; pi4) ssh=2323 mac=02 ;; *) echo "bad profile: $profile" >&2; exit 2 ;; esac
dir="${VYOS_PI_VM_DIR:-$root/.work/vm}/$profile"
img_src=$root/out/vyos-pi-$profile.img
WAN_MAC=52:54:00:57:41:$mac LAN_MAC=52:54:00:4c:41:$mac MGMT_MAC=52:54:00:4d:47:$mac CLIENT_MAC=52:54:00:c1:1e:$mac
mkdir -p "$dir"

stop() {
  [[ -f "$dir/qemu.pid" ]] && kill "$(cat "$dir/qemu.pid")" 2>/dev/null || true
  "$root/vm/client.sh" "$profile" stop 2>/dev/null || true
  [[ -n "${http_pid:-}" ]] && kill "$http_pid" 2>/dev/null || true
  sleep 2
}
ok() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; [[ -f "$dir/console.log" ]] && tail -c 3000 "$dir/console.log" | tr -d '\r' >&2; stop; exit 1; }

# Run a shell script as vyos over SSH (MGMT port). vsh 'cmd' / op 'show ...'
vsh() {
  ssh -q -i "$dir/id_test" -p "$ssh" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 vyos@127.0.0.1 /bin/bash -s <<<"$1"
}
op() { vsh "/bin/vbash -c 'source /opt/vyatta/etc/functions/script-template; run $1'"; }
wait_ssh() {
  local n=${1:-240}
  for _ in $(seq "$n"); do vsh true 2>/dev/null && return 0; sleep 5; done
  return 1
}
# Wait for VyOS to finish loading its config: vyos-router's start script has
# exited (Type=simple + RemainAfterExit: SubState goes running -> exited).
wait_ready() {
  for _ in $(seq 180); do
    [[ "$(vsh 'systemctl show -p SubState --value vyos-router' 2>/dev/null)" == exited ]] && return 0
    sleep 5
  done
  return 1
}

# A copy of the image with files added to the FAT partition's vyos-pi/:
# test_image NAME=FILE...
test_image() {
  local t="$dir/test.img" off
  if [[ ! -f "$img_src" ]]; then
    [[ -f "$img_src.xz" ]] || fail "missing $img_src(.xz) (make image BOARD=$profile)"
    xz -dkc "$img_src.xz" >"$img_src"
  fi
  cp --sparse=always "$img_src" "$t"
  off=$(sfdisk -J "$t" | python3 -c 'import json,sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][0]["start"] * 512)')
  for kv in "$@"; do
    MTOOLS_SKIP_CHECK=1 mcopy -o -i "$t@@$off" "${kv#*=}" "::/vyos-pi/${kv%%=*}"
  done
  echo "$t"
}

# Seed config: hostname, SSH key, and the NICs named against their PCI order
# (vm/run.sh: WAN, LAN, MGMT), so the LAN only serves DHCP on the LAN wire if
# names follow the hw-ids: eth0 = LAN, eth1 = WAN, eth2 = MGMT.
seed() {
  [[ -f "$dir/id_test" ]] || ssh-keygen -q -t ed25519 -N '' -C vyos-pi-test -f "$dir/id_test"
  python3 "$root/scripts/seed-config.py" "$root/out/vyos-pi.config.boot.default" "$dir/config.boot" \
    --hostname vyos-pi-test --ssh-key "$dir/id_test.pub" \
    --lan "eth0=$LAN_MAC" --wan "eth1=$WAN_MAC" --mgmt "eth2=$MGMT_MAC"
}

# LAN client console: client_sh TIMEOUT 'command' (logs in first)
C() { python3 -I "$root/vm/console.py" "$dir/client.sock" "$@"; }
client_login() {
  for _ in $(seq 60); do
    case "$(tail -c 200 "$dir/client.log" 2>/dev/null | tr -d '\r')" in
      *"login: ") C 20 'Password: ' cirros >/dev/null || true ;;
      *"Password: ") C 30 '\$ $' gocubsgo >/dev/null || true ;;
      *'$ ') return 0 ;;
      *) C 5 'login: $' '' >/dev/null || true; sleep 5 ;;
    esac
  done
  return 1
}
client_sh() { C "$1" '__END__\r?\n.*\$ ' "$2; echo __EN''D__" | tr -d '\r' | sed -n '1d; /^__END__$/q; p'; }

boot_seeded() {
  seed
  local img
  img=$(test_image "config.boot=$dir/config.boot" "$@")
  "$root/vm/run.sh" "--$profile" --headless --reset --image "$img"
  wait_ssh || fail "SSH with the seeded key never worked (seed not applied, or MGMT not eth2?)"
}

stop
case "$test" in
  image)
    boot_seeded
    ok "SSH as vyos with the key from the seeded config.boot (MGMT port)"
    wait_ready || fail "vyos-router never became active"
    [[ "$(vsh hostname)" == vyos-pi-test ]] || fail "hostname is $(vsh hostname), not the seeded one"
    ok "seeded hostname"
    vsh 'grep -q "installed config.boot" /var/log/vyos-pi.log' || fail "boot hook did not log the seed"
    ok "boot hook installed config.boot from the FAT partition"
    for pair in "eth0 $LAN_MAC" "eth1 $WAN_MAC" "eth2 $MGMT_MAC"; do
      read -r ifname want <<<"$pair"
      have=$(vsh "cat /sys/class/net/$ifname/address")
      [[ "$have" == "$want" ]] || fail "$ifname has MAC $have, expected $want (names not pinned by hw-id)"
    done
    vsh 'cat /opt/vyatta/etc/config/interface-mapping.json'
    ok "NIC names follow the seeded hw-ids (eth0=LAN, eth1=WAN, eth2=MGMT; PCI order is WAN, LAN, MGMT)"
    vsh 'grep "grow" /var/log/vyos-pi.log'
    size=$(vsh 'df -B1G --output=size "$(/opt/vyatta/sbin/vyos-persistpath)" | tail -1' | tr -d ' ')
    (( size >= 28 )) || fail "root filesystem is ${size} GiB; it should have grown to fill the 32 GiB disk"
    ok "root partition and filesystem grew to fill the disk (${size} GiB)"
    ver=$(op 'show version')
    echo "$ver"
    grep -q '^Version: *vyos-pi ' <<<"$ver" || fail "show version does not say vyos-pi"
    grep -q 'Release flavor: *raspberrypi' <<<"$ver" || fail "show version: flavor is not raspberrypi"
    grep -q 'Build comment: *vyos-pi .*Raspberry Pi' <<<"$ver" || fail "show version: no vyos-pi build comment"
    op 'show version kernel'
    vsh 'grep -E "^CONFIG_(MISC_RP1|MACB|BCMGENET|MMC_SDHCI_BRCMSTB|MMC_SDHCI_IPROC|BCM2712_MIP)=" /boot/config-$(uname -r)' | tee "$dir/kconfig.txt"
    [[ $(wc -l <"$dir/kconfig.txt") -eq 6 ]] || fail "running kernel lacks the Raspberry Pi options"
    ok "show version reports vyos-pi (flavor raspberrypi), running the Pi kernel ($(vsh 'uname -r'))"
    vsh 'sudo modprobe macb && sudo modprobe bcmgenet && sudo modprobe ipt_NETFLOW && sudo modprobe jool && lsmod | grep -E "^(macb|genet|bcmgenet|ipt_NETFLOW|jool) "' \
      || fail "Pi Ethernet drivers or the rebuilt out-of-tree modules do not load (signature/symbol mismatch?)"
    ok "Pi Ethernet drivers (macb, bcmgenet) and rebuilt out-of-tree modules (ipt_NETFLOW, jool) load"
    vsh 'systemctl is-active getty@tty1' || fail "no login prompt on tty1 (HDMI)"
    ok "login prompt on tty1 (what HDMI shows)"
    if [[ $profile == pi5 ]]; then
      vsh 'sudo /usr/libexec/vyos-pi/vyos-pi-bootsync --check' || fail "Pi 5 boot files on the FAT partition do not match the running image"
      ok "Pi 5 direct-boot files on the FAT partition match the running image"
    fi

    # LAN client: DHCP, DNS, NAT
    "$root/vm/client.sh" "$profile"
    client_login || fail "LAN client never reached a shell"
    lease=
    for _ in $(seq 30); do
      lease=$(client_sh 20 "ip -4 -o addr show eth0 | awk '{print \$4}'" | grep -oE '^192\.168\.1\.[0-9]+' || true)
      [[ -n "$lease" ]] && break
      client_sh 60 'sudo ifdown eth0 >/dev/null 2>&1; sudo ifup eth0 >/dev/null 2>&1' >/dev/null || true
    done
    [[ -n "$lease" ]] || fail "LAN client got no 192.168.1.x lease"
    op 'show dhcp server leases' | tee "$dir/leases.txt"
    grep -qi "$CLIENT_MAC" "$dir/leases.txt" || fail "lease for $CLIENT_MAC not in show dhcp server leases"
    ok "LAN client ($CLIENT_MAC) got $lease from VyOS's DHCP server"
    client_sh 60 'nslookup example.com 192.168.1.1' | tee "$dir/nslookup.txt"
    grep -qE 'Address( 1)?: *[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' <(grep -v '192.168.1.1' "$dir/nslookup.txt") \
      || fail "LAN client could not resolve example.com through the DNS forwarder"
    ok "LAN client resolves names through VyOS's DNS forwarder"
    # A web server on the host, reached through slirp's 10.0.2.2 on the WAN side.
    token=vyos-pi-nat-$RANDOM$RANDOM
    mkdir -p "$dir/www" && echo "$token" >"$dir/www/token"
    port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
    python3 -m http.server "$port" --bind 127.0.0.1 --directory "$dir/www" >"$dir/http.log" 2>&1 &
    http_pid=$!
    sleep 2
    got=$(client_sh 60 "wget -q -O - http://10.0.2.2:$port/token")
    [[ "$got" == *"$token"* ]] || fail "LAN client could not fetch a page from the WAN side (got: $got)"
    ct=$(vsh "sudo conntrack -L -p tcp --dport $port 2>/dev/null")
    echo "$ct"
    grep -q "src=$lease dst=10.0.2.2 .*src=10.0.2.2 dst=10.0.2.15" <<<"$ct" \
      || fail "conntrack shows no source NAT of $lease to the WAN address 10.0.2.15"
    ok "LAN client reaches the WAN side through source NAT ($lease -> 10.0.2.15)"
    vsh 'head -40 /usr/share/vyos-pi/manifest.txt'
    ;;
  trial)
    echo 3 >"$dir/reboot-after-minutes"
    boot_seeded "reboot-after-minutes=$dir/reboot-after-minutes"
    vsh 'grep -q "rebooting in 3 minutes" /var/log/vyos-pi.log' || fail "boot hook did not schedule the reboot"
    ok "reboot scheduled"
    for _ in $(seq 180); do
      [[ "$(vsh 'grep -c "rebooting in 3 minutes" /var/log/vyos-pi.log' 2>/dev/null || true)" -ge 2 ]] && break
      sleep 10
    done
    [[ "$(vsh 'grep -c "rebooting in 3 minutes" /var/log/vyos-pi.log')" -ge 2 ]] || fail "it never rebooted by itself"
    vsh 'grep "reboot-after-minutes" /var/log/vyos-pi.log'
    ok "rebooted by itself and scheduled the next one"
    vsh 'sudo bash -c ". /usr/libexec/vyos-pi/common.sh; mount_esp; d=\$ESP_MNT/vyos-pi; ls -l \$d; grep -q \"stage boot\" \$d/diag-boot.txt && grep -q \"stage reboot\" \$d/diag-reboot.txt && grep -q \"^### ip addr\" \$d/diag-reboot.txt; r=\$?; umount_esp; exit \$r"' \
      || fail "diagnostics snapshots missing from the FAT partition"
    ok "diagnostics saved to the FAT partition (diag-boot.txt, diag-reboot.txt)"
    ;;
  direct)
    [[ $profile == pi5 ]] || fail "direct boot is the Pi 5 path"
    [[ -f "$dir/vyos.qcow2" ]] || fail "run vm/test.sh image pi5 first"
    "$root/vm/run.sh" --pi5 --headless --direct --image "$(cat "$dir/base")"
    wait_ssh || fail "direct boot (kernel+initrd+cmdline.txt from the FAT partition) never came up"
    wait_ready || fail "vyos-router never became active"
    cmd=$(vsh 'cat /proc/cmdline')
    echo "$cmd"
    [[ "$cmd" == *vyos-union=/boot/* && "$cmd" == BOOT_IMAGE=/boot/* ]] || fail "unexpected kernel command line"
    [[ "$(vsh hostname)" == vyos-pi-test ]] || fail "config not loaded on direct boot"
    vsh 'test ! -d /sys/firmware/efi' || fail "booted through UEFI, not directly"
    op 'show system image'
    ok "direct boot (no UEFI/GRUB) from the FAT partition's kernel, initrd and cmdline.txt: config loaded, $(vsh 'uname -r')"
    ;;
  upgrade)
    iso=${3:-}
    [[ -f "$iso" ]] || fail "usage: vm/test.sh upgrade $profile ISO (another vyos-pi ISO, a different version)"
    [[ -f "$dir/vyos.qcow2" ]] || fail "run vm/test.sh image $profile first"
    "$root/vm/run.sh" "--$profile" --headless --image "$(cat "$dir/base")"
    wait_ssh || fail "SSH never worked"
    wait_ready || fail "vyos-router never became active"
    before=$(vsh 'cat /proc/cmdline' | grep -oE 'vyos-union=/boot/[^ ]+' | cut -d/ -f3)
    mkdir -p "$dir/www"
    ln -sf "$(realpath "$iso")" "$dir/www/upgrade.iso"
    port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
    python3 -m http.server "$port" --bind 127.0.0.1 --directory "$dir/www" >"$dir/http.log" 2>&1 &
    http_pid=$!
    sleep 2
    vsh "sudo /usr/libexec/vyos/op_mode/image_installer.py --action add --no-prompt --image-path http://10.0.2.2:$port/upgrade.iso" \
      | tr '\r' '\n' | grep -v '^\s*$' | tail -15 || fail "add system image failed"
    op 'show system image'
    new=$(vsh 'python3 -c "from vyos.system import image; print(image.get_default_image())"')
    [[ -n "$new" && "$new" != "$before" ]] || fail "default image is still $before"
    ok "add system image: $new installed and set as default (was $before)"
    vsh 'sudo systemctl reboot' || true
    sleep 30
    wait_ssh || fail "never came back after the reboot into $new"
    wait_ready || fail "vyos-router never became active after the upgrade"
    running=$(vsh 'cat /proc/cmdline' | grep -oE 'vyos-union=/boot/[^ ]+' | cut -d/ -f3)
    [[ "$running" == "$new" ]] || fail "running $running after the reboot, expected $new"
    [[ "$(vsh hostname)" == vyos-pi-test ]] || fail "config not carried over to $new"
    ok "rebooted into $new with the config carried over"
    if [[ $profile == pi5 ]]; then
      vsh 'grep "bootsync" /var/log/vyos-pi.log | tail -3'
      vsh "sudo /usr/libexec/vyos-pi/vyos-pi-bootsync --check" || fail "FAT partition boot files do not match $new"
      ok "vyos-pi-bootsync moved the Pi 5 boot files to $new"
      stop
      "$root/vm/run.sh" --pi5 --headless --direct --image "$(cat "$dir/base")"
      wait_ssh || fail "direct boot after the upgrade never came up"
      running=$(vsh 'cat /proc/cmdline' | grep -oE 'vyos-union=/boot/[^ ]+' | cut -d/ -f3)
      [[ "$running" == "$new" ]] || fail "direct boot started $running, expected $new"
      ok "direct boot (as on a Pi 5) starts the upgraded image $new"
    fi
    ;;
  *) echo "usage: $0 image|trial|direct|upgrade [pi5|pi4] [ISO]" >&2; exit 2 ;;
esac
stop
