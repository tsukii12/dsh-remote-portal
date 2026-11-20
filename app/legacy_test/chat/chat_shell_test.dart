// The chat screen's shell around the messages: the new-chat empty state,
// the slash palette and the send-options sheet. Geometry (the suggestion
// chips line up with the composer; the palette's icons sit over the ＋ key;
// narrow phones with large text do not overflow) and goldens for the
// send-options sheet. Regenerate with
// `flutter test --update-goldens test/chat/chat_shell_test.dart`.

import 'dart:math' as math;

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/empty_actions.dart';
import 'package:dsh_app/ui/chat/empty_state.dart';
import 'package:dsh_app/ui/chat/slash_palette.dart';
import 'package:dsh_app/ui/chat/widgets/live_clock.dart' show runClock;
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

Future<void> _pump(
  WidgetTester tester,
  ChatHarness harness, {
  Brightness brightness = Brightness.light,
  Size? size,
  double textScale = 1,
}) async {
  usePhoneView(tester);
  if (size != null) tester.view.physicalSize = size * 2;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  mockClipboard(tester);
  await tester.pumpWidget(testApp(const ChatScreen(), brightness: brightness, overrides: harness.overrides));
  await pumpFrames(tester, 8);
}

double _screenWidth(WidgetTester tester) => tester.view.physicalSize.width / tester.view.devicePixelRatio;

Rect _suggestion(WidgetTester tester, int i) =>
    tester.getRect(find.ancestor(of: find.text(defaultSuggestions[i].label), matching: find.byType(InkWell)).first);

