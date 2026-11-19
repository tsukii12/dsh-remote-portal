package cn.tsukii.drp

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collect
import okhttp3.*
import okhttp3.ResponseBody.Companion.toResponseBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.concurrent.LinkedBlockingQueue

class TransportGroundworkTests {
    @get:Rule val temporary = TemporaryFolder()
    private val metadata = o("type" to "server-response", "result" to o("ok" to true, "value" to o("data" to null)), "attachments" to listOf(o("path" to listOf("data"), "codec" to "bytes", "part" to "bytes-0"))).toString()
    private fun multipart(vararg parts: Pair<String, ByteArray>): Pair<MediaType, Buffer> {
        val body = MultipartBody.Builder("test-boundary").setType(MultipartBody.FORM).apply {
            parts.forEach { (name, bytes) -> addFormDataPart(name, null, bytes.toRequestBody()) }
        }.build()
        return body.contentType() to Buffer().apply { body.writeTo(this) }
    }
    private fun decode(vararg parts: Pair<String, ByteArray>): BinaryRPCResult {
        val (type, body) = multipart(*parts)
        return Response.Builder().request(Request.Builder().url("http://localhost/").build()).protocol(Protocol.HTTP_1_1).code(200).message("OK")
            .body(body.readByteArray().toResponseBody(type)).build().use(PortalAPI::decodeResponse)
    }
    @Test fun multipartPreservesExactBinaryBytesIncludingEmptyData() {
        val bytes = byteArrayOf(0, -1, 13, 10, 64)
        val result = decode("bytes-0" to bytes, "metadata" to metadata.toByteArray())
        assertArrayEquals(bytes, result.bytes("data")); assertEquals(j(null), result.value["data"])
        assertArrayEquals(byteArrayOf(), decode("metadata" to metadata.toByteArray(), "bytes-0" to byteArrayOf()).bytes("data"))
    }
    @Test fun malformedMultipartRejectsMissingDuplicateAndUnexpectedParts() {
        val m = "metadata" to metadata.toByteArray(); val b = "bytes-0" to byteArrayOf(1)
        listOf(arrayOf(b), arrayOf(m), arrayOf(m, m, b), arrayOf(m, b, b), arrayOf(m, b, "unused" to byteArrayOf(2)),
            arrayOf("metadata" to metadata.replace("\"bytes\"", "\"unknown\"").toByteArray(), b),
            arrayOf("metadata" to metadata.replace("\"data\":null", "\"data\":1").toByteArray(), b),
            arrayOf("metadata" to "not-json".toByteArray(), b)
        ).forEach { parts -> fails<APIError.InvalidResponse> { decode(*parts) } }
        val duplicatePath = parse(metadata).with("attachments", listOf(parse(metadata)["attachments"].array.single(), parse(metadata)["attachments"].array.single()))
        fails<APIError.InvalidResponse> { decode("metadata" to duplicatePath.toString().toByteArray(), b) }
    }
    @Test fun binaryRPCUsesTheRealHttpDecoderAndNonJsonErrorsKeepTheirStatus() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            val api = PortalAPI(server.url("/relay/"), PortalClient(CookieVault(temporary.newFolder())), this)
            val (type, body) = multipart("metadata" to metadata.toByteArray(), "bytes-0" to byteArrayOf(65))
            server.enqueue(MockResponse().addHeader("Content-Type", type).setBody(body))
            assertArrayEquals(byteArrayOf(65), api.rpcBinary("workspaceFiles/readBytes").bytes("data"))
            assertEquals("/relay/api/workspaceFiles/readBytes", server.takeRequest().path)
            server.enqueue(MockResponse().setResponseCode(502).setBody("<html>Bad gateway</html>"))
            assertEquals(APIError.Http(502), fails<APIError.Http> { api.rpcBinary("bad") })
            server.enqueue(MockResponse().setBody("not JSON"))
            fails<APIError.InvalidResponse> { api.rpc("bad") }
            server.enqueue(MockResponse().setResponseCode(401).setBody("Login"))
            fails<APIError.SessionExpired> { api.rpcBinary("bad") }; assertTrue(api.sessionExpired.value)
        }
    }
    private suspend fun <T> LinkedBlockingQueue<T>.next(): T = withTimeout(8000) {
        var value = poll()
        while (value == null) { delay(10); value = poll() }
        value
    }
    @Test fun duplexDiesWithItsGenerationNeverReopensOrReplaysWhileChatReopens() = runBlocking {
        MockWebServer().use { server ->
            val frames = LinkedBlockingQueue<J>(); val sockets = LinkedBlockingQueue<WebSocket>()
            fun upgrade() = MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) { sockets.add(webSocket) }
                override fun onMessage(webSocket: WebSocket, text: String) { frames.add(parse(text)) }
                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(code, reason) }
            })
            server.enqueue(upgrade()); server.enqueue(upgrade()); server.start()
            val api = PortalAPI(server.url("/"), PortalClient(CookieVault(temporary.newFolder())), this)
            val chatFrames = LinkedBlockingQueue<J>()
            val chat = launch { api.stream("session/control").collect { chatFrames.add(it) } }
            var duplex: PortalMux.DuplexStream? = null
            try {
                sockets.next(); val chatOpen = frames.next()
                duplex = api.mux.openDuplex("terminal/attach", o("agentId" to "S", "id" to "T"))
                val terminalOpen = frames.next()
                duplex.send(o("type" to "write", "sequence" to 1, "data" to "once\n"))
                assertEquals("once\n", frames.next()["value"]["data"].text)
                api.mux.reconnect()
                assertEquals("connection-reset", chatFrames.next()["type"].text)
                fails<APIError.Disconnected> { duplex.send(j("offline")) }
                fails<APIError.Disconnected> { duplex.frames.collect() }
                sockets.next(); assertEquals(chatOpen, frames.next())
                fails<APIError.Disconnected> { duplex.send(j("stale generation")) }
                val fresh = api.mux.openDuplex("terminal/attach", o("agentId" to "S", "id" to "T"), maxFrameBytes = 1024)
                try {
                    val freshOpen = frames.next()
                    assertNotEquals(terminalOpen["streamId"], freshOpen["streamId"])
                    fails<APIError.Disconnected> { fresh.send(j("x".repeat(2048))) }
                    fresh.send(j("new input")); assertEquals(j("new input"), frames.next()["value"])
                    fresh.endInput(); assertEquals("end", frames.next()["type"].text)
                    fails<APIError.Disconnected> { fresh.send(j("after half close")) }
                    assertNull(frames.poll())
                } finally { fresh.close() }
            } finally { duplex?.close(); chat.cancelAndJoin(); api.mux.close() }
        }
    }
}
