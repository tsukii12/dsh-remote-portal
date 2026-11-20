import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:dsh_tavern/src/director/direct_tool.dart' show directorEvery;
import 'package:dsh_tavern/src/state/state_engine.dart';
import 'package:dsh_tavern/src/story/story_engine.dart';
import 'package:dsh_tavern/src/tool_policy.dart' show captureToolCardPolicy;
import 'package:test/test.dart';

typedef Json = Map<String, Object?>;

void main() {
  test('definition inspection leaves defaults, derive, rules and story conditions dormant', () {
    final state = <String, Object?>{
      'schema': {
        'type': 'object',
        'properties': {
          'n': {
            'type': 'number',
            'default': 0,
            'x-dsh-derive': {
              '/': [1, 0],
            },
          },
        },
      },
      'init': <String, Object?>{},
      'summary': '<script>doNotRun()</script>{{setglobalvar::inspection-ran::yes}}',
      'rules': [
        {
          'id': 'once',
          'when': true,
          'once': true,
          'do': [
            {'type': 'notice', 'text': 'MUST_NOT_FIRE'},
            {'type': 'prompt', 'text': '{{setglobalvar::inspection-ran::yes}}'},
          ],
        },
      ],
    };
    final story = <String, Object?>{
      'acts': [
        {'id': 'first', 'when': true},
      ],
      'endings': [
        {
          'id': 'unsafe-domain',
          'title': 'Dormant',
          'when': {
            '/': [1, 0],
          },
        },
      ],
    };
    final raw = <String, Object?>{'state': state, 'story': story};
    final before = jsonEncode(raw);
    final nativeState = StateDefinition.parse(state);
    final nativeStory = StoryDefinition.parse(story);
    final inspection = inspectDshgoExtension(raw);
    expect(_block(inspection, '/state').executable, isTrue);
    expect(_nativeIssues(_block(inspection, '/state').issues), nativeState.issues);
    expect(_block(inspection, '/story').executable, isTrue);
    expect(_nativeIssues(_block(inspection, '/story').issues), nativeStory.issues);
    expect(inspection.issues, isEmpty);
    expect(inspection.raw, jsonDecode(before));
    expect(jsonEncode(raw), before);
    expect((inspection.raw! as Json)['state'], state);
    expect(((inspection.raw! as Json)['state']! as Json)['init'], isEmpty);

    // The same schema has a real runtime failure. Explicit value validation
    // must still use validate, without the initialization/derive path.
    expect(nativeState.initialPreview().valid, isFalse);
    final value = <String, Object?>{'n': 5};
    final checked = validateDshgoStateValue(raw, valueExists: true, value: value);
    expect(checked.validated, isTrue);
    expect(_nativeIssues(checked.issues), nativeState.validate(value));
    expect(checked.issues, isEmpty);
    expect(checked.value, value);
    expect(jsonEncode(raw), before);
  });

  test('explicit value validation distinguishes an absent validator from pass and failure', () {
    final noSchema = <String, Object?>{
      'state': {
        'init': {'n': 7},
      },
    };
    final notValidated = validateDshgoStateValue(noSchema, valueExists: true, value: <String, Object?>{});
    expect(notValidated.validated, isFalse);
    expect(notValidated.issues, isEmpty);
    final raw = <String, Object?>{
      'state': {
        'schema': {
          'type': 'object',
          'required': ['n'],
          'properties': {
            'n': {'type': 'integer', 'default': 7},
          },
        },
      },
    };
    final definition = StateDefinition.parse(raw['state']);
    final value = <String, Object?>{};
    final invalid = validateDshgoStateValue(raw, valueExists: true, value: value);
    expect(invalid.validated, isTrue);
    expect(_nativeIssues(invalid.issues), definition.validate(value));
    expect(invalid.issues.single['code'], 'value_required');
    expect(invalid.issues.single['sourcePath'], '/value/n');
    expect(invalid.value, isEmpty);
    expect(value, isEmpty);
    final missing = validateDshgoStateValue(raw, valueExists: false);
    expect(missing.validated, isTrue);
    expect(missing.valueExists, isFalse);
    expect(missing.value, isNull);
    expect(_nativeIssues(missing.issues), definition.validate(null, valueExists: false));
    final valid = validateDshgoStateValue(raw, valueExists: true, value: {'n': 7});
    expect(valid.validated, isTrue);
    expect(valid.issues, isEmpty);
    final explicitNullVersion = validateDshgoStateValue({...raw, 'v': null}, valueExists: true, value: {'n': 7});
    expect(explicitNullVersion.validated, isFalse);
    expect(_nativeIssues(explicitNullVersion.issues), StateDefinition.parse(raw['state'], version: null).issues);
  });

  test('native executable flags stay distinct from issues and detached opaque or cast content', () {
    final state = <String, Object?>{
      'schema': {
        'type': 'object',
        'properties': {
          'unsupported': {'type': 'string', 'pattern': '^A'},
          'entity': {'type': 'string'},
          'vault': {
            'type': 'object',
            'properties': {
              'fact': {
                'type': ['string', 'null'],
                'x-dsh-hidden': true,
              },
              'other': {
                'type': ['string', 'null'],
                'x-dsh-hidden': true,
              },
            },
          },
        },
      },
    };
    final events = <String, Object?>{
      'v': 1,
      'rules': [
        {
          'id': 'missing-when',
          'name': 'signal',
          'do': [
            {'type': 'notice', 'text': 'disabled'},
          ],
        },
        {
          'id': 'good',
          'name': 'signal',
          'when': true,
          'do': [
            {'type': 'notice', 'text': 'enabled'},
          ],
        },
      ],
    };
    final secrets = <String, Object?>{
      'v': 1,
      'slots': [
        {
          'id': 'slot',
          'path': '/vault/fact',
          'entityPath': '/entity',
          'unbound': {'exists': false},
          'bindWhen': true,
          'release': {'id': 'release', 'audience': 'currentCharacter', 'when': true, 'template': '{{fact}}'},
        },
        {'id': 'malformed', 'path': '/vault/other'},
      ],
    };
    final card = <String, Object?>{
      'name': 'Cast member',
      'vendor': {'kept': true},
    };
    final raw = <String, Object?>{
      'state': state,
      'director': {'eventRules': events, 'secretSlots': secrets},
      'cast': [
        {'id': 'npc', 'card': card},
      ],
      'theme': null,
      'vendor/key': <String, Object?>{
        'nested': <Object?>[1, null, 'kept'],
      },
    };
    final before = jsonDecode(jsonEncode(raw));
    final nativeState = StateDefinition.parse(state);
    final nativeEvents = CardEventDefinition.parse(events);
    final nativeSecrets = SecretDefinition.parse(secrets, state: nativeState);
    final inspection = inspectDshgoExtension(raw);
    expect(_block(inspection, '/state').executable, nativeState.executable);
    expect(_block(inspection, '/state').executable, isTrue);
    expect(_nativeIssues(_block(inspection, '/state').issues), nativeState.issues);
    expect(_block(inspection, '/state').issues.single['code'], 'schema_unsupported');
    expect(_block(inspection, '/director/eventRules').executable, nativeEvents.executable);
    expect(_block(inspection, '/director/eventRules').executable, isTrue);
    expect(nativeEvents.handlerIds, ['good']);
    expect(_nativeIssues(_block(inspection, '/director/eventRules').issues), nativeEvents.issues);
    expect(_block(inspection, '/director/secretSlots').executable, nativeSecrets.executable);
    expect(_block(inspection, '/director/secretSlots').executable, isFalse);
    expect(_nativeIssues(_block(inspection, '/director/secretSlots').issues), nativeSecrets.issues);
    expect(_block(inspection, '/theme').present, isTrue);
    expect(_block(inspection, '/theme').owner, TavernDshgoBlockOwner.app);
    expect(_block(inspection, '/theme').executable, isNull);
    expect(_block(inspection, '/vendor~1key').status, TavernDshgoBlockStatus.opaque);
    expect(_block(inspection, '/cast').issues, isEmpty);
    const CardCodec().validateAuthority({'spec': 'chara_card_v3', 'spec_version': '3.0', 'data': card});
    expect(card.keys, ['name', 'vendor']);
    expect(inspection.raw, before);
    final originalList = (raw['vendor/key']! as Json)['nested']! as List<Object?>;
    final capturedList = ((inspection.raw! as Json)['vendor/key']! as Json)['nested']! as List<Object?>;
    originalList.add('source');
    expect(capturedList, [1, null, 'kept']);
    capturedList.add('report');
    expect(originalList, [1, null, 'kept', 'source']);
    expect(inspectDshgoExtension(7).raw, 7);
    expect(inspectDshgoExtension(null).present, isTrue);
    final absent = inspectDshgoExtension(null, present: false);
    expect(absent.present, isFalse);
    expect(absent.issues, isEmpty);
    expect(() => inspectDshgoExtension({'unknown': DateTime.utc(2026)}), throwsFormatException);
    expect(() => validateDshgoStateValue(raw, valueExists: true, value: double.infinity), throwsFormatException);
  });

  test('tool declarations keep their own version gate without inventing identity or permission', () {
    final raw = <String, Object?>{
      'v': 1.0,
      'state': {
        'schema': {'type': 'object'},
      },
      'tools': {
        'roll': {'disabled': false},
        'remember': {'disabled': true},
      },
      'director': {'every': 1.0},
    };
    final card = <String, Object?>{
      'extensions': {'dshgo': raw},
    };
    final native = captureToolCardPolicy(card, characterId: 'real-host');
    final inspection = inspectDshgoExtension(raw);
    expect(_block(inspection, '/state').executable, isTrue);
    expect(_block(inspection, '/tools/roll').status, TavernDshgoBlockStatus.invalid);
    expect(_block(inspection, '/tools/roll').executable, isNull);
    expect(_nativeIssues(_block(inspection, '/tools').issues), [
      for (final issue in native.diagnostics) Map<String, Object?>.of(issue)..remove('characterId'),
    ]);
    expect(native.diagnostics.single['characterId'], 'real-host');
    expect(_block(inspection, '/tools').issues.single.keys, ['code', 'fieldPath', 'raw', 'sourcePath']);
    expect(_block(inspection, '/tools').issues.single['sourcePath'], '/v');
    expect(jsonEncode(inspection.toJson()), isNot(contains('characterId')));
    expect(_block(inspection, '/director/every').issues, [
      {'kind': 'director', 'code': 'invalid_director_every', 'sourcePath': '/director/every'},
    ]);
    final normal = inspectDshgoExtension({...raw, 'v': 1});
    expect(_block(normal, '/tools/remember').status, TavernDshgoBlockStatus.conditional);
    expect(_block(normal, '/tools/remember').executable, isNull);
    expect((((normal.raw! as Json)['tools']! as Json)['remember']! as Json)['disabled'], isTrue);
    expect(
      () => captureToolCardPolicy(card, characterId: ''),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'A card policy requires a character identity.',
        ),
      ),
    );

    // The native afterTurn wrapper uses this same pure helper at its old tick boundary.
    expect(directorEvery(settings: {'every': null}, card: {'every': 100}), (every: 1, invalid: true));
    expect(directorEvery(card: {'every': 100}), (every: 100, invalid: false));
    expect(directorEvery(), (every: 1, invalid: false));
  });
}

TavernDshgoBlockInspection _block(TavernDshgoInspection inspection, String path) =>
    inspection.blocks.singleWhere((block) => block.path == path);

List<Json> _nativeIssues(List<Json> issues) => [
  for (final issue in issues) Map<String, Object?>.of(issue)..remove('sourcePath'),
];
