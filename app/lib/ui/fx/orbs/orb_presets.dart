// Portions derived from Libraries.dev Thinking orbs (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

// The shipped tunings, translated from thinking-orbs `src/presets.ts` and
// `src/engine/profiles.ts`: nine states x two sizes, baked by the author from
// the inkform mini-page tuning session. `count`/`size` are multipliers over
// the base "fine" profiles; `speed` multiplies the shared clock. Resolved once
// per (state, size) pair and cached, so the render loop sees plain numbers.

import 'dart:math' as math;

import 'orb_core.dart';

/// 光球在做什么。九种状态各是一套独立的动画,不是同一个的变体。
enum OrbState {
  /// 倾斜轨道上跑的粒子:泛指干活、工具在跑。
  working(OrbMode.orbits),

  /// 扫描经线扫过点阵地球:搜索、检索、查找。
  searching(OrbMode.globe),

  /// 几条环带按四分之一圈打乱再拧回原样:跑代码、算题、调试。
  solving(OrbMode.rubik),

  /// 波形滚过一圈圈纬线:麦克风开着、听写、语音。
  listening(OrbMode.wave),

  /// 星座自己连线,线上跑着数据包:连服务、接数据源。
  connecting(OrbMode.web),

  /// 三股线绕球编辫:规划、合并结果。
  weaving(OrbMode.braid),

  /// 起伏的多股绶带:写作、起草、生成文字。
  composing(OrbMode.ribbon),

  /// 正对着的一圈慢慢变形:空闲的"思考中"、推理。
  breathing(OrbMode.ring),

  /// 点画轮廓在圆、三角、方之间变:设计、搭版式。
  shaping(OrbMode.morph);

  const OrbState(this.mode);

  /// The engine mode that draws this state (`STATE_TO_MODE`).
  final OrbMode mode;
}

/// 两档调好的尺寸(逻辑像素)。不是一个设计的缩放:每档有自己的点数、点大小和速度。
enum OrbSize {
  /// 头像大小。
  px64(64),

  /// 跟一行字并排。
  px20(20);

  const OrbSize(this.px);

  final double px;
}

/// The engine's geometry builders, one per look (`ModeKey`).
enum OrbMode { orbits, globe, rubik, wave, web, braid, ribbon, ring, morph }

/// A (state, size) pair resolved to its mode, baked speed and scaled options.
typedef OrbPreset = ({OrbMode mode, double speed, ModeOpts opts});

typedef _Tuning = ({double speed, double count, double size, ModeOpts? extra});

// 2-D lattices (rings x dots-per-ring) come in pairs: each side takes sqrt(scale)
// so the TOTAL dot count scales by `scale`; flat lists scale linearly. `iconD`
// sets the morph outline's sampling density.
const _countPairs = [('latRings', 'lonDensity'), ('rings', 'lonDensity'), ('lanes', 'segs')];
const _countKeys = ['orbitN', 'ghostN', 'nodeN', 'strandN', 'signals'];
const _iconDensityKeys = ['iconD'];

// Every key that sets a dot's rendered radius: scaling all of them keeps a
// dot's near/far falloff intact while shrinking or growing the mark.
const _radiusKeys = ['rBase', 'rDepth', 'rActive', 'rDot', 'ghostR', 'partR', 'partRDepth', 'nodeR', 'nodeRDepth'];

ModeOpts scaleCounts(ModeOpts opts, double scale) {
  final out = {...opts};
  final done = <String>{};
  final rt = math.sqrt(scale);
  for (final (a, b) in _countPairs) {
    final va = out[a];
    final vb = out[b];
    if (va != null && vb != null && !done.contains(a) && !done.contains(b)) {
      out[a] = math.max(2, (va * rt).round()).toDouble();
      out[b] = math.max(2, (vb * rt).round()).toDouble();
      done
        ..add(a)
        ..add(b);
    }
  }
  for (final k in _countKeys) {
    final v = out[k];
    // 0 means the mode opted out of that layer entirely (ring has no ghost
    // sphere): scaling must not resurrect it as a single stray dot.
    if (v != null && v != 0 && !done.contains(k)) out[k] = math.max(1, (v * scale).round()).toDouble();
  }
  for (final k in _iconDensityKeys) {
    final v = out[k];
    if (v != null) out[k] = math.max(0.02, v * scale);
  }
  return out;
}

ModeOpts scaleRadii(ModeOpts opts, double scale) {
  final out = {...opts};
  for (final k in _radiusKeys) {
    final v = out[k];
    if (v != null) out[k] = v * scale;
  }
  // Remember the multiplier itself: spacing-derived radii (the morph outline)
  // use it, since they aren't based on any single radius key.
  out['rSizeMul'] = (out['rSizeMul'] ?? 1) * scale;
  return out;
}

