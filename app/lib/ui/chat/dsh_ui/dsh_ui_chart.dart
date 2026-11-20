// SPDX-FileCopyrightText: 2026 Fei2411 and the DS Bot contributors
// SPDX-License-Identifier: Apache-2.0
// See THIRD_PARTY_NOTICES.md.
// Modified: ticks and axes of `widget-chart.js` translated to Dart and drawn
// with CustomPainter; touch instead of hover; horizontal bars and a donut added.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../theme/theme.dart';
import 'dsh_ui_model.dart';
import 'dsh_ui_plugin_styles.dart';
import 'dsh_ui_style.dart';

/// 约四段的整齐刻度（1、2、2.5、5 × 10ⁿ），覆盖 [low]..[high]。
/// 非有限数、零跨度、极端量级都不会死循环或抛异常。
List<double> dshUiNiceTicks(double low, double high) {
  if (!low.isFinite || !high.isFinite) return const [0, 1];
  var lo = low;
  var hi = high;
  if (lo == hi) {
    lo = math.min(0, lo);
    hi = hi == 0 ? 1 : math.max(0, hi);
  }
  if (lo == hi) hi = lo + 1;
  if (lo > hi) (lo, hi) = (hi, lo);
  final raw = (hi - lo) / 4;
  if (!raw.isFinite || raw <= 0) return [lo, hi];
  final magnitude = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  if (!magnitude.isFinite || magnitude <= 0) return [lo, hi];
  var step = 10 * magnitude;
  for (final scale in const [1.0, 2.0, 2.5, 5.0, 10.0]) {
    if (scale * magnitude >= raw * (1 - 1e-12)) {
      step = scale * magnitude;
      break;
    }
  }
  final start = (lo / step + 1e-9).floorToDouble() * step;
  final end = (hi / step - 1e-9).ceilToDouble() * step;
  if (!start.isFinite || !end.isFinite) return [lo, hi];
  final ticks = <double>[];
  for (var i = 0; i < 24; i++) {
    final value = start + step * i;
    if (value > end + step / 2) break;
    ticks.add(double.parse(value.toStringAsPrecision(12)));
  }
  return ticks.length < 2 ? [lo, hi] : ticks;
}

/// 数值轴：柱状图从 0 起；折线图上下各留 10%。
List<double> dshUiValueAxis(Iterable<double> values, {required bool zero}) {
  final finite = values.where((v) => v.isFinite).toList();
  if (finite.isEmpty) return dshUiNiceTicks(0, 1);
  final low = finite.reduce(math.min);
  final high = finite.reduce(math.max);
  if (zero) return dshUiNiceTicks(math.min(0, low), math.max(0, high));
  var pad = (high - low) * 0.1;
  if (pad == 0 || !pad.isFinite) pad = high.abs() * 0.1;
  if (pad == 0 || !pad.isFinite) pad = 1;
  return dshUiNiceTicks(low - pad, high + pad);
}

/// 「3,800 元」「38%」。
String dshUiWithUnit(double? value, String? unit) {
  if (value == null) return '—';
  final n = formatDshUiNumber(value);
  if (unit == null || unit.isEmpty) return n;
  return unit == '%' ? '$n%' : '$n $unit';
}

/// `chart` 组件。
class DshUiChartView extends StatefulWidget {
  const DshUiChartView({super.key, required this.chart, this.animate = false});

  final DshUiChart chart;

  /// 首次绘制时轻轻生长（只给刚生成完的视图；翻历史时直接到位）。
  final bool animate;

  @override
  State<DshUiChartView> createState() => _DshUiChartViewState();
}

