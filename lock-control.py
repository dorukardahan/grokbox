#!/usr/bin/env python3
"""Linux backup-lock inspection and explicit, pidfd-safe emergency termination."""
import argparse
import os
import signal
import time
from pathlib import Path


def holds(pid, path):
    try:
        target = os.stat(path)
        for fd in Path(f'/proc/{pid}/fd').iterdir():
            try:
                st = fd.stat()
                if ((st.st_dev, st.st_ino) == (target.st_dev, target.st_ino) and
                        "FLOCK" in Path(f"/proc/{pid}/fdinfo/{fd.name}").read_text()):
                    return True
            except OSError:
                pass
    except OSError:
        pass
    return False


def processes():
    result = {}
    for proc in Path('/proc').iterdir():
        if not proc.name.isdigit():
            continue
        try:
            raw = (proc / 'stat').read_text()
            fields = raw[raw.rfind(')') + 2:].split()
            result[int(proc.name)] = (int(fields[1]), int(fields[2]), fields[19])
        except (OSError, ValueError, IndexError):
            pass
    return result


def holders(path):
    return [p for p in processes() if holds(p, path)]


def force(path):
    # Pin identities before signalling: a recycled pid can never receive a signal.
    if not hasattr(os, 'pidfd_open') or not hasattr(signal, 'pidfd_send_signal'):
        raise RuntimeError('pidfd support is required; refusing unsafe termination')
    table = processes()
    pinned = {}
    try:
        # Validate and pin roots before deriving descendants. A stale root PID must
        # never authorize signalling a recycled process's children.
        for pid in table:
            if not holds(pid, path):
                continue
            try:
                fd = os.pidfd_open(pid)
                if processes().get(pid) != table[pid] or not holds(pid, path):
                    os.close(fd)
                    continue
                pinned[pid] = fd
            except ProcessLookupError:
                pass
        if not pinned:
            raise RuntimeError('lock holder cannot be verified through /proc; refusing --force')
        selected = set(pinned)
        while True:
            new = {p for p, (parent, group, _) in table.items()
                   if parent in selected or group in selected}
            if new <= selected:
                break
            selected |= new
        if os.getpid() in selected or os.getppid() in selected:
            raise RuntimeError('holder shares the recovery process; refusing --force')
        for pid in selected - pinned.keys():
            try:
                fd = os.pidfd_open(pid)
                if processes().get(pid) != table[pid]:
                    os.close(fd)
                    continue
                pinned[pid] = fd
            except ProcessLookupError:
                pass
        for sig in (signal.SIGTERM, signal.SIGKILL):
            for fd in pinned.values():
                try:
                    signal.pidfd_send_signal(fd, sig)
                except ProcessLookupError:
                    pass
            if sig == signal.SIGTERM:
                # Escaped rclone groups remain pinned even if the parent exits first.
                import select
                poll = select.poll()
                for fd in pinned.values():
                    poll.register(fd, select.POLLIN)
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    if len(poll.poll(100)) == len(pinned):
                        break
        deadline = time.monotonic() + 2
        remaining = holders(path)
        while remaining and time.monotonic() < deadline:
            time.sleep(.05)
            remaining = holders(path)
        if remaining:
            raise RuntimeError('lock still held after termination by PIDs: ' +
                               ', '.join(map(str, remaining)))
        print('Verified lock job terminated (including inherited holders and descendants).')
    finally:
        for fd in pinned.values():
            os.close(fd)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['holds', 'holders', 'force', 'stop'])
    parser.add_argument('path')
    parser.add_argument('pid', nargs='?', type=int)
    args = parser.parse_args()
    if args.action == 'holds':
        raise SystemExit(0 if holds(args.pid, args.path) else 1)
    if args.action == 'holders':
        for pid in holders(args.path):
            try:
                name = Path(f'/proc/{pid}/comm').read_text().strip()
            except OSError:
                name = 'exited'
            print(f'{pid} ({name})')
    else:
        try:
            if args.action == 'stop':
                if not hasattr(os, 'pidfd_open') or not hasattr(signal, 'pidfd_send_signal'):
                    raise RuntimeError('pidfd support is required; refusing unsafe scheduler stop')
                fd = os.pidfd_open(args.pid)
                try:
                    if not holds(args.pid, args.path):
                        raise RuntimeError('process no longer holds the lock; refusing signal')
                    signal.pidfd_send_signal(fd, signal.SIGTERM)
                finally:
                    os.close(fd)
            else:
                force(args.path)
        except (OSError, RuntimeError, AttributeError) as exc:
            parser.exit(1, f'{exc}\n')
