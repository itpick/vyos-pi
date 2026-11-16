#!/usr/bin/env python3
"""Patch a vyos-build checkout for the vyos-pi build.

  scripts/patch-vyos-build.py VYOS_BUILD_DIR

raw_image.py (the raw disk image target) maps the image's partitions with
kpartx, as device-mapper devices. grub-install, run on those, cannot tell they
are partitions of one GPT disk, so the GRUB it writes to the ESP has no
part_gpt module and stops at "grub rescue>" (no such device: <root uuid>).
This switches it to a partition-scanning loop device (losetup -P:
/dev/loopNp1..3), which grub-install sees as the disk it is. Idempotent; fails
if the code it patches has changed.
"""
import pathlib
import sys

p = pathlib.Path(sys.argv[1], 'scripts/image-build/raw_image.py')
s = p.read_text()
if 'vyos-pi: partscan' in s:
    sys.exit(0)

edits = [
    ("command = f'losetup --show -f {raw_file}'",
     "command = f'losetup --show -f -P {raw_file}'  # vyos-pi: partscan"),
    ('cmd(f"kpartx -av {con.loop_device}")',
     'cmd(f"partx -u {con.loop_device}")'),
    ('mapped_parts = sorted(glob(f"/dev/mapper/{mapper_base}p*"))',
     'for _ in range(50):\n'
     '            mapped_parts = sorted(glob(f"/dev/{mapper_base}p[0-9]*"))\n'
     '            if len(mapped_parts) >= 3:\n'
     '                break\n'
     '            time.sleep(0.2)'),
]
for old, new in edits:
    if s.count(old) != 1:
        sys.exit(f'patch-vyos-build: {p}: expected exactly one "{old}"')
    s = s.replace(old, new)
p.write_text(s)
print(f'   patched {p.relative_to(sys.argv[1])}: partition-scanning loop device instead of kpartx')
