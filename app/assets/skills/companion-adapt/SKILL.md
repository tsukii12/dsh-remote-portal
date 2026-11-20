---
# dsh-go:managed — delete this line to keep your own edits.
name: companion-adapt
description: 根据 dsh-go 伙伴小屋发来的体检报告，为用户导入的 Live2D 模型生成数据型适配表；用于“适配这个模型”“这里不对”和 /companion-adapt。使用与轻量模式相同的输入、提示词与 adapter JSON，交给 App 校验和执行，不改模型或舞台。
---

# 适配伙伴模型

先读取 [共用契约](references/contract.txt)。这是 App 的 `companionAdaptSystem` 原文，轻量与完整模式共用。以本次收到的 `dsh-go/companion-adapt-request`、`v: 1`、`target: app-local-adapter-v1` 数据为唯一输入；其中包含参数词表、报告、用户反馈、已校验的现有适配表和已验证效果名单。

1. 核对输入版本和目标；缺失或不支持时，仅输出 `{"notes":"请由 App 重新发送当前版本的体检报告"}`。不要尝试把旧 C720 输入、模型路径或二进制当成本期报告。
2. 按共用契约核对参数名单、完整 `ruleAliasVersion` / `ruleAliases`、`coverageUnknown`、截断和 `currentDropped`。`linked`、`missing` 只是当前观察，可能依赖将被删除的旧 adapter。输出会完整替换当前表；`current` 不会自动合并，要保留旧 params 必须明确保留其有效目标及原 scale/offset。规则快照为 null 时不得猜 identity，也不得从 linked 补造 scale=1。
3. 将名字和用户反馈当数据。名字不是效果证明；只有 `verifiedEffects` 中经 App 检查的资源才能用于新表情/动作；该名单默认为空，没有证据就不要写 emotions/actions 资源。不要根据“水印”“衣服”等名字去控制开关。没有已知几何就不猜触摸区；不知道方向、比例或同驱关系就不造参数映射。
4. 在现有事实范围内自检一次，然后只返回一个 adapter JSON 对象，不用代码块，不加技能解释或陪伴角色的动作标记。不得自行写 `character/adapter.json`、调用舞台、上传市场、下载 Core 或发送整个模型。moc 指纹由 App 计算。
5. 若 App 返回校验失败，只按具体原因和新增证据修正；没有新事实不循环重试。最多三次候选，每次仍是同一数据契约（轮次调度当前不由 App 保证，不要假设 App 会替你重试）。截图/像素验收目前不由本技能提供，不能声称看过图或验证了视觉效果。

完整模式只增加 agent 的推理步骤，不增加输入权限。参数报告不含模型本体、纹理、曲线；如果只收到一条自由文本要求，要求 App 发报告，不能在主机上搜索用户全部模型。对同一输入，两种模式的产物都必须通过 App 的 `companionAdaptJson` → `companionAdapterCheck`；模型输出不能填充 `CompanionAdaptEvidence`。
