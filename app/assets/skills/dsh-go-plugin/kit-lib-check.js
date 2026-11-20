// `check`: what the dsh-go app and the bridge will say about a plugin, before
// you install it. Manifest problems come from the bridge's own parser
// (lib/bridge/, copied from runtime/bridge), view problems from a line-by-line
// twin of the app's parser (lib/view-check.js), with the app's words.
// Zero dependencies; Node 22.19+.
//
//   node bin/check.mjs <plugin dir | package.json | view.json | -> [--load] [--json] [--lang en]
//                      [--budget toolCard|panel|strip] [--app x.y.z]
//
// Exit codes: 0 nothing that stops anything (notes allowed), 1 some items do not
// apply, 2 the plugin's native part or the view does not apply at all, 3 cannot read.
import { existsSync, readFileSync, statSync } from 'node:fs'
import { delimiter, dirname, join, relative, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { ICON, LIMITS, SEMVER } from './bridge/limits.js'
import { checkManifest as bridgeCheckManifest, insidePackage } from './bridge/manifest.js'
import { BUDGETS, bindingsIn, checkView, labeled } from './view-check.js'

export { checkView, BUDGETS }

const VIEW_KEY = 'dsh-go/view'
const ICONS = new Set(JSON.parse(readFileSync(new URL('../schema/view.schema.json', import.meta.url), 'utf8')).$defs.icon.anyOf[0].enum)

// ── words (the check's own; issue texts come from the app / bridge) ─────────

const WORDS = {
  zh: {
    error: '错误', warn: '提示', note: '提示', fatal: '错误',
    plugin: (name, version) => `${name}${version ? ` ${version}` : ''}`,
    noDshGo: '没有 dshGo 清单：只有工具卡（presentationMeta）这类零成本扩展',
    manifest: { ok: '原生界面能显示', invalid: '清单无效，原生部分不显示', unsupported: '协议版本不被支持，原生部分不显示', 'needs-app': 'App 版本太低，原生部分不显示', degraded: '已降级' },
    counts: (c) => [
      c['composer.actions'] && `胶囊 ${c['composer.actions']}`,
      c['message.actions'] && `菜单 ${c['message.actions']}`,
      c['composer.strip'] && `状态条 ${c['composer.strip']}`,
      c.panels && `面板 ${c.panels}`,
      c['composer.tools'] && `加号工具 ${c['composer.tools']}`,
      c['session.actions'] && `对话操作 ${c['session.actions']}`,
      c['turn.note'] && `回合尾注 ${c['turn.note']}`,
    ].filter(Boolean).join(' · '),
    view: (where, budget) => `视图 ${where}（${{ toolCard: '工具卡', panel: '面板', strip: '状态条' }[budget]}）`,
    viewOk: '能显示', viewFatal: '整块无法显示：', viewProblems: (n) => `，${n} 处问题`,
    unknownIcon: '不认识的图标，已换成默认图标',
    notBundle: '不是 DSH 组合包：package.json 缺 dsh.bundle.patch，DSH 装不上',
    patchMissing: (p) => `找不到组合包补丁文件 ${p}`,
    noEngines: '没写 engines.dsh：DSH 不检查版本，装到不兼容的 DSH 上会在运行时出错',
    noName: '缺少 name',
    cardBindings: '工具卡没有数据模型，绑定都会显示成「—」',
    cardTaps: '工具卡（第 0 期）不能点：按钮、确认不显示，选项只读',
    loadHint: '加 --load 再查处理函数和视图函数',
    loaded: (n) => `已加载宿主半侧：${n} 项可用`,
    loadedTools: '已加载',
    loadFailed: (m) => `宿主半侧加载失败：${m}`,
    optionalInject: "写成了 ctx.inject(['dshGo?'])：cordis 没有可选依赖语法，这个回调永远不执行，改成 ['dshGo']",
    topInject: '插件顶层的 inject 里有 dshGo：没有桥接的主机上整个插件起不来，改用 ctx.inject([\'dshGo\'], …)',
    viewFailed: (id, m) => `面板 ${id} 的视图函数出错：${m}`,
    stripText: (id, n) => `状态条 ${id} 的文字超过 24 字（${n} 字），会被截断`,
    stripEmit: (id, m) => `状态条 ${id}：${m}`,
    tools: (names) => `注册了工具：${names}`,
    missing: (p) => `找不到 ${p}`,
    readFailed: (p, m) => `读不了 ${p}：${m}`,
    notJson: (m) => `不是合法的 JSON（${m}）`,
    packageObject: 'package.json 必须是 JSON 对象',
    optionValue: (name) => `${name} 缺少值`,
    unknownOption: (name) => `不认识的选项 ${name}；以 - 开头的文件名请放在 -- 后面`,
    invalidOption: (name, values) => `${name} 必须是 ${values}`,
  },
  en: {
    error: 'error', warn: 'note', note: 'note', fatal: 'error',
    plugin: (name, version) => `${name}${version ? ` ${version}` : ''}`,
    noDshGo: 'No dshGo manifest: only zero-cost extensions such as tool cards (presentationMeta)',
    manifest: { ok: 'Native UI shows', invalid: 'Invalid manifest; the native part is not shown', unsupported: 'Protocol version not supported; the native part is not shown', 'needs-app': 'App too old; the native part is not shown', degraded: 'Degraded' },
    counts: (c) => [
      c['composer.actions'] && `${c['composer.actions']} capsule(s)`,
      c['message.actions'] && `${c['message.actions']} menu item(s)`,
      c['composer.strip'] && `${c['composer.strip']} strip`,
      c.panels && `${c.panels} panel(s)`,
      c['composer.tools'] && `${c['composer.tools']} plus-panel tool(s)`,
      c['session.actions'] && `${c['session.actions']} chat action(s)`,
      c['turn.note'] && `${c['turn.note']} turn note`,
    ].filter(Boolean).join(' · '),
    view: (where, budget) => `View ${where} (${{ toolCard: 'tool card', panel: 'panel', strip: 'strip' }[budget]})`,
    viewOk: 'renders', viewFatal: 'does not render: ', viewProblems: (n) => `, ${n} problem(s)`,
    unknownIcon: 'Unknown icon; drawn as the default icon',
    notBundle: 'Not a DSH bundle: package.json lacks dsh.bundle.patch, DSH cannot install it',
    patchMissing: (p) => `Bundle patch file ${p} not found`,
    noEngines: 'No engines.dsh: DSH does not check versions and an incompatible DSH fails at run time',
    noName: 'Missing name',
    cardBindings: 'A tool card has no data model; every binding shows as "—"',
    cardTaps: 'Tool cards (phase 0) are not tappable: buttons and confirms are hidden, options read-only',
    loadHint: 'Add --load to check handlers and view functions too',
    loaded: (n) => `Host half loaded: ${n} item(s) ready`,
    loadedTools: 'Loaded',
    loadFailed: (m) => `Host half failed to load: ${m}`,
    optionalInject: "ctx.inject(['dshGo?']) never runs: cordis has no optional syntax; write ['dshGo']",
    topInject: "dshGo is in the plugin's top-level inject: the plugin will not start on hosts without the bridge; use ctx.inject(['dshGo'], …)",
    viewFailed: (id, m) => `View function of panel ${id} failed: ${m}`,
    stripText: (id, n) => `Strip ${id} text is over 24 characters (${n}); it will be cut`,
    stripEmit: (id, m) => `Strip ${id}: ${m}`,
    tools: (names) => `Tools registered: ${names}`,
    missing: (p) => `${p} not found`,
    readFailed: (p, m) => `Cannot read ${p}: ${m}`,
    notJson: (m) => `Not valid JSON (${m})`,
    packageObject: 'package.json must be a JSON object',
    optionValue: (name) => `${name} requires a value`,
    unknownOption: (name) => `Unknown option ${name}; put filenames beginning with - after --`,
    invalidOption: (name, values) => `${name} must be ${values}`,
  },
}

const words = (lang) => WORDS[lang === 'en' ? 'en' : 'zh']

// ── manifest ──────────────────────────────────────────────────────────────

const FEED_SETTLE_MS = 2000
const LOCALES = ['zh-CN', 'en-US']

/** App-side icon problems (the app draws unknown names as its default glyph). */
function iconIssues(pkgJson, w) {
  const out = []
  const m = pkgJson.dshGo
  if (typeof m !== 'object' || m === null) return out
  const check = (icon, path) => {
    if (typeof icon === 'string' && ICON.test(icon) && !ICONS.has(icon)) out.push({ path, code: 'unknown-icon', severity: 'warn', message: w.unknownIcon })
  }
  check(m.icon, '/dshGo/icon')
  for (const [surface, list] of Object.entries(m.contributes ?? {})) {
    if (Array.isArray(list)) list.forEach((item, i) => check(item?.icon, `/dshGo/contributes/${surface}/${i}/icon`))
  }
  return out
}

/**
 * The plugin's native part as the bridge reports it (lib/bridge/manifest.js
 * checkManifest), for every locale the app ships: labels are measured per
 * language. `registrations`: what the host half registered (from --load); without
 * it every handler is assumed present, so only static problems show.
 */
export function checkManifest(pkgJson, options = {}) {
  const w = words(options.lang)
  const dir = resolve(options.dir ?? '.')
  const regs = options.registrations
  const seen = new Set()
  const issues = []
  let first
  for (const locale of LOCALES) {
    const r = bridgeCheckManifest(pkgJson, dir, {
      locale,
      app: options.app,
      ...(regs === undefined ? { handlers: 'assume' } : { handlers: [...regs.handlers, ...regs.panels], panels: regs.panels, strips: regs.strips, notes: regs.notes, dataPanels: regs.dataPanels }),
    })
    first ??= r
    for (const i of r.issues) {
      const key = `${i.path}\0${i.code}\0${i.message}`
      if (!seen.has(key)) {
        seen.add(key)
        issues.push(i)
      }
    }
  }
  if (first.state === 'absent') return null
  issues.push(...iconIssues(pkgJson, w))
  const row = first.plugin
  const counts = Object.fromEntries(Object.entries(row.contributes).map(([k, v]) => [k, v.length]))
  const rawPanels = pkgJson.dshGo?.contributes?.panels
  const panels = Array.isArray(rawPanels) ? rawPanels : []
  return { state: row.state, title: row.title, counts, contributes: row.contributes, issues, panels }
}

// ── package basics ────────────────────────────────────────────────────────

function packageIssues(pkgJson, dir, w) {
  const out = []
  if (typeof pkgJson.name !== 'string' || pkgJson.name === '') out.push({ path: '/name', code: 'package', severity: 'error', message: w.noName })
  const patch = pkgJson.dsh?.bundle?.patch
  if (typeof patch !== 'string') out.push({ path: '/dsh/bundle/patch', code: 'package', severity: 'error', message: w.notBundle })
  else if (!existsSync(join(dir, patch))) out.push({ path: '/dsh/bundle/patch', code: 'package', severity: 'error', message: w.patchMissing(patch) })
  if (typeof pkgJson.engines?.dsh !== 'string') out.push({ path: '/engines/dsh', code: 'package', severity: 'warn', message: w.noEngines })
  return out
}

// ── loading the host half (--load) ────────────────────────────────────────

let hooksInstalled = false

/**
 * Let the plugin's `import … from '@deepseek-ai/…'` resolve: from an installed DSH (DSH_DIR,
 * or the `dsh` on PATH) by resolving as if imported from inside it; `dsh-tools` falls back to a
 * stub whose defineTool returns the definition.
 */
async function installHooks() {
  if (hooksInstalled) return
  hooksInstalled = true
  const { registerHooks } = await import('node:module')
  const { realpathSync } = await import('node:fs')
  const parents = []
  const add = (pkgDir) => {
    const bin = join(pkgDir, 'lib', 'bin.js')
    if (existsSync(bin)) parents.push(pathToFileURL(bin).href)
  }
  if (process.env.DSH_DIR) add(process.env.DSH_DIR)
  for (const d of (process.env.PATH ?? '').split(delimiter)) {
    const bin = join(d, 'dsh')
    if (!existsSync(bin)) continue
    try {
      add(dirname(dirname(realpathSync(bin))))
    } catch {}
  }
  const stub = `data:text/javascript,${encodeURIComponent('export const defineTool = (o) => o')}`
  registerHooks({
    resolve(specifier, context, next) {
      if (!specifier.startsWith('@deepseek-ai/')) return next(specifier, context)
      try {
        return next(specifier, context)
      } catch {}
      for (const parentURL of parents) {
        try {
          return next(specifier, { ...context, parentURL })
        } catch {}
      }
      if (specifier === '@deepseek-ai/dsh-tools') return { url: stub, shortCircuit: true }
      return next(specifier, context)
    },
  })
}

function entryOf(pkgJson, dir) {
  const e = pkgJson.exports
  const dot = typeof e === 'string' ? e : e?.['.']
  const target = typeof dot === 'string' ? dot : dot?.import ?? dot?.default ?? pkgJson.main ?? 'index.js'
  return join(dir, target)
}

const SAMPLE_SCOPES = { 'session.tab': { sessionId: 'check-session' }, 'chat.panel': { sessionId: 'check-session' }, features: {}, plugin: {} }

async function loadHostHalf(pkgJson, dir, w) {
  // The plugin's code runs here: keep it away from the real DSH home.
  const saved = process.env.DSH_HOME
  const { mkdtempSync, rmSync } = await import('node:fs')
  const { tmpdir } = await import('node:os')
  const home = mkdtempSync(join(tmpdir(), 'dsh-go-check-'))
  process.env.DSH_HOME = home
  try {
    return await loadIn(pkgJson, dir, w)
  } finally {
    if (saved === undefined) delete process.env.DSH_HOME
    else process.env.DSH_HOME = saved
    rmSync(home, { recursive: true, force: true })
  }
}

async function loadIn(pkgJson, dir, w) {
  const notes = []
  const { createTestHost } = await import('./testing.js')
  await installHooks()
  let mod
  try {
    mod = await import(pathToFileURL(entryOf(pkgJson, dir)).href)
  } catch (error) {
    return { ok: false, error: w.loadFailed(String(error?.message ?? error).split('\n')[0]) }
  }
  const tools = []
  const services = {
    tools: { register: (def) => { tools.push(def?.name); return () => {} } },
    sessions: { get: () => undefined, list: () => [] },
    commands: { register: () => () => {} },
  }
  // As the newest app sees it: every v1.2 capability on offer.
  const { FEATURES } = await import('./bridge/capabilities.js')
  const host = createTestHost({ dir, pkg: pkgJson, services, caps: { features: [...FEATURES] } })
  if (Array.isArray(mod.inject) ? mod.inject.includes('dshGo') : mod.inject && typeof mod.inject === 'object' && 'dshGo' in mod.inject) {
    notes.push({ path: '/runtime/inject', code: 'load', severity: 'error', message: w.topInject })
  }
  try {
    let config = {}
    if (mod.Config) {
      // Cordis resolves the plugin's own Standard Schema before apply.
      const result = mod.Config['~standard'].validate(config)
      if ('then' in result) {
        // Refuse async validation without leaving its eventual rejection unobserved.
        Promise.resolve(result).catch(() => {})
        throw new TypeError('Async config validation is not supported')
      }
      if (result.issues) throw new TypeError(`invalid config: ${result.issues.map(issue => issue.message).join('; ')}`)
      config = result.value
    }
    await mod.apply?.(host.ctx, config)
  } catch (error) {
    return { ok: false, error: w.loadFailed(String(error?.message ?? error).split('\n')[0]) }
  }
  if (host.pending.some((p) => p.missing.some((n) => n.endsWith('?')))) {
    notes.push({ path: '/runtime/inject', code: 'load', severity: 'error', message: w.optionalInject })
  }
  const views = []
  const row = host.contributions()
  for (const panel of host.parsed.items.panels) {
    for (const placement of panel.placement) {
      for (const locale of LOCALES) {
        try {
          const r = await host.view(panel.id, SAMPLE_SCOPES[placement] ?? {}, { locale })
          if (r.source === 'file') break   // checked once below, as a file
          views.push({ where: `${panel.id} · ${placement} · ${locale}`, view: r.view, budget: 'panel' })
        } catch (error) {
          if (error?.code === 'no-handler') continue
          notes.push({ path: `/runtime/${panel.id}`, code: 'load', severity: 'error', message: w.viewFailed(panel.id, String(error?.message ?? error)) })
        }
      }
    }
  }
  const feeds = [...host.parsed.items['composer.strip'], ...(host.parsed.items['turn.note'] ?? [])]
    .map((item) => host.subscribe(item.id, { sessionId: 'check-session' }))
  // A data function may be async: wait for it to finish starting, but not for one that never does.
  let timer
  await Promise.race([
    Promise.all(feeds.map((feed) => feed.settled)),
    new Promise((done) => { timer = setTimeout(done, FEED_SETTLE_MS) }),
  ])
  clearTimeout(timer)
  for (const feed of feeds) {
    for (const e of feed.errors) notes.push({ path: `/runtime/${feed.id}`, code: 'load', severity: 'error', message: w.stripEmit(feed.id, e) })
    feed.stop()
  }
  host.dispose()
  const count = [...Object.values(row.contributes)].flat().filter((x) => x.ready).length
  return { ok: true, row, notes, views, tools: tools.filter(Boolean), registered: count, registrations: host.registrations() }
}

// ── plugin ────────────────────────────────────────────────────────────────

/**
 * Check a plugin directory: package basics, the dshGo manifest (every locale),
 * static view files, and with `load: true` the host half's registrations and views.
 */
export async function checkPlugin(dirOrFile, options = {}) {
  const w = words(options.lang)
  let dir = resolve(dirOrFile)
  if (dir.endsWith('package.json')) dir = dirname(dir)
  const pkgPath = join(dir, 'package.json')
  if (!existsSync(pkgPath)) return { kind: 'plugin', target: dir, unreadable: w.missing(pkgPath) }
  let pkgJson
  try {
    pkgJson = JSON.parse(readFileSync(pkgPath, 'utf8'))
  } catch (error) {
    return { kind: 'plugin', target: dir, unreadable: w.readFailed(pkgPath, error.message) }
  }
  if (pkgJson === null || typeof pkgJson !== 'object' || Array.isArray(pkgJson)) {
    return { kind: 'plugin', target: dir, unreadable: w.readFailed(pkgPath, w.packageObject) }
  }
  const report = { kind: 'plugin', target: dir, name: pkgJson.name, version: pkgJson.version, package: packageIssues(pkgJson, dir, w), views: [], load: null }
  if (options.load) report.load = await loadHostHalf(pkgJson, dir, w)
  const loaded = report.load?.ok ? report.load : undefined
  report.manifest = checkManifest(pkgJson, { dir, lang: options.lang, app: options.app, registrations: loaded?.registrations })
  if (report.manifest !== null) {
    if (loaded) {
      report.manifest.issues.push(...loaded.row.issues.filter((i) => i.code === 'undeclared'))
      for (const v of loaded.views) report.views.push({ where: v.where, ...checkView(v.view, { budget: v.budget, lang: options.lang }) })
    }
    // Static view files: the bridge checked size and JSON; the app checks the rest.
    for (const panel of report.manifest.panels) {
      if (typeof panel?.view !== 'string') continue
      // Use the bridge's path policy, including real-path containment. A raw
      // string prefix accepts sibling directories and follows rejected symlinks.
      const file = insidePackage(dir, panel.view)
      if (file === undefined || !file.endsWith('.json') || !existsSync(file)) continue
      const where = relative(dir, file)
      try {
        const st = statSync(file)
        if (!st.isFile() || st.size > LIMITS.viewBytes) continue
        report.views.push({ where, ...checkView(readFileSync(file, 'utf8'), { budget: 'panel', lang: options.lang }) })
      } catch (error) {
        report.views.push({ where, unreadable: w.readFailed(where, error.message) })
      }
    }
    delete report.manifest.panels
  }
  return report
}

// ── single view ───────────────────────────────────────────────────────────

/** Check a view file (or a tool result meta `{ "dsh-go/view": … }`). */
export function checkViewText(text, options = {}) {
  const w = words(options.lang)
  let json
  try {
    json = JSON.parse(text)
  } catch (error) {
    return { kind: 'view', target: options.target ?? '-', unreadable: w.notJson(error.message) }
  }
  let budget = options.budget
  let view = json
  if (typeof json === 'object' && json !== null && !Array.isArray(json) && VIEW_KEY in json && json.type === undefined) {
    view = json[VIEW_KEY]
    budget ??= 'toolCard'
  }
  budget ??= 'panel'
  const result = checkView(view, { budget, lang: options.lang })
  const extra = []
  if (budget === 'toolCard' && !result.fatal) {
    if (bindingsIn(view).length > 0) extra.push({ path: bindingsIn(view)[0].path, message: w.cardBindings, kind: 'note' })
    if (JSON.stringify(view).match(/"type":"(actions|confirm)"/)) extra.push({ path: 'view', message: w.cardTaps, kind: 'note' })
  }
  return { kind: 'view', target: options.target ?? '-', views: [{ where: options.target ?? '-', ...result, issues: [...result.issues, ...extra] }] }
}

// ── output ────────────────────────────────────────────────────────────────

const sevOf = (i) => (i.severity ?? (i.kind === 'note' ? 'note' : i.kind === 'fatal' ? 'fatal' : 'error'))

/** Exit code for a report (see the header). */
export function exitCode(report) {
  if (report.unreadable) return 3
  const views = report.views ?? []
  const manifestDead = report.manifest && report.manifest.state !== 'ok'
  const loadFailed = report.load && !report.load.ok
  if (manifestDead || loadFailed || views.some((v) => v.fatal || v.unreadable)) return 2
  const errors = [
    ...(report.package ?? []),
    ...(report.manifest?.issues ?? []),
    ...(report.load?.notes ?? []),
    ...views.flatMap((v) => v.issues ?? []),
  ].filter((i) => ['error', 'broken', 'fatal'].includes(i.severity ?? i.kind))
  return errors.length > 0 ? 1 : 0
}

/** Human-readable lines, in the app's words. */
export function formatReport(report, lang) {
  const w = words(lang)
  const out = []
  const line = (i, indent = '  ') => {
    const sev = sevOf(i)
    const label = w[sev] ?? w.error
    const colon = lang === 'en' ? ': ' : '：'
    if (i.code !== undefined) out.push(`${indent}${label} ${i.path ? `${i.path}${colon}` : ''}${i.message}`)
    else out.push(`${indent}${label} ${labeled(i, lang)}`)
  }
  if (report.unreadable) {
    out.push(report.unreadable)
    return out.join('\n')
  }
  if (report.kind === 'plugin') {
    out.push(w.plugin(report.name ?? report.target, report.version))
    for (const i of report.package) line(i)
    if (report.manifest === null) out.push(`  ${w.noDshGo}`)
    else if (report.manifest) {
      const m = report.manifest
      const counts = w.counts(m.counts)
      const tail = m.state === 'ok' && counts ? (lang === 'en' ? ` (${counts})` : `（${counts}）`) : ''
      out.push(`  ${w.manifest[m.state] ?? m.state}${tail}`)
      for (const i of m.issues) line(i, '    ')
    }
    if (report.load) {
      if (!report.load.ok) out.push(`  ${w.error} ${report.load.error}`)
      else {
        const sep = lang === 'en' ? '; ' : '；'
        const toolText = report.load.tools.length ? w.tools(report.load.tools.join(lang === 'en' ? ', ' : '、')) : ''
        if (report.manifest) out.push(`  ${w.loaded(report.load.registered)}${toolText ? `${sep}${toolText}` : ''}`)
        else out.push(`  ${w.loadedTools}${toolText ? `${sep}${toolText}` : ''}`)
        for (const i of report.load.notes) line(i, '    ')
      }
    } else if (report.manifest) {
      out.push(`  ${w.loadHint}`)
    }
  }
  for (const v of report.views ?? []) {
    if (v.unreadable) {
      out.push(`  ${w.error} ${v.unreadable}`)
      continue
    }
    const head = w.view(v.where, v.budget)
    if (v.fatal) {
      out.push(`  ${head}${lang === 'en' ? ': ' : '：'}${w.viewFatal}${labeled(v.issues.find((i) => i.kind === 'fatal'), lang)}`)
      continue
    }
    out.push(`  ${head}${lang === 'en' ? ': ' : '：'}${w.viewOk}${v.issues.length ? w.viewProblems(v.issues.length) : ''}`)
    for (const i of v.issues) line(i, '    ')
  }
  return out.join('\n')
}

// ── CLI ───────────────────────────────────────────────────────────────────

function parseArgs(argv) {
  const opts = { targets: [], json: false, load: false, lang: undefined, budget: undefined, app: undefined }
  const optionArgs = argv.slice(0, argv.indexOf('--') < 0 ? argv.length : argv.indexOf('--'))
  const w = words(optionArgs.some((a, i) => a === '--lang=en' || (a === '--lang' && optionArgs[i + 1] === 'en')) ? 'en' : 'zh')
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--') {
      opts.targets.push(...argv.slice(i + 1))
      break
    }
    if (a === '--json') opts.json = true
    else if (a === '--load') opts.load = true
    else if (/^--(lang|budget|app)(=|$)/.test(a)) {
      const equals = a.indexOf('=')
      const name = equals < 0 ? a : a.slice(0, equals)
      const value = equals < 0 ? argv[++i] : a.slice(equals + 1)
      if (value === undefined || value === '' || value.startsWith('-')) throw new Error(w.optionValue(name))
      opts[name.slice(2)] = value
    } else if (a !== '-' && a.startsWith('-')) throw new Error(w.unknownOption(a))
    else opts.targets.push(a)
  }
  if (opts.lang !== undefined && !['zh', 'en'].includes(opts.lang)) throw new Error(w.invalidOption('--lang', 'zh, en'))
  opts.lang ??= 'zh'
  if (opts.budget !== undefined && !Object.hasOwn(BUDGETS, opts.budget)) throw new Error(w.invalidOption('--budget', Object.keys(BUDGETS).join(', ')))
  if (opts.app !== undefined && !SEMVER.test(opts.app)) throw new Error(w.invalidOption('--app', 'x.y.z'))
  if (opts.targets.length === 0) opts.targets.push('.')
  return opts
}

