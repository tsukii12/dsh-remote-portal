// Twin of dsh_ui_plugin_controls_model.dart. Keep diagnostics and budgets aligned.
export const INPUT_TYPES = Object.freeze(['textField', 'number', 'stepper', 'toggle', 'slider', 'select', 'segmented', 'chips', 'date', 'time', 'rating'])
export const CONTROL_TYPES = Object.freeze([...INPUT_TYPES, 'form', 'tabs', 'collapsible', 'accordion', 'carousel', 'timeline', 'grid', 'badge', 'tag', 'avatar', 'codeBlock', 'divider', 'spacer', 'emptyState', 'gallery'])
export const INPUT_LIMITS = Object.freeze({ fields: 32, options: 24, sections: 8, timeline: 24, textLength: 2000, textLines: 8, columns: 4, codeLength: 8000, valueBytes: 4096 })
/** Pictures in a gallery (panel, tool card) and points in a metric's trend (DshUiControlLimits). */
export const FIGURE_LIMITS = Object.freeze({ gallery: 24, galleryCard: 8, trendPoints: 30 })
const PATTERNS = ['email', 'integer', 'decimal', 'alphanumeric', 'slug']
const isMap = (v) => v !== null && typeof v === 'object' && !Array.isArray(v)

export function inputPath(raw) {
  if (typeof raw !== 'string' || raw.length > 256 || !raw.startsWith('data.')) return null
  const parts = raw.slice(5).split('.')
  if (parts.length === 0 || parts.length > 16 || parts.some((p) => !/^[A-Za-z_][A-Za-z0-9_-]{0,63}$/.test(p) || ['__proto__', 'prototype', 'constructor'].includes(p))) return null
  return parts
}

export function inputBindings(value, missing, depth = 0) {
  if (depth > 64) return missing
  if (Array.isArray(value)) return value.map((v) => inputBindings(v, missing, depth + 1))
  if (!isMap(value) || (Object.keys(value).length === 1 && typeof value.$ === 'string')) return value
  const out = Object.fromEntries(Object.entries(value).map(([k, v]) => [k, inputBindings(v, missing, depth + 1)]))
  if (INPUT_TYPES.includes(out.type) && inputPath(out.bind) !== null) out.value = { $: out.bind }
  return out
}

function validDate(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false
  const [y, m, d] = value.split('-').map(Number)
  if (y < 1900 || y > 2100) return false
  const date = new Date(Date.UTC(y, m - 1, d))
  return date.getUTCFullYear() === y && date.getUTCMonth() + 1 === m && date.getUTCDate() === d
}