/// Base (fine) profiles per mode, before preset multipliers.
const Map<OrbMode, ModeOpts> baseProfiles = {
  OrbMode.globe: {
    'latRings': 17,
    'lonDensity': 44,
    'rBase': 0.6,
    'rDepth': 1.7,
    'rBoost': 1.0,
    'inkFar': 0.62,
    'inkSpan': 0.54,
    'rsPow': 0.6,
    'rMin': 0.3,
  },
  OrbMode.orbits: {
    'orbitN': 12,
    'ghostN': 40,
    'ghostR': 0.9,
    'ghostA': 0.5,
    'particles': 3,
    'partR': 1.2,
    'partRDepth': 1.6,
    'rsPow': 0.6,
    'rMin': 0.3,
  },
  OrbMode.rubik: {
    'latRings': 15,
    'lonDensity': 40,
    'moveCount': 14,
    'rBase': 0.6,
    'rDepth': 1.7,
    'rActive': 0.3,
    'inkFar': 0.62,
    'inkSpan': 0.54,
    'rsPow': 0.6,
    'rMin': 0.3,
  },
  OrbMode.wave: {'rings': 15, 'lonDensity': 40, 'rBase': 0.6, 'rDepth': 1.7, 'rsPow': 0.6, 'rMin': 0.3},
  OrbMode.web: {
    'nodeN': 30,
    'thr': 0.72,
    'signals': 5,
    'nodeR': 1.4,
    'nodeRDepth': 1.8,
    'lineW': 0.8,
    'rsPow': 0.6,
    'rMin': 0.3,
  },
  OrbMode.braid: {'strandN': 52, 'turns': 3.0, 'ghostN': 150, 'rBase': 1.2, 'rDepth': 1.8, 'rsPow': 0.6, 'rMin': 0.3},
  OrbMode.ribbon: {'lanes': 5, 'segs': 88, 'ghostN': 150, 'rBase': 1.1, 'rDepth': 1.7, 'rsPow': 0.6, 'rMin': 0.3},
  // Ring shares ribbon's geometry; faceOn cancels the camera tilt and moves the
  // undulation onto the radius, and there is no ghost sphere behind it.
  OrbMode.ring: {
    'lanes': 5,
    'segs': 88,
    'ghostN': 0,
    'faceOn': 1,
    'rBase': 1.1,
    'rDepth': 1.7,
    'rsPow': 0.6,
    'rMin': 0.3,
  },
  OrbMode.morph: {'rDot': 0.021, 'iconD': 1, 'rMin': 0.25},
};

/// The author's tunings per mode and size (`PRESETS`, 64 and 20 only).
const Map<OrbMode, Map<OrbSize, _Tuning>> _tunings = {
  OrbMode.orbits: {
    OrbSize.px64: (speed: 1.885, count: 1, size: 1, extra: null),
    OrbSize.px20: (speed: 3.9, count: 0.238, size: 2.4, extra: null),
  },
  OrbMode.globe: {
    OrbSize.px64: (speed: 2.015, count: 0.42, size: 1.15, extra: {'scanMul': 4.08, 'dimBase': 0.45}),
    OrbSize.px20: (speed: 2.665, count: 0.105, size: 1.75, extra: {'scanMul': 4.335, 'dimBase': 0.45}),
  },
  OrbMode.rubik: {
    OrbSize.px64: (speed: 1.82, count: 0.35, size: 1.05, extra: null),
    OrbSize.px20: (speed: 1.95, count: 0.088, size: 1.9, extra: null),
  },
  OrbMode.wave: {
    OrbSize.px64: (speed: 4.388, count: 0.341, size: 1, extra: null),
    OrbSize.px20: (speed: 3.998, count: 0.105, size: 1.6, extra: null),
  },
  OrbMode.web: {
    OrbSize.px64: (speed: 3.315, count: 1.35, size: 0.95, extra: null),
    OrbSize.px20: (speed: 6.63, count: 0.25, size: 1.52, extra: null),
  },
  OrbMode.braid: {
    OrbSize.px64: (speed: 1.625, count: 0.5, size: 1, extra: null),
    OrbSize.px20: (speed: 2.75, count: 0.1125, size: 1.36, extra: null),
  },
  OrbMode.ribbon: {
    OrbSize.px64: (speed: 2.34, count: 0.25, size: 0.85, extra: {'spin': 0, 'bandMul': 3.9, 'wobMul': 1}),
    OrbSize.px20: (speed: 3.12, count: 0.051, size: 1.073, extra: {'spin': 0, 'bandMul': 4.94, 'wobMul': 1}),
  },
  OrbMode.ring: {
    OrbSize.px64: (speed: 3.24, count: 0.25, size: 0.956, extra: {'spin': 0, 'bandMul': 3.627, 'wobMul': 0.368}),
    OrbSize.px20: (speed: 3.78, count: 0.028, size: 1.622, extra: {'spin': 0, 'bandMul': 3.968, 'wobMul': 0.565}),
  },
  OrbMode.morph: {
    OrbSize.px64: (speed: 2.405, count: 0.702, size: 0.395, extra: {'spread': 1.45}),
    OrbSize.px20: (speed: 2.08, count: 0.53, size: 1.011, extra: {'spread': 1.45}),
  },
};

final _cache = <(OrbState, OrbSize), OrbPreset>{};

/// Resolve a (state, size) pair to its mode and fully scaled draw options.
/// Cached: never mutate the returned options.
OrbPreset resolvePreset(OrbState state, OrbSize size) => _cache.putIfAbsent((state, size), () {
  final mode = state.mode;
  final preset = _tunings[mode]![size]!;
  var opts = {...baseProfiles[mode]!};
  if (preset.count != 1) opts = scaleCounts(opts, preset.count);
  if (preset.size != 1) opts = scaleRadii(opts, preset.size);
  final extra = preset.extra;
  if (extra != null) opts = {...opts, ...extra};
  return (mode: mode, speed: preset.speed, opts: opts);
});
