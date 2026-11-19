package cn.tsukii.drp

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.util.UUID

data class PendingInteraction(val id: String, val clientID: String, val agentID: String, val kind: String, val request: J)
data class RemoteEventsState(val clientID: String? = null, val pending: List<PendingInteraction> = emptyList(), val error: String? = null)
class RemoteEvents(private val api: RPCServing, private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)) {
    private val mutable = MutableStateFlow(RemoteEventsState())
    val state = mutable.asStateFlow()
    private var task: Job? = null
    private val listeners = linkedMapOf<String, (J) -> Unit>()
    private val resolved = mutableSetOf<String>()
    fun observe(handler: (J) -> Unit): String = UUID.randomUUID().toString().also { listeners[it] = handler }
    fun removeObserver(id: String) { listeners.remove(id) }
    fun apply(frame: J) {
        val s = state.value
        mutable.value = when (frame["type"].text) {
            "ready" -> s.copy(clientID = frame["clientId"].string, pending = emptyList())
            "connection-reset" -> s.copy(clientID = null, pending = emptyList())
            "cancel" -> { resolved += frame["eventId"].text; s.copy(pending = s.pending.filterNot { it.id == frame["eventId"].text }) }
            "waterfall" -> if (s.clientID != null && frame["eventId"].text !in resolved && frame["event"].text in listOf("approval/request", "user-questions/request")) {
                val item = PendingInteraction(frame["eventId"].text, s.clientID, frame["agentId"].text, frame["event"].text, frame["request"])
                s.copy(pending = s.pending.filterNot { it.id == item.id } + item)
            } else s
            else -> s
        }
        listeners.values.toList().forEach { it(frame) }
    }
    fun start() {
        if (task != null) return
        task = scope.launch {
            try { api.stream("\$events").collect(::apply) }
            catch (e: CancellationException) { throw e }
            catch (e: Exception) { apply(o("type" to "connection-reset")); mutable.value = state.value.copy(error = e.message) }
        }
    }
    fun stop() { task?.cancel(); task = null; apply(o("type" to "connection-reset")) }
    suspend fun answerApproval(id: String, allow: Boolean) { answer(id, j(if (allow) "allowed-once" else "rejected")) }
    suspend fun answerQuestions(id: String, answers: List<J>) { answer(id, o("answers" to answers)) }
    private suspend fun answer(id: String, value: J) {
        val clientID = state.value.clientID ?: throw APIError.Disconnected
        val item = state.value.pending.find { it.id == id && it.clientID == clientID } ?: throw APIError.Disconnected
        api.rpc("\$events/result", o("clientId" to clientID, "eventId" to item.id, "outcome" to o("kind" to "result", "value" to value)))
        resolved += id
        mutable.value = state.value.copy(pending = state.value.pending.filterNot { it.id == id })
    }
}

class NativeConnection(val api: PortalAPI, private val scope: CoroutineScope = api.scope) {
    val sidebar = SidebarStore(api, scope)
    val events = RemoteEvents(api, scope)
    private val mutableError = MutableStateFlow<String?>(null)
    val error = mutableError.asStateFlow()
    private var observer: String? = null
    suspend fun start() {
        sidebar.refresh(); sidebar.start()
        if (observer == null) observer = events.observe { frame ->
            sidebar.applyEvent(frame)
            if (frame["type"].text == "ready") scope.launch {
                try { sidebar.refresh() } catch (e: CancellationException) { throw e } catch (e: Exception) { mutableError.value = e.message }
            }
        }
        events.start()
    }
    fun stop() { sidebar.stop(); events.stop(); observer?.let(events::removeObserver); observer = null; api.mux.close() }
    fun chat(sessionID: String) = ChatStore(sessionID, api, events, scope)
}
