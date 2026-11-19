package cn.tsukii.drp

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.util.UUID

interface TerminalChannel {
    val frames: Flow<J>
    suspend fun send(value: J)
    suspend fun close()
}
class MuxTerminalChannel(private val stream: PortalMux.DuplexStream) : TerminalChannel {
    override val frames get() = stream.frames
    override suspend fun send(value: J) = stream.send(value)
    override suspend fun close() = stream.close()
}
class TerminalProtocol {
    var output: Long? = null; private set
    var sent = 0L; private set
    var acknowledged = 0L; private set
    fun reset(sequence: Long? = null) { require(sequence == null || sequence >= 0); output = sequence; sent = 0; acknowledged = 0 }
    fun output(sequence: Long): Boolean {
        val previous = output ?: throw APIError.InvalidResponse
        if (sequence < 0) throw APIError.InvalidResponse
        if (sequence <= previous) return false
        if (sequence != previous + 1) throw APIError.InvalidResponse
        output = sequence; return true
    }
    fun next(): Long { sent = Math.addExact(sent, 1); return sent }
    fun ack(sequence: Long) {
        if (sequence != acknowledged + 1 || sequence > sent) throw APIError.InvalidResponse
        acknowledged = sequence
    }
    fun discard(after: Long?) { sent = after ?: acknowledged }
}
data class TerminalState(val info: J, val ready: Boolean = false, val writable: Boolean = false,
    val error: String? = null, val notice: String? = null, val acknowledged: Long = 0, val snapshots: Int = 0)
