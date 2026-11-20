// The new-chat empty state — at most one primary pill (「重新连接」), quiet
// chips of one size (the workspace chip and the new chat's options), the
// suggestions as quiet cards and one tip line. Geometry is measured, not
// eyeballed; goldens in light and dark. Regenerate with
// `flutter test --update-goldens test/chat/empty_actions_test.dart`.

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/empty_actions.dart';
import 'package:dsh_app/ui/chat/empty_state.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const _workspace = Workspace(workspaceId: 'w1', path: '/root/workspace/dsh-app', title: 'dsh-app', sessionIds: []);

const _workspaceLabel = '在「dsh-app」中';

/// The new-chat screen: connected in a workspace, or with a failed engine
/// connection.
Future<void> _pumpChat(
  WidgetTester tester, {
  bool failed = false,
  Brightness brightness = Brightness.light,
  Size? size,
  double textScale = 1,
}) async {
  usePhoneView(tester);
  if (size != null) tester.view.physicalSize = size * 2;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final harness = ChatHarness(connected: !failed);
  final List<Override> overrides = failed
      ? [
          activeConnectionProvider.overrideWithValue(AsyncError<HostConnection?>(StateError('raw'), StackTrace.empty)),
          ...harness.overrides.skip(1),
        ]
      : [...harness.overrides, selectedWorkspaceProvider.overrideWithValue(_workspace)];
  await tester.pumpWidget(testApp(const ChatScreen(), brightness: brightness, overrides: overrides));
  await pumpFrames(tester, 8);
}

/// Just the empty state, centred in a phone-wide page.
Future<void> _pumpState(WidgetTester tester, ChatEmptyState state) async {
  usePhoneView(tester);
  await tester.pumpWidget(testApp(Scaffold(body: Center(child: state))));
  await pumpFrames(tester, 8);
}

double _screenWidth(WidgetTester tester) => tester.view.physicalSize.width / tester.view.devicePixelRatio;

/// The pill around [label] (its ink fills it exactly).
Finder _pill(String label) => find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first;

Rect _rect(WidgetTester tester, String label) => tester.getRect(_pill(label));

/// The suggestion card around [label].
Rect _card(WidgetTester tester, String label) =>
    tester.getRect(find.ancestor(of: find.text(label), matching: find.byType(SuggestionCard)));

bool _cut(WidgetTester tester, String text) => tester.renderObject<RenderParagraph>(find.text(text)).didExceedMaxLines;


