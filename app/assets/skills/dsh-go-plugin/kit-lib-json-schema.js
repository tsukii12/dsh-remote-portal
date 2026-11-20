// A small JSON Schema (draft 2020-12) validator for the plugin-kit schemas. Zero
// dependencies. Covers the keywords those files use: $ref (local and cross-file),
// type, enum, const, properties, required, additionalProperties,
// unevaluatedProperties (with annotations from allOf / anyOf / oneOf / if-then-else
// / $ref), propertyNames, minProperties, items, minItems, maxItems, uniqueItems,
// minLength, maxLength (code points), pattern (ECMA-262, unicode), minimum,
// maximum, allOf, anyOf, oneOf, if / then / else. Unknown keywords (description,
// default, x-*) are ignored, as the spec says.
import { readFileSync } from 'node:fs'

const SCHEMA_FILES = ['view', 'manifest', 'invoke', 'contributions', 'stream']

/** Load the plugin-kit schemas: { 'view.schema.json': {...}, … }. */
export function loadSchemas(dir = new URL('../schema/', import.meta.url)) {
  const out = {}
  for (const name of SCHEMA_FILES) {
    const file = `${name}.schema.json`
    out[file] = JSON.parse(readFileSync(new URL(file, dir), 'utf8'))
  }
  return out
}

const isObject = (v) => typeof v === 'object' && v !== null && !Array.isArray(v)
const esc = (s) => String(s).replaceAll('~', '~0').replaceAll('/', '~1')

function typeOf(v) {
  if (v === null) return 'null'
  if (Array.isArray(v)) return 'array'
  if (typeof v === 'number') return Number.isInteger(v) ? 'integer' : 'number'
  return typeof v
}

function deepEqual(a, b) {
  if (a === b) return true
  if (typeof a !== typeof b || a === null || b === null || typeof a !== 'object') return false
  if (Array.isArray(a) !== Array.isArray(b)) return false
  if (Array.isArray(a)) return a.length === b.length && a.every((x, i) => deepEqual(x, b[i]))
  const ka = Object.keys(a)
  return ka.length === Object.keys(b).length && ka.every((k) => Object.hasOwn(b, k) && deepEqual(a[k], b[k]))
}

const regexCache = new Map()
function regex(pattern) {
  let re = regexCache.get(pattern)
  if (re === undefined) {
    re = new RegExp(pattern, 'u')
    regexCache.set(pattern, re)
  }
  return re
}

export class SchemaSet {
  /** @param {Record<string, object>} schemas file name → schema */
  constructor(schemas = loadSchemas()) {
    this.schemas = schemas
  }

  /** Resolve `$ref` from `file` → { file, schema }. */
  resolve(ref, file) {
    const [target, fragment = ''] = ref.split('#')
    const f = target === '' ? file : target
    const root = this.schemas[f]
    if (root === undefined) throw new Error(`unknown $ref target ${ref} (from ${file})`)
    let node = root
    if (fragment !== '') {
      for (const part of fragment.split('/').slice(1)) {
        node = node?.[part.replaceAll('~1', '/').replaceAll('~0', '~')]
        if (node === undefined) throw new Error(`unresolvable $ref ${ref} (from ${file})`)
      }
    }
    return { file: f, schema: node }
  }

  /**
   * Validate `value` against `file#pointer` (pointer like '/$defs/viewResponse', '' for the root).
   * @returns {{ path: string, schemaPath: string, message: string }[]} errors; empty when valid.
   */
  validate(value, file, pointer = '') {
    const { schema } = pointer === '' ? { schema: this.schemas[file] } : this.resolve(`#${pointer}`, file)
    const errors = []
    this.#check(schema, value, file, '', `${file}#${pointer}`, errors)
    return errors
  }

  /** Returns the set of evaluated property names (for unevaluatedProperties), or null when invalid. */
  #check(schema, value, file, path, spath, errors) {
    if (schema === true || schema === undefined) return new Set()
    if (schema === false) {
      errors.push({ path, schemaPath: spath, message: 'not allowed' })
      return null
    }
    const start = errors.length
    const evaluated = new Set()
    const fail = (keyword, message) => errors.push({ path, schemaPath: `${spath}/${keyword}`, message })
    const sub = (s, v, p, sp, into) => {
      const r = this.#check(s, v, file, p, sp, into)
      return r
    }

    if (typeof schema.$ref === 'string') {
      const target = this.resolve(schema.$ref, file)
      const r = this.#check(target.schema, value, target.file, path, `${spath}/$ref→${schema.$ref}`, errors)
      if (r) for (const k of r) evaluated.add(k)
    }

    if (schema.type !== undefined) {
      const types = Array.isArray(schema.type) ? schema.type : [schema.type]
      const t = typeOf(value)
      if (!types.some((x) => x === t || (x === 'number' && t === 'integer'))) fail('type', `expected ${types.join(' | ')}, got ${t}`)
    }
    if (Array.isArray(schema.enum) && !schema.enum.some((e) => deepEqual(e, value))) fail('enum', `not one of ${JSON.stringify(schema.enum).slice(0, 120)}`)
    if ('const' in schema && !deepEqual(schema.const, value)) fail('const', `expected ${JSON.stringify(schema.const)}`)

