import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_tavern/src/io/st_chat_document.dart';
import 'package:test/test.dart';

void main() {
  test('ST-style JSONL preserves unknown header, metadata, swipe and message values', () {
    // Self-authored data; framing is checked by the fixed ST trySaveChat probe.
    final header = <String, Object?>{
      'chat_metadata': {
        'integrity': 'fixture-integrity',
        'main_chat': '母对话',
        'chat_id_hash': 12345,
        'variables': {'visits': 2},
        'future': {
          'keep': [null, false, '🐋'],
        },
      },
      'user_name': 'unused',
      'character_name': 'unused',
      'future_header': '保留',
    };
    final message = <String, Object?>{
      'name': '鲸',
      'is_user': false,
      'is_system': true,
      'mes': '第一行\r\n第二行🐋',
      'send_date': '2026-11-10 @04h 05m 06s 007ms',
      'swipes': ['相同回复', '相同回复'],
      'swipe_id': 1,
      'swipe_info': [
        {
          'send_date': 123,
          'extra': {'reasoning': '原思考', 'unknown': 1},
        },
        {
          'send_date': '另一日期',
          'gen_started': 'S',
          'gen_finished': 'F',
          'extra': {
            'reasoning': '另一思考',
            'unknown': [1, null],
          },
        },
      ],
      'force_avatar': 'https://example.invalid/avatar.png',
      'extra': {
        'display_text': '显示',
        'branches': ['分支'],
        'bookmark_link': '存档',
        'dshgo': {'future': true},
        'unknown': {'preserve': true},
      },
      'variables': [
        {
          'stat_data': {'value': 1},
        },
        {
          'stat_data': {'value': 2},
        },
      ],
      'unknown_message': '未识别消息字段',
    };
    final bytes = _bytes('${jsonEncode(header)}\n${jsonEncode(message)}');
    final doc = StChatDocument.decode('母对话.jsonl', bytes);
    expect(doc.fileName, '母对话.jsonl');
    expect(doc.header, header);
    expect(doc.messages, [message]);
    expect(doc.messageLines, [2]);
    final roundTrip = StChatDocument.decode(doc.fileName, doc.encode());
    expect(roundTrip.header, header);
    expect(roundTrip.messages, [message]);
  });

  test('BOM, CRLF and skipped blank lines retain physical message line numbers', () {
    final doc = StChatDocument.decode(
      '空白.jsonl',
      Uint8List.fromList([
        0xef,
        0xbb,
        0xbf,
        ...utf8.encode('\r\n \t\r\n{"head":true}\r\n\r\n{"mes":"一"}\r\n \t\r\n{"mes":"二"}\r\n'),
      ]),
    );
    expect(doc.header, {'head': true});
    expect(doc.headerLineNumber, 3);
    expect(doc.messages.map((message) => message['mes']), ['一', '二']);
    expect(doc.messageLines, [5, 7]);
  });

  test('header location is original physical input while object construction and encoding start at one', () {
    for (final prefix in ['\n\n', '\r\r', '\r\n\r\n', '\n \t\r\n']) {
      final decoded = StChatDocument.decode('header-position.jsonl', _bytes('$prefix{"head":true}\n{"mes":"A"}'));
      expect(decoded.headerLineNumber, 3);
      expect(decoded.messageLines, [4]);
      final encoded = StChatDocument.decode(decoded.fileName, decoded.encode());
      expect(encoded.headerLineNumber, 1);
      expect(encoded.messageLines, [2]);
    }
    final constructed = StChatDocument(
      fileName: 'constructed.jsonl',
      header: {},
      messages: [
        {'mes': 'A'},
      ],
    );
    expect(constructed.headerLineNumber, 1);
    expect(constructed.messageLines, [2]);
  });

  test('LF, CRLF and standalone CR each delimit one physical line', () {
    final doc = StChatDocument.decode('mixed.jsonl', _bytes('{}\r{"mes":"A"}\r\n{"mes":"B"}\n{"mes":"C"}'));
    expect(doc.messageLines, [2, 3, 4]);
    expect(doc.messages.map((message) => message['mes']), ['A', 'B', 'C']);
  });

  test('JSON whitespace is ignored outside objects without trimming field text', () {
    final doc = StChatDocument.decode(
      'spaces.jsonl',
      _bytes(' \t{ "future key": " 头 " } \t\n\t{"mes":"  文本\\r\\n\\t  "}  '),
    );
    expect(doc.header, {'future key': ' 头 '});
    expect(doc.messages.single['mes'], '  文本\r\n\t  ');
  });

  test('empty, BOM-only and whitespace-only documents fail at the absent header', () {
    for (final bytes in <Uint8List>[
      Uint8List(0),
      Uint8List.fromList([0xef, 0xbb, 0xbf]),
      _bytes(' \t\r\n\n\t'),
    ]) {
      expect(() => StChatDocument.decode('empty.jsonl', bytes), _errorAt('empty.jsonl', 1));
    }
  });

  test('a header-only document is valid and unfamiliar header fields are not replaced', () {
    final doc = StChatDocument.decode('header.jsonl', _bytes('\n{"future":null}\n'));
    expect(doc.header, {'future': null});
    expect(doc.header.containsKey('chat_metadata'), isFalse);
    expect(doc.messages, isEmpty);
    expect(doc.messageLines, isEmpty);
    expect(utf8.decode(doc.encode()), '{"future":null}');
  });

  test('malformed nonblank JSON reports its original line and does not skip forward', () {
    expect(
      () => StChatDocument.decode(
        'broken.jsonl',
        _bytes('{}\r\n\r\n{"mes":"good"}\r\n \t\r\n{broken}\r\n{"mes":"later"}'),
      ),
      _errorAt('broken.jsonl', 5),
    );
    expect(
      () => StChatDocument.decode('truncated.jsonl', _bytes('{}\n{"mes":"good"}\n{"mes":"unfinished')),
      _errorAt('truncated.jsonl', 3),
    );
  });

  test('multiple JSON values and trailing junk on one line are rejected', () {
    for (final line in ['{} {}', '{}junk', '{"a":1,}']) {
      expect(() => StChatDocument.decode('junk.jsonl', _bytes('{}\n$line')), _errorAt('junk.jsonl', 2));
    }
  });

  test('the header must be a JSON object', () {
    for (final line in ['[]', 'null', '42', 'true', '"text"']) {
      expect(() => StChatDocument.decode('header-type.jsonl', _bytes(line)), _errorAt('header-type.jsonl', 1));
    }
  });

  test('each message must be an object while nested primitive JSON remains valid', () {
    for (final line in ['[]', 'null', '42', 'true', '"text"']) {
      expect(
        () => StChatDocument.decode('message-type.jsonl', _bytes('{}\n\n$line')),
        _errorAt('message-type.jsonl', 3),
      );
    }
    final doc = StChatDocument.decode('nested.jsonl', _bytes('{}\n{"future":[null,true,42,"text",[]]}'));
    expect(doc.messages.single['future'], [null, true, 42, 'text', <Object?>[]]);
  });

  test('invalid and truncated UTF-8 fail on the physical source line', () {
    for (final bad in <List<int>>[
      [0xff],
      [0xe4, 0xbd],
      [0xc0, 0xaf],
      [0xed, 0xa0, 0x80],
    ]) {
      final bytes = Uint8List.fromList([...utf8.encode('{}\r\n\r\n'), ...bad, ...utf8.encode('\n{"mes":"later"}')]);
      expect(() => StChatDocument.decode('utf8.jsonl', bytes), _errorAt('utf8.jsonl', 3));
    }
  });

  test('a second or non-file-leading BOM is not silently discarded', () {
    final bom = <int>[0xef, 0xbb, 0xbf];
    expect(
      () => StChatDocument.decode('twice.jsonl', Uint8List.fromList([...bom, ...bom, ...utf8.encode('{}')])),
      _errorAt('twice.jsonl', 1),
    );
    expect(
      () => StChatDocument.decode(
        'later.jsonl',
        Uint8List.fromList([...utf8.encode('{}\n'), ...bom, ...utf8.encode('{"mes":"x"}')]),
      ),
      _errorAt('later.jsonl', 2),
    );
    expect(
      () => StChatDocument.decode('blank-first.jsonl', Uint8List.fromList([10, ...bom, ...utf8.encode('{}')])),
      _errorAt('blank-first.jsonl', 2),
    );
  });

  test('Unicode whitespace outside JSON is not treated as an empty line', () {
    expect(() => StChatDocument.decode('nbsp.jsonl', _bytes('{}\n\u00a0\n{}')), _errorAt('nbsp.jsonl', 2));
    expect(() => StChatDocument.decode('inner-bom.jsonl', _bytes('{}\n \ufeff{}')), _errorAt('inner-bom.jsonl', 2));
  });

  test('text preserves BOM characters, emoji, quotes, backslashes and escaped surrogates', () {
    final text = '\ufeff鲸🐋 "quote" \\ path\r\nnext';
    final doc = StChatDocument(
      fileName: 'text.jsonl',
      header: {},
      messages: [
        {'mes': text},
      ],
    );
    expect(StChatDocument.decode(doc.fileName, doc.encode()).messages.single['mes'], text);
    final surrogate = StChatDocument.decode('surrogate.jsonl', _bytes('{}\n${r'{"mes":"\ud800"}'}'));
    expect((surrogate.messages.single['mes']! as String).codeUnits, [0xd800]);
    final encoded = surrogate.encode();
    expect(utf8.decode(encoded), contains(r'\ud800'));
    expect((StChatDocument.decode('surrogate.jsonl', encoded).messages.single['mes']! as String).codeUnits, [0xd800]);
  });

  test('constructor snapshots and every returned container are detached and immutable', () {
    final nested = <String, Object?>{
      'values': <Object?>[1],
    };
    final header = <String, Object?>{'nested': nested};
    final message = <String, Object?>{
      'mes': 'before',
      'extra': <String, Object?>{'keep': true},
    };
    final messages = <Map<String, Object?>>[message];
    final doc = StChatDocument(fileName: 'immutable.jsonl', header: header, messages: messages);
    header.clear();
    (nested['values']! as List<Object?>).add(2);
    message['mes'] = 'after';
    messages.clear();
    expect(doc.header, {
      'nested': {
        'values': [1],
      },
    });
    expect(doc.messages.single['mes'], 'before');
    expect(doc.messageLines, [2]);
    expect(() => doc.header['x'] = 1, throwsUnsupportedError);
    expect(() => (doc.header['nested']! as Map<String, Object?>)['x'] = 1, throwsUnsupportedError);
    expect(
      () => ((doc.header['nested']! as Map<String, Object?>)['values']! as List<Object?>).add(2),
      throwsUnsupportedError,
    );
    expect(() => doc.messages.add({}), throwsUnsupportedError);
    expect(() => doc.messages.single['mes'] = 'changed', throwsUnsupportedError);
    expect(() => doc.messageLines.add(99), throwsUnsupportedError);
  });

  test('decoded documents detach from the input bytes and encode returns a fresh buffer', () {
    final input = _bytes('{}\n{"mes":"original"}');
    final doc = StChatDocument.decode('bytes.jsonl', input);
    input.fillRange(0, input.length, 0);
    final encoded = doc.encode();
    encoded.fillRange(0, encoded.length, 0);
    expect(StChatDocument.decode('again.jsonl', doc.encode()).messages.single['mes'], 'original');
  });

  test('non-JSON constructor values and non-string nested keys are rejected', () {
    for (final value in <Object?>[
      Object(),
      DateTime.utc(2026),
      <int>{1},
      <Object?, Object?>{1: 'value'},
    ]) {
      expect(() => StChatDocument(fileName: 'bad.jsonl', header: {'future': value}, messages: []), throwsArgumentError);
    }
  });

  test('non-finite numbers cannot become successfully decoded or constructed documents', () {
    for (final value in [double.nan, double.infinity, double.negativeInfinity]) {
      expect(
        () => StChatDocument(
          fileName: 'number.jsonl',
          header: {},
          messages: [
            {'future': value},
          ],
        ),
        throwsArgumentError,
      );
    }
    for (final literal in ['1e309', '-1e309']) {
      expect(
        () => StChatDocument.decode('overflow.jsonl', _bytes('{}\n\n{"future":$literal}')),
        _errorAt('overflow.jsonl', 3),
      );
    }
    final doc = StChatDocument(
      fileName: 'finite.jsonl',
      header: {'n': 9007199254740993},
      messages: [
        {'n': 1e200},
      ],
    );
    final restored = StChatDocument.decode('finite.jsonl', doc.encode());
    expect(restored.header['n'], 9007199254740993);
    expect(restored.messages.single['n'], 1e200);
  });

  test('cyclic containers fail but repeated non-cyclic references remain valid', () {
    final list = <Object?>[];
    list.add(list);
    final map = <String, Object?>{};
    map['self'] = map;
    for (final value in <Object?>[list, map]) {
      expect(
        () => StChatDocument(fileName: 'cycle.jsonl', header: {'value': value}, messages: []),
        throwsArgumentError,
      );
    }
    final shared = <String, Object?>{'value': 1};
    final doc = StChatDocument(fileName: 'shared.jsonl', header: {'a': shared, 'b': shared}, messages: []);
    expect(doc.header, {
      'a': {'value': 1},
      'b': {'value': 1},
    });
  });

  test('canonical encoding adds no BOM, trailing newline, integrity or filename rewrite', () {
    final doc = StChatDocument(
      fileName: '../原名.JSONL',
      header: {
        'chat_metadata': {'integrity': 'original'},
      },
      messages: [
        {'mes': 'A'},
        {'mes': 'B'},
      ],
    );
    expect(doc.fileName, '../原名.JSONL');
    final output = utf8.decode(doc.encode());
    expect(output.startsWith('\ufeff'), isFalse);
    expect(output.endsWith('\n'), isFalse);
    expect(output.contains('\r'), isFalse);
    expect(output.split('\n'), hasLength(3));
    expect(StChatDocument.decode('other-name.jsonl', doc.encode()).header, doc.header);
    expect(doc.messageLines, [2, 3]);
  });

  test('many messages keep ordering and a malformed final line reports its actual position', () {
    final source = StringBuffer('{}');
    for (var i = 0; i < 5000; i++) {
      source.write('\n${jsonEncode({'mes': '第$i条🐋', 'i': i})}');
    }
    final doc = StChatDocument.decode('long.jsonl', _bytes(source.toString()));
    expect(doc.messages, hasLength(5000));
    expect(doc.messages.first['i'], 0);
    expect(doc.messages.last['i'], 4999);
    expect(doc.messageLines.first, 2);
    expect(doc.messageLines.last, 5001);
    expect(StChatDocument.decode('long.jsonl', doc.encode()).messages, doc.messages);
    expect(
      () => StChatDocument.decode('long-broken.jsonl', _bytes('$source\n{"unfinished":')),
      _errorAt('long-broken.jsonl', 5002),
    );
  });
}

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

Matcher _errorAt(String fileName, int lineNumber) => throwsA(
  isA<StChatFormatException>()
      .having((error) => error.fileName, 'fileName', fileName)
      .having((error) => error.lineNumber, 'lineNumber', lineNumber)
      .having((error) => error.toString(), 'diagnostic', contains('$fileName:$lineNumber:')),
);
