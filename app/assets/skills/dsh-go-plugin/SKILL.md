---
# dsh-go:managed — the dsh-go app keeps this skill up to date; delete this line to keep your own edits.
name: dsh-go-plugin
description: 给 dsh-go 手机 App 写一个本地小插件，在**手机原生界面**里出现：输入框上方的胶囊、回复长按菜单里的操作、状态条、原生面板、工具结果卡片，还能朗读、开口即停、显示字幕；写完用自带的检查器检查，装进当前主机。用户要给 dsh-go App 加需要逻辑或数据的东西时先加载它，比如「输入框上面加个按钮，把剪贴板译成英文」「长按消息加个『存到笔记』」「输入框上方显示今天用了多少」「做个面板看我的待办」「这个工具的结果画成卡片」「加个按钮把回复读出来」。只用于 dsh-go 手机原生界面；用户要做 Cordis 插件、改 Harness 网页版 / 桌面端，或明确说的是网页插件时，用官方 cordis-plugin-development 技能，不要用本技能的目录和安装方式。Write a small local DSH plugin that shows up natively in the dsh-go phone app; for Cordis / Harness Web UI plugins use the official skill instead.
whenToUse: The user wants to add something of their own to the dsh-go phone app (手机 App / 原生界面) that needs logic or data. For fixed buttons, layout, theme or hiding things use the dsh-go-ui skill (ui.json) instead. For Cordis plugins or the Harness Web UI / desktop, use the official cordis-plugin-development skill — different directory and install entry.
---

# 给 dsh-go 写一个本地小插件

插件是一个放在主机上的 npm 包目录：`package.json` 里的 `dshGo` 清单声明 App 里出现什么，`lib/index.js` 在引擎里处理点按、推数据。App 只画声明和 JSON 视图，不执行插件代码。

## 和官方技能的分工（先判断界面载体）

这个技能只负责 **dsh-go 手机 App 的原生界面**。创造模式里还会加载官方的 `cordis-plugin-development`，它负责 **Harness Web UI / 桌面端**的插件，两套的目录、清单和安装入口都不同。**先确定界面载体，再选技能**；不要按加载顺序、也不要混着用：

| 用户要的 | 用哪个 | 目录 / 安装 |
|---|---|---|
| 手机 App 里加胶囊、菜单项、状态条、原生面板、工具结果卡片、朗读 / 字幕 | 本技能 | `$DSH_HOME/dsh-go/plugins/<name>/`，`dsh plugin --profile web add <目录>` |
| 改 dsh-go App 自己的样子（顶栏按钮、主题、隐藏元素） | `dsh-go-ui`（ui.json） | `$DSH_HOME/dsh-go/ui.json` |
| Cordis / Harness Web UI 插件、装饰、槽位、MCP、页面 | 官方 `cordis-plugin-development` | 工作区建包 + `plugin_manager` → `install_bundle` |
| Agent 预设、Cordis 组合 | 官方组合类技能 | 官方流程 |

- 用户没点名界面载体时：在本 App 里默认目标是 dsh-go 手机原生界面（`AGENTS.md` 也这么写）；但如果用户明确要网页版 / 桌面端，就按官方技能走。
- 官方技能里的「不要在工作区外建包、不要在 `$DSH_HOME` 下建包、不要手写 profile 的 package.json / cordis.patch.yml」针对的是 **Cordis bundle**。dsh-go 原生插件不是 Cordis bundle：它就是放在 `$DSH_HOME/dsh-go/plugins/` 下的 npm 包，用 `dsh plugin --profile web add` 装。两条规则各管各的，不冲突，也不能互换目录和安装方式。
- 同一个「加个按钮」两边都能做时：在 dsh-go 里先做原生版本；用户还要网页版，再让官方技能另做一份。

## 先判断用哪个

| 用户要的 | 做法 |
|---|---|
| 固定文字的按钮、顶栏按钮、隐藏元素、主题 | 不写插件，用 dsh-go-ui 技能改 ui.json |
| 按钮要读剪贴板 / 输入框 / 某条回复，或要算点什么 | 本技能：`composer.actions` / `message.actions` + `on(id)` |
| 一直看得到的一行数字 | 本技能：`composer.strip` + `strip(id)` |
| 一整页信息 | 本技能：`panels` + `panel(id)` |
| 不常用但要顺手的工具 | 本技能：`composer.tools`（加号面板，要较新的 App） |
| 对整段对话做事：导出、归档 | 本技能：`session.actions`（右侧栏「信息」，要较新的 App） |
| 每轮一眼看到的数字 | 本技能：`turn.note` + `turnNote(id)`（回合脚注，要较新的 App） |
| 某个工具的结果画成卡片 | 本技能：工具 `output.presentationMeta` 返回 `{ "dsh-go/view": 视图 }`，不需要清单 |
| 把回复读出来、开口就停、跟读字幕 | 本技能：`capabilities` + `media` / `micro` / `overlays`（见下文「声音与字幕」） |

