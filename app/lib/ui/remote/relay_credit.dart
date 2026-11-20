// The line under the DSH Remote card: who provides the service, with the
// upstream project as a link to its GitHub page.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/app_info.dart';
import '../../state/star_prompt.dart' show starLinkOpenerProvider;
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';

/// 「服务由 liguobao/ds-harness-remote 提供」. Only the project name and its
/// glyph open the project page, in the browser app as 给项目点 Star does
/// (signed in to GitHub there, a star is one tap away).
/// They take taps up to 48dp tall by reaching into the empty space above and
/// below their line: never into the card above, the next section or the rest
/// of the line.
///
/// The footer of a [SettingsSection] laid out with [sectionMargin]: the
/// credit carries the section's bottom margin itself, so the link can reach
/// into it while the page lays out exactly as with [kSettingsGroupMargin].
class RelayCredit extends ConsumerStatefulWidget {
  const RelayCredit({super.key, this.server});

  /// A self-hosted server, named after the credit.
  final String? server;

  /// The margin of the section this is the footer of.
  static final sectionMargin = kSettingsGroupMargin.copyWith(bottom: 0);

  @override
  ConsumerState<RelayCredit> createState() => _RelayCreditState();
}

class _RelayCreditState extends ConsumerState<RelayCredit> {
  late final _tap = TapGestureRecognizer()
    ..onTapDown = ((_) => _press(true))
    ..onTapCancel = (() => _press(false))
    ..onTap = () {
      _press(false);
      unawaited(_open());
    };
  bool _pressed = false;

  void _press(bool down) {
    if (mounted && _pressed != down) setState(() => _pressed = down);
  }

