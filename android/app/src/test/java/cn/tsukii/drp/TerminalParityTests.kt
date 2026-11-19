package cn.tsukii.drp

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream

@OptIn(ExperimentalCoroutinesApi::class)
class TerminalParityTests {
    @Test fun modelModalitiesGateImagesButNotFilesOrTextAndUnknownCatalogRemainsCompatible() = runTest {
        val api = StubAPI(); val chat = ChatStore("S", api)
        chat.apply(snapshot("live-approval-events"))
        val model = chat.state.value.currentModel
        fun catalog(modalities: J) = o("groups" to listOf(o("id" to model["provider"], "models" to listOf(o("id" to model["model"], "inputModalities" to modalities)))))
        api.response = catalog(j(listOf("text"))); chat.loadModels(); assertNotNull(chat.state.value.imageInputError)
        val before = chat.state.value.transcript
        fails<PortalError> { chat.send("keep my typed text", attachments = listOf(o("receiptId" to "R", "image" to o("name" to "pic.png")))) }
        assertEquals(before, chat.state.value.transcript); assertTrue(api.calls.none { it.first == "session/prompt" })
        chat.send("ordinary text"); chat.send("file", attachments = listOf(o("receiptId" to "F", "file" to o("name" to "file.txt"))))
        assertEquals(2, api.calls.count { it.first == "session/prompt" })
        for (modalities in listOf(j(listOf("text", "image")), j(null))) {
            api.response = catalog(modalities); chat.loadModels(); assertNull(chat.state.value.imageInputError)
            chat.send("image", attachments = listOf(o("receiptId" to "R", "image" to o("name" to "pic.png"))))
        }
        api.response = catalog(j(emptyList<String>())); chat.loadModels(); assertNotNull(chat.state.value.imageInputError)
    }
    @Test fun lateImagePickerAndRetryCannotUploadAfterSwitchToTextOnlyModel() = runTest {
        var denied: String? = "no images"; var uploads = 0
        val api = object : RPCServing {
            override suspend fun rpc(method: String, args: J) = EMPTY
            override fun stream(endpoint: String, args: J) = emptyFlow<J>()
            override suspend fun upload(sessionID: String, source: UploadSource, maxBytes: Long, progress: (Long) -> Unit): J {
                uploads++; return o("receiptId" to "R", "image" to o("bytes" to 3))
            }
        }
        val limits = o("maxImageBytes" to 10, "maxMessageImageBytes" to 20, "maxImagesPerMessage" to 2, "mediaTypes" to listOf("image/png"))
        val draft = AttachmentDraft("S", api, backgroundScope, { denied }) { limits }
        draft.add(UploadSource("pic.png", "image/png", 3) { ByteArrayInputStream(byteArrayOf()) }); runCurrent()
        assertEquals(0, uploads); assertFalse(draft.ready); assertEquals("no images", draft.items.value.single().error)
        denied = null; draft.retry(draft.items.value.single().id); runCurrent(); assertEquals(1, uploads); assertTrue(draft.ready)
        denied = "no images"; fails<PortalError> { draft.validateImages() }; draft.close()
    }
    @Test fun resolvedApprovalAndQuestionIdsSurviveReplayReadyAndReconnectButFailuresRemainRetryable() = runTest {
        val api = StubAPI(); val events = RemoteEvents(api, backgroundScope)
        fun ready(id: String) = events.apply(o("type" to "ready", "clientId" to id))
        fun ask(id: String, kind: String = "approval/request") = events.apply(o("type" to "waterfall", "eventId" to id, "agentId" to "S", "event" to kind, "request" to EMPTY))
        ready("C1"); ask("A"); events.answerApproval("A", true); ask("A"); assertTrue(events.state.value.pending.isEmpty())
        ask("Q", "user-questions/request"); events.answerQuestions("Q", emptyList()); ask("Q", "user-questions/request"); assertTrue(events.state.value.pending.isEmpty())
        ask("cancelled"); events.apply(o("type" to "cancel", "eventId" to "cancelled"))
        events.apply(o("type" to "connection-reset")); ready("C2"); ask("A"); ask("Q", "user-questions/request"); ask("cancelled"); assertTrue(events.state.value.pending.isEmpty())
        ask("failed"); api.failure = APIError.Disconnected; fails<APIError.Disconnected> { events.answerApproval("failed", false) }
        events.apply(o("type" to "connection-reset")); ready("C3"); ask("failed"); assertEquals("failed", events.state.value.pending.single().id)
        api.failure = null; events.answerApproval("failed", false); ask("failed"); assertTrue(events.state.value.pending.isEmpty())
    }
    @Test fun successAfterReconnectAlsoClearsReplayedNewClientInteraction() = runTest {
        val done = CompletableDeferred<Unit>()
        val api = object : RPCServing {
            override suspend fun rpc(method: String, args: J): J { done.await(); return EMPTY }
            override fun stream(endpoint: String, args: J) = emptyFlow<J>()
        }
        val events = RemoteEvents(api, backgroundScope)
        val frame = o("type" to "waterfall", "eventId" to "A", "agentId" to "S", "event" to "approval/request", "request" to EMPTY)
        events.apply(o("type" to "ready", "clientId" to "C1")); events.apply(frame)
        val answer = backgroundScope.launch { events.answerApproval("A", true) }; runCurrent()
        events.apply(o("type" to "connection-reset")); events.apply(o("type" to "ready", "clientId" to "C2")); events.apply(frame)
        done.complete(Unit); runCurrent(); answer.join(); assertTrue(events.state.value.pending.isEmpty()); events.apply(frame); assertTrue(events.state.value.pending.isEmpty())
    }
    @Test fun privatePathsAreHiddenInTreeSearchAndMentionsButSimilarlyNamedFilesRemainVisible() = runTest {
        val api = object : RPCServing {
            override suspend fun rpc(method: String, args: J): J = when (method) {
                "workspaceFiles/list" -> o("entries" to listOf(o("name" to ".dsh"), o("name" to ".dsh-notes"), o("name" to "normal"), o("name" to "secret", "path" to "sub/.dsh/token")))
                "workspaceFiles/search" -> o("matches" to listOf(o("path" to ".dsh/config"), o("path" to "sub/.dsh/history"), o("path" to ".dsh-notes")))
                "fileReferences/list" -> j(listOf(o("path" to ".dsh", "kind" to "directory"), o("path" to "sub/.dsh/token"), o("path" to "allowed file.txt")))
                else -> j(emptyList<J>())
            }
            override fun stream(endpoint: String, args: J) = flow<J> { awaitCancellation() }
        }
        val store = WorkspaceFilesStore("S", api, backgroundScope); store.start(); runCurrent()
        assertEquals(listOf(".dsh-notes", "normal"), store.state.value.directories.getValue(".").entries.map { it["name"].text })
        store.search("dsh"); advanceTimeBy(251); runCurrent(); assertEquals(listOf(".dsh-notes"), store.state.value.results.map { it["path"].text })
        assertEquals(listOf("allowed file.txt"), Mentions.candidates(api, "S", AtToken(0, 1, "", false)).map { it.label })
        for (path in listOf(".dsh", "./.dsh/config", "sub/.dsh/token", "C:\\.dsh\\config")) {
            assertFalse(WorkspacePaths.visible(path)); assertNull(Mentions.file(path, false, false)); val preview = WorkspacePreviewStore("S", api, path); preview.load(); assertNotNull(preview.state.value.error); assertNull(preview.download())
        }
        store.close()
    }
    @Test fun extensionlessImagesAreProbedFromMagicBytesWithTextEmptyAndFailureCases() = runTest {
        var bytes = byteArrayOf(137.toByte(), 80, 78, 71, 13, 10, 26, 10, 1); var broken = false; var textReads = 0
        val api = object : RPCServing {
            override suspend fun rpc(method: String, args: J): J {
                if (method == "workspaceFiles/stat") return o("bytes" to bytes.size, "version" to "V")
                textReads++; return o("text" to String(bytes), "lines" to if (bytes.isEmpty()) 0 else 1, "eof" to true, "version" to "V")
            }
            override suspend fun rpcBinary(method: String, args: J): BinaryRPCResult {
                if (broken) throw APIError.Disconnected
                val part = bytes.take(args["options"]["range"]["length"].int!!).toByteArray()
                return BinaryRPCResult(o("offset" to 0, "bytes" to bytes.size, "version" to "V", "eof" to true), mapOf(listOf("data") to part))
            }
            override fun stream(endpoint: String, args: J) = emptyFlow<J>()
        }
        val image = WorkspacePreviewStore("S", api, "picture"); image.load(); assertEquals(FilePreviewKind.IMAGE, image.state.value.kind); assertArrayEquals(bytes, image.state.value.data); assertEquals(0, textReads)
        bytes = "ordinary text".toByteArray(); val text = WorkspacePreviewStore("S", api, "README"); text.load(); assertEquals(FilePreviewKind.TEXT, text.state.value.kind); assertEquals("ordinary text", text.state.value.text)
        bytes = byteArrayOf(); val empty = WorkspacePreviewStore("S", api, "empty"); empty.load(); assertTrue(empty.state.value.loaded); assertTrue(empty.state.value.eof)
        broken = true; image.load(true); assertNotNull(image.state.value.error); assertFalse(image.state.value.loaded)
        assertFalse(ImageSignatures.detected(byteArrayOf())); assertFalse(ImageSignatures.detected("GIF89".toByteArray())); assertFalse(ImageSignatures.detected("RIFF1234WAVE".toByteArray()))
        assertTrue(ImageSignatures.detected("GIF89a12".toByteArray())); assertTrue(ImageSignatures.detected("RIFF1234WEBP".toByteArray())); assertTrue(ImageSignatures.detected(byteArrayOf(255.toByte(), 216.toByte(), 255.toByte())))
    }
}
