// Data bindings and size guards for plugin views
// (docs/design/native-plugins-views.md §3, §5).

import '../../../l10n/l10n.dart';
import 'dsh_ui_model.dart' show formatDshUiValue;

/// A binding that found nothing. Text shows「—」, chart points are gaps,
/// arrays draw「暂无数据」.
final class DshUiMissing {
  const DshUiMissing._();

  @override
  String toString() => '—';
}

/// The one [DshUiMissing].
const dshUiMissing = DshUiMissing._();

/// What a missing value reads as.
const dshUiMissingText = '—';

/// Path segments a binding may have after `data`.
const dshUiBindingSegments = 16;

/// The path of `{"$": "data.a.b"}`, or null when [value] is not a binding
/// (a binding is an object with exactly the one key `$` holding a string).
String? dshUiBindingPath(Object? value) {
  if (value is Map && value.length == 1) {
    final path = value[r'$'];
    if (path is String) return path;
  }
  return null;
}

final _segment = RegExp(r'\.([^.\[\]]+)|\[(\d+)\]');
final _paths = <String, List<Object>?>{};

/// `data.rows[0].name` → `['rows', 0, 'name']` (a key is a String, a `[n]`
/// index an int). null when the path does not start with `data`, has more
/// than [dshUiBindingSegments] segments or anything that is not a segment.
List<Object>? parseDshUiBindingPath(String path) {
  if (_paths.containsKey(path)) return _paths[path];
  final parsed = _parsePath(path);
  if (_paths.length >= 256) _paths.remove(_paths.keys.first);
  _paths[path] = parsed;
  return parsed;
}

List<Object>? _parsePath(String path) {
  if (!path.startsWith('data')) return null;
  final segments = <Object>[];
  var at = 4;
  while (at < path.length) {
    final m = _segment.matchAsPrefix(path, at);
    if (m == null) return null;
    final key = m.group(1);
    segments.add(key ?? int.parse(m.group(2)!));
    if (segments.length > dshUiBindingSegments) return null;
    at = m.end;
  }
  return segments;
}

/// The value at [segments] in [data]; [dshUiMissing] when any step is absent
/// or the value is null. A numeric key indexes a list (`data.rows.0`).
Object? dshUiLookup(Object? data, List<Object> segments) {
  Object? current = data;
  for (final segment in segments) {
    switch (current) {
      case final Map<Object?, Object?> map:
        final key = segment is int ? '$segment' : segment;
        if (!map.containsKey(key)) return dshUiMissing;
        current = map[key];
      case final List<Object?> list:
        final index = segment is int ? segment : int.tryParse(segment as String);
        if (index == null || index < 0 || index >= list.length) {
          return dshUiMissing;
        }
        current = list[index];
      default:
        return dshUiMissing;
    }
  }
  return current ?? dshUiMissing;
}

/// [value] with its binding resolved against [data]: the bound value, or
/// [dshUiMissing] when the path is invalid or finds nothing. Anything that
/// is not a binding comes back as it is (not walked).
Object? resolveDshUiBinding(Object? value, Object? data) {
  final path = dshUiBindingPath(value);
  if (path == null) return value;
  final segments = parseDshUiBindingPath(path);
  if (segments == null) return dshUiMissing;
  return dshUiLookup(data, segments);
}

/// Deep copy of [value] with every binding resolved against [data]. Bound
/// values are inserted as they are: data is never searched for bindings, so
/// a value cannot pull in another. Deeper than [maxDepth] reads as missing
/// (the template has already passed [measureDshUiJson]).
///
/// [view]: a component's `type` is never bound (a bound `type` reads as
/// missing, so the component becomes a placeholder).
Object? resolveDshUiBindings(Object? value, Object? data, {int maxDepth = 64, bool view = false}) {
  Object? walk(Object? v, int depth) {
    if (depth > maxDepth) return dshUiMissing;
    if (dshUiBindingPath(v) != null) return resolveDshUiBinding(v, data);
    if (v is Map) {
      return <String, Object?>{
        for (final e in v.entries)
          '${e.key}': view && e.key == 'type' && dshUiBindingPath(e.value) != null
              ? dshUiMissing
              : walk(e.value, depth + 1),
      };
    }
    if (v is List) return [for (final item in v) walk(item, depth + 1)];
    return v;
  }

  return walk(value, 0);
}

// ───────────────────────── 公开的纯函数（状态条等直接用） ─────────────────────────

