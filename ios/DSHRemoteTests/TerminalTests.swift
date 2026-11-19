import XCTest
import Network
import UIKit
import SwiftTerm
@testable import DSHRemote

private final class TerminalReplies: TerminalDelegate {
    var replies: [UInt8] = []
    func send(source: Terminal, data: ArraySlice<UInt8>) { replies += data }
}

@MainActor
final class TerminalTests: XCTestCase {
    func testNativeCopyAllPreservesWideCharactersAndHandlesEmptyScreen() {
        let view = RemoteTerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        defer { view.updateUiClosed() }
        view.feed(text: "Native DRP terminal\r\n中文宽字符：原生终端\r\nASCII after CJK")
        view.copyAll()
        XCTAssertTrue(UIPasteboard.general.string?.contains("中文宽字符：原生终端\nASCII after CJK") == true)
        XCTAssertFalse(UIPasteboard.general.string?.contains("\u{0}") == true)
        XCTAssertNil(view.getSelection())
        view.getTerminal().resetToInitialState(); view.copyAll()
        XCTAssertEqual(UIPasteboard.general.string ?? "", "")
    }
    func testEmptyOversizedAndDisconnectedInputAreNotSent() {
        let api = PortalAPI(base: URL(string: "http://127.0.0.1:1/")!, client: PortalClient())
        defer { api.client.session.invalidateAndCancel() }
        let store = TerminalStore(api: api, sessionID: "S", info: ["id": "T"])
        store.write(""); XCTAssertNil(store.error)
        store.write(String(repeating: "中", count: 30_000)); XCTAssertNotNil(store.error)
        store.error = nil; store.write("ls\r"); XCTAssertNotNil(store.error)
        XCTAssertFalse(store.ready); XCTAssertEqual(store.protocolState.inputSequence, 0)
    }
    func testCursorEraseAndFragmentedParser() throws {
        let delegate = TerminalReplies()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 10, rows: 4))
        terminal.feed(text: "abcdef\u{1b}["); terminal.feed(text: "2DXY")
        XCTAssertEqual(terminal.getCharacter(col: 4, row: 0), "X")
        terminal.feed(text: "\u{1b}[2;3HZ\u{1b}[1K")
        XCTAssertEqual(terminal.getCharacter(col: 2, row: 1), "\0")
        terminal.feed(text: "\u{1b}[2J\u{1b}[Hstart\u{1b}[3D\u{1b}[K")
        XCTAssertEqual(terminal.getCharacter(col: 0, row: 0), "s")
        XCTAssertEqual(terminal.getCharacter(col: 2, row: 0), "\0")
        terminal.feed(text: "\u{1b}[6n")
        XCTAssertTrue(String(decoding: delegate.replies, as: UTF8.self).contains("\u{1b}[1;3R"))
    }
    func testColorsBoldWideCJKAndAlternateScreen() throws {
        let delegate = TerminalReplies()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 4))
        terminal.feed(text: "\u{1b}[1;31mA\u{1b}[38;5;201mB\u{1b}[38;2;1;2;3;48;2;4;5;6mC\u{1b}[0m中文")
        XCTAssertEqual(terminal.getCharData(col: 0, row: 0)?.attribute.fg, .ansi256(code: 1))
        XCTAssertTrue(try XCTUnwrap(terminal.getCharData(col: 0, row: 0)).attribute.style.contains(.bold))
        XCTAssertEqual(terminal.getCharData(col: 1, row: 0)?.attribute.fg, .ansi256(code: 201))
        XCTAssertEqual(terminal.getCharData(col: 2, row: 0)?.attribute.fg, .trueColor(red: 1, green: 2, blue: 3))
        XCTAssertEqual(terminal.getCharData(col: 2, row: 0)?.attribute.bg, .trueColor(red: 4, green: 5, blue: 6))
        XCTAssertEqual(terminal.getCharacter(col: 3, row: 0), "中")
        XCTAssertEqual(terminal.getCharData(col: 3, row: 0)?.width, 2)
        XCTAssertEqual(terminal.getCharacter(col: 5, row: 0), "文")
        terminal.feed(text: "\u{1b}[94;41mD")
        XCTAssertEqual(terminal.getCharData(col: 7, row: 0)?.attribute.fg, .ansi256(code: 12))
        XCTAssertEqual(terminal.getCharData(col: 7, row: 0)?.attribute.bg, .ansi256(code: 1))
        terminal.feed(text: "\u{1b}[?1049h\u{1b}[Hvim")
        XCTAssertEqual(terminal.getCharacter(col: 0, row: 0), "v")
        terminal.feed(text: "\u{1b}[?1049l")
        XCTAssertEqual(terminal.getCharacter(col: 0, row: 0), "A")
    }
    func testScrollbackResizeResetAndEmptyInvalidSequences() {
        let delegate = TerminalReplies()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 12, rows: 3, scrollback: 20))
        terminal.feed(text: "")
        terminal.feed(text: "\u{1b}[999999z\u{1b}[0m")
        terminal.feed(text: "one\r\ntwo\r\nthree\r\nfour\r\nfive")
        XCTAssertTrue(String(data: terminal.getBufferAsData(), encoding: .utf8)!.contains("one"))
        terminal.resize(cols: 20, rows: 5)
        XCTAssertEqual(terminal.cols, 20); XCTAssertEqual(terminal.rows, 5)
        terminal.resetToInitialState(); terminal.feed(text: "replacement")
        let screen = String(data: terminal.getBufferAsData(), encoding: .utf8)!
        XCTAssertTrue(screen.contains("replacement")); XCTAssertFalse(screen.contains("five"))
    }
    func testSnapshotOutputAndIndependentInputSequences() throws {
        var state = TerminalProtocolState()
        XCTAssertThrowsError(try state.output(1))
        state.snapshot(42)
        XCTAssertTrue(try state.output(43)); XCTAssertFalse(try state.output(43)); XCTAssertFalse(try state.output(1))
        XCTAssertThrowsError(try state.output(45))
        XCTAssertEqual(state.nextInput(), 1)
        XCTAssertThrowsError(try state.acknowledge(2)); try state.acknowledge(1)
        state.snapshot(90)
        XCTAssertEqual(state.nextInput(), 1); XCTAssertEqual(state.acknowledged, 0)
        XCTAssertEqual(state.nextInput(), 2); XCTAssertEqual(state.nextInput(), 3)
        state.discardUnsentInput(after: 1); try state.acknowledge(1)
        XCTAssertEqual(state.nextInput(), 2)
        state.discardUnsentInput(after: nil); XCTAssertEqual(state.nextInput(), 2)
        XCTAssertTrue(try state.output(91))
        state.reset(); XCTAssertNil(state.outputSequence)
    }
    func testDuplexOverRealListenerReopensWithoutReplayingInput() async throws {
        let server = try TerminalSocketListener()
        let base = try await server.start()
        let api = PortalAPI(base: base, client: PortalClient())
        let deadline = Task { try await Task.sleep(nanoseconds: 15_000_000_000); api.mux.close() }
        defer { deadline.cancel() }
        defer { api.mux.close(); api.client.session.invalidateAndCancel(); server.stop() }
        let channel = api.mux.openDuplex("terminal/attach", args: ["agentId": "SESSION", "id": "TERM"])
        defer { channel.cancel() }
        var iterator = channel.frames.makeAsyncIterator()
        let firstValue = try await iterator.next()
        let first = try XCTUnwrap(firstValue)
        XCTAssertEqual(first.value["type"], "snapshot")
        try await channel.send(["type": "write", "sequence": 1, "data": "ls\r", "typed": true], generation: first.generation)
        let ackValue = try await iterator.next()
        let ack = try XCTUnwrap(ackValue); XCTAssertEqual(ack.value, ["type": "ack", "sequence": 1])
        try await channel.send(["type": "resize", "sequence": 2, "cols": 100, "rows": 30], generation: first.generation)
        let resizeValue = try await iterator.next()
        let resized = try XCTUnwrap(resizeValue); XCTAssertEqual(resized.value["sequence"], 2)
        api.mux.reconnect()
        do { try await channel.send(["type": "write", "sequence": 3, "data": "stale"], generation: first.generation); XCTFail("Old generation accepted input") } catch {}
        var second: PortalMux.Event?
        for _ in 0..<3 { if let value = try await iterator.next(), value.value["type"] == "snapshot" { second = value; break } }
        let recovered = try XCTUnwrap(second); XCTAssertNotEqual(first.generation, recovered.generation)
        try await channel.send(["type": "write", "sequence": 1, "data": "\u{3}", "typed": true], generation: recovered.generation)
        _ = try await iterator.next()
        try await channel.end(generation: recovered.generation)
        let received = server.received
        let opens = received.filter { $0["type"] == "open" }
        XCTAssertEqual(opens.count, 2)
        XCTAssertTrue(opens.allSatisfy { $0["endpoint"] == "terminal/attach" && $0["payload"]["args"] == ["agentId": "SESSION", "id": "TERM"] })
        let items = received.filter { $0["type"] == "item" }.map { $0["value"] }
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0]["data"], "ls\r"); XCTAssertEqual(items[0]["typed"], true)
        XCTAssertEqual(items[1], ["type": "resize", "sequence": 2, "cols": 100, "rows": 30])
        XCTAssertEqual(items[2]["sequence"], 1); XCTAssertEqual(items[2]["data"], "\u{3}")
    }
}

