// The official plugin market (docs/design/plugin-market.md): the sidecar read
// leniently, the official entry winning over dshfind's, the three sections,
// risk tags and the confirm before a risky install, the integrity check, the
// minimum app version, 有更新 and withdrawn versions, and 提交插件. Fixtures
// in fixtures/official-index.json and fixtures/dsh-go.json follow §3.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/plugins/installed_tab.dart';
import 'package:dsh_app/ui/plugins/market_tab.dart';
import 'package:dsh_app/ui/plugins/plugin_detail_sheet.dart';
import 'package:dsh_app/ui/plugins/plugin_widgets.dart';
import 'package:dsh_app/ui/plugins/plugins_screen.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_app/update/version.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import 'support/fake_plugin_host.dart';

Map<String, Object?> _listing({
  String version = '1.0.0',
  Object? tier = 'community',
  Object? risk = const {'level': 'low', 'flags': <String>[]},
  Object? dshGo,
  Object? screenshots,
  Object? integrity,
}) => {
  'version': version,
  'tier': ?tier,
  'title': {'zh': '插件', 'en': 'Plugin'},
  'risk': ?risk,
  'dshGo': ?dshGo,
  'screenshots': ?screenshots,
  'integrity': ?integrity,
};

void main() {
  group('sidecar', () {
    test('reads the contract fixture', () {
      final sidecar = parseMarketSidecar(officialSidecarJson());
      expect(sidecar.issues, isEmpty);
      expect(sidecar.generatedAt, DateTime.utc(2026, 10, 30, 12));
      expect(sidecar.plugins.keys, [
        '@dsh-go/media',
        '@dsh-go/translate',
        '@someone/dsh-weather',
        '@acme/dsh-native-helper',
        'dsh-approval-gate',
      ]);
      final media = sidecar.plugins['@dsh-go/media']!;
      expect(media.version, '0.2.0');
      expect(media.tier, MarketTier.official);
      expect(media.title!.resolve('zh'), '生图生视频');
      expect(media.summary!.resolve('en'), startsWith('Generate images'));
      expect(media.screenshots, hasLength(2));
      expect(media.adapted, isTrue);
      expect(media.minApp, AppVersion.tryParse('1.0.2'));
      expect(media.features, ['native-cards', 'settings-page', 'media']);
      expect(media.risk, MarketRisk.low);
      expect(media.flags, ['network']);
      expect(media.integrity, startsWith('sha512-'));
      expect(media.checkedAt, DateTime.utc(2026, 10, 30, 11, 58));
      expect(media.blockedVersions, isEmpty);
      // Only https screenshots.
      expect(sidecar.plugins['@someone/dsh-weather']!.screenshots.map((u) => u.toString()), [
        'https://example.com/weather-1.png',
        'https://example.com/weather-2.png',
      ]);
      expect(sidecar.plugins['dsh-approval-gate']!.blockedVersions, {'0.3.0'});
    });

    test('a malformed entry is skipped; the rest still count', () {
      final sidecar = parseMarketSidecar({
        'schema': 1,
        'plugins': {
          'ok': _listing(),
          'not-a-map': 'nope',
          'bad-version': _listing(version: 'latest'),
          'bad-tier': _listing(tier: 'gold'),
          'no-tier': _listing(tier: null),
          'no-risk': _listing(risk: null),
          'bad-level': _listing(risk: {'level': 'severe', 'flags': <String>[]}),
          'bad-flags': _listing(risk: {'level': 'low', 'flags': 'shell'}),
          'bad-min-app': _listing(dshGo: {'adapted': true, 'minApp': 'soon'}),
          'loose': _listing(
            screenshots: [for (var i = 0; i < 6; i++) 'https://example.com/$i.png', 42, 'ftp://x/y.png'],
            integrity: 'md5-abc',
            dshGo: {'adapted': 'yes', 'features': 'cards'},
          ),
        },
      });
      expect(sidecar.plugins.keys, ['ok', 'loose']);
      expect(sidecar.issues.map((i) => i.path), [
        r'$.plugins.not-a-map',
        r'$.plugins.bad-version',
        r'$.plugins.bad-tier',
        r'$.plugins.no-tier',
        r'$.plugins.no-risk',
        r'$.plugins.bad-level',
        r'$.plugins.bad-flags',
        r'$.plugins.bad-min-app',
      ]);
      // Optional members that don't qualify are dropped, the entry kept.
      final loose = sidecar.plugins['loose']!;
      expect(loose.screenshots, hasLength(maxMarketScreenshots));
      expect(loose.integrity, isNull);
      expect(loose.adapted, isFalse);
      expect(loose.features, isEmpty);
    });

    test('the level is never below its flags', () {
      MarketRisk of(String level, List<String> flags) => parseMarketSidecar({
        'schema': 1,
        'plugins': {
          'p': _listing(risk: {'level': level, 'flags': flags}),
        },
      }).plugins['p']!.risk;
      expect(of('low', ['install-scripts']), MarketRisk.high);
      expect(of('low', ['network', 'shell']), MarketRisk.medium);
      expect(of('high', ['network']), MarketRisk.high);
      // A flag this app doesn't know keeps the declared level.
      expect(of('medium', ['crypto-miner']), MarketRisk.medium);
    });

    test('not a schema-1 sidecar at all throws', () {
      expect(() => parseMarketSidecar({'schema': 2, 'plugins': {}}), throwsA(isA<MarketIndexException>()));
      expect(() => parseMarketSidecar({'schema': 1, 'plugins': []}), throwsA(isA<MarketIndexException>()));
      expect(() => parseMarketSidecar([]), throwsA(isA<MarketIndexException>()));
      expect(() => parseMarketSidecarText('<html>'), throwsA(isA<MarketIndexException>()));
    });
  });

  group('official market', () {
    test('sections from the tier and the protocol declaration', () {
      final official = officialFixtureMarket();
      List<String> names(MarketSection s, [String query = '']) => [
        for (final e in marketSection(official, s, MarketFilter(query: query))) e.name,
      ];
      expect(names(MarketSection.official), ['@dsh-go/media', '@dsh-go/translate']);
      expect(names(MarketSection.adapted), ['@someone/dsh-weather', '@acme/dsh-native-helper']);
      // Not adapted: only under 全部.
      expect(official.byName['dsh-approval-gate']!.section, isNull);
      // The search box reaches the sidecar's titles too.
      expect(names(MarketSection.adapted, '天气'), ['@someone/dsh-weather']);
      expect(names(MarketSection.official, '天气'), isEmpty);
      expect(official.byName['@dsh-go/media']!.title('en'), 'Images & video');
      expect(official.byName['@dsh-go/media']!.summary(), startsWith('在对话里用即梦'));
    });

    test('a sidecar entry for another version is ignored', () {
      final sidecar = officialSidecarJson();
      ((sidecar['plugins']! as Map)['@someone/dsh-weather'] as Map)['version'] = '1.1.0';
      final official = officialFixtureMarket(sidecar: sidecar);
      expect(official.byName['@someone/dsh-weather']!.listing, isNull);
      expect(marketSection(official, MarketSection.adapted, const MarketFilter()).map((e) => e.name), [
        '@acme/dsh-native-helper',
      ]);
    });

    test('全部: the official entry wins for the same package; the others are added', () {
      final all = MarketCatalog(parseMarketIndex(sampleIndex, Uri.parse(dshfindIndexUrl)));
      final merged = MarketCatalog.merged(all, officialFixtureMarket());
      expect(merged.entries.map((e) => e.name), [
        'novel-writer',
        'dsh-approval-gate',
        'dsh-pink-skin',
        'dsh-memory-lite',
        '@dsh-go/media',
        '@dsh-go/translate',
        '@someone/dsh-weather',
        '@acme/dsh-native-helper',
      ]);
      final gate = merged.byName['dsh-approval-gate']!;
      expect(gate.listing, isNotNull);
      expect(gate.plugin.versions.map((v) => v.version), ['0.4.0'], reason: 'the pinned version only');
      expect(merged.byName['novel-writer']!.listing, isNull);
      // dshfind's categories still drive the chips.
      expect(merged.categories.map((c) => c.id), containsAll(['agent', 'tools']));
    });

    test('fetch: 404 is an empty market, other failures fail, a missing sidecar leaves no tiers', () async {
      SharedPreferences.setMockInitialValues({});
      final index = jsonEncode(officialIndexJson());
      final sidecar = jsonEncode(officialSidecarJson());
      Never http(int status) => throw MarketFetchException('HTTP $status', statusCode: status);
      // Both bases answer alike; [sidecarOf] stands in for dsh-go.json.
      MarketFileFetcher serve({Object? indexOf, Object? sidecarOf}) => (url, {etag}) async {
        final body = url.path.endsWith('index.json') ? indexOf : sidecarOf;
        if (body is Never Function()) body();
        return (text: body as String, etag: null);
      };

      final full = await fetchOfficialMarket(get: serve(indexOf: index, sidecarOf: sidecar), refresh: true);
      expect(full.byName['@dsh-go/media']!.section, MarketSection.official);
      SharedPreferences.setMockInitialValues({});

      final unpublished = await fetchOfficialMarket(get: serve(indexOf: () => http(404), sidecarOf: () => http(404)));
      expect(unpublished.entries, isEmpty);

      await expectLater(
        fetchOfficialMarket(get: serve(indexOf: () => http(503), sidecarOf: sidecar)),
        throwsA(isA<MarketFetchException>().having((e) => e.statusCode, 'status', 503)),
      );
      await expectLater(
        fetchOfficialMarket(get: serve(indexOf: () => throw const MarketFetchException('offline'), sidecarOf: sidecar)),
        throwsA(isA<MarketFetchException>()),
      );
      // The sidecar unreachable: an error, not 暂无.
      await expectLater(
        fetchOfficialMarket(get: serve(indexOf: index, sidecarOf: () => throw const MarketFetchException('offline'))),
        throwsA(isA<MarketFetchException>()),
      );
      for (final missing in <Object>[() => http(404), '{"schema": 2}']) {
        final bare = await fetchOfficialMarket(get: serve(indexOf: index, sidecarOf: missing));
        expect(bare.entries, hasLength(5));
        expect(bare.entries.every((e) => e.listing == null && e.section == null), isTrue);
      }
    });

    test('the install request pins name@version and carries the integrity', () {
      final media = officialFixtureMarket().byName['@dsh-go/media']!;
      final request = marketInstallRequest(media);
      expect(request.spec, '@dsh-go/media@0.2.0');
      expect(request.title, '生图生视频');
      expect(request.integrity?.version, '0.2.0');
      expect(request.integrity?.integrity, media.listing!.integrity);
      expect(request.withApprovedBuilds(['esbuild']).integrity, request.integrity);
      expect(marketInstallRequest(media, replace: true).replaceInstalled, isTrue);
    });

    test('minApp: shown to older apps but not installable', () {
      final official = officialFixtureMarket();
      final app = AppVersion.tryParse('1.0.2+1')!;
      expect(marketNeedsApp(official.byName['@dsh-go/media']!, app), isNull, reason: 'minApp 1.0.2 == the app');
      expect(marketNeedsApp(official.byName['@dsh-go/translate']!, app), AppVersion.tryParse('9.0.0'));
      expect(marketNeedsApp(official.byName['@acme/dsh-native-helper']!, app), isNull, reason: 'no minApp');
      expect(marketNeedsApp(official.byName['@dsh-go/media']!, AppVersion.tryParse('1.0.1')!), isNotNull);
    });

    test('a withdrawn version is the installed one, listed in blockedVersions', () {
      final gate = officialFixtureMarket().byName['dsh-approval-gate']!;
      PluginBundle bundle(String version, {bool installed = true}) =>
          PluginBundle.fromJson(bundleJson('dsh-approval-gate', version: version, installed: installed));
      expect(marketBlockedInstall(gate, bundle('0.3.0')), isTrue);
      expect(marketBlockedInstall(gate, bundle('0.4.0')), isFalse);
      expect(marketBlockedInstall(gate, null), isFalse);
      expect(marketInstallStatus(gate.plugin, [bundle('0.3.0')]), MarketInstallStatus.updateAvailable);
    });
  });

  group('market page', () {
    late FakePluginCarrier carrier;
    late DshClient client;
    late List<(String, String)> npmAsked;

    setUp(() {
      carrier = FakePluginCarrier();
      client = DshClient.withCarrier(carrier);
      carrier.handlers['pluginManager/listBundles'] = (_) => sampleBundles;
      npmAsked = [];
    });
    tearDown(() => client.close());

    Future<void> pumpScreen(
      WidgetTester tester, {
      PluginsTab tab = PluginsTab.market,
      OfficialMarketFetcher? official,
      FutureOr<String?> Function(String name, String version)? npm,
    }) async {
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          PluginsScreen(initialTab: tab),
          overrides: pluginOverrides(
            fakeHost(client),
            official: official ?? () async => officialFixtureMarket(),
            npmIntegrity: (name, version) async {
              npmAsked.add((name, version));
              return npm == null ? officialFixtureMarket().byName[name]?.listing?.integrity : npm(name, version);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Finder card(String title) => find.widgetWithText(MarketCard, title).first;

    Finder inCard(String title, String text) => find.descendant(of: card(title), matching: find.text(text));

    Future<void> openSheet(WidgetTester tester, String title) async {
      final target = find.widgetWithText(MarketCard, title).hitTestable();
      final scroll = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first;
      for (var i = 0; i < 15 && target.evaluate().isEmpty; i++) {
        await tester.drag(scroll, const Offset(0, -180));
        await tester.pumpAndSettle();
      }
      await tester.tap(target.first);
      await tester.pumpAndSettle();
    }

    Finder sheetButton(String label) => find.widgetWithText(FilledButton, label).last;

    Finder inDialog(String text) => find.descendant(of: find.byType(AlertDialog), matching: find.text(text));

    // The page's own vertical scroll (the category chips scroll sideways).
    final page = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first;
    final sheetList = find.descendant(of: find.byType(MarketPluginSheet), matching: find.byType(Scrollable)).first;

    testWidgets('three sections; cards carry the section and the risk', (tester) async {
      await pumpScreen(tester);
      for (final title in ['官方', '适配 DSH Go', '全部']) {
        expect(find.widgetWithText(Semantics, title), findsWidgets, reason: title);
      }
      expect(inCard('生图生视频', '官方'), findsOneWidget);
      expect(inCard('生图生视频', '中风险'), findsNothing, reason: 'low risk shows no tag');
      expect(inCard('天气', '适配 DSH Go'), findsOneWidget);
      expect(inCard('天气', '中风险'), findsOneWidget);
      expect(inCard('原生助手', '高风险'), findsOneWidget);
      // The tags' colours: amber for medium, red for high.
      final colors = DshColors.of(tester.element(card('天气')));
      Color fill(String text) {
        final box = tester.widget<DecoratedBox>(
          find.ancestor(of: find.text(text).first, matching: find.byType(DecoratedBox)).first,
        );
        return (box.decoration as ShapeDecoration).color!;
      }

      expect(fill('中风险'), colors.warningContainer);
      expect(fill('高风险'), colors.dangerContainer);
      // dshfind's list follows under 全部, the official entry in place of its own.
      await tester.scrollUntilVisible(find.widgetWithText(MarketCard, '危险命令审批'), 200, scrollable: page);
      expect(inCard('危险命令审批', '更新'), findsOneWidget);
    });

    testWidgets('searching hides an official section with nothing to show', (tester) async {
      await pumpScreen(tester);
      await tester.enterText(find.byType(TextField), '天气');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('官方'), findsNothing);
      expect(find.text('适配 DSH Go'), findsWidgets);
      expect(card('天气'), findsOneWidget);
    });

    testWidgets('not published yet (404): the official sections say 暂无, 全部 works', (tester) async {
      await pumpScreen(tester, official: () async => emptyOfficialMarket);
      expect(find.text('暂无'), findsNWidgets(2));
      expect(card('novel-writer'), findsOneWidget);
    });

    testWidgets('unreachable: the official sections say so with 重试, 全部 works', (tester) async {
      var attempts = 0;
      await pumpScreen(
        tester,
        official: () async {
          if (attempts++ == 0) throw const MarketFetchException('没能连上插件目录');
          return officialFixtureMarket();
        },
      );
      expect(find.text('官方目录没打开'), findsNWidgets(2));
      expect(card('novel-writer'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '重试').first);
      await tester.pumpAndSettle();
      expect(card('生图生视频'), findsOneWidget);
    });

    testWidgets('a medium risk asks first, listing its flags; 取消 installs nothing', (tester) async {
      carrier.handlers['pluginManager/installBundle'] = (_) => installResult(target: '@someone/dsh-weather');
      await pumpScreen(tester);
      await openSheet(tester, '天气');
      // The detail: every flag in plain words, and the note.
      expect(find.text('自动检查'), findsOneWidget);
      expect(find.text('代码里会调用系统命令（child_process）'), findsOneWidget);
      expect(find.textContaining('自动检查发现的特征，不代表插件有恶意'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('锁定版本'), 200, scrollable: sheetList);

      await tester.tap(sheetButton('安装到本机'));
      await tester.pumpAndSettle();
      expect(find.text('「天气」有风险特征'), findsOneWidget);
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('执行命令')), findsOneWidget);
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('联网')), findsOneWidget);
      expect(inDialog('自动检查发现的特征，不代表插件有恶意'), findsOneWidget);
      await tester.tap(inDialog('取消'));
      await tester.pumpAndSettle();
      expect(carrier.argsOf('pluginManager/installBundle'), isEmpty);

      await tester.tap(sheetButton('安装到本机'));
      await tester.pumpAndSettle();
      await tester.tap(inDialog('仍然安装'));
      await tester.pumpAndSettle();
      expect(carrier.argsOf('pluginManager/installBundle').single['spec'], '@someone/dsh-weather@1.2.0');
      expect(npmAsked, [('@someone/dsh-weather', '1.2.0')]);
    });

    testWidgets('a high risk confirms with the danger colour', (tester) async {
      await pumpScreen(tester);
      await openSheet(tester, '原生助手');
      await tester.tap(sheetButton('安装到本机'));
      await tester.pumpAndSettle();
      expect(find.text('「原生助手」有风险特征'), findsOneWidget);
      final confirm = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '仍然安装'));
      final colors = DshColors.of(tester.element(find.byType(AlertDialog)));
      expect(confirm.style?.backgroundColor?.resolve({}), colors.danger);
    });

    testWidgets('low risk installs the pinned version straight away, once npm agrees', (tester) async {
      final npm = Completer<String?>();
      carrier.handlers['pluginManager/installBundle'] = (_) => installResult(target: '@dsh-go/media');
      final media = officialFixtureMarket().byName['@dsh-go/media']!;
      await pumpScreen(tester, npm: (_, _) => npm.future);
      await openSheet(tester, '生图生视频');
      await tester.tap(sheetButton('安装到本机'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('正在核对版本…'), findsOneWidget);
      expect(carrier.argsOf('pluginManager/installBundle'), isEmpty, reason: 'nothing runs before the check');

      npm.complete(media.listing!.integrity);
      await tester.pumpAndSettle();
      expect(npmAsked, [('@dsh-go/media', '0.2.0')]);
      expect(carrier.argsOf('pluginManager/installBundle').single['spec'], '@dsh-go/media@0.2.0');
    });

    testWidgets('npm reporting another integrity stops the install', (tester) async {
      await pumpScreen(tester, npm: (_, _) => 'sha512-c29tZXRoaW5nIGVsc2U=');
      await openSheet(tester, '生图生视频');
      await tester.tap(sheetButton('安装到本机'));
      await tester.pumpAndSettle();
      expect(carrier.argsOf('pluginManager/installBundle'), isEmpty);
      expect(find.text('版本校验不一致'), findsWidgets);
      expect(find.textContaining('npm 上的 0.2.0 和插件市场检查过的不是同一个包'), findsOneWidget);
    });

    testWidgets('npm not answering: installation stops with a retryable explanation', (tester) async {
      carrier.handlers['pluginManager/installBundle'] = (_) => installResult(target: '@dsh-go/media');
      await pumpScreen(tester, npm: (_, _) => null);
      await openSheet(tester, '生图生视频');
      await tester.tap(sheetButton('安装到本机'));
      await tester.pumpAndSettle();
      expect(carrier.argsOf('pluginManager/installBundle'), isEmpty);
      expect(find.text('暂时无法核对版本'), findsWidgets);
    });

    testWidgets('an app older than minApp shows the plugin but no install', (tester) async {
      await pumpScreen(tester);
      await openSheet(tester, '同声翻译');
      final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '需要 DSH Go 9.0.0 或更高版本'));
      expect(button.onPressed, isNull);
      expect(find.text('需要 DSH Go'), findsOneWidget);
      expect(find.text('安装到本机'), findsNothing);
    });

    testWidgets('提交插件 opens the submission guide', (tester) async {
      final launched = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/url_launcher'),
        (call) async {
          launched.add((call.arguments as Map)['url']);
          return true;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/url_launcher'),
          null,
        ),
      );
      await pumpScreen(tester);
      await tester.scrollUntilVisible(find.text('提交插件'), 400, scrollable: page);
      await tester.tap(find.text('提交插件'));
      await tester.pumpAndSettle();
      expect(launched, [Uri.parse(marketSubmitUrl).toString()]);
      expect(Uri.decodeComponent(Uri.parse(launched.single! as String).fragment), '提交插件');
    });

    group('updates and withdrawn versions', () {
      setUp(() {
        carrier.handlers['pluginManager/listBundles'] = (_) => [
          ...sampleBundles,
          bundleJson('@someone/dsh-weather', version: '1.1.0', title: {'zh': '天气', 'en': 'Weather'}),
        ];
      });

      Finder tile(String title) => find.widgetWithText(BundleTile, title);

      testWidgets('已安装: 有更新, and 已下架 with the warning', (tester) async {
        await pumpScreen(tester, tab: PluginsTab.installed);
        expect(find.descendant(of: tile('天气'), matching: find.text('有更新')), findsOneWidget);
        expect(find.descendant(of: tile('dsh-approval-gate'), matching: find.text('已下架')), findsOneWidget);
        expect(find.descendant(of: tile('dsh-approval-gate'), matching: find.text('此版本已下架，建议卸载')), findsOneWidget);
        expect(find.descendant(of: tile('dsh-approval-gate'), matching: find.text('有更新')), findsNothing);
      });

      testWidgets('the installed detail: the warning, 卸载, and 有更新 to the market', (tester) async {
        await pumpScreen(tester, tab: PluginsTab.installed);
        await tester.tap(tile('dsh-approval-gate'));
        await tester.pumpAndSettle();
        expect(find.text('这个版本已下架'), findsOneWidget);
        expect(find.text('已安装的 0.3.0 已从插件市场下架，建议卸载'), findsOneWidget);
        expect(find.widgetWithText(OutlinedButton, '卸载'), findsOneWidget);
        await tester.tap(
          find.descendant(of: find.byType(BundleSheet), matching: find.widgetWithText(ListPageRow, '有更新')),
        );
        await tester.pumpAndSettle();
        expect(find.widgetWithText(FilledButton, '更新到 0.4.0'), findsOneWidget);
      });

      testWidgets('the market detail: 有更新, the warning with 卸载', (tester) async {
        await pumpScreen(tester);
        await tester.scrollUntilVisible(find.widgetWithText(MarketCard, '危险命令审批'), 200, scrollable: page);
        await openSheet(tester, '危险命令审批');
        expect(find.descendant(of: find.byType(PluginBadge), matching: find.text('有更新')), findsOneWidget);
        expect(find.text('这个版本已下架'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, '卸载'));
        await tester.pumpAndSettle();
        expect(find.text('卸载「dsh-approval-gate」？'), findsOneWidget);
      });
    });
  });
}
