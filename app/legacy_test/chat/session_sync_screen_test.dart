import 'dart:async';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/plugins/native/native_state.dart';
import 'package:dsh_app/plugins/seams/seat_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/features_state.dart';
import 'package:dsh_app/state/header_schedule_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';
import 'support/session_sync_host.dart';

// Peripheral catalogs are unrelated to the first history snapshot.
class _NoFormatSettings extends EngineSettingsController {
  @override
  Future<EngineSettings?> build() async => null;
}

class _NoFormatPlugins extends InstalledPluginsController {
  @override
  Future<List<PluginBundle>?> build() async => const [];
}

class _RuntimeSpy extends StaticRuntime {
  var stops = 0;
  @override
  Future<void> stop() async {
    stops++;
  }
}

List<String> _writes(SyncHarness h) => h.methods
    .where((method) => const ['session/cancel', 'session/updateQueue', 'session/prompt'].contains(method))
    .toList();

Future<void> _pumpUntil(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 250; i++) {
    if (ready()) return;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 5));
  }
  fail('UI/IO did not settle');
}

Future<SyncHarness> _start(
  WidgetTester tester, {
  required _RuntimeSpy runtime,
  String? phase,
  bool newSession = false,
  bool initialSnapshot = true,
}) async {
  usePhoneView(tester);
  mockClipboard(tester);
  final ui = ChatHarness(session: newSession ? null : 'S', created: 'S', runtime: () => runtime);
  late SyncHarness h;
  await tester.runAsync(
    () => HttpOverrides.runWithHttpOverrides(() async {
      h = await SyncHarness.start(
        initialSnapshot: initialSnapshot && !newSession,
        overrides: [
          for (final override in ui.overrides)
            if (override.origin != activeConnectionProvider && override.origin != chatProvider) override,
          skillsProvider.overrideWith((ref, id) async => const []),
          sessionSchedulesProvider.overrideWith((ref, id) async => const []),
          engineSettingsProvider.overrideWith(_NoFormatSettings.new),
          installedPluginsProvider.overrideWith(_NoFormatPlugins.new),
          nativeBridgeProvider.overrideWithValue(null),
          webBootProvider.overrideWith((ref) async => null),
          bridgeInventoryProvider.overrideWith((ref) async => null),
        ],
      );
      if (phase != null) await h.enter(phase);
    }, RealSyncHttp()),
  );
  await tester.pumpWidget(UncontrolledProviderScope(container: h.container, child: testApp(const ChatScreen())));
  await pumpFrames(tester);
  return h;
}

