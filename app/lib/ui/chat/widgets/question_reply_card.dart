import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../secret_mask.dart';
import '../tool_view.dart';

/// Readable answers from the saved tool result; no optimistic user message.
class QuestionReplyCard extends StatelessWidget {
  const QuestionReplyCard({super.key, required this.replies});

  final List<QuestionReply> replies;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: DecoratedBox(
        decoration: ShapeDecoration(color: colors.primary.withValues(alpha: 0.08), shape: AppShape.bubble),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(AppIcons.selected, size: 16, color: colors.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      context.l10n.chatQuestionAnswered,
                      style: theme.textTheme.labelLarge?.copyWith(color: colors.primary),
                    ),
                  ),
                ],
              ),
              for (final reply in replies) ...[
                const SizedBox(height: 8),
                SecretText(
                  reply.question,
                  style: AppType.chatBody(context, scale: 14 / 16, color: colors.onSurfaceVariant),
                ),
                const SizedBox(height: 2),
                SecretText(
                  reply.answer,
                  key: ValueKey(reply.id),
                  style: AppType.chatBody(context, color: colors.onSurface),
                  interactive: true,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
