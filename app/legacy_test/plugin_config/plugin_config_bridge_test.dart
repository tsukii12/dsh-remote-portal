// The plugin configuration on the dsh-go bridge's routes (PLUGIN-CONFIG-
// CONTRACT R1), against a fake Host over real HTTP: the capability probe and
// its fallback, entries read one at a time, the opaque revision sent back,
// held edits in one write, and every refusal with its rollback path —
// 400 invalid-operation, 404 entry-unavailable, 409 conflict / overridden /
// apply-failed, 422 invalid-config, 503 host-unavailable, 500
// recovery-failed, a dropped connection — then bound and bare secrets, and
// the scope: DSH's own entries, listed and configurable on the Host, are
// never read or written from here.

import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/plugin_config/plugin_config_memory.dart';
import 'package:dsh_app/state/plugin_config/plugin_config_state.dart';
import 'package:dsh_app/state/plugins_state.dart' show installedPluginsProvider;
import 'package:dsh_app/ui/plugins/config/plugin_config_entries.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../engine_settings/support.dart';
import 'fake_bridge.dart';

const _ns = 'speech-to-text-sensevoice';
const _threads = FieldRef(_ns, ['threads']);
const _precision = FieldRef(_ns, ['precision']);
const _language = FieldRef(_ns, ['language']);

typedef _Rig = ({FakeBridgeHost host, ProviderContainer c, PluginConfigController controller});

Future<_Rig> _rig({
  bool routes = true,
  Duration writeTimeout = const Duration(seconds: 5),
  List<Override> extra = const [],
}) async {
  final host = await FakeBridgeHost.start();
  addTearDown(host.close);
  host.routes = routes;
  host.entries[_ns] = sensevoiceEntry();
  host.unavailable['nested'] = ('unsupported', 'nested-include');
  final client = await DshClient.connect(baseUri: host.baseUri, token: FakeBridgeHost.token, startMux: false);
  addTearDown(client.close);
  final c = ProviderContainer(
    overrides: [
      ...engineOverrides(client),
      if (writeTimeout != const Duration(seconds: 5))
        pluginConfigApiProvider.overrideWith(
          (ref) => BridgePluginConfigApi(
            client,
            MemoryPluginConfigApi(const []),
            writeTimeout: writeTimeout,
            scope: () => ref.read(pluginConfigScopeProvider),
          ),
        ),
      ...extra,
    ],
  );
  addTearDown(c.dispose);
  final sub = c.listen(pluginConfigProvider, (_, _) {});
  addTearDown(sub.close);
  await c.read(pluginConfigProvider.future);
  await _scoped(c);
  return (host: host, c: c, controller: c.read(pluginConfigProvider.notifier));
}