void main() {
  setUpAll(() async {
    await loadTestFonts();
    chatClock = () => DateTime(2026, 10, 23, 15, 20);
    tipStart = (_) => 0;
  });

  group('geometry', () {
    testWidgets('suggestions: two equal columns of cards, edge to edge with the composer', (tester) async {
      await _pumpChat(tester);
      expect(tester.takeException(), isNull);
      final composer = tester.getRect(find.byType(Composer));
      final cells = [for (final s in defaultSuggestions) _card(tester, s.label)];

      for (final c in cells) {
        expect(c.width, moreOrLessEquals(cells[0].width, epsilon: 0.5));
      }
      // 2×2, the outer edges on the composer's (12 from the screen).
      expect(cells[0].left, moreOrLessEquals(composer.left, epsilon: 0.5));
      expect(cells[2].left, moreOrLessEquals(composer.left, epsilon: 0.5));
      expect(cells[1].right, moreOrLessEquals(composer.right, epsilon: 0.5));
      expect(cells[3].right, moreOrLessEquals(composer.right, epsilon: 0.5));
      // Each row as tall as its taller card.
      expect(cells[0].top, cells[1].top);
      expect(cells[0].height, moreOrLessEquals(cells[1].height, epsilon: 0.5));
      expect(cells[2].top, cells[3].top);
      expect(cells[2].height, moreOrLessEquals(cells[3].height, epsilon: 0.5));
      expect(cells[1].left - cells[0].right, moreOrLessEquals(SuggestionCardMetrics.gap));
      expect(cells[2].top - cells[0].bottom, moreOrLessEquals(SuggestionCardMetrics.gap));

      // The badge on the card's inset, the text beside it; nothing cut.
      for (final s in defaultSuggestions) {
        final card = _card(tester, s.label);
        final title = tester.getRect(find.text(s.label));
        expect(
          title.left - card.left,
          moreOrLessEquals(
            SuggestionCardMetrics.padH + SuggestionCardMetrics.badge + SuggestionCardMetrics.badgeGap,
            epsilon: 0.5,
          ),
          reason: s.label,
        );
        expect(_cut(tester, s.label), isFalse, reason: '${s.label} is cut');
        expect(_cut(tester, s.detail!), isFalse, reason: '${s.detail} is cut');
      }
    });

    testWidgets('workspace chip: same height, centred, both sides read equal', (tester) async {
      await _pumpChat(tester);
      final chip = _rect(tester, _workspaceLabel);
      expect(chip.height, moreOrLessEquals(EmptyActions.height));
      expect(chip.center.dx, moreOrLessEquals(_screenWidth(tester) / 2, epsilon: 0.5));
      final folder = tester.getRect(
        find.descendant(of: _pill(_workspaceLabel), matching: find.byIcon(AppIcons.workspace)),
      );
      final chevron = tester.getRect(
        find.descendant(of: _pill(_workspaceLabel), matching: find.byIcon(AppIcons.expand)),
      );
      final left = folder.left - chip.left + EmptyActions.leadingAir;
      final right = chip.right - chevron.right + EmptyActions.chevronAir;
      expect(left, moreOrLessEquals(EmptyActions.inset, epsilon: 0.5));
      expect(right, moreOrLessEquals(EmptyActions.inset, epsilon: 0.5));
      expect(folder.center.dy, moreOrLessEquals(chip.center.dy, epsilon: 0.5));
      expect(chevron.center.dy, moreOrLessEquals(chip.center.dy, epsilon: 0.5));
    });

    testWidgets('360dp with large text: still two columns, titles only, nothing cut', (tester) async {
      await _pumpChat(tester, size: const Size(360, 780), textScale: 1.3);
      expect(tester.takeException(), isNull);
      final composer = tester.getRect(find.byType(Composer));
      final cells = [for (final s in defaultSuggestions) _card(tester, s.label)];
      expect(cells[0].left, moreOrLessEquals(composer.left, epsilon: 0.5));
      expect(cells[1].right, moreOrLessEquals(composer.right, epsilon: 0.5));
      expect(cells[0].top, cells[1].top);
      // A detail would wrap here, so every card keeps just its title.
      for (final s in defaultSuggestions) {
        expect(_cut(tester, s.label), isFalse, reason: s.label);
        expect(find.text(s.detail!), findsNothing, reason: s.detail);
      }
      // The workspace chip grows with the text, like the chips always did.
      expect(_rect(tester, _workspaceLabel).height, greaterThan(EmptyActions.height));
    });

    testWidgets('a cell too narrow for two lines: one card per row, full width', (tester) async {
      await _pumpChat(tester, size: const Size(260, 700));
      expect(tester.takeException(), isNull);
      final composer = tester.getRect(find.byType(Composer));
      final cells = [for (final s in defaultSuggestions) _card(tester, s.label)];
      for (final (i, c) in cells.indexed) {
        expect(c.left, moreOrLessEquals(composer.left, epsilon: 0.5));
        expect(c.right, moreOrLessEquals(composer.right, epsilon: 0.5));
        if (i > 0) expect(c.top - cells[i - 1].bottom, moreOrLessEquals(SuggestionCardMetrics.gap));
      }
    });

    testWidgets('no workspace chosen on a remote host: the chip names the one it falls back to', (tester) async {
      usePhoneView(tester);
      final harness = ChatHarness(connected: true);
      await tester.pumpWidget(
        testApp(
          const ChatScreen(),
          overrides: [...harness.overrides, recentWorkspaceForNewChatProvider.overrideWithValue(_workspace)],
        ),
      );
      await pumpFrames(tester, 8);
      expect(find.text(_workspaceLabel), findsOneWidget);
    });

    testWidgets('no workspace at all on a remote host: the chip names its default folder', (tester) async {
      usePhoneView(tester);
      final harness = ChatHarness(connected: true);
      await tester.pumpWidget(
        testApp(
          const ChatScreen(),
          overrides: [...harness.overrides, newChatInHostDefaultProvider.overrideWithValue(true)],
        ),
      );
      await pumpFrames(tester, 8);
      expect(find.text('在「主机默认目录」中'), findsOneWidget);
    });

    testWidgets('the primary pill takes the workspace chip\'s place exactly', (tester) async {
      Future<(Rect, double)> slot(bool failed) async {
        await _pumpState(
          tester,
          ChatEmptyState(
            connected: !failed,
            onSuggestion: (_) {},
            workspace: failed ? null : '项目',
            onWorkspace: () {},
            onReconnect: failed ? () {} : null,
          ),
        );
        final label = failed ? '重新连接' : '在「项目」中';
        final subtitle = tester.getRect(find.text(failed ? '没能连上引擎' : '今天想做点什么？'));
        final pill = _rect(tester, label);
        return (pill, pill.top - subtitle.bottom);
      }

      final (primary, primaryGap) = await slot(true);
      final (chip, chipGap) = await slot(false);
      expect(primary.height, moreOrLessEquals(chip.height));
      expect(primary.height, moreOrLessEquals(EmptyActions.height));
      expect(primary.center.dx, moreOrLessEquals(195, epsilon: 0.5));
      expect(chip.center.dx, moreOrLessEquals(195, epsilon: 0.5));
      expect(primaryGap, moreOrLessEquals(chipGap, epsilon: 0.1));
    });
  });

  group('tiers', () {
    testWidgets('connected: no primary, quiet chips and cards, one tip line', (tester) async {
      await _pumpChat(tester);
      expect(find.byType(EmptyPrimaryPill), findsNothing);
      expect(find.byType(QuietChip), findsOneWidget, reason: 'the workspace chip');
      expect(find.byType(SuggestionCard), findsNWidgets(defaultSuggestions.length));
      expect(find.byType(TipLine), findsOneWidget);
      final theme = Theme.of(tester.element(find.byType(ChatEmptyState)));
      for (final material in tester.widgetList<Material>(
        find.descendant(
          of: find.byWidgetPredicate((w) => w is QuietChip || w is SuggestionCard),
          matching: find.byType(Material),
        ),
      )) {
        expect(material.color, quietChipFill(theme));
        expect(material.elevation, 0);
      }
    });

    testWidgets('failed: one primary pill, nothing else to tap', (tester) async {
      await _pumpChat(tester, failed: true);
      await pumpFrames(tester, 6);
      expect(find.text('没能连上引擎'), findsOneWidget);
      expect(find.byType(EmptyPrimaryPill), findsOneWidget);
      expect(find.byType(QuietChip), findsNothing);
      expect(find.byType(SuggestionCard), findsNothing);
      expect(find.byType(TipLine), findsNothing);
      final theme = Theme.of(tester.element(find.byType(ChatEmptyState)));
      final fill = tester.widget<Material>(
        find.descendant(of: find.byType(EmptyPrimaryPill), matching: find.byType(Material)),
      );
      expect(fill.color, theme.colorScheme.primary);
    });

    testWidgets('the primary pill reconnects', (tester) async {
      var taps = 0;
      await _pumpState(tester, ChatEmptyState(connected: false, onSuggestion: (_) {}, onReconnect: () => taps++));
      await tester.tap(find.text('重新连接'));
      await tester.pump();
      expect(taps, 1);
      final semantics = tester.getSemantics(_pill('重新连接'));
      expect(semantics.label, '重新连接');
    });

    testWidgets('connecting: the cards are there but do nothing, no tip yet', (tester) async {
      final picked = <ChatSuggestion>[];
      await _pumpState(tester, ChatEmptyState(connected: false, connecting: true, onSuggestion: picked.add));
      expect(find.text('正在连接引擎…'), findsOneWidget);
      expect(find.byType(EmptyPrimaryPill), findsNothing);
      await tester.tap(find.text(defaultSuggestions[0].label));
      await tester.pump();
      expect(picked, isEmpty);
      expect(find.byType(TipLine), findsNothing);
    });

    testWidgets('a card fills in its suggestion and reads as one button', (tester) async {
      final picked = <ChatSuggestion>[];
      await _pumpState(tester, ChatEmptyState(connected: true, onSuggestion: picked.add));
      await tester.tap(find.text(defaultSuggestions[2].label));
      await tester.pump();
      expect(picked, [defaultSuggestions[2]]);
      final s = defaultSuggestions[2];
      final semantics = tester.getSemantics(find.byType(SuggestionCard).at(2));
      expect(semantics.label, '${s.label}, ${s.detail}');
    });

    testWidgets('tip line: one tip at a time, a tap rises in the next', (tester) async {
      await _pumpState(
        tester,
        ChatEmptyState(connected: true, onSuggestion: (_) {}, tips: const ['甲', '乙'], tipStart: 0),
      );
      expect(find.text('甲'), findsOneWidget);
      final semantics = tester.getSemantics(find.byType(TipLine));
      expect(semantics.label, '小技巧：甲');
      expect(semantics.hintOverrides?.onTapHint, '下一条小技巧');
      await tester.tap(find.byType(TipLine));
      await pumpFrames(tester, 6);
      expect(find.text('乙'), findsOneWidget);
      expect(find.text('甲'), findsNothing);
      await tester.tap(find.byType(TipLine));
      await pumpFrames(tester, 6);
      expect(find.text('甲'), findsOneWidget, reason: 'wraps around');
    });

    testWidgets('tips turn on their own; a tap restarts the wait', (tester) async {
      await _pumpState(
        tester,
        ChatEmptyState(connected: true, onSuggestion: (_) {}, tips: const ['甲', '乙', '丙'], tipStart: 0),
      );
      expect(find.text('甲'), findsOneWidget);
      await tester.pump(tipDwell - const Duration(seconds: 1));
      expect(find.text('甲'), findsOneWidget, reason: 'not before the dwell');
      await tester.pump(const Duration(seconds: 1));
      await pumpFrames(tester, 6);
      expect(find.text('乙'), findsOneWidget);
      // A tap shows the next one now and waits a full dwell again.
      await tester.pump(tipDwell - const Duration(seconds: 2));
      await tester.tap(find.byType(TipLine));
      await pumpFrames(tester, 6);
      expect(find.text('丙'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('丙'), findsOneWidget);
    });

    testWidgets('with reduced motion the tip stays until tapped', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          MediaQuery(
            data: const MediaQueryData(disableAnimations: true, size: Size(390, 844)),
            child: Scaffold(
              body: Center(
                child: ChatEmptyState(connected: true, onSuggestion: (_) {}, tips: const ['甲', '乙'], tipStart: 0),
              ),
            ),
          ),
        ),
      );
      await tester.pump(tipDwell * 3);
      expect(find.text('甲'), findsOneWidget);
      await tester.tap(find.byType(TipLine));
      await tester.pump();
      expect(find.text('乙'), findsOneWidget);
    });

    testWidgets('the default tips are all there, each fits two lines', (tester) async {
      await _pumpState(tester, ChatEmptyState(connected: true, onSuggestion: (_) {}));
      final tips = defaultTips();
      expect(tips.toSet(), hasLength(tips.length));
      for (var i = 0; i < tips.length; i++) {
        expect(find.text(tips[i]), findsOneWidget);
        expect(_cut(tester, tips[i]), isFalse, reason: tips[i]);
        await tester.tap(find.byType(TipLine));
        await pumpFrames(tester, 4);
      }
    });

    testWidgets('workspace chip: a label and a hint, not one long sentence', (tester) async {
      var opened = 0;
      await _pumpState(
        tester,
        ChatEmptyState(connected: true, onSuggestion: (_) {}, workspace: '项目', onWorkspace: () => opened++),
      );
      final semantics = tester.getSemantics(_pill('在「项目」中'));
      expect(semantics.label, '在「项目」中');
      expect(semantics.hint, isEmpty);
      await tester.tap(find.text('在「项目」中'));
      await tester.pump();
      expect(opened, 1);
    });
  });

  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    group('goldens ($mode)', () {
      testWidgets('connected, in a workspace', (tester) async {
        await _pumpChat(tester, brightness: brightness);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/empty_tiers_$mode.png'));
      });

      testWidgets('engine unreachable', (tester) async {
        await _pumpChat(tester, failed: true, brightness: brightness);
        await pumpFrames(tester, 6);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/empty_tiers_failed_$mode.png'));
      });

      testWidgets('360dp, large text', (tester) async {
        await _pumpChat(tester, brightness: brightness, size: const Size(360, 780), textScale: 1.3);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/empty_tiers_narrow_$mode.png'));
      });
    });
  }
}
