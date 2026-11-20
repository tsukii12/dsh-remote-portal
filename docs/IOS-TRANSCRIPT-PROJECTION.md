# Native Chat projection / 原生对话投影

Reference: installed `@deepseek-ai/dsh-web-frontend` and its
`@deepseek-ai/dsh-client-ui-chat` dependency, version `0.2.2-rc.5`.
The installed packages are read-only. Android and the portal transport are unchanged.

参考：已安装的 dsh 网页前端及其 Chat 包；不修改安装包、Android 或传输层。

## Rules / 规则

Paths below are relative to `dsh-client-ui-chat/src/client/`, except `surface.ts`
which is in `dsh-session/src/`.

| Record / 记录 | Web rule / 网页规则 | Native / 原生 |
| --- | --- | --- |
| Human `user/message`, append | `conversation-nodes/message.ts`: user bubble; inbox claims distinguish steering | User bubble, steering label; durable ID / RPC ID reconciliation |
| Non-human `user/message`, append | Context disclosure, not human text; waking inbox claims are independent trigger disclosures | Collapsed context / trigger disclosure; never an editable queued prompt |
| `developer/message`, append | Context; tool additions/removals have structured presentation | Context disclosure and structured tool-change entries |
| Context forms | `chat/ContextBody.tsx`: instructions, catalog, snapshot, notice, relay, recall; malformed / foreign source falls back to opaque context | Same form validation, content order, fields and bounded bodies; notice summary in header |
| `system/message` | `request-prompt.ts`, `contract/chat-visibility.ts`: system-prompt node excluded from Chat | Hidden; not a generic notice |
| `assistant/message`, append | `assistant.ts`: nonblank visible blocks; every reply remains outside process folding | Empty blocks removed; every reply retained; reasoning/tool details separately foldable |
| Stopped turn process | Stopped turns retain collapsed command/process groups; opening one reveals reasoning, arguments and aborted-tool results | Aborted turns can collapse details just like completed turns; partial replies stay outside the fold and tool errors remain inspectable |
| `assistant/attempt` | Trajectory/turn bookkeeping, not an assistant Chat message | Hidden, including recorded stream fragments |
| Live assistant stream | Nonempty text/reasoning/tool deltas; durable settlement replaces stream | Existing stream reconstruction; empty block starts and whitespace-only thinking hidden |
| Interrupted assistant message | Meaningful visible content remains; interrupted turn has stopped state | Preserved with explicit interrupted/stopped presentation, not an invented reply |
| `tool/call`, `tool/result` | `tool.ts`: correlate call ID; no duplicate embedded call; result belongs to call | Same correlation; existing native argument/result/image/unknown-block renderers |
| Orphan append `tool/result` | Unclaimed append-surface event can reach `fallback.ts` | Compact unknown-message disclosure preserves payload |
| `command/run` + `command/done` | `command.ts`: one correlated command card; a lone done can build a partial-history card | One card, result/error summary; RPC caption retires by command ID |
| Permission command | `chat-visibility.ts`: always hidden | Hidden, including permission RPC caption |
| Team `on` / `off` command | Hidden unless the outcome is an error | Same |
| Other slash commands | Visible command card, not raw lifecycle rows | Visible command card |
| `/goal` input | `dsh-client-ui-goal/goal-command-input.ts`: human command echo plus generic result, within process folding | Same command-input bubble and separate result card |
| Compaction start/summary/end | `compaction.ts`: no automatic marker without a landed checkpoint | Lifecycle metadata hidden until checkpoint |
| Compact checkpoint replacement | Dedicated compaction marker; manual checkpoint joins command | One marker with summary and counts; never a user bubble |
| Other surface replacements | `surface.ts`: model history, not append-origin transcript | Hidden; do not erase original human/assistant Chat history |
| Completed / ordinary aborted / blocked `turn/end` | No raw terminal row | Outcome metadata only; completed/stopped turn presentation |
| Error / interrupted / max-token end | `turn-error.ts`, `turn-max-tokens.ts`: dedicated notice; AUTH detail suppressed | Dedicated localized notice; no raw AUTH payload |
| `llm/retry`, `llm/retry-started` | `retry.ts`: correlate producer retry ID | One correlated retry notice; no raw lifecycle rows |
| Permission/sandbox/approval policy, approval asked/decided, model selection, turn/step starts/ends, request headers/context, session titles, job/workspace/inbox/goal bookkeeping | Only dedicated business projections contribute; not a blanket generic fallback | Hidden as standalone records; inbox still supplies steering/trigger identity |
| Unknown durable event, even with `surfaceOp: append` | `fallback.ts` also requires `isSurfaceEvent`; `surface.ts` recognizes only system/developer/user/assistant messages and tool results | Hidden unless a recognized surface or dedicated rule owns it |
| Unknown assistant/context/result content block | Opaque content remains inspectable | Compact generic content disclosure, not silent dropping |
| Pending queued human input | Queue, not an additional optimistic bubble | Editable queue; stale committed IDs/RPC IDs excluded |
| Pending steering | One pending transcript echo, not the ordinary queue | One steering echo, reconciled against optimistic and committed identities |
| Pending host context | Inbox state does not itself contribute Chat rows | Wait for durable context record |

## Captures and tests / 捕获与测试

`ios/DSHRemoteTests/Fixtures/r7-local-projection.json` contains 70 events captured
from an owned loopback host using `session/events`, plus a pending queue/steering
snapshot from `session/state`. It includes permission changes, an approved `bash`
`pwd` call and its result, reasoning/replies, queue/steer admission, slash-command
success/error and a successful manual compaction checkpoint. System prompts and
request payloads were elided, and local home paths were replaced. No remote-host
data or credentials are included.

该脱敏 fixture 来自自有本地主机，包含权限变更、已批准的工具调用及结果、思考、排队／引导、
命令成功／失败与实际压缩检查点；不含远程主机数据或凭据。

The same fixture includes the three r6 `DRP测试 r6 slow queue` records: all three
have different durable message IDs **and different RPC IDs**. They are real
separate submissions, so text-based deduplication would incorrectly erase user
history. Tests require preserving them while removing actual identity duplicates.
The captured reasoning-only replies have `interrupted: true`; empty attempts are
tested separately rather than misreporting these cancellations as lost replies.

r6 的三个同文提示具有不同消息 ID 和 RPC ID，不能按文本删除；实际重复按标识去重。
所捕获的仅思考消息明确标记为中断，不应伪造正文或将其误报为正文丢失。

`Round4Tests` also supplies protocol edge cases that the local capture did not
naturally produce: malformed/foreign context forms, future blocks, orphan results,
AUTH errors, max-token endings, Team toggles and incomplete compaction evidence.
`NativeStateTests` pins append-origin history through surface replacements.

未在本次真实捕获中自然出现的协议边界由合成测试覆盖；不将这些测试冒充实测捕获。
