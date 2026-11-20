// Portions derived from Libraries.dev Image (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:async';

import 'package:flutter/painting.dart';

import 'reveal.dart';

/// 占位卡片的阶段（原库 `onCycle` 的 phase）：`idle` 只有马赛克（或再生成的翻涌），
/// `reveal` 正在溶解出图，`visible` 图完整显示，`hide` 图淡回马赛克。
enum ImageGenerationPhase { idle, reveal, visible, hide }

/// cycle.ts `createCycle`, the paths a card driven by its image uses:
/// `triggerOnce({hold: 'manual'})`, `triggerHide`, `triggerBoil`. The auto
/// loop (`autoReveal`, delays, hold timers) is left out.
class FxCycle {
  FxCycle({required this.reveal, required this.load, required this.onPhase, this.onError, this.fadeOutMs = 300});

  final FxReveal reveal;

  /// `loadImage`: decodes a picture; the reveal owns what it returns.
  final Future<RevealImage> Function(ImageProvider src) load;
  final void Function(ImageGenerationPhase phase, ImageProvider? src) onPhase;
  final void Function(Object error, StackTrace? stack)? onError;

  /// Cross-fade back to the mosaic, ms (`revealFadeOutMs`).
  final double fadeOutMs;

  ImageGenerationPhase phase = ImageGenerationPhase.idle;

  /// The picture being loaded, revealed or shown.
  ImageProvider? currentSrc;

  Timer? _timer;
  bool _running = false;
  bool _disposed = false;

  void _emit(ImageGenerationPhase p) {
    phase = p;
    onPhase(p, currentSrc);
  }

  void _clearTimer() {
    _timer?.cancel();
    _timer = null;
  }

  /// A picture is being handed to the churn (BLEND → RESOLVE).
  bool get _handingOff => phase == ImageGenerationPhase.reveal && reveal.phase == RevealPhase.boil;

  /// Reveal [src] and keep it until [triggerHide] or [triggerBoil]. No-op
  /// while a reveal, hold or hide runs, except that a newer picture replaces
  /// one still being handed to the churn; over a boil the image dissolves in
  /// over the churn.
  void triggerOnce(ImageProvider src) {
    if (phase != ImageGenerationPhase.idle && !_handingOff) return;
    _clearTimer();
    _running = true;
    currentSrc = src;
    load(src).then(
      (img) {
        // Stopped, or another picture was asked for while this one decoded.
        if (_disposed || !_running || currentSrc != src) {
          img.dispose();
          return;
        }
        reveal.startReveal(img, () {
          if (!_running) return;
          _emit(ImageGenerationPhase.visible);
          _clearTimer();
        });
        _emit(ImageGenerationPhase.reveal);
      },
      onError: (Object error, StackTrace stack) {
        if (_disposed || currentSrc != src) return;
        currentSrc = null;
        _running = false;
        onError?.call(error, stack);
      },
    );
  }

  /// Forget a reveal that hasn't shown yet: a picture still decoding, or one
  /// handed to the churn. A churn keeps churning.
  void cancel() {
    currentSrc = null;
    _running = false;
    if (_handingOff) {
      reveal.dropPending();
      _emit(ImageGenerationPhase.idle);
    }
  }

  /// Fade the shown picture, or the churn, back to the mosaic; a picture
  /// still decoding is dropped. No-op otherwise.
  void triggerHide() {
    if (phase != ImageGenerationPhase.reveal &&
        phase != ImageGenerationPhase.visible &&
        reveal.phase != RevealPhase.boil) {
      return;
    }
    _running = false;
    _emit(ImageGenerationPhase.hide);
    reveal.startHide(fadeOutMs);
    _clearTimer();
    _timer = Timer(Duration(microseconds: (fadeOutMs * 1000).round()), () {
      _timer = null;
      currentSrc = null;
      _emit(ImageGenerationPhase.idle);
    });
  }

  /// Break the shown picture into the churn (`startBoil`) and come to a
  /// stopped idle, so a later [triggerOnce] reveals the next one over it.
  void triggerBoil() {
    if (phase != ImageGenerationPhase.reveal && phase != ImageGenerationPhase.visible) return;
    _clearTimer();
    reveal.startBoil();
    currentSrc = null;
    _running = false;
    _emit(ImageGenerationPhase.idle);
  }

  /// Drop everything at once.
  void stop() {
    _running = false;
    _clearTimer();
    reveal.clear();
    currentSrc = null;
    phase = ImageGenerationPhase.idle;
  }

  void dispose() {
    _disposed = true;
    _running = false;
    _clearTimer();
  }
}
