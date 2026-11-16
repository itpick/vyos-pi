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
  *) echo "usage: $0 image|trial|ids|direct|upgrade [pi5|pi4] [ISO]" >&2; exit 2 ;;
esac
stop
