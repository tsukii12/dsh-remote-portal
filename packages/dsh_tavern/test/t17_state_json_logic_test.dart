import 'dart:convert';

import 'package:dsh_tavern/src/state/state_engine.dart';
import 'package:test/test.dart';

// Expectations were obtained by executing the unchanged pinned upstream JS in
// native V8. Running these Dart tests is a separate owner verification step.
const _oracle = r'''{
  "source": {
    "repository": "jwadhams/json-logic-js",
    "commit": "c5c73601c90b11e98f6846609bac4dec203d1c18",
    "blob": "3d238d5ffc7ef4997a6192aaf434eba5ecf88f4a",
    "version": "2.0.5"
  },
  "execution": "Original pinned JS source executed in the tools native V8. No Dart or T17 implementation executed.",
  "cases": [
    {
      "name": "empty_array_falsy",
      "rule": {
        "!!": [
          []
        ]
      },
      "data": null,
      "resultKind": "json",
      "result": false
    },
    {
      "name": "string_zero_truthy",
      "rule": {
        "!!": [
          "0"
        ]
      },
      "data": null,
      "resultKind": "json",
      "result": true
    },
    {
      "name": "empty_object_truthy",
      "rule": {
        "!!": [
          {}
        ]
      },
      "data": null,
      "resultKind": "json",
      "result": true
    },
    {
      "name": "and_returns_first_falsy",
      "rule": {
        "and": [
          true,
          0,
          7
        ]
      },
      "data": null,
      "resultKind": "json",
      "result": 0
    },
    {
      "name": "or_returns_first_truthy",
      "rule": {
        "or": [
          false,
          "ready",
          7
        ]
      },
      "data": null,
      "resultKind": "json",
      "result": "ready"
    },
    {
      "name": "if_short_circuits_nonfinite_branch",
      "rule": {
        "if": [
          true,
          7,
          {
            "/": [
              1,
              0
            ]
          }
        ]
      },
      "data": null,
      "resultKind": "json",
      "result": 7
    },
    {
      "name": "loose_number_string",
      "rule": {
        "==": [
          1,
          "1"
        ]
      },
      "data": null,
      "resultKind": "json",
      "result": true
    },
    {
      "name": "strict_number_string",
      "rule": {
        "===": [
          1,
          "1"
        ]
      },
      "data": null,
      "resultKind": "json",
      "result": false
    },
    {
      "name": "loose_zero_false",
      "rule": {
        "==": [
          0,
          false
        ]
      },
      "data": null,
      "resultKind": "json",
      "result": true
    },
    {
      "name": "object_equality_is_not_deep",
      "rule": {
        "==": [
          {
            "a": 1,
            "b": 2
          },
          {
            "a": 1,
            "b": 2
          }
        ]
      },
      "data": null,
      "resultKind": "json",
      "result": false
    },
    {
      "name": "same_data_array_identity",
      "rule": {
        "===": [
          {
            "var": "a"
          },
          {
            "var": "a"
          }
        ]
      },
      "data": {
        "a": [
          1
        ]
      },
      "resultKind": "json",
      "result": true
    },
    {
      "name": "plus_uses_parseFloat_prefix",
      "rule": {
        "+": "3.14tail"
      },
      "data": null,
      "resultKind": "json",
      "result": 3.14
    },
    {
      "name": "multiply_uses_parseFloat_prefix",
      "rule": {
        "*": [
          2,
          "3tail"
        ]
      },
      "data": null,
      "resultKind": "json",
      "result": 6
    },
    {
      "name": "minus_uses_numeric_conversion",
      "rule": {
        "-": [
          2,
          "1tail"
        ]
      },
      "data": null,
      "resultKind": "NaN"
    },
    {
      "name": "plus_boolean_is_nan",
      "rule": {
        "+": [
          true,
          1
        ]
      },
      "data": null,
      "resultKind": "NaN"
    },
    {
      "name": "minus_boolean",
      "rule": {
        "-": [
          true,
          1
        ]
      },
      "data": null,
      "resultKind": "json",
      "result": 0
    },
    {
      "name": "negative_remainder",
      "rule": {
        "%": [
          -5,
          2
        ]
      },
      "data": null,
      "resultKind": "json",
      "result": -1
    },
    {
      "name": "var_explicit_null_kept",
      "rule": {
        "var": [
          "a",
          7
        ]
      },
      "data": {
        "a": null
      },
      "resultKind": "json",
      "result": null
    },
    {
      "name": "var_missing_default",
      "rule": {
        "var": [
          "a",
          7
        ]
      },
      "data": {},
      "resultKind": "json",
      "result": 7
    },
    {
      "name": "var_dot_path",
      "rule": {
        "var": "a.b"
      },
      "data": {
        "a.b": 7,
        "a": {
          "b": 3
        }
      },
      "resultKind": "json",
      "result": 3
    },
    {
      "name": "var_empty_returns_root",
      "rule": {
        "var": ""
      },
      "data": {
        "x": 1
      },
      "resultKind": "json",
      "result": {
        "x": 1
      }
    },
    {
      "name": "less_than_chain",
      "rule": {
        "<": [
          1,
          2,
          3
        ]
      },
      "data": null,
      "resultKind": "json",
      "result": true
    },
    {
      "name": "empty_and_nonjson",
      "rule": {
        "and": []
      },
      "data": null,
      "resultKind": "undefined"
    },
    {
      "name": "divide_zero_nonjson",
      "rule": {
        "/": [
          1,
          0
        ]
      },
      "data": null,
      "resultKind": "Infinity"
    }
  ]
}
''';

