package cn.tsukii.drp

import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import okhttp3.mockwebserver.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.concurrent.CopyOnWriteArrayList

@OptIn(ExperimentalCoroutinesApi::class)
class NativeControlsTests {
    @get:Rule val temporary = TemporaryFolder()
    private val catalog = parse("""{"default":{"provider":"fake","model":"one","reasoningEffort":"high"},"groups":[{"id":"fake","name":"Fake","models":[{"id":"one","name":"One","reasoning":{"efforts":[{"id":"off","name":"Off"},{"id":"high","name":"High"}]}},{"id":"two","name":"Two","reasoning":{"defaultEffort":"off"}}]}]}""")
    private fun ok(value: J) = MockResponse().setBody(o("type" to "server-response", "result" to o("ok" to true, "value" to value)).toString())

    @Test fun planOptionsRequireAnUnstartedSessionWithoutPendingChanges() {
        val state = ChatState(commands = listOf(o("name" to "plan")))
        assertFalse(ChatState().canChangePlan)
        assertTrue(state.canChangePlan)
        assertTrue(state.copy(projections = parse("""{"sessionListMetadata":{"blank":true},"plan":{"active":true}}""")).canChangePlan)
        assertFalse(state.copy(projections = parse("""{"plan":{"pending":true}}""")).canChangePlan)
        assertFalse(state.copy(projections = parse("""{"sessionListMetadata":{"blank":false}}""")).canChangePlan)
        assertFalse(state.copy(running = true).canChangePlan)
    }

    @Test fun planToggleUsesAdvertisedCommandAndRefreshesOnAndOffOverHTTP() = runTest {
        MockWebServer().use { server ->
            server.start()
            val api = PortalAPI(server.url("/relay/"), PortalClient(CookieVault(temporary.newFolder())), backgroundScope)
            val chat = ChatStore("S", api)
            fun metadata(commands: List<J>) {
                server.enqueue(ok(EMPTY)); server.enqueue(ok(EMPTY)); server.enqueue(ok(j(commands)))
                server.enqueue(ok(o("asOfSeq" to 1, "values" to o("sessionListMetadata" to o("blank" to true)))))
            }
            metadata(listOf(o("name" to "permission")))
            chat.loadControls()
            repeat(4) { server.takeRequest() }
            assertFalse(chat.state.value.supportsPlanMode)
            assertFalse(chat.state.value.canChangePlan)
            val before = server.requestCount
            assertEquals("Plan mode is not available for this agent preset.", fails<PortalError> { chat.togglePlan() }.message)
            assertEquals(before, server.requestCount)
            metadata(listOf(o("name" to "plan")))
            chat.loadControls()
            repeat(4) { server.takeRequest() }
            assertTrue(chat.state.value.canChangePlan)
            for ((index, line) in listOf("/plan", "/plan off").withIndex()) {
                server.enqueue(ok(o("commandId" to "C", "result" to o("kind" to "success", "text" to "Changed"))))
                server.enqueue(ok(o("asOfSeq" to index + 2, "values" to o("plan" to o("active" to (index == 0), "pending" to false)))))
                chat.togglePlan()
                val command = server.takeRequest()
                assertEquals("/relay/api/commands/execute", command.path)
                assertEquals(o("agentId" to "S", "line" to line, "submittedAttachments" to emptyList<J>()), parse(command.body.readUtf8())["payload"]["args"])
                assertEquals("/relay/api/session/projections", server.takeRequest().path)
                assertEquals(index == 0, chat.state.value.planEnabled)
            }
            chat.applyProjections(o("asOfSeq" to 4, "values" to o("plan" to o("pending" to true))))
            fails<PortalError> { chat.togglePlan() }
            chat.applyProjections(o("asOfSeq" to 5, "values" to o("sessionListMetadata" to o("blank" to false))))
            fails<PortalError> { chat.togglePlan() }
            assertEquals(12, server.requestCount)
        }
    }

    @Test fun firstOptimisticMessageLocksPlanAndPresetWithoutAnRpc() = runTest {
        val api = StubAPI(); val chat = ChatStore("S", api)
        assertFalse(chat.state.value.sessionStarted)
        chat.addOptimistic("first message", "R")
        assertTrue(chat.state.value.sessionStarted)
        assertFalse(chat.state.value.canChangePlan)
        fails<PortalError> { chat.selectPreset("minimal") }
        assertTrue(api.calls.isEmpty())
    }

