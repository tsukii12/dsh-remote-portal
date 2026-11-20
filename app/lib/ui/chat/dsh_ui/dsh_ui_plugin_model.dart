// The plugin-view half of the dsh-ui parser
// (docs/design/native-plugins-views.md): the six blocks a plugin view adds
// (list, keyValue, progress, table, actions, image), action references,
// semantic tones and image sources. Same lenient rules as the model cards:
// a broken child becomes a placeholder, limits truncate with a note.

part of 'dsh_ui_model.dart';

/// 解析档案：模型卡（```` ```dsh-ui ```` 围栏）或三档插件视图。
final class DshUiProfile {
  const DshUiProfile._({
    required this.name,
    required this.plugin,
    required this.bytes,
    required this.nodes,
    required this.depth,
    required this.children,
    this.text = DshUiLimits.text,
  });

  final String name;

  /// 插件视图：16 种组件、绑定、受限文字、点按走 invoke。
  final bool plugin;

  /// 视图（不含数据）编成 JSON 的字节上限；超了整块降级。
  final int bytes;
  final int nodes;
  final int depth;

  /// 每个 stack / row 的子节点。
  final int children;

  /// text / callout 的字数。
  final int text;

  static const listItems = 50;
  static const tableRows = 50;
  static const tableColumns = 8;
  static const keyValues = 24;
  static const actions = 4;

  /// 原始 JSON 的嵌套层数（含数组）。
  static const jsonNesting = 64;

  /// 动作参数（求值后）的字节上限。
  static const actionArgsBytes = 1024;

  /// `data:` 图片的字符数上限，以及解码后的尺寸上限。
  static const imageDataBytes = 65536;
  static const imageSide = 4096;
  static const imagePixels = 4000000;

  static const model = DshUiProfile._(
    name: 'model',
    plugin: false,
    bytes: DshUiLimits.hardBytes,
    nodes: DshUiLimits.nodes,
    depth: DshUiLimits.depth,
    children: DshUiLimits.children,
  );

  static const toolCard = DshUiProfile._(
    name: 'toolCard',
    plugin: true,
    bytes: 8192,
    nodes: 40,
    depth: 6,
    children: 16,
  );

  static const panel = DshUiProfile._(name: 'panel', plugin: true, bytes: 32768, nodes: 120, depth: 8, children: 32);

  static const strip = DshUiProfile._(
    name: 'strip',
    plugin: true,
    bytes: 2048,
    nodes: 8,
    depth: 3,
    children: 4,
    text: 200,
  );

  @override
  String toString() => 'DshUiProfile.$name';
}

const _pluginTypes = [..._types, 'list', 'keyValue', 'progress', 'table', 'actions', 'image'];

/// 插件视图里能用的组件名（能力声明 `caps.components`）。
const dshUiPluginComponents = [..._pluginTypes, ..._pluginControlTypes];

// ───────────────────────── 节点 ─────────────────────────

/// 一次点按要发的 invoke：动作 id + 参数（已求值）。
final class DshUiAction {
  const DshUiAction(this.id, [this.args = const {}]);

  final String id;
  final Map<String, Object?> args;
}

final class DshUiListItem {
  const DshUiListItem({required this.title, this.subtitle, this.trailing, this.icon, this.tone, this.action});

  final String title;
  final String? subtitle;

  /// 行尾的值或状态。
  final String? trailing;

  /// ui.json 图标名（不认识的画默认图标）。
  final String? icon;
  final DshUiTone? tone;
  final DshUiAction? action;
}

/// `list`：一组行。
final class DshUiList extends DshUiNode {
  const DshUiList({required super.path, required this.items, super.truncation});

  final List<DshUiListItem> items;
}

final class DshUiKeyValueItem {
  const DshUiKeyValueItem(this.label, this.value, [this.tone]);

  final String label;
  final String value;
  final DshUiTone? tone;
}

/// `keyValue`：「名称 …… 值」。
final class DshUiKeyValue extends DshUiNode {
  const DshUiKeyValue({required super.path, required this.items, super.truncation});

  final List<DshUiKeyValueItem> items;
}

/// `progress`：一条进度。
final class DshUiProgress extends DshUiNode {
  const DshUiProgress({
    required super.path,
    required this.value,
    this.max = 100,
    this.label,
    this.caption,
    this.tone,
    this.ring = false,
  });

