import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../diagnostics/ansi.dart';
import '../../l10n/l10n.dart';
import '../terminal/terminal_palette.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../common/brief_notice.dart';

export '../../diagnostics/ansi.dart';

/// Live log well: monospace 12/1.5 in the code-well material, pinned to the newest
/// line. Built as a reversed list, so it stays at the bottom without jump logic
/// while the user hasn't scrolled up.
///
/// [terminal] draws it as a bare dark terminal (dark palette in both themes,
/// no well of its own) for [TerminalCard].
class LogView extends StatelessWidget {
  const LogView({super.key, required this.lines, this.emptyText, this.terminal = false});

  final List<String> lines;
  final String? emptyText;
  final bool terminal;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = terminal ? TerminalCard.colorsOf(context) : DshColors.of(context);
    final accent = terminal ? TerminalPalette.of(context).accent : Theme.of(context).colorScheme.primary;
    final base = AppType.monoSmall(color: colors.codeWellFg);
    final body = lines.isEmpty
        ? Center(
            child: Text(emptyText ?? l10n.phoneLogEmpty, style: base.copyWith(color: colors.textTertiary)),
          )
        : SelectionArea(
            child: ListView.builder(
              reverse: true,
              padding: terminal ? const EdgeInsets.fromLTRB(16, 4, 16, 14) : const EdgeInsets.fromLTRB(14, 12, 14, 12),
              itemCount: lines.length,
              itemBuilder: (context, index) {
                final line = stripAnsi(lines[lines.length - 1 - index]);
                final Color color;
                if (line.startsWith('[dsh-app]')) {
                  color = accent;
                } else if (_looksLikeError(line)) {
                  color = colors.danger;
                } else {
                  color = colors.codeWellFg;
                }
                return Text(line, style: base.copyWith(color: color));
              },
            ),
          );
    if (terminal) return body;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: colors.codeWellBg,
        shape: AppShape.outlined(colors.codeWellBorder, width: 0.5),
      ),
      child: ClipRSuperellipse(borderRadius: AppShape.radiusMd, child: body),
    );
  }

  static bool _looksLikeError(String line) {
    final lower = line.toLowerCase();
    return lower.contains('error') || lower.contains('fatal') || lower.contains('exception');
  }
}

/// A dark terminal card (dark in light mode too): a title row with a quiet
/// count and copy / share, then the live [LogView].
///
/// ```
/// ╭──────────────────────────────────────╮
/// │ 日志  14 行                  ⧉   ⇪ │
/// │ [gateway] listening on 127.0.0.1…   │
/// ╰──────────────────────────────────────╯
/// ```
class TerminalCard extends StatelessWidget {
  const TerminalCard({
    super.key,
    required this.title,
    required this.lines,
    this.height,
    this.emptyText,
    this.command,
    this.countLabel,
    this.shareSubject,
  });

  final String title;
  final List<String> lines;

  /// A command shown under the title row (`\$ npm run dev`).
  final String? command;

  /// Replaces 「N 行」 next to the title.
  final String? countLabel;
  final String? shareSubject;

  /// Fixed height; null fills the parent.
  final double? height;
  final String? emptyText;

  /// The dark semantic colours of the current palette: the card is dark in
  /// both themes, its neutrals follow the palette.
  static DshColors colorsOf(BuildContext context) =>
      DshColors.forAccent(Brightness.dark, DshSurfaces.of(context).accent);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = colorsOf(context);
    final background = TerminalPalette.of(context).background;
    final theme = Theme.of(context);
    final muted = colors.textTertiary;
    Widget action(IconData icon, String tooltip, VoidCallback? onPressed) => IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        foregroundColor: colors.codeWellFg,
        disabledForegroundColor: colors.textDisabled,
        highlightColor: Colors.white.withValues(alpha: 0.08),
      ),
      icon: Icon(icon, size: 18),
      onPressed: onPressed,
    );
    final card = DecoratedBox(
      decoration: ShapeDecoration(
        color: background,
        shape: RoundedSuperellipseBorder(
          borderRadius: AppShape.radiusLg,
          side: BorderSide(color: Colors.white.withValues(alpha: 0.06), width: 0.5),
        ),
      ),
      child: ClipRSuperellipse(
        borderRadius: AppShape.radiusLg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 5, 0),
              child: Row(
                children: [
                  Text(title, style: theme.textTheme.titleSmall?.copyWith(color: colors.codeWellFg)),
                  const SizedBox(width: 8),
                  Text(
                    countLabel ?? l10n.phoneLogLineCount(lines.length),
                    style: AppType.tabular(theme.textTheme.labelSmall!.copyWith(color: muted)),
                  ),
                  const Spacer(),
                  action(
                    AppIcons.copy,
                    l10n.phoneLogCopyAll,
                    lines.isEmpty ? null : () => LogActions.copy(context, lines),
                  ),
                  action(
                    AppIcons.share,
                    l10n.commonShare,
                    lines.isEmpty
                        ? null
                        : () => LogActions.share(lines, subject: shareSubject ?? l10n.phoneLogShareTitle),
                  ),
                ],
              ),
            ),
            if (command case final command?)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: SelectableText('\$ $command', maxLines: 3, style: AppType.monoSmall(color: colors.codeWellFg)),
              ),
            Expanded(
              // Lines scrolled up melt into the title row instead of being cut.
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (rect) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x00000000), Color(0xFF000000)],
                  stops: [0, 0.12],
                ).createShader(rect),
                child: LogView(lines: lines, emptyText: emptyText, terminal: true),
              ),
            ),
          ],
        ),
      ),
    );
    return height == null ? card : SizedBox(height: height, child: card);
  }
}

/// Copy / share helpers shared by the engine screen and the setup screen.
abstract final class LogActions {
  static String joined(List<String> lines) => lines.map(stripAnsi).join('\n');

  static Future<void> copy(BuildContext context, List<String> lines) async {
    await Clipboard.setData(ClipboardData(text: joined(lines)));
    if (!context.mounted) return;
    showBriefNotice(context, context.l10n.phoneLogCopiedLines(lines.length));
  }

  static Future<void> share(List<String> lines, {String? subject}) async {
    if (lines.isEmpty) return;
    await SharePlus.instance.share(ShareParams(text: joined(lines), subject: subject ?? appL10n.phoneLogShareTitle));
  }
}
