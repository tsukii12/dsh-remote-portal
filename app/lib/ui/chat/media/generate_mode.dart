// Generation mode on the composer (docs/design/media-generation.md §4.2): the
// mode capsule on the composer's top-left edge — where the permission pill
// sits, and beside it (as a 34 round ⚠) when both show — and the 首帧 / 尾帧
// labels on a video's reference pictures.
//
// ```
//  ╭──────────────────────────╮
//  │ ◧  视频 · 5 秒 · 720p  × │   34 high, 12 in on both sides
//  ╰──────────────────────────╯
//  ╭────────────────────────────────────╮
//  │ (＋)  描述画面和镜头…          (↑) │
//  ╰────────────────────────────────────╯
// ```

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../state/media_generation.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import 'media_format.dart';

/// The capsule's measured geometry; `test/media/generate_mode_test.dart`.
abstract final class GenerateCapsuleMetrics {
  /// As high as the plugin capsules beside it.
  static const height = 34.0;

  /// Capsule edge → the type icon, and → the ×'s circle.
  static const inset = 12.0;
  static const icon = 16.0;

  /// Permission ⚠ → capsule.
  static const gap = 8.0;
}

/// 「图像 · 3:4 · 2 张」: what the capsule says (no model: it lives in the
/// sheet).
String generateSummary(GenerateParams params) => mediaParamsLine(
  video: params.isVideo,
  aspect: params.aspect,
  count: params.count,
  seconds: params.seconds,
  resolution: params.resolution,
);

/// The mode capsule: a tap opens the parameter sheet, × leaves the mode.
class GenerateCapsule extends StatelessWidget {
  const GenerateCapsule({super.key, required this.params, required this.onTap, required this.onExit});

  final GenerateParams params;
  final VoidCallback onTap;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final fg = theme.colorScheme.onSurface;
    final summary = generateSummary(params);
    const inset = GenerateCapsuleMetrics.inset;
    return GlassSurface(
      tier: GlassTier.chrome,
      borderRadius: BorderRadius.circular(GenerateCapsuleMetrics.height / 2),
      child: Material(
        type: MaterialType.transparency,
        clipBehavior: Clip.antiAlias,
        shape: const StadiumBorder(),
        child: SizedBox(
          height: GenerateCapsuleMetrics.height,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Semantics(
                  button: true,
                  label: l10n.mediaModeLabel(summary),
                  excludeSemantics: true,
                  child: InkWell(
                    onTap: onTap,
                    child: Padding(
                      padding: const EdgeInsets.only(left: inset),
                      child: SizedBox(
                        height: GenerateCapsuleMetrics.height,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              params.isVideo ? AppIcons.generateVideo : AppIcons.generateImage,
                              size: GenerateCapsuleMetrics.icon,
                              color: fg,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                summary,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                softWrap: false,
                                style: AppType.tabular(theme.textTheme.labelMedium!.copyWith(color: fg)),
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Semantics(
                button: true,
                label: l10n.mediaModeExit,
                excludeSemantics: true,
                child: InkWell(
                  onTap: onExit,
                  child: Padding(
                    padding: const EdgeInsets.only(right: inset),
                    child: SizedBox(
                      height: GenerateCapsuleMetrics.height,
                      child: Center(
                        child: Container(
                          key: const ValueKey('generate-exit'),
                          width: GenerateCapsuleMetrics.icon,
                          height: GenerateCapsuleMetrics.icon,
                          decoration: BoxDecoration(color: fg.withValues(alpha: 0.10), shape: BoxShape.circle),
                          child: Icon(AppIcons.close, size: 12, color: fg),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「首帧」 / 「尾帧」 on a reference picture: a small label, radius 8, 6 in
/// from the bottom-left corner. [dimmed]: the model takes no such frame.
class FrameLabel extends StatelessWidget {
  const FrameLabel({super.key, required this.text, this.dimmed = false});

  final String text;
  final bool dimmed;

  static const inset = 6.0;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall!.copyWith(color: Colors.white, fontSize: 10.5, height: 1.2);
    return Opacity(
      opacity: dimmed ? 0.45 : 1,
      child: Container(
        height: 18,
        padding: const EdgeInsets.symmetric(horizontal: 5),
        alignment: Alignment.center,
        decoration: ShapeDecoration(color: Colors.black.withValues(alpha: 0.6), shape: Squircle.border(8)),
        child: Text(text, maxLines: 1, style: style),
      ),
    );
  }
}

/// The labels a video's tray shows, by position: 首帧, 尾帧, then none.
List<FrameLabel?> frameLabels(GenerateParams? params, MediaModel? model, int count) {
  if (params == null || !params.isVideo) return List.filled(count, null);
  return [
    for (var i = 0; i < count; i++)
      switch (i) {
        0 => FrameLabel(text: appL10n.mediaFirstFrame),
        1 => FrameLabel(text: appL10n.mediaLastFrame, dimmed: model != null && !model.lastFrame),
        _ => null,
      },
  ];
}