  /// v2 `shape: "ring"`: a 64 dp ring instead of a bar.
  final bool ring;

  /// null：取不到（画空条，显示「—」）。
  final double? value;
  final double max;
  final String? label;
  final String? caption;
  final DshUiTone? tone;

  /// 0–1；取不到为 null。
  double? get fraction => value == null ? null : (value! / max).clamp(0.0, 1.0);

  /// 行尾显示的字：[caption]，缺省是百分比。
  String get shown {
    if (caption case final c?) return c;
    final f = fraction;
    if (f == null) return dshUiMissingText;
    return '${formatDshUiNumber(f * 100)}%';
  }
}

enum DshUiAlign { start, end }

final class DshUiColumn {
  const DshUiColumn(this.label, this.align);

  final String label;
  final DshUiAlign align;
}

/// `table`：表格。
final class DshUiTable extends DshUiNode {
  const DshUiTable({required super.path, required this.columns, required this.rows, super.truncation});

  final List<DshUiColumn> columns;

  /// 每行的格数等于列数（短的补空，长的截掉）。
  final List<List<String>> rows;
}

final class DshUiButton {
  const DshUiButton({required this.label, required this.action, this.icon, this.primary = false});

  final String label;
  final DshUiAction action;
  final String? icon;
  final bool primary;
}

/// `actions`：按钮组。
final class DshUiActions extends DshUiNode {
  const DshUiActions({required super.path, required this.items, super.truncation});

  final List<DshUiButton> items;
}

/// 图片的来源：校验过的 `data:` 字节，或插件自己的资源（`asset:`）。
sealed class DshUiImageSource {
  const DshUiImageSource();
}

final class DshUiDataImage extends DshUiImageSource {
  const DshUiDataImage(this.bytes, this.width, this.height);

  final Uint8List bytes;
  final int width;
  final int height;
}

final class DshUiAssetImage extends DshUiImageSource {
  const DshUiAssetImage(this.path);

  /// 插件资源目录里的相对路径（`icons/a.png`）。App 的图片解析器收到的是
  /// `asset:` 加这个路径，拼成桥接的资源地址、带凭据去取。
  final String path;

  String get src => 'asset:$path';
}

/// `image`：图片。[source] 为 null 时画「图片无法显示」。
final class DshUiImage extends DshUiNode {
  const DshUiImage({required super.path, required this.source, this.alt, this.aspect, this.caption});

  final DshUiImageSource? source;
  final String? alt;

  /// 宽 / 高（0.25–4）。
  final double? aspect;
  final String? caption;
}

/// 插件视图里需要数组的组件拿到空数组或取不到：一行「暂无数据」，不算错。
final class DshUiEmpty extends DshUiNode {
  const DshUiEmpty({required super.path, required this.type});

  final String type;
}

// ───────────────────────── 校验 ─────────────────────────

bool _isEmpty(Object? value) => value is DshUiMissing || (value is List && value.isEmpty);

/// 新增的 6 种；其余返回 null，交给共用的校验。
DshUiNode? _pluginNode(String type, Map<String, Object?> raw, String path, int depth, _Ctx ctx) => switch (type) {
  'list' => _list(raw, path, ctx),
  'keyValue' => _keyValue(raw, path, ctx),
  'progress' => _progress(raw, path, ctx),
  'table' => _table(raw, path, ctx),
  'actions' => _actions(raw, path, ctx),
  'image' => _image(raw, path, ctx),
  'confirm' => _markPrimary(ctx),
  _ => _pluginControlNode(type, raw, path, depth, ctx),
};

/// confirm 的确认键是实心主色：之后的 primary 按钮按普通画。
DshUiNode? _markPrimary(_Ctx ctx) {
  ctx.primaryUsed = true;
  return null;
}

DshUiTone? _pluginTone(Object? raw, String path, _Ctx ctx, {bool muted = true}) {
  if (raw == null || raw is DshUiMissing) return null;
  final tone = switch (raw) {
    'good' || 'success' || 'positive' => DshUiTone.good,
    'warn' || 'warning' || 'caution' => DshUiTone.warn,
    'bad' || 'danger' || 'error' || 'negative' => DshUiTone.bad,
    'info' || 'note' => DshUiTone.info,
    'muted' || 'secondary' when muted => DshUiTone.muted,
    _ => null,
  };
  if (tone == null) {
    ctx.note(path, appL10n.plugViewUnknownTone(_show(raw)));
  }
  return tone;
}

