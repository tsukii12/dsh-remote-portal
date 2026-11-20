// Twin of dsh_ui_plugin_formula.dart: a bounded arithmetic language, never eval.
export const FORMULA_LIMITS = Object.freeze({ length: 256, tokens: 128, depth: 16 })

export function evaluateFormula(source, data) {
  if (typeof source !== 'string' || source.length === 0 || source.length > FORMULA_LIMITS.length) return null
  let at = 0, tokens = 0, depth = 0
  const fail = () => { throw new SyntaxError('Invalid bounded formula') }
  const token = () => { if (++tokens > FORMULA_LIMITS.tokens) fail() }
  const space = () => { while (at < source.length && /[ \t\n\r]/.test(source[at])) at++ }
  const take = (text) => {
    space()
    if (!source.startsWith(text, at)) return false
    token(); at += text.length; return true
  }
  const finite = (n) => { if (!Number.isFinite(n)) fail(); return n }
  const number = (value) => {
    if (typeof value === 'number') return finite(value)
    if (typeof value !== 'string' || !/^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$/.test(value.trim())) fail()
    return finite(Number(value))
  }
  const lookup = (path) => {
    const parts = [...path.matchAll(/\.([A-Za-z_][A-Za-z0-9_]*)|\[([0-9]+)\]/g)]
    if (parts.length > 16) fail()
    let current = data
    for (const part of parts) {
      if (Array.isArray(current) && part[1] !== undefined) fail()
      const key = part[1] ?? String(Number(part[2]))
      if (current === null || typeof current !== 'object' || !Object.prototype.hasOwnProperty.call(current, key)) fail()
      current = current[key]
    }
    return number(current)
  }
  const expression = () => {
    if (++depth > FORMULA_LIMITS.depth) fail()
    let value = term()
    while (true) {
      if (take('+')) value = finite(value + term())
      else if (take('-')) value = finite(value - term())
      else break
    }
    depth--; return value
  }
  const term = () => {
    let value = factor()
    while (true) {
      if (take('*')) value = finite(value * factor())
      else if (take('/')) value = finite(value / factor())
      else if (take('%')) {
        const divisor = Math.abs(factor())
        if (divisor === 0) fail()
        const remainder = value % divisor
        value = finite(remainder < 0 ? remainder + divisor : remainder)
      } else break
    }
    return value
  }
  const factor = () => {
    if (++depth > FORMULA_LIMITS.depth) fail()
    const result = atom()
    depth--; return result
  }
  const atom = () => {
    if (take('+')) return factor()
    if (take('-')) return -factor()
    if (take('(')) {
      const value = expression()
      if (!take(')')) fail()
      return value
    }
    space()
    const numeric = /^(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?/.exec(source.slice(at))
    if (numeric !== null) { token(); at += numeric[0].length; return finite(Number(numeric[0])) }
    const path = /^data(?:\.[A-Za-z_][A-Za-z0-9_]*|\[[0-9]{1,6}\])+/.exec(source.slice(at))
    if (path !== null) { token(); at += path[0].length; return lookup(path[0]) }
    const name = /^[A-Za-z]+/.exec(source.slice(at))
    if (name === null) fail()
    token(); at += name[0].length
    if (!['abs', 'min', 'max', 'clamp'].includes(name[0]) || !take('(')) fail()
    const args = [expression()]
    while (take(',')) { if (args.length === 3) fail(); args.push(expression()) }
    if (!take(')')) fail()
    if (name[0] === 'abs' && args.length === 1) return Math.abs(args[0])
    if (name[0] === 'min' && args.length === 2) return Math.min(...args)
    if (name[0] === 'max' && args.length === 2) return Math.max(...args)
    if (name[0] === 'clamp' && args.length === 3 && args[1] <= args[2]) return Math.max(args[1], Math.min(args[2], args[0]))
    fail()
  }
  try {
    const result = expression()
    space()
    return at === source.length && Number.isFinite(result) ? result : null
  } catch (error) {
    if (error instanceof SyntaxError) return null
    throw error
  }
}

export function resolveFormulas(value, data, invalid, missing) {
  const map = (v) => v !== null && typeof v === 'object' && !Array.isArray(v)
  const binding = (v) => map(v) && Object.keys(v).length === 1 && typeof v.$ === 'string'
  const walk = (v, path, depth) => {
    if (depth > 64) return missing
    if (binding(v)) return v
    if (Array.isArray(v)) return v.map((x, i) => walk(x, `${path}[${i}]`, depth + 1))
    if (!map(v)) return v
    if (Object.keys(v).length === 1 && Object.prototype.hasOwnProperty.call(v, '=')) {
      const result = evaluateFormula(v['='], data)
      if (result === null) invalid(path)
      return result ?? missing
    }
    return Object.fromEntries(Object.entries(v).map(([key, x]) => [key,
      key === 'type' && map(x) && Object.prototype.hasOwnProperty.call(x, '=') ? missing : walk(x, `${path}.${key}`, depth + 1),
    ]))
  }
  return walk(value, 'view', 0)
}
