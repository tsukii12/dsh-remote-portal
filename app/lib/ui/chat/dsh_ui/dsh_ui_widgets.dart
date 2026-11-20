// The Flutter components of a dsh-ui view. The catalog names live in
// `dsh_ui_model.dart`.

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../common/pressable.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../render/markdown_body.dart';
import 'dsh_ui_blocks.dart';
import 'dsh_ui_plugin_controls.dart';
import 'dsh_ui_chart.dart';
import 'dsh_ui_model.dart';
import 'dsh_ui_plugin_styles.dart';
import 'dsh_ui_reply.dart';
import 'dsh_ui_scope.dart';
import 'dsh_ui_style.dart';

/// 一张视图：卡片外框（圆角 20）+ 标题 + 组件。回答组件的状态从
/// [DshUiScope] 读；没有 scope 时只读展示。
class DshUiCard extends StatefulWidget {
  const DshUiCard({super.key, required this.view, this.animate = false});

  final DshUiView view;

  /// 刚生成完（流式结束）时为 true：图表轻轻生长。翻历史时为 false。
  final bool animate;

  @override
  State<DshUiCard> createState() => _DshUiCardState();
}

class _DshUiCardState extends State<DshUiCard> {
  /// 正在发出的回复（点下到 `onReply` 返回之间）。
  DshUiReply? _sending;

  /// 已发出、记录里还没出现的回复：先按「已答」画。
  DshUiReply? _sent;

  Future<void> _send(DshUiReply reply) async {
    final onReply = DshUiScope.maybeOf(context)?.onReply;
    if (onReply == null || _sending != null || _sent != null) return;
    setState(() => _sending = reply);
    var ok = false;
    try {
      ok = await onReply(reply.text);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _sending = null;
      if (ok) _sent = reply;
    });
  }

  _Answering _answering(DshUiScope? scope) {
    final view = widget.view;
    final state = scope?.state;
    if (state?.interaction == DshUiInteraction.answered) {
      final answer = dshUiAnswerFor(view, state!.reply!);
      return answer == null ? const _Answering(_Mode.expired) : _Answering(_Mode.answered, answer: answer);
    }
    if (_sending case final reply?) {
      return _Answering(_Mode.sending, sending: reply);
    }
    if (_sent case final reply?) {
      final answer = dshUiAnswerFor(view, reply);
      if (answer != null) return _Answering(_Mode.answered, answer: answer);
    }
    if (state == null) return const _Answering(_Mode.readOnly);
    return switch (state.interaction) {
      DshUiInteraction.live when scope?.onReply != null => _Answering(_Mode.live, onSend: _send),
      DshUiInteraction.live => const _Answering(_Mode.readOnly),
      DshUiInteraction.running => const _Answering(_Mode.running),
      _ => const _Answering(_Mode.expired),
    };
  }

  @override
  Widget build(BuildContext context) {
    final view = widget.view;
    final theme = Theme.of(context);
    return _CardContext(
      view: view,
      animate: widget.animate,
      answering: _answering(DshUiScope.maybeOf(context)),
      child: GlassSurface(
        tier: GlassTier.card,
        borderRadius: AppShape.radiusLg,
        padding: const EdgeInsets.all(DshUiMetrics.cardPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (view.title case final title?) ...[
              Semantics(
                header: true,
                child: Text(title, style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurface)),
              ),
              const SizedBox(height: 12),
            ],
            DshUiNodeView(node: view.root),
          ],
        ),
      ),
    );
  }
}

enum _Mode { readOnly, live, running, sending, answered, expired }

/// 回答组件此刻的处境。
class _Answering {
  const _Answering(this.mode, {this.answer, this.sending, this.onSend});

  final _Mode mode;
  final DshUiAnswer? answer;
  final DshUiReply? sending;
  final void Function(DshUiReply reply)? onSend;

  bool get enabled => mode == _Mode.live && onSend != null;

  /// 控件下方的一行说明。
  String? get caption => switch (mode) {
    _Mode.running => appL10n.viewUiReplyAfterEnd,
    _Mode.expired => appL10n.viewUiExpired,
    _ => null,
  };
}

