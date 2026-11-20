import 'dart:convert';

import 'package:dsh_tavern/src/state/state_engine.dart';
import 'package:test/test.dart';

typedef _Json = Map<String, Object?>;

enum _Shape { scalar, object, array }

enum _Existing { positive, missing, negative }

Object _wrapped(_Shape shape, double zero) => switch (shape) {
  _Shape.scalar => zero,
  _Shape.object => <String, Object?>{'z': zero},
  _Shape.array => <Object?>[zero],
};

num _zeroLeaf(_Shape shape, Object? value) => switch (shape) {
  _Shape.scalar => value! as num,
  _Shape.object => (value! as _Json)['z']! as num,
  _Shape.array => (value! as List<Object?>).single! as num,
};

_Json _valueSchema(_Shape shape, {bool restrictedLeaf = false}) {
  final leaf = <String, Object?>{
    'type': 'number',
    if (restrictedLeaf) 'x-dsh-by': ['user'],
  };
  return switch (shape) {
    _Shape.scalar => leaf,
    _Shape.object => <String, Object?>{
      'type': 'object',
      'properties': {'z': leaf},
    },
    _Shape.array => <String, Object?>{'type': 'array', 'items': leaf},
  };
}

StateDefinition _definition(_Shape shape, {_Json? init, bool restrictedLeaf = false, bool includeConsumer = true}) {
  final producer = _valueSchema(shape, restrictedLeaf: restrictedLeaf);
  producer['x-dsh-derive'] = shape == _Shape.scalar
      ? <String, Object?>{
          '-': [0],
        }
      : <String, Object?>{'var': 'source'};
  final path = switch (shape) {
    _Shape.scalar => 'a',
    _Shape.object => 'a.z',
    _Shape.array => 'a.0',
  };
  return StateDefinition.parse({
    'schema': {
      'type': 'object',
      'properties': {
        if (shape != _Shape.scalar) 'source': _valueSchema(shape),
        'a': producer,
        if (includeConsumer)
          'b': {
            'type': 'boolean',
            'x-dsh-derive': {
              '<': [
                {
                  '/': [
                    1,
                    {'var': path},
                  ],
                },
                0,
              ],
            },
          },
      },
    },
    'init': ?init,
  });
}

_Json _input(_Shape shape, _Existing existing) => {
  if (shape != _Shape.scalar) 'source': _wrapped(shape, -0.0),
  if (existing != _Existing.missing) 'a': _wrapped(shape, existing == _Existing.negative ? -0.0 : 0.0),
  'b': false,
};