class _DshUiChartViewState extends State<DshUiChartView> with SingleTickerProviderStateMixin {
  late final AnimationController _grow = AnimationController(
    vsync: this,
    duration: AppMotion.collapse,
    value: widget.animate ? 0 : 1,
  );
  late final Animation<double> _t = CurvedAnimation(parent: _grow, curve: AppMotion.enter);
  int? _active;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_grow.value >= 1 || _grow.isAnimating) return;
    if (AppMotion.reduced(context)) {
      _grow.value = 1;
    } else {
      _grow.forward();
    }
  }

  @override
  void didUpdateWidget(DshUiChartView old) {
    super.didUpdateWidget(old);
    if (old.chart != widget.chart) _active = null;
  }

  @override
  void dispose() {
    _grow.dispose();
    super.dispose();
  }

  void _select(int? index) {
    if (index == _active) return;
    setState(() => _active = index);
  }

  void _toggle(int? index) => setState(() {
    _active = index == null || index == _active ? null : index;
  });

  @override
  Widget build(BuildContext context) {
    final chart = widget.chart;
    final body = switch (chart.kind) {
      DshUiChartKind.bar || DshUiChartKind.line => _xy(context),
      DshUiChartKind.hbar => _hbar(context),
      DshUiChartKind.donut => _donut(context),
    };
    return Semantics(
      label: _semantics(chart),
      container: true,
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_header(context) case final header?) ...[header, const SizedBox(height: 12)],
            body,
          ],
        ),
      ),
    );
  }

  /// 图例（≥ 2 组）+ 单位。环形图的图例在图旁边。
  Widget? _header(BuildContext context) {
    final chart = widget.chart;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final palette = DshUiPalette.of(context);
    final legend = chart.kind != DshUiChartKind.donut && chart.series.length > 1;
    // 环形图和单组横向柱状图的每个数都带着单位，不再单独写一行。
    final unitWithValues =
        chart.kind == DshUiChartKind.donut || (chart.kind == DshUiChartKind.hbar && chart.series.length == 1);
    final unit = unitWithValues ? null : chart.unit;
    if (!legend && (unit == null || unit.isEmpty)) return null;
    final label = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontSize: 12);
    final unitText = unit == null || unit.isEmpty
        ? null
        : Text(context.l10n.viewChartUnit(unit), style: label?.copyWith(color: dsh.textTertiary));
    if (!legend) return Align(alignment: Alignment.centerLeft, child: unitText);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              for (var i = 0; i < chart.series.length; i++)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Key(color: palette[i % palette.length], line: chart.kind == DshUiChartKind.line),
                    const SizedBox(width: 6),
                    Text(chart.series[i].name ?? context.l10n.viewChartSeries(i + 1), style: label),
                  ],
                ),
            ],
          ),
        ),
        if (unitText != null) ...[const SizedBox(width: 12), unitText],
      ],
    );
  }

  _Styles _styles(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final small = theme.textTheme.labelSmall!.copyWith(fontSize: 11);
    return _Styles(
      tick: AppType.tabular(small.copyWith(color: dsh.textTertiary)),
      category: small.copyWith(color: dsh.textTertiary),
      value: AppType.tabular(small.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      label: theme.textTheme.bodySmall!.copyWith(color: theme.colorScheme.onSurface),
      grid: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
      baseline: theme.colorScheme.outlineVariant,
      guide: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.35),
      surface: context.dshUiCardSurface,
      palette: DshUiPalette.of(context),
      scaler: MediaQuery.textScalerOf(context),
      fadeUnselected: DshUiPluginStyles.viewOf(context) == null,
    );
  }

  // ── 柱状 / 折线 ────────────────────────────────────────

  Widget _xy(BuildContext context) {
    final styles = _styles(context);
    return SizedBox(
      height: DshUiMetrics.chartHeight,
      child: LayoutBuilder(
        builder: (context, box) {
          final geo = _XYGeometry(widget.chart, box.biggest, styles);
          int? hit(Offset p) => geo.indexAt(p.dx);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _toggle(hit(d.localPosition)),
            onHorizontalDragStart: (d) => _select(hit(d.localPosition)),
            onHorizontalDragUpdate: (d) => _select(hit(d.localPosition)),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: RepaintBoundary(child: CustomPaint(painter: _XYPainter(geo, styles, _active, _t))),
                ),
                if (_active case final index?)
                  _tooltip(
                    context,
                    anchor: geo.x(index),
                    below: 0,
                    above: 0,
                    avoid: geo.topAt(index),
                    width: box.maxWidth,
                    index: index,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ── 横向柱状 ──────────────────────────────────────────

  Widget _hbar(BuildContext context) {
    final styles = _styles(context);
    final chart = widget.chart;
    final rowHeight = math.max(DshUiMetrics.hbarRow, chart.series.length * 10.0 + 14);
    return SizedBox(
      height: rowHeight * chart.categories.length,
      child: LayoutBuilder(
        builder: (context, box) {
          final geo = _HBarGeometry(chart, box.biggest, rowHeight, styles);
          int? hit(Offset p) => (p.dy / rowHeight).floor().clamp(0, chart.categories.length - 1);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _toggle(hit(d.localPosition)),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: RepaintBoundary(child: CustomPaint(painter: _HBarPainter(geo, styles, _active, _t))),
                ),
                if (_active case final index?)
                  _tooltip(
                    context,
                    anchor: geo.barLeft + geo.barWidth / 2,
                    below: (index + 1) * rowHeight,
                    above: index * rowHeight,
                    width: box.maxWidth,
                    index: index,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ── 环形 ──────────────────────────────────────────────

  Widget _donut(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final styles = _styles(context);
    final slices = _DonutSlices.of(widget.chart, styles.palette, DshUiPalette.other(context));
    final total = slices.total;
    final active = _active == null || _active! >= slices.items.length ? null : slices.items[_active!];
    final unit = widget.chart.unit;

    final center = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedSwitcher(
          duration: AppMotion.of(context, AppMotion.quick),
          child: FittedBox(
            key: ValueKey(_active),
            fit: BoxFit.scaleDown,
            child: Text.rich(
              dshUiNumberSpan(
                active == null ? dshUiWithUnit(total, unit) : dshUiWithUnit(active.value, unit),
                number: theme.textTheme.titleMedium!.copyWith(color: theme.colorScheme.onSurface),
                unit: theme.textTheme.labelSmall!.copyWith(color: theme.colorScheme.onSurfaceVariant, fontSize: 11),
              ),
              maxLines: 1,
              textAlign: TextAlign.center,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          active == null ? context.l10n.viewChartTotal : active.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall?.copyWith(color: dsh.textTertiary),
        ),
      ],
    );

    final ring = SizedBox.square(
      dimension: DshUiMetrics.donut,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => _toggle(slices.indexAt(d.localPosition, const Size.square(DshUiMetrics.donut))),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: RepaintBoundary(child: CustomPaint(painter: _DonutPainter(slices, styles, _active, _t))),
            ),
            SizedBox(width: DshUiMetrics.donut - 56, child: center),
          ],
        ),
      ),
    );

    final legend = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < slices.items.length; i++)
          _DonutLegendRow(
            slice: slices.items[i],
            total: total,
            unit: unit,
            active: _active == i,
            dimmed: styles.fadeUnselected && _active != null && _active != i,
            onTap: () => _toggle(i),
          ),
      ],
    );

    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth >= 320) {
          return Row(
            children: [
              ring,
              const SizedBox(width: 20),
              Expanded(child: legend),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(child: ring),
            const SizedBox(height: 16),
            legend,
          ],
        );
      },
    );
  }

  // ── 提示框 ────────────────────────────────────────────

  Widget _tooltip(
    BuildContext context, {
    required double anchor,
    required double below,
    required double above,
    double? avoid,
    required double width,
    required int index,
  }) {
    final chart = widget.chart;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final palette = DshUiPalette.of(context);
    final valueStyle = theme.textTheme.labelLarge!.copyWith(color: theme.colorScheme.onSurface);
    final unitStyle = theme.textTheme.labelSmall!.copyWith(color: theme.colorScheme.onSurfaceVariant, fontSize: 11);
    final rows = [
      for (var s = 0; s < chart.series.length; s++)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Key(color: palette[s % palette.length], line: true),
              const SizedBox(width: 8),
              Text.rich(
                dshUiNumberSpan(
                  dshUiWithUnit(chart.series[s].values[index], chart.unit),
                  number: valueStyle,
                  unit: unitStyle,
                ),
              ),
              if (chart.series.length > 1 || chart.series[s].name != null) ...[
                const SizedBox(width: 8),
                Text(
                  chart.series[s].name ?? context.l10n.viewChartSeries(s + 1),
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
    ];
    return Positioned.fill(
      child: IgnorePointer(
        child: CustomSingleChildLayout(
          delegate: _TooltipLayout(anchor, below: below, above: above, avoid: avoid),
          child: GlassSurface(
            tier: GlassTier.sheet,
            blur: false,
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: math.max(120, width * 0.8)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    chart.categories[index],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(color: dsh.textTertiary),
                  ),
                  ...rows,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _semantics(DshUiChart chart) {
    final kind = switch (chart.kind) {
      DshUiChartKind.bar => appL10n.viewChartBar,
      DshUiChartKind.hbar => appL10n.viewChartHorizontalBar,
      DshUiChartKind.line => appL10n.viewChartLine,
      DshUiChartKind.donut => appL10n.viewChartDonut,
    };
    final parts = <String>[];
    for (final series in chart.series) {
      final data = [
        for (var i = 0; i < chart.categories.length; i++)
          '${chart.categories[i]} ${dshUiWithUnit(series.values[i], chart.unit)}',
      ].join(appL10n.viewListSeparator);
      parts.add(series.name == null ? data : appL10n.viewLabeledValue(series.name!, data));
    }
    return appL10n.viewChartSemantics(kind, parts.join(appL10n.viewSemicolonSeparator));
  }
}

/// 图例 / 提示里的系列标记：柱用小方块，线用短线。
class _Key extends StatelessWidget {
  const _Key({required this.color, this.line = false});

  final Color color;
  final bool line;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: line ? 12 : 8,
      height: line ? 2 : 8,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(line ? 1 : 2)),
    );
  }
}

/// 提示框的位置：水平以 [anchor] 为中心、夹在图内；竖直放在 [below] 之下，
/// 放不下就放到 [above] 之上；会盖住被点的那个点（[avoid]）时挪到它下面
/// （下面放不下就放上面）。
class _TooltipLayout extends SingleChildLayoutDelegate {
  _TooltipLayout(this.anchor, {required this.below, required this.above, this.avoid});

  final double anchor;
  final double below;
  final double above;
  final double? avoid;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size child) {
    final x = (anchor - child.width / 2).clamp(0.0, math.max(0.0, size.width - child.width));
    var y = below + child.height <= size.height ? below : math.max(0.0, above - child.height);
    final point = avoid;
    if (point != null && y < point + 8 && y + child.height > point - 8) {
      final under = point + 12;
      y = under + child.height <= size.height ? under : math.max(0.0, point - 12 - child.height);
    }
    return Offset(x.toDouble(), y);
  }

  @override
  bool shouldRelayout(_TooltipLayout old) =>
      old.anchor != anchor || old.below != below || old.above != above || old.avoid != avoid;
}

class _Styles {
  const _Styles({
    required this.tick,
    required this.category,
    required this.value,
    required this.label,
    required this.grid,
    required this.baseline,
    required this.guide,
    required this.surface,
    required this.palette,
    required this.scaler,
    required this.fadeUnselected,
  });

  final TextStyle tick;
  final TextStyle category;
  final TextStyle value;
  final TextStyle label;
  final Color grid;
  final Color baseline;
  final Color guide;
  final Color surface;
  final List<Color> palette;
  final TextScaler scaler;
  // V2 colours were checked against this opaque surface. Do not reduce their
  // alpha on selection; tooltips, guides and ring width retain the highlight.
  final bool fadeUnselected;

  Color series(int i) => palette[i % palette.length];

  TextPainter text(String text, TextStyle style, {double? maxWidth}) => span(
    TextSpan(text: text, style: style),
    maxWidth: maxWidth,
  );

  TextPainter span(InlineSpan span, {double? maxWidth}) =>
      TextPainter(text: span, textDirection: TextDirection.ltr, textScaler: scaler, maxLines: 1, ellipsis: '…')
        ..layout(maxWidth: maxWidth ?? double.infinity);

  /// 「68.4%」：数字等宽，单位小一号、淡一档。
  TextPainter number(String text) => span(
    dshUiNumberSpan(
      text,
      number: value,
      unit: value.copyWith(fontSize: (value.fontSize ?? 11) - 1, color: tick.color),
    ),
  );
}

// ───────────────────────── 柱状 / 折线 ─────────────────────────

class _XYGeometry {
  _XYGeometry(this.chart, Size size, _Styles styles) {
    final values = [
      for (final s in chart.series)
        for (final v in s.values) ?v,
    ];
    ticks = dshUiValueAxis(values, zero: chart.kind == DshUiChartKind.bar);
    lo = ticks.first;
    hi = ticks.last;
    tickLabels = [for (final t in ticks) styles.text(formatDshUiCompact(t), styles.tick)];
    final labelWidth = tickLabels.fold<double>(0, (w, p) => math.max(w, p.width));
    // l10n:keep font height measurement sample
    final categoryHeight = styles.text('国', styles.category).height;
    plot = Rect.fromLTRB(labelWidth + 8, 8, size.width, size.height - categoryHeight - 8);
    band = plot.width / chart.categories.length;
    // 类别标签放不下就隔几个画一个。
    final widest = chart.categories.fold<double>(0, (w, c) => math.max(w, styles.text(c, styles.category).width));
    final every = math.max(1, ((math.min(widest, 72) + 8) / band).ceil());
    categoryLabels = [
      for (var i = 0; i < chart.categories.length; i++)
        i % every == 0
            ? styles.text(chart.categories[i], styles.category, maxWidth: math.max(8, band * every - 4))
            : null,
    ];
  }

  final DshUiChart chart;
  late final List<double> ticks;
  late final double lo;
  late final double hi;
  late final List<TextPainter> tickLabels;
  late final List<TextPainter?> categoryLabels;
  late final Rect plot;
  late final double band;

  double x(int index) => plot.left + band * index + band / 2;

  double y(double value) {
    final span = hi - lo;
    if (span <= 0 || !span.isFinite) return plot.bottom;
    final t = ((value - lo) / span).clamp(-0.05, 1.05);
    return plot.bottom - t * plot.height;
  }

  double get zeroY => y(math.max(lo, math.min(0, hi)));

  /// 这一类里最高的那个值的 y（提示框别盖住它）；没有值时为 null。
  double? topAt(int index) {
    double? top;
    for (final s in chart.series) {
      final v = s.values[index];
      if (v == null) continue;
      final at = chart.kind == DshUiChartKind.bar ? math.min(y(v), zeroY) : y(v);
      top = top == null ? at : math.min(top, at);
    }
    return top;
  }

  int? indexAt(double dx) {
    if (chart.categories.isEmpty || band <= 0) return null;
    return ((dx - plot.left) / band).floor().clamp(0, chart.categories.length - 1);
  }
}

class _XYPainter extends CustomPainter {
  _XYPainter(this.geo, this.styles, this.active, this.t) : super(repaint: t);

  final _XYGeometry geo;
  final _Styles styles;
  final int? active;
  final Animation<double> t;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = geo.plot;
    final grid = Paint()
      ..color = styles.grid
      ..strokeWidth = 0.5;
    for (var i = 0; i < geo.ticks.length; i++) {
      final y = geo.y(geo.ticks[i]);
      if (geo.ticks[i] != 0) {
        canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      }
      final label = geo.tickLabels[i];
      label.paint(canvas, Offset(plot.left - 8 - label.width, y - label.height / 2));
    }
    // 零线 / 底线稍重一点。
    final zero = geo.zeroY;
    canvas.drawLine(
      Offset(plot.left, zero),
      Offset(plot.right, zero),
      Paint()
        ..color = styles.baseline
        ..strokeWidth = 1,
    );
    for (var i = 0; i < geo.categoryLabels.length; i++) {
      final label = geo.categoryLabels[i];
      if (label == null) continue;
      label.paint(canvas, Offset(geo.x(i) - label.width / 2, plot.bottom + 8));
    }
    if (geo.chart.kind == DshUiChartKind.bar) {
      _bars(canvas);
    } else {
      _lines(canvas);
    }
  }

  void _bars(Canvas canvas) {
    final series = geo.chart.series;
    final k = series.length;
    const gap = 2.0;
    final group = geo.band * 0.72;
    final barWidth = math.max(2.0, math.min(24.0, (group - gap * (k - 1)) / k));
    final used = barWidth * k + gap * (k - 1);
    final zero = geo.zeroY;
    final grow = t.value;
    for (var i = 0; i < geo.chart.categories.length; i++) {
      final left0 = geo.plot.left + geo.band * i + (geo.band - used) / 2;
      final dim = styles.fadeUnselected && active != null && active != i;
      for (var s = 0; s < k; s++) {
        final value = series[s].values[i];
        if (value == null) continue;
        final top = zero + (geo.y(value) - zero) * grow;
        final rect = Rect.fromLTRB(
          left0 + s * (barWidth + gap),
          math.min(top, zero),
          left0 + s * (barWidth + gap) + barWidth,
          math.max(top, zero),
        );
        if (rect.height < 0.5) continue;
        final r = Radius.circular(math.min(4, math.min(barWidth / 2, rect.height)));
        final up = value >= 0;
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            rect,
            topLeft: up ? r : Radius.zero,
            topRight: up ? r : Radius.zero,
            bottomLeft: up ? Radius.zero : r,
            bottomRight: up ? Radius.zero : r,
          ),
          Paint()..color = styles.series(s).withValues(alpha: dim ? 0.3 : 1),
        );
      }
    }
  }

  void _lines(Canvas canvas) {
    final series = geo.chart.series;
    final n = geo.chart.categories.length;
    final grow = t.value;
    final base = geo.zeroY;
    double yOf(double v) => base + (geo.y(v) - base) * grow;
    if (active case final a?) {
      canvas.drawLine(
        Offset(geo.x(a), geo.plot.top),
        Offset(geo.x(a), geo.plot.bottom),
        Paint()
          ..color = styles.guide
          ..strokeWidth = 1,
      );
    }
    for (var s = 0; s < series.length; s++) {
      final color = styles.series(s);
      final path = Path();
      var open = false;
      for (var i = 0; i < n; i++) {
        final v = series[s].values[i];
        if (v == null) {
          open = false;
          continue;
        }
        final p = Offset(geo.x(i), yOf(v));
        open ? path.lineTo(p.dx, p.dy) : path.moveTo(p.dx, p.dy);
        open = true;
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
      // 点少时每点一个小圆；点多时只画选中的和孤立的点（前后都断开，
      // 否则这一点在线上看不见）。
      for (var i = 0; i < n; i++) {
        final v = series[s].values[i];
        if (v == null) continue;
        final lonely = (i == 0 || series[s].values[i - 1] == null) && (i == n - 1 || series[s].values[i + 1] == null);
        final isActive = active == i;
        if (!(n <= 12 || isActive || lonely)) continue;
        final c = Offset(geo.x(i), yOf(v));
        final r = isActive ? 4.5 : 3.0;
        canvas.drawCircle(c, r + 2, Paint()..color = styles.surface);
        canvas.drawCircle(c, r, Paint()..color = color);
      }
    }
  }

  @override
  bool shouldRepaint(_XYPainter old) => old.geo != geo || old.active != active || old.styles != styles;
}

