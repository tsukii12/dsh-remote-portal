// Small parts every workshop page shares: the item's square, the capsule at
// the end of a row, and the quiet line that says something went wrong without
// taking the page over.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/workshop_dependencies.dart';
import '../../workshop/workshop_models.dart';
import '../plugins/plugin_widgets.dart' show PluginAvatar;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'workshop_text.dart';

/// The item's square, app-store style, for when there is no picture: the
/// title's first letter on a tint the item keeps.
class WorkshopAvatar extends StatelessWidget {
  const WorkshopAvatar(this.metadata, {super.key, this.size = 40});

  final WorkshopMetadata metadata;
  final double size;

  @override
  Widget build(BuildContext context) => PluginAvatar(
    name: metadata.identity,
    title: workshopTitleOf(metadata, Localizations.localeOf(context).languageCode),
    size: size,
  );
}

/// Where [entry]'s public picture is, or null when it has none (or the
/// workshop is not ready to say). The address is the data layer's: the same
/// origin the package itself is fetched from, never one a page puts together.
Uri? workshopPreviewUri(WidgetRef ref, WorkshopEntry entry) {
  if (entry.preview == null) return null;
  return switch (ref.watch(workshopClientProvider)) {
    AsyncData(:final value) => value.publicPreviewUri(entry),
    _ => null,
  };
}

/// The picture itself. Pixel pets are drawn with hard edges; a companion's
/// cover is smoothed. While it loads, and if it cannot be had, [fallback]
/// stays: a missing picture says nothing about the package.
class WorkshopPreviewImage extends StatelessWidget {
  const WorkshopPreviewImage({
    super.key,
    required this.uri,
    required this.kind,
    required this.fallback,
    this.fit = BoxFit.contain,
    this.cacheExtent,
  });

  final Uri uri;
  final String kind;
  final Widget fallback;
  final BoxFit fit;

  /// The longest side to decode to, in physical pixels. Not used for pixel
  /// pets: resampling would blur them.
  final int? cacheExtent;

  @override
  Widget build(BuildContext context) {
    final pixel = kind == 'pet';
    return Image.network(
      uri.toString(),
      fit: fit,
      filterQuality: pixel ? FilterQuality.none : FilterQuality.medium,
      cacheWidth: pixel ? null : cacheExtent,
      gaplessPlayback: true,
      excludeFromSemantics: true,
      frameBuilder: (context, child, frame, synchronous) => frame == null && !synchronous ? fallback : child,
      errorBuilder: (context, error, stack) => fallback,
    );
  }
}

/// The item's square with its public picture when the workshop has one for
/// this release, and the letter square otherwise.
class WorkshopEntryAvatar extends ConsumerWidget {
  const WorkshopEntryAvatar(this.entry, {super.key, this.size = 40});

  final WorkshopEntry entry;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final letter = WorkshopAvatar(entry.metadata, size: size);
    final uri = workshopPreviewUri(ref, entry);
    if (uri == null) return letter;
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: scheme.onSurface.withValues(alpha: 0.05),
          shape: Squircle.border(size * 0.25),
        ),
        child: ClipPath(
          clipper: ShapeBorderClipper(shape: Squircle.border(size * 0.25)),
          child: WorkshopPreviewImage(
            uri: uri,
            kind: entry.metadata.kind,
            fallback: letter,
            fit: entry.metadata.kind == 'pet' ? BoxFit.contain : BoxFit.cover,
            cacheExtent: (size * MediaQuery.devicePixelRatioOf(context)).ceil(),
          ),
        ),
      ),
    );
  }
}

/// The picture at a size it can be judged by, in the item's detail. Nothing
/// at all when the release has no picture or it cannot be shown.
class WorkshopPreviewPanel extends ConsumerWidget {
  const WorkshopPreviewPanel(this.entry, {super.key, this.height = 176});

  final WorkshopEntry entry;
  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uri = workshopPreviewUri(ref, entry);
    if (uri == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: scheme.onSurface.withValues(alpha: 0.04),
            shape: Squircle.border(AppShape.radiusLg.topLeft.x),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: WorkshopPreviewImage(
              uri: uri,
              kind: entry.metadata.kind,
              // Not an empty frame: the same square the list shows, larger.
              fallback: Center(child: WorkshopAvatar(entry.metadata, size: 72)),
              cacheExtent: (height * MediaQuery.devicePixelRatioOf(context)).ceil(),
            ),
          ),
        ),
      ),
    );
  }
}

/// What the capsule at the end of a row offers.
enum WorkshopGetState { get, update, installed, running }

/// 获取 / 更新 / 已安装, or a small ring while this item is being installed.
/// Every state opens the detail sheet; installing always goes through it.
class WorkshopGetButton extends StatelessWidget {
  const WorkshopGetButton({super.key, required this.state, this.onPressed});

  final WorkshopGetState state;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final dark = theme.brightness == Brightness.dark;
    final installed = state == WorkshopGetState.installed;
    final running = state == WorkshopGetState.running;
    final track = dark ? Colors.white.withValues(alpha: 0.09) : scheme.onSurface.withValues(alpha: 0.06);
    final fg = installed ? colors.textTertiary : scheme.primary;
    final label = switch (state) {
      WorkshopGetState.get => l10n.workshopGet,
      WorkshopGetState.update => l10n.commonUpdate,
      WorkshopGetState.installed => l10n.commonInstalled,
      WorkshopGetState.running => l10n.pluginsInstalling,
    };
    return FilledButton.tonal(
      style: FilledButton.styleFrom(
        backgroundColor: installed ? Colors.transparent : track,
        foregroundColor: fg,
        minimumSize: const Size(68, 30),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        shape: const StadiumBorder(),
        elevation: 0,
        textStyle: theme.textTheme.labelLarge?.copyWith(fontSize: 13.5),
      ),
      onPressed: onPressed,
      child: AnimatedSwitcher(
        duration: AppMotion.of(context, AppMotion.quick),
        child: Row(
          key: ValueKey(label),
          mainAxisSize: MainAxisSize.min,
          children: [
            if (running) ...[
              SizedBox.square(
                dimension: 12,
                child: CircularProgressIndicator(strokeWidth: 1.8, strokeCap: StrokeCap.round, color: fg),
              ),
              const SizedBox(width: 6),
            ],
            Text(label),
          ],
        ),
      ),
    );
  }
}

/// How loud a [WorkshopNote] is.
enum WorkshopNoteTone { quiet, warning, danger }

/// One or two lines beside a small mark: a refresh that failed, a version
/// that was withdrawn. It sits in the page's flow and leaves the content up.
class WorkshopNote extends StatelessWidget {
  const WorkshopNote(
    this.text, {
    super.key,
    this.tone = WorkshopNoteTone.quiet,
    this.actionLabel,
    this.onAction,
    this.padding = const EdgeInsets.fromLTRB(24, 0, 16, 12),
  });

  final String text;
  final WorkshopNoteTone tone;
  final String? actionLabel;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final color = switch (tone) {
      WorkshopNoteTone.quiet => colors.textTertiary,
      WorkshopNoteTone.warning => colors.warning,
      WorkshopNoteTone.danger => colors.danger,
    };
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(tone == WorkshopNoteTone.quiet ? AppIcons.info : AppIcons.warning, size: 16, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: tone == WorkshopNoteTone.quiet ? colors.textTertiary : theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(width: 4),
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                minimumSize: const Size(44, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed: onAction,
              child: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}
