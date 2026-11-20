// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'package:flutter/material.dart';

import '../../theme/semantic_colors.dart';

/// CSI 序列(ESC[ ... 终结字节)。非 SGR(终结字节非 m)一律剥离不渲染。
final _csi = RegExp('\x1B\\[([0-9;?]*)([A-Za-z])');

/// OSC 序列(ESC] ... BEL / ESC\),如终端标题、超链接。直接剥离。
final _osc = RegExp('\x1B\\][^\x07\x1B]*(?:\x07|\x1B\\\\)');

/// 去掉所有 ANSI 转义(复制 / 纯文本场景用)。
String stripAnsi(String input) => input.replaceAll(_osc, '').replaceAll(_csi, '');

/// 文本里有没有 ANSI 转义(没有就走纯文本快路径)。
bool hasAnsi(String input) => input.contains('\x1B');

/// 去掉 OSC 序列,留下 SGR 着色。
String stripOsc(String input) => input.replaceAll(_osc, '');

/// 往回找转义序列起点时最多看这么远:一个 OSC 序列(超链接的地址在里面)
/// 不会比这更长,CSI 更短。有了上限,在一段没有转义的长文本里反复问也不贵。
const _escapeLookBack = 4096;

/// [index] 落在一个转义序列中间时,序列的 (起点, 终点后一位);否则 null。
/// 截断长文本时用:序列要么整个留下,要么整个不要。
(int, int)? ansiEscapeAround(String text, int index) {
  if (index <= 0 || index >= text.length) return null;
  var esc = -1;
  final floor = index > _escapeLookBack ? index - _escapeLookBack : 0;
  for (var i = index - 1; i >= floor; i--) {
    if (text.codeUnitAt(i) == 0x1B) {
      esc = i;
      break;
    }
  }
  if (esc < 0 || esc + 1 >= text.length) return null;
  final kind = text.codeUnitAt(esc + 1);
  if (kind == 0x5D) {
    // OSC:到 BEL 或 ST(ESC \)才算完,中间的字母不是终结符。
    final limit = esc + _escapeLookBack < text.length ? esc + _escapeLookBack : text.length;
    for (var i = esc + 2; i < limit; i++) {
      final c = text.codeUnitAt(i);
      if (c == 0x07) return i >= index ? (esc, i + 1) : null;
      if (c == 0x1B) {
        final st = i + 1 < text.length && text.codeUnitAt(i + 1) == 0x5C;
        final end = st ? i + 2 : i;
        return end > index ? (esc, end) : null;
      }
    }
    return null;
  }
  // ST 的那个 ESC:[index] 夹在 ESC 和 \ 之间。
  if (kind == 0x5C) return index == esc + 1 ? (esc, esc + 2) : null;
  if (kind != 0x5B) return null;
  final (params, end) = _csiAt(text, esc);
  if (end > 0) return end > index ? (esc, end) : null;
  // 没写完的 CSI(文本到此为止):[index] 还在它的参数里,从 ESC 起都不要。
  return params >= index ? (esc, index) : null;
}

/// 认作一个整体的 CSI 最长这么多。前景加背景的真彩色也就三十多个字;
/// 再长的(ESC[ 后面跟着几兆数字)不是着色,当普通文字,免得在它身上
/// 反复做和它一样长的匹配。
const _csiMax = 4000;

/// [esc] 处的 `ESC[`:参数到哪为止,以及整个序列的终点后一位(没有终结
/// 字母、或者超过 [_csiMax] 时是 -1)。
(int, int) _csiAt(String text, int esc) {
  var i = esc + 2;
  final limit = esc + _csiMax < text.length ? esc + _csiMax : text.length;
  while (i < limit) {
    final c = text.codeUnitAt(i);
    if (!((c >= 0x30 && c <= 0x39) || c == 0x3B || c == 0x3F)) break;
    i++;
  }
  if (i >= limit) return (i, -1);
  final c = text.codeUnitAt(i);
  final letter = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
  return (i, letter ? i + 1 : -1);
}

/// 顺着一段文本往后走,记住「到这里为止还生效的着色」。
///
/// 把着色文本从中间切开单独渲染时(截断后的尾部、全文页的每一行),在这
/// 一段前面补上 [prefix],颜色就和连着渲染时一样。只看转义序列,不建
/// TextSpan;游标只往前走,整段文本一共只扫一遍,和切成多少段无关。
class SgrCarry {
  SgrCarry(this.source);

