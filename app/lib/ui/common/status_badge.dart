import 'package:flutter/material.dart';

import '../theme/theme.dart';

class StatusBadge extends StatelessWidget {
  const StatusBadge(this.text, {super.key, this.tone = StatusBadgeTone.neutral});
  final String text;
  final StatusBadgeTone tone;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final (bg, fg) = switch (tone) {
      StatusBadgeTone.official => (scheme.primaryContainer, scheme.onPrimaryContainer),
      StatusBadgeTone.featured || StatusBadgeTone.warning => (colors.warningContainer, colors.onWarningContainer),
      StatusBadgeTone.danger => (colors.dangerContainer, colors.onDangerContainer),
      StatusBadgeTone.neutral => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    return DecoratedBox(
      decoration: ShapeDecoration(color: bg, shape: Squircle.border(8)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        child: Text(
          text,
          style: theme.textTheme.labelSmall?.copyWith(color: fg, fontWeight: FontWeight.w600, height: 1.3),
        ),
      ),
    );
  }
}

enum StatusBadgeTone { neutral, official, featured, warning, danger }
