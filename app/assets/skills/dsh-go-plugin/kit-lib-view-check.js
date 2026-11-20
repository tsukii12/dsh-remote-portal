// Twin of the app's plugin-view parser (app/lib/ui/chat/dsh_ui/: dsh_ui_model.dart,
// dsh_ui_plugin_model.dart, dsh_ui_bind.dart — parseDshUiPluginUncached): the same
// lenient rules, the same paths (`view.children[2].items[0].action`) and the same
// words (lib/messages.json is copied from the app's ARB files). When the app's
// parser changes, change this file the same way; test/parity/ holds the shared
// cases. Zero dependencies.
import { readFileSync } from 'node:fs'
import { initStyles, readStyle, RESERVED_ROLES } from './style-check.js'
import { CONTROL_TYPES, FIGURE_LIMITS, inputBindings, parseControl } from './controls-check.js'
import { resolveFormulas } from './formula.js'

const MESSAGES = JSON.parse(readFileSync(new URL('./messages.json', import.meta.url), 'utf8'))
const VIEW_SCHEMA = JSON.parse(readFileSync(new URL('../schema/view.schema.json', import.meta.url), 'utf8'))

/** Icon names the app knows (the ui.json whitelist). */
const ICONS = new Set(VIEW_SCHEMA.$defs.icon.anyOf[0].enum)

// ── limits (DshUiLimits, DshUiProfile) ────────────────────────────────────

const L = {
  nodes: 40, depth: 6, children: 16, series: 6, points: 60, compareItems: 4, compareRows: 8,
  options: 8, steps: 12, text: 2000, label: 200, title: 80,
}
const P = {
  listItems: 50, tableRows: 50, tableColumns: 8, keyValues: 24, actions: 4, jsonNesting: 64,
  actionArgsBytes: 1024, imageDataBytes: 65536, imageSide: 4096, imagePixels: 4000000,
}

/** The three plugin budgets (docs/design/native-plugins-views.md §5). */
export const BUDGETS = Object.freeze({
  toolCard: Object.freeze({ name: 'toolCard', bytes: 8192, nodes: 40, depth: 6, children: 16, text: L.text }),
  panel: Object.freeze({ name: 'panel', bytes: 32768, nodes: 120, depth: 8, children: 32, text: L.text }),
  strip: Object.freeze({ name: 'strip', bytes: 2048, nodes: 8, depth: 3, children: 4, text: 200 }),
})

const MODEL_TYPES = ['stack', 'row', 'text', 'metric', 'chart', 'compare', 'steps', 'callout', 'options', 'confirm']
const PLUGIN_TYPES = [...MODEL_TYPES, 'list', 'keyValue', 'progress', 'table', 'actions', 'image']

// ── messages ──────────────────────────────────────────────────────────────

/**
 * Internal formatter for the shipped ARB subset: named arguments and plural
 * branches with exact-number selectors plus `other`. The current catalogues
 * contain no offsets, category selectors, # substitution or ICU quoting.
 * It is deliberately not a general MessageFormat implementation. Catalogue
 * tests reject unsupported future syntax instead of silently printing it.
 * Inserted values are appended once and are never reparsed as template text.
 */
export function formatCatalogMessage(pattern, values) {
  if (/'[{}#]|''|#/.test(pattern)) throw new TypeError('Unsupported catalogue quoting or # substitution')
  let at = 0
  const fail = () => { throw new TypeError(`Unsupported catalogue pattern at ${at}: ${pattern}`) }
  const whitespace = () => { while (/\s/.test(pattern[at] ?? '') && at < pattern.length) at++ }
  const token = () => {
    const start = at
    while (at < pattern.length && !/[\s,{}]/.test(pattern[at])) at++
    return pattern.slice(start, at)
  }
  const message = (nested = false) => {
    let out = ''
    while (at < pattern.length) {
      const c = pattern[at++]
      if (c === '}') {
        if (!nested) fail()
        return out
      }
      if (c !== '{') { out += c; continue }
      whitespace()
      const name = token()
      if (!name || !Object.hasOwn(values, name)) fail()
      whitespace()
      if (pattern[at] === '}') {
        at++
        out += String(values[name])
        continue
      }
      if (pattern[at++] !== ',') fail()
      whitespace()
      if (token() !== 'plural') fail()
      whitespace()
      if (pattern[at++] !== ',') fail()
      let selected, fallback
      const selectors = new Set()
      while (true) {
        whitespace()
        if (pattern[at] === '}') { at++; break }
        const selector = token()
        if (selector !== 'other' && !/^=-?\d+(?:\.\d+)?$/.test(selector)) fail()
        if (selectors.has(selector)) fail()
        selectors.add(selector)
        whitespace()
        if (pattern[at++] !== '{') fail()
        const branch = message(true)
        if (selector === 'other') fallback = branch
        else if (typeof values[name] === 'number' && values[name] === Number(selector.slice(1))) selected = branch
      }
      if (fallback === undefined) fail()
      out += selected ?? fallback
    }
    if (nested) fail()
    return out
  }
  return message()
}

function messages(lang) {
  const table = MESSAGES[lang === 'en' ? 'en' : 'zh']
  return (key, ...args) => {
    const text = table[key]
    if (text === undefined) return key
    const names = MESSAGES.params[key] ?? []
    return formatCatalogMessage(text, Object.fromEntries(names.map((name, i) => [name, args[i]])))
  }
}

// ── bindings (dsh_ui_bind.dart) ───────────────────────────────────────────

/** A binding that found nothing. */
const MISSING = Object.freeze({ missing: true })
const MISSING_TEXT = '—'
const isMissing = (v) => v === MISSING
const isMap = (v) => typeof v === 'object' && v !== null && !Array.isArray(v) && v !== MISSING
const isNum = (v) => typeof v === 'number'

function bindingPath(value) {
  if (isMap(value)) {
    const keys = Object.keys(value)
    if (keys.length === 1 && keys[0] === '$' && typeof value.$ === 'string') return value.$
  }
  return null
}

const SEGMENT = /\.([^.[\]]+)|\[(\d+)\]/y

function parsePath(path) {
  if (!path.startsWith('data')) return null
  const segments = []
  let at = 4
  while (at < path.length) {
    SEGMENT.lastIndex = at
    const m = SEGMENT.exec(path)
    if (m === null) return null
    segments.push(m[1] !== undefined ? m[1] : Number.parseInt(m[2], 10))
    if (segments.length > 16) return null
    at = SEGMENT.lastIndex
  }
  return segments
}

function lookup(data, segments) {
  let current = data
  for (const segment of segments) {
    if (isMap(current)) {
      const key = typeof segment === 'number' ? String(segment) : segment
      if (!Object.prototype.hasOwnProperty.call(current, key)) return MISSING
      current = current[key]
    } else if (Array.isArray(current)) {
      const index = typeof segment === 'number' ? segment : /^[+-]?\d+$/.test(segment) ? Number.parseInt(segment, 10) : null
      if (index === null || index < 0 || index >= current.length) return MISSING
      current = current[index]
    } else {
      return MISSING
    }
  }
  return current === null || current === undefined ? MISSING : current
}

function resolveBinding(value, data) {
  const path = bindingPath(value)
  if (path === null) return value
  const segments = parsePath(path)
  if (segments === null) return MISSING
  return lookup(data, segments)
}

function resolveBindings(value, data, maxDepth = 64) {
  const walk = (v, depth) => {
    if (depth > maxDepth) return MISSING
    if (bindingPath(v) !== null) return resolveBinding(v, data)
    if (isMap(v)) {
      const out = {}
      for (const [k, x] of Object.entries(v)) {
        out[k] = k === 'type' && bindingPath(x) !== null ? MISSING : walk(x, depth + 1)
      }
      return out
    }
    if (Array.isArray(v)) return v.map((x) => walk(x, depth + 1))
    return v
  }
  return walk(value, 0)
}

// ── size and nesting (measureDshUiJson) ───────────────────────────────────

function stringBytes(s, room) {
  if (s.length > room) return s.length + 2
  let n = 2
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i)
    if (c === 0x22 || c === 0x5c) n += 2
    else if (c < 0x20) n += 6
    else if (c < 0x80) n += 1
    else if (c < 0x800) n += 2
    else if (c >= 0xd800 && c <= 0xdfff) n += 2
    else n += 3
  }
  return n
}

