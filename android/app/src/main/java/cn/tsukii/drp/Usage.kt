package cn.tsukii.drp

import kotlinx.serialization.json.JsonNull
import java.text.NumberFormat

data class TokenUsage(val input: Long, val output: Long, val total: Long, val cacheRead: Long? = null,
    val cacheWrite: Long? = null, val reasoning: Long? = null, val routes: List<String>? = null)

object Usage {
    private fun count(value: J): Long? = value.long?.takeIf { it >= 0 }
    private fun sum(values: List<Long>): Long? = try { values.fold(0L, Math::addExact) } catch (_: ArithmeticException) { null }
    fun session(projections: J): TokenUsage? {
        val value = projections["tokenUsage"]
        val input = count(value["uncachedInputTokens"]) ?: return null
        val output = count(value["outputTokens"]) ?: return null
        val read = count(value["cacheReadTokens"]) ?: return null
        val write = count(value["cacheWriteTokens"]) ?: return null
        return TokenUsage(input, output, sum(listOf(input, output, read, write)) ?: return null, read, write)
    }
    fun contextUsed(projections: J): Long? {
        val pressure = projections["contextPressure"]
        return count(if (pressure["projectedTokens"] == JsonNull) pressure["pressureTokens"] else pressure["projectedTokens"])
    }
    fun contextCapacity(projections: J): Long? = count(projections["contextPressure"]["contextWindow"])?.takeIf { it > 0 }
    fun contextCounts(projections: J) = "≈ " + number(contextUsed(projections)) + " / " + number(contextCapacity(projections))
    fun contextPercent(projections: J): Double? {
        val window = contextCapacity(projections) ?: return null
        val projected = contextUsed(projections) ?: return null
        return (projected.toDouble() / window.toDouble() * 100).coerceIn(0.0, 100.0)
    }
    fun number(value: Long?): String = value?.let { NumberFormat.getIntegerInstance().format(it) } ?: L("Unknown", "未知")
    fun percent(value: Double?): String = when {
        value == null -> L("Unknown", "未知")
        value > 0 && value < 0.1 -> "<0.1%"
        else -> NumberFormat.getNumberInstance().apply { maximumFractionDigits = 1 }.format(value) + "%"
    }
    fun line(tokens: TokenUsage?): String = tokens?.let { number(it.total) + L(" tokens", " 令牌") } ?: L("Usage unavailable", "用量未知")
    private fun normalize(sample: J, route: String?): TokenUsage? {
        val input = count(sample["inputTokens"]) ?: return null
        val output = count(sample["outputTokens"]) ?: return null
        fun optional(key: String) = count(sample[key])
        val read = optional("cacheReadTokens"); val write = optional("cacheWriteTokens"); val reasoning = optional("reasoningTokens")
        if (listOf("cacheReadTokens", "cacheWriteTokens", "reasoningTokens", "totalTokens").any { sample[it] != JsonNull && optional(it) == null }) return null
        if (reasoning != null && reasoning > output) return null
        val known = sum(listOf(input, read ?: 0L, write ?: 0L, output)) ?: return null
        val total = if (sample["totalTokens"] != JsonNull) optional("totalTokens")!! else {
            if (read == null || write == null) return null
            known
        }
        if (total < known || (read != null && write != null && total != known)) return null
        return TokenUsage(input, output, total, read, write, reasoning, route?.let(::listOf))
    }
    fun turns(events: Collection<J>): Map<Int, TokenUsage> {
        val result = linkedMapOf<Int, TokenUsage>()
        var current: MutableList<J>? = null
        for (event in events) {
            if (event["type"].text == "turn/start") current = mutableListOf()
            current?.add(event)
            if (event["type"].text == "turn/end") {
                current?.let { turnEvents ->
                    val turnNumber = turnEvents.first()["data"]["turn"].int
                    if (turnNumber != null) turn(turnEvents)?.let { result[turnNumber] = it }
                }
                current = null
            }
        }
        return result
    }
    fun turn(events: List<J>): TokenUsage? {
        var turn: Int? = null
        var step: Int? = null
        var state = "idle"
        var sample: J = JsonNull
        var ended = false
        val attempts = mutableListOf<TokenUsage>()
        fun close(route: String? = null): Boolean {
            if (state != "open") return false
            val usage = normalize(sample, route) ?: return false
            attempts.add(usage)
            return true
        }
        for (event in events) {
            val type = event["type"].text; val data = event["data"]
            if (type == "turn/start") {
                if (turn != null || state != "idle") return null
                turn = data["turn"].int ?: return null
                continue
            }
            if (turn == null || ended) return null
            if (type == "turn/end") {
                if (data["turn"].int != turn || state != "idle") return null
                ended = true; continue
            }
            if (type !in listOf("step/start", "llm/retry-started", "assistant/attempt", "assistant/message", "llm/retry", "step/end")) continue
            if (data["turn"].int != turn) return null
            if (type == "step/start") {
                if (state != "idle") return null
                step = data["step"].int ?: return null
                state = "open"; sample = JsonNull; continue
            }
            if (data["step"].int != step || state == "idle") return null
            when (type) {
                "llm/retry-started" -> {
                    if (state != "retry") return null
                    state = "open"; sample = JsonNull
                }
                "assistant/message", "assistant/attempt" -> {
                    if (state != "open") return null
                    val streamSample = CompactStream.expand(data["stream"].array).lastOrNull { it["type"].text == "usage" }?.get("usage") ?: JsonNull
                    val next = if (type == "assistant/message" && data["usage"] != JsonNull) data["usage"] else streamSample
                    if (next != JsonNull) sample = next
                    val source = data["message"]["source"]
                    val route = if (type == "assistant/message" && source["provider"].text.isNotEmpty() && source["model"].text.isNotEmpty()) source["provider"].text + "/" + source["model"].text else null
                    if (!close(route)) return null
                    state = if (type == "assistant/message") "message" else "finishClosed"
                }
                "llm/retry" -> {
                    if (state == "message" || state == "retry" || (state == "open" && !close())) return null
                    state = "retry"
                }
                "step/end" -> {
                    if (state == "open" && !close()) return null
                    state = "idle"
                }
            }
        }
        if (!ended || state != "idle" || attempts.isEmpty()) return null
        fun aggregate(get: (TokenUsage) -> Long?): Long? {
            val values = attempts.map { get(it) ?: return null }
            return sum(values)
        }
        return TokenUsage(aggregate { it.input } ?: return null, aggregate { it.output } ?: return null,
            aggregate { it.total } ?: return null, aggregate { it.cacheRead }, aggregate { it.cacheWrite }, aggregate { it.reasoning },
            if (attempts.all { it.routes != null }) attempts.flatMap { it.routes!! }.distinct() else null)
    }
}
