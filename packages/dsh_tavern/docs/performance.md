# T23：性能改动与仍在调用方 isolate 的工作

本文对应 ADDENDUM-04 的 T23.1–T23.6。实现前五项，并说明后续测量边界；没有把整个引擎移入 Isolate。这里的成本判断来自当前代码和下列一手资料，不是手机耗时、帧率或峰值内存测量。若 App 在 UI isolate 创建 TavernEngine，表中“调用方”工作也在 UI isolate 执行。

## 一、流式正文检查点

生成增量仍立即发送给订阅者。数据库正文检查点改为每 500 毫秒检查一次 dirty；没有新增正文或允许保存的 reasoning 时不写。取消旧的每 16 个增量落盘条件。定时器实际触发受 isolate 调度影响，500ms 不是实时截止保证，也不是网络/UI 增量节流。

schema 4 新增 nullable `nodes.stream_text`、`stream_reasoning` 和 pending 部分索引。检查点只 SET 两个正文通道；不重写 usage、检视 JSON、变量、original 或聊天更新时间。`stream_text != null` 是完整影子正文存在的标志，空字符串仍是合法正文；pending reasoning 为 null 时不能回退成旧 reasoning。消息/历史/导出从同一存储投影读取影子正文，pending usage 为 null，旧 owned inspection 暂不对外显示。pathChanges 仍通知已提交的检查点。

普通完成、取消或有输出的失败在一个 FULL SQL 事务中提交最终正文、reasoning、节点 usage、变量状态、终态检视和 latest 指针，并清空影子列。节点 usage 沿用既有合同；本次调用是否报告用量以 `inspection.reportedUsage` 为准，续写未收到新用量时节点可能仍保留旧用量。writeback 正则仍仅在终态执行一次，故其清空正文或抛错的语义保留。仅 usage 也算有输出，但不单独触发正文检查点；被门控丢弃的 reasoning 不算输出。无输出失败仍恢复原路径；impersonate 不创建临时正文的周期 SQL 写入，只提交终态状态与快照。

