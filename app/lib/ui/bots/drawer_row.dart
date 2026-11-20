// The one row the sessions drawer shows for DS Bot, in place of the team's
// own Sessions (Bots' chats in all their parts, groups, members' hidden group
// Sessions), which the drawer leaves out (`dsBotOwnedSessionsProvider`).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/bots_state.dart';
import '../common/status_dot.dart';
import '../theme/theme.dart';
import 'bots_page.dart';

/// 「DS Bot · 3 个 Bot」 on the drawer's 44dp row grid, a breathing dot while a
/// Bot works, the unread count otherwise; nothing on a host without DS Bot.
class DsBotDrawerRow extends ConsumerWidget {
  const DsBotDrawerRow({super.key, this.onOpen});

  /// Defaults to pushing the Bots home; the drawer passes its own (closing
  /// itself first).
  final VoidCallback? onOpen;

  static const height = 44.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final status = ref.watch(dsBotProvider);
    final team = status.team;
    if (!status.ready || team == null) return const SizedBox.shrink();
    final unread = ref.watch(dsBotInboxProvider.select((inbox) => inbox.total));
    final working = status.live.bots.isNotEmpty;
    final theme = Theme.of(context);
    final shape = Squircle.border(AppShape.md);
    final count = l10n.botsBotCount(team.bots.length);
    final open = onOpen ?? () => Navigator.of(context).push(BotsPage.route());
    return Semantics(
      button: true,
      onTap: open,
      label: [
        'DS Bot',
        count,
        if (working) l10n.botsActivelyRunning,
        if (unread > 0) l10n.botsUnreadCount(unread),
      ].join(l10n.botsListSeparator),
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: const ValueKey('dsbot-drawer-row'),
          onTap: open,
          customBorder: shape,
          child: Ink(
            height: height,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        const TextSpan(text: 'DS Bot'),
                        TextSpan(
                          text: ' · $count',
                          style: TextStyle(color: DshColors.of(context).textTertiary),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontSize: 15,
                      height: 1.4,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                const Spacer(),
                if (unread > 0) UnreadBadge(unread) else if (working) const StatusDot(tone: StatusTone.busy, size: 7),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
