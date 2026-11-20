// Gallery of dsh-ui views: every component, the skeleton, the fallbacks, and
// the answer states, in light and dark. Look at each image after
// regenerating (`--update-goldens`).

import 'dart:convert';

import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

String j(Object json) => jsonEncode(json);

final spending = j({
  'type': 'stack',
  'title': '近 6 个月支出',
  'children': [
    {
      'type': 'row',
      'children': [
        {'type': 'metric', 'label': '月均', 'value': '¥4,180'},
        {'type': 'metric', 'label': '最高', 'value': '¥5,920', 'tone': 'warn', 'caption': '8 月，含机票'},
      ],
    },
    {
      'type': 'chart',
      'kind': 'bar',
      'categories': ['5月', '6月', '7月', '8月', '9月', '10月'],
      'series': [
        {
          'name': '支出',
          'values': [3800, 4100, 3650, 5920, 4010, 3600],
        },
      ],
      'unit': '元',
    },
  ],
});

final trend = j({
  'type': 'stack',
  'title': '收入与支出',
  'children': [
    {
      'type': 'chart',
      'kind': 'line',
      'categories': [for (var m = 1; m <= 12; m++) '$m月'],
      'series': [
        {
          'name': '收入',
          'values': [8.2, 8.4, 8.1, 9.0, 9.3, 9.1, 9.8, 10.2, 9.9, 10.6, 10.4, 11.2],
        },
        {
          'name': '支出',
          'values': [6.1, 5.8, 6.4, 6.0, 7.2, 6.8, 7.1, 8.4, 6.9, 7.3, 7.0, 7.6],
        },
      ],
      'unit': '千元',
      'caption': '示例数据，不是你的真实账单',
    },
    {
      'type': 'row',
      'children': [
        {'type': 'metric', 'label': '年收入', 'value': '¥11.4 万', 'tone': 'good'},
        {'type': 'metric', 'label': '年支出', 'value': '¥8.2 万'},
        {'type': 'metric', 'label': '储蓄率', 'value': '28%', 'caption': '比去年高 4 个点'},
      ],
    },
  ],
});

final shares = j({
  'type': 'stack',
  'title': '仓库语言',
  'children': [
    {
      'type': 'chart',
      'kind': 'hbar',
      'categories': ['Dart', 'Kotlin', 'Shell', 'TypeScript', 'C'],
      'series': [
        {
          'values': [68.4, 17.2, 7.9, 4.6, 1.9],
        },
      ],
      'unit': '%',
    },
    {
      'type': 'chart',
      'kind': 'donut',
      'categories': ['房租', '餐饮', '交通', '娱乐', '其他'],
      'series': [
        {
          'values': [3200, 1450, 420, 600, 380],
        },
      ],
      'unit': '元',
    },
  ],
});

final plan = j({
  'type': 'stack',
  'title': '迁移计划',
  'children': [
    {'type': 'text', 'text': '先把**数据库**迁到新集群，再切读流量。全程预计 `2` 天。'},
    {
      'type': 'steps',
      'items': [
        {'label': '备份旧库', 'status': 'done'},
        {'label': '双写 24 小时', 'status': 'current', 'detail': '已运行 9 小时，无差异'},
        {'label': '切换读流量', 'status': 'todo'},
        {'label': '下线旧库', 'status': 'failed', 'detail': '还有 2 个服务在直连'},
      ],
    },
    {'type': 'callout', 'tone': 'warn', 'text': '切读流量前要先改掉直连旧库的 2 个服务。'},
    {'type': 'callout', 'text': '双写期间写入延迟会增加约 3 ms。'},
  ],
});

final choose = j({
  'type': 'stack',
  'title': '选一个方案',
  'children': [
    {
      'type': 'compare',
      'items': [
        {
          'title': '方案 A',
          'badge': '推荐',
          'rows': [
            ['月供', '¥4,200'],
            ['总利息', '¥31.2 万'],
            ['年限', '30 年'],
          ],
        },
        {
          'title': '方案 B',
          'rows': [
            ['月供', '¥5,100'],
            ['总利息', '¥22.8 万'],
            ['年限', '20 年'],
          ],
        },
      ],
    },
    {
      'type': 'options',
      'id': 'plan',
      'options': [
        {'label': '方案 A'},
        {'label': '方案 B'},
        {'label': '都不要，再算算', 'description': '换个首付比例重新算'},
      ],
    },
  ],
});

final toppings = j({
  'type': 'stack',
  'title': '要装哪些组件',
  'children': [
    {
      'type': 'options',
      'id': 'parts',
      'multi': true,
      'options': [
        {'label': 'Node.js 22', 'description': '约 60 MB'},
        {'label': 'Python 3.12'},
        {'label': 'Rust 工具链', 'description': '约 400 MB，下载较慢'},
      ],
    },
  ],
});

final deploy = j({
  'type': 'stack',
  'title': '部署到生产',
  'children': [
    {'type': 'text', 'tone': 'muted', 'text': '会重启 3 个实例，期间有约 30 秒不可用。'},
    {'type': 'confirm', 'id': 'go', 'confirmLabel': '开始部署', 'cancelLabel': '再等等'},
  ],
});

final quick = j({
  'type': 'options',
  'id': 'q',
  'options': [
    {'label': '继续'},
    {'label': '换个做法'},
  ],
});

/// options + 「其他（自己填）」：选中一项、填一句话、发送按钮亮起的样子。
final free = j({
  'type': 'stack',
  'title': '要不要先算一遍',
  'children': [
    {
      'type': 'options',
      'id': 'f',
      'freetext': true,
      'options': [
        {'label': '直接开始'},
        {'label': '先算成本'},
      ],
    },
  ],
});

