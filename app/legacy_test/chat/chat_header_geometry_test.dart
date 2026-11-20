// The chat header at phone widths: ≡ and 新对话 mirror each other, every
// piece sits on one line, and when the bar is crowded (a long title, the
// agents capsule, large text) the pieces give way in a fixed order: the
// model chip's 「· 高」 first, then the title down to its first characters
// and the host, then the model's name down to ✦ ⌄. Measured with real fonts.

import 'package:dsh_app/state/agents_state.dart';
import 'package:dsh_app/ui/agents/header_agents.dart';
import 'package:dsh_app/ui/chat/chat_header.dart';
import 'package:dsh_app/ui/chat/model_sheet.dart';
import 'package:dsh_app/ui/common/status_dot.dart';
import 'package:dsh_app/ui/theme/theme.dart' show GlassSurface;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

Future<void> _pump(
  WidgetTester tester, {
  required double width,
  required double scale,
  String title = '修复登录重复提交',
  String status = '连接已断开',
  String? detail,
  bool chip = true,
  bool agents = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 800);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    testApp(
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: ChatHeader(
                title: title,
                status: HeaderStatus(StatusTone.ok, status),
                detail: detail,
                trailing: chip
                    ? ModelChip(selection: testCatalog.defaultSelection, onSelected: (_) {}, grouped: true)
                    : null,
                onOpenDrawer: () {},
                onNewChat: () {},
              ),
            ),
          ),
        ),
      ),
      overrides: [
        ...ChatHarness(session: agents ? 's1' : null).overrides,
        if (agents) headerAgentsProvider.overrideWith((ref, id) => const HeaderAgents(children: 3, running: 1)),
      ],
    ),
  );
  await pumpFrames(tester);
}

Rect _rect(WidgetTester tester, String key) => tester.getRect(find.byKey(ValueKey(key)));

/// The chip's glass, not the widget (whose box is the same).
Rect _chip(WidgetTester tester) =>
    tester.getRect(find.descendant(of: find.byType(ModelChip), matching: find.byType(GlassSurface)).first);

/// The model chip's words on screen; null when only ✦ ⌄ are left.
RenderParagraph? _chipWords(WidgetTester tester) {
  final words = find.descendant(of: find.byType(ModelChip), matching: find.byWidgetPredicate((w) => w is Text));
  if (words.evaluate().isEmpty) return null;
  return tester.renderObject<RenderParagraph>(words);
}

RenderParagraph _paragraph(WidgetTester tester, String text) =>
    tester.renderObject<RenderParagraph>(find.descendant(of: find.byType(ChatHeader), matching: find.text(text)));

