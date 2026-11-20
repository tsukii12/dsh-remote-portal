// The todo bar above the composer (DSH's `conversation.input.dock#todo`): a
// slim bar while the session has a todo list, expanding in place into the
// whole checklist.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/l10n.dart';
import '../../common/expand_reveal.dart';
import '../../common/scroll_edge_fade.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import 'dock_pill.dart';

/// What the todo bar says about a list; null from [of] when the bar hides.
@immutable
class TodoDockSummary {
  const TodoDockSummary._(this.todos, this.running);

  /// The bar shows while the session has a todo list, as the official
  /// TodoDock does: the `todos` projection keeps a finished list after its
  /// turn ends and clears it when the next turn starts.
  static TodoDockSummary? of(List<TodoItem>? todos, {required bool running}) {
    if (todos == null || todos.isEmpty) return null;
    return TodoDockSummary._(List.unmodifiable(todos), running);
  }

  final List<TodoItem> todos;
  final bool running;

  int get total => todos.length;
  int get done => todos.where((t) => t.status == _completed).length;
  bool get allDone => done == total;
  double get fraction => total == 0 ? 0 : done / total;

  /// The item being worked on; the first pending one when none is.
  TodoItem? get current =>
      todos.where((t) => t.status == _inProgress).firstOrNull ?? todos.where((t) => t.status != _completed).firstOrNull;

  /// 「3/7」.
  String get count => '$done/$total';

  /// 「正在：跑测试」 while the turn runs, 「下一步：…」 once it stopped
  /// short, 「全部完成」.
  String get label {
    if (allDone) return appL10n.chatTodoAllDone;
    final item = current!;
    final now = running && item.status == _inProgress;
    return now ? appL10n.chatTodoCurrent(item.content) : appL10n.chatTodoNext(item.content);
  }

  @override
  bool operator ==(Object other) =>
      other is TodoDockSummary && other.running == running && listEquals(_key, other._key);

  @override
  int get hashCode => Object.hash(running, Object.hashAll(_key));

  List<String> get _key => [for (final t in todos) '${t.status}\u0000${t.content}'];
}

const _completed = 'completed';
const _inProgress = 'in_progress';

/// 「☑ 3/7 · 正在：跑测试 ▰▰▱ ˄」;点一下在原地展开整张清单(完成的淡、进行
/// 中的加粗,和对话详情「进度」页一个样),再点收起。清单最多占屏幕三成高,
/// 多了在卡片里滚动,展开时先滚到正在做的那一项。
class TodoBar extends StatefulWidget {
  const TodoBar({super.key, required this.summary, this.initiallyOpen = false});

  final TodoDockSummary summary;
  final bool initiallyOpen;

  /// How tall the open list may get: at most this share of the screen.
  static const maxListShare = 0.3;
  static const maxList = 196.0;

  @override
  State<TodoBar> createState() => _TodoBarState();
}

class _TodoBarState extends State<TodoBar> {
  late bool _open = widget.initiallyOpen;
  final _currentRow = GlobalKey();

  void _toggle() {
    HapticFeedback.selectionClick();
    setState(() => _open = !_open);
    if (_open) {
      // Bring the item being worked on into view once the list is laid out.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final row = _currentRow.currentContext;
        if (row != null && row.mounted) {
          Scrollable.ensureVisible(row, alignment: 0.5);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dsh = DshColors.of(context);
    final s = widget.summary;
    final header = Semantics(
      button: true,
      expanded: _open,
      label: l10n.chatTodoSemantics(s.count, s.label),
      onTapHint: _open ? l10n.chatCollapseTodos : l10n.chatExpandTodos,
      excludeSemantics: true,
      child: InkWell(
        onTap: _toggle,
        customBorder: const RoundedSuperellipseBorder(borderRadius: DockMetrics.shape),
        child: DockRow(
          leading: DockGlyph.icon(AppIcons.todo, color: colors.onSurfaceVariant),
          content: _Line(summary: s),
          accessory: DockProgressLine(fraction: s.fraction),
          trailing: DockGlyph(
            child: AnimatedRotation(
              turns: _open ? 0.5 : 0,
              duration: AppMotion.of(context, AppMotion.standard),
              curve: AppMotion.std,
              child: Icon(AppIcons.collapse, size: DockGlyph.iconSize, color: dsh.textTertiary),
            ),
          ),
        ),
      ),
    );
    final maxList = (MediaQuery.sizeOf(context).height * TodoBar.maxListShare).clamp(0.0, TodoBar.maxList);
    final current = s.current;
    return GlassSurface(
      tier: GlassTier.chrome,
      borderRadius: DockMetrics.shape,
      grouped: true,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            ExpandReveal(
              open: _open,
              duration: AppMotion.standard,
              curve: AppMotion.std,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxList),
                child: ScrollEdgeFade(
                  // Every row is built (lists are short): the current one
                  // can be scrolled to however far down it is.
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(DockMetrics.edge, 0, DockMetrics.edge, DockMetrics.edge),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final todo in s.todos)
                          TodoDockRow(key: identical(todo, current) ? _currentRow : null, todo: todo),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「3/7 · 正在：跑测试」,换项时交叉淡变。
class _Line extends StatelessWidget {
  const _Line({required this.summary});

  final TodoDockSummary summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final text = '${s.count}\u0000${s.label}';
    return AnimatedSwitcher(
      duration: AppMotion.of(context, AppMotion.quick),
      layoutBuilder: (current, previous) => Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
      child: Text.rich(
        key: ValueKey(text),
        TextSpan(
          children: [
            TextSpan(text: s.count, style: AppType.tabular(DockText.title(context))),
            TextSpan(text: ' · ${s.label}', style: DockText.detail(context)),
          ],
        ),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// 清单里的一项:图形格和标题行的图形格对齐,正文和标题的字对齐。
class TodoDockRow extends StatelessWidget {
  const TodoDockRow({super.key, required this.todo});

  final TodoItem todo;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dsh = DshColors.of(context);
    final (IconData icon, Color color, String state) = switch (todo.status) {
      _completed => (AppIcons.success, dsh.success, l10n.commonCompleted),
      _inProgress => (AppIcons.inProgress, colors.primary, l10n.commonInProgress),
      _ => (AppIcons.pending, dsh.textTertiary, l10n.chatTodoNotStarted),
    };
    final style = theme.textTheme.bodyMedium!.copyWith(
      color: todo.status == _completed ? dsh.textTertiary : colors.onSurface,
      fontWeight: todo.status == _inProgress ? FontWeight.w600 : null,
    );
    final line = MediaQuery.textScalerOf(context).scale(style.fontSize ?? 14) * (style.height ?? 1.4);
    return Semantics(
      label: l10n.chatTodoItemSemantics(todo.content, state),
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: DockMetrics.glyph,
              // One text line tall: the glyph sits on the first line.
              height: line,
              child: Center(child: Icon(icon, size: 16, color: color)),
            ),
            const SizedBox(width: DockMetrics.glyphGap),
            Expanded(
              child: Text(todo.content, style: style, maxLines: 3, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }
}
