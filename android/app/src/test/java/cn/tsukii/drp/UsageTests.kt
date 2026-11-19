package cn.tsukii.drp

import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test
import java.util.Locale

class UsageTests {
    private fun event(type: String, vararg fields: Pair<String, Any?>): J = o("type" to type, "data" to o("turn" to 1, "step" to 1, *fields))
    private val sample = o("inputTokens" to 100L, "outputTokens" to 20L, "cacheReadTokens" to 50L, "cacheWriteTokens" to 10L, "reasoningTokens" to 5L, "totalTokens" to 180L)
    private fun message(usage: J = sample): J = event("assistant/message", "usage" to usage, "message" to o("id" to "M", "source" to o("provider" to "P", "model" to "model"), "content" to emptyList<J>()))
    private fun turn(usage: J = sample) = listOf(event("turn/start"), event("step/start"), message(usage), event("step/end"), event("turn/end"))
    @Test fun sessionCountsUnknownZeroLargeAndOverflow() {
        assertNull(Usage.session(EMPTY)); assertNull(Usage.contextPercent(EMPTY))
        fun projection(input: Long, output: Long = 0) = o("tokenUsage" to o("uncachedInputTokens" to input, "outputTokens" to output, "cacheReadTokens" to 0, "cacheWriteTokens" to 0))
        assertEquals(0L, Usage.session(projection(0))!!.total)
        assertEquals(6000000000L, Usage.session(projection(5000000000, 1000000000))!!.total)
        assertNull(Usage.session(projection(-1))); assertNull(Usage.session(projection(Long.MAX_VALUE, 1)))
        assertNull(Usage.session(o("tokenUsage" to o("uncachedInputTokens" to "100"))))
        fun context(projected: Long?, pressure: Long = 50, window: Long = 100) = o("contextPressure" to o("projectedTokens" to projected, "pressureTokens" to pressure, "contextWindow" to window))
        assertEquals(50.0, Usage.contextPercent(context(null))!!, 0.001)
        assertEquals(0.0, Usage.contextPercent(context(0))!!, 0.001)
        assertEquals(100.0, Usage.contextPercent(context(200))!!, 0.001)
        assertNull(Usage.contextPercent(context(2, window = 0)))
    }
    @Test fun completeTurnCountsAttemptsAndRejectsIncompleteOrContradictoryEvidence() {
        val tokens = Usage.turn(turn())!!
        assertEquals(180L, tokens.total); assertEquals(5L, tokens.reasoning); assertEquals(listOf("P/model"), tokens.routes)
        assertNull(Usage.turn(turn().drop(1))); assertNull(Usage.turn(turn().dropLast(1)))
        assertNull(Usage.turn(turn(sample.with("totalTokens", 179))))
        assertNull(Usage.turn(turn(sample.with("reasoningTokens", 21))))
        assertNull(Usage.turn(turn(sample.with("inputTokens", -1))))
        val retry = listOf(event("turn/start"), event("step/start"), event("assistant/attempt", "stream" to listOf(o("type" to "chunk", "chunk" to o("type" to "usage", "usage" to sample)))),
            event("llm/retry"), event("llm/retry-started"), message(), event("step/end"), event("turn/end"))
        assertEquals(360L, Usage.turn(retry)!!.total)
        assertNull(Usage.turn(retry)!!.routes)
        assertNull(Usage.turn(retry.filterNot { it["type"].text == "llm/retry-started" }))
        assertNull(Usage.turn(emptyList()))
    }
    @Test fun missingOptionalBucketsDoNotBecomeZeroAndUnknownIsLocalized() {
        val exact = o("inputTokens" to 100, "outputTokens" to 20, "totalTokens" to 180)
        val usage = Usage.turn(turn(exact))!!
        assertNull(usage.cacheRead); assertNull(usage.cacheWrite); assertEquals(180L, usage.total)
        assertNull(Usage.turn(turn(o("inputTokens" to 1, "outputTokens" to 2))))
        val before = Locale.getDefault()
        try {
            Locale.setDefault(Locale.ENGLISH); assertEquals("Usage unavailable", Usage.line(null)); assertEquals("0 tokens", Usage.line(TokenUsage(0, 0, 0)))
            Locale.setDefault(Locale.SIMPLIFIED_CHINESE); assertEquals("用量未知", Usage.line(null)); assertEquals("0 令牌", Usage.line(TokenUsage(0, 0, 0)))
        } finally { Locale.setDefault(before) }
    }
    @Test fun historyUsageReconcilesSnapshotsEventsAndOnlyAppearsWhenComplete() = runTest {
        val store = ChatStore("S", StubAPI(), scope = backgroundScope)
        val records = turn().mapIndexed { i, value -> o("event" to value.with("seq", i + 1)) }
        store.apply(o("type" to "snapshot", "records" to records.dropLast(1)))
        assertTrue(store.state.value.turnUsage.isEmpty())
        store.apply(o("type" to "event", "event" to records.last()["event"]))
        assertEquals(180L, store.state.value.turnUsage[1]!!.total)
        assertEquals(setOf(1), store.state.value.completedTurns)
        store.apply(o("type" to "snapshot", "records" to emptyList<J>()))
        assertTrue(store.state.value.turnUsage.isEmpty()); assertTrue(store.state.value.completedTurns.isEmpty())
    }
    @Test fun absentOrSignedOutAccountIsHiddenButServedBalanceIsKept() = runTest {
        val api = StubAPI(); val store = ChatStore("S", api, scope = backgroundScope)
        api.failure = APIError.Remote("unknown-method", "Not served"); store.loadUsageAccount(); assertEquals(j(null), store.state.value.accountBalance)
        api.failure = null; api.response = j(null); store.loadUsageAccount(); assertEquals(j(null), store.state.value.accountBalance)
        api.response = o("status" to "ready", "value" to listOf(o("currency" to "USD", "balance" to "1.2345")))
        store.loadUsageAccount(); assertEquals("1.2345", store.state.value.accountBalance["value"].array.single()["balance"].text)
        api.failure = APIError.SessionExpired; fails<APIError.SessionExpired> { store.loadUsageAccount() }
    }
}
