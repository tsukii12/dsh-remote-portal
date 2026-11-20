import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../theme/theme.dart';
import 'dsh_ui_style.dart';
import '../../common/smooth_size.dart';

/// 骨架里的一块。
enum DshUiGhost { metrics, chart, hbar, donut, compare, steps, text, callout, options, confirm, block }

/// 骨架的一块和它的数量（几个指标、几个选项、几行…）。
final class DshUiGhostPart {
  const DshUiGhostPart(this.kind, [this.count = 1]);

  final DshUiGhost kind;
  final int count;

  @override
  bool operator ==(Object other) => other is DshUiGhostPart && other.kind == kind && other.count == count;

  @override
  int get hashCode => Object.hash(kind, count);

  @override
  String toString() => '${kind.name}×$count';
}

/// 从半截源文本猜出来的形状。
final class DshUiShape {
  const DshUiShape({this.title, required this.parts});

  final String? title;
  final List<DshUiGhostPart> parts;
}

final _typePattern = RegExp(r'"type"\s*:\s*"(\w+)"');
final _titlePattern = RegExp(r'"title"\s*:\s*"((?:[^"\\]|\\.)*)"');
final _kindPattern = RegExp(r'"kind"\s*:\s*"(\w+)"');
final _labelPattern = RegExp(r'"label"\s*:');
final _itemTitlePattern = RegExp(r'"title"\s*:');
final _categoriesPattern = RegExp(r'"categories"\s*:\s*\[([^\]]*)');

/// 流式中、围栏没闭合时：不解析 JSON，只用正则抠出已经写出来的组件类型
/// （`"type":"chart"`）和数量，猜一个形状，让骨架的高度接近成品、少跳动。
DshUiShape guessDshUiShape(String partial) {
  String? title;
  final titleMatch = _titlePattern.firstMatch(partial);
  // 只认根节点的标题：它在第一个子组件之前。
  final firstChild = _typePattern.allMatches(partial).skip(1).firstOrNull;
  if (titleMatch != null && (firstChild == null || titleMatch.start < firstChild.start)) {
    try {
      title = (jsonDecode('"${titleMatch.group(1)}"') as String).trim();
    } catch (_) {
      title = null;
    }
    if (title != null && title.isEmpty) title = null;
  }

  final matches = _typePattern.allMatches(partial).toList();
  final parts = <DshUiGhostPart>[];
  for (var i = 0; i < matches.length; i++) {
    final type = matches[i].group(1);
    final segment = partial.substring(matches[i].end, i + 1 < matches.length ? matches[i + 1].start : partial.length);
    int count(RegExp pattern, int min) => math.max(min, pattern.allMatches(segment).length);
    switch (type) {
      case 'metric':
        final last = parts.isEmpty ? null : parts.last;
        if (last?.kind == DshUiGhost.metrics && last!.count < 3) {
          parts[parts.length - 1] = DshUiGhostPart(DshUiGhost.metrics, last.count + 1);
        } else {
          parts.add(const DshUiGhostPart(DshUiGhost.metrics));
        }
      case 'chart':
        final kind = _kindPattern.firstMatch(segment)?.group(1);
        if (kind == 'hbar' || kind == 'barh' || kind == 'horizontal') {
          final categories = _categoriesPattern.firstMatch(segment)?.group(1);
          final n = categories == null ? 4 : math.max(1, '"'.allMatches(categories).length ~/ 2);
          parts.add(DshUiGhostPart(DshUiGhost.hbar, math.min(n, 12)));
        } else if (kind == 'donut' || kind == 'pie') {
          parts.add(const DshUiGhostPart(DshUiGhost.donut));
        } else {
          parts.add(const DshUiGhostPart(DshUiGhost.chart));
        }
      case 'compare':
        parts.add(DshUiGhostPart(DshUiGhost.compare, count(_itemTitlePattern, 2).clamp(2, 4)));
      case 'steps':
        parts.add(DshUiGhostPart(DshUiGhost.steps, count(_labelPattern, 2).clamp(1, 12)));
      case 'options':
        parts.add(DshUiGhostPart(DshUiGhost.options, count(_labelPattern, 2).clamp(1, 8)));
      case 'confirm':
        parts.add(const DshUiGhostPart(DshUiGhost.confirm));
      case 'text':
        parts.add(const DshUiGhostPart(DshUiGhost.text));
      case 'callout':
        parts.add(const DshUiGhostPart(DshUiGhost.callout));
      default:
        break;
    }
  }
  if (parts.isEmpty) parts.add(const DshUiGhostPart(DshUiGhost.block));
  return DshUiShape(title: title, parts: parts);
}

/// 视图还在生成：同一张卡片外框里放形状相近的灰块，慢慢呼吸（系统关了动画
/// 就静止）。
class DshUiSkeleton extends StatefulWidget {
  const DshUiSkeleton({super.key, required this.shape});

  final DshUiShape shape;

  @override
  State<DshUiSkeleton> createState() => _DshUiSkeletonState();
}