FTS 继续索引普通 `nodes.text`，原触发器不改。这样每个检查点都保留真正的已索引旧值，最终 UPDATE 才删除旧词、加入最终词。仅跳过触发器却继续修改 text，会让终态的 OLD.text 不再对应实际索引，无法可靠删除旧词；这是 SQLite 外部内容 FTS 的一致性要求，见 [FTS5 外部内容表](https://www.sqlite.org/fts5.html#external_content_tables) 与 [delete 命令](https://www.sqlite.org/fts5.html#the_delete_command)。低层 search 暂时排除有 pending 影子正文的节点，避免旧索引的命中返回不匹配的新正文；节点在终态或重开恢复后重新参与搜索。新回复的空节点插入、输入/首条消息的准备写入不属于周期正文写入，仍按原规则入树。

重开库时，用一个 FULL 事务把尚存的影子正文推广到 text，清空旧 usage 和 owned inspection，并只移除指向这些 pending 节点的 latest 指针。其他分支检视、unknown JSON、节点身份和当前路径保留。恢复不是伪造 completed/failed 回执：没有足够证据的检视保持缺失。再开一次没有 pending 就不再推广。普通编辑推广一个未能终态提交的 pending 节点时，同样不会复活旧 usage/inspection。

数据库恢复失败会回滚整笔恢复；schema 迁移失败回滚整条升级链，旧 V1/V2/V3 SQL 未改。真实 v3 fixture 验证到 4 的升级，第二条 ALTER 冲突用于检查第一条 ALTER 也回滚。保留原来一个引擎实例拥有一个根目录的约束，不新增多实例同时打开活动流式库的协议。

## 二、NORMAL 与终态耐久性

流式写者有引用计数；只在事务之外切换 `synchronous`。正文检查点用 NORMAL，所有普通外层事务——包括另一聊天的编辑、设置、空回滚和终态——临时使用 FULL。事务结束后若仍有流式写者，再恢复 NORMAL；最后一个写者结束恢复 FULL。恢复较弱模式失败时保留 FULL，不把已成功的 COMMIT 误报为失败。

SQLite 官方说明 WAL+NORMAL 保持一致性，但掉电/系统崩溃可能丢失最近事务；应用进程崩溃与掉电不是同一保证。FULL 的终态事务提供更强的持久性，但只把设置改回 FULL 并不等于执行了一次提交或 fsync。见 [synchronous](https://www.sqlite.org/pragma.html#pragma_synchronous)。宿主 SQL 探针中的进程退出不是手机掉电实验；未收到的尾部或未写到检查点的尾部不能恢复。

全局变量仍保存到 settings.json。异步文件结果先确定，随后只提交一次已知终态的 SQL 检视；文件失败不能阻止无输出回合回滚。文件与 SQLite 不是跨介质原子事务；本文不改变已有全局文件失败合同。

## 三、500ms 没有消除全部渐进成本

设第 i 次检查点的正文长度为 L_i，K 次检查点传给正文写入接口的累计文本量为 `Σ L_i`。若文本以固定平均速度 v 增长、检查点间隔为 Δ，则 `L_i ≈ vΔi`，累计约为 `vΔK(K+1)/2`。最终长度 n 约为 vΔK 时，该量仍可随 n 二次增长。

这项修改减少频率，并移除周期检视序列化、usage/状态写入和重复 FTS 更新；不能据此声称整条长回复已经变成 O(n)，也不能把逻辑文本量当作实测磁盘写入字节。StringBuffer 汇总、UTF-8/SQLite 绑定、SQLite 行页处理、WAL 与观察者读取仍有成本。本轮按题目选全文检查点，没有引入增量正文日志或后台数据库线程。

## 四、历史与宏环境

`ChatStore.historyTo(chatId, leafId)` 返回任意叶子的全部 StoredNode，包含 inactive 分支和完整 extra/original，不使用 path 的默认 60 条分页上限。非空叶只执行聊天检查和共享祖先 CTE 两条顶层 SELECT；不是每个祖先一次 Dart→SQL 调用。兄弟计数的相关子查询仍在 SQL 内运行，不能把“两个顶层 SELECT”解释成恒定数据库工作量。

CTE 只对稳定 `(id,parent_id)` 使用 UNION；种子和递归都限定 chat_id。结果在 Dart 按父指针重建，避免依赖 SQL 输出顺序、时间或 depth。完整读取遇到环、断链或跨 chat 指针抛错；有限分页只检查请求边界以内。`path` 的 exclusive cursor、limit=0、负数拒绝和默认 60 条保持。UNION 去重与负 LIMIT 的语义见 [SQLite WITH](https://www.sqlite.org/lang_with.html#recursive_common_table_expressions)。其他既有树写入方法不是本轮新增的损坏环修复接口。

每个 `_MacroEnvironment` 懒建一个 MacroContext；本回合 history、local/global 变量和 outlets 保持活引用。历史投影按 StoredNode 对象身份复用 MacroMessage，append、首条替换、同 nodeId 续写替换与回滚均能刷新。仍有 O(H) 路径/缓存空间，读取相关历史宏也可能扫描 H 条；没有给整个历史常量时间承诺。

每次 expand 仍新建 Evaluation；字段 memo、original 一次性闭包、随机抽取、变量副作用及替换 hook 不跨调用缓存。本次 char override/card mode 是调用参数，包含嵌套字段展开，不修改共享 context。现代 null/0 hash 与 legacy falsy fallback 的既有区别保留。显示通道仍另建副本，不能修改活动生成变量或消耗生成随机源。

固定语法正则提为库级对象；legacy 动态编译对象以 pattern/caseSensitive/multiLine 为键，LRU 上限 1000。普通 WI 单词边界正则以归一化后的字面 needle 为键，LRU 上限 1000，仍先 escape；多词/非整词继续 contains。没有缓存匹配结果、宏展开结果、replacement closure 或激活结果。T21 用户正则仍走其已有 worker，额度、取消和错误分类不变。

## 五、角色摘要索引与详情缓存

`watchCharacters()` 返回摘要：id、名字、昵称、作者、tags、avatarPath、导入时间、已有能力计数与动态聊天数/最后时间。description、creatorNotes、greetings、regexDiagnostics 使用空默认值。详情请调用 `character(id)`；字段编辑器仍用 `characterFields(id)`。这是有意的列表合同调整，api.dart 注释和已有编辑集成断言同步说明；无需新增 Tavern 方法转发。

列表成员来自已提交卡目录；有效 `character-index/<id>.json` 只读小索引，不打开卡目录里的原件、正文、报告或资源。缺失/无效索引才用 library.json 与 card.json 重建；JSON 卡解码仍用原 isolate helper，不读原件/图片/嵌入字节。索引只存 hasPortrait，avatarPath 按当前根目录生成；没有重新采样图片，也不保证图片文件一定存在。

编辑提交源卡前先使旧索引失效。源卡已提交后的派生缓存写失败不误报源卡保存失败，下一次可从源恢复；删除后孤儿索引不能复活角色。源卡与 T22 报告的原发布/队列合同保留。有效索引不探测绕过库接口直接修改源 JSON 的行为，单实例拥有目录的原约束不变。

引擎摘要缓存不再保留全库卡与资源。完整记录的 Future 以 id 作最近访问 LRU，最多 8 项；失败和缺失结果可重试，编辑/导入/删除只改变对应项。正在执行的回合可以继续持有自己捕获的卡，因此这不是所有活对象总数或内存字节硬上限。详情字段/导出/重检沿各自库入口，不能笼统称所有卡操作均命中该缓存。

摘要聊天统计改为 `COUNT(*) / MAX(updated_at)` 聚合，不为角色列表读取每段对话末条全文。有效索引冷启动仍有目录枚举、小文件 I/O、JSON 解码与排序；大量缺索引旧卡首次重建仍需逐卡读取完整 JSON，并会产生 isolate 调度和派生文件写入。

## 六、仍在调用方 isolate 的工作及建议测量点

| 工作 | 当前工作量来源 | 可能集中变重的情形 | 建议记录 |
|---|---|---|---|
| 同步 SQLite | 查树、状态恢复、500ms 正文检查点、终态事务、FTS、迁移/恢复 | 长正文、长分支、许多同父兄弟、打开时有 pending | 各操作的中位数/p95/最大值、正文长度、路径条数、WAL 大小 |
| PromptAssembler 与 token 估算回调 | 预设/角色/历史复制、宏展开、预算裁剪、请求 JSON 构造 | 大上下文、大预设、多次重算预算 | 组装总时间、输入字符数、回调调用次数；不要当作提供方 token 账单 |
| 宏 Evaluation | 每次 parse/evaluate、eager/lazy 字段、历史扫描、字符串处理 | 重复大字段、很多宏、legacy eager 展开 | expand 次数与耗时、history 长度、字符量 |
| 普通 WI | 候选遍历、字面/整词匹配、宏关键词、递归轮次、分组与预算 | 多书、多关键词、深扫描/递归 | 候选数、扫描轮次、关键词文本量、evaluate 时间 |
| 同步 prompt/writeback 正则 | 既有 RegexEngine 匹配和替换、宏替换 | 多规则、长文本、昂贵模式 | 规则数、输入输出量和对应阶段耗时；本轮编译缓存不等于匹配期限保护 |
| T21 受控显示/WI 的调用方部分 | 复制上下文、完整历史读取、任务发送、模板/宏替换与结果组装 | 频繁 displayText、长捕获或替换 | 调用方准备/收尾与 worker 执行分别记时 |
| SSE/模型事件与内存正文 | JSON 解码、StringBuffer、事件分发和最终文本取得 | 高频小增量、大回复、多订阅处理 | 增量数/字节、事件处理和最终拼装耗时 |
| 库及设置 JSON、导入体检、JSONL | 文件 I/O 的等待是异步；解析、复制、指纹、静态扫描和编码仍有 CPU 工作 | 大卡/大书/大量报告、整段导入导出 | 文件总字节、解析/序列化/检测时间、峰值 RSS/GC |
| 列表通知 | 聚合聊天统计、摘要投影和排序，或 App 请求路径后重读正文 | 多聊天、多卡、频繁观察者重算 | 触发次数、结果规模、App 实际订阅范围 |

已经独立执行的工作包括卡导入的解码/ZIP 解压/头像转换、存储 JSON 卡解码、卡导出编码，以及 T21 的两个常驻正则 worker。异步文件读写本身不等于“后续 JSON CPU 工作已移到后台”。上述表格不包含 App 的 Markdown/HTML/WebView、图片解码与实际绘制；本补丁没有修改或测量它们。

SQLite 自动 WAL checkpoint 默认阈值为 1000 页，但可受编译/运行设置改变；默认由触发阈值的 COMMIT 所在线程执行，所以 NORMAL 也不能消除偶发同步工作。见 [WAL checkpoint 与性能](https://www.sqlite.org/wal.html#performance_considerations)。本轮没有关闭自动 checkpoint，也没有把它移入另一线程。

后续应在目标 Android 设备、同一真实资料集上测冷/热角色列表、长历史普通回合、长流式回复、多聊天并行、取消与恢复。记录设备/构建、输入规模、CPU/内存/磁盘和 UI frame 数据，再决定数据库 owner 或整引擎迁移。没有当前测量结果时，不给加速倍数，也不把“100 项测试通过”的未来结果解释成帧率达标。

## 七、验证口径与模拟清单

新增测试静态登记 100 项：13 存储/迁移、14 流式 facade、11 历史/统计、14 宏缓存、5 WI 缓存、10 双方言宏环境、21 角色库、12 角色 facade。登记数不代表已运行；formatter/analyzer/test、固定 20 组 ST 对拍结果以随精确补丁交付的 owner 回执为准。

流式 facade 用受控 periodic Timer 检查间隔和触发顺序，不用睡眠测速度；模型只供确定性增量/错误。真实 SQLite trigger 记录写者实际 synchronous、正文/extra 更新次数，并注入 checkpoint、终态和恢复失败；FTS 的 rank=1 integrity-check 同时核外部内容一致性，见 [FTS5 integrity-check](https://www.sqlite.org/fts5.html#the_integrity_check_command)。角色测试让不应读取的文件不可用，观察列表/详情边界；不存在真实模型、Android帧率、真实掉电或全引擎 isolate 的测试声明。

固定 ST 语义仍以 1.19.0 的 `7e8663cd9c184a550b37238218bdd32c6efc68e9` 为基准：[macros.js](https://github.com/SillyTavern/SillyTavern/blob/7e8663cd9c184a550b37238218bdd32c6efc68e9/public/scripts/macros.js)、[MacroEngine.js](https://github.com/SillyTavern/SillyTavern/blob/7e8663cd9c184a550b37238218bdd32c6efc68e9/public/scripts/macros/engine/MacroEngine.js)、[world-info.js](https://github.com/SillyTavern/SillyTavern/blob/7e8663cd9c184a550b37238218bdd32c6efc68e9/public/scripts/world-info.js) 和 [script.js](https://github.com/SillyTavern/SillyTavern/blob/7e8663cd9c184a550b37238218bdd32c6efc68e9/public/script.js)。未读取 JS-Slash-Runner 源码。

## 八、T24 加入后的成本补充

T24 没有搬迁整个 engine。重接快照需要取得当前完整正文/思维，成本随已收到文本增长；事件分发随活跃观察者数增长，暂停订阅可能积压事件。零观察者时生成仍继续，不应从“页面离开”推导出网络调用或存储工作已经停止。

消息 reportedUsage 改为小列投影，省去逐条重建完整检视的 JSON/对象成本；现有 SELECT 仍包含节点其他字段，因此没有声称消除 extra 的数据库读取。schema5 首次迁移会检查全部旧节点的 owned inspection 并回填小列，成本随旧数据量增长。

中文字面搜索采用带前导通配符的 LIKE，按指定 chat 扫描 text/speaker，不借此声称 FTS 或倒排索引速度。软删标记整个物理子树；撤销批量解除标记；下次开库的真删除和 FTS/state 清理仍在调用方同步事务里。长子树和大量待清理行应纳入打开/删除耗时测量。

备份的 staging 文件复制使用异步 I/O；SQLite 3.9.1 的 backup stream 在调用方执行 native backup_step，每步最多1024页，未完成步之间由该依赖等待250ms。[固定源码](https://github.com/simolus3/sqlite3.dart/blob/sqlite3-3.9.1/sqlite3/lib/src/ffi/implementation.dart) 支持这一调用顺序，但不证明单步适合所有设备帧预算。只有 detached 快照的哈希/压缩、恢复解包/长度及哈希检查在辅助 isolate；staging 数据库迁移、完整性检查和领域 loader 仍有调用方成本。

备份至少同时需要源库、独立 staging 和写入中的 ZIP 空间；恢复暂时保留 incoming/previous。payload 使用文件流，manifest/路径表仍占内存，第三方解压器也有自己的工作区，不能宣称全流程常量内存。上述均为源码成本分析，没有新增手机耗时、帧率或峰值内存实测结果。
