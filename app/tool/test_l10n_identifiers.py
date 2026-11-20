"""Boundary regression tests for the source ARB key contract."""
from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile
import unittest


class IdentifierTests(unittest.TestCase):
    def run_merge(self, key, mode):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        app = Path(temporary.name) / 'app'
        (app / 'tool').mkdir(parents=True)
        parts = app / 'lib/l10n/parts'
        parts.mkdir(parents=True)
        script = app / 'tool/l10n_merge.py'
        shutil.copy2(Path(__file__).with_name('l10n_merge.py'), script)
        for locale, text in [('zh', '示例'), ('en', 'Example')]:
            (parts / f'example_{locale}.arb').write_text(
                json.dumps({'@@locale': locale, key: text}, ensure_ascii=False), encoding='utf-8')
        result = subprocess.run([sys.executable, '-B', str(script), mode],
                                capture_output=True, text=True, encoding='utf-8')
        return result, app / 'lib/l10n'

    def test_trailing_newline_cannot_pass_check_as_an_identifier(self):
        result, _ = self.run_merge('exampleKey\n', '--check')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('bad key', result.stdout + result.stderr)

    def test_invalid_identifier_cannot_write_generated_arbs(self):
        result, output = self.run_merge('exampleKey\n', '--no-gen')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('bad key', result.stdout + result.stderr)
        self.assertFalse((output / 'app_zh.arb').exists())
        self.assertFalse((output / 'app_en.arb').exists())

    def test_valid_lower_camel_identifier_still_passes(self):
        result, _ = self.run_merge('exampleKey2', '--check')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
