import 'dart:convert';

import 'package:dsh_tavern/src/state/state_engine.dart';
import 'package:test/test.dart';

typedef Json = Map<String, Object?>;
Json op(String operation, String path, [Object? value]) => {
  'op': operation,
  'path': path,
  if (operation != 'remove') 'value': value,
  'why': 'projection test',
};
StateDefinition def(Json properties, {Json extra = const {}}) => StateDefinition.parse({
  'schema': {'type': 'object', 'properties': properties},
  ...extra,
});
List<Json> branches(StateStrictTool tool) {
  final function = tool.tool!['function']! as Json;
  final parameters = function['parameters']! as Json;
  final properties = parameters['properties']! as Json;
  final ops = properties['ops']! as Json;
  final items = ops['items']! as Json;
  return (items['anyOf']! as List<Object?>).cast<Json>();
}

Json properties(Json branch) => branch['properties']! as Json;
bool matches(Json branch, String operation, String path) {
  final p = properties(branch);
  if (!((p['op']! as Json)['enum']! as List<Object?>).contains(operation)) {
    return false;
  }
  final spec = p['path']! as Json;
  return spec.containsKey('enum')
      ? (spec['enum']! as List<Object?>).contains(path)
      : RegExp(spec['pattern']! as String).hasMatch(path);
}

