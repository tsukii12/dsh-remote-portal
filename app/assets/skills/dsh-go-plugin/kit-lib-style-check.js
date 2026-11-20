// View-v2 style checks. Constants come from the author schema; the Dart twin
// lives in dsh_ui_plugin_styles_model.dart. No CSS, evaluation or network I/O.
import { readFileSync } from 'node:fs'

const schema = JSON.parse(readFileSync(new URL('../schema/view.schema.json', import.meta.url), 'utf8'))
const spec = schema['x-dsh-go'].v2Styles
const numberColor = value => Number.parseInt(value.slice(1), 16)
const palette = Object.fromEntries(Object.entries(spec.namedColors).map(([key, value]) => [key, numberColor(value)]))
const pair = value => [value, value]
const surface = spec.backgrounds.surface.map(numberColor)
const elevated = spec.backgrounds.elevated.map(numberColor)
const ink = spec.ink.map(numberColor)
const muted = spec.muted.map(numberColor)
const defaultAccent = numberColor(spec.defaultAccent)
// `accent: "app"`: the person's palette; offline checks assume the app's default (雾蓝).
const appAccent = numberColor(spec.appAccent)
const reserved = new Set(spec.reservedStyleKeys)
const known = new Set(['size', 'weight', 'italic', 'underline', 'strike', 'align', 'maxLines', 'color',
  'card', 'padding', 'gap', 'columns', 'dividers', 'background'])
export const RESERVED_ROLES = new Set(spec.reservedRoles)

/** WCAG 2.2 sRGB relative luminance; do not round before comparison. */
export function contrast(foreground, background) {
  const luminance = color => {
    const channel = shift => {
      const c = ((color >> shift) & 255) / 255
      return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4
    }
    return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
  }
  const a = luminance(foreground)
  const b = luminance(background)
  return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05)
}

function mix(from, to, amount) {
  const channel = shift => Math.round(((from >> shift) & 255) * (1 - amount) + ((to >> shift) & 255) * amount)
  return (channel(16) << 16) | (channel(8) << 8) | channel(0)
}

/** Same bounded 16-step, quantised search as the app. */
export function readableColor(requested, background, minimum = 4.5) {
  if (contrast(requested, background) >= minimum) return requested
  let best = requested
  let bestDistance = 2
  for (const target of [0x000000, 0xffffff]) {
    if (contrast(target, background) < minimum) continue
    let low = 0
    let high = 1
    let passing = target
    for (let step = 0; step < 16; step++) {
      const middle = (low + high) / 2
      const candidate = mix(requested, target, middle)
      if (contrast(candidate, background) >= minimum) {
        high = middle
        passing = candidate
      } else low = middle
    }
    if (high < bestDistance) {
      bestDistance = high
      best = passing
    }
  }
  return best
}

const hex = value => `#${value.toString(16).padStart(6, '0').toUpperCase()}`
const isMap = v => typeof v === 'object' && v !== null && !Array.isArray(v)
const absent = (value, ctx) => value == null || ctx.styleHelpers.isMissing(value)

