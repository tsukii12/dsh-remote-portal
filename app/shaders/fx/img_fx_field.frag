// Portions derived from Libraries.dev Image (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

// img-fx, pass 1 of the mosaic (IMGFX_PASS 1 in shaders.ts): the effect colour
// of every cell, one fragment per cell, into a gridX×gridY image. With
// u_raw = 1 it is instead the raw field (u_dotMode 0) the reveal mask and the
// regenerate churn read back, one fragment per sample point.
//
// Only the three effect branches the bundled presets use are kept: 11 Nebula
// (pixels-mechanic), 22 Chromium Flow (pixels-organic), 25 Gradient Sweep
// (sweep-gradient). All bundled palettes have every alpha at 1, so the u_alphaN
// weights are folded away. Coordinates follow WebGL: uv origin at the bottom left.

#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 u_size;       // card size, logical px (the shader's CSS px)
uniform vec2 u_target;     // render target size: the mosaic grid, or the sample edge
uniform vec2 u_cells;      // mosaic grid (cells along x / y)
uniform float u_raw;       // 0: cell field, 1: raw field sample
uniform float u_time;
uniform float u_speed;
uniform float u_effect;
uniform float u_intensity;
uniform float u_scale;
uniform float u_direction;
uniform float u_distortion;
uniform float u_complexity;
uniform float u_shape;
uniform float u_flicker;
uniform float u_blur;
uniform float u_sweepEase;
uniform float u_vignette;
uniform float u_vigOpacity;
uniform vec3 u_color1;
uniform vec3 u_color2;
uniform vec3 u_color3;
uniform vec3 u_color4;
uniform vec3 u_color5;

out vec4 fragColor;

