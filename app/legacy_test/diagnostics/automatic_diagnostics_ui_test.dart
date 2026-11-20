import 'package:dsh_app/diagnostics/automatic_diagnostics.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/ask_ai.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/settings/diagnostics_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart' show testApp, loadTestFonts, usePhoneView;
import 'automatic_diagnostics_test.dart' show sample;

class _Settings extends SettingsController {
  @override
  AppSettings build() => const AppSettings(loaded: true);
  @override
  Future<void> setAutomaticDiagnostics(bool value) async {
    state = state.copyWith(automaticDiagnostics: value);
  }
}

class _Host extends ActiveHostController {
  _Host(this.initial);
  final HostRef initial;
  @override
  HostRef build() => initial;
}

class _Current extends CurrentSessionController {
  @override
  String? build() => 'working';
  @override
  void select(String? sessionId) => state = sessionId;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  AutomaticDiagnostics coordinator() =>
      AutomaticDiagnostics(collect: () async => sample(), load: () async => {}, store: (_) async {});

  Future<ProviderContainer> pump(
    WidgetTester tester,
    AutomaticDiagnostics automatic, {
    HostRef host = HostRef.none,
  }) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        const Scaffold(body: SingleChildScrollView(child: AutomaticDiagnosticsSection())),
        overrides: [
          automaticDiagnosticsProvider.overrideWithValue(automatic),
          settingsProvider.overrideWith(_Settings.new),
          activeHostProvider.overrideWith(() => _Host(host)),
          currentSessionProvider.overrideWith(_Current.new),
          askAiAvailableProvider.overrideWithValue(false),
        ],
      ),
    );
    await tester.pump();
    return ProviderScope.containerOf(tester.element(find.byType(AutomaticDiagnosticsSection)));
  }

  testWidgets('off by default; consent states recipients, costs and exclusions before enabling', (tester) async {
    final automatic = coordinator();
    final container = await pump(tester, automatic);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text(appL10n.automaticDiagnosticsConsent), findsOneWidget);
    expect(appL10n.automaticDiagnosticsConsent, contains('模型费用'));
    expect(appL10n.automaticDiagnosticsConsent, contains('不含聊天正文、录音、凭据'));
    expect(container.read(settingsProvider).automaticDiagnostics, isFalse);
    await tester.tap(find.text(appL10n.automaticDiagnosticsEnable));
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).automaticDiagnostics, isTrue);
    expect(container.read(currentSessionProvider), 'working');
    await tester.pumpWidget(const SizedBox());
    automatic.dispose();
  });

  testWidgets('remote connection cannot enable or open a local report', (tester) async {
    final automatic = coordinator()..reportSessionId = 'local-report';
    final container = await pump(tester, automatic, host: const HostRef.portal('remote'));
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    await tester.tap(find.text(appL10n.automaticDiagnosticsViewReport));
    await tester.pump();
    expect(container.read(currentSessionProvider), 'working');
    expect(find.text(appL10n.automaticDiagnosticsConsentTitle), findsNothing);
    await tester.pumpWidget(const SizedBox());
    automatic.dispose();
  });

  testWidgets('report never steals the current session; explicit entry opens ordinary report', (tester) async {
    final automatic = coordinator()..reportSessionId = 'local-report';
    final container = await pump(tester, automatic);
    expect(container.read(currentSessionProvider), 'working');
    await tester.tap(find.text(appL10n.automaticDiagnosticsViewReport));
    await tester.pump();
    expect(container.read(currentSessionProvider), 'local-report');
    await tester.pumpWidget(const SizedBox());
    automatic.dispose();
  });

  testWidgets('explicit recovery entry rebuilds local records without model submission', (tester) async {
    var sends = 0;
    final automatic =
        AutomaticDiagnostics(
          collect: () async => sample(),
          load: () async => throw const FormatException('synthetic corrupt checkpoint'),
          store: (_) async {},
        )..configure(Object(), (_, _, _) async {
          sends++;
        });
    await automatic.ready;
    await pump(tester, automatic);
    expect(find.text(appL10n.automaticDiagnosticsRecoverHint), findsOneWidget);
    await tester.tap(find.text(appL10n.automaticDiagnosticsRecover));
    await tester.pumpAndSettle();
    expect(sends, 0);
    expect(automatic.failureCode, isNull);
    expect(find.text(appL10n.automaticDiagnosticsRecover), findsNothing);
    await tester.pumpWidget(const SizedBox());
    automatic.dispose();
  });

  testWidgets('remote host cannot recover local records', (tester) async {
    final automatic = AutomaticDiagnostics(
      collect: () async => throw StateError('remote recovery must not collect'),
      load: () async => throw const FormatException('synthetic corrupt checkpoint'),
      store: (_) async => fail('remote recovery must not write'),
    );
    await automatic.ready;
    await pump(tester, automatic, host: const HostRef.portal('remote'));
    await tester.tap(find.text(appL10n.automaticDiagnosticsRecover));
    await tester.pump();
    expect(automatic.failureCode, 'store_failed');
    await tester.pumpWidget(const SizedBox());
    automatic.dispose();
  });

  testWidgets('analysis and stop failures remain visible', (tester) async {
    final automatic = coordinator()
      ..phase = AutomaticDiagnosticsPhase.failed
      ..failureCode = 'cancel_failed';
    await pump(tester, automatic);
    expect(find.text(appL10n.automaticDiagnosticsCancelFailed), findsOneWidget);
    expect(find.text(appL10n.automaticDiagnosticsRecover), findsNothing);
    await tester.pumpWidget(const SizedBox());
    automatic.dispose();
  });
}