    if (typeof value === 'string') {
      const len = [...value].length
      if (schema.minLength !== undefined && len < schema.minLength) fail('minLength', `shorter than ${schema.minLength}`)
      if (schema.maxLength !== undefined && len > schema.maxLength) fail('maxLength', `longer than ${schema.maxLength} (${len})`)
      if (schema.pattern !== undefined && !regex(schema.pattern).test(value)) fail('pattern', `does not match ${schema.pattern}`)
    }
    if (typeof value === 'number') {
      if (schema.minimum !== undefined && value < schema.minimum) fail('minimum', `less than ${schema.minimum}`)
      if (schema.maximum !== undefined && value > schema.maximum) fail('maximum', `greater than ${schema.maximum}`)
    }
    if (Array.isArray(value)) {
      if (schema.minItems !== undefined && value.length < schema.minItems) fail('minItems', `fewer than ${schema.minItems} items`)
      if (schema.maxItems !== undefined && value.length > schema.maxItems) fail('maxItems', `more than ${schema.maxItems} items (${value.length})`)
      if (schema.uniqueItems === true && value.some((x, i) => value.findIndex((y) => deepEqual(x, y)) !== i)) fail('uniqueItems', 'items are not unique')
      if (schema.items !== undefined) value.forEach((x, i) => sub(schema.items, x, `${path}/${i}`, `${spath}/items`, errors))
    }
    if (isObject(value)) {
      const keys = Object.keys(value)
      if (schema.minProperties !== undefined && keys.length < schema.minProperties) fail('minProperties', `fewer than ${schema.minProperties} properties`)
      for (const r of schema.required ?? []) if (!Object.hasOwn(value, r)) fail('required', `missing ${r}`)
      if (schema.propertyNames !== undefined) for (const k of keys) sub(schema.propertyNames, k, `${path}/${esc(k)}`, `${spath}/propertyNames`, errors)
      const props = schema.properties ?? {}
      for (const k of keys) {
        if (Object.hasOwn(props, k)) {
          evaluated.add(k)
          sub(props[k], value[k], `${path}/${esc(k)}`, `${spath}/properties/${esc(k)}`, errors)
        } else if (schema.additionalProperties !== undefined) {
          evaluated.add(k)
          sub(schema.additionalProperties, value[k], `${path}/${esc(k)}`, `${spath}/additionalProperties`, errors)
        }
      }
    }

    // Applicators that contribute annotations.
    const tryAll = (list, keyword) => list.map((s, i) => {
      const scratch = []
      const r = this.#check(s, value, file, path, `${spath}/${keyword}/${i}`, scratch)
      return { ok: scratch.length === 0, evaluated: r, errors: scratch }
    })
    if (Array.isArray(schema.allOf)) {
      for (const r of tryAll(schema.allOf, 'allOf')) {
        errors.push(...r.errors)
        if (r.ok && r.evaluated) for (const k of r.evaluated) evaluated.add(k)
      }
    }
    if (Array.isArray(schema.anyOf)) {
      const rs = tryAll(schema.anyOf, 'anyOf')
      const ok = rs.filter((r) => r.ok)
      if (ok.length === 0) fail('anyOf', `matches none of ${rs.length} alternatives${bestHint(rs)}`)
      for (const r of ok) if (r.evaluated) for (const k of r.evaluated) evaluated.add(k)
    }
    if (Array.isArray(schema.oneOf)) {
      const rs = tryAll(schema.oneOf, 'oneOf')
      const ok = rs.filter((r) => r.ok)
      if (ok.length !== 1) fail('oneOf', ok.length === 0 ? `matches none of ${rs.length} alternatives${bestHint(rs)}` : `matches ${ok.length} alternatives (${rs.map((r, i) => (r.ok ? i : null)).filter((i) => i !== null).join(', ')}), expected exactly one`)
      for (const r of ok) if (r.evaluated) for (const k of r.evaluated) evaluated.add(k)
    }
    if (schema.if !== undefined) {
      const scratch = []
      const r = this.#check(schema.if, value, file, path, `${spath}/if`, scratch)
      if (scratch.length === 0) {
        if (r) for (const k of r) evaluated.add(k)
        if (schema.then !== undefined) {
          const t = this.#check(schema.then, value, file, path, `${spath}/then`, errors)
          if (t) for (const k of t) evaluated.add(k)
        }
      } else if (schema.else !== undefined) {
        const e = this.#check(schema.else, value, file, path, `${spath}/else`, errors)
        if (e) for (const k of e) evaluated.add(k)
      }
    }
    if (schema.unevaluatedProperties !== undefined && isObject(value)) {
      for (const k of Object.keys(value)) {
        if (evaluated.has(k)) continue
        if (schema.unevaluatedProperties === false) errors.push({ path: `${path}/${esc(k)}`, schemaPath: `${spath}/unevaluatedProperties`, message: `unevaluated property ${k}` })
        else sub(schema.unevaluatedProperties, value[k], `${path}/${esc(k)}`, `${spath}/unevaluatedProperties`, errors)
        evaluated.add(k)
      }
    }
    return errors.length === start ? evaluated : null
  }
}

/** The closest alternative's first error, to make anyOf / oneOf failures readable. */
function bestHint(results) {
  const best = [...results].sort((a, b) => a.errors.length - b.errors.length)[0]
  const e = best?.errors[0]
  return e ? `; closest: ${e.path || '/'} ${e.message}` : ''
}
