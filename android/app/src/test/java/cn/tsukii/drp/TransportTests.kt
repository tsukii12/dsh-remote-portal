package cn.tsukii.drp

import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import okhttp3.Headers
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class TransportTests {
    @get:Rule val temporary = TemporaryFolder()
    @Test fun envelopeErrorsAndPathPrefix() {
        val api = PortalAPI(PortalURL.normalize("https://relay.example/__t/id"), PortalClient(CookieVault(temporary.newFolder())))
        val request = api.request("api/session/list").build()
        assertEquals("https://relay.example/__t/id/api/session/list", request.url.toString()); assertEquals("https://relay.example", request.header("Origin")); assertEquals(PortalClient.USER_AGENT, request.header("User-Agent"))
        val envelope = PortalAPI.envelope("session/list", o("_request" to EMPTY), "id")
        assertEquals(o("_request" to EMPTY), envelope["payload"]["args"]); assertEquals("id", envelope["rpcId"].text)
        assertEquals("local-fake", PortalAPI.decode(fixture("live-model-catalog").toString(), 200)["default"]["provider"].text)
        fails<APIError.SessionExpired> { PortalAPI.decode("", 401) }; assertEquals(APIError.Http(503), fails<APIError.Http> { PortalAPI.decode("", 503) })
        listOf("not json", "{}", """{"type":"server-response","result":{"ok":"true"}}""").forEach { fails<APIError.InvalidResponse> { PortalAPI.decode(it, 200) } }
        val error = parse("""{"type":"server-response","result":{"ok":false,"error":{"code":"model/missing","message":"Select a model"}}}""")
        assertEquals(APIError.Remote("model/missing", "Select a model"), fails<APIError.Remote> { PortalAPI.decode(error.toString(), 200) })
        assertEquals(j(null), PortalAPI.decode("""{"type":"server-response","result":{"ok":true}}""", 200))
    }
    @Test fun cookiesPersistAllNamesAndIsolateBaseIncludingPorts() {
        val root = temporary.newFolder(); val base = "http://localhost:3081/__t/one/".toHttpUrl(); val vault = CookieVault(root)
        fun ingest(name: String, value: String, extra: String = "Max-Age=3600") = vault.ingest(base, base, Headers.headersOf("Set-Cookie", "$name=$value; Path=/; HttpOnly; $extra"))
        ingest("dsh_portal", "portal"); ingest("dsh-auth-demo", "upstream"); ingest("other", "additional")
        val restored = CookieVault(root)
        assertEquals(setOf("dsh_portal", "dsh-auth-demo", "other"), restored.cookies(base, base).map { it.name }.toSet())
        listOf("http://localhost:3082/__t/one/", "http://localhost:3081/__t/two/").forEach { val other = it.toHttpUrl(); assertTrue(restored.cookies(other, other).isEmpty()) }
        ingest("dsh-auth-demo", "renewed"); ingest("other", "", "Max-Age=0")
        val renewed = CookieVault(root).cookies(base, base); assertEquals("renewed", renewed.first { it.name == "dsh-auth-demo" }.value); assertFalse(renewed.any { it.name == "other" })
        vault.clear(base); assertTrue(CookieVault(root).cookies(base, base).isEmpty())
    }
    @Test fun cookiesMatchDomainPathSecureExpiryAndCombinedHeaders() {
        val base = "https://example.com/relay/".toHttpUrl(); val vault = CookieVault(temporary.newFolder())
        vault.ingest(base, base, Headers.headersOf("Set-Cookie", "secure=yes; Secure; Path=/relay; Max-Age=3600, domain=yes; Domain=.example.com; Path=/; Expires=Wed, 01 Jan 2031 00:00:00 GMT",
            "Set-Cookie", "expired=no; Max-Age=0; Path=/", "Set-Cookie", "host=yes; Path=/; Max-Age=3600", "Set-Cookie", "bad=no; Domain=evil.example; Path=/"))
        assertEquals(setOf("secure", "domain", "host"), vault.cookies(base, base).map { it.name }.toSet())
        assertEquals(setOf("domain"), vault.cookies(base, "https://sub.example.com/relay/".toHttpUrl()).map { it.name }.toSet())
        assertEquals(setOf("domain", "host"), vault.cookies(base, "http://example.com/relay/".toHttpUrl()).map { it.name }.toSet())
        assertFalse(vault.cookies(base, "https://example.com/relay-other".toHttpUrl()).any { it.name == "secure" })
    }
    @Test fun loginRPCRefreshCookiesAndExpire() = runTest {
        MockWebServer().use { server ->
            server.start(); val base = server.url("/__t/id/"); val vault = CookieVault(temporary.newFolder()); val api = PortalAPI(base, PortalClient(vault), backgroundScope)
            server.enqueue(MockResponse().setResponseCode(303).addHeader("Location", "/do-not-follow").addHeader("Set-Cookie", "dsh_portal=portal; Path=/; Max-Age=3600").addHeader("Set-Cookie", "dsh-auth-demo=upstream; Path=/; Max-Age=3600"))
            api.login("not-a-real-password")
            val login = server.takeRequest(); assertEquals("/__t/id/__portal/login", login.path); assertEquals("POST", login.method)
            assertEquals(PortalURL.origin(base), login.getHeader("Origin")); assertEquals(PortalClient.USER_AGENT, login.getHeader("User-Agent")); assertEquals(2, vault.cookies(base, base).size)
            server.enqueue(MockResponse().addHeader("Set-Cookie", "dsh-auth-demo=renewed; Path=/; Max-Age=3600").setBody("""{"type":"server-response","result":{"ok":true,"value":{"items":[]}}}"""))
            assertEquals(j(emptyList<J>()), api.rpc("session/list", o("_request" to EMPTY))["items"])
            val rpc = server.takeRequest(); assertEquals("/__t/id/api/session/list", rpc.path); assertTrue(rpc.getHeader("Cookie")!!.contains("dsh-auth-demo=upstream"))
            assertEquals("renewed", vault.cookies(base, base).first { it.name == "dsh-auth-demo" }.value)
            server.enqueue(MockResponse().setResponseCode(401).addHeader("Set-Cookie", "extra=from-error-response; Path=/; Max-Age=3600"))
            fails<APIError.SessionExpired> { api.rpc("session/list") }; assertTrue(api.sessionExpired.value); assertTrue(vault.cookies(base, base).any { it.name == "extra" })
            assertEquals(3, server.requestCount)
        }
    }
    @Test fun modelsAndSidebarActions() = runTest {
        val api = StubAPI(); val chat = ChatStore("S", api, scope = backgroundScope)
        api.response = o("groups" to emptyList<J>()); chat.loadModels(); assertEquals("session/modelCatalog", api.calls.last().first); assertEquals(j(emptyList<J>()), chat.state.value.catalog["groups"])
        api.response = o("selected" to o("provider" to "local-fake", "model" to "native-demo")); chat.selectModel("local-fake", "native-demo", "high")
        assertEquals("high", api.calls.last().second["request"]["reasoningEffort"].text); assertEquals(api.response, chat.state.value.selectedModel)
        val sidebar = SidebarStore(api, backgroundScope); sidebar.applySessions(o("items" to listOf(o("sessionId" to "S"))))
        api.response = o("title" to "Renamed"); sidebar.rename("S", "Renamed"); assertEquals("Renamed", sidebar.state.value.sessions["S"]?.title)
        api.response = o("pinnedSessionIds" to listOf("S")); sidebar.pin("S", true); assertEquals(listOf("S"), sidebar.state.value.pinnedIDs)
        api.response = o("pinnedSessionIds" to emptyList<J>()); sidebar.pin("S", false); assertEquals("workspace/unpinSession", api.calls.last().first); assertTrue(sidebar.state.value.pinnedIDs.isEmpty())
        api.response = o("archivedSessionIds" to listOf("S")); sidebar.archive("S"); assertEquals(listOf("S"), sidebar.state.value.archivedIDs)
        api.failure = APIError.Remote("workspace/session-active", "Still running"); assertEquals("Still running", fails<APIError.Remote> { sidebar.archive("S") }.message); assertEquals(listOf("S"), sidebar.state.value.archivedIDs)
        api.failure = null; api.response = o("sessionId" to "new"); assertEquals("new", sidebar.createSession("W"))
        assertEquals(o("request" to o("agentPreset" to "standard", "workspaceId" to "W")), api.calls[api.calls.lastIndex - 1].second)
    }
}
