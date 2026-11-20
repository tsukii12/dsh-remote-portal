// Portions derived from Libraries.dev Bot avatars (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

/* The rig. A pose is a handful of numbers — head yaw / pitch / roll, a
   position, squash, how open the eyes are, where they look — and blend
   weights for the three states. A Sim advances a pose through time: each
   state sets targets and wanders around them, runs its own events (a
   flip, a hop, a nod, a blink), and a state change eases from one set of
   targets to the next on a timed curve, so it starts and ends softly. */

import 'dart:math' as math;

import 'bot_avatar_types.dart';

const _states = BotAvatarState.values;

/* the working state's hop: its period, and the height of the spinning one */
const _hopT = 0.68;
const _hopSpinH = 26.0;
/* a flip is that spinning hop on its own: a crouch before it, the hop, and
   the landing's recovery after — measured in hop periods */
const _flipPre = 0.2;

/// The jump's numbers: an idle flip's and a tap's.
class BotAvatarJump {
  const BotAvatarJump({
    this.height = _hopSpinH,
    this.time = _hopT,
    this.stretch = 1,
    this.squash = 1.15,
    this.squashTime = 0.37,
    this.squashEase = BotAvatarSquashEase.pulse,
    this.groundTime = 0.11,
    this.groundEase = BotAvatarSquashEase.pulse,
    this.riseTime = 0.33,
    this.riseEase = BotAvatarSquashEase.pulse,
    this.clickSquashTime = 0.24,
    this.spin = 1,
    this.lean = 6,
    this.every = 8,
    this.land = 0,
  });

  /// How high, in body units (the body is 100 tall).
  final double height;

  /// Seconds in the air.
  final double time;

  /// How much the body stretches in the air, 0–2.
  final double stretch;

  /// How much it squashes on the ground, before take-off and on landing, 0–2.
  final double squash;

  /// Seconds the landing squash takes, contact to recovered.
  final double squashTime;
  final BotAvatarSquashEase squashEase;

  /// Seconds the body holds its deepest squash on the ground.
  final double groundTime;
  final BotAvatarSquashEase groundEase;

  /// Seconds the body takes to rise from its deepest squash back to shape.
  final double riseTime;
  final BotAvatarSquashEase riseEase;

  /// Seconds a tap's jump takes for its crouch and landing squash.
  final double clickSquashTime;

  /// Whole turns in the air.
  final double spin;

  /// Degrees of lean into it.
  final double lean;

  /// Seconds between idle jumps, roughly (±40 %); 0 for none.
  final double every;

  /// When the landing squash begins: seconds before (negative) or after touch-down.
  final double land;
}

/* where in its time each easing reaches the deepest squash */
const _squashPeak = {
  BotAvatarSquashEase.sharp: 0.0,
  BotAvatarSquashEase.pulse: 2 / 7,
  BotAvatarSquashEase.soft: 0.5,
  BotAvatarSquashEase.bouncy: 0.144,
};

/* a tap's jump crouches for its squash time before take-off and lands with a
   squash of the same length; an idle jump's crouch is the working hop's */
double _flipPreOf(BotAvatarJump j, bool poked) => poked ? j.clickSquashTime : _flipPre * j.time;
double _flipDuration(BotAvatarJump j, bool poked) =>
    _flipPreOf(j, poked) +
    j.time +
    _squashPeak[j.squashEase]! * (poked ? j.clickSquashTime : j.squashTime) +
    math.max(0, j.groundTime) +
    j.riseTime +
    math.max(0, j.land) +
    0.05;

/* the rise: how the body comes back from its deepest squash to its own
   shape, 1 → 0 over the rise time */
double _risePulse(double v, BotAvatarSquashEase ease) {
  if (v <= 0) return 1;
  if (v >= 1) return 0;
  switch (ease) {
    case BotAvatarSquashEase.sharp:
      return (1 - v) * (1 - v);
    case BotAvatarSquashEase.soft:
      return 0.5 + 0.5 * math.cos(math.pi * v);
    case BotAvatarSquashEase.bouncy:
      return math.exp(-3.2 * v) * math.cos(5.4 * v) - v * v * v * 0.026;
    case BotAvatarSquashEase.pulse:
      final k = 4.2 * v;
      return (1 + k) * math.exp(-k) - v * v * v * 0.078;
  }
}

