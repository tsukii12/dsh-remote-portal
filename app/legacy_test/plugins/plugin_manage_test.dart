import 'package:dsh_app/ui/plugins/plugin_detail_sheet.dart';
import 'package:dsh_app/ui/plugins/market_tab.dart';
import 'package:dsh_app/ui/plugins/plugin_widgets.dart';
import 'package:dsh_app/ui/plugins/plugins_screen.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'support/fake_plugin_host.dart';

void main() {
  for (final update in [false, true]) {
    testWidgets('market installed plugin opens management and returns; update=$update', (tester) async {
      final carrier = FakePluginCarrier();
      final client = DshClient.withCarrier(carrier);
      addTearDown(client.close);
      carrier.handlers['pluginManager/listBundles'] = (_) => [
        bundleJson('dsh-approval-gate', version: update ? '0.3.0' : '0.4.0'),
      ];
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(const PluginsScreen(initialTab: PluginsTab.market), overrides: pluginOverrides(fakeHost(client))),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(MarketCard, 'Approval Gate'),
          matching: find.byType(PluginInstallButton),
        ),
      );
      await tester.pumpAndSettle();
      final manage = find.widgetWithText(OutlinedButton, '管理');
      expect(tester.widget<OutlinedButton>(manage).onPressed, isNotNull);
      if (update) {
        final upgrade = find.widgetWithText(FilledButton, '更新到 0.4.0');
        final left = tester.getRect(manage);
        final right = tester.getRect(upgrade);
        final sheet = tester.getRect(find.byType(MarketPluginSheet));
        expect(left.width, closeTo(right.width, 0.01));
        expect(left.height, 48);
        expect(right.height, 48);
        expect(right.left - left.right, closeTo(12, 0.01));
        expect(left.left - sheet.left, closeTo(20, 0.01));
        expect(sheet.right - right.right, closeTo(20, 0.01));
      }
      await tester.tap(manage);
      await tester.pumpAndSettle();
      expect(find.text('管理插件'), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
      expect(find.text('卸载'), findsOneWidget);
      expect(find.text('停用后仍保留安装'), findsNothing);
      await tester.tap(find.descendant(of: find.byType(BundleSheet), matching: find.byTooltip('返回')));
      await tester.pumpAndSettle();
      expect(find.byType(MarketPluginSheet), findsOneWidget);
      expect(find.byType(BundleSheet), findsNothing);
      expect(find.widgetWithText(OutlinedButton, '管理'), findsOneWidget);
      if (!update) {
        carrier.handlers['pluginManager/removeBundle'] = (_) {
          carrier.handlers['pluginManager/listBundles'] = (_) => <Object?>[];
          return {'stage': 'remove', 'target': 'dsh-approval-gate', 'changed': true, 'application': 'applied'};
        };
        await tester.tap(find.widgetWithText(OutlinedButton, '管理'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(OutlinedButton, '卸载'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '卸载'));
        await tester.pumpAndSettle();
        expect(find.byType(MarketPluginSheet), findsNothing);
        expect(find.byType(BundleSheet), findsNothing);
        expect(carrier.argsOf('pluginManager/removeBundle'), isEmpty);
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        expect(carrier.argsOf('pluginManager/removeBundle'), hasLength(1));
      }
    });
  }
}
