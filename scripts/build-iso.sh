#!/usr/bin/env bash
# Build the VyOS arm64 ISO with the Raspberry Pi kernel, and a raw disk image
# installed from it.
#
#   scripts/build-iso.sh [VERSION]      (in the vyos-build container, as root)
#
# scripts/container.sh runs this in the right container: vyos-build's own
# Dockerfile at VYOS_BUILD_REV, on an arm64 host (natively: GitHub's
# ubuntu-24.04-arm runners, or an Apple Silicon Mac), --privileged (the raw
# image is assembled on loop devices).
#
#   1. vyos-build at VYOS_BUILD_REV, the kernel at LINUX_VERSION (sha256 checked)
#   2. the kernel with kernel/raspberrypi.config merged in, and the out-of-tree
#      modules VyOS needs rebuilt against it (KERNEL_PACKAGES), with
#      vyos-build's linux-kernel/build.py. Cached in $WORK/kernel-debs by a
#      hash of everything that goes into them.
#   3. the ISO: vyos-build's build-vyos-image, flavor vyos/raspberrypi.toml,
#      with overlay/ and vyos/hooks/ added, VyOS artwork replaced
#   4. the raw image from that ISO (vyos-build's raw image target)
#
# WORK (default /work) keeps the vyos-build checkout and caches; it must be on
# a case-sensitive Linux filesystem (the kernel tree needs one).
#
# Output, in out/:
#   vyos-pi-arm64.iso            install / upgrade ISO ("add system image")
#   vyos-pi-arm64.raw            raw disk for scripts/build-image.sh
#   vyos-pi-arm64.manifest.txt   what went in
#   vyos-pi.config.boot.default  the default config with its version footer
#                                (scripts/seed-config.py starts from it)
#   boot/                        vmlinuz, initrd.img, version, dtbs/ (for the
#                                Pi 5 direct-boot files)
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=versions.env
source "$repo/versions.env"
version=${1:-$(date -u +%Y.%m.%d)-dev}
work=${WORK:-/work}
out=$repo/out
die() { echo "E: $*" >&2; exit 1; }
step() { echo; echo ">> $*"; }

[ "$(uname -m)" = aarch64 ] || die "needs an arm64 host (this is $(uname -m))"
[ "$(id -u)" = 0 ] || die "needs root"
case "$version" in *[!A-Za-z0-9.+-]*) die "bad version string: $version" ;; esac
mkdir -p "$work/cache" "$out"
commit=${COMMIT:-$(git -c safe.directory='*' -C "$repo" rev-parse --short HEAD 2>/dev/null || echo unknown)}

step "vyos-build ${VYOS_BUILD_REV:0:12}"
vb=$work/vyos-build
# REUSE_ISO=1: keep the last build's ISO, redo only the raw image and the export
if [ -z "${REUSE_ISO:-}" ]; then
[ -d "$vb/.git" ] || git clone -q "$VYOS_BUILD_REPO" "$vb"
git -C "$vb" cat-file -e "$VYOS_BUILD_REV^{commit}" 2>/dev/null || git -C "$vb" fetch -q origin
git -C "$vb" checkout -q --force "$VYOS_BUILD_REV"
git -C "$vb" clean -ffdxq
kver=$(python3 -c 'import sys, tomli; print(tomli.load(open(sys.argv[1], "rb"))["kernel_version"])' "$vb/data/defaults.toml")
[ "$kver" = "$LINUX_VERSION" ] || die "vyos-build wants kernel $kver, versions.env pins $LINUX_VERSION"

# --- kernel ---
kdir=$vb/scripts/package-build/linux-kernel
key=$({ echo "$VYOS_BUILD_REV $LINUX_SHA256 $KERNEL_PACKAGES"; cat "$repo/kernel/raspberrypi.config"; } | sha256sum | cut -c1-16)
kcache=$work/kernel-debs/$key
if [ -f "$kcache/done" ]; then
	step "kernel packages: cached ($key)"
