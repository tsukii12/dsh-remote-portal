// Portions derived from Libraries.dev Distortion waves (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.
//
// One side of the transition through the swell (waveLens), with its
// progressive blur (waveBlurMask) stacked in: the side's sharp snapshot, then a
// copy blurred by 7pt and one blurred by the style's full radius, each covering
// the one below where the blur this point should have runs past it.
//
// side: +1 the content the wave leaves behind it (visible ahead of the front),
//       -1 the content it reveals (visible behind the front).
//
// Content rises once as the swell passes and settles back. Gravity is the
// anticipation before that: everything falls toward the source, more the nearer
// it is. Chromatic aberration follows from the same displacement: the colours
// part along the way a pixel has been moved, in proportion to how far, over five
// samples across the spectrum.

#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;
uniform vec4 uFront;   // originX, originY, spine, radius
uniform vec4 uShape;   // squash, time, swell, tilt
uniform vec4 uMotion;  // energy, gravity, ring, hold
uniform vec4 uLens;    // amplitude, lensWidth, aberration, side
uniform vec4 uBlur;    // blur, blurAhead, blurBehind, launched
uniform sampler2D uSharp;
uniform sampler2D uNear;
uniform sampler2D uFar;

out vec4 fragColor;

#define WAVE_RING uMotion.z
#define WAVE_HOLD uMotion.w
#include "distortion_wave_field.glsl"

// The radius of the first blurred copy; the second has the style's full radius.
const float nearBlur = 7.0;

float ease(float a, float b, float x) {
  float t = clamp((x - a) / max(b - a, 1e-3), 0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

// The side, sharp and with its blurred copies over it, at x.
vec4 layerAt(vec2 x, float near, float far) {
  vec2 uv = clamp(x, vec2(0.5), uSize - 0.5) / uSize;
  vec4 c = texture(uSharp, uv);
  if (near > 0.0) {
    vec4 a = texture(uNear, uv) * near;
    c = a + c * (1.0 - a.a);
  }
  if (far > 0.0) {
    vec4 b = texture(uFar, uv) * far;
    c = b + c * (1.0 - b.a);
  }
  return c;
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  vec2 n;
  vec2 q;
  vec2 raw;
  float g;
  float d = fieldAt(p, n, q, raw, g);
  float energy = uMotion.x;
  float gravity = uMotion.y;
  float side = uLens.w;

  // Ahead of the zone the outgoing side covers the incoming one completely, so
  // the incoming side has nothing to draw there. Before the launch the incoming
  // side is not drawn at all.
  float cover = 1.0;
  if (side > 0.0) {
    if (uBlur.w > 0.5) cover = smoothstep(-coverZone, coverZone, d);
    if (cover <= 0.0) {
      fragColor = vec4(0.0);
      return;
    }
  } else if (d > coverZone + 6.0) {
    fragColor = vec4(0.0);
    return;
  }

  // Steeper ahead, where it compresses what it is about to reach; long behind.
  float u = d / (uLens.y * (d > 0.0 ? 0.85 : 1.5));
  float lift = exp(-u * u);
  float r = max(length(raw), 1.0);

  // Gravity moves the whole screen, but far from the source it only slides
  // content along: it bends it near the source, so only there does it count
  // as distortion.
  float held = heldAt(p);
  vec2 swollen = n * energy * uLens.x * lift * held;
  vec2 inward = raw / r;
  vec2 s = p - swollen + inward * gravity * exp(-r / 900.0) * held;
  vec2 split = (swollen - inward * gravity * exp(-r / 240.0) * held) * uLens.z;

  // The blur the layer has where the middle sample lands: gathering ahead of
  // the front, peaking on it, clearing slowly behind it.
  float near = 0.0;
  float far = 0.0;
  if (energy > 0.0 && uBlur.x > 0.0) {
    vec2 sn;
    vec2 sq;
    vec2 sraw;
    float sg;
    float ds = fieldAt(s, sn, sq, sraw, sg);
    float su = ds / (ds > 0.0 ? uBlur.y : uBlur.z);
    float radius = energy * uBlur.x * exp(-su * su) * heldAt(s);
    near = ease(0.0, nearBlur, radius);
    far = ease(nearBlur, uBlur.x, radius);
  }

  // Under a quarter of a point the colours can't be seen apart.
  if (dot(split, split) < 0.0625) {
    fragColor = layerAt(s, near, far) * cover;
    return;
  }

  vec4 c0 = layerAt(s - split, near, far);
  vec4 c1 = layerAt(s - split * 0.5, near, far);
  vec4 c2 = layerAt(s, near, far);
  vec4 c3 = layerAt(s + split * 0.5, near, far);
  vec4 c4 = layerAt(s + split, near, far);
  vec3 rgb = c0.rgb * vec3(0.571, 0.0, 0.0) + c1.rgb * vec3(0.343, 0.206, 0.0)
    + c2.rgb * vec3(0.086, 0.588, 0.086) + c3.rgb * vec3(0.0, 0.206, 0.343)
    + c4.rgb * vec3(0.0, 0.0, 0.571);
  float a = (c0.a + c1.a + c2.a + c3.a + c4.a) / 5.0;
  fragColor = vec4(rgb, a) * cover;
}