    @Test fun sidebarWaitsForWorkspaceBaselineAndWaitsAgainAfterReset() {
        val store = SidebarStore(StubAPI())
        assertFalse(store.state.value.loaded)
        assertTrue(store.state.value.displayGroups.isEmpty())
        store.applySessions(parse("""{"items":[{"sessionId":"S","projections":{"values":{"title":"First"}}}]}"""))
        assertTrue(store.state.value.displayGroups.isEmpty())
        store.applyWorkspace(parse("""{"type":"upsert","workspace":{"workspaceId":"W","title":"Work","sessionIds":["S"]}}"""))
        assertTrue(store.state.value.displayGroups.isEmpty())
        val baseline = parse("""{"type":"baseline","value":{"items":[{"workspaceId":"W","title":"Work","sessionIds":["S"]}]}}""")
        store.applyWorkspace(baseline)
        assertTrue(store.state.value.loaded)
        assertEquals(listOf("S"), store.state.value.displayGroups.single { it.id == "W" }.sessions.map { it.id })
        assertTrue(store.state.value.displayGroups.single { it.id == "ungrouped" }.sessions.isEmpty())
        store.applyWorkspace(o("type" to "connection-reset"))
        assertFalse(store.state.value.loaded)
        assertTrue(store.state.value.displayGroups.isEmpty())
        store.applyWorkspace(baseline)
        assertEquals(listOf("S"), store.state.value.displayGroups.flatMap { it.sessions }.map { it.id })
    }

    @Test fun emptyWorkspaceBaselineFinishesLoadingAndAllowsUngroupedSessions() {
        val store = SidebarStore(StubAPI())
        store.applyWorkspace(o("type" to "replace", "value" to o("items" to emptyList<J>())))
        assertTrue(store.state.value.loaded)
        assertTrue(store.state.value.displayGroups.all { it.sessions.isEmpty() })
        store.applySessions(o("items" to listOf(o("sessionId" to "S"))))
        assertEquals(listOf("S"), store.state.value.displayGroups.single { it.id == "ungrouped" }.sessions.map { it.id })
    }

    @Test fun failedWorkspaceStreamDoesNotShowUnassignedSessions() = runTest {
        val api = object : RPCServing {
            override suspend fun rpc(method: String, args: J): J = EMPTY
            override fun stream(endpoint: String, args: J) = kotlinx.coroutines.flow.flow<J> { throw APIError.Disconnected }
        }
        val store = SidebarStore(api, backgroundScope)
        store.applySessions(o("items" to listOf(o("sessionId" to "S"))))
        store.start(); runCurrent()
        assertNotNull(store.state.value.error)
        assertFalse(store.state.value.loaded)
        assertTrue(store.state.value.displayGroups.isEmpty())
        store.stop()
    }