  /// No browser: the address goes to the clipboard and a line says so.
  Future<void> _open() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final url = Uri.parse(AppInfo.remoteProjectUrl);
    var opened = false;
    try {
      opened = await ref.read(starLinkOpenerProvider)(url);
    } catch (_) {
      // No browser: handled below.
    }
    if (opened) return;
    var copied = true;
    try {
      await Clipboard.setData(ClipboardData(text: url.toString()));
    } catch (_) {
      copied = false;
    }
    messenger?.showSnackBar(SnackBar(content: Text(copied ? l10n.shellBrowserUrlCopied : l10n.stateBrowserOpenFailed)));
  }

  @override
  void dispose() {
    _tap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    const project = AppInfo.remoteProject;
    final server = widget.server;
    final text = server == null ? l10n.remoteRelayProvider(project) : l10n.remoteRelayProviderServer(project, server);
    final at = text.indexOf(project);
    final gapBelow = EdgeInsets.only(bottom: kSettingsGroupMargin.bottom);
    if (at < 0) return Padding(padding: gapBelow, child: Text(text));

    final color = Theme.of(context).colorScheme.primary.withValues(alpha: _pressed ? 0.6 : 1);
    final before = text.substring(0, at);
    // The word joiner keeps the glyph on the name's line.
    const name = '$project\u2060';
    return _LinkHitArea(
      start: before.length,
      textEnd: before.length + name.length,
      // + the glyph's placeholder.
      end: before.length + name.length + 1,
      above: SettingsSection.footerGap,
      below: kSettingsGroupMargin.bottom,
      child: Padding(
        padding: gapBelow,
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: before),
              TextSpan(
                text: name,
                semanticsLabel: project,
                style: TextStyle(color: color),
                recognizer: _tap,
              ),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: ExcludeSemantics(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 2),
                    child: Icon(AppIcons.openExternal, size: 12, color: color, applyTextScaling: true),
                  ),
                ),
              ),
              TextSpan(text: text.substring(at + project.length)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Passes taps in the link's area to the link span of the [Text] below it.
/// The area is the link's text and glyph, on the first line taken up to
/// [above] higher and on the last line up to [below] lower, until it is
/// [kMinInteractiveDimension] tall. The ancestors must let taps there through:
/// [above] lies in the padding above this box, [below] inside it.
class _LinkHitArea extends SingleChildRenderObjectWidget {
  const _LinkHitArea({
    required this.start,
    required this.textEnd,
    required this.end,
    required this.above,
    required this.below,
    required super.child,
  });

  /// The link in the paragraph's text: [start]–[textEnd] the words, up to
  /// [end] with the glyph.
  final int start;
  final int textEnd;
  final int end;
  final double above;
  final double below;

  @override
  _RenderLinkHitArea createRenderObject(BuildContext context) =>
      _RenderLinkHitArea(start: start, textEnd: textEnd, end: end, above: above, below: below);

  @override
  void updateRenderObject(BuildContext context, _RenderLinkHitArea renderObject) {
    renderObject
      ..start = start
      ..textEnd = textEnd
      ..end = end
      ..above = above
      ..below = below;
  }
}

/// See [_LinkHitArea].
class _RenderLinkHitArea extends RenderProxyBox {
  _RenderLinkHitArea({
    required this.start,
    required this.textEnd,
    required this.end,
    required this.above,
    required this.below,
  });

  // Read on each hit test; nothing to lay out or paint again.
  int start;
  int textEnd;
  int end;
  double above;
  double below;

  RenderParagraph? get _paragraph {
    RenderObject? node = child;
    while (node is RenderObjectWithChildMixin) {
      node = node.child;
    }
    return node is RenderParagraph ? node : null;
  }

  /// Where the link takes taps, in this box's coordinates: one area per line
  /// it is on, each with the point on its words a tap there goes to.
  List<({Rect area, Offset anchor})> get _targets {
    final paragraph = _paragraph;
    if (paragraph == null || !paragraph.hasSize) return const [];
    final length = paragraph.text.toPlainText(includeSemanticsLabels: false).length;
    if (length == 0 || end > length) return const [];
    List<Rect> boxes(int from, int to) => [
      for (final box in paragraph.getBoxesForSelection(
        TextSelection(baseOffset: from, extentOffset: to),
        boxHeightStyle: ui.BoxHeightStyle.includeLineSpacingMiddle,
      ))
        box.toRect(),
    ];
    bool sameLine(Rect a, Rect b) => a.top < b.bottom && b.top < a.bottom;
    final firstLine = boxes(0, 1).firstOrNull;
    final lastLine = boxes(length - 1, length).firstOrNull;
    final lines = <Rect>[];
    for (final box in boxes(start, end)) {
      final i = lines.indexWhere((line) => sameLine(line, box));
      if (i < 0) {
        lines.add(box);
      } else {
        lines[i] = lines[i].expandToInclude(box);
      }
    }
    final words = boxes(start, textEnd);
    final toHere = paragraph.getTransformTo(this);
    final height = paragraph.size.height;
    final targets = <({Rect area, Offset anchor})>[];
    for (final line in lines) {
      // The glyph alone on a line has no words to pass the tap to.
      final word = words.where((w) => sameLine(w, line)).firstOrNull;
      if (word == null) continue;
      final first = firstLine != null && sameLine(line, firstLine);
      final last = lastLine != null && sameLine(line, lastLine);
      final top = first ? 0.0 : line.top;
      final bottom = last ? height : line.bottom;
      final need = math.max(0.0, kMinInteractiveDimension - (bottom - top));
      var up = first ? math.min(above, need / 2) : 0.0;
      final down = last ? math.min(below, need - up) : 0.0;
      if (first) up = math.min(above, need - down);
      targets.add((
        area: MatrixUtils.transformRect(toHere, Rect.fromLTRB(line.left, top - up, line.right, bottom + down)),
        anchor: MatrixUtils.transformPoint(toHere, word.center),
      ));
    }
    return targets;
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    for (final target in _targets) {
      if (target.area.contains(position)) {
        // As if the words themselves were tapped: their recognizer takes it.
        child!.hitTest(result, position: target.anchor);
        result.add(BoxHitTestEntry(this, position));
        return true;
      }
    }
    return super.hitTest(result, position: position);
  }
}
