import 'dart:async';
import 'dart:io';

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/schedule_editor_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/features/preset_editor/preset_editor_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../plugins/support/fake_plugin_host.dart';

enum _WaitAt { create, select, prompt }

class _Sessions extends SessionsController {
  _Sessions(this.waitAt);

  final _WaitAt waitAt;
  final created = Completer<String>();
  int creates = 0;
  final connections = <HostConnection>[];
  final autoApprovals = <bool>[];

  @override
  Future<List<SessionSummary>> build() async => const [];

  @override
  Future<String> createForConnection(
    HostConnection conn, {
    required bool Function() isCurrent,
    bool autoApprove = true,
  }) async {
    // Isolate creation exactly as the old fixture did. Do not enforce owner
    // after the gate: that would hide a missing outer startCreator check.
    expect(isCurrent(), isTrue, reason: 'the real caller must enter with a live intent');
    connections.add(conn);
    autoApprovals.add(autoApprove);
    creates++;
    if (waitAt == _WaitAt.create) return created.future;
    return 'created-a';
  }

  @override
  Future<void> refresh() async {}
}

class _Settings extends SettingsController {
  @override
  AppSettings build() => const AppSettings(loaded: true);
}

class _Current extends CurrentSessionController {
  @override
  String? build() => null;
}

class _Host extends ActiveHostController {
  _Host(this.initial);

  final HostRef initial;

  @override
  HostRef build() => initial;

  void selectForTest(String id) => state = HostRef.portal(id);
}

class _Connection extends AsyncNotifier<HostConnection?> {
  _Connection(this.initial);

  final HostConnection initial;

  @override
  HostConnection build() => initial;

  void replaceForTest(HostConnection next) => state = AsyncData(next);

  void loadingForTest() => state = const AsyncLoading<HostConnection?>();
}

final _connectionProvider = AsyncNotifierProvider<_Connection, HostConnection?>(() => throw UnimplementedError());