void main() {
  test('derived signed zero reaches dependent booleans for saved and initial values', () {
    for (final shape in _Shape.values) {
      for (final existing in _Existing.values) {
        for (final initial in [false, true]) {
          final input = _input(shape, existing);
          final before = jsonEncode(input);
          final definition = _definition(shape, init: initial ? input : null);
          final reason = '${shape.name}/${existing.name}${initial ? '/initial' : '/saved'}';
          late final bool valid;
          late final Object? value;
          late final List<_Json> issues;
          if (initial) {
            final result = definition.initialPreview();
            valid = result.valid;
            value = result.value;
            issues = result.issues;
          } else {
            final result = definition.startSession(valueExists: true, value: input).finish();
            valid = result.valid;
            value = result.value;
            issues = result.issues;
          }

          expect(valid, isTrue, reason: '$reason: $issues');
          final state = value! as _Json;
          // First old-product defect assertion: scalar/positive/saved yields false.
          expect(state['b'], isTrue, reason: reason);
          expect(issues, isEmpty, reason: reason);
          expect(_zeroLeaf(shape, state['a']).isNegative, isTrue, reason: reason);
          expect(jsonEncode(input), before, reason: '$reason input is detached');
        }
      }
    }
  });

  test('derived containers reject changing protected zero signs without mutating inputs', () {
    for (final shape in [_Shape.object, _Shape.array]) {
      final input = _input(shape, _Existing.positive);
      final before = jsonEncode(input);
      final runtime = <String, Object?>{
        'version': 1,
        'firedRules': ['id:previous'],
        'future': {'kept': true},
      };
      final runtimeBefore = jsonEncode(runtime);
      final definition = _definition(shape, restrictedLeaf: true);
      final result = definition
          .startSession(valueExists: true, value: input, runtimeExists: true, runtime: runtime)
          .finish();
      final reason = shape.name;

      expect(result.valid, isFalse, reason: reason);
      expect(result.issues.map((issue) => issue['code']), ['permission'], reason: reason);
      expect(result.issues.single['path'], shape == _Shape.object ? '/a/z' : '/a/0', reason: reason);
      expect(result.value, input, reason: reason);
      expect(_zeroLeaf(shape, (result.value! as _Json)['a']).isNegative, isFalse, reason: reason);
      expect(result.runtime, runtime, reason: reason);
      expect(result.changed, isFalse, reason: reason);
      expect(result.changes, isEmpty, reason: reason);
      expect(jsonEncode(input), before, reason: '$reason failed candidate did not mutate input');
      expect(jsonEncode(runtime), runtimeBefore, reason: '$reason failed candidate did not mutate runtime');

      // An already matching protected leaf needs no write and must stay usable.
      final unchangedInput = _input(shape, _Existing.negative);
      final unchangedBefore = jsonEncode(unchangedInput);
      final unchanged = definition.startSession(valueExists: true, value: unchangedInput).finish();
      expect(unchanged.valid, isTrue, reason: '$reason unchanged protected leaf');
      expect((unchanged.value! as _Json)['b'], isTrue, reason: '$reason unchanged protected leaf');
      expect(unchanged.issues, isEmpty, reason: '$reason unchanged protected leaf');
      expect(jsonEncode(unchangedInput), unchangedBefore, reason: '$reason control input is detached');
    }
  });

  test('zero signs remain numerically equal in enums guards and JSON change receipts', () {
    final definition = StateDefinition.parse({
      'schema': {
        'type': 'object',
        'properties': {
          'n': {
            'type': 'number',
            'enum': [0.0],
          },
          'box': {
            'type': 'object',
            'properties': {
              'z': {'type': 'number'},
            },
          },
          'list': {
            'type': 'array',
            'items': {'type': 'number'},
          },
        },
      },
    });
    final input = <String, Object?>{
      'n': -0.0,
      'box': <String, Object?>{'z': -0.0},
      'list': <Object?>[-0.0],
    };
    final before = jsonEncode(input);
    expect(definition.validate(input), isEmpty, reason: 'enum keeps JSON numerical equality');
    final session = definition.startSession(valueExists: true, value: input);
    final applied = session.apply([
      {'op': 'set', 'path': '/n', 'value': 0.0, 'from': 0.0, 'why': 'equal zero'},
      {
        'op': 'set',
        'path': '/box',
        'value': {'z': 0.0},
        'from': {'z': 0.0},
        'why': 'equal object zero',
      },
      {
        'op': 'set',
        'path': '/list',
        'value': [0.0],
        'from': [0.0],
        'why': 'equal array zero',
      },
    ], actor: StateActor.user);
    expect(applied.acceptedCount, 3);
    expect(applied.rejectedCount, 0);
    for (final receipt in applied.receipts) {
      expect(receipt['conflict'], isNull, reason: 'from ignores zero signs recursively');
      expect(receipt['changed'], isFalse, reason: 'JSON operation receipts ignore zero signs');
    }
    final result = session.finish(runRules: false);
    expect(result.valid, isTrue);
    expect(result.changed, isFalse);
    expect(result.changes, isEmpty);
    expect(jsonEncode(input), before);
  });

  test('a derived sign update alone leaves the JSON change audit empty', () {
    final input = <String, Object?>{'a': 0.0};
    final before = jsonEncode(input);
    final definition = _definition(_Shape.scalar, includeConsumer: false);
    final result = definition.startSession(valueExists: true, value: input).finish();

    expect(result.valid, isTrue);
    expect(((result.value! as _Json)['a']! as num).isNegative, isTrue);
    expect(result.changed, isFalse);
    expect(result.changes, isEmpty);
    expect(jsonEncode(input), before);
  });

  test('signed-zero derivation still preserves native integer precision', () {
    const maxInt = 0x7fffffffffffffff;
    const nextDouble = 9223372036854775808.0;
    final input = <String, Object?>{'source': maxInt, 'a': nextDouble};
    final definition = StateDefinition.parse({
      'schema': {
        'type': 'object',
        'properties': {
          'source': {'type': 'number'},
          'a': {
            'type': 'number',
            'x-dsh-derive': {'var': 'source'},
          },
        },
      },
    });
    final result = definition.startSession(valueExists: true, value: input).finish();

    expect(result.valid, isTrue);
    expect(result.issues, isEmpty);
    final value = result.value! as _Json;
    // A direct var retains the native int; no JsonLogic arithmetic is involved.
    expect(value['a'], isA<int>());
    expect(value['a'], maxInt);
    expect(result.changed, isTrue);
    expect(result.changes.map((change) => change['path']), ['/a']);
    expect(input['a'], isA<double>());
    expect(input['a'], nextDouble);
  });
}
