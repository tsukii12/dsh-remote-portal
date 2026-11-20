#!/usr/bin/env python3
"""Create source fingerprints and reviewable translation plans, entirely offline.

This tool never invokes a model, edits ARBs/translations, or activates a locale.
It creates new JSON files only; existing paths are never overwritten.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[2]
HASH_ALGORITHM = 'sha256-canonical-source-v1'
KEY_RE = re.compile(r'^[a-z][a-zA-Z0-9]*$')
HASH_RE = re.compile(r'^[0-9a-f]{64}$')
LOCALE_RE = re.compile(r'^[a-z]{2,3}(?:_[A-Z][a-z]{3})?(?:_(?:[A-Z]{2}|[0-9]{3}))?$')


class CatalogError(ValueError):
    """A concise diagnostic that does not include complete source/target text."""


def canonical_hash(value):
    """Matches the translation draft manifest's source and translation hashes."""
    try:
        encoded = json.dumps(value, ensure_ascii=False, sort_keys=True,
                             separators=(',', ':'), allow_nan=False).encode('utf-8')
    except (ValueError, UnicodeError, TypeError) as exc:
        raise CatalogError('value cannot be encoded as canonical UTF-8 JSON') from exc
    return hashlib.sha256(encoded).hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise CatalogError(f'duplicate JSON key: {key[:80]!r}')
        result[key] = value
    return result


def reject_constant(_value):
    raise CatalogError('non-JSON numeric constant')


def read_json(path):
    try:
        with Path(path).open(encoding='utf-8') as stream:
            return json.load(stream, object_pairs_hook=unique_object, parse_constant=reject_constant)
    except json.JSONDecodeError as exc:
        raise CatalogError(f'{Path(path).name}: invalid JSON at line {exc.lineno}, column {exc.colno}') from exc
    except UnicodeError as exc:
        raise CatalogError(f'{Path(path).name}: invalid UTF-8') from exc


def object_fields(value, expected, label):
    if not isinstance(value, dict):
        raise CatalogError(f'{label}: expected an object')
    missing, unknown = set(expected) - value.keys(), value.keys() - set(expected)
    if missing or unknown:
        raise CatalogError(f'{label}: missing fields {sorted(missing)}, unknown fields {sorted(unknown)}')


def message_payload(value, label):
    object_fields(value, ('area', 'zh', 'en', 'metadata'), label)
    for field in ('area', 'zh', 'en'):
        if not isinstance(value[field], str) or not value[field].strip():
            raise CatalogError(f'{label}: {field} must be a non-empty string')
    meta = value['metadata']
    if not isinstance(meta, dict):
        raise CatalogError(f'{label}: metadata must be an object')
    if 'placeholders' in meta:
        placeholders = meta['placeholders']
        if not isinstance(placeholders, dict) or any(not isinstance(v, dict) for v in placeholders.values()):
            raise CatalogError(f'{label}: placeholders must map names to objects')


def source_metrics(entries):
    return {
        'keys': len(entries),
        'zhCharacters': sum(len(entry['zh']) for entry in entries.values()),
        'enCharacters': sum(len(entry['en']) for entry in entries.values()),
        'enWhitespaceWords': sum(len(entry['en'].split()) for entry in entries.values()),
    }


