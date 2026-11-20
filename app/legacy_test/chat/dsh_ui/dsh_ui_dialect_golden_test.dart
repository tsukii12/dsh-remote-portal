// genui blocks (docs/design/plugin-ui-v3.md §3.2) as the chat draws them, in
// light and dark. Look at each image after regenerating (`--update-goldens`).

import 'dart:convert';

import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

String j(Object json) => jsonEncode(json);

/// A build report: figures, a table, progress, a warning, and two parts the
/// app leaves to DSH Web.
final report = j({
  'title': '本周构建',
  'items': [
    {
      'type': 'grid',
      'cols': 3,
      'items': [
        {'type': 'stat', 'label': '通过', 'value': '26', 'delta': '+4'},
        {'type': 'stat', 'label': '失败', 'value': '2', 'delta': '-1'},
        {'type': 'stat', 'label': '平均耗时', 'value': '6.2 分'},
      ],
    },
    {
      'type': 'table',
      'columns': ['任务', '状态', '耗时（秒）'],
      'rows': [
        ['lint', '通过', 42],
        ['unit', '通过', 318],
        ['e2e', '失败', 905],
      ],
    },
    {
      'type': 'steps',
      'current': 1,
      'steps': [
        {'title': '拉代码'},
        {'title': '跑测试', 'desc': 'e2e 第 2 个分片超时'},
        {'title': '发布'},
      ],
    },
    {'type': 'callout', 'tone': 'warning', 'title': '注意', 'content': 'e2e 的 [日志](https://ci.example/1) 里有 ==超时==，先重跑一次'},
    {'type': 'echart', 'preset': 'line', 'data': []},
    {'type': 'button', 'label': '重跑', 'action': 'rerun'},
  ],
});

/// An explainer: a card with an eyebrow, a list, a timeline and code.
final explainer = j({
  'items': [
    {'type': 'text', 'size': 'h1', 'content': '发布流程'},
    {
      'type': 'card',
      'tone': 'info',
      'eyebrow': '第 1 章',
      'title': '准备',
      'items': [
        {
          'type': 'list',
          'items': [
            {'title': '冻结代码', 'desc': '周四 18:00 之后只合修复'},
            {'title': '跑全量', 'desc': '六千多个测试，约 25 分钟'},
          ],
        },
      ],
    },
    {
      'type': 'timeline',
      'items': [
        {'time': '10-29', 'title': '候选版', 'desc': '内部试用'},
        {'time': '10-30', 'title': '公测'},
      ],
    },
    {
      'type': 'keyvalue',
      'pairs': [
        {'key': '版本', 'value': '0.10.0'},
        {'key': '引擎', 'value': 'DSH 0.2.1-rc.4'},
      ],
    },
    {'type': 'code', 'lang': 'sh', 'code': 'flutter build apk --release'},
  ],
});

Widget block(String source) => DshUiScope(
  sessionId: 's1',
  messageId: 'a1',
  state: DshUiState.live,
  onReply: (_) async => true,
  onAskResend: (_) async => true,
  child: DshUiBlock(source: source),
);

Widget sheet(List<Widget> children) => AppBackdrop(
  child: SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(16, 56, 16, 40),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[if (i > 0) const SizedBox(height: 24), children[i]],
      ],
    ),
  ),
);

void main() {
  setUpAll(loadTestFonts);

  for (final brightness in Brightness.values) {
    final suffix = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('genui dialect ($suffix)', (tester) async {
      usePhoneView(tester);
      tester.view.physicalSize = const Size(780, 1960 * 2);
      await tester.pumpWidget(testApp(Scaffold(body: sheet([block(report), block(explainer)])), brightness: brightness));
      await tester.pump(const Duration(milliseconds: 400));
      await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/dsh_ui_dialect_$suffix.png'));
    });
  }
}
