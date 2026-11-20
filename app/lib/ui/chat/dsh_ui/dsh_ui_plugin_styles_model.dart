// Bounded view-v2 styles. The interpreter owns both opaque backgrounds and
// text colours, so contrast diagnostics describe the colours actually drawn.
part of 'dsh_ui_model.dart';

/// Colour values are opaque 24-bit sRGB. Alpha is never author controlled.
final class DshUiColorPair {
  const DshUiColorPair(this.light, this.dark);

  final int light;
  final int dark;
  int at(bool darkMode) => darkMode ? dark : light;
}

abstract final class DshUiPluginPalette {
  // The existing card palette's neutral anchors. V2 paints these explicitly;
  // it does not estimate the colour underneath a translucent parent card.
  static const surface = DshUiColorPair(0xF8FAFE, 0x272A33);
  static const elevated = DshUiColorPair(0xF0F3F9, 0x30343F);
  static const ink = DshUiColorPair(0x20242B, 0xF1F4F9);
  static const muted = DshUiColorPair(0x586372, 0xB5BDCA);
  static const defaultAccent = 0x3D6FD6;
  // Original category palette, corrected only when a v2 background is used.
  static const chart = [
    DshUiColorPair(0x3D6FD6, 0x5B8EE6),
    DshUiColorPair(0xDC6530, 0xD9692F),
    DshUiColorPair(0x169470, 0x1F9E76),
    DshUiColorPair(0xB88000, 0xB88510),
    DshUiColorPair(0xD0628F, 0xD6649A),
    DshUiColorPair(0x6B58D0, 0x8A7DE0),
  ];
  static const chartOther = DshUiColorPair(0x9AA0AA, 0x6B707A);
  static const named = <String, int>{
    'red': 0xD04545,
    'orange': 0xCA6328,
    'amber': 0xAA7900,
    'green': 0x258051,
    'teal': 0x167F84,
    'blue': 0x3D6FD6,
    'indigo': 0x5B5CC7,
    'violet': 0x8554BB,
    'pink': 0xB94F83,
    'gray': 0x697382,
  };
}

/// The person's accent (设置 › 主题) for a view that asks for `accent: "app"`
/// (docs/design/plugin-ui-v3.md §4.3): the light seed of the palette; the
/// dark side is derived like any requested colour, by the contrast search.
/// The app sets it whenever the palette changes; the plugin-view parse cache
/// starts over when [revision] moves. The default is 雾蓝, the app's default.
abstract final class DshUiAppAccent {
  static const fallback = 0x4B67B4;
  static int _rgb = fallback;
  static int _revision = 0;

  static int get rgb => _rgb;
  static int get revision => _revision;

  static void set(int rgb) {
    final value = rgb & 0xFFFFFF;
    if (value == _rgb) return;
    _rgb = value;
    _revision++;
  }
}

/// WCAG 2.2 relative luminance and ratio, without rounding the threshold.
double dshUiContrast(int foreground, int background) {
  double luminance(int rgb) {
    double channel(int shift) {
      final c = ((rgb >> shift) & 255) / 255;
      return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
    }

    return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0);
  }

  final a = luminance(foreground);
  final b = luminance(background);
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
}

int _mixPluginColor(int from, int to, double amount) {
  int channel(int shift) => (((from >> shift) & 255) * (1 - amount) + ((to >> shift) & 255) * amount).round();
  return (channel(16) << 16) | (channel(8) << 8) | channel(0);
}

/// Search only two bounded, monotone sRGB segments. Every returned candidate
/// was tested after 8-bit quantisation; 4.499 never counts as 4.5.
int dshUiReadableColor(int requested, int background, {double minimum = 4.5}) {
  if (dshUiContrast(requested, background) >= minimum) return requested;
  var best = requested;
  var bestDistance = 2.0;
  for (final target in const [0x000000, 0xFFFFFF]) {
    if (dshUiContrast(target, background) < minimum) continue;
    var low = 0.0;
    var high = 1.0;
    var passing = target;
    for (var step = 0; step < 16; step++) {
      final middle = (low + high) / 2;
      final candidate = _mixPluginColor(requested, target, middle);
      if (dshUiContrast(candidate, background) >= minimum) {
        high = middle;
        passing = candidate;
      } else {
        low = middle;
      }
    }
    if (high < bestDistance) {
      bestDistance = high;
      best = passing;
    }
  }
  return best;
}

