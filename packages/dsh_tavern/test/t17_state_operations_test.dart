import 'dart:convert';

import 'package:dsh_tavern/src/state/state_engine.dart';
import 'package:test/test.dart';

typedef Json = Map<String, Object?>;
Json op(String operation, String path, [Object? value]) => {
  'op': operation,
  'path': path,
  if (operation != 'remove') 'value': value,
  'why': 'operation test',
};
StateDefinition def(Json properties) => StateDefinition.parse({
  'schema': {'type': 'object', 'properties': properties},
});

void main() {
  test('Pointer decodes once; object numeric keys and empty key remain literal', () {
    final d = def({
      'a/b': {
        'type': 'object',
        'properties': {
          '~x': {'type': 'integer'},
          '~1': {'type': 'integer'},
        },
      },
      '01': {'type': 'integer'},
      '': {'type': 'integer'},
    });
    final s = d.startSession(
      valueExists: true,
      value: {
        'a/b': {'~x': 0, '~1': 0},
        '01': 0,
        '': 0,
      },
    );
    expect(
      s.apply([
        op('set', '/a~1b/~0x', 1),
        op('set', '/a~1b/~01', 2),
        op('set', '/01', 3),
        op('set', '/', 4),
      ], actor: StateActor.user).acceptedCount,
      4,
    );
    expect(s.apply([op('set', 'a', 5), op('set', '/bad~2', 5)], actor: StateActor.user).rejectedCount, 2);
    expect(s.finish(runRules: false).value, {
      'a/b': {'~x': 1, '~1': 2},
      '01': 3,
      '': 4,
    });
  });

  test('set creates defined missing leaf but never invents intermediate containers or array slots', () {
    final d = def({
      'box': {
        'type': 'object',
        'properties': {
          'x': {'type': 'integer'},
        },
      },
      'a': {
        'type': 'array',
        'items': {'type': 'integer'},
      },
      'leaf': {'type': 'integer'},
    });
    final s = d.startSession(
      valueExists: true,
      value: {
        'a': [0],
      },
    );
    expect(s.apply([op('set', '/leaf', 2)], actor: StateActor.user).acceptedCount, 1);
    expect(
      s.apply([
        op('set', '/box/x', 2),
        op('set', '/a/1', 2),
        op('set', '/a/01', 2),
        op('set', '/a/-', 2),
        op('set', '/unknown', 2),
      ], actor: StateActor.user).rejectedCount,
      5,
    );
    expect(s.finish(runRules: false).value, {
      'a': [0],
      'leaf': 2,
    });
  });

  test('fixed baseline crosses calls and uses net displacement, not cumulative spending', () {
    final d = def({
      'n': {'type': 'number', 'x-dsh-step': 5},
    });
    final s = d.startSession(valueExists: true, value: {'n': 0});
    expect(s.apply([op('add', '/n', 5)], actor: StateActor.model, source: 'call-0').acceptedCount, 1);
    expect(s.apply([op('add', '/n', -10)], actor: StateActor.model, source: 'call-1').acceptedCount, 1);
    final result = s.finish(runRules: false);
    expect(result.value, {'n': -5});
    expect(result.changes.single, containsPair('old', 0));
    expect(result.changes.single, containsPair('new', -5));
    expect(result.receipts.map((x) => x['source']), ['call-0', 'call-1']);
    final next = d.startSession(valueExists: true, value: result.value);
    next.apply([op('add', '/n', -100)], actor: StateActor.user);
    expect(next.finish(runRules: false).value, {'n': -10});
  });

  test('remove and parent replacement retain the invocation numeric baseline', () {
    final d = def({
      'n': {'type': 'integer', 'x-dsh-step': 5},
    });
    final s = d.startSession(valueExists: true, value: {'n': 10});
    final result = s.apply([
      op('remove', '/n'),
      op('set', '/n', 100),
      op('set', '', {'n': -100}),
    ], actor: StateActor.user);
    expect(result.acceptedCount, 3);
    expect(s.finish(runRules: false).value, {'n': 5});
    expect(result.receipts[1]['clamps'], [containsPair('actual', 15)]);
    expect(result.receipts[2]['clamps'], [containsPair('actual', 5)]);
  });

  test('new step number cannot invent a zero baseline; first initialization may set it', () {
    final d = def({
      'n': {'type': 'integer', 'default': 7, 'x-dsh-step': 2},
    });
    final s = d.startSession(valueExists: true, value: <String, Object?>{});
    expect(s.apply([op('set', '/n', 1)], actor: StateActor.user).rejectedCount, 1);
    expect(s.finish(runRules: false).value, <String, Object?>{});
    final initialized = d.startSession(valueExists: false);
    expect(initialized.apply([op('set', '/n', 100)], actor: StateActor.user).acceptedCount, 1);
    expect(initialized.finish(runRules: false).value, {'n': 9});
  });

  test('integer strict endpoints clamp exactly; fractions and post-clamp enum conflicts reject atomically', () {
    final d = def({
      'n': {'type': 'integer', 'minimum': 0.2, 'exclusiveMaximum': 3},
      'e': {
        'type': 'integer',
        'enum': [0, 10],
        'x-dsh-step': 5,
      },
    });
    final s = d.startSession(valueExists: true, value: {'n': 1, 'e': 0});
    final result = s.apply([op('set', '/n', 100), op('add', '/n', 0.5), op('add', '/e', 100)], actor: StateActor.user);
    expect(result.acceptedCount, 1);
    expect(result.rejectedCount, 2);
    expect(s.finish(runRules: false).value, {'n': 2, 'e': 0});
  });

  test('number exclusive boundaries never invent epsilon; non-finite input and addition overflow reject', () {
    final d = def({
      'n': {'type': 'number', 'exclusiveMinimum': 0},
      'huge': {'type': 'number'},
    });
    final s = d.startSession(valueExists: true, value: {'n': 1, 'huge': 1e308});
    expect(
      s.apply([
        op('set', '/n', -1),
        op('set', '/n', double.nan),
        op('add', '/huge', 1e308),
      ], actor: StateActor.user).rejectedCount,
      3,
    );
    final result = s.finish(runRules: false);
    expect(result.value, {'n': 1, 'huge': 1e308});
    expect(() => jsonEncode(result.toJson()), returnsNormally);
    expect((result.receipts[1]['operation'] as Json)['value'], {'nonJsonNumber': 'NaN'});
  });

  test('add delta and from guard do not inherit target bounds, enum or length constraints', () {
    final d = def({
      'n': {'type': 'number', 'minimum': 0},
      's': {'type': 'string', 'maxLength': 2},
    });
    final session = d.startSession(valueExists: true, value: {'n': -20, 's': 'long'});
    final result = session.apply([
      {
        ...op('set', '', {'n': 0, 's': 'ok'}),
        'from': {'n': -20, 's': 'long'},
      },
      {...op('add', '/n', -5), 'from': 0},
    ], actor: StateActor.user);
    expect(result.acceptedCount, 2);
    expect(result.receipts.every((x) => x['conflict'] == null), isTrue);
    expect(session.finish(runRules: false).value, {'n': 0, 's': 'ok'});
    final second = d.startSession(valueExists: true, value: {'n': -20, 's': 'ok'});
    expect(
      second.apply([
        {...op('add', '/n', 5), 'from': -20},
      ], actor: StateActor.user).acceptedCount,
      1,
    );
    expect(second.finish(runRules: false).value, {'n': 0, 's': 'ok'});
  });

  test('missing guard differs from expected null and JSON guards ignore map order and 1 versus 1.0', () {
    final d = def({
      'n': {
        'type': ['number', 'null'],
      },
      'map': {
        'type': 'object',
        'properties': {
          'a': {'type': 'integer'},
          'b': {'type': 'integer'},
        },
      },
    });
    final s = d.startSession(
      valueExists: true,
      value: {
        'map': {'a': 1, 'b': 2},
      },
    );
    final result = s.apply([
      {...op('set', '/n', null), 'from': null},
      {...op('set', '/n', null), 'from': null},
      {
        ...op('set', '/map', {'a': 1, 'b': 2}),
        'from': {'b': 2, 'a': 1.0},
      },
    ], actor: StateActor.user);
    expect(result.acceptedCount, 3);
    expect(result.receipts[0]['conflict'], containsPair('actualExists', false));
    expect(result.receipts[1]['conflict'], isNull);
    expect(result.receipts[2]['conflict'], isNull);
    expect(s.finish(runRules: false).changes.single, containsPair('oldExists', false));
  });

  test('move resolves the new array index after removal while guard reads the original target', () {
    final d = def({
      'a': {
        'type': 'array',
        'items': {'type': 'integer'},
      },
    });
    final s = d.startSession(
      valueExists: true,
      value: {
        'a': [10, 20, 30],
      },
    );
    final result = s.apply([
      {...op('move', '/a/2', '/a/0'), 'from': 30},
    ], actor: StateActor.user);
    expect(result.acceptedCount, 1);
    expect(result.receipts.single['conflict'], isNull);
    final finalResult = s.finish(runRules: false);
    expect(finalResult.value, {
      'a': [20, 30, 10],
    });
    expect(finalResult.changes, hasLength(1));
    expect(finalResult.changes.single['path'], '/a');
  });

  test('move permits append and exact same-path no-op but rejects invalid parent without losing source', () {
    final d = def({
      'a': {
        'type': 'array',
        'items': {'type': 'integer'},
      },
      'box': {
        'type': 'object',
        'properties': {
          'x': {'type': 'integer'},
        },
      },
    });
    final s = d.startSession(
      valueExists: true,
      value: {
        'a': [1, 2],
      },
    );
    final result = s.apply([
      op('move', '/a/-', '/a/0'),
      op('move', '/a/1', '/a/1'),
      op('move', '/box/x', '/a/0'),
      op('move', '/a/0', '/a/9'),
    ], actor: StateActor.user);
    expect(result.acceptedCount, 2);
    expect(result.rejectedCount, 2);
    expect(result.receipts[1]['changed'], isFalse);
    expect(s.finish(runRules: false).value, {
      'a': [2, 1],
    });
  });

  test('move ancestry compares tokens and root destination follows root validation', () {
    final d = StateDefinition.parse({
      'schema': {
        'type': ['object', 'integer'],
        'properties': {
          'a': {
            'type': 'object',
            'properties': {
              'x': {'type': 'integer'},
            },
          },
          'ab': {
            'type': 'object',
            'properties': {
              'x': {'type': 'integer'},
            },
          },
          'n': {'type': 'integer'},
        },
      },
    });
    final s = d.startSession(
      valueExists: true,
      value: {
        'a': {'x': 1},
        'ab': {},
        'n': 9,
      },
    );
    expect(
      s.apply([
        op('move', '/a/x', '/a'),
        op('move', '/ab/x', '/a/x'),
        op('move', '', '/n'),
      ], actor: StateActor.user).acceptedCount,
      2,
    );
    expect(s.finish(runRules: false).value, 9);
    final root = d.startSession(
      valueExists: true,
      value: {
        'a': {'x': 1},
      },
    );
    expect(root.apply([op('move', '/a/x', '')], actor: StateActor.user).rejectedCount, 1);
  });

  test('structural array shifts retain payload and reject fixed-path step violations', () {
    final d = def({
      'a': {
        'type': 'array',
        'items': {'type': 'integer', 'x-dsh-step': 5},
      },
    });
    final s = d.startSession(
      valueExists: true,
      value: {
        'a': [0, 100, 200],
      },
    );
    expect(
      s.apply([
        op('move', '/a/2', '/a/0'),
        op('remove', '/a/0'),
        op('push', '/a', 300),
      ], actor: StateActor.user).rejectedCount,
      3,
    );
    expect(s.finish(runRules: false).value, {
      'a': [0, 100, 200],
    });
  });

  test('push clamps only its new item; rejected removal preserves required properties', () {
    final d = StateDefinition.parse({
      'schema': {
        'type': 'object',
        'required': ['required'],
        'properties': {
          'required': {'type': 'integer'},
          'a': {
            'type': 'array',
            'items': {'type': 'integer', 'maximum': 3},
          },
        },
      },
    });
    final s = d.startSession(
      valueExists: true,
      value: {
        'required': 1,
        'a': [2],
      },
    );
    expect(
      s.apply([
        op('push', '/a', 100),
        op('remove', '/required'),
        op('remove', ''),
      ], actor: StateActor.user).acceptedCount,
      1,
    );
    expect(s.finish(runRules: false).value, {
      'required': 1,
      'a': [2, 3],
    });
  });

  test('each failed operation is independent; net no-op has no fabricated change and final writer wins', () {
    final d = def({
      'n': {'type': 'number'},
      'x': {'type': 'integer'},
    });
    final s = d.startSession(valueExists: true, value: {'n': 1, 'x': 0});
    s.apply([op('set', '/n', 1.0), op('set', '/x', 'bad'), op('add', '/n', 4)], actor: StateActor.model);
    s.apply([op('set', '/n', 1), op('set', '/x', 3)], actor: StateActor.user);
    final result = s.finish(runRules: false);
    expect(result.changes, hasLength(1));
    expect(result.changes.single, containsPair('path', '/x'));
    expect(result.changes.single, containsPair('actor', 'user'));
    expect(result.receipts.where((x) => x['accepted'] == false), hasLength(1));
  });

  test('256 operation limit spans calls and explicitly rejects the unexecuted suffix', () {
    final s = def({
      'n': {'type': 'integer'},
    }).startSession(valueExists: true, value: {'n': 0});
    expect(s.apply([for (var i = 0; i < 255; i++) op('add', '/n', 1)], actor: StateActor.user).acceptedCount, 255);
    final second = s.apply([op('add', '/n', 1), op('add', '/n', 1), op('add', '/n', 1)], actor: StateActor.user);
    expect(second.acceptedCount, 1);
    expect(second.rejectedCount, 2);
    expect(second.receipts.last, containsPair('skippedCount', 2));
    expect(s.finish(runRules: false).value, {'n': 256});
  });

  test('native integers beyond double precision retain exact type bounds addition and step baseline', () {
    const minimum = 9007199254740993;
    final d = def({
      'n': {'type': 'integer', 'minimum': minimum, 'x-dsh-step': 1},
    });
    expect(d.validate({'n': minimum}), isEmpty);
    final s = d.startSession(valueExists: true, value: {'n': minimum});
    expect(
      s.apply([op('set', '/n', 0), op('add', '/n', 1), op('add', '/n', 1)], actor: StateActor.user).acceptedCount,
      3,
    );
    expect(s.finish(runRules: false).value, {'n': minimum + 1});
  });

  test('integer overflow cannot wrap or silently lose a unit; representable boundary remains legal', () {
    const maximum = 0x7fffffffffffffff;
    const next = 9223372036854775808.0;
    final s = def({
      'n': {'type': 'integer'},
    }).startSession(valueExists: true, value: {'n': maximum});
    expect(s.apply([op('add', '/n', 2)], actor: StateActor.user).rejectedCount, 1);
    expect(s.apply([op('add', '/n', 1)], actor: StateActor.user).acceptedCount, 1);
    final added = s.finish(runRules: false);
    expect(added.value, {'n': next});
    expect(added.changed, isTrue);
    expect(added.changes.single['old'], isA<int>());
    expect(added.changes.single['new'], isA<double>());
    final bound = def({
      'n': {'type': 'integer', 'exclusiveMinimum': maximum},
    }).startSession(valueExists: true, value: {'n': maximum});
    expect(bound.apply([op('set', '/n', 0)], actor: StateActor.user).acceptedCount, 1);
    final raised = bound.finish(runRules: false);
    expect(raised.value, {'n': next});
    expect(raised.valid, isTrue);
    expect(raised.changed, isTrue);

    // The reverse strict endpoint must retain the exact native integer, too.
    final upper = def({
      'n': {'type': 'integer', 'exclusiveMaximum': next},
    }).startSession(valueExists: true, value: {'n': next});
    expect(upper.apply([op('set', '/n', next)], actor: StateActor.user).acceptedCount, 1);
    final lowered = upper.finish(runRules: false);
    expect(lowered.value, {'n': maximum});
    expect((lowered.value as Json)['n'], isA<int>());
    expect(lowered.valid, isTrue);
    expect(lowered.changed, isTrue);

    final singleton = def({
      'n': {'type': 'integer', 'exclusiveMinimum': maximum, 'maximum': next},
    });
    expect(singleton.issues, isEmpty);
    expect(singleton.validate({'n': next}), isEmpty);
    expect(singleton.validate({'n': maximum}), isNotEmpty);
  });

  test('state equality keeps distinct native integers while ordinary numeric and signed zero values stay equal', () {
    const maximum = 0x7fffffffffffffff;
    const next = 9223372036854775808.0;
    final d = def({
      'n': {
        'type': 'integer',
        'enum': [maximum, next],
      },
      'ordinary': {'type': 'number'},
      'zero': {'type': 'number'},
    });
    expect(d.issues, isEmpty);
    final s = d.startSession(valueExists: true, value: {'n': maximum, 'ordinary': 1, 'zero': -0.0});
    final applied = s.apply([
      {...op('set', '/n', next), 'from': next},
      {...op('set', '/ordinary', 1.0), 'from': 1.0},
      {...op('set', '/zero', 0), 'from': 0},
    ], actor: StateActor.user);
    expect(applied.acceptedCount, 3);
    expect(applied.receipts.first['conflict'], isNotNull);
    expect(applied.receipts[1]['conflict'], isNull);
    expect(applied.receipts[2]['conflict'], isNull);
    final result = s.finish(runRules: false);
    expect(result.value, {'n': next, 'ordinary': 1.0, 'zero': 0});
    expect(result.changed, isTrue);
    expect(result.changes, hasLength(1));
    expect(result.changes.single['path'], '/n');
    expect(result.changes.single['old'], isA<int>());
    expect(result.changes.single['new'], isA<double>());
  });
}
