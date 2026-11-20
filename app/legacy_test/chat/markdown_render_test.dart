// What a reply renders: maths, workspace images, and the rest of the
// Markdown a model writes (alerts, details, HTML bits, tables, lists, code),
// plus the streaming tail and a long-reply timing.

import 'dart:typed_data';

import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/render/code_block.dart';
import 'package:dsh_app/ui/chat/render/markdown_blocks.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/chat/render/markdown_image.dart';
import 'package:dsh_app/ui/chat/render/markdown_math.dart';
import 'package:dsh_app/ui/common/streaming_cursor.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:val_latex_flutter/val_latex_flutter.dart' show Math;

import 'support/harness.dart';
import 'support/markdown_samples.dart';

/// Every piece of text the reply painted, as plain text.
String _paintedText(WidgetTester tester) => [
  // Subclasses too: gpt_markdown paints paragraphs with code or taps in a
  // `BidiRichText`.
  for (final text in tester.widgetList<RichText>(find.byWidgetPredicate((w) => w is RichText))) text.text.toPlainText(),
].join('\n');

/// Hands back [image] (or throws [error]) for every path, recording asks.
class _FakeReader implements WorkspaceImageReader {
  _FakeReader({this.image, this.error});

  final LoadedImage? image;
  final Object? error;
  final calls = <(String, String)>[];

  @override
  Future<LoadedImage> read(String sessionId, String path) async {
    calls.add((sessionId, path));
    if (error != null) throw error!;
    return image!;
  }
}

List<Override> _imageOverrides(_FakeReader reader, {String session = 's1'}) => [
  workspaceImageReaderProvider.overrideWithValue(CachedImageReader(reader)),
  activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(fakeConnection)),
  currentSessionProvider.overrideWith(() => FixedSession(session)),
  sessionsProvider.overrideWith(FakeSessions.new),
  chatProvider.overrideWith2((id) => FakeChatController(id, const ChatState(loading: false))),
];

Widget _reply(String text, {bool streaming = false, double width = 358}) => Material(
  type: MaterialType.transparency,
  child: Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      width: width,
      child: SingleChildScrollView(
        child: MarkdownBody(text: text, streaming: streaming, selectable: false),
      ),
    ),
  ),
);

