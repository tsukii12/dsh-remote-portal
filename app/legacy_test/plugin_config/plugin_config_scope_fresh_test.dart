// CR-a17797b: which entries are plugins is decided only by the plugin list
// the Host confirmed last, on this connection. A list kept on screen after a
// failed refresh, one being read again, an optimistic switch not yet
// answered, or one from another connection grants nothing: no detail GET, no
// write, no credential call. Over the real providers, controller,
// BridgePluginConfigApi and DshClient, against the HTTP fake bridge.
//
// The first two cases are the review's counterexample (a17797b let the GET
// and the POST through after a failed refresh) and its control.

import 'dart:async';

import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/hosts_state.dart' show HostKind;
import 'package:dsh_app/state/plugin_config/plugin_config_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/read_list_cache.dart';
import 'package:dsh_app/state/read_list_identity.dart' show readListIdentityProvider;
import 'package:dsh_app/ui/plugins/config/plugin_config_entries.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../engine_settings/support.dart';
import 'fake_bridge.dart';

const _ns = 'speech-to-text-sensevoice';
const _language = FieldRef(_ns, ['language']);
const _voice = '@deepseek-ai/dsh-experimental-voice-input-bundle';

typedef _Rig = ({FakeBridgeHost host, ProviderContainer c, PluginConfigController controller});