胶囊、菜单、状态条、面板只在装了 dsh-go 桥接的主机上出现：手机本机引擎有（`/etc/dsh-app/runtime.json` 存在就是）；其他主机只有工具卡。

## 步骤

1. **建目录**（放在 `$DSH_HOME/dsh-go/plugins/` 下，引擎重置时会保留；`DSH_HOME` 默认 `~/.dsh`）：
   ```sh
   P="${DSH_HOME:-$HOME/.dsh}/dsh-go/plugins/local-quote"
   mkdir -p "$(dirname "$P")" && cp -r "${DSH_HOME:-$HOME/.dsh}/skills/dsh-go-plugin/template" "$P"
   ```
2. **改名**：`package.json` 的 `name`、`cordis.patch.yml` 的 `name`、`lib/index.js` 的 `name` 三处一致，用 `local-` 开头，小写字母、数字和 `-`。
3. **写清单**（`package.json` → `dshGo`，见下表），只声明用得到的；`wants` 只要真读的内容。
4. **写处理**（`lib/index.js`）：一律写在 `ctx.inject(['dshGo'], (ctx) => { … })` 里。
5. **自查**，改到没有「错误」为止：
   ```sh
   node "${DSH_HOME:-$HOME/.dsh}/skills/dsh-go-plugin/kit/bin/check.mjs" "$P" --load
   ```
   `--load` 会在隔离环境里加载你的代码：查处理函数在不在、视图函数画出来的视图 App 能不能画。
   `--json` 给机器读；`--lang zh` 指定语言；`--budget toolCard|panel|strip` 按工具卡、面板或状态条检查视图预算；`--app <版本>` 按目标 App 版本判断 `minApp`（不写时按 999.0.0 判断，`minApp` 不会被拦截，检查目标版本时必须写出）；面板位置等较新字段不按版本检查。
6. **安装**（装上即生效，不用重启）：
   ```sh
   dsh plugin --profile web add "$P"
   ```
   手机本机引擎用的 profile 是 `web`。装的是指向这个目录的链接：目录不能删。
7. **改代码之后**：清单（`package.json`）改了会自动重读；`lib/` 里的代码改了，要用户在 App 的「引擎」页重启引擎才生效。
8. **告诉用户**改了什么、在哪看：胶囊在输入框上方；菜单项在长按助手消息的菜单里，按插件分组；状态条在输入框上方；面板在对话详情页「插件」页签或「全部功能」。第一次点按要读剪贴板 / 输入框 / 消息的按钮时，App 会问用户一次。

卸载：`dsh plugin --profile web remove local-quote`，再删目录。

## 清单（`package.json` → `dshGo`）

```json
{
  "v": 1,
  "title": { "zh": "引用", "en": "Quote" },
  "icon": "bolt",
  "wants": ["clipboard"],
  "contributes": {
    "composer.actions": [
      { "id": "summarize", "label": "总结", "effect": { "type": "insert", "text": "总结上面的对话，列三条要点。" } },
      { "id": "paste-quote", "label": { "zh": "引用剪贴板", "en": "Quote clip" }, "icon": "document" }
    ],
    "message.actions": [{ "id": "save", "label": "存进笔记", "icon": "note" }],
    "composer.strip":   [{ "id": "today", "icon": "chart", "panel": "stats" }],
    "panels":           [{ "id": "stats", "title": "统计", "icon": "chart", "placement": ["session.tab", "features"] }]
  }
}
```

| 插槽 | 每插件 | 文字上限 | 字段 | 点按 |
|---|---|---|---|---|
| `composer.actions` | 2 | `label` 10 字 | `id` `label` `icon?` `effect?` | 有 `effect`：App 直接执行，不写代码；否则调 `on(id)` |
| `message.actions` | 2 | `label` 12 字 | 同上 | 同上 |
| `composer.strip` | 1 | `text` 24 字 | `id` `icon?` `text?` `panel?` | `panel` → 打开该面板；否则 `on(id)` |
| `panels` | 4 | `title` 16 字 | `id` `title` `icon?` `placement?` `presentation?` `view?` | 视图里的按钮 / 行 / 选项 → `actions` |
| `composer.tools` | 2 | `label` 8 字 | `id` `label` `icon?` `effect?` `panel?` `requires?` | `panel` / `effect` App 直接执行（两者只写一个）；否则 `on(id)` |
| `session.actions` | 2 | `label` 12 字 | `id` `label` `icon?` `effect?` `requires?` | 同胶囊 |
| `turn.note` | 1 | 每段 16 字 | `id` | 不能点；`turnNote(id, (scope, emit) => …)` 里 `emit({ 回合序号: { text, tone? } })` |