class _CardContext extends InheritedWidget {
  const _CardContext({required this.view, required this.animate, required this.answering, required super.child});

  final DshUiView view;
  final bool animate;
  final _Answering answering;

  static _CardContext? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_CardContext>();

  @override
  bool updateShouldNotify(_CardContext old) =>
      old.view != view ||
      old.animate != animate ||
      old.answering.mode != answering.mode ||
      old.answering.answer != answering.answer ||
      old.answering.sending != answering.sending ||
      old.answering.onSend != answering.onSend;
}

/// 一个节点（含它的截断说明）。
class DshUiNodeView extends StatelessWidget {
  const DshUiNodeView({super.key, required this.node, this.depth = 0});

  final DshUiNode node;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final plugin = DshUiPluginScope.maybeOf(context);
    final animate = _CardContext.of(context)?.animate ?? plugin?.animate ?? false;
    final node = this.node;
    if (DshUiPluginScope.hides(context, node)) return const SizedBox.shrink();
    final Widget base = switch (node) {
      DshUiLayout(row: false) => _StackView(node: node, depth: depth),
      DshUiLayout(row: true) => _RowView(node: node, depth: depth),
      DshUiText(restricted: true) => DshUiPlainText(node.text, muted: node.muted),
      DshUiText() => _TextView(node: node),
      DshUiMetric() => _MetricView(node: node),
      DshUiChart() => _ChartBlock(node: node, animate: animate),
      DshUiCompare() => _CompareView(node: node),
      DshUiSteps() => _StepsView(node: node),
      DshUiCallout() => _CalloutView(node: node),
      DshUiOptions() when plugin != null => DshUiPluginOptions(node: node),
      DshUiOptions() => _OptionsView(node: node),
      DshUiConfirm() when plugin != null => DshUiPluginConfirm(node: node),
      DshUiConfirm() => _ConfirmView(node: node),
      DshUiPlaceholder() => _PlaceholderView(node: node),
      DshUiList() => DshUiListBlock(node: node),
      DshUiKeyValue() => DshUiKeyValueBlock(node: node),
      DshUiProgress() => DshUiProgressBlock(node: node),
      DshUiTable() => DshUiTableBlock(node: node),
      DshUiActions() => DshUiActionsBlock(node: node),
      DshUiImage() => DshUiImageBlock(node: node),
      DshUiEmptyState() => DshUiEmptyStateBlock(node: node),
      DshUiGallery() => DshUiGalleryBlock(key: ValueKey(node.path), node: node),
      DshUiEmpty() => const DshUiEmptyBlock(),
      DshUiInput() => DshUiInputView(key: ValueKey(node.path), node: node),
      DshUiControlContainer() => DshUiControlContainerView(key: ValueKey(node.path), node: node, depth: depth),
      DshUiControlDisplay() => DshUiControlDisplayView(node: node),
    };
    final body = DshUiPluginStyles.viewOf(context) == null
        ? base
        : DshUiStyledNode(node: node, depth: depth, fallback: base);
    final note = node.truncation;
    if (note == null) return body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [body, const SizedBox(height: 8), DshUiNote(note)],
    );
  }
}

/// 一行小字说明（截断、失效）。
class DshUiNote extends StatelessWidget {
  const DshUiNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: DshColors.of(context).textTertiary, fontSize: 12),
    );
  }
}

// ───────────────────────── 布局 ─────────────────────────

class _StackView extends StatelessWidget {
  const _StackView({required this.node, required this.depth});

  final DshUiLayout node;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final gap = depth == 0 ? DshUiMetrics.gap : DshUiMetrics.rowGap;
    final children = [
      for (final child in node.children)
        if (!DshUiPluginScope.hides(context, child)) child,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          DshUiNodeView(node: children[i], depth: depth + 1),
        ],
      ],
    );
  }
}

/// 横排：按最宽的子组件算一行放几个，放不下就换行；最后一行留空位，列始终
/// 对齐（对称）。
class _RowView extends StatelessWidget {
  const _RowView({required this.node, required this.depth});

  final DshUiLayout node;
  final int depth;

