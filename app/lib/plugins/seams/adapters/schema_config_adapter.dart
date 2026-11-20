// `schema-config` (plugin-seams.md §4.2): a package's own settings drawn from
// its `settings/describe` schema with the engine settings form, in place of
// the web client's `settings.section` / `plugins.bundle.config` /
// `plugins.row.config` component.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/engine_settings_state.dart';
import '../../../state/plugins_state.dart';
import '../../../ui/common/list_page_row.dart';
import '../../../ui/engine_settings/engine_settings_page.dart' show namespaceTitle, openSettingsPage;
import '../../../ui/engine_settings/namespace_copy.dart';
import '../../../ui/engine_settings/schema_form.dart';
import '../../../ui/theme/app_icons.dart';
import '../seat_models.dart';
import '../seat_planner.dart';
import '../seat_state.dart';
import '../slot_catalog.dart';

class SchemaConfigAdapter implements NativeSlotAdapter {
  const SchemaConfigAdapter();

  @override
  String get id => 'schema-config';

  @override
  Set<String> get slots => const {Slots.settingsSection, Slots.bundleConfig, Slots.rowConfig};

  /// The package has a namespace the form can draw (`autoGenerate != false`).
  @override
  bool canRender(SlotOccupant o, PluginClientInfo info) => namespacesFor(o, info).isNotEmpty;

  @override
  NativeCoverage coverage(SlotOccupant o) => NativeCoverage.full;

  @override
  Widget build(BuildContext context, SeatContext seat, SlotOccupant o) =>
      SchemaConfigSeat(occupant: o, placement: seat.placement);

  /// A row's own namespace for `plugins.row.config` (`<package>#<row id>`),
  /// every drawable namespace of the package otherwise.
  static List<String> namespacesFor(SlotOccupant o, PluginClientInfo info) {
    if (o.slot != Slots.rowConfig) return info.configNamespaces;
    final row = o.cell.substring(o.cell.lastIndexOf('#') + 1);
    return info.configNamespaces.contains(row) ? [row] : const [];
  }
}

/// The settings of one occupant: a row per namespace that opens its page
/// ([SeatPlacement.row]), or the form itself.
class SchemaConfigSeat extends ConsumerWidget {
  const SchemaConfigSeat({super.key, required this.occupant, required this.placement});

  final SlotOccupant occupant;
  final SeatPlacement placement;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(seatInventoryProvider)?.infoOf(occupant.package);
    final namespaces = info == null ? const <String>[] : SchemaConfigAdapter.namespacesFor(occupant, info);
    if (namespaces.isEmpty) return const SizedBox.shrink();
    final bundle = ref.watch(
      installedPluginsProvider.select((s) => s.value?.where((b) => b.name == occupant.package).firstOrNull),
    );
    String rowTitle(String ns) =>
        bundle?.rows.where((r) => r.rowId == ns).firstOrNull?.meta?.title?.resolve() ?? namespaceTitle(ns);
    final single = namespaces.length == 1;
    final l10n = context.l10n;

    if (placement == SeatPlacement.row) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final ns in namespaces)
            ListPageRow(
              icon: AppIcons.configure,
              title: single ? l10n.commonSettings : rowTitle(ns),
              chevron: true,
              onTap: () => unawaited(
                openSettingsPage(context, ns, title: single ? (bundle?.title() ?? occupant.label) : rowTitle(ns)),
              ),
            ),
        ],
      );
    }

    final settings = ref.watch(engineSettingsProvider).value;
    if (settings == null) return const SizedBox.shrink();
    final groups = [
      for (final ns in namespaces)
        if (settings[ns] case final view?)
          ...schemaFormGroups(
            schemaSections(view, copy: namespaceCopy[ns] ?? const {}, title: single ? null : rowTitle(ns)),
            settings: settings,
          ),
    ];
    if (groups.isEmpty) return const SizedBox.shrink();
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: groups);
  }
}
