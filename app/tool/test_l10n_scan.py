"""Portable scan output and generated-file filtering regressions."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import l10n_scan


class ScannerPortabilityTest(unittest.TestCase):
    def test_generated_directories_are_skipped_with_either_path_separator(self):
        for prefix in ('/repo/app/lib', r'C:\repo\app\lib'):
            with self.subTest(prefix=prefix):
                separator = '\\' if prefix.startswith('C:') else '/'
                rows = [(prefix + separator + 'ui', [], ['page.dart', 'page.g.dart']),
                        (prefix + separator + 'l10n', [], ['l10n.dart']),
                        (prefix + separator + 'l10n' + separator + 'gen', [], ['app_localizations_zh.dart'])]
                with patch.object(l10n_scan.os.path, 'isfile', return_value=False), \
                        patch.object(l10n_scan.os, 'walk', return_value=rows):
                    result = list(l10n_scan.dart_files([prefix]))
                self.assertEqual(len(result), 1, result)
                self.assertTrue(result[0].endswith('page.dart'))

    def test_explicit_file_request_remains_explicit(self):
        path = '/repo/app/lib/l10n/gen/app_localizations_zh.dart'
        with patch.object(l10n_scan.os.path, 'isfile', return_value=True):
            self.assertEqual(list(l10n_scan.dart_files([path])), [path])

    def test_chinese_literal_output_is_utf8_in_legacy_pipes(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'fixture.dart'
            source.write_text("final label = '你好';\n", encoding='utf-8')
            for encoding in ('cp1252', 'cp936'):
                with self.subTest(encoding=encoding):
                    result = subprocess.run(
                        [sys.executable, str(Path(l10n_scan.__file__)), str(source)],
                        env={**os.environ, 'PYTHONIOENCODING': encoding}, capture_output=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('你好', result.stdout.decode('utf-8'))
                    self.assertIn('# 1 literals in 1 files', result.stderr.decode('utf-8'))

    def test_json_output_uses_utf8_even_when_default_text_files_are_ascii(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory) / 'fixture.dart', Path(directory) / 'result.json'
            source.write_text("final label = '你好';\n", encoding='utf-8')
            environment = {**os.environ, 'LC_ALL': 'C', 'LANG': 'C',
                           'PYTHONUTF8': '0', 'PYTHONCOERCECLOCALE': '0',
                           'PYTHONIOENCODING': 'cp1252'}
            result = subprocess.run(
                [sys.executable, str(Path(l10n_scan.__file__)), '--json', str(output), str(source)],
                env=environment, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(output.read_bytes().decode('utf-8')), {str(source): [[1, '你好']]})


if __name__ == '__main__':
    unittest.main()
