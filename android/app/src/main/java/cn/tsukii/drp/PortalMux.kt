package cn.tsukii.drp

import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.receiveAsFlow
import okhttp3.*
import okio.ByteString
import java.util.UUID

class PortalMux(private val api: PortalAPI, private val scope: CoroutineScope) {
    private data class Subscription(val endpoint: String, val args: J, val channel: Channel<J>, val ready: CompletableDeferred<Int>? = null)
    private val subscriptions = linkedMapOf<String, Subscription>()
    private var socket: WebSocket? = null
    private var retry: Job? = null
    private var generation = 0
    private var failures = 0
    private var connected = false
    private val opened = mutableSetOf<String>()

    inner class DuplexStream internal constructor(private val id: String, private val token: Int, private val channel: Channel<J>, private val maxFrameBytes: Long) {
        val frames: Flow<J> = channel.receiveAsFlow()
        private var inputEnded = false
        suspend fun send(value: J) = input(o("type" to "item", "streamId" to id, "value" to value))
        suspend fun endInput() {
            input(o("type" to "end", "streamId" to id))
        }
        private suspend fun input(frame: J) = withContext(scope.coroutineContext.minusKey(Job)) {
            if (token != generation || id !in opened || id !in subscriptions || inputEnded) throw APIError.Disconnected
            val text = frame.toString()
            val bytes = text.toByteArray(Charsets.UTF_8).size.toLong()
            if (bytes > maxFrameBytes || (socket?.queueSize() ?: 0) + bytes > 1024 * 1024) throw APIError.Disconnected
            this@PortalMux.send(frame)
            if (frame["type"].text == "end") inputEnded = true
        }
        suspend fun close() = withContext(NonCancellable + scope.coroutineContext.minusKey(Job)) { unsubscribe(id) }
    }
    suspend fun openDuplex(endpoint: String, args: J = EMPTY, maxFrameBytes: Long = 262144): DuplexStream {
        require(maxFrameBytes > 0)
        val id = UUID.randomUUID().toString()
        val ready = CompletableDeferred<Int>()
        val channel = Channel<J>(64)
        try {
            withContext(scope.coroutineContext.minusKey(Job)) {
                if (api.sessionExpired.value) throw APIError.SessionExpired
                subscriptions[id] = Subscription(endpoint, args, channel, ready)
                if (socket == null && retry == null) connect() else if (connected) sendOpen(id)
            }
            return DuplexStream(id, ready.await(), channel, maxFrameBytes)
        } catch (e: Throwable) {
            withContext(NonCancellable + scope.coroutineContext.minusKey(Job)) { unsubscribe(id) }
            throw e
        }
    }

    fun open(endpoint: String, args: J = EMPTY): Flow<J> = flow {
        val id = UUID.randomUUID().toString()
        val channel = Channel<J>(Channel.UNLIMITED)
        withContext(scope.coroutineContext) {
            if (api.sessionExpired.value) channel.close(APIError.SessionExpired)
            else {
                subscriptions[id] = Subscription(endpoint, args, channel)
                if (socket == null && retry == null) connect() else if (connected) sendOpen(id)
            }
        }
        try { for (frame in channel) emit(frame) }
        finally { withContext(NonCancellable + scope.coroutineContext.minusKey(Job)) { unsubscribe(id) } }
    }
    private fun unsubscribe(id: String) {
        val sub = subscriptions.remove(id) ?: return
        sub.ready?.completeExceptionally(APIError.Disconnected)
        sub.channel.close()
        opened.remove(id)
        socket?.send(o("type" to "cancel", "streamId" to id).toString())
        if (subscriptions.isEmpty()) { failures = 0; disconnect(graceful = true) }
    }
    private fun disconnect(graceful: Boolean = false) {
        generation++; retry?.cancel(); retry = null
        if (graceful) socket?.close(1000, null) else socket?.cancel()
        socket = null; connected = false; opened.clear()
    }
    fun close() {
        disconnect(); failures = 0
        val old = subscriptions.values.toList(); subscriptions.clear()
        old.forEach { it.ready?.completeExceptionally(APIError.SessionExpired); it.channel.close(APIError.SessionExpired) }
    }
    fun reconnect() { if (subscriptions.isNotEmpty()) failed(generation, null) }
    private fun send(frame: J) {
        if (!connected || socket?.send(frame.toString()) != true) throw APIError.Disconnected
    }
    private fun sendOpen(id: String) {
        val sub = subscriptions[id] ?: return
        if (opened.add(id)) {
            send(o("type" to "open", "streamId" to id, "endpoint" to sub.endpoint, "payload" to o("args" to sub.args)))
            sub.ready?.complete(generation)
        }
    }
    private fun connect() {
        val token = ++generation
        connected = false; opened.clear()
        val request = api.request("api/remote.mux").build()
        socket = api.client.http.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) { scope.launch {
                if (token != generation) return@launch
                try {
                    api.client.cookies.ingest(response, api.base)
                    connected = true
                    subscriptions.keys.toList().forEach(::sendOpen)
                } catch (_: Exception) { failed(token, response) }
            } }
            override fun onMessage(webSocket: WebSocket, text: String) { scope.launch { receive(token, text) } }
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) { onMessage(webSocket, bytes.utf8()) }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) { scope.launch { failed(token, response) } }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(code, reason) }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { scope.launch { failed(token, null) } }
        })
    }
    private fun receive(token: Int, text: String) {
        if (token != generation) return
        val frame = try { parse(text) } catch (_: Exception) { failed(token, null); return }
        failures = 0
        val id = frame["streamId"].text
        val sub = subscriptions[id] ?: return
        when (frame["type"].text) {
            "item" -> if (sub.channel.trySend(frame["value"]).isFailure && sub.ready != null) {
                sub.channel.close(APIError.Disconnected); unsubscribe(id)
            }
            "end", "error" -> {
                subscriptions.remove(id); opened.remove(id)
                val error = if (frame["type"].text == "error") APIError.Remote(frame["error"]["code"].text, frame["error"]["message"].text) else null
                sub.ready?.completeExceptionally(error ?: APIError.Disconnected)
                sub.channel.close(error)
                if (subscriptions.isEmpty()) { failures = 0; disconnect(graceful = true) }
            }
        }
    }
    private fun failed(token: Int, response: Response?) {
        if (token != generation) return
        if (response != null) {
            try { api.client.cookies.ingest(response, api.base) } catch (_: Exception) { }
        }
        if (response?.code == 401) { api.expire(); return }
        disconnect()
        subscriptions.filterValues { it.ready != null }.keys.toList().forEach { id ->
            subscriptions.remove(id)?.let { it.ready?.completeExceptionally(APIError.Disconnected); it.channel.close(APIError.Disconnected) }
        }
        subscriptions.values.forEach { it.channel.trySend(o("type" to "connection-reset")) }
        if (subscriptions.isEmpty()) return
        val delaySeconds = minOf(30, 1 shl minOf(failures++, 5))
        retry = scope.launch {
            delay(delaySeconds * 1000L); retry = null
            if (subscriptions.isNotEmpty()) connect()
        }
    }
}
