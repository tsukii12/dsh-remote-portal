// 舞台 › 本局 › 分支 (docs/design/roleplay-ui §7, engine T16): a chat's whole
// message tree as its branches. A stretch of messages with no fork is one
// row; where the story forks, the way it is going now carries on unindented
// and every other way hangs indented under the fork. The current path is
// marked. A row switches the story to that branch (its remembered path below
// comes along), takes a name, or — one the story is not on — goes, for a few
// seconds to take back.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_provider.dart';
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../features/feature_kit.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../workspace/text_prompt.dart';
import 'tavern_chat_page.dart' show tavernUndoWindow;
import 'tavern_widgets.dart' show confirmTavernDelete;

/// A stretch of the tree: [nodes], each the only child of the one before,
/// from a fork (or a root) down to the next fork or a leaf. [level] is how
/// many times it turned off the way the story is going.
class TavernBranch {
  const TavernBranch(this.nodes, this.level);

  final List<TavernTreeNode> nodes;
  final int level;

  TavernTreeNode get first => nodes.first;
  TavernTreeNode get last => nodes.last;
  bool get current => first.isCurrentPath;
}

/// [tree] as rows, in reading order: each stretch, then the ways that turn
/// off where it ends (one level in), then the way that carries on (the
/// current one if it is among them, else the first). Other openings last.
List<TavernBranch> tavernBranches(List<TavernTreeNode> tree) {
  final ids = {for (final n in tree) n.nodeId};
  final children = <String?, List<TavernTreeNode>>{};
  for (final n in tree) {
    // A parent that is not in the tree (deleted) makes this a root.
    final parent = n.parentId != null && ids.contains(n.parentId) ? n.parentId : null;
    children.putIfAbsent(parent, () => []).add(n);
  }
  for (final list in children.values) {
    list.sort((a, b) => a.siblingIndex.compareTo(b.siblingIndex));
  }
  final rows = <TavernBranch>[];
  // A worklist, not recursion: a long chat regenerated at every turn forks
  // hundreds of times down one line. Last pushed is read first.
  final pending = <(TavernTreeNode, int)>[];
  void fork(List<TavernTreeNode> ways, int level) {
    if (ways.isEmpty) return;
    final on = ways.firstWhere((n) => n.isCurrentPath, orElse: () => ways.first);
    pending.add((on, level));
    for (final n in ways.reversed) {
      if (n != on) pending.add((n, level + 1));
    }
  }

  // The other openings (an alternate greeting chosen once) come after the
  // whole story, each a row of its own.
  final roots = children[null] ?? const <TavernTreeNode>[];
  if (roots.isNotEmpty) {
    final opening = roots.firstWhere((n) => n.isCurrentPath, orElse: () => roots.first);
    for (final n in roots.reversed) {
      if (n != opening) pending.add((n, 0));
    }
    pending.add((opening, 0));
  }
  while (pending.isNotEmpty) {
    final (start, level) = pending.removeLast();
    final run = [start];
    var kids = children[start.nodeId] ?? const <TavernTreeNode>[];
    while (kids.length == 1) {
      run.add(kids.single);
      kids = children[run.last.nodeId] ?? const <TavernTreeNode>[];
    }
    rows.add(TavernBranch(run, level));
    fork(kids, level);
  }
  return rows;
}

/// Makes [node] current, with every message above it and the path it last
/// took below it.
Future<void> switchTavernBranch(Tavern tavern, String chatId, TavernTreeNode node) =>
    tavern.selectSibling(chatId, node.nodeId, node.siblingIndex);

class TavernBranchesPage extends ConsumerStatefulWidget {
  const TavernBranchesPage({super.key, required this.chatId});

  final String chatId;

  static Route<void> route(String chatId) =>
      MaterialPageRoute<void>(builder: (_) => TavernBranchesPage(chatId: chatId));

  @override
  ConsumerState<TavernBranchesPage> createState() => _TavernBranchesPageState();
}

/// What a branch's sheet was asked for.
enum _BranchAction { switchTo, name, delete }

class _TavernBranchesPageState extends ConsumerState<TavernBranchesPage> {
  List<TavernBranch>? _rows;
  List<TavernTreeNode> _tree = const [];
  StreamSubscription<void>? _changes;
  int _ticket = 0;

  Tavern get _tavern => ref.read(tavernProvider);