class _DshUiSkeletonState extends State<DshUiSkeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: AppMotion.breath);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _pulse
        ..stop()
        ..value = 1;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final shape = widget.shape;
    final ghost = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFFFFFFFF).withValues(alpha: 0.08)
        : NeutralTones.current(context).shadowInk.withValues(alpha: 0.07);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < shape.parts.length; i++) ...[
          if (i > 0) const SizedBox(height: DshUiMetrics.gap),
          _GhostPart(part: shape.parts[i], color: ghost),
        ],
      ],
    );
    return Semantics(
      label: l10n.viewUiGenerating,
      child: GlassSurface(
        tier: GlassTier.card,
        borderRadius: AppShape.radiusLg,
        padding: const EdgeInsets.all(DshUiMetrics.cardPadding),
        child: SmoothSize(
          duration: AppMotion.of(context, AppMotion.standard),
          curve: AppMotion.std,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (shape.title case final title?) ...[
                Text(title, style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurface)),
                const SizedBox(height: 12),
              ],
              AnimatedBuilder(
                animation: _pulse,
                child: body,
                builder: (context, child) {
                  // 0.55 ↔ 1 的余弦呼吸。
                  final v = 0.775 + 0.225 * math.cos(_pulse.value * 2 * math.pi);
                  return Opacity(opacity: v, child: child);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GhostPart extends StatelessWidget {
  const _GhostPart({required this.part, required this.color});

  final DshUiGhostPart part;
  final Color color;

  Widget _bar(double width, double height, {double radius = 4}) => Container(
    width: width,
    height: height,
    decoration: ShapeDecoration(color: color, shape: Squircle.border(radius)),
  );

  Widget _well(double height, {double radius = DshUiMetrics.wellRadius}) =>
      _bar(double.infinity, height, radius: radius);

  @override
  Widget build(BuildContext context) {
    final n = part.count;
    switch (part.kind) {
      case DshUiGhost.metrics:
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < math.max(n, 2); i++) ...[
              if (i > 0) const SizedBox(width: DshUiMetrics.rowGap),
              Expanded(
                child: i < n
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(height: 18, child: Center(widthFactor: 1, child: _bar(40, 10))),
                          const SizedBox(height: 4),
                          SizedBox(height: 29, child: Center(widthFactor: 1, child: _bar(80, 22, radius: 6))),
                        ],
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ],
        );
      case DshUiGhost.chart:
        const heights = [0.55, 0.7, 0.5, 0.95, 0.65, 0.6];
        return SizedBox(
          height: DshUiMetrics.chartHeight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 8, 0, 23),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final h in heights)
                  Expanded(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(heightFactor: h, child: _bar(20, double.infinity)),
                    ),
                  ),
              ],
            ),
          ),
        );
      case DshUiGhost.hbar:
        return Column(
          children: [
            for (var i = 0; i < n; i++)
              SizedBox(
                height: DshUiMetrics.hbarRow,
                child: Row(
                  children: [
                    _bar(48, 10),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: 0.9 - 0.6 * i / math.max(1, n),
                          child: _bar(double.infinity, 14),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      case DshUiGhost.donut:
        return SizedBox(
          height: DshUiMetrics.donut,
          child: Row(
            children: [
              Container(
                width: DshUiMetrics.donut,
                height: DshUiMetrics.donut,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: color, width: 18),
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < 4; i++)
                      SizedBox(
                        height: 28,
                        child: Align(alignment: Alignment.centerLeft, child: _bar(96 - i * 12.0, 10)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      case DshUiGhost.compare:
        if (n == 2) {
          return Row(
            children: [
              Expanded(child: _well(132)),
              const SizedBox(width: DshUiMetrics.rowGap),
              Expanded(child: _well(132)),
            ],
          );
        }
        return Column(
          children: [
            for (var i = 0; i < n; i++) ...[if (i > 0) const SizedBox(height: DshUiMetrics.rowGap), _well(88)],
          ],
        );
      case DshUiGhost.steps:
        return Column(
          children: [
            for (var i = 0; i < n; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              SizedBox(
                height: 22,
                child: Row(
                  children: [
                    const SizedBox(width: 2),
                    _bar(16, 16, radius: 8),
                    const SizedBox(width: 14),
                    _bar(120 + (i % 3) * 32.0, 10),
                  ],
                ),
              ),
            ],
          ],
        );
      case DshUiGhost.options:
        return Column(
          children: [
            for (var i = 0; i < n; i++) ...[if (i > 0) const SizedBox(height: 8), _well(DshUiMetrics.control)],
          ],
        );
      case DshUiGhost.confirm:
        return Row(
          children: [
            Expanded(child: _bar(double.infinity, 44, radius: 22)),
            const SizedBox(width: 12),
            Expanded(child: _bar(double.infinity, 44, radius: 22)),
          ],
        );
      case DshUiGhost.text:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 26,
              child: Align(alignment: Alignment.centerLeft, child: _bar(double.infinity, 12)),
            ),
            SizedBox(
              height: 26,
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(widthFactor: 0.6, child: _bar(double.infinity, 12)),
              ),
            ),
          ],
        );
      case DshUiGhost.callout:
        return _well(48);
      case DshUiGhost.block:
        return _well(120);
    }
  }
}
