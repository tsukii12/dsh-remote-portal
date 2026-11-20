// The failure card's two quiet links, 「查看日志」 and 「导出诊断包」: mirrored
// halves under the buttons (or stacked when they don't fit), 50 tall, on the
// same edges as the primary button.

import 'package:dsh_app/ui/safe_mode/recovery_actions.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final (width, scale) in [(390.0, 1.0), (360.0, 1.3), (304.0, 1.0)]) {
    testWidgets('log and export links at $width / $scale', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme(),
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: RecoveryActions(
                  primaryLabel: '安全模式',
                  onPrimary: () {},
                  secondary: [(label: '重试', onPressed: () {})],
                  onLog: () {},
                  onExport: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final primary = tester.getRect(find.widgetWithText(FilledButton, '安全模式'));
      final log = tester.getRect(find.widgetWithText(TextButton, '查看日志'));
      final export = tester.getRect(find.widgetWithText(TextButton, '导出诊断包'));
      for (final rect in [primary, log, export]) {
        expect(rect.height, 50);
      }
      if ((log.top - export.top).abs() < .5) {
        expect(log.left, closeTo(primary.left, .5));
        expect(export.right, closeTo(primary.right, .5));
        expect(log.width, closeTo(export.width, .5));
        expect(export.left - log.right, closeTo(RecoveryActions.gap, .5));
        expect((log.left + export.right) / 2, closeTo(width / 2, .5));
      } else {
        for (final rect in [log, export]) {
          expect(rect.left, closeTo(primary.left, .5));
          expect(rect.right, closeTo(primary.right, .5));
        }
        expect(export.top - log.bottom, closeTo(RecoveryActions.gap, .5));
      }
      for (final label in ['查看日志', '导出诊断包']) {
        expect(tester.widget<Text>(find.text(label)).maxLines, 1);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('without onExport, 查看日志 stays alone and centred', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: RecoveryActions(primaryLabel: '重试', onPrimary: () {}, onLog: () {}),
          ),
        ),
      ),
    );
    final log = tester.getRect(find.widgetWithText(TextButton, '查看日志'));
    expect(log.left, 16);
    expect(log.right, 390 - 16);
    expect(find.text('导出诊断包'), findsNothing);
  });
}
