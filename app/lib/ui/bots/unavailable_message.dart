import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/bots_state.dart';
import '../features/feature_kit.dart';
import '../features/feature_widgets.dart';
import '../theme/app_icons.dart';
import 'install_card.dart';

/// The same connection states as the team home, for a directly opened Bot or
/// room page. Only a ready team can establish that an entity is gone.
class DsBotUnavailableMessage extends ConsumerWidget {
  const DsBotUnavailableMessage({super.key, required this.status, required this.goneIcon, required this.goneTitle});

  final DsBotStatus status;
  final IconData goneIcon;
  final String goneTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return switch (status.availability) {
      DsBotAvailability.offline => const FeatureOffline(),
      DsBotAvailability.relay => FeatureMessage(
        icon: AppIcons.disconnected,
        title: l10n.botsRelayUnavailable,
        body: l10n.botsUseSsh,
      ),
      DsBotAvailability.missing || DsBotAvailability.outdated => DsBotInstallCard(status: status),
      DsBotAvailability.failed => FeatureMessage(
        icon: AppIcons.error,
        title: l10n.botsTeamLoadFailed,
        body: status.error,
        action: (l10n.commonRetry, () => ref.read(dsBotProvider.notifier).retry()),
      ),
      DsBotAvailability.connecting => const QuietSpinner(),
      DsBotAvailability.ready => FeatureMessage(icon: goneIcon, title: goneTitle),
    };
  }
}