  static double _minWidth(DshUiNode node) => switch (node) {
    DshUiMetric() => 96,
    DshUiChart() || DshUiTable() => 260,
    DshUiCompare() => 280,
    DshUiOptions() || DshUiConfirm() || DshUiActions() => 220,
    DshUiLayout() || DshUiList() => 200,
    DshUiProgress() => 140,
    _ => 160,
  };

  @override
  Widget build(BuildContext context) {
    final children = [
      for (final child in node.children)
        if (!DshUiPluginScope.hides(context, child)) child,
    ];
    if (children.isEmpty) return const SizedBox.shrink();
    const gap = DshUiMetrics.rowGap;
    return LayoutBuilder(
      builder: (context, box) {
        final need = children.map(_minWidth).reduce((a, b) => a > b ? a : b);
        final fit = ((box.maxWidth + gap) / (need + gap)).floor();
        final columns = fit.clamp(1, children.length);
        final lines = <Widget>[];
        for (var start = 0; start < children.length; start += columns) {
          lines.add(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var c = 0; c < columns; c++) ...[
                  if (c > 0) const SizedBox(width: gap),
                  Expanded(
                    child: start + c < children.length
                        ? DshUiNodeView(node: children[start + c], depth: depth + 1)
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < lines.length; i++) ...[if (i > 0) const SizedBox(height: DshUiMetrics.gap), lines[i]],
          ],
        );
      },
    );
  }
}

// ───────────────────────── 展示 ─────────────────────────

/// 文字里的 dsh-ui 围栏不再当视图画（防递归），按 JSON 代码显示。
String _noNestedViews(String text) =>
    text.replaceAllMapped(RegExp(r'^(\s{0,3}(?:`{3,}|~{3,}))\s*dsh-ui\b', multiLine: true), (m) => '${m.group(1)}json');

class _TextView extends StatelessWidget {
  const _TextView({required this.node});

  final DshUiText node;

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(text: _noNestedViews(node.text), selectable: false, secondary: node.muted);
  }
}

Color? _toneColor(DshColors dsh, DshUiTone? tone) => switch (tone) {
  DshUiTone.good => dsh.success,
  DshUiTone.warn => dsh.warning,
  DshUiTone.bad => dsh.danger,
  DshUiTone.info => dsh.info,
  DshUiTone.muted || null => null,
};

class _MetricView extends StatelessWidget {
  const _MetricView({required this.node});

  final DshUiMetric node;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dsh = DshColors.of(context);
    final tone = _toneColor(dsh, node.tone);
    final number = theme.textTheme.headlineMedium!.copyWith(color: tone ?? colors.onSurface);
    final unit = theme.textTheme.titleSmall!.copyWith(
      color: tone ?? colors.onSurfaceVariant,
      fontWeight: FontWeight.w400,
    );
    return Semantics(
      container: true,
      label: node.caption == null
          ? context.l10n.viewMetricSemantics(node.label, node.value)
          : context.l10n.viewMetricCaptionSemantics(node.label, node.value, node.caption!),
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (tone != null) ...[
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    node.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text.rich(dshUiNumberSpan(node.value, number: number, unit: unit), maxLines: 1),
            ),
            if (node.caption case final caption?) ...[
              const SizedBox(height: 4),
              Text(
                caption,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ChartBlock extends StatelessWidget {
  const _ChartBlock({required this.node, required this.animate});

  final DshUiChart node;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DshUiChartView(chart: node, animate: animate),
        if (node.caption case final caption?) ...[
          const SizedBox(height: 12),
          Text(
            caption,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
          ),
        ],
      ],
    );
  }
}

/// 对比卡：两项并排、四项 2×2，三项或放不下时竖排。并排时同一行的名称在
/// 各列对齐。
class _CompareView extends StatelessWidget {
  const _CompareView({required this.node});

  final DshUiCompare node;

  static const _minColumn = 140.0;
  static const _gap = DshUiMetrics.rowGap;