def build_snapshot(repo=ROOT):
    parts = Path(repo) / 'app/lib/l10n/parts'
    if not parts.is_dir():
        raise CatalogError('source repository has no app/lib/l10n/parts directory')
    areas = sorted({p.name[:-7] for lang in ('zh', 'en') for p in parts.glob(f'*_{lang}.arb')})
    if not areas:
        raise CatalogError('source catalog is empty')
    entries = {}
    for area in areas:
        data = {}
        for lang in ('zh', 'en'):
            path = parts / f'{area}_{lang}.arb'
            if not path.is_file():
                raise CatalogError(f'{area}: missing {lang} source fragment')
            data[lang] = read_json(path)
            if not isinstance(data[lang], dict):
                raise CatalogError(f'{area}/{lang}: ARB root must be an object')
            if '@@locale' in data[lang] and data[lang]['@@locale'] != lang:
                raise CatalogError(f'{area}/{lang}: @@locale does not match the filename')
            for key, value in data[lang].items():
                if key.startswith('@') and not key.startswith('@@'):
                    if key[1:] not in data[lang] or not isinstance(value, dict):
                        raise CatalogError(f'{area}/{lang}/{key}: orphan or non-object metadata')
        zh_keys = {key for key in data['zh'] if not key.startswith('@')}
        en_keys = {key for key in data['en'] if not key.startswith('@')}
        if zh_keys != en_keys:
            changed = sorted(zh_keys ^ en_keys)
            raise CatalogError(f'{area}: zh/en keys differ: {changed}')
        for key in sorted(zh_keys):
            if not KEY_RE.fullmatch(key):
                raise CatalogError(f'{area}: invalid message key {key[:80]!r}')
            if key in entries:
                raise CatalogError(f'{key}: duplicate message across areas')
            payload = {'area': area, 'zh': data['zh'][key], 'en': data['en'][key],
                       'metadata': data['zh'].get('@' + key, {})}
            message_payload(payload, key)
            entries[key] = {**payload, 'sourceHash': canonical_hash(payload)}
    entries = dict(sorted(entries.items()))
    return {'format': 'dsh-go-i18n-catalog', 'schemaVersion': 1,
            'sourceHashAlgorithm': HASH_ALGORITHM, 'entries': entries,
            'metrics': source_metrics(entries)}


def validate_snapshot(snapshot):
    object_fields(snapshot, ('format', 'schemaVersion', 'sourceHashAlgorithm', 'entries', 'metrics'), 'catalog')
    if snapshot['format'] != 'dsh-go-i18n-catalog' or type(snapshot['schemaVersion']) is not int or snapshot['schemaVersion'] != 1:
        raise CatalogError('unsupported catalog format/version')
    if snapshot['sourceHashAlgorithm'] != HASH_ALGORITHM or not isinstance(snapshot['entries'], dict):
        raise CatalogError('unsupported catalog hash algorithm or entries shape')
    for key, entry in snapshot['entries'].items():
        if not KEY_RE.fullmatch(key):
            raise CatalogError('catalog contains an invalid message key')
        object_fields(entry, ('area', 'zh', 'en', 'metadata', 'sourceHash'), key)
        payload = {name: entry[name] for name in ('area', 'zh', 'en', 'metadata')}
        message_payload(payload, key)
        if entry['sourceHash'] != canonical_hash(payload):
            raise CatalogError(f'{key}: catalog sourceHash mismatch')
    object_fields(snapshot['metrics'], ('keys', 'zhCharacters', 'enCharacters', 'enWhitespaceWords'), 'catalog metrics')
    if any(type(value) is not int or value < 0 for value in snapshot['metrics'].values()):
        raise CatalogError('catalog metrics must be non-negative integers')
    if snapshot['metrics'] != source_metrics(snapshot['entries']):
        raise CatalogError('catalog metrics do not match its entries')
    return snapshot


def validate_translations(state, locale, known_keys):
    object_fields(state, ('format', 'schemaVersion', 'locale', 'entries'), 'translation state')
    if state['format'] != 'dsh-go-i18n-translations' or type(state['schemaVersion']) is not int or state['schemaVersion'] != 1:
        raise CatalogError('unsupported translation state format/version')
    if state['locale'] != locale or not isinstance(state['entries'], dict):
        raise CatalogError('translation state locale or entries shape does not match the request')
    for key, entry in state['entries'].items():
        if key not in known_keys:
            raise CatalogError(f'{key[:80]!r}: translation key is absent from both source catalogs')
        object_fields(entry, ('text', 'sourceHash', 'translationHash', 'review', 'locked'), key)
        if not isinstance(entry['text'], str) or not entry['text'].strip():
            raise CatalogError(f'{key}: translation text must be non-empty')
        if not isinstance(entry['sourceHash'], str) or not HASH_RE.fullmatch(entry['sourceHash']):
            raise CatalogError(f'{key}: invalid sourceHash')
        if entry['translationHash'] != canonical_hash(entry['text']):
            raise CatalogError(f'{key}: translationHash mismatch; do not retain an old review for changed text')
        if entry['review'] not in ('ai-draft', 'human-reviewed') or type(entry['locked']) is not bool:
            raise CatalogError(f'{key}: invalid review declaration or locked flag')
    return state['entries']