export function parseControl(raw, path, depth, ctx, api) {
  const type = raw.type, m = ctx.m
  const { node, parseNode, pluginAction, parseImage, pluginTone, isMissing, icon, str, empty, isEmptyValue } = api
  if (ctx.version < 2 || ctx.p.name === 'strip') return ctx.broken(`${path}.type`, m('plugInputUnavailable'), type)
  if (INPUT_TYPES.includes(type)) {
    if (++ctx.inputFields > INPUT_LIMITS.fields) return ctx.broken(path, m('viewUiItemLimit', ctx.inputFields, INPUT_LIMITS.fields), type)
    if (raw.obscureText === true || raw.password === true || raw.inputType === 'password' || raw.keyboardType === 'password') return ctx.broken(path, m('plugInputNoPassword'), type)
    if (typeof raw.label !== 'string' || raw.label.trim() === '') return ctx.broken(`${path}.label`, m('viewUiExpectedString'), type)
    const bind = raw.bind
    if (bind !== undefined && bind !== null && inputPath(bind) === null) return ctx.broken(`${path}.bind`, m('plugInputBadBinding'), type)
    if (bind !== undefined && bind !== null) {
      if ([...ctx.inputBindings].some((b) => b === bind || b.startsWith(`${bind}.`) || bind.startsWith(`${b}.`))) return ctx.broken(`${path}.bind`, m('plugInputDuplicateBinding'), type)
      ctx.inputBindings.add(bind)
    }
    const bounded = (key, fallback, min, max) => {
      const n = raw[key]
      if (n === null || n === undefined) return fallback
      if (Number.isInteger(n) && n >= min && n <= max) return n
      ctx.note(`${path}.${key}`, m('plugInputInvalidValue'))
      return typeof n === 'number' && Number.isFinite(n) ? Math.max(min, Math.min(max, Math.trunc(n))) : fallback
    }
    const maxLength = bounded('maxLength', 256, 1, INPUT_LIMITS.textLength)
    bounded('minLength', 0, 0, maxLength)
    bounded('maxLines', raw.multiline === true ? 4 : 1, 1, INPUT_LIMITS.textLines)
    const number = (key, fallback) => {
      const n = raw[key]
      if (n === null || n === undefined) return fallback
      if (typeof n === 'number' && Number.isFinite(n) && Math.abs(n) <= 1e12) return n
      ctx.note(`${path}.${key}`, m('viewUiExpectedFinite'))
      return fallback
    }
    const numeric = ['number', 'stepper', 'slider', 'rating'].includes(type)
    let min = number('min', ['number', 'stepper'].includes(type) ? -1e9 : 0)
    let max = number('max', ['number', 'stepper'].includes(type) ? 1e9 : type === 'rating' ? 5 : 100)
    if (type === 'rating') {
      max = Math.floor(Math.max(1, Math.min(10, max)))
      if (min !== 0) ctx.note(`${path}.min`, m('plugInputInvalidValue'))
      min = 0
    }
    if (max <= min && numeric) return ctx.broken(`${path}.max`, m('plugInputInvalidValue'), type)
    const step = number('step', 1)
    if (numeric && step < 1e-9) return ctx.broken(`${path}.step`, m('plugInputInvalidValue'), type)
    if (type === 'slider') {
      const divisions = (max - min) / step
      if (divisions < 1 || divisions > 1000 || Math.abs(divisions - Math.round(divisions)) > 1e-7) return ctx.broken(`${path}.step`, m('plugInputInvalidValue'), type)
    }
    if (['select', 'segmented', 'chips'].includes(type)) {
      const items = raw.options
      if (!Array.isArray(items)) return ctx.broken(`${path}.options`, m('viewUiNoOptions'), type)
      const seen = new Set()
      for (let i = 0; i < items.length; i++) {
        if (i >= INPUT_LIMITS.options) { ctx.note(`${path}.options`, m('viewUiItemLimit', items.length, INPUT_LIMITS.options)); break }
        const item = items[i]
        const label = typeof item === 'string' ? item : isMap(item) ? item.label : null
        const value = typeof item === 'string' ? item : isMap(item) ? item.value ?? label : null
        if (typeof label !== 'string' || label === '' || typeof value !== 'string' || value === '' || value.length > 200 || seen.has(value)) {
          ctx.note(`${path}.options[${i}]`, m('plugInputInvalidValue')); continue
        }
        seen.add(value)
      }
    }
    if (raw.pattern !== null && raw.pattern !== undefined && !PATTERNS.includes(raw.pattern)) return ctx.broken(`${path}.pattern`, m('plugInputNamedPattern'), type)
    if ((raw.minDate != null && !validDate(raw.minDate)) || (raw.maxDate != null && !validDate(raw.maxDate)) || (raw.minDate != null && raw.maxDate != null && raw.minDate > raw.maxDate)) return ctx.broken(path, m('plugInputDate'), type)
    const value = raw.value
    if (typeof value === 'string' && value.length > INPUT_LIMITS.textLength * 2) ctx.note(`${path}.value`, m('viewUiTextLimit', value.length, INPUT_LIMITS.textLength))
    if ((!isMissing(value) && isMap(value)) || (typeof value === 'number' && !Number.isFinite(value))) ctx.note(`${path}.value`, m('plugInputInvalidValue'))
    pluginAction(raw.onChange, `${path}.onChange`, ctx)
    return node(path, type)
  }
  if (['form', 'tabs', 'collapsible', 'accordion', 'carousel', 'timeline', 'grid'].includes(type)) {
    if (type === 'form' && ctx.inForm) return ctx.broken(path, m('plugInputNestedForm'), type)
    const wasInForm = ctx.inForm
    if (type === 'form') ctx.inForm = true
    const built = []
    let truncated = false
    const children = (value, at, childDepth) => {
      if (!Array.isArray(value)) return [ctx.broken(at, m('viewUiExpectedChildren', ctx.p.children))]
      const out = []
      for (let i = 0; i < value.length; i++) {
        if (i >= ctx.p.children || ctx.nodes >= ctx.p.nodes) {
          truncated = true
          ctx.note(at, m('viewUiNodeLimit', ctx.p.nodes, value.length - i)); break
        }
        out.push(parseNode(value[i], `${at}[${i}]`, childDepth, ctx))
      }
      return out
    }
    if (['tabs', 'accordion', 'carousel', 'timeline'].includes(type)) {
      const items = raw.items
      if (!Array.isArray(items)) { ctx.inForm = wasInForm; return ctx.broken(`${path}.items`, m('viewUiNoItems'), type) }
      const max = type === 'timeline' ? INPUT_LIMITS.timeline : INPUT_LIMITS.sections
      for (let i = 0; i < items.length; i++) {
        if (i >= max || ctx.nodes >= ctx.p.nodes) {
          truncated = true
          ctx.note(`${path}.items`, m('viewUiItemLimit', items.length, max)); break
        }
        const item = items[i]
        if (!isMap(item) || typeof item.label !== 'string' || item.label === '') { ctx.note(`${path}.items[${i}].label`, m('viewUiExpectedString')); continue }
        ctx.nodes++
        built.push(...children(item.children ?? [], `${path}.items[${i}].children`, depth + 1))
      }
    } else built.push(...children(raw.children, `${path}.children`, depth + 1))
    ctx.inForm = wasInForm
    const submit = type === 'form' ? pluginAction(raw.submit, `${path}.submit`, ctx) : null
    if (type === 'form' && submit === null) return ctx.broken(`${path}.submit`, m('plugInputSubmitMissing'), type)
    if (raw.columns != null && (!Number.isInteger(raw.columns) || raw.columns < 1 || raw.columns > INPUT_LIMITS.columns)) ctx.note(`${path}.columns`, m('plugInputInvalidValue'))
    if (truncated) ctx.counts.truncated++
    return node(path, type, { children: built })
  }
  if (type === 'avatar') { parseImage(raw, path, ctx); return node(path, type) }
  if (type === 'emptyState') return parseEmptyState(raw, path, ctx, api)
  if (type === 'gallery') {
    const shape = '{src, alt?, caption?, action?}'
    const items = raw.items
    if (isEmptyValue(items)) return empty(ctx, path, type)
    if (!Array.isArray(items)) return ctx.broken(`${path}.items`, m('plugViewExpectedItems', shape), type)
    const max = ctx.p.name === 'toolCard' ? FIGURE_LIMITS.galleryCard : FIGURE_LIMITS.gallery
    let count = 0
    for (let i = 0; i < items.length; i++) {
      if (count >= max) {
        ctx.counts.truncated++
        ctx.note(`${path}.items`, m('viewUiItemLimit', items.length, max)); break
      }
      const item = items[i]
      const at = `${path}.items[${i}]`
      if (!isMap(item)) { ctx.note(at, m('plugViewSkippedItem', shape)); continue }
      parseImage({ src: item.src, alt: item.alt }, at, ctx)
      pluginAction(item.action, `${at}.action`, ctx)
      count++
    }
    if (count === 0) return ctx.broken(`${path}.items`, m('viewUiNoItems'), type)
    const columns = raw.columns
    if (!(Number.isInteger(columns) && columns >= 2 && columns <= 4) && columns !== null && columns !== undefined && !isMissing(columns)) ctx.note(`${path}.columns`, m('plugViewStyleInvalid', '2–4'))
    const aspect = raw.aspect
    if (!(typeof aspect === 'number' && Number.isFinite(aspect) && aspect >= 0.5 && aspect <= 2) && aspect !== null && aspect !== undefined && !isMissing(aspect)) ctx.note(`${path}.aspect`, m('plugViewStyleInvalid', '0.5–2'))
    return node(path, type)
  }
  if (['divider', 'spacer'].includes(type)) {
    if (!['S', 'M', 'L'].includes(raw.size ?? 'M')) ctx.note(`${path}.size`, m('plugInputInvalidValue'))
    return node(path, type)
  }
  const key = type === 'codeBlock' ? 'code' : 'text'
  if (typeof raw[key] !== 'string') return ctx.broken(`${path}.${key}`, m('viewUiExpectedString'), type)
  const max = type === 'codeBlock' ? INPUT_LIMITS.codeLength : 200
  if (raw[key].length > max) { ctx.note(`${path}.${key}`, m('viewUiTextLimit', raw[key].length, max)); ctx.counts.truncated++ }
  pluginTone(raw.tone, `${path}.tone`, ctx)
  return node(path, type)
}

