"""The CLIs emit UTF-8 even through legacy-codepage pipes (Windows)."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parent
LEGACY = ('cp1252', 'cp936')


def cli(script, *args, encoding):
    result = subprocess.run(
        [sys.executable, str(script), *args],
        env={**os.environ, 'PYTHONIOENCODING': encoding},
        capture_output=True,
    )
    return result.returncode, result.stdout.decode('utf-8'), result.stderr.decode('utf-8')


class ConsoleEncodingTest(unittest.TestCase):
    def test_chinese_and_marks_pass_through_a_legacy_pipe(self):
        for encoding in LEGACY:
            for name, arg in (('l10n_merge.py', '--check'), ('guide_sync.py', '--help')):
                with self.subTest(encoding=encoding, script=name):
                    code, out, err = cli(TOOLS / name, arg, encoding=encoding)
                    self.assertEqual(code, 0, err)
                    self.assertEqual(err, '')

    def test_guide_error_is_utf8_on_stderr(self):
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp) / '中文仓库'
            for encoding in LEGACY:
                with self.subTest(encoding=encoding):
                    code, out, err = cli(
                        TOOLS / 'guide_sync.py', '--check', '--repo', str(repo),
                        encoding=encoding,
                    )
                    self.assertEqual(code, 1)
                    self.assertEqual(out, '')
                    self.assertIn(str(repo), err)
                    self.assertIn('missing SKILL.md', err)

    def test_a_failed_l10n_check_still_fails_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp)
            (app / 'tool').mkdir()
            shutil.copyfile(TOOLS / 'l10n_merge.py', app / 'tool/l10n_merge.py')
            parts = app / 'lib/l10n/parts'
            parts.mkdir(parents=True)
            (parts / 'probe_zh.arb').write_text(json.dumps({'onlyZh': '仅中文'}), encoding='utf-8')
            (parts / 'probe_en.arb').write_text('{}', encoding='utf-8')
            for encoding in LEGACY:
                with self.subTest(encoding=encoding):
                    code, out, err = cli(app / 'tool/l10n_merge.py', '--check', encoding=encoding)
                    self.assertEqual(code, 1)
                    self.assertIn('✗ probe: "onlyZh" has zh but no en', out)
                    self.assertEqual(err, '')
                    self.assertFalse((app / 'lib/l10n/app_zh.arb').exists())


if __name__ == '__main__':
    unittest.main()
