import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/engine_settings/field_sheets.dart';
import 'package:dsh_app/ui/plugins/plugin_inventory_page.dart';
import 'package:dsh_app/ui/plugins/voice_scribe_settings_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

import '../engine_settings/support.dart';
import '../shell/golden_harness.dart' show goldenApp;
import 'voice_scribe_settings_test.dart' show VoiceServer, VoiceHttpCarrier;

final selectedVoiceHost = StateProvider<AsyncValue<HostConnection?>>((ref) => const AsyncData(null));

Future<void> network(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await flush(tester);
}

// Positive waits follow an observable response/UI result. Negative no-write
// checks below keep network()'s original real observation window.
Future<void> voiceReady(WidgetTester tester, bool Function() complete, String label) async {
  final elapsed = Stopwatch()..start();
  do {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 50));
    if (complete()) {
      await settle(tester);
      return;
    }
  } while (elapsed.elapsed < const Duration(seconds: 5));
  fail('Voice settings did not reach $label');
}

bool refreshEnabled() => find
    .byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == appL10n.voiceScribeRefresh && widget.onPressed != null,
    )
    .evaluate()
    .isNotEmpty;

class RealVoiceHttp extends HttpOverrides {}

void voiceTest(String description, WidgetTesterCallback callback) {
  testWidgets(description, (tester) => HttpOverrides.runWithHttpOverrides(() => callback(tester), RealVoiceHttp()));
}