  @override
  void initState() {
    super.initState();
    _changes = _tavern.pathChanges(widget.chatId).listen((_) => unawaited(_load()));
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  Future<void> _load() async {
    final ticket = ++_ticket;
    final tree = await _tavern.tree(widget.chatId);
    if (!mounted || ticket != _ticket) return;
    setState(() {
      _tree = tree;
      _rows = tavernBranches(tree);
    });
  }

  Future<void> _choose(TavernBranch branch) async {
    final l10n = context.l10n;
    final named = branch.first.branchName != null;
    final action = await showAppSheet<_BranchAction>(
      context,
      builder: (sheet) => SafeArea(
        top: false,
        child: SheetGroup(
          margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          children: [
            if (!branch.current)
              SettingsTile(
                key: const ValueKey('tavern-branch-switch'),
                icon: AppIcons.fork,
                tinted: false,
                title: l10n.tavernBranchSwitch,
                subtitle: l10n.tavernBranchSwitchSubtitle,
                onTap: () => Navigator.of(sheet).pop(_BranchAction.switchTo),
              ),
            SettingsTile(
              key: const ValueKey('tavern-branch-name'),
              icon: AppIcons.rename,
              tinted: false,
              title: named ? l10n.tavernBranchRename : l10n.tavernBranchName,
              onTap: () => Navigator.of(sheet).pop(_BranchAction.name),
            ),
            // The story's own way is deleted in the chat (删除这条及以后);
            // here, only a way it is not on.
            if (!branch.current)
              SettingsTile(
                key: const ValueKey('tavern-branch-delete'),
                icon: AppIcons.delete,
                danger: true,
                tinted: false,
                title: l10n.tavernBranchDelete,
                chevron: false,
                onTap: () => Navigator.of(sheet).pop(_BranchAction.delete),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case _BranchAction.switchTo:
        await _switch(branch);
      case _BranchAction.name:
        await _name(branch);
      case _BranchAction.delete:
        await _delete(branch);
      case null:
    }
  }

  /// How many messages go with [nodeId]: it and everything below it.
  int _subtree(String nodeId) {
    final parents = {for (final n in _tree) n.nodeId: n.parentId};
    bool under(String? id) {
      for (var at = id; at != null; at = parents[at]) {
        if (at == nodeId) return true;
      }
      return false;
    }

    return _tree.where((n) => under(n.nodeId)).length;
  }

  /// Asks, then the branch and all that grew from it go; 撤销 brings them back.
  Future<void> _delete(TavernBranch branch) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final count = _subtree(branch.first.nodeId);
    final ok = await confirmTavernDelete(
      context,
      title: l10n.tavernBranchDeleteTitle,
      message: l10n.tavernBranchDeleteMessage(count),
    );
    if (!ok || !mounted) return;
    final String token;
    try {
      token = await _tavern.deleteFrom(widget.chatId, branch.first.nodeId);
    } on Object catch (e) {
      messenger?.showBriefNotice(l10n.tavernBranchFailed('$e'));
      return;
    }
    await _load();
    messenger?.showUndoNotice(
      l10n.tavernDeletedCount(count),
      undoLabel: l10n.tavernUndo,
      window: tavernUndoWindow,
      onUndo: () => unawaited(
        _tavern.undoDeleteFrom(widget.chatId, token).then((_) => mounted ? _load() : null, onError: (Object _) {}),
      ),
    );
  }

  Future<void> _switch(TavernBranch branch) async {
    final l10n = context.l10n;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await switchTavernBranch(_tavern, widget.chatId, branch.last);
    } on Object catch (e) {
      messenger?.showBriefNotice(l10n.tavernBranchFailed('$e'));
      return;
    }
    // Back to the story, now on that branch, felt as a swipe to another reply is.
    unawaited(HapticFeedback.selectionClick());
    if (mounted) navigator.pop();
    messenger?.showBriefNotice(l10n.tavernBranchSwitched);
  }

  Future<void> _name(TavernBranch branch) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final name = await showTextPrompt(
      context,
      title: l10n.tavernBranchName,
      initial: branch.first.branchName ?? '',
      hint: l10n.tavernBranchNameHint,
      caption: l10n.tavernBranchNameCaption,
      maxLength: 40,
    );
    if (name == null) return;
    try {
      await _tavern.nameBranch(widget.chatId, branch.first.nodeId, name.isEmpty ? null : name);
    } on Object catch (e) {
      messenger?.showBriefNotice(l10n.tavernBranchFailed('$e'));
      return;
    }
    // Naming does not move the path: read the tree again here.
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final rows = _rows;
    return AppPage.list(
      title: l10n.tavernBranches,
      children: [
        if (rows == null)
          const QuietSpinner()
        else if (rows.isEmpty)
          Padding(
            key: const ValueKey('tavern-branches-empty'),
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 16),
            child: Text(
              l10n.tavernBranchesEmpty,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
            ),
          )
        else
          SettingsSection(
            footer: Text(l10n.tavernBranchesNote),
            children: [
              for (final (i, row) in rows.indexed)
                _BranchRow(
                  key: ValueKey('tavern-branch-${row.first.nodeId}'),
                  branch: row,
                  onTap: () => unawaited(_choose(row)),
                  joinsAbove: i > 0,
                ),
            ],
          ),
      ],
    );
  }
}

/// A row: a rail with a dot (filled on the current path), indented by how
/// far it turned off; the branch's name or its first line; how many
/// messages and where it ends.
class _BranchRow extends StatelessWidget {
  const _BranchRow({super.key, required this.branch, required this.onTap, required this.joinsAbove});

  final TavernBranch branch;
  final VoidCallback onTap;
  final bool joinsAbove;

  /// Indents past this many levels would leave no room for the text.
  static const _maxIndent = 5;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final first = branch.first;
    final accent = theme.colorScheme.primary;
    // One line, without the *action* marks.
    String line(TavernTreeNode n) => n.preview.replaceAll('*', '').replaceAll(RegExp(r'\s+'), ' ').trim();
    final speaker = first.role == TavernRole.narrator && (first.speaker.isEmpty || first.speaker == 'System')
        ? l10n.tavernNarrator
        : first.speaker;
    final title = first.branchName ?? '$speaker：${line(first)}';
    final meta = [
      l10n.tavernBranchCount(branch.nodes.length),
      if (branch.nodes.length > 1) l10n.tavernBranchUntil(line(branch.last)),
    ].join(' · ');
    final indent = branch.level.clamp(0, _maxIndent) * 16.0;
    return InkWell(
      onTap: onTap,
      splashFactory: rowSplash(context),
      child: Padding(
        padding: EdgeInsets.fromLTRB(SettingsMetrics.inset + indent, 12, SettingsMetrics.inset, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 5, right: 12),
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: branch.current ? accent : null,
                  border: Border.all(color: branch.current ? accent : dsh.textTertiary, width: 1.5),
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: first.branchName != null ? FontWeight.w600 : null,
                          ),
                        ),
                      ),
                      if (branch.current)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Text(
                            l10n.tavernBranchCurrent,
                            style: theme.textTheme.labelSmall?.copyWith(color: accent),
                          ),
                        ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