final _actionIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$');

String? _pluginActionId(Object? raw, String path, _Ctx ctx) {
  if (raw is String && _actionIdPattern.hasMatch(raw)) return raw;
  ctx.note(path, appL10n.plugViewBadActionId(_show(raw)));
  return null;
}

/// `"action": "id"` 或 `{id, args?}`；没写为 null（不记问题），写坏了记一条。
DshUiAction? _pluginAction(Object? raw, String path, _Ctx ctx) {
  if (raw == null || raw is DshUiMissing) return null;
  if (raw is String) {
    final id = _pluginActionId(raw, path, ctx);
    return id == null ? null : DshUiAction(id);
  }
  if (raw is! Map) {
    ctx.note(path, appL10n.plugViewBadAction('{id, args?}'));
    return null;
  }
  final id = _pluginActionId(raw['id'], '$path.id', ctx);
  if (id == null) return null;
  final args = raw['args'];
  if (args == null || args is DshUiMissing) return DshUiAction(id);
  if (args is! Map) {
    ctx.note('$path.args', appL10n.plugViewBadAction('{id, args?}'));
    return null;
  }
  final size = measureDshUiJson(args, maxBytes: DshUiProfile.actionArgsBytes, maxDepth: 16);
  if (!size.ok) {
    ctx.note('$path.args', appL10n.plugViewArgsLimit(DshUiProfile.actionArgsBytes));
    return null;
  }
  return DshUiAction(id, Map.unmodifiable(_plainJson(args) as Map));
}

/// 求值后的 JSON 里把「取不到」换成 null（发给插件的参数是纯 JSON）。
Object? _plainJson(Object? value) => switch (value) {
  DshUiMissing() => null,
  final Map<Object?, Object?> map => <String, Object?>{for (final e in map.entries) '${e.key}': _plainJson(e.value)},
  final List<Object?> list => [for (final v in list) _plainJson(v)],
  _ => value,
};

List<String> _selected(Object? raw) => switch (raw) {
  final String s => [s],
  final List<Object?> list => [
    for (final v in list.take(DshUiLimits.options * 4))
      if (v is String) v,
  ],
  _ => const [],
};

String? _icon(Object? raw, String path, _Ctx ctx) {
  if (raw == null || raw is DshUiMissing) return null;
  if (raw is String && nativeIcon(raw) != null) return raw;
  ctx.note(path, appL10n.plugViewUnknownIcon(_show(raw)));
  return '';
}

String? _optionalText(Object? raw, int max) => raw == null ? null : _clip(_string(raw)?.trim(), max);

DshUiNode _list(Map<String, Object?> raw, String path, _Ctx ctx) {
  final rawItems = raw['items'];
  if (_isEmpty(rawItems)) return DshUiEmpty(path: path, type: 'list');
  const shape = '{title, subtitle?, trailing?, icon?, tone?, action?}';
  if (rawItems is! List) {
    return ctx.broken('$path.items', appL10n.plugViewExpectedItems(shape), type: 'list');
  }
  final items = <DshUiListItem>[];
  String? truncation;
  for (var i = 0; i < rawItems.length; i++) {
    if (items.length >= DshUiProfile.listItems) {
      final dropped = rawItems.length - i;
      truncation = appL10n.viewUiHiddenItems(dropped);
      ctx.note('$path.items', appL10n.viewUiItemLimit(rawItems.length, DshUiProfile.listItems));
      break;
    }
    final item = rawItems[i];
    final at = '$path.items[$i]';
    if (item is! Map<String, Object?>) {
      ctx.note(at, appL10n.plugViewSkippedItem(shape));
      continue;
    }
    final title = _string(item['title'])?.trim();
    if (title == null || title.isEmpty) {
      ctx.note('$at.title', appL10n.viewUiSkippedItemLabel);
      continue;
    }
    items.add(
      DshUiListItem(
        title: _clip(title, DshUiLimits.label)!,
        subtitle: _optionalText(item['subtitle'], DshUiLimits.label),
        trailing: _optionalText(item['trailing'], 40),
        icon: _icon(item['icon'], '$at.icon', ctx),
        tone: _pluginTone(item['tone'], '$at.tone', ctx),
        action: _pluginAction(item['action'], '$at.action', ctx),
      ),
    );
  }
  if (items.isEmpty) {
    return ctx.broken('$path.items', appL10n.viewUiNoItems, type: 'list');
  }
  return DshUiList(path: path, items: List.unmodifiable(items), truncation: truncation);
}

