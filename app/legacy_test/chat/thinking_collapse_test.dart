// 展开的思考正文本身也是收起的落点:点它和再点一次头部等价 —— 回到三行
// 实时窗口(思考中)或行内预览(一轮结束)。正文里的链接、译文切换按钮
// 是更靠里的手势目标,不能被收起吞掉。
//
// 正文自带文本选择(SelectionArea),选择区自己也装了一个 tap 手势,而且比
// 外层包装更先摸到指针;控件因此把选择区套在收起手势的**外面**(见
// thinking_pill.dart 的 _CollapsibleReasoningBody)。这里用真实的点击路径
// 验证,不直接调回调。

import 'dart:ui' as ui;

import 'package:dsh_app/links/app_links.dart';
import 'package:dsh_app/links/page_links.dart';
import 'package:dsh_app/state/cot_translation_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/chat/widgets/thinking_pill.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const _reasoning = '第一段思考:先确认按钮在请求期间是否禁用。\n\n第二段:再补一个连点测试。';
const _preview = '第一段思考:先确认按钮在请求期间是否禁用。';

const _english = 'The user wants double taps on the login button to send one request.';
const _translated = '用户希望连点登录按钮时只发出一次请求。';
const _limits = CotTranslationLimits(
  maxTextChars: 4000,
  provider: 'bing',
  targetLanguage: 'auto',
  availableProviders: ['bing', 'google'],
);

Widget _app(ThinkingPill pill) => testApp(
  Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Align(alignment: Alignment.topLeft, child: pill),
      ),
    ),
  ),
);

Finder get _body => find.byType(MarkdownBody);
Finder get _ticker => find.byType(ThinkingTicker);

Future<void> _expand(WidgetTester tester, {bool active = false}) async {
  await tester.tap(find.text(active ? '思考中' : '思考'));
  await pumpFrames(tester, 6);
}

