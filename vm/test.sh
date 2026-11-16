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
#   vm/test.sh trial   [pi5|pi4]  reboot-after-minutes=12: it reboots by itself,
#                                 with diagnostics saved to the FAT partition
#   vm/test.sh ids     [pi5|pi4]  Suricata: seed it on the WAN (eth1), fetch ET
#                                 Open ("update suricata"), and check an alert
#                                 (sid 2100498, the testmynids.org check) fires
#                                 for a page served from the WAN side; then
#                                 IPS mode (vyos-pi-suricata-mode ips, NFQUEUE)
#                                 with that sid made a drop rule: the LAN
#                                 client's fetch of the page is blocked while
#                                 other traffic still flows
#   vm/test.sh direct  [pi5]      after "image": boot the same disk the way a
#                                 Pi 5 does (kernel, initrd and cmdline.txt from
#                                 the FAT partition, no UEFI or GRUB) and check
#                                 VyOS comes up with its config
#   vm/test.sh trialboot [pi5]   scripts/pi-trial-install.sh against disk
#                                 images: writes the image to a "target" disk
#                                 and arms a trial on a fake SD card's FAT
#                                 (MBR, like Ubuntu's or Pi OS's); checks
#                                 tryboot.txt and vyos-pi-trial/; boots what
#                                 the firmware would boot in tryboot mode
#                                 (kernel, initrd, cmdline.txt from the SD's
#                                 vyos-pi-trial/, both disks attached): VyOS
#                                 comes up from the target, boot logs land on
#                                 the SD; then --commit from VyOS renames the
#                                 SD's config.txt and removes the trial timer,
#                                 and --uncommit puts config.txt back
#   vm/test.sh panic [pi5]       after trialboot: the trial's command line
#                                 with a root that does not exist reboots by
#                                 itself (panic=10) instead of waiting at an
#                                 initramfs shell, and leaves a boot log
#                                 (initramfs-panic) on the SD card
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
  local pid
  if [[ -f "$dir/qemu.pid" ]] && pid=$(cat "$dir/qemu.pid") && kill "$pid" 2>/dev/null; then
    for _ in $(seq 60); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  fi
  "$root/vm/client.sh" "$profile" stop 2>/dev/null || true
  [[ -n "${http_pid:-}" ]] && kill "$http_pid" 2>/dev/null || true
  sleep 2
}
ok() { echo "PASS: $*"; }
# KEEP=1: leave the VMs running after a failure, to look around
fail() {
  echo "FAIL: $*" >&2
  [[ -f "$dir/console.log" ]] && tail -c 3000 "$dir/console.log" | tr -d '\r' | sed 's/^/console: /' >&2
  [[ -n "${KEEP:-}" ]] || stop
  exit 1
}

# Run a shell script as vyos over SSH (MGMT port). vsh 'cmd' / op 'show ...'
vsh() {
  ssh -q -i "$dir/id_test" -p "$ssh" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 vyos@127.0.0.1 /bin/bash -s <<<"$1"
}
op() { vsh "/opt/vyatta/bin/vyatta-op-cmd-wrapper $1"; }
wait_ssh() {
  local n=${1:-240}
  for _ in $(seq "$n"); do vsh true 2>/dev/null && return 0; sleep 5; done
  return 1
}
# A web server on the host, reached through slirp's 10.0.2.2 on the WAN side.
# Serves $dir/www; sets $port and $http_pid.
www_up() {
  mkdir -p "$dir/www"
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  python3 -m http.server "$port" --bind 127.0.0.1 --directory "$dir/www" >"$dir/http.log" 2>&1 &
  http_pid=$!
  sleep 2
}
# Wait until a Suricata process other than $1 (suricata_mark: the running
# one's pid) has loaded its rules, asking it over its unix socket. (VyOS's
# Suricata logs to eve.json only, so there is no suricata.log to read.)
suricata_mark() { vsh 'cat /run/suricata/suricata.pid 2>/dev/null || echo none'; }
suricata_ready() {
  local pid
  for _ in $(seq 120); do
    pid=$(vsh 'cat /run/suricata/suricata.pid 2>/dev/null' || true)
    if [[ -n "$pid" && "$pid" != "$1" ]] &&
      vsh 'sudo suricatasc -c ruleset-stats /run/suricata/suricata.socket 2>/dev/null' | grep -qE '"rules_loaded": [1-9]'; then
      vsh 'sudo suricatasc -c ruleset-stats /run/suricata/suricata.socket'
      return 0
    fi
    sleep 5
  done
  vsh 'sudo journalctl -u suricata --no-pager | tail -20' >&2
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
    --lan "eth0=$LAN_MAC" --wan "eth1=$WAN_MAC" --mgmt "eth2=$MGMT_MAC" "${SEED_ARGS[@]}"
}
SEED_ARGS=()

