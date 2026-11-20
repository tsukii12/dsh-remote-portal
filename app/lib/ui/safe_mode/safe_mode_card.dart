import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../../state/safe_mode_state.dart';
import '../common/status_chip.dart';
import '../theme/theme.dart';
import 'recovery_actions.dart';
import 'safe_mode_actions.dart';

/// Why safe mode is on, in one sentence.
String safeModeReasonText(RuntimeStatus status) {
  final culprits = status.mainFailure?.culprits ?? const <String>[];
  return switch (status.safeReason) {
    'auto' =>
      culprits.isEmpty
          ? appL10n.phoneSafeReasonStartup
          : appL10n.phoneSafeReasonPlugins(culprits.take(2).join(appL10n.phoneListSeparator)),
    'probation' => appL10n.phoneSafeReasonProbation,
    _ => appL10n.phoneSafeReasonManual,
  };
}

/// The engine page's safe-mode section: why we are here, home-level files to move
/// aside, and the ways out. Renders nothing outside safe mode.
class SafeModeCard extends ConsumerWidget {
  const SafeModeCard({super.key, this.onRepair, this.padding = EdgeInsets.zero});

  /// 「帮我修复」. Default: queue the repair prompt and go back to the chat.
  final VoidCallback? onRepair;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final status = ref.watch(localRuntimeProvider.select((s) => s.status));
    if (!status.inSafeMode || status.phase == RuntimePhase.notInstalled) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final hazards = ref.watch(safePreflightProvider).value ?? const <SafeHazard>[];
    final lkg = ref.watch(lastKnownGoodProvider).value;
    final running = status.phase == RuntimePhase.running;
    final busy = status.phase.isBusy;

    return Padding(
      padding: padding,
      child: GlassSurface(
        tier: GlassTier.card,
        borderRadius: AppShape.radiusLg,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const AnimatedStatusDot(tone: StatusTone.warn, size: 8),
                const SizedBox(width: 10),
                Expanded(child: Text(l10n.phoneSafeMode, style: theme.textTheme.titleMedium)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              safeModeReasonText(status),
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            for (final h in hazards) ...[
              const SizedBox(height: 10),
              Text(h.path, style: AppType.monoLabel(color: colors.textTertiary)),
              Text(
                h.kind == 'homePatch' ? l10n.phoneFailureGlobalPatch : l10n.phoneFailureEnvironment,
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 14),
            RecoveryActions(
              primaryLabel: l10n.phoneSafeRepair,
              onPrimary: running ? (onRepair ?? () => SafeModeActions.requestRepair(context)) : null,
              secondary: [
                (
                  label: l10n.phoneFailureStartNormal,
                  onPressed: busy ? null : () => unawaited(SafeModeActions.leave(context)),
                ),
                if (lkg != null && lkg.useful)
                  (
                    label: l10n.phoneFailureRestore,
                    onPressed: busy ? null : () => unawaited(SafeModeActions.restoreLastKnownGood(context)),
                  ),
                if (hazards.isNotEmpty)
                  (
                    label: SafeModeActions.moveAsideLabel(hazards),
                    onPressed: busy ? null : () => unawaited(SafeModeActions.moveAsideAndRetry(context, hazards)),
                  ),
              ],
              onLog: switch (status.mainFailure) {
                final failure? => () => unawaited(SafeModeActions.showFailureLog(context, summary: failure.summary)),
                null => null,
              },
            ),
          ],
        ),
      ),
    );
  }
}
