#!/usr/bin/env python3
"""Bound untrusted producer output BEFORE it reaches Quickshell collectors.

Linux only (Omarchy): each producer gets its own process group. This helper
acts as a subreaper so orphaned grandchildren are collected as well. Nothing
is forwarded until both streams reach EOF and the producer exits successfully.
"""

import ctypes
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import time

INPUT_LIMIT = 4 * 1024
TERM_LIMIT = 1024
OUTPUT_LIMIT = 256 * 1024
STDERR_LIMIT = 8 * 1024
SELECTION_SECONDS = 2.0
PASTE_SECONDS = 1.0
QUERY_SECONDS = 5.0
KILL_GRACE = 0.1

OVERFLOW = 65
INVALID = 66
FAILED = 70
CANCELLED = 75
TIMED_OUT = 124
cancelled = False


class Rejected(Exception):
    def __init__(self, code):
        self.code = code


def cancel(_signum, _frame):
    global cancelled
    cancelled = True


def check_deadline(deadline):
    if cancelled:
        raise Rejected(CANCELLED)
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise Rejected(TIMED_OUT)
    return remaining


def enable_subreaper():
    # PR_SET_CHILD_SUBREAPER: adopted descendants can be waitpid()'d here,
    # without relying on the desktop session's PID 1 to collect zombies.
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:
        raise Rejected(FAILED)


def signal_group(pid, sig):
    try:
        os.killpg(pid, sig)
    except ProcessLookupError:
        pass


def terminate_and_reap(proc):
    # Always clean up the group, including when its leader already exited or
    # descendants closed their pipes. Closing readers also unblocks writers.
    proc.stdout.close()
    proc.stderr.close()
    signal_group(proc.pid, signal.SIGTERM)
    time.sleep(KILL_GRACE)
    signal_group(proc.pid, signal.SIGKILL)
    proc.wait()
    while True:
        try:
            os.waitpid(-proc.pid, 0)
        except ChildProcessError:
            break


def collect(command, limit, deadline):
    check_deadline(deadline)
    proc = subprocess.Popen(
        command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, start_new_session=True, close_fds=True,
    )
    output = bytearray()
    sizes = [0, 0]
    limits = [limit, STDERR_LIMIT]
    try:
        with selectors.DefaultSelector() as selector:
            for index, stream in enumerate((proc.stdout, proc.stderr)):
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ, index)
            # EOF alone is insufficient: a producer can close its streams and
            # keep running. Conversely, descendants may hold an exited
            # parent's streams open. Both cases share the same deadline.
            while selector.get_map() or proc.poll() is None:
                remaining = check_deadline(deadline)
                events = selector.select(min(remaining, 0.05))
                for key, _mask in events:
                    index = key.data
                    # Read at most the remaining allowance plus ONE sentinel
                    # byte. No unbounded read(), communicate(), or shell $().
                    chunk = os.read(key.fd, min(8192, limits[index] - sizes[index] + 1))
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    sizes[index] += len(chunk)
                    if sizes[index] > limits[index]:
                        raise Rejected(OVERFLOW)
                    if index == 0:
                        output.extend(chunk)
                    # Count stderr, but never forward arbitrary diagnostics.
            check_deadline(deadline)
            code = proc.wait()
    finally:
        terminate_and_reap(proc)
    return code, bytes(output)


def decode(data):
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeError:
        raise Rejected(INVALID) from None
    if "\0" in text:
        raise Rejected(INVALID)
    return text


def term_bytes(text):
    data = text.encode("utf-8", errors="strict")
    if len(data) > TERM_LIMIT:
        raise Rejected(OVERFLOW)
    if "\0" in text:
        raise Rejected(INVALID)
    return data


def clipboard(primary, deadline):
    command = ["wl-paste", "--type", "text", "--no-newline"]
    if primary:
        command.append("--primary")
    code, data = collect(command, INPUT_LIMIT, deadline)
    # No offered text is normal for selection fallback. Overflow, timeout,
    # and invalid encoding are never treated as an empty successful read.
    return decode(data) if code == 0 else ""


def selection(args, deadline):
    if args and args[0]:
        return term_bytes(args[0])
    cache = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "omarchy-dict"
    primary_first = True
    try:
        primary_first = (cache / "primary.time").stat().st_mtime_ns >= (cache / "clipboard.time").stat().st_mtime_ns
    except OSError:
        pass
    # Preserve dict-watch's source preference without executing lib.sh, whose
    # internal shell variables could grow before an outer limiter saw output.
    text = clipboard(primary_first, min(deadline, time.monotonic() + PASTE_SECONDS))
    if not text.strip():
        text = clipboard(not primary_first, min(deadline, time.monotonic() + PASTE_SECONDS))
    text = text.split("\n", 1)[0].strip()
    text = re.sub(r"^[\W_]+|[\W_]+$", "", text)
    words = re.findall(r"[^\W\d_][^\W\d_'-]*(?:['-][^\W\d_]+)*", text)
    if len(words) > 4:
        text = max(words, key=len)
    return term_bytes(text)


def produce(args, deadline):
    mode = args[0]
    if mode == "selection" and len(args) <= 2:
        return selection(args[1:], deadline)
    if mode == "paste" and len(args) == 1:
        code, data = collect(["wl-paste", "--no-newline", "--type", "text/plain"], INPUT_LIMIT, deadline)
    elif mode == "query" and len(args) == 3 and args[1] in ("exact", "fuzzy"):
        term_bytes(args[2])
        command = ["sdcv", "-n", "-j"]
        if args[1] == "exact":
            command.append("-e")
        command.extend(["--", args[2]])
        code, data = collect(command, OUTPUT_LIMIT, deadline)
    else:
        raise Rejected(INVALID)
    if code != 0:
        raise Rejected(FAILED)
    decode(data)
    return data


def emit(data, deadline):
    # Include forwarding in the deadline, even if the consumer stops reading.
    fd = sys.stdout.fileno()
    os.set_blocking(fd, False)
    with selectors.PollSelector() as selector:
        selector.register(fd, selectors.EVENT_WRITE)
        offset = 0
        while offset < len(data):
            remaining = check_deadline(deadline)
            if selector.select(min(remaining, 0.05)):
                try:
                    offset += os.write(fd, data[offset:offset + 8192])
                except BlockingIOError:
                    pass


def main():
    args = sys.argv[1:]
    seconds = {"selection": SELECTION_SECONDS, "paste": PASTE_SECONDS, "query": QUERY_SECONDS}
    if not args or args[0] not in seconds:
        return INVALID
    deadline = time.monotonic() + seconds[args[0]]
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, cancel)
    try:
        enable_subreaper()
        data = produce(args, deadline)
        check_deadline(deadline)
        emit(data, deadline)
        return 0
    except Rejected as error:
        return error.code
    except (OSError, UnicodeError, ValueError):
        return FAILED


if __name__ == "__main__":
    sys.exit(main())
