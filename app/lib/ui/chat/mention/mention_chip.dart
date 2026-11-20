// The inline reference chip (after DSH's `ReferenceChip`: file / folder /
// conversation icon + label), shared by the composer and the sent bubble, and
// the bubble's text with chips in it.

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../theme/app_icons.dart';
import '../secret_mask.dart';
import 'mention_syntax.dart';

/// 行内引用签:图标 + 名字,很淡的中性底,和一行文字同高。
///
/// ```
/// 看看 ( ▤ main.dart ) 为什么报错
/// ```
///
/// 图标是主色的小线性图标,名字是正文色;太长的名字截断。
class MentionChip extends StatelessWidget {
  const MentionChip({super.key, required this.kind, required this.label, this.style});

  final MentionKind kind;
  final String label;

  /// The surrounding text's style; the chip sizes itself to one line of it.
  final TextStyle? style;

  static const maxWidth = 200.0;

  /// The rest of a reference's characters in the composer: drawn with no
  /// width, so the chip stands in for all of them.
  static const hiddenStyle = TextStyle(
    color: Color(0x00000000),
    fontSize: 0.01,
    letterSpacing: 0,
    wordSpacing: 0,
    decoration: TextDecoration.none,
  );

  /// Dictated text that is not final yet: secondary ink, a step lighter
  /// than the text and darker than the hint.
  static TextStyle provisionalStyle(BuildContext context, TextStyle? base) =>
      TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant);

  static IconData iconFor(MentionKind kind) => switch (kind) {
    MentionKind.file => AppIcons.document,
    MentionKind.folder => AppIcons.folder,
    MentionKind.session => AppIcons.chat,
  };

  static String semanticKind(MentionKind kind) => switch (kind) {
    MentionKind.file => appL10n.chatFile,
    MentionKind.folder => appL10n.chatFolder,
    MentionKind.session => appL10n.chatChat,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final base = style ?? DefaultTextStyle.of(context).style;
    final size = base.fontSize ?? 16;
    final labelStyle = base.copyWith(
      fontSize: size * 0.875,
      height: 1.25,
      fontWeight: FontWeight.w500,
      color: colors.onSurface,
      decoration: TextDecoration.none,
    );
    final dark = theme.brightness == Brightness.dark;
    return Semantics(
      label: l10n.chatMentionSemantics(semanticKind(kind), label),
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(maxWidth: maxWidth),
        margin: const EdgeInsets.symmetric(horizontal: 1),
        padding: const EdgeInsets.fromLTRB(5, 1, 7, 1),
        decoration: ShapeDecoration(
          color: dark ? Colors.white.withValues(alpha: 0.09) : colors.onSurface.withValues(alpha: 0.06),
          shape: const StadiumBorder(),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(iconFor(kind), size: MediaQuery.textScalerOf(context).scale(size * 0.8125), color: colors.primary),
            const SizedBox(width: 3),
            Flexible(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false, style: labelStyle),
            ),
          ],
        ),
      ),
    );
  }
}

/// 已发送消息的文字:引用画成 [MentionChip],其余照常。
///
/// 含凭据的消息整段交给 [SecretText](遮挡优先,不画签)。
class ReferenceText extends StatelessWidget {
  const ReferenceText(this.text, {super.key, required this.style, this.interactive = false});

  final String text;
  final TextStyle style;

  /// Passed through to [SecretText] (the eye on masked values).
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    final tokens = parseMessageMentions(text, labels: MentionLabels.all);
    if (tokens.isEmpty || findSecrets(text).isNotEmpty) {
      return SecretText(text, style: style, interactive: interactive);
    }
    // A canonical mention in an optimistic bubble: remember its label, the
    // echoed message carries it as plain `@label`.
    for (final t in tokens) {
      if (t.kind == MentionKind.session) MentionLabels.add(t.label);
    }
    final children = <InlineSpan>[];
    var at = 0;
    for (final t in tokens) {
      if (t.start > at) {
        children.add(TextSpan(text: text.substring(at, t.start)));
      }
      children.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: MentionChip(kind: t.kind, label: t.label, style: style),
        ),
      );
      at = t.end;
    }
    if (at < text.length) children.add(TextSpan(text: text.substring(at)));
    return Text.rich(TextSpan(children: children), style: style);
  }
}
