import 'dart:convert';

import 'package:dsh_tavern/src/director/direct_tool.dart';
import 'package:test/test.dart';

typedef Json = Map<String, Object?>;

void main() {
  test('strict direct closes all five object schemas and uses only the supported schema vocabulary', () {
    final tool = directToolDefinition();
    expect(tool['type'], 'function');
    final function = tool['function']! as Json;
    expect(function['name'], 'direct');
    expect(function['strict'], isTrue);
    final parameters = function['parameters']! as Json;
    expect(parameters['required'], ['notes', 'beat', 'prefetch', 'suggestions', 'events']);
    var objects = 0;
    void visit(Json schema) {
      expect(
        schema.keys.toSet().difference(const {
          'type',
          'description',
          'properties',
          'required',
          'additionalProperties',
          'items',
          'enum',
          'anyOf',
        }),
        isEmpty,
      );
      if (schema['type'] case final String type) {
        expect(const {'object', 'string', 'array'}, contains(type));
      }
      if (schema['type'] == 'object') {
        objects++;
        final properties = schema['properties']! as Json;
        expect(schema['additionalProperties'], isFalse);
        expect((schema['required']! as List<Object?>).toSet(), properties.keys.toSet());
        expect(schema['required'], hasLength(properties.length));
        for (final child in properties.values) {
          visit(child! as Json);
        }
      }
      if (schema['items'] case final Map<String, Object?> child) {
        visit(child);
      }
      if (schema['anyOf'] case final List<Object?> alternatives) {
        for (final child in alternatives) {
          visit(child! as Json);
        }
      }
    }

    visit(parameters);
    expect(objects, 5);
    final properties = parameters['properties']! as Json;
    final items = (properties['prefetch']! as Json)['items']! as Json;
    final alternatives = items['anyOf']! as List<Object?>;
    expect(alternatives, hasLength(2));
    expect(
      [for (final branch in alternatives) (((branch! as Json)['properties']! as Json)['kind']! as Json)['enum']],
      [
        ['worldInfo'],
        ['memory'],
      ],
    );
  });

  test('generic tool omits strict and every returned schema is independently mutable', () {
    final tool = directToolDefinition(strict: false);
    final function = tool['function']! as Json;
    expect(function.containsKey('strict'), isFalse);
    final parameters = function['parameters']! as Json;
    (parameters['required']! as List<Object?>).clear();
    ((parameters['properties']! as Json)['notes']! as Json)['type'] = 'number';
    final fresh = (directToolDefinition()['function']! as Json)['parameters']! as Json;
    expect(fresh['required'], hasLength(5));
    expect(((fresh['properties']! as Json)['notes']! as Json)['type'], 'string');
  });

  test('minimal legal output accepts empty optional text and empty references or events', () {
    final raw = _valid();
    raw['notes'] = '';
    raw['beat'] = '';
    raw['prefetch'] = <Object?>[];
    raw['events'] = <Object?>[];
    for (final item in raw['suggestions']! as List<Object?>) {
      (item! as Json)['risk'] = '';
    }
    final result = DirectOutput.parse(raw);
    expect(result.toJson(), raw);
    expect(result.notes, '');
    expect(result.beat, '');
    expect(result.issues, isEmpty);
  });

  test('all five root fields are required and unexpected fields or wrong types reject', () {
    for (final key in ['notes', 'beat', 'prefetch', 'suggestions', 'events']) {
      final missing = _valid()..remove(key);
      _reject(missing);
      final explicitNull = _valid()..[key] = null;
      _reject(explicitNull);
      final wrong = _valid()..[key] = key == 'notes' || key == 'beat' ? <Object?>[] : 'not an array';
      _reject(wrong);
    }
    _reject(_valid()..['extra'] = 'preserve elsewhere, not in direct');
  });

  test('suggestions require exactly three closed records with nonempty text and string risk', () {
    for (final count in [0, 2, 4]) {
      _reject(
        _valid()
          ..['suggestions'] = <Object?>[
            for (var i = 0; i < count; i++) <String, Object?>{'text': 'option', 'risk': ''},
          ],
      );
    }
    for (final invalid in <Object?>[
      <String, Object?>{'text': '', 'risk': ''},
      <String, Object?>{'text': 'option'},
      <String, Object?>{'text': 'option', 'risk': null},
      <String, Object?>{'text': 'option', 'risk': '', 'id': 'unexpected'},
      <String, Object?>{'text': 1, 'risk': ''},
      'not an object',
    ]) {
      final raw = _valid();
      (raw['suggestions']! as List<Object?>)[0] = invalid;
      _reject(raw);
    }
    final spaces = _valid();
    _suggestion(spaces)['text'] = ' ';
    expect(DirectOutput.parse(spaces).suggestions.first['text'], ' ');
  });

  test('reference variants preserve exact identities duplicates and request order', () {
    final raw = _valid()
      ..['prefetch'] = <Object?>[
        <String, Object?>{'kind': 'worldInfo', 'bookId': ' Book ', 'uid': ' 007 '},
        <String, Object?>{'kind': 'memory', 'id': '记忆'},
        <String, Object?>{'kind': 'worldInfo', 'bookId': ' Book ', 'uid': ' 007 '},
      ];
    final result = DirectOutput.parse(raw);
    expect(result.prefetch, raw['prefetch']);
    expect(result.prefetch, hasLength(3));
  });

  test('reference variants reject unknown kind mixed fields empty identity and implicit numbers', () {
    for (final invalid in <Object?>[
      <String, Object?>{'kind': 'other', 'id': 'x'},
      <String, Object?>{'kind': 'worldInfo', 'bookId': 'book', 'uid': '1', 'id': 'x'},
      <String, Object?>{'kind': 'worldInfo', 'bookId': 'book'},
      <String, Object?>{'kind': 'worldInfo', 'bookId': '', 'uid': '1'},
      <String, Object?>{'kind': 'worldInfo', 'bookId': 'book', 'uid': ''},
      <String, Object?>{'kind': 'worldInfo', 'bookId': 'book', 'uid': 1},
      <String, Object?>{'kind': 'memory', 'id': ''},
      <String, Object?>{'kind': 'memory', 'id': 'x', 'bookId': 'book'},
      <String, Object?>{'kind': null, 'id': 'x'},
      <Object?>[],
    ]) {
      _reject(_valid()..['prefetch'] = <Object?>[invalid]);
    }
  });

  test('events accept description strings and reject arbitrary payload objects or extra fields', () {
    final raw = _valid()
      ..['events'] = <Object?>[
        <String, Object?>{'name': ' secret reveal ', 'data': '{"op":"set","path":"/hidden"}'},
        <String, Object?>{'name': 'empty-description', 'data': ''},
      ];
    expect(DirectOutput.parse(raw).events, raw['events']);
    for (final invalid in <Object?>[
      <String, Object?>{'name': '', 'data': ''},
      <String, Object?>{'name': 'event'},
      <String, Object?>{
        'name': 'event',
        'data': <String, Object?>{'op': 'set'},
      },
      <String, Object?>{'name': 'event', 'data': <Object?>[]},
      <String, Object?>{'name': 'event', 'data': '', 'executed': true},
      <String, Object?>{'name': 'event', 'data': double.nan},
    ]) {
      _reject(_valid()..['events'] = <Object?>[invalid]);
    }
  });

  test('reference and event counts accept their exact caps and reject the next item', () {
    final raw = _valid();
    raw['prefetch'] = <Object?>[
      for (var i = 0; i < 64; i++) <String, Object?>{'kind': 'memory', 'id': '$i'},
    ];
    raw['events'] = <Object?>[
      for (var i = 0; i < 32; i++) <String, Object?>{'name': '$i', 'data': ''},
    ];
    expect(DirectOutput.parse(raw).prefetch, hasLength(64));
    expect(DirectOutput.parse(raw).events, hasLength(32));
    final extraRef = _copy(raw);
    (extraRef['prefetch']! as List<Object?>).add(<String, Object?>{'kind': 'memory', 'id': 'next'});
    _reject(extraRef);
    final extraEvent = _copy(raw);
    (extraEvent['events']! as List<Object?>).add(<String, Object?>{'name': 'next', 'data': ''});
    _reject(extraEvent);
  });

  test('each string byte limit is inclusive and an additional ASCII byte rejects', () {
    final cases = <(int, void Function(Json, String))>[
      (
        64 * 1024,
        (raw, text) {
          raw['notes'] = text;
        },
      ),
      (
        16 * 1024,
        (raw, text) {
          raw['beat'] = text;
        },
      ),
      (
        4 * 1024,
        (raw, text) {
          _suggestion(raw)['text'] = text;
        },
      ),
      (
        1024,
        (raw, text) {
          _suggestion(raw)['risk'] = text;
        },
      ),
      (
        1024,
        (raw, text) {
          _reference(raw)['bookId'] = text;
        },
      ),
      (
        1024,
        (raw, text) {
          _reference(raw)['uid'] = text;
        },
      ),
      (
        1024,
        (raw, text) {
          (raw['prefetch']! as List<Object?>)[1] = <String, Object?>{'kind': 'memory', 'id': text};
        },
      ),
      (
        1024,
        (raw, text) {
          _event(raw)['name'] = text;
        },
      ),
      (
        16 * 1024,
        (raw, text) {
          _event(raw)['data'] = text;
        },
      ),
    ];
    for (final limit in cases) {
      final raw = _valid();
      limit.$2(raw, 'x' * limit.$1);
      expect(DirectOutput.parse(raw).toJson(), raw);
      limit.$2(raw, 'x' * (limit.$1 + 1));
      _reject(raw);
    }
  });

  test('byte limits count CJK and supplementary Unicode UTF-8 rather than characters', () {
    final raw = _valid()..['notes'] = '${'界' * 21845}a';
    expect(utf8.encode(raw['notes']! as String), hasLength(64 * 1024));
    expect(DirectOutput.parse(raw).notes, raw['notes']);
    raw['notes'] = '${raw['notes']}b';
    _reject(raw);
    final emoji = _valid();
    _suggestion(emoji)['text'] = '😀' * 1024;
    expect(DirectOutput.parse(emoji).suggestions.first['text'], '😀' * 1024);
    _suggestion(emoji)['text'] = '${'😀' * 1024}a';
    _reject(emoji);
  });

  test('the complete encoded JSON accepts exactly 256 KiB and rejects one extra byte', () {
    final raw = _valid()
      ..['notes'] = ''
      ..['beat'] = ''
      ..['prefetch'] = <Object?>[];
    raw['events'] = <Object?>[
      for (var i = 0; i < 16; i++) <String, Object?>{'name': '$i', 'data': i < 15 ? 'x' * (16 * 1024) : ''},
    ];
    final remaining = 256 * 1024 - utf8.encode(jsonEncode(raw)).length;
    expect(remaining, inInclusiveRange(1, 16 * 1024 - 1));
    final last = (raw['events']! as List<Object?>).last! as Json;
    last['data'] = 'x' * remaining;
    expect(utf8.encode(jsonEncode(raw)), hasLength(256 * 1024));
    expect(DirectOutput.parse(raw).toJson(), raw);
    last['data'] = 'x' * (remaining + 1);
    _reject(raw);
  });

  test('total byte validation includes JSON escaping and precedes beat filtering', () {
    final escaped = _valid()..['notes'] = '\u0000' * (64 * 1024);
    expect(utf8.encode(escaped['notes']! as String), hasLength(64 * 1024));
    _reject(escaped);
    final removable = _valid()..['beat'] = 'Alice ${'x' * (16 * 1024)}.';
    expect(sanitizeDirectorBeat(removable['beat']! as String, 'Alice').text, '');
    _reject(removable, personaName: 'Alice');
  });

  test('invalid types cycles and secrets always produce the same safe FormatException', () {
    final secret = 'SECRET_CREDENTIAL_MUST_NOT_APPEAR';
    _reject(_valid()..['notes'] = '$secret${'x' * (64 * 1024)}');
    _reject(_valid()..['notes'] = double.infinity);
    final cyclic = <Object?>[];
    cyclic.add(cyclic);
    _reject(_valid()..['prefetch'] = cyclic);
    _reject(
      _valid()
        ..['events'] = <Object?>[
          <Object?, Object?>{'name': 'x', 7: secret},
        ],
    );
    _reject(
      _valid()
        ..['events'] = <Object?>[
          <String, Object?>{'name': 'x', 'data': _SecretObject(secret)},
        ],
    );
  });

  test('input mutations and every returned collection are detached from the stored output', () {
    final raw = _valid()..['beat'] = 'Alice走开。余下不动。';
    final result = DirectOutput.parse(raw, personaName: 'Alice');
    final expected = result.toJson();
    raw['notes'] = 'changed';
    _reference(raw)['uid'] = 'changed';
    _suggestion(raw)['text'] = 'changed';
    _event(raw)['data'] = 'changed';
    final copy = result.toJson();
    copy['notes'] = 'changed copy';
    (copy['prefetch']! as List<Object?>).clear();
    result.prefetch.first['uid'] = 'changed getter';
    result.suggestions.first['text'] = 'changed getter';
    result.events.first['data'] = 'changed getter';
    result.issues.first['offset'] = -1;
    result.issues.clear();
    expect(result.toJson(), expected);
    expect(result.notes, 'private notes');
    expect(result.beat, '余下不动。');
    expect(result.issues.single['offset'], 0);
  });

  test('notes suggestions events and retained beat text preserve literal macro syntax', () {
    final raw = _valid();
    raw['notes'] = '{{setvar::secret::1}}\r\n隐藏';
    raw['beat'] = '风声{{getvar::secret}}。';
    _suggestion(raw)['text'] = '{{incvar::counter}}';
    _suggestion(raw)['risk'] = '{{random::a::b}}';
    _event(raw)['data'] = '{"macro":"{{setglobalvar::x::1}}"}';
    final result = DirectOutput.parse(raw, personaName: 'Alice');
    expect(result.toJson(), raw);
    expect(result.issues, isEmpty);
  });

  test('fixed action prefixes remove only the named persona sentence', () {
    for (final action in ['走', '说', '决定', '拿', '转身', '点头', '摇头', '回答', '问', '推', '冲', '握', '选择', '同意', '拒绝']) {
      final result = sanitizeDirectorBeat('林$action了。风继续吹。', '林');
      expect(result.text, '风继续吹。', reason: action);
      expect(result.issues.single['offset'], 0);
      expect(result.issues.single['end'], '林$action了。'.length);
    }
  });

  test('whitespace and both colons trigger the heuristic without normalizing surroundings', () {
    const original = '  Alice: move.\r\n\tAlice：决定。\nAlice waits!  风吹。\n';
    final result = sanitizeDirectorBeat(original, 'Alice');
    expect(result.text, '  \r\n\t\n  风吹。\n');
    expect(result.issues, hasLength(3));
    expect(result.issues.first['offset'], 2);
  });

  test('longer names ordinary prefixes and noninitial quoted mentions remain unchanged', () {
    const latin = 'Alice2 走开。风中有人说：“Alice 决定留下。”';
    expect(sanitizeDirectorBeat(latin, 'Alice').text, latin);
    const chinese = '林场安静。林子里传来声音。旁人提到林走过这里。';
    final result = sanitizeDirectorBeat(chinese, '林');
    expect(result.text, chinese);
    expect(result.issues, isEmpty);
  });

  test('regex metacharacters and sentence punctuation in a persona name are literal', () {
    const name = 'A.[x]+?';
    const original = 'A.[x]+?决定向前。旁人提到 A.[x]+?。';
    final result = sanitizeDirectorBeat(original, name);
    expect(result.text, '旁人提到 A.[x]+?。');
    expect(result.issues.single['end'], 'A.[x]+?决定向前。'.length);
    expect(sanitizeDirectorBeat('AAAx 决定。', name).text, 'AAAx 决定。');
  });

  test('mixed sentence endings and line separators preserve all unrelated bytes', () {
    const original = 'A走。Keep!A说?Stay？\r\nA点头！\u2028A回答.\u2029Tail  ';
    final result = sanitizeDirectorBeat(original, 'A');
    expect(result.text, 'Keep!Stay？\r\n\u2028\u2029Tail  ');
    expect(result.issues, hasLength(4));
    expect(sanitizeDirectorBeat('A选择没有终止标点', 'A').text, '');
  });

  test('a bare name nonaction suffix or quoted opening is not treated as a user action', () {
    for (final original in ['Alice', 'Alice。', 'Alice的帽子。', 'Alice2 waits.', '“Alice走开。”', '林场。']) {
      final name = original.startsWith('林') ? '林' : 'Alice';
      final result = sanitizeDirectorBeat(original, name);
      expect(result.text, original);
      expect(result.issues, isEmpty);
    }
  });

  test('parse stores only sanitized beat while issues keep original UTF-16 positions outside wire', () {
    final raw = _valid()..['beat'] = '😀风声。 Alice走开。余下。';
    final result = DirectOutput.parse(raw, personaName: 'Alice');
    expect(result.beat, '😀风声。 余下。');
    expect(result.toJson()['beat'], result.beat);
    expect(result.toJson().keys.toSet(), {'notes', 'beat', 'prefetch', 'suggestions', 'events'});
    expect(result.issues.single, {
      'code': 'persona-action-filtered',
      'index': 1,
      'offset': '😀风声。 '.length,
      'end': '😀风声。 Alice走开。'.length,
    });
    expect(raw['beat'], '😀风声。 Alice走开。余下。');
  });

  test('empty name and empty beat are unchanged and sanitizer calls share no diagnostics', () {
    expect(sanitizeDirectorBeat('Alice走开。', '').text, 'Alice走开。');
    expect(sanitizeDirectorBeat('Alice走开。', ' \t').issues, isEmpty);
    expect(sanitizeDirectorBeat('', 'Alice').text, '');
    final first = sanitizeDirectorBeat('Alice走开。', 'Alice');
    first.issues.clear();
    expect(sanitizeDirectorBeat('Alice走开。', 'Alice').issues, hasLength(1));
  });
}