vec3 mod289(vec3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec2 mod289v2(vec2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec3 permute(vec3 x) { return mod289((x * 34.0 + 1.0) * x); }

float snoise(vec2 v) {
  const vec4 C = vec4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
  vec2 i = floor(v + dot(v, C.yy));
  vec2 x0 = v - i + dot(i, C.xx);
  vec2 i1 = (x0.x > x0.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
  vec4 x12 = x0.xyxy + C.xxzz;
  x12.xy -= i1;
  i = mod289v2(i);
  vec3 p = permute(permute(i.y + vec3(0.0, i1.y, 1.0)) + i.x + vec3(0.0, i1.x, 1.0));
  vec3 m = max(0.5 - vec3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
  m = m * m;
  m = m * m;
  vec3 x_ = 2.0 * fract(p * C.www) - 1.0;
  vec3 h = abs(x_) - 0.5;
  vec3 ox = floor(x_ + 0.5);
  vec3 a0 = x_ - ox;
  m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
  vec3 g;
  g.x = a0.x * x0.x + h.x * x0.y;
  g.yz = a0.yz * x12.xz + h.yz * x12.yw;
  return 130.0 * dot(m, g);
}

float fbm(vec2 p, float oct) {
  float val = 0.0;
  float amp = 0.5;
  int n = int(oct);
  for (int i = 0; i < 4; i++) {
    if (i >= n) break;
    val += amp * snoise(p);
    p *= 2.0;
    amp *= 0.5;
  }
  return val;
}

float nfbm(vec2 p) { return fbm(p, 2.0 + u_complexity * 2.0); }

vec3 palette(float t) {
  t = clamp(t, 0.0, 1.0);
  t = t * t * (3.0 - 2.0 * t);
  float k = 64.0;
  float w1 = exp(-k * t * t);
  float w2 = exp(-k * (t - 0.25) * (t - 0.25));
  float w3 = exp(-k * (t - 0.5) * (t - 0.5));
  float w4 = exp(-k * (t - 0.75) * (t - 0.75));
  float w5 = exp(-k * (t - 1.0) * (t - 1.0));
  float total = w1 + w2 + w3 + w4 + w5 + 0.0001;
  return (u_color1 * w1 + u_color2 * w2 + u_color3 * w3 + u_color4 * w4 + u_color5 * w5) / total;
}

vec3 softBlend(float a, float b, float c) {
  a = clamp(a, 0.0, 1.0);
  a *= a;
  b = clamp(b, 0.0, 1.0);
  b *= b;
  c = clamp(c, 0.0, 1.0);
  c *= c;
  float d = clamp(a * 0.7 + c * 0.3, 0.0, 1.0);
  d *= d;
  float e = clamp(b * 0.5 + c * 0.5, 0.0, 1.0);
  e *= e;
  float total = a + b + c + d + e;
  float floorW = max(0.001 - total, 0.0);
  vec3 fallback = (u_color1 + u_color2 + u_color3 + u_color4 + u_color5) * 0.2;
  return (u_color1 * a + u_color2 * b + u_color3 * c + u_color4 * d + u_color5 * e + fallback * floorW) /
         (total + floorW);
}

vec2 warp(vec2 p, float t) {
  float str = u_distortion * 2.0;
  return vec2(nfbm(p + vec2(t * 0.1, 0.0)), nfbm(p + vec2(0.0, t * 0.12) + 5.0)) * str;
}

float sweepEase(float x) {
  int e = int(u_sweepEase + 0.5);
  if (e == 1) return x * x * (3.0 - 2.0 * x);
  if (e == 2) {
    float p = 1.0 - x;
    return 1.0 - p * p * p;
  }
  if (e == 3) {
    return x < 0.5 ? 4.0 * x * x * x : 1.0 - pow(-2.0 * x + 2.0, 3.0) * 0.5;
  }
  if (e == 4) return 1.0 - pow(2.0, -10.0 * x) * (1.0 - x);
  return x;
}

vec3 computeEffect(vec2 uv, float aspect, float t) {
  float dist = u_distortion;
  float cpx = u_complexity;
  float shp = u_shape;
  vec2 p = (uv - 0.5) * u_scale;
  p.x *= aspect;
  p += vec2(cos(u_direction), sin(u_direction)) * t * 0.15;
  vec3 col = vec3(0.0);
  int effect = int(u_effect + 0.5);

  if (effect == 11) {
    // Nebula
    vec2 q = vec2(nfbm(p * 0.5 + vec2(t * 0.05, 0.0)), nfbm(p * 0.5 + vec2(0.0, t * 0.07)));
    vec2 r = vec2(nfbm(p * 0.6 + q * (1.0 + dist * 1.5) + vec2(1.7, 9.2) + t * 0.03),
                  nfbm(p * 0.6 + q * (1.0 + dist * 1.5) + vec2(8.3, 2.8) + t * 0.04));
    float f = nfbm(p + r * 1.5);
    float f2 = nfbm(p * 0.7 + r + vec2(3.0, 7.0));
    col = softBlend((f * 0.5 + 0.5) * u_intensity, (f2 * 0.5 + 0.5) * u_intensity,
                    (nfbm(p * 0.4 - t * 0.02) * 0.5 + 0.5) * u_intensity);

  } else if (effect == 22) {
    // Chromium Flow
    vec2 w = warp(p * 0.7, t * 0.5);
    vec2 w2 = warp(p * 0.4 + w * 0.3, t * 0.3);
    vec2 wp = p + w * (0.4 + dist * 0.6);
    float n1 = snoise(wp * (1.4 + cpx * 1.6) + t * 0.14);
    float n2 = snoise((wp + w2 * dist * 0.4) * (2.0 + cpx * 2.0) + vec2(3.0, 7.0) - t * 0.1);
    float ridge1 = 1.0 - abs(n1);
    ridge1 = pow(ridge1, 5.0 + shp * 12.0);
    float ridge2 = 1.0 - abs(n2);
    ridge2 = pow(ridge2, 4.0 + shp * 10.0);
    float base = (n1 + n2) * 0.25 + 0.5;
    float w1 = (base * 0.6 + ridge1 * 1.2) * u_intensity;
    float w2c = ((1.0 - base) * 0.6 + ridge2 * 1.0) * u_intensity;
    float w3 = (ridge1 * 0.8 + ridge2 * 0.6) * u_intensity;
    col = softBlend(w1, w2c, w3);

  } else if (effect == 25) {
    // Gradient Sweep
    float d = (uv.x + (1.0 - uv.y)) * 0.5;
    float w = 0.9 / max(u_scale, 0.25);
    float cyc = t * 0.08;
    float pA = mix(-w, 1.0 + w, sweepEase(fract(cyc)));
    float pB = mix(-w, 1.0 + w, sweepEase(fract(cyc + 0.5)));
    float band = max(clamp(1.0 - abs(d - pA) / w, 0.0, 1.0), clamp(1.0 - abs(d - pB) / w, 0.0, 1.0));
    float v = band * u_intensity;

    vec2 cell = floor(uv * u_cells);
    float clk = t * 1.6;
    // Wrap the stepped clock to keep sin() arguments small (mediump GPUs).
    float step0 = mod(floor(clk), 1024.0);
    float step1 = mod(step0 + 1.0, 1024.0);
    float fz = smoothstep(0.0, 1.0, fract(clk));
    float cellSeed = dot(cell, vec2(127.1, 311.7));
    float r1 = fract(sin(cellSeed + step0 * 17.23) * 43758.5453);
    float r2 = fract(sin(cellSeed + step1 * 17.23) * 43758.5453);
    float rnd = mix(r1, r2, fz);
    v += (rnd - 0.5) * u_flicker * 0.9 * (0.15 + band * 0.85);

    col = palette(clamp(v, 0.0, 1.0));
  }

  return col;
}

/** Effect colour at sampleUV, with the optional 5-tap blur. */
vec3 effectColor(vec2 sampleUV, float aspect, float t) {
  if (u_blur < 0.01) {
    return computeEffect(sampleUV, aspect, t);
  }
  float r = u_blur * 0.02;
  vec3 col = computeEffect(sampleUV, aspect, t) * 0.4;
  col += computeEffect(sampleUV + vec2(r, 0.0), aspect, t) * 0.15;
  col += computeEffect(sampleUV + vec2(-r, 0.0), aspect, t) * 0.15;
  col += computeEffect(sampleUV + vec2(0.0, r), aspect, t) * 0.15;
  col += computeEffect(sampleUV + vec2(0.0, -r), aspect, t) * 0.15;
  return col;
}

void main() {
  vec2 fc = FlutterFragCoord().xy;
  // Cell field: the fragment centre is the cell centre in grid units. Raw
  // sample: the fragment centre is the sample point.
  vec2 uv = vec2(fc.x, u_target.y - fc.y) / u_target;
  float aspect = u_size.x / u_size.y;
  float t = u_time * u_speed;
  vec3 col = effectColor(uv, aspect, t);
  if (u_raw > 0.5) {
    // imgfx_shade at u_dotMode 0: gamma and vignette; alpha stays 1.
    col = pow(col, vec3(1.3));
    vec2 cssCoord = uv * u_size;
    float edgeDistPx = min(min(cssCoord.x, u_size.x - cssCoord.x), min(cssCoord.y, u_size.y - cssCoord.y));
    float vigRangePx = 40.0 * (1.0 + u_vignette * 3.0);
    float vig = smoothstep(0.0, 1.0, (edgeDistPx * edgeDistPx) / (vigRangePx * vigRangePx));
    col *= mix(1.0, vig, u_vignette * u_vigOpacity);
  }
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
