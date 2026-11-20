// What 快捷入口 lists: every destination it can, ticked or not, with a handle
// to put them in order.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/quick_panel_state.dart';
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../common/sheet_title_bar.dart';
import '../shell/drawer/drawer_destination.dart';
import '../shell/quick_panel.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

Future<void> showQuickPanelItems(BuildContext context) =>
    showAppSheet<void>(context, isScrollControlled: true, builder: (_) => const QuickPanelItemsSheet());

class QuickPanelItemsSheet extends ConsumerStatefulWidget {
  const QuickPanelItemsSheet({super.key});

  @override
  ConsumerState<QuickPanelItemsSheet> createState() => _QuickPanelItemsSheetState();
}

class _QuickPanelItemsSheetState extends ConsumerState<QuickPanelItemsSheet> {
  /// Every destination as the rows stand: what's stored first, in its order,
  /// then the rest. Only the ticked ones' order is stored.
  late final List<DrawerDestination> _rows = [
    ...ref.read(quickPanelProvider).items,
    for (final d in DrawerDestination.values)
      if (!ref.read(quickPanelProvider).items.contains(d)) d,
  ];
  late final Set<DrawerDestination> _ticked = {...ref.read(quickPanelProvider).items};

  void _save() => unawaited(ref.read(quickPanelProvider.notifier).setItems(_rows.where(_ticked.contains).toList()));

  void _toggle(DrawerDestination destination) {
    setState(() => _ticked.contains(destination) ? _ticked.remove(destination) : _ticked.add(destination));
    _save();
  }

  void _move(int from, int to) {
    setState(() {
      final moved = _rows.removeAt(from);
      _rows.insert(to.clamp(0, _rows.length), moved);
    });
    _save();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final colors = DshColors.of(context);
    Widget row(DrawerDestination destination, int index) {
      final ticked = _ticked.contains(destination);
      return Semantics(
        key: ValueKey(destination),
        checked: ticked,
        child: ListPageRow(
          leading: Icon(
            ticked ? AppIcons.checkboxOn : AppIcons.checkboxOff,
            size: 22,
            color: ticked ? scheme.primary : colors.textTertiary,
          ),
          title: destination.label(l10n),
          trailing: ReorderableDragStartListener(
            index: index,
            child: Semantics(
              label: l10n.shellDragToReorder,
              child: SizedBox.square(
                dimension: 32,
                child: Icon(AppIcons.dragHandle, size: 20, color: colors.textTertiary),
              ),
            ),
          ),
          onTap: () => _toggle(destination),
        ),
      );
    }

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(l10n.hubQuickPanelItems),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(kSheetGutter, 6, kSheetGutter, 6),
                child: GlassSurface(
                  tier: GlassTier.card,
                  borderRadius: AppShape.radiusLg,
                  child: Material(
                    type: MaterialType.transparency,
                    clipBehavior: Clip.antiAlias,
                    shape: const RoundedSuperellipseBorder(borderRadius: AppShape.radiusLg),
                    child: ReorderableListView.builder(
                      shrinkWrap: true,
                      buildDefaultDragHandles: false,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: _rows.length,
                      // The lifted row keeps its glass look, a touch raised.
                      proxyDecorator: (child, _, animation) => AnimatedBuilder(
                        animation: animation,
                        builder: (context, child) => Material(
                          color: scheme.surface.withValues(alpha: 0.92),
                          elevation: 6 * animation.value,
                          shadowColor: Colors.black26,
                          shape: Squircle.border(AppShape.md),
                          clipBehavior: Clip.antiAlias,
                          child: child,
                        ),
                        child: child,
                      ),
                      onReorderItem: _move,
                      itemBuilder: (context, i) => row(_rows[i], i),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}
