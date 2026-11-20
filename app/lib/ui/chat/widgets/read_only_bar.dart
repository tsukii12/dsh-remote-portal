// What sits where the composer would in a conversation that can't take
// messages (a one-shot subagent: DSH Web shows it read-only).

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';

/// The composer's glass capsule, same height and radius, with one quiet
/// centred line instead of the input.
class ReadOnlyBar extends StatelessWidget {
  const ReadOnlyBar({super.key, this.text});

  final String? text;

  /// A one-line composer: the 40 keys plus 8 on each side.
  static const height = 48.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final text = this.text ?? l10n.chatReadOnlySubagent;
    final theme = Theme.of(context);
    final tertiary = DshColors.of(context).textTertiary;
    return Semantics(
      label: text,
      excludeSemantics: true,
      child: GlassSurface(
        tier: GlassTier.chrome,
        borderRadius: AppShape.radiusXl,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: height),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(AppIcons.lock, size: 16, color: tertiary),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: tertiary),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
