// Parameter header v1 (docs/design/media-generation.md §4.6): the shared
// golden set, case by case, both ways — the dsh-media plugin runs the same
// file. Then what the app writes from its own values.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/ui/chat/media/generate_header.dart';
import 'package:flutter_test/flutter_test.dart';

final _golden =
    jsonDecode(File('test/media/fixtures/header_grammar_v1.json').readAsStringSync()) as Map<String, Object?>;

List<Map<String, Object?>> _group(String name) => [for (final c in _golden[name]! as List) c as Map<String, Object?>];

/// What [read] parsed, in the golden's (the plugin parser's) shape.
Map<String, Object?> _wire(GenerateRead read) => read.header!.wire(read.description!);

String? _formatCode(Map<String, Object?> value) {
  try {
    GenerateHeader.formatWire(value);
    return null;
  } on GenerateHeaderException catch (e) {
    return e.code;
  }
}

void main() {
  group('golden: valid', () {
    for (final c in _group('valid')) {
      test(c['id']! as String, () {
        final text = c['text']! as String;
        final read = GenerateHeader.read(text);
        expect(read, isNotNull, reason: 'a generation message');
        expect(read!.error, isNull);
        expect(_wire(read), c['expected']);
        // Back to text and parsed again: the same values.
        final again = GenerateHeader.formatWire(c['expected']! as Map<String, Object?>);
        if (c['canonical'] != false) expect(again, text);
        expect(_wire(GenerateHeader.read(again)!), c['expected']);
        // The convenience reader agrees.
        final parsed = GenerateHeader.parse(text)!;
        expect(parsed.header, read.header);
        expect(parsed.description, read.description);
      });
    }
  });

  group('golden: plain', () {
    for (final c in _group('plain')) {
      test(c['id']! as String, () {
        expect(GenerateHeader.read(c['text']! as String), isNull);
        expect(GenerateHeader.parse(c['text']! as String), isNull);
      });
    }
  });

  group('golden: invalid', () {
    for (final c in _group('invalid')) {
      test(c['id']! as String, () {
        final read = GenerateHeader.read(c['text']! as String);
        expect(read, isNotNull, reason: 'recognised as a generation message');
        expect(read!.error, c['code']);
        expect(read.header, isNull);
        // Never hidden.
        expect(GenerateHeader.parse(c['text']! as String), isNull);
      });
    }
  });

  group('golden: format', () {
    for (final c in _group('format')) {
      test(c['id']! as String, () {
        final value = c['value']! as Map<String, Object?>;
        expect(GenerateHeader.formatWire(value), c['text']);
        expect(_wire(GenerateHeader.read(c['text']! as String)!), value);
      });
    }
  });

  group('golden: format rejects', () {
    for (final c in _group('formatRejects')) {
      test(c['id']! as String, () => expect(_formatCode(c['value']! as Map<String, Object?>), c['code']));
    }
  });

  group('golden: titles', () {
    for (final c in _group('titles')) {
      test(c['id']! as String, () {
        final split = GenerateHeader.splitTitle(c['title']! as String);
        if (c['kind'] == null) {
          expect(split, isNull);
        } else {
          expect(split?.kind.name, c['kind']);
          expect(split?.rest, c['rest']);
        }
      });
    }
  });

  test('the golden set covers what the spec promises', () {
    expect(_group('valid').length, greaterThanOrEqualTo(10));
    expect(_group('invalid').length, greaterThanOrEqualTo(10));
    expect(_group('plain').length, greaterThanOrEqualTo(10));
  });

  group('what the app writes', () {
    test('image: the quality\'s own value after 质量=, the model with its marker', () {
      const header = GenerateHeader(
        kind: GenerateKind.image,
        aspect: '1:1',
        count: 1,
        quality: '2k',
        model: GenerateModelTag('Seedream 5.0', service: 'ark', id: 'doubao-seedream-5-0-pro'),
      );
      expect(header.message('画一只猫'), '〔生成图像 · 1:1 · 1 张 · 质量=2k · Seedream 5.0〈ark/doubao-seedream-5-0-pro〉〕\n画一只猫');
    });

    test('video: aspect, then length, then resolution, then the model; no sound', () {
      const header = GenerateHeader(
        kind: GenerateKind.video,
        aspect: '16:9',
        seconds: 5,
        resolution: '720p',
        model: GenerateModelTag('Seedance 2.0', service: 'ark', id: 'doubao-seedance-2-0'),
      );
      expect(header.message('镜头推近'), '〔生成视频 · 16:9 · 5 秒 · 720p · Seedance 2.0〈ark/doubao-seedance-2-0〉〕\n镜头推近');
    });

    test('empty option sets: those fields are left out, nothing made up', () {
      const header = GenerateHeader(
        kind: GenerateKind.image,
        count: 1,
        model: GenerateModelTag('Gemini 2.5 Flash Image', service: 'google', id: 'gemini-2.5-flash-image'),
      );
      expect(header.message('猫'), '〔生成图像 · 1 张 · Gemini 2.5 Flash Image〈google/gemini-2.5-flash-image〉〕\n猫');
    });

    test('the description goes as it is, and comes back as it is', () {
      const header = GenerateHeader(kind: GenerateKind.image, count: 2);
      const description = '  第一行\n\n  第三行  ';
      final parsed = GenerateHeader.parse(header.message(description))!;
      expect(parsed.description, description);
      expect(parsed.header, header);
    });

    test('a value the grammar can\'t carry is refused, never bent to fit', () {
      for (final header in const [
        GenerateHeader(kind: GenerateKind.image, quality: '高清'),
        GenerateHeader(kind: GenerateKind.image, aspect: '0:1'),
        GenerateHeader(kind: GenerateKind.image, count: 5),
        GenerateHeader(kind: GenerateKind.video, resolution: '4k'),
        GenerateHeader(kind: GenerateKind.image, model: GenerateModelTag('〔怪〕 · 名')),
        GenerateHeader(
          kind: GenerateKind.image,
          model: GenerateModelTag('Demo', service: 'Office', id: 'x'),
        ),
      ]) {
        expect(() => header.message('猫'), throwsA(isA<GenerateHeaderException>()), reason: '$header');
        expect(header.tryMessage('猫').text, isNull);
      }
      expect(const GenerateHeader(kind: GenerateKind.image).tryMessage('   ').code, 'missing_prompt');
      expect(const GenerateHeader(kind: GenerateKind.image).tryMessage('猫' * 1366).code, 'too_long');
    });

    test('a label the header can carry, and one it can\'t', () {
      expect(GenerateModelTag.expressible('GPT Image 2'), isTrue);
      expect(GenerateModelTag.expressible('通义千问图像 3.0'), isTrue);
      expect(GenerateModelTag.expressible('1.5p'), isFalse);
      expect(GenerateModelTag.expressible('3:4'), isFalse);
      expect(GenerateModelTag.expressible('质量=high'), isFalse);
      expect(GenerateModelTag.expressible(' padded'), isFalse);
      expect(GenerateModelTag.expressible('a · b'), isFalse);
    });
  });
}
