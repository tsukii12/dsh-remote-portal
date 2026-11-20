// Portions derived from Libraries.dev Metal (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.
//
// The liquid-metal material: Paper Shaders' `liquidMetal` fragment stage
// (Apache-2.0, paper-design/shaders @ 0.0.80) in the full-fill (`shape: none`)
// mode metal-fx v2 uses, translated line for line from the author's SwiftUI
// port (MetalFxKit `MetalFxShaders.metal`, `mfxLiquidMetal`).
//
// As in that port: the web's sheet crop is a uv mapping (uv = uOrigin + pos *
// uScale), the stripe anti-aliasing width is a finite difference over one
// texel of the web's 192-px sheet instead of `fwidth`, and whatever the paint
// covers (a ring band, glyphs through srcIn, a pill) is the mask.
// Output is premultiplied.

#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uOrigin;      // 0, 1
uniform vec2 uScale;       // 2, 3
uniform float uTime;       // 4: seconds × preset speed
uniform vec4 uColorBack;   // 5..8
uniform vec4 uColorTint;   // 9..12: colour-burn tint, .a is the amount
uniform float uRepetition; // 13
uniform float uSoftness;   // 14
uniform float uShiftRed;   // 15
uniform float uShiftBlue;  // 16
uniform float uDistortion; // 17
uniform float uContour;    // 18
uniform float uAngle;      // 19
uniform float uOpacity;    // 20: strength × preset shaderOpacity (× metalOpacity)
uniform float uDither;     // 21: device pixel ratio

out vec4 fragColor;

#define MFX_PI 3.14159265358979323846
#define MFX_TEXEL (1.0 / 192.0)

vec3 mfxMod3(vec3 x, float y) { return x - y * floor(x / y); }
vec2 mfxMod2(vec2 x, float y) { return x - y * floor(x / y); }

vec2 mfxRotate(vec2 uv, float th) {
  return mat2(cos(th), sin(th), -sin(th), cos(th)) * uv;
}

vec3 mfxPermute(vec3 x) { return mfxMod3(((x * 34.0) + 1.0) * x, 289.0); }

