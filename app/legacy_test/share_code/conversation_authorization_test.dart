import 'dart:convert';

import 'package:dsh_app/share_code/conversation_export.dart';
import 'package:dsh_app/share_code/conversation_redact.dart';
import 'package:dsh_app/share_code/conversation_share.dart';
import 'package:dsh_app/share_code/share_codec.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../replay/support/conversation_fixture.dart';

void main() {
  test('Authorization credentials never reach exported tools or decoded share code', () {
    for (final scheme in ['Bearer', 'Basic']) {
      const secret = 'shareOnlyCredential1234567890';
      final command = 'curl -H "Authorization: $scheme $secret" https://example.invalid/api';
      final source = ConversationSource(
        title: 'API 调试求助',
        items: [
          UserChatItem(seq: 2, time: at(200), text: '检查请求为什么返回 401', images: const [], files: const []),
          ToolChatItem(
            callId: 'call-1',
            name: 'bash',
            arguments: jsonEncode({'command': command, 'timeout': 30}),
            status: ToolStatus.succeeded,
            seq: 4,
            resultParts: [TextPart('Request header: Authorization: $scheme $secret')],
          ),
        ],
        turns: fixtureTurns.take(1).toList(),
        events: fixtureEvents.take(3).toList(),
      );
      final exported = ConversationExport(source).build(now: at(40000));
      final tool = exported.entries.whereType<ToolEntry>().single;
      expect(tool.args['command'], contains('Authorization: $scheme ••••••'));
      expect(tool.args['timeout'], 30);
      expect(jsonEncode(exported.toJson()), isNot(contains(secret)));
      final decoded = decodeConversationCode(encodeShareJson(exported.toJson())).share;
      expect(jsonEncode(decoded.toJson()), isNot(contains(secret)));
      expect(decoded.entries.whereType<ToolEntry>().single.args, tool.args);
    }
  });

  test('header forms hide the whole credential and preserve surrounding text', () {
    final cases = {
      'Authorization: Bearer abc.DEF_123-~+/=': 'Authorization: Bearer ••••••',
      'proxy-authorization: bAsIc dXNlcjpwYXNz': 'proxy-authorization: bAsIc ••••••',
      '"Authorization": "Bearer abcdef123456"': '"Authorization": "Bearer ••••••"',
      "'Authorization' = 'Basic YTpiY2Q='": "'Authorization' = 'Basic ••••••'",
      'Authorization:\tBearer\topaque123\nX-Request-ID: 42': 'Authorization:\tBearer\t••••••\nX-Request-ID: 42',
      'Authorization: Bearer sk-${'0123456789abcdef' * 2}': 'Authorization: Bearer ••••••',
      'Authorization: Bearer xxx-real-opaque-token': 'Authorization: Bearer ••••••',
    };
    for (final entry in cases.entries) {
      final redacted = redactText(entry.key);
      expect(redacted, entry.value);
      expect(redactText(redacted), redacted);
    }
  });

  test('placeholders, already hidden values and ordinary prose stay unchanged', () {
    for (final text in [
      r'Authorization: Bearer $TOKEN',
      r'Authorization: Bearer $'
          '{API_KEY}',
      'Authorization: Basic <encoded-credentials>',
      'Authorization: Bearer ***',
      'Authorization: Bearer ••••••',
      'Learn basic usage and bearer token authentication.',
      'maxTokens: 4096',
    ]) {
      expect(redactText(text), text);
    }
  });
}