/* the weight settling through the hold, as a gain on the deepest squash */
double _groundShape(double v, BotAvatarSquashEase ease) => 1 + 0.25 * _squashPulse(v, ease);

/* the landing squash over its time, 0–1 → its depth, 0–1 at the peak */
double _squashPulse(double u, BotAvatarSquashEase ease) {
  if (u <= 0 || u >= 1) return 0;
  double x;
  switch (ease) {
    case BotAvatarSquashEase.sharp:
      x = (1 - u) * (1 - u);
    case BotAvatarSquashEase.soft:
      x = math.pow(math.sin(math.pi * u), 2).toDouble();
    case BotAvatarSquashEase.bouncy:
      x = (math.exp(-3.15 * u) * math.sin(8.43 * u)) / 0.596;
    case BotAvatarSquashEase.pulse:
      final k = 7 * u;
      x = (k * k * math.exp(2 - k)) / 4;
  }
  final tail = u > 0.85 ? 1 - (u - 0.85) / 0.15 : 1.0;
  return x * tail * tail * (3 - 2 * tail);
}

/* the hop's shaping: squash on the ground, stretch at the top */
double _hopSquash(double a) => math.exp(-math.pow(math.min(a.abs(), (a - 1).abs()) / 0.11, 2));

/// The rig's numbers for one frame.
class BotAvatarPose {
  BotAvatarPose();

  /// radians; yaw > 0 turns the face to the viewer's right, pitch > 0 looks up
  double yaw = 0;
  double pitch = 0;
  double roll = 0;

  /// body-box units (the 100×100 design space)
  double x = 0;
  double y = 0;
  double sx = 1;
  double sy = 1;

  /// 0 shut … 1 open, before blinks
  double eyeOpen = 1;

  /// how far each lid is down right now, 0 … 1
  double blinkL = 0;
  double blinkR = 0;
  double lookX = 0;
  double lookY = 0;

  /// the breathing cycle, −1 … 1
  double breath = 0;

  /// working only: how far the eyes have closed into a laugh, 0 … 1
  double laugh = 0;

  /// the whirl round a spinning body: strength 0 … 1, and where its head is
  double whirl = 0;
  double whirlAngle = 0;

  /// blend weights: idle, working, sleeping — they sum to 1
  final List<double> w = [1, 0, 0];

  /// The still pose of a state, for reduced motion and cached frames.
  factory BotAvatarPose.rest(BotAvatarState state) {
    final r = _rest[state]!;
    final p = BotAvatarPose()
      ..pitch = r.pitch
      ..roll = r.roll
      ..y = r.y
      ..lookX = r.lookX
      ..lookY = r.lookY;
    for (var i = 0; i < 3; i++) {
      p.w[i] = _states[i] == state ? 1 : 0;
    }
    return p;
  }
}

const _deg = math.pi / 180;
const _tau = math.pi * 2;

/* How long a switch takes. Settling down takes longer than getting to work:
   coming back to idle the body has to let go of the hops. */
const _switchTo = {BotAvatarState.idle: 1.2, BotAvatarState.working: 0.7, BotAvatarState.sleeping: 1.4};
const _switchFromSleep = 1.0;

int _imul(int a, int b) => (a * b) & 0xFFFFFFFF;

/// Deterministic per-instance randomness (mulberry32), as the author's.
double Function() mulberry32(int seed) {
  var a = (seed * 0x9e3779b1) & 0xFFFFFFFF;
  if (a == 0) a = 1;
  return () {
    a = (a + 0x6d2b79f5) & 0xFFFFFFFF;
    var t = a;
    t = _imul(t ^ (t >> 15), t | 1);
    t ^= (t + _imul(t ^ (t >> 7), t | 61)) & 0xFFFFFFFF;
    return ((t ^ (t >> 14)) & 0xFFFFFFFF) / 4294967296;
  };
}

/// Exponential approach: `rate` per second, frame-rate independent.
double _approach(double cur, double target, double rate, double dt) =>
    cur + (target - cur) * (1 - math.exp(-rate * dt));

