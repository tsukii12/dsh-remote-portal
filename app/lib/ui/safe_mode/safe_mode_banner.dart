import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../engine/engine_status.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'safe_mode_actions.dart';

/// Persistent strip for the chat and session list while the local engine is in safe
/// mode (not dismissible), or on its two-minute trial back in normal mode.
/// Renders nothing otherwise.
class SafeModeBanner extends ConsumerWidget {
  const SafeModeBanner({super.key, this.onRepair, this.onDetails, this.padding = EdgeInsets.zero});

  /// 「帮我修复」. Default: queue the repair prompt in [repairDraftProvider] (not sent).
  final VoidCallback? onRepair;

  /// Tapping the banner itself, e.g. to open the engine page's safe-mode card.
  final VoidCallback? onDetails;
  final EdgeInsetsGeometry padding;

  static bool visibleFor(RuntimeStatus status) {
    if (status.phase == RuntimePhase.notInstalled || status.phase == RuntimePhase.installing) {
      return false;
    }
    if (status.inSafeMode) return true;
    return status.onProbation && (status.phase == RuntimePhase.starting || status.phase == RuntimePhase.running);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final status = ref.watch(localRuntimeProvider.select((s) => s.status));
    if (!visibleFor(status)) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final safe = status.inSafeMode;
    final background = safe ? colors.warningContainer : colors.infoContainer;
    final foreground = safe ? colors.onWarningContainer : colors.onInfoContainer;
    final title = safe ? l10n.phoneSafeBannerTitle : l10n.phoneSafeBannerProbation;
    final subtitle = switch (status.phase) {
      _ when !safe => l10n.phoneSafeBannerProbationHint,
      RuntimePhase.starting => l10n.phoneEngineStartingSafeEllipsis,
      RuntimePhase.running => l10n.phoneSafeBannerRunningHint,
      RuntimePhase.stopping =>
        isLocalStartupFailure(status) ? l10n.phoneStartupFailureStopping : l10n.phoneEngineStoppingEllipsis,
      RuntimePhase.error => l10n.phoneSafeBannerFailedHint,
      _ => l10n.phoneSafeBannerStoppedHint,
    };
    final buttonStyle = TextButton.styleFrom(
      foregroundColor: foreground,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 10),
    );

    return Padding(
      padding: padding,
      child: Semantics(
        container: true,
        liveRegion: true,
        label: '$title。$subtitle',
        child: Material(
          color: background,
          shape: const RoundedRectangleBorder(borderRadius: AppShape.radiusMd),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onDetails,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 6, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Icon(safe ? AppIcons.safeMode : AppIcons.waiting, size: 20, color: foreground),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ExcludeSemantics(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title, style: theme.textTheme.titleSmall?.copyWith(color: foreground)),
                              const SizedBox(height: 2),
                              Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: foreground)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (safe)
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: Wrap(
                        spacing: 4,
                        children: [
                          if (status.phase == RuntimePhase.running)
                            TextButton(
                              style: buttonStyle,
                              onPressed: onRepair ?? () => SafeModeActions.requestRepair(context, popToRoot: false),
                              child: Text(l10n.phoneSafeRepair),
                            ),
                          if (status.phase != RuntimePhase.starting && status.phase != RuntimePhase.stopping)
                            TextButton(
                              style: buttonStyle,
                              onPressed: () => unawaited(SafeModeActions.leave(context)),
                              child: Text(l10n.phoneFailureStartNormal),
                            ),
                        ],
                      ),
                    )
                  else
                    const SizedBox(height: 4),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
