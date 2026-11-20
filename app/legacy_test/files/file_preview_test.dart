// File previews: text page by page up to the cap, Markdown front matter,
// CSV and XLSX tables, large / binary / unsupported files, and following the
// file as the agent changes or deletes it.

import 'dart:io';

import 'package:dsh_app/ui/chat/artifact_preview.dart';
import 'package:dsh_app/ui/chat/render/code_block.dart';
import 'package:dsh_app/ui/files/table_view.dart';
import 'package:dsh_app/ui/session/workspace_files.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'support/files_harness.dart';
import 'support/xlsx_builder.dart';

Future<MemoryWorkspace> _open(WidgetTester tester, String rel, {MemoryWorkspace? workspace}) async {
  usePhoneView(tester);
  final ws = workspace ?? sampleWorkspace();
  await tester.pumpWidget(filesApp(FilePreviewPage(sessionId: 's1', path: '${ws.root}/$rel'), ws));
  await pumpFrames(tester, 8);
  return ws;
}

Finder _text(String text) => find.textContaining(text, findRichText: true);

int _count(MemoryWorkspace ws, String call) => ws.calls.where((c) => c == call).length;

Future<void> _scrollToEnd(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -30000));
    await pumpFrames(tester, 4);
  }
}

String _lines(int n) => [for (var i = 1; i <= n; i++) 'line $i'].join('\n');