double _easeInOut(double p) => p < 0.5 ? 4 * p * p * p : 1 - math.pow(-2 * p + 2, 3) / 2;
/* gentler at both ends than the cubic: for drifting off and waking */
double _easeSine(double p) => 0.5 - 0.5 * math.cos(math.pi * p);

double _smooth(double a, double b, double v) {
  final x = ((v - a) / (b - a)).clamp(0.0, 1.0);
  return x * x * (3 - 2 * x);
}

/* A value that drifts: picks a new target inside its range every hold and
   moves to it. The head channels move as a lightly damped spring, the eyes
   dart with an exponential approach. */
class _Wander {
  _Wander(this._rand, this.amp, this.holdMin, this.holdMax, this.rate, {this.spring = false});

  final double Function() _rand;
  double amp;
  double holdMin;
  double holdMax;
  double rate;
  final bool spring;
  double value = 0;
  double _vel = 0;
  double _target = 0;
  double _next = 0;

  void update(double t, double dt) {
    if (t >= _next) {
      _target = (_rand() * 2 - 1) * amp;
      _next = t + holdMin + _rand() * (holdMax - holdMin);
    }
    if (spring) {
      final w = rate * 1.6, z = 0.9;
      _vel += (w * w * (_target - value) - 2 * z * w * _vel) * dt;
      value += _vel * dt;
    } else {
      value = _approach(value, _target, rate, dt);
    }
  }

  /// aim at a value and stay there: the rig picks the next one
  void aim(double v) {
    _target = v;
    _next = double.infinity;
  }

  void set(double amp, double holdMin, double holdMax, double rate) {
    this.amp = amp;
    this.holdMin = holdMin;
    this.holdMax = holdMax;
    this.rate = rate;
    _next = 0;
  }
}

/* A one-shot event: progress 0 → 1 over its duration, then idle at -1. */
class _Event {
  _Event(this.duration);

  double duration;
  double p = -1;

  void fire() => p = 0;
  bool get active => p >= 0;

  void update(double dt) {
    if (p < 0) return;
    p += dt / duration;
    if (p >= 1) p = -1;
  }
}

/* The idle gaze: how far the head swings, and how long it stays. */
const _gazeYaw = 35 * _deg;
const _gazePitch = 14 * _deg;
const _gazeRoll = 3.2 * _deg;
const _gazeHoldMin = 2.6;
const _gazeHoldMax = 4.4;

class _Rest {
  const _Rest(this.pitch, this.roll, this.y, this.lookX, this.lookY);
  final double pitch;
  final double roll;
  final double y;
  final double lookX;
  final double lookY;
}

/* Resting targets per state; everything the wanderers and events add sits on
   top of these. */
const _rest = {
  BotAvatarState.idle: _Rest(0, 0, 0, 0, 0),
  BotAvatarState.working: _Rest(5 * _deg, 0, 0, 0, 0),
  BotAvatarState.sleeping: _Rest(-16 * _deg, 6 * _deg, 3, 0, 1),
};

/// Advances a [BotAvatarPose] through time (the author's `Sim`).
class BotAvatarSim {
  BotAvatarSim(double seed, [BotAvatarState state = BotAvatarState.idle])
    : _rand = mulberry32((seed * 1e6).floor() + 1) {
    final r = _rand;
    _yawW = _Wander(r, 36 * _deg, 1.1, 2.6, 3, spring: true);
    _pitchW = _Wander(r, 10 * _deg, 1.1, 2.6, 2.6, spring: true);
    _rollW = _Wander(r, 5 * _deg, 1.6, 3.2, 2, spring: true);
    _lookXW = _Wander(r, 3.6, 0.5, 2, 14);
    _lookYW = _Wander(r, 2.4, 0.5, 2, 14);
    /* every instance starts somewhere else in its loops */
    _t = r() * 10;
    _hopPhase = r();
    _breathPhase = r();
    /* event timers count from that start, so nothing fires on the first tick */
    _blinkAt = _t + 1 + r() * 3;
    _flipAt = _nextFlip(_t, 1);
    _nodAt = _t + 3 + r() * 4;
    _dartAt = _t + 1 + r() * 2;
    _laughAt = _t + 0.6 + r() * 1.5;
    setState(state, immediate: true);
  }

