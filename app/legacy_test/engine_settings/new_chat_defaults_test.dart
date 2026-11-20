import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/model_defaults_state.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/ui/providers/new_chat_defaults_card.dart';
import 'package:dsh_app/ui/providers/providers_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Map<String, Object?> defaultsDescribe({bool mode = true, int revision = 17, String? baseEffort}) => {
  'namespaces': [
    {
      'ns': defaultModelSettingsNs,
      'schema': {
        'type': 'object',
        'dict': {
          'provider': {'type': 'string'},
          'model': {'type': 'string'},
          'reasoningEffort': {'type': 'string'},
          if (mode) 'rememberLastSelection': {'type': 'boolean'},
        },
      },
      'base': {
        'provider': 'deepseek-official',
        'model': 'deepseek-flash',
        'reasoningEffort': ?baseEffort,
        if (mode) 'rememberLastSelection': true,
      },
      'revision': revision,
    },
  ],
};

Map<String, Object?> thinkingCatalog({bool high = true}) => {
  ...sampleCatalog,
  'default': {'provider': 'deepseek-official', 'model': 'deepseek-flash', 'reasoningEffort': 'high'},
  'groups': [
    {
      'id': 'deepseek-official',
      'name': 'DeepSeek',
      'models': [
        {
          'id': 'deepseek-flash',
          'name': 'DeepSeek-V4.1-Flash',
          'reasoning': {
            'defaultEffort': 'low',
            'efforts': [
              {'id': 'off', 'name': 'Off'},
              {'id': 'low', 'name': 'Low'},
              if (high) {'id': 'high', 'name': 'High'},
            ],
          },
        },
      ],
    },
  ],
};

final _host = StateProvider<HostConnection?>((ref) => null);

class _SshHost extends ActiveHostController {
  @override
  HostRef build() => const HostRef.portal('test-host');
}

