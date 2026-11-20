// Conversation files: the schema round trip,
// what old and new readers do with it, the envelope and its pictures, the
// export (range, options, redaction, times) and the JPEG encoder.
//
//   flutter test test/share_code/conversation_share_test.dart

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_app/share_code/conversation_export.dart';
import 'package:dsh_app/share_code/conversation_redact.dart';
import 'package:dsh_app/share_code/conversation_share.dart';
import 'package:dsh_app/share_code/image_shrink.dart';
import 'package:dsh_app/share_code/jpeg_encoder.dart';
import 'package:dsh_app/share_code/share_codec.dart';
import 'package:dsh_app/share_code/share_models.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../replay/support/conversation_fixture.dart';

final _now = DateTime.utc(2026, 10, 25, 3);

ConversationShare _build({int? from, int? to, bool thinking = true, bool tools = true}) =>
    ConversationExport(fixtureSource())
        .build(from: from, to: to, thinking: thinking, toolOutput: tools, now: _now, app: 'dsh-go 1.0.0');

String _code(Map<String, Object?> json) {
  final body = utf8.encode(jsonEncode(json));
  return '${base64Url.encode(ZLibEncoder(raw: true).convert(body)).replaceAll('=', '')}.${shareChecksum(body)}';
}

void main() {
  group('schema', () {
    test('round trip through a share code keeps every entry', () {
      final share = _build();
      final back = decodeConversationCode(encodeShareJson(share.toJson())).share;
      expect(jsonEncode(back.toJson()), jsonEncode(share.toJson()));
      expect(back.entries.map((e) => e.type), [
        'turn', 'user', 'reply', 'tool', 'todos', 'reply', 'command', //
        'turn', 'user', 'tool', 'tool', 'goal', 'reply', 'notice',
      ]);
      expect(back.title, '修复登录重复提交');
      expect(back.model, 'deepseek-v4-pro');
      expect(back.app, 'dsh-go 1.0.0');
    });

    test('written as v2 with schema 1; older readers ask for an update', () {
      final json = _build().toJson();
      expect(json['v'], conversationBodyVersion);
      expect(json['schema'], conversationSchema);
      // A plugin / profile reader (what older apps run) refuses v2 as newer.
      expect(
        () => decodeShareCode(encodeShareJson(json)),
        throwsA(isA<ShareFormatException>().having((e) => e.reason, 'reason', 'newer format')),
      );
      expect(
        () => decodeConversationCode(_code({...json, 'schema': 2})),
        throwsA(isA<ShareFormatException>().having((e) => e.reason, 'reason', 'newer format')),
      );
      expect(
        () => decodeConversationCode(_code({...json, 'v': 3})),
        throwsA(isA<ShareFormatException>().having((e) => e.reason, 'reason', 'newer format')),
      );
    });

    test('unknown entry types are skipped; texts are cut, not refused', () {
      final json = _build().toJson();
      final entries = [
        ...(json['entries']! as List),
        {'type': 'sparkle', 't': 1},
        {'type': 'user', 't': 2, 'text': 'x' * 500000},
      ];
      final back = decodeConversationCode(_code({...json, 'entries': entries})).share;
      expect(back.entries.whereType<UserEntry>().last.text.length, lessThan(400002));
      expect(back.entries.length, 15);
    });

    test('a broken body is refused', () {
      final json = _build().toJson();
      expect(
        () => decodeConversationCode(_code({...json, 'start': 'yesterday'})),
        throwsA(isA<ShareFormatException>()),
      );
      expect(() => decodeConversationCode(_code({...json, 'entries': 'none'})), throwsA(isA<ShareFormatException>()));
      expect(() => decodeConversationCode(_code({...json, 'kind': 'profile'})), throwsA(isA<ShareFormatException>()));
    });

    test('large conversations decode; large plugins and profiles still do not', () {
      final big = 'y' * (maxShareBodyBytes + 100);
      final share = ConversationShare(
        title: '长对话',
        start: t0,
        entries: [UserEntry(t: 0, text: big)],
      );
      expect(decodeConversationCode(encodeShareJson(share.toJson())).share.entries, hasLength(1));
      final profile = _code({'v': 1, 'kind': 'profile', 'name': big});
      expect(() => decodeShareJson(profile, large: true), throwsA(isA<ShareDecodeException>()));
      expect(() => decodeShareCode(profile), throwsA(isA<ShareDecodeException>()));
    });
  });

  group('file envelope', () {
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGPwTt/yHxkzkC4AAAPnJlH/osXzAAAAAElFTkSuQmCC',
    );

    test('pictures ride next to the code, checked by their names', () {
      final asset = ConversationAsset.of(png, mediaType: 'image/png', width: 4, height: 4);
      final share = ConversationShare(
        title: '带图',
        start: t0,
        entries: [
          UserEntry(
            t: 0,
            text: '看图',
            images: [ImageRef(id: asset.id, width: 4, height: 4)],
          ),
        ],
      );
      final other = ConversationAsset.of(Uint8List.fromList([1, 2, 3]), mediaType: 'image/png');
      final text = encodeConversationFile(share, [asset, other]);
      final envelope = jsonDecode(text) as Map<String, Object?>;
      expect(envelope['dshgo'], 2);
      expect(envelope['kind'], 'conversation');
      expect(envelope['name'], '带图');
      // Only pictures the conversation uses.
      expect((envelope['assets']! as Map).keys, [asset.id]);

      final read = decodeConversationFile(text);
      expect(read.assets[asset.id]!.bytes, png);
      expect(read.share.images.single.id, asset.id);

      // A picture swapped for another is dropped, the rest still opens.
      (envelope['assets']! as Map)[asset.id] = {
        'type': 'image/png',
        'data': base64.encode([9, 9, 9]),
      };
      expect(decodeConversationFile(jsonEncode(envelope)).assets, isEmpty);
      // Old readers see the header and a v2 code.
      expect(readShareEnvelope(text).kind, ShareKind.conversation);
      expect(() => decodeShareFile(text), throwsA(isA<ShareFormatException>()));
    });
  });

  group('export', () {
    test('times: replies from their first token, tools from dispatch, origin at the first thing', () {
      final share = _build();
      expect(share.start, at(100));
      final entries = share.entries;
      final turn = entries[0] as TurnEntry;
      expect(turn.t, 0);
      expect(turn.d, 30900);
      expect(turn.end, 'completed');
      expect(turn.steps, 2);
      expect(turn.tokens, 2400);
      final reply = entries[2] as ReplyEntry;
      expect(reply.t, 2100);
      expect(reply.d, 3000);
      final tool = entries[3] as ToolEntry;
      expect(tool.t, 5200);
      expect(tool.d, 20000);
      expect(tool.status, ToolOutcome.failed);
      expect(tool.verb, '运行');
    });

    test('texts are redacted everywhere', () {
      final text = jsonEncode(_build().toJson());
      expect(text, isNot(contains('/home/user')));
      expect(text, isNot(contains('abcdefghij0123456789')));
      expect(text, isNot(contains('hunter2hunter2')));
      expect(text, contains('~/code/app'));
      // The on-device home says nothing about anyone: kept.
      expect(text, contains('/root/workspace/src/login.ts'));
      // Pictures in replies become their alt text; dsh-ui gets a plain twin.
      final reply = _build().entries.whereType<ReplyEntry>().elementAt(1);
      expect(reply.text, contains('〔截图〕'));
      expect(reply.text, isNot(contains('shot.png')));
      expect(reply.plain, isNotNull);
      expect(reply.plain, isNot(contains('```dsh-ui')));
    });

    test('long tool output keeps its start and end', () {
      final tool = _build().entries.whereType<ToolEntry>().first;
      expect(tool.result!.length, lessThanOrEqualTo(exportToolOutputChars + 3));
      expect(tool.result, startsWith('FAIL test/login.test.ts'));
      expect(tool.result, endsWith('Tests: 1 failed, 41 passed'));
      expect(tool.omitted, greaterThan(3000));
      expect(tool.summary, 'cd ~/code/app && npm test');
    });

    test('options: no thinking, no tool output', () {
      final share = _build(thinking: false, tools: false);
      expect(share.entries.whereType<ReplyEntry>().every((r) => r.thinking == null), isTrue);
      expect(share.entries.whereType<ToolEntry>().every((t) => t.result == null), isTrue);
      expect(share.toJson()['include'], {'thinking': false, 'tools': false});
      // Arguments stay: they are the calls themselves.
      expect(share.entries.whereType<ToolEntry>().first.args['command'], isNotNull);
    });

    test('rounds: a prompt and what followed, its turn start first', () {
      final export = ConversationExport(fixtureSource());
      expect(export.rounds.map((r) => (r.index, r.startSeq)), [(1, 1), (2, 10)]);
      expect(export.rounds.first.prompt, startsWith('帮我看看 ~/code/app'));
      final second = export.build(from: 2, to: 2, now: _now);
      expect(second.range, (from: 2, to: 2, of: 2));
      expect(second.entries.first, isA<TurnEntry>());
      expect(second.entries.whereType<UserEntry>().single.text, '好的，修一下');
      expect(second.entries.first.t, 0);
      final first = export.build(from: 1, to: 1, now: _now);
      expect(first.entries.map((e) => e.type), ['turn', 'user', 'reply', 'tool', 'todos', 'reply', 'command']);
      expect(export.build(now: _now).range, isNull);
    });

    test('picked messages: only them, with the work of the picked replies\' turns', () {
      final export = ConversationExport(fixtureSource());
      String key(int seq) => fixtureItems
          .firstWhere(
            (i) => switch (i) {
              UserChatItem(seq: final s) || AssistantChatItem(seq: final s?) => s == seq,
              _ => false,
            },
          )
          .key;
      // The first prompt and the turn's second reply (not the first one).
      final first = export.build(only: {key(2), key(6)}, now: _now);
      expect(first.entries.map((e) => e.type), ['turn', 'user', 'tool', 'todos', 'reply']);
      expect(first.entries.whereType<ReplyEntry>().single.text, startsWith('登录测试挂在重复提交上'));
      expect(first.range, (from: 1, to: 1, of: 2));
      // A prompt alone brings no tool calls: they belong to the replies.
      final prompt = export.build(only: {key(11)}, now: _now);
      expect(prompt.entries.map((e) => e.type), ['turn', 'user', 'notice']);
      expect(prompt.range, (from: 2, to: 2, of: 2));
      final reply = export.build(only: {key(15)}, now: _now);
      expect(reply.entries.map((e) => e.type), ['turn', 'tool', 'tool', 'goal', 'reply', 'notice']);
      // Across rounds: the range spans them; commands stay out.
      final both = export.build(only: {key(3), key(15)}, now: _now);
      expect(both.range, (from: 1, to: 2, of: 2));
      expect(both.entries.whereType<CommandEntry>(), isEmpty);
    });

    test('tools off: no calls, todos or goals; images off: no pictures', () {
      final export = ConversationExport(fixtureSource());
      final quiet = export.build(tools: false, now: _now);
      expect(quiet.entries.map((e) => e.type), [
        'turn', 'user', 'reply', 'reply', 'command', //
        'turn', 'user', 'reply', 'notice',
      ]);
      expect(quiet.toJson()['include'], {'thinking': true, 'tools': false});
      expect(quiet.toolCount, 0);
    });

    testWidgets('images off leaves the pictures out of the file', (tester) async {
      final export = ConversationExport(fixtureSource());
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGPwTt/yHxkzkC4AAAPnJlH/osXzAAAAAElFTkSuQmCC',
      );
      await tester.runAsync(() => export.loadImages((_) async => png));
      expect(export.build(now: _now).images, hasLength(1));
      final share = export.build(images: false, now: _now);
      expect(share.images, isEmpty);
      final user = share.entries.whereType<UserEntry>().first;
      expect(user.images, isEmpty);
      expect(user.files.single.name, 'log.txt', reason: 'files are not pictures');
      expect(decodeConversationFile(export.file(share).text).assets, isEmpty);
    });

    testWidgets('pictures are read once, shrunk and named by their hash', (tester) async {
      final export = ConversationExport(fixtureSource());
      var reads = 0;
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGPwTt/yHxkzkC4AAAPnJlH/osXzAAAAAElFTkSuQmCC',
      );
      await tester.runAsync(
        () => export.loadImages((_) async {
          reads++;
          return png;
        }),
      );
      await tester.runAsync(() => export.loadImages((_) async => png));
      expect(reads, 1);
      final share = export.build(now: _now);
      final image = share.images.single;
      expect(image.id, assetIdOf(png));
      expect(image.name, '截图.png');
      final file = export.file(share);
      expect(decodeConversationFile(file.text).assets.keys, [image.id]);
      expect(file.bytes, lessThan(maxConversationFileBytes));
    });
  });

  group('redaction', () {
    test('homes, app storage, assigned secrets; placeholders stay', () {
      expect(redactText('ls /home/alice/src /Users/bob C:\\Users\\Carol\\x'), 'ls ~/src ~ ~\\x');
      expect(redactText('/data/user/0/io.github.app/files/a'), '…/files/a');
      expect(redactText('export OPENAI_API_KEY=abcdef123456789'), 'export OPENAI_API_KEY=abcd••••••');
      expect(redactText('"password": "hunter22"'), '"password": "••••••"');
      expect(redactText(r'TOKEN=$GITHUB_TOKEN'), r'TOKEN=$GITHUB_TOKEN');
      expect(redactText('maxTokens: 4096'), 'maxTokens: 4096');
      expect(redactText('/root/workspace/a'), '/root/workspace/a');
    });

    test('pictures outside code blocks only', () {
      const md = '![a](x.png) and ![](y.png)\n```\n![keep](z.png)\n```';
      expect(markdownWithoutImages(md), '〔a〕 and \n```\n![keep](z.png)\n```');
    });
  });

  group('jpeg', () {
    testWidgets('decodes back to the same size and colours', (tester) async {
      const w = 37, h = 21;
      final rgba = Uint8List(w * h * 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          final left = x < w ~/ 2;
          rgba[i] = left ? 220 : 30;
          rgba[i + 1] = left ? 40 : 120;
          rgba[i + 2] = left ? 40 : 230;
          rgba[i + 3] = 255;
        }
      }
      final jpeg = encodeJpeg(rgba, w, h, quality: 90);
      expect(jpeg.sublist(0, 2), [0xFF, 0xD8]);
      expect(jpeg.sublist(jpeg.length - 2), [0xFF, 0xD9]);
      final decoded = await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(jpeg);
        final frame = await codec.getNextFrame();
        final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
        return (frame.image.width, frame.image.height, data!.buffer.asUint8List());
      });
      final (dw, dh, pixels) = decoded!;
      expect((dw, dh), (w, h));
      int at(int x, int y, int c) => pixels[(y * w + x) * 4 + c];
      expect(at(4, 10, 0), closeTo(220, 18));
      expect(at(4, 10, 2), closeTo(40, 18));
      expect(at(32, 10, 2), closeTo(230, 18));
      expect(at(32, 10, 0), closeTo(30, 18));
    });

    testWidgets('large pictures shrink to 1600 on the long side', (tester) async {
      final png = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 3200, 1800), ui.Paint()..color = const ui.Color(0xFF4D6BFE));
        canvas.drawCircle(const ui.Offset(1600, 900), 500, ui.Paint()..color = const ui.Color(0xFFFFFFFF));
        final image = await recorder.endRecording().toImage(3200, 1800);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data!.buffer.asUint8List();
      });
      final shrunk = (await tester.runAsync(() => shrinkImage(png!)))!;
      expect(shrunk.mediaType, 'image/jpeg');
      expect((shrunk.width, shrunk.height), (1600, 900));
      expect(shrunk.bytes.length, lessThan(png!.length));
      final small = (await tester.runAsync(
        () => shrinkImage(
          File('assets/brand/glyph-light.png').existsSync()
              ? File('assets/brand/glyph-light.png').readAsBytesSync()
              : png,
        ),
      ))!;
      expect(small.width, lessThanOrEqualTo(1600));
    });
  });
}