void _catalog(FakePluginCarrier carrier) {
  carrier.handlers['agentPresets/list'] = (_) => {
    'presets': [
      {'id': 'standard', 'order': 1, 'isDefault': true},
      {'id': 'cordis', 'order': 4, 'isDefault': false},
    ],
  };
  carrier.handlers['agentPresets/read'] = (_) => {
    'agentPreset': 'standard',
    'content': File('test/features/fixtures/preset_standard.yaml').readAsStringSync(),
  };
  carrier.handlers['agentPresets/select'] = (_) => 'cordis';
  carrier.handlers['session/prompt'] = (_) => {'accepted': true};
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final waitAt in _WaitAt.values) {
    for (final change in [
      'none',
      'host',
      'connection',
      'host away and back',
      'covered route',
      if (waitAt == _WaitAt.create) 'closed page',
      if (waitAt == _WaitAt.create) ...['first ready', 'initial wrong host', 'initial loading', 'double tap'],
      if (waitAt == _WaitAt.select) 'reconnect',
    ]) {
      testWidgets('preset creation ${waitAt.name}: $change', (tester) async {
        usePhoneView(tester);
        final oldCarrier = FakePluginCarrier();
        final replacementCarrier = FakePluginCarrier();
        _catalog(oldCarrier);
        _catalog(replacementCarrier);
        final oldClient = DshClient.withCarrier(oldCarrier);
        final replacementClient = DshClient.withCarrier(replacementCarrier);
        addTearDown(oldClient.close);
        addTearDown(replacementClient.close);
        final sessions = _Sessions(waitAt);
        final gate = Completer<Object?>();
        if (waitAt == _WaitAt.select) oldCarrier.handlers['agentPresets/select'] = (_) => gate.future;
        if (waitAt == _WaitAt.prompt) oldCarrier.handlers['session/prompt'] = (_) => gate.future;
        final firstReady = change == 'first ready';
        final initialHost = firstReady ? HostRef.none : const HostRef.portal('a');
        final first = HostConnection(
          client: oldClient,
          isLocal: firstReady,
          kind: firstReady ? HostKind.portal : HostKind.portal,
          hostId: firstReady ? '' : 'a',
        );
        final replacement = HostConnection(client: replacementClient, isLocal: false, kind: HostKind.portal, hostId: 'a');
        if (change == 'reconnect') {
          final ready = oldClient.mux.ready();
          await tester.pump();
          await ready;
          expect(oldClient.mux.lastReadyGenerationNumber, 1);
        }
        await tester.pumpWidget(
          testApp(
            Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () =>
                        Navigator.of(context)
                            .push<void>(MaterialPageRoute<void>(builder: (_) => const PresetEditorPage())),
                    child: const Text('open preset editor'),
                  ),
                ),
              ),
            ),
            overrides: [
              activeHostProvider.overrideWith(() => _Host(initialHost)),
              _connectionProvider.overrideWith(() => _Connection(first)),
              activeConnectionProvider.overrideWith((ref) => ref.watch(_connectionProvider)),
              sessionsProvider.overrideWith(() => sessions),
              currentSessionProvider.overrideWith(_Current.new),
              settingsProvider.overrideWith(_Settings.new),
              localRuntimeProvider.overrideWith(StaticRuntime.new),
              deviceTimeZoneProvider.overrideWith((ref) async => 'Asia/Shanghai'),
            ],
          ),
        );
        await tester.tap(find.text('open preset editor'));
        await pumpFrames(tester, 8);
        await tester.enterText(find.widgetWithText(TextField, '比如：代码审查'), 'Owned Review');
        await pumpFrames(tester, 2);
        final pageContext = tester.element(find.byType(PresetEditorPage));
        final container = ProviderScope.containerOf(pageContext);
        final navigator = Navigator.of(pageContext);
        if (change == 'initial wrong host') {
          (container.read(activeHostProvider.notifier) as _Host).selectForTest('b');
        } else if (change == 'initial loading') {
          container.read(_connectionProvider.notifier).loadingForTest();
          expect(container.read(_connectionProvider).isLoading, isTrue);
          expect(container.read(_connectionProvider).value, same(first));
        }
        await tester.tap(find.text('开始创建'));
        if (change == 'double tap') await tester.tap(find.text('开始创建'));
        await pumpFrames(tester, 2);
        if (change.startsWith('initial ')) {
          // Release any wrongly submitted create so a baseline failure does
          // not leave the fake request unresolved at test teardown.
          sessions.created.complete('created-a');
          await pumpFrames(tester, 8);
          expect(sessions.creates, 0, reason: 'initial selection and live connection must agree before creation');
          expect(oldCarrier.argsOf('agentPresets/select'), isEmpty);
          expect(oldCarrier.argsOf('session/prompt'), isEmpty);
          expect(container.read(currentSessionProvider), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          return;
        }
        if (change != 'double tap') expect(sessions.creates, 1);
        expect(sessions.connections, isNotEmpty, reason: 'the new entry must reach this fake');
        expect(sessions.connections.every((conn) => identical(conn, first)), isTrue);
        expect(sessions.autoApprovals.every((value) => value), isTrue);
        expect(oldCarrier.argsOf('agentPresets/select').length, waitAt == _WaitAt.create ? 0 : 1);
        expect(oldCarrier.argsOf('session/prompt').length, waitAt == _WaitAt.prompt ? 1 : 0);
        expect(container.read(currentSessionProvider), isNull);

        switch (change) {
          case 'host':
            // Selection can change before the replacement connection resolves.
            (container.read(activeHostProvider.notifier) as _Host).selectForTest('b');
          case 'connection':
            container.read(_connectionProvider.notifier).replaceForTest(replacement);
          case 'host away and back':
            final host = container.read(activeHostProvider.notifier) as _Host;
            host.selectForTest('b');
            host.selectForTest('a');
          case 'covered route':
            unawaited(
              navigator.push<void>(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('cover page')))),
            );
          case 'closed page':
            navigator.pop();
          case 'first ready':
            expect(oldClient.mux.lastReadyGenerationNumber, 0);
            final ready = oldClient.mux.ready();
            await tester.pump();
            await ready;
            expect(oldClient.mux.lastReadyGenerationNumber, 1);
          case 'reconnect':
            oldClient.mux.reconnect();
            await tester.pump(const Duration(seconds: 1));
            await tester.pump();
            expect(oldClient.mux.generation, isNotNull);
            expect(oldClient.mux.lastReadyGenerationNumber, 2);
          default:
            break;
        }
        await pumpFrames(tester, 4);
        if (waitAt == _WaitAt.create) {
          sessions.created.complete('created-a');
        } else {
          gate.complete(waitAt == _WaitAt.select ? 'cordis' : {'accepted': true});
        }
        await pumpFrames(tester, 8);

        if (change == 'none' || change == 'first ready' || change == 'double tap') {
          expect(sessions.creates, 1, reason: 'two pointer clicks before a frame must share one save attempt');
          expect(oldCarrier.argsOf('agentPresets/select'), [
            {'agentId': 'created-a', 'agentPreset': 'cordis'},
          ]);
          expect(oldCarrier.argsOf('session/prompt'), hasLength(1));
          final request = oldCarrier.argsOf('session/prompt').single['request']! as Map;
          final text = ((request['content']! as List).single as Map)['text']! as String;
          expect(text, contains('Owned Review'));
          expect(text, contains('dsh-preset-owned-review'));
          expect(container.read(currentSessionProvider), 'created-a');
          expect(find.byType(PresetEditorPage), findsNothing);
          expect(find.text('open preset editor'), findsOneWidget);
        } else {
          expect(
            oldCarrier.argsOf('agentPresets/select').length,
            waitAt == _WaitAt.create ? 0 : 1,
            reason: 'a retired creation must not send a later select command',
          );
          expect(
            oldCarrier.argsOf('session/prompt').length,
            waitAt == _WaitAt.prompt ? 1 : 0,
            reason: 'already-sent work is not undone, but a retired creation must not start a new prompt',
          );
          expect(
            container.read(currentSessionProvider),
            isNull,
            reason: 'a late response must not select an old session on the current host',
          );
          if (change == 'covered route') {
            expect(find.text('cover page'), findsOneWidget, reason: 'late completion must not pop a newer route');
            navigator.pop();
            await pumpFrames(tester, 4);
            expect(find.byType(PresetEditorPage), findsOneWidget);
            expect(
              tester.widget<FilledButton>(find.widgetWithText(FilledButton, '开始创建')).onPressed,
              isNotNull,
              reason: 'retiring publication must still release this attempt busy state',
            );
          } else if (change == 'closed page') {
            expect(find.byType(PresetEditorPage), findsNothing);
            expect(find.text('open preset editor'), findsOneWidget);
          } else {
            expect(find.byType(PresetEditorPage), findsOneWidget);
          }
        }
        expect(replacementCarrier.argsOf('agentPresets/select'), isEmpty);
        expect(replacementCarrier.argsOf('session/prompt'), isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
    }
  }
}
