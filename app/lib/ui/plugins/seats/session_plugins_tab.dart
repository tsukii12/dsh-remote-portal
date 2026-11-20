// 对话详情 › 插件: the conversation's plugin tabs (`sidebar.right.pane.tab`,
// docs/design/plugin-seams.md §3) and its plugin views (`conversation.view`,
// docs/design/plugin-ui-v3.md §3.3). One fills the page under its name;
// several are a list, each opening a page of its own.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../plugins/native/native_state.dart';
import '../../../plugins/seams/seams.dart';
import '../../../state/plugins_state.dart';
import '../../common/app_sheet.dart' show groupTitleStyle;
import '../../common/list_page_row.dart';
import '../../theme/app_icons.dart';
import 'plugin_seat_page.dart';
import 'seat_links.dart';

/// The detail tab and its contents share one plan: the conversation's plugin
/// tabs, then its plugin views. Without conversation tabs, global panels
/// remain alongside those views; they keep their root scope even though
/// this entry lives inside a conversation.
final sessionPluginPlanProvider = Provider.autoDispose.family<SeatPlan, String>((ref, sessionId) {
  final tabs = ref.watch(seatPlanProvider(SessionPluginsTab.requestFor(sessionId)));
  final views = ref.watch(seatPlanProvider(SessionPluginsTab.viewsFor(sessionId)));
  if (!tabs.isEmpty) {
    return views.isEmpty ? tabs : SeatPlan(tabs.seat, [...tabs.items, ...views.items]);
  }
  final panels = ref.watch(seatPlanProvider(const SeatRequest(slot: Slots.main, placement: SeatPlacement.page)));
  return views.isEmpty ? panels : SeatPlan(views.seat, [...views.items, ...panels.items]);
});

class SessionPluginsTab extends ConsumerWidget {
  const SessionPluginsTab({super.key, required this.sessionId});

  final String sessionId;

  /// The seat behind the tab; 对话详情 shows the tab only while it has
  /// something to show.
  static SeatRequest requestFor(String sessionId) =>
      SeatRequest(slot: Slots.rightPaneTab, placement: SeatPlacement.page, sessionId: sessionId);

  /// The seat of the conversation's plugin views.
  static SeatRequest viewsFor(String sessionId) =>
      SeatRequest(slot: Slots.conversationView, placement: SeatPlacement.page, sessionId: sessionId);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final plan = ref.watch(sessionPluginPlanProvider(sessionId));
    final items = plan.visible;
    if (items.isEmpty) return const SizedBox.shrink();
    final bundles = ref.watch(installedPluginsProvider.select((s) => s.value));
    final inventory = ref.watch(seatInventoryProvider);

    // The tab's own title (`sidebar.right.pane.tab.title`), else the
    // occupant's name.
    String name(SlotOccupant o) => seatEntryTitle(o, inventory: inventory, bundle: seatBundleOf(bundles, o.package));

    SeatRequest pageOf(SlotOccupant o) => SeatRequest(
      slot: o.slot,
      placement: SeatPlacement.page,
      sessionId: o.slot == Slots.main ? null : plan.seat.sessionId,
      package: o.package,
      cell: o.cell,
    );

    if (items.length == 1) {
      final item = items.single;
      final o = item.occupant;
      return _SingleTab(seat: plan.seat, item: item, name: name(o));
    }

    final seat = plan.seat;
    return ListView(
      padding: EdgeInsets.fromLTRB(0, 4, 0, MediaQuery.paddingOf(context).bottom + 24),
      children: [
        ListPageCard(
          children: [
            for (final item in items)
              Builder(
                key: ValueKey('${item.occupant.slot}|${item.occupant.package}|${item.occupant.cell}'),
                builder: (context) {
                  final o = item.occupant;
                  final title = name(o);
                  final web = item.mode == SeatMode.webLink;
                  return ListPageRow(
                    icon: AppIcons.plugin,
                    title: title,
                    meta: web ? l10n.commonWeb : null,
                    chevron: true,
                    onTap: () {
                      if (web) {
                        final target = seatWebTarget(
                          o,
                          sessionId: o.slot == Slots.main ? null : seat.sessionId,
                          bundle: seatBundleOf(bundles, o.package),
                        );
                        ref.read(seatWebOpenerProvider)(context, ref, target);
                      } else {
                        Navigator.of(context).push(PluginSeatPage.route(title: title, request: pageOf(o)));
                      }
                    },
                  );
                },
              ),
          ],
        ),
      ],
    );
  }
}

/// One plugin tab filling the page under its name; when its island can't
/// come up, the way to DSH Web alone (it names the tab itself).
class _SingleTab extends ConsumerStatefulWidget {
  const _SingleTab({required this.seat, required this.item, required this.name});

  final SeatContext seat;
  final SeatItem item;
  final String name;

  @override
  ConsumerState<_SingleTab> createState() => _SingleTabState();
}

class _SingleTabState extends ConsumerState<_SingleTab> {
  /// The island that fell back.
  IslandSpec? _fallen;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    // A native panel: under the tab's name, scrolling like the page. Its
    // card is signed with the plugin's name; when that is the tab's name
    // too, the card alone says it.
    if (item.mode == SeatMode.native) {
      final signed = ref.watch(nativePluginTitleProvider(item.occupant.package));
      return ListView(
        padding: EdgeInsets.fromLTRB(0, 4, 0, MediaQuery.paddingOf(context).bottom + 24),
        children: [
          if (signed.trim() != widget.name.trim()) _TabName(widget.name),
          KeyedSubtree(
            key: ValueKey('native|${item.occupant.package}|${item.occupant.cell}'),
            child: item.adapter!.build(context, widget.seat, item.occupant),
          ),
        ],
      );
    }
    Widget web(BuildContext context) => SeatWebLink(seat: widget.seat, item: item);
    final spec = item.island;
    final island = ref.watch(seatRenderersProvider).island;
    if (item.mode != SeatMode.island || spec == null || spec == _fallen || island == null) {
      return item.mode == SeatMode.hidden ? const SizedBox.shrink() : web(context);
    }
    Widget fallback(BuildContext context) {
      if (_fallen != spec) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _fallen = spec);
        });
      }
      return web(context);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TabName(widget.name),
        Expanded(
          child: KeyedSubtree(
            key: ValueKey('island|${spec.key}'),
            child: Builder(builder: (context) => island(context, spec, [item], fallback)),
          ),
        ),
      ],
    );
  }
}

/// The tab's name over its content, on the 24 column of the page's group
/// titles.
class _TabName extends StatelessWidget {
  const _TabName(this.name);

  final String name;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
    child: Semantics(
      header: true,
      child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: groupTitleStyle(context)),
    ),
  );
}