enum DshUiTextSize {
  display(28),
  title(24),
  subtitle(20),
  body(16),
  caption(13),
  mono(14);

  const DshUiTextSize(this.pixels);
  final double pixels;
}

enum DshUiTextWeight {
  regular(400),
  medium(500),
  semibold(600),
  bold(700);

  const DshUiTextWeight(this.value);
  final int value;
}

enum DshUiStyleAlign { start, center, end }

enum DshUiCardStyle { plain, surface, tinted, outlined }

final class DshUiRichSpan {
  const DshUiRichSpan({
    required this.text,
    required this.color,
    required this.weight,
    this.mono = false,
    this.background,
  });
  final String text;
  final DshUiColorPair color;
  final DshUiTextWeight weight;
  final bool mono;
  final DshUiColorPair? background;
}

final class DshUiPluginStyle {
  const DshUiPluginStyle({
    required this.foreground,
    required this.background,
    required this.accent,
    required this.muted,
    this.size = DshUiTextSize.body,
    this.weight = DshUiTextWeight.regular,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.align = DshUiStyleAlign.start,
    this.maxLines,
    this.card = DshUiCardStyle.plain,
    this.padding = 0,
    this.gap = 12,
    this.columns = const [],
    this.dividers = false,
    this.spans = const [],
    this.chartColors = const [],
    this.chartOther,
  });

  final DshUiColorPair foreground;
  final DshUiColorPair background;
  final DshUiColorPair accent;
  final DshUiColorPair muted;
  final DshUiTextSize size;
  final DshUiTextWeight weight;
  final bool italic;
  final bool underline;
  final bool strike;
  final DshUiStyleAlign align;
  final int? maxLines;
  final DshUiCardStyle card;
  final double padding;
  final double gap;
  final List<int> columns;
  final bool dividers;
  final List<DshUiRichSpan> spans;
  final List<DshUiColorPair> chartColors;
  final DshUiColorPair? chartOther;

  // Colours survive both enlargement and reduction of the system text size.
  // The stronger 4.5 floor also exceeds WCAG's 3.0 floor for large text.
  double get minimumContrast => _pluginMinimumContrast(size, weight);
}

double _pluginMinimumContrast(DshUiTextSize size, DshUiTextWeight weight) => 4.5;

const _pluginReservedStyleKeys = {
  'position',
  'left',
  'right',
  'top',
  'bottom',
  'width',
  'height',
  'radius',
  'borderRadius',
  'elevation',
  'shadow',
  'fontFamily',
  'fontSize',
  'lineHeight',
  'opacity',
  'gradient',
  'transform',
  'zIndex',
};
const _pluginReservedRoles = {'system', 'approval', 'authorization', 'dialog', 'permission'};

void _initPluginStyles(Map<String, Object?> raw, _Ctx ctx) {
  final version = raw['v'];
  ctx.version = version == 2 ? 2 : 1;
  if (version != null && version != 1 && version != 2) {
    ctx.note('view.v', appL10n.plugViewVersionFallback(_show(version)));
  }
  if (ctx.version == 1) return;
  ctx.accent = raw['accent'] == 'app'
      ? DshUiAppAccent.rgb
      : _pluginColor(raw['accent'], 'view.accent', ctx, allowAccent: false) ?? DshUiPluginPalette.defaultAccent;
}

String _pluginHex(int rgb) => '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';