  final BotAvatarPose pose = BotAvatarPose();
  BotAvatarState state = BotAvatarState.idle;

  final double Function() _rand;
  double _t = 0;
  List<double> _wFrom = [1, 0, 0];
  double _tr = 1;
  double _trDuration = 1.2;
  late final _Wander _yawW;
  late final _Wander _pitchW;
  late final _Wander _rollW;
  late final _Wander _lookXW;
  late final _Wander _lookYW;
  final _blink = _Event(0.17);
  double _blinkAt = 0;
  bool _blinkAgain = false;
  final _dart = _Event(0.12);
  double _dartAt = 0;
  double _dartX = 0;
  double _dartY = 0;
  final _flip = _Event(_flipDuration(const BotAvatarJump(), false));
  bool _flipPoked = false;
  BotAvatarJump _jump = const BotAvatarJump();
  double _flipAt = 0;
  double _flipSide = 1;
  final _nod = _Event(1.7);
  double _nodAt = 0;
  double _hopPhase = 0;
  int _hopCount = 0;
  double _hopGain = 0;
  final _laughEv = _Event(0.8);
  double _laughAt = 0;
  double _prevYaw = 0;
  double _jelly = 0;
  double _jellyV = 0;
  double _gazeLead = 0;
  (double, double) _gazeDir = (0, 0);
  double _gazeAt = 0;
  double _turnK = 1;
  double _breathPhase = 0;
  double _baseYaw = 0;

  /// Whether a hop or a flip is under way (a tap's included).
  bool get jumping => _flip.active;

  void setState(BotAvatarState next, {bool immediate = false}) {
    if (next == state && !immediate) return;
    final from = state;
    state = next;
    final w = pose.w;
    if (immediate) {
      for (var i = 0; i < 3; i++) {
        w[i] = _states[i] == next ? 1 : 0;
      }
      _tr = 1;
    } else {
      _wFrom = [w[0], w[1], w[2]];
      _tr = 0;
      _trDuration = from == BotAvatarState.sleeping ? _switchFromSleep : _switchTo[next]!;
    }
    switch (next) {
      case BotAvatarState.idle:
        /* the head holds a place, then swings to the next over about a
           second; the gaze picks where */
        _yawW.set(_gazeYaw, 2.6, 5.4, 2);
        _pitchW.set(_gazePitch, 2.8, 5.8, 1.8);
        _rollW.set(_gazeRoll, 3.4, 6.6, 1.5);
        _gazeAt = 0;
        _gazeDir = (0, 0);
        _lookXW.set(3.6, 0.6, 2.2, 13);
        _lookYW.set(2.4, 0.6, 2.2, 13);
        _flipAt = _nextFlip(_t, 0.6);
      case BotAvatarState.working:
        _yawW.set(16 * _deg, 0.9, 1.8, 4);
        _pitchW.set(3 * _deg, 1.2, 2.4, 3);
        _rollW.set(0, 1, 2, 3);
        _lookXW.set(2, 0.5, 1.2, 12);
        _lookYW.set(1, 0.5, 1.2, 12);
        _hopPhase = 0;
        _hopCount = 0;
        _laughAt = _t + 0.5 + _rand() * 1.2;
      case BotAvatarState.sleeping:
        _yawW.set(7 * _deg, 3, 6, 0.7);
        _pitchW.set(3 * _deg, 3, 6, 0.7);
        _rollW.set(2 * _deg, 3, 6, 0.6);
        _lookXW.set(0, 2, 4, 2);
        _lookYW.set(0, 2, 4, 2);
        _nodAt = _t + 2.5 + _rand() * 4;
    }
  }

  /// A hop and a full turn, right now, whatever the state.
  void poke() {
    if (_flip.active && _flip.p < 0.6) return;
    _flipPoked = true;
    _flip.duration = _flipDuration(_jump, true);
    _flipSide = _rand() < 0.5 ? -1 : 1;
    _flip.fire();
    _flipAt = _nextFlip(_t, 1.1);
  }

