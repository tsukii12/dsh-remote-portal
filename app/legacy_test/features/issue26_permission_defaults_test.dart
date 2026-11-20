import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/features_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/features/permission_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../plugins/support/fake_plugin_host.dart';

class _Settings extends SettingsController {
  @override
  AppSettings build() => const AppSettings(loaded: true);
}

const _ordinary = [
  {'value': 'workspace-write', 'name': 'workspace-write'},
  {'value': 'danger-full-access', 'name': 'danger-full-access'},
];
const _auto = {'value': 'auto', 'name': 'auto'};

void main() {
  late FakePluginCarrier carrier;
  late DshClient client;
  var stored = 'workspace-write';

  setUp(() {
    // 自动审查's first-time notice reads whether it was silenced.
    SharedPreferences.setMockInitialValues({});
    carrier = FakePluginCarrier();
    client = DshClient.withCarrier(carrier);
    stored = 'workspace-write';
    carrier.handlers['settings/describe'] = (_) => {
      'writable': true,
      'namespaces': [
        {
          'ns': 'permission',
          'value': {'defaultPreset': stored},
          'revision': 7,
        },
      ],
    };
    carrier.handlers['session/projections'] = (_) => {
      'kind': 'sequenced',
      'asOfSeq': 1,
      'values': {
        'permissions': {'currentValue': 'workspace-write'},
      },
    };
    carrier.handlers['permissionPresets/catalog'] = (_) => {
      'options': [..._ordinary, _auto],
      'defaultOptions': _ordinary,
      'defaultPreset': stored,
    };
    carrier.handlers['commands/execute'] = (_) => {
      'commandId': 'permission-1',
      'result': {'kind': 'success', 'text': 'preset auto'},
    };
  });
  tearDown(() => client.close());

  Future<void> pump(WidgetTester tester, {String? sessionId}) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        PermissionPage(sessionId: sessionId),
        overrides: [
          activeConnectionProvider.overrideWithValue(AsyncData(fakeHost(client, kind: HostKind.portal))),
          settingsProvider.overrideWith(_Settings.new),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Auto stays selectable for the current chat but is absent from defaults', (tester) async {
    await pump(tester, sessionId: 's1');
    expect(find.text('自动审查'), findsOneWidget);
    await tester.tap(find.text('自动审查'));
    await tester.pumpAndSettle();
    // First time: said once, 不再提示 ticked.
    expect(find.text('开启自动审查？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '开启自动审查'));
    await tester.pumpAndSettle();
    expect(carrier.argsOf('commands/execute').single['line'], '/permission auto');
    expect(carrier.argsOf('settings/mutate'), isEmpty);
  });

  testWidgets('a poisoned default can be explicitly reset without touching the current chat', (tester) async {
    stored = 'auto';
    carrier.handlers['permissionPresets/catalog'] = (_) {
      if (stored == 'auto') {
        throw const DshRemoteException('internal', 'permission: unknown default preset "auto"');
      }
      return {
        'options': [..._ordinary, _auto],
        'defaultOptions': _ordinary,
        'defaultPreset': stored,
      };
    };
    carrier.handlers['settings/mutate'] = (_) {
      stored = 'workspace-write';
      return {
        'ns': 'permission',
        'value': {'defaultPreset': stored},
        'revision': 8,
      };
    };
    await pump(tester, sessionId: 's1');
    expect(find.text('恢复默认'), findsOneWidget);
    expect(carrier.argsOf('settings/mutate'), isEmpty, reason: 'opening the page never changes permissions');
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    expect(carrier.argsOf('settings/mutate').single, {
      'ns': 'permission',
      'ops': [
        {
          'op': 'unset',
          'path': ['defaultPreset'],
        },
      ],
      'expectedRevision': 7,
    });
    expect(carrier.argsOf('commands/execute'), isEmpty);
    expect(find.text('恢复默认'), findsNothing);
    expect(find.text('自动审查'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('an explicit empty defaultOptions list is honored', () async {
    carrier.handlers['permissionPresets/catalog'] = (_) => {
      'options': [..._ordinary, _auto],
      'defaultOptions': <Object?>[],
      'defaultPreset': 'workspace-write',
    };
    expect((await client.permissionPresets()).defaultOptions, isEmpty);
  });

  test('old catalogs omit defaultOptions but Auto is still session-only', () async {
    carrier.handlers['permissionPresets/catalog'] = (_) => {
      'options': [..._ordinary, _auto],
      'defaultPreset': 'workspace-write',
    };
    expect((await client.permissionPresets()).defaultOptions.map((option) => option.value), [
      'workspace-write',
      'danger-full-access',
    ]);
  });

  test('unrelated catalog failures are not rewritten as invalid settings', () async {
    stored = 'auto';
    carrier.handlers['permissionPresets/catalog'] = (_) => throw const DshRemoteException('offline', 'unreachable');
    final container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [activeConnectionProvider.overrideWithValue(AsyncData(fakeHost(client, kind: HostKind.portal)))],
    );
    addTearDown(container.dispose);
    final sub = container.listen(permissionStateProvider(null), (_, _) {});
    addTearDown(sub.close);
    await expectLater(container.read(permissionStateProvider(null).future), throwsA(isA<DshRemoteException>()));
  });
}
