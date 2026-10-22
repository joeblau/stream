"""Owned diagnostic processes only. Kernel start identity fences every signal."""
import ctypes
import json
import os
import pathlib
import signal
import subprocess
import sys
import time


def identity(pid):
    if sys.platform == 'darwin':
        class BSDInfo(ctypes.Structure):
            _fields_ = [(name, ctypes.c_uint32) for name in (
                'flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid', 'rgid', 'svuid', 'svgid', 'reserved')]
            _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
            _fields_ += [(name, ctypes.c_uint32) for name in ('nfiles', 'pgid', 'jobc', 'tdev', 'tpgid', 'nice')]
            _fields_ += [('seconds', ctypes.c_uint64), ('microseconds', ctypes.c_uint64)]
        api = ctypes.CDLL('/usr/lib/libproc.dylib')
        api.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        value = BSDInfo()
        if api.proc_pidinfo(pid, 3, 0, ctypes.byref(value), ctypes.sizeof(value)) != ctypes.sizeof(value):
            return None
        # SZOMB is terminal; it cannot receive a signal or own more work.
        if value.status == 5:
            return None
        return dict(pid=value.pid, ppid=value.ppid, pgid=value.pgid, uid=value.uid,
                    birth=[value.seconds, value.microseconds])
    if sys.platform.startswith('linux'):
        try:
            root = pathlib.Path('/proc') / str(pid)
            fields = (root / 'stat').read_text().rsplit(') ', 1)[1].split()
            if fields[0] == 'Z':
                return None
            return dict(pid=pid, ppid=int(fields[1]), pgid=int(fields[2]), uid=root.stat().st_uid,
                        birth=[int(fields[19]), 0])
        except (OSError, ValueError, IndexError):
            return None
    raise RuntimeError('Unsupported owned-process identity API')


def capture(pid, parent):
    value = identity(pid)
    if not value or value['ppid'] != parent or value['uid'] != os.getuid() or value['pgid'] != pid:
        raise RuntimeError('Refused non-child or non-owned process group')
    return value


def matches(expected, current):
    return bool(current) and all(expected.get(key) == current.get(key) for key in ('pid', 'pgid', 'uid', 'birth'))


def group_members(expected):
    listing = subprocess.run(['pgrep', '-g', str(expected['pgid'])], capture_output=True, text=True, timeout=1)
    pids = [int(value) for value in listing.stdout.split() if value.isdigit()]
    if len(pids) > 64:
        raise RuntimeError('Owned group exceeds diagnostic process budget')
    return [value for pid in pids if (value := identity(pid)) and value['uid'] == expected['uid']
            and value['pgid'] == expected['pgid']]


def retire(expected, snapshot=identity, send=os.killpg, sleep=time.sleep, clock=time.monotonic, members=group_members):
    if expected['uid'] != os.getuid() or expected['pid'] != expected['pgid']:
        raise RuntimeError('Refused unowned process group')
    current = snapshot(expected['pid'])
    if not current:
        return 'absent'
    if not matches(expected, current):
        return 'replaced'
    # Capture members while the original group leader is still proven. A
    # surviving captured member pins the group's lifetime if its leader exits.
    captured_members = members(expected)
    current = snapshot(expected['pid'])
    if not current:
        return 'absent'
    if not matches(expected, current):
        return 'replaced'
    anchors = [expected] + captured_members
    live = lambda: any(matches(anchor, snapshot(anchor['pid'])) for anchor in anchors)
    for operation in (signal.SIGTERM, signal.SIGKILL):
        if not live():
            return 'drained'
        try:
            send(expected['pgid'], operation)
        except ProcessLookupError:
            return 'absent'
        deadline = clock() + 2
        while clock() < deadline:
            if not live():
                return 'drained'
            sleep(.025)
    return 'still-owned' if live() else 'drained'


def atomic_private_json(path, value):
    path = pathlib.Path(path)
    encoded = (json.dumps(value, sort_keys=True) + '\n').encode()
    if len(encoded) > 4096:
        raise RuntimeError('Owned process manifest exceeds budget')
    temporary = path.with_name(path.name + '.new-' + str(os.getpid()))
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'wb') as output:
            output.write(encoded)
            output.flush()
            os.fsync(output.fileno())
        os.link(temporary, path)  # atomic publication; never replace old evidence
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == '__main__':
    if sys.argv[1] == 'capture':
        print(json.dumps(capture(int(sys.argv[2]), int(sys.argv[3]))))
    elif sys.argv[1] == 'retire':
        encoded = sys.stdin.buffer.read(4097)
        if len(encoded) > 4096:
            raise RuntimeError('Owned identity exceeds budget')
        print(retire(json.loads(encoded)))
    else:
        raise RuntimeError('Unknown owned-process operation')
