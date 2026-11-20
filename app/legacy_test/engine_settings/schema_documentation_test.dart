import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/ui/engine_settings/engine_settings_page.dart';
import 'package:dsh_app/ui/engine_settings/schema_documentation.dart';
import 'package:dsh_app/ui/engine_settings/schema_fields.dart' show FieldCopy, hintFor, labelFor, plainSchemaText;
import 'package:dsh_app/ui/plugins/plugin_inventory_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import 'form_catalog_scenarios.dart';
import 'support.dart';
import '../shell/golden_harness.dart' show goldenApp;

class NoNetwork extends HttpOverrides {
  int requests = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    requests++;
    throw StateError('documentation must not create a network client');
  }
}

/// The heading the sheet shows for the entry at [path], in the current locale.
String heading(String fixture, String path) =>
    schemaDocumentation(SchemaNode.fromJson(catalogFixture(fixture)), 'en').singleWhere((e) => e.path == path).heading;

void main() {
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  test('headings name the place in words, never the raw schema path', () {
    const voice = 'goodandready-dsh-voice-0.9.42';
    expect(heading(voice, r'$.hotkey'), 'Hotkey');
    expect(heading(voice, r'$.dictation.chain[].provider'), 'Dictation › Chain › 每一项 › ${appL10n.engineFieldService}');
    final all = [
      for (final fixture in [voice, 'schemastery-description'])
        ...schemaDocumentation(SchemaNode.fromJson(catalogFixture(fixture)), 'en'),
    ];
    expect(all.where((e) => e.path == r'$').map((e) => e.heading), everyElement('概述'));
    expect(all.map((e) => e.heading).where((h) => h.contains(r'$') || h.contains('variant')), isEmpty);
    AppLocale.use(AppLocale.en);
    expect(heading(voice, r'$.dictation.chain[].provider'), startsWith('Dictation › Chain › Each item › '));
  });

  test('documentation toolbar title follows the generated app locale', () {
    AppLocale.use(AppLocale.en);
    expect(schemaDocumentationLabel, 'Field descriptions');
    AppLocale.use(AppLocale.zhCN);
    expect(schemaDocumentationLabel, '字段说明');
  });

  test('a row reads a Markdown description as plain text; the sheet keeps the Markdown', () {
    expect(plainSchemaText('**按住快捷键**开始录音。'), '按住快捷键开始录音。');
    expect(plainSchemaText('Use `Control` or [the guide](https://example.test/keys).'), 'Use Control or the guide.');
    expect(plainSchemaText('- __Hold__ to talk'), 'Hold to talk');
    expect(plainSchemaText('2 * 3 = 6, a_b_c'), '2 * 3 = 6, a_b_c');
    final hotkey = SchemaNode.fromJson(catalogFixture('schemastery-description')).dict['hotkey']!;
    // Its first sentence names the field; the list under it is the hint.
    expect(labelFor('hotkey', hotkey, const FieldCopy()), '按住快捷键开始录音');
    expect(hintFor(hotkey, const FieldCopy()), '松开后发送。');
    expect(hintFor(hotkey, const FieldCopy(label: '快捷键')), '按住快捷键开始录音。');
  });

  test('raw nested intersect and transform documentation keeps every visible structural layer', () {
    final fixtures = catalogFixture('schemastery-description-structure') as Map;
    List<String?> docs(String name) =>
        schemaDocumentation(SchemaNode.fromJson(fixtures[name]), 'en').map((e) => e.description).toList();
    expect(docs('nested'), contains('NESTED GROUP EXPLANATION'));
    expect(docs('hidden'), ['visible']);
    expect(docs('wrappers'), ['outer explanation', 'MIDDLE EXPLANATION', 'inner explanation']);
    expect(docs('overwritten'), isEmpty);
  });

  test('real i18n factory retains language, Markdown, comment and link without exposing defaults', () {
    final schema = SchemaNode.fromJson(catalogFixture('schemastery-description'));
    final zh = schemaDocumentation(schema, 'zh-CN');
    final en = schemaDocumentation(schema, 'en');
    final zhKey = zh.singleWhere((e) => e.path == r'$.hotkey');
    expect(zhKey.description, contains('**按住快捷键**'));
    expect(en.singleWhere((e) => e.path == r'$.hotkey').description, contains('**Hold the shortcut**'));
    expect(zhKey.comment, 'Use `Control` or `Alt`.');
    expect(zhKey.link, 'https://example.test/docs#keys');
    expect(zh.any((e) => e.path.contains('hidden')), isFalse);
    expect(zh.singleWhere((e) => e.path == r'$.group.override').description, 'Visible override');
    expect(zh.map((e) => '${e.description}${e.comment}${e.link}').join(), isNot(contains('MUST_NOT_APPEAR')));
  });

  test('published provider instructions and hotkey final sentence survive in full', () {
    final docs = schemaDocumentation(SchemaNode.fromJson(catalogFixture('goodandready-dsh-voice-0.9.42')), 'en');
    expect(
      docs.singleWhere((e) => e.path == r'$.dictation.chain[].provider').description,
      contains('put a normal host provider after them as a fallback.'),
    );
    expect(
      docs.singleWhere((e) => e.path == r'$.hotkey').description,
      contains('Modifier names (Control, Alt, Shift) or a KeyboardEvent code. Empty disables the hotkey.'),
    );
  });

  testWidgets('published voice hotkey explanation has a reachable full description', (tester) async {
    final host = FakeSettingsHost(
      describe: {
        'namespaces': [
          {
            'ns': 'voice',
            'schema': catalogFixture('goodandready-dsh-voice-0.9.42'),
            'base': {},
            'value': {},
            'revision': 0,
          },
        ],
      },
    );
    await pumpPage(
      tester,
      const EngineSettingsPage(ns: 'voice'),
      overrides: engineOverrides(DshClient.withCarrier(host)),
    );
    expect(find.byTooltip('字段说明'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.3, 2.0]) {
      testWidgets('plugin detail reaches scrollable full voice instructions ${brightness.name} $scale', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 900);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final host = FakeSettingsHost(
          describe: {
            'namespaces': [
              {
                'ns': 'voice',
                'schema': catalogFixture('goodandready-dsh-voice-0.9.42'),
                'base': {},
                'value': {},
                'revision': 0,
              },
            ],
          },
        )
          // Installed from the market: its row is a plugin's.
          ..bundles = [
            {
              'name': '@goodandready/dsh-voice',
              'enabled': true,
              'installed': true,
              'source': '@goodandready/dsh-voice@0.9.42',
              'rows': [
                {'rowId': 'voice', 'moduleName': '@goodandready/dsh-voice'},
              ],
            },
          ];
        await tester.pumpWidget(
          goldenApp(
            brightness: brightness,
            overrides: engineOverrides(DshClient.withCarrier(host)),
            home: const Scaffold(
              body: InventorySheet(
                item: InventoryItem(
                  entryId: 'include:voice',
                  moduleName: '@goodandready/dsh-voice',
                  title: 'dsh-voice',
                  status: InventoryStatus.running,
                ),
              ),
            ),
          ),
        );
        await flush(tester);
        await tester.tap(find.text(appL10n.commonSettings));
        await flush(tester);
        final help = find.byTooltip('字段说明');
        expect(help.hitTestable(), findsOneWidget);
        // AppPage uses the shared 44dp navigation action target.
        expect(tester.getSize(help).height, greaterThanOrEqualTo(44));
        await tester.tap(help);
        await settle(tester);
        final sheet = find.byType(SchemaDocumentationSheet);
        expect(sheet, findsOneWidget);
        expect(MediaQuery.textScalerOf(tester.element(sheet)).scale(10), closeTo(scale * 10, .01));
        final scroll = find.descendant(of: sheet, matching: find.byType(Scrollable)).first;
        final provider = heading('goodandready-dsh-voice-0.9.42', r'$.dictation.chain[].provider');
        final hotkey = heading('goodandready-dsh-voice-0.9.42', r'$.hotkey');
        // The page under the sheet has rows with the same names.
        Finder inSheet(String text) => find.descendant(of: sheet, matching: find.text(text));
        await tester.scrollUntilVisible(inSheet(provider), 200, scrollable: scroll);
        expect(
          find.byWidgetPredicate(
            (w) => w is GptMarkdown && w.data.contains('put a normal host provider after them as a fallback.'),
          ),
          findsWidgets,
        );
        await tester.scrollUntilVisible(inSheet(hotkey), 300, scrollable: scroll, maxScrolls: 100);
        expect(
          find.byWidgetPredicate((w) => w is GptMarkdown && w.data.contains('Empty disables the hotkey.')),
          findsOneWidget,
        );
        expect(inSheet(hotkey).hitTestable(), findsOneWidget);
        expect(host.mutates(), isEmpty);
        expect(tester.takeException(), isNull);
      });

      for (final locale in [AppLocale.zhCN, AppLocale.en]) {
        testWidgets('i18n Markdown sheet ${locale.languageCode} ${brightness.name} $scale', (tester) async {
          AppLocale.use(locale);
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(320, 900);
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final entries = schemaDocumentation(
            SchemaNode.fromJson(catalogFixture('schemastery-description')),
            locale.toLanguageTag(),
          );
          await tester.pumpWidget(
            goldenApp(
              brightness: brightness,
              home: Scaffold(
                body: SchemaDocumentationSheet(title: 'Voice', entries: entries),
              ),
            ),
          );
          await settle(tester);
          expect(find.text(heading('schemastery-description', r'$.hotkey')), findsOneWidget);
          final markdown = tester.widgetList<GptMarkdown>(find.byType(GptMarkdown)).map((w) => w.data).join();
          expect(markdown, contains(locale.languageCode == 'zh' ? '**按住快捷键**' : '**Hold the shortcut**'));
          final rendered = tester.widgetList<RichText>(find.byType(RichText)).map((w) => w.text.toPlainText()).join();
          expect(rendered, contains(locale.languageCode == 'zh' ? '按住快捷键' : 'Hold the shortcut'));
          expect(rendered, isNot(contains('**')));
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets('static Markdown never loads images, executes fences or resolves host-relative links', (tester) async {
    final launched = <Uri>[];
    final network = NoNetwork();
    const markdown = '''[Web](https://example.test/manual)
[Relative](/settings)
[File](file:///tmp/private)
[App](dshgo://open/settings)
![image](https://example.test/pixel.png)
<img src="https://example.test/html.png">
```dsh-ui
{"type":"button","action":"danger"}
```
''';
    await HttpOverrides.runZoned(() async {
      await tester.pumpWidget(
        goldenApp(
          brightness: Brightness.light,
          home: Scaffold(
            body: SchemaDocumentationSheet(
              title: 'Voice',
              entries: const [SchemaDocumentationEntry(r'$.source', markdown, null, null)],
              launcher: (uri) async {
                launched.add(uri);
                return true;
              },
            ),
          ),
        ),
      );
      await settle(tester);
    }, createHttpClient: network.createHttpClient);
    expect(network.requests, 0);
    expect(find.byType(Image), findsNothing);
    expect(find.byWidgetPredicate((w) => w.runtimeType.toString().contains('DshUi')), findsNothing);
    final body = tester.widget<GptMarkdown>(find.byType(GptMarkdown));
    expect(body.html, isFalse);
    expect(launched, isEmpty);
    for (final link in [
      '/settings',
      'file:///tmp/private',
      'dshgo://open/settings',
      '//example.test/path',
      'https://user:secret@example.test',
    ]) {
      body.onLinkTap!(link, 'test');
    }
    await tester.pump();
    expect(launched, isEmpty);
    body.onLinkTap!('https://example.test/manual', 'Web');
    body.onLinkTap!('http://example.test/manual', 'Web');
    await tester.pump();
    expect(launched.map((u) => u.toString()), ['https://example.test/manual', 'http://example.test/manual']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('documentation link launches only after a user tap and reports launch failure', (tester) async {
    final launched = <Uri>[];
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: Scaffold(
          body: SchemaDocumentationSheet(
            title: 'Voice',
            entries: const [
              SchemaDocumentationEntry(r'$.hotkey', 'Complete instructions.', null, 'https://example.test/manual'),
            ],
            launcher: (uri) async {
              launched.add(uri);
              return false;
            },
          ),
        ),
      ),
    );
    await settle(tester);
    expect(launched, isEmpty);
    await tester.tap(find.text('https://example.test/manual'));
    await settle(tester);
    expect(launched.single.toString(), 'https://example.test/manual');
    expect(find.text(appL10n.stateLinkOpenFailed), findsOneWidget);
    expect(find.byType(SchemaDocumentationSheet), findsOneWidget);
  });
}