App 另有全局上限：输入框上方胶囊合计 8 个、加号面板工具合计 8 个、回合尾注同时 2 个、note feed 8 条；超过的不显示。面板按钮 pending 状态的 label 不超过 16 字。

- `title`、`label`、`text` 写字符串或 `{ "zh": "…", "en": "…" }`；中英文都不能超上限。插件名 `title` ≤ 24 字。
- `id`：字母数字开头，字母数字和 `_ . -`，≤ 40 字；**整个插件内不能重复**（跨插槽也算）。
- `wants`：`clipboard`、`draft`（输入框文字）只给胶囊和 `composer.tools`；`message`（被长按的回复正文）只给菜单项。
- `placement`：`session.tab`（对话详情页，scope 带 sessionId，缺省）、`features`（全部功能）、`chat.panel`（聊天页输入框上方「插件」胶囊打开的弹层，scope 带 sessionId）、`plugin`（插件自己入口里的面板，较新 App）。可写一个字符串或数组；老 App 不认识的值会忽略，只放在 `plugin` 的面板退回 `session.tab`。
- `presentation`：`page`（推整页，缺省）或 `sheet`（弹层）；较新 App 才认，老 App 忽略，仍按页打开。
- 视图函数按 `caps.surfaces` 判断 App 能不能画（`hasSurface(caps, 'chat.panel')` 之类），判断不到时退回 `session.tab`。
- 静态 `effect` 只能用 `insert` `command` `open` `link` `toast` `copy`。
- `icon`：bolt star sparkle heart flag bookmark pin bell clock alarm calendar todo note document folder search code terminal globe chart lightbulb book puzzle robot chat mail translate image camera mic link summary wrench bug travel school home play refresh archive team wallet palette coin money speaker read copy quote share edit write save paste add remove delete clear fork regenerate reply select-text qr download downloads external info warning check done success error question pending running tip list table panel sidebar menu more expand collapse file folder-open workspace storage pdf zip slides article text diff gallery audio music video video-file play-video pause stop replay generate-image generate-video diagram plugin bot agent skill model tool workflow goal plan job automation command trajectory web web-search browser history time today timezone schedule repeat reminder user account group chats mention invite announcement reaction poll notification send community forum feedback wechat qq telegram discord phone computer cloud server power restart retry theme color text-size pet featured badge favorite settings

不认识的图标会画成默认图标，不报错。不要用锁、钥匙、盾牌这类图标表达安全/私密：App 不保证这些语义，容易误导。
- `minApp`：可选，最低 App 版本（如 `"1.0.16"`）。App 版本低于它时原生部分不显示，并提示用户更新 App。
- `capabilities`：可选能力清单。`files` 表示要用系统选择器选文件/图片（见下文「选择文件与图片」）；旧 App、旧桥不协商时普通面板仍能打开。

## 处理（`ctx.dshGo`）

```js
export const name = 'local-quote'
export function apply(ctx) {
  ctx.inject(['dshGo'], (ctx) => {
    // 胶囊 / 菜单项 / 状态条的点按：(scope, event) → 效果
    ctx.dshGo.on('paste-quote', (scope, event) => scope.clipboard ? { insert: `> ${scope.clipboard}` } : { toast: '剪贴板里没有文字' })

    // 状态条：推 { text ≤ 24, icon?, tone? }；返回取消函数
    ctx.dshGo.strip('today', (scope, emit, caps) => {
      const tick = () => emit({ text: caps.locale.startsWith('en') ? `Today ${count()}` : `今日 ${count()}` })
      tick()
      const timer = setInterval(tick, 60_000)
      return () => clearInterval(timer)
    })

    // 面板：视图（结构）+ 数据（推完整对象，桥接算差量）+ 视图里点按的处理
    ctx.dshGo.panel('stats', {
      view: (scope, caps) => ({ type: 'stack', children: [
        { type: 'metric', label: '今日', value: { $: 'data.today' } },
        { type: 'actions', items: [{ label: '清零', action: 'reset' }] },
      ] }),
      data: (scope, emit, caps) => { emit({ today: count() }); return () => {} },
      actions: { reset: (scope, event) => ({ toast: '已清零', patch: { today: 0 } }) },
    })
  })
}
```

