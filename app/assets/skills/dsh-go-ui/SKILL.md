---
# dsh-go:managed — the dsh-go app keeps this skill up to date; delete this line to keep your own edits.
name: dsh-go-ui
description: dsh-go 手机 App 原生界面的配置（$DSH_HOME/dsh-go/ui.json）：顶栏按钮、输入框上方的快捷胶囊、新对话建议卡、抽屉分组与排序、密度、隐藏元素、主题和强调色、平板快捷键、插件座位。只改 **dsh-go 手机原生界面**；用户要改 Harness 网页版 / 桌面端、做 Cordis 插件或网页插件时，用官方技能，不要用本技能。用户要改 App 本身的样子时先加载它，比如「把顶栏的 XX 换成 YY」「输入框上面加个总结按钮」「新对话页放几个常用问题」「抽屉按创建时间排」「把回合脚注藏掉」「换成暗色 / 黛青」「加个 ctrl+k 打开搜索」。Change how the dsh-go phone app's native screens look and behave by editing ui.json; the Harness Web UI / Cordis plugins are the official skills' business.
whenToUse: The user asks to change the dsh-go app (手机 App / 原生界面) itself. Not for the Harness Web UI, Cordis plugins or DSH settings; anything that needs logic or data is a plugin (dsh-go-plugin).
---

# dsh-go 界面配置（ui.json）

dsh-go App 会读 `$DSH_HOME/dsh-go/ui.json`（`DSH_HOME` 默认 `~/.dsh`），按里面的声明改自己的原生界面。改完保存，已接线的键一两秒内自动生效，不用重启。

**当前只有部分键真正接线，见下面的「生效状态」表。**没接线的键 App 仍会解析和校验，但界面不会变——不要向用户保证写了就生效。

文件只能声明，不能执行：没有脚本、没有网络请求、不能装东西。按钮能做的事只有四种动作（见下），而且都要用户亲手点才会发生。

## 和官方技能的分工

- **本技能**：改 dsh-go 手机 App 的原生界面（ui.json）。
- **dsh-go-plugin**：给手机 App 加胶囊、菜单、状态条、原生面板、工具卡；要逻辑或数据时用它，不用 ui.json。
- **官方 `cordis-plugin-development` 等**：Harness Web UI / 桌面端的插件、装饰、槽位、页面和 MCP；目录在工作区，安装走 `plugin_manager → install_bundle`。
- 用户没点名界面载体时，手机上默认是 dsh-go 原生界面；先确定载体再选技能，不看加载顺序。两套配置（ui.json / Cordis bundle）不要混写，也不要拿官方网页插件的做法套到 App 上。

## 怎么改

1. 先读现有文件：`cat "$DSH_HOME/dsh-go/ui.json"`（没有就新建，目录不存在就 `mkdir -p`）。
2. 只改用户要求的部分，其他键原样保留。用户之前的配置不要删。
3. 写回：严格 JSON，UTF-8，不要注释，不要尾逗号，不超过 64 KiB。最好先写临时文件再 `mv` 过去。
4. 自查：`node "$DSH_HOME/skills/dsh-go-ui/scripts/check.mjs"`。输出是 App 解析器的判断，**不是界面生效数**；只有「生效状态」表里已接线的键会改变界面：
   - `错误 /composer/quickActions/2/action/url：只支持 https 链接`：这一项不生效，其余照常；
   - `忽略`：App 不认识或超出上限的部分；
   - `提示`：已自动修正（比如文字太长被截断），仍然生效；
   - `ui.json 没有生效：…`：整份没读进去（语法错误、版本不对），App 继续用上一次有效的配置。
   有错就改到没有 `错误` 为止。加 `--json` 得到机器可读结果。checker 报的「已应用 N 项」只是解析器接收的声明的数量，不要转述成「已生效」。
5. 本机（手机上的引擎）还会有 `$DSH_HOME/dsh-go/ui.status.json`，是 App 实际读到的结果，可以对照。
6. 告诉用户改了什么。用户想撤销某一项，就把那个键删掉；已接线的项（`theme.mode`、`plugins.seats`）还能在 App 设置里点「来自 ui.json」→「恢复默认」，这只让 App 忽略那一项，不会改文件。

完整字段定义在同目录的 `schema.json`，示例在 `examples/`。

## 生效状态

| 键 | 状态 |
|---|---|
| `theme.mode` | 已接线：明暗切换生效 |
| `composer.quickActions` | 已接线：输入框上方胶囊生效 |
| `hide.pluginCapsule` | 已接线：隐藏 App 的插件聚合入口 |
| `plugins.seats` | 已接线：插件座位生效 |
| `header.actions` | 只校验，尚未接线 |
| `emptyState.suggestions` | 只校验，尚未接线 |
| `drawer.groups` / `drawer.sort` / `drawer.filter` | 只校验，尚未接线 |
| `density` | 只校验，尚未接线 |
| `theme.accent` / `theme.accentPreset` | 只校验，尚未接线 |
| `pet` | 只校验，尚未接线 |
| `shortcuts` | 只校验，尚未接线 |
| `hide` 的其余项 | 只校验，尚未接线 |

未接线的键先如实告诉用户「这项目前还没有应用到界面」，不要编造已生效。

## 字段

