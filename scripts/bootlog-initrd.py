#!/usr/bin/env python3
"""Add vyos-pi's boot log to an existing VyOS initrd, for images built before
it was part of the image (overlay/etc/initramfs-tools).

  scripts/bootlog-initrd.py IN OUT

OUT is IN with one more (uncompressed) cpio archive appended; the kernel
unpacks concatenated archives in order, later files replacing earlier ones. It
adds bin/vyos-pi-bootlog, live-boot's panic hook
(lib/live/boot/9999-vyos-pi-bootlog.sh), the init-premount and init-bottom
scripts, and those two folders' ORDER files with the scripts added (read from
IN, so nothing else changes). vfat and the code pages must already be in IN
(VyOS's initrd has them: MODULES=most).

For a trial of such an image: pi-trial-install.sh --initrd OUT.
"""
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OV = os.path.join(REPO, 'overlay')
ADD = {
    'usr/bin/vyos-pi-bootlog': 'usr/libexec/vyos-pi/vyos-pi-bootlog',
    'usr/lib/live/boot/9999-vyos-pi-bootlog.sh': 'usr/lib/vyos-pi/9999-vyos-pi-bootlog.sh',
    'scripts/init-top/00-vyos-pi-bootlog': 'etc/initramfs-tools/scripts/init-top/00-vyos-pi-bootlog',
    'scripts/init-premount/vyos-pi-bootlog': 'etc/initramfs-tools/scripts/init-premount/vyos-pi-bootlog',
    'scripts/init-bottom/vyos-pi-bootlog': 'etc/initramfs-tools/scripts/init-bottom/vyos-pi-bootlog',
}


def decompress(data):
    magic = data[:4]
    if magic == b'\x28\xb5\x2f\xfd':
        cmd = ['zstd', '-dc']
    elif magic[:2] == b'\x1f\x8b':
        cmd = ['gzip', '-dc']
    elif magic == b'\xfd7zX':
        cmd = ['xz', '-dc']
    elif magic[:6] == b'070701':
        return data
    else:
        raise SystemExit('unknown initrd compression')
    return subprocess.run(cmd, input=data, stdout=subprocess.PIPE, check=True).stdout


def read_cpio(data):
    """{name: (mode, content)} of a newc archive (first one only)."""
    files, i = {}, 0
    while i + 110 <= len(data) and data[i:i + 6] == b'070701':
        h = data[i:i + 110]
        mode = int(h[14:22], 16)
        size = int(h[54:62], 16)
        nlen = int(h[94:102], 16)
        name = data[i + 110:i + 110 + nlen - 1].decode()
        j = (i + 110 + nlen + 3) & ~3
        files[name] = (mode, data[j:j + size])
        i = (j + size + 3) & ~3
        if name == 'TRAILER!!!':
            break
    return files


def newc(entries):
    out, ino = bytearray(), 0x7f0000
    for name, mode, content in entries + [('TRAILER!!!', 0, b'')]:
        ino += 1
        nb = name.encode() + b'\0'
        hdr = '070701' + ''.join('%08x' % v for v in (
            ino, mode, 0, 0, 1, 0, len(content), 0, 0, 0, 0, len(nb), 0))
        out += hdr.encode() + nb
        out += b'\0' * (-len(out) % 4)
        out += content
        out += b'\0' * (-len(out) % 4)
    return bytes(out)


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    src, dst = sys.argv[1:]
    data = open(src, 'rb').read()
    files = read_cpio(decompress(data))
    if 'init' not in files:
        raise SystemExit(f'{src}: no /init in the first archive')
    for m in ('vfat.ko', 'nls_cp437.ko'):
        if not any(m in n for n in files):
            raise SystemExit(f'{src} has no {m}')

    def find(*names):
        for n in names:
            if n in files:
                return n
        return None

    entries, dirs = [], set()

    def add_dirs(path):
        parts = path.split('/')[:-1]
        for k in range(1, len(parts) + 1):
            d = '/'.join(parts[:k])
            if d not in dirs and d not in files:
                dirs.add(d)
                entries.append((d, 0o40755, b''))

    # bin and lib may be symlinks to usr/bin, usr/lib (merged /usr)
    for want, rel in ADD.items():
        name = want
        if want.startswith('usr/') and not find('usr/bin', 'usr/lib'):
            name = want[4:]
        add_dirs(name)
        entries.append((name, 0o100755, open(os.path.join(OV, rel), 'rb').read()))
    # init-top: first, before udev (whose settle can wait on a hung probe)
    for stage, script, first in (('init-top', '00-vyos-pi-bootlog', True),
                                 ('init-premount', 'vyos-pi-bootlog', False),
                                 ('init-bottom', 'vyos-pi-bootlog', False)):
        order = f'scripts/{stage}/ORDER'
        line = f'/scripts/{stage}/{script} "$@"\n[ -e /conf/param.conf ] && . /conf/param.conf\n'
        old = files.get(order, (0o100644, b''))[1].decode()
        if 'vyos-pi-bootlog' not in old:
            old = line + old if first else old + line
        entries.append((order, 0o100644, old.encode()))
    pad = b'\0' * (-len(data) % 4)
    with open(dst, 'wb') as f:
        f.write(data + pad + newc(entries))
    for e in entries:
        print(f'   + {e[0]}')


main()
