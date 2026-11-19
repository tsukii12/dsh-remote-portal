package cn.tsukii.drp

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.test.*
import okhttp3.mockwebserver.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.util.Locale

@OptIn(ExperimentalCoroutinesApi::class)
class AttachmentTests {
    @get:Rule val temporary = TemporaryFolder()
    private val limits = o("maxImageBytes" to 10, "maxMessageImageBytes" to 15, "maxImagesPerMessage" to 2, "maxImageDimension" to 8, "maxImagePixels" to 32, "mediaTypes" to listOf("image/png"))
    private fun source(size: Long? = 3, type: String? = null) = UploadSource("space name.txt", type, size) { ByteArrayInputStream(byteArrayOf(0, 1, -1)) }
    private fun receipt(image: Boolean = false) = o("receiptId" to "R", (if (image) "image" else "file") to o("name" to "picked.txt", "bytes" to 3, "attachmentId" to "sha256:test", "width" to 4, "height" to 4))
    private fun response(value: J) = MockResponse().setBody(o("type" to "server-response", "result" to o("ok" to true, "value" to value)).toString())

    @Test fun controlsArrivingAfterFollowSnapshotNeverRestoreTheLoadingState() = runTest {
        lateinit var chat: ChatStore
        val api = object : RPCServing {
            override suspend fun rpc(method: String, args: J): J {
                if (method != "session/projections") {
                    delay(10)
                    chat.apply(snapshot("live-hello-events"))
                }
                return EMPTY
            }
            override fun stream(endpoint: String, args: J): Flow<J> = emptyFlow()
        }
        chat = ChatStore("S", api, scope = backgroundScope)
        chat.loadControls()
        assertTrue(chat.state.value.loaded); assertTrue(chat.state.value.transcript.isNotEmpty())
        chat.apply(o("type" to "connection-reset")); assertFalse(chat.state.value.loaded)
        chat.loadControls(); assertTrue(chat.state.value.loaded); assertTrue(chat.state.value.transcript.isNotEmpty())
    }

