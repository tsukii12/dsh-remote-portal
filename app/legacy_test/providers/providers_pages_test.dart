// 模型渠道 list and 渠道详情: what each state shows, where taps go, delete
// with confirmation, the connection test, and measured row geometry.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/providers_state.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/common/page_hero.dart';
import 'package:dsh_app/ui/common/status_chip.dart';
import 'package:dsh_app/ui/providers/provider_detail_page.dart';
import 'package:dsh_app/ui/providers/provider_form_page.dart';
import 'package:dsh_app/ui/providers/provider_widgets.dart' show Monogram;
import 'package:dsh_app/ui/providers/providers_page.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart' show goldenApp, loadGoldenFonts;
import 'support.dart';

Future<void> _pump(WidgetTester tester, Widget home, List<Override> overrides) async {
  await tester.runAsync(loadGoldenFonts);
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(390 * 2, 1200 * 2);
  tester.view.padding = const FakeViewPadding(top: 64, bottom: 48);
  tester.view.viewPadding = const FakeViewPadding(top: 64, bottom: 48);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(goldenApp(home: home, brightness: Brightness.light, overrides: overrides));
  await settle(tester);
}

void main() {
  testWidgets('the settings hub has a 模型 row in AI', (tester) async {
    await _pump(tester, const SettingsScreen(), providerOverrides(sampleBackend()));
    await tester.scrollUntilVisible(find.text('模型'), 200);
    await settle(tester);
    final group = find.ancestor(of: find.text('模型'), matching: find.byType(Column));
    expect(find.descendant(of: group, matching: find.text('权限')), findsWidgets);
    await tester.tap(find.text('模型'));
    await settle(tester);
    expect(find.byType(ProvidersPage), findsOneWidget);
  });

  group('list', () {
    testWidgets('defaults first, then DeepSeek and each provider with its state, then 添加渠道', (tester) async {
      await _pump(tester, const ProvidersPage(), providerOverrides(sampleBackend(), account: signedInAccount));
      expect(find.text('4 个渠道 · 2 个可用'), findsOneWidget);
      expect(find.textContaining('新渠道的模型'), findsNothing);
      expect(find.text('账号 · 雾蓝'), findsOneWidget);
      expect(find.text('OpenAI 兼容 · 3 个模型'), findsOneWidget);
      expect(find.text('缺少 API Key'), findsOneWidget);
      expect(find.text('配置有误'), findsOneWidget);
      final dots = tester.widgetList<AnimatedStatusDot>(find.byType(AnimatedStatusDot)).map((d) => d.tone).toList();
      expect(dots, [StatusTone.ok, StatusTone.ok, StatusTone.warn, StatusTone.error]);
      final titles = [
        for (final row in tester.widgetList<ListPageRow>(find.byType(ListPageRow)))
          row.title ?? row.spot?.title(appL10n),
      ];
      expect(titles, [appL10n.viewModelSelect, 'DeepSeek', 'My Gateway', 'Claude 中转', '家里的 vLLM', '添加渠道']);

      await tester.tap(find.text('Claude 中转'));
      await settle(tester);
      expect(find.byType(ProviderDetailPage), findsOneWidget);
      expect(find.text('未设置'), findsWidgets);
      await tester.tap(find.byTooltip('返回'));
      await settle(tester);
      await tester.tap(find.text('添加渠道'));
      await settle(tester);
      expect(find.byType(ProviderFormPage), findsOneWidget);
    });

    testWidgets('a remote host: its own providers, DeepSeek from its catalog', (tester) async {
      await _pump(tester, const ProvidersPage(), [
        ...providerOverrides(sampleBackend(isLocal: false)),
        modelCatalogProvider.overrideWith(
          (ref) async => const ModelCatalog(
            defaultSelection: null,
            routableProviders: ['deepseek-official'],
            groups: [
              ProviderGroup('deepseek-official', 'DeepSeek', [
                ModelInfo(provider: 'deepseek-official', id: 'deepseek-v4-pro', name: 'DeepSeek-V4-Pro'),
              ]),
            ],
            failures: [],
          ),
        ),
      ]);
      expect(find.text('电脑 · SSH · 4 个渠道 · 2 个可用'), findsOneWidget);
      expect(find.text('已配置'), findsOneWidget);
      expect(tester.widget<ListPageRow>(find.widgetWithText(ListPageRow, 'DeepSeek')).onTap, isNull);
    });

    testWidgets('not connected, unsupported, read-only', (tester) async {
      await _pump(tester, const ProvidersPage(), providerOverrides(null));
      expect(find.text('没有连上引擎'), findsOneWidget);
      expect(find.text('DeepSeek'), findsWidgets, reason: 'the app-side DeepSeek row still shows');

      await _pump(tester, const ProvidersPage(), providerOverrides(FakeProviderBackend(supported: false)));
      expect(find.text('这台主机不支持自定义渠道'), findsOneWidget);

      await _pump(tester, const ProvidersPage(), providerOverrides(FakeProviderBackend(writable: false)));
      expect(tester.widget<ListPageRow>(find.widgetWithText(ListPageRow, '添加渠道')).onTap, isNull);
      expect(find.text('引擎设置是只读的，无法添加'), findsOneWidget);
    });

    testWidgets('geometry: both cards on one column, rows 52 / 64, dots aligned', (tester) async {
      await _pump(tester, const ProvidersPage(), providerOverrides(sampleBackend()));
      final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
      final cards = [
        for (final title in ['DeepSeek', 'My Gateway'])
          tester.getRect(find.ancestor(of: find.text(title), matching: find.byType(GlassSurface)).first),
      ];
      for (final card in cards) {
        expect(card.left, moreOrLessEquals(16, epsilon: 0.6));
        expect(width - card.right, moreOrLessEquals(16, epsilon: 0.6));
      }
      final rows = tester.widgetList<ListPageRow>(find.byType(ListPageRow)).toList();
      for (final row in rows) {
        final rect = tester.getRect(find.byWidget(row));
        final two = row.subtitle != null && row.subtitle!.isNotEmpty;
        if (row.subtitleMaxLines > 1) {
          // The new-defaults row explains disabled states on multiple lines;
          // provider rows below keep their existing 52/64dp anatomy.
          expect(rect.height, greaterThanOrEqualTo(64));
          continue;
        }
        expect(rect.height, moreOrLessEquals(two ? 64 : 52, epsilon: 0.6), reason: row.title);
      }
      final dots = [for (final e in find.byType(AnimatedStatusDot).evaluate()) tester.getRect(find.byWidget(e.widget))];
      for (final dot in dots.skip(1)) {
        expect(dot.right, moreOrLessEquals(dots.first.right, epsilon: 0.6));
      }
      // Every row leads with a 32 monogram tile 16 in; 「添加渠道」's glyph
      // shares the tiles' centre line.
      final tiles = [for (final e in find.byType(Monogram).evaluate()) tester.getRect(find.byWidget(e.widget))];
      expect(tiles, hasLength(4));
      for (final tile in tiles) {
        expect(tile.width, moreOrLessEquals(32, epsilon: 0.6));
        expect(tile.left - cards.first.left, moreOrLessEquals(16, epsilon: 0.6));
      }
      final add = tester.getRect(
        find.descendant(of: find.widgetWithText(ListPageRow, '添加渠道'), matching: find.byType(Icon)).first,
      );
      expect(add.center.dx, moreOrLessEquals(tiles.first.center.dx, epsilon: 0.6));
      expect(
        [for (final e in find.byType(Monogram).evaluate()) Monogram.letterOf((e.widget as Monogram).name)],
        ['D', 'M', 'C', '家'],
      );
    });
  });

  group('detail', () {
    testWidgets('test connection: listed count, or the reason in Chinese', (tester) async {
      final backend = sampleBackend()..discoverResult = discovered;
      await _pump(tester, const ProviderDetailPage(providerId: 'custom-mygw'), providerOverrides(backend));
      expect(find.text('可用 · gw.example.com'), findsOneWidget);
      await tester.tap(find.text('测试连接'));
      await settle(tester);
      expect(find.text('连接正常 · 列出 3 个模型'), findsOneWidget);

      backend.discoverError = DshRemoteException(
        'gateway/internal',
        'could not reach https://gw.example.com/v1/models',
      );
      await tester.tap(find.text('测试连接'));
      await settle(tester);
      expect(find.text('连不上这个地址，检查 Base URL 和网络'), findsOneWidget);
    });

    testWidgets('delete asks first, then removes the route and its key', (tester) async {
      final backend = sampleBackend();
      final vault = MemoryProviderKeyVault({'custom-mygw': 'sk-gw'});
      await _pump(
        tester,
        const ProviderDetailPage(providerId: 'custom-mygw'),
        providerOverrides(backend, vault: vault),
      );
      await tester.ensureVisible(find.text('删除渠道'));
      await tester.pump();
      await tester.tap(find.text('删除渠道'));
      await settle(tester);
      expect(find.text('删除「My Gateway」？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await settle(tester);
      expect(backend.callNames, isNot(contains('remove')));

      await tester.tap(find.text('删除渠道'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await settle(tester);
      expect(backend.callNames.where((c) => c != 'read'), ['remove', 'clearKey']);
      expect(vault.data, isEmpty);
    });

    testWidgets('a route set up in the web page: no edit, a note instead', (tester) async {
      await _pump(
        tester,
        const ProviderDetailPage(providerId: 'openai'),
        providerOverrides(
          FakeProviderBackend(
            profiles: const [ProviderProfile(route: 'openai', apiKeyEnv: 'OPENAI_API_KEY')],
          ),
        ),
      );
      expect(find.byTooltip('编辑'), findsNothing);
      expect(find.text('这个渠道在网页版里配置，这里只能查看和删除'), findsOneWidget);
    });

    testWidgets('missing key offers one primary edit action only when writable', (tester) async {
      await _pump(
        tester,
        const ProviderDetailPage(providerId: 'custom-claude-relay'),
        providerOverrides(sampleBackend()),
      );
      expect(find.widgetWithText(FilledButton, '填写 API Key'), findsOneWidget);
      final primary = tester.getRect(find.widgetWithText(FilledButton, '填写 API Key'));
      // The theme's primary-button height, like every other primary action.
      final theme = Theme.of(tester.element(find.byType(ProviderDetailPage)));
      expect(primary.height, theme.filledButtonTheme.style!.minimumSize!.resolve({})!.height);
      expect(primary.left, 16);
      expect(primary.right, 390 - 16);
      await tester.tap(find.text('填写 API Key'));
      await settle(tester);
      expect(find.byType(ProviderFormPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await _pump(
        tester,
        const ProviderDetailPage(providerId: 'custom-claude-relay'),
        providerOverrides(sampleBackend()..writable = false),
      );
      expect(find.byType(ProviderDetailPage), findsOneWidget);
      expect(find.byType(ProviderFormPage), findsNothing);
      expect(find.text('填写 API Key'), findsNothing);
    });

    testWidgets('read failures are distinct from offline', (tester) async {
      await _pump(tester, const ProviderDetailPage(providerId: 'custom-mygw'), [
        ...providerOverrides(sampleBackend()),
        customProvidersProvider.overrideWith((ref) async => throw StateError('raw-secret')),
      ]);
      expect(find.text('没能读取渠道'), findsOneWidget);
      expect(find.text('没有连上引擎'), findsNothing);
      expect(find.text('重试'), findsOneWidget);
      expect(find.textContaining('raw-secret'), findsNothing);
    });

    testWidgets('delete confirms in the danger colours', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 1200);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        goldenApp(
          home: const ProviderDetailPage(providerId: 'custom-mygw'),
          brightness: Brightness.dark,
          overrides: providerOverrides(sampleBackend()),
        ),
      );
      await settle(tester);
      await tester.ensureVisible(find.text('删除渠道'));
      await tester.tap(find.text('删除渠道'));
      await settle(tester);
      final finder = find.widgetWithText(FilledButton, '删除');
      final button = tester.widget<FilledButton>(finder);
      final colors = DshColors.of(tester.element(finder));
      expect(button.style!.backgroundColor!.resolve({}), colors.danger);
      expect(button.style!.foregroundColor!.resolve({}), colors.onDanger);
    });

    testWidgets('a provider that disappeared says so', (tester) async {
      await _pump(tester, const ProviderDetailPage(providerId: 'custom-gone'), providerOverrides(sampleBackend()));
      expect(find.text('这个渠道已不在'), findsOneWidget);
    });

    testWidgets('geometry: the two hero figures share the width', (tester) async {
      await _pump(tester, const ProviderDetailPage(providerId: 'custom-mygw'), providerOverrides(sampleBackend()));
      final stats = [for (final e in find.byType(HeroStat).evaluate()) tester.getRect(find.byWidget(e.widget))];
      expect(stats, hasLength(2));
      expect(stats[1].width, moreOrLessEquals(stats[0].width, epsilon: 0.6));
      expect(stats[0].center.dy, moreOrLessEquals(stats[1].center.dy, epsilon: 0.6));
    });
  });
}