/** Dart's `'$n'` for a JSON number: ints plainly, doubles with a fraction or exponent. */
function dartNum(n) {
  if (!Number.isFinite(n)) return 'null'
  if (Number.isInteger(n) && Math.abs(n) < 1e21) return String(n)
  return String(n)
}

export function measureJson(value, maxBytes, maxDepth = 64) {
  let bytes = 0
  let tooDeep = false
  const add = (n) => (bytes += n) <= maxBytes
  const walk = (v, depth) => {
    if (depth > maxDepth) {
      tooDeep = true
      return false
    }
    if (v === null || v === undefined || v === MISSING) return add(4)
    if (typeof v === 'boolean') return add(v ? 4 : 5)
    if (isNum(v)) return add(Number.isFinite(v) ? dartNum(v).length : 4)
    if (typeof v === 'string') return add(stringBytes(v, maxBytes - bytes))
    if (Array.isArray(v)) {
      if (!add(2 + (v.length === 0 ? 0 : v.length - 1))) return false
      for (const item of v) if (!walk(item, depth + 1)) return false
      return true
    }
    if (typeof v === 'object') {
      const entries = Object.entries(v)
      if (!add(2 + (entries.length === 0 ? 0 : entries.length - 1))) return false
      for (const [k, x] of entries) {
        if (!add(stringBytes(k, maxBytes - bytes) + 1)) return false
        if (!walk(x, depth + 1)) return false
      }
      return true
    }
    return add(4)
  }
  const ok = walk(value, 1)
  return { bytes, overBytes: !ok && !tooDeep, tooDeep, ok: ok }
}

// ── value formatting (formatDshUiValue) ───────────────────────────────────

function group(digits) {
  const negative = digits.startsWith('-')
  const body = negative ? digits.slice(1) : digits
  const dot = body.indexOf('.')
  const whole = dot < 0 ? body : body.slice(0, dot)
  const frac = dot < 0 ? '' : body.slice(dot)
  let out = ''
  for (let i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 === 0) out += ','
    out += whole[i]
  }
  return `${negative ? '-' : ''}${out}${frac}`
}

export function formatValue(value) {
  if (Number.isInteger(value) && Math.abs(value) < 1e15) {
    const whole = Math.round(value)
    const s = Object.is(whole, -0) ? '0' : String(whole)
    return Math.abs(whole) >= 10000 ? group(s) : s
  }
  const fixed = value.toFixed(2).replace(/\.?0+$/, '')
  return Math.abs(value) >= 10000 ? group(fixed) : fixed
}

// ── the parser ────────────────────────────────────────────────────────────

class Ctx {
  constructor(profile, m) {
    this.p = profile
    this.m = m
    this.nodes = 0
    this.primaryUsed = false
    this.version = 1
    this.inputFields = 0
    this.inputBindings = new Set()
    this.inForm = false
    this.issues = []
    this.counts = { components: 0, placeholders: 0, empty: 0, truncated: 0 }
  }

  broken(path, message, type) {
    const issue = { path, message, kind: 'broken' }
    this.issues.push(issue)
    this.counts.placeholders++
    return { kind: 'placeholder', path, issue, type }
  }

  note(path, message) {
    this.issues.push({ path, message, kind: 'note' })
  }
}

