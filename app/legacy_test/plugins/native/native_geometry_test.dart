// Measured, not eyeballed: the capsules' insets are equal left and right,
// their content sits on the centre line, the row lines up with the
// composer, a working capsule keeps its size; the status line's mark is
// concentric with its left end; a panel card keeps the page's gutters.

import 'package:dsh_app/plugins/native/native_model.dart';
import 'package:dsh_app/ui/plugins/native/composer_capsules.dart';
import 'package:dsh_app/ui/plugins/native/composer_strip.dart';
import 'package:dsh_app/ui/plugins/native/native_composer_bar.dart';
import 'package:dsh_app/ui/plugins/native/native_panel.dart';
import 'package:dsh_app/ui/plugins/view/plugin_view.dart';
import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/support/harness.dart';
import 'support.dart';

const _quick = [UiQuickAction(label: '总结', action: UiSendAction('总结上面的对话'))];

Widget bed(FakeBridge bridge) => testApp(
  Scaffold(
    body: withComposer(
      FakeComposer(),
      const Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, 0, 12, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              NativeComposerBar(sessionId: 's1', visible: true),
              SizedBox(key: ValueKey('composer'), height: 56),
            ],
          ),
        ),
      ),
    ),
  ),
  overrides: nativeOverrides(bridge, quick: _quick),
);

void expectClose(double actual, double expected, String what) =>
    expect(actual, moreOrLessEquals(expected, epsilon: 0.01), reason: what);

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final scale in [1.0, 1.3]) {
    testWidgets('capsules: equal insets, centred content, aligned row (text ×$scale)', (tester) async {
      usePhoneView(tester);
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final bridge = FakeBridge(contributions([quickPlugin(), usagePlugin()]));
      await tester.pumpWidget(bed(bridge));
      await pumpFrames(tester);
      bridge.socket.push({
        't': 'data',
        'sub': bridge.socket.subOf('cost')!['sub'],
        'rev': '1',
        'data': {'text': '本对话 ¥0.42 · 今日 ¥3.1'},
      });
      await pumpFrames(tester);

      final capsules = find.byType(ComposerCapsule);
      expect(capsules, findsNWidgets(3));
      final composer = tester.getRect(find.byKey(const ValueKey('composer')));
      final rects = [for (var i = 0; i < 3; i++) tester.getRect(capsules.at(i))];

      expectClose(rects.first.left, composer.left, 'the row starts at the composer edge');
      for (final (i, r) in rects.indexed) {
        expectClose(r.height, CapsuleMetrics.height, 'capsule $i height');
        expectClose(r.top, rects.first.top, 'capsule $i top');
        if (i > 0) expectClose(r.left - rects[i - 1].right, CapsuleMetrics.gap, 'gap before capsule $i');
        final capsule = capsules.at(i);
        final text = tester.getRect(find.descendant(of: capsule, matching: find.byType(Text)));
        final icon = find.descendant(of: capsule, matching: find.byType(Icon));
        final start = icon.evaluate().isEmpty ? text.left : tester.getRect(icon).left;
        expectClose(start - r.left, r.right - text.right, 'capsule $i: left inset = right inset');
        expectClose(r.right - text.right, CapsuleMetrics.inset, 'capsule $i: inset');
        expectClose(text.center.dy, r.center.dy, 'capsule $i: text on the centre line');
        if (icon.evaluate().isNotEmpty) {
          expectClose(tester.getRect(icon).center.dy, r.center.dy, 'capsule $i: icon on the centre line');
        }
      }
      expectClose(composer.top - rects.first.bottom, CapsuleMetrics.below, 'row to composer');

      // The status line: across the composer's width, its mark concentric
      // with the left end.
      final strip = tester.getRect(find.byType(ComposerStrip));
      final mark = tester.getRect(find.byKey(const ValueKey('strip-mark')));
      expectClose(strip.left, composer.left, 'strip left');
      expectClose(strip.right, composer.right, 'strip right');
      expectClose(strip.height, StripMetrics.height, 'strip height');
      expectClose(mark.left - strip.left, mark.top - strip.top, 'mark: left = top');
      expectClose(mark.top - strip.top, strip.bottom - mark.bottom, 'mark: top = bottom');
      expectClose(rects.first.top - strip.bottom, StripMetrics.below, 'strip to capsules');
      final line = tester.getRect(find.descendant(of: find.byType(ComposerStrip), matching: find.byType(Text)).last);
      expectClose(line.center.dy, strip.center.dy, 'strip text on the centre line');
    });
  }

  testWidgets('a working capsule keeps its size; its ring sits in the middle', (tester) async {
    usePhoneView(tester);
    final bridge = FakeBridge(contributions([quickPlugin()]))
      ..answer = (_) => DshGoInvokeResult.fromJson({
        'effects': [],
        'pending': {'id': 'p1', 'timeoutMs': 30000},
      });
    await tester.pumpWidget(bed(bridge));
    await pumpFrames(tester);
    final capsule = find.widgetWithText(ComposerCapsule, '译成英文');
    final idle = tester.getRect(capsule);
    final neighbour = tester.getRect(find.widgetWithText(ComposerCapsule, '打招呼'));
    await tester.tap(capsule);
    await pumpFrames(tester, 3);
    expect(tester.getRect(capsule), idle);
    expect(tester.getRect(find.widgetWithText(ComposerCapsule, '打招呼')), neighbour, reason: 'nothing moves');
    final ring = tester.getRect(find.byKey(const ValueKey('capsule-ring')));
    expectClose(ring.center.dx, idle.center.dx, 'ring centred across');
    expectClose(ring.center.dy, idle.center.dy, 'ring centred down');
    bridge.socket.push({'t': 'void', 'pending': 'p1', 'reason': 'timeout'});
    await pumpFrames(tester, 3);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a panel page: the signed card keeps the 16 gutters, equal both sides', (tester) async {
    usePhoneView(tester);
    final bridge = FakeBridge(contributions([usagePlugin()]));
    bridge.views['dsh-go-example-usage/usage'] = const DshGoView(
      pkg: 'dsh-go-example-usage',
      id: 'usage',
      view: {'type': 'metric', 'label': '本对话', 'value': '¥0.42'},
    );
    await tester.pumpWidget(
      testApp(
        const NativePanelPage(
          panel: NativePanel(package: 'dsh-go-example-usage', id: 'usage', title: '用量', placement: {'features'}),
        ),
        overrides: nativeOverrides(bridge),
      ),
    );
    await pumpFrames(tester);
    final frame = tester.getRect(find.byType(PluginFrame));
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expectClose(frame.left, 16, 'left gutter');
    expectClose(width - frame.right, 16, 'right gutter');
  });
}
