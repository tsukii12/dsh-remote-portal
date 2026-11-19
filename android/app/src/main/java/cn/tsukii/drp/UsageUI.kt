package cn.tsukii.drp

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun UsageSheet(chat: ChatStore, onDismiss: () -> Unit) {
    val state by chat.state.collectAsState()
    LaunchedEffect(chat) {
        try { chat.loadUsageAccount() }
        catch (e: CancellationException) { throw e }
        catch (_: APIError.SessionExpired) { }
    }
    val tokens = Usage.session(state.projections)
    val stats = state.projections["sessionStats"]
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp).padding(bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(L("Session usage", "会话用量"), style = MaterialTheme.typography.headlineSmall)
            Text(L("Provider-reported tokens, not a bill. Missing data is unknown, not zero.", "令牌数由模型提供方报告，不代表账单。缺失数据为未知，而不是零。"), style = MaterialTheme.typography.bodySmall)
            UsageRow(L("Total tokens", "令牌总数"), Usage.number(tokens?.total))
            UsageRow(L("Uncached input", "未缓存输入"), Usage.number(tokens?.input))
            UsageRow(L("Cache read", "缓存读取"), Usage.number(tokens?.cacheRead))
            UsageRow(L("Cache write", "缓存写入"), Usage.number(tokens?.cacheWrite))
            UsageRow(L("Output", "输出"), Usage.number(tokens?.output))
            val billedInput = tokens?.let { it.total - it.output }
            val cacheRead = tokens?.cacheRead
            UsageRow(L("Cache hit", "缓存命中率"), Usage.percent(if (billedInput != null && billedInput > 0 && cacheRead != null) cacheRead.toDouble() / billedInput * 100 else null))
            HorizontalDivider()
            UsageRow(L("Context occupancy", "上下文占用"), Usage.percent(Usage.contextPercent(state.projections)))
            UsageRow(L("Context used / capacity (approx.)", "上下文已用／容量（估算）"), Usage.contextCounts(state.projections))
            val breakdown = state.projections["contextBreakdown"]
            UsageRow(L("System / tools / messages (estimated)", "系统／工具／消息（估算）"), listOf("systemTokens", "toolsTokens", "messageTokens").joinToString(" / ") { Usage.number(breakdown[it].long?.takeIf { n -> n >= 0 }) })
            HorizontalDivider()
            UsageRow(L("Turns / steps", "轮次／步骤"), Usage.number(stats["turns"].long) + " / " + Usage.number(stats["steps"].long))
            UsageRow(L("Model", "模型"), state.modelName)
            UsageRow(L("LLM / tool time (ms)", "模型／工具耗时（毫秒）"), Usage.number(stats["llmMs"].long) + " / " + Usage.number(stats["toolMs"].long))
            val ttftSteps = stats["ttftSteps"].long?.takeIf { it > 0 }
            UsageRow(L("Mean first token (ms)", "平均首令牌时间（毫秒）"), Usage.number(ttftSteps?.let { stats["ttftMs"].long?.div(it) }))
            val decodeMs = stats["decodeMs"].long?.takeIf { it > 0 }
            val speed = decodeMs?.let { ms -> stats["decodeTokens"].long?.takeIf { it > 0 }?.let { it.toDouble() * 1000 / ms } }
            UsageRow(L("Decode tokens / second", "生成令牌／秒"), speed?.let { java.text.NumberFormat.getNumberInstance().apply { maximumFractionDigits = 1 }.format(it) } ?: L("Unknown", "未知"))
            if (state.completedTurns.isNotEmpty()) {
                HorizontalDivider()
                Text(L("Completed turns", "已完成轮次"), style = MaterialTheme.typography.titleMedium)
                state.completedTurns.sorted().forEach { turn ->
                    val used = state.turnUsage[turn]
                    UsageRow(L("Turn $turn", "第 $turn 轮"), Usage.line(used))
                    TurnUsageView(used)
                    used?.routes?.let { Text(it.joinToString(", "), style = MaterialTheme.typography.bodySmall) }
                }
            }
            val balances = state.accountBalance["value"].array + state.accountBalance["bonusWallets"].array
            if (balances.isNotEmpty()) {
                HorizontalDivider()
                Text(L("Account balance", "账户余额"), style = MaterialTheme.typography.titleMedium)
                balances.forEach { balance -> UsageRow(balance["currency"].text, balance["balance"].text) }
            }
            TextButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth()) { Text(L("Done", "完成")) }
        }
    }
}

@Composable
fun TurnUsageView(tokens: TokenUsage?) {
    ExpandableBlock(Usage.line(tokens)) {
        UsageRow(L("Uncached input", "未缓存输入"), Usage.number(tokens?.input))
        UsageRow(L("Cache read", "缓存读取"), Usage.number(tokens?.cacheRead))
        UsageRow(L("Cache write", "缓存写入"), Usage.number(tokens?.cacheWrite))
        UsageRow(L("Output", "输出"), Usage.number(tokens?.output))
        tokens?.reasoning?.let { reasoning -> ExpandableBlock(L("Reasoning tokens", "推理令牌")) {
            Text(Usage.number(reasoning))
            Text(L("Included in output, not additional tokens.", "已包含在输出中，并非额外令牌。"), style = MaterialTheme.typography.bodySmall)
        } }
    }
}

@Composable
private fun UsageRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
        Text(value, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
    }
}
