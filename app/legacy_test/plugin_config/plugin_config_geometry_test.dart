// Measured symmetry of a plugin's configuration page: the save bar's two
// equal, mirrored buttons on the cards' gutter with the status centred over
// them; the search capsule, the web row and the folded 「高级」 card on the
// same column as the fields; and a narrow phone at large text that neither
// overflows nor squeezes the buttons apart.

import 'package:dsh_app/ui/plugins/config/plugin_config_page.dart';
import 'package:dsh_app/ui/plugins/config/plugin_config_save_bar.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../engine_settings/support.dart';
import 'support.dart';

Rect _card(WidgetTester tester, Finder child) =>
    tester.getRect(find.ancestor(of: child, matching: find.byType(GlassSurface)).first);

const _primary = ValueKey('plugin-config-primary');
const _secondary = ValueKey('plugin-config-secondary');

void main() {
  testWidgets('save bar: two equal mirrored buttons, the status centred over them', (tester) async {
    await pumpConfigPage(tester, const PluginConfigPage(ns: 'speech-to-text-sensevoice'), sampleConfigApi());
    await tester.tap(find.text('自动加标点'));
    await settle(tester);

    final screen = tester.getRect(find.byType(MaterialApp));
    final left = tester.getRect(find.byKey(_secondary));
    final right = tester.getRect(find.byKey(_primary));
    final field = _card(tester, find.text('识别语言'));
    expect(left.size, right.size, reason: 'equal buttons');
    expect(right.height, PluginConfigSaveBar.buttonHeight);
    expect(left.top, right.top);
    expect(right.left - left.right, closeTo(PluginConfigSaveBar.gap, 0.01));
    expect(left.left - screen.left, closeTo(screen.right - right.right, 0.5), reason: 'mirrored about the centre');
    expect(left.left, closeTo(field.left, 0.5), reason: 'on the cards\' gutter');
    expect(right.right, closeTo(field.right, 0.5));

    final status = tester.getRect(find.byKey(const ValueKey('plugin-config-status')));
    expect(status.center.dx, closeTo(screen.center.dx, 0.5), reason: 'the status is centred');
    expect(left.top - status.bottom, closeTo(PluginConfigSaveBar.statusGap, 0.5));
    final bottomInset = MediaQuery.of(tester.element(find.byKey(_primary))).viewPadding.bottom;
    expect(screen.bottom - right.bottom, closeTo(12 + bottomInset, 0.5), reason: 'above the gesture bar');
  });

  testWidgets('search, the web row, the fields and 高级 share one column', (tester) async {
    await pumpConfigPage(tester, const PluginConfigPage(ns: 'speech-to-text-sensevoice'), sampleConfigApi());
    final screen = tester.getRect(find.byType(MaterialApp));
    final search = tester.getRect(find.byKey(const ValueKey('plugin-config-search')));
    final fields = _card(tester, find.text('识别语言'));
    final advanced = _card(tester, find.text('高级'));
    expect(search.left, fields.left);
    expect(search.right, fields.right);
    expect(advanced.left, fields.left);
    expect(advanced.right, fields.right);
    expect(fields.left - screen.left, closeTo(screen.right - fields.right, 0.5), reason: 'centred column');
    expect(fields.left - screen.left, 16);

    await pumpConfigPage(tester, const PluginConfigPage(ns: 'weather'), sampleConfigApi());
    final web = _card(tester, find.text('在网页版设置'));
    final form = _card(tester, find.text('城市'));
    expect(web.left, form.left);
    expect(web.right, form.right);
    expect(form.top - web.bottom, 24, reason: 'the gap between groups');
  });

  testWidgets('360 wide at 1.3x text: no overflow, the buttons stay equal', (tester) async {
    await tester.runAsync(() async {});
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(360 * 2, 780 * 2);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.view.reset);
    await pumpConfigPage(
      tester,
      const PluginConfigPage(ns: 'speech-to-text-sensevoice'),
      sampleConfigApi(),
      height: 780,
    );
    tester.view.physicalSize = const Size(360 * 2, 780 * 2);
    await settle(tester);
    await tester.tap(find.text('自动加标点'));
    await settle(tester);
    expect(tester.takeException(), isNull);
    final left = tester.getRect(find.byKey(_secondary));
    final right = tester.getRect(find.byKey(_primary));
    expect(left.size, right.size);
    expect(left.left, closeTo(360 - right.right, 0.5));
  });
}