/** A value quoted in a problem: short JSON, never throws (dsh_ui_model.dart `_show`). */
function show(value) {
  if (isMissing(value)) return MISSING_TEXT
  if (isMap(value)) return '{…}'
  if (Array.isArray(value)) return '[…]'
  if (typeof value === 'string') return JSON.stringify(value.length <= 40 ? value : `${value.slice(0, 40)}…`)
  if (isNum(value)) return Number.isFinite(value) ? String(value) : Number.isNaN(value) ? 'NaN' : value > 0 ? 'Infinity' : '-Infinity'
  return String(value)
}

function str(value) {
  if (typeof value === 'string') return value
  if (isMissing(value)) return MISSING_TEXT
  if (isNum(value) && Number.isFinite(value)) return formatValue(value)
  if (typeof value === 'boolean') return String(value)
  return null
}

const clip = (text, max) => (text === null || text === undefined || text.length <= max ? text : `${text.slice(0, max)}…`)

const isEmptyValue = (v) => isMissing(v) || (Array.isArray(v) && v.length === 0)

const node = (path, type, extra = {}) => ({ kind: 'node', path, type, ...extra })
const empty = (ctx, path, type) => {
  ctx.counts.empty++
  return { kind: 'empty', path, type }
}

function parseNode(raw, path, depth, ctx) {
  const m = ctx.m
  if (!isMap(raw)) return ctx.broken(path, m('viewUiExpectedObject'))
  if (depth > ctx.p.depth) return ctx.broken(path, m('viewUiDepthLimit', depth, ctx.p.depth))
  ctx.nodes += 1
  const type = raw.type
  const types = ctx.version >= 2 ? [...PLUGIN_TYPES, ...CONTROL_TYPES] : PLUGIN_TYPES
  if (typeof type !== 'string' || !types.includes(type)) {
    const shown = type === undefined || type === null || isMissing(type) || isMap(type)
      ? m('viewUiMissingType')
      : m('viewUiUnknownComponent', show(type))
    return ctx.broken(`${path}.type`, m('viewUiAvailableTypes', shown, types.join(', ')))
  }
  if (ctx.version === 2 && RESERVED_ROLES.has(raw.role)) return ctx.broken(`${path}.role`, m('plugViewStyleReserved'), type)
  ctx.counts.components++
  const previousBackground = ctx.styleBackground
  if (ctx.version === 2) {
    const style = readStyle(raw, path, ctx)
    ctx.styles.set(path, style)
    ctx.styleBackground = style.background
  }
  try {
  switch (type) {
    case 'list': return parseList(raw, path, ctx)
    case 'keyValue': return parseKeyValue(raw, path, ctx)
    case 'progress': return parseProgress(raw, path, ctx)
    case 'table': return parseTable(raw, path, ctx)
    case 'actions': return parseActions(raw, path, ctx)
    case 'image': return parseImage(raw, path, ctx)
    case 'confirm': ctx.primaryUsed = true; return parseConfirm(raw, path, ctx)
    case 'stack':
    case 'row': return parseLayout(raw, path, depth, ctx, type)
    case 'text': return parseText(raw, path, ctx)
    case 'metric': return parseMetric(raw, path, ctx)
    case 'chart': return parseChart(raw, path, ctx)
    case 'compare': return parseCompare(raw, path, ctx)
    case 'steps': return parseSteps(raw, path, ctx)
    case 'callout': return parseCallout(raw, path, ctx)
    case 'options': return parseOptions(raw, path, ctx)
    default: return parseControl(raw, path, depth, ctx, { node, parseNode, pluginAction, parseImage, pluginTone, isMissing, icon, str, empty, isEmptyValue })
  }
  } finally {
    ctx.styleBackground = previousBackground
  }
}

function parseLayout(raw, path, depth, ctx, type) {
  const m = ctx.m
  const children = raw.children
  if (isEmptyValue(children)) return empty(ctx, path, type)
  if (!Array.isArray(children) || children.length === 0) {
    return ctx.broken(`${path}.children`, m('viewUiExpectedChildren', ctx.p.children), type)
  }
  const built = []
  let dropped = 0
  for (let i = 0; i < children.length; i++) {
    if (i >= ctx.p.children || ctx.nodes >= ctx.p.nodes) {
      dropped = children.length - i
      break
    }
    built.push(parseNode(children[i], `${path}.children[${i}]`, depth + 1, ctx))
  }
  if (dropped > 0) {
    ctx.counts.truncated++
    ctx.note(`${path}.children`, ctx.nodes >= ctx.p.nodes ? m('viewUiNodeLimit', ctx.p.nodes, dropped) : m('viewUiChildLimit', ctx.p.children, dropped))
  }
  return node(path, type, { children: built })
}

function parseText(raw, path, ctx) {
  const m = ctx.m
  const text = str(raw.text)
  if (text === null) return ctx.broken(`${path}.text`, m('viewUiExpectedString'), 'text')
  const max = ctx.p.text
  if (text.length > max) {
    ctx.counts.truncated++
    ctx.note(`${path}.text`, m('viewUiTextLimit', text.length, max))
  }
  return node(path, 'text')
}

function parseMetric(raw, path, ctx) {
  const m = ctx.m
  const label = str(raw.label)
  if (label === null) return ctx.broken(`${path}.label`, m('viewUiExpectedString'), 'metric')
  const value = raw.value
  if (isNum(value)) {
    if (!Number.isFinite(value)) return ctx.broken(`${path}.value`, m('viewUiExpectedFinite'), 'metric')
  } else if (typeof value !== 'string' && typeof value !== 'boolean' && !isMissing(value)) {
    return ctx.broken(`${path}.value`, m('viewUiExpectedStringNumber'), 'metric')
  }
  pluginTone(raw.tone, `${path}.tone`, ctx, false)
  if (ctx.version >= 2) metricTrend(raw.trend, `${path}.trend`, ctx)
  return node(path, 'metric')
}