void main() {
  setUpAll(loadTestFonts);

  group('maths', () {
    testWidgets('formulas render as maths, not source', (tester) async {
      await tester.pumpWidget(testApp(_reply(mathReply)));
      await tester.pump();
      expect(tester.takeException(), isNull);
      // Five inline `$…$` (three in the list), one `\(…\)`, two display blocks.
      expect(find.byType(MathFormula), findsNWidgets(8));
      expect(find.byType(Math), findsNWidgets(8));
      expect(find.byType(MathSource), findsNothing);
      final text = _paintedText(tester);
      expect(text, isNot(contains(r'\frac')));
      expect(text, isNot(contains(r'$E')));
      expect(text, isNot(contains(r'\begin')));
      // Prices and code stay as written.
      expect(text, contains(r'$5 and $10'));
      expect(text, contains(r'$HOME'));
    });

    testWidgets('a formula that does not parse shows its source, muted', (tester) async {
      await tester.pumpWidget(testApp(_reply(r'坏公式 $\frac{a}{$ 之后')));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(MathSource), findsOneWidget);
      final source = tester.widget<Text>(find.descendant(of: find.byType(MathSource), matching: find.byType(Text)));
      expect(source.textSpan!.toPlainText(), r'\frac{a}{');
      final context = tester.element(find.byType(MathSource));
      expect(source.style?.color, isNot(Theme.of(context).colorScheme.error));
      expect(source.style?.fontFamily, 'JetBrainsMono');
    });

    testWidgets('a display formula wider than the column scrolls instead of overflowing', (tester) async {
      final wide = '\$\$${List.generate(40, (i) => 'a_{$i}').join(' + ')}\$\$';
      await tester.pumpWidget(testApp(_reply(wide, width: 300)));
      await tester.pump();
      expect(tester.takeException(), isNull);
      final scroll = find.descendant(of: find.byType(MathFormula), matching: find.byType(SingleChildScrollView));
      expect(scroll, findsOneWidget);
      expect(tester.getSize(scroll).width, lessThanOrEqualTo(300));
    });

    testWidgets('formulas and images inside table cells lay out', (tester) async {
      for (final table in [
        '| 公式 | 说明 |\n|---|---|\n| \$\$x^2\$\$ | 块 |\n| \$y\$ | 行内 |',
        '| 图 | 说明 |\n|---|---|\n| ![](https://example.com/a.png) | 网图 |',
      ]) {
        await tester.pumpWidget(testApp(_reply(table)));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: table);
        expect(find.byType(Table), findsOneWidget);
      }
    });

    testWidgets('a display formula still streaming shows its source until it closes', (tester) async {
      await tester.pumpWidget(testApp(_reply('矩阵：\n\n\$\$\n\\begin{pmatrix} a & b', streaming: true)));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(Math), findsNothing);
      expect(find.byType(MathSource), findsOneWidget);
      // The cursor follows the source that has arrived.
      expect(find.descendant(of: find.byType(MathSource), matching: find.byType(StreamingCursor)), findsOneWidget);

      await tester.pumpWidget(
        testApp(_reply('矩阵：\n\n\$\$\n\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}\n\$\$', streaming: true)),
      );
      await tester.pump();
      expect(find.byType(MathSource), findsNothing);
      expect(find.byType(Math), findsOneWidget);
      expect(find.byType(StreamingCursor), findsOneWidget);
    });

    testWidgets('maths inside code stays literal', (tester) async {
      await tester.pumpWidget(testApp(_reply('行内 `\$x\$`\n\n```tex\n\$\$\\frac{a}{b}\$\$\n```')));
      await tester.pump();
      expect(find.byType(Math), findsNothing);
      expect(tester.widget<CodeBlock>(find.byType(CodeBlock)).code, contains(r'$$\frac{a}{b}$$'));
    });

    testWidgets('inline maths follows the chat text scale', (tester) async {
      Future<double> heightAt(double scale) async {
        await tester.pumpWidget(
          testApp(
            MediaQuery(
              data: const MediaQueryData(size: Size(800, 600)).copyWith(textScaler: TextScaler.linear(scale)),
              child: _reply(r'分式 $\frac{a}{b}$ 也是'),
            ),
          ),
        );
        await tester.pump();
        // Global: the paragraph scales its inline widgets by a transform.
        return tester.getRect(find.byType(Math)).height;
      }

      final normal = await heightAt(1);
      final large = await heightAt(1.3);
      expect(large / normal, closeTo(1.3, 0.05));
    });
  });

  group('image paths', () {
    test('sources are classified', () {
      expect(imageSourceOf('test-image.jpg'), isA<WorkspaceImageSource>());
      expect((imageSourceOf('out/my%20chart.png') as WorkspaceImageSource).path, 'out/my chart.png');
      expect((imageSourceOf('<out/a b.png>') as WorkspaceImageSource).path, 'out/a b.png');
      expect((imageSourceOf('file:///root/workspace/x.png') as WorkspaceImageSource).path, '/root/workspace/x.png');
      expect((imageSourceOf('/root/workspace/x.png#top') as WorkspaceImageSource).path, '/root/workspace/x.png');
      expect(imageSourceOf('https://example.com/a.png'), isA<WebImageSource>());
      expect(imageSourceOf('HTTP://example.com/a.png'), isA<WebImageSource>());
      expect(imageSourceOf('data:image/png;base64,AAAA'), isA<DataImageSource>());
      expect(imageSourceOf('javascript:alert(1)'), isA<UnsupportedImageSource>());
      expect(imageSourceOf('intent://x#Intent;end'), isA<UnsupportedImageSource>());
      expect(imageSourceOf(r'C:\out\a.png'), isA<WorkspaceImageSource>());
    });

    test('relative paths resolve against the folder, the session, or the local workspace', () {
      expect(workspaceImagePath('test-image.jpg', cwd: '/root/workspace/proj'), '/root/workspace/proj/test-image.jpg');
      expect(workspaceImagePath('./img/../a.png', cwd: '/w'), '/w/a.png');
      expect(workspaceImagePath('a.png', baseDir: '/w/docs', cwd: '/w'), '/w/docs/a.png');
      expect(workspaceImagePath('a.png', local: true), '/root/workspace/a.png');
      // A remote Host resolves a relative path against the session itself.
      expect(workspaceImagePath('a.png'), 'a.png');
      expect(workspaceImagePath('/root/workspace/x.png', cwd: '/elsewhere'), '/root/workspace/x.png');
    });

    test('display names', () {
      expect(imageDisplayName('out/test-image.jpg'), 'test-image.jpg');
      expect(imageDisplayName('https://example.com/img/cat.png?size=2'), 'cat.png');
      expect(imageDisplayName('data:image/png;base64,AAAA'), '图片');
    });
  });

  group('workspace images', () {
    testWidgets('a relative image is read through the workspace reader, once', (tester) async {
      final provider = MemoryImage(tinyPng);
      final reader = _FakeReader(image: RasterImage(provider));
      final overrides = _imageOverrides(reader);
      await tester.pumpWidget(testApp(_reply('图：\n\n![测试图](test-image.jpg)'), overrides: overrides));
      expect(reader.calls, [('s1', '/root/workspace/test-image.jpg')]);
      final context = tester.element(find.byType(MarkdownImage));
      final inline = inlineImageProvider(provider, MediaQuery.devicePixelRatioOf(context), null);
      await tester.runAsync(() => precacheImage(inline, context));
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      final image = find.descendant(of: find.byType(MarkdownImage), matching: find.byType(Image));
      expect(image, findsOneWidget);
      expect(find.byIcon(AppIcons.imageBroken), findsNothing);
      // Rounded and no wider than the column.
      expect(tester.getSize(image).width, lessThanOrEqualTo(358));

      // Scrolled away and back (a new widget): served from the cache.
      await tester.pumpWidget(testApp(const SizedBox(), overrides: overrides));
      await tester.pumpWidget(testApp(_reply('图：\n\n![测试图](test-image.jpg)'), overrides: overrides));
      expect(reader.calls, hasLength(1));
    });

    testWidgets('a previewed Markdown file resolves images from its own folder', (tester) async {
      final reader = _FakeReader(image: RasterImage(MemoryImage(tinyPng)));
      await tester.pumpWidget(
        testApp(
          MarkdownImageScope(
            sessionId: 's9',
            baseDir: '/root/workspace/docs',
            child: _reply('![](img/a.png) ![](/abs/b.png)'),
          ),
          overrides: _imageOverrides(reader),
        ),
      );
      expect(reader.calls, unorderedEquals([('s9', '/root/workspace/docs/img/a.png'), ('s9', '/abs/b.png')]));
    });

    testWidgets('an image that cannot be read shows its name and why, and retries on tap', (tester) async {
      final reader = _FakeReader(error: const ArtifactError('missing'));
      await tester.pumpWidget(testApp(_reply('![](out/test-image.jpg)'), overrides: _imageOverrides(reader)));
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('test-image.jpg'), findsOneWidget);
      expect(find.text('找不到图片 · 轻点重试'), findsOneWidget);
      expect(find.byIcon(AppIcons.imageBroken), findsOneWidget);
      await tester.tap(find.text('test-image.jpg'));
      await tester.pump();
      expect(reader.calls, hasLength(2));
    });

    testWidgets('a data: image draws without the workspace', (tester) async {
      final reader = _FakeReader(error: StateError('unused'));
      final url = Uri.dataFromBytes(Uint8List.fromList(tinyPng), mimeType: 'image/png').toString();
      await tester.pumpWidget(testApp(_reply('![]($url)'), overrides: _imageOverrides(reader)));
      await tester.pump();
      expect(reader.calls, isEmpty);
      expect(find.descendant(of: find.byType(MarkdownImage), matching: find.byType(Image)), findsOneWidget);
    });
  });

  group('the rest of a reply', () {
    testWidgets('a task item: its box takes the bullet\'s place, its text stays on the column', (tester) async {
      await tester.pumpWidget(testApp(_reply('- 普通一项\n- [ ] 待办一项\n  - [x] 子任务\n- 又一项')));
      await tester.pump();
      double left(String label) => tester
          .renderObjectList<RenderParagraph>(find.byType(RichText))
          .firstWhere((p) => p.text.toPlainText().trim() == label)
          .localToGlobal(Offset.zero)
          .dx;
      final margin = tester.getTopLeft(find.byType(MarkdownBody)).dx;
      final column = left('普通一项');
      final gutter = column - margin;
      expect(left('待办一项'), moreOrLessEquals(column, epsilon: 0.5));
      // The box hangs into the gutter, TaskBox.gap before the text.
      final box = tester.getRect(find.byIcon(AppIcons.checkboxOff));
      expect(box.right + TaskBox.gap, moreOrLessEquals(column, epsilon: 0.5));
      expect(box.left, greaterThanOrEqualTo(margin - 0.5));
      // A nested task keeps its level: one gutter further in.
      expect(left('子任务'), moreOrLessEquals(column + gutter, epsilon: 0.5));
    });

    testWidgets('GitHub alerts are tinted callouts with Chinese titles', (tester) async {
      await tester.pumpWidget(testApp(_reply(quotesReply)));
      await tester.pump();
      final text = _paintedText(tester);
      for (final title in ['注意', '提示', '重要', '警告', '小心']) {
        expect(text, contains(title));
      }
      expect(text, isNot(contains('[!NOTE]')));
      expect(text, isNot(contains('Note')));
    });

    testWidgets('HTML bits render, never as raw tags', (tester) async {
      await tester.pumpWidget(testApp(_reply(miscReply)));
      await tester.pump();
      expect(tester.takeException(), isNull);
      final text = _paintedText(tester);
      for (final tag in ['<sup>', '<sub>', '<kbd>', '<u>', '<mark>', '<br>', '<details>', '<summary>']) {
        expect(text, isNot(contains(tag)), reason: tag);
      }
      expect(text, contains('状态: 运行中'));
    });

    testWidgets('details start closed and open on tap', (tester) async {
      await tester.pumpWidget(testApp(_reply(miscReply)));
      await tester.pump();
      expect(find.byType(MarkdownDisclosure), findsOneWidget);
      expect(_paintedText(tester), isNot(contains('折叠起来的内容')));
      await tester.tap(find.text('展开细节'));
      await tester.pumpAndSettle();
      expect(_paintedText(tester), contains('折叠起来的内容'));
    });

    testWidgets('long URLs and words wrap instead of overflowing', (tester) async {
      await tester.pumpWidget(testApp(_reply(miscReply, width: 300)));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a wide table scrolls sideways, also at the largest text size', (tester) async {
      for (final scale in [1.0, 1.3]) {
        await tester.pumpWidget(
          testApp(
            MediaQuery(
              data: const MediaQueryData(size: Size(390, 844)).copyWith(textScaler: TextScaler.linear(scale)),
              child: _reply(tableReply),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        final table = find.byType(Table);
        expect(table, findsOneWidget);
        expect(
          find.ancestor(
            of: table,
            matching: find.byWidgetPredicate((w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal),
          ),
          findsOneWidget,
        );
        // Inline Markdown inside cells renders as such.
        expect(_paintedText(tester), isNot(contains('**默认**')));
      }
    });

    testWidgets('one-digit lists keep the 1.375 em column', (tester) async {
      await tester.pumpWidget(testApp(_reply('1. 甲\n2. 乙\n\n- 圆点项')));
      await tester.pump();
      final start = tester.getTopLeft(find.byType(MarkdownBody)).dx;
      final body = AppType.chatBody(tester.element(find.byType(MarkdownBody))).fontSize!;
      for (final text in ['甲', '乙', '圆点项']) {
        expect(tester.getTopLeft(find.text(text, findRichText: true)).dx - start, closeTo(body * listGutterEm, 0.01));
      }
    });

    for (final count in [12, 101]) {
      testWidgets('numbers up to $count show whole and every item keeps one text column', (tester) async {
        final items = List.generate(count, (i) => '${i + 1}. 第 ${i + 1} 项').join('\n');
        await tester.pumpWidget(testApp(_reply('$items\n\n- 圆点项', width: 358)));
        await tester.pump();
        expect(tester.takeException(), isNull);
        final listItems = find.byType(ListItem);
        final left = tester.getTopLeft(find.byType(MarkdownBody)).dx;
        double? column;
        for (final element in listItems.evaluate()) {
          final geometry = element.renderObject! as ListItemGeometry;
          final box = element.renderObject! as RenderBox;
          final origin = box.localToGlobal(Offset.zero).dx;
          final marker = geometry.markerRect;
          if (marker != null) {
            // Painted inside the item and inside the reply: no digit is cut.
            expect(marker.left, greaterThanOrEqualTo(0));
            expect(origin + marker.left, greaterThanOrEqualTo(left));
            expect(marker.right, lessThanOrEqualTo(geometry.textStart));
          }
          if (marker == null) {
            // The bullet list below is a list of its own: standard column.
            expect(geometry.textStart, closeTo(AppType.chatBody(element).fontSize! * listGutterEm, 0.01));
            continue;
          }
          column ??= origin + geometry.textStart;
          expect(origin + geometry.textStart, closeTo(column, 0.5));
        }
        // The widest number's own width fits in front of the text.
        final last = listItems.evaluate().firstWhere((e) => (e.widget as ListItem).marker == '$count.');
        final rect = (last.renderObject! as ListItemGeometry).markerRect!;
        final painter = TextPainter(
          text: TextSpan(text: '$count.', style: AppType.tabular(AppType.chatBody(last))),
          textDirection: TextDirection.ltr,
        )..layout();
        expect(rect.width, closeTo(painter.width, 0.5));
        painter.dispose();
      });
    }

    testWidgets('a list reaching 10 widens only itself; lists above stay put', (tester) async {
      // The streaming cursor rides at the end of the last item.
      double textX(String text) => tester
          .getTopLeft(
            find.byWidgetPredicate(
              (w) => w is RichText && w.text.toPlainText().replaceAll('\uFFFC', '').trim() == text,
            ),
          )
          .dx;
      String reply(int count) =>
          '1. 上面的列表\n2. 已经读过\n\n- 圆点项\n\n${List.generate(count, (i) => '${i + 1}. 第 ${i + 1} 项').join('\n')}';
      await tester.pumpWidget(testApp(_reply(reply(9), streaming: true)));
      await tester.pump();
      final above = textX('上面的列表');
      final bullet = textX('圆点项');
      final nine = textX('第 9 项');
      expect(nine, above);

      await tester.pumpWidget(testApp(_reply(reply(10), streaming: true)));
      await tester.pump();
      expect(tester.takeException(), isNull);
      // Nothing outside the growing list moved.
      expect(textX('上面的列表'), above);
      expect(textX('已经读过'), above);
      expect(textX('圆点项'), bullet);
      // The growing list widened once, all of its items together.
      final widened = textX('第 10 项');
      expect(widened, greaterThan(nine));
      for (var i = 1; i <= 9; i++) {
        expect(textX('第 $i 项'), widened, reason: '第 $i 项');
      }
    });

    testWidgets('a nested list measures its own numbers', (tester) async {
      final nested = List.generate(10, (i) => '   ${i + 1}. 子项 ${i + 1}').join('\n');
      await tester.pumpWidget(testApp(_reply('1. 父项\n$nested\n2. 父项二')));
      await tester.pump();
      expect(tester.takeException(), isNull);
      final start = tester.getTopLeft(find.byType(MarkdownBody)).dx;
      final body = AppType.chatBody(tester.element(find.byType(MarkdownBody))).fontSize!;
      Finder starting(String text) =>
          find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().startsWith(text)).last;
      // The parent list is one-digit: it keeps the standard column.
      final parent = tester.getTopLeft(starting('父项二')).dx;
      expect(parent - start, closeTo(body * listGutterEm, 0.01));
      // The nested list widened its own column, relative to the parent text.
      final one = tester.getTopLeft(find.text('子项 1', findRichText: true)).dx;
      final ten = tester.getTopLeft(find.text('子项 10', findRichText: true)).dx;
      // (The paragraph places its last placeholder a quarter pixel apart.)
      expect(ten, closeTo(one, 0.5));
      expect(one - parent, greaterThan(body * listGutterEm));
    });

    testWidgets('a nested list reaching 10 while streaming widens all its items at once', (tester) async {
      String reply(int count) => '1. 父项\n${List.generate(count, (i) => '   ${i + 1}. 子项 ${i + 1}').join('\n')}';
      double textX(String text) => tester
          .getTopLeft(
            find.byWidgetPredicate(
              (w) => w is RichText && w.text.toPlainText().replaceAll('\uFFFC', '').trim() == text,
            ),
          )
          .dx;
      await tester.pumpWidget(testApp(_reply(reply(9), streaming: true)));
      await tester.pump();
      final parent = textX('父项');
      final narrow = textX('子项 1');
      await tester.pumpWidget(testApp(_reply(reply(10), streaming: true)));
      await tester.pump();
      expect(textX('父项'), parent);
      final wide = textX('子项 10');
      expect(wide, greaterThan(narrow));
      for (var i = 1; i <= 9; i++) {
        expect(textX('子项 $i'), closeTo(wide, 0.5), reason: '子项 $i');
      }
    });

    testWidgets('a nested list hangs its markers under the parent text', (tester) async {
      await tester.pumpWidget(testApp(_reply('- 父项\n  - 子项')));
      await tester.pump();
      final start = tester.getTopLeft(find.byType(MarkdownBody)).dx;
      Finder starting(String text) =>
          find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().startsWith(text)).last;
      final parent = tester.getTopLeft(starting('父项')).dx;
      final child = tester.getTopLeft(starting('子项')).dx;
      // One gutter per level.
      expect(child - parent, closeTo(parent - start, 0.5));
    });

    testWidgets('code blocks: wrap toggle, diff rows, Mermaid label', (tester) async {
      await tester.pumpWidget(testApp(Material(child: _reply(codeReply))));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Mermaid 图表'), findsOneWidget);
      expect(find.text('预览'), findsOneWidget);
      // Diff lines carry the diff colours across the whole row.
      final rows = tester.widgetList<Container>(
        find.descendant(of: find.byType(CodeBlock).at(1), matching: find.byType(Container)),
      );
      expect(rows.where((c) => c.color != null), hasLength(3)); // hunk, -, +
      // Long lines scroll until wrapping is switched on.
      final first = find.byType(CodeBlock).first;
      Finder sideways() => find.descendant(
        of: first,
        matching: find.byWidgetPredicate((w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal),
      );
      expect(sideways(), findsOneWidget);
      await tester.tap(find.descendant(of: first, matching: find.byTooltip('自动换行')));
      await tester.pump();
      expect(sideways(), findsNothing);
    });

    testWidgets('dsh-ui blocks still render as cards', (tester) async {
      await tester.pumpWidget(
        testApp(
          _reply(
            '看这里：\n\n```dsh-ui\n{"type":"stack","title":"选一个方案","children":[\n'
            ' {"type":"options","id":"plan","options":[{"label":"方案 A"},{"label":"方案 B"}]}]}\n```',
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(CodeBlock), findsNothing);
      expect(find.text('选一个方案', findRichText: true), findsOneWidget);
    });
  });

  group('streaming', () {
    testWidgets('half-written markup never shows its markers', (tester) async {
      for (final (text, hidden) in [
        ('这是 **重点', '**'),
        ('运行 `npm ins', '`'),
        ('前文\n\n| 模型 | 价格 |', '|'),
        ('见[文档](https://exa', 'https://exa'),
      ]) {
        await tester.pumpWidget(testApp(_reply(text, streaming: true)));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: text);
        expect(_paintedText(tester), isNot(contains(hidden)), reason: text);
        expect(find.byType(StreamingCursor), findsOneWidget, reason: text);
      }
    });

    testWidgets('the cursor rides after a closed fence and inside a table row', (tester) async {
      await tester.pumpWidget(testApp(_reply('```dart\nprint(1);\n```', streaming: true)));
      await tester.pump();
      expect(find.byType(StreamingCursor), findsOneWidget);
      expect(_paintedText(tester), isNot(contains('```')));

      await tester.pumpWidget(testApp(_reply('| a | b |\n|---|---|\n| 1 | 2 |', streaming: true)));
      await tester.pump();
      expect(find.byType(StreamingCursor), findsOneWidget);
      final table = tester.widget<Table>(find.byType(Table));
      expect(table.children.first.children, hasLength(2)); // no stray third column
    });
  });

  testWidgets('a 3000-line reply lays out in reasonable time', (tester) async {
    final lines = <String>[];
    for (var i = 0; i < 300; i++) {
      lines
        ..add('## 第 $i 节')
        ..add('正文第 $i 段，含 **粗体**、`code`、公式 \$x_$i^2\$ 和价格 \$5 与 \$10。')
        ..add('')
        ..add('- 列表项 $i')
        ..add('- 另一项')
        ..add('')
        ..add('```dart')
        ..add('final v$i = $i;')
        ..add('```');
      while (lines.length % 10 != 0) {
        lines.add('');
      }
    }
    final text = lines.join('\n');
    expect(text.split('\n').length, greaterThanOrEqualTo(3000));
    final prepare = Stopwatch()..start();
    MarkdownBody.prepareSource(text, streaming: true);
    prepare.stop();
    final build = Stopwatch()..start();
    await tester.pumpWidget(testApp(_reply(text, streaming: true)));
    build.stop();
    // A token arriving: only the tail segment is rebuilt (the gpt_markdown
    // segment cache), so this stays far below the first build.
    final append = Stopwatch()..start();
    await tester.pumpWidget(testApp(_reply('$text\n\n追加的一句', streaming: true)));
    append.stop();
    final next = Stopwatch()..start();
    await tester.pumpWidget(testApp(_reply('$text\n\n追加的一句话', streaming: true)));
    next.stop();
    // ignore: avoid_print
    print(
      '3000-line reply: prepare ${prepare.elapsedMilliseconds} ms, '
      'first build+layout ${build.elapsedMilliseconds} ms, '
      'token appends ${append.elapsedMilliseconds} / ${next.elapsedMilliseconds} ms (debug, test engine)',
    );
    expect(tester.takeException(), isNull);
    expect(prepare.elapsedMilliseconds, lessThan(200));
  });
}
