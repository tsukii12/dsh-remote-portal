import 'dart:ui' as ui;

import 'package:dsh_app/ui/plugins/installed_tab.dart';
import 'package:dsh_app/ui/plugins/plugin_detail_sheet.dart';
import 'package:dsh_app/ui/plugins/plugins_screen.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'support/fake_plugin_host.dart';

void main() {
  late FakePluginCarrier carrier;
  late DshClient client;

  setUp(() {
    carrier = FakePluginCarrier();
    client = DshClient.withCarrier(carrier);
    carrier.handlers['pluginManager/listBundles'] = (_) => sampleBundles;
  });
  tearDown(() => client.close());

  Future<void> pumpScreen(WidgetTester tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(testApp(const PluginsScreen(), overrides: pluginOverrides(fakeHost(client))));
    await tester.pumpAndSettle();
  }

  Finder toggleFor(String title) =>
      find.descendant(of: find.widgetWithText(BundleTile, title), matching: find.byType(Switch));

  for (final (title, enabled) in [('dsh-approval-gate', true), ('会话搜索', false)]) {
    testWidgets('installed switch is named $title and reports its state', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await pumpScreen(tester);
        final data = tester.getSemantics(toggleFor(title)).getSemanticsData();
        expect(data.label, title);
        expect(data.flagsCollection.isToggled, enabled ? ui.Tristate.isTrue : ui.Tristate.isFalse);
        expect(data.flagsCollection.isEnabled, ui.Tristate.isTrue);
        expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }

  testWidgets('switch and details remain separate semantic actions', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      carrier.handlers['pluginManager/setBundleEnabled'] = (args) => {
        'stage': 'enable',
        'target': args['name'],
        'changed': true,
        'application': 'applied',
      };
      await pumpScreen(tester);
      final row = find.widgetWithText(BundleTile, 'dsh-approval-gate');
      final rowNode = tester.getSemantics(row);
      final switchNode = tester.getSemantics(toggleFor('dsh-approval-gate'));
      expect(switchNode.id, isNot(rowNode.id));
      expect(rowNode.getSemanticsData().label, contains('dsh-approval-gate'));
      expect(rowNode.getSemanticsData().flagsCollection.isButton, isTrue);
      switchNode.owner!.performAction(switchNode.id, ui.SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(carrier.argsOf('pluginManager/setBundleEnabled').single, {'name': 'dsh-approval-gate', 'enabled': false});
      expect(find.byType(BundleSheet), findsNothing);
      final detailsNode = tester.getSemantics(row);
      detailsNode.owner!.performAction(detailsNode.id, ui.SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(find.byType(BundleSheet), findsOneWidget);
      expect(carrier.argsOf('pluginManager/setBundleEnabled'), hasLength(1));
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('read-only cached plugin keeps a named disabled switch', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final bundle = PluginBundle.fromJson(bundleJson('saved-plugin', title: {'zh': '保存的插件', 'en': 'Saved plugin'}));
      await tester.pumpWidget(
        testApp(
          Scaffold(body: BundleTile(bundle: bundle, readOnly: true, displaySnapshot: true)),
          overrides: pluginOverrides(fakeHost(client)),
        ),
      );
      await tester.pumpAndSettle();
      final data = tester.getSemantics(find.byType(Switch)).getSemanticsData();
      expect(data.label, contains('保存的插件'));
      expect('保存的插件'.allMatches(data.label), hasLength(1));
      expect(data.flagsCollection.isToggled, ui.Tristate.isTrue);
      expect(data.flagsCollection.isEnabled, ui.Tristate.isFalse);
      expect(data.hasAction(ui.SemanticsAction.tap), isFalse);
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
      expect(carrier.argsOf('pluginManager/setBundleEnabled'), isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
