// 插件详情 › 网页版界面 (docs/design/plugin-ui-v3.md §3.5): where a plugin's web
// part lives that the app has no seat for, in plain words, each a way to DSH
// Web. Nothing is dropped silently: an installed plugin with a browser half
// always has at least one way to be seen.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../plugins/seams/seams.dart';
import '../../../state/sessions_state.dart';
import '../../common/list_page_row.dart';
import '../../theme/app_icons.dart';
import '../../web/web_target.dart';
import 'seat_links.dart' show seatWebOpenerProvider;

/// A place in DSH Web, in the order the section lists them.
enum WebPlace {
  besideComposer,
  header,
  messages,
  overlay,
  sidebar,
  rightbar,
  files,
  settings,
  plugins,
  newChat,
  elsewhere,

  /// The host can't say where (no occupancy table): the whole web part.
  unknown;

  String get label => switch (this) {
    besideComposer => appL10n.plugslotsPlaceBesideComposer,
    header => appL10n.plugslotsPlaceHeader,
    messages => appL10n.plugslotsPlaceMessages,
    overlay => appL10n.plugslotsPlaceOverlay,
    sidebar => appL10n.plugslotsPlaceSidebar,
    rightbar => appL10n.plugslotsPlaceRightbar,
    files => appL10n.plugslotsPlaceFiles,
    settings => appL10n.plugslotsPlaceSettings,
    plugins => appL10n.plugslotsPlacePlugins,
    newChat => appL10n.plugslotsPlaceNewChat,
    elsewhere => appL10n.plugslotsPlaceElsewhere,
    unknown => appL10n.plugslotsPlaceUnknown,
  };

  /// Where [slot] sits in DSH Web.
  static WebPlace of(String slot) {
    if (slot.startsWith('conversation.input.') || slot.startsWith('conversation.composer')) return besideComposer;
    if (slot.startsWith('conversation.session.header') || slot == 'conversation.header.leading') return header;
    if (slot.startsWith('conversation.chat.') ||
        slot == 'conversation.user.text.node' ||
        slot.startsWith('tool.call.') ||
        slot == 'conversation.plan-review.actions') {
      return messages;
    }
    if (slot.startsWith('shell.')) return overlay;
    if (slot.startsWith('sidebar.right.tab.document') || slot.startsWith('deliverables.')) return files;
    if (slot.startsWith('sidebar.right.')) return rightbar;
    if (slot.startsWith('sidebar')) return sidebar;
    if (slot.startsWith('settings')) return settings;
    if (slot.startsWith('plugins.')) return plugins;
    if (slot.startsWith('conversation.hero.')) return newChat;
    return elsewhere;
  }

  /// Where 「网页版」 lands for this place.
  DshWebTarget target({String? sessionId, List<String> pluginNames = const []}) => switch (this) {
    besideComposer || header || messages || rightbar || files => DshWebTarget(sessionId: sessionId),
    sidebar => const DshWebTarget(sidebar: true),
    settings => const DshWebTarget(settings: DshWebSettings.plugins),
    plugins => DshWebTarget(pluginItem: pluginNames),
    newChat => const DshWebTarget(newSession: true),
    overlay || elsewhere || unknown => const DshWebTarget(),
  };
}

/// The places of [package]'s web part the app can't show, in order. Empty
/// without a browser half, on a host without DSH Web, or when every place it
/// uses has a seat. Without the bridge's occupancy table (remote hosts) the
/// app can't tell where it is: one [WebPlace.unknown].
List<WebPlace> pluginWebPlaces(SeatInventory inventory, String package) {
  if (!inventory.webReachable) return const [];
  final info = inventory.infoOf(package);
  if (!info.hasClient || info.official || !info.enabled) return const [];
  final occupancy = inventory.occupancy;
  if (occupancy == null || inventory.occupancyStale) return const [WebPlace.unknown];
  final places = <WebPlace>{
    for (final MapEntry(key: slot, value: occupants) in occupancy.entries)
      if (!Slots.seated.contains(slot) && occupants.any((o) => o.package == package && !o.official)) WebPlace.of(slot),
  };
  return [
    for (final place in WebPlace.values)
      if (places.contains(place)) place,
  ];
}

/// The section in a plugin's details; nothing when there's nothing to list.
class PluginWebPlacesSection extends ConsumerWidget {
  const PluginWebPlacesSection({super.key, required this.package, this.pluginNames = const []});

  final String package;

  /// The plugin's names on DSH Web's Plugins page (its titles, its package).
  final List<String> pluginNames;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inventory = ref.watch(seatInventoryProvider);
    if (inventory == null) return const SizedBox.shrink();
    final places = pluginWebPlaces(inventory, package);
    if (places.isEmpty) return const SizedBox.shrink();
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: ListPageCard(
        key: const ValueKey('plugin-web-places'),
        title: l10n.plugslotsWebPlacesTitle,
        margin: EdgeInsets.zero,
        children: [
          for (final place in places)
            ListPageRow(
              key: ValueKey('web-place-${place.name}'),
              icon: AppIcons.webApp,
              title: place.label,
              meta: l10n.commonWeb,
              chevron: true,
              onTap: () => ref.read(seatWebOpenerProvider)(
                context,
                ref,
                place.target(sessionId: ref.read(currentSessionProvider), pluginNames: [...pluginNames, package]),
              ),
            ),
        ],
      ),
    );
  }
}
