package cn.tsukii.drp

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.test.runTest
import okhttp3.*
import okhttp3.mockwebserver.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.concurrent.LinkedBlockingQueue

class ListenerTests {
    @get:Rule val temporary = TemporaryFolder()
    @Test fun gatewayLoginAndPairFailureReasonsOverHTTP() = runTest {
        val generic = L("Sign-in failed. Check your password or pairing code.", "登录失败，请检查密码或配对码。")
        val cases = listOf(
            Triple(401, """{"error":"This pairing code has expired. Generate a new one.","message":"wrong field"}""", "This pairing code has expired. Generate a new one."),
            Triple(403, """{"error":"Password login is disabled."}""", "Password login is disabled."),
            Triple(401, """{"error":"配对码无效或已被使用。"}""", "配对码无效或已被使用。"),
            Triple(401, """{"message":"Legacy reason"}""", "Legacy reason"),
            Triple(401, """{"error":"  "}""", generic), Triple(500, "not JSON", generic), Triple(401, """{"error":123}""", generic),
            Triple(429, "{}", L("Too many attempts. Try again after 3 seconds.", "尝试次数过多，请稍后重试（3秒）。")))
        MockWebServer().use { server ->
            server.start(); val base = server.url("/__t/test/"); val api = PortalAPI(base, PortalClient(CookieVault(temporary.newFolder())), backgroundScope)
            cases.forEachIndexed { index, (status, body, expected) ->
                server.enqueue(MockResponse().setResponseCode(status).setHeader("Retry-After", "3").setBody(body))
                val pairing = index % 2 == 0
                assertEquals(expected, fails<PortalError> { api.login("secret", pairing) }.message)
                val request = server.takeRequest()
                assertEquals("/__t/test/__portal/login", request.path); assertEquals("POST", request.method)
                assertEquals(PortalClient.USER_AGENT, request.getHeader("User-Agent")); assertEquals(PortalURL.origin(base), request.getHeader("Origin")); assertEquals(L("en", "zh"), request.getHeader("Accept-Language"))
                assertEquals(if (pairing) "token=secret" else "password=secret", request.body.readUtf8())
            }
        }
    }
    @Test fun logoutClearsOnlySelectedPersistedJarAndExpiresStreams() = runTest {
        for (status in listOf(303, 204)) MockWebServer().use { server ->
            server.start(); val root = temporary.newFolder(); val client = PortalClient(CookieVault(root)); val base = server.url("/selected/"); val other = server.url("/other/")
            val api = PortalAPI(base, client, backgroundScope)
            repeat(2) { server.enqueue(MockResponse().setResponseCode(303).addHeader("Location", "/should-not-follow")
                .addHeader("Set-Cookie", "dsh_portal=test; Path=/; Max-Age=3600, dsh-auth-demo=upstream; Path=/; Max-Age=3600")) }
            api.login("secret"); PortalAPI(other, client, backgroundScope).login("secret", true)
            assertEquals(2, CookieVault(root).cookies(base, base).size)
            server.enqueue(MockResponse().setResponseCode(status).addHeader("Location", "/should-not-follow"))
            api.logout()
            fails<APIError.SessionExpired> { api.stream("\$events").collect() }
            assertTrue(api.sessionExpired.value); assertTrue(client.cookies.cookies(base, base).isEmpty())
            assertTrue(CookieVault(root).cookies(base, base).isEmpty()); assertEquals(setOf("dsh_portal", "dsh-auth-demo"), CookieVault(root).cookies(other, other).map { it.name }.toSet())
            server.takeRequest(); server.takeRequest(); val logout = server.takeRequest()
            assertEquals("/selected/__portal/logout", logout.path); assertEquals("POST", logout.method); assertTrue(logout.getHeader("Cookie")!!.contains("dsh_portal=test")); assertEquals(3, server.requestCount)
        }
    }
    @Test fun failedLogoutPreservesSessionAndCookies() = runTest {
        MockWebServer().use { server ->
            server.start(); val root = temporary.newFolder(); val base = server.url("/"); val api = PortalAPI(base, PortalClient(CookieVault(root)), backgroundScope)
            server.enqueue(MockResponse().setResponseCode(303).addHeader("Set-Cookie", "dsh_portal=test; Path=/; Max-Age=3600")); api.login("secret")
            server.enqueue(MockResponse().setResponseCode(500).setBody("{}"))
            assertEquals(L("Sign-out failed. Please try again.", "退出登录失败，请重试。"), fails<PortalError> { api.logout() }.message)
            assertFalse(api.sessionExpired.value); assertEquals(1, CookieVault(root).cookies(base, base).size)
        }
    }
    @Test fun approvalLoaderFailureEmptyRetryAndRejectOverHTTP() = runTest {
        MockWebServer().use { server ->
            server.start(); val api = PortalAPI(server.url("/relay/"), PortalClient(CookieVault(temporary.newFolder())), backgroundScope)
            val item = PendingInteraction("E", "client", "S", "approval/request", o("toolName" to "bash", "callId" to "C")); val loader = ApprovalInputLoader(api, item)
            val records = listOf(o("event" to o("type" to "tool/call", "data" to o("callId" to "wrong", "arguments" to "{\"command\":\"wrong\"}"))),
                o("event" to o("type" to "tool/call", "data" to o("callId" to "C", "arguments" to "{\"command\":\"pwd\"}"))))
            fun page(rows: List<J>) = MockResponse().setBody(o("type" to "server-response", "result" to o("ok" to true, "value" to o("records" to rows))).toString())
            server.enqueue(MockResponse().setResponseCode(503)); server.enqueue(page(emptyList())); server.enqueue(page(records)); server.enqueue(MockResponse().setResponseCode(503))
            repeat(2) { loader.load(); assertFalse(loader.state.value.isLoading); assertFalse(loader.state.value.canAllow); assertNull(loader.state.value.input); assertNotNull(loader.state.value.error) }
            loader.load(); assertEquals("pwd", loader.state.value.input); assertTrue(loader.state.value.canAllow); assertNull(loader.state.value.error)
            loader.load(); assertNull(loader.state.value.input); assertFalse(loader.state.value.canAllow)
            repeat(4) {
                val request = server.takeRequest(); val body = parse(request.body.readUtf8())
                assertEquals("/relay/api/session/events", request.path); assertEquals("POST", request.method); assertEquals("client-request", body["type"].text); assertEquals("session/events", body["method"].text); assertFalse(body["rpcId"].text.isEmpty())
                assertEquals(o("request" to o("address" to o("kind" to "session", "sessionId" to "S"), "maxMessages" to 50)), body["payload"]["args"])
            }
            server.enqueue(MockResponse().setBody("""{"type":"server-response","result":{"ok":true}}"""))
            val events = RemoteEvents(api, backgroundScope); events.apply(o("type" to "ready", "clientId" to "client")); events.apply(o("type" to "waterfall", "event" to item.kind, "eventId" to "E", "agentId" to "S", "request" to item.request))
            events.answerApproval("E", false); assertTrue(events.state.value.pending.isEmpty())
            val answer = server.takeRequest(); assertEquals("/relay/api/\$events/result", answer.path); assertEquals(j("rejected"), parse(answer.body.readUtf8())["payload"]["args"]["outcome"]["value"])
            server.enqueue(page(records)); loader.load(); assertTrue(loader.state.value.canAllow); assertEquals("pwd", loader.state.value.input); assertNull(loader.state.value.error)
        }
    }
    @Test fun healthRequestHasFixedHeadersAndOnly200Wins() = runBlocking {
        MockWebServer().use { bad -> MockWebServer().use { good ->
            bad.start(); good.start(); bad.enqueue(MockResponse().setResponseCode(503)); good.enqueue(MockResponse().setResponseCode(200))
            val client = PortalClient(CookieVault(temporary.newFolder())); val result = client.connect(listOf(bad.url("/prefix/"), good.url("/relay/")))
            assertEquals(good.port, result.base.port)
            val request = good.takeRequest(); assertEquals("/relay/__portal/health", request.path); assertEquals(PortalClient.USER_AGENT, request.getHeader("User-Agent")); assertEquals(PortalURL.origin(good.url("/")), request.getHeader("Origin"))
            assertTrue(request.getHeader("Cache-Control")!!.contains("no-cache"))
        } }
    }
    private suspend fun <T> LinkedBlockingQueue<T>.next(): T = withTimeout(8000) {
        var value = poll()
        while (value == null) { delay(10); value = poll() }
        value
    }
    @Test fun muxMultiplexesFramesEndsErrorsAndCancels() = runBlocking {
        MockWebServer().use { server ->
            val frames = LinkedBlockingQueue<J>(); val sockets = LinkedBlockingQueue<WebSocket>()
            server.enqueue(MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) { sockets.add(webSocket) }
                override fun onMessage(webSocket: WebSocket, text: String) { frames.add(parse(text)) }
                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(code, reason) }
            })); server.start()
            val api = PortalAPI(server.url("/relay/"), PortalClient(CookieVault(temporary.newFolder())), this)
            val got = LinkedBlockingQueue<J>()
            val first = launch { api.stream("session/follow", o("request" to o("sessionId" to "S"))).collect { got.add(it) } }
            val second = launch { api.stream("\$events").collect { got.add(it) } }
            try {
                val ws = sockets.next(); val opens = listOf(frames.next(), frames.next()); assertTrue(opens.all { it["type"].text == "open" })
                val follow = opens.first { it["endpoint"].text == "session/follow" }; val events = opens.first { it["endpoint"].text == "\$events" }
                assertEquals(o("request" to o("sessionId" to "S")), follow["payload"]["args"])
                ws.send(o("type" to "item", "streamId" to follow["streamId"], "value" to o("type" to "snapshot")).toString())
                assertEquals("snapshot", got.next()["type"].text)
                api.mux.sendItem(j("input"), follow["streamId"].text); assertEquals("item", frames.next()["type"].text)
                api.mux.endInput(follow["streamId"].text); assertEquals("end", frames.next()["type"].text)
                ws.send(o("type" to "end", "streamId" to follow["streamId"]).toString()); withTimeout(8000) { first.join() }
                second.cancelAndJoin(); val cancel = frames.next(); assertEquals("cancel", cancel["type"].text); assertEquals(events["streamId"], cancel["streamId"])
                val request = server.takeRequest(); assertEquals("/relay/api/remote.mux", request.path); assertEquals(PortalClient.USER_AGENT, request.getHeader("User-Agent")); assertEquals(PortalURL.origin(api.base), request.getHeader("Origin")); assertEquals(1, server.requestCount)
            } finally { first.cancelAndJoin(); second.cancelAndJoin(); api.mux.close() }
        }
    }
    @Test fun muxReconnectsReopensAndInjectsReset() = runBlocking {
        MockWebServer().use { server ->
            val frames = LinkedBlockingQueue<J>(); val sockets = LinkedBlockingQueue<WebSocket>()
            fun upgrade() = MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) { sockets.add(webSocket) }
                override fun onMessage(webSocket: WebSocket, text: String) { frames.add(parse(text)) }
                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(code, reason) }
            })
            server.enqueue(upgrade()); server.enqueue(upgrade()); server.start()
            val api = PortalAPI(server.url("/"), PortalClient(CookieVault(temporary.newFolder())), this); val got = LinkedBlockingQueue<J>()
            val reader = launch { api.stream("\$events").collect { got.add(it) } }
            try {
                sockets.next(); val first = frames.next(); api.mux.reconnect(); assertEquals("connection-reset", got.next()["type"].text)
                val socket = sockets.next(); val reopened = frames.next(); assertEquals(first, reopened)
                socket.send(o("type" to "item", "streamId" to reopened["streamId"], "value" to o("type" to "ready", "clientId" to "new")).toString())
                assertEquals("new", got.next()["clientId"].text); assertEquals(2, server.requestCount)
            } finally { reader.cancelAndJoin(); api.mux.close() }
        }
    }
    @Test fun mux401ExpiresAndBusinessErrorFinishesOnlyItsStream() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(401).addHeader("Set-Cookie", "extra=error; Path=/; Max-Age=3600")); server.start()
            val api = PortalAPI(server.url("/"), PortalClient(CookieVault(temporary.newFolder())), this)
            fails<APIError.SessionExpired> { withTimeout(8000) { api.stream("\$events").collect() } }
            assertTrue(api.sessionExpired.value); assertEquals("error", api.client.cookies.cookies(api.base, api.base).single().value)
        }
        MockWebServer().use { server ->
            server.enqueue(MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
                override fun onMessage(webSocket: WebSocket, text: String) {
                    val frame = parse(text); webSocket.send(o("type" to "error", "streamId" to frame["streamId"], "error" to o("code" to "denied", "message" to "No")).toString())
                }
                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(code, reason) }
            })); server.start()
            val api = PortalAPI(server.url("/"), PortalClient(CookieVault(temporary.newFolder())), this)
            assertEquals(APIError.Remote("denied", "No"), fails<APIError.Remote> { withTimeout(8000) { api.stream("bad").collect() } }); assertFalse(api.sessionExpired.value)
        }
    }
}