// v2 `metric.trend`: 2–30 finite numbers or nulls, at least two numbers.
function metricTrend(raw, path, ctx) {
  if (raw === null || raw === undefined || isMissing(raw)) return
  const bad = () => ctx.note(path, ctx.m('plugViewBadTrend', FIGURE_LIMITS.trendPoints))
  if (!Array.isArray(raw) || raw.length < 2 || raw.length > FIGURE_LIMITS.trendPoints) return bad()
  let numbers = 0
  for (const v of raw) {
    if (v === null || v === undefined || isMissing(v)) continue
    if (!isNum(v) || !Number.isFinite(v)) return bad()
    numbers++
  }
  if (numbers < 2) bad()
}

function pluginTone(raw, path, ctx, muted = true) {
  if (raw === null || raw === undefined || isMissing(raw)) return null
  let tone = null
  if (['good', 'success', 'positive'].includes(raw)) tone = 'good'
  else if (['warn', 'warning', 'caution'].includes(raw)) tone = 'warn'
  else if (['bad', 'danger', 'error', 'negative'].includes(raw)) tone = 'bad'
  else if (['info', 'note'].includes(raw)) tone = 'info'
  else if (muted && ['muted', 'secondary'].includes(raw)) tone = 'muted'
  if (tone === null) ctx.note(path, ctx.m('plugViewUnknownTone', show(raw)))
  return tone
}

function chartValue(value, onBad) {
  if (isMissing(value)) return null
  if (isNum(value)) {
    if (Number.isFinite(value)) return value
    onBad()
    return null
  }
  if (typeof value === 'string') {
    let s = value.trim().replaceAll(',', '').replaceAll('_', '')
    if (s.endsWith('%')) s = s.slice(0, -1).trim()
    const parsed = dartDouble(s)
    if (parsed !== null && Number.isFinite(parsed)) return parsed
  }
  if (value !== null && value !== undefined) onBad()
  return null
}

/** Dart double.tryParse: a decimal literal (optionally signed, exponent), Infinity, NaN. */
function dartDouble(s) {
  if (/^[+-]?(\d+\.?\d*([eE][+-]?\d+)?|\.\d+([eE][+-]?\d+)?)$/.test(s)) return Number(s)
  if (/^[+-]?Infinity$/.test(s)) return s.startsWith('-') ? -Infinity : Infinity
  if (/^[+-]?NaN$/.test(s)) return Number.NaN
  return null
}

function parseChart(raw, path, ctx) {
  const m = ctx.m
  const rawKind = raw.kind
  const KINDS = {
    bar: ['bar', 'column', 'columns'],
    hbar: ['hbar', 'barh', 'horizontal', 'horizontalBar'],
    line: ['line', 'area', 'spline'],
    donut: ['donut', 'pie', 'doughnut', 'ring'],
  }
  let kind = rawKind === undefined || rawKind === null || isMissing(rawKind) ? 'bar' : Object.keys(KINDS).find((k) => KINDS[k].includes(rawKind)) ?? null
  if (kind === null) {
    ctx.note(`${path}.kind`, m('viewUiUnknownChart', show(rawKind)))
    kind = 'bar'
  }
  const rawCategories = raw.categories
  if (isEmptyValue(rawCategories) || isEmptyValue(raw.series)) return empty(ctx, path, 'chart')
  if (!Array.isArray(rawCategories) || rawCategories.length === 0) {
    return ctx.broken(`${path}.categories`, m('viewUiExpectedCategories'), 'chart')
  }
  let truncated = false
  let categories = rawCategories.slice(0, L.points + 1)
  if (categories.length > L.points) {
    ctx.note(`${path}.categories`, m('viewUiCategoryLimit', rawCategories.length, L.points))
    categories = categories.slice(0, L.points)
    truncated = true
  }
  let rawSeries = raw.series
  if (isMap(rawSeries)) rawSeries = [rawSeries]
  if (Array.isArray(rawSeries) && rawSeries.length > 0 && rawSeries.every((e) => e === null || isNum(e) || typeof e === 'string')) {
    rawSeries = [{ values: rawSeries }]
  }
  if ((rawSeries === undefined || rawSeries === null) && Array.isArray(raw.values)) rawSeries = [{ values: raw.values }]
  if (!Array.isArray(rawSeries) || rawSeries.length === 0) {
    return ctx.broken(`${path}.series`, m('viewUiExpectedSeries', '{name?, values}'), 'chart')
  }
  const series = []
  for (let i = 0; i < rawSeries.length; i++) {
    const item = rawSeries[i]
    const at = `${path}.series[${i}]`
    const values = isMap(item) ? item.values : item
    if (!Array.isArray(values)) {
      ctx.note(`${at}.values`, m('viewUiSkippedSeries'))
      continue
    }
    if (values.length !== categories.length && values.length !== rawCategories.length) {
      ctx.note(`${at}.values`, m('viewUiValuesCategories', values.length, rawCategories.length))
    }
    let bad = 0
    const parsed = []
    for (let j = 0; j < categories.length; j++) parsed.push(j < values.length ? chartValue(values[j], () => bad++) : null)
    if (bad > 0) ctx.note(`${at}.values`, m('viewUiNonFiniteValues', bad))
    series.push(parsed)
  }
  if (series.length === 0) return ctx.broken(`${path}.series`, m('viewUiNoSeries'), 'chart')
  let kept = series
  if (kind === 'donut' && kept.length > 1) {
    ctx.note(`${path}.series`, m('viewUiDonutSeries', kept.length - 1))
    kept = kept.slice(0, 1)
    truncated = true
  } else if (kept.length > L.series) {
    ctx.note(`${path}.series`, m('viewUiSeriesLimit', kept.length, L.series))
    kept = kept.slice(0, L.series)
    truncated = true
  }
  if (kept.every((s) => s.every((v) => v === null))) return empty(ctx, path, 'chart')
  if (truncated) ctx.counts.truncated++
  return node(path, 'chart')
}