# LAN client console: client_sh TIMEOUT 'command' (logs in first)
C() { python3 -I "$root/vm/console.py" "$dir/client.sock" "$@"; }
client_login() {
  for _ in $(seq 60); do
    case "$(tail -c 200 "$dir/client.log" 2>/dev/null | tr -d '\r' | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g')" in
      *"login: ") C 30 '# $' root >/dev/null || true ;;
      *'# ') return 0 ;;
      *) sleep 5 ;;
    esac
  done
  return 1
}
client_sh() { C "$1" '__END__\r?\n.*# ' "$2; echo __EN''D__" | tr -d '\r' | sed -n '1d; /^__END__$/q; p'; }

# Start the VM; if no kernel starts within 8 minutes, start it once more
# (QEMU's UEFI under TCG has been seen to spin forever before GRUB).
start_vm() {
  local n0 attempt
  for attempt in 1 2; do
    n0=$(grep -ac 'Booting Linux' "$dir/console.log" 2>/dev/null || true)
    "$root/vm/run.sh" "--$profile" --headless "$@"
    for _ in $(seq 96); do
      (( $(grep -ac 'Booting Linux' "$dir/console.log" 2>/dev/null || echo 0) > ${n0:-0} )) && return 0
      sleep 5
    done
    echo "W: no kernel within 8 minutes (attempt $attempt); restarting the VM"
    stop
  done
  return 1
}

boot_seeded() {
  seed
  local img
  img=$(test_image "config.boot=$dir/config.boot" "$@")
  start_vm --reset --image "$img" || fail "the VM never started a kernel"
  wait_ssh || fail "SSH with the seeded key never worked (seed not applied, or MGMT not eth2?)"
}

