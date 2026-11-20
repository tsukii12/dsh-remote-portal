import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';

/// Shared feedback for the card and full-screen image, including small tiles.
class MediaImageFeedback extends StatelessWidget {
  const MediaImageFeedback({super.key, this.error, this.onRetry, this.caption, this.dark = false});

  final String? error;
  final VoidCallback? onRetry;
  final String? caption;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final color = dark ? Colors.white70 : DshColors.of(context).textTertiary;
    final loading = error == null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            (constraints.hasBoundedHeight && constraints.maxHeight < 160) ||
            (constraints.hasBoundedWidth && constraints.maxWidth < 150);
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (loading)
                  SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2, color: color))
                else
                  Icon(AppIcons.imageBroken, size: 22, color: color),
                const SizedBox(height: 8),
                Text(
                  error ?? context.l10n.mediaImageLoading,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
                ),
                if (caption case final text? when !compact && text.trim().isNotEmpty)
                  Text(
                    text.trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
                  ),
                if (!loading && onRetry != null)
                  Tooltip(
                    message: context.l10n.mediaImageReloadHint,
                    child: TextButton(
                      style: dark ? TextButton.styleFrom(foregroundColor: Colors.white) : null,
                      onPressed: onRetry,
                      child: Text(context.l10n.mediaImageReload, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