| 参数 | 内容 |
|---|---|
| `scope` | `{ sessionId?, turnId?, messageId?, callId? }`；点按时另有声明过的 `clipboard` / `draft` / `message` |
| `event` | `{ surface, id, action?, value?, locale }`；面板点按：`action` 是视图里的动作 id，`value` 是 args（`options` → `{ value }`，`confirm` → `{ confirmed }`） |
| `caps` | 视图函数：`{ protocol, app, locale, surfaces, components }`；数据函数：`{ protocol, locale }` |

**返回的效果**（一次 ≤ 4 个，点按后 3 秒内返回才执行）：

| 写法 | 作用 |
|---|---|
| `{ insert: '…' }` | 放进输入框（≤ 2000 字），**绝不自动发送** |
| `{ toast: '…' }` | 一行提示（≤ 40 字） |
| `{ copy: '…' }` | 复制（≤ 8000 字） |
| `{ link: 'https://…' }` | 用户确认后浏览器打开，只收 https |
| `{ open: 'panel:stats' }` / `{ open: '页面 id' }` | 打开本插件面板或 App 页面 |
| `{ command: 'compact' }` | 在当前对话执行斜杠命令 |
| `{ refresh: true }` / `{ patch: {…} }` | 面板重取视图 / 合并数据 |
| 多个键写在一个对象里 | 按顺序都执行，例如 `{ copy: md, toast: '已复制' }` |

**慢活（调模型、联网）用延后效果**：先回 `pending`，App 显示等待；结果 ≤ 60 秒到，只能是 `insert` `copy` `toast` `patch`；每插件同时最多 2 个；`signal` 在取消 / 超时 / 断开时触发，收到就停。

```js
ctx.dshGo.on('translate', (scope) => ({
  pending: { label: '正在翻译', timeoutMs: 60_000 },
  result: async (signal) => ({ insert: await translate(scope.clipboard, signal) }),
}))
```

## 视图（面板、工具卡）

一棵 JSON 组件树。任何值都可以写绑定 `{ "$": "data.a.b" }`，从推来的数据里取，取不到显示「—」；工具卡没有数据，直接写值。

**先选视图版本**：根节点不写 `v` 或写 `v: 1` 时使用 v1 组件和原样式；需要新增控件、结构组件或有界样式时，在根节点写 `v: 2`。清单的 `dshGo.v` 仍为 `1`，与视图版本分开。

下表只列 v1 的基础组件。v2 的完整组件与字段见自带的 `kit/schema/view.schema.json`；App 仓库的 `docs/plugins/components.md`、`styles.md`、`inputs.md` 说明新增组件、样式和表单。不要因为组件不在下表就拒绝 v2。兼容旧 App 时按 `caps.components` / SDK 的 `adaptView` 降级，文字保留 `text` 等基础字段。

```json
{"v":2,"type":"stack","accent":"teal","children":[
  {"type":"text","text":"示例","style":{"size":"title","weight":"bold"}},
  {"type":"emptyState","title":"暂时没有内容"}
]}
```

| 组件 | 字段 |
|---|---|
| `stack` / `row` | `children`（row 窄屏自动折行）；根节点可带 `title` |
| `text` | `text`，`tone?: muted` |
| `metric` | `label` `value` `tone?: good\|warn\|bad\|info` `caption?` |
| `chart` | `kind: bar\|hbar\|line\|donut` `categories` `series: [{ name?, values }]` `unit?` `caption?` |
| `compare` | `items: [{ title, badge?, rows: [[名称, 值]] }]`（2–4 项） |
| `steps` | `items: [{ label, status: done\|current\|todo\|failed, detail? }]` |
| `callout` | `text` `tone?: info\|good\|warn\|bad` |
| `list` | `items: [{ title, subtitle?, trailing?, icon?, tone?, action? }]`（≤ 50） |
| `keyValue` | `items: [[名称, 值], …]` 或 `[{ label, value, tone? }]` 或 `{ 名称: 值 }`（≤ 24） |
| `progress` | `value` `max?`（缺省 100）`label?` `caption?` `tone?` |
| `table` | `columns: [文字 \| { label, align? }]`（≤ 8）`rows: [[…]]`（≤ 50） |
| `actions` | `items: [{ label, action, icon?, style?: primary\|plain }]`（≤ 4，至多一个 primary） |
| `options` | `id` `options: [{ label, value? }]` `multi?` `selected?` |
| `confirm` | `id` `confirmLabel?` `cancelLabel?` |
| `image` | `src`：`/dsh-go/v1/…` 同源路径或 ≤ 64 KiB 的 `data:image/…`；`alt?` `aspect?` |