DshUiNode _keyValue(Map<String, Object?> raw, String path, _Ctx ctx) {
  final rawItems = raw['items'];
  const shape = '[label, value] | {label, value, tone?}';
  final List<Object?> entries = switch (rawItems) {
    final List<Object?> list => list,
    final Map<String, Object?> map => [
      for (final e in map.entries.take(DshUiProfile.keyValues + 1)) [e.key, e.value],
    ],
    _ => const [],
  };
  if (_isEmpty(rawItems) || (rawItems is Map && rawItems.isEmpty)) {
    return DshUiEmpty(path: path, type: 'keyValue');
  }
  if (rawItems is! List && rawItems is! Map) {
    return ctx.broken('$path.items', appL10n.plugViewExpectedItems(shape), type: 'keyValue');
  }
  final total = rawItems is Map ? rawItems.length : entries.length;
  final items = <DshUiKeyValueItem>[];
  String? truncation;
  for (var i = 0; i < entries.length; i++) {
    if (items.length >= DshUiProfile.keyValues) {
      truncation = appL10n.viewUiHiddenItems(total - i);
      ctx.note('$path.items', appL10n.viewUiItemLimit(total, DshUiProfile.keyValues));
      break;
    }
    final entry = entries[i];
    final at = '$path.items[$i]';
    String? label;
    Object? value;
    Object? tone;
    if (entry is List && entry.isNotEmpty) {
      label = _string(entry[0]);
      value = entry.length > 1 ? entry[1] : '';
    } else if (entry is Map) {
      label = _string(entry['label'] ?? entry['name']);
      value = entry['value'];
      tone = entry['tone'];
    }
    if (label == null || label.trim().isEmpty) {
      ctx.note(at, appL10n.plugViewSkippedItem(shape));
      continue;
    }
    items.add(
      DshUiKeyValueItem(
        _clip(label.trim(), 80)!,
        _clip(_string(value) ?? '', DshUiLimits.label)!,
        _pluginTone(tone, '$at.tone', ctx),
      ),
    );
  }
  if (items.isEmpty) {
    return ctx.broken('$path.items', appL10n.viewUiNoItems, type: 'keyValue');
  }
  return DshUiKeyValue(path: path, items: List.unmodifiable(items), truncation: truncation);
}

/// 数字：有限数，或能读成数的字符串（千分位、末尾 % 都认）。取不到为 null。
double? _number(Object? raw, String path, _Ctx ctx) {
  if (raw == null || raw is DshUiMissing) return null;
  var bad = false;
  final value = _chartValue(raw, () => bad = true);
  if (bad || value == null) {
    ctx.note(path, appL10n.viewUiExpectedFinite);
    return null;
  }
  return value;
}

DshUiNode _progress(Map<String, Object?> raw, String path, _Ctx ctx) {
  if (!raw.containsKey('value')) {
    return ctx.broken('$path.value', appL10n.viewUiExpectedFinite, type: 'progress');
  }
  final value = _number(raw['value'], '$path.value', ctx);
  var max = _number(raw['max'], '$path.max', ctx) ?? 100;
  if (max <= 0) {
    ctx.note('$path.max', appL10n.plugViewBadMax);
    max = 100;
  }
  return DshUiProgress(
    path: path,
    value: value,
    max: max,
    label: _optionalText(raw['label'], DshUiLimits.label),
    caption: _optionalText(raw['caption'], 40),
    tone: _pluginTone(raw['tone'], '$path.tone', ctx, muted: false),
    ring: ctx.version >= 2 && _progressShape(raw['shape'], '$path.shape', ctx),
  );
}

/// v2 `progress.shape`: `bar` (the default) or `ring`.
bool _progressShape(Object? raw, String path, _Ctx ctx) {
  if (raw == null || raw is DshUiMissing || raw == 'bar') return false;
  if (raw == 'ring') return true;
  ctx.note(path, appL10n.plugViewStyleInvalid('bar / ring'));
  return false;
}

/// 「¥1,234」「12%」「3.5 万」「-8」这类：整列都是它就右对齐。
final _numericCell = RegExp(r'^\s*[¥$€£+\-−]?\s*\d[\d,]*(\.\d+)?\s*(%|‰|[A-Za-z]{1,3}|[一-鿿]{1,2})?\s*$');