```json
{
  "version": 1,
  "header": { "actions": ["schedule", "detail", "newChat",
    { "id": "daily", "icon": "bolt", "label": "日报", "action": { "type": "send", "text": "按模板写今天的日报" } }] },
  "composer": { "quickActions": [
    { "label": "总结", "action": { "type": "send", "text": "总结上面的对话，列三条要点" } },
    { "label": "压缩", "action": { "type": "command", "name": "compact" } } ] },
  "emptyState": { "suggestions": [
    { "title": "看看今天的待办", "subtitle": "读工作区里的 TODO.md", "action": { "type": "send", "text": "读一下 TODO.md，告诉我今天先做什么" } } ] },
  "drawer": { "groups": ["pinned", "folders", "today", "yesterday", "thisWeek", "earlier"], "sort": "activity", "filter": "all" },
  "density": "compact",
  "hide": ["turnFooter", "tokenCount"],
  "theme": { "mode": "system", "accentPreset": "daiqing" },
  "shortcuts": [ { "keys": "ctrl+k", "action": { "type": "open", "page": "search" } } ],
  "plugins": { "seats": { "conversation.input.dock": { "dsh-cost-meter": "hidden" } } }
}
```

| 键 | 写法 |
|---|---|
| `version` | 必填，`1` |
| `header.actions` | 聊天顶栏右侧按钮，按顺序显示。内置：`newChat`（新对话）、`detail`（对话详情）、`schedule`（定时任务时钟）、`agents`（子代理胶囊）、`model`（模型胶囊）。没列出的内置按钮会隐藏，`[]` 全部隐藏。自定义按钮最多 3 个：`id`（小写字母开头，字母数字和 -）、`icon`（见下）、`label`（≤ 8 字）、`action` |
| `composer.quickActions` | 输入框上方的胶囊，≤ 8 个；`label` ≤ 10 字 + `action`。生成回复时自动收起 |
| `emptyState.suggestions` | 新对话页的建议卡，≤ 6 张；`title` ≤ 20 字，`subtitle`（可选）≤ 40 字，`action` |
| `drawer.groups` | 对话列表分组的顺序和可见性：`pinned` 置顶、`folders` 文件夹、`today`、`yesterday`、`thisWeek`、`earlier`；没列出的分组隐藏 |
| `drawer.sort` | `activity`（最近活动）或 `created`（创建时间） |
| `drawer.filter` | 打开抽屉时的筛选：`all`、`running`、`pending`、`unread` |
| `density` | `compact` 或 `comfortable` |
| `hide` | 要藏起来的元素：`turnFooter`（回合脚注）、`tokenCount`（token 数）、`reasoningDetails`（思考过程）、`activityStrip`（生成中的活动条）、`whaleTail`（鲸尾动画）、`todoPill`（待办条）、`goalBar`（目标条）、`pluginCapsule`（聊天输入框上方由 App 绘制的「插件」入口） |
| `theme.mode` | `system`、`light`、`dark` |
| `theme.accentPreset` | `mist` 雾蓝、`daiqing` 黛青、`dusk` 暮紫、`turquoise` 松石、`amber` 琥珀、`graphite` 石墨 |
| `theme.accent` | 自定义强调色 `#RRGGBB`（App 会自动调到对比度达标）；和 `accentPreset` 二选一 |
| `pet` | `id`、`position`（`top-left` / `top-right` / `bottom-left` / `bottom-right`）、`quiet`（布尔）。当前只校验，不改变界面 |
| `shortcuts` | 平板外接键盘快捷键，≤ 20 条：`keys` 如 `ctrl+k`、`ctrl+shift+n`、`alt+1`、`f5`（必须带 ctrl 或 alt，F 键除外；不能用 meta/cmd/win；`ctrl+a/c/v/x/y/z`、`ctrl+shift+v/z`、`alt+f4` 被占用）+ `action` |
| `plugins.seats` | 插件在原生界面里怎么出现：`{ "<slot>": { "<npm 包名>": "native" \| "island" \| "web" \| "hidden" } }`（原生画 / 内嵌网页 / 在网页版打开 / 隐藏）。slot 名见 `schema.json` 的 `x-dsh-go.slots.known`；`unseatable` 里的是 App 自己的界面，不放插件 |

图标（`icon`）：bolt star sparkle heart flag bookmark pin bell clock alarm calendar todo note document folder search code terminal globe chart lightbulb book puzzle robot chat mail translate image camera mic link summary wrench bug travel school home play refresh archive team wallet palette

要隐藏聊天页的「插件」入口，把 `pluginCapsule` 加进现有 `hide` 数组，例如 `{"version":1,"hide":["pluginCapsule"]}`。它只隐藏 App 的聚合入口，不停用插件、不隐藏插件自己的快捷胶囊，也不改变「全部功能」或「对话详情」的入口。删除该项或在界面配置页恢复默认即可显示。`plugins.seats` 配置的是插件的槽位，不是这个 App 入口；不要用 `chat.panel` / `dsh-go.panel` 座位设置替代。

## 动作（action）

| `type` | 字段 | 用户点了之后 |
|---|---|---|
| `send` | `text`（≤ 2000 字） | 把文字放进输入框，用户自己点发送；绝不自动发送 |
| `open` | `page` | 打开 App 页面：`new-chat`、`settings`、`search`、`files`、`terminal`、`jobs`、`skills`、`schedules`、`models`、`plugins`、`cordis`、`engine`、`web`、`session-detail`、`workspaces`、`account`、`remote`、`phone`、`notifications`、`diagnostics` 等，全部见 `schema.json` 的 `$defs.page` |
| `command` | `name`（不带 `/`）、`args`（可选，单行） | 在当前对话里执行 `/name args` |
| `link` | `url`（只收 `https://`） | 弹确认后用浏览器打开 |

## 注意

- 每台主机各有一份 ui.json，App 连哪台主机就用哪台的。
- 一项写错只影响那一项；整份语法错误时 App 保留上一次有效的配置。
- 不要在文件里放密钥、令牌等敏感信息。
- 不要编造字段或取值；不在上表里的东西 App 不认识。