/// `value` 是绑定就返回取到的值（取不到为 null），否则原样返回。
Object? resolvePluginBinding(Object? value, Object? data) {
  final resolved = resolveDshUiBinding(value, data);
  return resolved is DshUiMissing ? null : resolved;
}

/// 深度求值整棵 JSON：每个绑定换成取到的值（取不到为 null）。
Object? resolvePluginBindings(Object? value, Object? data) {
  Object? clean(Object? v) {
    if (v is DshUiMissing) return null;
    if (v is Map) {
      return <String, Object?>{for (final e in v.entries) '${e.key}': clean(e.value)};
    }
    if (v is List) return [for (final item in v) clean(item)];
    return v;
  }

  return clean(resolveDshUiBindings(value, data));
}

/// 求值后转成一行显示文字：取不到为「—」，数字按 [formatDshUiValue] 的规则，
/// 空白压成一个空格，超过 [max] 个字截断加「…」。
String pluginBindingText(Object? value, Object? data, {int max = 200}) {
  final resolved = resolveDshUiBinding(value, data);
  final text = dshUiDisplayText(resolved) ?? dshUiMissingText;
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.length <= max) return flat;
  return '${flat.substring(0, max)}…';
}

/// 文字型的值怎么显示：字符串照用；有限数按 [formatDshUiValue]；布尔是
/// 「是 / 否」；取不到是「—」。其余（对象、数组、NaN）为 null。
String? dshUiDisplayText(Object? value) => switch (value) {
  final String s => s,
  final num n when n.isFinite => formatDshUiValue(n.toDouble()),
  final bool b => b ? appL10n.viewUiYes : appL10n.viewUiNo,
  DshUiMissing() => dshUiMissingText,
  _ => null,
};

// ───────────────────────── 大小与嵌套 ─────────────────────────

/// [measureDshUiJson] 的结果。
final class DshUiJsonSize {
  const DshUiJsonSize(this.bytes, {this.overBytes = false, this.tooDeep = false});

  /// 按 UTF-8 编码的 JSON 字节数；超限时是停下来那一刻的数。
  final int bytes;
  final bool overBytes;
  final bool tooDeep;

  bool get ok => !overBytes && !tooDeep;
}

/// [value] 编成 JSON 有多少字节、嵌套几层，超过 [maxBytes] 或 [maxDepth]
/// 立刻停：一个巨大或很深（甚至带环）的对象也只走到上限为止。
DshUiJsonSize measureDshUiJson(Object? value, {required int maxBytes, int maxDepth = 64}) {
  var bytes = 0;
  var tooDeep = false;

  bool add(int n) {
    bytes += n;
    return bytes <= maxBytes;
  }

  bool walk(Object? v, int depth) {
    if (depth > maxDepth) {
      tooDeep = true;
      return false;
    }
    switch (v) {
      case null:
        return add(4);
      case final bool b:
        return add(b ? 4 : 5);
      case final num n:
        return add(n.isFinite ? '$n'.length : 4);
      case final String s:
        return add(_stringBytes(s, maxBytes - bytes));
      case final Map<Object?, Object?> map:
        if (!add(2 + (map.isEmpty ? 0 : map.length - 1))) return false;
        for (final e in map.entries) {
          final key = _stringBytes('${e.key}', maxBytes - bytes) + 1;
          if (!add(key)) return false;
          if (!walk(e.value, depth + 1)) return false;
        }
        return true;
      case final List<Object?> list:
        if (!add(2 + (list.isEmpty ? 0 : list.length - 1))) return false;
        for (final item in list) {
          if (!walk(item, depth + 1)) return false;
        }
        return true;
      default:
        // 不是 JSON 的东西（解码出来的不会有）：按 null 计。
        return add(4);
    }
  }

  final ok = walk(value, 1);
  return DshUiJsonSize(bytes, overBytes: !ok && !tooDeep, tooDeep: tooDeep);
}

/// 一个字符串编成 JSON 的字节数（含引号和转义）。比 [room] 长时不再细数：
/// UTF-8 字节数不少于 UTF-16 码元数。
int _stringBytes(String s, int room) {
  if (s.length > room) return s.length + 2;
  var n = 2;
  for (final c in s.codeUnits) {
    if (c == 0x22 || c == 0x5C) {
      n += 2;
    } else if (c < 0x20) {
      n += 6;
    } else if (c < 0x80) {
      n += 1;
    } else if (c < 0x800) {
      n += 2;
    } else if (c >= 0xD800 && c <= 0xDFFF) {
      n += 2; // 代理对的一半：一对共 4 字节。
    } else {
      n += 3;
    }
  }
  return n;
}