  final String source;

  /// 走过的 CSI 序列(着色和非着色的)一共占了多少字。
  int escapeChars = 0;

  String? _fg;
  String? _bg;
  bool _bold = false;
  bool _italic = false;
  bool _underline = false;
  String? _prefix = '';

  /// 下一个 ESC 的位置;-1 是后面再没有了,-2 是还没找。
  int _next = -2;
  int _from = 0;

  /// 走到 [end](不含)。[end] 只能往后。
  void advanceTo(int end) {
    while (true) {
      if (_next == -2) _next = source.indexOf('\x1B', _from);
      if (_next < 0 || _next >= end) return;
      final esc = _next;
      final csi = esc + 1 < source.length && source.codeUnitAt(esc + 1) == 0x5B;
      final (params, stop) = csi ? _csiAt(source, esc) : (esc, -1);
      // 跨过了 [end] 的序列留给下一次。
      if (stop > end) return;
      _from = esc + 1;
      _next = -2;
      if (stop < 0) continue;
      escapeChars += stop - esc;
      if (source.codeUnitAt(params) == 0x6D) _apply(source.substring(esc + 2, params));
    }
  }

  /// 和 [parseAnsi] 对同一串参数的理解一致,只是记的是参数本身而不是颜色。
  void _apply(String raw) {
    final params = (raw.isEmpty ? '0' : raw).split(';').map((s) => int.tryParse(s) ?? 0).toList();
    for (var i = 0; i < params.length; i++) {
      final code = params[i];
      switch (code) {
        case 0:
          _fg = _bg = null;
          _bold = _italic = _underline = false;
        case 1:
          _bold = true;
        case 3:
          _italic = true;
        case 4:
          _underline = true;
        case 22:
          _bold = false;
        case 23:
          _italic = false;
        case 24:
          _underline = false;
        case 39:
          _fg = null;
        case 49:
          _bg = null;
        case (>= 30 && <= 37) || (>= 90 && <= 97):
          _fg = '$code';
        case (>= 40 && <= 47) || (>= 100 && <= 107):
          _bg = '$code';
        case 38 || 48:
          if (i + 1 >= params.length) break;
          String? colour;
          if (params[i + 1] == 5) {
            if (i + 2 >= params.length) {
              i += 1;
            } else {
              final n = params[i + 2];
              if (n >= 0 && n <= 255) colour = '$code;5;$n';
              i += 2;
            }
          } else if (params[i + 1] == 2) {
            if (i + 4 >= params.length) {
              i = params.length - 1;
            } else {
              colour = '$code;2;${params[i + 2]};${params[i + 3]};${params[i + 4]}';
              i += 4;
            }
          }
          if (colour != null) {
            if (code == 38) {
              _fg = colour;
            } else {
              _bg = colour;
            }
          }
      }
    }
    _prefix = null;
  }

  /// 补在后面一段文本前的序列;没有生效的着色时是空串。
  String get prefix {
    if (_prefix case final cached?) return cached;
    final parts = [if (_bold) '1', if (_italic) '3', if (_underline) '4', ?_fg, ?_bg];
    return _prefix = parts.isEmpty ? '' : '\x1B[${parts.join(';')}m';
  }
}

class _SgrState {
  Color? fg;
  Color? bg;
  bool bold = false;
  bool italic = false;
  bool underline = false;

  void reset() {
    fg = null;
    bg = null;
    bold = false;
    italic = false;
    underline = false;
  }

  TextStyle apply(TextStyle base) => base.copyWith(
    color: fg ?? base.color,
    backgroundColor: bg ?? base.backgroundColor,
    fontWeight: bold ? FontWeight.w600 : base.fontWeight,
    fontStyle: italic ? FontStyle.italic : base.fontStyle,
    decoration: underline ? TextDecoration.underline : base.decoration,
  );
}