else
	step "kernel $LINUX_VERSION with kernel/raspberrypi.config, and $KERNEL_PACKAGES"
	tarball=$work/cache/${LINUX_URL##*/}
	if [ ! -f "$tarball" ]; then
		curl -fSL --retry 3 -o "$tarball.part" "$LINUX_URL"
		mv "$tarball.part" "$tarball"
	fi
	echo "$LINUX_SHA256  $tarball" | sha256sum -c --quiet - || die "sha256 mismatch: $tarball"
	tar -C "$kdir" -xf "$tarball"
	ln -sfn "linux-$LINUX_VERSION" "$kdir/linux"
	cp "$repo/kernel/raspberrypi.config" "$kdir/config/70-raspberrypi.config"
	# shellcheck disable=SC2086 # KERNEL_PACKAGES is a list
	(cd "$kdir" && python3 build.py --config package.toml --packages $KERNEL_PACKAGES)
	# Every line of the fragment must have reached the kernel's .config.
	missing=$(grep -E '^CONFIG_' "$repo/kernel/raspberrypi.config" | while read -r l; do grep -qxF "$l" "$kdir/linux/.config" || echo "$l"; done)
	[ -z "$missing" ] || die "not in the kernel .config: $missing"
	# build.py reports failed packages but carries on; check every one is there.
	rm -rf "$kcache.new"; mkdir -p "$kcache.new"
	# (accel-ppp-ng builds VPP to link against; the image keeps VyOS's own VPP packages)
	find "$kdir" -maxdepth 3 -name '*.deb' ! -name '*-dbg_*' ! -name '*-dbgsym_*' ! -name 'linux-libc-dev_*' \
		! -name 'vpp*' ! -name 'libvpp*' ! -name 'python3-vpp*' -exec cp {} "$kcache.new/" \;
	for p in "linux-image-$LINUX_VERSION-" "linux-headers-$LINUX_VERSION-" accel-ppp-ng jool_ nat-rtsp vyos-ipt-netflow_; do
		ls "$kcache.new" | grep -q "^$p" || die "no $p*.deb built"
	done
	cp "$kdir/linux/.config" "$kcache.new/kernel.config"
	touch "$kcache.new/done"
	rm -rf "$kcache"; mv "$kcache.new" "$kcache"
	rm -rf "$kdir/linux" "$kdir/linux-$LINUX_VERSION"
fi
ls "$kcache"/*.deb | sed 's|.*/|   |'
mkdir -p "$vb/packages"
cp "$kcache"/*.deb "$vb/packages/"

# --- ISO ---
step "ISO $version (flavor raspberrypi)"
cp "$repo/vyos/raspberrypi.toml" "$vb/data/build-flavors/"
cp -a "$repo/overlay/." "$vb/data/live-build-config/includes.chroot/"
install -m 755 "$repo/scripts/pi-trial-install.sh" "$vb/data/live-build-config/includes.chroot/usr/libexec/vyos-pi/pi-trial-install"
install -m 755 "$repo"/vyos/hooks/*.chroot "$vb/data/live-build-config/hooks/live/"
mkdir -p "$vb/data/live-build-config/includes.chroot/usr/share/vyos-pi"
{
	echo "vyos-pi $version"
	echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ) from itpick/vyos-pi $commit"
	echo "vyos-build: $VYOS_BUILD_REV"
	echo "kernel: $LINUX_VERSION + kernel/raspberrypi.config"
} > "$vb/data/live-build-config/includes.chroot/usr/share/vyos-pi/manifest.txt"
# VyOS logo artwork (LICENSE.artwork: copyright Sentrium S.L.) -> a plain image.
python3 - "$vb" <<'EOF'
import pathlib, struct, sys, zlib
def png(w, h, rgb):
    raw = b''.join(b'\0' + bytes(rgb) * w for _ in range(h))
    chunk = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')
for p in pathlib.Path(sys.argv[1], 'data').rglob('*.png'):
    p.write_bytes(png(640, 480, (28, 25, 23)))
    print(f'   replaced artwork {p.relative_to(sys.argv[1])}')
EOF
fi
cd "$vb"
git -C "$vb" checkout -q -- scripts/image-build/raw_image.py
python3 "$repo/scripts/patch-vyos-build.py" "$vb"
# Undo the raw image step's loop devices and mounts (it can leave some behind).
raw_cleanup() {
	local m l
	for m in build/tmp/squash/dev build/tmp/squash/proc build/tmp/squash/sys build/tmp/squash/boot/efi \
		build/tmp/squash/boot build/tmp/squash build/tmp/iso build/tmp/raw build/tmp/efi; do
		mountpoint -q "$m" && umount -l "$m"
	done
	for l in $(losetup -j "$vb/build/vyos-$version-raspberrypi-arm64.raw" -O NAME -n 2>/dev/null); do
		losetup -d "$l" 2>/dev/null
	done
	return 0
}
opts=(--architecture arm64 --build-by "vyos-pi@github.com/itpick/vyos-pi" --version "$version"
	--build-comment "vyos-pi $commit: Raspberry Pi 4/5 kernel (kernel/raspberrypi.config)")
raw_only() {
	raw_cleanup
	rm -f "build/vyos-$version-raspberrypi-arm64.raw"
	./build-vyos-image "${opts[@]}" --reuse-iso "vyos-$version-raspberrypi-arm64.iso" raspberrypi || die "raw image build failed"
}
if [ -n "${REUSE_ISO:-}" ]; then
	[ -f "build/vyos-$version-raspberrypi-arm64.iso" ] || die "REUSE_ISO: no build/vyos-$version-raspberrypi-arm64.iso"
	step "raw image from the existing ISO"
	raw_only
elif ! ./build-vyos-image "${opts[@]}" raspberrypi; then
	# The raw image step has failed to mount its fresh root partition right
	# after live-build; once the ISO exists, retry only that step.
	[ -f "build/vyos-$version-raspberrypi-arm64.iso" ] || die "ISO build failed"
	echo "W: raw image step failed; retrying it from the ISO"
	raw_only
fi
raw_cleanup
iso=build/vyos-$version-raspberrypi-arm64.iso
raw=build/vyos-$version-raspberrypi-arm64.raw
[ -f "$iso" ] || die "no ISO built"
[ -f "$raw" ] || die "no raw image built"

step "exporting to out/"
rm -rf "${out:?}/boot"
mkdir -p "$out/boot/dtbs"
cp "$iso" "$out/vyos-pi-arm64.iso"
# (plain copy: some bind mounts, e.g. macOS virtiofs, reject sparse writes)
cp --sparse=never "$raw" "$out/vyos-pi-arm64.raw" && rm -f "$raw"
(cd "$out" && sha256sum vyos-pi-arm64.iso > vyos-pi-arm64.iso.sha256)
x=$(mktemp -d)
trap 'umount "$x/sq" 2>/dev/null; rm -rf "$x"' EXIT
xorriso -osirrox on -indev "$out/vyos-pi-arm64.iso" -extract /live "$x/live" >/dev/null 2>&1
cp -L "$x/live/vmlinuz" "$out/boot/vmlinuz"
cp -L "$x/live/initrd.img" "$out/boot/initrd.img"
mkdir "$x/sq"
mount -t squashfs -o loop,ro "$x/live/filesystem.squashfs" "$x/sq"
# The boot log (overlay/etc/initramfs-tools) must be in the initramfs. The
# image's own zstd decompresses it (the build container has none).
initrd_files=$(chroot "$x/sq" zstd -dc <"$out/boot/initrd.img" | cpio -it 2>/dev/null) \
	|| initrd_files=$(gzip -dc <"$out/boot/initrd.img" | cpio -it 2>/dev/null) || true
for f in bin/vyos-pi-bootlog lib/live/boot/9999-vyos-pi-bootlog.sh scripts/init-top/00-vyos-pi-bootlog scripts/init-premount/vyos-pi-bootlog scripts/init-bottom/vyos-pi-bootlog; do
	grep -qE "(^|/)$f\$" <<<"$initrd_files" || die "initrd lacks $f (vyos-pi boot log)"
done
cp "$x"/sq/usr/lib/linux-image-*/broadcom/bcm271*.dtb "$out/boot/dtbs/"
cp "$x/sq/usr/share/vyos/version.json" "$out/boot/version.json"
python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$out/boot/version.json" > "$out/boot/version"
# The default config with the version footer VyOS adds on first boot, from
# the image's own code, so a seed made from it migrates correctly.
{
	cat "$x/sq/usr/share/vyos/config.boot.default"
	chroot "$x/sq" /usr/bin/python3 -B /usr/libexec/vyos/add-system-version.py
} > "$out/vyos-pi.config.boot.default"
grep -q '^// vyos-config-version: ".*interfaces@' "$out/vyos-pi.config.boot.default" || die "no version footer"
{
	cat "$x/sq/usr/share/vyos-pi/manifest.txt"
	echo "iso: vyos-pi-arm64.iso $(cut -d' ' -f1 "$out/vyos-pi-arm64.iso.sha256")"
	echo "out-of-tree modules rebuilt against the Pi kernel:"
	find "$vb/packages" -name '*.deb' -printf '  %f\n' | sort
} > "$out/vyos-pi-arm64.manifest.txt"
[ -n "${HOST_UID:-}" ] && chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" "$out"
cat "$out/vyos-pi-arm64.manifest.txt"
ls -la "$out" "$out/boot" "$out/boot/dtbs"
