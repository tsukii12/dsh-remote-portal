// Plugin views used by the tests in this directory: one per component, the
// samples in docs/design/native-plugins-views.md, and a few broken ones.

import 'dart:convert';
import 'dart:typed_data';

/// A 192 × 108 PNG (dusk over the sea), 771 bytes.
const duskPng =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAMAAAABsCAIAAACzYCrFAAACyklEQVR42u3S2UrUYRyH8e8FdQXRQlFEEUXhvptmmmaaae454+zjLDrquIyORBFFEUUURRTRPXQxHXUwJ0FQ8OP9v7zCA58beODRyaYjwEynmo8AM51urgNmOttSB8x0rrUOmOl82yFgpgtth4CZLrYfAGa61HEAmOlyxwFgpiudNcBMV7tqgJmuddcAM13v3gfMdKNnHzDTzd49wExNvXuAmVr69gAztfbvAmZq798FzNR5axcwU9fADmCmnsEdwEy9g1XATP23q4CZBoaqgJkGh7YBMw3d2QbMNDy8DZhpZGQLMNPoyBZgprG7m4CZxkc3ATNNjG4CZpocqwBmmrpXAcw0PV4BzDQzvgGYafb+BmCmuYl1wEwLE+uAmZYm1wEzLT8oA2ZamSoDZopPlQEzrT4sAWZKTpcAM6Wmi4CZMjNFwEy5R0XATPnZAmCmwmwBMFNprgCYqTy/Bp9+/dz+t+OVo435NXjw32/+diy6VFnII2qGexrCT9PWYh7RMa/zp5ADVV3MIyJO7mkItlE7SzlEweE9DWFmam85B+ec39MQYKlqj3NwLqKBAizVweMs3IronobQYlVfycKhSO9pCKpXR7EMHPIwUFC9ehLLwCEPAwXVq6fxDFzxcE9DOMl6tpqGK94GCidZzxNpuOJtoHCS9SKRhiveBgonWS+TKbjibaBwkvUqlYIr3gYKJ1mvU0m44m2gcJL1Jp2EK94GCidZbzNJuOJtoHCS9S6bgCveBgonWe+zCbjibaBwkvUhl4BDHu4Jqlcf86twyMNAQfXqU34VDnkYKKhefV6Lw61I7wktVl8KcTgX0T0BluprMQ7nIhoowFJ9K8YQBef3hJmp76UYIuLwnmAb9aMcQ3Sc3BNyoE6c6QPMGAgMBAYCA4GBAAYCA4GBwEAAA4GBwEBgIICBwEBgIDAQwEBgIDAQGAgMBFj8BngD9EmXLNCsAAAAAElFTkSuQmCC';

Uint8List get duskBytes => base64Decode(duskPng.substring(duskPng.indexOf(',') + 1));

/// The weather tool card of the spec (§1, §8.1).
final Map<String, Object?> weatherCard = {
  'type': 'stack',
  'title': '东京 · 未来 3 天',
  'children': [
    {
      'type': 'row',
      'children': [
        {'type': 'metric', 'label': '最高', 'value': '21°'},
        {'type': 'metric', 'label': '最低', 'value': '14°', 'tone': 'info'},
        {'type': 'metric', 'label': '降水', 'value': '60%', 'tone': 'warn'},
      ],
    },
    {
      'type': 'chart',
      'kind': 'line',
      'categories': ['周六', '周日', '周一'],
      'series': [
        {
          'name': '气温',
          'values': [21, 19, 17],
        },
      ],
      'unit': '°C',
    },
  ],
};

/// A usage panel bound to [usageData].
final Map<String, Object?> usagePanel = {
  'type': 'stack',
  'title': '用量',
  'children': [
    {
      'type': 'row',
      'children': [
        {
          'type': 'metric',
          'label': '本对话',
          'value': {r'$': 'data.session'},
        },
        {
          'type': 'metric',
          'label': '今日',
          'value': {r'$': 'data.today'},
        },
      ],
    },
    {
      'type': 'progress',
      'label': '本月额度',
      'value': {r'$': 'data.month.used'},
      'max': {r'$': 'data.month.limit'},
    },
    {
      'type': 'list',
      'items': {r'$': 'data.recent'},
    },
    {
      'type': 'actions',
      'items': [
        {'label': '刷新', 'icon': 'refresh', 'action': 'refresh'},
        {
          'label': '查看明细',
          'style': 'primary',
          'action': {
            'id': 'open',
            'args': {'page': 'detail'},
          },
        },
      ],
    },
  ],
};

