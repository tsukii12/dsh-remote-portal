import XCTest
@testable import DSHRemote

final class PresentationTests: XCTestCase {
    func testApplicationBranding() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "DRP")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String, "DRP")
        XCTAssertEqual(Bundle.main.bundleIdentifier, "io.github.tsukii12.dshremote")
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        XCTAssertEqual(primary?["CFBundleIconName"] as? String, "AppIcon")
    }
    func testMarkdownBlocksAndStreamingFence() {
        XCTAssertEqual(MarkdownParser.blocks(""), [])
        XCTAssertEqual(MarkdownParser.blocks("# Hello\n\n- **One**\n2. Two\n\n```swift\nlet x = 1\n```\n\nEnd"), [.heading(1, "Hello"), .list("•", "**One**"), .list("2.", "Two"), .code("swift", "let x = 1"), .paragraph("End")])
        XCTAssertEqual(MarkdownParser.blocks("Intro\n~~~sh\npwd"), [.paragraph("Intro"), .code("sh", "pwd")])
        XCTAssertEqual(MarkdownParser.blocks("````text\n```\n````"), [.code("text", "```")])
        XCTAssertEqual(MarkdownParser.blocks("not # a heading\ninline `code`"), [.paragraph("not # a heading\ninline `code`")])
    }
    func testToolSummaryAndResultFallback() {
        XCTAssertEqual(ToolPresentation.summary("{\"command\":\"pwd\"}"), "pwd")
        XCTAssertEqual(ToolPresentation.summary("{partial"), "{partial")
        XCTAssertEqual(ToolPresentation.summary(""), "")
        XCTAssertEqual(ToolPresentation.result(["message": ["content": [["text": "/workspace"]]]]), "/workspace")
        XCTAssertEqual(ToolPresentation.result(["error": ["message": "Denied"]]), "Denied")
    }
    func testLocalizedApprovalReason() {
        let request: JSON = ["reason": "Raw reason", "displayReason": ["en": "Allow", "zh": "允许"]]
        XCTAssertEqual(InteractionPresentation.reason(request, languages: ["zh-Hans"]), "允许")
        XCTAssertEqual(InteractionPresentation.reason(request, languages: ["fr"]), "Allow")
        XCTAssertEqual(InteractionPresentation.reason(["reason": "Raw"], languages: []), "Raw")
    }
    func testSingleMultiCustomQuestionsAndFixedApprovals() {
        var draft = QuestionDraft()
        let question: JSON = ["id": "Q", "options": [["label": "A"], ["label": "B"]]]
        XCTAssertFalse(draft.canSubmit([]))
        XCTAssertFalse(draft.canSubmit([question]))
        draft.toggle("A", question: question); draft.toggle("B", question: question)
        XCTAssertEqual(draft.answers([question])[0]["selected"], ["B"])
        draft.setCustom(" Other ", question: question)
        XCTAssertEqual(draft.answers([question])[0]["custom"], "Other")
        XCTAssertEqual(draft.answers([question])[0]["selected"], [])
        var multi = question; multi["multiSelect"] = true
        draft.toggle("A", question: multi); draft.toggle("B", question: multi)
        XCTAssertEqual(draft.answers([multi])[0]["selected"], ["A", "B"])
        XCTAssertTrue(draft.canSubmit([multi]))
        draft.toggle("A", question: multi)
        XCTAssertEqual(draft.answers([multi])[0]["selected"], ["B"])
        var fixed = question; fixed["intent"] = ["kind": "approval"]
        draft.setCustom("not a permission choice", question: fixed)
        XCTAssertFalse(draft.canSubmit([fixed]))
        XCTAssertEqual(draft.answers([fixed])[0]["custom"], .null)
    }
}
