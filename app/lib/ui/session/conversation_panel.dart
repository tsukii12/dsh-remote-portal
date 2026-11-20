import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/quick_panel_state.dart';
import '../shell/drawer/drawer_destination.dart';
import '../shell/quick_panel.dart';
import '../theme/app_icons.dart';
import 'conversation_overview.dart';
import 'session_detail_page.dart';

class ConversationPanel extends ConsumerWidget {
  const ConversationPanel({super.key, required this.sessionId, required this.onOpen});
  final String sessionId;
  final ValueChanged<DrawerDestination> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final destinations = ref.watch(quickPanelProvider.select((panel) => panel.items));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: [
              Expanded(child: Text(context.l10n.shellPanelOverview, style: Theme.of(context).textTheme.titleMedium)),
              IconButton(
                icon: const Icon(AppIcons.openExternal),
                tooltip: context.l10n.shellPanelOpenFull,
                onPressed: () => SessionDetailPage.open(context, sessionId),
              ),
            ],
          ),
        ),
        Expanded(
          child: PrimaryScrollController.none(child: ConversationOverview(sessionId: sessionId)),
        ),
        if (destinations.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Wrap(
              alignment: WrapAlignment.spaceEvenly,
              children: [
                for (final destination in destinations)
                  IconButton(
                    icon: Icon(destination.icon),
                    tooltip: destination.label(context.l10n),
                    onPressed: () => onOpen(destination),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