  /// How far the head turns to the side while idle: 1 as the gaze has it, 0
  /// keeps it facing forward.
  void setTurn(double k) {
    final next = math.max(0.0, k);
    if (next == _turnK) return;
    _turnK = next;
    if (state == BotAvatarState.idle) _gazeAt = 0;
  }

  /// The jump's numbers.
  void setJump(BotAvatarJump j) {
    final every = _jump.every;
    _jump = j;
    if (j.every != every) _flipAt = _nextFlip(_t, 1);
  }

  /* Where the head looks next: from a corner it mostly swings straight across
     to the opposite one, now and then only sideways, or back to the middle. */
  (double, double) _nextGaze() {
    final r = _rand;
    final (px, py) = _gazeDir;
    if (px != 0 || py != 0) {
      final p = r();
      if (p < 0.66) return (-px, -py);
      if (p < 0.85) return (-px, py);
      return (0, 0);
    }
    const corners = [(1.0, -1.0), (-1.0, 1.0), (-1.0, -1.0), (1.0, 1.0)];
    return corners[(r() * corners.length).floor()];
  }

  /// when the next idle jump is due: `every` seconds, give or take 40 %
  double _nextFlip(double t, double k) {
    final every = _jump.every;
    return every > 0 ? t + every * k * (0.625 + _rand() * 0.75) : double.infinity;
  }