private final class TerminalSocketListener {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "DRP.TerminalSocketListener")
    private let lock = NSLock()
    private var frames: [JSON] = []
    private var connections: [NWConnection] = []
    var received: [JSON] { lock.lock(); defer { lock.unlock() }; return frames }
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let webSocket = NWProtocolWebSocket.Options(); webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                if case .ready = state { listener.stateUpdateHandler = nil; continuation.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/relay/")!) }
                if case .failed(let error) = state { listener.stateUpdateHandler = nil; continuation.resume(throwing: error) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connections.append(connection); connection.start(queue: queue); receive(connection)
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel(); queue.async { self.connections.forEach { $0.cancel() } } }
    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, complete, error in
            guard let self else { return }
            if (context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata)?.opcode == .close { connection.cancel(); return }
            if let data, let frame = try? JSONDecoder().decode(JSON.self, from: data) {
                lock.lock(); frames.append(frame); lock.unlock()
                let id = frame["streamId"]
                var value: JSON?
                if frame["type"] == "open" { value = ["type": "snapshot", "sequence": 10, "screen": "recovered"] }
                if frame["type"] == "item" { value = ["type": "ack", "sequence": frame["value"]["sequence"]] }
                if let value {
                    let response: JSON = ["type": "item", "streamId": id, "value": value]
                    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                    let context = NWConnection.ContentContext(identifier: UUID().uuidString, metadata: [metadata])
                    connection.send(content: try? JSONEncoder().encode(response), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
                }
            }
            if error == nil, data != nil { receive(connection) }
        }
    }
}
