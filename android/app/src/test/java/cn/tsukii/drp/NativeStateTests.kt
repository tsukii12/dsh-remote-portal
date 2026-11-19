package cn.tsukii.drp

import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID
import java.util.TimeZone

@OptIn(ExperimentalCoroutinesApi::class)
class NativeStateTests {
    @Test fun historySnapshotAndToolResultPairing() {
        val chat = ChatStore("S", StubAPI()); chat.apply(snapshot("live-approval-events"))
        val s = chat.state.value
        assertEquals(3, s.transcript.count { it.role == "user" }); assertEquals(5, s.transcript.count { it.role == "assistant" })
        assertFalse(s.transcript.any { it.role == "tool" })
        val calls = s.transcript.flatMap { it.blocks }.filter { it.kind == "tool-call" }
        assertEquals(2, calls.size); assertTrue(calls.all { it.result!!["message"]["content"].array.first()["text"].text == "/Users/devin/fake-llm\n" })
        assertTrue(s.transcript.first { it.role == "assistant" }.blocks.any { it.kind == "reasoning" })
        chat.apply(snapshot("live-approval-events")); assertEquals(s.transcript, chat.state.value.transcript)
    }
    @Test fun liveChunksCommitAndOptimisticReconciliation() {
        val chat = ChatStore("S", StubAPI())
        chat.addOptimistic("hello", fixture("live-hello-prompt-request")["payload"]["args"]["request"]["requestId"].text)
        val frames = fixture("live-hello-stream").array.filter { it["streamId"].text == "follow" }
        var sawStreaming = false
        frames.forEach {
            chat.apply(it["value"])
            if (!chat.state.value.inProgress?.text.isNullOrEmpty()) sawStreaming = true
            if (chat.state.value.transcript.any { it.role == "assistant" }) assertNull(chat.state.value.inProgress)
        }
        val s = chat.state.value
        assertTrue(sawStreaming); assertEquals(1, s.transcript.count { it.role == "user" }); assertEquals(1, s.transcript.count { it.role == "assistant" })
        assertFalse(s.transcript.any { it.optimistic }); assertTrue(s.transcript.last().text.contains("```sh"))
        frames.forEach { chat.apply(it["value"]) }; assertEquals(s.transcript, chat.state.value.transcript); assertNull(chat.state.value.inProgress)
    }
    @Test fun compactExpansionAndReconnectActiveAttempt() {
        val event = fixture("live-hello-events")["result"]["value"]["records"].array.first { it["event"]["type"].text == "assistant/message" }["event"]
        val compact = event["data"]["stream"]
        val blocks = CompactStream.expand(compact.array).fold(emptyList<TranscriptBlock>()) { b, c -> CompactStream.apply(c, b) }
        assertEquals(event["data"]["message"]["content"].array.map(::TranscriptBlock), blocks)
        val chat = ChatStore("S", StubAPI())
        chat.apply(o("type" to "snapshot", "records" to emptyList<J>(), "assistantStream" to o("revision" to 10, "activeAttempt" to o("attemptId" to "A", "turn" to 1, "step" to 1, "nextIndex" to 12, "stream" to compact))))
        assertEquals(blocks, chat.state.value.inProgress?.blocks)
        chat.apply(parse("""{"type":"assistant-stream","frame":{"type":"chunk","attemptId":"A","revision":10,"index":11,"chunk":{"type":"text-delta","index":1,"text":"duplicate"}}}"""))
        assertEquals(blocks, chat.state.value.inProgress?.blocks)
        chat.apply(parse("""{"type":"assistant-stream","frame":{"type":"end","attemptId":"A","revision":11,"outcome":{"kind":"abandoned"}}}"""))
        assertNull(chat.state.value.inProgress)
    }
    @Test fun surfaceReplacementAndUnknownEvents() {
        val chat = ChatStore("S", StubAPI())
        fun user(seq: Int, text: String, op: J = j("append")) = o("type" to "event", "event" to o("seq" to seq, "type" to "user/message", "surfaceOp" to op,
            "data" to o("id" to "u$seq", "content" to listOf(o("type" to "text", "text" to text)))))
        chat.apply(user(1, "one")); chat.apply(user(2, "two")); chat.apply(user(3, "three"))
        chat.apply(user(4, "replacement", o("op" to "replace", "startSeq" to 1, "endSeq" to 2)))
        chat.apply(parse("""{"type":"event","event":{"seq":5,"type":"future/plugin","data":{}}}"""))
        assertEquals(listOf("replacement", "three"), chat.state.value.transcript.map { it.text })
        chat.apply(user(6, "replacement again", o("op" to "replace", "startSeq" to 4, "endSeq" to 3)))
        assertEquals(listOf("replacement again"), chat.state.value.transcript.map { it.text })
    }
    @Test fun interactionsFromLiveEventsAndGenerationReset() = runTest {
        val api = StubAPI(); val events = RemoteEvents(api, backgroundScope)
        fixture("live-stream-all").array.filter { it["streamId"].text == "events" }.forEach { events.apply(it["value"]) }
        val pending = events.state.value.pending.first()
        assertEquals("approval/request", pending.kind); assertEquals("bash", pending.request["toolName"].text)
        events.answerApproval(pending.id, true)
        assertEquals("\$events/result", api.calls.last().first); assertEquals(pending.clientID, api.calls.last().second["clientId"].text)
        assertEquals(j("allowed-once"), api.calls.last().second["outcome"]["value"]); assertTrue(events.state.value.pending.isEmpty())
        events.apply(parse("""{"type":"waterfall","event":"user-questions/request","eventId":"Q","agentId":"S","request":{"questions":[]}}"""))
        events.answerQuestions("Q", listOf(o("id" to "q1", "selected" to listOf("Yes"))))
        assertEquals(1, api.calls.last().second["outcome"]["value"]["answers"].array.size)
        events.apply(parse("""{"type":"waterfall","event":"approval/request","eventId":"E","request":{}}"""))
        events.apply(o("type" to "cancel", "eventId" to "E")); assertTrue(events.state.value.pending.isEmpty())
        events.apply(o("type" to "connection-reset")); assertNull(events.state.value.clientID)
        fails<APIError.Disconnected> { events.answerApproval("E", false) }
    }
    @Test fun workspaceBaselineDeltasAndGrouping() {
        val store = SidebarStore(StubAPI()); val id = fixture("live-session-create")["result"]["value"]["sessionId"]
        val summary = o("sessionId" to id, "updatedAt" to 1, "projections" to o("values" to o("title" to "Fixture conversation")))
        store.applySessions(o("items" to listOf(summary, o("sessionId" to "other", "updatedAt" to 2))))
        store.applyWorkspace(o("type" to "baseline", "value" to o("items" to listOf(o("workspaceId" to "W", "title" to "Workspace", "path" to "/workspace", "sessionIds" to listOf(id))))))
        assertEquals("Fixture conversation", store.state.value.groups.first { it.id == "W" }.sessions.first().title)
        assertEquals(listOf("other"), store.state.value.groups.last().sessions.map { it.id })
        store.applyWorkspace(o("type" to "pinned", "pinnedSessionIds" to listOf(id)))
        assertEquals(1, store.state.value.groups.first().sessions.size); assertTrue(store.state.value.groups.first { it.id == "W" }.sessions.isEmpty())
        store.applyWorkspace(o("type" to "archived", "archivedSessionIds" to listOf(id))); assertTrue(store.state.value.groups.first().sessions.isEmpty())
        store.applyWorkspace(parse("""{"type":"upsert","workspace":{"workspaceId":"W2","title":"Second","sessionIds":[]}}"""))
        store.applyWorkspace(o("type" to "order", "workspaceIds" to listOf("W2", "W"))); assertEquals(listOf("W2", "W"), store.state.value.workspaces.map { it.id })
        store.applyWorkspace(o("type" to "remove", "workspaceId" to "W")); assertEquals(listOf("W2"), store.state.value.workspaces.map { it.id })
        store.applyWorkspace(parse("""{"type":"replace","value":{"items":[],"archivedSessionIds":[],"pinnedSessionIds":[]}}""")); assertEquals(2, store.state.value.groups.last().sessions.size)
        store.applyEvent(o("type" to "emit", "event" to "api-session/status", "args" to listOf(id, j(true)))); assertTrue(store.state.value.sessions[id.text]!!.running)
        store.applyEvent(o("type" to "emit", "event" to "api-session/activity", "args" to listOf(id, j(42)))); assertEquals(42, store.state.value.sessions[id.text]!!.updatedAt.int)
        store.applyControl(o("type" to "projection", "sessionId" to id, "changes" to listOf(o("key" to "title", "val" to "Renamed")))); assertEquals("Renamed", store.state.value.sessions[id.text]!!.title)
        store.applyEvent(o("type" to "emit", "event" to "api-session/removed", "args" to listOf(id))); assertNull(store.state.value.sessions[id.text])
        store.applyEvent(o("type" to "emit", "event" to "api-session/added", "args" to listOf(summary))); assertEquals("Fixture conversation", store.state.value.sessions[id.text]!!.title)
    }
    @Test fun capturedWorkspaceBaselineAndDeltas() {
        val frames = fixture("live-workspace-stream").array
        val workspace = frames.first { it["workspace"]["title"].text == "Native fixture workspace" }["workspace"]
        val session = workspace["sessionIds"].array.first().text
        val ids = frames.flatMap { frame -> (frame["value"]["items"].array + frame["workspace"]).flatMap { it["sessionIds"].array.map { it.text } } }.toSet()
        val store = SidebarStore(StubAPI()); store.applySessions(o("items" to ids.map { o("sessionId" to it, "projections" to o("values" to o("title" to "Captured session"))) }))
        var sawPinned = false; var sawGrouped = false
        frames.forEach { frame ->
            store.applyWorkspace(frame)
            if (session in store.state.value.pinnedIDs) {
                sawPinned = true; assertTrue(store.state.value.groups.first().sessions.any { it.id == session })
                assertFalse(store.state.value.groups.first { it.id == workspace["workspaceId"].text }.sessions.any { it.id == session })
            } else if (store.state.value.groups.find { it.id == workspace["workspaceId"].text }?.sessions?.any { it.id == session } == true) sawGrouped = true
        }
        assertTrue(sawPinned); assertTrue(sawGrouped); assertTrue(session in store.state.value.archivedIDs)
        assertFalse(store.state.value.workspaces.any { it.id == workspace["workspaceId"].text }); assertFalse(store.state.value.groups.flatMap { it.sessions }.any { it.id == session })
    }
    @Test fun fullLiveStreamIncludingToolDeltas() {
        val chat = ChatStore("S", StubAPI()); var sawToolDelta = false
        fixture("live-stream-all").array.filter { it["streamId"].text == "follow" }.forEach {
            chat.apply(it["value"])
            if (chat.state.value.inProgress?.blocks?.any { it.kind == "tool-call" && it.name == "bash" && it.arguments.contains("pwd") } == true) sawToolDelta = true
        }
        assertTrue(sawToolDelta); assertNull(chat.state.value.inProgress); assertEquals(5, chat.state.value.transcript.count { it.role == "assistant" })
        assertEquals(2, chat.state.value.transcript.flatMap { it.blocks }.count { it.kind == "tool-call" && it.result != null }); assertFalse(chat.state.value.transcript.any { it.role == "tool" })
    }
    @Test fun actionsFailureEmptySendAndPagination() = runTest {
        val api = StubAPI(); val chat = ChatStore("S", api, scope = backgroundScope)
        fails<PortalError> { chat.send(" \n") }; assertTrue(api.calls.isEmpty())
        api.failure = APIError.SessionExpired; fails<APIError.SessionExpired> { chat.send("hello") }; assertNotNull(chat.state.value.transcript.first().deliveryError)
        api.failure = null; api.response = o("accepted" to true); chat.applyState(o("running" to true)); chat.send("steer", true)
        val request = api.calls.last().second["request"]; assertEquals("steer", request["mode"].text); UUID.fromString(request["requestId"].text)
        assertEquals(TimeZone.getDefault().id, request["clientTimeZone"].text)
        chat.cancel(); assertEquals("session/cancel", api.calls.last().first)
        val page = snapshot("live-hello-events").with("hasMore", true); chat.apply(page)
        api.response = o("records" to emptyList<J>(), "hasMore" to false); chat.loadOlder()
        assertEquals("session/events", api.calls.last().first); assertEquals(page["cursor"], api.calls.last().second["request"]["throughSeq"])
        assertEquals(0, api.calls.last().second["request"]["beforeSeq"].int); assertFalse(chat.state.value.hasMore)
        val count = api.calls.size; chat.loadOlder(); assertEquals(count, api.calls.size)
    }
    @Test fun emptyResetInvalidIndicesAndLifecycle() = runTest {
        val api = StubAPI(); val events = RemoteEvents(api, backgroundScope); val chat = ChatStore("S", api, events, backgroundScope)
        chat.apply(o("type" to "snapshot")); assertTrue(chat.state.value.loaded); assertTrue(chat.state.value.transcript.isEmpty())
        assertEquals(emptyList<TranscriptBlock>(), CompactStream.apply(o("index" to -1), emptyList()))
        assertEquals(emptyList<TranscriptBlock>(), CompactStream.apply(o("index" to 4096), emptyList()))
        assertTrue(CompactStream.expand(listOf(o("type" to "unknown"))).isEmpty())
        chat.start(); chat.start(); runCurrent(); assertEquals(1, api.streams.count { it.first == "session/follow" })
        events.apply(o("type" to "emit", "event" to "api-session/status", "args" to listOf("S", true))); assertTrue(chat.state.value.running)
        chat.apply(o("type" to "connection-reset")); assertFalse(chat.state.value.loaded); assertNull(chat.state.value.inProgress)
        chat.stop(); chat.stop(); events.stop()
    }
}