final Map<String, Object?> usageData = {
  'session': '¥0.42',
  'today': '¥3.10',
  'month': {'used': 62, 'limit': 100},
  'recent': [
    {
      'title': '重构登录流程',
      'subtitle': '今天 14:20',
      'trailing': '¥0.42',
      'icon': 'chat',
      'action': {
        'id': 'openSession',
        'args': {'id': 's1'},
      },
    },
    {'title': '周报整理', 'subtitle': '昨天', 'trailing': '¥1.08', 'icon': 'note'},
    {'title': '翻译合同', 'trailing': '¥0.36', 'icon': 'translate', 'tone': 'good'},
  ],
};

final Map<String, Object?> listView = {
  'type': 'list',
  'items': [
    {'title': '单行', 'trailing': '12', 'icon': 'bolt'},
    {'title': '两行', 'subtitle': '副标题', 'trailing': '¥3.5', 'icon': 'chart', 'tone': 'warn'},
    {'title': '可点', 'action': 'go'},
  ],
};

final Map<String, Object?> keyValueView = {
  'type': 'keyValue',
  'items': [
    ['模型', 'deepseek-v4'],
    {'label': '输入', 'value': '12,480 tokens'},
    {'label': '状态', 'value': '正常', 'tone': 'good'},
  ],
};

final Map<String, Object?> tableView = {
  'type': 'table',
  'columns': ['日期', '对话', '花费'],
  'rows': [
    ['10-23', '重构登录流程', '¥0.42'],
    ['10-24', '周报整理', '¥1.08'],
    ['10-25', '翻译合同', '¥0.36'],
  ],
};

final Map<String, Object?> progressView = {
  'type': 'stack',
  'children': [
    {'type': 'progress', 'label': '本月额度', 'value': 62},
    {'type': 'progress', 'label': '上下文', 'value': 0.91, 'max': 1, 'tone': 'bad'},
    {'type': 'progress', 'label': '同步', 'value': 3, 'max': 12, 'caption': '3/12', 'tone': 'good'},
  ],
};

final Map<String, Object?> actionsView = {
  'type': 'stack',
  'children': [
    {
      'type': 'actions',
      'items': [
        {'label': '取消订阅', 'action': 'unsubscribe'},
        {'label': '续费', 'style': 'primary', 'icon': 'wallet', 'action': 'renew'},
      ],
    },
    {
      'type': 'actions',
      'items': [
        {'label': '导出 CSV', 'icon': 'document', 'action': 'csv'},
        {'label': '复制摘要', 'icon': 'summary', 'action': 'copy'},
        {'label': '在网页版打开', 'icon': 'globe', 'action': 'web'},
      ],
    },
  ],
};

final Map<String, Object?> imageView = {'type': 'image', 'src': duskPng, 'alt': '黄昏的海面', 'caption': '江之岛 · 17:42'};

final Map<String, Object?> choiceView = {
  'type': 'stack',
  'children': [
    {
      'type': 'options',
      'id': 'range',
      'options': [
        {'label': '近 7 天', 'value': '7d'},
        {'label': '近 30 天', 'value': '30d'},
        {'label': '今年', 'value': 'year'},
      ],
      'selected': {r'$': 'data.range'},
    },
    {'type': 'confirm', 'id': 'reset', 'confirmLabel': '重置', 'cancelLabel': '保留'},
  ],
};

final Map<String, Object?> textView = {
  'type': 'stack',
  'children': [
    {
      'type': 'text',
      'text': '**已同步** 3 个日历。\n\n下次同步在 `18:00`，详情见 [设置](https://example.com) ![图](https://tracker.example/p.png)。',
    },
    {'type': 'text', 'text': '数据来自本机日历，只读。', 'tone': 'muted'},
    {'type': 'callout', 'text': '有 2 个日程时间冲突', 'tone': 'warn'},
  ],
};

/// Things that are not right, each in its own way.
final Map<String, Object?> partlyBroken = {
  'type': 'stack',
  'title': '部分有误',
  'children': [
    {'type': 'gauge', 'value': 3},
    {
      'type': 'list',
      'items': {r'$': 'data.nothing'},
    },
    {'type': 'image', 'src': 'https://tracker.example/p.png'},
    {
      'type': 'metric',
      'label': '还在',
      'value': {r'$': 'data.missing'},
    },
  ],
};
