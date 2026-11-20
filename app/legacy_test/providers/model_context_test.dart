// 订阅渠道模型的「上下文长度」：目录给的值不对时（例如 GPT-6.1 Sol 的目录写
// 500K），用户可以在订阅详情里给单个模型覆盖——写到
// `llm-pi-ai.providers.<route>.modelOverrides.<modelId>`，引擎下一请求就按新值
// 计算上下文占用与压缩。留空 = 回到目录值。

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/ui/providers/model_context_page.dart';
import 'package:dsh_app/ui/providers/subscription_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart' show goldenApp, loadGoldenFonts;
import 'support.dart';

const _codexModels = [
  ModelInfo(provider: 'openai-codex', id: 'gpt-6.1-sol', name: 'GPT-6.1 Sol'),
  ModelInfo(provider: 'openai-codex', id: 'gpt-5.6-sol', name: 'GPT-5.6 Sol'),
];

const _catalog = ModelCatalog(
  defaultSelection: null,
  routableProviders: [],
  groups: [ProviderGroup('openai-codex', 'ChatGPT', _codexModels)],
  failures: [],
);

void main() {
  /// The ChatGPT page on a fake engine whose route already has [overrides].
  Future<FakeProviderBackend> pumpPage(
    WidgetTester tester, {
    Map<String, ModelOverride> overrides = const {},
  }) async {
    await tester.runAsync(loadGoldenFonts);
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(780, 1800);
    addTearDown(tester.view.reset);
    final backend = FakeProviderBackend(
      profiles: [ProviderProfile(route: 'openai-codex', displayName: 'ChatGPT', modelOverrides: overrides)],
    );
    await tester.pumpWidget(
      goldenApp(
        home: const SubscriptionPage(subscription: Subscription.chatgpt),
        brightness: Brightness.light,
        overrides: [
          ...providerOverrides(
            backend,
            subscriptions: FakeSubscriptionBackend(
              statuses: const [SubscriptionStatus(subscription: Subscription.chatgpt, signedIn: true)],
            ),
          ),
          modelCatalogProvider.overrideWith((ref) async => _catalog),
        ],
      ),
    );
    await settle(tester);
    return backend;
  }

  testWidgets('a model row shows its override, and "default" when it has none', (tester) async {
    await pumpPage(tester, overrides: const {'gpt-6.1-sol': ModelOverride(contextWindow: 1000000)});
    expect(find.text('GPT-6.1 Sol'), findsOneWidget);
    expect(find.text('GPT-5.6 Sol'), findsOneWidget);
    expect(find.text('1M'), findsOneWidget, reason: 'the overridden context length, in token terms');
    expect(find.text(appL10n.commonDefault), findsOneWidget, reason: 'the other model still follows the catalog');
    expect(tester.takeException(), isNull);
  });

  testWidgets('picking a size writes modelOverrides for that model', (tester) async {
    final backend = await pumpPage(tester);
    await tester.tap(find.text('GPT-5.6 Sol'));
    await settle(tester);
    expect(find.byType(ModelContextPage), findsOneWidget);
    await tester.enterText(find.byType(TextField), '1.5M');
    await tester.pump();
    await tester.tap(find.text(appL10n.commonSave));
    await settle(tester);
    expect(find.byType(ModelContextPage), findsNothing, reason: 'saved, back to the subscription');
    final call = backend.calls.lastWhere((c) => c.$1 == 'setModelOverride');
    expect(call.$2['route'], 'openai-codex');
    expect(call.$2['modelId'], 'gpt-5.6-sol');
    expect(call.$2['override'], {'contextWindow': 1500000});
  });

  testWidgets('clearing the field drops the override; the last one drops the dict too', (tester) async {
    final backend = await pumpPage(tester, overrides: const {'gpt-6.1-sol': ModelOverride(contextWindow: 1000000)});
    await tester.tap(find.text('GPT-6.1 Sol'));
    await settle(tester);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, '1M', reason: 'the editor opens on the stored override');
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    await tester.tap(find.text(appL10n.commonSave));
    await settle(tester);
    final call = backend.calls.lastWhere((c) => c.$1 == 'clearModelOverride');
    expect(call.$2['route'], 'openai-codex');
    expect(call.$2['modelId'], 'gpt-6.1-sol');
    expect(call.$2['last'], isTrue, reason: 'it was the route\'s only override');
  });

  testWidgets('a value that is not a token count is refused before the wire', (tester) async {
    final backend = await pumpPage(tester);
    await tester.tap(find.text('GPT-5.6 Sol'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), '..');
    await tester.pump();
    await tester.tap(find.text(appL10n.commonSave));
    await settle(tester);
    expect(find.byType(ModelContextPage), findsOneWidget, reason: 'stays open with the error');
    expect(find.text(appL10n.stateProviderTokenCountInvalid), findsOneWidget);
    expect(backend.calls.where((c) => c.$1 == 'setModelOverride'), isEmpty);
  });
}
