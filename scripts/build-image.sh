#!/usr/bin/env bash
# Build a flashable VyOS image for a Raspberry Pi from the raw image.
#
#   scripts/build-image.sh pi4|pi5
#
# Takes out/vyos-pi-arm64.raw (scripts/build-iso.sh: VyOS installed on a disk
# the way "install image" does it, GRUB on the EFI system partition) and makes
# out/vyos-pi-<board>.img:
#
#   - partition 1 is the FAT32 EFI system partition, where the Pi's EEPROM
#     bootloader looks for its files (scripts/patch-vyos-build.py)
#   - pi4: the pftf/RPi4 UEFI firmware goes into the ESP (config.txt ->
#     armstub=RPI_EFI.fd), preset to use all the RAM (uefi/pi4-vars.json).
#     UEFI then starts GRUB (EFI/BOOT/BOOTAA64.EFI) and GRUB starts VyOS.
#   - pi5: config.txt starts the VyOS kernel and initrd directly with the
#     mainline device tree (no UEFI; see README "Pi 5 boot path"), staged by
#     overlay/.../vyos-pi-bootsync, the same code that keeps them current on
#     the running system. GRUB stays on the ESP for VMs and UEFI boards.
#     overlays/bcm2712d0.dtbo (firmware/pi5/bcm2712d0-overlay.dts): the
#     firmware applies it on D0 boards to the C1 tree it always loads.
#   - both: vyos-pi/ with README.txt and config.boot.default, where
#     first-boot settings go
#
# Then scripts/compress.sh writes out/vyos-pi-<board>.img.xz and its .sha256.
# Needs: curl sha256sum sfdisk mtools unzip python3 (+ virt-fw-vars for pi4,
# dtc for pi5)
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=versions.env
source versions.env

board=${1:-}
case "$board" in pi4|pi5) ;; *) echo "usage: $0 pi4|pi5" >&2; exit 2 ;; esac
for tool in curl sha256sum sfdisk mcopy unzip python3; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
raw=out/vyos-pi-arm64.raw
[[ -f "$raw" && -f out/boot/version ]] || { echo "missing $raw / out/boot (make iso)" >&2; exit 1; }

cache=.work/cache
mkdir -p "$cache" out
work=$(mktemp -d .work/build-XXXXXX)
trap 'rm -rf "$work"' EXIT

# fetch URL SHA256 -> prints the cached path, verified
fetch() {
  local url=$1 sha=$2 dest="$cache/${1##*/}"
  if [[ ! -f "$dest" ]]; then
    echo ">> downloading ${url##*/}" >&2
    curl -fSL --retry 3 -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
  fi
  echo "$sha  $dest" | sha256sum -c --quiet - >&2 || {
    echo "sha256 mismatch for $dest (delete it to re-download)" >&2; exit 1; }
  echo "$dest"
}

img=$work/vyos-pi-$board.img
echo ">> copying $raw"
cp --sparse=always "$raw" "$img"

# Partition 1 must be the ESP (the Pi bootloader reads it), 2 the root.
# scripts/patch-vyos-build.py makes the raw image that way: GRUB records the
# partition number, so it cannot be changed here.
parts() { sfdisk -J "$img" | python3 -c 'import json,sys; [print(p["node"][-1], p["type"].upper(), p["start"], p["size"]) for p in json.load(sys.stdin)["partitiontable"]["partitions"]]'; }
parts | sed 's/^/   partition /'
read -r esp_n esp_type esp_start _ < <(parts | head -1)
[[ "$esp_n" == 1 && "$esp_type" == C12A7328-F81F-11D2-BA4B-00A0C93EC93B ]] || { echo "partition 1 is not the ESP" >&2; exit 1; }
esp="$img@@$((esp_start * 512))"
export MTOOLS_SKIP_CHECK=1
mdir -i "$esp" ::/EFI/BOOT/BOOTAA64.EFI >/dev/null || { echo "no EFI/BOOT/BOOTAA64.EFI on the ESP" >&2; exit 1; }

