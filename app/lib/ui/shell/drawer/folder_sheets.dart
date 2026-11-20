// The drawer's sheets for folders and the list's
// options — 对话列表 (sort, new folder, manage, multi-select), the folder
// editor (name and mark), 移到文件夹, a folder's actions and 管理文件夹
// (drag to reorder).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/drawer_view_state.dart';
import '../../common/app_sheet.dart';
import '../../common/list_page_row.dart';
import '../../common/segmented_pill.dart';
import '../../common/sheet_title_bar.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import 'folder_mark.dart';

const _groupMargin = EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12);

// ── 对话列表 ─────────────────────────────────────────────────────────────────

enum DrawerViewAction { newFolder, manageFolders, select, archived }

/// Sort (applies at once), then 新建文件夹 / 管理文件夹 / 多选.
Future<DrawerViewAction?> showDrawerViewSheet(BuildContext context) =>
    showAppSheet<DrawerViewAction>(context, builder: (_) => const DrawerViewSheet());

class DrawerViewSheet extends ConsumerWidget {
  const DrawerViewSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final sort = ref.watch(drawerViewProvider.select((v) => v.sort));
    final hasFolders = ref.watch(drawerViewProvider.select((v) => v.folders.isNotEmpty));
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitleBar(l10n.shellChatList),
          Padding(
            padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 8, 0, SheetTitleBar.inset, 8),
            child: Semantics(header: true, child: Text(l10n.shellSort, style: groupTitleStyle(context))),
          ),
          Padding(
            padding: _groupMargin.copyWith(bottom: 16),
            child: SegmentedPill<DrawerSort>(
              segments: [
                PillSegment(DrawerSort.activity, l10n.shellRecentActivity),
                PillSegment(DrawerSort.created, l10n.shellCreatedTime),
              ],
              selected: sort,
              onChanged: (value) => ref.read(drawerViewProvider.notifier).setSort(value),
            ),
          ),
          SheetGroup(
            margin: _groupMargin,
            children: [
              ListPageRow(
                icon: AppIcons.newFolder,
                title: l10n.shellNewFolder,
                chevron: false,
                onTap: () => Navigator.of(context).pop(DrawerViewAction.newFolder),
              ),
              if (hasFolders)
                ListPageRow(
                  icon: AppIcons.manageFolders,
                  title: l10n.shellManageFolders,
                  onTap: () => Navigator.of(context).pop(DrawerViewAction.manageFolders),
                ),
              ListPageRow(
                icon: AppIcons.archive,
                title: l10n.shellArchived,
                onTap: () => Navigator.of(context).pop(DrawerViewAction.archived),
              ),
              ListPageRow(
                icon: AppIcons.multiSelect,
                title: l10n.shellMultiSelect,
                chevron: false,
                onTap: () => Navigator.of(context).pop(DrawerViewAction.select),
              ),
            ],
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

// ── Folder editor ────────────────────────────────────────────────────────────

/// What the editor returns.
typedef FolderDraft = ({String name, int? tint, String? emoji});

/// 新建文件夹 / 编辑文件夹: a name and a mark (plain, a hue or an emoji).
/// [takenNames] can't be reused.
Future<FolderDraft?> showFolderEditor(
  BuildContext context, {
  DrawerFolder? initial,
  Iterable<String> takenNames = const [],
}) => showAppSheet<FolderDraft>(
  context,
  dismissal: SheetDismissal.button,
  isScrollControlled: true,
  builder: (_) => FolderEditorSheet(initial: initial, takenNames: takenNames.toSet()),
);

class FolderEditorSheet extends StatefulWidget {
  const FolderEditorSheet({super.key, this.initial, this.takenNames = const {}});

  final DrawerFolder? initial;
  final Set<String> takenNames;

  @override
  State<FolderEditorSheet> createState() => _FolderEditorSheetState();
}

class _FolderEditorSheetState extends State<FolderEditorSheet> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late int? _tint = widget.initial?.tint;
  late String? _emoji = widget.initial?.emoji;
  String? _problem;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    if (name != widget.initial?.name && widget.takenNames.contains(name)) {
      setState(() => _problem = context.l10n.shellFolderNameExists);
      return;
    }
    Navigator.of(context).pop<FolderDraft>((name: name, tint: _emoji == null ? _tint : null, emoji: _emoji));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final editing = widget.initial != null;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(editing ? l10n.shellEditFolder : l10n.shellNewFolder),
            SheetGroup(
              margin: _groupMargin,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: _name,
                    autofocus: !editing,
                    maxLength: DrawerViewController.maxName,
                    textInputAction: TextInputAction.done,
                    style: theme.textTheme.bodyLarge?.copyWith(fontSize: 15),
                    decoration: InputDecoration(
                      hintText: l10n.commonName,
                      counterText: '',
                      errorText: _problem,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                      filled: false,
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onChanged: (_) => setState(() => _problem = null),
                    onSubmitted: (_) => _submit(),
                  ),
                ),
              ],
            ),
            SheetGroup(
              title: l10n.shellFolderMark,
              margin: _groupMargin,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Column(
                    children: [
                      _MarkRow(
                        children: [
                          _MarkKey(
                            label: l10n.commonDefault,
                            selected: _tint == null && _emoji == null,
                            onTap: () => setState(() {
                              _tint = null;
                              _emoji = null;
                            }),
                            child: const FolderMarkGlyph(),
                          ),
                          for (var i = 0; i < DrawerFolder.markTints; i++)
                            _MarkKey(
                              label: l10n.shellFolderColor(i + 1),
                              selected: _emoji == null && _tint == i,
                              onTap: () => setState(() {
                                _tint = i;
                                _emoji = null;
                              }),
                              child: FolderMarkGlyph(tint: i),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      _MarkRow(
                        children: [
                          for (final e in folderEmoji)
                            _MarkKey(
                              label: e,
                              selected: _emoji == e,
                              onTap: () => setState(() => _emoji = e),
                              child: FolderMarkGlyph(emoji: e),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 4, SheetTitleBar.inset, 12),
              child: ListenableBuilder(
                listenable: _name,
                builder: (context, _) => FilledButton(
                  onPressed: _name.text.trim().isEmpty ? null : _submit,
                  child: Text(editing ? l10n.commonSave : l10n.commonCreate),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Nine equal columns, so both rows line up and the ends mirror each other.
class _MarkRow extends StatelessWidget {
  const _MarkRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Row(
    children: [for (final child in children) Expanded(child: Center(child: child))],
  );
}

/// A 36 round key; the chosen one gets a soft fill and an ink ring.
class _MarkKey extends StatelessWidget {
  const _MarkKey({required this.label, required this.selected, required this.onTap, required this.child});

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  static const size = 36.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: AnimatedContainer(
            duration: AppMotion.of(context, AppMotion.quick),
            curve: AppMotion.std,
            width: size,
            height: size,
            decoration: ShapeDecoration(
              color: selected ? scheme.onSurface.withValues(alpha: 0.08) : scheme.onSurface.withValues(alpha: 0),
              shape: CircleBorder(
                side: BorderSide(
                  color: selected ? scheme.onSurface : scheme.onSurface.withValues(alpha: 0),
                  width: 1.5,
                ),
              ),
            ),
            alignment: Alignment.center,
            child: child,
          ),
        ),
      ),
    );
  }
}

// ── 移到文件夹 ───────────────────────────────────────────────────────────────

/// Where 移到文件夹 sends the conversations.
sealed class FolderPick {
  const FolderPick();
}

final class PickFolder extends FolderPick {
  const PickFolder(this.folderId);

  final String folderId;
}

final class PickNewFolder extends FolderPick {
  const PickNewFolder();
}

final class PickNoFolder extends FolderPick {
  const PickNoFolder();
}

/// The folders (a check on [currentFolder], where every chosen conversation
/// already is), then 新建文件夹 and, when any is filed, 移出文件夹.
Future<FolderPick?> showMoveToFolderSheet(
  BuildContext context, {
  required List<DrawerFolder> folders,
  required Map<String, int> counts,
  String? currentFolder,
  bool anyFiled = false,
  String? title,
  bool allowCreate = true,
}) => showAppSheet<FolderPick>(
  context,
  isScrollControlled: true,
  builder: (sheet) {
    final scheme = Theme.of(sheet).colorScheme;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.8),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitleBar(title ?? context.l10n.shellMoveToFolder),
              if (folders.isNotEmpty)
                SheetGroup(
                  margin: _groupMargin,
                  children: [
                    for (final f in folders)
                      ListPageRow(
                        leading: FolderMarkGlyph.of(f),
                        title: f.name,
                        meta: (counts[f.id] ?? 0) == 0 ? null : '${counts[f.id]}',
                        trailing: f.id == currentFolder
                            ? Icon(AppIcons.selected, size: 20, color: scheme.primary)
                            : const SizedBox(width: 20),
                        onTap: () => Navigator.of(sheet).pop(PickFolder(f.id)),
                      ),
                  ],
                ),
              if (allowCreate || anyFiled)
                SheetGroup(
                  margin: _groupMargin,
                  children: [
                    if (allowCreate)
                      ListPageRow(
                        icon: AppIcons.newFolder,
                        title: context.l10n.shellNewFolder,
                        chevron: false,
                        onTap: () => Navigator.of(sheet).pop(const PickNewFolder()),
                      ),
                    if (anyFiled)
                      ListPageRow(
                        icon: AppIcons.noFolder,
                        title: context.l10n.shellMoveOutOfFolder,
                        chevron: false,
                        onTap: () => Navigator.of(sheet).pop(const PickNoFolder()),
                      ),
                  ],
                ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  },
);

// ── A folder's actions ───────────────────────────────────────────────────────

enum FolderAction { newChat, edit, delete }

Future<FolderAction?> showFolderActionSheet(BuildContext context, DrawerFolder folder) => showAppSheet<FolderAction>(
  context,
  builder: (sheet) => SafeArea(
    top: false,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetTitleBar(folder.name),
        SheetGroup(
          margin: _groupMargin,
          children: [
            ListPageRow(
              icon: AppIcons.newChat,
              title: context.l10n.commonNewChat,
              chevron: false,
              onTap: () => Navigator.of(sheet).pop(FolderAction.newChat),
            ),
            ListPageRow(
              icon: AppIcons.edit,
              title: context.l10n.commonEdit,
              chevron: false,
              onTap: () => Navigator.of(sheet).pop(FolderAction.edit),
            ),
            ListPageRow(
              icon: AppIcons.delete,
              title: context.l10n.shellDeleteFolder,
              danger: true,
              chevron: false,
              onTap: () => Navigator.of(sheet).pop(FolderAction.delete),
            ),
          ],
        ),
        const SizedBox(height: 4),
      ],
    ),
  ),
);

// ── 管理文件夹 ───────────────────────────────────────────────────────────────

/// The folders in order; drag the handle to reorder, tap one to edit it.
Future<void> showManageFolders(BuildContext context, {required void Function(DrawerFolder folder) onEdit}) =>
    showAppSheet<void>(context, isScrollControlled: true, builder: (_) => ManageFoldersSheet(onEdit: onEdit));

class ManageFoldersSheet extends ConsumerWidget {
  const ManageFoldersSheet({super.key, required this.onEdit});

  final void Function(DrawerFolder folder) onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final folders = ref.watch(drawerViewProvider.select((v) => v.folders));
    final scheme = Theme.of(context).colorScheme;
    final colors = DshColors.of(context);
    Widget row(DrawerFolder f, int index) => ListPageRow(
      key: ValueKey(f.id),
      leading: FolderMarkGlyph.of(f),
      title: f.name,
      trailing: ReorderableDragStartListener(
        index: index,
        child: Semantics(
          label: l10n.shellDragToReorder,
          child: SizedBox.square(dimension: 32, child: Icon(AppIcons.dragHandle, size: 20, color: colors.textTertiary)),
        ),
      ),
      onTap: () => onEdit(f),
    );
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(l10n.shellManageFolders),
            Flexible(
              child: Padding(
                padding: _groupMargin,
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
                      itemCount: folders.length,
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
                      onReorderItem: (from, to) => ref.read(drawerViewProvider.notifier).reorderFolders(from, to),
                      itemBuilder: (context, i) => row(folders[i], i),
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