// ───────────────────────── 横向柱状 ─────────────────────────

class _HBarGeometry {
  _HBarGeometry(this.chart, Size size, this.rowHeight, _Styles styles) {
    final values = [
      for (final s in chart.series)
        for (final v in s.values) ?v,
    ];
    lo = values.isEmpty ? 0 : math.min(0, values.reduce(math.min));
    hi = values.isEmpty ? 1 : math.max(0, values.reduce(math.max));
    if (lo == hi) hi = lo + 1;
    final labelMax = math.max(48.0, size.width * 0.32);
    labels = [for (final c in chart.categories) styles.text(c, styles.label, maxWidth: labelMax)];
    final labelWidth = labels.fold<double>(0, (w, p) => math.max(w, p.width));
    single = chart.series.length == 1;
    valueLabels = single
        ? [for (final v in chart.series.first.values) styles.number(dshUiWithUnit(v, chart.unit))]
        : const [];
    final valueWidth = valueLabels.fold<double>(0, (w, p) => math.max(w, p.width));
    barLeft = labelWidth + 12;
    barWidth = math.max(24, size.width - barLeft - (single ? valueWidth + 8 : 0));
  }

  final DshUiChart chart;
  final double rowHeight;
  late final double lo;
  late final double hi;
  late final List<TextPainter> labels;
  late final List<TextPainter> valueLabels;
  late final bool single;
  late final double barLeft;
  late final double barWidth;

