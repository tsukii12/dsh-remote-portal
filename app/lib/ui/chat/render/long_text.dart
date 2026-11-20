// Long tool output in the chat row: only its head and tail are laid out, the
// rest is one tap away on the full page (output_page.dart). Laying out a
// megabyte of text as one paragraph is what froze the list.

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../common/overscroll_forwarder.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../output_page.dart';
import 'ansi_text.dart';

/// 行内最多排版这么多字;超过(或行数超过头尾之和)就只留头尾。
const kClipMaxChars = 16000;

/// 行内保留的头、尾行数。结尾留得多:命令的报错和结论通常在最后。
const kClipHeadLines = 60;
const kClipTailLines = 140;

/// [text] 在行内显示的部分。没截断时 [tail] 为 null,[head] 就是全文。
class ClippedText {
  const ClippedText({
    required this.head,
    required this.totalLines,
    this.tail,
    this.hiddenLines = 0,
    this.hiddenChars = 0,
    this.tailSgr = '',
  });

  final String head;
  final String? tail;
  final int totalLines;

  /// 中间没显示的整行数;长行被拦腰截断时可能是 0,这时看 [hiddenChars]。
  final int hiddenLines;
  final int hiddenChars;

  /// 尾部开头处还生效的着色序列(开头或中间起的一段红字延续到了尾部):
  /// 渲染尾部时补在前面,颜色才不会丢。不按 ANSI 解析时是空串。
  final String tailSgr;

  bool get clipped => tail != null;
}

int _newlines(String text, int start, int end) {
  var count = 0;
  for (var i = text.indexOf('\n', start); i >= 0 && i < end; i = text.indexOf('\n', i + 1)) {
    count++;
  }
  return count;
}

bool _splitsSurrogate(String text, int index) =>
    index > 0 && index < text.length && (text.codeUnitAt(index - 1) & 0xFC00) == 0xD800;

/// 头部的结束位置往前收:不拆代理对,不拆转义序列。
int _cutBefore(String text, int index) {
  if (ansiEscapeAround(text, index) case (final start, _)) index = start;
  return _splitsSurrogate(text, index) ? index - 1 : index;
}

/// 尾部的起始位置往后放:同上。
int _cutAfter(String text, int index) {
  if (ansiEscapeAround(text, index) case (_, final end)) index = end;
  return _splitsSurrogate(text, index) ? index + 1 : index;
}

/// 只留 [text] 的头尾。按行取整;单行就超出预算的(压成一行的 JSON)按字截。
ClippedText clipLongText(
  String text, {
  int maxChars = kClipMaxChars,
  int headLines = kClipHeadLines,
  int tailLines = kClipTailLines,
  bool ansi = false,
}) {
  final totalLines = _newlines(text, 0, text.length) + 1;
  if (text.length <= maxChars && totalLines <= headLines + tailLines) {
    return ClippedText(head: text, totalLines: totalLines);
  }
  final headBudget = maxChars * 3 ~/ 10;
  final tailBudget = maxChars - headBudget;

  var headEnd = 0;
  for (var lines = 0; lines < headLines; lines++) {
    final nl = text.indexOf('\n', headEnd);
    if (nl < 0 || nl >= headBudget) break;
    headEnd = nl + 1;
  }
  if (headEnd == 0) headEnd = _cutBefore(text, headBudget.clamp(0, text.length));

  var tailStart = text.length;
  for (var lines = 0; lines < tailLines && tailStart > 0; lines++) {
    final start = tailStart < 2 ? 0 : text.lastIndexOf('\n', tailStart - 2) + 1;
    if (text.length - start > tailBudget) break;
    tailStart = start;
  }
  if (tailStart == text.length) tailStart = _cutAfter(text, (text.length - tailBudget).clamp(0, text.length));

  if (headEnd >= tailStart) return ClippedText(head: text, totalLines: totalLines);
  final head = text.substring(0, headEnd);
  return ClippedText(
    head: head.endsWith('\n') ? head.substring(0, head.length - 1) : head,
    tail: text.substring(tailStart),
    totalLines: totalLines,
    hiddenLines: _newlines(text, headEnd, tailStart),
    hiddenChars: tailStart - headEnd,
    tailSgr: ansi && hasAnsi(text) ? (SgrCarry(text)..advanceTo(tailStart)).prefix : '',
  );
}

