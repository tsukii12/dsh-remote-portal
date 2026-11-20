import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// A full-resolution picture, optionally read only when its page is built.
@immutable
class ViewerImage {
  const ViewerImage({required this.name, required ImageProvider this.image, this.heroTag}) : load = null;

  const ViewerImage.lazy({required this.name, required Future<ImageProvider> Function() this.load, this.heroTag})
    : image = null;

  final String name;
  final ImageProvider? image;
  final Future<ImageProvider> Function()? load;
  final Object? heroTag;
}

/// A gallery's gesture layer. Each page starts fitted; enlarged pictures pan
/// instead of turning pages. The caller owns loading, errors and the chrome.
class ImagePager extends StatefulWidget {
  const ImagePager({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.initialPage = 0,
    this.onPageChanged,
    this.onTap,
    this.onLongPress,
    this.tapWhenZoomed = false,
  }) : assert(itemCount > 0);

  final int itemCount;
  final int initialPage;
  final IndexedWidgetBuilder itemBuilder;
  final ValueChanged<int>? onPageChanged;
  final VoidCallback? onTap;
  final ValueChanged<int>? onLongPress;
  final bool tapWhenZoomed;

  @override
  State<ImagePager> createState() => _ImagePagerState();
}

class _ImagePagerState extends State<ImagePager> {
  late int _index = widget.initialPage.clamp(0, widget.itemCount - 1);
  late final _pages = PageController(initialPage: _index);
  bool _zoomed = false;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PageView.builder(
    controller: _pages,
    physics: _zoomed ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
    itemCount: widget.itemCount,
    onPageChanged: (index) {
      setState(() {
        _index = index;
        _zoomed = false;
      });
      widget.onPageChanged?.call(index);
    },
    itemBuilder: (context, index) => ZoomableImage(
      // A page becoming inactive also forgets its previous transform.
      key: ValueKey((index, index == _index)),
      onTap: widget.onTap,
      tapWhenZoomed: widget.tapWhenZoomed,
      onLongPress: widget.onLongPress == null ? null : () => widget.onLongPress!(index),
      onZoomChanged: (zoomed) {
        if (index == _index && zoomed != _zoomed) setState(() => _zoomed = zoomed);
      },
      child: widget.itemBuilder(context, index),
    ),
  );
}

/// Pinch to 8x, double-tap around the touched point to 2.5x and back.
/// The transform is bounded by the viewport, including while pinching back.
class ZoomableImage extends StatefulWidget {
  const ZoomableImage({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onZoomChanged,
    this.tapWhenZoomed = false,
  });

  static const maxScale = 8.0;
  static const doubleTapScale = 2.5;

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final ValueChanged<bool>? onZoomChanged;
  final bool tapWhenZoomed;

  @override
  State<ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<ZoomableImage> {
  double _scale = 1;
  Offset _offset = Offset.zero;
  double _startScale = 1;
  Offset _sceneFocalPoint = Offset.zero;
  Offset _doubleTap = Offset.zero;
  Size _size = Size.zero;

  bool get _zoomed => _scale > 1.01;

  Offset _bounded(Offset offset, double scale) =>
      Offset(offset.dx.clamp(-_size.width * (scale - 1), 0.0), offset.dy.clamp(-_size.height * (scale - 1), 0.0));

  void _setTransform(double scale, Offset offset) {
    final wasZoomed = _zoomed;
    setState(() {
      _scale = scale;
      _offset = _bounded(offset, scale);
    });
    if (_zoomed != wasZoomed) widget.onZoomChanged?.call(_zoomed);
  }

  void _start(ScaleStartDetails details) {
    _startScale = _scale;
    _sceneFocalPoint = (details.localFocalPoint - _offset) / _scale;
  }

  void _update(ScaleUpdateDetails details) {
    final scale = (_startScale * details.scale).clamp(1.0, ZoomableImage.maxScale);
    _setTransform(scale, details.localFocalPoint - _sceneFocalPoint * scale);
  }

  void _toggleZoom() {
    final scale = _zoomed ? 1.0 : ZoomableImage.doubleTapScale;
    _setTransform(scale, _zoomed ? Offset.zero : _doubleTap * (1 - scale));
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _size = constraints.biggest;
      // Rotation/resizing must not leave the picture outside the new viewport.
      _offset = _bounded(_offset, _scale);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _zoomed && !widget.tapWhenZoomed ? null : widget.onTap,
        onLongPress: widget.onLongPress,
        onDoubleTapDown: (details) => _doubleTap = details.localPosition,
        onDoubleTap: _toggleZoom,
        child: RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: {
            _ImageScaleGestureRecognizer: GestureRecognizerFactoryWithHandlers<_ImageScaleGestureRecognizer>(
              () => _ImageScaleGestureRecognizer(debugOwner: this),
              (recognizer) {
                recognizer
                  ..canPan = (() => _zoomed)
                  ..onStart = _start
                  ..onUpdate = _update;
              },
            ),
          },
          child: ClipRect(
            child: Transform(
              alignment: Alignment.topLeft,
              transform: Matrix4.identity()
                ..translateByDouble(_offset.dx, _offset.dy, 0, 1)
                ..scaleByDouble(_scale, _scale, 1, 1),
              child: SizedBox.expand(child: widget.child),
            ),
          ),
        ),
      );
    },
  );
}

/// Unlike a normal scale recognizer, a fitted image does not claim a one-finger
/// drag before PageView can see it. Two fingers claim both arenas immediately,
/// so a pinch cannot accidentally start a page turn.
class _ImageScaleGestureRecognizer extends ScaleGestureRecognizer {
  _ImageScaleGestureRecognizer({super.debugOwner});

  bool Function() canPan = () => false;

  @override
  void resolve(GestureDisposition disposition) {
    if (disposition == GestureDisposition.accepted && pointerCount < 2 && !canPan()) return;
    super.resolve(disposition);
  }

  @override
  void handleEvent(PointerEvent event) {
    super.handleEvent(event);
    if (event is PointerDownEvent && pointerCount > 1) resolve(GestureDisposition.accepted);
  }
}