  @override
  Widget build(BuildContext context) {
    final items = node.items;
    return LayoutBuilder(
      builder: (context, box) {
        final fit = ((box.maxWidth + _gap) / (_minColumn + _gap)).floor();
        final int columns;
        if (items.length == 1) {
          columns = 1;
        } else if (items.length <= fit) {
          columns = items.length;
        } else if (items.length == 4 && fit >= 2) {
          columns = 2;
        } else {
          columns = 1;
        }
        if (columns == 1) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) const SizedBox(height: _gap),
                _CompareWell(
                  highlighted: items[i].badge != null,
                  child: _CompareStacked(item: items[i]),
                ),
              ],
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var start = 0; start < items.length; start += columns) ...[
              if (start > 0) const SizedBox(height: _gap),
              _CompareGrid(items: items.sublist(start, start + columns)),
            ],
          ],
        );
      },
    );
  }
}

class _CompareWell extends StatelessWidget {
  const _CompareWell({required this.highlighted, required this.child});

  final bool highlighted;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final well = context.dshUiWell;
    final styled = DshUiPluginStyles.viewOf(context) != null;
    final color = highlighted && !styled
        ? Color.alphaBlend(Theme.of(context).colorScheme.primary.withValues(alpha: 0.08), well)
        : well;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: color,
        shape: Squircle.border(
          DshUiMetrics.wellRadius,
          side: styled && highlighted ? BorderSide(color: Theme.of(context).colorScheme.primary) : BorderSide.none,
        ),
      ),
      child: child,
    );
  }
}

class _CompareHeader extends StatelessWidget {
  const _CompareHeader({required this.item});

  final DshUiCompareItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          child: Text(
            item.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onSurface),
          ),
        ),
        if (item.badge case final badge?) ...[const SizedBox(width: 8), DshUiBadge(badge)],
      ],
    );
  }
}

/// 小标签（圆角 8）：强调色的容器底，不是实心主色。
class DshUiBadge extends StatelessWidget {
  const DshUiBadge(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: ShapeDecoration(color: colors.primaryContainer, shape: Squircle.border(DshUiMetrics.tagRadius)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          text,
          maxLines: 1,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: colors.onPrimaryContainer, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

TextSpan _valueSpan(BuildContext context, String value, {double size = 15}) {
  final theme = Theme.of(context);
  return dshUiNumberSpan(
    value,
    number: theme.textTheme.titleSmall!.copyWith(fontSize: size, color: theme.colorScheme.onSurface),
    unit: theme.textTheme.bodySmall!.copyWith(color: theme.colorScheme.onSurfaceVariant),
  );
}

/// 竖排的一项：标题，下面每行「名称 …… 值」。
class _CompareStacked extends StatelessWidget {
  const _CompareStacked({required this.item});

  final DshUiCompareItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CompareHeader(item: item),
          for (final (name, value) in item.rows) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: Text(name, style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary)),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text.rich(_valueSpan(context, value, size: 14), textAlign: TextAlign.right)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 并排的一行项：用 [Table] 让同一行的名称和值跨列对齐，底下按列铺井。
class _CompareGrid extends StatelessWidget {
  const _CompareGrid({required this.items});

  final List<DshUiCompareItem> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    const gap = _CompareView._gap;
    final rows = items.fold<int>(0, (m, i) => i.rows.length > m ? i.rows.length : m);
    final widths = <int, TableColumnWidth>{
      for (var c = 0; c < items.length * 2 - 1; c++) c: c.isOdd ? const FixedColumnWidth(gap) : const FlexColumnWidth(),
    };

    TableRow line(Widget Function(DshUiCompareItem item) cell) => TableRow(
      children: [
        for (var c = 0; c < items.length; c++) ...[if (c > 0) const SizedBox.shrink(), cell(items[c])],
      ],
    );

    return Stack(
      children: [
        Positioned.fill(
          child: Row(
            children: [
              for (var c = 0; c < items.length; c++) ...[
                if (c > 0) const SizedBox(width: gap),
                Expanded(
                  child: _CompareWell(highlighted: items[c].badge != null, child: const SizedBox.expand()),
                ),
              ],
            ],
          ),
        ),
        Table(
          columnWidths: widths,
          defaultVerticalAlignment: TableCellVerticalAlignment.top,
          children: [
            line(
              (item) => Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: _CompareHeader(item: item),
              ),
            ),
            for (var r = 0; r < rows; r++)
              line((item) {
                if (r >= item.rows.length) return const SizedBox.shrink();
                final (name, value) = item.rows[r];
                return Padding(
                  padding: EdgeInsets.fromLTRB(12, 8, 12, r == rows - 1 ? 12 : 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary)),
                      const SizedBox(height: 2),
                      Text.rich(_valueSpan(context, value)),
                    ],
                  ),
                );
              }),
            if (rows == 0) line((_) => const SizedBox(height: 8)),
          ],
        ),
      ],
    );
  }
}

