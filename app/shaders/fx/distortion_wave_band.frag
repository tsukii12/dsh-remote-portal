// Portions derived from Libraries.dev Distortion waves (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.
//
// The wave's colour (waveBand), drawn over both sides, in two parts.
//
// The band rides the front: the palette flowing along it, a fringe ahead, one
// behind, a glow between them. Every edge of it is wide and feathered.
//
// The rim is what the band leaves on the view's edges: colour clinging to them
// after the middle has cleared, uneven lumps drifting round, with a hairline on
// the glass, until two later fronts wipe them away.
//
// The palette is OKLab, up to eight colours plus the two fringes, mixed so
// neighbours never pass through grey.

#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;
uniform vec4 uFront;   // originX, originY, spine, radius
uniform vec4 uShape;   // squash, time, swell, tilt
uniform vec4 uGlow;    // glow, rim, clearRadius, hairClearRadius
uniform vec4 uKind;    // ring, hold, lead, tail
uniform vec4 uRimA;    // strength, rimWidth, rimSoftness, cornerRadius
uniform vec4 uRimB;    // unevenness, pulse, hairlineWidth, hairlineOpacity
uniform vec4 uRimC;    // hairlineWhite, palette count, -, -
uniform vec4 uP0;
uniform vec4 uP1;
uniform vec4 uP2;
uniform vec4 uP3;
uniform vec4 uP4;
uniform vec4 uP5;
uniform vec4 uP6;
uniform vec4 uP7;
uniform vec4 uAhead;
uniform vec4 uBehind;
// The rim's lumps: centre along the perimeter, length, depth (WaveRim).
uniform vec4 uL0;
uniform vec4 uL1;
uniform vec4 uL2;
uniform vec4 uL3;
uniform vec4 uL4;
uniform vec4 uL5;
uniform vec4 uL6;

out vec4 fragColor;

#define WAVE_RING uKind.x
#define WAVE_HOLD uKind.y
#include "distortion_wave_field.glsl"

float sq(float x) {
  return x * x;
}

vec3 oklabToSRGB(vec3 c) {
  float l = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z;
  float m = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z;
  float s = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z;
  l = l * l * l;
  m = m * m * m;
  s = s * s * s;
  vec3 lin = clamp(vec3(
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
  ), 0.0, 1.0);
  return mix(12.92 * lin, 1.055 * pow(lin, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), lin));
}

// Signed distance to a rect with continuous corners, as a phone's screen has:
// the curve starts 1.53 radii from the corner and passes where a circular
// corner of that radius would at 45 degrees.
float continuousRectSDF(vec2 p, vec2 halfSize, float radius) {
  float a = min(radius * 1.528665, min(halfSize.x, halfSize.y));
  vec2 q = abs(p) - (halfSize - a);
  if (q.x <= 0.0 || q.y <= 0.0) {
    return max(abs(p.x) - halfSize.x, abs(p.y) - halfSize.y);
  }
  const float n = 3.26;
  vec2 u = q / a;
  float norm = pow(pow(u.x, n) + pow(u.y, n), 1.0 / n);
  vec2 g = pow(u / max(norm, 1e-4), vec2(n - 1.0));
  return (norm - 1.0) * a / max(length(g), 1e-3);
}

// Where a point is along the view's rounded-rect edge: clockwise from the top
// centre, through the corner arcs, pt. .y is the whole perimeter.
vec2 perimeterAt(vec2 p, vec2 halfSize, float r) {
  float ex = max(halfSize.x - r, 0.0);
  float ey = max(halfSize.y - r, 0.0);
  float arc = 0.5 * wavePi * r;
  float P = 4.0 * (ex + ey + arc);
  float ax = abs(p.x);
  float ay = abs(p.y);
  if (ax > ex && ay > ey) {
    vec2 v = p - vec2(p.x >= 0.0 ? ex : -ex, p.y >= 0.0 ? ey : -ey);
    float a;
    float base;
    if (p.x >= 0.0 && p.y < 0.0) {
      a = atan(v.x, -v.y);
      base = ex;
    } else if (p.x >= 0.0) {
      a = atan(v.y, v.x);
      base = ex + arc + 2.0 * ey;
    } else if (p.y >= 0.0) {
      a = atan(-v.x, v.y);
      base = 3.0 * ex + 2.0 * arc + 2.0 * ey;
    } else {
      a = atan(-v.y, -v.x);
      base = 3.0 * ex + 3.0 * arc + 4.0 * ey;
    }
    return vec2(base + r * clamp(a, 0.0, 0.5 * wavePi), P);
  }
  bool side = ax > ex ? true : (ay > ey ? false : (halfSize.x - ax) < (halfSize.y - ay));
  if (side) {
    return vec2(p.x >= 0.0 ? ex + arc + (p.y + ey) : 3.0 * ex + 3.0 * arc + 2.0 * ey + (ey - p.y), P);
  }
  return vec2(p.y < 0.0 ? (p.x >= 0.0 ? p.x : P + p.x) : ex + 2.0 * arc + 2.0 * ey + (ex - p.x), P);
}

