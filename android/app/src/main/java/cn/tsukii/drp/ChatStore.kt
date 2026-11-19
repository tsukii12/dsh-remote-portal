package cn.tsukii.drp

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.JsonNull
import java.util.UUID
import java.util.TimeZone

data class TranscriptBlock(val kind: String, val text: String = "", val callID: String = "", val name: String = "", val arguments: String = "", val result: J? = null) {
    constructor(value: J) : this(value["type"].text, value["text"].text, value["id"].text, value["name"].text, value["arguments"].text)
}
data class TranscriptItem(val id: String, val role: String, val blocks: List<TranscriptBlock>, val seq: Int? = null,
    val requestID: String? = null, val optimistic: Boolean = false, val deliveryError: String? = null,
    val inProgress: Boolean = false, val turn: Int? = null, val step: Int? = null) {
    val text: String get() = blocks.filter { it.kind == "text" }.joinToString("") { it.text }
}
object CompactStream {
    fun expand(records: List<J>): List<J> = records.flatMap { record ->
        when (record["type"].text) {
            "chunk" -> listOf(record["chunk"])
            "text-chunks", "reasoning-chunks" -> record["texts"].array.map { o("type" to if (record["type"].text == "text-chunks") "text-delta" else "reasoning-delta", "index" to record["index"], "text" to it) }
            "tool-call-chunks" -> record["args"].array.mapIndexed { index, argument ->
                var chunk = o("type" to "tool-call-delta", "index" to record["index"], "id" to record["id"], "argumentsDelta" to argument)
                if (index == 0) chunk = chunk.with("name", record["name"])
                chunk
            }
            else -> emptyList()
        }
    }
    fun apply(chunk: J, blocks: List<TranscriptBlock>): List<TranscriptBlock> {
        val index = chunk["index"].int?.takeIf { it in 0..4095 } ?: return blocks
        val result = blocks.toMutableList()
        while (result.size <= index) result.add(TranscriptBlock("unknown"))
        val old = result[index]
        result[index] = when (chunk["type"].text) {
            "block-start" -> TranscriptBlock(chunk["blockType"].text)
            "text-delta", "reasoning-delta" -> old.copy(kind = if (chunk["type"].text == "text-delta") "text" else "reasoning", text = old.text + chunk["text"].text)
            "tool-call-delta" -> old.copy(kind = "tool-call", callID = chunk["id"].string ?: old.callID, name = chunk["name"].string ?: old.name, arguments = old.arguments + chunk["argumentsDelta"].text)
            "block-end" -> TranscriptBlock(chunk["block"])
            else -> old
        }
        return result
    }
}
data class ChatState(val transcript: List<TranscriptItem> = emptyList(), val inProgress: TranscriptItem? = null,
    val running: Boolean = false, val hasMore: Boolean = false, val loaded: Boolean = false,
    val catalog: J = EMPTY, val selectedModel: J = EMPTY, val error: String? = null)