class _StepsView extends StatelessWidget {
  const _StepsView({required this.node});

  final DshUiSteps node;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dsh = DshColors.of(context);
    final body = theme.textTheme.bodyMedium!;
    final line = (body.fontSize ?? 14) * (body.height ?? 1.55);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < node.items.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          Semantics(
            label: context.l10n.viewLabeledValue(_statusName(node.items[i].status), node.items[i].label),
            child: ExcludeSemantics(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 20,
                    height: line,
                    child: Center(child: _StepGlyph(node.items[i].status)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          node.items[i].label,
                          style: body.copyWith(
                            color: node.items[i].status == DshUiStepStatus.done
                                ? colors.onSurfaceVariant
                                : colors.onSurface,
                            fontWeight: node.items[i].status == DshUiStepStatus.current
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                        if (node.items[i].detail case final detail?)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              detail,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: node.items[i].status == DshUiStepStatus.failed ? dsh.danger : dsh.textTertiary,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  static String _statusName(DshUiStepStatus status) => switch (status) {
    DshUiStepStatus.done => appL10n.commonCompleted,
    DshUiStepStatus.current => appL10n.commonInProgress,
    DshUiStepStatus.todo => appL10n.viewUiNotStarted,
    DshUiStepStatus.failed => appL10n.commonFailed,
  };
}

class _StepGlyph extends StatelessWidget {
  const _StepGlyph(this.status);

  final DshUiStepStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dsh = DshColors.of(context);
    return switch (status) {
      DshUiStepStatus.done => Icon(AppIcons.success, size: 18, color: dsh.success),
      DshUiStepStatus.failed => Icon(AppIcons.stepFailed, size: 18, color: dsh.danger),
      DshUiStepStatus.current => Container(
        width: 16,
        height: 16,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: dsh.info, width: 2),
        ),
        child: Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: dsh.info, shape: BoxShape.circle),
        ),
      ),
      DshUiStepStatus.todo => Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: colors.outline, width: 1.5),
        ),
      ),
    };
  }
}

class _CalloutView extends StatelessWidget {
  const _CalloutView({required this.node});

  final DshUiCallout node;

