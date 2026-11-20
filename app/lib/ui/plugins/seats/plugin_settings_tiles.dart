// 设置 › 引擎与扩展, under 「插件」: a row per settings section and general
// settings item the host's plugins add to DSH Web (`settings.section`,
// `settings.general.item`; docs/design/plugin-seams.md §3). Nothing without
// them, so the hub is unchanged.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../plugins/seams/seams.dart';
import '../../../state/plugins_state.dart';
import '../../engine_settings/engine_settings_page.dart' show openSettingsPage, namespaceTitle;
import '../../engine_settings/schema_form.dart' show SchemaUnsupportedField;
import '../../settings/settings_widgets.dart';
import '../../theme/app_icons.dart';
import 'plugin_seat_page.dart';
import 'seat_links.dart';

/// The slots the hub seats, in order.
const pluginSettingsSlots = [Slots.settingsSection, Slots.generalItem];

/// The rows, for the 「插件」 group's card; watches the seats' plans. [tint]
/// is the group's hue.
List<Widget> pluginSettingsTiles(WidgetRef ref, {int tint = 0}) => [
  for (final slot in pluginSettingsSlots)
    for (final (seat, item) in _items(ref, slot))
      PluginSettingsTile(
        key: ValueKey([slot, item.occupant.package, item.occupant.cell, ?item.configNamespace].join('|')),
        seat: seat,
        item: item,
        tint: tint,
      ),
];

Iterable<(SeatContext, SeatItem)> _items(WidgetRef ref, String slot) {
  final plan = ref.watch(seatPlanProvider(SeatRequest(slot: slot, placement: SeatPlacement.row)));
  return [for (final item in plan.visible) (plan.seat, item)];
}

/// One plugin section as a hub row: its settings form, its island page, or
/// 「网页版」 when it only opens there.
class PluginSettingsTile extends ConsumerWidget {
  const PluginSettingsTile({super.key, required this.seat, required this.item, this.tint = 0});

  final SeatContext seat;
  final SeatItem item;
  final int tint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final o = item.occupant;
    final bundle = seatBundleOf(ref.watch(installedPluginsProvider.select((s) => s.value)), o.package);
    if (item.configNamespace case final ns?) {
      final title =
          bundle?.rows.where((row) => row.rowId == ns).firstOrNull?.meta?.title?.resolve() ?? namespaceTitle(ns);
      return SchemaUnsupportedField(title: title, ns: ns);
    }
    final title = seatEntryTitle(o, inventory: ref.watch(seatInventoryProvider), bundle: bundle);
    final bool web;
    final void Function(BuildContext context) open;
    if (item.mode == SeatMode.native) {
      // One settings namespace opens the same page the plugin's detail does.
      final info = ref.watch(seatInventoryProvider)?.infoOf(o.package);
      final namespaces = item.adapter is SchemaConfigAdapter && info != null
          ? SchemaConfigAdapter.namespacesFor(o, info)
          : const <String>[];
      web = false;
      open = namespaces.length == 1
          ? (context) => unawaited(openSettingsPage(context, namespaces.single, title: title))
          : (context) => unawaited(
              Navigator.of(context).push(
                PluginSeatPage.route(
                  title: title,
                  request: SeatRequest(slot: o.slot, placement: SeatPlacement.page, package: o.package, cell: o.cell),
                ),
              ),
            );
    } else {
      final entry = seatRowEntry(ref, seat, item, title: title);
      web = entry.web;
      open = entry.open;
    }
    return SettingsTile(
      icon: AppIcons.plugin,
      tint: tint,
      title: title,
      value: web ? Text(l10n.commonWeb) : null,
      onTap: () => open(context),
    );
  }
}
