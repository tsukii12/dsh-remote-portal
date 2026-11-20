"""Offline source/translation lifecycle regression tests."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import l10n_catalog as catalog


class RepositoryFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.parts = self.root / 'app/lib/l10n/parts'
        self.parts.mkdir(parents=True)
        self.write_area('common', {'title': '标题', 'count': '{n} 项',
                                  '@count': {'placeholders': {'n': {'type': 'int'}}}},
                        {'title': 'Title', 'count': '{n} items'})

    def write_area(self, area, zh, en):
        for lang, data in [('zh', zh), ('en', en)]:
            (self.parts / f'{area}_{lang}.arb').write_text(
                json.dumps(data, ensure_ascii=False), encoding='utf-8')

    def state(self, snapshot, entries):
        records = {}
        for key, text, review, locked in entries:
            records[key] = {'text': text, 'sourceHash': snapshot['entries'][key]['sourceHash'],
                            'translationHash': catalog.canonical_hash(text), 'review': review, 'locked': locked}
        return {'format': 'dsh-go-i18n-translations', 'schemaVersion': 1, 'locale': 'ru', 'entries': records}


class FingerprintTest(RepositoryFixture):
    def test_hash_is_independent_of_json_member_order(self):
        left = {'area': 'common', 'zh': '标题', 'en': 'Title', 'metadata': {}}
        right = {'metadata': {}, 'en': 'Title', 'zh': '标题', 'area': 'common'}
        self.assertEqual(catalog.canonical_hash(left), catalog.canonical_hash(right))
        self.assertNotEqual(catalog.canonical_hash('Отмена'), catalog.canonical_hash('Cancel'))

    def test_all_context_fields_change_the_source_hash(self):
        before = catalog.build_snapshot(self.root)['entries']['title']
        payload = {key: before[key] for key in ('area', 'zh', 'en', 'metadata')}
        for field, value in [('area', 'moved'), ('zh', '标题二'), ('en', 'New title'),
                             ('metadata', {'description': 'A changed context'})]:
            with self.subTest(field=field):
                changed = {**payload, field: value}
                self.assertNotEqual(catalog.canonical_hash(changed), before['sourceHash'])

    def test_metrics_are_characters_and_whitespace_words(self):
        snapshot = catalog.build_snapshot(self.root)
        self.assertEqual(snapshot['metrics'], {'keys': 2, 'zhCharacters': 7,
                                              'enCharacters': 14, 'enWhitespaceWords': 3})
        self.assertEqual(catalog.validate_snapshot(snapshot), snapshot)

    def test_missing_pair_duplicate_area_and_bad_metadata_are_rejected(self):
        (self.parts / 'common_en.arb').unlink()
        with self.assertRaisesRegex(catalog.CatalogError, 'missing en'):
            catalog.build_snapshot(self.root)
        self.write_area('common', {'title': '标题'}, {'title': 'Title'})
        self.write_area('second', {'title': '重复'}, {'title': 'Duplicate'})
        with self.assertRaisesRegex(catalog.CatalogError, 'duplicate message across areas'):
            catalog.build_snapshot(self.root)
        for path in self.parts.glob('second_*.arb'):
            path.unlink()
        self.write_area('common', {'title': '标题', '@title': {'placeholders': []}}, {'title': 'Title'})
        with self.assertRaisesRegex(catalog.CatalogError, 'placeholders must map'):
            catalog.build_snapshot(self.root)

    def test_snapshot_tampering_and_unknown_fields_are_rejected(self):
        snapshot = catalog.build_snapshot(self.root)
        for mutation, needle in [
            (lambda s: s['entries']['title'].update(en='Tampered'), 'sourceHash mismatch'),
            (lambda s: s.update(approval='trusted'), 'unknown fields'),
            (lambda s: s['entries']['title'].update(extra='ignored'), 'unknown fields'),
            (lambda s: s['metrics'].update(keys=999), 'metrics do not match'),
            (lambda s: s['metrics'].update(keys=2.0), 'non-negative integers'),
            (lambda s: s.update(schemaVersion=True), 'unsupported catalog'),
        ]:
            with self.subTest(needle=needle):
                value = copy.deepcopy(snapshot)
                mutation(value)
                with self.assertRaisesRegex(catalog.CatalogError, needle):
                    catalog.validate_snapshot(value)


class TranslationPlanTest(RepositoryFixture):
    def test_diff_has_all_four_categories_and_preserves_retired_text(self):
        self.write_area('common', {'same': '相同', 'changed': '原始', 'removed': '移除'},
                        {'same': 'Same', 'changed': 'Before', 'removed': 'Removed'})
        previous = catalog.build_snapshot(self.root)
        state = self.state(previous, [('removed', 'Сохранить перевод', 'human-reviewed', True)])
        self.write_area('common', {'same': '相同', 'changed': '更新', 'added': '新增'},
                        {'same': 'Same', 'changed': 'After', 'added': 'Added'})
        current = catalog.build_snapshot(self.root)
        plan = catalog.make_plan(current, previous, 'ru', state)
        self.assertEqual(plan['sourceDiff'], {'new': ['added'], 'changed': ['changed'],
                                            'removed': ['removed'], 'unchanged': ['same']})
        self.assertEqual(plan['retiredTranslations']['removed'], state['entries']['removed'])
        self.assertEqual(plan['freshness']['removed'], 'removed')
        self.assertNotIn('removed', [item['key'] for item in plan['translationQueue']])

    def test_human_reviewed_and_locked_translations_are_never_machine_replacements(self):
        previous = catalog.build_snapshot(self.root)
        state = self.state(previous, [('title', 'Ручной заголовок', 'human-reviewed', False),
                                      ('count', '{n} пунктов', 'ai-draft', True)])
        original_state = copy.deepcopy(state)
        self.write_area('common', {'title': '新标题', 'count': '有 {n} 项'},
                        {'title': 'New title', 'count': 'There are {n} items'})
        current = catalog.build_snapshot(self.root)
        plan = catalog.make_plan(current, previous, 'ru', state)
        self.assertEqual(plan['translationQueue'], [])
        self.assertEqual([item['key'] for item in plan['humanReviewQueue']], ['count', 'title'])
        self.assertEqual(plan['preservedTranslations'], original_state['entries'])
        self.assertEqual(plan['freshness'], {'count': 'stale', 'title': 'stale'})
        self.assertEqual(state, original_state)
        for item in plan['humanReviewQueue']:
            self.assertEqual(item['sourceHash'], current['entries'][item['key']]['sourceHash'])
            self.assertNotEqual(item['sourceHash'], original_state['entries'][item['key']]['sourceHash'])

    def test_changed_unlocked_ai_draft_is_queued_but_its_text_is_preserved(self):
        previous = catalog.build_snapshot(self.root)
        state = self.state(previous, [('title', 'Черновик', 'ai-draft', False),
                                      ('count', '{n} элементов', 'ai-draft', False)])
        self.write_area('common', {'title': '新标题', 'count': '{n} 项',
                                  '@count': {'placeholders': {'n': {'type': 'int'}}}},
                        {'title': 'New title', 'count': '{n} items'})
        current = catalog.build_snapshot(self.root)
        plan = catalog.make_plan(current, previous, 'ru', state)
        self.assertEqual([item['key'] for item in plan['translationQueue']], ['title'])
        self.assertEqual(plan['translationQueue'][0]['sourceHash'], current['entries']['title']['sourceHash'])
        self.assertEqual(plan['preservedTranslations'], state['entries'])
        self.assertEqual(plan['freshness'], {'count': 'current', 'title': 'stale'})

    def test_missing_translations_are_queued_even_when_source_is_unchanged(self):
        snapshot = catalog.build_snapshot(self.root)
        plan = catalog.make_plan(snapshot, snapshot, 'ru')
        self.assertEqual(plan['sourceDiff']['changed'], [])
        self.assertEqual([item['key'] for item in plan['translationQueue']], ['count', 'title'])
        self.assertEqual(plan['metrics']['translationQueue'], snapshot['metrics'])

    def test_unknown_translation_key_does_not_disappear_silently(self):
        snapshot = catalog.build_snapshot(self.root)
        state = self.state(snapshot, [('title', 'Заголовок', 'ai-draft', False)])
        state['entries']['unknown'] = state['entries'].pop('title')
        with self.assertRaisesRegex(catalog.CatalogError, 'absent from both source catalogs'):
            catalog.make_plan(snapshot, snapshot, 'ru', state)

    def test_changed_translation_cannot_reuse_its_review_hash(self):
        snapshot = catalog.build_snapshot(self.root)
        state = self.state(snapshot, [('title', 'Согласованный перевод', 'human-reviewed', False)])
        state['entries']['title']['text'] = 'Changed after review'
        with self.assertRaisesRegex(catalog.CatalogError, 'translationHash mismatch'):
            catalog.make_plan(snapshot, snapshot, 'ru', state)

    def test_invalid_state_shapes_and_unknown_fields_fail(self):
        snapshot = catalog.build_snapshot(self.root)
        original = self.state(snapshot, [('title', 'Заголовок', 'ai-draft', False)])
        for mutation in [lambda s: s.update(extra=True), lambda s: s.update(locale='es'),
                         lambda s: s['entries']['title'].update(locked='false'),
                         lambda s: s['entries']['title'].update(sourceHash='bad'),
                         lambda s: s['entries']['title'].update(review='automatically-approved'),
                         lambda s: s['entries']['title'].update(extra='unknown')]:
            state = copy.deepcopy(original)
            mutation(state)
            with self.subTest(state=state), self.assertRaises(catalog.CatalogError):
                catalog.make_plan(snapshot, snapshot, 'ru', state)


class CliAndJsonTest(RepositoryFixture):
    def cli(self, *args):
        return subprocess.run([sys.executable, str(Path(catalog.__file__)), *args],
                              capture_output=True, text=True, encoding='utf-8')

    def test_duplicate_json_keys_at_any_depth_and_constants_fail(self):
        path = self.root / 'bad.json'
        for value in ['{"x":1,"x":2}', '{"x":{"nested":1,"nested":2}}', '{"x":NaN}']:
            with self.subTest(value=value):
                path.write_text(value, encoding='utf-8')
                with self.assertRaises(catalog.CatalogError):
                    catalog.read_json(path)

    def test_new_output_only_deterministic_bytes_and_no_source_changes(self):
        before = {p.name: p.read_bytes() for p in self.parts.iterdir()}
        first, second = self.root / 'first.json', self.root / 'second.json'
        for output in (first, second):
            result = self.cli('snapshot', '--repo', str(self.root), '--output', str(output))
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        original = first.read_bytes()
        result = self.cli('snapshot', '--repo', str(self.root), '--output', str(first))
        self.assertEqual(result.returncode, 1)
        self.assertIn('output already exists', result.stderr)
        self.assertEqual(first.read_bytes(), original)
        self.assertEqual({p.name: p.read_bytes() for p in self.parts.iterdir()}, before)
        self.assertEqual(list(self.parts.parent.glob('app_*.arb')), [])

    def test_plan_cli_does_not_modify_state_or_previous_snapshot(self):
        snapshot = catalog.build_snapshot(self.root)
        state = self.state(snapshot, [('title', 'Заголовок', 'human-reviewed', True)])
        previous, translations, output = [self.root / name for name in ('old.json', 'state.json', 'plan.json')]
        catalog.write_new_json(previous, snapshot)
        catalog.write_new_json(translations, state)
        original = (previous.read_bytes(), translations.read_bytes())
        result = self.cli('plan', '--repo', str(self.root), '--locale', 'ru', '--previous', str(previous),
                          '--translations', str(translations), '--output', str(output))
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = catalog.read_json(output)
        self.assertEqual(plan['preservedTranslations']['title'], state['entries']['title'])
        self.assertEqual([item['key'] for item in plan['translationQueue']], ['count'])
        self.assertEqual((previous.read_bytes(), translations.read_bytes()), original)

    def test_invalid_json_diagnostic_never_repeats_source_text(self):
        previous = self.root / 'bad.json'
        previous.write_text('{"text": "do-not-print-this-full-value" BROKEN}', encoding='utf-8')
        output = self.root / 'plan.json'
        result = self.cli('plan', '--repo', str(self.root), '--locale', 'ru', '--previous', str(previous),
                          '--output', str(output))
        self.assertEqual(result.returncode, 1)
        self.assertIn('invalid JSON at line', result.stderr)
        self.assertNotIn('do-not-print-this-full-value', result.stdout + result.stderr)
        self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
