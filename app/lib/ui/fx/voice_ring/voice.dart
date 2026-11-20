// Portions derived from Libraries.dev Voice ring (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

// The voice follower (voice.ts) and the emotion glow (emotion.ts): turn a
// plain 0–1 level into the shaped, smoothed VoiceInput the ring draws from,
// and ease an emotion's colour in and out. Only the level path is ported —
// the app hands us meter levels, never an analyser — so the bands and the
// spectrum get the author's synthetic life (readLevel).

import 'dart:math' as math;
import 'dart:typed_data';

/// Slots in the log spectrum.
const int spectrumN = 16;

const double _tau = math.pi * 2;

// Processing's turn, radians per ring second, and the fastest it settles home.
const double _spinRate = 2.1;
const double _settleMax = 0.3;
// The lean toward a voice rides a critically damped spring: in about two
// seconds to a side, about three back home.
const double _panIn = 2.5;
const double _panOut = 1.6;
const double _softAttack = 0.35;
const double _softRelease = 0.9;

// The author's analyser path: RMS × this gain, before `sensitivity`.
const double _baseGain = 5;

/// 把 App 里两路电平换回作者算法期待的输入。
///
/// 通话的麦克风和朗读播放都是每 40ms 一个 dBFS 的 RMS，再各自线性映射到 0–1；
/// 作者的跟随器要的是「线性 RMS × 5」（笔记本麦克风正常说话约 0.15–1）。
/// 这里先还原 dBFS，再按作者的增益换算，噪声门和软饱和才落在原来的位置。
abstract final class VoiceRingLevel {
  /// 通话麦克风：`((db + 60) / 50).clamp(0, 1)` 的逆。
  static double mic(double shown) => fromDbfs(shown * 50 - 60);

  /// 朗读播放：`((db + 50) / 40).clamp(0, 1)` 的逆。
  static double playback(double shown) => fromDbfs(shown * 40 - 50);

  /// A dBFS RMS reading as the author's follower reads one.
  static double fromDbfs(double db) => math.pow(10, db / 20) * _baseGain;
}

/// What the voice is doing at one instant, gated, saturated and smoothed.
class VoiceInput {
  /// Loudness envelope, 0–1, with the idle breathing folded in.
  double level = 0;

  /// Low / mid / high envelopes, 0–1.
  final Float64List bands = Float64List(3);

  /// `level` on a slow envelope (~0.35 s up, ~0.9 s down).
  double soft = 0;

  /// `bands` on the same slow envelope.
  final Float64List softBands = Float64List(3);

  /// Log-spaced spectrum envelope, low → high.
  final Float64List spectrum = Float64List(spectrumN);

  /// The voice clock, seconds: runs at 1 + gain × level.
  double drive = 0;

  /// How far into processing, 0–1, eased.
  double processing = 0;

  /// Processing's turn, radians; settles to a whole turn afterwards.
  double spin = 0;

  /// Where the voice comes from, −1 left … 1 right, smoothed.
  double pan = 0;
}

double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

/// Noise gate then soft saturation, so a shout rounds off instead of clipping.
double shapeLevel(double raw, double threshold) {
  if (raw <= threshold) return 0;
  final t = (raw - threshold) / math.max(0.001, 1 - threshold);
  return _clamp01((1 - math.exp(-3 * t)) / (1 - math.exp(-3)));
}

/// One-pole follower: fast up (attack), slow down (release).
double followLevel(double prev, double target, double dt, double attack, double release) {
  final tau = target > prev ? attack : release;
  return prev + (target - prev) * (1 - math.exp(-dt / math.max(0.001, tau)));
}

/// The per-ring follower. It keeps its own clocks, so a paused ring resumes
/// in phase rather than jumping.
class VoiceFollower {
  /// Real seconds this ring has run.
  double clock = 0;

  /// The ambient clock, in ring seconds.
  double t = 0;

  double _drive = 0;
  double _level = 0;
  final Float64List _bands = Float64List(3);
  double _heard = 0;
  double _proc = 0;
  double _spin = 0;
  double _pan = 0;
  double _panVel = 0;
  double _rawLevel = 0;
  final Float64List _rawBands = Float64List(3);
  final Float64List _rawSpectrum = Float64List(spectrumN);

  /// The shaped input, rewritten in place every [step].
  final VoiceInput out = VoiceInput();

  /// Read a plain level. With no spectrum behind it, the bands and slots get
  /// slow out-of-phase drifts and two wandering formant humps, scaled by the
  /// level, so a level-driven ring still moves like a voice.
  void readLevel(double level, double sensitivity) {
    final raw = _clamp01(level) * sensitivity;
    final t = clock;
    _rawLevel = raw;
    _rawBands[0] = raw;
    _rawBands[1] = raw * (0.72 + 0.28 * math.sin(t * 2.3));
    _rawBands[2] = raw * (0.6 + 0.4 * math.sin(t * 3.7 + 2));
    final c1 = 0.28 + 0.1 * math.sin(t * 2.3) + 0.05 * math.sin(t * 5.1);
    final c2 = 0.64 + 0.1 * math.sin(t * 1.7 + 1);
    for (var k = 0; k < spectrumN; k++) {
      final f = k / (spectrumN - 1);
      final hump = math.exp(-(f - c1) * (f - c1) / 0.012) + 0.6 * math.exp(-(f - c2) * (f - c2) / 0.008);
      _rawSpectrum[k] = raw * (0.25 + 0.75 * hump) * (1 - 0.4 * f);
    }
  }

