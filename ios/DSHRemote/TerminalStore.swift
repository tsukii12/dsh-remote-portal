import Foundation

struct TerminalProtocolState {
    private(set) var outputSequence: Int?
    private(set) var acknowledged = 0
    private(set) var inputSequence = 0
    mutating func reset() { outputSequence = nil; acknowledged = 0; inputSequence = 0 }
    mutating func snapshot(_ sequence: Int) { reset(); outputSequence = sequence }
    mutating func output(_ sequence: Int) throws -> Bool {
        guard let previous = outputSequence else { throw APIError.invalidResponse }
        if sequence <= previous { return false }
        guard sequence == previous + 1 else { throw APIError.invalidResponse }
        outputSequence = sequence; return true
    }
    mutating func nextInput() -> Int { inputSequence += 1; return inputSequence }
    mutating func discardUnsentInput(after inFlight: Int?) { inputSequence = inFlight ?? acknowledged }
    mutating func acknowledge(_ sequence: Int) throws {
        guard sequence == acknowledged + 1, sequence <= inputSequence else { throw APIError.invalidResponse }
        acknowledged = sequence
    }
}

@MainActor
final class TerminalStore: ObservableObject {
    let api: PortalAPI
    let sessionID: String
    let id: String
    @Published private(set) var info: JSON
    @Published private(set) var ready = false
    @Published private(set) var writable = false
    @Published var error: String?
    @Published private(set) var notice: String?
    private(set) var environment: JSON = [:]
    private(set) var protocolState = TerminalProtocolState()
    var render: ((JSON) -> Void)?
    private var holdTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var channel: PortalMux.Channel?
    private var generation: UUID?
    private var runID = UUID()
    private var queue: [JSON] = []
    private var inFlight: JSON?
    private var bufferedBytes = 0
    private var inputWindow: JSON = [:]
    private var desiredCols = 80
    private var desiredRows = 24
    init(api: PortalAPI, sessionID: String, info: JSON) {
        self.api = api; self.sessionID = sessionID; self.info = info; id = info["id"].text
    }
    func start() {
        guard holdTask == nil else { return }
        let run = UUID(); runID = run
        error = nil
        holdTask = Task { [weak self] in
            guard let self else { return }
            do {
                environment = try await api.rpc("terminal/environment", args: ["agentId": .string(sessionID)])
                try Task.checkCancellation()
                guard runID == run else { return }
                for try await value in api.stream("terminal/retain", args: ["sessionId": .string(sessionID), "id": .string(id)]) {
                    if Task.isCancelled || runID != run { return }
                    if value["type"] == "retained", receiveTask == nil { attach(run: run) }
                }
            } catch { if !Task.isCancelled, runID == run { self.error = error.localizedDescription; disconnect() } }
        }
    }
    func stop() {
        runID = UUID()
        holdTask?.cancel(); holdTask = nil
        receiveTask?.cancel(); receiveTask = nil
        channel?.cancel(); channel = nil
        disconnect()
    }
    func reconnect() { stop(); start() }
    private func disconnect() {
        if bufferedBytes > 0 { notice = L("Connection changed. Pending input was not replayed; check the shell before typing again.", "连接已改变。待确认输入未重发，请检查终端后再输入。") }
        ready = false; writable = false; generation = nil
        queue = []; inFlight = nil; bufferedBytes = 0; protocolState.reset()
    }
    private func attach(run: UUID) {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                let opened = api.mux.openDuplex("terminal/attach", args: ["agentId": .string(sessionID), "id": .string(id)])
                channel = opened
                do {
                    for try await event in opened.frames {
                        try Task.checkCancellation()
                        guard runID == run else { return }
                        guard event.generation == opened.generation else { continue }
                        try apply(event.value, generation: event.generation)
                    }
                    if !Task.isCancelled, runID == run { error = L("Terminal attachment ended. Reconnect to review its final state.", "终端连接已结束。请重新连接以查看最终状态。") }
                    break
                } catch APIError.invalidResponse {
                    guard !Task.isCancelled, runID == run else { break }
                    opened.cancel(); disconnect()
                    notice = L("Refreshing the terminal screen after an out-of-order frame.", "收到乱序数据，正在刷新终端画面。")
                    do { try await Task.sleep(nanoseconds: 300_000_000) } catch { break }
                } catch {
                    if !Task.isCancelled, runID == run { self.error = error.localizedDescription }
                    break
                }
            } while !Task.isCancelled
            if runID == run { disconnect() }
        }
    }
    private func apply(_ value: JSON, generation: UUID) throws {
        switch value["type"].text {
        case "connection-reset": disconnect()
        case "snapshot":
            guard let sequence = value["sequence"].int, sequence >= 0, value["screen"].string != nil,
                  let cols = value["info"]["cols"].int, let rows = value["info"]["rows"].int,
                  cols >= 2, rows >= 1, cols <= (environment["maxCols"].int ?? 500), rows <= (environment["maxRows"].int ?? 200) else { throw APIError.invalidResponse }
            disconnect(); self.generation = generation; protocolState.snapshot(sequence)
            info = value["info"]; inputWindow = value["inputWindow"]
            render?(value)
            ready = true; writable = value["writable"].boolean; error = nil
            resize(cols: desiredCols, rows: desiredRows)
        case "output":
            guard let sequence = value["sequence"].int, value["data"].string != nil else { throw APIError.invalidResponse }
            if try protocolState.output(sequence) { render?(value) }
        case "state":
            info = value["info"]; writable = ready && value["writable"].boolean
            if !writable { discardInput() }
        case "ack":
            guard let sequence = value["sequence"].int, let command = inFlight, command["sequence"].int == sequence else { throw APIError.invalidResponse }
            try protocolState.acknowledge(sequence)
            bufferedBytes -= encodedBytes(command); inFlight = nil
            if value["refusal"].string != nil {
                writable = false; discardInput()
                error = L("Input refused: terminal is read-only or no longer running. Reconnect to request control.", "输入被拒绝：终端为只读或已停止。请重新连接以请求控制权。")
            } else { flush() }
        default: throw APIError.invalidResponse
        }
    }
    private func discardInput() { queue = []; protocolState.discardUnsentInput(after: inFlight?["sequence"].int); bufferedBytes = inFlight.map(encodedBytes) ?? 0 }
    private func encodedBytes(_ command: JSON) -> Int { ((try? JSONEncoder().encode(command).count) ?? Int.max / 2) + (inputWindow["frameOverheadBytes"].int ?? 128) }
    func write(_ data: String, typed: Bool = true) {
        guard !data.isEmpty else { return }
        let maxInput = max(1, environment["maxInputBytes"].int ?? 65_536)
        guard data.utf8.count <= maxInput else { error = L("Input is too large. Paste a smaller selection.", "输入过大，请分段粘贴。"); return }
        let chunkLimit = max(1, min(4096, ((inputWindow["maxBytes"].int ?? 262_144) - 1024) / 6, maxInput))
        var chunks: [String] = []; var chunk = ""
        for scalar in data.unicodeScalars {
            if chunk.utf8.count + scalar.utf8.count > chunkLimit, !chunk.isEmpty { chunks.append(chunk); chunk = "" }
            chunk.unicodeScalars.append(scalar)
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        enqueue(chunks.map { ["type": "write", "data": .string($0), "typed": .bool(typed)] })
    }
    func resize(cols: Int, rows: Int) {
        desiredCols = max(2, min(cols, environment["maxCols"].int ?? 500))
        desiredRows = max(1, min(rows, environment["maxRows"].int ?? 200))
        guard ready, writable else { return }
        let last = queue.last { $0["type"] == "resize" } ?? (inFlight?["type"] == "resize" ? inFlight! : info)
        guard last["cols"].int != desiredCols || last["rows"].int != desiredRows else { return }
        enqueue([["type": "resize", "cols": .number(Double(desiredCols)), "rows": .number(Double(desiredRows))]])
    }
    private func enqueue(_ commands: [JSON]) {
        guard ready, writable, generation == channel?.generation else {
            error = L("Terminal is not writable. Reconnect before typing.", "终端当前不可写，请重新连接后输入。"); return
        }
        var next = protocolState
        let numbered = commands.map { command -> JSON in var command = command; command["sequence"] = .number(Double(next.nextInput())); return command }
        let bytes = numbered.reduce(0) { $0 + encodedBytes($1) }
        let rawBytes = (queue + (inFlight.map { [$0] } ?? []) + numbered).reduce(0) { $0 + $1["data"].text.utf8.count }
        guard bufferedBytes + bytes <= (environment["maxBufferedBytes"].int ?? 2_097_152),
              rawBytes <= (environment["maxInputBytes"].int ?? 65_536),
              numbered.allSatisfy({ encodedBytes($0) <= (inputWindow["maxBytes"].int ?? 262_144) }) else {
            error = L("Input buffer full. Wait for acknowledgement or paste less text.", "输入缓冲区已满，请等待确认或减少粘贴内容。"); return
        }
        protocolState = next; queue += numbered; bufferedBytes += bytes; flush()
    }
    private func flush() {
        guard inFlight == nil, !queue.isEmpty, writable, let channel, let generation else { return }
        let command = queue.removeFirst(); inFlight = command
        Task { [weak self] in
            do { try await channel.send(command, generation: generation) }
            catch {
                guard let self, self.generation == generation, self.channel === channel else { return }
                self.error = error.localizedDescription; disconnect()
                channel.cancel()
            }
        }
    }
}