float mfxSnoise(vec2 v) {
  const vec4 C = vec4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
  vec2 i = floor(v + dot(v, C.yy));
  vec2 x0 = v - i + dot(i, C.xx);
  vec2 i1 = (x0.x > x0.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
  vec4 x12 = x0.xyxy + C.xxzz;
  x12.xy -= i1;
  i = mfxMod2(i, 289.0);
  vec3 p = mfxPermute(mfxPermute(i.y + vec3(0.0, i1.y, 1.0)) + i.x + vec3(0.0, i1.x, 1.0));
  vec3 m = max(0.5 - vec3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
  m = m * m;
  m = m * m;
  vec3 x = 2.0 * fract(p * C.www) - 1.0;
  vec3 h = abs(x) - 0.5;
  vec3 ox = floor(x + 0.5);
  vec3 a0 = x - ox;
  m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
  vec3 g;
  g.x = a0.x * x0.x + h.x * x0.y;
  g.yz = a0.yz * x12.xz + h.yz * x12.yw;
  return 130.0 * dot(m, g);
}

float mfxSs(float e0, float e1, float x) {
  return smoothstep(e0, max(e1, e0 + 1e-6), x);
}

// One channel of the stripe field, with the colour-burn tint.
float mfxColorChanges(float c1, float c2, float stripeP, vec3 w, float blurIn, float bump, float tint, float tintA) {
  float blur = max(blurIn, 1e-5);
  float ch = mix(c2, c1, mfxSs(0.0, 2.0 * blur, stripeP));
  float border = w.x;
  ch = mix(ch, c2, mfxSs(border, border + 2.0 * blur, stripeP));
  border = w.x + 0.4 * (1.0 - bump) * w.y;
  ch = mix(ch, c1, mfxSs(border, border + 2.0 * blur, stripeP));
  border = w.x + 0.5 * (1.0 - bump) * w.y;
  ch = mix(ch, c2, mfxSs(border, border + 2.0 * blur, stripeP));
  border = w.x + w.y;
  ch = mix(ch, c1, mfxSs(border, border + 2.0 * blur, stripeP));
  float gradientT = (stripeP - w.x - w.y) / w.z;
  float gradient = mix(c1, c2, mfxSs(0.0, 1.0, gradientT));
  ch = mix(ch, gradient, mfxSs(border, border + 0.5 * blur, stripeP));
  ch = mix(ch, 1.0 - min(1.0, (1.0 - ch) / max(tint, 0.0001)), tintA);
  return ch;
}

// Everything that depends on uv, up to (but not including) the stripe fract.
void mfxField(vec2 uv, float t, float noise, float cw,
              out float direction, out float bump, out float edge, out float diagBL, out float diagTL) {
  vec2 uvc = clamp(uv, 0.0, 1.0);

  // Full-fill edge mask, on the web's square sheet.
  vec2 mask = min(uvc, 1.0 - uvc);
  float maskX = pow(mfxSs(0.0, 0.5, mask.x), 0.25);
  float maskY = pow(mfxSs(0.0, 0.5, mask.y), 0.25);
  edge = clamp(1.0 - maskX * maskY, 0.0, 1.0);
  const float fwE = 0.002;
  edge = mix(mfxSs(0.9 - 2.0 * fwE, 0.9, edge), edge, mfxSs(0.0, 0.4, uContour));
  edge = 1.2 * edge;

  vec2 rotatedUV = uv - 0.5;
  float a = (-uAngle + 70.0) * MFX_PI / 180.0;
  float cosA = cos(a);
  float sinA = sin(a);
  rotatedUV = vec2(rotatedUV.x * cosA - rotatedUV.y * sinA, rotatedUV.x * sinA + rotatedUV.y * cosA) + 0.5;
  diagBL = rotatedUV.x - rotatedUV.y;
  diagTL = rotatedUV.x + rotatedUV.y;

  vec2 gradUV = uv - 0.5;
  float dist = length(gradUV + vec2(0.0, 0.2 * diagBL));
  gradUV = mfxRotate(gradUV, (0.25 - 0.2 * diagBL) * MFX_PI);
  direction = gradUV.x;

  float uy = max(uvc.y, 0.0);
  bump = pow(1.8 * dist, 1.2);
  bump = 1.0 - bump;
  bump *= pow(uy, 0.3);

  edge += (1.0 - edge) * uDistortion * noise;

  direction += diagBL;
  float sE = mfxSs(0.0, 1.0, edge);
  direction -= 2.0 * noise * diagBL * (sE * (1.0 - sE));
  float c51 = mfxSs(0.5, 1.0, uContour);
  direction *= mix(1.0, 1.0 - edge, c51);
  direction -= 1.7 * edge * c51;
  direction += 0.2 * pow(uContour, 4.0) * (1.0 - sE);

  bump *= clamp(pow(uy, 0.1), 0.3, 1.0);
  direction *= (0.1 + (1.1 - edge) * bump);

  direction *= (0.4 + 0.6 * (1.0 - mfxSs(0.5, 1.0, edge)));
  direction += 0.18 * (mfxSs(0.1, 0.2, uv.y) * (1.0 - mfxSs(0.2, 0.4, uv.y)));
  direction += 0.03 * (mfxSs(0.1, 0.2, 1.0 - uv.y) * (1.0 - mfxSs(0.2, 0.4, 1.0 - uv.y)));

  direction *= (0.5 + 0.5 * uv.y * uv.y);
  direction *= cw;
  direction -= t;
}

// The material at `uv` (0..1 over the web's square sheet, y down), premultiplied.
vec4 mfxMaterial(vec2 uv, vec2 dither) {
  float t = 0.3 * (uTime + 2.8);
  float cw = uRepetition * 2.0;

  float noise = mfxSnoise(uv - t);
  float direction;
  float bump;
  float edge;
  float diagBL;
  float diagTL;
  mfxField(uv, t, noise, cw, direction, bump, edge, diagBL, diagTL);
  // Stripe AA width: finite difference over one texel of the web's sheet.
  float dx;
  float dy;
  float unused0;
  float unused1;
  float unused2;
  float unused3;
  mfxField(uv + vec2(MFX_TEXEL, 0.0), t, noise, cw, dx, unused0, unused1, unused2, unused3);
  mfxField(uv + vec2(0.0, MFX_TEXEL), t, noise, cw, dy, unused0, unused1, unused2, unused3);
  float fw = abs(dx - direction) + abs(dy - direction);

  // Full-fill opacity: only the sheet's outermost sliver ever reaches .9.
  const float fwE = 0.002;
  vec2 uvc = clamp(uv, 0.0, 1.0);
  vec2 mask = min(uvc, 1.0 - uvc);
  float rawEdge = clamp(1.0 - pow(mfxSs(0.0, 0.5, mask.x), 0.25) * pow(mfxSs(0.0, 0.5, mask.y), 0.25), 0.0, 1.0);
  float opacity = 1.0 - mfxSs(0.9 - 2.0 * fwE, 0.9, rawEdge);

  vec3 color1 = vec3(0.98, 0.98, 1.0);
  vec3 color2 = vec3(0.1, 0.1, 0.1 + 0.1 * mfxSs(0.7, 1.3, diagTL));

  float thin1 = 0.12 / cw * (1.0 - 0.4 * bump);
  float thin2 = 0.07 / cw * (1.0 + 0.4 * bump);
  float wide = 1.0 - thin1 - thin2;
  vec3 w = vec3(cw * thin1, cw * thin2, wide);

  float colorDispersion = clamp(1.0 - bump, 0.0, 1.0);
  float dR = colorDispersion;
  dR += 0.03 * bump * noise;
  dR += 5.0 * (mfxSs(-0.1, 0.2, uv.y) * (1.0 - mfxSs(0.1, 0.5, uv.y))) * (mfxSs(0.4, 0.6, bump) * (1.0 - mfxSs(0.4, 1.0, bump)));
  dR -= diagBL;
  float dB = colorDispersion * 1.3;
  dB += (mfxSs(0.0, 0.4, uv.y) * (1.0 - mfxSs(0.1, 0.8, uv.y))) * (mfxSs(0.4, 0.6, bump) * (1.0 - mfxSs(0.4, 0.8, bump)));
  dB -= 0.2 * edge;
  dR *= (uShiftRed / 20.0);
  dB *= (uShiftBlue / 20.0);

  float blur = uSoftness / 15.0;
  w.y -= 0.02 * mfxSs(0.0, 1.0, edge + bump);

  float r = mfxColorChanges(color1.r, color2.r, fract(direction + dR), w, blur + fw, bump, uColorTint.r, uColorTint.a);
  float g = mfxColorChanges(color1.g, color2.g, fract(direction), w, blur + fw, bump, uColorTint.g, uColorTint.a);
  float b = mfxColorChanges(color1.b, color2.b, fract(direction - dB), w, blur + fw, bump, uColorTint.b, uColorTint.a);

  vec3 color = vec3(r, g, b) * opacity;
  vec3 bgColor = uColorBack.rgb * uColorBack.a;
  color = color + bgColor * (1.0 - opacity);
  opacity = opacity + uColorBack.a * (1.0 - opacity);

  // Banding fix (dither), as in Paper's shader.
  color += 1.0 / 256.0 * (fract(sin(dot(0.014 * dither, vec2(12.9898, 78.233))) * 43758.5453123) - 0.5);
  return vec4(color, opacity);
}

void main() {
  vec2 pos = FlutterFragCoord().xy;
  vec2 uv = uOrigin + pos * uScale;
  fragColor = mfxMaterial(uv, pos * uDither) * uOpacity;
}
