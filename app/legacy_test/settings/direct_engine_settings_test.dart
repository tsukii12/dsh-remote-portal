import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/ui/settings/direct_engine_settings.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_fonts.dart';

class _Runtime extends LocalRuntimeController {
  _Runtime(this.initial, {this.loaded = true});
  final RuntimeStatus initial;
  final bool loaded;
  @override
  LocalRuntimeState build() => LocalRuntimeState(status: initial, loaded: loaded);
  void update(RuntimeStatus next) => state = state.copyWith(status: next);
}

class _Bridge extends RuntimeBridge {
  final changes = <bool>[];
  Completer<void>? pending;
  bool fail = false;
  @override
  Future<void> setDirectEngine(bool enabled) async {
    changes.add(enabled);
    if (fail) throw StateError('native rejected transition');
    if (pending case final future?) await future.future;
  }

  final tawcChanges = <bool>[];
  @override
  Future<void> setTawcEngine(bool enabled) async => tawcChanges.add(enabled);
}

void main() {
  const stopped = RuntimeStatus(phase: RuntimePhase.installed, directEngineAvailable: true);

  Future<void> show(
    WidgetTester tester,
    _Runtime runtime,
    _Bridge bridge, {
    Locale locale = AppLocale.zhCN,
    double scale = 1,
  }) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [localRuntimeProvider.overrideWith(() => runtime), runtimeBridgeProvider.overrideWithValue(bridge)],
        child: MaterialApp(
          theme: withTestFonts(buildLightTheme()),
          locale: locale,
          supportedLocales: AppLocale.supported,
          localizationsDelegates: const [L10n.delegate, ...GlobalMaterialLocalizations.delegates],
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const Scaffold(body: SingleChildScrollView(child: DirectEngineSettings())),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  SettingsSwitchTile tile(WidgetTester tester) =>
      tester.widget<SettingsSwitchTile>(find.byType(SettingsSwitchTile).first);

  testWidgets('failed direct launch offers original compatible setter, once', (tester) async {
    final bridge = _Bridge()..pending = Completer<void>();
    await show(
      tester,
      _Runtime(
        const RuntimeStatus(
          phase: RuntimePhase.error,
          directEngineEnabled: true,
          directEngineAvailable: true,
          launchSelectedMode: 'direct',
          launchFailureReason: 'startFailed',
        ),
      ),
      bridge,
    );
    final entry = find.text(lookupL10n(AppLocale.zhCN).phoneReturnCompatible);
    expect(entry, findsOneWidget);
    await tester.tap(entry);
    await tester.pump();
    expect(bridge.changes, [false]);
    expect(tester.widget<SettingsTile>(find.ancestor(of: entry, matching: find.byType(SettingsTile))).onTap, isNull);
    bridge.pending!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('fallback while running does not silently stop or change preference', (tester) async {
    final bridge = _Bridge();
    await show(
      tester,
      _Runtime(
        const RuntimeStatus(
          phase: RuntimePhase.running,
          directEngineEnabled: true,
          directEngineAvailable: true,
          currentExecutionMode: 'proot',
          launchSelectedMode: 'proot',
          launchSpawned: true,
          directEngineFallbackReason: 'incompatibleFiles',
        ),
      ),
      bridge,
    );
    // Already compatible: the switch's hint says so, no second way back.
    final l10n = lookupL10n(AppLocale.zhCN);
    expect(find.text(l10n.phoneReturnCompatible), findsNothing);
    expect(tile(tester).subtitle, l10n.phoneDirectCompatibleHint);
    expect(tile(tester).value, isTrue);
    expect(tile(tester).onChanged, isNull);
    expect(bridge.changes, isEmpty);
  });

  testWidgets('safe mode launching compatibly is not offered as a way back', (tester) async {
    await show(
      tester,
      _Runtime(
        const RuntimeStatus(
          phase: RuntimePhase.installed,
          mode: EngineMode.safe,
          directEngineEnabled: true,
          directEngineAvailable: true,
          launchSelectedMode: 'proot',
          launchSpawned: true,
          directEngineFallbackReason: 'safeRecovery',
        ),
      ),
      _Bridge(),
    );
    final l10n = lookupL10n(AppLocale.zhCN);
    expect(find.text(l10n.phoneReturnCompatible), findsNothing);
    expect(tile(tester).subtitle, l10n.phoneDirectSafeHint);
    expect(tile(tester).onChanged, isNotNull);
  });

  test('old native status and absent fields remain default off', () {
    final old = RuntimeStatus.fromMap({'phase': 'installed'});
    expect(old.directEngineEnabled, isFalse);
    expect(old.directEngineAvailable, isFalse);
    expect(old.directEngineActive, isFalse);
    expect(old.directEngineFallbackReason, isNull);
    final direct = RuntimeStatus.fromMap({
      'phase': 'running',
      'directEngineEnabled': true,
      'directEngineAvailable': true,
      'directEngineActive': true,
    });
    expect(direct.directEngineEnabled && direct.directEngineAvailable && direct.directEngineActive, isTrue);
  });

  testWidgets('compatibility fallback shows actual method without clearing the saved choice', (tester) async {
    const status = RuntimeStatus(
      phase: RuntimePhase.running,
      directEngineAvailable: true,
      directEngineEnabled: true,
      directEngineActive: false,
      directEngineFallbackReason: 'incompatibleFiles',
    );
    await show(tester, _Runtime(status), _Bridge());
    expect(tile(tester).value, isTrue);
    expect(tile(tester).onChanged, isNull);
    expect(find.text(lookupL10n(AppLocale.zhCN).phoneDirectCompatibleHint), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('after Direct failed to launch the switch is off with its reason, and turning it on retries', (
    tester,
  ) async {
    const fellBack = RuntimeStatus(
      phase: RuntimePhase.installed,
      directEngineAvailable: true,
      launchSelectedMode: 'proot',
      launchSpawned: true,
      directEngineFallbackReason: 'directFailed',
    );
    final runtime = _Runtime(fellBack);
    final bridge = _Bridge();
    await show(tester, runtime, bridge);
    final l10n = lookupL10n(AppLocale.zhCN);
    expect(tile(tester).value, isFalse);
    expect(tile(tester).subtitle, l10n.phoneDirectFailedHint);
    expect(find.text(l10n.phoneReturnCompatible), findsNothing);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(bridge.changes, [true]);
    // Native now reports it on; the last launch's reason no longer explains the switch.
    runtime.update(
      const RuntimeStatus(
        phase: RuntimePhase.installed,
        directEngineAvailable: true,
        directEngineEnabled: true,
        launchSelectedMode: 'proot',
        launchSpawned: true,
        directEngineFallbackReason: 'directFailed',
      ),
    );
    await tester.pumpAndSettle();
    expect(tile(tester).value, isTrue);
    expect(tile(tester).subtitle, l10n.phoneDirectHint);
  });

  testWidgets('running compatibly after a failed Direct launch explains it and waits for a stop', (tester) async {
    await show(
      tester,
      _Runtime(
        const RuntimeStatus(
          phase: RuntimePhase.running,
          directEngineAvailable: true,
          currentExecutionMode: 'proot',
          launchSelectedMode: 'proot',
          launchSpawned: true,
          directEngineFallbackReason: 'directFailed',
        ),
      ),
      _Bridge(),
    );
    expect(tile(tester).subtitle, lookupL10n(AppLocale.zhCN).phoneDirectFailedHint);
    expect(tile(tester).onChanged, isNull);
  });

  testWidgets('turning it on commits once while save is pending and waits for native status', (tester) async {
    final runtime = _Runtime(stopped);
    final bridge = _Bridge()..pending = Completer<void>();
    await show(tester, runtime, bridge);
    expect(tile(tester).value, isFalse);
    expect(tile(tester).onChanged, isNotNull);
    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    expect(bridge.changes, [true]);
    expect(tile(tester).onChanged, isNull);
    expect(tile(tester).value, isFalse);
    bridge.pending!.complete();
    runtime.update(
      const RuntimeStatus(phase: RuntimePhase.installed, directEngineAvailable: true, directEngineEnabled: true),
    );
    await tester.pumpAndSettle();
    expect(tile(tester).value, isTrue);
  });

  for (final phase in [RuntimePhase.installing, RuntimePhase.starting, RuntimePhase.running, RuntimePhase.stopping]) {
    testWidgets('$phase prevents launch method changes', (tester) async {
      await show(tester, _Runtime(RuntimeStatus(phase: phase, directEngineAvailable: true)), _Bridge());
      expect(tile(tester).onChanged, isNull);
    });
  }

  testWidgets('old runtime cannot enable but an already enabled preference can be turned off', (tester) async {
    final runtime = _Runtime(const RuntimeStatus(phase: RuntimePhase.installed));
    final bridge = _Bridge();
    await show(tester, runtime, bridge);
    expect(tile(tester).onChanged, isNull);
    runtime.update(const RuntimeStatus(phase: RuntimePhase.installed, directEngineEnabled: true));
    await tester.pumpAndSettle();
    expect(tile(tester).onChanged, isNotNull);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(bridge.changes, [false]);
  });

  testWidgets('loading is disabled and rejected changes leave the switch unchanged', (tester) async {
    await show(tester, _Runtime(stopped, loaded: false), _Bridge());
    expect(tile(tester).onChanged, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    final bridge = _Bridge()..fail = true;
    await show(tester, _Runtime(stopped), bridge);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(tile(tester).value, isFalse);
    expect(find.text(lookupL10n(AppLocale.zhCN).phoneDirectChangeFailed), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  SettingsSwitchTile tawcTile(WidgetTester tester) =>
      tester.widget<SettingsSwitchTile>(find.byType(SettingsSwitchTile).last);

  testWidgets('tawcroot switch is off by default and turns on through the bridge', (tester) async {
    final bridge = _Bridge();
    await show(tester, _Runtime(const RuntimeStatus(phase: RuntimePhase.installed, tawcEngineAvailable: true)), bridge);
    final l10n = lookupL10n(AppLocale.zhCN);
    expect(tawcTile(tester).value, isFalse);
    expect(tawcTile(tester).subtitle, l10n.phoneTawcHint);
    await tester.tap(find.byType(Switch).last);
    await tester.pumpAndSettle();
    expect(bridge.tawcChanges, [true]);
    expect(bridge.changes, isEmpty);
  });

  testWidgets('tawcroot switch explains a build without it and a failed start', (tester) async {
    final l10n = lookupL10n(AppLocale.zhCN);
    final runtime = _Runtime(const RuntimeStatus(phase: RuntimePhase.installed));
    await show(tester, runtime, _Bridge());
    expect(tawcTile(tester).subtitle, l10n.phoneTawcUnavailable);
    expect(tawcTile(tester).onChanged, isNull);
    runtime.update(
      const RuntimeStatus(
        phase: RuntimePhase.installed,
        tawcEngineAvailable: true,
        directEngineFallbackReason: 'tawcrootFailed',
      ),
    );
    await tester.pumpAndSettle();
    expect(tawcTile(tester).subtitle, l10n.phoneTawcFailedHint);
    expect(tawcTile(tester).onChanged, isNotNull);
  });

  for (final locale in AppLocale.supported) {
    testWidgets('safe mode explains proot recovery at 200% text in ${locale.languageCode}', (tester) async {
      await show(
        tester,
        _Runtime(
          const RuntimeStatus(
            phase: RuntimePhase.installed,
            mode: EngineMode.safe,
            safeState: SafeModeState.on,
            directEngineAvailable: true,
            directEngineEnabled: true,
          ),
        ),
        _Bridge(),
        locale: locale,
        scale: 2,
      );
      expect(find.text(lookupL10n(locale).phoneDirectSafeHint), findsOneWidget);
      expect(tile(tester).value, isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}