void main() {
  test('public projection drops hidden and unknown fields without shifting array indices', () {
    final d = def({
      'shown': {'type': 'string', 'title': 'PUBLIC_TITLE', 'description': 'public label'},
      'hidden': {
        'type': 'object',
        'x-dsh-hidden': true,
        'description': 'HIDDEN_METADATA',
        'properties': {
          'n': {
            'type': 'integer',
            'enum': [999],
            'default': 999,
          },
        },
      },
      'bag': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
            'secret': {'type': 'string', 'x-dsh-hidden': true},
          },
        },
      },
      'slots': {
        'type': 'array',
        'items': {'type': 'string', 'x-dsh-hidden': true},
      },
    });
    final value = <String, Object?>{
      'shown': 'ok',
      'hidden': {'n': 999},
      'bag': [
        {'name': 'a', 'secret': 'HIDDEN_VALUE', 'unknown': 'UNKNOWN_VALUE'},
        {'name': 'b'},
      ],
      'slots': ['HIDDEN_SLOT_0', 'HIDDEN_SLOT_1'],
      'unknown': 'UNKNOWN_ROOT',
    };
    final projection = d.project(value);
    expect(projection.value, {
      'shown': 'ok',
      'bag': [
        {'name': 'a'},
        {'name': 'b'},
      ],
      'slots': [null, null],
    });
    expect(projection.hiddenPaths, containsAll(['/hidden', '/bag/0/secret', '/slots/0', '/slots/1']));
    expect(projection.summary, contains('public label'));
    expect(jsonEncode(d.strictTool(value: value, valueExists: true).tool), contains('PUBLIC_TITLE'));
    expect(jsonEncode(d.strictTool(value: value, valueExists: true).tool), contains('public label'));
    for (final sentinel in ['HIDDEN_METADATA', 'HIDDEN_VALUE', 'UNKNOWN_VALUE', 'UNKNOWN_ROOT', 'HIDDEN_SLOT']) {
      expect(projection.summary, isNot(contains(sentinel)));
      expect(jsonEncode(d.strictTool(value: value, valueExists: true).tool), isNot(contains(sentinel)));
    }
    final blocked = StateDefinition.parse({
      'schema': {
        'type': 'object',
        'allOf': <Object?>[],
        'properties': {
          'secret': {'type': 'string', 'x-dsh-hidden': true},
        },
      },
    }).project({'secret': 'HIDDEN_VALUE'});
    expect(blocked.hiddenPaths, contains('/secret'));
    expect(blocked.summary, isNot(contains('HIDDEN_VALUE')));
  });

  test('historical wrong-type values are preserved by the session but redacted from automatic projection', () {
    final d = def({
      'items': {
        'type': 'array',
        'items': {'type': 'integer'},
      },
    });
    expect(d.project('UNKNOWN_ROOT_SECRET').valueExists, isFalse);
    expect(
      d.project({
        'items': [1, 'UNKNOWN_ITEM_SECRET', 3],
      }).value,
      {
        'items': [1, null, 3],
      },
    );
    expect(
      d.startSession(valueExists: true, value: 'UNKNOWN_ROOT_SECRET').finish(runRules: false).value,
      'UNKNOWN_ROOT_SECRET',
    );
  });

  test('summary substitutes once, leaves literal ST macros and diagnoses inaccessible pointers', () {
    final d = def(
      {
        'text': {'type': 'string'},
        'secret': {'type': 'string', 'x-dsh-hidden': true},
        'n': {
          'type': ['integer', 'null'],
        },
      },
      extra: {'summary': 'X={{state:/text}}; S={{state:/secret}}; N={{state:/n}}; U={{state:/unknown}}; J={{state}}'},
    );
    final result = d.project({'text': '{{state:/secret}} {{getvar::secret}}', 'secret': 'DO_NOT_REVEAL', 'n': null});
    expect(result.summary, startsWith('X={{state:/secret}} {{getvar::secret}}; S=; N=null; U=; J='));
    expect(result.summary, isNot(contains('DO_NOT_REVEAL')));
    expect(result.issues.where((x) => x['code'] == 'summary_pointer'), hasLength(2));
  });

  test('UI pin paths merge with metadata while invalid role depth and display hints remain diagnosed', () {
    final d = def(
      {
        'n': {'type': 'integer', 'x-dsh-pin': true, 'x-dsh-show': 'bar'},
        's': {'type': 'string', 'x-dsh-show': 'future-widget'},
      },
      extra: {
        'pin': ['/n', '/s', '/unknown'],
        'depth': -1,
        'role': 'future',
      },
    );
    final result = d.project({'n': 1, 's': 'a'});
    expect(result.pinPaths, ['/n', '/s']);
    expect(result.depth, 1);
    expect(result.role, 'system');
    expect(
      result.issues.map((x) => x['code']),
      containsAll(['state_pin', 'summary_depth', 'summary_role', 'schema_show']),
    );
    expect(((d.schema as Json)['properties']! as Json)['s'], containsPair('x-dsh-show', 'future-widget'));
    final zero = def(
      {
        'n': {'type': 'integer'},
      },
      extra: {'depth': 0, 'role': 'user'},
    ).project({'n': 1});
    expect(zero.depth, 0);
    expect(zero.role, 'user');
  });

  test('strict envelope recursively closes every object without changing original optional schema', () {
    final d = def({
      'bag': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
            'count': {'type': 'integer'},
          },
        },
      },
      'optional': {'type': 'string'},
    });
    final tool = d.strictTool(value: {'bag': <Object?>[]}, valueExists: true);
    expect(tool.tool!['type'], 'function');
    expect((tool.tool!['function']! as Json)['name'], 'update_state');
    expect((tool.tool!['function']! as Json)['strict'], isTrue);
    void closed(Object? value) {
      if (value is Json) {
        if (value['type'] == 'object') {
          final fields = value['properties']! as Json;
          expect(value['additionalProperties'], isFalse);
          expect((value['required']! as List<Object?>).toSet(), fields.keys.toSet());
        }
        for (final child in value.values) {
          closed(child);
        }
      } else if (value is List<Object?>) {
        for (final child in value) {
          closed(child);
        }
      }
    }

    closed((tool.tool!['function']! as Json)['parameters']);
    expect((d.schema as Json).containsKey('required'), isFalse);
    expect(d.initialPreview().value, <String, Object?>{});
    for (final branch in branches(tool).where((x) => matches(x, 'remove', '/optional'))) {
      expect(properties(branch).containsKey('value'), isFalse);
    }
  });

  test('strict delta and guard do not inherit new-value bounds enum or length', () {
    final d = def({
      'n': {
        'type': 'integer',
        'minimum': 0,
        'maximum': 10,
        'enum': [0, 10],
        'x-dsh-step': 2,
      },
      'text': {
        'type': 'string',
        'maxLength': 2,
        'enum': ['ok'],
      },
    });
    final list = branches(d.strictTool(value: {'n': -20, 'text': 'long'}, valueExists: true));
    final add = list.firstWhere((x) => matches(x, 'add', '/n') && properties(x).containsKey('from'));
    expect(properties(add)['value'], {'type': 'number'});
    expect(properties(add)['from'], {'type': 'integer'});
    final text = list.firstWhere((x) => matches(x, 'set', '/text') && properties(x).containsKey('from'));
    expect(properties(text)['from'], {'type': 'string'});
    expect(properties(text)['value'], {
      'type': 'string',
      'enum': ['ok'],
    });
  });

  test('array paths use canonical schema index patterns and move alone admits append token', () {
    final d = def({
      'bag': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'n': {'type': 'integer'},
          },
        },
      },
    });
    final list = branches(d.strictTool(value: {'bag': <Object?>[]}, valueExists: true));
    expect(list.any((x) => matches(x, 'set', '/bag/123456/n')), isTrue);
    expect(list.any((x) => matches(x, 'set', '/bag/01/n')), isFalse);
    expect(list.any((x) => matches(x, 'set', '/bag/-')), isFalse);
    expect(list.any((x) => matches(x, 'move', '/bag/-')), isTrue);
    final move = list.firstWhere((x) => matches(x, 'move', '/bag/2'));
    final source = properties(move)['value']! as Json;
    expect(RegExp(source['pattern']! as String).hasMatch('/a~1b/~0x'), isTrue);
    expect(RegExp(source['pattern']! as String).hasMatch('/bad~2'), isFalse);
  });

  test('protected descendants omit whole model operations and reject unexpected parent replacement', () {
    final d = def({
      'editable': {'type': 'integer'},
      'locked': {
        'type': 'integer',
        'x-dsh-by': ['user'],
      },
      'secret': {'type': 'string', 'x-dsh-hidden': true},
    });
    final value = <String, Object?>{'editable': 0, 'locked': 2, 'secret': 'S'};
    final list = branches(d.strictTool(value: value, valueExists: true));
    expect(list.any((x) => matches(x, 'set', '')), isFalse);
    expect(list.any((x) => matches(x, 'set', '/editable')), isTrue);
    expect(list.any((x) => matches(x, 'set', '/locked')), isFalse);
    final s = d.startSession(valueExists: true, value: value);
    expect(
      s.apply([
        op('set', '', {'editable': 1, 'locked': 2, 'secret': 'S'}),
      ], actor: StateActor.model).rejectedCount,
      1,
    );
    expect(s.apply([op('set', '/editable', 1)], actor: StateActor.model).acceptedCount, 1);
    expect(s.finish(runRules: false).value, {'editable': 1, 'locked': 2, 'secret': 'S'});
  });

  test('unknown saved keys suppress parent capability and cannot be removed through a model parent set', () {
    final d = def({
      'n': {'type': 'integer'},
    });
    final value = <String, Object?>{
      'n': 0,
      'unknown': {'future': 1},
    };
    final tool = d.strictTool(value: value, valueExists: true);
    expect(branches(tool).any((x) => matches(x, 'set', '')), isFalse);
    final s = d.startSession(valueExists: true, value: value);
    expect(
      s.apply([
        op('set', '', {'n': 1}),
        op('set', '', {
          'n': 1,
          'unknown': {'future': 1},
        }),
      ], actor: StateActor.model).rejectedCount,
      2,
    );
    expect(s.apply([op('set', '/n', 1)], actor: StateActor.model).acceptedCount, 1);
    expect(s.finish(runRules: false).value, {
      'n': 1,
      'unknown': {'future': 1},
    });
  });

  test('nullable model values expose non-null alternatives; null-only does not invent a tool', () {
    final d = def({
      'nullable': {
        'type': ['string', 'null'],
      },
      'onlyNull': {'type': 'null'},
    });
    final tool = d.strictTool(value: {'nullable': null, 'onlyNull': null}, valueExists: true);
    final list = branches(tool);
    expect(list.any((x) => matches(x, 'set', '/onlyNull')), isFalse);
    expect(properties(list.firstWhere((x) => matches(x, 'set', '/nullable')))['value'], {'type': 'string'});
    expect(tool.issues.map((x) => x['code']), contains('strict_nullable'));
    expect(
      StateDefinition.parse({
        'schema': {'type': 'null'},
      }).strictTool().tool,
      isNull,
    );
    final s = d.startSession(valueExists: true, value: {'nullable': 'a', 'onlyNull': null});
    expect(s.apply([op('set', '/nullable', null)], actor: StateActor.model).rejectedCount, 1);
    expect(s.apply([op('set', '/nullable', null)], actor: StateActor.user).acceptedCount, 1);
  });

  test('strict branch and byte overflow remove the entire tool and model capability set', () {
    final d = def({
      for (var i = 0; i < 257; i++) 'n$i': {'type': 'integer'},
    });
    final value = <String, Object?>{for (var i = 0; i < 257; i++) 'n$i': 0};
    final tool = d.strictTool(value: value, valueExists: true);
    expect(tool.tool, isNull);
    expect(tool.issues.map((x) => x['code']), contains('strict_limit'));
    final s = d.startSession(valueExists: true, value: value);
    expect(s.apply([op('set', '/n0', 1)], actor: StateActor.model).rejectedCount, 1);
    expect(s.apply([op('set', '/n0', 1)], actor: StateActor.user).acceptedCount, 1);
    final bytes = def({
      'text': {
        'type': 'string',
        'enum': ['字' * (100 * 1024)],
      },
    }).strictTool();
    expect(bytes.tool, isNull);
    expect(bytes.issues.map((x) => x['code']), contains('strict_limit'));
  });

  test('explicit scalar type does not advertise unreachable properties or spend their branch budget', () {
    final d = StateDefinition.parse({
      'schema': {
        'type': 'string',
        'properties': {
          for (var i = 0; i < 256; i++) 'p$i': {'type': 'integer'},
        },
      },
      'init': 'a',
    });
    final tool = d.strictTool(value: 'a', valueExists: true);
    expect(tool.tool, isNotNull);
    final list = branches(tool);
    expect(list, hasLength(4));
    expect(list.any((x) => matches(x, 'set', '')), isTrue);
    expect(list.any((x) => matches(x, 'set', '/p0')), isFalse);
    final s = d.startSession(valueExists: true, value: 'a');
    expect(s.apply([op('set', '', 'b')], actor: StateActor.model).acceptedCount, 1);
    expect(s.apply([op('set', '/p0', 1)], actor: StateActor.model).rejectedCount, 1);
    expect(s.finish(runRules: false).value, 'b');
  });

  test('author-defined public derivation can intentionally reveal hidden data; no taint claim is made', () {
    final d = def(
      {
        'secret': {'type': 'string', 'x-dsh-hidden': true},
        'intentional': {
          'type': 'string',
          'x-dsh-derive': {'var': 'secret'},
        },
      },
      extra: {
        'init': {'secret': 'AUTHOR_PUBLISHED'},
      },
    );
    final value = d.initialPreview().value;
    final projection = d.project(value);
    expect(projection.value, {'intentional': 'AUTHOR_PUBLISHED'});
    expect(projection.summary, contains('AUTHOR_PUBLISHED'));
    expect(projection.hiddenPaths, contains('/secret'));
  });
}