  double x(double value) => barLeft + (value - lo) / (hi - lo) * barWidth;
}

class _HBarPainter extends CustomPainter {
  _HBarPainter(this.geo, this.styles, this.active, this.t) : super(repaint: t);

  final _HBarGeometry geo;
  final _Styles styles;
  final int? active;
  final Animation<double> t;

  @override
  void paint(Canvas canvas, Size size) {
    final series = geo.chart.series;
    final k = series.length;
    const gap = 2.0;
    final thickness = k == 1 ? 14.0 : math.min(10.0, (geo.rowHeight - 14 - gap * (k - 1)) / k);
    final used = thickness * k + gap * (k - 1);
    final zero = geo.x(0);
    final grow = t.value;
    if (geo.lo < 0) {
      canvas.drawLine(
        Offset(zero, 0),
        Offset(zero, size.height),
        Paint()
          ..color = styles.baseline
          ..strokeWidth = 1,
      );
    }
    for (var i = 0; i < geo.chart.categories.length; i++) {
      final top = geo.rowHeight * i;
      final mid = top + geo.rowHeight / 2;
      final dim = styles.fadeUnselected && active != null && active != i;
      final label = geo.labels[i];
      label.paint(canvas, Offset(0, mid - label.height / 2));
      var tip = zero;
      for (var s = 0; s < k; s++) {
        final value = series[s].values[i];
        if (value == null) continue;
        final end = zero + (geo.x(value) - zero) * grow;
        final y0 = mid - used / 2 + s * (thickness + gap);
        final rect = Rect.fromLTRB(math.min(end, zero), y0, math.max(end, zero), y0 + thickness);
        tip = value >= 0 ? math.max(tip, rect.right) : math.min(tip, rect.left);
        if (rect.width < 0.5) continue;
        final r = Radius.circular(math.min(4, math.min(thickness / 2, rect.width)));
        final right = value >= 0;
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            rect,
            topRight: right ? r : Radius.zero,
            bottomRight: right ? r : Radius.zero,
            topLeft: right ? Radius.zero : r,
            bottomLeft: right ? Radius.zero : r,
          ),
          Paint()..color = styles.series(s).withValues(alpha: dim ? 0.3 : 1),
        );
      }
      if (geo.single && series.first.values[i] != null) {
        final value = geo.valueLabels[i];
        final negative = series.first.values[i]! < 0;
        final dx = negative ? tip - 6 - value.width : tip + 6;
        value.paint(canvas, Offset(dx, mid - value.height / 2));
      }
    }
  }

  @override
  bool shouldRepaint(_HBarPainter old) => old.geo != geo || old.active != active || old.styles != styles;
}