DshUiNode _table(Map<String, Object?> raw, String path, _Ctx ctx) {
  final rawColumns = raw['columns'];
  final rawRows = raw['rows'];
  if (_isEmpty(rawRows)) return DshUiEmpty(path: path, type: 'table');
  if (rawColumns is! List || rawColumns.isEmpty) {
    if (rawColumns is DshUiMissing) {
      return DshUiEmpty(path: path, type: 'table');
    }
    return ctx.broken('$path.columns', appL10n.plugViewExpectedItems('label | {label, align?}'), type: 'table');
  }
  if (rawRows is! List) {
    return ctx.broken('$path.rows', appL10n.plugViewExpectedItems('[cell, …]'), type: 'table');
  }
  final notes = <String>[];
  var columnsRaw = rawColumns;
  if (columnsRaw.length > DshUiProfile.tableColumns) {
    ctx.note('$path.columns', appL10n.plugViewColumnLimit(columnsRaw.length, DshUiProfile.tableColumns));
    notes.add(appL10n.plugViewFirstColumns(DshUiProfile.tableColumns));
    columnsRaw = columnsRaw.sublist(0, DshUiProfile.tableColumns);
  }
  final labels = <String>[];
  final aligns = <DshUiAlign?>[];
  for (var c = 0; c < columnsRaw.length; c++) {
    final column = columnsRaw[c];
    final label = column is Map ? column['label'] : column;
    labels.add(_clip(_string(label)?.trim() ?? '', 40)!);
    final align = column is Map ? column['align'] : null;
    aligns.add(switch (align) {
      'end' || 'right' => DshUiAlign.end,
      'start' || 'left' => DshUiAlign.start,
      _ => null,
    });
  }
  final width = labels.length;
  final rows = <List<String>>[];
  for (var r = 0; r < rawRows.length; r++) {
    if (rows.length >= DshUiProfile.tableRows) {
      ctx.note('$path.rows', appL10n.viewUiRowLimit(rawRows.length, DshUiProfile.tableRows));
      notes.add(appL10n.plugViewFirstRows(DshUiProfile.tableRows));
      break;
    }
    final row = rawRows[r];
    if (row is! List) {
      ctx.note('$path.rows[$r]', appL10n.plugViewSkippedItem('[cell, …]'));
      continue;
    }
    rows.add([
      for (var c = 0; c < width; c++) c < row.length && row[c] != null ? _clip(_string(row[c]) ?? '', 80)! : '',
    ]);
  }
  if (rows.isEmpty) return DshUiEmpty(path: path, type: 'table');
  final columns = [
    for (var c = 0; c < width; c++)
      DshUiColumn(
        labels[c],
        aligns[c] ??
            (rows.every((row) => row[c].isEmpty || _numericCell.hasMatch(row[c])) &&
                    rows.any((row) => row[c].isNotEmpty)
                ? DshUiAlign.end
                : DshUiAlign.start),
      ),
  ];
  return DshUiTable(
    path: path,
    columns: List.unmodifiable(columns),
    rows: List.unmodifiable(rows),
    truncation: notes.isEmpty ? null : appL10n.viewUiTruncated(notes.join(appL10n.viewListSeparator)),
  );
}