/// Waits for [done] (a state reached over real HTTP), not a fixed number of
/// event-loop turns.
Future<void> _until(bool Function() done, {String what = 'the condition'}) async {
  for (var i = 0; i < 500; i++) {
    if (done()) return;
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('timed out waiting for $what');
}

Future<_Rig> _rig({bool routes = true, bool listFails = false, bool voiceOn = true}) async {
  final host = await FakeBridgeHost.start();
  addTearDown(host.close);
  host
    ..routes = routes
    ..failListBundles = listFails
    ..bundles = [
      for (final b in bridgeBundles().cast<Map<String, Object?>>()) {...b, 'enabled': b['name'] != _voice || voiceOn},
    ];
  host.entries[_ns] = sensevoiceEntry();
  final client = await DshClient.connect(baseUri: host.baseUri, token: FakeBridgeHost.token, startMux: false);
  addTearDown(client.close);
  final c = ProviderContainer(overrides: engineOverrides(client));
  addTearDown(c.dispose);
  final sub = c.listen(pluginConfigProvider, (_, _) {});
  addTearDown(sub.close);
  final plugins = c.listen(installedPluginsProvider, (_, _) {});
  addTearDown(plugins.close);
  await c.read(pluginConfigProvider.future);
  await _until(() => !c.read(installedPluginsProvider).isLoading, what: 'the plugin list');
  if (!listFails && voiceOn) await _until(() => _state(c).isPlugin(_ns), what: 'the voice plugin in scope');
  return (host: host, c: c, controller: c.read(pluginConfigProvider.notifier));
}

PluginConfigState _state(ProviderContainer c) => c.read(pluginConfigProvider).value!;

PluginConfigApi _api(_Rig rig) => rig.c.read(pluginConfigApiProvider)!;

/// Requests that named [_ns]'s own route, since [from].
List<String> _touched(_Rig rig, [int from = 0]) => [
  for (final (method, path, _) in rig.host.requests.skip(from))
    if (path == dshGoPluginConfigEntryPath(_ns)) '$method $path',
];

List<String> _credentialCalls(_Rig rig, [int from = 0]) => [
  for (final (_, path, _) in rig.host.requests.skip(from))
    if (path == '/api/credentials/set' || path == '/api/credentials/unset') path,
];

Future<void> _refreshPlugins(_Rig rig) => rig.c.read(installedPluginsProvider.notifier).refresh();

int _listReads(_Rig rig) => rig.host.requests.where((r) => r.$2 == '/api/pluginManager/listBundles').length;

void main() {
  group('a stale plugin list', () {
    test('a refresh that fails: no detail read, no write, until a read succeeds again', () async {
      final rig = await _rig();
      await rig.controller.load(_ns);
      expect(_state(rig.c)[_ns], isNotNull);
      rig.host.failListBundles = true;
      await expectLater(_refreshPlugins(rig), throwsA(isA<DshRemoteException>()));
      expect(rig.c.read(installedPluginsProvider).value, isNotNull, reason: 'the list stays on screen');
      expect(rig.c.read(pluginListViewProvider).readOnly, isTrue);
      final before = rig.host.requests.length;

      await _until(() => _state(rig.c).scope.status == PluginScopeStatus.failed, what: 'the failed list');
      expect(rig.c.read(pluginConfigScopeProvider).allows(_ns), isFalse);
      expect(_state(rig.c).scope.status, PluginScopeStatus.failed);
      expect(pluginConfigEntries(_state(rig.c)), isEmpty);
      await expectLater(
        _api(rig).read(_ns),
        throwsA(isA<PluginConfigFailure>().having((f) => f.message, 'message', '插件清单读取失败，稍后重试')),
      );
      expect(await rig.controller.set(_language, 'zh'), isFalse);
      await expectLater(
        _api(rig).apply(_ns, const [
          SettingsOp.set(['language'], 'zh'),
        ], revision: 'r1').drain<void>(),
        throwsA(isA<PluginConfigFailure>()),
      );
      expect(_touched(rig, before), isEmpty, reason: 'neither the GET nor the POST goes out');
      expect(rig.host.entries[_ns]!.user, isEmpty);

      // Read again successfully: the plugin is back.
      rig.host.failListBundles = false;
      await _refreshPlugins(rig);
      await _until(() => _state(rig.c).isPlugin(_ns), what: 'the scope from the new list');
      expect(await rig.controller.set(_language, 'zh'), isTrue);
      expect(rig.host.entries[_ns]!.user, {'language': 'zh'});
    });

    test('the first read fails: nothing is a plugin (control)', () async {
      final rig = await _rig(listFails: true);
      final before = rig.host.requests.length;
      await rig.controller.load(_ns);
      await expectLater(_api(rig).read(_ns), throwsA(isA<PluginConfigFailure>()));
      expect(await rig.controller.set(_language, 'zh'), isFalse);
      expect(rig.c.read(pluginConfigScopeProvider).allows(_ns), isFalse);
      expect(_touched(rig, before), isEmpty);
    });

    test('while the list is read again: nothing is read or written until it answers', () async {
      final rig = await _rig();
      await rig.controller.load(_ns);
      final asked = _listReads(rig);
      final hold = rig.host.holds['pluginManager/listBundles'] = Completer<void>();
      final refreshing = _refreshPlugins(rig);
      await _until(() => _listReads(rig) > asked, what: 'the list request');
      await _until(() => _state(rig.c).scope.status == PluginScopeStatus.pending, what: 'the list being read');
      expect(_state(rig.c).scope.status, PluginScopeStatus.pending);
      final before = rig.host.requests.length;
      await expectLater(
        _api(rig).read(_ns),
        throwsA(isA<PluginConfigFailure>().having((f) => f.message, 'message', '插件清单正在更新，请稍后再试')),
      );
      expect(await rig.controller.set(_language, 'zh'), isFalse);
      expect(_touched(rig, before), isEmpty);
      rig.host.holds.clear();
      hold.complete();
      await refreshing;
      await _until(() => _state(rig.c).isPlugin(_ns), what: 'the scope from the answer');
      expect(await rig.controller.set(_language, 'zh'), isTrue);
    });

    test('switching the bundle on: nothing until the Host confirms it', () async {
      final rig = await _rig(voiceOn: false);
      expect(_state(rig.c).isPlugin(_ns), isFalse);
      final voice = rig.c.read(installedPluginsProvider).value!.firstWhere((b) => b.name == _voice);
      final hold = rig.host.holds['pluginManager/setBundleEnabled'] = Completer<void>();
      final on = rig.c.read(installedPluginsProvider.notifier).setEnabled(voice, true);
      await _until(
        () => rig.c.read(installedPluginsProvider).value!.firstWhere((b) => b.name == _voice).enabled,
        what: 'the optimistic switch',
      );
      // On on screen, not yet answered: an optimistic list grants nothing.
      final before = rig.host.requests.length;
      expect(rig.c.read(pluginConfigScopeProvider).allows(_ns), isFalse);
      expect(rig.c.read(pluginConfigScopeProvider).status, PluginScopeStatus.pending);
      await rig.controller.load(_ns);
      await expectLater(_api(rig).read(_ns), throwsA(isA<PluginConfigFailure>()));
      expect(_touched(rig, before), isEmpty);
      rig.host.holds.clear();
      hold.complete();
      expect((await on).succeeded, isTrue);
      // The Host's own list says on: in scope.
      await _refreshPlugins(rig);
      await _until(() => _state(rig.c).isPlugin(_ns), what: 'the confirmed switch');
      await rig.controller.load(_ns);
      expect(await rig.controller.set(_language, 'zh'), isTrue);
    });

    test('switching the bundle off: out of scope at once, and for good once confirmed', () async {
      final rig = await _rig();
      await rig.controller.load(_ns);
      final voice = rig.c.read(installedPluginsProvider).value!.firstWhere((b) => b.name == _voice);
      final off = rig.c.read(installedPluginsProvider.notifier).setEnabled(voice, false);
      expect(rig.c.read(pluginConfigScopeProvider).allows(_ns), isFalse);
      expect((await off).succeeded, isTrue);
      await _refreshPlugins(rig);
      await _until(
        () => _state(rig.c).scope.confirmed && !_state(rig.c).isPlugin(_ns),
        what: 'the confirmed list without it',
      );
      final before = rig.host.requests.length;
      expect(await rig.controller.set(_language, 'zh'), isFalse);
      expect(_touched(rig, before), isEmpty);
    });
  });

  group('the connection the list came from', () {
    final bundles = [for (final b in bridgeBundles()) PluginBundle.fromJson(b)];

    ProviderContainer container({required PluginHost? host, required Object listedBy}) {
      final c = ProviderContainer(
        overrides: [
          readListIdentityProvider.overrideWithValue(null),
          pluginHostProvider.overrideWithValue(host),
          installedPluginsProvider.overrideWith(() => _Stamped(bundles, listedBy)),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('a list read over another connection grants nothing', () async {
      final current = DshClient.withCarrier(FakeSettingsHost());
      final other = DshClient.withCarrier(FakeSettingsHost());
      final c = container(
        host: PluginHost(client: current, label: 'pc', kind: HostKind.portal),
        listedBy: other,
      );
      await c.read(installedPluginsProvider.future);
      expect(c.read(pluginConfigScopeProvider).allows(_ns), isFalse);
      expect(c.read(pluginConfigScopeProvider).status, PluginScopeStatus.pending);
    });

    test('the same list over this connection does', () async {
      final current = DshClient.withCarrier(FakeSettingsHost());
      final c = container(
        host: PluginHost(client: current, label: 'pc', kind: HostKind.portal),
        listedBy: current,
      );
      await c.read(installedPluginsProvider.future);
      expect(c.read(pluginConfigScopeProvider).allows(_ns), isTrue);
    });

    test('no plugin host (disconnected): nothing', () async {
      final c = container(host: null, listedBy: Object());
      await c.read(installedPluginsProvider.future);
      expect(c.read(pluginConfigScopeProvider).allows(_ns), isFalse);
      expect(c.read(pluginConfigScopeProvider).status, PluginScopeStatus.offline);
    });
  });

  group('credentials', () {
    test('only a key a plugin in scope declares is described, set or cleared', () async {
      final rig = await _rig();
      await rig.controller.load(_ns);
      final api = _api(rig);
      final before = rig.host.requests.length;
      await expectLater(api.setCredential('DEEPSEEK_API_KEY', 'sk-core'), throwsA(isA<PluginConfigFailure>()));
      await expectLater(api.clearCredential('DEEPSEEK_API_KEY'), throwsA(isA<PluginConfigFailure>()));
      expect(_credentialCalls(rig, before), isEmpty);
      expect(rig.host.credentials, isEmpty);
      final described = await api.describeCredentials({'DEEPSEEK_API_KEY', 'SENSEVOICE_KEY'});
      expect(described.keys, ['SENSEVOICE_KEY']);
      final asked = [
        for (final (_, path, body) in rig.host.requests.skip(before))
          if (path == '/api/credentials/describe') ((body! as Map)['payload'] as Map)['args'],
      ];
      expect(asked, [
        {
          'refs': ['SENSEVOICE_KEY'],
        },
      ]);
      // The plugin's own key goes through.
      await api.setCredential('SENSEVOICE_KEY', 'sk-plugin');
      expect(rig.host.credentials, {'SENSEVOICE_KEY': 'sk-plugin'});
    });

    test('a key whose plugin form was not read is not written', () async {
      final rig = await _rig();
      await expectLater(_api(rig).setCredential('SENSEVOICE_KEY', 'sk'), throwsA(isA<PluginConfigFailure>()));
      expect(_credentialCalls(rig), isEmpty);
    });

    test('once the plugin list fails, not even the plugin\'s own key', () async {
      final rig = await _rig();
      await rig.controller.load(_ns);
      rig.host.failListBundles = true;
      await expectLater(_refreshPlugins(rig), throwsA(isA<DshRemoteException>()));
      await _until(() => _state(rig.c).scope.status == PluginScopeStatus.failed, what: 'the failed list');
      final before = rig.host.requests.length;
      await expectLater(_api(rig).setCredential('SENSEVOICE_KEY', 'sk'), throwsA(isA<PluginConfigFailure>()));
      expect(_credentialCalls(rig, before), isEmpty);
    });

    test('without the routes (live fields only) a core key is not written either', () async {
      final rig = await _rig(routes: false);
      await expectLater(_api(rig).setCredential('DEEPSEEK_API_KEY', 'sk'), throwsA(isA<PluginConfigFailure>()));
      await expectLater(_api(rig).clearCredential('DEEPSEEK_API_KEY'), throwsA(isA<PluginConfigFailure>()));
      expect(_credentialCalls(rig), isEmpty);
    });
  });
}

/// The bundles as read over [client]: the Host's answer, stamped like a real read.
class _Stamped extends InstalledPluginsController {
  _Stamped(this.bundles, this.client);

  final List<PluginBundle> bundles;
  final Object client;

  @override
  Future<List<PluginBundle>?> build() async =>
      ref.read(readListCacheProvider).stamp<List<PluginBundle>>([...bundles], null, client);
}