// ───────────────────────── 环形 ─────────────────────────

class _Slice {
  const _Slice(this.label, this.value, this.color);

  final String label;
  final double? value;
  final Color color;

  /// 画进环里的量（≤ 0 和空值不画）。
  double get drawn => value != null && value! > 0 ? value! : 0;
}

class _DonutSlices {
  _DonutSlices(this.items) : total = items.fold(0, (sum, s) => sum + s.drawn);

  /// 超过 6 类：前 5 类照画，其余合成「其他」。
  factory _DonutSlices.of(DshUiChart chart, List<Color> palette, Color other) {
    final values = chart.series.first.values;
    final n = chart.categories.length;
    final keep = n > palette.length ? palette.length - 1 : n;
    final items = [for (var i = 0; i < keep; i++) _Slice(chart.categories[i], values[i], palette[i % palette.length])];
    if (keep < n) {
      var rest = 0.0;
      for (var i = keep; i < n; i++) {
        final v = values[i];
        if (v != null && v > 0) rest += v;
      }
      items.add(_Slice(appL10n.commonOther, rest, other));
    }
    return _DonutSlices(items);
  }

  final List<_Slice> items;
  final double total;

  int? indexAt(Offset p, Size size) {
    final center = size.center(Offset.zero);
    final d = p - center;
    final radius = size.shortestSide / 2;
    if (d.distance > radius || d.distance < radius - 40 || total <= 0) {
      return null;
    }
    var angle = math.atan2(d.dy, d.dx) + math.pi / 2;
    if (angle < 0) angle += 2 * math.pi;
    var start = 0.0;
    for (var i = 0; i < items.length; i++) {
      final sweep = items[i].drawn / total * 2 * math.pi;
      if (angle >= start && angle < start + sweep) return i;
      start += sweep;
    }
    return null;
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter(this.slices, this.styles, this.active, this.t) : super(repaint: t);

  final _DonutSlices slices;
  final _Styles styles;
  final int? active;
  final Animation<double> t;

  static const thickness = 18.0;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - thickness / 2 - 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final total = slices.total;
    if (total <= 0) {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = styles.grid
          ..style = PaintingStyle.stroke
          ..strokeWidth = thickness,
      );
      return;
    }
    final drawn = slices.items.where((s) => s.drawn > 0).length;
    // 2dp 的表面缝（按弧长换成角度）；只有一块时不留缝。
    final gap = drawn > 1 ? 2 / radius : 0.0;
    final sweepTotal = 2 * math.pi * t.value;
    var start = -math.pi / 2;
    for (var i = 0; i < slices.items.length; i++) {
      final slice = slices.items[i];
      if (slice.drawn <= 0) continue;
      final sweep = slice.drawn / total * sweepTotal;
      final visible = sweep - gap;
      if (visible > 0.001) {
        final dim = styles.fadeUnselected && active != null && active != i;
        canvas.drawArc(
          rect,
          start + gap / 2,
          visible,
          false,
          Paint()
            ..color = slice.color.withValues(alpha: dim ? 0.3 : 1)
            ..style = PaintingStyle.stroke
            ..strokeWidth = active == i ? thickness + 4 : thickness,
        );
      }
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) => old.slices != slices || old.active != active || old.styles != styles;
}

