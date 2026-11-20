// The picture of a custom launch screen, opened while the system's launch picture still shows:
// a still, an animation played once (GIF, animated WebP) or a short silent clip played once.
// Decoded no larger than the screen needs.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'custom_launch.dart';
import 'launch_motion.dart';
import 'launch_video.dart';

/// One custom launch picture, ready to show: its first frame is decoded.
abstract class LaunchMedia extends ChangeNotifier {
  /// Pixel size of the picture as decoded (its aspect is the file's).
  Size get size;

  /// The picture, filling whatever box it is given (the caller sizes it to [size]'s aspect).
  Widget view();

  /// Plays it once from the start (a still has nothing to play); [onDone] when it has
  /// come to rest.
  void play({VoidCallback? onDone});

  /// A still's "round": as long as the default motion, so a cold start shows it as long.
  static const stillRound = LaunchMotion.total;

  /// Opens [custom] for a screen of [screen] physical pixels; null when it can't be read
  /// (missing, damaged, not what it says it is).
  static Future<LaunchMedia?> open(CustomLaunch custom, {required Size screen}) async {
    try {
      return switch (custom.kind) {
        LaunchMediaKind.image || LaunchMediaKind.animation => await _FramesMedia.open(custom, screen),
        LaunchMediaKind.video => await LaunchClip.open(custom),
      };
    } catch (_) {
      return null;
    }
  }

  /// The size to decode a [width] × [height] picture at so it fills or fits [screen] without
  /// waste; never larger than the file.
  static ui.TargetImageSize targetSize(int width, int height, Size screen, LaunchFit fit, {double zoom = 1}) {
    final sx = screen.width / width;
    final sy = screen.height / height;
    final z = fit == LaunchFit.fill ? zoom.clamp(1.0, CustomLaunch.maxZoom) : 1.0;
    final scale = (fit == LaunchFit.fill ? (sx > sy ? sx : sy) : (sx < sy ? sx : sy)) * z;
    if (scale >= 1) return ui.TargetImageSize(width: width, height: height);
    return ui.TargetImageSize(
      width: (width * scale).ceil().clamp(1, width),
      height: (height * scale).ceil().clamp(1, height),
    );
  }
}

/// One still image, given (a settings thumbnail, a test).
class StillLaunchMedia extends LaunchMedia {
  StillLaunchMedia(this.image, {this.owned = true});

  final ui.Image image;

  /// Disposed with this.
  final bool owned;

  @override
  Size get size => Size(image.width.toDouble(), image.height.toDouble());

  @override
  Widget view() => RawImage(image: image, fit: BoxFit.fill, filterQuality: FilterQuality.medium);

  Timer? _timer;

  @override
  void play({VoidCallback? onDone}) {
    _timer?.cancel();
    _timer = Timer(LaunchMedia.stillRound, () => onDone?.call());
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (owned) image.dispose();
    super.dispose();
  }
}

/// A still or an animation, frame by frame through one codec.
class _FramesMedia extends LaunchMedia {
  _FramesMedia(this._codec, this._frame);

  final ui.Codec _codec;
  ui.FrameInfo _frame;
  int _index = 0;
  Timer? _timer;
  bool _playing = false;
  bool _disposed = false;

  static Future<_FramesMedia> open(CustomLaunch custom, Size screen) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(custom.path);
    final codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (w, h) => LaunchMedia.targetSize(w, h, screen, custom.fit, zoom: custom.zoom),
    );
    try {
      final first = await codec.getNextFrame();
      return _FramesMedia(codec, first);
    } catch (_) {
      codec.dispose();
      rethrow;
    }
  }

  @override
  Size get size => Size(_frame.image.width.toDouble(), _frame.image.height.toDouble());

  @override
  Widget view() => ListenableBuilder(
    listenable: this,
    builder: (context, _) => RawImage(image: _frame.image, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
  );

  @override
  void play({VoidCallback? onDone}) {
    if (_playing) return;
    _playing = true;
    if (_codec.frameCount <= 1) {
      _timer = Timer(LaunchMedia.stillRound, () => onDone?.call());
      return;
    }
    _schedule(onDone);
  }

  void _schedule(VoidCallback? onDone) {
    // Browsers' rule: a frame shorter than 20 ms is shown for 100.
    var hold = _frame.duration;
    if (hold < const Duration(milliseconds: 20)) hold = const Duration(milliseconds: 100);
    // One round: the last frame keeps its hold before reporting completion.
    if (_index >= _codec.frameCount - 1) {
      _timer = Timer(hold, () => onDone?.call());
      return;
    }
    final next = _codec.getNextFrame()..ignore();
    _timer = Timer(hold, () async {
      try {
        final frame = await next;
        if (_disposed) {
          frame.image.dispose();
          return;
        }
        final old = _frame;
        _frame = frame;
        _index++;
        notifyListeners();
        old.image.dispose();
        _schedule(onDone);
      } catch (_) {
        // A broken later frame: stay on the last good one.
        onDone?.call();
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _frame.image.dispose();
    _codec.dispose();
    super.dispose();
  }
}