void main() {
  final fixture = jsonDecode(_oracle) as Map<String, Object?>;
  for (final raw in fixture['cases']! as List<Object?>) {
    final row = raw! as Map<String, Object?>;
    test('pinned JsonLogic ${row['name']}', () {
      final result = evaluateStateExpression(row['rule'], row['data']);
      if (row['resultKind'] == 'json') {
        expect(result.valid, isTrue, reason: '${result.issues}');
        expect(result.value, row['result']);
      } else {
        expect(result.valid, isFalse);
        expect(result.issues.map((x) => x['code']), contains('logic_result'));
      }
    });
  }

  test('JS coercion preserves empty array equality lexical comparison and numeric var access', () {
    expect(
      evaluateStateExpression({
        '==': [<Object?>[], false],
      }, null).value,
      isTrue,
    );
    expect(
      evaluateStateExpression({
        '===': [<Object?>[], <Object?>[]],
      }, null).value,
      isFalse,
    );
    expect(
      evaluateStateExpression({
        '<': ['20', '3'],
      }, null).value,
      isTrue,
    );
    expect(evaluateStateExpression({'var': 0}, ['first']).value, 'first');
    expect(
      evaluateStateExpression(
        {'var': 'a.length'},
        {
          'a': [1, 2],
        },
      ).value,
      2,
    );
    expect(
      evaluateStateExpression({
        '-': ['0x10', 1],
      }, null).value,
      15,
    );
    expect(
      evaluateStateExpression({
        '-': ['\u00851', 0],
      }, null).valid,
      isFalse,
    );
  });

  test('nonfinite intermediate may be compared while an unknown lazy branch is still unsupported', () {
    final finite = evaluateStateExpression({
      'if': [
        {
          '>': [
            {
              '/': [1, 0],
            },
            0,
          ],
        },
        4,
        8,
      ],
    }, null);
    expect(finite.valid, isTrue);
    expect(finite.value, 4);
    final unknown = evaluateStateExpression({
      'if': [
        true,
        4,
        {'log': 0},
      ],
    }, null);
    expect(unknown.valid, isFalse);
    expect(unknown.issues.map((x) => x['code']), contains('logic_operator'));
    expect(
      evaluateStateExpression(
        {
          'var': {
            'if': [true, 'x', 'y'],
          },
        },
        {'x': 1},
      ).valid,
      isFalse,
    );
  });

  test('expression result and supplied data snapshots do not alias the caller', () {
    final data = <String, Object?>{
      'a': [1],
    };
    final result = evaluateStateExpression({'var': ''}, data);
    (data['a']! as List<Object?>).add(2);
    (result.value! as Map<String, Object?>)['a'] = 99;
    expect(result.value, {
      'a': [1],
    });
  });

  test('based Number strings require unsigned radix digits rather than BigInt sign syntax', () {
    for (final text in ['0x-1', '0x+1', '0b-1', '0o+7']) {
      final result = evaluateStateExpression({
        '-': [text, 0],
      }, null);
      expect(result.valid, isFalse, reason: text);
      expect(result.issues.map((x) => x['code']), contains('logic_result'));
    }
    for (final row in <(String, num)>[('0x10', 16), ('0b10', 2), ('0o10', 8)]) {
      expect(
        evaluateStateExpression({
          '-': [row.$1, 0],
        }, null).value,
        row.$2,
      );
    }
  });

  test('JS numeric string uses shortest round trip with decimal and exponent thresholds', () {
    const n = 1000000000000000128;
    expect(
      evaluateStateExpression({
        '==': [
          [n],
          '1000000000000000100',
        ],
      }, null).value,
      isTrue,
    );
    expect(evaluateStateExpression({'var': n}, {'1000000000000000100': 'found'}).value, 'found');
    for (final row in <(num, String)>[
      (1e-6, '0.000001'),
      (1e-7, '1e-7'),
      (1e20, '100000000000000000000'),
      (1e21, '1e+21'),
    ]) {
      expect(
        evaluateStateExpression({
          '==': [
            [row.$1],
            row.$2,
          ],
        }, null).value,
        isTrue,
      );
    }
  });

  test('JSON object that shadows toString cannot be silently coerced with the inherited default', () {
    final result = evaluateStateExpression({
      '==': [
        {'toString': 1, 'x': 2},
        '[object Object]',
      ],
    }, null);
    expect(result.valid, isFalse);
    expect(result.issues.map((x) => x['code']), contains('logic_coercion'));
    expect(
      evaluateStateExpression({
        '!!': [
          {'toString': 1, 'x': 2},
        ],
      }, null).value,
      isTrue,
    );
  });

  test('each expression enforces AST node and recursive depth bounds with diagnostics', () {
    final wide = evaluateStateExpression({
      'and': [for (var i = 0; i < 4097; i++) true],
    }, null);
    expect(wide.valid, isFalse);
    expect(wide.issues.map((x) => x['code']), contains('logic_limit'));
    Object? nested = true;
    for (var i = 0; i < 65; i++) {
      nested = {'!': nested};
    }
    final deep = evaluateStateExpression(nested, null);
    expect(deep.valid, isFalse);
    expect(deep.issues.map((x) => x['code']), contains('logic_limit'));
  });
}
