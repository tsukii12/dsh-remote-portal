package cn.tsukii.drp

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class TerminalTests {
    private fun info(id: String = "T", cols: Int = 80, rows: Int = 24) = o("id" to id, "title" to "bash", "cwd" to "/workspace", "cols" to cols, "rows" to rows, "state" to "running")
    private fun snapshot(sequence: Long = 7, screen: String = "host$ ", cols: Int = 80, rows: Int = 24) = o("type" to "snapshot", "sequence" to sequence, "screen" to screen, "info" to info(cols = cols, rows = rows), "writable" to true,
        "inputWindow" to o("maxBytes" to 262144, "frameOverheadBytes" to 46))
    private class Link : TerminalChannel {
        val input = Channel<J>(Channel.UNLIMITED)
        override val frames = input.receiveAsFlow()
        val sent = mutableListOf<J>()
        var closed = false
        override suspend fun send(value: J) { check(!closed); sent += value }
        override suspend fun close() { closed = true; input.close() }
    }
    @Test fun sequencesRejectMissingSnapshotGapsNegativeValuesAndOutOfOrderAcks() {
        val p = TerminalProtocol()
        fails<APIError.InvalidResponse> { p.output(1) }; fails<IllegalArgumentException> { p.reset(-1) }
        p.reset(2147483648L); assertFalse(p.output(2147483648L)); assertFalse(p.output(1))
        assertTrue(p.output(2147483649L)); fails<APIError.InvalidResponse> { p.output(2147483651L) }
        fails<APIError.InvalidResponse> { p.output(-1) }
        assertEquals(1L, p.next()); assertEquals(2L, p.next())
        fails<APIError.InvalidResponse> { p.ack(2) }; p.ack(1)
        fails<APIError.InvalidResponse> { p.ack(1) }; p.ack(2)
        p.reset(90); assertEquals(0L, p.sent); assertEquals(0L, p.acknowledged); assertEquals(1L, p.next())
    }
    @Test fun writesAndResizesShareAcknowledgedChannelAndEmulatorRepliesOmitTyped() = runTest {
        val api = StubAPI(); val link = Link(); val store = TerminalStore(api, "S", info(), backgroundScope) { link }
        val rendered = mutableListOf<J>(); store.render = { rendered += it }
        store.start(); runCurrent(); link.input.send(snapshot()); runCurrent()
        assertEquals("terminal/environment" to o("agentId" to "S"), api.calls.single())
        assertTrue(api.streams.contains("terminal/retain" to o("sessionId" to "S", "id" to "T")))
        store.write("echo 你好\r"); store.resize(92, 28); store.write("\u001b[1;1R", typed = false); runCurrent()
        assertEquals(listOf(o("type" to "write", "data" to "echo 你好\r", "typed" to true, "sequence" to 1)), link.sent)
        link.input.send(o("type" to "ack", "sequence" to 1)); runCurrent()
        assertEquals(o("type" to "resize", "cols" to 92, "rows" to 28, "sequence" to 2), link.sent.last())
        link.input.send(o("type" to "ack", "sequence" to 2)); runCurrent()
        assertEquals(o("type" to "write", "data" to "\u001b[1;1R", "sequence" to 3), link.sent.last())
        link.input.send(o("type" to "ack", "sequence" to 3)); runCurrent(); assertEquals(3L, store.state.value.acknowledged)
        link.input.send(o("type" to "output", "sequence" to 8, "data" to "ok")); link.input.send(o("type" to "output", "sequence" to 8, "data" to "duplicate")); runCurrent()
        assertEquals(listOf("snapshot", "output"), rendered.map { it["type"].text })
        store.stop(); runCurrent(); assertTrue(link.closed); assertFalse(store.state.value.writable)
    }
    @Test fun reconnectRestoresSnapshotAndNeverReplaysPendingInputAndForegroundAlwaysReattaches() = runTest {
        val links = mutableListOf<Link>(); val api = StubAPI()
        val store = TerminalStore(api, "S", info(), backgroundScope) { Link().also { links += it } }
        val engine = TerminalEngine { _, _ -> }; store.render = { engine.apply(it) }
        store.start(); runCurrent(); links[0].input.send(snapshot(screen = "old snapshot")); runCurrent()
        store.write("dangerous\r"); store.write("queued\r"); runCurrent()
        links[0].input.send(o("type" to "output", "sequence" to 10, "data" to "gap")); runCurrent()
        assertFalse(store.state.value.writable); assertNotNull(store.state.value.notice)
        advanceTimeBy(301); runCurrent(); assertEquals(2, links.size)
        links[1].input.send(snapshot(100, "restored host")); runCurrent()
        assertTrue(links[1].sent.isEmpty()); assertEquals("restored host", engine.text().trim()); assertEquals(2, store.state.value.snapshots)
        store.write("new\r"); runCurrent(); assertEquals(1L, links[1].sent.single()["sequence"].long)
        store.foreground(false); runCurrent(); assertTrue(links[1].closed)
        store.start(); runCurrent(); assertEquals(2, links.size)
        store.foreground(true); runCurrent(); assertEquals(3, links.size)
        links[2].input.send(snapshot(150, "foreground host")); runCurrent(); assertTrue(links[2].sent.isEmpty()); assertEquals("foreground host", engine.text().trim())
        store.stop()
    }
    @Test fun flowControlBoundsUtf8InputAndRefusalsDropQueuedCommandsWithoutSequenceGaps() = runTest {
        val api = StubAPI(); val link = Link(); val store = TerminalStore(api, "S", info(), backgroundScope) { link }
        store.start(); runCurrent(); link.input.send(snapshot().with("inputWindow", o("maxBytes" to 1024, "frameOverheadBytes" to 46))); runCurrent()
        val text = "😀".repeat(100)
        store.write(text); runCurrent(); assertEquals(1, link.sent.size)
        repeat(4) { index -> link.input.send(o("type" to "ack", "sequence" to index + 1)); runCurrent() }
        assertEquals(text, link.sent.joinToString("") { it["data"].text }); assertTrue(link.sent.all { it.toString().toByteArray().size + 46 <= 1024 })
        store.write("a".repeat(65537)); runCurrent(); assertEquals(4, link.sent.size); assertNotNull(store.state.value.error)
        store.write("first"); store.write("never"); runCurrent()
        link.input.send(o("type" to "ack", "sequence" to 5, "refusal" to "read-only")); runCurrent()
        assertFalse(store.state.value.writable)
        link.input.send(o("type" to "state", "info" to info(), "writable" to true)); runCurrent()
        store.write("after"); runCurrent(); assertEquals(6L, link.sent.last()["sequence"].long); assertEquals("after", link.sent.last()["data"].text)
        store.stop()
    }
    @Test fun invalidSnapshotsAndAckSequencesFailClosedAndReadOnlyCannotSend() = runTest {
        val api = StubAPI(); val link = Link(); val store = TerminalStore(api, "S", info(), backgroundScope) { link }
        fails<APIError.InvalidResponse> { store.apply(snapshot().with("info", info("other"))) }
        fails<APIError.InvalidResponse> { store.apply(snapshot().with("inputWindow", EMPTY)) }
        fails<APIError.InvalidResponse> { store.apply(snapshot(cols = 501)) }
        store.start(); runCurrent(); link.input.send(snapshot().with("writable", false)); runCurrent()
        store.write("blocked"); store.resize(90, 25); runCurrent(); assertTrue(link.sent.isEmpty())
        fails<APIError.InvalidResponse> { store.apply(o("type" to "ack", "sequence" to 1)) }
        store.stop()
    }
    @Test fun inventoryUsesSessionScopedExactArgumentsAndRetriesSameAllocationAfterAmbiguousFailure() = runTest {
        val calls = mutableListOf<Pair<String, J>>(); var failed = true; val saved = mutableListOf<String?>()
        val api = object : RPCServing {
            override suspend fun rpc(method: String, args: J): J {
                calls += method to args
                return when (method) {
                    "terminal/list" -> j(emptyList<J>())
                    "terminal/create" -> { if (failed) { failed = false; throw APIError.Disconnected }; info(args["request"]["id"].text) }
                    else -> EMPTY
                }
            }
            override fun stream(endpoint: String, args: J) = flow<J> { assertEquals("terminal/watch", endpoint); assertEquals(o("sessionId" to "S"), args); awaitCancellation() }
        }
        val inventory = TerminalInventory(api, "S", backgroundScope, saveAllocation = { saved += it })
        inventory.start(); runCurrent(); assertTrue(inventory.state.value.loaded); assertTrue(inventory.state.value.entries.isEmpty())
        assertNull(inventory.create()); val id = inventory.create()!!
        val creates = calls.filter { it.first == "terminal/create" }; assertEquals(creates[0], creates[1])
        assertEquals(o("agentId" to "S", "request" to o("id" to id, "cols" to 80, "rows" to 24)), creates[0].second)
        assertEquals(listOf(id, null), saved); assertFalse(inventory.rename(id, " ")); assertTrue(inventory.rename(id, "Renamed"))
        assertEquals("terminal/rename" to o("agentId" to "S", "id" to id, "title" to "Renamed"), calls.last())
        inventory.stop(); runCurrent(); assertTrue(calls.none { it.first == "terminal/close" })
        assertTrue(inventory.close(id)); assertEquals("terminal/close" to o("agentId" to "S", "id" to id), calls.last()); assertTrue(inventory.state.value.entries.isEmpty())
    }
    @Test fun nativeEmulatorRestoresColorsCursorUnicodeAlternateScreenAndApplicationArrowMode() {
        val replies = mutableListOf<Pair<String, Boolean>>()
        val engine = TerminalEngine { text, typed -> replies += text to typed }
        engine.apply(snapshot(screen = "\u001b[31m你好\u001b[0m\r\nline\u001b[?1h"))
        assertTrue(engine.text().contains("你好")); assertEquals("\u001bOA", engine.key(19))
        engine.apply(o("type" to "output", "data" to "\u001b[?1049h\u001b[2J\u001b[Halternate")); assertTrue(engine.text().contains("alternate")); assertFalse(engine.text().contains("你好"))
        engine.apply(o("type" to "output", "data" to "\u001b[?1049l")); assertTrue(engine.text().contains("你好"))
        engine.apply(o("type" to "output", "data" to "\u001b[6n")); assertTrue(replies.any { it.first.endsWith("R") && !it.second })
        engine.apply(snapshot(screen = "fresh")); assertEquals("fresh", engine.text().trim()); assertEquals("\u001b[A", engine.key(19))
        engine.apply(o("type" to "output", "data" to "\u001b[?2004h")); engine.paste("paste\ntext"); assertTrue(replies.any { it.second && it.first.startsWith("\u001b[200~") })
    }
    @Test fun returnCommitsMarkedTextBeforeCarriageReturnWithoutDroppingUnicode() {
        val value = TextFieldValue("echo 中文", selection = TextRange(7), composition = TextRange(5, 7))
        assertEquals("echo 中文\r", TerminalInput.returnText(value)); assertEquals("\r", TerminalInput.returnText(TextFieldValue()))
    }
}
