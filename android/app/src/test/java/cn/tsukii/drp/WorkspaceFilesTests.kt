package cn.tsukii.drp

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.test.*
import okhttp3.MultipartBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

@OptIn(ExperimentalCoroutinesApi::class)
class WorkspaceFilesTests {
    @get:Rule val temporary = TemporaryFolder()
    private fun stat(size: Long, version: String = "V") = o("bytes" to size, "version" to version)
    private fun page(text: String, lines: Int, eof: Boolean, version: String = "V") = o("text" to text, "lines" to lines, "eof" to eof, "version" to version)

    @Test fun filePanelInsertsAtTheSelectionQuotesPathsAndRejectsEmptyOrUnsafeMentions() {
        assertEquals("@\"space name.txt\" " to 18, Mentions.insertFile("", 0, 0, "space name.txt"))
        assertEquals("ask @\"new.txt\" " to 15, Mentions.insertFile("ask @\"ol", 8, 8, "new.txt"))
        assertEquals("@new.txt tail" to 9, Mentions.insertFile("oldtail", 0, 3, "new.txt"))
        assertNull(Mentions.insertFile("", 0, 0, "")); assertNull(Mentions.insertFile("", 0, 0, "bad\"path")); assertNull(Mentions.insertFile("", 1, 1, "file"))
    }

