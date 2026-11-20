// The genui dialect of the ```dsh-ui fence (docs/design/plugin-ui-v3.md §3.2).
//
// `@changfenhuang/dsh-genui` teaches the model a JSON of its own under the
// same fence name: a root `{title?, items}` without `type`, and components
// such as `stat`, `card`, `col`, `keyvalue`. Its blocks map onto a read-only
// plugin view (v2) drawn by the app's renderer; a part with no native
// counterpart becomes one quiet 「… · 在网页版查看」 tag, never an error.
//
// Pure: decoded JSON in, plugin-view JSON out. The vocabulary follows the
// plugin's published SKILL.md (0.15.0); none of its code is used.

import 'dart:convert';

import '../../../l10n/l10n.dart';

/// Component names only genui writes: the app's own model cards never use
/// them at the root.
const genuiOnlyTypes = {
  'col', 'grid', 'card', 'carousel', 'divider', 'spacer', 'arrow', 'hero', //
  'stat', 'badge', 'progress', 'list', 'table', 'keyvalue', 'avatar', 'image',
  'image-group', 'audio', 'video', 'timeline', 'file-tree', 'breadcrumb', 'diff',
  'json', 'code', 'icon', 'blocks', 'plot', 'echart', 'button', 'input', 'select',
  'checkbox', 'radio', 'switch', 'slider', 'textarea', 'tabs', 'accordion', 'copy',
  'link', 'submit', 'svg', 'mermaid', 'diagram', 'scene3d', 'quiz', 'map',
};

/// Interactive genui parts: in the app they are one 「可交互内容」 tag, since
/// a tap would have to go back as genui's own action message.
const _interactive = {
  'button', 'input', 'select', 'checkbox', 'radio', 'switch', 'slider', 'textarea', 'submit', 'quiz', //
};

/// Whether [json] (a decoded fence) is genui's, not the app's own format.
bool isGenuiDialect(Object? json) {
  if (json is List) {
    return json.any((e) => e is Map && genuiOnlyTypes.contains(e['type']));
  }
  if (json is! Map) return false;
  final type = json['type'];
  if (type == null) return json['items'] is List;
  if (type is! String) return false;
  if (genuiOnlyTypes.contains(type)) return true;
  // Names both formats share, written the genui way.
  return switch (type) {
    'text' || 'callout' => json['content'] is String && json['text'] == null,
    'row' => json['items'] is List && json['children'] == null,
    'steps' => json['steps'] is List && json['items'] == null,
    'chart' => json['data'] is List && json['categories'] == null,
    _ => false,
  };
}

/// A mapped block: the plugin view, or null when nothing in it can show.
final class GenuiMapping {
  const GenuiMapping(this.view, this.notes);

  final Map<String, Object?>? view;

  /// JSON paths of the parts drawn as 「在网页版查看」 or dropped.
  final List<String> notes;
}

/// Maps a genui fence ([json], already decoded) to a v2 plugin view.
GenuiMapping genuiToPluginView(Object? json) {
  final m = _Mapper();
  String? title;
  List<Object?> items;
  if (json is List) {
    items = json;
  } else if (json is Map && json['type'] == null) {
    items = json['items'] is List ? json['items'] as List : const [];
    title = _str(json['title']);
  } else {
    items = [json];
  }
  final children = m.nodes(items, 'spec.items');
  if (children.isEmpty) return GenuiMapping(null, m.notes);
  return GenuiMapping({'v': 2, 'type': 'stack', 'title': ?title, 'children': children}, m.notes);
}

String? _str(Object? v) => switch (v) {
  final String s when s.trim().isNotEmpty => s,
  final num n => n.toString(),
  _ => null,
};

String _cell(Object? v) => switch (v) {
  null => '',
  final String s => _inline(s),
  final num n => n is int || n == n.roundToDouble() ? n.toInt().toString() : n.toString(),
  final bool b => b ? '✓' : '',
  _ => '—',
};