function pair(raw) {
  if (Array.isArray(raw) && raw.length > 0) return str(raw[0]) === null ? null : true
  if (isMap(raw)) return str(raw.label ?? raw.name) === null ? null : true
  return null
}

function parseCompare(raw, path, ctx) {
  const m = ctx.m
  const rawItems = raw.items
  if (isEmptyValue(rawItems)) return empty(ctx, path, 'compare')
  if (!Array.isArray(rawItems) || rawItems.length === 0) {
    return ctx.broken(`${path}.items`, m('viewUiExpectedCompare', L.compareItems, '{title, badge?, rows}'), 'compare')
  }
  let items = 0
  let truncated = false
  for (let i = 0; i < rawItems.length; i++) {
    const item = rawItems[i]
    const at = `${path}.items[${i}]`
    if (items >= L.compareItems) {
      ctx.note(`${path}.items`, m('viewUiItemLimit', rawItems.length, L.compareItems))
      truncated = true
      break
    }
    if (!isMap(item)) {
      ctx.note(at, m('viewUiSkippedCompare', '{title, badge?, rows}'))
      continue
    }
    const title = str(item.title)
    if (title === null || title.trim() === '') {
      ctx.note(`${at}.title`, m('viewUiSkippedItemLabel'))
      continue
    }
    const rawRows = item.rows
    const entries = Array.isArray(rawRows) ? rawRows : isMap(rawRows) ? Object.entries(rawRows).map(([k, v]) => [k, v]) : []
    let rows = 0
    for (let r = 0; r < entries.length; r++) {
      if (rows >= L.compareRows) {
        ctx.note(`${at}.rows`, m('viewUiRowLimit', entries.length, L.compareRows))
        truncated = true
        break
      }
      if (pair(entries[r]) === null) {
        ctx.note(`${at}.rows[${r}]`, m('viewUiSkippedRow'))
        continue
      }
      rows++
    }
    items++
  }
  if (items === 0) return ctx.broken(`${path}.items`, m('viewUiNoItems'), 'compare')
  if (truncated) ctx.counts.truncated++
  return node(path, 'compare')
}

const STATUS = {
  done: ['done', 'completed', 'complete', 'success'],
  current: ['current', 'active', 'doing', 'in_progress', 'running'],
  todo: ['todo', 'pending', 'waiting'],
  failed: ['failed', 'error', 'blocked'],
}

function parseSteps(raw, path, ctx) {
  const m = ctx.m
  const rawItems = raw.items
  if (isEmptyValue(rawItems)) return empty(ctx, path, 'steps')
  if (!Array.isArray(rawItems) || rawItems.length === 0) {
    return ctx.broken(`${path}.items`, m('viewUiExpectedSteps', '{label, status, detail?}'), 'steps')
  }
  let items = 0
  for (let i = 0; i < rawItems.length; i++) {
    if (items >= L.steps) {
      ctx.note(`${path}.items`, m('viewUiStepLimit', rawItems.length, L.steps))
      ctx.counts.truncated++
      break
    }
    const item = rawItems[i]
    const at = `${path}.items[${i}]`
    if (typeof item === 'string') {
      items++
      continue
    }
    if (!isMap(item)) {
      ctx.note(at, m('viewUiSkippedStep', '{label, status, detail?}'))
      continue
    }
    const label = str(item.label ?? item.title)
    if (label === null) {
      ctx.note(`${at}.label`, m('viewUiSkippedStepLabel'))
      continue
    }
    const rawStatus = item.status
    const known = rawStatus === undefined || rawStatus === null || isMissing(rawStatus) || Object.values(STATUS).some((list) => list.includes(rawStatus))
    if (!known) ctx.note(`${at}.status`, m('viewUiUnknownStatus', show(rawStatus)))
    items++
  }
  if (items === 0) return ctx.broken(`${path}.items`, m('viewUiNoSteps'), 'steps')
  return node(path, 'steps')
}

function parseCallout(raw, path, ctx) {
  const m = ctx.m
  const text = str(raw.text)
  if (text === null) return ctx.broken(`${path}.text`, m('viewUiExpectedString'), 'callout')
  const rawTone = raw.tone
  const TONES = ['info', 'note', 'good', 'success', 'tip', 'warn', 'warning', 'caution', 'bad', 'danger', 'error']
  if (rawTone !== undefined && rawTone !== null && !isMissing(rawTone) && !TONES.includes(rawTone)) {
    ctx.note(`${path}.tone`, m('viewUiUnknownCalloutTone', show(rawTone)))
  }
  if (text.length > ctx.p.text) {
    ctx.counts.truncated++
    ctx.note(`${path}.text`, m('viewUiTextLimit', text.length, ctx.p.text))
  }
  return node(path, 'callout')
}

function parseOptions(raw, path, ctx) {
  const m = ctx.m
  const rawOptions = raw.options
  if (isEmptyValue(rawOptions)) return empty(ctx, path, 'options')
  if (!Array.isArray(rawOptions) || rawOptions.length === 0) {
    return ctx.broken(`${path}.options`, m('viewUiExpectedOptions', L.options, '{label, description?}'), 'options')
  }
  let count = 0
  const seen = new Set()
  for (let i = 0; i < rawOptions.length; i++) {
    if (count >= L.options) {
      ctx.note(`${path}.options`, m('viewUiOptionLimit', rawOptions.length, L.options))
      ctx.counts.truncated++
      break
    }
    const item = rawOptions[i]
    const at = `${path}.options[${i}]`
    const label = str(isMap(item) ? item.label : item)?.trim() ?? null
    if (label === null || label === '') {
      ctx.note(`${at}.label`, m('viewUiSkippedItemLabel'))
      continue
    }
    const rawValue = isMap(item) ? item.value : null
    const value = typeof rawValue === 'string' && rawValue !== '' ? clip(rawValue, L.label) : null
    const key = value ?? label
    if (seen.has(key)) {
      ctx.note(`${at}.label`, m('viewUiDuplicateLabel', show(label)))
      continue
    }
    seen.add(key)
    count++
  }
  if (count === 0) return ctx.broken(`${path}.options`, m('viewUiNoOptions'), 'options')
  actionId(raw.id, `${path}.id`, ctx)
  return node(path, 'options')
}

