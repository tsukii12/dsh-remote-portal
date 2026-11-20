import 'dart:async';

import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  late FakeSettingsHost host;
  late DshClient client;
  late ProviderContainer container;

  Future<EngineSettings> start({FakeSettingsHost? fake}) async {
    host = fake ?? FakeSettingsHost();
    client = await fakeClient(host);
    await client.mux.ready();
    container = ProviderContainer(overrides: engineOverrides(client));
    addTearDown(container.dispose);
    final sub = container.listen(engineSettingsProvider, (_, _) {});
    addTearDown(sub.close);
    final EngineSettings? settings = await container.read(engineSettingsProvider.future);
    return settings!;
  }

  EngineSettings read() => container.read(engineSettingsProvider).value!;
  EngineSettingsController controller() => container.read(engineSettingsProvider.notifier);
  Future<void> pause([int ms = 20]) => Future<void>.delayed(Duration(milliseconds: ms));

  const depth = FieldRef('subagent', ['maxDepth']);
  const active = FieldRef('subagent', ['maxActiveSubagents']);

  test('loads every namespace with layers and credential states', () async {
    final fake = FakeSettingsHost()..credentials['DEEPSEEK_API_KEY'] = 'sk-test';
    final settings = await start(fake: fake);
    expect(settings.served('subagent'), isTrue);
    expect(settings.valueOf(depth), 1);
    expect(settings.layerOf(depth), FieldLayer.inherited);
    expect(settings.inheritedOf(depth), 1);
    const key = FieldRef('web-search-deepseek', ['apiKey']);
    expect(settings.credentialRefOf(key), 'DEEPSEEK_API_KEY');
    expect(settings.secretConfigured(key), isTrue);
    expect(settings.canWrite('subagent'), isTrue);
    expect(settings.isLocked('subagent'), isFalse);
    // bash-sandbox's composition (60 s) differs from its schema default
    // (120 s): that is the deployment's value, not a lock.
    expect(settings.isLocked('bash-sandbox'), isFalse);
    expect(settings.inheritedOf(const FieldRef('bash-sandbox', ['timeoutMs'])), 60000);
  });

  test('a write shows at once, carries the revision and lands as the user layer', () async {
    await start();
    host.gate = Completer<void>();
    final done = controller().set(depth, 3);
    expect(read().valueOf(depth), 3, reason: 'optimistic');
    expect(read().isSaving(depth), isTrue);
    expect(read().layerOf(depth), FieldLayer.user);
    host.gate!.complete();
    expect(await done, isTrue);
    expect(host.mutates().single, {
      'ns': 'subagent',
      'ops': [
        {
          'op': 'set',
          'path': ['maxDepth'],
          'value': 3,
        },
      ],
      'expectedRevision': 0,
    });
    expect(read().isSaving(depth), isFalse);
    expect(read()['subagent']!.revision, 1);
    expect(read()['subagent']!.user, {'maxDepth': 3});
  });

  test('the inherited value clears the user value; nothing is sent when already inherited', () async {
    await start();
    await controller().set(depth, 3);
    await controller().set(depth, 1);
    expect(host.mutates().last['ops'], [
      {
        'op': 'unset',
        'path': ['maxDepth'],
      },
    ]);
    expect(read().layerOf(depth), FieldLayer.inherited);
    final before = host.mutates().length;
    expect(await controller().set(depth, 1), isFalse);
    expect(host.mutates(), hasLength(before));

    await controller().set(active, 4);
    await controller().reset(active);
    expect(read().valueOf(active), 8);
    expect(read()['subagent']!.user, isEmpty);
  });

  test('writes to one namespace go in order, each on the revision before it', () async {
    await start();
    final a = controller().set(depth, 2);
    final b = controller().set(active, 4);
    expect(await a, isTrue);
    expect(await b, isTrue);
    expect([for (final m in host.mutates()) m['expectedRevision']], [0, 1]);
    expect(read()['subagent']!.user, {'maxDepth': 2, 'maxActiveSubagents': 4});
  });

  test('a stale revision is re-read and retried when the field is untouched', () async {
    await start();
    host.externalSet('subagent', ['maxActiveSubagents'], 5, notify: false);
    expect(await controller().set(depth, 2), isTrue);
    expect(host.mutates().map((m) => m['expectedRevision']), [0, 1]);
    expect(read().valueOf(depth), 2);
    expect(read().valueOf(active), 5);
    expect(read().errorOf(depth), isNull);
  });

  test('a stale revision on the same field keeps the other change and says so', () async {
    await start();
    host.externalSet('subagent', ['maxDepth'], 4, notify: false);
    expect(await controller().set(depth, 2), isFalse);
    expect(host.mutates(), hasLength(1));
    expect(read().valueOf(depth), 4);
    expect(read().errorOf(depth), '刚在别处改过，已刷新');
    controller().clearError(depth);
    expect(read().errorOf(depth), isNull);
  });

  test('a refused value reverts with the reason in words', () async {
    await start();
    const count = FieldRef('web-deepseek-api', ['count']);
    expect(await controller().set(count, 51), isFalse);
    expect(read().valueOf(count), 10);
    expect(read().errorOf(count), '不能大于 50');
    expect(await controller().set(depth, 1.5), isFalse);
    expect(read().errorOf(depth), '请填整数');
  });

  test('a home patch locks the namespace, read or refused', () async {
    final fake = FakeSettingsHost();
    fake.namespaces['agent-loop']!.overlay = {'maxParallelToolCalls': 3};
    final settings = await start(fake: fake);
    const loop = FieldRef('agent-loop', ['maxParallelToolCalls']);
    expect(settings.valueOf(loop), 3);
    expect(settings.layerOf(loop), FieldLayer.locked);
    expect(settings.canWrite('agent-loop'), isFalse);
    expect(await controller().set(loop, 4), isFalse);
    expect(host.mutates(), isEmpty);

    // Same value as the composition: only the refused write tells.
    host.namespaces['subagent']!.overlay = {'maxDepth': 1};
    expect(await controller().set(depth, 2), isFalse);
    expect(read().errorOf(depth), '由配置文件固定');
    expect(read().isLocked('subagent'), isTrue);
    expect(read().layerOf(active), FieldLayer.locked);
  });

  test('a read-only profile disables every write', () async {
    final settings = await start(fake: FakeSettingsHost(writable: false));
    expect(settings.writable, isFalse);
    expect(settings.canWrite('subagent'), isFalse);
    expect(await controller().set(depth, 2), isFalse);
  });

  test('secrets go to the credential the section names', () async {
    await start();
    const key = FieldRef('web-deepseek-api', ['apiKey']);
    await controller().setSecret(key, 'sk-search');
    expect(host.credentials['DEEPSEEK_API_KEY'], 'sk-search');
    expect(host.mutates(), isEmpty);
    expect(read().secretConfigured(key), isTrue);
    await controller().clearSecret(key);
    expect(host.credentials, isEmpty);
    expect(read().secretConfigured(key), isFalse);

    host.envCredentials.add('DEEPSEEK_API_KEY');
    await container.read(engineSettingsProvider.notifier).refresh();
    expect(read().secretWritable(key), isFalse);
    await expectLater(
      controller().setSecret(key, 'sk-other'),
      throwsA(isA<EngineSettingsFailure>().having((f) => f.message, 'message', contains('启动环境'))),
    );
  });

  test('a secret without a credential reference is written into the section', () async {
    final described = recordedDescribe();
    final namespaces = (described['namespaces']! as List).cast<Map<String, Object?>>();
    namespaces.add({
      'ns': 'my-plugin',
      'autoGenerate': true,
      'schema': {
        'type': 'object',
        'dict': {
          'token': {
            'type': 'string',
            'meta': {'role': 'secret'},
          },
          'enabled': {
            'type': 'boolean',
            'meta': {'default': true},
          },
        },
      },
      'value': {'enabled': true},
      'base': {'enabled': true},
      'user': <String, Object?>{},
      'secrets': [
        {
          'path': ['token'],
          'set': false,
        },
      ],
      'revision': 0,
    });
    await start(fake: FakeSettingsHost(describe: described));
    const token = FieldRef('my-plugin', ['token']);
    expect(read().credentialRefOf(token), isNull);
    expect(read().secretConfigured(token), isFalse);
    await controller().setSecret(token, 'abc');
    expect(host.mutates().single['ops'], [
      {
        'op': 'set',
        'path': ['token'],
        'value': 'abc',
      },
    ]);
    expect(read().secretConfigured(token), isTrue);
  });

  test('a change made elsewhere is picked up from the host event', () async {
    await start();
    host.externalSet('subagent', ['maxDepth'], 6);
    await pause(400);
    expect(read().valueOf(depth), 6);
    expect(read().layerOf(depth), FieldLayer.user);
  });

  group('pure helpers', () {
    test('applyOps follows the host: set writes both layers, unset falls back', () {
      final view = SettingsDescription.fromJson(recordedDescribe()).namespaces['bash-sandbox']!;
      final set = applyOps(view, const [
        SettingsOp.set(['timeoutMs'], 90000),
      ]);
      expect(set.value['timeoutMs'], 90000);
      expect(set.user, {'timeoutMs': 90000});
      final unset = applyOps(set, const [
        SettingsOp.unset(['timeoutMs']),
      ]);
      expect(unset.value['timeoutMs'], 60000, reason: 'the composition, not the schema default');
      expect(unset.user, isEmpty);
      expect(schemaAt(view.schema, ['timeoutMs'])!.type, 'number');
      expect(schemaAt(view.schema, ['nope']), isNull);
    });

    test('settings errors in words', () {
      String words(String code, String message) => describeSettingsError(DshRemoteException(code, message));
      expect(words('settings/rejected', r'invalid config:  - $.maxDepth expected number >= 0 but got -1'), '不能小于 0');
      expect(words('settings/rejected', r'- $.indexes[0] expect string to match regexp /x/'), '格式不对');
      expect(words('settings/rejected', 'Configuration for "x" is overridden by a home patch'), '由配置文件固定');
      expect(words('settings/conflict', 'changed'), '刚在别处改过，已刷新');
      expect(words('credential/rejected', 'env'), contains('启动环境'));
      expect(words('gateway/method-not-found', 'no'), '当前引擎版本不支持');
      expect(describeSettingsError(const DshClosedException('x')), '没能连上引擎');
    });

    test('inventory rows: titles, sources, versions, states and presets', () {
      final inventory = PluginInventory.fromJson(recordedInventory());
      final bundles = [for (final b in sampleBundles()) PluginBundle.fromJson(b)];
      final items = inventoryItems(inventory, bundles);
      final loop = items.global.firstWhere((i) => i.entryId == 'include:agent-loop');
      expect(loop.title, isNot(contains('@deepseek-ai')));
      expect(loop.source, 'DSH 内置');
      expect(loop.version, '0.2.1-rc.2');
      expect(loop.status, InventoryStatus.running);
      expect(loop.rowId, 'agent-loop');
      final model = items.global.firstWhere((i) => i.entryId == 'include:subagent-model-selection-settings');
      expect(model.source, '网页版');
      final hand = items.global.firstWhere((i) => i.entryId == '959f2f0f');
      expect(hand.source, '配置文件');
      final off = items.global.firstWhere((i) => i.entryId == 'include:tool-bash');
      expect(off.status, InventoryStatus.off);
      expect(off.enabledIn, isNotEmpty, reason: 'presets provide the bash tool per session');
      expect(items.presets.keys, ['standard', 'ptc']);
      expect(items.presets['standard']!.firstWhere((i) => i.entryId == 'tool-bash').condition, contains('win32'));
      expect(loop.system, isFalse);
      expect(loop.description, isNotNull);
      final remote = items.global.firstWhere((i) => i.entryId == 'include:remote-access');
      expect(remote.system, isTrue, reason: 'no Chinese name in its package');
      expect(remote.title, 'api-remote-access');
      expect(remote.description, isNull, reason: 'English one-liners are not shown');
      expect(chineseText(LocalizedText.plain('远程访问')), '远程访问');
      expect(chineseText(LocalizedText.plain('Remote access')), isNull);
      expect(chineseText(const LocalizedText({'en': 'a', 'zh-cn': '甲'})), '甲');
      expect(loop.matches(['agent']), isTrue);
      expect(loop.matches(['nothing-like-this']), isFalse);
    });

    test('inventory states and short names', () {
      expect(inventoryStatus(enabled: true, fiberPhase: 'active'), InventoryStatus.running);
      expect(inventoryStatus(enabled: true, fiberPhase: 'failed'), InventoryStatus.failed);
      expect(inventoryStatus(enabled: false), InventoryStatus.off);
      expect(inventoryStatus(enabled: true, fiberPhase: 'pending'), InventoryStatus.waiting);
      expect(inventoryStatus(enabled: true, fiberPhase: 'loading'), InventoryStatus.loading);
      expect(inventoryStatus(enabled: false, conditional: true), InventoryStatus.conditional);
      expect(shortModuleName('@deepseek-ai/dsh-web-app'), 'web-app');
      expect(shortModuleName('@deepseek-ai/cordis-plugin-timer'), 'timer');
      expect(shortModuleName('cordis:include'), 'include');
      expect(shortModuleName('my-plugin'), 'my-plugin');
    });
  });
}
