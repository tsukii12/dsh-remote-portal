// Plugin-view entry points on top of the dsh-ui parser
// (docs/design/native-plugins-views.md §5, §9): budgets, the cached parse,
// and what a tap hands to the app.

import 'package:flutter/painting.dart' show ImageProvider;

import '../../../l10n/l10n.dart';
import 'dsh_ui_model.dart';

/// 工具结果 meta 里放原生卡片的键（`presentationMeta` 的返回值里）。
const toolCardViewKey = 'dsh-go/view';

/// 三档上限（规格 §5）。
enum PluginViewBudget {
  /// 工具卡：8 KiB、40 个节点、6 层；写进对话记录。
  toolCard(DshUiProfile.toolCard),

  /// 面板：32 KiB、120 个节点、8 层。
  panel(DshUiProfile.panel),

  /// 状态条：2 KiB、8 个节点、3 层，只画一行。
  strip(DshUiProfile.strip);

  const PluginViewBudget(this.profile);

  final DshUiProfile profile;
}

/// 动作从哪个元素来。
enum PluginActionSource { button, row, option, confirm, change, submit }

/// 用户在插件视图里点了一下：App 据此发 invoke（`id` + `args`），并附上
/// 插件包名、插槽和作用域。
final class PluginAction {
  const PluginAction({
    required this.id,
    this.args = const {},
    required this.source,
    required this.path,
    this.gestureAt,
  });

  final String id;

  /// 已求值的纯 JSON 对象。
  final Map<String, Object?> args;
  final PluginActionSource source;

  /// Host-only time of the originating user gesture, captured before queuing.
  /// Never read from plugin JSON or forwarded as plugin-provided arguments.
  final DateTime? gestureAt;

  PluginAction withGestureAt(DateTime time) =>
      PluginAction(id: id, args: args, source: source, path: path, gestureAt: time);

  /// 元素在视图里的路径（`view.children[1].items[0]`），调试用。
  final String path;

  @override
  bool operator ==(Object other) =>
      other is PluginAction &&
      other.id == id &&
      other.source == source &&
      other.path == path &&
      other.gestureAt == gestureAt &&
      _sameJson(other.args, args);

  @override
  int get hashCode => Object.hash(id, source, path, gestureAt);

  @override
  String toString() => 'PluginAction($id, $args, ${source.name}, $path)';
}

bool _sameJson(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (!b.containsKey(e.key) || !_sameJson(e.value, b[e.key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameJson(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// 发 invoke 并执行效果；返回 false 表示失败（被点的元素复原）。不要抛错。
typedef PluginActionHandler = Future<bool> Function(PluginAction action);

/// 把插件资源 `asset:<路径>` 换成带凭据的图片（`/dsh-go/v1/assets/<包名>/<路径>`，
/// 包名由调用方补上）；返回 null 画占位。
typedef PluginImageResolver = ImageProvider? Function(String src);

/// 解析 + 求值 + 校验一份插件视图，按 [view] / [data] 的对象身份缓存
/// （字符串按内容）：数据变了要传新对象，不要原地改。解析结果里的 issues
/// 是带路径的问题列表。
DshUiParse parsePluginView(Object? view, {Object? data, PluginViewBudget budget = PluginViewBudget.panel}) =>
    _cache.get(view, data, budget.profile);

final _cache = _PluginParseCache(64);

final class _Key {
  _Key(this.view, this.data, this.profile);

  final Object? view;
  final Object? data;
  final DshUiProfile profile;

  static bool _same(Object? a, Object? b) => a is String && b is String ? a == b : identical(a, b);

  static int _hash(Object? v) => v is String ? v.hashCode : identityHashCode(v);

  @override
  bool operator ==(Object other) =>
      other is _Key && identical(other.profile, profile) && _same(other.view, view) && _same(other.data, data);

  @override
  int get hashCode => Object.hash(_hash(view), _hash(data), profile);
}

class _PluginParseCache {
  _PluginParseCache(this.capacity);

  final int capacity;
  final _entries = <_Key, DshUiParse>{};
  String? _language;
  int _accent = DshUiAppAccent.revision;

  DshUiParse get(Object? view, Object? data, DshUiProfile profile) {
    final language = AppLocale.current.languageCode;
    if (_language != language || _accent != DshUiAppAccent.revision) {
      _entries.clear();
      _language = language;
      _accent = DshUiAppAccent.revision;
    }
    final key = _Key(view, data, profile);
    final hit = _entries.remove(key);
    if (hit != null) {
      _entries[key] = hit;
      return hit;
    }
    DshUiParse parsed;
    try {
      parsed = parseDshUiPluginUncached(view, data: data, profile: profile);
    } on Object {
      // 解析器的最后一道防线：任何意外都只让这一张降级。
      parsed = DshUiInvalid(DshUiIssue('view', appL10n.plugViewInvalid));
    }
    _entries[key] = parsed;
    if (_entries.length > capacity) _entries.remove(_entries.keys.first);
    return parsed;
  }
}
