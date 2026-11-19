package cn.tsukii.drp

import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import okhttp3.*
import okio.ByteString
import java.util.UUID

class PortalMux(private val api: PortalAPI, private val scope: CoroutineScope) {
    private data class Subscription(val endpoint: String, val args: J, val channel: Channel<J>)
    private val subscriptions = linkedMapOf<String, Subscription>()
    private var socket: WebSocket? = null
    private var retry: Job? = null
    private var generation = 0
    private var failures = 0
    private var connected = false
    private val opened = mutableSetOf<String>()

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
        if (subscriptions.remove(id) == null) return
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
        old.forEach { it.channel.close(APIError.SessionExpired) }
    }
    fun reconnect() { if (subscriptions.isNotEmpty()) failed(generation, null) }
    fun sendItem(value: J, streamId: String) = send(o("type" to "item", "streamId" to streamId, "value" to value))
    fun endInput(streamId: String) = send(o("type" to "end", "streamId" to streamId))
    private fun send(frame: J) {
        if (!connected || socket?.send(frame.toString()) != true) throw APIError.Disconnected
    }
    private fun sendOpen(id: String) {
        val sub = subscriptions[id] ?: return
        if (opened.add(id)) send(o("type" to "open", "streamId" to id, "endpoint" to sub.endpoint, "payload" to o("args" to sub.args)))
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
            "item" -> sub.channel.trySend(frame["value"])
            "end", "error" -> {
                subscriptions.remove(id); opened.remove(id)
                sub.channel.close(if (frame["type"].text == "error") APIError.Remote(frame["error"]["code"].text, frame["error"]["message"].text) else null)
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
        subscriptions.values.forEach { it.channel.trySend(o("type" to "connection-reset")) }
        if (subscriptions.isEmpty()) return
        val delaySeconds = minOf(30, 1 shl minOf(failures++, 5))
        retry = scope.launch {
            delay(delaySeconds * 1000L); retry = null
            if (subscriptions.isNotEmpty()) connect()
        }
    }
}