Json _valid() => <String, Object?>{
  'notes': 'private notes',
  'beat': '风声渐紧。',
  'prefetch': <Object?>[
    <String, Object?>{'kind': 'worldInfo', 'bookId': 'book', 'uid': '007'},
    <String, Object?>{'kind': 'memory', 'id': 'memory'},
  ],
  'suggestions': <Object?>[
    <String, Object?>{'text': '观察', 'risk': ''},
    <String, Object?>{'text': '询问', 'risk': '可能引人注意'},
    <String, Object?>{'text': '等待', 'risk': '时间会流逝'},
  ],
  'events': <Object?>[
    <String, Object?>{'name': 'proposal', 'data': '仅建议'},
  ],
};
Json _copy(Json raw) => jsonDecode(jsonEncode(raw)) as Json;
Json _suggestion(Json raw) => (raw['suggestions']! as List<Object?>).first! as Json;
Json _reference(Json raw) => (raw['prefetch']! as List<Object?>).first! as Json;
Json _event(Json raw) => (raw['events']! as List<Object?>).first! as Json;

void _reject(Json raw, {String personaName = ''}) {
  expect(
    () => DirectOutput.parse(raw, personaName: personaName),
    throwsA(
      isA<FormatException>()
          .having((error) => error.message, 'safe message', 'Invalid director output.')
          .having((error) => error.source, 'no raw source', isNull),
    ),
  );
}

class _SecretObject {
  _SecretObject(this.secret);
  final String secret;
  Object toJson() => throw StateError(secret);
}