export async function main(argv, io = { stdout: process.stdout, stdin: 0 }) {
  let opts
  try {
    opts = parseArgs(argv)
  } catch (error) {
    const flags = argv.slice(0, argv.indexOf('--') < 0 ? argv.length : argv.indexOf('--'))
    const report = { kind: 'arguments', unreadable: error.message }
    io.stdout.write(`${flags.includes('--json') ? JSON.stringify(report) : report.unreadable}\n`)
    return 3
  }
  let worst = 0
  const reports = []
  for (const target of opts.targets) {
    let report
    if (target === '-') {
      try {
        report = checkViewText(readFileSync(io.stdin, 'utf8'), { lang: opts.lang, budget: opts.budget, target: '-' })
      } catch (error) {
        report = { kind: 'view', target, unreadable: words(opts.lang).readFailed('-', error.message) }
      }
    } else {
      const path = resolve(target)
      let isDir = false
      try {
        isDir = statSync(path).isDirectory()
      } catch {
        report = { kind: 'view', target, unreadable: words(opts.lang).missing(target) }
      }
      if (report === undefined) {
        if (isDir || path.endsWith('package.json')) report = await checkPlugin(path, { load: opts.load, lang: opts.lang, app: opts.app })
        else {
          try {
            report = checkViewText(readFileSync(path, 'utf8'), { lang: opts.lang, budget: opts.budget, target })
          } catch (error) {
            report = { kind: 'view', target, unreadable: words(opts.lang).readFailed(target, error.message) }
          }
        }
      }
    }
    reports.push(report)
    worst = Math.max(worst, exitCode(report))
  }
  if (opts.json) io.stdout.write(`${JSON.stringify(reports.length === 1 ? reports[0] : reports)}\n`)
  else io.stdout.write(`${reports.map((r) => formatReport(r, opts.lang)).join('\n\n')}\n`)
  return worst
}

export { LIMITS }
export { SchemaSet, loadSchemas } from './json-schema.js'