class ChatStore(val sessionID: String, private val api: RPCServing, private val events: RemoteEvents? = null,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)) {
    private val mutable = MutableStateFlow(ChatState())
    val state = mutable.asStateFlow()
    private var observer: String? = null
    private var followTask: Job? = null
    private val history = sortedMapOf<Int, J>()
    private var optimistic = listOf<TranscriptItem>()
    private var snapshotCursor: Int? = null
    private var attemptID: String? = null
    private var revision = -1
    private var nextIndex = 0
    private var pendingCommitSeq: Int? = null
    private val address get() = o("kind" to "session", "sessionId" to sessionID)
    suspend fun start() {
        if (followTask != null) return
        observer = events?.observe(::applyStatusEvent)
        followTask = scope.launch {
            try { api.stream("session/follow", o("request" to o("address" to address, "assistantStream" to true, "maxMessages" to 50))).collect(::apply) }
            catch (e: CancellationException) { throw e } catch (e: Exception) { mutable.value = state.value.copy(error = e.message) }
        }
        applyState(api.rpc("session/state", o("request" to o("sessionId" to sessionID))))
    }
    fun stop() { followTask?.cancel(); followTask = null; observer?.let { events?.removeObserver(it) }; observer = null }
    fun applyState(value: J) { mutable.value = state.value.copy(running = value["running"].boolean) }
    fun applyStatusEvent(frame: J) {
        if (frame["type"].text == "ready") scope.launch {
            try { applyState(api.rpc("session/state", o("request" to o("sessionId" to sessionID)))) }
            catch (e: CancellationException) { throw e } catch (e: Exception) { mutable.value = state.value.copy(error = e.message) }
        }
        val args = frame["args"].array
        if (frame["type"].text == "emit" && frame["event"].text == "api-session/status" && args.size > 1 && args[0].text == sessionID)
            mutable.value = state.value.copy(running = args[1].boolean)
    }
    fun apply(frame: J) {
        when (frame["type"].text) {
            "connection-reset" -> {
                attemptID = null; revision = -1; pendingCommitSeq = null
                mutable.value = state.value.copy(inProgress = null, loaded = false)
            }
            "snapshot" -> {
                history.clear(); snapshotCursor = frame["cursor"].int
                frame["records"].array.forEach { record -> record["event"]["seq"].int?.let { history[it] = record["event"] } }
                attemptID = null; pendingCommitSeq = null
                mutable.value = state.value.copy(hasMore = frame["hasMore"].boolean, selectedModel = frame["projections"]["values"]["modelSelection"], inProgress = null)
                val baseline = frame["assistantStream"]
                revision = baseline["revision"].int ?: -1
                val attempt = baseline["activeAttempt"]
                if (attempt != JsonNull) {
                    begin(attempt); nextIndex = attempt["nextIndex"].int ?: 0
                    val blocks = CompactStream.expand(attempt["stream"].array).fold(emptyList<TranscriptBlock>()) { blocks, chunk -> CompactStream.apply(chunk, blocks) }
                    mutable.value = state.value.copy(inProgress = state.value.inProgress?.copy(blocks = blocks))
                }
                mutable.value = state.value.copy(loaded = true); rebuild()
            }
            "event" -> {
                val event = frame["event"]
                event["seq"].int?.let { seq ->
                    history[seq] = event
                    val active = state.value.inProgress
                    if (seq == pendingCommitSeq || (event["type"].text == "assistant/message" && event["data"]["turn"].int == active?.turn && event["data"]["step"].int == active?.step)) {
                        mutable.value = state.value.copy(inProgress = null); pendingCommitSeq = null
                    }
                    rebuild()
                }
            }
            "assistant-stream" -> applyAssistant(frame["frame"])
        }
    }
    private fun begin(frame: J) {
        attemptID = frame["attemptId"].text; nextIndex = 0; pendingCommitSeq = null
        mutable.value = state.value.copy(inProgress = TranscriptItem("attempt:" + frame["attemptId"].text, "assistant", emptyList(),
            inProgress = true, turn = frame["turn"].int, step = frame["step"].int))
    }
    private fun applyAssistant(frame: J) {
        val newRevision = frame["revision"].int?.takeIf { it > revision } ?: return
        revision = newRevision
        when (frame["type"].text) {
            "start" -> begin(frame)
            "chunk" -> {
                if (frame["attemptId"].text != attemptID) return
                val index = frame["index"].int?.takeIf { it >= nextIndex } ?: return
                nextIndex = index + 1
                mutable.value = state.value.copy(inProgress = state.value.inProgress?.let { it.copy(blocks = CompactStream.apply(frame["chunk"], it.blocks)) })
            }
            "end" -> {
                if (frame["attemptId"].text != attemptID) return
                if (frame["outcome"]["kind"].text == "abandoned") { mutable.value = state.value.copy(inProgress = null); attemptID = null }
                else frame["outcome"]["seq"].int?.let { seq ->
                    pendingCommitSeq = seq
                    if (history.containsKey(seq) || frame["outcome"]["eventType"].text == "assistant/attempt") {
                        mutable.value = state.value.copy(inProgress = null); pendingCommitSeq = null
                    }
                }
            }
        }
    }
    fun addOptimistic(text: String, requestID: String) {
        optimistic = optimistic + TranscriptItem("request:$requestID", "user", listOf(TranscriptBlock("text", text)), requestID = requestID, optimistic = true)
        rebuild()
    }
    private fun rebuild() {
        val surface = mutableListOf<J>()
        for (event in history.values) {
            if (event["type"].text !in listOf("user/message", "assistant/message", "tool/result")) continue
            val op = event["surfaceOp"]
            val start = surface.indexOfFirst { it["seq"] == op["startSeq"] }
            val end = surface.indexOfFirst { it["seq"] == op["endSeq"] }
            if (op["op"].text == "replace" && start >= 0 && end >= start) { surface.subList(start, end + 1).clear(); surface.add(start, event) }
            else surface.add(event)
        }
        val committed = history.values.filter { it["type"].text == "user/message" }.mapNotNull { it["data"]["source"]["rpcId"].string }.toSet()
        optimistic = optimistic.filterNot { it.requestID in committed }
        val items = mutableListOf<TranscriptItem>()
        val results = mutableListOf<J>()
        for (event in surface) {
            val type = event["type"].text; val data = event["data"]
            if (type == "tool/result") { results.add(event); continue }
            val message = if (type == "user/message") data else data["message"]
            if (type == "user/message" && message["source"]["kind"].string?.let { it != "user" } == true) continue
            var blocks = message["content"].array.map(::TranscriptBlock)
            if (blocks.isEmpty() && type == "assistant/message") blocks = CompactStream.expand(data["stream"].array).fold(blocks) { acc, chunk -> CompactStream.apply(chunk, acc) }
            items.add(TranscriptItem(message["id"].string ?: "seq:${event["seq"].int ?: 0}", if (type == "user/message") "user" else "assistant", blocks,
                event["seq"].int, message["source"]["rpcId"].string, turn = data["turn"].int, step = data["step"].int))
        }
        for (result in results) {
            val message = result["data"]["message"]; val call = message["toolCallId"].text
            val itemIndex = items.indexOfLast { it.blocks.any { it.kind == "tool-call" && it.callID == call } }
            if (itemIndex >= 0) {
                val item = items[itemIndex]; val blockIndex = item.blocks.indexOfFirst { it.kind == "tool-call" && it.callID == call }
                items[itemIndex] = item.copy(blocks = item.blocks.mapIndexed { index, block -> if (index == blockIndex) block.copy(result = result["data"]) else block })
            } else items.add(TranscriptItem("result:${result["seq"].int ?: 0}", "tool", message["content"].array.map(::TranscriptBlock), result["seq"].int))
        }
        val positions = surface.mapIndexedNotNull { index, event -> event["seq"].int?.let { it to index } }.toMap()
        mutable.value = state.value.copy(transcript = items.sortedBy { positions[it.seq] ?: 0 } + optimistic)
    }
    suspend fun send(text: String, steer: Boolean = false): String {
        if (text.isBlank()) throw PortalError(L("Enter a message.", "请输入消息。"))
        val id = UUID.randomUUID().toString(); addOptimistic(text, id)
        try {
            api.rpc("session/prompt", o("request" to o("sessionId" to sessionID, "requestId" to id, "mode" to if (steer && state.value.running) "steer" else "queue",
                "content" to listOf(o("type" to "text", "text" to text)), "clientTimeZone" to TimeZone.getDefault().id)))
            return id
        } catch (e: Exception) {
            optimistic = optimistic.map { if (it.requestID == id) it.copy(deliveryError = e.message) else it }; rebuild(); throw e
        }
    }
    suspend fun cancel() { api.rpc("session/cancel", o("request" to o("sessionId" to sessionID))) }
    suspend fun loadModels() {
        val value = api.rpc("session/modelCatalog"); mutable.value = state.value.copy(catalog = value)
    }
    suspend fun selectModel(provider: String, model: String, reasoningEffort: String? = null) {
        var request = o("sessionId" to sessionID, "provider" to provider, "model" to model)
        if (reasoningEffort != null) request = request.with("reasoningEffort", reasoningEffort)
        val value = api.rpc("session/selectModel", o("request" to request)); mutable.value = state.value.copy(selectedModel = value)
    }
    suspend fun loadOlder() {
        if (!state.value.hasMore) return
        val before = history.keys.firstOrNull() ?: return; val through = snapshotCursor ?: return
        val page = api.rpc("session/events", o("request" to o("address" to address, "beforeSeq" to before, "throughSeq" to through, "maxMessages" to 50)))
        page["records"].array.forEach { record -> record["event"]["seq"].int?.let { history[it] = record["event"] } }
        mutable.value = state.value.copy(hasMore = page["hasMore"].boolean); rebuild()
    }
}
