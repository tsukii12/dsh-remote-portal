// Measured symmetry of the engine settings controls: the number sheet's
// mirrored stepper and its two equal buttons, row heights, the trailing edge
// shared by switches and capsules, and the 已修改 tag centred on its title.

import 'package:dsh_app/ui/engine_settings/field_row.dart';
import 'package:dsh_app/ui/engine_settings/field_sheets.dart';
import 'package:dsh_app/ui/engine_settings/general_settings_page.dart';
import 'package:dsh_app/ui/engine_settings/runtime_settings_pages.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

Rect cardOf(WidgetTester tester, Finder child) =>
    tester.getRect(find.ancestor(of: child, matching: find.byType(GlassSurface)).first);

void main() {
  testWidgets('the number sheet: mirrored keys, centred value, equal buttons', (tester) async {
    final host = FakeSettingsHost()..namespaces['bash-sandbox']!.user = {'timeoutMs': 90000};
    await pumpPage(tester, const ShellSettingsPage(), overrides: engineOverrides(DshClient.withCarrier(host)));
    await tester.tap(find.text('命令超时'));
    await settle(tester);

    final down = tester.getRect(find.byKey(const ValueKey('step-down')));
    final up = tester.getRect(find.byKey(const ValueKey('step-up')));
    final card = cardOf(tester, find.byKey(const ValueKey('step-down')));
    expect(down.size, const Size.square(NumberFieldSheet.keySize));
    expect(up.size, down.size);
    expect(down.left - card.left, closeTo(card.right - up.right, 0.5), reason: 'equal side insets');
    expect(down.top - card.top, closeTo(card.bottom - down.bottom, 0.5), reason: 'centred vertically');
    expect(down.top - card.top, closeTo(down.left - card.left, 0.5), reason: 'equal on all sides');
    expect(up.center.dy, down.center.dy);
    final group = tester.getRect(
      find.ancestor(of: find.byKey(const ValueKey('number-input')), matching: find.byType(Row)).first,
    );
    expect(group.center.dx, closeTo(card.center.dx, 0.5), reason: 'value and unit centred between the keys');

    final restore = tester.getRect(find.widgetWithText(OutlinedButton, '恢复默认'));
    final done = tester.getRect(find.widgetWithText(FilledButton, '完成'));
    expect(restore.size, done.size);
    expect(done.height, 48);
    expect(done.left - restore.right, closeTo(12, 0.01));
    final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '完成'));
    expect(button.style?.shape?.resolve({}), isNot(isA<StadiumBorder>()));
    expect(restore.top, done.top);
    final screen = tester.getRect(find.byType(MaterialApp));
    expect(restore.left - screen.left, closeTo(screen.right - done.right, 0.5));
    expect(restore.left - screen.left, card.left - screen.left, reason: 'buttons share the card\'s gutter');
  });

  testWidgets('rows: 52 with one line, 64 with two', (tester) async {
    await pumpPage(
      tester,
      const GeneralSettingsPage(),
      overrides: engineOverrides(DshClient.withCarrier(FakeSettingsHost())),
    );
    final oneLine = tester.getRect(find.ancestor(of: find.text('工作步骤展示'), matching: find.byType(EngineFieldRow)).first);
    expect(oneLine.height, 52);
    final locked = FakeSettingsHost()..namespaces['agent-loop']!.overlay = {'maxParallelToolCalls': 3};
    await pumpPage(tester, const AgentLoopSettingsPage(), overrides: engineOverrides(DshClient.withCarrier(locked)));
    final twoLine = tester.getRect(
      find.ancestor(of: find.text('每步并行工具调用上限'), matching: find.byType(EngineFieldRow)).first,
    );
    expect(twoLine.height, 64, reason: 'title over 「由配置文件固定」');
  });

  for (final (name, page) in [
    ('general', const GeneralSettingsPage() as Widget),
    ('shell', const ShellSettingsPage() as Widget),
  ]) {
    testWidgets('$name: 360 wide at text scale 1.3 nothing overflows', (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(360 * 2, 1400 * 2);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        goldenApp(
          brightness: Brightness.light,
          overrides: engineOverrides(DshClient.withCarrier(FakeSettingsHost())),
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
              child: page,
            ),
          ),
        ),
      );
      await flush(tester);
      expect(tester.takeException(), isNull);
      for (final pill in tester.widgetList<Text>(find.text('有新消息时'))) {
        expect(pill.maxLines, 1);
      }
    });
  }

  testWidgets('switch tracks and capsules end on the same line; the tag sits on the title', (tester) async {
    final host = FakeSettingsHost()..namespaces['ui-chat']!.user = {'linkOpening': 'new-tab'};
    await pumpPage(tester, const GeneralSettingsPage(), overrides: engineOverrides(DshClient.withCarrier(host)));
    final card = cardOf(tester, find.text('显示代码工作视图'));
    final switchBox = tester.getRect(find.byType(Switch).first);
    // The track sits 4 inside the switch's box.
    final trackRight = switchBox.right - 4;
    expect(card.right - trackRight, closeTo(16, 0.5));
    Rect pillOf(String label) =>
        tester.getRect(find.ancestor(of: find.text(label), matching: find.byType(GestureDetector)).last);
    // One layout per card: 「收起时机」 needs its capsule underneath, so
    // 「性能与用量」 in the same card stacks too, edge to edge alike.
    final timing = pillOf('有新消息时');
    final usage = pillOf('简洁');
    expect(usage.width, timing.width);
    expect(usage.left, timing.left);
    expect(card.right - usage.right, closeTo(16, 0.5));
    expect(usage.left - card.left, closeTo(16, 0.5));

    final title = tester.getRect(find.text('链接打开方式'));
    final badge = tester.getRect(find.byType(FieldBadge));
    expect(badge.center.dy, closeTo(title.center.dy, 1));
    expect(badge.left - title.right, 8);
  });
}
