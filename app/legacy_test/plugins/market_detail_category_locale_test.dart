import 'dart:convert';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/ui/plugins/plugin_detail_sheet.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'support/fake_plugin_host.dart';

MarketCatalog _catalog(Map<String, Object?> data) => MarketCatalog(parseMarketIndex(data, Uri.parse(dshfindIndexUrl)));

void main() {
  setUpAll(loadTestFonts);
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  test('the same cached entry resolves categories in both UI languages', () {
    final entry = _catalog(sampleIndex).byName['novel-writer']!;
    expect(entry.categoryTitleIn('zh'), 'Agent 增强');
    expect(entry.categoryTitleIn('en'), 'Agent Boosters');
    expect(entry.categoryTitleIn('zh'), 'Agent 增强');
    // Preserve the legacy plain-label property and constructor contract.
    expect(entry.categoryTitle, 'Agent 增强');
  });

  test('plain-label callers and absent categories keep their fallback', () {
    final catalog = _catalog(sampleIndex);
    final legacy = MarketEntry(catalog.byName['novel-writer']!.plugin, webOnly: false, categoryTitle: 'custom label');
    expect(legacy.categoryTitleIn('en'), 'custom label');
    expect(legacy.categoryTitleIn('zh'), 'custom label');
    expect(catalog.byName['dsh-memory-lite']!.categoryTitleIn('en'), isNull);
  });

  test('merged catalog keeps the chosen entry original category declaration', () {
    final officialData = jsonDecode(jsonEncode(sampleIndex)) as Map<String, dynamic>;
    final metadata = officialData['metadata'] as Map<String, dynamic>;
    final categories = metadata['categories'] as Map<String, dynamic>;
    categories['agent'] = {
      'title': {'en': 'Official agents', 'zh': '官方智能体'},
    };
    final merged = MarketCatalog.merged(_catalog(sampleIndex), _catalog(officialData));
    expect(merged.byName['novel-writer']!.categoryTitleIn('en'), 'Official agents');
    expect(merged.byName['novel-writer']!.categoryTitleIn('zh'), '官方智能体');
  });

  testWidgets('detail header follows a locale switch with the same cached entry', (tester) async {
    final entry = _catalog(sampleIndex).byName['novel-writer']!;
    final carrier = FakePluginCarrier();
    carrier.handlers['pluginManager/listBundles'] = (_) => sampleBundles;
    final client = DshClient.withCarrier(carrier);
    addTearDown(client.close);
    usePhoneView(tester);

    Future<void> show(Locale locale) async {
      AppLocale.use(locale);
      await tester.pumpWidget(
        testApp(
          Builder(
            builder: (context) => Localizations.override(
              context: context,
              locale: locale,
              child: Scaffold(body: MarketPluginSheet(entry: entry)),
            ),
          ),
          overrides: pluginOverrides(fakeHost(client)),
        ),
      );
      await tester.pumpAndSettle();
    }

    await show(AppLocale.zhCN);
    expect(find.text('sailoumili · Agent 增强'), findsOneWidget);
    await show(AppLocale.en);
    expect(find.text('sailoumili · Agent Boosters'), findsOneWidget);
    expect(find.text('sailoumili · Agent 增强'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
