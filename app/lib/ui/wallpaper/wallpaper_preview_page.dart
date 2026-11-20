// 设置 › 主题 › 壁纸 › 预览: a conversation on the backdrop in use, over the whole screen, drawn
// with the chat's own materials (chrome glass for the header and the composer, the person's
// bubble, a tool's card, reply text in its three colours). A tap anywhere, or back, closes it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../chat/chat_header.dart' show ChatHeader;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'wallpaper_backdrop.dart';

Future<void> showWallpaperPreview(BuildContext context) => Navigator.of(context).push(
  PageRouteBuilder<void>(
    opaque: true,
    transitionDuration: AppMotion.of(context, AppMotion.standard),
    reverseTransitionDuration: AppMotion.of(context, AppMotion.quick),
    pageBuilder: (context, _, _) => const WallpaperPreviewPage(),
    transitionsBuilder: (context, animation, _, child) => FadeTransition(opacity: animation, child: child),
  ),
);

class WallpaperPreviewPage extends StatelessWidget {
  const WallpaperPreviewPage({super.key});

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: dshSystemOverlay(Theme.of(context).brightness),
    child: WallpaperBackdrop(
      child: GestureDetector(
        key: const ValueKey('wallpaper-preview'),
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(),
        child: const Scaffold(backgroundColor: Colors.transparent, body: WallpaperSampleChat()),
      ),
    ),
  );
}

/// A short conversation laid out as the chat lays out its own: the header's pieces, a question,
/// an answer, the composer.
class WallpaperSampleChat extends StatelessWidget {
  const WallpaperSampleChat({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final surfaces = DshSurfaces.of(context);
    final padding = MediaQuery.paddingOf(context);
    final body = theme.textTheme.bodyLarge?.copyWith(height: 1.6, color: scheme.onSurface);
    return Stack(
      fit: StackFit.expand,
      children: [
        ListView(
          padding: EdgeInsets.fromLTRB(16, ChatHeader.heightOf(context) + 16, 16, padding.bottom + 96),
          children: [
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
                child: DecoratedBox(
                  key: const ValueKey('wallpaper-sample-bubble'),
                  decoration: ShapeDecoration(color: surfaces.userBubble, shape: AppShape.bubble),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: Text(l10n.wallpaperSampleQuestion, style: body?.copyWith(color: surfaces.onUserBubble)),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            // A tool's row, on a card as the chat draws one.
            GlassSurface(
              key: const ValueKey('wallpaper-sample-card'),
              tier: GlassTier.card,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(AppIcons.search, size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.wallpaperSampleTool,
                      key: const ValueKey('wallpaper-sample-tool'),
                      style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Text(l10n.wallpaperSampleAnswer, key: const ValueKey('wallpaper-sample-answer'), style: body),
            const SizedBox(height: 8),
            Text(
              l10n.wallpaperSampleNote,
              key: const ValueKey('wallpaper-sample-note'),
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.6, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            Text(
              l10n.wallpaperSampleStatus,
              key: const ValueKey('wallpaper-sample-meta'),
              style: theme.textTheme.labelSmall?.copyWith(color: colors.textTertiary),
            ),
          ],
        ),
        Positioned(
          left: 12,
          right: 12,
          top: padding.top,
          height: ChatHeader.barHeightOf(context),
          child: BackdropGroup(
            child: Row(
              children: [
                _Key(icon: AppIcons.menu, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Flexible(
                  child: GlassSurface(
                    key: const ValueKey('wallpaper-sample-title'),
                    tier: GlassTier.chrome,
                    stadium: true,
                    grouped: true,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.wallpaperSampleTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(fontSize: 15, height: 1.3),
                        ),
                        Text(
                          l10n.wallpaperPreview,
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 11,
                            height: 1.25,
                            color: colors.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                _Key(icon: AppIcons.add, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: padding.bottom + 12,
          child: GlassSurface(
            key: const ValueKey('wallpaper-sample-composer'),
            tier: GlassTier.chrome,
            stadium: true,
            child: SizedBox(
              height: 52,
              child: Row(
                children: [
                  const SizedBox(width: 20),
                  Expanded(
                    child: Text(
                      l10n.chatComposerHint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(color: colors.textTertiary),
                    ),
                  ),
                  Container(
                    width: 36,
                    height: 36,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                    child: Icon(AppIcons.send, size: 18, color: scheme.onPrimary),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => GlassSurface(
    tier: GlassTier.chrome,
    circle: true,
    grouped: true,
    child: SizedBox.square(dimension: 44, child: Icon(icon, size: 20, color: color)),
  );
}