def make_plan(current, previous, locale, state=None):
    validate_snapshot(current)
    validate_snapshot(previous)
    if not isinstance(locale, str) or not LOCALE_RE.fullmatch(locale):
        raise CatalogError('locale must use canonical ARB notation, e.g. ru or es_MX')
    now, old = current['entries'], previous['entries']
    translations = {} if state is None else validate_translations(state, locale, now.keys() | old.keys())
    shared = now.keys() & old.keys()
    diff = {
        'new': sorted(now.keys() - old.keys()),
        'changed': sorted(key for key in shared if now[key]['sourceHash'] != old[key]['sourceHash']),
        'removed': sorted(old.keys() - now.keys()),
        'unchanged': sorted(key for key in shared if now[key]['sourceHash'] == old[key]['sourceHash']),
    }
    kept, retired, freshness, translation_queue, review_queue = {}, {}, {}, [], []
    for key in sorted(translations):
        entry = translations[key]
        if key not in now:
            retired[key] = dict(entry)
            freshness[key] = 'removed'
        else:
            kept[key] = dict(entry)
            freshness[key] = 'current' if entry['sourceHash'] == now[key]['sourceHash'] else 'stale'
    for key in sorted(now):
        entry = translations.get(key)
        if entry is None:
            freshness[key] = 'missing'
            translation_queue.append({'key': key, 'reason': 'missing', **now[key]})
        elif freshness[key] == 'stale':
            request = {'key': key, 'reason': 'source-changed', **now[key]}
            # These are local workflow declarations, not authenticated approvals.
            if entry['locked'] or entry['review'] == 'human-reviewed':
                review_queue.append(request)
            else:
                translation_queue.append(request)
    return {
        'format': 'dsh-go-i18n-plan', 'schemaVersion': 1, 'locale': locale,
        'sourceHashAlgorithm': HASH_ALGORITHM, 'sourceDiff': diff,
        'preservedTranslations': kept, 'retiredTranslations': retired, 'freshness': freshness,
        'translationQueue': translation_queue, 'humanReviewQueue': review_queue,
        'metrics': {'source': current['metrics'],
                    'translationQueue': source_metrics({item['key']: item for item in translation_queue}),
                    'humanReviewQueue': source_metrics({item['key']: item for item in review_queue})},
    }


def write_new_json(path, value):
    # Encode before exclusive creation so encoding errors cannot leave a file.
    encoded = (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False) + '\n').encode('utf-8')
    target = Path(path)
    created = False
    try:
        with target.open('xb') as stream:
            created = True
            stream.write(encoded)
    except FileExistsError as exc:
        raise CatalogError(f'{target.name}: output already exists; choose a new filename') from exc
    except OSError:
        if created:
            target.unlink(missing_ok=True)
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest='command', required=True)
    for name in ('snapshot', 'plan'):
        command = subparsers.add_parser(name)
        command.add_argument('--repo', type=Path, default=ROOT)
        command.add_argument('--output', type=Path, required=True)
        if name == 'plan':
            command.add_argument('--previous', type=Path, required=True)
            command.add_argument('--translations', type=Path)
            command.add_argument('--locale', required=True)
    args = parser.parse_args(argv)
    try:
        current = build_snapshot(args.repo)
        result = current
        if args.command == 'plan':
            previous = read_json(args.previous)
            state = read_json(args.translations) if args.translations else None
            result = make_plan(current, previous, args.locale, state)
        write_new_json(args.output, result)
    except (CatalogError, OSError, UnicodeError) as exc:
        if isinstance(exc, OSError):
            print(f'error: file operation failed ({type(exc).__name__}); no input was modified', file=sys.stderr)
        else:
            print(f'error: {exc}', file=sys.stderr)
        return 1
    print(f'created {args.output.name}; source keys: {current["metrics"]["keys"]}')
    return 0


if __name__ == '__main__':
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding='utf-8', errors='replace')
    sys.exit(main())