void main() {
  setUpAll(() async {
    await loadTestFonts();
    chatClock = () => DateTime(2026, 10, 23, 15, 20);
  });

  group('empty state', () {
    // The cards' own geometry (cells, insets, one column on very narrow
    // cells) is measured in empty_actions_test.dart.
    for (final (size, scale) in [(const Size(390, 844), 1.0), (const Size(360, 780), 1.3)]) {
      testWidgets('suggestions line up with the composer (${size.width.round()}dp, ×$scale)', (tester) async {
        await _pump(tester, ChatHarness(), size: size, textScale: scale);
        expect(tester.takeException(), isNull);
        final width = _screenWidth(tester);
        final composer = tester.getRect(find.byType(Composer));
        final chips = [for (var i = 0; i < 4; i++) _suggestion(tester, i)];

        // Same outer edges as the composer (12 from the screen).
        final left = chips.map((c) => c.left).reduce(math.min);
        final right = chips.map((c) => c.right).reduce(math.max);
        expect(left, moreOrLessEquals(composer.left, epsilon: 0.5));
        expect(right, moreOrLessEquals(composer.right, epsilon: 0.5));
        expect(composer.left, moreOrLessEquals(12, epsilon: 0.5));
        expect(width - composer.right, moreOrLessEquals(12, epsilon: 0.5));

        // Equal cards (each row as tall as its taller card), a card gap apart.
        for (final c in chips) {
          expect(c.width, moreOrLessEquals(chips[0].width, epsilon: 0.5));
        }
        expect(chips[1].height, moreOrLessEquals(chips[0].height, epsilon: 0.5));
        expect(chips[3].height, moreOrLessEquals(chips[2].height, epsilon: 0.5));
        // The third card starts the second row: one card gap below the first.
        expect(chips[2].top - chips[1].bottom, moreOrLessEquals(SuggestionCardMetrics.gap));

        // Greeting centred on the screen.
        final greeting = tester.getRect(find.text('下午好'));
        expect(greeting.center.dx, moreOrLessEquals(width / 2, epsilon: 0.5));
      });
    }

    testWidgets('a suggestion fills the composer', (tester) async {
      await _pump(tester, ChatHarness());
      await tester.tap(find.text(defaultSuggestions[1].label));
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, defaultSuggestions[1].prompt);
    });

    testWidgets('disconnected: the chips do nothing', (tester) async {
      await _pump(tester, ChatHarness(connected: false));
      expect(find.text('引擎未连接'), findsOneWidget);
      await tester.tap(find.text(defaultSuggestions[0].label));
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, isEmpty);
    });
  });

  testWidgets('slash palette: row icons sit over the ＋ key', (tester) async {
    await _pump(tester, ChatHarness(session: 's1', states: {'s1': const ChatState(loading: false)}));
    await tester.enterText(find.byType(TextField), '/');
    await pumpFrames(tester, 4);
    final palette = tester.getRect(find.byType(SlashPalette));
    final composer = tester.getRect(find.byType(Composer));
    expect(palette.left, moreOrLessEquals(composer.left, epsilon: 0.5));
    expect(palette.right, moreOrLessEquals(composer.right, epsilon: 0.5));
    final plus = tester.getCenter(find.byIcon(AppIcons.add));
    final icon = tester.getCenter(
      find.descendant(of: find.byType(SlashPalette), matching: find.byIcon(slashIconFor('compact'))),
    );
    expect(icon.dx, moreOrLessEquals(plus.dx, epsilon: 0.5));
  });

  testWidgets('model sheet on a 360dp phone with large text', (tester) async {
    await _pump(tester, ChatHarness(), size: const Size(360, 780), textScale: 1.3);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const ValueKey('composer-model')));
    await pumpFrames(tester, 8);
    expect(find.text('思考深度'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // "Remove animations" turns every AppMotion duration into zero; nothing on
  // the chat screen may trip over a zero-length animation (a zero-duration
  // AnimatedSize re-dirties itself during layout and asserts).
  group('animations off', () {
    setUp(() {
      TestWidgetsFlutterBinding.instance.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
    });
    tearDown(TestWidgetsFlutterBinding.instance.platformDispatcher.clearAccessibilityFeaturesTestValue);

    testWidgets('new chat, model sheet, effort, palette', (tester) async {
      await _pump(tester, ChatHarness());
      expect(tester.takeException(), isNull);
      expect(find.text('下午好'), findsOneWidget);

      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const ValueKey('composer-model')));
      await pumpFrames(tester, 6);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('V41 Flash'));
      await pumpFrames(tester, 2);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('不思考'));
      await pumpFrames(tester, 6);
      expect(tester.takeException(), isNull);
      expect(find.text('思考深度'), findsNothing, reason: 'closed at once');
      expect(find.text('V41 Flash 不思考'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '/');
      await pumpFrames(tester, 2);
      await tester.enterText(find.byType(TextField), '/co');
      await pumpFrames(tester, 2);
      expect(find.byType(SlashPalette), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a running chat with banners coming and going', (tester) async {
      final harness = ChatHarness(
        session: 's1',
        states: {'s1': const ChatState(loading: false, running: true, title: '修复登录重复提交')},
        balance: lowBalance,
      );
      await _pump(tester, harness);
      expect(tester.takeException(), isNull);
      final chat = harness.controllers['s1']!;
      chat.emit(chat.state.copyWith(error: '发送失败：连接已断开'));
      await pumpFrames(tester, 2);
      expect(tester.takeException(), isNull);
      chat.emit(const ChatState(loading: false, title: '修复登录重复提交', autoApprove: true, notice: '图片已作为文件发送'));
      await pumpFrames(tester, 2);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭').first);
      await pumpFrames(tester, 2);
      expect(tester.takeException(), isNull);
    });
  });

  for (final brightness in Brightness.values) {
    final suffix = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('send options sheet ($suffix)', (tester) async {
      // The running strip behind the sheet picks its line by the calendar
      // (weekends, holidays): pin a plain Sunday.
      runClock = () => DateTime(2026, 10, 25, 15, 20);
      addTearDown(() => runClock = DateTime.now);
      await _pump(
        tester,
        ChatHarness(session: 's1', states: {'s1': const ChatState(loading: false, running: true)}),
        brightness: brightness,
      );
      await tester.enterText(find.byType(TextField), '先停一下');
      // Let the stop key finish turning into ↑ before pressing it.
      await pumpFrames(tester, 2);
      await tester.longPress(find.byIcon(AppIcons.send));
      await pumpFrames(tester, 8);
      // Settings-row anatomy: titles at textStart of the card, line icons.
      final card = find
          .ancestor(of: find.widgetWithText(SettingsTile, '插话'), matching: find.byType(GlassSurface))
          .first;
      expect(tester.getTopLeft(find.text('插话')).dx - tester.getTopLeft(card).dx, SettingsMetrics.textStart);
      for (final icon in [AppIcons.steer, AppIcons.interrupt, AppIcons.queued]) {
        final glyph = find.descendant(of: card, matching: find.byIcon(icon));
        expect(tester.widget<Icon>(glyph).size, SettingsMetrics.lineGlyph);
      }
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/send_options_$suffix.png'));
    });
  }
}