final _link = RegExp(r'\[([^\]\n]+)\]\([^)\s]+\)');
final _mark = RegExp(r'==([^=\n]+)==');

/// genui's inline marks the app's restricted text doesn't read: a link keeps
/// its words, a highlight its text. `**bold**` and `` `code` `` stay.
String _inline(String s) => s.replaceAllMapped(_link, (m) => m[1]!).replaceAllMapped(_mark, (m) => m[1]!);

/// Tone words → the plugin view's (good / warn / bad / info / muted).
String? _tone(Object? v) => switch (v) {
  'success' || 'good' => 'good',
  'warn' || 'warning' => 'warn',
  'danger' || 'error' || 'bad' => 'bad',
  'info' || 'accent' => 'info',
  'muted' => 'muted',
  _ => null,
};

/// Tone words → a named colour for a card's tint or a text run.
String? _toneColor(Object? v) => switch (v) {
  'success' => 'green',
  'warning' || 'warn' => 'amber',
  'danger' || 'error' => 'red',
  'info' || 'accent' => 'blue',
  _ => null,
};

final _hex = RegExp(r'^#[0-9a-fA-F]{6}$');

class _Mapper {
  final notes = <String>[];

  /// Maps a component list. Placeholders in a row with the same words fold
  /// into one; parts with nothing to show drop out.
  List<Map<String, Object?>> nodes(Object? raw, String path) {
    if (raw is! List) return const [];
    final out = <Map<String, Object?>>[];
    for (final (i, item) in raw.indexed) {
      final mapped = node(item, '$path[$i]');
      if (mapped == null) continue;
      final last = out.isEmpty ? null : out.last;
      if (last != null && last['type'] == 'tag' && mapped['type'] == 'tag' && last['text'] == mapped['text']) {
        continue;
      }
      out.add(mapped);
    }
    return out;
  }

  Map<String, Object?> web(String path, String kind) {
    notes.add(path);
    return {'type': 'tag', 'text': appL10n.viewUiDialectWebOnly(kind), 'tone': 'muted'};
  }

  Map<String, Object?> text(
    String text, {
    String? size,
    String? weight,
    String? color,
    String? align,
    bool muted = false,
  }) => {
    'type': 'text',
    'text': text,
    if (muted) 'tone': 'muted',
    if (size != null || weight != null || color != null || align != null)
      'style': {'size': ?size, 'weight': ?weight, 'color': ?color, 'align': ?align},
  };

  Map<String, Object?> stack(List<Map<String, Object?>> children, {Map<String, Object?>? style}) => {
    'type': 'stack',
    'style': ?style,
    'children': children,
  };

