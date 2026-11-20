import 'package:dsh_app/state/media_generation.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/ui/plugins/plugin_detail_sheet.dart';
import 'package:dsh_app/ui/plugins/plugins_screen.dart';
import 'package:dsh_app/ui/settings/media_settings_page.dart';
import 'package:dsh_app/update/version.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import '../plugins/support/fake_plugin_host.dart';

void main() {
  test('official and fallback media names; offered, installed, disabled, disconnected', () {
    for (final name in ['@dsh-go/media', '@ccchimneyyy/dsh-media', 'dsh-media', '@example/dsh-media']) {
      expect(isMediaPluginName(name), isTrue);
      final installed = PluginBundle.fromJson(bundleJson(name));
      expect(mediaPluginStateOf([installed]), MediaPluginState.ready);
      final disabled = PluginBundle.fromJson(bundleJson(name, enabled: false));
      expect(mediaPluginStateOf([disabled]), MediaPluginState.installable);
    }
    expect(isMediaPluginName('@example/media'), isFalse);
    expect(mediaPluginStateOf([], offered: true), MediaPluginState.installable);
    expect(mediaPluginStateOf([]), MediaPluginState.absent);
    expect(mediaPluginStateOf(null, offered: true), MediaPluginState.absent);
  });

  late FakePluginCarrier carrier;
  late DshClient client;
  setUp(() {
    carrier = FakePluginCarrier();
    client = DshClient.withCarrier(carrier);
    carrier.handlers['pluginManager/listBundles'] = (_) => sampleBundles;
    carrier.handlers['pluginManager/installBundle'] = (_) => installResult(target: '@dsh-go/media');
  });
  tearDown(() => client.close());

  Future<void> pump(WidgetTester tester, {String appVersion = '1.0.2', bool settings = false}) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        settings ? const MediaSettingsPage() : const Scaffold(body: MediaInstallPrompt()),
        overrides: [
          ...pluginOverrides(
            fakeHost(client),
            official: () async => officialFixtureMarket(),
            npmIntegrity: (name, _) async => officialFixtureMarket().byName[name]?.listing?.integrity,
          ),
          appVersionProvider.overrideWithValue(AppVersion.tryParse(appVersion)!),
        ],
      ),
    );
    final container = ProviderScope.containerOf(tester.element(find.byType(MediaInstallPrompt)));
    container.listen(installedPluginsProvider, (_, _) {});
    await tester.pumpAndSettle();
  }

  testWidgets('the generate install prompt installs the official pinned package', (tester) async {
    await pump(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(MediaInstallPrompt)));
    expect(container.read(mediaPluginProvider), MediaPluginState.installable);
    await tester.tap(find.text('在此主机上安装'));
    await tester.pumpAndSettle();
    expect(carrier.argsOf('pluginManager/installBundle').single['spec'], '@dsh-go/media@0.2.0');
  });

  testWidgets('media settings still offers installation when no plugin serves settings', (tester) async {
    await pump(tester, settings: true);
    expect(find.byType(MediaInstallPrompt), findsOneWidget);
    await tester.tap(find.text('在此主机上安装'));
    await tester.pumpAndSettle();
    expect(carrier.argsOf('pluginManager/installBundle').single['spec'], '@dsh-go/media@0.2.0');
  });

  testWidgets('an old app reaches the detail with a disabled install action', (tester) async {
    await pump(tester, appVersion: '1.0.1');
    await tester.tap(find.text('在此主机上安装'));
    await tester.pumpAndSettle();
    expect(find.byType(MarketPluginSheet), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '需要 DSH Go 1.0.2 或更高版本')).onPressed, isNull);
    expect(carrier.argsOf('pluginManager/installBundle'), isEmpty);
  });

  testWidgets('a disabled installed media plugin opens management without reinstalling', (tester) async {
    carrier.handlers['pluginManager/listBundles'] = (_) => [bundleJson('@dsh-go/media', enabled: false)];
    await pump(tester);
    await tester.tap(find.text('在此主机上安装'));
    await tester.pumpAndSettle();
    expect(find.byType(PluginsScreen), findsOneWidget);
    expect(carrier.argsOf('pluginManager/installBundle'), isEmpty);
  });
}
