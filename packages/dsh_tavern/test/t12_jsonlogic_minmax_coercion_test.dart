import 'package:dsh_tavern/src/state/state_engine.dart';
import 'package:test/test.dart';

typedef _Json = Map<String, Object?>;

// Two keys keep this a literal JSON object rather than a JsonLogic op.
// All input values are finite JSON; only numeric conversion produces NaN.
_Json _coercionAfterNaN(String op) => {
  '!': {
    op: [
      'not-a-number',
      {'toString': 0, 'literal': true},
    ],
  },
};

void main() {
  test('min and max do not hide a later numeric coercion error after NaN', () {
    for (final op in ['min', 'max']) {
      final result = evaluateStateExpression(_coercionAfterNaN(op), null);

      // The old product returns valid=true/value=true here: ! consumes NaN.
      expect(result.valid, isFalse, reason: '$op must convert the later literal');
      expect(result.value, isNull, reason: op);
      expect(result.issues.map((issue) => issue['code']), ['logic_coercion'], reason: op);
    }
  });

  test('min and max preserve NaN results lazy branches signed zero and empty extrema', () {
    for (final op in ['min', 'max']) {
      final ordinaryNaN = <String, Object?>{
        op: ['not-a-number', 7],
      };
      final raw = evaluateStateExpression(ordinaryNaN, null);
      expect(raw.valid, isFalse, reason: '$op direct NaN is not a JSON result');
      expect(raw.issues.map((issue) => issue['code']), ['logic_result'], reason: '$op direct NaN');

      final wrapped = evaluateStateExpression({'!': ordinaryNaN}, null);
      expect(wrapped.valid, isTrue, reason: '$op NaN remains usable as an intermediate');
      expect(wrapped.value, isTrue, reason: '$op !NaN');
      expect(wrapped.issues, isEmpty, reason: '$op !NaN');

      final lazy = <(String, _Json, Object?)>[
        (
          'if',
          {
            'if': [true, 7, _coercionAfterNaN(op)],
          },
          7,
        ),
        (
          'and',
          {
            'and': [false, _coercionAfterNaN(op)],
          },
          false,
        ),
        (
          'or',
          {
            'or': [true, _coercionAfterNaN(op)],
          },
          true,
        ),
      ];
      for (final row in lazy) {
        final result = evaluateStateExpression(row.$2, null);
        final reason = '$op in the unselected ${row.$1} branch';
        expect(result.valid, isTrue, reason: reason);
        expect(result.value, row.$3, reason: reason);
        expect(result.issues, isEmpty, reason: reason);
      }

      final zeroCases = <(String, List<Object?>)>[
        ('positive then negative', [0.0, -0.0]),
        ('negative then positive', [-0.0, 0.0]),
      ];
      for (final row in zeroCases) {
        final result = evaluateStateExpression({op: row.$2}, null);
        final reason = '$op zero order: ${row.$1}';
        expect(result.valid, isTrue, reason: reason);
        expect(result.value, 0, reason: reason);
        expect((result.value! as num).isNegative, op == 'min', reason: reason);
      }

      final empty = evaluateStateExpression({
        '===': [
          {op: <Object?>[]},
          {
            '/': [op == 'min' ? 1 : -1, 0],
          },
        ],
      }, null);
      expect(empty.valid, isTrue, reason: '$op empty result remains an infinite intermediate');
      expect(empty.value, isTrue, reason: '$op empty result has the expected infinity sign');

      final finite = evaluateStateExpression({
        op: [4, -3],
      }, null);
      expect(finite.valid, isTrue, reason: '$op finite control');
      expect(finite.value, op == 'min' ? -3 : 4, reason: '$op finite control');
    }
  });

  test('rule coercion errors preserve state effects and once bookkeeping independently', () {
    final original = <String, Object?>{'n': 7};
    final definition = StateDefinition.parse({
      'schema': {
        'type': 'object',
        'properties': {
          'n': {'type': 'integer'},
        },
      },
      'rules': [
        for (final op in ['min', 'max'])
          {
            'id': 'bad-$op',
            'once': true,
            'when': _coercionAfterNaN(op),
            'do': [
              {
                'type': 'state',
                'ops': [
                  {'op': 'set', 'path': '/n', 'value': 99, 'why': 'must not run'},
                ],
              },
              {'type': 'notice', 'text': 'bad-$op must not run'},
            ],
          },
        {
          'id': 'control',
          'once': true,
          'when': true,
          'do': [
            {'type': 'notice', 'text': 'control still runs'},
          ],
        },
      ],
    });
    final result = definition.startSession(valueExists: true, value: original).finish();

    expect(result.value, {'n': 7});
    expect(original, {'n': 7});
    expect(result.valid, isTrue, reason: 'condition errors do not invalidate otherwise valid state');
    expect(result.changes, isEmpty);
    expect(result.issues.map((issue) => issue['code']), ['logic_coercion', 'logic_coercion']);

    final judgments = result.receipts.where((receipt) {
      final operation = receipt['operation']! as _Json;
      return operation['op'] == 'rule';
    }).toList();
    expect(judgments.map((receipt) => receipt['status']), ['condition_error', 'condition_error', 'matched']);
    for (var i = 0; i < 2; i++) {
      final op = ['min', 'max'][i];
      final receipt = judgments[i];
      expect(receipt['source'], 'id:bad-$op', reason: op);
      expect(receipt['accepted'], isFalse, reason: op);
      expect(receipt['matched'], isNull, reason: op);
      expect(receipt['consumedOnce'], isFalse, reason: op);
      final issues = receipt['issues']! as List<Object?>;
      expect(issues.map((issue) => (issue! as _Json)['code']), ['logic_coercion'], reason: op);
    }

    expect(result.effects, [
      {'type': 'notice', 'text': 'control still runs', 'ruleId': 'id:control', 'source': 'rules'},
    ]);
    expect(result.runtimeExists, isTrue);
    expect(result.runtime, {
      'version': 1,
      'firedRules': ['id:control'],
    });
    expect(judgments.last['accepted'], isTrue);
    expect(judgments.last['consumedOnce'], isTrue);
  });
}