    @Test fun treeUsesSessionScopeAndRootExpandsRefreshesAndReloadsOnWatchReset() = runTest {
        val events = MutableSharedFlow<J>()
        val calls = mutableListOf<Pair<String, J>>()
        val api = object : RPCServing {
            override suspend fun rpc(method: String, args: J): J { calls += method to args; return o("entries" to if (args["path"].text == ".") listOf(o("name" to "src", "type" to "directory")) else emptyList<J>(), "truncated" to true) }
            override fun stream(endpoint: String, args: J): Flow<J> { assertEquals("workspaceFiles/changes", endpoint); assertEquals(o("workspaceFileScopeId" to "S", "path" to "."), args); return events }
        }
        val store = WorkspaceFilesStore("S", api, backgroundScope)
        store.start(); assertTrue(store.state.value.directories.getValue(".").loading); runCurrent()
        assertEquals(o("workspaceFileScopeId" to "S", "path" to "."), calls.single().second)
        store.toggle("src"); runCurrent(); assertTrue(store.state.value.directories.getValue("src").entries.isEmpty())
        assertTrue(store.state.value.directories.getValue("src").truncated)
        assertEquals("src/test.kt", WorkspaceFilesStore.child("src", "test.kt")); assertEquals("src", WorkspaceFilesStore.child(".", "src"))
        events.emit(o("kind" to "ready")); runCurrent(); assertEquals(2, calls.size)
        events.emit(o("kind" to "change")); advanceTimeBy(151); runCurrent(); assertEquals(4, calls.size)
        events.emit(o("type" to "connection-reset")); advanceTimeBy(151); runCurrent(); assertEquals(6, calls.size)
        store.toggle("src"); store.refresh(); runCurrent(); assertEquals(7, calls.size)
        store.close(); events.emit(o("kind" to "change")); advanceTimeBy(151); runCurrent(); assertEquals(7, calls.size)
    }
    @Test fun searchIsDebouncedCancellableAndCarriesExactFlagsWithEmptyTruncatedAndErrorStates() = runTest {
        val calls = mutableListOf<J>()
        var fail = false
        val api = object : RPCServing {
            override suspend fun rpc(method: String, args: J): J { assertEquals("workspaceFiles/search", method); calls += args; if (fail) throw PortalError("offline"); return o("matches" to emptyList<J>(), "truncated" to true, "incomplete" to true) }
            override fun stream(endpoint: String, args: J): Flow<J> = flow { awaitCancellation() }
        }
        val store = WorkspaceFilesStore("S", api, backgroundScope)
        store.search("a"); advanceTimeBy(100); store.search("src/a"); advanceTimeBy(249); runCurrent(); assertTrue(calls.isEmpty())
        advanceTimeBy(2); runCurrent()
        assertEquals(o("workspaceFileScopeId" to "S", "request" to o("query" to "src/a", "excludedPaths" to emptyList<String>(), "includeHidden" to false, "respectGitignore" to true)), calls.single())
        assertTrue(store.state.value.results.isEmpty()); assertTrue(store.state.value.truncated); assertTrue(store.state.value.incomplete); assertFalse(store.state.value.searching)
        fail = true; store.search("bad"); advanceTimeBy(251); runCurrent(); assertEquals("offline", store.state.value.searchError)
        store.search(""); assertNull(store.state.value.searchError); assertFalse(store.state.value.searching)
        store.close()
    }
    @Test fun staleDirectoryCompletionCannotOverwriteRefreshOrDifferentSessionAndErrorsCanRetry() = runTest {
        val done = CompletableDeferred<Unit>(); var first = true; var failure = false
        val api = object : RPCServing {
            override suspend fun rpc(method: String, args: J): J {
                if (first) { first = false; withContext(NonCancellable) { done.await() }; return o("entries" to listOf(o("name" to "old"))) }
                if (failure) throw PortalError("denied")
                return o("entries" to emptyList<J>())
            }
            override fun stream(endpoint: String, args: J): Flow<J> = flow { awaitCancellation() }
        }
        val old = WorkspaceFilesStore("A", api, backgroundScope); old.start(); runCurrent(); old.refresh(); runCurrent()
        done.complete(Unit); runCurrent(); assertTrue(old.state.value.directories.getValue(".").entries.isEmpty())
        failure = true; old.refresh(); runCurrent(); assertEquals("denied", old.state.value.directories.getValue(".").error)
        failure = false; old.load("."); runCurrent(); assertNull(old.state.value.directories.getValue(".").error)
        old.close(); val fresh = WorkspaceFilesStore("B", api, backgroundScope); assertTrue(fresh.state.value.directories.isEmpty()); fresh.close()
    }
    @Test fun textUsesTwoHundredLinePagesDetectsVersionChangesAndSupportsEmptyAndBinaryFallback() = runTest {
        val calls = mutableListOf<J>(); var value = page("first", 200, false)
        val api = object : RPCServing {
            override suspend fun rpc(method: String, args: J): J { calls += args; if (value == EMPTY) throw APIError.Remote("workspace-file/not-text", "binary"); return value }
            override fun stream(endpoint: String, args: J) = emptyFlow<J>()
        }
        val preview = WorkspacePreviewStore("S", api, "src/a.txt")
        preview.load(); assertEquals(o("workspaceFileScopeId" to "S", "path" to "src/a.txt", "range" to o("offset" to 1, "limit" to 200)), calls.single())
        value = page("second", 1, true, "changed"); preview.load(); assertEquals("first", preview.state.value.text); assertNotNull(preview.state.value.error)
        value = page("second", 1, true); preview.load(); assertEquals("first\nsecond", preview.state.value.text); assertEquals(201, calls.last()["range"]["offset"].int)
        value = page("", 0, true); preview.load(true); assertTrue(preview.state.value.loaded); assertEquals("", preview.state.value.text)
        value = page("", 0, false); preview.load(true); assertNotNull(preview.state.value.error)
        value = page("x".repeat(WorkspacePreviewStore.MAX_TEXT_CHARS + 1), 1, false); preview.load(true)
        assertTrue(preview.state.value.truncated); assertEquals(WorkspacePreviewStore.MAX_TEXT_CHARS, preview.state.value.text.length)
        value = EMPTY; preview.load(true); assertEquals(FilePreviewKind.BINARY, preview.state.value.kind)
    }
    @Test fun binaryDownloadsAreChunkedBoundedVersionCheckedAndNeverAcceptMalformedOrMissingParts() = runTest {
        val calls = mutableListOf<J>(); var size = WorkspacePreviewStore.CHUNK_BYTES.toLong() + 3; var broken = ""
        val api = object : RPCServing {
            override suspend fun rpc(method: String, args: J) = stat(size)
            override suspend fun rpcBinary(method: String, args: J): BinaryRPCResult {
                assertEquals("workspaceFiles/readBytes", method); assertEquals("S", args["workspaceFileScopeId"].text); assertEquals("a.bin", args["path"].text); calls += args
                val offset = args["options"]["range"]["offset"].int!!; val length = args["options"]["range"]["length"].int!!
                val metadata = o("version" to if (broken == "version") "other" else "V", "bytes" to size, "offset" to if (broken == "offset") offset + 1 else offset, "eof" to (offset + length >= size))
                val bytes = if (broken == "zero") byteArrayOf() else ByteArray(length + if (broken == "oversize") 1 else 0) { 42 }
                return BinaryRPCResult(metadata, if (broken == "missing") emptyMap() else mapOf(listOf("data") to bytes))
            }
            override fun stream(endpoint: String, args: J) = emptyFlow<J>()
        }
        val preview = WorkspacePreviewStore("S", api, "a.bin")
        assertEquals(size.toInt(), preview.download()!!.size); assertEquals(2, calls.size); assertEquals(WorkspacePreviewStore.CHUNK_BYTES, calls.last()["options"]["range"]["offset"].int)
        size = 0; assertArrayEquals(byteArrayOf(), preview.download()); assertEquals(2, calls.size)
        size = WorkspacePreviewStore.MAX_DOWNLOAD_BYTES + 1; assertNull(preview.download()); assertEquals(2, calls.size)
        size = 3
        listOf("version", "offset", "missing", "zero", "oversize").forEach { broken = it; assertNull(preview.download()); assertNotNull(preview.state.value.error) }
    }
    @Test fun imagePreviewUsesMultipartBytesOverRealHttpAndPreservesRelayPrefix() = runBlocking {
        MockWebServer().use { server ->
            server.start(); val api = PortalAPI(server.url("/relay/"), PortalClient(CookieVault(temporary.newFolder())), this)
            server.enqueue(MockResponse().setBody(o("type" to "server-response", "result" to o("ok" to true, "value" to stat(3))).toString()))
            val value = o("bytes" to 3, "offset" to 0, "version" to "V", "eof" to true, "data" to null)
            val metadata = o("type" to "server-response", "result" to o("ok" to true, "value" to value), "attachments" to listOf(o("path" to listOf("data"), "codec" to "bytes", "part" to "bytes-0")))
            val body = MultipartBody.Builder().setType(MultipartBody.FORM).addFormDataPart("metadata", metadata.toString()).addFormDataPart("bytes-0", null, byteArrayOf(0, -1, 1).toRequestBody()).build()
            server.enqueue(MockResponse().addHeader("Content-Type", body.contentType()).setBody(Buffer().apply { body.writeTo(this) }))
            val preview = WorkspacePreviewStore("S", api, "a.png"); preview.load()
            assertTrue(preview.state.value.loaded); assertEquals(FilePreviewKind.IMAGE, preview.state.value.kind); assertArrayEquals(byteArrayOf(0, -1, 1), preview.state.value.data)
            assertEquals("/relay/api/workspaceFiles/stat", server.takeRequest().path)
            val request = server.takeRequest(); assertEquals("/relay/api/workspaceFiles/readBytes", request.path)
            assertEquals(o("workspaceFileScopeId" to "S", "path" to "a.png", "options" to o("range" to o("offset" to 0, "length" to 3))), parse(request.body.readUtf8())["payload"]["args"])
            server.enqueue(MockResponse().setResponseCode(401)); preview.load(true); assertNotNull(preview.state.value.error); assertTrue(api.sessionExpired.value)
        }
    }
}