float lumpAt(float s, float P, vec4 lump) {
  float ds = s - lump.x;
  ds -= P * floor(ds / P + 0.5);
  return lump.z * exp(-sq(ds / lump.y));
}

// How thick the colour on the edges is at s along the perimeter, as a share of
// rimWidth: averages 1, about a tenth of that at its thinnest, almost three
// times at its thickest.
float rimThickness(float s, float P) {
  float t = 0.08 + lumpAt(s, P, uL0) + lumpAt(s, P, uL1) + lumpAt(s, P, uL2) + lumpAt(s, P, uL3)
    + lumpAt(s, P, uL4) + lumpAt(s, P, uL5) + lumpAt(s, P, uL6);
  return t / 1.0498;
}

// Interleaved gradient noise: enough to hide banding, not enough to see.
float dither(vec2 p) {
  return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715)))) - 0.5;
}

vec3 paletteColor(float k) {
  if (k < 0.5) return uP0.xyz;
  if (k < 1.5) return uP1.xyz;
  if (k < 2.5) return uP2.xyz;
  if (k < 3.5) return uP3.xyz;
  if (k < 4.5) return uP4.xyz;
  if (k < 5.5) return uP5.xyz;
  if (k < 6.5) return uP6.xyz;
  return uP7.xyz;
}

