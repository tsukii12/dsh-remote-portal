// The plugin mark in a frame's header takes the same icon names as the native
// slots (nativeIcon: ui.json's names plus coin, speaker, …); only an unknown
// or missing name falls back to the name's first character.

import 'package:dsh_app/plugins/native/native_icons.dart';
import 'package:dsh_app/ui/plugins/view/plugin_view.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Future<void> _pumpMark(WidgetTester tester, String name, String? icon) async {
  usePhoneView(tester);
  await tester.pumpWidget(
    testApp(
      Scaffold(
        body: Center(
          child: PluginMark(name: name, icon: icon),
        ),
      ),
    ),
  );
  await pumpFrames(tester);
}

void main() {
  setUpAll(loadTestFonts);

  final markIcon = find.descendant(of: find.byType(PluginMark), matching: find.byType(Icon));

  for (final (name, icon, glyph) in [
    ('用量', 'coin', AppIcons.balance),
    ('朗读', 'speaker', AppIcons.readText),
    ('用量', 'chart', AppIcons.chart),
  ]) {
    testWidgets('「$icon」 draws its glyph, centred in the mark', (tester) async {
      expect(nativeIcon(icon), glyph);
      await _pumpMark(tester, name, icon);
      expect(markIcon, findsOneWidget);
      expect(tester.widget<Icon>(markIcon).icon, glyph);
      expect(find.text(name.characters.first), findsNothing);
      final mark = tester.getRect(find.byType(PluginMark));
      final drawn = tester.getRect(markIcon);
      expect(mark.size, const Size.square(PluginFrame.markSize));
      expect(drawn.center.dx, moreOrLessEquals(mark.center.dx, epsilon: 0.01));
      expect(drawn.center.dy, moreOrLessEquals(mark.center.dy, epsilon: 0.01));
    });
  }

  for (final icon in ['no-such-icon', null]) {
    testWidgets('icon $icon: the name\'s first character', (tester) async {
      await _pumpMark(tester, 'weather', icon);
      expect(markIcon, findsNothing);
      expect(find.text('W'), findsOneWidget);
      expect(tester.getRect(find.byType(PluginMark)).size, const Size.square(PluginFrame.markSize));
    });
  }
}