  Map<String, Object?>? node(Object? raw, String path) {
    if (raw is String) return _str(raw) == null ? null : text(_inline(raw));
    if (raw is! Map) {
      notes.add(path);
      return null;
    }
    final type = raw['type'];
    if (type is! String) {
      notes.add(path);
      return null;
    }
    if (_interactive.contains(type)) return web(path, appL10n.viewUiDialectKindInteractive);
    switch (type) {
      case 'text':
        return _text(raw);
      case 'row':
      case 'col':
      case 'grid':
      case 'card':
      case 'carousel':
        return _container(type, raw, path);
      case 'hero':
        return _hero(raw);
      case 'stat':
        return _stat(raw, path);
      case 'badge':
        final label = _str(raw['label']);
        return label == null ? null : {'type': 'badge', 'text': label, 'tone': ?_tone(raw['tone'])};
      case 'avatar':
        final name = _str(raw['name']);
        return name == null ? null : {'type': 'tag', 'text': name};
      case 'progress':
        return _progress(raw);
      case 'list':
        return _list(raw, path);
      case 'table':
        return _table(raw, path);
      case 'keyvalue':
        return _keyValue(raw, path);
      case 'timeline':
        return _timeline(raw, path);
      case 'steps':
        return _steps(raw, path);
      case 'callout':
        return _callout(raw);
      case 'chart':
        return _chart(raw, path);
      case 'code':
        final code = raw['code'];
        return code is String ? {'type': 'codeBlock', 'code': code, 'language': ?_str(raw['lang'])} : null;
      case 'diff':
        return _diff(raw);
      case 'json':
        return {
          'type': 'codeBlock',
          'language': 'json',
          'code': const JsonEncoder.withIndent('  ').convert(raw['value']),
        };
      case 'copy':
        final body = raw['text'];
        if (body is! String) return null;
        final code = {'type': 'codeBlock', 'code': body};
        final label = _str(raw['label']);
        return label == null ? code : stack([text(label, size: 'caption', muted: true), code], style: {'gap': 'S'});
      case 'link':
        final label = _str(raw['label']) ?? _str(raw['href']);
        return label == null ? null : text(label);
      case 'breadcrumb':
        final parts = [for (final p in raw['items'] is List ? raw['items'] as List : const []) ?_str(p)];
        return parts.isEmpty ? null : text(parts.join(' › '), size: 'caption', muted: true);
      case 'divider':
        final label = _str(raw['label']);
        return label == null
            ? {'type': 'divider'}
            : stack(
                [
                  {'type': 'divider'},
                  text(label, size: 'caption', weight: 'medium', align: 'center', muted: true),
                ],
                style: {'gap': 'S'},
              );
      case 'spacer':
        return {'type': 'spacer', 'size': 'M'};
      case 'arrow' || 'icon':
        // Decoration between blocks: the app's spacing already separates them.
        return null;
      case 'tabs':
        return _sections('tabs', raw['tabs'], path, label: 'label');
      case 'accordion':
        return _sections('accordion', raw['items'], path, label: 'title');
      case 'image':
        return _image(raw, path);
      case 'image-group':
        return _imageGroup(raw, path);
      case 'audio':
        return web(path, appL10n.viewUiDialectKindAudio);
      case 'video':
        return web(path, appL10n.viewUiDialectKindVideo);
      case 'echart' || 'plot':
        return web(path, appL10n.viewUiDialectKindChart);
      case 'mermaid' || 'diagram' || 'svg' || 'blocks':
        return web(path, appL10n.viewUiDialectKindDiagram);
      case 'scene3d':
        return web(path, appL10n.viewUiDialectKindScene);
      case 'file-tree':
        return web(path, appL10n.viewUiDialectKindFiles);
      case 'map':
        return web(path, appL10n.viewUiDialectKindMap);
    }
    return web(path, appL10n.viewUiDialectKindOther);
  }

  Map<String, Object?>? _text(Map raw) {
    final content = _str(raw['content'] ?? raw['text']);
    if (content == null) return null;
    final size = raw['size'];
    final tone = raw['tone'];
    final align = switch (raw['align'] ?? (raw['center'] == true ? 'center' : null)) {
      'center' => 'center',
      'right' => 'end',
      _ => null,
    };
    final (String? s, String? w) = switch (size) {
      'display' => ('title', 'semibold'),
      'h1' => ('subtitle', 'semibold'),
      'h2' || 'h3' => ('body', 'semibold'),
      'caption' => ('caption', null),
      _ => (raw['mono'] == true ? 'mono' : null, null),
    };
    return text(
      _inline(content),
      size: s,
      weight: w,
      color: _toneColor(tone),
      align: align,
      muted: tone == 'muted' || size == 'muted' || size == 'caption',
    );
  }