Future<void> _pumpRemoteProviders(WidgetTester tester, FakeSettingsHost host) async {
  final client = DshClient.withCarrier(host);
  addTearDown(client.close);
  await tester.runAsync(() => client.mux.ready());
  await pumpPage(
    tester,
    const ProvidersPage(),
    overrides: [
      ...engineOverrides(client).skip(1),
      activeHostProvider.overrideWith(_SshHost.new),
      activeConnectionProvider.overrideWithValue(
        AsyncData(HostConnection(client: client, isLocal: false, kind: HostKind.portal, hostId: 'test-host')),
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> start(FakeSettingsHost host) async {
    final client = DshClient.withCarrier(host);
    final container = ProviderContainer(overrides: engineOverrides(client));
    addTearDown(() async {
      container.dispose();
      await client.close();
    });
    return container;
  }

  test('default-model document updates refresh the authoritative catalog', () async {
    final host = FakeSettingsHost(describe: defaultsDescribe())
      ..modelCatalog = {...sampleCatalog, 'default': sampleCatalog['defaultSelection']};
    final container = await start(host);
    final sub = container.listen(currentModelCatalogProvider, (_, _) {});
    addTearDown(sub.close);
    await container.read(activeConnectionProvider).value!.client.mux.ready();
    expect((await container.read(modelCatalogProvider.future))!.defaultSelection!.model, 'deepseek-flash');
    final readsBefore = host.calls.where((call) => call.$1 == 'session/modelCatalog').length;
    host.modelCatalog = {
      ...sampleCatalog,
      'default': {'provider': 'custom-mygw', 'model': 'qwen3-coder', 'reasoningEffort': 'high'},
    };
    host.emit('settings/document-updated', [defaultModelSettingsNs, 18]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final catalog = await container.read(modelCatalogProvider.future);
    expect(catalog!.defaultSelection!.provider, 'custom-mygw');
    expect(catalog.defaultSelection!.reasoningEffort, 'high');
    expect(host.calls.where((call) => call.$1 == 'session/modelCatalog').length, greaterThan(readsBefore));
  });

  test('an editor from the prior mux cannot write after same-client reconnect', () async {
    final host = FakeSettingsHost(describe: defaultsDescribe());
    final client = DshClient.withCarrier(host);
    final container = ProviderContainer(overrides: engineOverrides(client));
    addTearDown(() async {
      container.dispose();
      await client.close();
    });
    final subscription = container.listen(engineSettingsProvider, (_, _) {});
    addTearDown(subscription.close);
    await client.mux.ready();
    final snapshot = (await container.read(engineSettingsProvider.future))!;
    final editor = container.read(engineSettingsProvider.notifier).edit(snapshot);
    client.mux.reconnect();
    expect(editor.active, isFalse);
    expect(await editor.set(defaultModelIdField, 'must-not-write'), isFalse);
    await client.mux.ready();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(editor.active, isFalse);
    expect(host.mutates(), isEmpty);
    expect(
      container.read(engineSettingsProvider.notifier).edit(container.read(engineSettingsProvider).value!).active,
      isTrue,
    );
  });

  test('pending model never follows host A -> B -> A', () async {
    final a = HostConnection(hostId: '', client: DshClient.withCarrier(FakeSettingsHost()), isLocal: true);
    final b = HostConnection(hostId: '', client: DshClient.withCarrier(FakeSettingsHost()), isLocal: true);
    final container = ProviderContainer(
      overrides: [
        ...engineOverrides(a.client).skip(1),
        _host.overrideWith((ref) => a),
        activeConnectionProvider.overrideWith((ref) => AsyncData(ref.watch(_host))),
        readListLiveConnectionProvider.overrideWith((ref) => ref.watch(_host)),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await a.client.close();
      await b.client.close();
    });
    final sub = container.listen(pendingModelProvider, (_, _) {});
    addTearDown(sub.close);
    final firstScope = container.read(modelSelectionScopeProvider);
    container.read(pendingModelProvider.notifier).select(const ModelSelection(provider: 'A', model: 'draft'));
    container.read(_host.notifier).state = b;
    expect(container.read(pendingModelProvider), isNull);
    container.read(_host.notifier).state = a;
    expect(container.read(pendingModelProvider), isNull);
    expect(identical(container.read(modelSelectionScopeProvider), firstScope), isFalse);
  });

  test('retained catalog cannot supply the effective default while new host loads', () async {
    final a = HostConnection(hostId: '', client: DshClient.withCarrier(FakeSettingsHost()), isLocal: true);
    final b = HostConnection(hostId: '', client: DshClient.withCarrier(FakeSettingsHost()), isLocal: true);
    final gate = Completer<ModelCatalog?>();
    final catalog = ModelCatalog.fromJson(sampleCatalog);
    final container = ProviderContainer(
      overrides: [
        ...engineOverrides(a.client).skip(1),
        _host.overrideWith((ref) => a),
        activeConnectionProvider.overrideWith((ref) => AsyncData(ref.watch(_host))),
        readListLiveConnectionProvider.overrideWith((ref) => ref.watch(_host)),
        modelCatalogProvider.overrideWith((ref) async => ref.watch(_host) == a ? catalog : gate.future),
      ],
    );
    addTearDown(() async {
      gate.complete(catalog);
      container.dispose();
      await a.client.close();
      await b.client.close();
    });
    final sub = container.listen(currentModelCatalogProvider, (_, _) {});
    addTearDown(sub.close);
    await container.read(modelCatalogProvider.future);
    expect(container.read(currentModelCatalogProvider), same(catalog));
    container.read(_host.notifier).state = b;
    expect(container.read(modelCatalogProvider).isLoading, isTrue);
    expect(container.read(currentModelCatalogProvider), isNull);
  });

  Future<FakeSettingsHost> pumpDefaults(
    WidgetTester tester, {
    bool mode = true,
    bool writable = true,
    String? effort,
  }) async {
    final host = FakeSettingsHost(
      describe: defaultsDescribe(mode: mode, baseEffort: effort),
      writable: writable,
    );
    final client = DshClient.withCarrier(host);
    addTearDown(client.close);
    await pumpPage(
      tester,
      const Scaffold(body: SingleChildScrollView(child: NewChatDefaultsCard())),
      overrides: engineOverrides(client),
    );
    return host;
  }

  testWidgets('mode change writes route effort and mode atomically, never the current session', (tester) async {
    final host = await pumpDefaults(tester);
    await tester.tap(find.text(appL10n.engineNewChatUseFixed));
    await flush(tester);
    expect(host.mutates(), hasLength(1));
    final mutation = host.mutates().single;
    expect(mutation['ns'], defaultModelSettingsNs);
    expect(mutation['expectedRevision'], 17);
    expect(mutation['ops'], [
      {
        'op': 'set',
        'path': ['provider'],
        'value': 'deepseek-official',
      },
      {
        'op': 'set',
        'path': ['model'],
        'value': 'deepseek-flash',
      },
      {
        'op': 'unset',
        'path': ['reasoningEffort'],
      },
      {
        'op': 'set',
        'path': ['rememberLastSelection'],
        'value': false,
      },
    ]);
    expect(host.calls.where((call) => call.$1 == 'session/selectModel'), isEmpty);
    expect(host.calls.where((call) => call.$1 == 'settings/describe').length, greaterThan(1));
    expect(find.text(appL10n.engineNewChatDefaultsFixed), findsOneWidget);
  });

  testWidgets('picker saves only after explicit confirmation', (tester) async {
    final host = await pumpDefaults(tester);
    await tester.tap(find.text('DeepSeek-V4.1-Flash'));
    await settle(tester);
    await tester.tap(find.text('My Gateway'));
    await settle(tester);
    await tester.tap(find.text('Qwen3 Coder'));
    await settle(tester);
    expect(host.mutates(), isEmpty);
    await tester.tap(find.text(appL10n.commonSave));
    await flush(tester);
    expect(host.mutates(), hasLength(1));
    expect(host.namespaces[defaultModelSettingsNs]!.value['model'], 'qwen3-coder');
    expect(host.calls.where((call) => call.$1 == 'session/selectModel'), isEmpty);
  });

  testWidgets('empty picker closes before managing providers and system back returns to the original page', (
    tester,
  ) async {
    final host = FakeSettingsHost(describe: defaultsDescribe())
      ..modelCatalog = {
        'default': {'provider': 'deepseek-official', 'model': 'deepseek-flash'},
        'routableProviders': <String>[],
        'groups': <Object?>[],
        'failures': [
          {'id': 'test-route', 'name': 'Test route', 'message': 'No models available for the configured route'},
        ],
      };
    await _pumpRemoteProviders(tester, host);
    final originalPage = tester.element(find.byType(ProvidersPage));

    await tester.tap(find.text('deepseek-official / deepseek-flash'));
    await settle(tester);
    expect(find.text(appL10n.viewModelManageProviders), findsOneWidget);
    await tester.tap(find.text(appL10n.viewModelManageProviders));
    await flush(tester);
    expect(find.byType(ProvidersPage), findsOneWidget);
    expect(find.byType(ProvidersPage, skipOffstage: false), findsNWidgets(2));

    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(tester.element(find.byType(ProvidersPage)), same(originalPage));
    expect(find.byType(BottomSheet, skipOffstage: false), findsNothing);
    expect(host.mutates(), isEmpty);
    expect(host.calls.where((call) => call.$1 == 'session/selectModel'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('populated picker resumes after model management and saves only on confirmation', (tester) async {
    final host = FakeSettingsHost(describe: defaultsDescribe());
    await _pumpRemoteProviders(tester, host);
    await tester.tap(find.text('DeepSeek-V4.1-Flash'));
    await settle(tester);
    await tester.tap(find.text('My Gateway'));
    await settle(tester);
    await tester.tap(find.text('Qwen3 Coder'));
    await settle(tester);
    await tester.tap(find.text(appL10n.nearbyManageModels));
    await flush(tester);
    expect(host.mutates(), isEmpty);

    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Qwen3 Coder'), findsOneWidget);
    expect(host.mutates(), isEmpty);
    await tester.tap(find.text(appL10n.commonSave));
    await flush(tester);
    expect(find.byType(BottomSheet, skipOffstage: false), findsNothing);
    expect(host.mutates(), hasLength(1));
    expect(host.namespaces[defaultModelSettingsNs]!.value['model'], 'qwen3-coder');
    expect(host.calls.where((call) => call.$1 == 'session/selectModel'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('base effort cannot be silently inherited by a non-thinking model', (tester) async {
    final host = await pumpDefaults(tester, effort: 'high');
    await tester.tap(find.text('DeepSeek-V4.1-Flash · ${appL10n.viewModelThinkingHigh}'));
    await settle(tester);
    await tester.tap(find.text('My Gateway'));
    await settle(tester);
    await tester.tap(find.text('Qwen3 Coder'));
    await settle(tester);
    await tester.tap(find.text(appL10n.commonSave));
    await flush(tester);
    expect(host.mutates(), isEmpty);
    expect(find.text(appL10n.engineNewChatDefaultsInheritedEffort), findsOneWidget);
    expect(host.namespaces[defaultModelSettingsNs]!.value['model'], 'deepseek-flash');
  });

  testWidgets('a picker left open on the old host cannot write the replacement host', (tester) async {
    final a = FakeSettingsHost(describe: defaultsDescribe());
    final aClient = DshClient.withCarrier(a);
    addTearDown(aClient.close);
    await pumpPage(
      tester,
      const Scaffold(body: SingleChildScrollView(child: NewChatDefaultsCard())),
      overrides: [
        ...engineOverrides(aClient).skip(1),
        _host.overrideWith((ref) => fakeConnection(aClient)),
        activeConnectionProvider.overrideWith((ref) => AsyncData(ref.watch(_host))),
      ],
    );
    await tester.tap(find.text('DeepSeek-V4.1-Flash'));
    await settle(tester);
    final b = FakeSettingsHost(describe: defaultsDescribe(revision: 40));
    final bClient = DshClient.withCarrier(b);
    addTearDown(bClient.close);
    final container = ProviderScope.containerOf(tester.element(find.byType(NewChatDefaultsCard)));
    container.read(_host.notifier).state = fakeConnection(bClient);
    await flush(tester);
    final save = tester.widget<FilledButton>(find.widgetWithText(FilledButton, appL10n.commonSave));
    expect(save.onPressed, isNull);
    expect(a.mutates(), isEmpty);
    expect(b.mutates(), isEmpty);
  });

  testWidgets('missing schema explicitly disables default editing', (tester) async {
    final host = FakeSettingsHost(describe: {'namespaces': <Object?>[]});
    final client = DshClient.withCarrier(host);
    addTearDown(client.close);
    await pumpPage(tester, const Scaffold(body: NewChatDefaultsCard()), overrides: engineOverrides(client));
    expect(find.text(appL10n.engineNewChatDefaultsUnsupported), findsOneWidget);
    expect(host.mutates(), isEmpty);
  });

  for (final removeWhileOpen in [false, true]) {
    testWidgets('confirmation rejects ${removeWhileOpen ? 'freshly removed' : 'initially invalid'} effort', (
      tester,
    ) async {
      final host = FakeSettingsHost(describe: defaultsDescribe(baseEffort: 'high'))
        ..modelCatalog = thinkingCatalog(high: removeWhileOpen);
      final client = DshClient.withCarrier(host);
      addTearDown(client.close);
      await tester.runAsync(() => client.mux.ready());
      await pumpPage(
        tester,
        const Scaffold(body: SingleChildScrollView(child: NewChatDefaultsCard())),
        overrides: engineOverrides(client),
      );
      if (!removeWhileOpen) {
        await tester.tap(find.text(appL10n.engineNewChatUseFixed));
        await flush(tester);
        expect(host.mutates(), isEmpty, reason: 'mode changes cannot rewrite an unavailable effort');
      }
      await tester.tap(find.text('DeepSeek-V4.1-Flash · ${appL10n.viewModelThinkingHigh}'));
      await settle(tester);
      if (removeWhileOpen) {
        expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, appL10n.commonSave)).onPressed, isNotNull);
        host.modelCatalog = thinkingCatalog(high: false);
        await tester.runAsync(() async {
          host.emit('settings/document-updated', ['llm-pi-ai', 1]);
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        await flush(tester);
        final container = ProviderScope.containerOf(tester.element(find.byType(NewChatDefaultsCard)));
        expect(container.read(currentModelCatalogProvider)!.models.single.efforts.map((effort) => effort.id), [
          'off',
          'low',
        ]);
      }
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, appL10n.commonSave)).onPressed, isNull);
      expect(find.text(appL10n.engineNewChatDefaultsSelectionUnavailable), findsWidgets);
      await tester.tap(find.text(appL10n.viewModelThinkingLow));
      await settle(tester);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, appL10n.commonSave)).onPressed, isNotNull);
      expect(host.mutates(), isEmpty);
      await tester.tap(find.text(appL10n.commonSave));
      await flush(tester);
      expect(host.mutates(), hasLength(1));
      expect(host.namespaces[defaultModelSettingsNs]!.value['reasoningEffort'], 'low');
      expect(host.namespaces[defaultModelSettingsNs]!.value['rememberLastSelection'], isTrue);
    });
  }

  testWidgets('legacy hosts expose last choice but no false fixed mode', (tester) async {
    await pumpDefaults(tester, mode: false);
    expect(find.text(appL10n.engineNewChatUseFixed), findsNothing);
    expect(find.text(appL10n.engineNewChatDefaultsLegacy), findsOneWidget);
  });

  testWidgets('read-only profile clearly disables default selection', (tester) async {
    final host = await pumpDefaults(tester, writable: false);
    expect(find.text(appL10n.engineProvidersReadOnly), findsOneWidget);
    await tester.tap(find.text('DeepSeek-V4.1-Flash'));
    await settle(tester);
    expect(find.text(appL10n.commonSave), findsNothing);
    expect(host.mutates(), isEmpty);
  });
}