int? _pluginColor(Object? value, String path, _Ctx ctx, {bool allowAccent = true}) {
  if (value == null || value is DshUiMissing) return null;
  if (value is String) {
    if (value.length > 16) {
      ctx.note(path, appL10n.plugViewStyleInvalid('red … gray / #RRGGBB${allowAccent ? ' / accent' : ''}'));
      return null;
    }
    if (allowAccent && value == 'accent') return ctx.accent;
    if (DshUiPluginPalette.named[value] case final rgb?) return rgb;
    if (RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) return int.parse(value.substring(1), radix: 16);
  }
  ctx.note(path, appL10n.plugViewStyleInvalid('red … gray / #RRGGBB${allowAccent ? ' / accent' : ''}'));
  return null;
}

DshUiColorPair _pluginReadablePair(
  DshUiColorPair requested,
  DshUiColorPair background,
  double minimum,
  String path,
  _Ctx ctx, {
  bool once = false,
}) {
  int resolve(int value, int base, String mode) {
    final corrected = dshUiReadableColor(value, base, minimum: minimum);
    if (corrected != value && (!once || ctx.contrastNotes.add('$path:$value:$base:$minimum:$mode'))) {
      ctx.note(
        path,
        appL10n.plugViewContrastAdjusted(mode, _pluginHex(value), _pluginHex(corrected), formatDshUiValue(minimum)),
      );
    }
    return corrected;
  }

  return DshUiColorPair(
    resolve(requested.light, background.light, 'light'),
    resolve(requested.dark, background.dark, 'dark'),
  );
}

T _pluginStyleEnum<T extends Enum>(Object? raw, List<T> values, T fallback, String path, _Ctx ctx) {
  if (raw == null || raw is DshUiMissing) return fallback;
  for (final value in values) {
    if (value.name == raw) return value;
  }
  ctx.note(path, appL10n.plugViewStyleInvalid(values.map((e) => e.name).join(' / ')));
  return fallback;
}

bool _pluginStyleFlag(Map raw, String key, String path, _Ctx ctx) {
  final value = raw[key];
  if (value == null || value is DshUiMissing) return false;
  if (value is bool) return value;
  ctx.note('$path.$key', appL10n.plugViewStyleInvalid('true / false'));
  return false;
}

double _pluginSpacing(Object? value, double fallback, String path, _Ctx ctx) {
  if (value == null || value is DshUiMissing) return fallback;
  final spacing = switch (value) {
    'S' => 8.0,
    'M' => 12.0,
    'L' => 16.0,
    _ => null,
  };
  if (spacing != null) return spacing;
  ctx.note(path, appL10n.plugViewStyleInvalid('S / M / L'));
  return fallback;
}

DshUiColorPair _pluginTint(int rgb) => DshUiColorPair(
  _mixPluginColor(DshUiPluginPalette.surface.light, rgb, 0.10),
  _mixPluginColor(DshUiPluginPalette.surface.dark, rgb, 0.16),
);