[[ -n "${REUSE_VM:-}" ]] || stop
case "$test" in
  image)
    # REUSE_VM=1: run the checks against the VM a previous run left up
    if [[ -n "${REUSE_VM:-}" ]]; then wait_ssh 2 || fail "REUSE_VM: no VM answers on ssh"; else boot_seeded; fi
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
    mods="macb genet ipt_NETFLOW jool nf_nat_rtsp ipoe vlan_mon"
    vsh "for m in $mods; do sudo modprobe \$m || exit 1; done; lsmod | grep -E '^(${mods// /|}) '" \
      || fail "Pi Ethernet drivers or the rebuilt out-of-tree modules do not load (signature/symbol mismatch?)"
    ok "Pi Ethernet drivers (macb, genet) and the rebuilt out-of-tree modules (ipt_NETFLOW, jool, nf_nat_rtsp, accel-ppp's ipoe/vlan_mon) load"
    vsh '! systemctl is-active -q suricata' || fail "Suricata runs without being configured (it should be off by default)"
    ok "Suricata installed ($(vsh 'suricata -V | grep -oE "[0-9]+\.[0-9.]+"')) and off by default"
    vsh 'systemctl is-active getty@tty1' || fail "no login prompt on tty1 (HDMI)"
    ok "login prompt on tty1 (what HDMI shows)"
    if [[ $profile == pi5 ]]; then
      # (after vyos-pi-bootsync.service's own run at boot)
      for _ in $(seq 30); do [[ "$(vsh 'systemctl show -p SubState --value vyos-pi-bootsync')" == exited ]] && break; sleep 5; done
      vsh 'sudo /usr/libexec/vyos-pi/vyos-pi-bootsync --check' || fail "Pi 5 boot files on the FAT partition do not match the running image"
      ok "Pi 5 direct-boot files on the FAT partition match the running image"
    fi

    # LAN client: DHCP, DNS, NAT
    "$root/vm/client.sh" "$profile"
    client_login || fail "LAN client never reached a shell"
    client_sh 90 'ip link set eth0 up; udhcpc -i eth0 -n -q -t 10' | tail -5
    lease=$(client_sh 20 "ip -4 -o addr show eth0 | awk '{print \$4}'" | grep -oE '^192\.168\.1\.[0-9]+' || true)
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
    www_up
    echo "$token" >"$dir/www/token"
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
    # Long enough for a boot under TCG (~7 minutes to a loaded config) plus the checks.
    echo 12 >"$dir/reboot-after-minutes"
    boot_seeded "reboot-after-minutes=$dir/reboot-after-minutes"
    vsh 'grep -q "rebooting in 12 minutes" /var/log/vyos-pi.log' || fail "boot hook did not schedule the reboot"
    ok "reboot scheduled"
    for _ in $(seq 180); do
      [[ "$(vsh 'grep -c "rebooting in 12 minutes" /var/log/vyos-pi.log' 2>/dev/null || true)" -ge 2 ]] && break
      sleep 10
    done
    [[ "$(vsh 'grep -c "rebooting in 12 minutes" /var/log/vyos-pi.log')" -ge 2 ]] || fail "it never rebooted by itself"
    vsh 'grep "reboot-after-minutes" /var/log/vyos-pi.log'
    ok "rebooted by itself and scheduled the next one"
    vsh 'sudo bash -c ". /usr/libexec/vyos-pi/common.sh; mount_esp; d=\$ESP_MNT/vyos-pi; ls -l \$d; grep -q \"stage boot\" \$d/diag-boot.txt && grep -q \"stage reboot\" \$d/diag-reboot.txt && grep -q \"^### ip addr\" \$d/diag-reboot.txt; r=\$?; umount_esp; exit \$r"' \
      || fail "diagnostics snapshots missing from the FAT partition"
    ok "diagnostics saved to the FAT partition (diag-boot.txt, diag-reboot.txt)"
    ;;
  ids)
    SEED_ARGS=(--ids eth1)
    boot_seeded
    wait_ready || fail "vyos-router never became active"
    vsh 'systemctl is-active suricata' || fail "service suricata configured, but suricata is not running"
    ok "Suricata $(vsh 'suricata -V | grep -oE "[0-9]+\.[0-9.]+"') runs on eth1 (af-packet, from the seeded service suricata)"
    m0=$(suricata_mark)
    op 'update suricata' 2>&1 | tail -5
    vsh 'test -s /var/lib/suricata/rules/suricata.rules' || vsh 'sudo /usr/libexec/vyos/op_mode/update_suricata.sh' 2>&1 | tail -5
    rules=$(vsh 'grep -c "^alert" /var/lib/suricata/rules/suricata.rules')
    vsh 'grep -q "sid:2100498;" /var/lib/suricata/rules/suricata.rules' || fail "update suricata did not fetch ET Open (sid 2100498 missing)"
    ok "update suricata fetched ET Open: $rules alert rules"
    suricata_ready "$m0" || fail "Suricata never finished loading the rules"
    # testmynids.org used to serve "uid=0(root) gid=0(root) groups=0(root)"
    # (the domain is parked now); the same page, served from the WAN side
    www_up
    mkdir -p "$dir/www/uid" && echo 'uid=0(root) gid=0(root) groups=0(root)' >"$dir/www/uid/index.html"
    echo ok >"$dir/www/ok.txt"
    vsh "curl -s http://10.0.2.2:$port/uid/index.html"
    for _ in $(seq 24); do
      vsh 'sudo grep -q "\"signature_id\":2100498" /var/log/suricata/eve.json' && break
      sleep 5
    done
    vsh 'sudo grep "\"signature_id\":2100498" /var/log/suricata/eve.json | tail -1' | tee "$dir/ids-alert.json"
    [[ -s "$dir/ids-alert.json" ]] || fail "no Suricata alert for the id check (sid 2100498)"
    ok "IDS: alert 2100498 \"GPL ATTACK_RESPONSE id check returned root\" in eve.json"

    # IPS: make that sid a drop rule, put Suricata on NFQUEUE
    vsh 'echo 2100498 | sudo tee /etc/suricata/drop.conf >/dev/null && sudo /usr/libexec/vyos/op_mode/update_suricata.sh >/dev/null 2>&1; grep -E "^drop .*sid:2100498;" /var/lib/suricata/rules/suricata.rules | cut -c1-90' \
      || fail "drop.conf did not turn sid 2100498 into a drop rule"
    m0=$(suricata_mark)
    vsh 'sudo /usr/libexec/vyos-pi/vyos-pi-suricata-mode ips'
    suricata_ready "$m0" || fail "Suricata (IPS) never finished loading"
    vsh 'sudo nft list table inet vyos_pi_ips' | tee "$dir/ips-nft.txt"
    grep -q 'queue .*num 0 bypass\|queue flags bypass to 0\|queue to 0 bypass\|bypass' "$dir/ips-nft.txt" || fail "no NFQUEUE rule in inet vyos_pi_ips"
    "$root/vm/client.sh" "$profile"
    client_login || fail "LAN client never reached a shell"
    client_sh 90 'ip link set eth0 up; udhcpc -i eth0 -n -q -t 10' | tail -1
    got=$(client_sh 60 "wget -q -T 10 -O - http://10.0.2.2:$port/ok.txt")
    [[ "$got" == *ok* ]] || fail "IPS mode: the LAN client cannot reach the WAN side at all (got: $got)"
    got=$(client_sh 60 "wget -q -T 15 -O - http://10.0.2.2:$port/uid/index.html; echo rc=\$?")
    echo "$got"
    [[ "$got" != *"uid=0(root)"* ]] || fail "IPS mode: the id check page reached the LAN client"
    for _ in $(seq 12); do
      vsh 'sudo grep "\"signature_id\":2100498" /var/log/suricata/eve.json | grep -q "\"action\":\"blocked\""' && break
      sleep 5
    done
    vsh 'sudo grep "\"signature_id\":2100498" /var/log/suricata/eve.json | grep "\"action\":\"blocked\"" | tail -1' | tee "$dir/ips-drop.json"
    [[ -s "$dir/ips-drop.json" ]] || fail "no blocked event for sid 2100498 in eve.json"
    ok "IPS: the LAN client's fetch of the id check page was dropped (eve.json action blocked); other traffic flows"
    ;;
  direct)
    [[ $profile == pi5 ]] || fail "direct boot is the Pi 5 path"
    [[ -f "$dir/vyos.qcow2" ]] || fail "run vm/test.sh image pi5 first"
    start_vm --direct --image "$(cat "$dir/base")" || fail "direct boot: no kernel"
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
    start_vm --image "$(cat "$dir/base")" || fail "the VM never started a kernel"
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
      start_vm --direct --image "$(cat "$dir/base")" || fail "direct boot: no kernel"
      wait_ssh || fail "direct boot after the upgrade never came up"
      running=$(vsh 'cat /proc/cmdline' | grep -oE 'vyos-union=/boot/[^ ]+' | cut -d/ -f3)
      [[ "$running" == "$new" ]] || fail "direct boot started $running, expected $new"
      ok "direct boot (as on a Pi 5) starts the upgraded image $new"
    fi
    ;;
  trialboot)
    [[ $profile == pi5 ]] || fail "the trial boot is the Pi 5 path"
    sd_id=5d0c0a1e
    sd_part=$sd_id-01
    sdfat=$dir/sdfat
    target=$dir/trial-target.img
    rm -rf "$sdfat" "$target" "$dir/sd.img"
    mkdir -p "$sdfat"
    # the "old OS" boot partition: what the trial must leave alone
    printf '[all]\nkernel=vmlinuz\n# the old OS\n' >"$sdfat/config.txt"
    [[ -f "$img_src" ]] || { [[ -f "$img_src.xz" ]] && xz -dkc "$img_src.xz" >"$img_src"; } || fail "no $img_src"
    truncate -s 8G "$target"
    seed
    # Older images: add the boot log to their initrd (scripts/bootlog-initrd.py)
    off=$(sfdisk -J "$img_src" | python3 -c 'import json,sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][0]["start"] * 512)')
    MTOOLS_SKIP_CHECK=1 mcopy -n -o -i "$img_src@@$off" ::/vyos-pi/boot/initrd.img "$dir/initrd.target"
    initrd_opt=()
    if ! python3 -c 'import subprocess,sys; d=open(sys.argv[1],"rb").read(); sys.exit(0 if b"vyos-pi-bootlog" in subprocess.run(["zstd","-dc"],input=d,stdout=subprocess.PIPE).stdout else 1)' "$dir/initrd.target"; then
      echo "   (image predates the boot log: adding it with scripts/bootlog-initrd.py)"
      python3 "$root/scripts/bootlog-initrd.py" "$dir/initrd.target" "$dir/initrd.bootlog" >/dev/null
      initrd_opt=(--initrd "$dir/initrd.bootlog")
    fi
    "$root/scripts/pi-trial-install.sh" --boot "$sdfat" --boot-partuuid "$sd_part" --config "$dir/config.boot" \
      --trial-minutes 30 "${initrd_opt[@]}" "$img_src" "$target" | tee "$dir/install.log" || fail "pi-trial-install.sh failed"
    grep -q '^# vyos-pi-trial' "$sdfat/tryboot.txt" || fail "no tryboot.txt"
    for want in 'os_prefix=vyos-pi-trial/' 'kernel=Image' 'initramfs initrd.img followkernel' 'cmdline=cmdline.txt' 'kernel_watchdog_timeout=300'; do
      grep -qxF "$want" "$sdfat/tryboot.txt" || fail "tryboot.txt lacks $want"
    done
    for f in Image initrd.img bcm2712-rpi-5-b.dtb bcm2712d0-rpi-5-b.dtb cmdline.txt trial.env overlays/bcm2712d0.dtbo overlays/vyos-pi-thermal.dtbo overlays/README pi-trial-install.sh; do
      [[ -s $sdfat/vyos-pi-trial/$f ]] || fail "vyos-pi-trial/$f missing"
    done
    grep -q '^# the old OS' "$sdfat/config.txt" || fail "config.txt was changed"
    root_uuid=$(sfdisk -J "$target" | python3 -c 'import json,sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][1]["uuid"].lower())')
    cmd=$(cat "$sdfat/vyos-pi-trial/cmdline.txt")
    echo "trial cmdline: $cmd"
    for want in "live-media=/dev/disk/by-partuuid/$root_uuid" persistence-storage=filesystem panic=10 \
        "vyos-pi.trial=PARTUUID=$sd_part" "vyos-pi.bootlog=PARTUUID=$sd_part:/vyos-pi-trial/boot-log," console=ttyAMA10,115200 vyos-union=/boot/; do
      [[ " $cmd " == *" $want"* ]] || fail "trial cmdline lacks $want"
    done
    python3 -I "$root/overlay/usr/libexec/vyos-pi/vyos-pi-bootsync" --patch-dtb "$sdfat/vyos-pi-trial/bcm2712-rpi-5-b.dtb" "$dir/check.dtb"
    cmp -s "$dir/check.dtb" "$sdfat/vyos-pi-trial/bcm2712-rpi-5-b.dtb" || fail "the trial's device tree lacks the early-watchdog properties"
    t_off=$(sfdisk -J "$target" | python3 -c 'import json,sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][0]["start"] * 512)')
    [[ "$(MTOOLS_SKIP_CHECK=1 mtype -i "$target@@$t_off" ::/vyos-pi/reboot-after-minutes | tr -d '\r\n')" == 30 ]] || fail "no trial timer on the target"
    ok "pi-trial-install.sh: image written, tryboot.txt and vyos-pi-trial/ on the boot partition, config.txt untouched, trial timer on the target"
    # The fake SD card: MBR (disk id $sd_id), one FAT32 partition with sdfat/.
    truncate -s 512M "$dir/sd.img"
    printf 'label: dos\nlabel-id: 0x%s\nstart=2048, type=c\n' "$sd_id" | sfdisk -q "$dir/sd.img"
    mkfs.vfat -F 32 --offset 2048 "$dir/sd.img" $((510 * 1024)) >/dev/null
    MTOOLS_SKIP_CHECK=1 mcopy -s -i "$dir/sd.img@@$((2048 * 512))" "$sdfat"/* ::/
    # What the firmware boots in tryboot mode: tryboot.txt's os_prefix files.
    start_vm --reset --image "$target" --disk2 "$dir/sd.img" --kernel "$sdfat/vyos-pi-trial/Image" \
      --initrd "$sdfat/vyos-pi-trial/initrd.img" --cmdline-file "$sdfat/vyos-pi-trial/cmdline.txt" \
      || fail "trial boot: no kernel"
    wait_ssh || fail "the trial boot never came up (SSH with the seeded key)"
    wait_ready || fail "vyos-router never became active"
    [[ "$(vsh hostname)" == vyos-pi-test ]] || fail "seed config not loaded in the trial"
    vsh 'cat /proc/cmdline' | grep -q "vyos-pi.trial=PARTUUID=$sd_part" || fail "not booted with the trial command line"
    vsh 'findmnt -no SOURCE /usr/lib/live/mount/persistence' | grep -q '^/dev/vda2$' || fail "VyOS's root is not the target's partition 2"
    ok "trial boot: VyOS up from the target disk with the trial command line"
    vsh "sudo mount /dev/disk/by-partuuid/$sd_part /mnt && ls /mnt/vyos-pi-trial/boot-log; r=0; for s in initramfs initramfs-done; do ls /mnt/vyos-pi-trial/boot-log/*-\$s.txt >/dev/null 2>&1 || r=1; done; sudo umount /mnt; exit \$r" \
      || fail "initramfs boot logs missing from the SD card"
    # (initramfs-top is there on a Pi, whose disks are built in; the VM's
    # virtio disk driver is a module that only udev loads)
    ok "boot logs on the SD card (initramfs, initramfs-done)"
    sdcopy=/tmp/pi-trial-install.sh
    vsh "sudo mount /dev/disk/by-partuuid/$sd_part /mnt && cp /mnt/vyos-pi-trial/pi-trial-install.sh $sdcopy && sudo umount /mnt"
    vsh "sudo bash $sdcopy --commit --force" || fail "--commit failed"
    vsh "sudo mount /dev/disk/by-partuuid/$sd_part /mnt; r=0; test ! -e /mnt/config.txt && test -f /mnt/config.txt.vyos-pi-committed && test ! -e /mnt/tryboot.txt || r=1; grep -q STATE=committed /mnt/vyos-pi-trial/trial.env || r=1; sudo umount /mnt; exit \$r" \
      || fail "--commit did not disable config.txt / tryboot.txt on the SD card"
    vsh 'sudo bash -c ". /usr/libexec/vyos-pi/common.sh; mount_esp; test ! -e \$ESP_MNT/vyos-pi/reboot-after-minutes; r=\$?; umount_esp; exit \$r"' \
      || fail "--commit left the trial timer on the target"
    ok "--commit (from VyOS): SD config.txt renamed, tryboot.txt gone, trial timer removed"
    vsh "sudo bash $sdcopy --uncommit" || fail "--uncommit failed"
    vsh "sudo mount /dev/disk/by-partuuid/$sd_part /mnt; grep -q '^# the old OS' /mnt/config.txt; r=\$?; sudo umount /mnt; exit \$r" \
      || fail "--uncommit did not restore config.txt"
    ok "--uncommit: config.txt is back"
    ;;
  panic)
    [[ -f "$dir/sd.img" && -f "$dir/sdfat/vyos-pi-trial/cmdline.txt" ]] || fail "run vm/test.sh trialboot pi5 first"
    rm -f "$dir/console.log"
    sdfat=$dir/sdfat
    start=$(date +%s)
    "$root/vm/run.sh" --pi5 --headless --image "$dir/trial-target.img" --disk2 "$dir/sd.img" --no-reboot \
      --kernel "$sdfat/vyos-pi-trial/Image" --initrd "$sdfat/vyos-pi-trial/initrd.img" \
      --cmdline-file "$sdfat/vyos-pi-trial/cmdline.txt" \
      --cmdline-sed 's|live-media=/dev/disk/by-partuuid/[^ ]*|live-media=/dev/disk/by-partuuid/00000000-0000-0000-0000-000000000000|'
    pid=$(cat "$dir/qemu.pid")
    # live-boot looks for 60 s, then panic=10: well within 15 minutes under TCG
    for _ in $(seq 180); do kill -0 "$pid" 2>/dev/null || break; sleep 5; done
    kill -0 "$pid" 2>/dev/null && fail "still running after 15 minutes: a missing root did not reboot"
    grep -aq 'Rebooting automatically due to panic= boot argument' "$dir/console.log" \
      || fail "QEMU stopped, but not through panic= (see console.log)"
    ok "missing root: reboots by itself after $(( $(date +%s) - start )) s (panic=10), no initramfs shell"
    MTOOLS_SKIP_CHECK=1 mdir -b -i "$dir/sd.img@@$((2048 * 512))" ::/vyos-pi-trial/boot-log | grep -q 'initramfs-panic.txt' \
      || fail "no initramfs-panic boot log on the SD card"
    ok "the panic left a boot log on the SD card (initramfs-panic)"
    ;;
  *) echo "usage: $0 image|trial|ids|direct|trialboot|panic|upgrade [pi5|pi4] [ISO]" >&2; exit 2 ;;
esac
stop