final wide = j({
  'type': 'stack',
  'title': '每日活跃',
  'children': [
    {
      'type': 'chart',
      'kind': 'line',
      'categories': [for (var d = 1; d <= 70; d++) '$d日'],
      'series': [
        {
          'values': [for (var d = 1; d <= 70; d++) 1200 + (d * 37 % 400) + d * 6],
        },
      ],
    },
    {'type': 'gauge', 'value': 3},
  ],
});

final four = j({
  'type': 'compare',
  'items': [
    for (final (name, price) in [('入门', '¥0'), ('标准', '¥30'), ('专业', '¥98'), ('团队', '¥298')])
      {
        'title': name,
        if (name == '专业') 'badge': '热门',
        'rows': [
          ['月费', price],
          ['存储', name == '入门' ? '5 GB' : '100 GB'],
        ],
      },
  ],
});

final three = j({
  'type': 'compare',
  'items': [
    {
      'title': '自建',
      'rows': [
        ['首年成本', '¥2.4 万'],
        ['上线时间', '6 周'],
      ],
    },
    {
      'title': '云托管',
      'badge': '推荐',
      'rows': [
        ['首年成本', '¥1.1 万'],
        ['上线时间', '1 周'],
      ],
    },
    {
      'title': '外包',
      'rows': [
        ['首年成本', '¥5 万'],
        ['上线时间', '3 周'],
      ],
    },
  ],
});

final slices = j({
  'type': 'chart',
  'kind': 'donut',
  'categories': ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H'],
  'series': [
    {
      'values': [30, 22, 15, 11, 8, 6, 5, 3],
    },
  ],
});

const partial =
    '{"type":"stack","title":"近 6 个月支出","children":[\n'
    ' {"type":"row","children":[\n'
    '  {"type":"metric","label":"月均","value":"¥4,180"},\n'
    '  {"type":"metric","label":"最高","value":"¥5,920"}]},\n'
    ' {"type":"chart","kind":"bar","categories":["5月","6月"';

Future<bool> _ok(String _) async => true;

Widget scoped(String source, {DshUiState state = DshUiState.live, bool streaming = false, bool closed = true}) =>
    DshUiScope(
      sessionId: 's1',
      messageId: 'a1',
      state: state,
      onReply: _ok,
      onAskResend: _ok,
      child: DshUiBlock(source: source, streaming: streaming, closed: closed),
    );

DshUiState answered(String text) => DshUiState(DshUiInteraction.answered, reply: parseDshUiReply(text));

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

final _sheets = <String, (double, List<Widget> Function())>{
  'display': (1640, () => [scoped(spending), scoped(trend), scoped(shares)]),
  'content': (1380, () => [scoped(plan), scoped(three), scoped(four)]),
  'answers': (
    2680,
    () => [
      KeyedSubtree(key: const ValueKey('live'), child: scoped(choose)),
      scoped(choose, state: answered('[dsh-ui reply] 选一个方案\n选择：方案 A')),
      KeyedSubtree(key: const ValueKey('multi'), child: scoped(toppings)),
      KeyedSubtree(key: const ValueKey('free'), child: scoped(free)),
      scoped(free, state: answered('[dsh-ui reply] 要不要先算一遍\n选择：先算成本\n其他：先算一次总利息')),
      scoped(deploy),
      scoped(deploy, state: answered('[dsh-ui reply] 部署到生产\n确认：开始部署')),
      scoped(quick, state: DshUiState.running),
      scoped(quick, state: DshUiState.expired),
    ],
  ),
  'states': (
    1900,
    () => [
      scoped(partial, streaming: true, closed: false),
      scoped('{"type":"chart","categories":["a"], "series": [}'),
      scoped(partial, closed: false),
      KeyedSubtree(key: const ValueKey('wide'), child: scoped(wide)),
      scoped(slices),
    ],
  ),
};

Finder _painter(String name, {Finder? within}) {
  final match = find.byWidgetPredicate((w) => w is CustomPaint && w.painter.runtimeType.toString() == name);
  return within == null ? match : find.descendant(of: within, matching: match);
}

void main() {
  setUpAll(loadTestFonts);

  for (final MapEntry(key: name, value: (height, build)) in _sheets.entries) {
    for (final brightness in Brightness.values) {
      final suffix = brightness == Brightness.dark ? 'dark' : 'light';
      testWidgets('dsh-ui $name ($suffix)', (tester) async {
        usePhoneView(tester);
        tester.view.physicalSize = Size(780, height * 2);
        await tester.pumpWidget(testApp(Scaffold(body: sheet(build())), brightness: brightness));
        await tester.pump(const Duration(milliseconds: 400));
        if (name == 'answers') {
          // Multi-select: tick two, so the send button is live.
          final multi = find.byKey(const ValueKey('multi'));
          await tester.tap(find.descendant(of: multi, matching: find.text('Node.js 22')));
          await tester.tap(find.descendant(of: multi, matching: find.text('Rust 工具链')));
          // options + 自己填：选一项、写一句，发送按钮亮起。
          final free = find.byKey(const ValueKey('free'));
          await tester.tap(find.descendant(of: free, matching: find.text('先算成本')));
          await tester.enterText(
            find.descendant(of: free, matching: find.byType(TextField)),
            '先算一次总利息',
          );
          await pumpFrames(tester, 12);
        }
        if (name == 'states') {
          // Touch the long line chart: the guide and the tooltip.
          final chart = _painter('_XYPainter', within: find.byKey(const ValueKey('wide')));
          final box = tester.getRect(chart);
          await tester.tapAt(Offset(box.left + box.width * 0.62, box.center.dy));
          await tester.pump(const Duration(milliseconds: 400));
        }
        await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/dsh_ui_${name}_$suffix.png'));
      });
    }
  }
}
