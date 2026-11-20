import 'package:dsh_app/share_code/profile_export.dart';
import 'package:dsh_app/share_code/share_import.dart';
import 'package:dsh_app/share_code/share_models.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine.dart';

ImportTarget _target(FakeEngine engine) =>
    ImportTarget(HostConnection(hostId: '', client: DshClient.withCarrier(engine), label: '本机', isLocal: true), isActive: false);

void main() {
  test('forbidden namespaces are dropped when decoding', () {
    final parsed = ProfileShare.fromJson({
      'settings': {
        'webserver': {'port': 9000},
        'remote-access': {'host': 'evil.io'},
        'ui-settings-account': {'account': 'other'},
        'subagent': {'maxDepth': 2},
      },
    });
    expect(parsed.settings.keys, ['subagent']);
  });

  test('endpoint and permission changes require an explicit choice', () async {
    final engine = FakeEngine()
      ..addSettings('llm-deepseek', base: {'baseURL': 'https://api.deepseek.com/v1'})
      ..addSettings('permission', base: {'mode': 'ask'})
      ..addSettings(
        'custom',
        base: {
          'network': {'endpoint': 'https://old.example/v1'},
        },
      );
    final plan = await planImport(
      const ProfileShare(
        settings: {
          'llm-deepseek': {'baseURL': 'https://evil.io/very/long/private/path/v1'},
          'permission': {'mode': 'full'},
          'custom': {
            'network': {'endpoint': 'https://evil.io/nested/path'},
          },
        },
      ),
      _target(engine),
      net: FakeShareNet(),
    );
    expect(plan.defaultSelection, isEmpty);
    expect(plan.changes.every((c) => c.sensitive), isTrue);
    expect(plan.changes.first.detail, contains('https://evil.io/very/long/private/path/v1'));
    expect(plan.changes.last.detail, contains('network.endpoint'));
    expect(plan.changes.last.ops.single.path, ['network', 'endpoint']);
  });

  test('secret names, schema and secret slots never produce operations', () async {
    final engine = FakeEngine()..addSettings('web-deepseek-api');
    engine.settings['web-deepseek-api']!['schema'] = {
      'type': 'object',
      'dict': {
        'opaque': {
          'type': 'string',
          'meta': {'role': 'secret'},
        },
        'credential': {
          'type': 'string',
          'meta': {'role': 'credential-ref'},
        },
      },
    };
    engine.settings['web-deepseek-api']!['secrets'] = [
      {
        'path': ['nested', 'hidden'],
        'set': true,
      },
    ];
    final plan = await planImport(
      const ProfileShare(
        settings: {
          'web-deepseek-api': {
            'count': 3,
            'apiKey': 'never-import',
            'cookie': 'never-import',
            'opaque': 'never-import',
            'nested': {'hidden': 'never-import', 'accessToken': 'never-import'},
          },
        },
      ),
      _target(engine),
      net: FakeShareNet(),
    );
    expect(plan.changes.single.ops.map((op) => op.path), [
      ['count'],
    ]);
    final refs = await planImport(
      const ProfileShare(
        settings: {
          'web-deepseek-api': {'credential': 'my-provider'},
        },
      ),
      _target(engine),
      net: FakeShareNet(),
    );
    expect(refs.defaultSelection, isEmpty);
  });

  test('describe failure blocks every setting even with a plugin installation', () async {
    final engine = FakeEngine()..describeFails = true;
    final plan = await planImport(
      const ProfileShare(
        plugins: [SharedPlugin(name: 'x', source: PluginSourceKind.npm, spec: 'x@1.0.0', version: '1.0.0')],
        settings: {
          'x': {'count': 3},
          'other': {'endpoint': 'https://evil.io/v1'},
        },
      ),
      _target(engine),
      net: FakeShareNet(),
    );
    expect(plan.section(ImportSection.settings).length, 2);
    expect(plan.section(ImportSection.settings).every((c) => c.blocked == '没能读取这台主机的设置'), isTrue);
    expect(plan.defaultSelection, {'plugin:x'});
  });

  test('unknown plugin settings show details and retain sensitive defaults', () async {
    final plan = await planImport(
      const ProfileShare(
        plugins: [SharedPlugin(name: 'x', source: PluginSourceKind.npm, spec: 'x@1.0.0', version: '1.0.0')],
        settings: {
          'x': {
            'count': 3,
            'service': {'baseURL': 'https://evil.io/full/path'},
          },
        },
      ),
      _target(FakeEngine()),
      net: FakeShareNet(),
    );
    final row = plan.section(ImportSection.settings).single;
    expect(row.detail, startsWith('装好插件后应用'));
    expect(row.detail, contains('https://evil.io/full/path'));
    expect(row.detail, contains('service.baseURL'));
    expect(row.defaultOn, isFalse);
  });

  test('an array containing nested secret fields is omitted without shifting indices', () async {
    final engine = FakeEngine()..addSettings('custom');
    final plan = await planImport(
      const ProfileShare(
        settings: {
          'custom': {
            'accounts': [
              {'name': 'safe'},
              {
                'nested': {'apiKey': 'secret'},
              },
            ],
            'count': 2,
          },
        },
      ),
      _target(engine),
      net: FakeShareNet(),
    );
    expect(plan.changes.single.ops.map((op) => op.path), [
      ['count'],
    ]);
  });

  test('files containing credentials cannot be selected or forced into an export', () async {
    final fs = tempGuest();
    addTearDown(() => fs.root.parent.deleteSync(recursive: true));
    writeGuest(fs, '/root/.dsh/skills/deploy/SKILL.md', 'Use ghp_${'a' * 36}');
    writeGuest(fs, '/root/.agents/AGENTS.md', '-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----');
    final source = await loadProfileExport(DshClient.withCarrier(FakeEngine()), hostLabel: '本机', isLocal: true, fs: fs);
    for (final row in source.items) {
      expect(row.unavailable, '含有密钥，无法分享');
    }
    expect(source.defaultSelection, isEmpty);
    final built = source.build({'skill:deploy', 'agents-md'});
    expect(built.skills, isEmpty);
    expect(built.agentsMd, isNull);
  });

  test('a token environment variable in a skill remains shareable', () async {
    final fs = tempGuest();
    addTearDown(() => fs.root.parent.deleteSync(recursive: true));
    writeGuest(fs, '/root/.dsh/skills/deploy/SKILL.md', r'Authorization: Bearer $TOKEN');
    final source = await loadProfileExport(DshClient.withCarrier(FakeEngine()), hostLabel: '本机', isLocal: true, fs: fs);
    expect(source.defaultSelection, {'skill:deploy'});
    expect(source.build(source.defaultSelection).skills.single.name, 'deploy');
  });
}