/// 代码井里一段可能很长的等宽文本:限高滚动;太长时只排头尾,中间一行
/// 「省略 N 行」,井底一条「查看全部」进全文页。不长的文本和原来一模一样。
///
/// 只能铺在代码井([DshColors.codeWellBg])上。
class LongTextWell extends StatefulWidget {
  const LongTextWell({
    super.key,
    required this.text,
    required this.style,
    required this.title,
    required this.maxHeight,
    this.ansi = false,
    this.prompt,
  });

  final String text;
  final TextStyle style;

  /// 全文页的标题(这一段叫什么:输出、命令、参数…)。
  final String title;
  final double maxHeight;

  /// 按 ANSI 着色解析。
  final bool ansi;

  /// 排在最前面的提示符(命令的 `$ `),只是装饰,不进全文页。
  final InlineSpan? prompt;

  @override
  State<LongTextWell> createState() => _LongTextWellState();
}

class _LongTextWellState extends State<LongTextWell> {
  ClippedText? _clip;
  String? _clippedFrom;

  /// 全文的字数(不算颜色控制符);只在截断时算。
  int _chars = 0;

  ClippedText get _clipped {
    if (_clip == null || _clippedFrom != widget.text) {
      final clip = _clip = clipLongText(widget.text, ansi: widget.ansi);
      _clippedFrom = widget.text;
      _chars = !clip.clipped
          ? 0
          : widget.ansi && hasAnsi(widget.text)
          ? stripAnsi(widget.text).length
          : widget.text.length;
    }
    return _clip!;
  }

  void _openAll() {
    Navigator.of(context)
        .push(OutputPage.route(title: widget.title, text: widget.text, ansi: widget.ansi, color: widget.style.color));
  }

  Widget _text(String text, {bool first = false}) {
    if (first && widget.prompt != null) {
      return SelectableText.rich(
        TextSpan(
          children: [
            widget.prompt!,
            TextSpan(text: text),
          ],
        ),
        style: widget.style,
      );
    }
    return widget.ansi ? AnsiText(text: text, style: widget.style) : SelectableText(text, style: widget.style);
  }

  @override
  Widget build(BuildContext context) {
    final clip = _clipped;
    final Widget content;
    if (clip.tail case final tail?) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (clip.head.isNotEmpty) _text(clip.head, first: true),
          _Gap(clip: clip, onTap: _openAll),
          _text(clip.tailSgr + tail, first: clip.head.isEmpty),
        ],
      );
    } else {
      content = _text(clip.head, first: true);
    }
    final well = ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      child: OverscrollForwarder(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(12, 4, 12, clip.clipped ? 8 : 12),
          child: SizedBox(width: double.infinity, child: content),
        ),
      ),
    );
    if (!clip.clipped) return well;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        well,
        _ViewAllBar(clip: clip, chars: _chars, onTap: _openAll),
      ],
    );
  }
}

/// 头尾之间的那一行:「⋯ 中间省略 1,234 行 ⋯」。点它也进全文页。
class _Gap extends StatelessWidget {
  const _Gap({required this.clip, required this.onTap});

  final ClippedText clip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final dsh = DshColors.of(context);
    final label = clip.hiddenLines > 0
        ? l10n.chatOutputHiddenLines(clip.hiddenLines, formatCount(context, clip.hiddenLines))
        : l10n.chatOutputHiddenChars(formatCount(context, clip.hiddenChars));
    final rule = Expanded(child: Divider(height: 1, thickness: 0.5, color: dsh.codeWellBorder));
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              rule,
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(label, style: AppType.monoLabel(color: dsh.textTertiary)),
              ),
              rule,
            ],
          ),
        ),
      ),
    );
  }
}

/// 井底的一条:左边「共 N 行 · M 字」,右边「查看全部 ›」。整条可点。
class _ViewAllBar extends StatelessWidget {
  const _ViewAllBar({required this.clip, required this.chars, required this.onTap});

  final ClippedText clip;
  final int chars;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final label = theme.textTheme.labelMedium;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: dsh.codeWellBorder, width: 0.5)),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.chatOutputSummary(
                      clip.totalLines,
                      formatCount(context, clip.totalLines),
                      formatCount(context, chars),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: label?.copyWith(color: dsh.textTertiary),
                  ),
                ),
                const SizedBox(width: 8),
                Text(l10n.chatOutputViewAll, style: label?.copyWith(color: theme.colorScheme.primary)),
                Icon(AppIcons.disclosure, size: 16, color: theme.colorScheme.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