  /// Nothing to read: every envelope settles.
  void readSilence() {
    _rawLevel = 0;
    _rawBands.fillRange(0, 3, 0);
    _rawSpectrum.fillRange(0, spectrumN, 0);
  }

  /// Advance by [dt] real seconds. [still] (reduced motion) holds the clocks.
  VoiceInput step(
    double dt, {
    required double threshold,
    required double attack,
    required double release,
    required double idle,
    required double driveGain,
    required double calm,
    required double rate,
    required bool processing,
    required double direction,
    required bool still,
  }) {
    // processing eases in over ~1 s and out a little slower
    final p = _proc = followLevel(_proc, processing ? 1 : 0, dt, 0.35, 0.5);
    // how awake the ring is: a voice or work brings the clocks up to speed,
    // waiting they idle at `calm`
    final pace = calm + (1 - calm) * math.min(1, math.max(_heard * 2.5, p));
    if (!still) {
      clock += dt;
      t += dt * rate * pace * (1 + 0.5 * p);
    }
    final target = shapeLevel(_rawLevel, threshold);
    _level = followLevel(_level, target, dt, attack, release);
    _heard = followLevel(_heard, _level, dt, _softAttack, _softRelease);
    for (var b = 0; b < 3; b++) {
      _bands[b] = followLevel(_bands[b], shapeLevel(_rawBands[b], threshold * 0.6), dt, attack, release * 1.15);
    }
    final o = out;
    for (var k = 0; k < spectrumN; k++) {
      o.spectrum[k] = followLevel(o.spectrum[k], shapeLevel(_rawSpectrum[k], threshold * 0.6), dt, attack, release);
    }

    // idle breathing folded under the voice, gone while processing
    final breathe = still ? 0.5 : 0.5 + 0.5 * math.sin(_tau * clock / 6);
    final lift = idle * breathe * (1 - p);
    o.level = _level + (1 - _level) * lift;
    for (var b = 0; b < 3; b++) {
      o.bands[b] = _bands[b] + (1 - _bands[b]) * lift * 0.6;
    }
    // the slow envelopes, for shape and amplitude
    o.soft = followLevel(o.soft, o.level, dt, _softAttack, _softRelease);
    for (var b = 0; b < 3; b++) {
      o.softBands[b] = followLevel(o.softBands[b], o.bands[b], dt, _softAttack, _softRelease);
    }
    if (!still) _drive += dt * rate * (pace + driveGain * _level + 1.3 * p);
    o.drive = _drive;
    o.processing = p;
    if (!still) {
      // processing winds the spin up and down; after, it coasts forward to
      // the next whole turn, capped, never winding back
      final home = (_spin / _tau - 1e-6).ceilToDouble() * _tau;
      final settle = math.min(_settleMax, (home - _spin) * 0.6);
      _spin += dt * (_spinRate * rate * p + settle * (1 - p));
    }
    o.spin = _spin;
    // the lean follows the side only while a voice is heard, drifting home
    // after, on a critically damped spring
    final raw = direction.clamp(-1.0, 1.0);
    final goal = _heard > 0.06 && !processing ? raw : 0.0;
    final w = goal.abs() > _pan.abs() ? _panIn : _panOut;
    _panVel += (w * w * (goal - _pan) - 2 * w * _panVel) * dt;
    _pan += _panVel * dt;
    o.pan = _pan;
    return o;
  }
}

/// 情绪：正面绿、负面红、平静蓝（作者的柔和色）。
enum VoiceRingEmotion { positive, negative, calm }

/// An RGB triple, 0–255 per channel, as the author's painters take colours.
class Rgb {
  const Rgb(this.r, this.g, this.b);

  final double r;
  final double g;
  final double b;
}

/// Soft, slightly desaturated hues that sit well beside grey.
const Map<VoiceRingEmotion, Rgb> emotionColors = {
  VoiceRingEmotion.positive: Rgb(92, 224, 150),
  VoiceRingEmotion.negative: Rgb(255, 104, 104),
  VoiceRingEmotion.calm: Rgb(104, 162, 255),
};

const double _glowIn = 0.7;
const double _glowOut = 1.1;
const double _glowShift = 0.6;

/// One ring's eased emotion colour: how present, and which colour it reached.
class GlowFollower {
  double r = 0;
  double g = 0;
  double b = 0;

  /// 0–1: how present the colour is.
  double amount = 0;

  /// Seconds, for anything that turns with the glow.
  double t = 0;

  /// Advance toward [target] (null fades out). [still] jumps straight there.
  void step(double dt, Rgb? target, double t, {required bool still}) {
    double ease(double tau) => still ? 1 : 1 - math.exp(-dt / tau);
    final goal = target == null ? 0.0 : 1.0;
    amount += (goal - amount) * ease(goal > amount ? _glowIn : _glowOut);
    if (target != null) {
      // from nothing the new colour simply appears; otherwise it crossfades
      final k = amount < 0.03 ? 1.0 : ease(_glowShift);
      r += (target.r - r) * k;
      g += (target.g - g) * k;
      b += (target.b - b) * k;
    }
    this.t = t;
  }
}
