#!/usr/bin/env python3
"""Exercise the shipped cleanup against mount-table fixtures, without root."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SOURCE = (ROOT / 'switcher/assets/guest_prepare.sh').read_text()
BLOCK = SOURCE.split('for d in $SPLIT_DIRS; do', 1)[1].split('rm -f "$STAGE"/oneos_split_*.xml', 1)[0]
BLOCK = 'for d in $SPLIT_DIRS; do' + BLOCK

class PermissionCleanup(unittest.TestCase):
    def test_only_own_split_binds_are_removed(self):
        for shortened in (False, True):
            with self.subTest(shortened=shortened), tempfile.TemporaryDirectory() as t:
                root = Path(t); perms = root / 'permissions'; perms.mkdir()
                stage = '/data/local/tmp/oneos'
                sources = {
                    'split.xml': stage + '/oneos_split_1.xml',
                    'features.xml': stage + '/oplus_features_config.xml',
                    'unrelated.xml': stage + '/some-other.xml',
                    'foreign.xml': stage + '.old-123/oneos_split_2.xml',
                    'invalid.xml': stage + '/oneos_split_3oops.xml',
                }
                table = root / 'mountinfo'
                lines = []
                for i, (name, source) in enumerate(sources.items()):
                    (perms / name).write_text('<permissions/>')
                    if shortened: source = source.removeprefix('/data')
                    lines.append(f'{100+i} 1 254:80 {source} {perms/name} rw - f2fs /dev/block/dm-80 rw\n')
                table.write_text(''.join(lines))
                log = root / 'unmounts'; bb = root / 'busybox'
                bb.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$UNMOUNT_LOG"\n')
                bb.chmod(0o755)
                script = BLOCK.replace('/proc/self/mountinfo', str(table))
                env = dict(os.environ, STAGE=stage, SPLIT_DIRS=str(perms), BB=str(bb), UNMOUNT_LOG=str(log))
                subprocess.run(['/bin/sh', '-c', script], env=env, check=True)
                self.assertEqual([f'umount -l {perms / "split.xml"}'], log.read_text().splitlines())

    def test_fold8_overlay_is_installed_after_system_ext_overlay(self):
        self.assertLess(SOURCE.index('"$GUEST_SYSTEM_EXT" && echo "Overlay on'), SOURCE.index('"$STAGE/fold8_coloros.sh" prepare'))

if __name__ == '__main__':
    unittest.main()