// emptyState (v2): title required; at most one button made of label + action.
function parseEmptyState(raw, path, ctx, api) {
  const m = ctx.m
  const { node, pluginAction, isMissing, icon, str } = api
  const title = str(raw.title)?.trim() ?? null
  if (title === null || title === '') return ctx.broken(`${path}.title`, m('viewUiExpectedString'), 'emptyState')
  if (title.length > 40) ctx.note(`${path}.title`, m('viewUiTextLimit', title.length, 40))
  const message = str(raw.message)?.trim() ?? null
  if (message !== null && message.length > 120) ctx.note(`${path}.message`, m('viewUiTextLimit', message.length, 120))
  const action = raw.action
  if (isMap(action)) {
    const label = str(action.label)?.trim() ?? null
    const id = pluginAction(action.action, `${path}.action.action`, ctx)
    if (label === null || label === '') ctx.note(`${path}.action.label`, m('viewUiSkippedItemLabel'))
    else if (id !== null) icon(action.icon, `${path}.action.icon`, ctx)
    else if (action.action === null || action.action === undefined) ctx.note(`${path}.action.action`, m('plugViewBadAction', '{id, args?}'))
  } else if (action !== null && action !== undefined && !isMissing(action)) {
    ctx.note(`${path}.action`, m('plugViewBadAction', '{label, action}'))
  }
  icon(raw.icon, `${path}.icon`, ctx)
  return node(path, 'emptyState')
}