  Map<String, Object?>? _container(String type, Map raw, String path) {
    final rawItems = raw['items'];
    final children = nodes(rawItems, '$path.items');
    if (type == 'carousel') {
      if (children.isEmpty) return null;
      return {
        'type': 'carousel',
        'items': [
          for (final (i, child) in children.take(8).indexed)
            {
              'label': _str(child['title']) ?? '${i + 1}',
              'children': [child],
            },
        ],
      };
    }
    if (type == 'card') {
      final heading = <Map<String, Object?>>[
        if (_str(raw['eyebrow']) case final eyebrow?) text(eyebrow, size: 'caption', muted: true),
        if (_str(raw['title']) case final title?) text(title, weight: 'semibold'),
      ];
      if (children.isEmpty && heading.isEmpty) return null;
      final accent = raw['accent'];
      final tint = accent is String && _hex.hasMatch(accent) ? accent : _toneColor(raw['tone']);
      return stack(
        [...heading, ...children],
        style: {'card': tint == null ? 'surface' : 'tinted', 'background': ?tint, 'gap': 'M'},
      );
    }
    if (children.isEmpty) return null;
    if (type == 'grid') {
      // A grid of figures reads best as the app's row of metrics: aligned
      // columns, no box around each number.
      if (children.every((c) => c['type'] == 'metric')) return {'type': 'row', 'children': children};
      final cols = raw['cols'];
      return {'type': 'grid', 'columns': cols is num ? cols.toInt().clamp(1, 4) : 2, 'children': children};
    }
    if (type == 'col') return stack(children);
    // A row of `col`s that all say how wide they are keeps those widths.
    final widths = [
      for (final item in rawItems is List ? rawItems : const [])
        if (item is Map && item['type'] == 'col' && item['width'] is num) (item['width'] as num).toDouble(),
    ];
    final weighted = widths.length == children.length && widths.length <= 8;
    return {
      'type': 'row',
      if (weighted)
        'style': {
          'columns': [for (final w in widths) (w / 100 * 12).round().clamp(1, 12)],
        },
      'children': children,
    };
  }

  Map<String, Object?>? _hero(Map raw) {
    final title = _str(raw['title']);
    final value = _str(raw['value']);
    final subtitle = _str(raw['subtitle']);
    final children = <Map<String, Object?>>[
      if (value != null)
        {
          'type': 'metric',
          'label': _str(raw['label']) ?? title ?? '',
          'value': value,
          'caption': ?_str(raw['delta']),
          'tone': ?_deltaTone(raw['delta']),
          'trend': ?_spark(raw['spark']),
          'style': {'size': 'display'},
        },
      if (value == null && title != null) text(title, size: 'title', weight: 'semibold'),
      if (value != null && title != null && raw['label'] != null) text(title, weight: 'semibold'),
      if (subtitle != null) text(_inline(subtitle), muted: true),
    ];
    if (children.isEmpty) return null;
    final tint = _toneColor(raw['tone']);
    return stack(children, style: {'card': 'tinted', 'background': ?tint, 'gap': 'S'});
  }

  String? _deltaTone(Object? delta) {
    final d = _str(delta)?.trim();
    if (d == null) return null;
    if (d.startsWith('+')) return 'good';
    if (d.startsWith('-') || d.startsWith('−')) return 'bad';
    return null;
  }

  Map<String, Object?>? _stat(Map raw, String path) {
    final label = _str(raw['label']);
    final value = _str(raw['value']);
    if (label == null || value == null) {
      notes.add(path);
      return null;
    }
    return {
      'type': 'metric',
      'label': label,
      'value': value,
      'caption': ?_str(raw['delta']),
      'tone': ?_deltaTone(raw['delta']),
      'trend': ?_spark(raw['spark']),
      if (raw['size'] == 'hero') 'style': {'size': 'display'},
    };
  }

  Map<String, Object?>? _progress(Map raw) {
    final value = raw['value'];
    if (value is! num) return null;
    return {
      'type': 'progress',
      'value': value,
      'max': 100,
      'label': ?_str(raw['label']),
      'caption': ?_str(raw['valueLabel']),
      if (raw['variant'] == 'ring') 'shape': 'ring',
    };
  }

  /// genui's `spark`: 2–60 numbers; the app's trend takes the last 30.
  static List<num>? _spark(Object? raw) {
    if (raw is! List || raw.length < 2 || !raw.every((v) => v is num && v.isFinite)) return null;
    final points = raw.cast<num>();
    return points.length > 30 ? points.sublist(points.length - 30) : points;
  }

  static const _titleKeys = ['title', 'label', 'name'];
  static const _descKeys = ['desc', 'description', 'content', 'text', 'body', 'detail'];