  /// Advance by `dt` seconds (already scaled by the speed).
  void update(double dt) {
    dt = math.min(dt, 0.05);
    _t += dt;
    final t = _t;
    final p = pose;
    final w = p.w;

    /* the state change eases from the weights it started with on an S-curve */
    if (_tr < 1) {
      _tr = math.min(1, _tr + dt / _trDuration);
      final e = _easeSine(_tr);
      for (var i = 0; i < 3; i++) {
        final target = _states[i] == state ? 1.0 : 0.0;
        w[i] = _wFrom[i] + (target - _wFrom[i]) * e;
      }
    }
    final wd = w[0], ww = w[1], ws = w[2];

    /* rest targets, blended */
    var rPitch = 0.0, rRoll = 0.0, rY = 0.0, rLookX = 0.0, rLookY = 0.0;
    for (var i = 0; i < 3; i++) {
      final r = _rest[_states[i]]!;
      rPitch += r.pitch * w[i];
      rRoll += r.roll * w[i];
      rY += r.y * w[i];
      rLookX += r.lookX * w[i];
      rLookY += r.lookY * w[i];
    }

    /* the idle gaze: a place to look, a while to stay, then the swing */
    if (state == BotAvatarState.idle && t >= _gazeAt) {
      final (gx, gy) = _nextGaze();
      _gazeDir = (gx, gy);
      final reach = 0.84 + _rand() * 0.16;
      _yawW.aim(gx * _gazeYaw * reach * _turnK);
      _pitchW.aim(gy * _gazePitch * reach);
      _rollW.aim(gx * _gazeRoll * reach * _turnK);
      _gazeAt = t + _gazeHoldMin + _rand() * (_gazeHoldMax - _gazeHoldMin);
    }

    _yawW.update(t, dt);
    _pitchW.update(t, dt);
    _rollW.update(t, dt);
    _lookXW.update(t, dt);
    _lookYW.update(t, dt);

    /* the base pose: the blended rest plus the smoothed wander (the author's
       pointer following is a mouse feature; on a phone its pull is zero) */
    _baseYaw = _approach(_baseYaw, _yawW.value, 5, dt);
    final basePitch = rPitch + _pitchW.value;
    final baseRoll = rRoll + _rollW.value;
    final baseY = rY;
    final baseLookX = rLookX + _lookXW.value;
    final baseLookY = rLookY + _lookYW.value;

    /* ── events ── */
    var spin = 0.0, hopY = 0.0, sx = 1.0, sy = 1.0, pitchAdd = 0.0, rollAdd = 0.0, blinkClose = 0.0;
    var lookXAdd = 0.0, lookYAdd = 0.0, laugh = 0.0, whirl = 0.0, whirlAngle = 0.0;
    double envelope(double q) => _smooth(0.1, 0.26, q) * (1 - _smooth(0.66, 0.9, q));
    double ringAngle(double q) => _tau * (1.5 * q + 0.9 * _easeInOut(q));

    /* blinks: idle and working blink; a double blink now and then */
    if (t >= _blinkAt && !_blink.active && wd + ww > 0.5) {
      _blink.fire();
      _blinkAgain = !_blinkAgain && _rand() < 0.22;
      _blinkAt = t + (_blinkAgain ? 0.28 : 2.2 + _rand() * 2.6);
    }
    _blink.update(dt);
    if (_blink.active) blinkClose = math.sin(math.pi * _blink.p);

    /* eye darts: a quick glance to the side and back */
    if (t >= _dartAt && !_dart.active && wd + ww > 0.5) {
      _dart.fire();
      _dartX = (_rand() * 2 - 1) * 4;
      _dartY = (_rand() * 2 - 1) * 2;
      _dart.duration = 0.25 + _rand() * 0.45;
      _dartAt = t + 1.2 + _rand() * 2.6;
    }
    _dart.update(dt);
    if (_dart.active) {
      final q = _dart.p;
      final hold = q < 0.15 ? q / 0.15 : (q > 0.8 ? (1 - q) / 0.2 : 1.0);
      lookXAdd += _dartX * hold * (wd + ww);
      lookYAdd += _dartY * hold * (wd + ww);
    }

    /* idle: a full turn now and then, with a jump */
    if (state == BotAvatarState.idle && t >= _flipAt && !_flip.active) {
      _flipPoked = false;
      _flip.duration = _flipDuration(_jump, false);
      _flipSide = _rand() < 0.5 ? -1 : 1;
      _flip.fire();
      _flipAt = _nextFlip(t, 1);
    }
    _flip.update(dt);
    final j = _jump;
    if (_flip.active) {
      final preS = _flipPreOf(j, _flipPoked);
      final a = (_flip.p * _flip.duration - preS) / j.time;
      final q = a.clamp(0.0, 1.0);
      final arc = math.sin(math.pi * q);
      spin += _tau * j.spin * _easeInOut(q);
      hopY -= j.height * arc;
      final tl = (a - 1) * j.time - j.land;
      final squashTime = _flipPoked ? j.clickSquashTime : j.squashTime;
      double crouch(double u) => _flipPoked ? u * u * (3 - 2 * u) : _hopSquash(u - 1);
      final hold = math.max(0.0, j.groundTime);
      final peakT = _squashPeak[j.squashEase]! * squashTime;
      final rise = tl - peakT - hold;
      final depth = tl <= peakT
          ? _squashPulse(tl / squashTime, j.squashEase)
          : (rise <= 0 ? _groundShape((tl - peakT) / hold, j.groundEase) : _risePulse(rise / j.riseTime, j.riseEase));
      final land =
          (a < 0 ? crouch(math.max(0, 1 + (a * j.time) / preS)) : (tl > 0 ? depth : (a < 0.2 ? _hopSquash(a) : 0))) *
          j.squash;
      sx += 0.16 * land - 0.06 * arc * j.stretch;
      sy += -0.18 * land + 0.09 * arc * j.stretch;
      rollAdd += _flipSide * j.lean * _deg * arc;
      if (j.spin > 0) {
        laugh = math.max(laugh, arc);
        whirl = math.max(whirl, envelope(q));
        whirlAngle = ringAngle(q);
      }
    }

    /* working: hops all the time; every third one spins. Leaving the state,
       the hop under way flies its whole arc and lands a jump's landing. */
    final exitHold = math.max(0.0, j.groundTime);
    final exitFor = exitHold + j.riseTime;
    if (state == BotAvatarState.working) _hopGain = ww;
    if (_hopGain > 0.02 && (state == BotAvatarState.working || _hopPhase > 0)) {
      _hopPhase += dt / _hopT;
      if (_hopPhase >= 1) {
        if (state == BotAvatarState.working) {
          _hopPhase -= 1;
          _hopCount += 1;
        } else if ((_hopPhase - 1) * _hopT >= exitFor) {
          _hopPhase = 0;
          _hopGain = 0;
        }
      }
      final g = _hopGain;
      final q = math.min(1.0, _hopPhase);
      final arc = math.sin(math.pi * q);
      final spinning = _hopCount % 3 == 2;
      final h = spinning ? _hopSpinH : 18.0;
      hopY -= h * arc * g;
      final exitT = state != BotAvatarState.working && _hopPhase > 1 ? (_hopPhase - 1) * _hopT : -1.0;
      final land = exitT < 0
          ? _hopSquash(_hopPhase)
          : (exitT < exitHold
                ? _groundShape(exitT / exitHold, j.groundEase)
                : _risePulse((exitT - exitHold) / j.riseTime, j.riseEase));
      sx += (0.16 * land - 0.06 * arc) * g;
      sy += (-0.18 * land + 0.09 * arc) * g;
      if (spinning) {
        spin += _tau * _easeInOut(q) * g;
        laugh = math.max(laugh, arc * g);
        if (envelope(q) * g > whirl) {
          whirl = envelope(q) * g;
          whirlAngle = ringAngle(q);
        }
      }
      rollAdd += (_hopCount % 2 == 0 ? 1 : -1) * 6 * _deg * arc * g;
    }

    /* working: now and then a laugh shuts the eyes into arcs */
    if (state == BotAvatarState.working && t >= _laughAt && !_laughEv.active) {
      _laughEv.fire();
      _laughEv.duration = 0.6 + _rand() * 0.5;
      _laughAt = t + 1.6 + _rand() * 2.2;
    }
    _laughEv.update(dt);
    if (_laughEv.active) {
      final q = _laughEv.p;
      laugh = math.max(laugh, q < 0.18 ? q / 0.18 : (q > 0.78 ? (1 - q) / 0.22 : 1.0));
    }

    /* sleeping: the head drops, then jerks back up */
    if (state == BotAvatarState.sleeping && t >= _nodAt && !_nod.active) {
      _nod.fire();
      _nodAt = t + 4 + _rand() * 4;
    }
    _nod.update(dt);
    if (_nod.active) {
      final q = _nod.p;
      final dip = q < 0.72 ? _easeInOut(q / 0.72) : 1 - _easeInOut((q - 0.72) / 0.28);
      pitchAdd -= 13 * _deg * dip * ws;
    }

    /* breathing, always, deeper and slower asleep */
    _breathPhase += dt / (3.6 + 1.2 * ws);
    final breath = math.sin(_breathPhase * _tau);
    p.breath = breath;
    sx += breath * (0.008 + 0.014 * ws);
    sy += breath * (0.012 + 0.02 * ws);
    final bob = math.sin(t * _tau / 3.4) * 2 * (1 - ws);

    /* ── compose ── */
    p.yaw = _baseYaw + spin;

    /* the jelly: the faster the head turns, the more the body stretches along
       the turn, on a spring that overshoots and settles */
    var dyaw = _baseYaw - _prevYaw;
    dyaw = ((dyaw + math.pi) % _tau + _tau) % _tau - math.pi;
    _prevYaw = _baseYaw;
    final rate = dt > 0 ? dyaw.abs() / dt : 0.0;
    final leadTarget = dt > 0 ? ((dyaw / dt) * 2.4).clamp(-2.2, 2.2) : 0.0;
    _gazeLead = _approach(_gazeLead, leadTarget, 9, dt);
    final jellyTarget = math.min(0.22, 0.055 * rate);
    const omega = 16.0, zeta = 0.45;
    _jellyV += (omega * omega * (jellyTarget - _jelly) - 2 * zeta * omega * _jellyV) * dt;
    _jelly += _jellyV * dt;
    final jelly = _jelly.clamp(-0.08, 0.28) * 0.6;
    sx *= 1 + jelly;
    sy *= 1 - 0.55 * jelly;

    p.pitch = basePitch + pitchAdd;
    p.roll = baseRoll + rollAdd;
    p.x = 0;
    p.y = baseY + hopY + bob;
    p.sx = sx;
    p.sy = sy;
    p.eyeOpen = 1;
    p.laugh = _approach(p.laugh, laugh, 30, dt);
    p.blinkL = blinkClose;
    p.blinkR = blinkClose;
    p.lookX = baseLookX + lookXAdd + _gazeLead;
    p.lookY = baseLookY + lookYAdd;
    p.whirl = whirl;
    p.whirlAngle = whirlAngle;
  }
}
