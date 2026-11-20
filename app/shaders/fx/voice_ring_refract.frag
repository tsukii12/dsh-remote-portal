// Portions derived from Libraries.dev Voice ring (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

// Refraction at the screen's edge (refract.ts, Refract.metal). Where the ring
// presses on the edge its pixels are drawn through a lens: toward the edge the
// image is stretched out across the gap it rests short by and opened a little
// taller, red and blue part as glass disperses them, and it blurs, more the
// nearer the edge. Everything is in the ring canvas's logical px.

#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;
uniform float uWall;
uniform float uSide;
uniform float uZone;
uniform float uGap;
uniform float uFlare;
uniform float uSplit;
uniform float uBlur;
uniform float uCy;
uniform sampler2D uTex;

out vec4 fragColor;

const int TAPS = 16;

vec4 tap(vec2 p) {
  return texture(uTex, p / uSize);
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  // 0 a zone back from the edge ... 1 at it and past it
  float t = clamp(1.0 - (uWall - p.x) * uSide / uZone, 0.0, 1.0);
  if (t <= 0.0) {
    fragColor = tap(p);
    return;
  }
  float w = t * t;
  // drawn out across the gap toward the edge, and opened a little taller
  float d = (uWall - p.x) * uSide + uGap * w;
  vec2 s = vec2(uWall - uSide * d, uCy + (p.y - uCy) / (1.0 + uFlare * w));
  // dispersion: red bent further out than blue, along the stretch and the flare
  vec2 split = vec2(uSide, 0.6 * (p.y - uCy) / uZone) * uSplit * w;
  // the blur grows toward the edge, drawn out along the stretch
  float b = uBlur * w;
  vec3 rgb = vec3(0.0);
  float a = 0.0;
  for (int i = 0; i < TAPS; i++) {
    float f = float(i);
    float r = sqrt((f + 0.5) / float(TAPS)) * b;
    vec2 o = vec2(cos(f * 2.39996) * 1.8, sin(f * 2.39996)) * r;
    vec4 cr = tap(s + o + split);
    vec4 cg = tap(s + o);
    vec4 cb = tap(s + o - split);
    rgb += vec3(cr.r, cg.g, cb.b);
    a += max(cg.a, max(cr.a, cb.a));
  }
  fragColor = vec4(rgb, a) / float(TAPS);
}