function parseConfirm(raw, path, ctx) {
  actionId(raw.id, `${path}.id`, ctx)
  return node(path, 'confirm')
}

const ACTION_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/

function actionId(raw, path, ctx) {
  if (typeof raw === 'string' && ACTION_ID.test(raw)) return raw
  ctx.note(path, ctx.m('plugViewBadActionId', show(raw ?? null)))
  return null
}

function pluginAction(raw, path, ctx) {
  const m = ctx.m
  if (raw === null || raw === undefined || isMissing(raw)) return null
  if (typeof raw === 'string') return actionId(raw, path, ctx)
  if (!isMap(raw)) {
    ctx.note(path, m('plugViewBadAction', '{id, args?}'))
    return null
  }
  const id = actionId(raw.id, `${path}.id`, ctx)
  if (id === null) return null
  const args = raw.args
  if (args === null || args === undefined || isMissing(args)) return id
  if (!isMap(args)) {
    ctx.note(`${path}.args`, m('plugViewBadAction', '{id, args?}'))
    return null
  }
  if (!measureJson(args, P.actionArgsBytes, 16).ok) {
    ctx.note(`${path}.args`, m('plugViewArgsLimit', P.actionArgsBytes))
    return null
  }
  return id
}

function icon(raw, path, ctx) {
  if (raw === null || raw === undefined || isMissing(raw)) return null
  if (typeof raw === 'string' && ICONS.has(raw)) return raw
  ctx.note(path, ctx.m('plugViewUnknownIcon', show(raw)))
  return ''
}

function parseList(raw, path, ctx) {
  const m = ctx.m
  const rawItems = raw.items
  if (isEmptyValue(rawItems)) return empty(ctx, path, 'list')
  const shape = '{title, subtitle?, trailing?, icon?, tone?, action?}'
  if (!Array.isArray(rawItems)) return ctx.broken(`${path}.items`, m('plugViewExpectedItems', shape), 'list')
  let items = 0
  for (let i = 0; i < rawItems.length; i++) {
    if (items >= P.listItems) {
      ctx.counts.truncated++
      ctx.note(`${path}.items`, m('viewUiItemLimit', rawItems.length, P.listItems))
      break
    }
    const item = rawItems[i]
    const at = `${path}.items[${i}]`
    if (!isMap(item)) {
      ctx.note(at, m('plugViewSkippedItem', shape))
      continue
    }
    const title = str(item.title)?.trim() ?? null
    if (title === null || title === '') {
      ctx.note(`${at}.title`, m('viewUiSkippedItemLabel'))
      continue
    }
    icon(item.icon, `${at}.icon`, ctx)
    pluginTone(item.tone, `${at}.tone`, ctx)
    pluginAction(item.action, `${at}.action`, ctx)
    items++
  }
  if (items === 0) return ctx.broken(`${path}.items`, m('viewUiNoItems'), 'list')
  return node(path, 'list')
}

function parseKeyValue(raw, path, ctx) {
  const m = ctx.m
  const rawItems = raw.items
  const shape = '[label, value] | {label, value, tone?}'
  const entries = Array.isArray(rawItems)
    ? rawItems
    : isMap(rawItems) ? Object.entries(rawItems).slice(0, P.keyValues + 1).map(([k, v]) => [k, v]) : []
  if (isEmptyValue(rawItems) || (isMap(rawItems) && Object.keys(rawItems).length === 0)) return empty(ctx, path, 'keyValue')
  if (!Array.isArray(rawItems) && !isMap(rawItems)) return ctx.broken(`${path}.items`, m('plugViewExpectedItems', shape), 'keyValue')
  const total = isMap(rawItems) ? Object.keys(rawItems).length : entries.length
  let items = 0
  for (let i = 0; i < entries.length; i++) {
    if (items >= P.keyValues) {
      ctx.counts.truncated++
      ctx.note(`${path}.items`, m('viewUiItemLimit', total, P.keyValues))
      break
    }
    const entry = entries[i]
    const at = `${path}.items[${i}]`
    let label = null
    let tone
    if (Array.isArray(entry) && entry.length > 0) {
      label = str(entry[0])
    } else if (isMap(entry)) {
      label = str(entry.label ?? entry.name)
      tone = entry.tone
    }
    if (label === null || label.trim() === '') {
      ctx.note(at, m('plugViewSkippedItem', shape))
      continue
    }
    pluginTone(tone, `${at}.tone`, ctx)
    items++
  }
  if (items === 0) return ctx.broken(`${path}.items`, m('viewUiNoItems'), 'keyValue')
  return node(path, 'keyValue')
}

function number(raw, path, ctx) {
  if (raw === null || raw === undefined || isMissing(raw)) return null
  let bad = false
  const value = chartValue(raw, () => { bad = true })
  if (bad || value === null) {
    ctx.note(path, ctx.m('viewUiExpectedFinite'))
    return null
  }
  return value
}

function parseProgress(raw, path, ctx) {
  const m = ctx.m
  if (!Object.prototype.hasOwnProperty.call(raw, 'value')) return ctx.broken(`${path}.value`, m('viewUiExpectedFinite'), 'progress')
  number(raw.value, `${path}.value`, ctx)
  const max = number(raw.max, `${path}.max`, ctx) ?? 100
  if (max <= 0) ctx.note(`${path}.max`, m('plugViewBadMax'))
  pluginTone(raw.tone, `${path}.tone`, ctx, false)
  // v2 `shape`: bar (the default) or ring.
  const shape = raw.shape
  if (ctx.version >= 2 && shape !== null && shape !== undefined && !isMissing(shape) && shape !== 'bar' && shape !== 'ring') {
    ctx.note(`${path}.shape`, ctx.m('plugViewStyleInvalid', 'bar / ring'))
  }
  return node(path, 'progress')
}

