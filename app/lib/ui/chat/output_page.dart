// The full text behind a clipped tool output (or a clipped section of the
// step page): every line of it, built a screenful at a time, ANSI colours
// kept, selectable, with copy-all and a jump to the end.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../common/brief_notice.dart';
import '../common/side_insets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'render/ansi_text.dart';

/// 千分位的整数(「12,480 行」)。
String formatCount(BuildContext context, int value) =>
    NumberFormat.decimalPattern(context.l10n.localeName).format(value);

/// 一行超过这么多字就切成几段各自排版(压成一行的 JSON 可能有几 MB;
/// 自动换行下切口看不出来)。
const _maxRowChars = 4000;

/// 行数不超过这么多时滚动条可以拖。
const _dragRows = 1500;

/// 一段长文本的全文页。
class OutputPage extends StatefulWidget {
  const OutputPage({super.key, required this.title, required this.text, this.ansi = false, this.color});

  final String title;
  final String text;

  /// 按 ANSI 着色解析;关掉时原样显示。
  final bool ansi;

  /// 文字颜色;默认代码井前景色(报错传危险色)。
  final Color? color;

  static Route<void> route({required String title, required String text, bool ansi = false, Color? color}) =>
      MaterialPageRoute<void>(
        builder: (_) => OutputPage(title: title, text: text, ansi: ansi, color: color),
      );

  @override
  State<OutputPage> createState() => _OutputPageState();
}

/// 每段在原文里的 [起, 止)(不含行尾换行)。长行按 [_maxRowChars] 再切,
/// 不拆代理对,也不拆转义序列。
List<int> _rowBounds(String text, {required bool ansi}) {
  final bounds = <int>[];
  var start = 0;
  while (true) {
    final nl = text.indexOf('\n', start);
    final end = nl < 0 ? text.length : nl;
    var from = start;
    while (end - from > _maxRowChars) {
      var cut = from + _maxRowChars;
      if (ansi) {
        if (ansiEscapeAround(text, cut) case (final escape, _) when escape > from) cut = escape;
      }
      if ((text.codeUnitAt(cut - 1) & 0xFC00) == 0xD800) cut--;
      bounds
        ..add(from)
        ..add(cut);
      from = cut;
    }
    bounds
      ..add(from)
      ..add(end);
    if (nl < 0) return bounds;
    start = nl + 1;
  }
}

class _OutputPageState extends State<OutputPage> {
  final _controller = ScrollController(keepScrollOffset: false);

  late final bool _coloured = widget.ansi && hasAnsi(widget.text);

  /// 排版用的文本:着色时先去掉 OSC(标题、超链接),只留颜色序列。
  late final String _source = _coloured ? stripOsc(widget.text) : widget.text;

  /// 每段的边界;段的文字用到时才切出来、才解析颜色。
  late final List<int> _bounds = _rowBounds(_source, ansi: _coloured);

  /// 着色时,每段开头还生效的颜色序列(只记非空的):一段红字跨了三行,
  /// 后两行各自解析时要先补上那个红。只扫一遍转义序列,不建 TextSpan。
  late final Map<int, String> _carried = _carry();
  int _escapeChars = 0;

  late final int _lines = '\n'.allMatches(widget.text).length + 1;

  Map<int, String> _carry() {
    if (!_coloured) return const {};
    final carried = <int, String>{};
    final carry = SgrCarry(_source);
    for (var row = 0; row * 2 < _bounds.length; row++) {
      final prefix = carry.prefix;
      if (prefix.isNotEmpty) carried[row] = prefix;
      carry.advanceTo(_bounds[row * 2 + 1]);
    }
    _escapeChars = carry.escapeChars;
    return carried;
  }

  /// 从末尾往回排(列表反向)。列表按需建行、行高不定,要滚到很远的地方只能
  /// 把途中每一行都排一遍,几万行就卡死了;所以「跳到末尾」不滚,而是换成
  /// 从最后一行排起的列表,和行数无关。
  bool _fromEnd = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggleEnd() {
    // 一屏就放得下:没有可跳的,反向排还会让内容沉到底。
    if (!_fromEnd && _controller.hasClients && _controller.position.maxScrollExtent <= 0) return;
    HapticFeedback.selectionClick();
    setState(() => _fromEnd = !_fromEnd);
  }

  Future<void> _copyAll() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    HapticFeedback.lightImpact();
    await Clipboard.setData(ClipboardData(text: widget.ansi ? stripAnsi(widget.text) : widget.text));
    messenger?.showBriefNotice(l10n.chatOutputCopied);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final padding = MediaQuery.paddingOf(context);
    final style = AppType.mono(size: 12.5, color: widget.color ?? dsh.codeWellFg, height: 1.55);

    final source = _source;
    final carried = _carried;
    final palette = dsh.ansi;
    final rows = _bounds.length ~/ 2;
    // 字数不算颜色控制符。
    final chars = source.length - _escapeChars;
    InlineSpan rowAt(int i) {
      final text = source.substring(_bounds[i * 2], _bounds[i * 2 + 1]);
      if (!_coloured) return TextSpan(text: text);
      final prefix = carried[i];
      return parseAnsi(prefix == null ? text : prefix + text, style, palette);
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dshSystemOverlay(theme.brightness),
      child: AppBackdrop(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SideSafeArea(
            child: Column(
              children: [
                SizedBox(height: padding.top),
                SizedBox(
                  height: 56,
                  child: BackdropGroup(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          GlassIconButton(
                            icon: AppIcons.back,
                            tooltip: l10n.commonBack,
                            onPressed: () => Navigator.of(context).maybePop(),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium?.copyWith(height: 1.25),
                                ),
                                Text(
                                  l10n.chatOutputSummary(
                                    _lines,
                                    formatCount(context, _lines),
                                    formatCount(context, chars),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall?.copyWith(fontSize: 12, color: dsh.textTertiary),
                                ),
                              ],
                            ),
                          ),
                          GlassIconButton(
                            icon: _fromEnd ? AppIcons.scrollToTop : AppIcons.scrollToBottom,
                            tooltip: _fromEnd ? l10n.chatOutputToStart : l10n.chatOutputToEnd,
                            onPressed: _toggleEnd,
                          ),
                          const SizedBox(width: 8),
                          GlassIconButton(icon: AppIcons.copy, tooltip: l10n.chatOutputCopyAll, onPressed: _copyAll),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, math.max(padding.bottom, 16)),
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        color: dsh.codeWellBg,
                        shape: RoundedSuperellipseBorder(
                          borderRadius: AppShape.radiusMd,
                          side: BorderSide(color: dsh.codeWellBorder, width: 0.5),
                        ),
                      ),
                      child: Squircle.clip(
                        radius: AppShape.md,
                        child: SelectionArea(
                          child: Scrollbar(
                            controller: _controller,
                            // 拖滑块等于滚到很远的地方,行多了同样会卡。
                            interactive: rows <= _dragRows,
                            child: ListView.builder(
                              // 换方向就是换一个列表,从它自己的起点开始。
                              key: ValueKey(_fromEnd),
                              controller: _controller,
                              reverse: _fromEnd,
                              padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
                              itemCount: rows,
                              itemBuilder: (context, i) => Text.rich(rowAt(_fromEnd ? rows - 1 - i : i), style: style),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
