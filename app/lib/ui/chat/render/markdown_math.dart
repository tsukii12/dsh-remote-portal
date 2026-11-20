// Formulas in replies, drawn by gpt_markdown's own maths engine
// (val_latex_flutter) with chat typography, and a quiet fallback.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:val_latex_flutter/val_latex_flutter.dart';

import '../../theme/theme.dart';

/// How much larger a formula is set than the text around it.
///
/// Latin Modern's x-height is about 0.43 em against 0.53 for the sans the
/// chat uses, so at the same nominal size a formula reads a size smaller
/// than its sentence. KaTeX solves the same mismatch with 1.21 em; 1.2 puts
/// `x` in `$x$` level with the x of the words beside it.
const mathScale = 1.2;

/// Formulas in [MarkdownBody]: the gpt_markdown builders and the views they
/// return. Static, so the builders are the same function on every build
/// (gpt_markdown compares configuration by identity).
abstract final class MarkdownMath {
  /// `$…$` / `\(…\)`: text style (small fractions, limits beside the
  /// operator), on the baseline of the sentence, at its size and colour.
  static InlineSpan inline(InlineLatexBuildDetails details) =>
      details.asWidgetSpan(MathFormula(tex: details.tex, style: details.style));

  /// `$$…$$` / `\[…\]`: display style, centred in the column; wider than the
  /// column, it starts at the left edge and scrolls sideways.
  static Widget block(BlockLatexBuildDetails details) =>
      MathFormula(tex: details.tex, style: details.style, display: true);
}

/// One formula, or — when it does not parse — its source, muted.
class MathFormula extends StatelessWidget {
  const MathFormula({super.key, required this.tex, required this.style, this.display = false});

  final String tex;

  /// The text around it (size, colour, weight).
  final TextStyle style;
  final bool display;

  @override
  Widget build(BuildContext context) {
    final fontSize = style.fontSize ?? 16;
    final color = style.color ?? Theme.of(context).colorScheme.onSurface;
    // A formula in a heading is set bold, like the words around it.
    final bold = (style.fontWeight?.value ?? 400) >= 600;
    Widget math = Math.tex(
      bold ? '\\boldsymbol{$tex}' : tex,
      displayMode: display,
      // Never Math's own full-width block: its width test is a LayoutBuilder,
      // which cannot answer the intrinsic sizes a table cell asks for.
      block: false,
      wrap: false,
      overflow: MathOverflow.visible,
      textStyle: TextStyle(fontSize: fontSize * mathScale, color: color),
      // A closed formula is complete: an unfinished group is an error here,
      // shown as source rather than half-drawn.
      parseOptions: const ParseOptions(strict: Strict.ignore, streaming: false),
      onError: (context, _) => MathSource(source: tex, style: style, display: display),
    );
    if (display) {
      // Centred when it fits; wider than the column, the scroll view takes
      // the column's width and the formula starts at its left edge.
      math = _BottomBaseline(
        child: Center(
          child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: math),
        ),
      );
      // Same breathing room above and below as a paragraph line gives its
      // text, so a block formula sits in the rhythm of the prose.
      math = Padding(
        padding: EdgeInsets.symmetric(vertical: fontSize * 0.25),
        child: math,
      );
    }
    return math;
  }
}

/// A formula's TeX source in a muted monospace: what a formula that does not
/// parse shows, and what a display formula shows while it is still
/// streaming in.
class MathSource extends StatelessWidget {
  const MathSource({super.key, required this.source, required this.style, this.display = true, this.trailing});

  final String source;
  final TextStyle style;
  final bool display;

  /// After the source (the streaming cursor while the formula arrives).
  final InlineSpan? trailing;

  @override
  Widget build(BuildContext context) {
    final muted = DshColors.of(context).textTertiary;
    final mono = AppType.mono(size: (style.fontSize ?? 16) * 0.875, color: muted, height: display ? 1.55 : 1.3);
    final text = Text.rich(
      TextSpan(text: source.trim(), children: [?trailing]),
      style: mono,
    );
    if (!display) return text;
    // Wrapped, not scrolled: the point is to read what has arrived.
    return Padding(
      padding: EdgeInsets.symmetric(vertical: (style.fontSize ?? 16) * 0.25),
      child: text,
    );
  }
}

/// A display formula's baseline is its bottom edge. Said explicitly because
/// a block formula inside a table cell is measured "dry" (without layout),
/// and the scroll view inside cannot report a dry baseline of its own.
class _BottomBaseline extends SingleChildRenderObjectWidget {
  const _BottomBaseline({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderBottomBaseline();
}

class _RenderBottomBaseline extends RenderProxyBox {
  @override
  double? computeDryBaseline(BoxConstraints constraints, TextBaseline baseline) => getDryLayout(constraints).height;

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => size.height;
}