    @Test fun rawUploadStreamsReopensOnRetryAndPreservesPrefixStatusAndExpiry(): Unit = runBlocking {
        MockWebServer().use { server ->
            server.start()
            val api = PortalAPI(server.url("/relay/"), PortalClient(CookieVault(temporary.newFolder())), this)
            var opens = 0; var closes = 0; var progress = 0L
            val picked = UploadSource("a b.png", "image/png", null) { opens++; object : ByteArrayInputStream(byteArrayOf(0, 1, -1)) { override fun close() { closes++; super.close() } } }
            repeat(2) {
                server.enqueue(MockResponse().setBody(o("ok" to true, "value" to receipt(true)).toString()))
                assertEquals("R", api.upload("S", picked, 10) { progress = it }["receiptId"].text)
                val req = server.takeRequest()
                assertEquals("/relay/api/session/uploadFileBinary", req.requestUrl!!.encodedPath)
                assertEquals("S", req.requestUrl!!.queryParameter("sessionId")); assertEquals("a b.png", req.requestUrl!!.queryParameter("name"))
                assertEquals("image/png", req.requestUrl!!.queryParameter("mediaType")); assertEquals("application/octet-stream", req.getHeader("Content-Type"))
                assertArrayEquals(byteArrayOf(0, 1, -1), req.body.readByteArray())
            }
            assertEquals(2, opens); assertEquals(2, closes); assertEquals(3L, progress)
            server.enqueue(MockResponse().setBody(o("ok" to true, "value" to receipt()).toString()))
            api.upload("S", UploadSource("empty.txt", null, 0) { ByteArrayInputStream(byteArrayOf()) }, 0) {}
            assertEquals(0L, server.takeRequest().bodySize)
            server.enqueue(MockResponse().setResponseCode(502).setBody("not json")); fails<APIError.Http> { api.upload("S", source(), 10) {} }
            server.enqueue(MockResponse().setBody(o("ok" to false, "error" to o("code" to "invalid", "message" to "Bad upload")).toString()))
            fails<APIError.Remote> { api.upload("S", source(), 10) {} }
            server.enqueue(MockResponse().setResponseCode(401)); fails<APIError.SessionExpired> { api.upload("S", source(), 10) {} }
            assertTrue(api.sessionExpired.value)
            server.enqueue(MockResponse().setBody("{}")); fails<java.io.IOException> { api.upload("S", source(size = null), 2) {} }
            fails<java.io.IOException> { api.upload("S", UploadSource("revoked.txt", null, null) { throw SecurityException("URI grant revoked") }, 10) {} }
        }
    }
    @Test fun draftBlocksPendingAndFailedUploadsSupportsRetryRemoveAndClosesAgainstLateCompletion() = runTest {
        var fail = true
        val done = CompletableDeferred<Unit>()
        val api = object : RPCServing {
            override suspend fun rpc(method: String, args: J) = EMPTY
            override fun stream(endpoint: String, args: J): Flow<J> = emptyFlow()
            override suspend fun upload(sessionID: String, source: UploadSource, maxBytes: Long, progress: (Long) -> Unit): J {
                progress(1); if (fail) throw java.io.IOException("offline")
                withContext(NonCancellable) { done.await() }; return receipt()
            }
        }
        val first = AttachmentDraft("A", api, backgroundScope) { limits }
        assertTrue(first.ready); first.add(source()); assertFalse(first.ready); runCurrent()
        assertEquals("offline", first.items.value.single().error)
        fail = false; first.retry(first.items.value.single().id); runCurrent(); assertFalse(first.ready)
        first.close()
        val second = AttachmentDraft("B", api, backgroundScope) { limits }; done.complete(Unit); runCurrent()
        assertTrue(first.items.value.isEmpty()); assertTrue(second.items.value.isEmpty())
        second.add(source()); runCurrent(); assertTrue(second.ready)
        val id = second.requestID; second.clear(); assertNotEquals(id, second.requestID); assertTrue(second.items.value.isEmpty())
    }
    @Test fun imageLimitsRejectUnsupportedCountBytesAndDimensionsWithoutInventingDefaults() = runTest {
        val api = object : RPCServing {
            var uploads = 0
            override suspend fun rpc(method: String, args: J) = EMPTY
            override fun stream(endpoint: String, args: J): Flow<J> = emptyFlow()
            override suspend fun upload(sessionID: String, source: UploadSource, maxBytes: Long, progress: (Long) -> Unit): J { uploads++; return receipt(true).with("image", receipt(true)["image"].with("width", 9)) }
        }
        val draft = AttachmentDraft("S", api, backgroundScope) { limits }
        draft.add(source(11, "image/png")); runCurrent(); assertFalse(draft.ready); assertEquals(0, api.uploads); draft.clear()
        draft.add(source(3, "image/svg+xml")); runCurrent(); assertEquals(0, api.uploads); draft.clear()
        repeat(3) { draft.add(source(3, "image/png")) }; runCurrent(); assertEquals(0, api.uploads); draft.clear()
        repeat(2) { draft.add(source(8, "image/png")) }; runCurrent(); assertEquals(0, api.uploads); draft.clear()
        draft.add(source(3, "image/png")); runCurrent(); assertFalse(draft.ready); assertNotNull(draft.items.value.single().error); assertEquals(1, api.uploads)
        val unknown = AttachmentDraft("S", api, backgroundScope) { EMPTY }; unknown.add(source(3, "image/png")); runCurrent(); assertFalse(unknown.ready)
    }
    @Test fun attachmentOnlyPromptUsesReceiptsAndRendersDurableBlocksWithoutDuplicatingOptimisticMessages() = runTest {
        val api = StubAPI(); val chat = ChatStore("S", api, scope = backgroundScope)
        chat.send("", attachments = listOf(receipt()), requestID = "stable")
        val request = api.calls.single().second["request"]
        assertEquals("S", request["sessionId"].text); assertEquals(j(listOf(o("type" to "file", "receiptId" to "R"))), request["content"])
        assertEquals("picked.txt", chat.state.value.transcript.single().blocks.single().attachment["name"].text)
        chat.apply(o("type" to "event", "event" to o("seq" to 1, "type" to "user/message", "data" to o("id" to "M", "source" to o("kind" to "user", "rpcId" to "stable"), "content" to listOf(o("type" to "file", "attachment" to receipt()["file"]))))))
        assertEquals(1, chat.state.value.transcript.size); assertFalse(chat.state.value.transcript.single().optimistic)
        assertEquals("picked.txt", chat.state.value.transcript.single().blocks.single().attachment["name"].text)
        fails<PortalError> { chat.send("") }; fails<APIError.InvalidResponse> { chat.send("", attachments = listOf(EMPTY)) }
        val block = TranscriptBlock(o("type" to "image", "attachment" to receipt(true)["image"]))
        assertEquals("sha256:test", block.attachment["attachmentId"].text)
        api.failure = APIError.Remote("session/attachment-invalid", "Model does not support image input.")
        fails<APIError.Remote> { chat.send("", attachments = listOf(receipt(true))) }
        assertTrue(ErrorPresentation.headline("Model does not support image input.", listOf("en")).contains("cannot read images"))
        assertTrue(ErrorPresentation.headline("Model does not support image input.", listOf("zh")).contains("不支持图片"))
    }
    @Test fun mentionGrammarPreservesQuotedDirectoriesRejectsUnsafePathsAndReplacesAtCursor() {
        assertNull(Mentions.active("a@b.com", 7)); assertNull(Mentions.active("ordinary", 8))
        val token = Mentions.active("Look @sp tail", 8)!!
        assertEquals("sp", token.query); assertEquals("Look @\"space name.txt\" tail", "Look @sp tail".replaceRange(token.start, token.end, Mentions.file("space name.txt", false, false)!!))
        assertEquals("@\"space dir/", Mentions.file("space dir", true, false))
        assertEquals("@\"src/file\"", Mentions.file("src/file", false, true))
        assertNull(Mentions.file("bad\nfile", false, false)); assertNull(Mentions.file("bad\"file", false, true))
        assertTrue(Mentions.active("@\"a b", 5)!!.quoted)
        assertFalse(Mentions.active("@\"file\"", 7)!!.quoted)
    }
    @Test fun mentionLookupsUseSessionCandidatesVerbatimSuppressInQuotesAndCancel() = runTest {
        val calls = mutableListOf<Pair<String, J>>()
        var hold = false; var cancelled = false
        val api = object : RPCServing {
            override suspend fun rpc(method: String, args: J): J {
                calls += method to args
                if (hold) try { awaitCancellation() } finally { cancelled = true }
                return if (method == "fileReferences/list") j(listOf(o("path" to "space name.txt", "kind" to "file")))
                    else j(listOf(o("displayTitle" to "Other session", "mention" to "@[label](dsh-session:opaque)")))
            }
            override fun stream(endpoint: String, args: J): Flow<J> = emptyFlow()
        }
        val choices = Mentions.candidates(api, "S", AtToken(0, 1, "", false))
        assertEquals("@[label](dsh-session:opaque)", choices.last().insertion)
        assertTrue(calls.all { it.second == o("agentId" to "S", "query" to "") })
        calls.clear(); assertEquals(1, Mentions.candidates(api, "S", AtToken(0, 2, "", true)).size); assertEquals(1, calls.size)
        hold = true; val lookup = launch { Mentions.candidates(api, "S", AtToken(0, 1, "", false)) }; runCurrent(); lookup.cancelAndJoin(); assertTrue(cancelled)
    }
}
