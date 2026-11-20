// Small pieces shared by the feature pages (plugins, automation, phone
// control, conversation details), plus the shared empty / press / entrance
// components they all use.

import 'package:flutter/material.dart';

import '../theme/theme.dart';

export '../common/empty_view.dart';
export '../common/fade_in.dart';
export '../common/pressable.dart';

/// Loading: a small quiet ring (never a full-screen spinner), optionally with
/// a line of text.
class QuietSpinner extends StatelessWidget {
  const QuietSpinner({super.key, this.label, this.padding = const EdgeInsets.symmetric(vertical: 56)});

  final String? label;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Padding(
      padding: padding,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2, strokeCap: StrokeCap.round, color: colors.textTertiary),
            ),
            if (label case final label?) ...[
              const SizedBox(height: 12),
              Text(label, style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary)),
            ],
          ],
        ),
      ),
    );
  }
}
