import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/state/schedule_editor_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/features/preset_editor/preset_editor_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../plugins/support/fake_plugin_host.dart';
import '../state/read_list_refresh_test.dart' show FixedHost;

class _Settings extends SettingsController {
  _Settings(this.approve);
  final bool approve;
  @override
  AppSettings build() => AppSettings(loaded: true, autoApproveCommands: approve);
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final operation in ['workspace fallback', 'local permission']) {
    for (final leave in [false, true]) {
      testWidgets('real preset inner create $operation: ${leave ? 'route closed' : 'current owner'}', (tester) async {
        usePhoneView(tester);
        final fallback = operation == 'workspace fallback';
        if (fallback) {
          SharedPreferences.setMockInitialValues({
            WorkspacePrefsController.keyFor(HostRef.none): jsonEncode({'selected': 'W'}),
          });
        }
        final carrier = FakePluginCarrier();
        final client = DshClient.withCarrier(carrier);
        addTearDown(client.close);
        final createReply = Completer<Object?>();
        var creates = 0;
        carrier.handlers['session/list'] = (_) => {'items': <Object?>[]};
        carrier.handlers['session/create'] = (_) {
          creates++;
          return creates == 1 ? createReply.future : {'sessionId': 'created-fallback'};
        };
        carrier.handlers['commands/execute'] = (_) => {'commandId': 'permission', 'result': {'kind': 'success'}};
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
        final conn = HostConnection(hostId: '', client: client, isLocal: true);
        try {
          await tester.pumpWidget(testApp(
            Builder(builder: (context) => Scaffold(body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(builder: (_) => const PresetEditorPage()),
              ),
              child: const Text('open real preset editor'),
            ))),
            overrides: [
              activeHostProvider.overrideWith(FixedHost.new),
              activeConnectionProvider.overrideWithValue(AsyncData(conn)),
              readListIdentityProvider.overrideWithValue(null),
              settingsProvider.overrideWith(() => _Settings(!fallback)),
              localRuntimeProvider.overrideWith(StaticRuntime.new),
              deviceTimeZoneProvider.overrideWith((ref) async => 'Asia/Shanghai'),
              // Deliberately no sessionsProvider override: build, create,
              // createForConnection and workspace fallback are all production.
            ],
          ));
          await tester.tap(find.text('open real preset editor'));
          await pumpFrames(tester, 8);
          await tester.enterText(find.widgetWithText(TextField, '比如：代码审查'), 'Inner owner');
          await pumpFrames(tester, 2);
          final page = tester.element(find.byType(PresetEditorPage));
          final container = ProviderScope.containerOf(page);
          final sessions = container.read(sessionsProvider.notifier);
          if (fallback) {
            expect(await container.read(workspacePrefsProvider.notifier).selection(), 'W');
          }
          await tester.tap(find.text('开始创建'));
          await pumpFrames(tester, 2);
          expect(creates, 1);
          final firstRequest = carrier.argsOf('session/create').single['request'] as Map;
          expect(firstRequest['workspaceId'], fallback ? 'W' : isNull);
          expect(carrier.argsOf('commands/execute'), isEmpty);
          if (leave) {
            Navigator.of(page).pop();
            await pumpFrames(tester, 8);
            expect(page.mounted, isFalse);
            expect(container.read(sessionsProvider.notifier), same(sessions),
                reason: 'closing the page does not dispose the non-autoDispose session controller');
          }
          if (fallback) {
            createReply.completeError(const DshRemoteException(WorkspaceErrors.notFound, 'controlled removed workspace'));
          } else {
            createReply.complete({'sessionId': 'created-a'});
          }
          await pumpFrames(tester, 12);
          if (fallback) {
            expect(creates, leave ? 1 : 2, reason: 'retired page must not issue a fresh fallback create');
            if (!leave) {
              final retry = carrier.argsOf('session/create').last['request'] as Map;
              expect(retry['workspaceId'], isNull);
              expect(retry['cwd'], localWorkspaceDir);
            }
            expect(carrier.argsOf('commands/execute'), isEmpty);
          } else {
            final permissions = carrier.argsOf('commands/execute');
            expect(permissions, hasLength(leave ? 0 : 1), reason: 'retired page must not start a permission mutation');
            if (!leave) {
              expect(permissions.single['agentId'], 'created-a');
              expect(permissions.single['line'], '/permission danger-full-access');
            }
          }
          // Retain 938's external select/prompt ownership, not merely the new boundary.
          expect(carrier.argsOf('agentPresets/select'), hasLength(leave ? 0 : 1));
          expect(carrier.argsOf('session/prompt'), hasLength(leave ? 0 : 1));
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          if (!createReply.isCompleted) createReply.complete({'sessionId': 'teardown-only'});
          await tester.pump(const Duration(seconds: 1));
        }
      });
    }
  }
}