void main() {
  for (final brightness in Brightness.values) {
    for (final scale in [1.3, 2.0]) {
      voiceTest('actual inventory voice entrance, draft retry and clear ${brightness.name} $scale', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 900);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        late VoiceServer server;
        late DshClient client;
        await tester.runAsync(() async {
          server = await VoiceServer.start();
          (client, _) = await server.client();
        });
        addTearDown(() async {
          await client.close();
          await server.close();
        });
        final item = InventoryItem(
          entryId: 'include:voice',
          moduleName: 'dsh-voice-scribe',
          title: 'Voice Scribe 语音输入与润色',
          status: InventoryStatus.values.first,
        );
        await tester.pumpWidget(
          goldenApp(
            brightness: brightness,
            overrides: engineOverrides(client, local: scale == 2.0),
            home: Scaffold(
              body: ListView(children: [InventoryRow(item: item)]),
            ),
          ),
        );
        await flush(tester);
        await tester.tap(find.byType(InventoryRow));
        await flush(tester);
        await tester.ensureVisible(find.text(voiceScribePageTitle));
        await tester.tap(find.text(voiceScribePageTitle));
        await voiceReady(tester, () => find.text('识别语言').evaluate().isNotEmpty, 'initial settings');
        expect(find.byType(VoiceScribeSettingsPage), findsOneWidget);
        expect(find.text('识别语言'), findsOneWidget);
        if (const bool.fromEnvironment('W3_VOICE_GOLDENS')) {
          await expectLater(
            find.byType(VoiceScribeSettingsPage),
            matchesGoldenFile('goldens/voice_scribe_${brightness.name}_${scale.toString().replaceAll('.', '_')}.png'),
          );
        }
        await tester.tap(find.text('识别语言'));
        await flush(tester);
        await tester.enterText(find.byKey(const ValueKey('text-input')), 'zh');
        server.rejectWrites = true;
        await tester.tap(find.text(appL10n.commonDone));
        await voiceReady(
          tester,
          () => find.text(appL10n.commonSaveFailed).evaluate().isNotEmpty,
          'rejected save feedback',
        );
        expect(find.byType(TextFieldSheet), findsOneWidget);
        expect(tester.widget<TextField>(find.byKey(const ValueKey('text-input'))).controller!.text, 'zh');
        expect(find.text(appL10n.commonSaveFailed), findsWidgets);
        server.rejectWrites = false;
        await tester.tap(find.text(appL10n.commonDone));
        await voiceReady(tester, () => find.byType(TextFieldSheet).evaluate().isEmpty, 'acknowledged retry');
        expect(find.byType(TextFieldSheet), findsNothing);
        expect(server.value['language'], 'zh');
        await tester.tap(find.text('识别语言'));
        await flush(tester);
        await tester.enterText(find.byKey(const ValueKey('text-input')), '');
        await tester.tap(find.text(appL10n.commonDone));
        await voiceReady(tester, () => find.byType(TextFieldSheet).evaluate().isEmpty, 'cleared language');
        expect(server.value['language'], '');
        await tester.tap(find.text('润色提示词'));
        await flush(tester);
        await tester.enterText(find.byKey(const ValueKey('text-input')), 'Keep words.\n保留原意。');
        server.failReadsAfterWrite = true;
        await tester.tap(find.text(appL10n.commonDone));
        await voiceReady(
          tester,
          () => find.byType(TextFieldSheet).evaluate().isEmpty && find.text('已保存，刷新后可查看最新设置。').evaluate().isNotEmpty,
          'acknowledged save with failed reread',
        );
        expect(find.byType(TextFieldSheet), findsNothing);
        expect(find.text('已保存，刷新后可查看最新设置。'), findsOneWidget);
        expect(server.value['polishPrompt'], 'Keep words.\n保留原意。');
        server.failReadsAfterWrite = false;
        await tester.tap(find.byTooltip('刷新'));
        await voiceReady(
          tester,
          () => refreshEnabled() && find.text('已保存，刷新后可查看最新设置。').evaluate().isEmpty,
          'completed refresh',
        );
        await tester.tap(find.text('润色提示词'));
        await flush(tester);
        await tester.tap(find.text(appL10n.engineFieldRestoreDefault));
        await voiceReady(tester, () => find.byType(TextFieldSheet).evaluate().isEmpty, 'restored default');
        expect(server.value['polishPrompt'], '');
        expect(
          server.requests
              .where((r) => r['action'] == 'set-settings')
              .every((r) => ['language', 'polishPrompt'].contains((r['patch'] as Map).keys.single)),
          isTrue,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        client.connection.close(force: true);
        await tester.pump();
      });
    }
  }

  for (final mode in ['host-switch', 'host-return', 'loading-with-old-data', 'plugin-restart']) {
    voiceTest('old voice edit cannot write after $mode', (tester) async {
      late VoiceServer server;
      late DshClient client;
      late VoiceHttpCarrier carrier;
      late VoiceServer otherServer;
      late DshClient otherClient;
      await tester.runAsync(() async {
        server = await VoiceServer.start();
        (client, carrier) = await server.client();
        otherServer = await VoiceServer.start();
        (otherClient, _) = await otherServer.client();
      });
      addTearDown(() async {
        await client.close();
        await server.close();
      });
      addTearDown(() async {
        otherClient.connection.close(force: true);
        await otherClient.close();
        await otherServer.close();
      });
      final source = HostConnection(client: client, isLocal: true, hostId: 'A');
      await tester.pumpWidget(
        goldenApp(
          brightness: Brightness.light,
          overrides: [
            ...engineOverrides(client).skip(1),
            selectedVoiceHost.overrideWith((ref) => AsyncData(source)),
            activeConnectionProvider.overrideWith((ref) => ref.watch(selectedVoiceHost)),
          ],
          home: VoiceScribeSettingsPage(source: source, entryId: 'include:voice'),
        ),
      );
      await voiceReady(tester, () => find.text('识别语言').evaluate().isNotEmpty, 'initial settings');
      final container = ProviderScope.containerOf(tester.element(find.byType(VoiceScribeSettingsPage)));
      await tester.tap(find.text('识别语言'));
      await flush(tester);
      await tester.enterText(find.byKey(const ValueKey('text-input')), 'obsolete');
      if (mode == 'plugin-restart') {
        final reads = server.requests.where((request) => request['action'] == 'get-settings').length;
        carrier.pluginChanged();
        await voiceReady(
          tester,
          () =>
              server.requests.where((request) => request['action'] == 'get-settings').length > reads &&
              refreshEnabled(),
          'plugin-change refresh',
        );
      } else {
        container.read(selectedVoiceHost.notifier).state = mode == 'loading-with-old-data'
            // Model Riverpod retaining prior data during a pending host rebuild.
            // ignore: invalid_use_of_internal_member
            ? const AsyncLoading<HostConnection?>().copyWithPrevious(AsyncData(source))
            : AsyncData(HostConnection(client: otherClient, isLocal: true, hostId: 'B'));
        await flush(tester);
        if (mode == 'host-return') {
          container.read(selectedVoiceHost.notifier).state = AsyncData(source);
          await flush(tester);
        }
      }
      await tester.tap(find.text(appL10n.commonDone));
      await network(tester);
      expect(server.writes, 0);
      expect(otherServer.writes, 0);
      expect(find.byType(TextFieldSheet), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('text-input'))).controller!.text, 'obsolete');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      client.connection.close(force: true);
      await tester.pump();
    });
  }

  voiceTest('relay states the real unavailable reason and performs no REST request', (tester) async {
    late VoiceServer server;
    late DshClient client;
    await tester.runAsync(() async {
      server = await VoiceServer.start();
      (client, _) = await server.client();
    });
    addTearDown(() async {
      await client.close();
      await server.close();
    });
    final source = HostConnection(client: client, isLocal: false, kind: HostKind.portal, hostId: 'relay');
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        overrides: [
          ...engineOverrides(client).skip(1),
          activeConnectionProvider.overrideWith((ref) => AsyncData(source)),
        ],
        home: VoiceScribeSettingsPage(source: source, entryId: 'include:voice'),
      ),
    );
    await network(tester);
    expect(find.text(appL10n.webRelayUnavailable), findsOneWidget);
    expect(find.text('识别语言'), findsNothing);
    expect(find.byTooltip('刷新'), findsNothing);
    expect(server.requests, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    client.connection.close(force: true);
    await tester.pump();
  });
}