DshUiPluginStyle _readPluginStyle(Map<String, Object?> raw, String path, _Ctx ctx) {
  final styleAt = '$path.style';
  final rawStyle = raw['style'];
  final style = rawStyle is Map ? rawStyle : const {};
  if (rawStyle != null && rawStyle is! DshUiMissing && rawStyle is! Map) {
    ctx.note(styleAt, appL10n.plugViewStyleInvalid('{…}'));
  }
  for (final key in _pluginReservedStyleKeys) {
    if (style.containsKey(key)) ctx.note('$styleAt.$key', appL10n.plugViewStyleReserved);
  }
  const known = {
    'size',
    'weight',
    'italic',
    'underline',
    'strike',
    'align',
    'maxLines',
    'color',
    'card',
    'padding',
    'gap',
    'columns',
    'dividers',
    'background',
  };
  for (final key in style.keys.take(32)) {
    if (!known.contains(key) && !_pluginReservedStyleKeys.contains(key)) {
      ctx.note('$styleAt.$key', appL10n.plugViewStyleReserved);
    }
  }
  if (style.length > 32) ctx.note(styleAt, appL10n.plugViewStyleReserved);
  final type = raw['type'];
  final layout = type == 'stack' || type == 'row';
  final textNode = type == 'text' || type == 'metric' || type == 'callout';
  final defaults = type == 'metric' ? DshUiTextSize.title : DshUiTextSize.body;
  final size = _pluginStyleEnum(style['size'], DshUiTextSize.values, defaults, '$styleAt.size', ctx);
  final weight = _pluginStyleEnum(
    style['weight'],
    DshUiTextWeight.values,
    type == 'metric' ? DshUiTextWeight.semibold : DshUiTextWeight.regular,
    '$styleAt.weight',
    ctx,
  );
  var card = _pluginStyleEnum(style['card'], DshUiCardStyle.values, DshUiCardStyle.plain, '$styleAt.card', ctx);
  if (!layout && card != DshUiCardStyle.plain) {
    ctx.note('$styleAt.card', appL10n.plugViewStyleContainerOnly);
    card = DshUiCardStyle.plain;
  }
  final tint = _pluginColor(style['background'], '$styleAt.background', ctx);
  if (!layout && tint != null) ctx.note('$styleAt.background', appL10n.plugViewStyleContainerOnly);
  final background = layout
      ? tint != null
            ? _pluginTint(tint)
            : switch (card) {
                DshUiCardStyle.surface => DshUiPluginPalette.elevated,
                DshUiCardStyle.tinted => _pluginTint(tint ?? ctx.accent),
                _ => ctx.styleBackground,
              }
      : ctx.styleBackground;
  final chosen = _pluginColor(style['color'], '$styleAt.color', ctx);
  final tone = switch (raw['tone']) {
    'good' || 'success' || 'positive' => DshUiPluginPalette.named['green'],
    'warn' || 'warning' || 'caution' => DshUiPluginPalette.named['amber'],
    'bad' || 'danger' || 'error' || 'negative' => DshUiPluginPalette.named['red'],
    'info' || 'note' => DshUiPluginPalette.named['blue'],
    _ => null,
  };
  final selected = chosen ?? tone;
  final requested = selected != null
      ? DshUiColorPair(selected, selected)
      : raw['tone'] == 'muted' || raw['tone'] == 'secondary'
      ? DshUiPluginPalette.muted
      : DshUiPluginPalette.ink;
  final minimum = _pluginMinimumContrast(size, weight);
  final foreground = _pluginReadablePair(requested, background, minimum, '$styleAt.color', ctx);
  final accent = _pluginReadablePair(
    DshUiColorPair(ctx.accent, ctx.accent),
    background,
    4.5,
    'view.accent',
    ctx,
    once: true,
  );
  final muted = _pluginReadablePair(DshUiPluginPalette.muted, background, 4.5, '$styleAt.muted', ctx);
  int? maxLines;
  final lines = style['maxLines'];
  if (lines is int && lines >= 1 && lines <= 20) {
    maxLines = lines;
  } else if (lines != null && lines is! DshUiMissing) {
    ctx.note('$styleAt.maxLines', appL10n.plugViewStyleInvalid('1–20'));
  }
  final columns = <int>[];
  final rawColumns = style['columns'];
  if (rawColumns is List &&
      rawColumns.isNotEmpty &&
      rawColumns.length <= 8 &&
      rawColumns.every((e) => e is int && e >= 1 && e <= 12)) {
    columns.addAll(rawColumns.cast<int>());
  } else if (rawColumns != null && rawColumns is! DshUiMissing && rawColumns != 'equal') {
    ctx.note('$styleAt.columns', appL10n.plugViewStyleInvalid('equal / [1…12] × 1…8'));
  }
  if (!layout && const ['padding', 'gap', 'columns', 'dividers'].any(style.containsKey)) {
    ctx.note(styleAt, appL10n.plugViewStyleContainerOnly);
  }
  if (!textNode &&
      const ['size', 'weight', 'italic', 'underline', 'strike', 'maxLines', 'color'].any(style.containsKey)) {
    ctx.note(styleAt, appL10n.plugViewStyleTextOnly);
  }
  final spans = <DshUiRichSpan>[];
  final rawSpans = raw['spans'];
  if (type == 'text' && rawSpans != null && rawSpans is! DshUiMissing) {
    if (rawSpans is! List) {
      ctx.note('$path.spans', appL10n.plugViewStyleInvalid('[{text, …}]'));
    } else {
      var characters = 0;
      final totalLimit = ctx.p == DshUiProfile.panel
          ? 256
          : ctx.p == DshUiProfile.toolCard
          ? 64
          : 16;
      for (var i = 0; i < rawSpans.length; i++) {
        if (i >= 32 || ctx.richSpans >= totalLimit || characters >= ctx.p.text) {
          ctx.note('$path.spans', appL10n.plugViewRichLimit);
          break;
        }
        final span = rawSpans[i];
        final at = '$path.spans[$i]';
        if (span is! Map || _string(span['text']) == null) {
          ctx.note(at, appL10n.plugViewStyleInvalid('{text, …}'));
          continue;
        }
        for (final key in const ['link', 'url', 'href', 'action']) {
          if (span.containsKey(key)) ctx.note('$at.$key', appL10n.plugViewStyleReserved);
        }
        final original = _string(span['text'])!;
        final room = ctx.p.text - characters;
        final text = original.length <= room ? original : '${original.substring(0, room)}…';
        if (original.length > room) ctx.note('$path.spans', appL10n.plugViewRichLimit);
        characters += math.min(original.length, room);
        final spanWeight = _pluginStyleEnum(span['weight'], DshUiTextWeight.values, weight, '$at.weight', ctx);
        final spanColor = _pluginColor(span['color'], '$at.color', ctx);
        final spanBackground = _pluginColor(span['background'], '$at.background', ctx);
        final highlight = spanBackground == null ? null : _pluginTint(spanBackground);
        final spanForeground = _pluginReadablePair(
          spanColor == null ? requested : DshUiColorPair(spanColor, spanColor),
          highlight ?? background,
          _pluginMinimumContrast(size, spanWeight),
          '$at.color',
          ctx,
        );
        spans.add(
          DshUiRichSpan(
            text: text,
            color: spanForeground,
            weight: spanWeight,
            mono: _pluginStyleFlag(span, 'mono', at, ctx),
            background: highlight,
          ),
        );
        ctx.richSpans++;
      }
    }
  }
  final chartColors = <DshUiColorPair>[];
  DshUiColorPair? chartOther;
  if (type == 'chart' || type == 'progress') {
    for (var i = 0; i < DshUiPluginPalette.chart.length; i++) {
      chartColors.add(_pluginReadablePair(DshUiPluginPalette.chart[i], background, 3, '$path.palette[$i]', ctx));
    }
    chartOther = _pluginReadablePair(DshUiPluginPalette.chartOther, background, 3, '$path.palette.other', ctx);
  }
  return DshUiPluginStyle(
    foreground: foreground,
    background: background,
    accent: accent,
    muted: muted,
    size: size,
    weight: weight,
    italic: _pluginStyleFlag(style, 'italic', styleAt, ctx),
    underline: _pluginStyleFlag(style, 'underline', styleAt, ctx),
    strike: _pluginStyleFlag(style, 'strike', styleAt, ctx),
    align: _pluginStyleEnum(style['align'], DshUiStyleAlign.values, DshUiStyleAlign.start, '$styleAt.align', ctx),
    maxLines: maxLines,
    card: card,
    padding: layout
        ? _pluginSpacing(style['padding'], card == DshUiCardStyle.plain ? 0 : 12, '$styleAt.padding', ctx)
        : 0,
    gap: layout ? _pluginSpacing(style['gap'], path == 'view' ? 16 : 12, '$styleAt.gap', ctx) : 12,
    columns: List.unmodifiable(columns),
    dividers: layout && _pluginStyleFlag(style, 'dividers', styleAt, ctx),
    spans: List.unmodifiable(spans),
    chartColors: List.unmodifiable(chartColors),
    chartOther: chartOther,
  );
}
