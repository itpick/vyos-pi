"""Drive a QEMU serial console over a unix socket.

usage: console.py SOCK TIMEOUT EXPECT_REGEX [SEND]
Sends SEND followed by CR (if given), then reads until EXPECT_REGEX matches or
TIMEOUT seconds pass. Prints what was read (ANSI escapes stripped).
The regex is matched against the text with ANSI escapes stripped (shells
like busybox ash send a cursor position query after the prompt).
Exit 0 on match, 1 on timeout.
"""
import re
import socket
import sys
import time

sock_path, timeout, pattern = sys.argv[1], float(sys.argv[2]), sys.argv[3]
send = sys.argv[4] if len(sys.argv) > 4 else None

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock_path)
s.settimeout(0.5)
if send is not None:
    s.sendall(send.encode() + b"\r")
buf = b""
rx = re.compile(pattern.encode())
ansi = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]")
text = lambda: ansi.sub(b"", buf)
deadline = time.time() + timeout
while time.time() < deadline and not rx.search(text()):
    try:
        chunk = s.recv(65536)
    except socket.timeout:
        continue
    if not chunk:
        break
    buf += chunk
sys.stdout.write(text().decode(errors="replace"))
sys.exit(0 if rx.search(text()) else 1)