void main() {
  setUpAll(loadTestFonts);

  testWidgets('code: syntax colours, line numbers, pages as you scroll', (tester) async {
    final ws = sampleWorkspace()..write('big.log', _lines(1200));
    await _open(tester, 'big.log', workspace: ws);
    expect(find.byType(CodeBlock), findsOneWidget);
    expect(_count(ws, 'read big.log'), 1);
    expect(_text('line 500'), findsWidgets);
    expect(_text('line 501'), findsNothing);
    // Folder and size under the title.
    expect(find.textContaining('工作区 · '), findsOneWidget);

    await _scrollToEnd(tester);
    expect(_count(ws, 'read big.log'), 3);
    expect(_text('line 1200'), findsWidgets);
    expect(find.textContaining('只显示前'), findsNothing);
  });

  testWidgets('very long text stops at the cap', (tester) async {
    final ws = sampleWorkspace()..write('huge.txt', _lines(3600));
    await _open(tester, 'huge.txt', workspace: ws);
    await _scrollToEnd(tester);
    await _scrollToEnd(tester);
    expect(_text('line $previewMaxLines'), findsWidgets);
    expect(_text('line ${previewMaxLines + 1}'), findsNothing);
    expect(find.text('文件较大，只显示前 $previewMaxLines 行'), findsOneWidget);
    expect(find.text('用其他应用打开'), findsOneWidget);
  });

  testWidgets('Markdown: front matter as fields, then the document', (tester) async {
    final ws = sampleWorkspace()..write('weekly.md', '---\ntitle: 周报\nowner: "李四"\n---\n# 本周进展\n\n登录问题已修复。\n');
    await _open(tester, 'weekly.md', workspace: ws);
    expect(find.text('title'), findsOneWidget);
    expect(find.text('周报'), findsOneWidget);
    expect(find.text('李四'), findsOneWidget);
    expect(_text('本周进展'), findsWidgets);
    expect(_text('---'), findsNothing);
  });

  test('front matter that is not plain fields stays as written', () {
    final split = splitFrontMatter('---\nlist:\n  - a\n---\nbody');
    expect(split.fields, isNull);
    expect(split.raw, 'list:\n  - a');
    expect(split.body, 'body');
    expect(splitFrontMatter('no front matter').body, 'no front matter');
    expect(splitFrontMatter('---\nopen: block').fields, isNull);
  });

  testWidgets('CSV: a table with the header pinned; a cell shows in full', (tester) async {
    final ws = await _open(tester, 'out/sales.csv');
    expect(ws.calls, contains('readBytes out/sales.csv'));
    expect(find.byType(SheetTable), findsOneWidget);
    for (final cell in ['地区', '一月', '华东', '132', '华南']) {
      expect(find.text(cell), findsOneWidget, reason: cell);
    }
    // Row numbers: the header is row 1.
    expect(find.text('1'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    await tester.tap(find.text('华南'));
    await pumpFrames(tester, 4);
    expect(find.text('A3'), findsOneWidget);
    expect(find.text('华南'), findsNWidgets(2));
  });

  testWidgets('a CSV that is not a table is shown as text', (tester) async {
    final ws = sampleWorkspace()..write('bad.csv', 'a,"b\nc,d\n');
    await _open(tester, 'bad.csv', workspace: ws);
    expect(find.byType(SheetTable), findsNothing);
    expect(find.byType(CodeBlock), findsOneWidget);
  });

  testWidgets('XLSX: sheets as capsules, read on the phone', (tester) async {
    final book = buildXlsx([
      const TestSheet('一月', [
        ['产品', '销量'],
        ['A', 12345],
      ]),
      const TestSheet('二月', [
        ['产品', '销量'],
        ['B', 30.5],
      ]),
    ]);
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('dsh-xlsx')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/book.xlsx');
    await tester.runAsync(() => file.writeAsBytes(book));
    const files = MethodChannel('dsh/files');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(files, (call) async {
      return call.method == 'resolveGuest' ? file.path : null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(files, null));
    final ws = sampleWorkspace()..write('book.xlsx', book);
    await _open(tester, 'book.xlsx', workspace: ws);
    for (var i = 0; i < 30 && find.byType(SheetTable).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await pumpFrames(tester, 2);
    }
    expect(find.byType(SheetTable), findsOneWidget);
    expect(find.text('一月'), findsOneWidget);
    expect(find.text('二月'), findsOneWidget);
    expect(find.text('12345'), findsOneWidget);
    await tester.tap(find.text('二月'));
    await pumpFrames(tester, 4);
    expect(find.text('30.5'), findsOneWidget);
  });

  testWidgets('one enormous line: 文件较大 and the way out', (tester) async {
    final ws = sampleWorkspace()..write('min.js', 'x' * 4000);
    ws.failures['read min.js'] = const DshRemoteException('workspace-file/too-large', 'page over 2 MiB');
    await _open(tester, 'min.js', workspace: ws);
    expect(find.text('文件较大'), findsOneWidget);
    expect(find.textContaining('3.9 KB'), findsOneWidget);
    expect(find.text('用其他应用打开'), findsOneWidget);
  });

  testWidgets('binary content says it cannot be previewed', (tester) async {
    final ws = sampleWorkspace()..write('data.bin', 'a\u0000b');
    await _open(tester, 'data.bin', workspace: ws);
    expect(find.text('无法预览'), findsOneWidget);
    expect(find.text('不是文本文件'), findsOneWidget);
  });

  testWidgets('known binary types go straight to another app', (tester) async {
    final ws = sampleWorkspace()..write('bundle.zip', 'PK');
    await _open(tester, 'bundle.zip', workspace: ws);
    expect(ws.calls, isNot(contains('read bundle.zip')));
    expect(find.text('无法预览'), findsOneWidget);
    expect(find.text('压缩包 · ZIP'), findsOneWidget);
    expect(find.text('用其他应用打开'), findsOneWidget);
  });

  testWidgets('follows the file: new content, deletion, reconnects', (tester) async {
    final ws = await _open(tester, 'notes 2.txt');
    expect(ws.calls, contains('watch notes 2.txt'));
    expect(_text('two'), findsWidgets);
    ws.write('notes 2.txt', 'three');
    await tester.pump(const Duration(milliseconds: 500));
    await pumpFrames(tester, 6);
    expect(_text('three'), findsWidgets);

    final reads = _count(ws, 'read notes 2.txt');
    ws.reconnect();
    await tester.pump(const Duration(milliseconds: 500));
    await pumpFrames(tester, 6);
    expect(_count(ws, 'read notes 2.txt'), reads + 1);

    ws.delete('notes 2.txt');
    await pumpFrames(tester, 6);
    expect(find.text('文件已经不在了'), findsOneWidget);
  });

  test('which preview a path gets', () {
    expect(previewModeOf('a/b.png'), PreviewMode.image);
    expect(previewModeOf('a/b.svg'), PreviewMode.text);
    expect(previewModeOf('r.pdf'), PreviewMode.pdf);
    expect(previewModeOf('r.docx'), PreviewMode.unsupported);
    expect(previewModeOf('r.docx', officeToPdf: true), PreviewMode.office);
    expect(previewModeOf('r.xls', officeToPdf: true), PreviewMode.office);
    expect(previewModeOf('r.xlsx'), PreviewMode.workbook);
    expect(previewModeOf('r.tsv'), PreviewMode.table);
    expect(previewModeOf('README.md'), PreviewMode.markdown);
    expect(previewModeOf('main.dart'), PreviewMode.text);
    expect(previewModeOf('Makefile'), PreviewMode.text);
    expect(previewModeOf('a.zip'), PreviewMode.unsupported);
    expect(previewModeOf('a.mp4'), PreviewMode.unsupported);
    expect(isTextLikePath('lib/main.dart'), isTrue);
    expect(isTextLikePath('LICENSE'), isTrue);
    expect(isTextLikePath('blob.bin'), isFalse);
  });
}