  Map<String, Object?>? _list(Map raw, String path) {
    final rawItems = raw['items'];
    if (rawItems is! List) return null;
    final items = <Map<String, Object?>>[];
    for (final (i, item) in rawItems.indexed) {
      if (item is String) {
        if (_str(item) != null) items.add({'title': _inline(item)});
        continue;
      }
      if (item is! Map) {
        notes.add('$path.items[$i]');
        continue;
      }
      String? first(List<String> keys) => [for (final k in keys) ?_str(item[k])].firstOrNull;
      final title = first(_titleKeys);
      final desc = first(_descKeys);
      if (title == null && desc == null) {
        notes.add('$path.items[$i]');
        continue;
      }
      items.add({'title': _inline(title ?? desc!), if (title != null && desc != null) 'subtitle': _inline(desc)});
    }
    return items.isEmpty ? null : {'type': 'list', 'items': items};
  }

  Map<String, Object?>? _table(Map raw, String path) {
    final columns = raw['columns'];
    final rows = raw['rows'];
    if (columns is! List || columns.isEmpty || rows is! List) return null;
    final types = raw['types'] is List ? raw['types'] as List : const [];
    final mapped = <List<String>>[];
    for (final (r, row) in rows.indexed) {
      if (row is! List) continue;
      mapped.add([
        for (var c = 0; c < columns.length; c++)
          c < types.length && types[c] == 'index' ? '${r + 1}' : (c < row.length ? _cell(row[c]) : ''),
      ]);
    }
    return {
      'type': 'table',
      'columns': [for (final c in columns) _cell(c)],
      'rows': mapped,
    };
  }

  Map<String, Object?>? _keyValue(Map raw, String path) {
    final pairs = raw['pairs'];
    if (pairs is! List) return null;
    final items = [
      for (final p in pairs)
        if (p is Map && _str(p['key']) != null) [_str(p['key'])!, _cell(p['value'])],
    ];
    return items.isEmpty ? null : {'type': 'keyValue', 'items': items};
  }

  Map<String, Object?>? _timeline(Map raw, String path) {
    final rawItems = raw['items'];
    if (rawItems is! List) return null;
    final items = <Map<String, Object?>>[];
    for (final item in rawItems) {
      if (item is! Map) continue;
      final title = _str(item['title']);
      if (title == null) continue;
      final time = _str(item['time']);
      final desc = _str(item['desc']);
      items.add({
        'label': time == null ? _inline(title) : '$time · ${_inline(title)}',
        'children': [if (desc != null) text(_inline(desc), muted: true)],
      });
    }
    return items.isEmpty ? null : {'type': 'timeline', 'items': items};
  }

  Map<String, Object?>? _steps(Map raw, String path) {
    final steps = raw['steps'] ?? raw['items'];
    if (steps is! List) return null;
    final current = raw['current'] is num ? (raw['current'] as num).toInt() : steps.length;
    final items = <Map<String, Object?>>[];
    for (final (i, step) in steps.indexed) {
      final title = step is Map ? _str(step['title'] ?? step['label']) : _str(step);
      if (title == null) continue;
      items.add({
        'label': _inline(title),
        'status': i < current ? 'done' : (i == current ? 'current' : 'todo'),
        if (step is Map && _str(step['desc']) != null) 'detail': _inline(_str(step['desc'])!),
      });
    }
    return items.isEmpty ? null : {'type': 'steps', 'items': items};
  }

  /// A tinted panel in the tone's colour: the title in that colour, the
  /// words in the reading colour.
  Map<String, Object?>? _callout(Map raw) {
    final content = _str(raw['content'] ?? raw['text']);
    final title = _str(raw['title']);
    if (content == null && title == null) return null;
    final color = _toneColor(raw['tone']) ?? 'blue';
    return stack(
      [
        if (title != null) text(_inline(title), weight: 'semibold', color: color),
        if (content != null) text(_inline(content)),
      ],
      style: {'card': 'tinted', 'background': color, 'gap': 'S'},
    );
  }