    @Test fun optionsCommandsAndQueueUseSwiftArgumentShapesOverHTTP() = runTest {
        val calls = CopyOnWriteArrayList<J>()
        MockWebServer().use { server ->
            server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    val body = parse(request.body.readUtf8()); calls.add(body)
                    val method = body["method"].text; val args = body["payload"]["args"]
                    assertEquals("/relay/api/$method", request.path)
                    assertEquals("POST", request.method)
                    assertEquals(PortalClient.USER_AGENT, request.getHeader("User-Agent"))
                    assertEquals(PortalURL.origin(server.url("/")), request.getHeader("Origin"))
                    return ok(when (method) {
                        "session/modelCatalog" -> catalog
                        "session/selectModel" -> o("selected" to args["request"])
                        "permissionPresets/catalog" -> parse("""{"options":[{"value":"read-only"}]}""")
                        "agentPresets/list" -> parse("""{"presets":[{"id":"standard"},{"id":"minimal"}]}""")
                        "commands/list" -> j(listOf(o("name" to "plan", "description" to "Plan")))
                        "session/projections" -> parse("""{"asOfSeq":1,"values":{"agentPreset":"standard","permissions":{"currentValue":"read-only"},"sessionListMetadata":{"blank":true}}}""")
                        "commands/execute" -> when (args["line"].text) {
                            "/bad" -> o("result" to o("kind" to "error", "text" to "Refused"))
                            "/unknown" -> j(null)
                            else -> o("result" to o("kind" to "success", "text" to "Changed"))
                        }
                        "session/state" -> o("running" to true, "queue" to emptyList<J>())
                        else -> EMPTY
                    })
                }
            }
            server.start()
            val api = PortalAPI(server.url("/relay/"), PortalClient(CookieVault(temporary.newFolder())), backgroundScope)
            val chat = ChatStore("S", api, scope = backgroundScope)
            chat.loadModels(); chat.loadControls()
            assertEquals("One", chat.state.value.modelName); assertEquals("High", chat.state.value.effortName)
            assertEquals(o("agentId" to "S"), calls.first { it["method"].text == "commands/list" }["payload"]["args"])
            chat.selectModel("fake", "one")
            assertEquals("high", calls.last()["payload"]["args"]["request"]["reasoningEffort"].text)
            chat.selectModel("fake", "one", "off"); chat.selectModel("fake", "one")
            assertEquals("off", calls.last()["payload"]["args"]["request"]["reasoningEffort"].text)
            chat.selectModel("fake", "two")
            assertEquals("off", chat.state.value.currentModel["reasoningEffort"].text)
            chat.selectModel("fake", "one", useDefaultEffort = true)
            assertNull(chat.state.value.currentModel["reasoningEffort"].string)
            chat.selectPermission("read-only"); chat.selectPreset("minimal"); chat.executeCommand("/plan")
            assertEquals("Changed", chat.state.value.commandNotice)
            assertTrue(calls.any { it["method"].text == "agentPresets/select" && it["payload"]["args"] == o("agentId" to "S", "agentPreset" to "minimal") })
            assertEquals(o("agentId" to "S", "line" to "/permission read-only", "submittedAttachments" to emptyList<J>()), calls.first { it["method"].text == "commands/execute" }["payload"]["args"])
            for (line in listOf("/bad", "/unknown")) fails<PortalError> { chat.executeCommand(line) }
            chat.addOptimistic("queued", "R")
            val queue = parse("""{"running":true,"queue":[{"id":"Q","rpcId":"R","placement":"queued","content":[{"type":"text","text":"queued"}]}]}""")
            chat.applyState(queue)
            assertTrue(chat.state.value.transcript.isEmpty())
            for (kind in listOf("edit", "steer", "remove")) {
                chat.applyState(queue); chat.updateQueue("Q", kind, if (kind == "edit") "changed" else null)
                val args = calls.last { it["method"].text == "session/updateQueue" }["payload"]["args"]
                val action = if (kind == "edit") o("kind" to kind, "content" to listOf(o("type" to "text", "text" to "changed"))) else o("kind" to kind)
                assertEquals(o("request" to o("sessionId" to "S", "itemId" to "Q", "action" to action)), args)
                assertTrue(chat.state.value.transcript.isEmpty()); assertTrue(chat.state.value.queue.isEmpty())
            }
            val before = calls.size
            fails<PortalError> { chat.updateQueue("Q", "edit", " ") }
            fails<PortalError> { chat.selectPreset("minimal") }
            assertEquals(before, calls.size)
        }
    }

    @Test fun projectionsRespectCursorSessionPendingAndReset() {
        val chat = ChatStore("S", StubAPI())
        chat.applyProjections(parse("""{"asOfSeq":2,"values":{"plan":{"active":false,"pending":true},"agentPreset":"minimal"}}"""))
        assertTrue(chat.state.value.planEnabled)
        chat.applyControl(parse("""{"type":"projection","sessionId":"Other","seq":20,"changes":[{"key":"agentPreset","val":"wrong"}]}"""))
        chat.applyControl(parse("""{"type":"projection","sessionId":"S","seq":1,"changes":[{"key":"agentPreset","val":"stale"}]}"""))
        chat.applyProjections(o("asOfSeq" to 1, "values" to EMPTY))
        assertEquals("minimal", chat.state.value.projections["agentPreset"].text)
        chat.applyControl(parse("""{"type":"projection","sessionId":"S","seq":3,"changes":[{"key":"plan","val":{"active":true,"pending":true}}]}"""))
        assertFalse(chat.state.value.planEnabled)
        chat.applyControl(o("type" to "connection-reset"))
        chat.applyControl(parse("""{"type":"baseline","value":{"projections":{"S":{"asOfSeq":1,"values":{"plan":{"active":true},"sessionListMetadata":{"blank":false}}}}}}"""))
        assertTrue(chat.state.value.planEnabled); assertTrue(chat.state.value.sessionStarted)
        chat.applyState(o("running" to false, "queue" to null))
        assertTrue(chat.state.value.queue.isEmpty()); assertFalse(chat.state.value.running)
    }

    @Test fun startsAndStopsControlAndStateStreams() = runTest {
        val api = StubAPI(); val chat = ChatStore("S", api, scope = backgroundScope)
        chat.start(); runCurrent()
        assertTrue(api.streams.contains("session/control" to EMPTY))
        assertTrue(api.streams.contains("session/observeState" to o("request" to o("sessionId" to "S"))))
        assertEquals(3, api.streams.size)
        chat.stop(); chat.start(); runCurrent(); assertEquals(6, api.streams.size); chat.stop()
    }

    @Test fun optionsRefreshMetadataAlsoForEmptyCatalogs() = runTest {
        for (empty in listOf(false, true)) MockWebServer().use { server ->
            server.start()
            val api = PortalAPI(server.url("/"), PortalClient(CookieVault(temporary.newFolder())), backgroundScope)
            val chat = ChatStore("S", api)
            repeat(2) { index ->
                server.enqueue(ok(if (empty) EMPTY else catalog))
                server.enqueue(ok(o("options" to emptyList<J>())))
                server.enqueue(ok(o("presets" to if (empty) emptyList<J>() else listOf(o("id" to "minimal")))))
                server.enqueue(ok(j(emptyList<J>())))
                server.enqueue(ok(o("asOfSeq" to index, "values" to o("agentPreset" to "standard"))))
                chat.loadModels(); chat.loadControls()
                assertEquals(if (empty) 0 else 1, chat.state.value.catalog["groups"].array.size)
                assertEquals(if (empty) 0 else 1, chat.state.value.presetCatalog["presets"].array.size)
                assertEquals("standard", chat.state.value.projections["agentPreset"].text)
            }
            assertEquals(10, server.requestCount)
        }
    }

    @Test fun foldersWorkspaceSearchAndArchiveOverHTTP() = runTest {
        MockWebServer().use { server ->
            server.start()
            val api = PortalAPI(server.url("/relay/"), PortalClient(CookieVault(temporary.newFolder())), backgroundScope)
            val store = SidebarStore(api)
            server.enqueue(MockResponse().setResponseCode(303).addHeader("Set-Cookie", "dsh_portal=fixture; Path=/; Max-Age=3600"))
            api.login("secret"); server.takeRequest()
            server.enqueue(MockResponse().setBody("""{"ok":true,"listing":{"entries":[],"path":"/host/a b","parent":"/host","roots":[]}}"""))
            assertTrue(store.folders("/host/a b")["entries"].array.isEmpty())
            val browse = server.takeRequest()
            assertEquals("/relay/dsh-remote-portal/fs?path=%2Fhost%2Fa%20b", browse.path)
            assertEquals("GET", browse.method); assertEquals(PortalClient.USER_AGENT, browse.getHeader("User-Agent"))
            assertTrue(browse.getHeader("Cookie")!!.contains("dsh_portal=fixture"))
            assertEquals(PortalURL.origin(server.url("/")), browse.getHeader("Origin"))
            server.enqueue(MockResponse().setBody("""{"ok":true,"created":{"path":"/host/a b/new"}}"""))
            assertEquals("/host/a b/new", store.makeFolder("/host/a b", "new")["path"].text)
            val mkdir = server.takeRequest()
            assertEquals("/relay/dsh-remote-portal/fs/mkdir", mkdir.path); assertEquals("POST", mkdir.method)
            assertEquals(o("parent" to "/host/a b", "name" to "new"), parse(mkdir.body.readUtf8()))
            val workspace = parse("""{"workspace":{"workspaceId":"W","title":"Work","path":"/host/a b","sessionIds":[]}}""")
            server.enqueue(ok(workspace)); store.createWorkspace("/host/a b")
            assertEquals(o("request" to o("path" to "/host/a b")), parse(server.takeRequest().body.readUtf8())["payload"]["args"])
            server.enqueue(ok(workspace)); store.renameWorkspace("W", "Renamed")
            assertEquals(o("request" to o("workspaceId" to "W", "title" to "Renamed")), parse(server.takeRequest().body.readUtf8())["payload"]["args"])
            store.applySessions(parse("""{"items":[{"sessionId":"S","projections":{"values":{"title":"Other"}}},{"sessionId":"N","projections":{"values":{"title":"Match name"}}}]}"""))
            store.setSearchText("match")
            assertEquals(listOf("N"), store.state.value.groups.flatMap { it.sessions }.map { it.id })
            server.enqueue(ok(parse("""{"items":[{"sessionId":"S"}]}"""))); store.search("match")
            assertEquals(o("request" to o("query" to "match")), parse(server.takeRequest().body.readUtf8())["payload"]["args"])
            assertEquals(2, store.state.value.groups.flatMap { it.sessions }.size)
            store.applyWorkspace(o("type" to "archived", "archivedSessionIds" to listOf("S"))); store.setArchivedOnly(true)
            assertEquals(listOf("S"), store.state.value.groups.flatMap { it.sessions }.map { it.id })
            server.enqueue(ok(o("archivedSessionIds" to emptyList<J>()))); store.unarchive("S"); server.takeRequest()
            assertTrue(store.state.value.groups.all { it.sessions.isEmpty() })
            store.setArchivedOnly(false)
            server.enqueue(MockResponse().setResponseCode(500)); fails<APIError.Http> { store.search("match") }; server.takeRequest()
            assertEquals(listOf("N"), store.state.value.groups.flatMap { it.sessions }.map { it.id })
            store.setSearchText(""); val count = server.requestCount; store.search(" "); assertEquals(count, server.requestCount)
            server.enqueue(ok(EMPTY)); store.deleteWorkspace("W")
            assertEquals(o("request" to o("workspaceId" to "W")), parse(server.takeRequest().body.readUtf8())["payload"]["args"])
            assertTrue(store.state.value.workspaces.isEmpty())
        }
    }

    @Test fun staleContentSearchDoesNotReplaceNewQuery() = runTest {
        lateinit var store: SidebarStore
        val api = object : RPCServing {
            override suspend fun rpc(method: String, args: J): J {
                store.setSearchText("new"); return o("items" to listOf(o("sessionId" to "S")))
            }
            override fun stream(endpoint: String, args: J) = kotlinx.coroutines.flow.emptyFlow<J>()
        }
        store = SidebarStore(api); store.setSearchText("old"); store.search("old")
        assertTrue(store.state.value.searchResults.isEmpty())
        store.applySessions(parse("""{"items":[{"sessionId":"S","projections":{"values":{"title":"Before"}}}]}"""))
        store.applyControl(parse("""{"type":"baseline","value":{"projections":{"S":{"values":{"title":"After"}}}}}"""))
        assertEquals("After", store.state.value.sessions["S"]?.title)
    }

    @Test fun exportValidatesZipAndExpiresOnUnauthorized() = runTest {
        for ((status, body, success) in listOf(Triple(200, "PKfixture", true), Triple(200, "", false), Triple(200, "{}", false), Triple(401, "", false), Triple(500, "Failed", false))) {
            MockWebServer().use { server ->
                server.start()
                val api = PortalAPI(server.url("/relay/"), PortalClient(CookieVault(temporary.newFolder())), backgroundScope)
                val chat = ChatStore("S", api)
                server.enqueue(ok(o("result" to o("kind" to "success"))))
                server.enqueue(MockResponse().setResponseCode(status).setBody(body).setHeader("Content-Type", "application/zip"))
                if (success) server.enqueue(ok(o("asOfSeq" to 0, "values" to EMPTY)))
                if (success) assertArrayEquals(body.toByteArray(), chat.executeCommand("/export")) else fails<APIError> { chat.executeCommand("/export") }
                server.takeRequest()
                val request = server.takeRequest()
                assertEquals("/relay/api/session.export?sessionId=S", request.path); assertEquals("GET", request.method)
                assertEquals(PortalClient.USER_AGENT, request.getHeader("User-Agent")); assertEquals(PortalURL.origin(server.url("/")), request.getHeader("Origin"))
                assertEquals(status == 401, api.sessionExpired.value)
            }
        }
    }

    @Test fun httpFailuresDoNotMutateOptionsOrWorkspaceState() = runTest {
        for (status in listOf(200, 401, 404, 500)) MockWebServer().use { server ->
            server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest) = MockResponse().setResponseCode(status).setBody(
                    if (request.path!!.contains("/api/")) """{"type":"server-response","result":{"ok":false,"error":{"code":"refused","message":"Refused"}}}"""
                    else """{"ok":false,"error":"Refused"}""")
            }
            server.start()
            val api = PortalAPI(server.url("/"), PortalClient(CookieVault(temporary.newFolder())), backgroundScope)
            val store = SidebarStore(api); val chat = ChatStore("S", api)
            fails<APIError> { store.folders() }; fails<APIError> { store.makeFolder("/host", "new") }
            fails<APIError> { store.createWorkspace("/host") }; fails<APIError> { chat.selectModel("p", "m") }
            fails<APIError> { chat.loadModels() }; fails<APIError> { chat.loadControls() }; fails<APIError> { chat.executeCommand("/plan") }
            assertTrue(store.state.value.workspaces.isEmpty()); assertEquals(EMPTY, chat.state.value.selectedModel)
            assertEquals(status == 401, api.sessionExpired.value)
        }
    }
}
