import 'dart:async';

import 'package:dsh_app/state/plugin_config/plugin_config_memory.dart';
import 'package:dsh_app/state/plugin_config/plugin_config_state.dart';
import 'package:dsh_app/state/plugins_state.dart' show installedPluginsProvider;
import 'package:dsh_app/ui/plugins/config/plugin_config_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../engine_settings/support.dart';
import 'support.dart';

class _Read {
  _Read(this.snapshot);

  final Future<PluginConfigForm?> snapshot;
  final result = Completer<PluginConfigForm?>();

  Future<void> succeed() async => result.complete(await snapshot);

  void fail() => result.completeError(const PluginConfigFailure(PluginConfigFailureKind.rejected, 'form read failed'));
}

class _HeldConfigApi extends MemoryPluginConfigApi {
  _HeldConfigApi(String owner)
    : super([
        translatorEntry()..user = {'targetLanguage': owner},
      ], lazy: true);

  final reads = <_Read>[];

  @override
  Future<PluginConfigForm?> read(String ns) {
    final pending = _Read(super.read(ns));
    reads.add(pending);
    return pending.result.future;
  }
}

class _ListHost extends FakeSettingsHost {
  _ListHost() {
    bundles = configBundles();
  }

  Completer<void>? listGate;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (endpoint == 'pluginManager/listBundles') await listGate?.future;
    return super.call(endpoint, args, timeout: timeout);
  }
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(PluginConfigPage)));

Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 20 && !done(); i++) {
    await tester.pump();
  }
  expect(done(), isTrue);
}

Future<void> _refreshPluginList(WidgetTester tester, ProviderContainer container, _ListHost host) async {
  final gate = host.listGate = Completer<void>();
  final refreshed = container.read(installedPluginsProvider.notifier).refresh();
  try {
    await _until(tester, () => container.read(pluginConfigProvider).value?.scope.status == PluginScopeStatus.pending);
  } finally {
    host.listGate = null;
    gate.complete();
  }
  await refreshed;
  await _until(tester, () => container.read(pluginConfigProvider).value?.isPlugin('translator') ?? false);
  await tester.pump();
}

void main() {
  for (final fails in [false, true]) {
    testWidgets('a retired form ${fails ? 'failure' : 'success'} cannot release the current page read', (tester) async {
      final old = _HeldConfigApi('old-host');
      final current = _HeldConfigApi('current-host');
      final currentHost = _ListHost();
      await pumpConfigPage(tester, const PluginConfigPage(ns: 'translator'), old);
      expect(old.reads, hasLength(1));
      final container = _container(tester);
      final controller = container.read(pluginConfigProvider.notifier);

      // The same open page follows a replacement active connection/API. The
      // real notifier rebuilds; the public page starts its new lazy read.
      await pumpConfigPage(tester, const PluginConfigPage(ns: 'translator'), current, host: currentHost);
      await _until(tester, () => current.reads.length == 1);
      expect(container.read(pluginConfigProvider.notifier), same(controller));
      expect(container.read(pluginConfigProvider).value!['translator'], isNull);

      // A confirmed plugin-list refresh notifies the page again. While its
      // current read is pending, the public consumer must not start another.
      await _refreshPluginList(tester, container, currentHost);
      expect(current.reads, hasLength(1));

      if (fails) {
        old.reads.single.fail();
      } else {
        await old.reads.single.succeed();
      }
      await tester.pump();
      expect(container.read(pluginConfigProvider).value!['translator'], isNull);
      expect(container.read(pluginConfigProvider).value!.loadErrors, isEmpty);

      await _refreshPluginList(tester, container, currentHost);
      expect(current.reads, hasLength(1), reason: 'the replacement connection still has its own pending read');
      await current.reads.single.succeed();
      await settle(tester);
      expect(
        container.read(pluginConfigProvider).value!.settingsFor('translator').valueOf(translator(['targetLanguage'])),
        'current-host',
      );
      expect(find.text('翻译服务'), findsOneWidget);
      expect(find.text('old-host'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a current form failure releases its read so the page can retry', (tester) async {
    final api = _HeldConfigApi('current-host');
    await pumpConfigPage(tester, const PluginConfigPage(ns: 'translator'), api);
    expect(api.reads, hasLength(1));
    api.reads.single.fail();
    await tester.pump();
    expect(find.text('form read failed'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await _until(tester, () => api.reads.length == 2);
    await api.reads.last.succeed();
    await settle(tester);
    expect(find.text('翻译服务'), findsOneWidget);
    expect(find.text('form read failed'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
