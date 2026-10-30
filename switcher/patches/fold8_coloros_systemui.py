#!/usr/bin/env python3
"""Apply the tested Find N6 SystemUI changes, checking every class before writing.

Usage: fold8_coloros_systemui.py <apktool decoded SystemUI directory>
Prints the smali directories to rebuild, like the other framework patchers.
Unknown or partly patched classes are refused; rerunning a complete patch is safe.
"""
import hashlib
import json
from pathlib import Path
import re
import sys

BUNDLE = Path(__file__).with_name('fold8-coloros')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def apply_hunks(original, diff):
    lines = original.splitlines(keepends=True)
    out, cursor = [], 0
    parts = re.split(r'^@@ -([0-9]+)(?:,([0-9]+))? \+[0-9]+(?:,[0-9]+)? @@[^\n]*\n', diff, flags=re.M)
    for i in range(1, len(parts), 3):
        start, count, body = int(parts[i]) - 1, int(parts[i + 1] or '1'), parts[i + 2]
        old, new = [], []
        for line in body.splitlines(keepends=True):
            if line.startswith((' ', '-')):
                old.append(line[1:])
            if line.startswith((' ', '+')):
                new.append(line[1:])
        if start < cursor or len(old) != count or lines[start:start + count] != old:
            raise ValueError('SystemUI patch context differs; rebuild the port for this image')
        out.extend(lines[cursor:start]); out.extend(new)
        cursor = start + count
    out.extend(lines[cursor:])
    return ''.join(out)


def patch(root):
    pins = json.loads((BUNDLE / 'classes.json').read_text())
    changes = {}
    diffs = re.split(r'^--- a/', (BUNDLE / 'systemui.patch').read_text(), flags=re.M)[1:]
    for section in diffs:
        name, body = section.split('\n', 1)
        changes[name] = body.split('\n', 1)[1]
    pending = {}
    for name, pin in pins.items():
        target = root / name
        data = target.read_bytes() if target.exists() else None
        if data is not None and digest(data) == pin['after']:
            continue
        if pin['before'] is None:
            if data is not None:
                raise ValueError(f'{name}: helper already exists with different code')
            result = (BUNDLE / name).read_bytes()
        else:
            if data is None or digest(data) != pin['before']:
                raise ValueError(f'{name}: not the supported Find N6 class')
            result = apply_hunks(data.decode(), changes[name]).encode()
        if digest(result) != pin['after']:
            raise ValueError(f'{name}: patched class checksum differs')
        pending[target] = result
    # Validate everything first: an unknown class leaves the whole tree untouched.
    for target, data in pending.items():
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    return sorted({name.split('/')[0] for name in pins})


if __name__ == '__main__':
    try:
        print(' '.join(patch(Path(sys.argv[1]))))
    except (ValueError, OSError) as exc:
        sys.exit(str(exc))