/// Waits for [done]: a state reached over real HTTP, never a fixed number of
/// event-loop turns, which a loaded machine outruns.
Future<void> _until(bool Function() done, {String what = 'the condition'}) async {
  for (var i = 0; i < 500; i++) {
    if (done()) return;
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('timed out waiting for $what');
}

/// The plugin list is in and confirmed, so the state knows which entries are
/// plugins.
Future<void> _scoped(ProviderContainer c) async {
  await c.read(installedPluginsProvider.future);
  await _until(() => c.read(pluginConfigProvider).value?.scope.confirmed ?? false, what: 'a confirmed plugin list');
}

PluginConfigApi _api(_Rig rig) => rig.c.read(pluginConfigApiProvider)!;

/// A failed save re-reads the Host in the background: wait until the form
/// has the Host's revision (or the entry is gone).
Future<void> _reread(_Rig rig) => _until(() {
  final entry = rig.host.entries[_ns];
  return entry == null || _state(rig).forms[_ns]?.revision == 'r${entry.revision}';
}, what: 'the re-read after the failure');

/// Every request that named [entryId]'s own route.
List<(String, String, Object?)> _touched(_Rig rig, String entryId) => [
  for (final r in rig.host.requests)
    if (r.$2 == dshGoPluginConfigEntryPath(entryId)) r,
];

PluginConfigState _state(_Rig rig) => rig.c.read(pluginConfigProvider).value!;

Future<void> _open(_Rig rig) async {
  await rig.controller.load(_ns);
  expect(_state(rig)[_ns], isNotNull);
}

PluginConfigFailure _failure(_Rig rig) => _state(rig).jobOf(_ns)!.failure!;

void main() {
  group('capability', () {
    test('no plugin-config routes (404): the live fields settings/describe serves, as before', () async {
      final rig = await _rig(routes: false);
      final state = _state(rig);
      expect(state.complete, isFalse);
      expect(state.lazy, isFalse);
      expect(state['cot-translation']!.allLive, isTrue);
      expect(state[_ns], isNull, reason: 'DSH 0.2.1 lists no ordinary-only plugin');
      expect((rig.c.read(pluginConfigApiProvider)! as BridgePluginConfigApi).supported, isFalse);
      expect(rig.host.requests.where((r) => r.$2 == '/api/settings/describe'), isNotEmpty);
      // Asked once; a refresh does not knock again.
      final asked = rig.host.requests.where((r) => r.$2 == dshGoPluginConfigPath).length;
      await rig.controller.refresh();
      expect(rig.host.requests.where((r) => r.$2 == dshGoPluginConfigPath).length, asked);
    });

    test('a connection that cannot reach the bridge (the relay) never asks it', () async {
      final c = ProviderContainer(overrides: engineOverrides(DshClient.withCarrier(FakeSettingsHost())));
      addTearDown(c.dispose);
      expect(c.read(pluginConfigApiProvider), isNot(isA<BridgePluginConfigApi>()));
    });

    test('the bridge: entries listed, a form read when its page opens', () async {
      final rig = await _rig();
      var state = _state(rig);
      expect(state.complete, isTrue);
      expect(state.lazy, isTrue);
      expect(state.forms, isEmpty, reason: 'nothing read before a page opens');
      expect(hasPluginConfig(state, _ns), isTrue);
      expect(hasPluginConfig(state, 'nested'), isFalse);
      expect(state.entries['nested']!.reason, 'nested-include');
      await _open(rig);
      state = _state(rig);
      expect(state[_ns]!.revision, 'r1');
      expect(state[_ns]!.isLive(['language']), isTrue);
      expect(state[_ns]!.isLive(['threads']), isFalse);
      expect(rig.host.requests.where((r) => r.$1 == 'GET').map((r) => r.$2), contains('$dshGoPluginConfigPath/$_ns'));
    });
  });

  group('writes', () {
    test('a live field goes at once with the revision as read; the answer brings the next one', () async {
      final rig = await _rig();
      await _open(rig);
      expect(await rig.controller.set(_language, 'zh'), isTrue);
      expect(rig.host.writes().single, {
        'revision': 'r1',
        'ops': [
          {'op': 'set', 'path': ['language'], 'value': 'zh'},
        ],
      });
      expect(_state(rig)[_ns]!.revision, 'r2');
      expect(_state(rig).settingsFor(_ns).valueOf(_language), 'zh');
    });

    test('held edits go in one write; 已生效', () async {
      final rig = await _rig();
      await _open(rig);
      await rig.controller.set(_threads, 4);
      await rig.controller.set(_precision, 'fp32');
      expect(rig.host.writes(), isEmpty);
      expect(await rig.controller.save(_ns), isTrue);
      expect((rig.host.writes().single! as Map)['ops'], [
        {'op': 'set', 'path': ['threads'], 'value': 4},
        {'op': 'set', 'path': ['precision'], 'value': 'fp32'},
      ]);
      expect(_state(rig).jobOf(_ns)!.done, isTrue);
      expect(rig.host.entries[_ns]!.user, {'threads': 4, 'precision': 'fp32'});
    });
  });

  group('refusals', () {
    Future<_Rig> refused(BridgeOutcome outcome) async {
      final rig = await _rig();
      await _open(rig);
      await rig.controller.set(_threads, 4);
      rig.host.next = outcome;
      expect(await rig.controller.save(_ns), isFalse);
      await _reread(rig);
      return rig;
    }

    test('409 apply-failed: restored; the edit waits; 重试 against the new revision', () async {
      final rig = await refused(BridgeOutcome.applyFailed);
      final failure = _failure(rig);
      expect(failure.kind, PluginConfigFailureKind.reloadFailed);
      expect(failure.settled, isTrue);
      expect(failure.message, '已恢复原设置');
      expect(_state(rig).hasDraft(_ns), isTrue);
      expect(rig.host.entries[_ns]!.user, isEmpty);
      expect(await rig.controller.retry(_ns), isTrue);
      expect((rig.host.writes().last! as Map)['revision'], 'r3', reason: 're-read after the failure');
      expect(rig.host.entries[_ns]!.user, {'threads': 4});
    });

    test('500 recovery-failed: not restored; 恢复原设置 sends what was there', () async {
      final rig = await refused(BridgeOutcome.recoveryFailed);
      final failure = _failure(rig);
      expect(failure.settled, isFalse);
      expect(failure.message, '没能生效，原设置也没能恢复');
      expect(rig.host.entries[_ns]!.user, {'threads': 4});
      expect(await rig.controller.rollback(_ns), isTrue);
      expect((rig.host.writes().last! as Map)['ops'], [
        {'op': 'unset', 'path': ['threads']},
      ]);
      expect(rig.host.entries[_ns]!.user, isEmpty);
      expect(_state(rig).jobOf(_ns), isNull);
    });

    test('500 recovery-failed and the plugin did not come back (R3): the form goes, nothing to put back', () async {
      // The case above is the fake's kindest one; on R3 the entry can turn
      // failed with its detail answering 404, as a review run against rc4 saw.
      final rig = await _rig();
      await _open(rig);
      await rig.controller.set(_threads, 4);
      rig.host
        ..next = BridgeOutcome.recoveryFailed
        ..recoveryLosesEntry = true;
      expect(await rig.controller.save(_ns), isFalse);
      await rig.controller.refresh();
      final state = _state(rig);
      expect(state[_ns], isNull);
      expect(state.entries[_ns]!.configurable, isFalse);
      expect(state.entries[_ns]!.state, 'failed', reason: 'the page says 插件没有启动, not 恢复原设置');
      expect(await rig.controller.rollback(_ns), isFalse, reason: 'the Host has no entry to write to');
      expect(rig.host.unavailable[_ns], ('failed', 'not-active'));
    });

    test('409 conflict: re-read under the edit; 重试 goes through', () async {
      final rig = await _rig();
      await _open(rig);
      await rig.controller.set(_threads, 4);
      rig.host.entries[_ns]!
        ..user = {'precision': 'fp32'}
        ..revision = 7;
      expect(await rig.controller.save(_ns), isFalse);
      await _reread(rig);
      expect(_failure(rig).kind, PluginConfigFailureKind.conflict);
      expect(_state(rig).settingsFor(_ns).valueOf(_precision), 'fp32');
      expect(_state(rig).hasDraft(_ns), isTrue);
      expect(await rig.controller.retry(_ns), isTrue);
      expect(rig.host.entries[_ns]!.user, {'precision': 'fp32', 'threads': 4});
    });

    for (final (outcome, kind, message) in [
      (BridgeOutcome.overridden, PluginConfigFailureKind.rejected, '由配置文件固定'),
      (BridgeOutcome.invalidOperation, PluginConfigFailureKind.rejected, '这项改动无法应用'),
      (BridgeOutcome.hostUnavailable, PluginConfigFailureKind.unreachable, '没能连上引擎'),
    ]) {
      test('${outcome.status} ${outcome.code}: nothing written, said in words', () async {
        final rig = await refused(outcome);
        final failure = _failure(rig);
        expect(failure.kind, kind);
        expect(failure.message, message);
        expect(failure.message, isNot(contains('sk-')), reason: 'never the Host\'s own text');
        expect(failure.settled, isTrue);
        expect(_state(rig).hasDraft(_ns), isTrue);
        expect(rig.host.entries[_ns]!.user, isEmpty);
      });
    }

    test('422 invalid-config names the field', () async {
      final rig = await _rig();
      await _open(rig);
      await rig.controller.set(_threads, 4);
      rig.host
        ..next = BridgeOutcome.invalidConfig
        ..invalidPath = ['threads'];
      await rig.controller.save(_ns);
      expect(_failure(rig).path, ['threads']);
      expect(_state(rig).settingsFor(_ns).errorOf(_threads), '值不合法');
    });

    test('404 entry-unavailable: gone after a re-read, edits with it', () async {
      final rig = await _rig();
      await _open(rig);
      await rig.controller.set(_threads, 4);
      rig.host.entries.remove(_ns);
      expect(await rig.controller.save(_ns), isFalse);
      expect(_failure(rig).kind, PluginConfigFailureKind.gone);
      expect(_failure(rig).message, '插件已不在运行，已刷新');
      await rig.controller.refresh();
      expect(_state(rig)[_ns], isNull);
      expect(_state(rig).entries.containsKey(_ns), isFalse);
      expect(_state(rig).hasDraft(_ns), isFalse);
    });

    test('a dropped connection after the write landed: re-read, nothing sent again', () async {
      final rig = await _rig(writeTimeout: const Duration(milliseconds: 150));
      await _open(rig);
      await rig.controller.set(_threads, 4);
      rig.host.next = BridgeOutcome.lostAfterWrite;
      expect(await rig.controller.save(_ns), isFalse);
      expect(_failure(rig).kind, PluginConfigFailureKind.unknown);
      expect(_failure(rig).message, '连接中断，已重新读取');
      // The write reached the Host (and landed) before its answer was lost.
      await _until(() => rig.host.writes().length == 1, what: 'the write at the Host');
      expect(await rig.controller.retry(_ns), isTrue);
      expect(rig.host.writes(), hasLength(1), reason: 'the unset/array ops are not replayed blindly');
      expect(_state(rig).jobOf(_ns), isNull);
      expect(_state(rig).settingsFor(_ns).valueOf(_threads), 4);
    });

    test('a dropped connection before it landed: re-read, 重试 sends it', () async {
      final rig = await _rig(writeTimeout: const Duration(milliseconds: 150));
      await _open(rig);
      await rig.controller.set(_threads, 4);
      rig.host.next = BridgeOutcome.lostBeforeWrite;
      await rig.controller.save(_ns);
      expect(_failure(rig).kind, PluginConfigFailureKind.unknown);
      // The write reached the Host, which refuses it after the client gave up.
      await _until(() => rig.host.writes().length == 1, what: 'the write at the Host');
      expect(await rig.controller.retry(_ns), isTrue);
      expect(rig.host.writes(), hasLength(2));
      expect(rig.host.entries[_ns]!.user, {'threads': 4});
    });
  });

  group('secrets', () {
    test('a bound key goes to the credential store, apart from the form', () async {
      final rig = await _rig();
      await _open(rig);
      const key = FieldRef(_ns, ['apiKey']);
      var shown = _state(rig).settingsFor(_ns);
      expect(shown.credentialRefOf(key), 'SENSEVOICE_KEY');
      expect(shown.secretWritable(key), isTrue);
      expect(shown.secretConfigured(key), isFalse);
      await rig.controller.setSecret(key, 'sk-new');
      expect(rig.host.credentials, {'SENSEVOICE_KEY': 'sk-new'});
      expect(rig.host.writes(), isEmpty, reason: 'never through the config write');
      shown = _state(rig).settingsFor(_ns);
      expect(shown.secretConfigured(key), isTrue);
      expect(_state(rig).hasDraft(_ns), isFalse);
      await rig.controller.clearSecret(key);
      expect(rig.host.credentials, isEmpty);
      expect(_state(rig).settingsFor(_ns).secretConfigured(key), isFalse, reason: 'described again after unset');
    });

    test('a bare secret is not written here', () async {
      final rig = await _rig();
      await _open(rig);
      const token = FieldRef(_ns, ['token']);
      final shown = _state(rig).settingsFor(_ns);
      expect(shown.secretUnbound(token), isTrue);
      expect(shown.secretWritable(token), isFalse);
      expect(shown.secretConfigured(token), isTrue, reason: 'its presence is still a fact');
      await expectLater(
        rig.controller.setSecret(token, 'tok'),
        throwsA(isA<EngineSettingsFailure>().having((e) => e.message, 'message', '需插件适配后设置')),
      );
      expect(rig.host.writes(), isEmpty);
    });
  });

  group('scope', () {
    test('the Host lists DSH\'s own web server, configurable: no page, no read', () async {
      final rig = await _rig();
      rig.host.entries['webserver'] = webserverEntry();
      await rig.controller.refresh();
      final state = _state(rig);
      expect(state.entries['webserver']!.configurable, isTrue, reason: 'the Host would take it');
      expect(state.isPlugin('webserver'), isFalse);
      expect(hasPluginConfig(state, 'webserver'), isFalse);
      expect(pluginConfigEntries(state), [_ns]);
      await rig.controller.load('webserver');
      expect(_state(rig)['webserver'], isNull);
      expect(_touched(rig, 'webserver'), isEmpty, reason: 'its form is not even asked for');
    });

    test('a core entry that got into the list anyway: the write layer sends no POST', () async {
      final rig = await _rig();
      rig.host.entries['webserver'] = webserverEntry();
      await rig.controller.refresh();
      await _open(rig);
      final api = _api(rig);
      // Straight to the Host interface, as a page or a bug might.
      await expectLater(
        api.apply('webserver', const [
          SettingsOp.set(['host'], '0.0.0.0'),
        ], revision: 'r1').drain<void>(),
        throwsA(isA<PluginConfigFailure>().having((f) => f.kind, 'kind', PluginConfigFailureKind.rejected)),
      );
      await expectLater(api.read('webserver'), throwsA(isA<PluginConfigFailure>()));
      // And through the controller.
      const host = FieldRef('webserver', ['host']);
      expect(await rig.controller.set(host, '0.0.0.0'), isFalse);
      expect(await rig.controller.save('webserver'), isFalse);
      await rig.controller.resetAll('webserver');
      expect(_touched(rig, 'webserver'), isEmpty);
      expect(rig.host.writes(), isEmpty);
      expect(rig.host.entries['webserver']!.user, isEmpty);
      // The plugin next to it still writes.
      expect(await rig.controller.set(_language, 'zh'), isTrue);
      expect(rig.host.writes(), hasLength(1));
    });

    test('the package the Host names must be the bundle row\'s', () async {
      final rig = await _rig();
      // A core entry under a plugin row's id: the id alone does not make it one.
      rig.host.entries[_ns] = BridgeEntry(_ns, webserverEntry().schema, package: '@deepseek-ai/dsh-host-webserver');
      await rig.controller.refresh();
      expect(_state(rig).isPlugin(_ns), isFalse);
      await expectLater(
        _api(rig).apply(_ns, const [
          SettingsOp.set(['host'], '0.0.0.0'),
        ], revision: 'r1').drain<void>(),
        throwsA(isA<PluginConfigFailure>()),
      );
      expect(rig.host.writes(), isEmpty);
    });

    test('a bundle switched off takes its rows out of scope, held edits and all', () async {
      final rig = await _rig();
      await _open(rig);
      await rig.controller.set(_threads, 4);
      rig.host.bundles = [
        for (final b in bridgeBundles().cast<Map<String, Object?>>())
          {...b, 'enabled': b['name'] != '@deepseek-ai/dsh-experimental-voice-input-bundle'},
      ];
      await rig.c.read(installedPluginsProvider.notifier).refresh();
      await _until(() => _state(rig).scope.confirmed && !_state(rig).isPlugin(_ns), what: 'the confirmed list');
      expect(pluginConfigEntries(_state(rig)), isEmpty);
      expect(await rig.controller.save(_ns), isFalse);
      expect(rig.host.writes(), isEmpty);
    });

    test('a confirmed plugin list without bundles: nothing is a plugin', () async {
      final rig = await _rig();
      rig.host.bundles = const [];
      await rig.c.read(installedPluginsProvider.notifier).refresh();
      await _until(() => _state(rig).scope.confirmed && _state(rig).scope.isEmpty, what: 'the empty list');
      expect(pluginConfigEntries(_state(rig)), isEmpty);
      await rig.controller.load(_ns);
      expect(_touched(rig, _ns), isEmpty);
    });

    test('without the routes (live fields only) a core namespace is not written either', () async {
      final rig = await _rig(routes: false);
      final state = _state(rig);
      expect(state['cot-translation'], isNotNull, reason: 'an official optional bundle\'s row');
      expect(state.forms.containsKey('agent-loop'), isTrue, reason: 'settings/describe serves the core too');
      expect(state['agent-loop'], isNull);
      await expectLater(
        _api(rig).apply('agent-loop', const [
          SettingsOp.set(['maxParallelToolCalls'], 64),
        ]).drain<void>(),
        throwsA(isA<PluginConfigFailure>()),
      );
      expect(await rig.controller.set(const FieldRef('agent-loop', ['maxParallelToolCalls']), 64), isFalse);
      expect(rig.host.requests.where((r) => r.$2 == '/api/settings/mutate'), isEmpty);
    });
  });
}
