package cn.tsukii.drp

import org.junit.Assert.*
import org.junit.Test

class InteractionRoutingTests {
    private fun item(id: String, agent: String, kind: String = "approval/request") = PendingInteraction(id, "client", agent, kind, EMPTY)

    @Test fun capturedWaterfallAgentIsTheSessionAddress() {
        val frames = fixture("live-stream-all").array.map { it["value"] }
        val events = RemoteEvents(StubAPI())
        frames.forEach(events::apply)
        val request = events.state.value.pending.first()
        val sessionID = "session-18be2ddf-6a3a-42d3-aa72-320df014ae67"
        assertEquals(sessionID, request.agentID)
        assertEquals(sessionID, InteractionRouting.sessionID(request, setOf(sessionID)))
        assertEquals(request, InteractionRouting.automatic(listOf(request), sessionID, emptySet()))
    }

    @Test fun onlyTheOpenSessionAutomaticallyPresentsAndLaterDefers() {
        val other = item("other", "B")
        val approval = item("approve", "A")
        val question = item("question", "A", "user-questions/request")
        val pending = listOf(other, approval, question)
        assertEquals(approval, InteractionRouting.automatic(pending, "A", emptySet()))
        assertEquals(question, InteractionRouting.automatic(pending, "A", setOf("approve")))
        assertNull(InteractionRouting.automatic(pending, "A", setOf("approve", "question")))
        assertEquals(listOf(approval, question), InteractionRouting.forSession(pending, "A"))
        assertEquals("A", InteractionRouting.sessionID(approval, setOf("A", "B")))
    }

    @Test fun emptyUnknownAndMissingAgentsNeverAutoOpenOrNavigate() {
        assertNull(InteractionRouting.automatic(emptyList(), "A", emptySet()))
        assertNull(InteractionRouting.automatic(listOf(item("unknown", "B")), "A", emptySet()))
        assertNull(InteractionRouting.automatic(listOf(item("missing", "")), "", emptySet()))
        assertNull(InteractionRouting.automatic(listOf(item("known", "A")), null, emptySet()))
        assertNull(InteractionRouting.sessionID(item("unknown", "subagent"), setOf("A")))
        assertNull(InteractionRouting.sessionID(item("missing", ""), setOf("")))
        assertTrue(InteractionRouting.forSession(listOf(item("missing", "")), "").isEmpty())
    }

    @Test fun pendingLabelsAreBilingualAndIncludeQuestions() {
        val approval = item("a", "A")
        val question = item("q", "A", "user-questions/request")
        assertEquals("1 pending approval", InteractionRouting.label(listOf(approval), listOf("en")))
        assertEquals("1 个待处理授权", InteractionRouting.label(listOf(approval), listOf("zh-CN")))
        assertEquals("2 pending approvals", InteractionRouting.label(listOf(approval, approval), listOf("en")))
        assertEquals("1 pending question", InteractionRouting.label(listOf(question), listOf("en")))
        assertEquals("2 个待处理请求", InteractionRouting.label(listOf(approval, question), listOf("zh-CN")))
    }
}
