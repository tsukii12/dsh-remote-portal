import 'package:dsh_app/pets/pet_overlay_actions.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/session_modes.dart';
import 'package:dsh_app/ui/chat/widgets/plus_panel.dart';
import 'package:dsh_app/ui/features/permission_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../plugins/support/fake_plugin_host.dart';
import '../shell/golden_harness.dart' show FakeRuntime, runningStatus;

void main() {
  for (final surface in ['settings', 'session']) {
    for (final scenario in ['switch to local', 'same remote', 'same local']) {
      testWidgets('permission default confirmation: $surface / $scenario', (tester) async {
        SharedPreferences.setMockInitialValues({});
        usePhoneView(tester);
        final remoteCarrier = FakePluginCarrier();
        final localCarrier = FakePluginCarrier();
        final remote = DshClient.withCarrier(remoteCarrier);
        final local = DshClient.withCarrier(localCarrier);
        addTearDown(remote.close);
        addTearDown(local.close);
        for (final carrier in [remoteCarrier, localCarrier]) {
          carrier.handlers['settings/describe'] = (_) => {
            'writable': true,
            'namespaces': [
              {'ns': 'permission', 'value': <String, Object?>{}, 'revision': 4},
            ],
          };
          carrier.handlers['permissionPresets/catalog'] = (_) => {
            'options': [
              {'value': 'workspace-write', 'name': 'workspace-write'},
              {'value': 'danger-full-access', 'name': 'danger-full-access'},
            ],
            'defaultPreset': 'workspace-write',
          };
          carrier.handlers['session/projections'] = (_) => {
            'kind': 'sequenced',
            'asOfSeq': 1,
            'values': {
              'permissions': {'currentValue': 'danger-full-access'},
            },
          };
          carrier.handlers['settings/mutate'] = (_) => {
            'ns': 'permission',
            'value': {'defaultPreset': 'danger-full-access'},
            'revision': 5,
          };
        }
        await tester.pumpWidget(
          testApp(
            surface == 'settings'
                ? const PermissionPage()
                : const Scaffold(body: SessionPermissionPage(sessionId: 's1')),
            overrides: [
              sessionModesProvider.overrideWith((ref, id) => const SessionModes(preset: 'danger-full-access')),
              activeConnectionProvider.overrideWith((ref) {
                final host = ref.watch(activeHostProvider);
                return AsyncData(
                  host.kind == HostKind.portal
                      ? HostConnection(hostId: '', client: local, isLocal: true)
                      : HostConnection(client: remote, isLocal: false, kind: HostKind.portal, hostId: 'pc'),
                );
              }),
              localRuntimeProvider.overrideWith(
                () => FakeRuntime(LocalRuntimeState(loaded: true, status: runningStatus)),
              ),
              petHostChoicesProvider.overrideWithValue(const [PetHostChoice(HostRef.none, '本机')]),
            ],
          ),
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(surface == 'settings' ? PermissionPage : SessionPermissionPage)),
        );
        if (scenario != 'same local') container.read(activeHostProvider.notifier).select(const HostRef.portal('pc'));
        await tester.pumpAndSettle();
        expect(container.read(settingsProvider).autoApproveCommands, isFalse);
        await tester.tap(find.text(surface == 'settings' ? '完全权限' : '设为新对话默认').last);
        await tester.pumpAndSettle();
        expect(find.text('开启完全权限？'), findsOneWidget);
        if (scenario == 'switch to local') {
          tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
          tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
          tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
          expect(
            await container
                .read(petOverlayActionsProvider)
                .handle(MethodCall('switchHost', {'host': HostRef.none.encode()})),
            isTrue,
          );
          tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
          tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
          tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          await tester.pumpAndSettle();
          expect(find.text('开启完全权限？'), findsOneWidget);
          expect(container.read(activeConnectionProvider).value!.client, same(local));
        }
        await tester.tap(find.widgetWithText(FilledButton, '开启完全权限'));
        await tester.pumpAndSettle();
        final prefs = await SharedPreferences.getInstance();
        expect(
          [container.read(settingsProvider).autoApproveCommands, prefs.getBool('auto_approve_commands') ?? false],
          [scenario == 'same local', scenario == 'same local'],
        );
        expect(remoteCarrier.argsOf('settings/mutate').length, scenario == 'same remote' ? 1 : 0);
        expect(localCarrier.argsOf('settings/mutate'), isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
