// Reproduces the image-viewer test with its first real decode still pending.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool_images_test.dart' as original;

class _PendingDecodeBinding extends AutomatedTestWidgetsFlutterBinding {
  final _gate = Completer<void>();
  // Native decoding lives outside the test fake clock. Keep the gate there too.
  final _realZone = Zone.current;
  bool _decoding = false;

  void release(String reason) {
    if (!_decoding || _gate.isCompleted) return;
    // ignore: avoid_print
    print('First image decode released by $reason');
    _gate.complete();
  }

  @override
  ImageCache createImageCache() => _WaitingImageCache(() => release('explicit image-stream wait'));

  @override
  Future<ui.Codec> instantiateImageCodecWithSize(
    ui.ImmutableBuffer buffer, {
    ui.TargetImageSizeCallback? getTargetSize,
  }) => _realZone.run(() async {
    if (!_decoding) {
      _decoding = true;
      await _gate.future;
    }
    return super.instantiateImageCodecWithSize(buffer, getTargetSize: getTargetSize);
  });

  @override
  void handlePointerEvent(PointerEvent event) {
    super.handlePointerEvent(event);
    // The old test taps the existing Image before its frame is decoded.
    // Complete after dispatch so the held real decoder does not leak.
    if (event is PointerUpEvent) release('tap while decode was pending');
  }
}

class _WaitingImageCache extends ImageCache {
  _WaitingImageCache(this.onWait);
  final void Function() onWait;
  final _seen = <Object>{};

  @override
  ImageStreamCompleter? putIfAbsent(Object key, ImageStreamCompleter Function() loader, {ImageErrorListener? onError}) {
    final result = super.putIfAbsent(key, loader, onError: onError);
    if (key is ResizeImageKey && !_seen.add(key)) onWait();
    return result;
  }
}

void main() {
  final binding = _PendingDecodeBinding();
  tearDown(() => binding.release('test cleanup'));
  original.main();
}