class TerminalStore(private val api: RPCServing, val sessionID: String, info: J, private val scope: CoroutineScope,
    private val open: suspend () -> TerminalChannel) {
    val id = info["id"].text
    private val mutable = MutableStateFlow(TerminalState(info))
    val state = mutable.asStateFlow()
    val protocol = TerminalProtocol()
    var render: (J) -> Unit = {}
    var environment: J = EMPTY; private set
    private var window: J = EMPTY
    private var task: Job? = null
    private var channel: TerminalChannel? = null
    private var run = 0L
    private val queue = ArrayDeque<J>()
    private var inFlight: J? = null
    private var desiredCols = 80
    private var desiredRows = 24
    private var foreground = true
    private fun limit(key: String, fallback: Long) = environment[key].long?.takeIf { it > 0 } ?: fallback
    fun start() {
        if (!foreground || task?.isActive == true) return
        val token = ++run
        task = scope.launch {
            try {
                environment = api.rpc("terminal/environment", o("agentId" to sessionID)); ensureActive()
                coroutineScope {
                    val hold = launch {
                        api.stream("terminal/retain", o("sessionId" to sessionID, "id" to id)).collect { frame ->
                            if (frame["type"].text == "connection-reset") disconnect()
                        }
                        throw APIError.Disconnected
                    }
                    try {
                        while (isActive && token == run) {
                            var opened: TerminalChannel? = null
                            try {
                                opened = open(); ensureActive()
                                if (token != run) break
                                channel = opened
                                opened.frames.collect { frame -> ensureActive(); if (token == run) apply(frame) }
                                if (state.value.info["state"].text != "running") break
                                throw APIError.Disconnected
                            } catch (e: CancellationException) { throw e }
                            catch (e: Exception) {
                                if (token != run) break
                                mutable.value = state.value.copy(error = e.message ?: L("Reconnecting terminal…", "正在重新连接终端…"))
                                disconnect()
                                if (e is APIError.SessionExpired || e is APIError.Remote) break
                            } finally {
                                withContext(NonCancellable) { opened?.close() }
                                if (channel === opened) channel = null
                            }
                            delay(300)
                        }
                    } finally { hold.cancel() }
                }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { if (token == run) mutable.value = state.value.copy(error = e.message) }
            finally { if (token == run) disconnect() }
        }
    }
    fun stop() { run++; task?.cancel(); task = null; channel = null; disconnect() }
    fun reconnect() { stop(); start() }
    fun foreground(active: Boolean) { if (foreground != active) { foreground = active; stop(); if (active) start() } }
    private fun disconnect() {
        val uncertain = inFlight != null || queue.isNotEmpty()
        queue.clear(); inFlight = null; protocol.reset()
        mutable.value = state.value.copy(ready = false, writable = false, acknowledged = 0,
            notice = if (uncertain) L("Pending input was not replayed. Check the shell before typing again.", "待确认输入未重发，请检查终端后再输入。") else state.value.notice)
    }
    fun apply(value: J) {
        when (value["type"].text) {
            "connection-reset" -> throw APIError.Disconnected
            "snapshot" -> {
                val seq = value["sequence"].long?.takeIf { it >= 0 } ?: throw APIError.InvalidResponse
                val info = value["info"]
                val cols = info["cols"].int ?: throw APIError.InvalidResponse
                val rows = info["rows"].int ?: throw APIError.InvalidResponse
                if (info["id"].text != id || cols !in 2..limit("maxCols", 500) || rows !in 1..limit("maxRows", 200) || value["screen"].string == null) throw APIError.InvalidResponse
                val input = value["inputWindow"]
                if ((input["maxBytes"].long ?: 0) <= 0 || (input["frameOverheadBytes"].long ?: -1) !in 0..4096) throw APIError.InvalidResponse
                disconnect(); protocol.reset(seq); window = input
                render(value)
                mutable.value = state.value.copy(info = info, ready = true, writable = value["writable"].boolean && info["state"].text == "running", error = null, snapshots = state.value.snapshots + 1)
                resize(desiredCols, desiredRows)
            }
            "output" -> {
                val seq = value["sequence"].long ?: throw APIError.InvalidResponse
                if (value["data"].string == null) throw APIError.InvalidResponse
                if (protocol.output(seq)) render(value)
            }
            "state" -> {
                if (!state.value.ready || value["info"]["id"].text != id) throw APIError.InvalidResponse
                mutable.value = state.value.copy(info = value["info"], writable = value["writable"].boolean && value["info"]["state"].text == "running")
                if (!state.value.writable) discardQueued()
                render(value)
            }
            "ack" -> {
                val seq = value["sequence"].long ?: throw APIError.InvalidResponse
                if (inFlight?.get("sequence")?.long != seq) throw APIError.InvalidResponse
                protocol.ack(seq); inFlight = null
                mutable.value = state.value.copy(acknowledged = seq)
                if (value["refusal"].string != null) {
                    discardQueued()
                    mutable.value = state.value.copy(writable = false, error = L("Input refused. Check terminal ownership and state.", "输入被拒绝，请检查终端控制权和状态。"))
                } else flush()
            }
        }
    }
    private fun discardQueued() { queue.clear(); protocol.discard(inFlight?.get("sequence")?.long) }
    fun write(data: String, typed: Boolean = true): Boolean {
        if (data.isEmpty()) return true
        val raw = data.toByteArray(Charsets.UTF_8).size.toLong()
        val chunkSize = minOf(4096L, limit("maxInputBytes", 65536), ((window["maxBytes"].long ?: 0) - (window["frameOverheadBytes"].long ?: 0) - 256) / 6).toInt()
        if (raw > limit("maxInputBytes", 65536) || chunkSize < 4) { bufferError(); return false }
        val chunks = mutableListOf<String>(); val chunk = StringBuilder(); var bytes = 0
        data.codePoints().forEachOrdered { code ->
            val text = String(Character.toChars(code)); val size = text.toByteArray(Charsets.UTF_8).size
            if (bytes + size > chunkSize) { chunks += chunk.toString(); chunk.setLength(0); bytes = 0 }
            chunk.append(text); bytes += size
        }
        if (chunk.isNotEmpty()) chunks += chunk.toString()
        return enqueue(chunks.map { if (typed) o("type" to "write", "data" to it, "typed" to true) else o("type" to "write", "data" to it) })
    }
    fun resize(cols: Int, rows: Int) {
        desiredCols = cols.coerceIn(2, limit("maxCols", 500).toInt())
        desiredRows = rows.coerceIn(1, limit("maxRows", 200).toInt())
        if (!state.value.ready || !state.value.writable) return
        val last = queue.lastOrNull { it["type"].text == "resize" } ?: inFlight?.takeIf { it["type"].text == "resize" } ?: state.value.info
        if (last["cols"].int != desiredCols || last["rows"].int != desiredRows) enqueue(listOf(o("type" to "resize", "cols" to desiredCols, "rows" to desiredRows)))
    }
    private fun encoded(value: J) = value.toString().toByteArray(Charsets.UTF_8).size.toLong() + (window["frameOverheadBytes"].long ?: 0)
    private fun bufferError() { mutable.value = state.value.copy(error = L("Input buffer full or paste too large. Wait for acknowledgement or paste less.", "输入缓冲区已满或粘贴过大，请等待确认或分段粘贴。")) }
    private fun enqueue(commands: List<J>): Boolean {
        if (!state.value.ready || !state.value.writable || channel == null) { mutable.value = state.value.copy(error = L("Terminal is not writable. Reconnect before typing.", "终端当前不可写，请重新连接后输入。")); return false }
        val numbered = commands.mapIndexed { index, command -> command.with("sequence", j(protocol.sent + index + 1)) }
        val all = queue.toList() + listOfNotNull(inFlight) + numbered
        if (all.sumOf(::encoded) > limit("maxBufferedBytes", 2097152) || all.sumOf { it["data"].text.toByteArray(Charsets.UTF_8).size.toLong() } > limit("maxInputBytes", 65536) || numbered.any { encoded(it) > (window["maxBytes"].long ?: 0) }) { bufferError(); return false }
        numbered.forEach { protocol.next(); queue.addLast(it) }; flush(); return true
    }
    private fun flush() {
        if (inFlight != null || queue.isEmpty() || !state.value.writable) return
        val opened = channel ?: return
        val command = queue.removeFirst(); inFlight = command; val token = run
        scope.launch {
            try { opened.send(command) }
            catch (e: CancellationException) { throw e }
            catch (e: Exception) {
                if (token == run && channel === opened) { mutable.value = state.value.copy(error = e.message); disconnect(); opened.close() }
            }
        }
    }
}

data class TerminalInventoryState(val entries: List<J> = emptyList(), val loaded: Boolean = false, val busy: Boolean = false, val error: String? = null)
class TerminalInventory(private val api: RPCServing, val sessionID: String, private val scope: CoroutineScope,
    private var allocation: String? = null, private val saveAllocation: (String?) -> Unit = {}) {
    private val mutable = MutableStateFlow(TerminalInventoryState())
    val state = mutable.asStateFlow()
    private var job: Job? = null
    fun start() {
        if (job?.isActive == true) return
        job = scope.launch {
            try {
                val entries = api.rpc("terminal/list", o("sessionId" to sessionID)).array; ensureActive()
                mutable.value = state.value.copy(entries = entries, loaded = true, error = null)
                api.stream("terminal/watch", o("sessionId" to sessionID)).collect { value ->
                    if (value["type"].text != "connection-reset") mutable.value = state.value.copy(entries = value.array, loaded = true)
                }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { mutable.value = state.value.copy(error = e.message) }
        }
    }
    fun stop() { job?.cancel(); job = null }
    suspend fun create(): String? {
        if (state.value.busy) return null
        val id = allocation ?: UUID.randomUUID().toString().also { allocation = it; saveAllocation(it) }
        return change {
            val info = api.rpc("terminal/create", o("agentId" to sessionID, "request" to o("id" to id, "cols" to 80, "rows" to 24)))
            currentCoroutineContext().ensureActive()
            if (info["id"].text != id) throw APIError.InvalidResponse
            mutable.value = state.value.copy(entries = state.value.entries.filterNot { it["id"].text == id } + info)
            allocation = null; saveAllocation(null); id
        }
    }
    suspend fun rename(id: String, title: String): Boolean {
        val value = title.trim()
        if (value.isEmpty() || value.length > 120) return false
        return change {
            api.rpc("terminal/rename", o("agentId" to sessionID, "id" to id, "title" to value)); currentCoroutineContext().ensureActive()
            mutable.value = state.value.copy(entries = state.value.entries.map { if (it["id"].text == id) it.with("title", j(value)) else it }); true
        } ?: false
    }
    suspend fun close(id: String): Boolean = change {
        api.rpc("terminal/close", o("agentId" to sessionID, "id" to id)); currentCoroutineContext().ensureActive()
        mutable.value = state.value.copy(entries = state.value.entries.filterNot { it["id"].text == id }); true
    } ?: false
    private suspend fun <T> change(block: suspend () -> T): T? {
        if (state.value.busy) return null
        mutable.value = state.value.copy(busy = true, error = null)
        return try { block() } catch (e: CancellationException) { throw e }
        catch (e: Exception) { mutable.value = state.value.copy(error = e.message); null }
        finally { mutable.value = state.value.copy(busy = false) }
    }
}