function parseTable(raw, path, ctx) {
  const m = ctx.m
  const rawColumns = raw.columns
  const rawRows = raw.rows
  if (isEmptyValue(rawRows)) return empty(ctx, path, 'table')
  if (!Array.isArray(rawColumns) || rawColumns.length === 0) {
    if (isMissing(rawColumns)) return empty(ctx, path, 'table')
    return ctx.broken(`${path}.columns`, m('plugViewExpectedItems', 'label | {label, align?}'), 'table')
  }
  if (!Array.isArray(rawRows)) return ctx.broken(`${path}.rows`, m('plugViewExpectedItems', '[cell, …]'), 'table')
  let truncated = false
  if (rawColumns.length > P.tableColumns) {
    ctx.note(`${path}.columns`, m('plugViewColumnLimit', rawColumns.length, P.tableColumns))
    truncated = true
  }
  let rows = 0
  for (let r = 0; r < rawRows.length; r++) {
    if (rows >= P.tableRows) {
      ctx.note(`${path}.rows`, m('viewUiRowLimit', rawRows.length, P.tableRows))
      truncated = true
      break
    }
    if (!Array.isArray(rawRows[r])) {
      ctx.note(`${path}.rows[${r}]`, m('plugViewSkippedItem', '[cell, …]'))
      continue
    }
    rows++
  }
  if (rows === 0) return empty(ctx, path, 'table')
  if (truncated) ctx.counts.truncated++
  return node(path, 'table')
}

function parseActions(raw, path, ctx) {
  const m = ctx.m
  const rawItems = raw.items
  const shape = '{label, icon?, style?, action}'
  if (isEmptyValue(rawItems)) return empty(ctx, path, 'actions')
  if (!Array.isArray(rawItems)) return ctx.broken(`${path}.items`, m('plugViewExpectedItems', shape), 'actions')
  let items = 0
  for (let i = 0; i < rawItems.length; i++) {
    if (items >= P.actions) {
      ctx.note(`${path}.items`, m('viewUiItemLimit', rawItems.length, P.actions))
      break
    }
    const item = rawItems[i]
    const at = `${path}.items[${i}]`
    if (!isMap(item)) {
      ctx.note(at, m('plugViewSkippedItem', shape))
      continue
    }
    const label = str(item.label)?.trim() ?? null
    if (label === null || label === '') {
      ctx.note(`${at}.label`, m('viewUiSkippedItemLabel'))
      continue
    }
    const act = pluginAction(item.action, `${at}.action`, ctx)
    if (act === null) {
      if (item.action === null || item.action === undefined) ctx.note(`${at}.action`, m('plugViewBadAction', '{id, args?}'))
      continue
    }
    let primary = item.style === 'primary'
    if (primary && ctx.version === 2) {
      ctx.note(`${at}.style`, m('plugViewStyleReserved'))
      primary = false
    }
    if (primary && ctx.primaryUsed) {
      ctx.note(`${at}.style`, m('plugViewOnePrimary'))
      primary = false
    }
    if (primary) ctx.primaryUsed = true
    icon(item.icon, `${at}.icon`, ctx)
    items++
  }
  if (items === 0) return ctx.broken(`${path}.items`, m('viewUiNoItems'), 'actions')
  return node(path, 'actions')
}

const DATA_IMAGE = /^data:image\/(png|jpeg|jpg|webp|gif);base64,/i
/** `asset:icons/a.png`: a file in the plugin's `dshGo.assets` directory. */
const ASSET_REF = /^asset:([A-Za-z0-9_~-][A-Za-z0-9._~-]*(\/[A-Za-z0-9_~-][A-Za-z0-9._~-]*)*)$/
const ASSET_EXT = /\.(png|jpe?g|webp|gif)$/i

function parseImage(raw, path, ctx) {
  const m = ctx.m
  const src = raw.src
  const at = `${path}.src`
  if (typeof src === 'string' && DATA_IMAGE.test(src)) {
    dataSource(src, at, ctx)
  } else if (typeof src === 'string' && src.length <= 512 && ASSET_REF.test(src) && ASSET_EXT.test(src)) {
    // the plugin's own image
  } else if (!isMissing(src)) {
    ctx.note(at, m('plugViewBadImageSource'))
  }
  const rawAspect = raw.aspect
  if (rawAspect !== null && rawAspect !== undefined && !isMissing(rawAspect)) {
    const a = isNum(rawAspect) ? rawAspect : Number.NaN
    if (!(Number.isFinite(a) && a >= 0.25 && a <= 4)) ctx.note(`${path}.aspect`, m('plugViewBadAspect'))
  }
  return node(path, 'image')
}

function dataSource(src, path, ctx) {
  const m = ctx.m
  if (src.length > P.imageDataBytes) {
    ctx.note(path, m('plugViewImageTooLarge', P.imageDataBytes))
    return
  }
  const body = src.slice(src.indexOf(',') + 1).replace(/\s/g, '')
  if (!/^[A-Za-z0-9+/_-]*={0,2}$/.test(body) || body.length % 4 === 1) {
    ctx.note(path, m('plugViewImageDecode'))
    return
  }
  const size = imageSize(Buffer.from(body, 'base64'))
  if (size === null) {
    ctx.note(path, m('plugViewImageDecode'))
    return
  }
  const [w, h] = size
  if (w <= 0 || h <= 0 || w > P.imageSide || h > P.imageSide || w * h > P.imagePixels) ctx.note(path, m('plugViewImagePixels'))
}

