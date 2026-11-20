// 设置 › 主题 › 壁纸 › 调整位置: the picture over the whole screen, as the screen will frame it.
// Drag to move it, pinch to zoom (it always covers the screen); 完成 keeps the framing.
//
//   (×)                                  ( 完成 )
//
//               the picture, sharp
//
//              ( 拖动、双指缩放 · 复原 )

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/wallpaper_state.dart';
import '../../wallpaper/custom_wallpaper.dart';
import '../common/pressable.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

Future<void> showWallpaperEditor(BuildContext context, CustomWallpaper wallpaper) => Navigator.of(context).push(
  PageRouteBuilder<void>(
    opaque: true,
    transitionDuration: AppMotion.of(context, AppMotion.standard),
    reverseTransitionDuration: AppMotion.of(context, AppMotion.quick),
    pageBuilder: (context, _, _) => WallpaperEditorPage(wallpaper: wallpaper),
    transitionsBuilder: (context, animation, _, child) => FadeTransition(opacity: animation, child: child),
  ),
);

class WallpaperEditorPage extends ConsumerStatefulWidget {
  const WallpaperEditorPage({super.key, required this.wallpaper});

  final CustomWallpaper wallpaper;

  /// The picture is decoded at most this large on its long side: enough to zoom into.
  static const decodeSide = 2560;

  @override
  ConsumerState<WallpaperEditorPage> createState() => _WallpaperEditorPageState();
}

