package cn.tsukii.drp

import org.junit.Assert.*
import org.junit.Test
import java.io.File

class PresentationTests {
    @Test fun applicationBranding() {
        val root = File("src/main")
        assertTrue(File(root, "res/values/strings.xml").readText().contains(">DRP<"))
        assertTrue(File("build.gradle.kts").readText().contains("cn.tsukii.drp"))
        assertTrue(File(root, "AndroidManifest.xml").readText().contains("@mipmap/ic_launcher"))
        listOf("mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi").forEach { assertTrue(File(root, "res/mipmap-$it/ic_launcher.png").length() > 0) }
    }
    @Test fun markdownBlocksAndStreamingFence() {
        assertEquals(emptyList<MarkdownBlock>(), MarkdownParser.blocks(""))
        assertEquals(listOf(MarkdownBlock.Heading(1, "Hello"), MarkdownBlock.ListItem("•", "**One**"), MarkdownBlock.ListItem("2.", "Two"),
            MarkdownBlock.Code("swift", "let x = 1"), MarkdownBlock.Paragraph("End")), MarkdownParser.blocks("# Hello\n\n- **One**\n2. Two\n\n```swift\nlet x = 1\n```\n\nEnd"))
        assertEquals(listOf(MarkdownBlock.Paragraph("Intro"), MarkdownBlock.Code("sh", "pwd")), MarkdownParser.blocks("Intro\n~~~sh\npwd"))
        assertEquals(listOf(MarkdownBlock.Code("text", "```")), MarkdownParser.blocks("````text\n```\n````"))
        assertEquals(listOf(MarkdownBlock.Paragraph("not # a heading\ninline `code`")), MarkdownParser.blocks("not # a heading\ninline `code`"))
    }
    @Test fun toolSummaryAndResultFallback() {
        assertEquals("pwd", ToolPresentation.summary("{\"command\":\"pwd\"}")); assertEquals("{partial", ToolPresentation.summary("{partial")); assertEquals("", ToolPresentation.summary(""))
        assertEquals("/workspace", ToolPresentation.result(parse("""{"message":{"content":[{"text":"/workspace"}]}}""")))
        assertEquals("Denied", ToolPresentation.result(parse("""{"error":{"message":"Denied"}}""")))
    }
    @Test fun toolCardSummaryAndStatus() {
        assertEquals("/workspace/file.txt", ToolPresentation.summary("{\"path\":\"/workspace/file.txt\",\"limit\":10}"))
        assertEquals("echo first", ToolPresentation.summary("{\"command\":\"echo first\\npwd\"}"))
        assertEquals("", ToolPresentation.summary("{}"))
        assertEquals("{partial", ToolPresentation.summary("{partial"))
        assertEquals("running", ToolPresentation.status(null))
        assertEquals("ok", ToolPresentation.status(o("message" to o("isError" to false))))
        assertEquals("error", ToolPresentation.status(o("message" to o("isError" to true))))
        assertEquals("error", ToolPresentation.status(o("error" to o("message" to "Denied"))))
    }
    @Test fun localizedApprovalReason() {
        val request = parse("""{"reason":"Raw reason","displayReason":{"en":"Allow","zh":"允许"}}""")
        assertEquals("允许", InteractionPresentation.reason(request, listOf("zh-Hans"))); assertEquals("Allow", InteractionPresentation.reason(request, listOf("fr")))
        assertEquals("Raw", InteractionPresentation.reason(o("reason" to "Raw"), emptyList()))
    }
    @Test fun approvalInputMatchesExactCallAndPreservesArguments() {
        val records = fixture("live-approval-events")["result"]["value"]["records"].array
        val request = records.last { it["event"]["type"].text == "approval/asked" }["event"]["data"]
        assertEquals("pwd", InteractionPresentation.input(request, records)); assertNull(InteractionPresentation.input(request, emptyList()))
        assertNull(InteractionPresentation.input(o("callId" to "unknown"), records)); assertNull(InteractionPresentation.input(EMPTY, records))
        fun call(arguments: String) = o("event" to o("type" to "tool/call", "data" to o("callId" to "C", "arguments" to arguments)))
        assertEquals("{\"command\":\"not a shell command\",\"path\":\"/workspace\"}", InteractionPresentation.input(o("callId" to "C", "toolName" to "read"), listOf(call("{\"path\": \"/workspace\", \"command\": \"not a shell command\"}"))))
        assertEquals("{partial", InteractionPresentation.input(o("callId" to "C"), listOf(call("{partial"))))
    }
    @Test fun singleMultiCustomQuestionsAndFixedApprovals() {
        val draft = QuestionDraft(); val question = parse("""{"id":"Q","options":[{"label":"A"},{"label":"B"}]}""")
        assertFalse(draft.canSubmit(emptyList())); assertFalse(draft.canSubmit(listOf(question)))
        draft.toggle("A", question); draft.toggle("B", question); assertEquals(j(listOf("B")), draft.answers(listOf(question))[0]["selected"])
        draft.setCustom(" Other ", question); assertEquals(j("Other"), draft.answers(listOf(question))[0]["custom"]); assertTrue(draft.answers(listOf(question))[0]["selected"].array.isEmpty())
        val multi = question.with("multiSelect", true); draft.toggle("A", multi); draft.toggle("B", multi)
        assertEquals(j(listOf("A", "B")), draft.answers(listOf(multi))[0]["selected"]); assertTrue(draft.canSubmit(listOf(multi)))
        draft.toggle("A", multi); assertEquals(j(listOf("B")), draft.answers(listOf(multi))[0]["selected"])
        val fixed = question.with("intent", o("kind" to "approval")); draft.setCustom("not a permission choice", fixed)
        assertFalse(draft.canSubmit(listOf(fixed))); assertEquals(j(null), draft.answers(listOf(fixed))[0]["custom"])
    }
    @Test fun bilingualErrors() {
        assertEquals("中文", L("English", "中文", listOf("zh-Hans"))); assertEquals("English", L("English", "中文", listOf("en")))
        assertEquals(L("Invalid server response.", "服务器响应无效。"), APIError.InvalidResponse.message)
        assertEquals(L("Connection closed.", "连接已关闭。"), APIError.Disconnected.message)
        assertEquals(L("Server request failed (HTTP 503).", "服务器请求失败（HTTP 503）。"), APIError.Http(503).message)
        assertEquals(L("Request failed.", "请求失败。"), fails<APIError.Remote> { PortalAPI.decode("""{"type":"server-response","result":{"ok":false,"error":{}}}""", 200) }.message)
    }
}