/** PNG / GIF / JPEG / WebP width and height from the header (dshUiImageSize). */
export function imageSize(b) {
  const u16be = (i) => (b[i] << 8) | b[i + 1]
  const u16le = (i) => b[i] | (b[i + 1] << 8)
  const u24le = (i) => b[i] | (b[i + 1] << 8) | (b[i + 2] << 16)
  const u32be = (i) => ((b[i] << 24) >>> 0) + ((b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3])
  const at = (i, sig) => {
    const bytes = typeof sig === 'string' ? [...sig].map((c) => c.charCodeAt(0)) : sig
    if (i + bytes.length > b.length) return false
    return bytes.every((v, k) => b[i + k] === v)
  }
  if (at(0, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
    if (b.length < 24 || !at(12, 'IHDR')) return null
    return [u32be(16) | 0, u32be(20) | 0]
  }
  if (at(0, 'GIF87a') || at(0, 'GIF89a')) {
    if (b.length < 10) return null
    return [u16le(6), u16le(8)]
  }
  if (at(0, [0xff, 0xd8])) {
    let i = 2
    while (i + 9 < b.length) {
      if (b[i] !== 0xff) return null
      const marker = b[i + 1]
      if (marker === 0xff) { i++; continue }
      if (marker === 0xd8 || (marker >= 0xd0 && marker <= 0xd7) || marker === 0x01) { i += 2; continue }
      const length = u16be(i + 2)
      const sof = marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc
      if (sof) return [u16be(i + 7), u16be(i + 5)]
      if (length < 2) return null
      i += 2 + length
    }
    return null
  }
  if (at(0, 'RIFF') && at(8, 'WEBP') && b.length >= 30) {
    if (at(12, 'VP8 ')) {
      if (!at(23, [0x9d, 0x01, 0x2a])) return null
      return [u16le(26) & 0x3fff, u16le(28) & 0x3fff]
    }
    if (at(12, 'VP8L')) {
      if (b[20] !== 0x2f) return null
      const bits = (b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24)) >>> 0
      return [(bits & 0x3fff) + 1, ((bits >>> 14) & 0x3fff) + 1]
    }
    if (at(12, 'VP8X')) return [u24le(24) + 1, u24le(27) + 1]
  }
  return null
}

// ── entry ─────────────────────────────────────────────────────────────────

/**
 * Check one plugin view like the app parses it.
 * @param {unknown} view decoded JSON (or JSON text)
 * @param {{ budget?: 'toolCard' | 'panel' | 'strip', data?: unknown, lang?: 'zh' | 'en' }} [options]
 * @returns {{ ok: boolean, fatal: boolean, budget: string, issues: { path: string, message: string, kind: 'broken' | 'note' | 'fatal' }[], title: string | null, bytes: number, components: number, placeholders: number, empty: number, truncated: number }}
 */
export function checkView(view, options = {}) {
  const budget = BUDGETS[options.budget ?? 'panel']
  if (budget === undefined) throw new TypeError(`unknown budget ${options.budget}`)
  const m = messages(options.lang)
  const fatal = (message, bytes = 0) => ({
    ok: false, fatal: true, budget: budget.name, issues: [{ path: 'view', message, kind: 'fatal' }], title: null, bytes,
    components: 0, placeholders: 0, empty: 0, truncated: 0,
  })
  let json = view
  if (typeof view === 'string') {
    if (view.length > budget.bytes * 4) return fatal(m('viewUiBytesLimit', view.length, budget.bytes))
    try {
      json = JSON.parse(view)
    } catch (error) {
      return fatal(m('viewUiInvalidJson', error.message))
    }
  }
  if (!isMap(json)) return fatal(m('viewUiExpectedObject'))
  const size = measureJson(json, budget.bytes, P.jsonNesting)
  if (size.tooDeep) return fatal(m('plugViewTooDeep', P.jsonNesting))
  if (size.overBytes) return fatal(m('viewUiBytesLimit', size.bytes, budget.bytes), size.bytes)
  const ctx = new Ctx(budget, m)
  ctx.version = json.v === 2 ? 2 : 1
  const template = ctx.version >= 2
    ? resolveFormulas(inputBindings(json, MISSING), options.data, (path) => ctx.note(path, m('plugInputFormula')), MISSING)
    : json
  const resolved = resolveBindings(template, options.data)
  initStyles(resolved, ctx, { isMissing, show, str })
  const root = parseNode(resolved, 'view', 1, ctx)
  const result = (ok, isFatal) => ({
    ok,
    fatal: isFatal,
    budget: budget.name,
    issues: ctx.issues,
    title: null,
    bytes: size.bytes,
    ...ctx.counts,
  })
  // Like the app: a dead root reports only the one problem that killed it.
  if (root.kind === 'placeholder') {
    ctx.issues = [{ ...root.issue, kind: 'fatal' }]
    return result(false, true)
  }
  if (root.kind === 'node' && Array.isArray(root.children) && root.children.length > 0 && root.children.every((c) => c.kind === 'placeholder')) {
    ctx.issues = [{ ...root.children[0].issue, kind: 'fatal' }]
    return result(false, true)
  }
  const out = result(true, false)
  const rawTitle = resolved.title
  const title = isMissing(rawTitle) ? null : clip(str(rawTitle)?.trim() ?? null, L.title)
  out.title = title === null || title === '' ? null : title
  return out
}

/** Every binding path in a view (for "a tool card has no data model"). */
export function bindingsIn(view) {
  const out = []
  const walk = (v, path) => {
    const p = bindingPath(v)
    if (p !== null) return out.push({ path, binding: p })
    if (Array.isArray(v)) v.forEach((x, i) => walk(x, `${path}[${i}]`))
    else if (isMap(v)) for (const [k, x] of Object.entries(v)) walk(x, `${path}.${k}`)
  }
  walk(view, 'view')
  return out
}

/** Label a problem the way the app lists it: 「path：message」. */
export function labeled(issue, lang) {
  return messages(lang)('viewLabeledValue', issue.path, issue.message)
}