class _DonutLegendRow extends StatelessWidget {
  const _DonutLegendRow({
    required this.slice,
    required this.total,
    required this.unit,
    required this.active,
    required this.dimmed,
    required this.onTap,
  });

  final _Slice slice;
  final double total;
  final String? unit;
  final bool active;
  final bool dimmed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    // 百分比统一一位小数，一列对得齐。
    final percent = total > 0 && slice.value != null && slice.value! > 0
        ? '${(slice.value! / total * 100).toStringAsFixed(1)}%'
        : '—';
    final body = theme.textTheme.bodySmall!;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedOpacity(
        opacity: dimmed ? 0.45 : 1,
        duration: AppMotion.of(context, AppMotion.quick),
        child: SizedBox(
          height: 28,
          child: Row(
            children: [
              _Key(color: slice.color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  slice.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: body.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text.rich(
                dshUiNumberSpan(
                  dshUiWithUnit(slice.value, unit),
                  number: body.copyWith(color: theme.colorScheme.onSurface),
                  unit: body.copyWith(fontSize: (body.fontSize ?? 12) - 1, color: dsh.textTertiary),
                ),
              ),
              SizedBox(
                width: 52,
                child: Text(
                  percent,
                  textAlign: TextAlign.right,
                  style: AppType.tabular(body.copyWith(color: dsh.textTertiary)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
