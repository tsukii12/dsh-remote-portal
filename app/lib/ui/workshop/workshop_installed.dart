// 「已安装」: what on this phone came from the workshop, read from the local
// records. The public catalogue only adds to a row (an update, a withdrawal);
// it never decides whether a row is listed, so the list stays as it is
// offline, with no workshop configured, and after an item is taken down
// (docs/design/workshop-app.md).
//
// 卸载 is confirmed in the row's sheet, then handed to
// workshopInstalledProvider with the row's own object. How it went is read
// from the controller's removal state, never from the call's return value.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/workshop_catalog_state.dart';
import '../../state/workshop_installed_state.dart';
import '../../workshop/workshop_models.dart';
import '../../workshop/workshop_repository.dart';
import '../common/brief_notice.dart';
import '../common/empty_view.dart';
import '../common/fade_in.dart';
import '../common/list_page_row.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'workshop_installed_sheet.dart';
import 'workshop_item_sheet.dart';
import 'workshop_text.dart';
import 'workshop_widgets.dart';

/// The slivers of the 已安装 tab. [onBrowse] is offered when nothing is
/// installed: it takes the person to 发现.
class WorkshopInstalledSliver extends ConsumerStatefulWidget {
  const WorkshopInstalledSliver({super.key, this.onBrowse});

  final VoidCallback? onBrowse;

  @override
  ConsumerState<WorkshopInstalledSliver> createState() => _WorkshopInstalledSliverState();
}

class _WorkshopInstalledSliverState extends ConsumerState<WorkshopInstalledSliver> {
  Future<void> _open(WorkshopInstalledRow row) async {
    final choice = await showWorkshopInstalledSheet(context, row);
    if (!mounted) return;
    switch (choice) {
      case WorkshopInstalledUpdate(:final entry):
        _update(entry);
      case WorkshopInstalledUninstall(:final local):
        unawaited(_uninstall(local));
      case null:
        break;
    }
  }

  /// Updating is installing: it happens in the item's own sheet, which shows
  /// the progress and asks before replacing anything.
  void _update(WorkshopEntry entry) {
    final item = ref.read(workshopItemProvider(entry.metadata.identity));
    if (item == null) {
      // The catalogue moved on between the row and the tap.
      showBriefNotice(context, context.l10n.workshopErrorCatalogChanged);
      return;
    }
    unawaited(showWorkshopItemSheet(context, item));
  }

  Future<void> _uninstall(WorkshopLocalEntry local) async {
    final accepted = await ref.read(workshopInstalledProvider.notifier).uninstall(local);
    // Accepted says nothing about how it went: _onRemoval reports that.
    if (!mounted || accepted) return;
    showBriefNotice(context, context.l10n.workshopInstallBusy);
  }

  void _onRemoval(WorkshopRemovalState? before, WorkshopRemovalState now) {
    if (before?.phase != WorkshopRemovalPhase.removing) return;
    final l10n = context.l10n;
    switch (now.phase) {
      case WorkshopRemovalPhase.succeeded:
        // The files are gone either way. A list that could not be read again
        // keeps its own error (loadError); the removal's refreshError may
        // also be about the pet on screen, which a pull here does not mend.
        final listOld = ref.read(workshopInstalledProvider).loadError != null;
        showBriefNotice(
          context,
          listOld
              ? l10n.workshopInstalledRemovedRefreshIssue
              : now.refreshError != null
              ? l10n.workshopInstalledRemovedLocalIssue
              : l10n.workshopInstalledStatusRemoved,
        );
      case WorkshopRemovalPhase.failed:
        // The row keeps saying so, and its sheet says why.
        showBriefNotice(context, l10n.workshopInstalledStatusRemoveFailed);
      default:
        break;
    }
  }

  void _reload() => unawaited(ref.read(workshopInstalledProvider.notifier).refresh());

