// A plugin's page in the official market: the link the detail sheet shares
// (`https://go.dshtui.com/p/<encoded name>`), and the same path coming back —
// as the web page's `dshgo://` hand-over or the https link itself — opening
// the plugin's detail sheet.

import 'dart:io';

import 'package:dsh_app/links/app_links.dart';
import 'package:dsh_app/links/plugin_links.dart';
import 'package:dsh_app/share_code/share_net.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/ui/plugins/plugin_detail_sheet.dart';
import 'package:dsh_app/ui/plugins/market_tab.dart';
import 'package:dsh_app/ui/plugins/plugins_screen.dart';
import 'package:dsh_app/ui/share_code/share_out.dart';
import 'package:dsh_app/ui/share/share_entry.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import '../plugins/support/fake_plugin_host.dart';
import '../share_code/support/fake_engine.dart' show FakeShareNet;
import '../share_code/support/sheet_support.dart' show RecordingShareOut;

void main() {
  group('the link', () {
    test('the package name is one encoded path segment', () {
      expect(marketPluginLink('@dsh-go/media'), 'https://go.dshtui.com/p/%40dsh-go%2Fmedia');
      expect(marketPluginLink('dsh-approval-gate'), 'https://go.dshtui.com/p/dsh-approval-gate');
    });

    test('image sharing keeps the official page and pinned install command', () {
      final entry = officialFixtureMarket().byName['@someone/dsh-weather']!;
      final text = pluginShareText(entry, webLink: marketPluginLink(entry.name));
      expect(text, contains('https://go.dshtui.com/p/%40someone%2Fdsh-weather'));
      expect(text, contains('@someone/dsh-weather@1.2.0'));
      expect(text, contains('天气'));
    });

    test('https and dshgo:// on the share host, encoded or not, name the package', () {
      for (final (link, name) in [
        ('https://go.dshtui.com/p/%40dsh-go%2Fmedia', '@dsh-go/media'),
        ('dshgo://go.dshtui.com/p/%40dsh-go%2Fmedia', '@dsh-go/media'),
        ('dshgo://go.dshtui.com/p/@dsh-go/media', '@dsh-go/media'),
        ('https://GO.DSHTUI.COM/p/dsh-approval-gate/', 'dsh-approval-gate'),
        (marketPluginLink('@someone/dsh-weather'), '@someone/dsh-weather'),
      ]) {
        expect(marketPluginLinkName(Uri.parse(link)), name, reason: link);
      }
    });

    test('anything else is not a plugin link', () {
      for (final link in [
        'http://go.dshtui.com/p/dsh-media',
        'https://example.com/p/dsh-media',
        'https://go.dshtui.com/c/a1B2c3D4e5',
        'https://go.dshtui.com/p',
        'https://go.dshtui.com/p/a/b/c',
        'https://go.dshtui.com/p/Not%20A%20Package',
        'https://me@go.dshtui.com/p/dsh-media',
        'https://go.dshtui.com:8443/p/dsh-media',
        'dshgo://share/p/dsh-media',
      ]) {
        expect(marketPluginLinkName(Uri.parse(link)), isNull, reason: link);
      }
    });
  });

  group('sharing', () {
    late FakePluginCarrier carrier;
    late DshClient client;
    late RecordingShareOut out;

    setUp(() {
      carrier = FakePluginCarrier();
      client = DshClient.withCarrier(carrier);
      carrier.handlers['pluginManager/listBundles'] = (_) => sampleBundles;
      out = RecordingShareOut(Directory.systemTemp);
    });
    tearDown(() => client.close());

    Future<void> openShare(WidgetTester tester, String title) async {
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          const PluginsScreen(initialTab: PluginsTab.market),
          overrides: [
            ...pluginOverrides(fakeHost(client), official: () async => officialFixtureMarket()),
            shareOutProvider.overrideWithValue(out),
            shareNetProvider.overrideWithValue(FakeShareNet()),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final card = find.widgetWithText(MarketCard, title);
      final scroll = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first;
      for (var i = 0; i < 15 && card.hitTestable().evaluate().isEmpty; i++) {
        await tester.drag(scroll, const Offset(0, -180));
        await tester.pumpAndSettle();
      }
      await tester.tap(card.hitTestable().first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('分享插件'));
      await tester.pumpAndSettle();
    }

    testWidgets('an official market plugin shares its market page', (tester) async {
      await openShare(tester, '天气');
      await tester.tap(find.byKey(const ValueKey('share-code-copy')));
      await tester.pumpAndSettle();
      expect(out.copied, ['https://go.dshtui.com/p/%40someone%2Fdsh-weather']);
      await tester.tap(find.byKey(const ValueKey('share-code-share')));
      await tester.pumpAndSettle();
      expect(out.sharedText.single, endsWith('\nhttps://go.dshtui.com/p/%40someone%2Fdsh-weather'));
    });

    testWidgets('a plugin only dshfind lists keeps the share-code link', (tester) async {
      await openShare(tester, 'novel-writer');
      await tester.tap(find.byKey(const ValueKey('share-code-copy')));
      await tester.pumpAndSettle();
      expect(out.copied.single, startsWith('https://go.dshtui.com/share/#p='));
    });
  });

  group('opening', () {
    late AppLinks links;
    late LinkRouter router;
    late FakePluginCarrier carrier;
    late DshClient client;

    setUp(() {
      carrier = FakePluginCarrier();
      client = DshClient.withCarrier(carrier);
      carrier.handlers['pluginManager/listBundles'] = (_) => sampleBundles;
    });
    tearDown(() {
      router.dispose();
      links.dispose();
      client.close();
    });

    // The real LinkHost wiring, in a home route.
    Future<void> pumpHome(WidgetTester tester, {OfficialMarketFetcher? official}) async {
      // Register the stream inside the widget test's clock/zone: its handler
      // awaits the catalogue before scheduling the detail sheet.
      links = AppLinks();
      router = LinkRouter(links.links, grace: Duration.zero);
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          const Scaffold(body: LinkHost()),
          overrides: [
            ...pluginOverrides(fakeHost(client), official: official ?? () async => officialFixtureMarket()),
            linkRouterProvider.overrideWithValue(router),
          ],
        ),
      );
      await tester.pump();
    }

    testWidgets('the web page hand-over opens the official entry', (tester) async {
      await pumpHome(tester);
      links.add(Uri.parse('dshgo://go.dshtui.com/p/%40dsh-go%2Fmedia'));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byType(MarketPluginSheet), findsOneWidget);
      expect(tester.widget<MarketPluginSheet>(find.byType(MarketPluginSheet)).entry.name, '@dsh-go/media');
      expect(find.text('生图生视频'), findsOneWidget);
    });

    testWidgets('an https link opens it too; a plugin only dshfind lists opens from dshfind', (tester) async {
      await pumpHome(tester);
      expect(await router.open(Uri.parse('https://go.dshtui.com/p/novel-writer')), isTrue);
      await tester.pumpAndSettle();
      expect(tester.widget<MarketPluginSheet>(find.byType(MarketPluginSheet)).entry.name, 'novel-writer');
    });

    testWidgets('the official index unreachable: dshfind still answers', (tester) async {
      await pumpHome(tester, official: () async => throw const MarketFetchException('offline'));
      expect(await router.open(Uri.parse('https://go.dshtui.com/p/dsh-memory-lite')), isTrue);
      await tester.pumpAndSettle();
      expect(tester.widget<MarketPluginSheet>(find.byType(MarketPluginSheet)).entry.name, 'dsh-memory-lite');
    });

    testWidgets('a plugin neither market lists: one line, no sheet', (tester) async {
      await pumpHome(tester);
      expect(await router.open(Uri.parse('dshgo://go.dshtui.com/p/nope')), isTrue);
      await tester.pumpAndSettle();
      expect(find.byType(MarketPluginSheet), findsNothing);
      expect(find.text('插件市场里没有 nope'), findsOneWidget);
    });
  });
}
