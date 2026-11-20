// Portions derived from Libraries.dev Distortion waves (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.
//
// The one field both wave shaders read (DistortionWaveShaders.metal, fieldAt):
// a signed distance to the wave's front, from which the swell, the blur and the
// colour all follow, so none of them can drift apart.
//
//   d > 0  the wave has not got here yet
//   d = 0  the front
//   d < 0  the wave has passed
//
// The front starts as the source's own outline (a pill) and opens into an arc:
// the pill's spine shrinks to nothing while its radius grows. Touched
// off-centre, the wave's frame is turned (tilt). A ring has no spine and no
// squash, and what varies along an arc with x varies along a ring with the
// angle. Positions are logical pixels, y down, as SwiftUI's points.
//
// The including shader declares, before including this file:
//   uniform vec4 uFront;  // originX, originY, spine, radius
//   uniform vec4 uShape;  // squash, time, swell, tilt
// and defines WAVE_RING and WAVE_HOLD (1 / 0 for a ring; the held radius).

#ifndef DISTORTION_WAVE_FIELD_GLSL_
#define DISTORTION_WAVE_FIELD_GLSL_

// Half the zone over which the two screens crossfade, pt (WaveFront.coverZone).
const float coverZone = 60.0;
const float wavePi = 3.14159265;

// How much of the wave acts at this point: 0 on a held source, 1 well clear of it.
float heldAt(vec2 p) {
  float hold = WAVE_HOLD;
  if (hold <= 0.0) return 1.0;
  return smoothstep(hold * 0.9, hold * 1.8, length(p - uFront.xy));
}

// The signed distance to the front at p. n points away from the source on
// screen; q is p in the wave's frame, raw on screen, both from the origin; g is
// how fast the raw distance grows, which d has been divided by.
float fieldAt(vec2 p, out vec2 n, out vec2 q, out vec2 raw, out float g) {
  raw = p - uFront.xy;
  float cs = cos(uShape.w);
  float sn = sin(uShape.w);
  q = vec2(cs * raw.x + sn * raw.y, -sn * raw.x + cs * raw.y);
  float spine = uFront.z;
  float radius = uFront.w;
  float squash = uShape.x;
  float time = uShape.y;
  float swell = uShape.z;

  // A narrower x metric bows the front: wider than a circle would be, it
  // would otherwise cross a phone screen as a nearly flat line.
  float mx = q.x * squash;
  vec2 v = vec2(max(abs(mx) - spine, 0.0), q.y);
  float l = max(length(v), 1e-3);
  vec2 grad = vec2(v.x * sign(q.x) * squash, v.y) / l;
  g = max(length(grad), 1e-3);

  // A slow bend along the front, so the wave never looks drawn with a compass.
  float bend;
  if (WAVE_RING > 0.5) {
    float a = atan(q.y, q.x);
    bend = 0.62 * sin(2.0 * a + time * 1.1) + 0.38 * sin(3.0 * a - time * 1.5 + 1.7);
  } else {
    float s = mx * 0.0058;
    bend = 0.62 * sin(s + time * 1.1) + 0.38 * sin(s * 2.1 - time * 1.5 + 1.7);
  }

  vec2 m = grad / g;
  n = vec2(cs * m.x - sn * m.y, sn * m.x + cs * m.y);
  return (l - radius) / g + swell * bend;
}

#endif