  /// Asks the catalogue again, then has the rows take what it brought. The
  /// second read also covers a problem that was local all along.
  Future<void> _recheck() async {
    await ref.read(workshopCatalogProvider.notifier).refresh();
    if (!mounted) return;
    await ref.read(workshopInstalledProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    ref.listen(workshopInstalledProvider.select((s) => s.removal), _onRemoval);
    final state = ref.watch(workshopInstalledProvider);
    final checking = ref.watch(workshopCatalogProvider.select((s) => s.refreshing));
    final rows = state.rows;

    if (rows.isEmpty) {
      // Nothing read yet: one quiet ring.
      if (state.loading) {
        return const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: 64),
            child: Center(child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))),
          ),
        );
      }
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: 40),
          child: switch (state.loadError) {
            // The local read failed and there is nothing older to show.
            final code? => EmptyView(
              icon: AppIcons.failed,
              title: l10n.workshopInstalledLoadFailedTitle,
              message: workshopErrorLine(l10n, code),
              actionLabel: l10n.commonRetry,
              onAction: state.refreshing ? null : _reload,
            ),
            null => EmptyView(
              icon: AppIcons.workshop,
              title: l10n.workshopInstalledEmptyTitle,
              message: l10n.workshopInstalledEmptyMessage,
              actionLabel: widget.onBrowse == null ? null : l10n.workshopInstalledEmptyAction,
              onAction: widget.onBrowse,
            ),
          },
        ),
      );
    }

    return SliverMainAxisGroup(
      slivers: [
        if (state.loadError != null)
          SliverToBoxAdapter(
            child: WorkshopNote(
              l10n.workshopInstalledLoadStale,
              tone: WorkshopNoteTone.warning,
              actionLabel: l10n.commonRetry,
              onAction: state.refreshing ? null : _reload,
            ),
          ),
        // The catalogue's half is missing or old. Why is not said: it may be
        // the network, the workshop, or this phone's own records.
        if (state.catalogError != null || state.catalogStale == true)
          SliverToBoxAdapter(
            child: WorkshopNote(
              rows.any((row) => row.remoteKnown)
                  ? l10n.workshopInstalledCatalogStale
                  : l10n.workshopInstalledCatalogUnknown,
              actionLabel: state.catalogError == 'workshop_unconfigured' ? null : l10n.commonRetry,
              onAction: state.refreshing || checking ? null : () => unawaited(_recheck()),
            ),
          ),
        SliverList.builder(
          itemCount: rows.length,
          itemBuilder: (context, i) {
            final first = i == 0;
            final last = i == rows.length - 1;
            final row = rows[i];
            return FadeSlideIn(
              index: i,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Material(
                  color: DshSurfaces.of(context).card.fill,
                  clipBehavior: Clip.antiAlias,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.vertical(
                      top: first ? AppShape.radiusLg.topLeft : Radius.zero,
                      bottom: last ? AppShape.radiusLg.bottomLeft : Radius.zero,
                    ),
                  ),
                  child: Padding(
                    padding: EdgeInsets.only(top: first ? 4 : 0, bottom: last ? 4 : 0),
                    child: WorkshopInstalledTile(
                      key: ValueKey(row.local.localId),
                      row: row,
                      removal: workshopInstalledRemovalOf(row, state.removal),
                      onOpen: () => unawaited(_open(row)),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// What the end of a row draws.
enum _Mark { none, update, attention, failed, removing }

/// One installed row: square · title · one line of status · a mark when the
/// row wants attention.
class WorkshopInstalledTile extends StatelessWidget {
  const WorkshopInstalledTile({super.key, required this.row, required this.removal, this.onOpen});

  final WorkshopInstalledRow row;

  /// The last uninstall as far as it concerns this row
  /// ([workshopInstalledRemovalOf]).
  final WorkshopRemovalPhase removal;
  final VoidCallback? onOpen;

  /// The status line and its mark. One thing at a time, the most pressing
  /// first: the uninstall under way, a local problem, a withdrawal, where it
  /// stands in the workshop, an update. What the catalogue has not said
  /// (null) is left unsaid.
  (String, _Mark) _status(L10n l10n) {
    switch (removal) {
      case WorkshopRemovalPhase.removing:
        return (l10n.workshopInstalledStatusRemoving, _Mark.removing);
      case WorkshopRemovalPhase.succeeded:
        return (l10n.workshopInstalledStatusRemoved, _Mark.none);
      case WorkshopRemovalPhase.failed:
        return (l10n.workshopInstalledStatusRemoveFailed, _Mark.failed);
      case WorkshopRemovalPhase.idle:
        break;
    }
    final local = row.local;
    final issue = row.localIssue;
    if (local is! WorkshopInstalled) {
      return (workshopInstalledIssueLine(l10n, issue ?? ''), _Mark.attention);
    }
    final version = local.receipt.version;
    String after(String status) => '$version · $status';
    if (issue != null) return (after(workshopInstalledIssueLine(l10n, issue)), _Mark.attention);
    if (row.installedWithdrawn == true) return (after(l10n.workshopInstalledStatusWithdrawn), _Mark.attention);
    switch (row.remoteUnavailable) {
      case 'workshop_other_origin':
        return (after(l10n.workshopInstalledStatusOtherOrigin), _Mark.none);
      case 'workshop_not_found':
        return (after(l10n.workshopInstalledStatusNotListed), _Mark.none);
      case 'workshop_companion_disabled':
        return (after(l10n.workshopInstalledStatusCompanionOff), _Mark.none);
      case 'workshop_version_rewritten':
        return (after(l10n.workshopInstalledStatusRewritten), _Mark.attention);
    }
    if (row.updateAvailable == true) return (after(l10n.workshopInstalledStatusUpdate), _Mark.update);
    return ('${workshopKindText(l10n, local.receipt.kind)} · $version', _Mark.none);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final colors = DshColors.of(context);
    final (status, mark) = _status(l10n);
    // A row being removed, or already removed, has nothing to open.
    final settled = removal != WorkshopRemovalPhase.removing && removal != WorkshopRemovalPhase.succeeded;
    return ListPageRow(
      leading: WorkshopInstalledAvatar(row),
      leadingWidth: 40,
      title: workshopInstalledTitle(row, Localizations.localeOf(context).languageCode),
      subtitle: status,
      subtitleColor: mark == _Mark.failed ? colors.danger : null,
      trailing: switch (mark) {
        _Mark.none => null,
        _Mark.update => SizedBox.square(
          dimension: 8,
          child: DecoratedBox(
            decoration: ShapeDecoration(color: scheme.primary, shape: const CircleBorder()),
          ),
        ),
        _Mark.attention => Icon(AppIcons.warning, size: 18, color: colors.warning),
        _Mark.failed => Icon(AppIcons.warning, size: 18, color: colors.danger),
        _Mark.removing => const SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(strokeWidth: 1.8, strokeCap: StrokeCap.round),
        ),
      },
      chevron: settled,
      onTap: settled ? onOpen : null,
    );
  }
}