class _WallpaperEditorPageState extends ConsumerState<WallpaperEditorPage> {
  final _transform = TransformationController();
  ui.Image? _picture;
  bool _failed = false;
  Size? _screen;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _transform.dispose();
    _picture?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    ui.Codec? codec;
    try {
      final buffer = await ui.ImmutableBuffer.fromFilePath(widget.wallpaper.path);
      codec = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: (w, h) {
          final scale = math.min(1.0, WallpaperEditorPage.decodeSide / math.max(w, h));
          return ui.TargetImageSize(width: math.max(1, (w * scale).round()), height: math.max(1, (h * scale).round()));
        },
      );
      final image = (await codec.getNextFrame()).image;
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() => _picture = image);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      codec?.dispose();
    }
  }

  /// The picture laid out covering [screen].
  Size _cover(Size screen) {
    final p = _picture!;
    final scale = math.max(screen.width / p.width, screen.height / p.height);
    return Size(p.width * scale, p.height * scale);
  }

  /// The matrix showing [zoom] at [alignX] / [alignY] in a [screen]-sized view.
  Matrix4 _matrixFor(Size screen, double zoom, double alignX, double alignY) {
    final child = _cover(screen);
    final z = zoom.clamp(1.0, CustomWallpaper.maxZoom);
    final spare = Size(child.width - screen.width / z, child.height - screen.height / z);
    final left = spare.width / 2 * (1 + alignX);
    final top = spare.height / 2 * (1 + alignY);
    return Matrix4.identity()
      ..translateByDouble(-left * z, -top * z, 0, 1)
      ..scaleByDouble(z, z, 1, 1);
  }

  /// The framing the view shows now.
  (double, double, double) _framing(Size screen) {
    final m = _transform.value;
    final z = m.getMaxScaleOnAxis();
    final child = _cover(screen);
    final left = -m.storage[12] / z;
    final top = -m.storage[13] / z;
    final spare = Size(child.width - screen.width / z, child.height - screen.height / z);
    double align(double offset, double room) => room < 0.5 ? 0 : (offset / room * 2 - 1).clamp(-1.0, 1.0);
    return (z, align(left, spare.width), align(top, spare.height));
  }

  Future<void> _done() async {
    final screen = _screen;
    if (_picture == null || screen == null) {
      Navigator.of(context).pop();
      return;
    }
    final (zoom, alignX, alignY) = _framing(screen);
    final navigator = Navigator.of(context);
    await ref.read(customWallpaperProvider.notifier).frame(zoom: zoom, alignX: alignX, alignY: alignY);
    navigator.pop();
  }

  void _reset() {
    final screen = _screen;
    if (screen == null || _picture == null) return;
    HapticFeedback.selectionClick();
    _transform.value = _matrixFor(screen, 1, 0, 0);
  }

  @override
  Widget build(BuildContext context) {
    // A photo's page, as the media viewer's: its keys in the dark theme of the palette in use.
    final surfaces = DshSurfaces.of(context);
    return Theme(
      data: buildDarkTheme(accent: surfaces.accent, glassBlur: surfaces.blurEnabled),
      child: Builder(builder: _page),
    );
  }

  Widget _page(BuildContext context) {
    final l10n = context.l10n;
    final padding = MediaQuery.paddingOf(context);
    final screen = MediaQuery.sizeOf(context);
    final picture = _picture;
    if (picture != null && _screen != screen) {
      // First layout (or the screen turned): the stored framing.
      final w = widget.wallpaper;
      final framing = _screen == null ? (w.zoom, w.alignX, w.alignY) : _framing(_screen!);
      _screen = screen;
      _transform.value = _matrixFor(screen, framing.$1, framing.$2, framing.$3);
    }
    final hint = Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.onSurface);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (picture != null)
              InteractiveViewer(
                key: const ValueKey('wallpaper-editor-view'),
                transformationController: _transform,
                constrained: false,
                minScale: 1,
                maxScale: CustomWallpaper.maxZoom,
                boundaryMargin: EdgeInsets.zero,
                child: SizedBox.fromSize(
                  size: _cover(screen),
                  child: RawImage(image: picture, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
                ),
              )
            else
              Center(
                child: _failed
                    ? Text(l10n.wallpaperUnreadable, style: hint?.copyWith(color: Colors.white))
                    : const SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      ),
              ),
            // A soft shade under the status bar and the keys, so both read on any picture.
            const IgnorePointer(child: _Shade()),
            Positioned(
              left: 12,
              right: 12,
              top: padding.top + 6,
              child: Row(
                children: [
                  _GlassKey(
                    key: const ValueKey('wallpaper-editor-cancel'),
                    tooltip: MaterialLocalizations.of(context).cancelButtonLabel,
                    onTap: () => Navigator.of(context).pop(),
                    child: Icon(AppIcons.close, size: 20, color: Theme.of(context).colorScheme.onSurface),
                  ),
                  const Spacer(),
                  GlassSurface(
                    key: const ValueKey('wallpaper-editor-done'),
                    tier: GlassTier.chrome,
                    stadium: true,
                    onTap: picture == null ? null : () => unawaited(_done()),
                    child: SizedBox(
                      height: 44,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Center(
                          child: Text(
                            l10n.commonDone,
                            style: hint?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (picture != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: padding.bottom + 20,
                child: Center(
                  child: GlassSurface(
                    tier: GlassTier.chrome,
                    stadium: true,
                    child: SizedBox(
                      height: 40,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(width: 18),
                          Text(l10n.wallpaperEditorHint, style: hint),
                          const SizedBox(width: 10),
                          SizedBox(
                            height: 16,
                            child: VerticalDivider(width: 1, color: Theme.of(context).colorScheme.outlineVariant),
                          ),
                          Semantics(
                            button: true,
                            child: Pressable(
                              key: const ValueKey('wallpaper-editor-reset'),
                              onTap: _reset,
                              child: SizedBox(
                                height: 40,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(12, 0, 18, 0),
                                  child: Center(
                                    child: Text(
                                      l10n.wallpaperEditorReset,
                                      style: hint?.copyWith(color: Theme.of(context).colorScheme.primary),
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
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _GlassKey extends StatelessWidget {
  const _GlassKey({super.key, required this.tooltip, required this.onTap, required this.child});

  final String tooltip;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: GlassSurface(
      tier: GlassTier.chrome,
      circle: true,
      onTap: onTap,
      child: SizedBox.square(dimension: 44, child: Center(child: child)),
    ),
  );
}

class _Shade extends StatelessWidget {
  const _Shade();

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    const shade = Color(0x59000000);
    return Column(
      children: [
        Container(
          height: padding.top + 72,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [shade, Color(0x00000000)],
            ),
          ),
        ),
        const Spacer(),
        Container(
          height: padding.bottom + 88,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [shade, Color(0x00000000)],
            ),
          ),
        ),
      ],
    );
  }
}
