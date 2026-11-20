// The app-side API for native plugin views (docs/design/native-plugins-views.md
// §9). A plugin view is drawn by the dsh-ui renderer with the plugin profile;
// this file is what the slots (tool cards, panels, the composer strip) use.

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../plugins/native/native_icons.dart' show nativeIcon;
import '../../chat/dsh_ui/dsh_ui_blocks.dart';
import '../../chat/dsh_ui/dsh_ui_model.dart';
import '../../chat/dsh_ui/dsh_ui_plugin.dart';
import '../../chat/dsh_ui/dsh_ui_plugin_styles.dart';
import '../../chat/dsh_ui/dsh_ui_plugin_controls.dart';
import '../../chat/dsh_ui/dsh_ui_plugin_controls_state.dart';
import '../../chat/dsh_ui/dsh_ui_style.dart';
import '../../chat/dsh_ui/dsh_ui_widgets.dart' show DshUiNodeView;
import '../../chat/media/media_viewer.dart' show openGalleryPictures;
import '../../chat/widgets/stream_row.dart';
import '../../common/expand_reveal.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';

export '../../chat/dsh_ui/dsh_ui_bind.dart' show pluginBindingText, resolvePluginBinding, resolvePluginBindings;
export '../../chat/dsh_ui/dsh_ui_blocks.dart' show PluginImages;
export '../../chat/dsh_ui/dsh_ui_model.dart'
    show DshUiInvalid, DshUiIssue, DshUiParse, DshUiParsed, DshUiView, dshUiPluginComponents;
export '../../chat/dsh_ui/dsh_ui_plugin.dart';

/// A plugin view: v1 retains its original rendering; v2 includes the fixed
/// host attribution boundary. [PluginFrame] supplies the outer plugin name.
/// [view] and [data] are decoded JSON. An invalid root draws one error line.
class PluginView extends StatefulWidget {
  const PluginView({
    super.key,
    required this.view,
    this.data,
    this.onAction,
    this.clock,
    this.budget = PluginViewBudget.panel,
    this.imageResolver,
    this.showTitle = true,
    this.animate = false,
  });

  final Object? view;
  final Object? data;

  /// null：只读（`actions`、`confirm` 不显示，`options` 只读，`list` 行不可点）。
  final PluginActionHandler? onAction;

  /// Uses the host clock at the real tap, before any local request queue.
  final DateTime Function()? clock;
  final PluginViewBudget budget;

  /// 缺省从上层的 [PluginImages] 取。
  final PluginImageResolver? imageResolver;

  /// 画视图自己的 `title`（面板已经有标题栏时可以关掉）。
  final bool showTitle;

  /// 图表生长（只在内容刚到时开）。
  final bool animate;

  @override
  State<PluginView> createState() => _PluginViewState();
}

class _PluginViewState extends State<PluginView> {
  late final PluginDraftController _drafts = PluginDraftController(
    data: widget.data,
    clock: () => widget.clock?.call() ?? DateTime.now(),
  )..addListener(_changed);

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(PluginView old) {
    super.didUpdateWidget(old);
    _drafts.syncRemote(widget.data);
    _drafts.setHandler(widget.budget == PluginViewBudget.panel ? widget.onAction : null);
  }

  @override
  void dispose() {
    _drafts.removeListener(_changed);
    _drafts.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A palette change rebuilds this view: one that asked for
    // `accent: "app"` is parsed again with the new accent (the cache knows).
    Theme.of(context);
    _drafts.setHandler(widget.budget == PluginViewBudget.panel ? widget.onAction : null);
    final parsed = parsePluginView(widget.view, data: _drafts.data, budget: widget.budget);
    if (parsed is DshUiInvalid) {
      _drafts.syncInputs(const []);
      return const PluginViewError();
    }
    final view = (parsed as DshUiParsed).view;
    _drafts.syncInputs(view.nodes.whereType<DshUiInput>());
    final body = PluginViewBody(
      view: view,
      budget: widget.budget,
      onAction: view.version >= 2 ? (_drafts.enabled ? _drafts.invoke : null) : widget.onAction,
      imageResolver: widget.imageResolver,
      showTitle: widget.showTitle,
      animate: widget.animate,
    );
    return view.version >= 2 ? PluginControlsScope(controller: _drafts, child: body) : body;
  }
}

/// 已经解析好的视图（工具卡在 `ToolView` 里解析过一次，直接用这个）。
class PluginViewBody extends StatelessWidget {
  const PluginViewBody({
    super.key,
    required this.view,
    this.budget = PluginViewBudget.panel,
    this.onAction,
    this.imageResolver,
    this.showTitle = true,
    this.animate = false,
  });

  final DshUiView view;
  final PluginViewBudget budget;
  final PluginActionHandler? onAction;
  final PluginImageResolver? imageResolver;
  final bool showTitle;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Widget content;
    if (budget == PluginViewBudget.strip) {
      content = DshUiStripLine(view: view);
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showTitle && view.title != null) ...[
            Semantics(
              header: true,
              child: Text(
                view.title!,
                style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurface),
              ),
            ),
            const SizedBox(height: 12),
          ],
          DshUiNodeView(node: view.root),
        ],
      );
    }
    return DshUiPluginScope(
      onAction: onAction,
      imageResolver: imageResolver ?? PluginImages.maybeOf(context)?.resolver,
      animate: animate,
      child: DshUiPictureViewer(
        open: openGalleryPictures,
        child: view.version == 2
            ? DshUiPluginStyles(view: view, compact: budget == PluginViewBudget.strip, child: content)
            : content,
      ),
    );
  }
}

