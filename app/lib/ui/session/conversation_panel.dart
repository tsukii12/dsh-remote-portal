// The side panel with a conversation open: 信息 and 插件, the shortcuts at its foot.
// Everything else about a conversation is on the page behind its title.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/quick_panel_state.dart';
import '../common/segmented_pill.dart';
import '../shell/drawer/drawer_destination.dart';
import '../shell/quick_panel.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'conversation_panes.dart';
import 'session_detail_page.dart';

/// Which side is showing, and which plugin; they come back as they were left.
class ConversationPaneController extends Notifier<String> {
  @override
  String build() => ConversationPanel.info;

  void select(String section) => state = section;
}

final conversationPaneProvider = NotifierProvider<ConversationPaneController, String>(ConversationPaneController.new);

class ConversationPluginController extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String id) => state = id;
}

final conversationPluginProvider = NotifierProvider<ConversationPluginController, String?>(
  ConversationPluginController.new,
);

class ConversationPanel extends ConsumerWidget {
  const ConversationPanel({super.key, required this.sessionId, required this.onOpen});

  final String sessionId;
  final ValueChanged<DrawerDestination> onOpen;

  static const info = 'info';
  static const plugins = 'plugins';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final section = ref.watch(conversationPaneProvider);
    final destinations = ref.watch(quickPanelProvider.select((p) => p.items));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: SegmentedPill<String>(
                  segments: [PillSegment(info, l10n.shellPanelOverview), PillSegment(plugins, l10n.hubPlugins)],
                  selected: section,
                  onChanged: ref.read(conversationPaneProvider.notifier).select,
                ),
              ),
              const SizedBox(width: 4),
              _Key(
                key: const ValueKey('pane-open-full'),
                icon: AppIcons.openExternal,
                label: l10n.shellPanelOpenFull,
                onTap: () => SessionDetailPage.open(context, sessionId),
              ),
            ],
          ),
        ),
        Expanded(
          // Not the chat's scroll controller, which a tap on the status bar goes to.
          child: PrimaryScrollController.none(
            child: AnimatedSwitcher(
              duration: AppMotion.of(context, AppMotion.quick),
              child: KeyedSubtree(
                key: ValueKey('$sessionId/$section'),
                child: section == info
                    ? ConversationPane.overview.build(sessionId)
                    : _Plugins(sessionId: sessionId, onOpen: onOpen),
              ),
            ),
          ),
        ),
        if (destinations.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            // Every shortcut ticked on a narrow phone doesn't fit on one line.
            child: Wrap(
              alignment: WrapAlignment.spaceEvenly,
              children: [
                for (final destination in destinations)
                  _Key(
                    key: ValueKey('quick-panel-${destination.name}'),
                    icon: destination.icon,
                    label: destination.label(l10n),
                    onTap: () => onOpen(destination),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 插件: always there. One panel fills it, several get a row to pick from, none says so
/// and leads to where plugins come from.
class _Plugins extends ConsumerWidget {
  const _Plugins({required this.sessionId, required this.onOpen});

  final String sessionId;
  final ValueChanged<DrawerDestination> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final panes = ConversationPane.pluginsFor(ref, sessionId);
    if (panes.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(AppIcons.plugin, size: 28, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(
                l10n.shellPanelNoPlugins,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              TextButton(
                key: const ValueKey('pane-find-plugins'),
                onPressed: () => onOpen(DrawerDestination.plugins),
                child: Text(l10n.hubPlugins),
              ),
            ],
          ),
        ),
      );
    }
    final picked = ref.watch(conversationPluginProvider);
    final pane = panes.where((p) => p.id == picked).firstOrNull ?? panes.first;
    final body = KeyedSubtree(key: ValueKey('$sessionId/${pane.id}'), child: pane.build(sessionId));
    if (panes.length == 1) return body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              for (final p in panes) ...[
                _Chip(
                  key: ValueKey('pane-${p.id}'),
                  icon: p.icon,
                  label: p.label(),
                  selected: p.id == pane.id,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    ref.read(conversationPluginProvider.notifier).select(p.id);
                  },
                ),
                if (p != panes.last) const SizedBox(width: 6),
              ],
            ],
          ),
        ),
        Expanded(child: body),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({super.key, required this.icon, required this.label, required this.selected, required this.onTap});

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final content = selected ? colors.onSurface : colors.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: InkResponse(
        onTap: onTap,
        highlightShape: BoxShape.rectangle,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: AppMotion.of(context, AppMotion.quick),
          curve: AppMotion.std,
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: ShapeDecoration(
            color: colors.onSurface.withValues(alpha: selected ? 0.1 : 0.04),
            shape: const StadiumBorder(),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: content),
              const SizedBox(width: 5),
              Text(label, maxLines: 1, style: theme.textTheme.labelMedium?.copyWith(color: content)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({super.key, required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: Tooltip(
        message: label,
        child: InkResponse(
          onTap: onTap,
          radius: 22,
          child: SizedBox.square(dimension: 40, child: Icon(icon, size: 20, color: colors.onSurfaceVariant)),
        ),
      ),
    );
  }
}