// One colour from the ring of palette colours.
vec3 paletteAt(float u) {
  float count = uRimC.y;
  float x = fract(u) * count;
  float i = min(floor(x), count - 1.0);
  float j = mod(i + 1.0, count);
  float m = fract(x);
  m = m * m * (3.0 - 2.0 * m);
  return mix(paletteColor(i), paletteColor(j), m);
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  float glow = uGlow.x;
  float rim = uGlow.y;
  float lead = uKind.z;
  float tail = uKind.w;
  float strength = uRimA.x;
  float rimWidth = uRimA.y;
  float rimSoftness = uRimA.z;
  float cornerRadius = uRimA.w;
  float unevenness = uRimB.x;
  float pulse = uRimB.y;
  float hairWidth = uRimB.z;
  float hairOpacity = uRimB.w;
  float hairWhite = uRimC.x;

  vec2 c = p - uSize * 0.5;
  float edgeDistance = continuousRectSDF(c, uSize * 0.5, cornerRadius);
  float inset = max(-edgeDistance, 0.0);
  // Past the rounded edge (the view's corners) there is no glass for the rim
  // and the hairline: they stop at it, antialiased over 0.75pt.
  float inside = 1.0 - smoothstep(0.0, 0.75, edgeDistance);
  // Further in than this, even the thickest lump has faded to nothing, and the
  // hairline is far behind.
  bool nearEdge = rim > 0.0 && inside > 0.0
    && inset < max(rimWidth * 2.2 * (1.0 + 1.9 * unevenness), hairWidth * 0.5 + 0.75);
  // Once the front's colour has gone, only the edges are left to draw.
  if (glow <= 0.0 && !nearEdge) {
    fragColor = vec4(0.0);
    return;
  }

  vec2 n;
  vec2 q;
  vec2 raw;
  float g;
  float d = fieldAt(p, n, q, raw, g);
  float time = uShape.y;

  // The tail swells and thins along the front, and is lighter in the middle of
  // the screen, which it clears first.
  bool ring = WAVE_RING > 0.5;
  float turn = atan(q.y, q.x);
  float along = q.x * 0.0068;
  float lobes = ring
    ? 0.5 + 0.5 * sin(2.0 * turn + time * 1.4) * cos(turn - time * 0.7 + 1.2)
    : 0.5 + 0.5 * sin(along * 1.3 + time * 1.4) * cos(along * 0.6 - time * 0.7 + 1.2);
  float bandA = 0.0;
  if (glow > 0.0 && d < lead) {
    if (d >= 0.0) {
      float k = 1.0 - d / lead;
      bandA = k * k * k * (k * (k * 6.0 - 15.0) + 10.0);
    } else {
      bandA = pow(1.0 - clamp(-d / (tail * mix(0.6, 1.3, lobes)), 0.0, 1.0), 2.3);
    }
    bandA *= glow * strength * mix(0.6, 1.0, exp(-inset / 140.0)) * heldAt(p);
  }

  // Around the view: normalised, so the long sides get their share of colour.
  float around = atan(c.y / uSize.y, c.x / uSize.x);
  float rimA = 0.0;
  float hairA = 0.0;
  float shimmer = 0.5;
  if (nearEdge) {
    vec2 edge = perimeterAt(c, uSize * 0.5, cornerRadius);
    float thickness = 1.0;
    if (unevenness > 0.0) {
      thickness = max(1.0 + (rimThickness(edge.x, edge.y) - 1.0) * unevenness, 0.04);
    }
    float hug = exp(-sq(inset / (rimWidth * thickness)));
    float reached = 1.0 - smoothstep(-lead * 0.7, lead * 0.5, d);
    float kept = smoothstep(-rimSoftness, rimSoftness, d + (uFront.w - uGlow.z) / g);
    // Two soft swells of brightness running round the edge.
    shimmer = 0.5 + 0.5 * sin(time * 3.4 - edge.x / edge.y * 4.0 * wavePi);
    rimA = hug * reached * kept * rim * mix(1.0, 0.7 + 0.3 * shimmer, pulse) * inside;

    // A hairline right on the glass: brightest where the lumps are and where
    // the light runs. Wiped by a front of its own, later and slower.
    if (hairWidth > 0.0) {
      float line = 1.0 - smoothstep(hairWidth * 0.5, hairWidth * 0.5 + 0.75, inset);
      float hairKept = smoothstep(-rimSoftness, rimSoftness, d + (uFront.w - uGlow.w) / g);
      hairA = line * reached * hairKept * rim * hairOpacity
        * mix(0.5, 1.0, smoothstep(0.1, 1.5, thickness))
        * mix(1.0, 0.55 + 0.45 * shimmer, pulse) * inside;
    }
  }

  float a = 1.0 - (1.0 - bandA) * (1.0 - rimA);
  float total = 1.0 - (1.0 - a) * (1.0 - hairA);
  if (total <= 0.0005) {
    fragColor = vec4(0.0);
    return;
  }

  // Round a ring, the palette goes once round with it.
  float flow = 0.62 + (ring ? turn / (2.0 * wavePi) : along * 0.2) + time * 0.13 + d * 0.0015
    + (ring ? 0.0 : 0.05 * sin(q.y * 0.009 + time));
  vec3 lab = paletteAt(flow);
  lab = mix(lab, uAhead.xyz, 0.5 * exp(-sq((d - 30.0) / 50.0)));
  lab = mix(lab, uBehind.xyz, 0.5 * exp(-sq((d + 84.0) / 72.0)));
  lab.yz *= 1.22;
  lab = mix(lab, vec3(0.99, 0.0, 0.0), 0.7 * exp(-sq((d + 8.0) / 26.0)));

  // Once around the view: `around` jumps by a full turn, which fract() hides.
  vec3 rimLab = paletteAt(around / (2.0 * wavePi) + time * (0.12 + 0.25 * pulse) + inset * 0.0012);
  rimLab.yz *= 1.1;
  lab = mix(lab, rimLab, rimA / (rimA + bandA + 1e-4));

  // The hairline over the glow: the edge's own colour, whitening where the
  // light passes.
  vec3 rgb = oklabToSRGB(lab);
  if (hairA > 0.0) {
    vec3 hair = mix(oklabToSRGB(rimLab), vec3(1.0), hairWhite * (0.5 + 0.5 * shimmer));
    rgb = (rgb * a * (1.0 - hairA) + hair * hairA) / total;
  }

  float noise = dither(p) * 2.0 / 255.0;
  fragColor = vec4(clamp(rgb * total + noise, 0.0, 1.0), clamp(total + noise, 0.0, 1.0));
}
