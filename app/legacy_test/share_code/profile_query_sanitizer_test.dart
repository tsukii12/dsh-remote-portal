import 'package:dsh_app/share_code/profile_export.dart';
import 'package:dsh_app/ui/engine_settings/schema_fields.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine.dart';

void main() {
  for (final query in ['%FF=value', 'label=%FF']) {
    test('profile export omits an undecodable query ($query) without losing other settings', () async {
      final unsafe = 'https://example.com/search?$query';
      final uri = Uri.tryParse(unsafe);
      expect(uri, isNotNull);
      expect(uri!.host, 'example.com');
      expect(validateText(unsafe, const SchemaMeta()), isNull, reason: 'an ordinary string field accepts this text');
      final engine = FakeEngine()
        ..addSettings('web-search-deepseek', user: {'endpoint': unsafe, 'title': '保留此名称', 'enabled': true})
        ..addSettings('subagent', user: {'maxDepth': 3});
      engine.settings['web-search-deepseek']!['schema'] = {
        'type': 'object',
        'dict': {
          'endpoint': {'type': 'string'},
          'title': {'type': 'string'},
          'enabled': {'type': 'boolean'},
        },
      };
      final client = DshClient.withCarrier(engine);
      try {
        final source = await loadProfileExport(client, hostLabel: '测试Host', isLocal: false);
        expect(engine.argsOf('settings/describe'), hasLength(1));
        expect(source.settings, {
          'web-search-deepseek': {'title': '保留此名称', 'enabled': true},
          'subagent': {'maxDepth': 3},
        });
        expect(source.defaultSelection, containsAll(['settings:web-search-deepseek', 'settings:subagent']));
        final share = source.build(source.defaultSelection, now: DateTime.utc(2026));
        expect(share.settings, source.settings);
      } finally {
        await client.close();
      }
    });
  }

  test('profile export preserves valid Unicode query and still omits credential query', () async {
    const valid = 'https://example.com/search?label=%E4%B8%AD%E6%96%87';
    final engine = FakeEngine()
      ..addSettings(
        'web-search-deepseek',
        user: {'endpoint': valid, 'callback': 'https://example.com/hook?token=private', 'count': 2},
      );
    final client = DshClient.withCarrier(engine);
    try {
      final source = await loadProfileExport(client, hostLabel: '测试Host', isLocal: false);
      expect(source.settings, {
        'web-search-deepseek': {'endpoint': valid, 'count': 2},
      });
      expect(source.build(source.defaultSelection, now: DateTime.utc(2026)).settings, source.settings);
    } finally {
      await client.close();
    }
  });
}