/// 正文里一段 [label] 文字的中心点(按排版框量,而不是猜坐标)。
Offset _labelCenter(WidgetTester tester, String label) {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(
      of: _body,
      matching: find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains(label)),
    ),
  );
  final text = paragraph.text.toPlainText();
  final start = text.indexOf(label);
  final box = paragraph
      .getBoxesForSelection(TextSelection(baseOffset: start, extentOffset: start + label.length))
      .first;
  return paragraph.localToGlobal(Offset((box.left + box.right) / 2, (box.top + box.bottom) / 2));
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('tapping the open body folds back to the live window while thinking', (tester) async {
    await tester.pumpWidget(_app(const ThinkingPill(reasoning: _reasoning, active: true)));
    await pumpFrames(tester, 4);
    expect(_ticker, findsOneWidget);

    await _expand(tester, active: true);
    expect(_body, findsOneWidget);
    expect(_ticker, findsNothing);

    await tester.tapAt(tester.getCenter(_body));
    await pumpFrames(tester, 8);
    expect(_ticker, findsOneWidget);
    expect(_body, findsNothing);
  });

  testWidgets('tapping the open body after the turn returns to the inline preview', (tester) async {
    await tester.pumpWidget(_app(const ThinkingPill(reasoning: _reasoning)));
    await pumpFrames(tester, 2);
    expect(find.text(_preview), findsOneWidget);

    await _expand(tester);
    expect(_body, findsOneWidget);
    expect(_ticker, findsNothing);

    await tester.tapAt(tester.getCenter(_body));
    await pumpFrames(tester, 8);
    expect(_body, findsNothing);
    expect(find.text(_preview), findsOneWidget);
  });

  testWidgets('the header still toggles the body on its own', (tester) async {
    await tester.pumpWidget(_app(const ThinkingPill(reasoning: _reasoning)));
    await pumpFrames(tester, 2);

    await _expand(tester);
    expect(_body, findsOneWidget);

    // 再点头部:收起。
    await tester.tap(find.text('思考'));
    await pumpFrames(tester, 8);
    expect(_body, findsNothing);
    expect(find.text(_preview), findsOneWidget);

    // 还能再点开。
    await _expand(tester);
    expect(_body, findsOneWidget);
  });

  testWidgets('a link in the open body opens its page and does not fold the body', (tester) async {
    final links = AppLinks();
    final router = LinkRouter(links.links, grace: Duration.zero);
    final opened = <String>[];
    addTearDown(() {
      router.dispose();
      links.dispose();
    });
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: SafeArea(
            child: Stack(
              children: [
                const LinkHost(),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: ThinkingPill(reasoning: '先看看[打开手机操控](dshgo://open/phone)再决定。\n\n第二段。'),
                ),
              ],
            ),
          ),
        ),
        overrides: [
          linkRouterProvider.overrideWithValue(router),
          pageLinkResolverProvider.overrideWithValue((id, _) {
            opened.add(id);
            return Scaffold(body: Text('page $id'));
          }),
        ],
      ),
    );
    await pumpFrames(tester, 2);
    await _expand(tester);

    await tester.tapAt(_labelCenter(tester, '打开手机操控'));
    await tester.pumpAndSettle();
    expect(opened, ['phone']);
    expect(find.text('page phone'), findsOneWidget);

    // 链接吞掉了这次点击:回到上面,思考正文还是展开的。
    Navigator.of(tester.element(find.text('page phone'))).pop();
    await tester.pumpAndSettle();
    expect(_body, findsOneWidget);
    expect(_ticker, findsNothing);
  });

  testWidgets('the translate chip toggles in place and does not fold the body', (tester) async {
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ThinkingPill(reasoning: _english),
            ),
          ),
        ),
        overrides: [
          currentSessionProvider.overrideWith(() => FixedSession('s1')),
          cotTranslationProvider.overrideWith((ref) async => _limits),
          reasoningTranslatorProvider.overrideWithValue((text, {required limits, sessionId}) async => _translated),
        ],
      ),
    );
    await pumpFrames(tester, 2);
    await _expand(tester);
    expect(find.text('翻译'), findsOneWidget);

    await tester.tap(find.text('翻译'));
    await pumpFrames(tester, 4);
    expect(find.text(_translated), findsOneWidget);
    // 工具栏不在收起手势里:切译文不会把正文收起来。
    expect(_body, findsOneWidget);
    expect(_ticker, findsNothing);

    await tester.tap(find.text('查看原文'));
    await pumpFrames(tester, 2);
    expect(find.textContaining('double taps'), findsOneWidget);
    expect(_body, findsOneWidget);
  });

  testWidgets('the open body advertises a collapse action; the header keeps its expanded flag', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app(const ThinkingPill(reasoning: '只有一段思考。')));
    await pumpFrames(tester, 2);

    final collapsed = tester.getSemantics(find.text('思考')).getSemanticsData();
    expect(collapsed.flagsCollection.isExpanded, ui.Tristate.isFalse);

    await _expand(tester);
    final header = tester.getSemantics(find.text('思考')).getSemanticsData();
    expect(header.flagsCollection.isButton, isTrue);
    expect(header.flagsCollection.isExpanded, ui.Tristate.isTrue);

    final bodySemantics = find.byWidgetPredicate((w) => w is Semantics && w.properties.hint == '收起');
    expect(bodySemantics, findsOneWidget);
    final data = tester.getSemantics(bodySemantics).getSemanticsData();
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    expect(data.hint, '收起');
    handle.dispose();
  });

  testWidgets('dragging the open body scrolls the list instead of folding', (tester) async {
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ListView(
            children: [
              const ThinkingPill(reasoning: _reasoning),
              for (var i = 0; i < 20; i++) SizedBox(height: 100, child: Text('row $i')),
            ],
          ),
        ),
      ),
    );
    await pumpFrames(tester, 2);
    await _expand(tester);
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).first);
    expect(scrollable.position.pixels, 0);

    // 从正文里一个确定落在文字上的点开始拖(不校验 finder 的 render box:
    // MarkdownBody 这个 finder 落在包装层上,不参与命中)。
    await tester.dragFrom(tester.getTopLeft(_body) + const Offset(120, 12), const Offset(0, -40));
    await pumpFrames(tester, 8);
    expect(scrollable.position.pixels, greaterThan(0));
    // 拖动不该被当成点按:正文还是展开的。
    expect(_body, findsOneWidget);
    expect(_ticker, findsNothing);
  });
}
