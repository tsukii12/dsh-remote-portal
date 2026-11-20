import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/share_code/conversation_export.dart';
import 'package:dsh_app/share_code/conversation_share.dart';
import 'package:dsh_app/share_code/share_codec.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 11, 3);
  final cases = [
    (
      label: 'title pair crosses the cut',
      title: '${'a' * 118}😀b',
      text: 'hello',
      wantTitle: '${'a' * 118}…',
      wantText: 'hello',
    ),
    (
      label: 'title pair ends at the cut',
      title: '${'a' * 117}😀bc',
      text: 'hello',
      wantTitle: '${'a' * 117}😀…',
      wantText: 'hello',
    ),
    (
      label: 'title pair starts after the cut',
      title: '${'a' * 119}😀',
      text: 'hello',
      wantTitle: '${'a' * 119}…',
      wantText: 'hello',
    ),
    (
      label: 'BMP title budget is unchanged',
      title: '字' * 121,
      text: 'hello',
      wantTitle: '${'字' * 119}…',
      wantText: 'hello',
    ),
    (
      label: 'body pair crosses the cut',
      title: 'chat',
      text: '${'a' * 399999}😀',
      wantTitle: 'chat',
      wantText: '${'a' * 399999}…',
    ),
    (
      label: 'body pair ends at the cut',
      title: 'chat',
      text: '${'a' * 399998}😀b',
      wantTitle: 'chat',
      wantText: '${'a' * 399998}😀…',
    ),
    (
      label: 'body pair starts after the cut',
      title: 'chat',
      text: '${'a' * 400000}😀',
      wantTitle: 'chat',
      wantText: '${'a' * 400000}…',
    ),
  ];
  for (final sample in cases) {
    test('conversation file Unicode: ${sample.label}', () async {
      expect(utf8.decode(utf8.encode(sample.title)), sample.title);
      expect(utf8.decode(utf8.encode(sample.text)), sample.text);
      final export = ConversationExport(
        ConversationSource(
          title: sample.title,
          items: [UserChatItem(seq: 1, time: now, text: sample.text, images: const [], files: const [])],
        ),
      );
      final share = export.build(now: now);
      // The actual exporter preserves these legal strings before read-side limits.
      expect(share.title, sample.title);
      expect(share.entries.whereType<UserEntry>().single.text, sample.text);
      final dir = await Directory.systemTemp.createTemp('conversation-unicode-');
      try {
        final file = File('${dir.path}/conversation.dshgo');
        await file.writeAsString(export.file(share).text, flush: true);
        final text = await file.readAsString();
        final envelope = jsonDecode(text) as Map<String, Object?>;
        final body = decodeShareJson(envelope['code']! as String, large: true);
        expect(body['title'], sample.title);
        expect(((body['entries']! as List).single as Map)['text'], sample.text);
        final back = decodeConversationFile(text).share;
        final backText = back.entries.whereType<UserEntry>().single.text;
        expect(
          utf8.decode(utf8.encode(back.title)),
          back.title,
          reason: 'read-side title limit must preserve valid Unicode',
        );
        expect(
          utf8.decode(utf8.encode(backText)),
          backText,
          reason: 'read-side text limit must preserve valid Unicode',
        );
        expect(back.title, sample.wantTitle);
        expect(backText, sample.wantText);
        expect(back.title.length, lessThanOrEqualTo(120));
        expect(backText.length, lessThanOrEqualTo(400001));
        final jsonRoundTrip = jsonDecode(jsonEncode(back.toJson())) as Map<String, Object?>;
        expect(jsonRoundTrip['title'], sample.wantTitle);
        expect(((jsonRoundTrip['entries']! as List).single as Map)['text'], sample.wantText);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  }
}