DshUiNode _actions(Map<String, Object?> raw, String path, _Ctx ctx) {
  final rawItems = raw['items'];
  const shape = '{label, icon?, style?, action}';
  if (_isEmpty(rawItems)) return DshUiEmpty(path: path, type: 'actions');
  if (rawItems is! List) {
    return ctx.broken('$path.items', appL10n.plugViewExpectedItems(shape), type: 'actions');
  }
  final items = <DshUiButton>[];
  for (var i = 0; i < rawItems.length; i++) {
    if (items.length >= DshUiProfile.actions) {
      ctx.note('$path.items', appL10n.viewUiItemLimit(rawItems.length, DshUiProfile.actions));
      break;
    }
    final item = rawItems[i];
    final at = '$path.items[$i]';
    if (item is! Map<String, Object?>) {
      ctx.note(at, appL10n.plugViewSkippedItem(shape));
      continue;
    }
    final label = _string(item['label'])?.trim();
    if (label == null || label.isEmpty) {
      ctx.note('$at.label', appL10n.viewUiSkippedItemLabel);
      continue;
    }
    final action = _pluginAction(item['action'], '$at.action', ctx);
    if (action == null) {
      if (item['action'] == null) {
        ctx.note('$at.action', appL10n.plugViewBadAction('{id, args?}'));
      }
      continue;
    }
    var primary = item['style'] == 'primary';
    if (primary && ctx.version == 2) {
      ctx.note('$at.style', appL10n.plugViewStyleReserved);
      primary = false;
    }
    if (primary && ctx.primaryUsed) {
      ctx.note('$at.style', appL10n.plugViewOnePrimary);
      primary = false;
    }
    if (primary) ctx.primaryUsed = true;
    items.add(
      DshUiButton(
        label: _clip(label, 24)!,
        action: action,
        icon: _icon(item['icon'], '$at.icon', ctx),
        primary: primary,
      ),
    );
  }
  if (items.isEmpty) {
    return ctx.broken('$path.items', appL10n.viewUiNoItems, type: 'actions');
  }
  return DshUiActions(path: path, items: List.unmodifiable(items));
}

final _dataImage = RegExp(r'^data:image/(png|jpeg|jpg|webp|gif);base64,', caseSensitive: false);

/// `asset:icons/a.png`：插件 `dshGo.assets` 目录里的图片
/// （docs/design/native-plugins-protocol.md §4.6），
/// App 拼成 `/dsh-go/v1/assets/<包名>/<路径>` 并带凭据去取。
final _assetRef = RegExp(r'^asset:([A-Za-z0-9_~-][A-Za-z0-9._~-]*(/[A-Za-z0-9_~-][A-Za-z0-9._~-]*)*)$');
final _assetExtension = RegExp(r'\.(png|jpe?g|webp|gif)$', caseSensitive: false);

DshUiNode _image(Map<String, Object?> raw, String path, _Ctx ctx) {
  final src = raw['src'];
  final at = '$path.src';
  DshUiImageSource? source;
  if (src is String && _dataImage.hasMatch(src)) {
    source = _dataSource(src, at, ctx);
  } else if (src is String && src.length <= 512 && _assetRef.hasMatch(src) && _assetExtension.hasMatch(src)) {
    source = DshUiAssetImage(src.substring('asset:'.length));
  } else if (src is! DshUiMissing) {
    ctx.note(at, appL10n.plugViewBadImageSource);
  }
  final rawAspect = raw['aspect'];
  double? aspect;
  if (rawAspect != null && rawAspect is! DshUiMissing) {
    final a = rawAspect is num ? rawAspect.toDouble() : double.nan;
    if (a.isFinite && a >= 0.25 && a <= 4) {
      aspect = a;
    } else {
      ctx.note('$path.aspect', appL10n.plugViewBadAspect);
    }
  }
  return DshUiImage(
    path: path,
    source: source,
    alt: _optionalText(raw['alt'], DshUiLimits.label),
    aspect: aspect,
    caption: _optionalText(raw['caption'], DshUiLimits.label),
  );
}

DshUiDataImage? _dataSource(String src, String path, _Ctx ctx) {
  if (src.length > DshUiProfile.imageDataBytes) {
    ctx.note(path, appL10n.plugViewImageTooLarge(DshUiProfile.imageDataBytes));
    return null;
  }
  final Uint8List bytes;
  try {
    final body = src.substring(src.indexOf(',') + 1).replaceAll(RegExp(r'\s'), '');
    bytes = base64Decode(body);
  } on FormatException {
    ctx.note(path, appL10n.plugViewImageDecode);
    return null;
  }
  final size = dshUiImageSize(bytes);
  if (size == null) {
    ctx.note(path, appL10n.plugViewImageDecode);
    return null;
  }
  final (w, h) = size;
  if (w <= 0 ||
      h <= 0 ||
      w > DshUiProfile.imageSide ||
      h > DshUiProfile.imageSide ||
      w * h > DshUiProfile.imagePixels) {
    ctx.note(path, appL10n.plugViewImagePixels);
    return null;
  }
  return DshUiDataImage(bytes, w, h);
}

