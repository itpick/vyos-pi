#!/usr/bin/env python3
"""Find the kernel log of a boot that died before it could write anything,
in the RAM it left behind. For a trial boot that panics or hangs before the
boot log reaches the SD card, and no serial console.

The kernel's log (with log_buf_len=8M on its command line, so it moves out
of the kernel image into a buffer the kernel allocates at the top of RAM)
survives a watchdog reset or reboot; the Pi firmware does not clear RAM. So:

  1. On the old OS, keep its kernel out of the top of RAM: add mem=8G (on a
     16 GB Pi 5; mem=4G on 8 GB) to its cmdline.txt. Remove it when done.
  2. Trial boot (pi-trial-install.sh) with log_buf_len=8M added to
     vyos-pi-trial/cmdline.txt; let it fail and come back.
  3. sudo scripts/pi-find-kernel-log.py [--from 8G] [--to 16G] [--out FILE]

It scans physical memory from --from to --to through /dev/mem (memory the
running kernel does not use may be mapped even with STRICT_DEVMEM), finds
"Linux version", and writes the printable text of the 8 MiB from there.
This is how vyos-pi found the SError that stopped its first Pi 5 boots
("Kernel panic - not syncing: Asynchronous SError Interrupt" in
brcmstb_pull_config_set: a D0 board with the C1 device tree).
"""
import argparse
import mmap
import os
import re


def size(s):
    m = re.fullmatch(r'(\d+)([KMG]?)', s.upper())
    if not m:
        raise argparse.ArgumentTypeError(f'bad size {s}')
    return int(m.group(1)) << {'': 0, 'K': 10, 'M': 20, 'G': 30}[m.group(2)]


ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
ap.add_argument('--from', dest='start', type=size, default=size('8G'))
ap.add_argument('--to', dest='end', type=size, default=size('16G'))
ap.add_argument('--match', default='Linux version ', help='text that starts the log')
ap.add_argument('--out', default='kernel-log-from-ram.txt')
a = ap.parse_args()

fd = os.open('/dev/mem', os.O_RDONLY | os.O_SYNC)
step = 64 << 20
needle = a.match.encode()
found = None
for off in range(a.start, a.end, step):
    try:
        m = mmap.mmap(fd, step, mmap.MAP_SHARED, mmap.PROT_READ, offset=off)
    except OSError:
        continue  # in use by the running kernel, or a hole
    data = m[:]
    m.close()
    i = data.find(needle)
    if i >= 0:
        found = off + i
        print(f'"{a.match}" at {found:#x}: {data[i:i + 100].split(bytes(1))[0].decode(errors="replace")}')
        break
if found is None:
    raise SystemExit(f'"{a.match}" not found between {a.start:#x} and {a.end:#x}')

base = found & ~0xfff
m = mmap.mmap(fd, 8 << 20, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
text = '\n'.join(r.decode() for r in re.findall(rb'[\x20-\x7e\t]{6,}', m[:]))
with open(a.out, 'w') as f:
    f.write(text + '\n')
print(f'{len(text.splitlines())} lines -> {a.out}')
for line in text.splitlines():
    if re.search(r'Kernel panic|Internal error|SError|Unable to handle|Call trace|BUG:|Oops', line):
        print('   ' + line)