Future<void> _close(WidgetTester tester, SyncHarness h) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 600));
  await tester.runAsync(h.close);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final scenario in [
    (phase: 'terminal-follow-error', input: 'button'),
    (phase: 'new-mux-ready-snapshot-held', input: 'button'),
    (phase: 'terminal-follow-error', input: 'double-escape'),
  ]) {
    testWidgets('ordinary ${scenario.input} is disabled while ${scenario.phase}', (tester) async {
      final runtime = _RuntimeSpy();
      final h = await _start(tester, runtime: runtime, phase: scenario.phase);
      try {
        final composer = tester.widget<Composer>(find.byType(Composer));
        expect(composer.connected, isTrue);
        expect(composer.running, isTrue);
        expect(composer.sessionReady, isFalse);
        expect(find.text('重新同步'), findsOneWidget);
        final size = tester.getSize(find.widgetWithText(TextButton, '重新同步'));
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
        if (scenario.input == 'button') {
          await tester.tap(find.byIcon(AppIcons.stopGenerating), warnIfMissed: false);
        } else {
          await tester.tap(find.byType(TextField));
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pump(const Duration(milliseconds: 100));
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        }
        await pumpFrames(tester);
        expect(_writes(h), isEmpty);
        expect(runtime.stops, 0);
        expect(tester.takeException(), isNull);
      } finally {
        await _close(tester, h);
      }
    });
  }

  for (final (locale, reason) in const [
    (AppLocale.zhCN, '对话同步中断：当前引擎无法读取此对话的日志格式，请导出诊断包排查'),
    (
      AppLocale.en,
      "Chat sync interrupted: This engine cannot read this chat's log format. Export diagnostics to investigate.",
    ),
  ]) {
    testWidgets('unsupported history shows its reason before the first snapshot: $locale', (tester) async {
      AppLocale.use(locale);
      addTearDown(() => AppLocale.use(AppLocale.zhCN));
      final h = await _start(tester, runtime: _RuntimeSpy(), initialSnapshot: false);
      tester.view.physicalSize = const Size(640, 1688);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      try {
        await tester.runAsync(() async {
          final follow = h.follows.single;
          follow.socket.send({
            'type': 'error',
            'streamId': follow.id,
            'error': {'code': 'session/format-unsupported', 'message': 'synthetic unsupported retained history'},
          });
        });
        await _pumpUntil(tester, () => h.state.streamLost);
        await pumpFrames(tester);
        expect(h.state.error, reason);
        expect(find.text(reason), findsOneWidget);
        final paragraph = tester.renderObject<RenderParagraph>(find.text(reason));
        expect(paragraph.didExceedMaxLines, isFalse, reason: 'the entire format reason must be readable');
        expect(tester.getRect(find.text(reason)).top, greaterThanOrEqualTo(0));
        expect(tester.getRect(find.text(reason)).bottom, lessThan(tester.getRect(find.byType(Composer)).top));
        h.chat.reportError('synthetic late action error');
        await pumpFrames(tester);
        expect(h.state.error, 'synthetic late action error');
        expect(find.text(reason), findsOneWidget, reason: 'an unrelated action cannot replace the follow cause');
        expect(find.text('synthetic late action error'), findsNothing);
        expect(tester.widget<Composer>(find.byType(Composer)).sessionReady, isFalse);
        expect(h.follows, hasLength(1), reason: 'a format refusal does not repeatedly reopen the same history');
        expect(_writes(h), isEmpty);
        expect(tester.takeException(), isNull, reason: 'the narrow refusal is laid out before retry');
        final retryButton = find.widgetWithText(TextButton, appL10n.stateChatSyncRetry);
        final buttonSize = tester.getSize(retryButton);
        expect(buttonSize.width, greaterThanOrEqualTo(48));
        expect(buttonSize.height, greaterThanOrEqualTo(48));
        await tester.tap(retryButton);
        await _pumpUntil(tester, () => h.follows.length == 2);
        await pumpFrames(tester);
        expect(find.text(appL10n.stateChatSyncInterrupted), findsOneWidget);
        expect(find.text(reason), findsNothing, reason: 'a new follow no longer claims the old failure');
        expect(tester.takeException(), isNull, reason: 'waiting for the replacement snapshot remains laid out');
        await tester.runAsync(() async {
          h.follows.last.socket.item(h.follows.last.id, {
            ...syncSnapshot(1),
            'cursor': -1,
            'records': <Object?>[],
            'projections': {
              'asOfSeq': -1,
              'values': {
                'inbox': {'next-turn': <Object?>[], 'next-step': <Object?>[]},
              },
            },
          });
        });
        await _pumpUntil(tester, () => h.state.controlReady && !h.state.resyncing);
        await pumpFrames(tester);
        expect(find.text(reason), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await _close(tester, h);
      }
    });
  }

  testWidgets('late action error does not masquerade as a synchronization failure', (tester) async {
    final h = await _start(tester, runtime: _RuntimeSpy(), phase: 'terminal-follow-error');
    try {
      h.chat.reportError('synthetic late action error');
      await pumpFrames(tester);
      expect(h.state.error, 'synthetic late action error');
      expect(find.text('对话同步中断'), findsOneWidget);
      expect(find.text('synthetic late action error'), findsNothing);
      expect(tester.widget<Composer>(find.byType(Composer)).sessionReady, isFalse);
      expect(_writes(h), isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await _close(tester, h);
    }
  });

  testWidgets('late model failure cannot replace the current history refusal', (tester) async {
    final h = await _start(tester, runtime: _RuntimeSpy(), initialSnapshot: false);
    final received = Completer<void>(), release = Completer<void>();
    bool? accepted;
    h.host.handlers['session/selectModel'] = (_) => {
      'ok': false,
      'error': {'code': 'gateway/internal', 'message': 'synthetic late model failure'},
    };
    h.host.beforeRpc = (endpoint, _) async {
      if (endpoint == 'session/selectModel') {
        received.complete();
        await release.future;
      }
    };
    unawaited(
      h.chat.setModel(const ModelSelection(provider: 'synthetic', model: 'model')).then((value) {
        accepted = value;
      }),
    );
    try {
      await _pumpUntil(tester, () => received.isCompleted);
      await tester.runAsync(() async {
        final follow = h.follows.single;
        follow.socket.send({
          'type': 'error',
          'streamId': follow.id,
          'error': {'code': 'session/format-unsupported', 'message': 'synthetic unsupported retained history'},
        });
      });
      await _pumpUntil(tester, () => h.state.streamLost);
      await pumpFrames(tester);
      const reason = '对话同步中断：当前引擎无法读取此对话的日志格式，请导出诊断包排查';
      expect(find.text(reason), findsOneWidget);
      release.complete();
      await _pumpUntil(tester, () => accepted != null);
      await pumpFrames(tester);
      expect(accepted, isFalse);
      expect(h.state.error, appL10n.stateChatModelSwitchFailed);
      expect(find.text(reason), findsOneWidget);
      expect(find.text(appL10n.stateChatModelSwitchFailed), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      if (!release.isCompleted) release.complete();
      await _pumpUntil(tester, () => accepted != null);
      await _close(tester, h);
    }
  });

  testWidgets('sync button reopens follow; only applied new snapshot enables ordinary stop', (tester) async {
    final runtime = _RuntimeSpy();
    final h = await _start(tester, runtime: runtime, phase: 'terminal-follow-error');
    try {
      h.followMode = 'hold';
      await tester.tap(find.text('重新同步'));
      await _pumpUntil(tester, () => h.follows.length == 7);
      expect(tester.widget<Composer>(find.byType(Composer)).sessionReady, isFalse);
      expect(_writes(h), isEmpty);
      await tester.runAsync(() async {
        h.follows.last.socket.item(h.follows.last.id, syncSnapshot(2));
      });
      await _pumpUntil(tester, () => h.state.controlReady);
      await tester.pump();
      expect(tester.widget<Composer>(find.byType(Composer)).sessionReady, isTrue);
      expect(h.state.pending.single.inboxId, 'queue-run-2');
      await tester.tap(find.byIcon(AppIcons.stopGenerating));
      await _pumpUntil(tester, () => _writes(h).length == 3);
      expect(_writes(h), ['session/cancel', 'session/updateQueue', 'session/prompt']);
      expect((h.boundary[1]['request'] as Map)['itemId'], 'queue-run-2');
      expect(runtime.stops, 0);
      expect(tester.takeException(), isNull);
    } finally {
      await _close(tester, h);
    }
  });

  for (final timeout in [false, true]) {
    testWidgets('new-session first message stays in composer while waiting; timeout=$timeout', (tester) async {
      final h = await _start(tester, runtime: _RuntimeSpy(), newSession: true);
      try {
        await tester.enterText(find.byType(TextField), 'first message');
        await tester.pump();
        await tester.tap(find.byIcon(AppIcons.send));
        await tester.pump();
        expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'first message');
        expect(_writes(h), isEmpty);
        if (timeout) {
          await tester.pump(const Duration(seconds: 11));
          expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'first message');
          expect(_writes(h), isEmpty);
        } else {
          await tester.runAsync(() async {
            h.follows.last.socket.item(h.follows.last.id, {
              ...syncSnapshot(1),
              'cursor': -1,
              'records': <Object?>[],
              'projections': {
                'asOfSeq': -1,
                'values': {
                  'inbox': {'next-turn': <Object?>[], 'next-step': <Object?>[]},
                },
              },
            });
          });
          await _pumpUntil(tester, () => _writes(h).length == 1);
          expect(_writes(h), ['session/prompt']);
          expect((h.boundary.single['request'] as Map)['mode'], 'queue');
          expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
        }
        expect(tester.takeException(), isNull);
      } finally {
        await _close(tester, h);
      }
    });
  }
  testWidgets('Escape presses cannot combine across a synchronization boundary', (tester) async {
    final input = TextEditingController();
    final focus = FocusNode();
    var ready = true;
    var stopped = 0;
    late StateSetter update;
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Composer(
                controller: input,
                focusNode: focus,
                connected: true,
                running: true,
                sessionReady: ready,
                onSend: () {},
                onStop: () => stopped++,
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    update(() => ready = false);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    update(() => ready = true);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(stopped, 0);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(stopped, 1);
    await tester.pumpWidget(const SizedBox());
    input.dispose();
    focus.dispose();
  });
}