function color(value, path, ctx, allowAccent = true) {
  if (absent(value, ctx)) return null
  if (typeof value === 'string') {
    if (value.length > 16) {
      ctx.note(path, ctx.m('plugViewStyleInvalid', `red … gray / #RRGGBB${allowAccent ? ' / accent' : ''}`))
      return null
    }
    if (allowAccent && value === 'accent') return ctx.accent
    if (Object.hasOwn(palette, value)) return palette[value]
    if (/^#[0-9a-fA-F]{6}$/.test(value)) return numberColor(value)
  }
  ctx.note(path, ctx.m('plugViewStyleInvalid', `red … gray / #RRGGBB${allowAccent ? ' / accent' : ''}`))
  return null
}

function readablePair(requested, background, minimum, path, ctx, once = false) {
  return requested.map((value, i) => {
    const base = background[i]
    const mode = i === 0 ? 'light' : 'dark'
    const corrected = readableColor(value, base, minimum)
    const key = `${path}:${value}:${base}:${minimum}:${mode}`
    if (corrected !== value && (!once || !ctx.contrastNotes.has(key))) {
      if (once) ctx.contrastNotes.add(key)
      ctx.note(path, ctx.m('plugViewContrastAdjusted', mode, hex(value), hex(corrected), String(minimum)))
    }
    return corrected
  })
}

function choice(raw, values, fallback, path, ctx) {
  if (absent(raw, ctx)) return fallback
  if (values.includes(raw)) return raw
  ctx.note(path, ctx.m('plugViewStyleInvalid', values.join(' / ')))
  return fallback
}

function flag(raw, key, path, ctx) {
  const value = raw[key]
  if (absent(value, ctx)) return false
  if (typeof value === 'boolean') return value
  ctx.note(`${path}.${key}`, ctx.m('plugViewStyleInvalid', 'true / false'))
  return false
}

function spacing(value, fallback, path, ctx) {
  if (absent(value, ctx)) return fallback
  if (typeof value === 'string' && Object.hasOwn(spec.spacingPixels, value)) return spec.spacingPixels[value]
  ctx.note(path, ctx.m('plugViewStyleInvalid', 'S / M / L'))
  return fallback
}

function tint(rgb) {
  return surface.map((base, i) => mix(base, rgb, spec.tintAmounts[i]))
}

export function initStyles(raw, ctx, helpers) {
  ctx.styleHelpers = helpers
  ctx.version = raw.v === 2 ? 2 : 1
  ctx.accent = defaultAccent
  ctx.styleBackground = surface
  ctx.richSpans = 0
  ctx.styles = new Map()
  ctx.contrastNotes = new Set()
  if (raw.v != null && raw.v !== 1 && raw.v !== 2) ctx.note('view.v', ctx.m('plugViewVersionFallback', helpers.show(raw.v)))
  if (ctx.version === 2) {
    ctx.accent = raw.accent === 'app' ? appAccent : color(raw.accent, 'view.accent', ctx, false) ?? defaultAccent
  }
}

export function readStyle(raw, path, ctx) {
  const styleAt = `${path}.style`
  const rawStyle = raw.style
  const style = isMap(rawStyle) && !ctx.styleHelpers.isMissing(rawStyle) ? rawStyle : {}
  if (!absent(rawStyle, ctx) && !isMap(rawStyle)) ctx.note(styleAt, ctx.m('plugViewStyleInvalid', '{…}'))
  for (const key of reserved) if (Object.hasOwn(style, key)) ctx.note(`${styleAt}.${key}`, ctx.m('plugViewStyleReserved'))
  let inspected = 0
  for (const key in style) {
    if (!Object.hasOwn(style, key)) continue
    if (inspected++ >= 32) { ctx.note(styleAt, ctx.m('plugViewStyleReserved')); break }
    if (!known.has(key) && !reserved.has(key)) ctx.note(`${styleAt}.${key}`, ctx.m('plugViewStyleReserved'))
  }
  const type = raw.type
  const layout = type === 'stack' || type === 'row'
  const textNode = ['text', 'metric', 'callout'].includes(type)
  const size = choice(style.size, Object.keys(spec.fontPixels), type === 'metric' ? 'title' : 'body', `${styleAt}.size`, ctx)
  const weight = choice(style.weight, spec.weights, type === 'metric' ? 'semibold' : 'regular', `${styleAt}.weight`, ctx)
  let card = choice(style.card, ['plain', 'surface', 'tinted', 'outlined'], 'plain', `${styleAt}.card`, ctx)
  if (!layout && card !== 'plain') {
    ctx.note(`${styleAt}.card`, ctx.m('plugViewStyleContainerOnly'))
    card = 'plain'
  }
  const tintColor = color(style.background, `${styleAt}.background`, ctx)
  if (!layout && tintColor !== null) ctx.note(`${styleAt}.background`, ctx.m('plugViewStyleContainerOnly'))
  const background = !layout ? ctx.styleBackground
    : tintColor !== null ? tint(tintColor)
      : card === 'surface' ? elevated : card === 'tinted' ? tint(ctx.accent) : ctx.styleBackground
  const chosen = color(style.color, `${styleAt}.color`, ctx)
  const toneName = ['good', 'success', 'positive'].includes(raw.tone) ? 'green'
    : ['warn', 'warning', 'caution'].includes(raw.tone) ? 'amber'
      : ['bad', 'danger', 'error', 'negative'].includes(raw.tone) ? 'red'
        : ['info', 'note'].includes(raw.tone) ? 'blue' : null
  const selected = chosen ?? (toneName === null ? null : palette[toneName])
  const requested = selected !== null ? pair(selected) : ['muted', 'secondary'].includes(raw.tone) ? muted : ink
  const foreground = readablePair(requested, background, 4.5, `${styleAt}.color`, ctx)
  const accent = readablePair(pair(ctx.accent), background, 4.5, 'view.accent', ctx, true)
  const secondary = readablePair(muted, background, 4.5, `${styleAt}.muted`, ctx)
  let maxLines = null
  if (Number.isInteger(style.maxLines) && style.maxLines >= 1 && style.maxLines <= spec.maxLines) maxLines = style.maxLines
  else if (!absent(style.maxLines, ctx)) ctx.note(`${styleAt}.maxLines`, ctx.m('plugViewStyleInvalid', '1–20'))
  let columns = []
  const rawColumns = style.columns
  if (Array.isArray(rawColumns) && rawColumns.length > 0 && rawColumns.length <= 8 && rawColumns.every(v => Number.isInteger(v) && v >= 1 && v <= 12)) columns = [...rawColumns]
  else if (!absent(rawColumns, ctx) && rawColumns !== 'equal') ctx.note(`${styleAt}.columns`, ctx.m('plugViewStyleInvalid', 'equal / [1…12] × 1…8'))
  if (!layout && ['padding', 'gap', 'columns', 'dividers'].some(k => Object.hasOwn(style, k))) ctx.note(styleAt, ctx.m('plugViewStyleContainerOnly'))
  if (!textNode && ['size', 'weight', 'italic', 'underline', 'strike', 'maxLines', 'color'].some(k => Object.hasOwn(style, k))) ctx.note(styleAt, ctx.m('plugViewStyleTextOnly'))
  const spans = []
  if (type === 'text' && !absent(raw.spans, ctx)) {
    if (!Array.isArray(raw.spans)) ctx.note(`${path}.spans`, ctx.m('plugViewStyleInvalid', '[{text, …}]'))
    else {
      let characters = 0
      const totalLimit = spec.spansPerView[ctx.p.name]
      for (let i = 0; i < raw.spans.length; i++) {
        if (i >= spec.spansPerText || ctx.richSpans >= totalLimit || characters >= ctx.p.text) {
          ctx.note(`${path}.spans`, ctx.m('plugViewRichLimit'))
          break
        }
        const span = raw.spans[i]
        const at = `${path}.spans[${i}]`
        const original = isMap(span) ? ctx.styleHelpers.str(span.text) : null
        if (original === null) {
          ctx.note(at, ctx.m('plugViewStyleInvalid', '{text, …}'))
          continue
        }
        for (const key of ['link', 'url', 'href', 'action']) if (Object.hasOwn(span, key)) ctx.note(`${at}.${key}`, ctx.m('plugViewStyleReserved'))
        const room = ctx.p.text - characters
        const text = original.length <= room ? original : `${original.slice(0, room)}…`
        if (original.length > room) ctx.note(`${path}.spans`, ctx.m('plugViewRichLimit'))
        characters += Math.min(original.length, room)
        const spanWeight = choice(span.weight, spec.weights, weight, `${at}.weight`, ctx)
        const spanColor = color(span.color, `${at}.color`, ctx)
        const spanBackground = color(span.background, `${at}.background`, ctx)
        const highlight = spanBackground === null ? null : tint(spanBackground)
        const spanForeground = readablePair(spanColor === null ? requested : pair(spanColor), highlight ?? background, 4.5, `${at}.color`, ctx)
        spans.push({ text, color: spanForeground, weight: spanWeight, mono: flag(span, 'mono', at, ctx), background: highlight })
        ctx.richSpans++
      }
    }
  }
  const chartColors = []
  let chartOther = null
  if (type === 'chart' || type === 'progress') {
    spec.chartPalette.forEach((colors, i) => chartColors.push(readablePair(colors.map(numberColor), background, 3, `${path}.palette[${i}]`, ctx)))
    chartOther = readablePair(spec.chartOther.map(numberColor), background, 3, `${path}.palette.other`, ctx)
  }
  return {
    foreground, background, accent, muted: secondary, size, weight,
    italic: flag(style, 'italic', styleAt, ctx), underline: flag(style, 'underline', styleAt, ctx), strike: flag(style, 'strike', styleAt, ctx),
    align: choice(style.align, ['start', 'center', 'end'], 'start', `${styleAt}.align`, ctx), maxLines, card,
    padding: layout ? spacing(style.padding, card === 'plain' ? 0 : 12, `${styleAt}.padding`, ctx) : 0,
    gap: layout ? spacing(style.gap, path === 'view' ? 16 : 12, `${styleAt}.gap`, ctx) : 12,
    columns, dividers: layout && flag(style, 'dividers', styleAt, ctx), spans, chartColors, chartOther,
  }
}
