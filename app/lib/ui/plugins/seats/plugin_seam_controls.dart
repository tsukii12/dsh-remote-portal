// Opt-in overlays and reported whole-page seams in one plugin's details.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../plugins/seams/seams.dart';
import '../../../plugins/seams/seat_preferences.dart';
import '../../../state/hosts_state.dart';
import '../../../ui_config/ui_config.dart';
import '../../common/list_page_row.dart';
import '../../theme/app_icons.dart';
import 'plugin_seat_page.dart';

class PluginSeamControls extends ConsumerStatefulWidget {
  const PluginSeamControls({super.key, required this.package});

  final String package;

  @override
  ConsumerState<PluginSeamControls> createState() => _PluginSeamControlsState();
}

class _PluginSeamControlsState extends ConsumerState<PluginSeamControls> {
  bool _saving = false;

  Future<void> _setOverlay(HostRef host, bool enabled) async {
    setState(() => _saving = true);
    try {
      await ref.read(seatPreferencesProvider.notifier).setOverlay(host, widget.package, enabled);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.l10n.commonSaveFailedRetry)));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inventory = ref.watch(seatInventoryProvider);
    if (inventory == null || inventory.occupancy == null || inventory.occupancyStale) return const SizedBox.shrink();
    final info = inventory.infoOf(widget.package);
    if (!info.enabled || info.official) return const SizedBox.shrink();
    final l10n = context.l10n;
    final host = ref.watch(activeHostProvider);
    List<SlotOccupant> reported(String slot) => [
      for (final o in inventory.occupantsFor(slot, package: widget.package))
        if (!o.official && !o.inferred) o,
    ];
    final setting = UiSettingKey.seat(Slots.shellOverlay, widget.package);
    final fromUiJson = ref.watch(uiSettingEntryProvider(setting)) != null;
    final enabled = ref.watch(seatOverridesProvider).lookup(Slots.shellOverlay, widget.package) == SeatOverride.island;
    final budget = ref.watch(islandBudgetProvider);
    final overlaySeat = SeatContext(host: host, placement: SeatPlacement.overlay, webAvailable: inventory.webReachable);
    final overlayInfo = slotInfo(Slots.shellOverlay);
    final overlayPolicy = seatPolicyOf(Slots.shellOverlay);
    final overlay = reported(Slots.shellOverlay).any((o) {
      final spec = SlotAdapterRegistry.islandSpecFor(
        overlayInfo,
        overlayPolicy,
        o,
        overlaySeat,
        inventory,
        SeatOverride.island,
      );
      return spec != null && (enabled || fromUiJson || budget.canOpen(spec));
    });
    final pages = <(SlotOccupant, SeatRequest, String, IconData, bool)>[];
    for (final (slot, label, icon) in [
      (Slots.sidebarFooter, l10n.seamsSidebarPage, AppIcons.sidebar),
      (Slots.settingsPluginsTab, l10n.seamsSettingsPage, AppIcons.settings),
      (Slots.pluginDetailSection, l10n.seamsDetailPage, AppIcons.plugin),
    ]) {
      for (final o in reported(slot)) {
        final request = SeatRequest(slot: slot, placement: SeatPlacement.page, package: widget.package, cell: o.cell);
        final visible = ref.watch(seatPlanProvider(request)).visible;
        if (visible.isNotEmpty) {
          final onWeb = visible.every((i) => i.mode == SeatMode.webLink);
          pages.add((o, request, label, icon, onWeb));
        }
      }
    }
    if (!overlay && pages.isEmpty) return const SizedBox.shrink();
    final canToggle = !fromUiJson && !_saving;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: ListPageCard(
        key: const ValueKey('plugin-seam-controls'),
        title: l10n.seamsTitle,
        margin: EdgeInsets.zero,
        children: [
          if (overlay)
            MergeSemantics(
              child: ListPageRow(
                icon: AppIcons.plugin,
                title: l10n.seamsOverlay,
                subtitle: l10n.seamsOverlayNote,
                subtitleMaxLines: 2,
                badge: FromUiJsonBadge(setting),
                onTap: canToggle ? () => unawaited(_setOverlay(host, !enabled)) : null,
                trailing: Switch(
                  key: const ValueKey('plugin-overlay-switch'),
                  value: enabled,
                  onChanged: canToggle ? (value) => unawaited(_setOverlay(host, value)) : null,
                ),
              ),
            ),
          for (final (o, request, label, icon, onWeb) in pages)
            ListPageRow(
              key: ValueKey('seam-page-${o.slot}-${o.package}-${o.cell}'),
              icon: icon,
              title: o.label?.isNotEmpty == true ? o.label! : label,
              subtitle: o.label?.isNotEmpty == true ? label : null,
              meta: onWeb ? l10n.commonWeb : null,
              chevron: true,
              onTap: () => unawaited(
                Navigator.of(
                  context,
                ).push(PluginSeatPage.route(title: o.label?.isNotEmpty == true ? o.label! : label, request: request)),
              ),
            ),
        ],
      ),
    );
  }
}
