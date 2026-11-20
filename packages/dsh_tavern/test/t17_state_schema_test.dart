import 'package:dsh_tavern/src/state/state_engine.dart';
import 'package:test/test.dart';

typedef Json = Map<String, Object?>;
Json op(String operation, String path, [Object? value]) => {
  'op': operation,
  'path': path,
  if (operation != 'remove') 'value': value,
  'why': 'test',
};
StateDefinition definition(Json properties, {Object? init, List<Object?>? required}) => StateDefinition.parse({
  'schema': {'type': 'object', 'properties': properties, 'required': ?required},
  'init': ?init,
});
List<Object?> codes(List<Json> issues) => issues.map((x) => x['code']).toList();

void main() {
  test('init wins; defaults fill present containers without inventing optional parents', () {
    final d = definition(
      {
        'n': {'type': 'integer', 'default': 5},
        'optional': {
          'type': 'object',
          'properties': {
            'child': {'type': 'string', 'default': 'hidden default'},
          },
        },
        'explicit': {
          'type': 'object',
          'default': <String, Object?>{},
          'properties': {
            'child': {'type': 'integer', 'default': 9},
          },
        },
        'present': {
          'type': 'object',
          'properties': {
            'child': {'type': 'integer', 'default': 7},
          },
        },
      },
      init: {'n': 0, 'present': <String, Object?>{}},
    );
    final preview = d.initialPreview();
    expect(preview.valid, isTrue);
    expect(preview.value, {
      'n': 0,
      'present': {'child': 7},
      'explicit': {'child': 9},
    });
    expect(d.startSession(valueExists: false).finish(runRules: false).initialized, isTrue);
  });

  test('root null is a saved value; missing scalar needs a real init or default', () {
    final d = StateDefinition.parse({
      'schema': {
        'type': ['number', 'null'],
      },
      'init': null,
    });
    expect(d.initialPreview().valueExists, isTrue);
    final saved = d.startSession(valueExists: true, value: null).finish(runRules: false);
    expect(saved.valueExists, isTrue);
    expect(saved.value, isNull);
    expect(saved.initialized, isFalse);
    expect(saved.changed, isFalse);
    final missing = StateDefinition.parse({
      'schema': {'type': 'string'},
    }).initialPreview();
    expect(missing.valueExists, isFalse);
    expect(codes(missing.issues), contains('initial_missing'));
  });

  test('invalid explicit schema remains present and raw copies are isolated', () {
    final raw = <String, Object?>{
      'schema': null,
      'vendor': {'x': 1},
    };
    final d = StateDefinition.parse(raw);
    raw['schema'] = {'type': 'object'};
    expect(d.hasSchema, isTrue);
    expect(d.schema, isNull);
    expect(d.executable, isFalse);
    final result = d.startSession(valueExists: true, value: {'old': 3});
    expect(result.apply([op('set', '', {})], actor: StateActor.user).rejectedCount, 1);
    expect(result.finish().value, {'old': 3});
    expect(
      StateDefinition.parse({
        'schema': {'type': 'object'},
      }, version: 2).executable,
      isFalse,
    );
  });

  test('properties and items infer only absent type; value constraints count Unicode scalars', () {
    final d = definition({
      'object': {
        'properties': {
          'x': {'type': 'integer'},
        },
      },
      'array': {
        'items': {'type': 'string'},
        'minItems': 1,
        'maxItems': 2.0,
      },
      'text': {'type': 'string', 'minLength': 1.0, 'maxLength': 1},
      'explicit': {
        'type': 'string',
        'properties': {
          'n': {'type': 'integer'},
        },
      },
    });
    expect(
      d.validate({
        'object': {'x': 1},
        'array': ['a'],
        'text': '😀',
        'explicit': 'x',
      }),
      isEmpty,
    );
    expect(
      codes(d.validate({'object': {}, 'array': [], 'text': 'a😀', 'explicit': {}})),
      containsAll(['value_min_items', 'value_max_length', 'value_type']),
    );
  });

  test('unsupported child is read-only while sibling remains executable and ancestor cannot erase it', () {
    final d = definition({
      'a': {'type': 'string', 'pattern': '^A'},
      'b': {'type': 'integer'},
      'meta': {
        'type': 'integer',
        'x-vendor-note': {'kept': true},
      },
    });
    expect(d.executable, isTrue);
    expect(codes(d.issues), containsAll(['schema_unsupported', 'schema_unknown']));
    final session = d.startSession(valueExists: true, value: {'a': 'preserve', 'b': 1, 'meta': 2});
    final result = session.apply([
      op('set', '/b', 2),
      op('set', '/a', 'Ax'),
      op('set', '', {'b': 3, 'meta': 2}),
      op('set', '', {'a': 'preserve', 'b': 4, 'meta': 2}),
    ], actor: StateActor.user);
    expect(result.acceptedCount, 2);
    expect(result.rejectedCount, 2);
    expect(session.finish(runRules: false).value, {'a': 'preserve', 'b': 4, 'meta': 2});
  });

  test('permissions intersect ancestors and malformed or empty permissions do not open writes', () {
    final d = definition({
      'limited': {
        'type': 'object',
        'x-dsh-by': ['user'],
        'properties': {
          'n': {
            'type': 'integer',
            'x-dsh-by': ['model', 'user'],
          },
        },
      },
      'none': {'type': 'integer', 'x-dsh-by': <Object?>[]},
      'bad': {'type': 'integer', 'x-dsh-by': 'user'},
    });
    final s = d.startSession(
      valueExists: true,
      value: {
        'limited': {'n': 1},
        'none': 0,
        'bad': 0,
      },
    );
    expect(s.apply([op('set', '/limited/n', 2)], actor: StateActor.model).rejectedCount, 1);
    expect(s.apply([op('set', '/limited/n', 2)], actor: StateActor.user).acceptedCount, 1);
    expect(s.apply([op('set', '/none', 2), op('set', '/bad', 2)], actor: StateActor.user).rejectedCount, 2);
  });

  test('historical invalid sibling is preserved; only an entirely valid candidate commits', () {
    final d = definition({
      'bad': {'type': 'integer', 'minimum': 0},
      'good': {'type': 'integer'},
    });
    final original = <String, Object?>{'bad': -10, 'good': 1};
    final s = d.startSession(valueExists: true, value: original);
    expect(s.apply([op('set', '/good', 2)], actor: StateActor.user).rejectedCount, 1);
    expect(original, {'bad': -10, 'good': 1});
    expect(
      s.apply([
        op('set', '', {'bad': 0, 'good': 2}),
      ], actor: StateActor.user).acceptedCount,
      1,
    );
    expect(s.finish(runRules: false).value, {'bad': 0, 'good': 2});
  });

  test('invalid defaults and empty integer intervals are diagnosed without invented initial values', () {
    expect(
      definition({
        'n': {'type': 'integer', 'default': 1.5},
      }).initialPreview().valueExists,
      isFalse,
    );
    final d = definition({
      'n': {'type': 'integer', 'minimum': 0.2, 'maximum': 0.8},
      'ok': {'type': 'integer'},
    });
    expect(d.executable, isTrue);
    expect(codes(d.issues), contains('schema_definition'));
    final s = d.startSession(valueExists: true, value: {'n': 0, 'ok': 0});
    expect(s.apply([op('set', '/ok', 1)], actor: StateActor.user).acceptedCount, 1);
    expect(s.apply([op('set', '/n', 1)], actor: StateActor.user).rejectedCount, 1);
  });

  test('explicit closed object required enum and length constraints validate complete values', () {
    final d = StateDefinition.parse({
      'schema': {
        'type': 'object',
        'additionalProperties': false,
        'required': ['n'],
        'properties': {
          'n': {
            'type': 'integer',
            'enum': [1, 3],
          },
          'xs': {
            'type': 'array',
            'minItems': 1,
            'maxItems': 2,
            'items': {'type': 'boolean'},
          },
        },
      },
    });
    expect(
      d.validate({
        'n': 1,
        'xs': [true],
      }),
      isEmpty,
    );
    expect(
      codes(
        d.validate({
          'xs': [true, false, true],
          'extra': 1,
        }),
      ),
      containsAll(['value_required', 'value_max_items', 'value_additional']),
    );
    expect(codes(d.validate({'n': 2})), contains('value_enum'));
  });

  test('schema node and depth resource limits disable the complete definition without raw truncation', () {
    final properties = <String, Object?>{
      for (var i = 0; i < 2048; i++) 'n$i': {'type': 'number'},
    };
    final d = definition(properties);
    expect(d.executable, isFalse);
    expect((d.schema as Json)['properties'], hasLength(2048));
    expect(codes(d.issues), contains('schema_limit'));
    Object? schema = <String, Object?>{'type': 'number'};
    for (var i = 0; i < 65; i++) {
      schema = {'type': 'array', 'items': schema};
    }
    final deep = StateDefinition.parse({'schema': schema});
    expect(deep.executable, isFalse);
    expect(codes(deep.issues), contains('schema_limit'));
  });

  test('raw definitions input values receipts and final snapshots do not share mutable JSON', () {
    final props = <String, Object?>{
      'n': <String, Object?>{'type': 'integer'},
    };
    final d = definition(props);
    (props['n'] as Json)['x-dsh-by'] = <Object?>[];
    final input = <String, Object?>{'n': 0};
    final s = d.startSession(valueExists: true, value: input);
    input['n'] = 99;
    final result = s.apply([op('set', '/n', 1)], actor: StateActor.user);
    (result.receipts.first['operation'] as Json)['value'] = 90;
    final finalResult = s.finish(runRules: false);
    (finalResult.value as Json)['n'] = 99;
    expect(finalResult.value, {'n': 1});
    expect((finalResult.receipts.first['operation'] as Json)['value'], 1);
    expect(s.finish(runRules: false).toJson(), finalResult.toJson());
    expect(() => s.apply([], actor: StateActor.user), throwsStateError);
    expect(() => s.finish(), throwsStateError);
  });
}