`action` 写动作 id 字符串，或 `{ "id": "open", "args": { … } }`（args ≤ 1 KiB）。上限：面板 32 KiB / 120 个组件 / 8 层；工具卡 8 KiB / 40 个 / 6 层，第 0 期不能点。

工具卡：

```js
presentationMeta: (args, value) => {
  try {   // 抛错或返回 undefined / NaN 会让整次工具调用失败
    const text = JSON.stringify({ type: 'stack', title: `${value.city} · 今天`, children: [{ type: 'metric', label: '气温', value: `${value.temp}°` }] })
    return text.length < 8000 ? { 'dsh-go/view': JSON.parse(text) } : {}
  } catch { return {} }
},
```

## 选择文件与图片（NA v1.3，可选）

插件可以在用户点按后打开系统选择器；选中的内容送到当前主机，插件通过一次性句柄读字节，不会拿到手机文件路径。

- 清单加 `"capabilities": ["files"]`；触发选择的按钮加 `"requires": ["files"]`；面板里的选择按钮只在 `caps.features?.includes('files')` 时显示，否则显示普通说明文字。
- 效果：`effects.pickFile('selected', { maxFiles: 2 })` 或 `effects.pickImage(...)`；不用 SDK 时返回 `{ type: 'pickFile', action: 'selected', maxFiles: 2 }`。`maxFiles` 默认 1，只收 1–4。
- 回调在同一个面板的 `actions[action]`，或回落到 `ctx.dshGo.on(贡献 id, handler)`；`event.value` 是 `{ status: 'selected', files: [{ handle, name, bytes, mediaType, access }] }`、`cancelled` 或 `error`。
- 在回调内用 `ctx.dshGo.readPickedFile(handle)` 取字节（独立副本）。句柄只在这一个待处理回调内有效：回调结束、超时、卸载或断线后就读不到；不要保存句柄，也不要拿 `name` 拼路径。
- 旧 App、旧桥、DSH Remote 中转不协商此能力，面板照常打开。`dshGo.v` 仍是 `1`，不要填 `1.3`。
- 发起选择的调用必须来自用户手势（`userGesture`），不能在后台自行触发。

## 声音与字幕（v1.2，可选）

清单加 `"capabilities": ["audio", "voice", "micro", "overlay"]`（用哪几样写哪几样），`contributes` 加 `media: [{ id }]`、`micro: [{ id }]`、`overlays: [{ id, channel }]`（各 ≤ 2，id 和其他贡献不重复）；要用声音的按钮加 `"requires": ["audio"]`。

```js
ctx.dshGo.on('read', (scope) => [   // 同一 instance：App 当作一个会话
  { type: 'audio', op: 'play', instance: 'reading', src: 'media:speech', key: 'k1' },
  { type: 'voice', op: 'start', instance: 'reading' },
  { type: 'overlay', op: 'show', instance: 'reading', id: 'subtitle' },
])
ctx.dshGo.media('speech', async (scope, { key, signal }) => ({ body: wavBuffer, contentType: 'audio/wav' }))   // 整段，≤ 16 MiB，30 秒内
ctx.dshGo.micro('caption', { data: (scope, emit) => { emit({ text: '读到这里', progress: 0.3 }); return () => {} } })   // 只能 { text ≤ 240 字, progress 0–1 }
ctx.dshGo.onCapability((scope, { event }) => {})   // audio.ended / voice.speechStart / …；返回值不执行
```

慢的事（TTS）放在 `media` 里，不放在 `on` 里。App 负责：开口时先停播再通知、问用户能不能听、只在前台、声音结束后自动停听关字幕。没有 TTS 时可以像 `examples/plugins/dsh-go-example-readaloud` 那样合成占位音。

## 规矩

- v1 保留原样式；v2 可用文档列出的颜色、语义字号、字重、spans 和容器样式。不要写任意 CSS、字体文件、尺寸、透明度、渐变或动画参数；实际几何、可读色和内容边界仍由 App 决定。
- 文案短、全角标点；报错像人话（「剪贴板里没有文字」），不写英文异常。
- 不在视图、清单、代码里放密钥和令牌；读到的剪贴板 / 消息只用于这一次点按。
- 不在没有点按时做有副作用的事；`insert` 永远不发送。
- 按所选视图版本的 schema 和组件目录写字段，用自带检查器验证；不要编造未支持的字段。完整说明在 App 仓库的 `docs/plugins/`。
