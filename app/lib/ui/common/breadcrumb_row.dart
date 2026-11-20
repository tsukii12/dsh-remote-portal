import 'package:flutter/material.dart';

import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'pressable.dart';

/// Breadcrumb capsules in one scrolling row, kept scrolled to the current
/// (last) one; [gap] below it.
class BreadcrumbRow extends StatefulWidget {
  const BreadcrumbRow({super.key, required this.crumbs, required this.onTap});

  final List<({String label, String path})> crumbs;
  final ValueChanged<String> onTap;

  static const height = 32.0;
  static const gap = 12.0;

  @override
  State<BreadcrumbRow> createState() => _BreadcrumbRowState();
}

class _BreadcrumbRowState extends State<BreadcrumbRow> {
  final _scroll = ScrollController();

  void _toEnd() {
    if (mounted && _scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _toEnd());
  }

  @override
  void didUpdateWidget(BreadcrumbRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.crumbs.length != widget.crumbs.length ||
        oldWidget.crumbs.lastOrNull?.path != widget.crumbs.lastOrNull?.path) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _toEnd());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: BreadcrumbRow.gap),
    child: SizedBox(
      height: BreadcrumbRow.height,
      child: ListView.separated(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: widget.crumbs.length,
        separatorBuilder: (_, _) => SizedBox(
          width: 20,
          child: Center(child: Icon(AppIcons.disclosure, size: 16, color: DshColors.of(context).textTertiary)),
        ),
        itemBuilder: (context, i) => BreadcrumbCapsule(
          label: widget.crumbs[i].label,
          current: i == widget.crumbs.length - 1,
          onTap: () => widget.onTap(widget.crumbs[i].path),
        ),
      ),
    ),
  );
}

/// One breadcrumb: a quiet capsule, a little stronger for the current one.
class BreadcrumbCapsule extends StatelessWidget {
  const BreadcrumbCapsule({super.key, required this.label, required this.current, required this.onTap});

  final String label;
  final bool current;
  final VoidCallback onTap;
  static const inset = 12.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final fill = dark
        ? Colors.white.withValues(alpha: current ? 0.11 : 0.06)
        : scheme.onSurface.withValues(alpha: current ? 0.08 : 0.04);
    return Semantics(
      button: !current,
      selected: current,
      label: label,
      onTap: current ? null : onTap,
      excludeSemantics: true,
      child: Center(
        child: Pressable(
          enabled: !current,
          onTap: current ? null : onTap,
          child: Container(
            height: BreadcrumbRow.height,
            padding: const EdgeInsets.symmetric(horizontal: inset),
            alignment: Alignment.center,
            decoration: ShapeDecoration(color: fill, shape: const StadiumBorder()),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontSize: 13,
                  height: 1.2,
                  fontWeight: current ? FontWeight.w600 : FontWeight.w500,
                  color: current ? scheme.onSurface : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
