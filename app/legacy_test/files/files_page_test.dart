// 文件 page: folders first in natural order with size and time, path
// capsules and back, search across the workspace, long-press actions, live
// updates from the Host's change feed, pull to refresh.

import 'package:dsh_app/ui/chat/artifact_preview.dart';
import 'package:dsh_app/ui/common/breadcrumb_row.dart';
import 'package:dsh_app/ui/files/files_page.dart';
import 'package:dsh_app/ui/files/workspace_browser.dart';
import 'package:dsh_app/ui/session/workspace_files.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'support/files_harness.dart';

DateTime _now() => DateTime(2026, 10, 24, 15, 0);

Future<MemoryWorkspace> _pump(WidgetTester tester, {MemoryWorkspace? workspace, bool knownRoot = true}) async {
  usePhoneView(tester);
  final ws = workspace ?? sampleWorkspace();
  await tester.pumpWidget(
    filesApp(
      const WorkspaceFilesPage(sessionId: 's1', now: _now),
      ws,
      knownRoot: knownRoot,
    ),
  );
  await pumpFrames(tester, 8);
  return ws;
}

double _y(WidgetTester tester, String text) => tester.getTopLeft(find.text(text)).dy;

/// Clipboard writes.
List<String> _clipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      copied.add((call.arguments as Map)['text'] as String);
    }
    return null;
  });
  return copied;
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('folders first, natural order, size and time', (tester) async {
    final ws = await _pump(tester);
    expect(ws.calls, contains('list '));
    expect(ws.calls, contains('watch '));
    for (final name in ['assets', 'lib', 'out', 'test', 'README.md']) {
      expect(find.text(name), findsOneWidget, reason: name);
    }
    // Folders above files; `notes 2` before `notes 10`; case ignored.
    expect(_y(tester, 'test'), lessThan(_y(tester, '.gitignore')));
    expect(_y(tester, 'notes 2.txt'), lessThan(_y(tester, 'notes 10.txt')));
    expect(_y(tester, 'pubspec.yaml'), lessThan(_y(tester, 'README.md')));
    // Size and the time read from the Host's version token.
    expect(find.text('32 B · 09:30'), findsOneWidget);
    // The workspace folder under the title.
    expect(find.text('/root/work'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('4 个文件夹，5 个文件'),
      200,
      scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first,
    );
    expect(find.text('4 个文件夹，5 个文件'), findsOneWidget);
  });

  testWidgets('capsules and back move between folders', (tester) async {
    final ws = await _pump(tester);
    await tester.tap(find.text('lib'));
    await pumpFrames(tester, 8);
    expect(ws.calls, contains('list lib'));
    expect(find.text('main.dart'), findsOneWidget);
    expect(find.text('README.md'), findsNothing);
    // The path capsules: 工作区 › lib.
    expect(find.widgetWithText(BreadcrumbCapsule, '工作区'), findsOneWidget);
    expect(find.widgetWithText(BreadcrumbCapsule, 'lib'), findsOneWidget);

    await tester.tap(find.widgetWithText(BreadcrumbCapsule, '工作区'));
    await pumpFrames(tester, 8);
    expect(find.text('README.md'), findsOneWidget);

    // System back goes up a folder first, then leaves.
    await tester.tap(find.text('out'));
    await pumpFrames(tester, 8);
    expect(find.text('sales.csv'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await pumpFrames(tester, 8);
    expect(find.byType(WorkspaceFilesPage), findsOneWidget);
    expect(find.text('README.md'), findsOneWidget);
  });

  testWidgets('a folder that went away offers the way up', (tester) async {
    final ws = await _pump(tester);
    ws.failures['list out'] = const DshRemoteException('workspace-file/not-found', 'gone');
    await tester.tap(find.text('out'));
    await pumpFrames(tester, 8);
    expect(find.text('这个文件夹已经不在了'), findsOneWidget);
    await tester.tap(find.text('回到上一级'));
    await pumpFrames(tester, 8);
    expect(find.text('README.md'), findsOneWidget);
  });

  testWidgets('search spans the workspace; a folder hit opens it', (tester) async {
    final ws = await _pump(tester);
    await tester.enterText(find.byType(TextField), 'login');
    await tester.pump(const Duration(milliseconds: 300));
    await pumpFrames(tester, 4);
    expect(ws.calls, contains('search login'));
    expect(find.text('login_page.dart'), findsOneWidget);
    expect(find.text('login_test.dart'), findsOneWidget);
    // Where each hit lives.
    expect(find.text('lib'), findsOneWidget);
    expect(find.text('test'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'ass');
    await tester.pump(const Duration(milliseconds: 300));
    await pumpFrames(tester, 4);
    await tester.tap(find.text('assets'));
    await pumpFrames(tester, 8);
    expect(ws.calls, contains('list assets'));
    expect(find.text('空文件夹'), findsOneWidget);
    // Search is over once a folder opens.
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '');

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump(const Duration(milliseconds: 300));
    await pumpFrames(tester, 4);
    expect(find.text('没有找到'), findsOneWidget);
  });

  testWidgets('tapping a file opens its preview', (tester) async {
    await _pump(tester);
    await tester.tap(find.text('pubspec.yaml'));
    await pumpFrames(tester, 10);
    expect(find.byType(FilePreviewPage), findsOneWidget);
    expect(find.byType(ArtifactPreviewPage), findsOneWidget);
    expect(find.textContaining('login_demo'), findsWidgets);
  });

  testWidgets('long press: open, share, save, copy path', (tester) async {
    await _pump(tester);
    final copied = _clipboard(tester);
    await tester.longPress(find.text('pubspec.yaml'));
    await pumpFrames(tester, 10);
    for (final label in ['预览', '打开', '用其他应用打开', '分享', '存到「下载」', '复制路径']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tester.tap(find.text('复制路径'));
    await pumpFrames(tester, 10);
    expect(copied, ['/root/work/pubspec.yaml']);

    // A folder: open or copy its path.
    await tester.longPress(find.text('lib'));
    await pumpFrames(tester, 10);
    expect(find.text('/root/work/lib'), findsOneWidget);
    await tester.tap(find.text('打开'));
    await pumpFrames(tester, 10);
    expect(find.text('main.dart'), findsOneWidget);
  });

  testWidgets('without a known root, paths stay relative until needed', (tester) async {
    final ws = await _pump(tester, knownRoot: false);
    final copied = _clipboard(tester);
    await tester.longPress(find.text('pubspec.yaml'));
    await pumpFrames(tester, 10);
    await tester.tap(find.text('复制路径'));
    await pumpFrames(tester, 10);
    // Asked of the Host.
    expect(ws.calls, contains('stat pubspec.yaml'));
    expect(copied, ['/root/work/pubspec.yaml']);
  });

  testWidgets('files the agent writes show up by themselves', (tester) async {
    final ws = await _pump(tester);
    expect(find.text('report.md'), findsNothing);
    ws.write('report.md', '# 报告');
    await tester.pump(const Duration(milliseconds: 300));
    await pumpFrames(tester, 12);
    expect(find.text('report.md'), findsOneWidget);

    ws.delete('pubspec.yaml');
    await tester.pump(const Duration(milliseconds: 300));
    await pumpFrames(tester, 12);
    expect(find.text('pubspec.yaml'), findsNothing);

    // After a reconnect the folder is read again.
    final before = ws.calls.where((c) => c == 'list ').length;
    ws.reconnect();
    await tester.pump(const Duration(milliseconds: 300));
    await pumpFrames(tester, 4);
    expect(ws.calls.where((c) => c == 'list ').length, before + 1);
  });

  testWidgets('leaving a folder stops watching it after a while', (tester) async {
    final ws = await _pump(tester);
    await tester.tap(find.text('lib'));
    await pumpFrames(tester, 8);
    expect(ws.watching('lib'), 1);
    await tester.tap(find.widgetWithText(BreadcrumbCapsule, '工作区'));
    await pumpFrames(tester, 8);
    expect(ws.watching('lib'), 1);
    await tester.pump(const Duration(seconds: 31));
    await pumpFrames(tester, 2);
    expect(ws.watching('lib'), 0);
    expect(ws.watching(''), 1);
  });

  testWidgets('pull to refresh lists the folder again', (tester) async {
    final ws = await _pump(tester);
    final before = ws.calls.where((c) => c == 'list ').length;
    await tester.fling(find.text('README.md'), const Offset(0, 500), 1200);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await pumpFrames(tester, 8);
    expect(ws.calls.where((c) => c == 'list ').length, greaterThan(before));
    // Times are read again too.
    expect(ws.calls.where((c) => c == 'stat README.md').length, greaterThan(1));
  });

  test('fileTimeLabel', () {
    final now = DateTime(2026, 10, 24, 15);
    expect(fileTimeLabel(DateTime(2026, 10, 24, 9, 5), now), '09:05');
    expect(fileTimeLabel(DateTime(2026, 10, 23, 22, 1), now), '昨天 22:01');
    expect(fileTimeLabel(DateTime(2026, 3, 2, 8), now), '3月2日');
    expect(fileTimeLabel(DateTime(2025, 1, 3), now), '2025/1/3');
  });
}
