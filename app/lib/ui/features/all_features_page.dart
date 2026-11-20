// 全部功能: every official DSH Web feature with a way in — the app's own page
// or the official page inside the app — as a hub of two-column cards in the
// accent; the nine headline features carry their tile in the user's style.
// It holds what you go to do now; settings live in 设置, and the last group
// is a few shortcuts there plus 全部设置 (settings search over the hub).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/bots_state.dart';
import '../../state/sessions_state.dart';
import '../common/app_sheet.dart' show groupTitleStyle;
import '../common/feature_tile.dart';
import '../common/list_page_row.dart';
import '../common/overview_card.dart';
import '../common/tile_grid.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../web/dsh_web_launcher.dart';
import '../web/web_target.dart';
import '../plugins/seats/seat_probe.dart';
import '../settings/search/settings_search_page.dart';
import '../settings/settings_screen.dart';
import 'feature_catalog.dart';
import 'feature_widgets.dart';

/// Opens DSH Web on a target; tests swap it for a recorder.
typedef DshWebOpener = void Function(BuildContext context, WidgetRef ref, DshWebTarget target);

final dshWebOpenerProvider = Provider<DshWebOpener>(
  (ref) =>
      (context, ref, target) => openDshWeb(context, ref, target: target),
);

/// 全部设置: the settings hub, with search open over it (back lands on the
/// hub, then here).
void openAllSettings(BuildContext context) {
  final navigator = Navigator.of(context);
  unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())));
  unawaited(navigator.push(SettingsSearchPage.route()));
}

class AllFeaturesPage extends ConsumerWidget {
  const AllFeaturesPage({super.key, this.sections});

  /// Defaults to [featureSectionsProvider]: [featureSections] and the
  /// host's plugin panels.
  final List<FeatureSection>? sections;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final sessionId = ref.watch(currentSessionProvider);
    final title = sessionId == null
        ? null
        : ref.watch(sessionsProvider).value?.where((s) => s.sessionId == sessionId).firstOrNull?.projections.title;

    void openWeb(FeatureItem item) => ref.read(dshWebOpenerProvider)(context, ref, item.webFor(sessionId)!);
    void open(FeatureItem item) {
      if (item.native case final page?) {
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page(sessionId)));
      } else if (item.action case final action?) {
        unawaited(Future.sync(() => action(context, ref, sessionId)));
      } else {
        openWeb(item);
      }
    }

    final List<FeatureSection> all = sections ?? ref.watch(featureSectionsProvider);
    final page = AppPage.list(
      title: l10n.catalogAllFeatures,
      subtitle: Text(l10n.catalogAllFeaturesSubtitle),
      children: [
        _ConversationCard(sessionId: sessionId, title: (title?.trim().isNotEmpty ?? false) ? title!.trim() : null),
        for (final section in all) ...[
          FeatureGroupLabel(section.title),
          TileGrid(
            children: [
              for (final item in section.items)
                FeatureTileFor(
                  item: item,
                  enabled: !item.needsSession || sessionId != null,
                  onOpen: () => open(item),
                  onOpenWeb: item.hasNative && item.web != null ? () => openWeb(item) : null,
                ),
            ],
          ),
          if (section.id == settingsFeatureSection)
            Padding(
              // The grid's 16 gutters and 12 between cards.
              padding: const EdgeInsets.only(top: 12),
              child: ListPageCard(
                children: [
                  ListPageRow(
                    key: const ValueKey('all-settings'),
                    icon: AppIcons.search,
                    title: l10n.catalogAllSettings,
                    onTap: () => openAllSettings(context),
                  ),
                ],
              ),
            ),
          if (section.note case final note?)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
              child: Text(
                note,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
              ),
            ),
        ],
      ],
    );
    // Reads which plugins sit where when the engine hasn't said yet; outside
    // the list, so it is built at once and never part of its layout.
    return Stack(
      fit: StackFit.expand,
      children: [
        page,
        const Positioned(left: 0, top: 0, child: SeatProbe()),
      ],
    );
  }
}

/// A group title over a [TileGrid]: small and faint, on the page's 24 column
/// (with the large title and every group title), 24 above, 8 below.
class FeatureGroupLabel extends StatelessWidget {
  const FeatureGroupLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Semantics(header: true, child: Text(text, style: groupTitleStyle(context))),
    );
  }
}

/// One feature as a card: its [FeatureTile] when it has one, else its icon on
/// an accent circle; 「网页版」 in the corner for items that only live there, a
/// small globe for items that have both.
class FeatureTileFor extends ConsumerWidget {
  const FeatureTileFor({
    super.key,
    required this.item,
    this.tint,
    required this.onOpen,
    this.onOpenWeb,
    this.enabled = true,
  });

  final FeatureItem item;

  /// An identity hue for the circle instead of the accent.
  final int? tint;
  final VoidCallback onOpen;

  /// Secondary way in for items that have both.
  final VoidCallback? onOpenWeb;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final unread = item.id == 'ds-bot' ? ref.watch(dsBotInboxProvider.select((inbox) => inbox.total)) : 0;
    return FeatureCard(
      icon: item.icon,
      art: switch (item.tile) {
        final kind? => FeatureTile(kind, size: FeatureCard.glyph),
        null => null,
      },
      tint: tint,
      title: item.title,
      subtitle: enabled ? item.summary : l10n.catalogOpenChatFirst,
      enabled: enabled,
      // 「网页版」 itself needs no badge saying so.
      badge: unread > 0
          ? (unread > 99 ? '99+' : '$unread')
          : item.webOnly && item.web != const DshWebTarget()
          ? l10n.commonWeb
          : null,
      corner: onOpenWeb == null
          ? null
          : IconButton(
              tooltip: l10n.commonOpenInWeb,
              padding: EdgeInsets.zero,
              iconSize: FeatureCard.cornerIcon,
              onPressed: enabled ? onOpenWeb : null,
              icon: Icon(AppIcons.webApp, color: scheme.onSurfaceVariant),
            ),
      onTap: onOpen,
    );
  }
}

/// The hub's overview: which conversation the 「当前对话」 tiles act on; a tap
/// goes back to it.
class _ConversationCard extends ConsumerWidget {
  const _ConversationCard({required this.sessionId, this.title});

  final String? sessionId;
  final String? title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final open = sessionId != null;
    return OverviewCard(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      leading: OverviewGlyph(open ? AppIcons.chat : AppIcons.conversations, tint: open ? 0 : 7),
      title: Text(open ? (title ?? l10n.commonUntitledChat) : l10n.catalogNoOpenChat),
      subtitle: Text(open ? l10n.catalogOpenChat : l10n.catalogOpenOrCreateChat),
      onTap: open ? () => openSessionInChat(context, ref, sessionId) : null,
    );
  }
}