/// 根节点坏了：一行「插件界面有误」。
class PluginViewError extends StatelessWidget {
  const PluginViewError({super.key});

  static const height = 32.0;

  @override
  Widget build(BuildContext context) {
    final dsh = DshColors.of(context);
    return SizedBox(
      height: height,
      child: Row(
        children: [
          Icon(AppIcons.info, size: 16, color: dsh.textTertiary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              context.l10n.plugViewInvalid,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
            ),
          ),
        ],
      ),
    );
  }
}

/// 署名外框：玻璃卡片（圆角 20、内边距 16），顶部一行插件图标 + 插件名
/// （次要色），[trailing] 在这一行末尾。插件界面一律套它，防止冒充系统
/// 界面（`native-plugins-views.md` §7、`native-plugins.md` §3.7）。
///
/// [icon] 是 ui.json 图标名；缺省画插件名的首字。[surface] 为 false 时
/// 只画署名行和内容（已经在卡片或弹层里时用）。
class PluginFrame extends StatelessWidget {
  const PluginFrame({
    super.key,
    required this.pluginName,
    this.icon,
    this.trailing,
    this.surface = true,
    required this.child,
  });

  final String pluginName;
  final String? icon;
  final Widget? trailing;
  final bool surface;
  final Widget child;

  /// 署名行的高度（也是图标的格子）。
  static const headerHeight = 24.0;
  static const markSize = 20.0;

  @override
  Widget build(BuildContext context) {
    final dsh = DshColors.of(context);
    final header = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: headerHeight),
      child: Row(
        children: [
          PluginMark(name: pluginName, icon: icon),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              pluginName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(color: dsh.textTertiary),
            ),
          ),
          if (trailing case final t?) ...[const SizedBox(width: 8), t],
        ],
      ),
    );
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        header,
        const SizedBox(height: 12),
        DshUiSourceName(name: pluginName, child: child),
      ],
    );
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: context.l10n.plugViewFrom(pluginName),
      child: surface
          ? GlassSurface(
              tier: GlassTier.card,
              borderRadius: AppShape.radiusLg,
              padding: const EdgeInsets.all(DshUiMetrics.cardPadding),
              child: content,
            )
          : content,
    );
  }
}

/// 插件的小标记（20 × 20）：认识的图标名（[nativeIcon]：ui.json 的名字加
/// coin、speaker 等）画图标，否则画名字的首字。
class PluginMark extends StatelessWidget {
  const PluginMark({super.key, required this.name, this.icon});

  final String name;
  final String? icon;

  @override
  Widget build(BuildContext context) {
    final dsh = DshColors.of(context);
    final glyph = nativeIcon(icon);
    const size = PluginFrame.markSize;
    if (glyph != null) {
      return SizedBox.square(
        dimension: size,
        child: Icon(glyph, size: 16, color: dsh.textTertiary),
      );
    }
    final initial = name.trim().isEmpty ? '·' : name.trim().characters.first.toUpperCase();
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: ShapeDecoration(color: context.dshUiWell, shape: Squircle.border(6)),
          child: Center(
            child: Text(
              initial,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 工具卡（`native-plugins-views.md` §8）：工具行展开区。能画就是一张与模型卡
/// 同一套的卡片（只读），参数和结果（[fallback]）收在卡片下的「详情」里、默认收起；
/// 画不了是一行「插件界面有误」，下面直接是 [fallback]。
///
/// [details] 为 false 时只画卡片（一轮折叠后外露的那张）。
class PluginToolCard extends StatelessWidget {
  const PluginToolCard({super.key, required this.parse, required this.fallback, this.details = true});

  final DshUiParse parse;
  final Widget fallback;
  final bool details;

  @override
  Widget build(BuildContext context) {
    return switch (parse) {
      DshUiParsed(:final view) when !details => _ToolCardSurface(view: view),
      DshUiParsed(:final view) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _ToolCardSurface(view: view),
          const SizedBox(height: 4),
          _ToolCardDetails(child: fallback),
        ],
      ),
      DshUiInvalid() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [const PluginViewError(), const SizedBox(height: 4), fallback],
      ),
    };
  }
}

class _ToolCardSurface extends StatelessWidget {
  const _ToolCardSurface({required this.view});

  final DshUiView view;

  @override
  Widget build(BuildContext context) => GlassSurface(
    tier: GlassTier.card,
    borderRadius: AppShape.radiusLg,
    padding: const EdgeInsets.all(DshUiMetrics.cardPadding),
    child: PluginViewBody(view: view, budget: PluginViewBudget.toolCard),
  );
}

/// 卡片下的「详情」：一行，点开是参数和结果。
class _ToolCardDetails extends StatefulWidget {
  const _ToolCardDetails({required this.child});

  final Widget child;

  @override
  State<_ToolCardDetails> createState() => _ToolCardDetailsState();
}

class _ToolCardDetailsState extends State<_ToolCardDetails> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    void toggle() => setState(() => _open = !_open);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          expanded: _open,
          child: StreamRowFrame(
            onTap: toggle,
            child: Row(
              children: [
                Text(context.l10n.commonDetails, style: StreamRow.detail(context)),
                const SizedBox(width: 4),
                StreamChevron(open: _open),
              ],
            ),
          ),
        ),
        ExpandReveal(
          open: _open,
          child: Padding(padding: const EdgeInsets.only(top: 4), child: widget.child),
        ),
      ],
    );
  }
}
