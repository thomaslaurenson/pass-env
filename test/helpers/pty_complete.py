#!/usr/bin/env python3

"""Drive a real interactive bash through a pty and report the line TAB produced.

The bats suite can assert what a completion function puts into COMPREPLY, but
not what readline then inserts onto the command line. That gap is the whole of
the completion escaping problem: candidate generation can be perfectly safe
while the inserted text still executes when the user presses Enter. Reproducing
it needs a terminal, which needs a pty.

Usage:
    pty_complete.py RCFILE TYPED

RCFILE is sourced by the spawned bash; it is expected to set PS1 to the marker
below and register the completions under test. TYPED is sent literally, then a
TAB, then a carriage return. Everything the terminal echoed is printed to
stdout for the caller to inspect.

Exits 0 on success, 2 if bash never reached a prompt.
"""

import os
import pty
import select
import signal
import sys
import time

PROMPT = "RDY> "
READ_TIMEOUT = 5.0


def read_until(fd, needle, timeout):
    """Read from fd until needle appears in the accumulated output, or timeout."""
    buf = ""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        remaining = deadline - time.monotonic()
        ready, _, _ = select.select([fd], [], [], remaining)
        if not ready:
            continue
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk.decode("utf-8", "replace")
        if needle in buf:
            return buf, True
    return buf, False


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    rcfile, typed = sys.argv[1], sys.argv[2]

    pid, fd = pty.fork()
    if pid == 0:
        # Child: a fresh interactive bash that reads only the supplied rcfile.
        os.environ["PS1"] = PROMPT
        os.execvp("bash", ["bash", "--noprofile", "--rcfile", rcfile, "-i"])
        os._exit(127)

    try:
        _, ok = read_until(fd, PROMPT, READ_TIMEOUT)
        if not ok:
            return 2

        os.write(fd, typed.encode())
        time.sleep(0.3)
        os.write(fd, b"\t")
        time.sleep(0.8)
        os.write(fd, b"\r")

        # Drain whatever follows; the next prompt marks the command finishing.
        tail, _ = read_until(fd, PROMPT, READ_TIMEOUT)
        sys.stdout.write(tail)
        return 0
    finally:
        try:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        except OSError:
            pass
        os.close(fd)


if __name__ == "__main__":
    sys.exit(main())
