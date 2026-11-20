// 设置 › 主题 › 启动画面: the default launch screen or the user's own picture, side by side as
// two small phones; how the picture sits, the colour around it, replace it, preview the launch.
//
//          ╭──────╮    ╭──────╮
//          │  ◖●  │    │ ▒▒▒▒ │      two phones the screen's shape, centred as a pair 12
//          │DSH Go│    │ ▒▒▒▒ │      apart, each a third of the card's inner width; the one
//          ╰──────╯    ╰──────╯      in use ringed in the accent
//            默认         自定义
//   适配方式                    ( 填满 | 居中 )     ┐
//   调整位置                               ›     │
//   背景色                        ◐ ● ○ ●         │ only while the custom one is in use
//   更换图片或视频                         ›     ┘
//   预览                                     ›

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../launch/custom_launch.dart';
import '../../../launch/launch_import.dart';
import '../../../launch/launch_media.dart';
import '../../../launch/launch_motion.dart';
import '../../../state/app_icon_state.dart';
import '../../../state/app_info.dart';
import '../../../state/launch_screen_state.dart';
import '../../common/brief_notice.dart';
import '../../common/expand_reveal.dart';
import '../../common/pressable.dart';
import '../../launch/launch_editor_page.dart';
import '../../launch/launch_overlay.dart';
import '../../launch/launch_preview_page.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../settings_widgets.dart';
import 'app_icon_picker.dart';
import 'appearance_page.dart';

/// The card's rows.
class LaunchScreenSection extends ConsumerStatefulWidget {
  const LaunchScreenSection({super.key});

  @override
  ConsumerState<LaunchScreenSection> createState() => _LaunchScreenSectionState();
}

class _LaunchScreenSectionState extends ConsumerState<LaunchScreenSection> {
  bool _busy = false;

  Future<void> _choose() async {
    if (_busy) return;
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _busy = true);
    LaunchImportProblem? problem;
    try {
      problem = await ref.read(customLaunchProvider.notifier).choose();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    final bytes = ref.read(customLaunchProvider).value?.bytes;
    final text = switch (problem) {
      // Once, as it comes in: how much it takes in the app.
      null => bytes == null ? l10n.launchChanged : l10n.launchChangedSize(launchFileSize(bytes)),
      LaunchImportProblem.cancelled => null,
      LaunchImportProblem.unavailable => l10n.launchUnavailable,
      LaunchImportProblem.tooLarge => l10n.launchTooLarge,
      LaunchImportProblem.overLimit => l10n.launchOverLimit,
      LaunchImportProblem.unsupported => l10n.launchUnsupported,
      LaunchImportProblem.unreadable => l10n.launchUnreadable,
    };
    if (text != null) messenger?.showBriefNotice(text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final custom = ref.watch(customLaunchProvider).value;
    final on = custom != null && custom.on;
    final notifier = ref.read(customLaunchProvider.notifier);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LaunchScreenPicker(
          custom: custom,
          busy: _busy,
          onDefault: () => unawaited(notifier.use(false)),
          onCustom: custom == null
              ? () => unawaited(_choose())
              : !custom.on
              ? () => unawaited(notifier.use(true))
              : custom.fit == LaunchFit.fill
              ? () => unawaited(showLaunchEditor(context, custom))
              : () {},
        ),
        ExpandReveal(
          open: on,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 2,
            children: [
              SettingsSegmentTile<LaunchFit>(
                title: l10n.launchFit,
                segments: [
                  PillSegment(LaunchFit.fill, l10n.launchFitFill),
                  PillSegment(LaunchFit.center, l10n.launchFitCenter),
                ],
                selected: custom?.fit ?? LaunchFit.fill,
                onChanged: (fit) => unawaited(notifier.setFit(fit)),
              ),
              if ((custom?.fit ?? LaunchFit.fill) == LaunchFit.fill)
                SettingsTile(
                  key: const ValueKey('launch-frame'),
                  title: l10n.launchFrame,
                  onTap: custom == null ? null : () => unawaited(showLaunchEditor(context, custom)),
                ),
              SettingsTile(
                title: l10n.launchBackground,
                value: LaunchBackdropSwatches(custom: custom, onChanged: (b) => unawaited(notifier.setBackdrop(b))),
              ),
              SettingsTile(title: l10n.launchReplace, onTap: _busy ? null : () => unawaited(_choose())),
            ],
          ),
        ),
        SettingsTile(
          title: l10n.launchPreview,
          onTap: () => unawaited(showLaunchPreview(context, custom: on ? custom : null)),
        ),
      ],
    );
  }
}

/// 默认 and 自定义 as two small phones, centred as a pair.
class LaunchScreenPicker extends StatelessWidget {
  const LaunchScreenPicker({
    super.key,
    required this.custom,
    required this.onDefault,
    required this.onCustom,
    this.busy = false,
  });

  final CustomLaunch? custom;
  final VoidCallback onDefault;
  final VoidCallback onCustom;

  /// A pick is being read in: the custom phone shows a small ring.
  final bool busy;

  /// Ring stroke and its gap to the phone.
  static const ring = 2.0;
  static const ringGap = 3.0;
  static const room = ring + ringGap;

