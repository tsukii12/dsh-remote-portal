// Portions derived from Libraries.dev Image (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

// img-fx, pass 2 of the mosaic (IMGFX_PASS 2 in shaders.ts): every pixel reads
// its cell's colour from the field image (img_fx_field.frag) and is shaded as a
// pixel-mosaic cell (u_dotMode 1): vignette, gap mask, highlight wave, edge fade
// and the fade against the card colour. Output is premultiplied for Flutter.
// Coordinates follow WebGL: uv origin at the bottom left.

#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 u_size;       // card size, logical px (the shader's CSS px)
uniform vec2 u_cells;      // mosaic grid (cells along x / y)
uniform float u_time;
uniform float u_speed;
uniform float u_scale;
uniform float u_highlight;
uniform float u_hlScale;
uniform float u_gap;
uniform float u_dotOpacity;
uniform float u_fillOpacity;
uniform float u_edgeFade;
uniform float u_fadeStr;
uniform float u_vignette;
uniform float u_vigOpacity;
uniform float u_opacity;   // shaderOpacity × strength × the reveal's cross-fade
uniform vec3 u_cardBg;
uniform sampler2D u_field;

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

/** Highlight wave weight of the cell centred at cellCenter. */
float cellHighlight(vec2 cellCenter, float aspect, float t) {
  if (u_highlight <= 0.01 && u_hlScale <= 0.01) return 0.0;
  vec2 cp2 = (cellCenter - 0.5) * u_scale;
  cp2.x *= aspect;
  float lw = sin(cp2.x * 3.0 + t * 1.5) * 0.5 + 0.5;
  lw *= sin(cp2.y * 2.5 - t * 1.1) * 0.5 + 0.5;
  lw += (snoise(cp2 * 2.0 + t * 0.6) * 0.5 + 0.5) * 0.3;
  float hlFactor = clamp(lw, 0.0, 1.0);
  return hlFactor * hlFactor;
}

void main() {
  vec2 fc = FlutterFragCoord().xy;
  vec2 uv = vec2(fc.x, u_size.y - fc.y) / u_size;
  float aspect = u_size.x / u_size.y;
  float t = u_time * u_speed;

  vec2 cell = floor(uv * u_cells);
  vec2 cellCenter = (cell + 0.5) / u_cells;
  // The field image's first row is the top cell row.
  vec3 col = texture(u_field, vec2(cellCenter.x, 1.0 - cellCenter.y)).rgb;
  float hlFactor = cellHighlight(cellCenter, aspect, t);
  vec3 baseCol = col;

  // CSS-pixel distance to the nearest edge.
  vec2 cssCoord = uv * u_size;
  float edgeDistPx = min(min(cssCoord.x, u_size.x - cssCoord.x), min(cssCoord.y, u_size.y - cssCoord.y));
  float vigRangePx = 40.0 * (1.0 + u_vignette * 3.0);
  float vig = smoothstep(0.0, 1.0, (edgeDistPx * edgeDistPx) / (vigRangePx * vigRangePx));
  col *= mix(1.0, vig, u_vignette * u_vigOpacity);

  vec2 cellLocal = fract(uv * u_cells);
  float scaleBoost = 1.0 + smoothstep(0.2, 0.8, hlFactor) * u_hlScale * 1.2;
  float mask = 1.0;
  float gapW = u_gap * 0.35 / scaleBoost;
  if (gapW > 0.003) {
    mask = step(gapW, cellLocal.x) * step(gapW, 1.0 - cellLocal.x) * step(gapW, cellLocal.y) *
           step(gapW, 1.0 - cellLocal.y);
  }

  if (u_highlight > 0.01) {
    float hl = hlFactor * u_highlight;
    col = col * (1.0 + hl * 2.5) + vec3(hl * hl * 0.3);
  }

  if (u_edgeFade > 0.5 && u_fadeStr > 0.005) {
    float ef = smoothstep(0.0, u_edgeFade, edgeDistPx);
    mask *= mix(1.0, ef, u_fadeStr);
  }

  float alpha = mix(u_fillOpacity, u_dotOpacity, mask);
  float bgLum = dot(u_cardBg, vec3(0.299, 0.587, 0.114));
  float colLum = dot(baseCol, vec3(0.299, 0.587, 0.114));
  alpha *= smoothstep(0.0, 0.33, abs(colLum - bgLum));

  float a = clamp(alpha * u_opacity, 0.0, 1.0);
  fragColor = vec4(clamp(col, 0.0, 1.0) * a, a);
}