  Map<String, Object?>? _chart(Map raw, String path) {
    final kind = switch (raw['kind']) {
      'line' => 'line',
      'donut' => 'donut',
      _ => raw['horizontal'] == true ? 'hbar' : 'bar',
    };
    // genui: `data` for one series, or `series[].data`, each `{label, value}`.
    final rawSeries = <(String?, List)>[
      if (raw['series'] case final List list)
        for (final s in list)
          if (s is Map && s['data'] is List) (_str(s['label']), s['data'] as List),
    ];
    if (rawSeries.isEmpty && raw['data'] is List) rawSeries.add((null, raw['data'] as List));
    final categories = <String>[];
    for (final (_, data) in rawSeries) {
      for (final d in data) {
        final label = d is Map ? _str(d['label']) : null;
        if (label != null && !categories.contains(label)) categories.add(label);
      }
    }
    if (categories.isEmpty) return null;
    final series = [
      for (final (name, data) in rawSeries)
        {
          'name': ?name,
          'values': [
            for (final c in categories)
              () {
                final hit = data.whereType<Map>().where((d) => _str(d['label']) == c).firstOrNull;
                final v = hit?['value'];
                return v is num ? v : null;
              }(),
          ],
        },
    ];
    if (series.every((s) => (s['values'] as List).every((v) => v == null))) {
      return web(path, appL10n.viewUiDialectKindChart);
    }
    return {'type': 'chart', 'kind': kind, 'categories': categories, 'series': series};
  }

  Map<String, Object?>? _diff(Map raw) {
    final diffs = raw['diffs'];
    if (diffs is! List) return null;
    final out = StringBuffer();
    for (final d in diffs) {
      if (d is! Map) continue;
      if (out.isNotEmpty) out.writeln();
      out.writeln('--- ${_str(d['path']) ?? ''}');
      final before = d['oldText'];
      if (before is String) {
        for (final line in const LineSplitter().convert(before)) {
          out.writeln('-$line');
        }
      }
      final after = d['newText'];
      if (after is String) {
        for (final line in const LineSplitter().convert(after)) {
          out.writeln('+$line');
        }
      }
    }
    final code = out.toString().trimRight();
    return code.isEmpty ? null : {'type': 'codeBlock', 'language': 'diff', 'code': code};
  }

  Map<String, Object?>? _sections(String type, Object? raw, String path, {required String label}) {
    if (raw is! List) return null;
    final items = <Map<String, Object?>>[];
    for (final (i, section) in raw.indexed) {
      if (section is! Map) continue;
      final name = _str(section[label]) ?? '${i + 1}';
      items.add({'label': name, 'children': nodes(section['items'], '$path[$i].items')});
    }
    return items.isEmpty ? null : {'type': type, 'items': items.take(8).toList()};
  }

  /// Only inline bitmaps: genui's own image addresses are served by the host
  /// web page (`/mmx-files/…`, `https://…`), which a card in the chat can't
  /// fetch.
  static bool _inlineImage(Object? src) => src is String && src.startsWith('data:image/');

  Map<String, Object?>? _image(Map raw, String path) {
    final src = raw['src'];
    if (!_inlineImage(src)) return web(path, appL10n.viewUiDialectKindImage);
    return {'type': 'image', 'src': src, 'alt': ?_str(raw['alt']), 'caption': ?_str(raw['caption'])};
  }

  Map<String, Object?>? _imageGroup(Map raw, String path) {
    final items = raw['items'];
    if (items is! List) return null;
    final images = [
      for (final item in items)
        if (item is Map && _inlineImage(item['src']))
          {'src': item['src'], 'alt': ?_str(item['alt']), 'caption': ?_str(item['caption'])},
    ];
    if (images.isEmpty) return web(path, appL10n.viewUiDialectKindImage);
    final gallery = {'type': 'gallery', 'items': images.take(24).toList()};
    final title = _str(raw['title']);
    return title == null ? gallery : stack([text(title, weight: 'semibold'), gallery]);
  }
}
