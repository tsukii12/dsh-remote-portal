// Goldens (light + dark) for the 文件 page and the file previews. Regenerate
// with `flutter test --update-goldens test/files/files_golden_test.dart`.

import 'package:dsh_app/ui/files/files_page.dart';
import 'package:dsh_app/ui/session/workspace_files.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'support/files_harness.dart';

DateTime _now() => DateTime(2026, 10, 24, 15, 0);

Future<void> _preview(WidgetTester tester, MemoryWorkspace ws, String rel, Brightness brightness, {int? bytes}) async {
  usePhoneView(tester);
  await tester.pumpWidget(
    filesApp(
      FilePreviewPage(sessionId: 's1', path: '${ws.root}/$rel', bytes: bytes),
      ws,
      brightness: brightness,
    ),
  );
  await pumpFrames(tester, 10);
}

const _sales = '''地区,一月,二月,三月,季度合计,同比
华东,120,132,141,393,12.4%
华南,98,101,117,316,8.1%
华北,87,90,95,272,-2.3%
西南,64,70,77,211,15.0%
西北,31,29,35,95,3.3%
东北,45,47,44,136,-0.7%
港澳台,12,15,16,43,22.9%
''';

const _weekly = '''---
title: 第 43 周周报
owner: 李四
date: 2026-10-24
---
# 本周进展

- 登录重复提交已修复，测试覆盖连点
- Q3 报表按区域拆分，周一发出

## 下周

1. 移动端改版评审
2. 运营活动预算复核
''';

void main() {
  setUpAll(loadTestFonts);

  for (final brightness in Brightness.values) {
    final suffix = brightness == Brightness.dark ? 'dark' : 'light';

    testWidgets('table preview ($suffix)', (tester) async {
      final ws = sampleWorkspace()..write('out/sales.csv', _sales);
      await _preview(tester, ws, 'out/sales.csv', brightness);
      await tester.tap(find.text('华南'));
      await pumpFrames(tester, 4);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/preview_table_$suffix.png'));
    });

    testWidgets('large file ($suffix)', (tester) async {
      final ws = sampleWorkspace()..write('dist/app.min.js', 'x');
      ws.failures['read dist/app.min.js'] = const DshRemoteException('workspace-file/too-large', 'page over 2 MiB');
      await _preview(tester, ws, 'dist/app.min.js', brightness, bytes: 38 * 1024 * 1024);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/preview_large_$suffix.png'));
    });

    testWidgets('Markdown with front matter ($suffix)', (tester) async {
      final ws = sampleWorkspace()..write('docs/weekly.md', _weekly);
      await _preview(tester, ws, 'docs/weekly.md', brightness);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/preview_markdown_$suffix.png'));
    });

    testWidgets('unsupported file ($suffix)', (tester) async {
      final ws = sampleWorkspace()..write('out/bundle.zip', 'PK');
      await _preview(tester, ws, 'out/bundle.zip', brightness);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/preview_unsupported_$suffix.png'));
    });

    testWidgets('files page ($suffix)', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(
        filesApp(
          const WorkspaceFilesPage(sessionId: 's1', now: _now),
          sampleWorkspace(),
          brightness: brightness,
        ),
      );
      await pumpFrames(tester, 12);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/files_page_$suffix.png'));
    });

    testWidgets('files page in a folder ($suffix)', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(
        filesApp(
          const WorkspaceFilesPage(sessionId: 's1', initialPath: 'out', now: _now),
          sampleWorkspace(),
          brightness: brightness,
        ),
      );
      await pumpFrames(tester, 12);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/files_folder_$suffix.png'));
    });

    testWidgets('files search ($suffix)', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(
        filesApp(
          const WorkspaceFilesPage(sessionId: 's1', now: _now),
          sampleWorkspace(),
          brightness: brightness,
        ),
      );
      await pumpFrames(tester, 8);
      await tester.enterText(find.byType(TextField), 'login');
      await tester.pump(const Duration(milliseconds: 300));
      await pumpFrames(tester, 12);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/files_search_$suffix.png'));
    });
  }
}