void main() {
  group('the line under the title', () {
    bool cut(WidgetTester tester, Pattern text) =>
        tester.renderObject<RenderParagraph>(find.textContaining(text).first).didExceedMaxLines;

    testWidgets('a long workspace shortens, the status does not', (tester) async {
      await _pump(tester, width: 360, scale: 1, chip: false, detail: '一个名字特别特别特别特别特别特别特别特别特别长的工作区');
      expect(cut(tester, '连接已断开'), isFalse);
      expect(cut(tester, '工作区'), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a short workspace leaves the status all the room', (tester) async {
      await _pump(tester, width: 360, scale: 1, chip: false, status: '正在重新连接到远程主机', detail: 'dsh');
      expect(cut(tester, '正在重新连接到远程主机'), isFalse);
      expect(cut(tester, 'dsh'), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a status wider than the bar shortens itself, nothing overflows', (tester) async {
      await _pump(tester, width: 320, scale: 1, chip: false, status: '正在重新连接' * 10, detail: 'dsh');
      expect(cut(tester, '正在重新连接'), isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  setUpAll(loadTestFonts);

  for (final width in [360.0, 390.0]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets('header geometry at $width and $scale', (tester) async {
        final semantics = tester.ensureSemantics();
        await _pump(tester, width: width, scale: scale);
        expect(tester.takeException(), isNull);
        final bar = _rect(tester, 'chat-header-bar');
        final pill = _rect(tester, 'chat-title-pill');
        final menu = _rect(tester, 'chat-menu');
        final fresh = _rect(tester, 'chat-new-chat');
        final status = tester.getRect(find.text('连接已断开'));
        expect(pill.top - bar.top, closeTo(bar.bottom - pill.bottom, 0.1));
        expect(menu.size, const Size.square(44));
        expect(fresh.size, menu.size);
        expect(menu.left, 12);
        expect(width - fresh.right, 12);
        expect(menu.center.dy, closeTo(pill.center.dy, 0.1));
        expect(fresh.center.dy, closeTo(pill.center.dy, 0.1));
        expect(tester.getRect(find.byType(ModelChip)).center.dy, closeTo(pill.center.dy, 0.1));
        expect(status.top, greaterThanOrEqualTo(pill.top));
        expect(status.bottom, lessThanOrEqualTo(pill.bottom));
        expect(_paragraph(tester, '连接已断开').didExceedMaxLines, isFalse);
        // No automation task: no clock, the pill's own 16 on both sides.
        expect(find.byKey(const ValueKey('chat-schedule')), findsNothing);
        final title = tester.getRect(find.text('修复登录重复提交'));
        final text = title.right > status.right ? title.right : status.right;
        expect(title.left - pill.left, moreOrLessEquals(16, epsilon: 0.5));
        expect(pill.right - text, moreOrLessEquals(16, epsilon: 0.5));
        if (scale == 1) expect(bar.height, 56);
        final live = find.byWidgetPredicate((w) => w is Semantics && w.properties.liveRegion == true);
        expect(tester.getSemantics(live).getSemanticsData().label, '连接已断开');
        expect(tester.getSemantics(live).getSemanticsData().flagsCollection.isLiveRegion, isTrue);
        await tester.pump(const Duration(seconds: 2));
        expect(tester.getSemantics(live).getSemanticsData().label, '连接已断开');
        semantics.dispose();
      });
    }
  }

  group('crowded', () {
    const long = '修复登录页重复提交并补上连点测试';
    for (final width in [360.0, 390.0]) {
      for (final scale in [1.0, 1.3, 1.5, 2.0]) {
        for (final agents in [false, true]) {
          for (final title in ['修复登录重复提交', long]) {
            final name =
                '$width × $scale${agents ? ', agents' : ''}'
                '${title == long ? ', long title' : ''}';
            testWidgets('gives way in order: $name', (tester) async {
              await _pump(tester, width: width, scale: scale, title: title, status: '本机', agents: agents);
              expect(tester.takeException(), isNull);
              final pill = _rect(tester, 'chat-title-pill');
              final menu = _rect(tester, 'chat-menu');
              final fresh = _rect(tester, 'chat-new-chat');
              final chip = _chip(tester);

              // The mirror holds and every gap is 8.
              expect(menu.size, const Size.square(44));
              expect(fresh.size, menu.size);
              expect(menu.left, 12);
              expect(width - fresh.right, 12);
              expect(pill.left - menu.right, closeTo(8, 0.01));
              expect(fresh.left - chip.right, closeTo(8, 0.01));
              final next = agents
                  ? tester.getRect(
                      find.descendant(of: find.byType(HeaderAgentsKey), matching: find.byType(GlassSurface)).first,
                    )
                  : chip;
              if (agents) expect(chip.left - next.right, closeTo(8, 0.01));
              expect(next.left - pill.right, greaterThanOrEqualTo(8 - 0.01));
              for (final piece in [menu, fresh, chip, next]) {
                expect(piece.center.dy, closeTo(pill.center.dy, 0.1));
              }

              // The host is always whole.
              expect(_paragraph(tester, '本机').didExceedMaxLines, isFalse);

              final titleText = _paragraph(tester, title);
              final words = _chipWords(tester);
              final compact = words == null;
              if (compact) {
                expect(chip.width, closeTo(ModelChip.compactWidth, 0.01));
              }
              final depth = words?.text.toPlainText().contains('·') ?? false;
              final em = scale * 15;

              // 「· 高」 goes before anything is cut, so it never shows
              // cut itself (no 「V41 Flash · …」).
              if (depth) {
                expect(words!.didExceedMaxLines, isFalse);
                expect(titleText.didExceedMaxLines, isFalse);
              }
              if (titleText.didExceedMaxLines || (words?.didExceedMaxLines ?? true)) {
                expect(depth, isFalse);
              }
              // The title keeps its first four characters unless the chip
              // has nothing left to give.
              if (!compact) {
                expect(
                  titleText.size.width,
                  greaterThanOrEqualTo(
                    titleText.getMaxIntrinsicWidth(double.infinity) < em * 5
                        ? titleText.getMaxIntrinsicWidth(double.infinity) - 1
                        : em * 5 - 1,
                  ),
                );
              }
              // The model's name is cut only once the title is down to
              // that minimum.
              if (words != null && words.didExceedMaxLines) {
                expect(titleText.size.width, lessThanOrEqualTo(em * 5 + 1));
              }
              // On a 390 phone at the default size there is room for the
              // title's start and the model's whole name without the
              // capsule; with it, the title still shows four characters.
              if (scale == 1 && width == 390 && !agents) {
                expect(words, isNotNull);
                expect(words!.didExceedMaxLines, isFalse);
              }
              if (scale == 1) {
                expect(
                  titleText.size.width,
                  greaterThanOrEqualTo(em * 4 - 1),
                  reason: 'at least three characters and the ellipsis',
                );
              }
            });
          }
        }
      }
    }

    testWidgets('a short title leaves the chip whole, depth included', (tester) async {
      await _pump(tester, width: 360, scale: 1, title: '新对话', status: '本机');
      final words = _chipWords(tester)!;
      expect(words.text.toPlainText(), 'V4 Pro · 高');
      expect(words.didExceedMaxLines, isFalse);
      expect(_paragraph(tester, '新对话').didExceedMaxLines, isFalse);
    });

    testWidgets('the depth is still read out when it is not shown', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pump(tester, width: 360, scale: 1, title: long, status: '本机');
      expect(find.text('V4 Pro · 高'), findsNothing);
      expect(find.text('V4 Pro'), findsOneWidget);
      expect(
        tester.getSemantics(find.bySemanticsLabel('模型：V4 Pro，思考深度高')),
        isSemantics(isButton: true, hasTapAction: true),
      );
      semantics.dispose();
    });
  });
}