stage=$work/esp
mkdir -p "$stage/vyos-pi"
version=$(cat out/boot/version)
case "$board" in
  pi4)
    fw=$(fetch "$RPI4_FW_URL" "$RPI4_FW_SHA256")
    echo ">> adding Pi 4 UEFI firmware ($(basename "$fw"))"
    unzip -q "$fw" -d "$stage"
    # Disable "Limit RAM to 3 GB" (on by default for old OSes; Linux handles
    # the Pi 4's DMA limits itself). An EFI variable in RPI_EFI.fd's store;
    # name and GUID from edk2-platforms Platform/RaspberryPi/RPi4/RPi4.dsc.
    command -v virt-fw-vars >/dev/null || { echo "needs virt-fw-vars (pip install virt-firmware)" >&2; exit 1; }
    echo ">> presetting UEFI variables (uefi/pi4-vars.json)"
    virt-fw-vars -l warning --input "$stage/RPI_EFI.fd" --set-json uefi/pi4-vars.json --output "$stage/RPI_EFI.fd.new"
    mv "$stage/RPI_EFI.fd.new" "$stage/RPI_EFI.fd"
    virt-fw-vars -l warning --input "$stage/RPI_EFI.fd" --output-json - | python3 -c '
import json, sys
want = json.load(open("uefi/pi4-vars.json"))["variables"]
have = json.load(sys.stdin)["variables"]
for v in want:
    assert any(h["name"] == v["name"] and h["guid"] == v["guid"] and h["data"] == v["data"] for h in have), v["name"]
    print("   " + v["name"] + " = " + v["data"])'
    ;;
  pi5)
    echo ">> staging Pi 5 direct-boot files for $version"
    cp firmware/pi5/config.txt "$stage/config.txt"
    command -v dtc >/dev/null || { echo "needs dtc (device-tree-compiler)" >&2; exit 1; }
    mkdir -p "$stage/overlays"
    dtc -q -@ -I dts -O dtb -o "$stage/overlays/bcm2712d0.dtbo" firmware/pi5/bcm2712d0-overlay.dts
    printf '%s\n' "vyos-pi: device tree overlays for the Pi 5 firmware (bcm2712d0.dtbo:" \
      "mainline's D0 changes, applied by the firmware on D0 boards). See" \
      "firmware/pi5/bcm2712d0-overlay.dts at https://github.com/itpick/vyos-pi" >"$stage/overlays/README"
    # the ESP's GPT partition UUID: cmdline.txt sends the boot log there
    esp_uuid=$(sfdisk -J "$img" | python3 -c 'import json,sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][0]["uuid"].lower())')
    python3 -I overlay/usr/libexec/vyos-pi/vyos-pi-bootsync --stage "$stage" --version "$version" \
      --vmlinuz out/boot/vmlinuz --initrd out/boot/initrd.img --dtbs out/boot/dtbs --esp-partuuid "$esp_uuid"
    ;;
esac
cp firmware/README.txt "$stage/vyos-pi/README.txt"
cp out/vyos-pi.config.boot.default "$stage/vyos-pi/config.boot.default"
mcopy -s -o -i "$esp" "$stage"/* ::/
echo ">> ESP contents"
mdir -/ -b -i "$esp" :: | sed 's/^/   /'
echo "   $(mdir -i "$esp" :: | grep -i "bytes free")"

{
  cat out/vyos-pi-arm64.manifest.txt
  echo "board: $board"
  case "$board" in
    pi4) echo "boot: Pi EEPROM -> UEFI $(basename "$RPI4_FW_URL") (RamLimitTo3GB=0) -> GRUB -> VyOS" ;;
    pi5) echo "boot: Pi EEPROM -> config.txt -> VyOS kernel + initrd + mainline device tree (no UEFI)" ;;
  esac
  echo "partitions (start, sectors):"
  parts | sed 's/^/  /'
  echo "ESP:"
  mdir -/ -b -i "$esp" :: | sed 's/^/  /'
} > "out/vyos-pi-$board.manifest.txt"

mv "$img" "out/vyos-pi-$board.img"
echo ">> out/vyos-pi-$board.img"