  @override
  Widget build(BuildContext context) {
    final dsh = DshColors.of(context);
    final (fill, fg, icon) = switch (node.tone) {
      DshUiCalloutTone.info => (dsh.infoContainer, dsh.info, AppIcons.info),
      DshUiCalloutTone.good => (dsh.successContainer, dsh.success, AppIcons.completed),
      DshUiCalloutTone.warn => (dsh.warningContainer, dsh.warning, AppIcons.warning),
      DshUiCalloutTone.bad => (dsh.dangerContainer, dsh.danger, AppIcons.error),
    };
    final body = Theme.of(context).textTheme.bodyMedium!;
    final line = (body.fontSize ?? 14) * 0.9 * (body.height ?? 1.55);
    return DecoratedBox(
      decoration: ShapeDecoration(color: fill.withValues(alpha: 0.7), shape: Squircle.border(DshUiMetrics.wellRadius)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: line + 4,
              child: Center(child: Icon(icon, size: 18, color: fg)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: node.restricted
                  ? DshUiPlainText(node.text, muted: true)
                  : MarkdownBody(text: _noNestedViews(node.text), selectable: false, secondary: true),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaceholderView extends StatelessWidget {
  const _PlaceholderView({required this.node});

  final DshUiPlaceholder node;

  static String _message(L10n l10n, String? type) => switch (type) {
    'chart' => l10n.viewUiUnavailableChart,
    'metric' => l10n.viewUiUnavailableMetric,
    'compare' => l10n.viewUiUnavailableCompare,
    'steps' => l10n.viewUiUnavailableSteps,
    'callout' => l10n.viewUiUnavailableCallout,
    'options' => l10n.viewUiUnavailableOptions,
    'confirm' => l10n.viewUiUnavailableConfirm,
    'text' => l10n.viewUiUnavailableText,
    'stack' || 'row' => l10n.viewUiUnavailableGroup,
    'list' => l10n.plugViewUnavailableList,
    'keyValue' => l10n.plugViewUnavailableKeyValue,
    'progress' => l10n.plugViewUnavailableProgress,
    'table' => l10n.plugViewUnavailableTable,
    'actions' => l10n.plugViewUnavailableActions,
    'image' => l10n.plugViewImageUnavailable,
    _ => l10n.viewUiUnavailablePart,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final dsh = DshColors.of(context);
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: dsh.textTertiary);
    return DecoratedBox(
      decoration: ShapeDecoration(color: context.dshUiWell, shape: Squircle.border(DshUiMetrics.wellRadius)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            Icon(AppIcons.cannotDisplay, size: 16, color: dsh.textTertiary),
            const SizedBox(width: 8),
            Expanded(child: Text(_message(l10n, node.type), style: style)),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── 回答组件 ─────────────────────────

class _OptionsView extends StatefulWidget {
  const _OptionsView({required this.node});

  final DshUiOptions node;

  @override
  State<_OptionsView> createState() => _OptionsViewState();
}

class _OptionsViewState extends State<_OptionsView> {
  final _picked = <String>{};
  final _free = TextEditingController();

  @override
  void dispose() {
    _free.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final card = _CardContext.of(context);
    final answering = card?.answering ?? const _Answering(_Mode.readOnly);
    final node = widget.node;
    final title = card?.view.title;
    final answer = answering.answer?.nodePath == node.path ? answering.answer : null;
    final answered = answer?.selected.toSet() ?? const <String>{};
    final answeredFree = answer?.freetext;
    final sendingReply = answering.sending?.kind == DshUiReplyKind.choice ? answering.sending : null;
    final sending = sendingReply?.selectedIn(node.labels).toSet() ?? const <String>{};
    final enabled = answering.enabled;
    final dsh = DshColors.of(context);
    final free = node.freetext;

    void send(List<String> labels, {String? freetext}) =>
        answering.onSend?.call(DshUiReply.choice(labels, title: title, freetext: freetext));

    List<String> chosen() => [
      for (final o in node.options)
        if (_picked.contains(o.label)) o.label,
    ];
    String typed() => _free.text.trim();
    // 点了选项或填了字才能发；单选 + 自己填也走这个按钮。
    final canSend = enabled && (_picked.isNotEmpty || typed().isNotEmpty);
    final showSend = (node.multi || free) &&
        answering.mode != _Mode.answered &&
        answering.mode != _Mode.expired &&
        answering.mode != _Mode.readOnly;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (node.multi && answering.mode != _Mode.answered)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(l10n.viewUiMultiple, style: AppType.eyebrow(color: dsh.textTertiary)),
          ),
        for (var i = 0; i < node.options.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          DshUiOptionRow(
            option: node.options[i],
            multi: node.multi,
            selected:
                answered.contains(node.options[i].label) ||
                ((node.multi || free) && _picked.contains(node.options[i].label)) ||
                sending.contains(node.options[i].label),
            answered: answered.contains(node.options[i].label),
            settled: answering.mode == _Mode.answered,
            busy: !node.multi && sending.contains(node.options[i].label),
            enabled: enabled,
            onTap: () {
              final label = node.options[i].label;
              // 单选且不能自己填：点了就是答案。
              if (!node.multi && !free) {
                send([label]);
                return;
              }
              setState(() {
                if (node.multi) {
                  _picked.contains(label) ? _picked.remove(label) : _picked.add(label);
                  return;
                }
                // 单选 + 自己填：点一下选中，再点一下取消。
                if (_picked.contains(label)) {
                  _picked.clear();
                } else {
                  _picked
                    ..clear()
                    ..add(label);
                }
              });
            },
          ),
        ],
        if (free && answering.mode != _Mode.answered) ...[
          const SizedBox(height: 8),
          _FreeTextField(
            controller: _free,
            enabled: enabled,
            hint: node.freetextHint ?? l10n.viewUiFreeTextHint,
            onChanged: () => setState(() {}),
            onSubmitted: canSend ? () => send(chosen(), freetext: typed()) : null,
          ),
        ],
        // 已答：自己填的那句跟在选项下面，和用户气泡上的标签对得上。
        if (answering.mode == _Mode.answered && answeredFree != null && answeredFree.isNotEmpty) ...[
          const SizedBox(height: 8),
          DshUiNote(l10n.viewUiReplyOther(answeredFree)),
        ],
        if (showSend) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: _SendButton(
              busy: answering.mode == _Mode.sending,
              onPressed: canSend ? () => send(chosen(), freetext: typed()) : null,
            ),
          ),
        ],
        if (answering.caption case final caption?) ...[const SizedBox(height: 8), DshUiNote(caption)],
      ],
    );
  }
}

/// options 的「其他（自己填）」：和选项同一套圆角、留白和底色。
class _FreeTextField extends StatelessWidget {
  const _FreeTextField({
    required this.controller,
    required this.enabled,
    required this.hint,
    required this.onChanged,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final bool enabled;
  final String hint;
  final VoidCallback onChanged;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    // 用 App 自己的输入框样式（圆角描边、聚焦换主色），和别的输入框一致。
    return TextField(
      key: const ValueKey('dsh-ui-freetext'),
      controller: controller,
      enabled: enabled,
      readOnly: !enabled,
      minLines: 1,
      maxLines: 3,
      textInputAction: TextInputAction.send,
      onChanged: (_) => onChanged(),
      onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
      style: theme.textTheme.bodyMedium?.copyWith(color: colors.onSurface),
      cursorColor: colors.primary,
      decoration: InputDecoration(hintText: hint),
    );
  }
}

class DshUiOptionRow extends StatelessWidget {
  const DshUiOptionRow({
    super.key,
    required this.option,
    required this.multi,
    required this.selected,
    required this.answered,
    required this.settled,
    required this.busy,
    required this.enabled,
    required this.onTap,
  });

  final DshUiOption option;
  final bool multi;

  /// 打勾（多选里点过的、正在发出的、已答的）。
  final bool selected;

  /// 已答且被选中：强调色容器底。
  final bool answered;

  /// 视图已答：没被选的项淡下去。
  final bool settled;

  /// 正在发出这一项（单选）。
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dsh = DshColors.of(context);
    final faded = (settled && !answered) || (!enabled && !answered && !selected && !busy);
    final fg = answered
        ? colors.onPrimaryContainer
        : faded
        ? colors.onSurfaceVariant
        : colors.onSurface;
    final fill = answered ? colors.primaryContainer : context.dshUiWell;
    final icon = selected
        ? (multi ? AppIcons.checkboxOn : AppIcons.radioOn)
        : (multi ? AppIcons.checkboxOff : AppIcons.radioOff);
    final duration = AppMotion.of(context, AppMotion.quick);
    final description = option.description;
    final styled = DshUiPluginStyles.viewOf(context) != null;
    return Semantics(
      button: enabled,
      selected: selected,
      enabled: enabled,
      child: Pressable(
        enabled: enabled,
        child: AnimatedOpacity(
          opacity: faded && !styled ? 0.6 : 1,
          duration: duration,
          child: Material(
            color: Colors.transparent,
            child: Ink(
              decoration: ShapeDecoration(color: fill, shape: Squircle.border(DshUiMetrics.wellRadius)),
              child: dshUiPluginInkWell(
                context,
                customBorder: Squircle.border(DshUiMetrics.wellRadius),
                onTap: enabled ? onTap : null,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: DshUiMetrics.control),
                  child: Padding(
                    padding: styled
                        ? const EdgeInsets.all(12)
                        : const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        SizedBox.square(
                          dimension: 20,
                          child: busy
                              ? Padding(
                                  padding: const EdgeInsets.all(2),
                                  child: CircularProgressIndicator(strokeWidth: 2, color: colors.primary),
                                )
                              : AnimatedSwitcher(
                                  duration: duration,
                                  child: Icon(
                                    icon,
                                    key: ValueKey(icon),
                                    size: 20,
                                    color: selected
                                        ? colors.primary
                                        : (faded ? dsh.textDisabled : colors.onSurfaceVariant),
                                  ),
                                ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                option.label,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: fg,
                                  fontWeight: answered ? FontWeight.w600 : FontWeight.w400,
                                ),
                              ),
                              if (description != null && description.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    description,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: answered ? colors.onPrimaryContainer : dsh.textTertiary,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 多选的「发送」：视图里唯一的实心主色。
class _SendButton extends StatelessWidget {
  const _SendButton({required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    return Pressable(
      enabled: onPressed != null && !busy,
      child: FilledButton(
        onPressed: busy ? null : onPressed,
        style: FilledButton.styleFrom(
          minimumSize: const Size(88, 40),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          shape: const StadiumBorder(),
        ),
        child: busy
            ? SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: colors.onSurfaceVariant),
              )
            : Text(l10n.commonSend),
      ),
    );
  }
}

class _ConfirmView extends StatelessWidget {
  const _ConfirmView({required this.node});

  final DshUiConfirm node;

  @override
  Widget build(BuildContext context) {
    final card = _CardContext.of(context);
    final answering = card?.answering ?? const _Answering(_Mode.readOnly);
    final title = card?.view.title;
    final answer = answering.answer?.nodePath == node.path ? answering.answer : null;
    final sending = answering.sending;
    final sendingConfirm = sending?.kind == DshUiReplyKind.confirm;
    final sendingCancel = sending?.kind == DshUiReplyKind.cancel;
    final enabled = answering.enabled;

    void send(bool confirmed) => answering.onSend?.call(
      DshUiReply.confirm(confirmed, label: confirmed ? node.confirmText : node.cancelText, title: title),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: DshUiConfirmButton(
                label: node.cancelText,
                primary: false,
                chosen: answer?.confirmed == false,
                settled: answer != null || answering.mode == _Mode.expired,
                busy: sendingCancel,
                enabled: enabled,
                onTap: () => send(false),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DshUiConfirmButton(
                label: node.confirmText,
                primary: true,
                chosen: answer?.confirmed == true,
                settled: answer != null || answering.mode == _Mode.expired,
                busy: sendingConfirm,
                enabled: enabled,
                onTap: () => send(true),
              ),
            ),
          ],
        ),
        if (answering.caption case final caption?) ...[const SizedBox(height: 8), DshUiNote(caption)],
      ],
    );
  }
}

class DshUiConfirmButton extends StatelessWidget {
  const DshUiConfirmButton({
    super.key,
    required this.label,
    required this.primary,
    required this.chosen,
    required this.settled,
    required this.busy,
    required this.enabled,
    required this.onTap,
  });

  final String label;

  /// 确认键：实心主色（可点时）。
  final bool primary;

  /// 已答且选的是这个。
  final bool chosen;

  /// 已答或已失效：不再是按钮的样子。
  final bool settled;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dsh = DshColors.of(context);
    final solid = primary && !settled && !chosen;
    final Color fill;
    final Color fg;
    if (chosen) {
      fill = colors.primaryContainer;
      fg = colors.onPrimaryContainer;
    } else if (solid) {
      fill = enabled || busy ? colors.primary : colors.primary.withValues(alpha: 0.4);
      fg = colors.onPrimary;
    } else {
      fill = context.dshUiWell;
      fg = settled || !enabled ? dsh.textTertiary : colors.onSurface;
    }
    final duration = AppMotion.of(context, AppMotion.quick);
    return Semantics(
      button: true,
      enabled: enabled,
      selected: chosen,
      child: Pressable(
        enabled: enabled,
        child: Material(
          color: Colors.transparent,
          child: Ink(
            decoration: ShapeDecoration(color: fill, shape: const StadiumBorder()),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: enabled ? onTap : null,
              child: SizedBox(
                height: 44,
                child: Center(
                  child: AnimatedSwitcher(
                    duration: duration,
                    child: busy
                        ? SizedBox.square(
                            key: const ValueKey('busy'),
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                          )
                        : Row(
                            key: ValueKey(chosen),
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (chosen) ...[Icon(AppIcons.selected, size: 18, color: fg), const SizedBox(width: 6)],
                              Flexible(
                                child: Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelLarge?.copyWith(color: fg),
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