  /// The phone's corner radius.
  static const radius = 14.0;

  /// A phone's width / height: the screen's own shape, kept within a sensible range.
  static double aspectFor(Size screen) =>
      screen.height <= 0 ? 0.5 : (screen.width / screen.height).clamp(0.45, 0.62).toDouble();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final on = custom != null && custom!.on;
    final aspect = aspectFor(MediaQuery.sizeOf(context));
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PickerGrid.inset - room,
        PickerGrid.inset - room,
        PickerGrid.inset - room,
        PickerGrid.inset,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // A third of the inner width, as the theme-mode phones above.
          final inner = constraints.maxWidth - 2 * room;
          final width = (inner - 2 * PickerGrid.gap) / 3;
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Phone(
                key: const ValueKey('launch-default'),
                label: l10n.launchDefault,
                width: width,
                aspect: aspect,
                selected: !on,
                onTap: onDefault,
                child: const _DefaultMini(),
              ),
              const SizedBox(width: PickerGrid.gap - 2 * room),
              _Phone(
                key: const ValueKey('launch-custom'),
                label: l10n.launchCustom,
                width: width,
                aspect: aspect,
                selected: on,
                onTap: onCustom,
                child: custom == null ? _AddMini(busy: busy) : _CustomMini(custom: custom!, busy: busy),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Phone extends StatelessWidget {
  const _Phone({
    super.key,
    required this.label,
    required this.width,
    required this.aspect,
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final String label;
  final double width;
  final double aspect;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const room = LaunchScreenPicker.room;
    final quick = AppMotion.of(context, AppMotion.quick);
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: label,
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        child: SizedBox(
          width: width + 2 * room,
          child: Column(
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(end: selected ? 1 : 0),
                duration: quick,
                curve: AppMotion.std,
                builder: (context, t, child) => CustomPaint(
                  foregroundPainter: _Ring(scheme.primary.withValues(alpha: t)),
                  child: child,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(room),
                  child: SizedBox(
                    width: width,
                    height: width / aspect,
                    child: ClipRSuperellipse(
                      borderRadius: BorderRadius.circular(LaunchScreenPicker.radius),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          child,
                          DecoratedBox(
                            decoration: ShapeDecoration(
                              shape: RoundedSuperellipseBorder(
                                borderRadius: BorderRadius.circular(LaunchScreenPicker.radius),
                                side: BorderSide(color: scheme.outlineVariant, width: 0.5),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: PickerGrid.labelGap - room),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: AnimatedDefaultTextStyle(
                  duration: quick,
                  style: PickerGrid.labelStyle(context, selected: selected),
                  child: Text(label, textAlign: TextAlign.center, maxLines: 1),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Ring extends CustomPainter {
  _Ring(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (color.a == 0) return;
    const w = LaunchScreenPicker.ring;
    final rect = (Offset.zero & size).deflate(w / 2);
    canvas.drawRSuperellipse(
      RSuperellipse.fromRectAndRadius(
        rect,
        const Radius.circular(LaunchScreenPicker.radius + LaunchScreenPicker.room - w / 2),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_Ring old) => old.color != color;
}

/// The whole screen drawn at its real size, then shrunk into the phone: the miniature is the
/// launch screen itself, not a sketch of it.
class _Screen extends StatelessWidget {
  const _Screen({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(width: screen.width, height: screen.height, child: child),
    );
  }
}

/// The default launch screen at rest, in the system's mode (the launch window follows the
/// system, not the app's own setting).
class _DefaultMini extends ConsumerWidget {
  const _DefaultMini();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final icon = ref.watch(appIconProvider).value;
    return _Screen(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final cover = Rect.fromCenter(
            center: size.center(Offset.zero),
            width: LaunchMotion.iconSize,
            height: LaunchMotion.iconSize,
          );
          final layout = LaunchLayout(cover: cover);
          final settled = layout.settled;
          return ColoredBox(
            color: dark ? LaunchColors.nightTop : LaunchColors.mistTop,
            child: Stack(
              children: [
                Positioned.fromRect(
                  rect: settled,
                  child: AppIconPreview(icon?.current ?? AppIcon.mist, size: settled.width, mask: icon?.mask),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: layout.wordmarkTop,
                  height: layout.wordmarkHeight,
                  child: Center(
                    child: Text(
                      AppInfo.name,
                      maxLines: 1,
                      softWrap: false,
                      textScaler: TextScaler.noScaling,
                      style: AppType.wordmark(
                        size: LaunchMotion.wordmarkSize,
                        color: dark ? LaunchColors.paper : LaunchColors.ink,
                      ).copyWith(height: LaunchMotion.wordmarkLine),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// No picture yet: a quiet phone with the add mark.
class _AddMini extends StatelessWidget {
  const _AddMini({required this.busy});

  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHigh,
      child: Center(
        child: busy
            ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(AppIcons.addImage, size: 24, color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// The user's picture as the launch screen shows it: its fit, its background.
class _CustomMini extends ConsumerWidget {
  const _CustomMini({required this.custom, required this.busy});

  final CustomLaunch custom;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final thumb = ref.watch(launchThumbProvider(custom.poster ?? custom.path));
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        switch (thumb) {
          AsyncData(value: final image?) => _Screen(
            child: CustomLaunchView(custom: custom, media: StillLaunchMedia(image, owned: false), dark: dark),
          ),
          AsyncData() || AsyncError() => ColoredBox(
            color: scheme.surfaceContainerHigh,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  context.l10n.launchBroken,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(color: DshColors.of(context).textTertiary),
                ),
              ),
            ),
          ),
          _ => ColoredBox(color: custom.background(dark: dark)),
        },
        if (busy)
          ColoredBox(
            color: scheme.surface.withValues(alpha: 0.6),
            child: const Center(
              child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          ),
      ],
    );
  }
}

/// The first frame of a picture (or a clip's poster), small enough for the phones.
final launchThumbProvider = FutureProvider.autoDispose.family<ui.Image?, String>((ref, path) async {
  final buffer = await ui.ImmutableBuffer.fromFilePath(path);
  final codec = await ui.instantiateImageCodecWithSize(
    buffer,
    getTargetSize: (w, h) {
      final scale = math.min(1.0, 720 / math.max(w, h));
      return ui.TargetImageSize(width: math.max(1, (w * scale).round()), height: math.max(1, (h * scale).round()));
    },
  );
  try {
    final image = (await codec.getNextFrame()).image;
    if (!ref.mounted) {
      image.dispose();
      return null;
    }
    ref.onDispose(image.dispose);
    return image;
  } finally {
    codec.dispose();
  }
});

/// 自动 · 取自图片 · 白 · 黑, as small discs; the chosen one ringed.
class LaunchBackdropSwatches extends StatelessWidget {
  const LaunchBackdropSwatches({super.key, required this.custom, required this.onChanged});

  final CustomLaunch? custom;
  final ValueChanged<LaunchBackdrop> onChanged;

  static const disc = 22.0;
  static const gap = 10.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final custom = this.custom;
    final chosen = custom?.backdrop ?? LaunchBackdrop.auto;
    // 取自图片 without a colour to take is 自动.
    final effective = chosen == LaunchBackdrop.edge && custom?.edge == null ? LaunchBackdrop.auto : chosen;
    final choices = [
      (LaunchBackdrop.auto, l10n.launchBackdropAuto),
      if (custom?.edge != null) (LaunchBackdrop.edge, l10n.launchBackdropEdge),
      (LaunchBackdrop.white, l10n.launchBackdropWhite),
      (LaunchBackdrop.black, l10n.launchBackdropBlack),
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: gap,
      children: [
        for (final (backdrop, label) in choices)
          _Swatch(
            key: ValueKey('launch-backdrop-${backdrop.name}'),
            backdrop: backdrop,
            edge: custom?.edge,
            label: label,
            selected: effective == backdrop,
            onTap: () => onChanged(backdrop),
          ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    super.key,
    required this.backdrop,
    required this.edge,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final LaunchBackdrop backdrop;
  final int? edge;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const d = LaunchBackdropSwatches.disc;
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: label,
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        child: SizedBox.square(
          dimension: d + 8,
          child: CustomPaint(
            painter: _SwatchPainter(
              backdrop: backdrop,
              edge: edge,
              ring: selected ? scheme.primary : null,
              hairline: scheme.outlineVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _SwatchPainter extends CustomPainter {
  _SwatchPainter({required this.backdrop, required this.edge, required this.ring, required this.hairline});

  final LaunchBackdrop backdrop;
  final int? edge;
  final Color? ring;
  final Color hairline;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    const r = LaunchBackdropSwatches.disc / 2;
    final disc = Rect.fromCircle(center: c, radius: r);
    switch (backdrop) {
      case LaunchBackdrop.auto:
        // Light and dark halves: it follows the system.
        canvas
          ..drawArc(disc, math.pi / 2, math.pi, true, Paint()..color = LaunchColors.mistTop)
          ..drawArc(disc, -math.pi / 2, math.pi, true, Paint()..color = LaunchColors.nightTop);
      case LaunchBackdrop.edge:
        canvas.drawCircle(c, r, Paint()..color = Color(edge ?? 0xFF808080));
      case LaunchBackdrop.white:
        canvas.drawCircle(c, r, Paint()..color = const Color(0xFFFFFFFF));
      case LaunchBackdrop.black:
        canvas.drawCircle(c, r, Paint()..color = const Color(0xFF000000));
    }
    canvas.drawCircle(
      c,
      r - 0.25,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..color = hairline,
    );
    if (ring case final ring?) {
      canvas.drawCircle(
        c,
        r + 3,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = ring,
      );
    }
  }

  @override
  bool shouldRepaint(_SwatchPainter old) =>
      old.backdrop != backdrop || old.edge != edge || old.ring != ring || old.hairline != hairline;
}

/// A file's size for people: 860 KB, 12.4 MB.
String launchFileSize(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
  final mb = bytes / (1024 * 1024);
  return '${mb >= 10 ? mb.round() : mb.toStringAsFixed(1)} MB';
}