/// PNG / GIF / JPEG / WebP 的宽高（只读文件头）；不认识或坏了为 null。
/// 解码前先量，防止一张很小的压缩图解出巨大的位图。
(int, int)? dshUiImageSize(Uint8List b) {
  int u16be(int i) => (b[i] << 8) | b[i + 1];
  int u16le(int i) => b[i] | (b[i + 1] << 8);
  int u24le(int i) => b[i] | (b[i + 1] << 8) | (b[i + 2] << 16);
  int u32be(int i) => (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
  bool at(int i, List<int> sig) {
    if (i + sig.length > b.length) return false;
    for (var k = 0; k < sig.length; k++) {
      if (b[i + k] != sig[k]) return false;
    }
    return true;
  }

  // PNG：签名 + IHDR。
  if (at(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    if (b.length < 24 || !at(12, 'IHDR'.codeUnits)) return null;
    return (u32be(16), u32be(20));
  }
  // GIF：逻辑屏幕尺寸。
  if (at(0, 'GIF87a'.codeUnits) || at(0, 'GIF89a'.codeUnits)) {
    if (b.length < 10) return null;
    return (u16le(6), u16le(8));
  }
  // JPEG：找第一个 SOF 段。
  if (at(0, const [0xFF, 0xD8])) {
    var i = 2;
    while (i + 9 < b.length) {
      if (b[i] != 0xFF) return null;
      final marker = b[i + 1];
      if (marker == 0xFF) {
        i++;
        continue;
      }
      if (marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker == 0x01) {
        i += 2;
        continue;
      }
      final length = u16be(i + 2);
      final sof = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
      if (sof) return (u16be(i + 7), u16be(i + 5));
      if (length < 2) return null;
      i += 2 + length;
    }
    return null;
  }
  // WebP：RIFF 容器里的 VP8 / VP8L / VP8X。
  if (at(0, 'RIFF'.codeUnits) && at(8, 'WEBP'.codeUnits) && b.length >= 30) {
    if (at(12, 'VP8 '.codeUnits)) {
      if (!at(23, const [0x9D, 0x01, 0x2A])) return null;
      return (u16le(26) & 0x3FFF, u16le(28) & 0x3FFF);
    }
    if (at(12, 'VP8L'.codeUnits)) {
      if (b[20] != 0x2F) return null;
      final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
      return ((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1);
    }
    if (at(12, 'VP8X'.codeUnits)) {
      return (u24le(24) + 1, u24le(27) + 1);
    }
  }
  return null;
}

// ───────────────────────── 插件视图入口 ─────────────────────────

/// 解析一份插件视图：大小与嵌套 → 求值绑定 → 按档案校验。
/// 不走缓存（缓存在 `dsh_ui_plugin.dart` 的 `parsePluginView`）。
///
/// [view] 是已解码的 JSON，或一段 JSON 文本（严格 JSON，不容忍注释）。
DshUiParse parseDshUiPluginUncached(Object? view, {Object? data, DshUiProfile profile = DshUiProfile.panel}) {
  assert(profile.plugin);
  Object? json = view;
  if (view is String) {
    if (view.length > profile.bytes * 4) {
      return DshUiInvalid(DshUiIssue('view', appL10n.viewUiBytesLimit(view.length, profile.bytes)));
    }
    try {
      json = jsonDecode(view);
    } on FormatException catch (e) {
      return DshUiInvalid(DshUiIssue('view', appL10n.viewUiInvalidJson(e.message)));
    }
  }
  if (json is! Map) {
    return DshUiInvalid(DshUiIssue('view', appL10n.viewUiExpectedObject));
  }
  final size = measureDshUiJson(json, maxBytes: profile.bytes, maxDepth: DshUiProfile.jsonNesting);
  if (size.tooDeep) {
    return DshUiInvalid(DshUiIssue('view', appL10n.plugViewTooDeep(DshUiProfile.jsonNesting)));
  }
  if (size.overBytes) {
    return DshUiInvalid(DshUiIssue('view', appL10n.viewUiBytesLimit(size.bytes, profile.bytes)));
  }
  // 插件写的是严格 JSON：不做模型卡那套规范化（数字字符串会被改成数）。
  final issues = <DshUiIssue>[];
  final template = json['v'] == 2
      ? resolveDshUiFormulas(
          dshUiInputBindings(json),
          data,
          (path) => issues.add(DshUiIssue(path, appL10n.plugInputFormula)),
        )
      : json;
  final resolved = resolveDshUiBindings(template, data, view: true);
  return dshUiFromJson(resolved, bytes: size.bytes, profile: profile, issues: issues);
}