/// 解析 SGR 着色文本为 TextSpan。[ansi16] 为 SGR 30-37 / 90-97 色板。
TextSpan parseAnsi(String input, TextStyle base, List<Color> ansi16) {
  final source = input.replaceAll(_osc, '');
  if (!hasAnsi(source)) return TextSpan(text: source, style: base);
  final children = <TextSpan>[];
  final sgr = _SgrState();
  var last = 0;
  void flushText(int end) {
    if (end > last) {
      children.add(TextSpan(text: source.substring(last, end), style: sgr.apply(base)));
    }
  }

  for (final m in _csi.allMatches(source)) {
    flushText(m.start);
    last = m.end;
    if (m[2] != 'm') continue;
    final params = (m[1]!.isEmpty ? '0' : m[1]!).split(';').map((s) => int.tryParse(s) ?? 0).toList();
    var i = 0;
    while (i < params.length) {
      final code = params[i];
      switch (code) {
        case 0:
          sgr.reset();
        case 1:
          sgr.bold = true;
        case 3:
          sgr.italic = true;
        case 4:
          sgr.underline = true;
        case 22:
          sgr.bold = false;
        case 23:
          sgr.italic = false;
        case 24:
          sgr.underline = false;
        case 39:
          sgr.fg = null;
        case 49:
          sgr.bg = null;
        case >= 30 && <= 37:
          sgr.fg = ansi16[code - 30];
        case >= 90 && <= 97:
          sgr.fg = ansi16[code - 82];
        case >= 40 && <= 47:
          sgr.bg = ansi16[code - 40].withValues(alpha: 0.18);
        case >= 100 && <= 107:
          sgr.bg = ansi16[code - 92].withValues(alpha: 0.18);
        case 38 || 48:
          final (color, consumed) = _extendedColor(params, i, ansi16);
          if (code == 38) {
            sgr.fg = color ?? sgr.fg;
          } else {
            sgr.bg = color?.withValues(alpha: 0.18) ?? sgr.bg;
          }
          i += consumed;
        default:
          break;
      }
      i++;
    }
  }
  flushText(source.length);
  return TextSpan(style: base, children: children);
}

/// 38;5;n(xterm256)/ 38;2;r;g;b(truecolor)。返回 (颜色, 额外消耗的参数个数)。
(Color?, int) _extendedColor(List<int> params, int i, List<Color> ansi16) {
  if (i + 1 >= params.length) return (null, 0);
  switch (params[i + 1]) {
    case 5:
      if (i + 2 >= params.length) return (null, 1);
      return (_xterm256(params[i + 2], ansi16), 2);
    case 2:
      if (i + 4 >= params.length) return (null, params.length - i - 1);
      return (
        Color.fromARGB(255, params[i + 2].clamp(0, 255), params[i + 3].clamp(0, 255), params[i + 4].clamp(0, 255)),
        4,
      );
    default:
      return (null, 0);
  }
}

Color? _xterm256(int n, List<Color> ansi16) {
  if (n < 0 || n > 255) return null;
  if (n < 16) return ansi16[n];
  if (n < 232) {
    // 6×6×6 色立方
    final v = n - 16;
    const steps = [0, 95, 135, 175, 215, 255];
    return Color.fromARGB(255, steps[v ~/ 36], steps[(v % 36) ~/ 6], steps[v % 6]);
  }
  final gray = 8 + (n - 232) * 10;
  return Color.fromARGB(255, gray, gray, gray);
}

/// 带 ANSI 着色的可选中文本;按 (text, 色板) 记忆化解析结果。
///
/// 只能铺在代码井([DshColors.codeWellBg])上:ANSI 色板是按井底调的对比度。
class AnsiText extends StatefulWidget {
  const AnsiText({super.key, required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  State<AnsiText> createState() => _AnsiTextState();
}

class _AnsiTextState extends State<AnsiText> {
  TextSpan? _span;
  String? _parsedText;
  TextStyle? _parsedStyle;
  List<Color>? _parsedPalette;

  @override
  Widget build(BuildContext context) {
    final palette = DshColors.of(context).ansi;
    if (_span == null ||
        _parsedText != widget.text ||
        _parsedStyle != widget.style ||
        !identical(_parsedPalette, palette)) {
      _span = parseAnsi(widget.text, widget.style, palette);
      _parsedText = widget.text;
      _parsedStyle = widget.style;
      _parsedPalette = palette;
    }
    return SelectableText.rich(_span!);
  }
}
