// A stand-in for DSH + the dsh-go bridge, for unit tests of a plugin's host
// half and for `check --load`. It runs your `apply(ctx)` against a fake
// cordis context, records what you register through `ctx.dshGo`, and answers
// like the bridge: the same manifest parse, the same `ready` / `no-handler` /
// `undeclared` issues and the same effect normalization (lib/bridge/ is the
// bridge's own code). Zero dependencies.
//
//   const host = createTestHost({ dir })            // reads <dir>/package.json
//   plugin.apply(host.ctx)
//   host.contributions()                            // the row the app would get
//   await host.invoke('translate', { context: { clipboard: '你好' } })
//   await host.view('usage', { sessionId: 's1' })   // { view, stats, issues }
//   const feed = host.subscribe('usage', { sessionId: 's1' })  // feed.data, feed.history
import { AUDIO_TYPES, CAP_LIMITS, microModel } from './bridge/capabilities.js'
import { readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { normalize as normalizeEffects, splitPending } from './bridge/effects.js'
import { ICON, ID, LIMITS, PROTOCOL, TONES } from './bridge/limits.js'
import { parseManifest, renderPlugin } from './bridge/manifest.js'
import { chars, cleanLine, isPlainObject, sanitizeNotes, toJson, truncateChars, viewStats, withoutNulls } from './bridge/util.js'

const CONTEXT_FOR = { 'composer.actions': ['draft', 'clipboard'], 'composer.tools': ['draft', 'clipboard'], 'message.actions': ['message'] }
const SURFACE_OF = { 'composer.actions': 'composer.actions', 'message.actions': 'message.actions', 'composer.strip': 'composer.strip', panel: 'panels', 'composer.tools': 'composer.tools', 'session.actions': 'session.actions' }

/** The caps an up-to-date app sends (protocol §3.1). */
export function defaultCaps(overrides = {}) {
  return {
    protocol: PROTOCOL,
    app: '99.0.0',
    locale: 'zh-CN',
    surfaces: ['composer.actions', 'message.actions', 'composer.strip', 'panels', 'composer.tools', 'session.actions', 'turn.note', 'plugin'],
    components: JSON.parse(readFileSync(new URL('../schema/view.schema.json', import.meta.url), 'utf8')).$defs.node.properties.type.enum,
    ...overrides,
  }
}

function stripValue(d) {
  if (d === null) return { text: null }
  if (!isPlainObject(d)) return undefined
  const text = typeof d.text === 'string' ? cleanLine(d.text) : ''
  const out = { text: text === '' ? null : chars(text) > LIMITS.textChars.stripText ? truncateChars(text, LIMITS.textChars.stripText) : text }
  if (typeof d.icon === 'string' && ICON.test(d.icon)) out.icon = d.icon
  if (TONES.includes(d.tone)) out.tone = d.tone
  return out
}

const recordFailure = (feed) => (error) => { feed.errors.push(String(error?.message ?? error)) }

/** A feed's cleanup as the bridge runs it: it may be async, and no failure of it escapes. */
function runCleanup(fn, failed) {
  try {
    Promise.resolve(fn()).catch(failed)
  } catch (error) {
    failed(error)
  }
}

class HostError extends Error {
  constructor(status, code, message) {
    super(`${status} ${code}: ${message}`)
    this.status = status
    this.code = code
  }
}

/**
 * @param {{ dir?: string, pkg?: object, services?: Record<string, unknown>, caps?: object, bridge?: boolean, config?: unknown }} [options]
 *   dir: plugin directory (package.json is read from it); pkg: package.json object instead;
 *   services: other cordis services by name (e.g. { sessions }); bridge: false simulates a host
 *   without dsh-go-bridge (the dshGo service never appears).
 */
export function createTestHost(options = {}) {
  const dir = resolve(options.dir ?? '.')
  const pkgJson = options.pkg ?? JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8'))
  const parsed = parseManifest(pkgJson, dir)
  const caps = defaultCaps(options.caps)
  const services = { ...(options.services ?? {}) }
  const listeners = new Map()
  const disposers = []
  const logs = []
  const pending = []
  const runtimeIssues = new Map()
  const regs = { panels: new Map(), strips: new Map(), notes: new Map(), handlers: new Map(), media: new Map(), micro: new Map(), capability: new Map() }
  const feeds = new Set()
  const violations = []

  const undeclared = (kind, id) => {
    const declared = parsed.ids.get(id)
    const ok = kind === 'media' || kind === 'micro' ? declared === kind : kind === 'handlers' ? declared !== undefined : kind === 'panels' ? declared === 'panels' : kind === 'notes' ? declared === 'turn.note' : declared === 'composer.strip'
    if (!ok) {
      const name = { panels: 'panel', strips: 'strip', notes: 'turnNote', handlers: 'on' }[kind]
      runtimeIssues.set(`undeclared:${kind}:${id}`, { path: `/runtime/${id}`, code: 'undeclared', severity: 'warn', message: `${name}("${id}") is not declared in dshGo.contributes; ignored` })
    }
  }

  const stopFeeds = (id) => {
    for (const feed of [...feeds]) {
      if (feed.id !== id) continue
      feed.stop()
      feeds.delete(feed)
    }
  }

  // As the bridge does: replacing or removing a registration ends its feeds, and the disposer of
  // one that was replaced leaves its successor alone.
  const addFeedSource = (map, id, reg) => {
    if (map.has(id)) stopFeeds(id)
    map.set(id, reg)
    return () => {
      if (map.get(id) !== reg) return
      map.delete(id)
      stopFeeds(id)
    }
  }

  const dshGo = {
    v: PROTOCOL,
    bridge: 'test-host',
    panel(id, def) {
      if (typeof id !== 'string' || !ID.test(id)) throw new TypeError(`dshGo.panels: id must match ${ID}`)
      if (!isPlainObject(def) || !(isPlainObject(def.view) || typeof def.view === 'function')) throw new TypeError('dshGo.panel: { view } is required (an object or a function)')
      if (def.data !== undefined && typeof def.data !== 'function') throw new TypeError('dshGo.panel: data must be a function (scope, emit) => cancel')
      if (def.actions !== undefined && (!isPlainObject(def.actions) || Object.values(def.actions).some((f) => typeof f !== 'function'))) throw new TypeError('dshGo.panel: actions must map names to functions')
      const dispose = addFeedSource(regs.panels, id, { view: def.view, data: def.data, actions: def.actions })
      undeclared('panels', id)
      return dispose
    },
    turnNote(id, def) {
      if (typeof id !== 'string' || !ID.test(id)) throw new TypeError(`dshGo.turnNote: id must match ${ID}`)
      const data = typeof def === 'function' ? def : def?.data
      if (typeof data !== 'function') throw new TypeError('dshGo.turnNote: pass (scope, emit) => cancel or { data }')
      const dispose = addFeedSource(regs.notes, id, { data })
      undeclared('notes', id)
      return dispose
    },
    strip(id, def) {
      if (typeof id !== 'string' || !ID.test(id)) throw new TypeError(`dshGo.strips: id must match ${ID}`)
      const data = typeof def === 'function' ? def : def?.data
      if (typeof data !== 'function') throw new TypeError('dshGo.strip: pass (scope, emit) => cancel or { data }')
      const dispose = addFeedSource(regs.strips, id, { data })
      undeclared('strips', id)
      return dispose
    },
    media(id, handler) {
      if (typeof id !== 'string' || !ID.test(id) || typeof handler !== 'function') throw new TypeError('invalid media registration')
      regs.media.set(id, handler)
      undeclared('media', id)
      return () => regs.media.delete(id)
    },
    micro(id, def) {
      if (typeof id !== 'string' || !ID.test(id) || typeof def?.data !== 'function') throw new TypeError('invalid micro registration')
      regs.micro.set(id, def)
      undeclared('micro', id)
      return () => regs.micro.delete(id)
    },
    onCapability(handler) {
      if (typeof handler !== 'function') throw new TypeError('invalid capability handler')
      regs.capability.set('events', handler)
      return () => regs.capability.delete('events')
    },
    on(id, handler) {
      if (typeof id !== 'string' || !ID.test(id)) throw new TypeError(`dshGo.handlers: id must match ${ID}`)
      if (typeof handler !== 'function') throw new TypeError('dshGo.on: handler must be a function')
      regs.handlers.set(id, handler)
      undeclared('handlers', id)
      return () => regs.handlers.delete(id)
    },
    refresh(id) {
      for (const feed of feeds) if (feed.id === id) feed.stale++
    },
    readPickedFile() {
      throw new HostError(409, 'unsupported', 'selected-file byte delivery requires the production bridge upload routes')
    },
  }

  const has = (name) => (name === 'dshGo' ? options.bridge !== false : name in services)

  /** A minimal cordis-like context. */
  function makeCtx(extra = {}) {
    const ctx = {
      ...services,
      ...extra,
      get: (name) => (name === 'dshGo' && options.bridge !== false ? dshGo : services[name]),
      inject(deps, callback) {
        const names = Array.isArray(deps) ? deps : Object.keys(deps ?? {})
        const missing = names.filter((n) => !has(n))
        if (missing.length > 0) {
          pending.push({ missing, callback })
          return () => {}
        }
        const child = makeCtx(names.includes('dshGo') ? { dshGo } : {})
        callback(child)
        return () => {}
      },
      on(name, fn) {
        const set = listeners.get(name) ?? new Set()
        set.add(fn)
        listeners.set(name, set)
        return () => set.delete(fn)
      },
      effect(fn) {
        const dispose = fn()
        if (typeof dispose === 'function') disposers.push(dispose)
        return dispose
      },
      logger: {
        info: (...a) => logs.push(['info', ...a]),
        warn: (...a) => logs.push(['warn', ...a]),
        error: (...a) => logs.push(['error', ...a]),
        debug: (...a) => logs.push(['debug', ...a]),
      },
    }
    return ctx
  }

  const ctx = makeCtx()

  function live() {
    return {
      panels: new Map([...regs.panels].map(([id, r]) => [id, { data: typeof r.data === 'function' }])),
      strips: new Set(regs.strips.keys()),
      notes: new Set(regs.notes.keys()),
      handlers: new Set(regs.handlers.keys()),
      degraded: false,
      runtimeIssues: [...runtimeIssues.values()],
    }
  }

  const surfaceItem = (surface, id) => parsed.items[SURFACE_OF[surface]]?.find((x) => x.id === id)

  function findSurface(id) {
    for (const surface of ['composer.actions', 'message.actions', 'composer.strip', 'composer.tools', 'session.actions']) if (surfaceItem(surface, id)) return surface
    if (surfaceItem('panel', id)) return 'panel'
    return undefined
  }

  const withTimeout = (promise, ms, what) => new Promise((ok, fail) => {
    const timer = setTimeout(() => fail(new HostError(504, 'timeout', `${what} took longer than ${ms} ms`)), ms)
    timer.unref?.()
    Promise.resolve(promise).then((v) => { clearTimeout(timer); ok(v) }, (e) => { clearTimeout(timer); fail(e) })
  })

  const pendings = new Map()
  let pendingSeq = 0

  /**
   * A deferred result (protocol §4.7) like the bridge runs it: the invoke answers at once with
   * `pending`; `settled` resolves with { t: 'done', effects, issues } or { t: 'void', reason }.
   * Only insert / copy / toast / patch are allowed in the result; the work gets an AbortSignal
   * that fires on timeout or cancel.
   */
  function startPending(id, deferred, panels, source) {
    if (!deferred.ok) {
      violations.push({ id, issues: deferred.issues })
      return { effects: [], issues: deferred.issues }
    }
    const active = [...pendings.values()].length
    if (active >= LIMITS.pendingPerPlugin) throw new HostError(429, 'too-many-pending', `at most ${LIMITS.pendingPerPlugin} pending results per plugin`)
    const controller = new AbortController()
    const pid = `p${++pendingSeq}`
    let settle
    const settled = new Promise((resolve) => { settle = resolve })
    const entry = { id: pid, done: false, controller }
    const finish = (msg, abort = true) => {
      if (entry.done) return
      entry.done = true
      clearTimeout(entry.timer)
      pendings.delete(pid)
      if (abort) controller.abort()
      settle(msg)
    }
    entry.cancel = () => finish({ t: 'void', reason: 'cancelled' })
    entry.timer = setTimeout(() => finish({ t: 'void', reason: 'timeout' }), deferred.timeoutMs)
    entry.timer.unref?.()
    pendings.set(pid, entry)
    let work
    try {
      work = Promise.resolve(typeof deferred.work === 'function' ? deferred.work(controller.signal) : deferred.work)
    } catch (error) {
      work = Promise.reject(error)
    }
    work.then((value) => {
      if (entry.done) return
      const norm = normalizeEffects(value, { panels, source, deferred: true })
      if (norm.violation) violations.push({ id, issues: norm.issues })
      finish({ t: 'done', effects: norm.effects, ...(norm.issues.length > 0 ? { issues: norm.issues } : {}) }, false)
    }, (error) => {
      if (entry.done) return
      violations.push({ id, error })
      finish({ t: 'void', reason: 'error' })
    })
    const pending = { id: pid, timeoutMs: deferred.timeoutMs }
    if (deferred.label !== undefined) pending.label = deferred.label
    return { effects: [], issues: deferred.issues, pending, settled, cancel: entry.cancel }
  }

  return {
    ctx,
    dshGo,
    parsed,
    caps,
    logs,
    violations,
    /** Callbacks waiting for services the host does not provide. */
    pending,
    /** What the host half registered: ids by kind (for checkManifest's `handlers` etc.). */
    registrations() {
      return {
        panels: [...regs.panels.keys()],
        strips: [...regs.strips.keys()],
        notes: [...regs.notes.keys()],
        handlers: [...regs.handlers.keys()],
        dataPanels: [...regs.panels].filter(([, r]) => typeof r.data === 'function').map(([id]) => id),
      }
    },
    /** The plugin's row in GET /dsh-go/v1/contributions for `caps`. */
    contributions(capsOverride = {}) {
      const c = { ...caps, ...capsOverride }
      return renderPlugin(parsed, { versions: [c.protocol ?? PROTOCOL], app: c.app, locale: c.locale, surfaces: c.surfaces, features: c.features }, live())
    },
    /**
     * POST /dsh-go/v1/invoke. Resolves { effects, issues } like the bridge; rejects with
     * { status, code } where the bridge would answer an error.
     */
    async invoke(id, request = {}) {
      const surface = request.surface ?? findSurface(id)
      if (surface === undefined) throw new HostError(404, 'not-found', `${parsed.pkg} declares no contribution ${id}`)
      const item = surfaceItem(surface, id)
      if (item === undefined) throw new HostError(404, 'not-found', `${parsed.pkg} declares no ${surface} ${id}`)
      if (!(item.requires ?? []).every(x => caps.features?.includes(x))) throw new HostError(409, 'unsupported', 'action requires capabilities')
      if (item.effect !== undefined) throw new HostError(409, 'no-handler', `${id} has a static effect; the app runs it without invoke`)
      let fn
      if (surface === 'panel' && request.action !== undefined) fn = regs.panels.get(id)?.actions?.[request.action]
      fn ??= regs.handlers.get(id)
      if (typeof fn !== 'function') throw new HostError(409, 'no-handler', `no handler for ${id}${request.action ? `/${request.action}` : ''}`)
      const arg = { ...(request.scope ?? {}) }
      for (const k of (CONTEXT_FOR[surface] ?? []).filter((k) => parsed.wants.includes(k))) {
        if (typeof request.context?.[k] === 'string') arg[k] = request.context[k]
      }
      const event = { surface, id, locale: request.locale ?? caps.locale }
      if (request.action !== undefined) event.action = request.action
      if (request.value !== undefined) event.value = request.value
      let result
      try {
        result = await withTimeout(fn(arg, event), LIMITS.handlerTimeoutMs, `on(${id})`)
      } catch (error) {
        violations.push({ id, error })
        if (error instanceof HostError) throw error
        throw Object.assign(new HostError(500, 'plugin-error', `handler failed: ${error?.message ?? error}`), { cause: error })
      }
      const panels = new Set(parsed.items.panels.map((p) => p.id))
      const source = surface === 'panel' ? id : undefined
      const deferred = splitPending(result)
      if (deferred !== undefined) return startPending(id, deferred, panels, source)
      const norm = normalizeEffects(result, { panels, source, userGesture: request.userGesture === true, capabilities: { declared: parsed.capabilities ?? [], features: caps.features ?? [], media: (parsed.items.media ?? []).map(x => x.id), overlays: (parsed.items.overlays ?? []).map(x => x.id) } })
      if (norm.violation) violations.push({ id, issues: norm.issues })
      return { effects: norm.effects, issues: norm.issues }
    },
    // Direct callback probes, not HTTP authorization/lease or scheduling simulations.
    async media(id, scope = {}, options = {}) {
      const fn = regs.media.get(id)
      if (!parsed.capabilities?.includes('audio') || !(parsed.items.media ?? []).some(x => x.id === id) || !fn) throw new HostError(404, 'not-found', 'no media')
      const result = await withTimeout(fn({ ...scope }, { locale: caps.locale, signal: new AbortController().signal, ...options }), CAP_LIMITS.mediaMs, 'media')
      if (!(result?.body instanceof Uint8Array) || !AUDIO_TYPES.has(result.contentType) || result.body.byteLength < 1 || result.body.byteLength > CAP_LIMITS.mediaBytes) throw new HostError(502, 'invalid-media', 'invalid audio result')
      return result
    },
    subscribeMicro(id, scope = {}) {
      const def = regs.micro.get(id)
      if (!caps.features?.includes('micro') || !parsed.capabilities?.includes('micro') || !(parsed.items.micro ?? []).some(x => x.id === id) || !def) throw new HostError(404, 'not-found', 'no micro')
      let closed = false, cancel
      const feed = { id, scope, data: undefined, history: [], errors: [], stale: 0, settled: Promise.resolve(), stop() { if (closed) return; closed = true; if (cancel) runCleanup(cancel, failed) } }
      const failed = recordFailure(feed)
      const emit = value => { if (closed) return; const model = microModel(value); if (!model) { feed.errors.push('invalid micro model'); return } feed.data = model; feed.history.push(model) }
      feed.settled = new Promise(resolve => resolve(def.data({ ...scope }, emit, { protocol: 1, locale: caps.locale }))).then(fn => {
        if (typeof fn !== 'function') return
        if (closed) runCleanup(fn, failed)
        else cancel = fn
      }).catch(failed)
      feeds.add(feed)
      return feed
    },
    async capabilityEvent(scope, event) {
      // Explicit test injection only; callback returns never become effects.
      // This probe has no lease lifecycle; its standalone signal does not model terminal revocation.
      await regs.capability.get('events')?.({ ...scope }, { signal: new AbortController().signal, ...event })
    },
    /** Deferred results still running (each settles once: done, timeout, cancelled or error). */
    pendings,
    /** GET /dsh-go/v1/views/<pkg>/<id>: the view your panel(id) returns for `scope`, with stats. */
    async view(id, scope = {}, capsOverride = {}) {
      const item = parsed.items.panels.find((p) => p.id === id)
      if (item === undefined) throw new HostError(404, 'not-found', `${parsed.pkg} declares no panel ${id}`)
      const reg = regs.panels.get(id)
      let view
      if (reg !== undefined) {
        view = typeof reg.view === 'function' ? await withTimeout(reg.view({ ...scope }, { ...caps, ...capsOverride }), LIMITS.viewTimeoutMs, `view(${id})`) : reg.view
      } else if (item.viewFile !== undefined) {
        view = JSON.parse(readFileSync(item.viewFile, 'utf8'))
      } else {
        throw new HostError(409, 'no-handler', `${parsed.pkg} has neither panel("${id}") nor a static view`)
      }
      const json = isPlainObject(view) ? toJson(view) : undefined
      if (json === undefined) throw new HostError(500, 'invalid-view', `view(${id}) is not a JSON object`)
      if (json.bytes > LIMITS.viewBytes) throw new HostError(500, 'invalid-view', `view(${id}) exceeds ${LIMITS.viewBytes} bytes`)
      return { view: json.value, stats: { bytes: json.bytes, ...viewStats(json.value) }, source: reg !== undefined ? 'registered' : 'file' }
    },
    /**
     * Start the data function of panel, strip or turn note `id` for `scope`. `feed.data` is the
     * latest value as the app would hold it (nulls dropped, strip text cut to 24); `feed.history`
     * all of them; `feed.settled` resolves once the data function has finished starting. Removing
     * or replacing the registration stops the feed. No 4 Hz throttling here: every emit is recorded.
     */
    subscribe(id, scope = {}) {
      // As the bridge does: the manifest says what this id is, whatever else is registered under it.
      const kind = parsed.ids.get(id)
      const reg = { 'composer.strip': regs.strips, 'turn.note': regs.notes, panels: regs.panels }[kind]?.get(id)
      const dataFn = reg?.data
      let stopped = false
      let cancel
      const feed = {
        id, scope, data: undefined, history: [], stale: 0, errors: [], settled: Promise.resolve(),
        stop: () => {
          stopped = true
          const fn = cancel
          cancel = undefined
          if (typeof fn === 'function') runCleanup(fn, failed)
        },
      }
      const failed = recordFailure(feed)
      if (typeof dataFn !== 'function') {
        feed.data = null
        return feed
      }
      const emit = (d) => {
        if (stopped) return
        let value
        if (kind === 'composer.strip') {
          value = stripValue(d)
          if (value === undefined) return feed.errors.push(`strip(${id}) emitted a non-object`)
        } else if (kind === 'turn.note') {
          value = sanitizeNotes(d)
          if (value === undefined) return feed.errors.push(`turnNote(${id}) emitted a non-object`)
        } else {
          if (d !== null && !isPlainObject(d)) return feed.errors.push(`data(${id}) emitted a non-object`)
          const json = toJson(d)
          if (json === undefined) return feed.errors.push(`data(${id}) emitted a value that is not JSON`)
          if (json.bytes > LIMITS.dataBytes) return feed.errors.push(`data(${id}) is ${json.bytes} bytes (max ${LIMITS.dataBytes})`)
          value = json.value === null ? null : withoutNulls(json.value)
        }
        feed.data = value
        feed.history.push(value)
      }
      try {
        const result = dataFn({ ...scope }, emit, { protocol: caps.protocol, locale: caps.locale })
        if (typeof result === 'function') cancel = result
        // A cleanup that arrives after stop() still has to run.
        else feed.settled = Promise.resolve(result).then((fn) => {
          if (typeof fn !== 'function') return
          if (stopped) runCleanup(fn, failed)
          else cancel = fn
        }).catch(failed)
      } catch (error) {
        failed(error)
      }
      feeds.add(feed)
      return feed
    },
    /** Fire a host event to the plugin's ctx.on listeners, e.g. emitEvent('session/event', session, event). */
    emitEvent(name, ...args) {
      for (const fn of listeners.get(name) ?? []) fn(...args)
    },
    /** Run the plugin's effect disposers. */
    dispose() {
      for (const p of [...pendings.values()]) p.cancel()
      for (const feed of feeds) feed.stop()
      while (disposers.length > 0) disposers.pop()()
    },
  }
}

export { HostError }
