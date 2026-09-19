import Foundation

/// A single-use WebSocket session. Consume events from exactly one task.
/// For microphone/speaker ownership use DialtVoiceClient instead.
@MainActor public final class DialtSession {
    public enum State: Sendable { case idle, connecting, live, reconnecting, closed }
    public private(set) var state: State = .idle
    public private(set) var sessionUUID: String?
    public let events: AsyncThrowingStream<DialtEvent, any Error>
    private let continuation: AsyncThrowingStream<DialtEvent, any Error>.Continuation
    private let configuration: DialtConfiguration
    private let factory: @MainActor (URL) -> any DialtTransport
    var audioFrontend: String
    private var wire: (any DialtTransport)?
    private var reader: Task<Void, Never>?
    private var generation = 0
    private var resumeToken: String?

    public convenience init(configuration: DialtConfiguration) {
        self.init(configuration: configuration, audioFrontend: "unknown", factory: { WebSocketTransport(url: $0) })
    }
    init(configuration: DialtConfiguration, audioFrontend: String = "unknown",
         factory: @escaping @MainActor (URL) -> any DialtTransport) {
        self.configuration = configuration; self.audioFrontend = audioFrontend; self.factory = factory
        let pair = AsyncThrowingStream<DialtEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        events = pair.stream; continuation = pair.continuation
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.close() } }
    }

    public func connect() async throws {
        guard state == .idle else { throw DialtError("invalid_state", "Create a new session for a new call.") }
        try configuration.validate()
        state = .connecting; generation += 1
        let epoch = generation
        do {
            try await handshake(epoch: epoch, reconnecting: false)
            try check(epoch)
            state = .live
            reader = Task { [weak self] in await self?.readLoop(epoch: epoch) }
        } catch {
            if generation == epoch { finish(error: error) }
            throw error
        }
    }

    public func close() { finish(error: nil) }

    func validateForVoice() throws {
        try configuration.validate()
        guard configuration.modality == .voice else { throw DialtError("wrong_modality", "Use DialtSession for text-only sessions.") }
    }

    private func finish(error: (any Error)?) {
        guard state != .closed else { return }
        state = .closed; generation += 1; resumeToken = nil
        reader?.cancel(); reader = nil; wire?.close(); wire = nil
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }

    private func check(_ epoch: Int) throws {
        try Task.checkCancellation()
        guard generation == epoch, state != .closed else { throw CancellationError() }
    }

    private func emit(_ event: DialtEvent) throws {
        if case .dropped = continuation.yield(event) {
            throw DialtError("event_overflow", "Event consumer fell behind; session closed instead of dropping protocol events.")
        }
    }

    private func handshake(epoch: Int, reconnecting: Bool) async throws {
        try check(epoch)
        let candidate = factory(configuration.endpoint)
        wire = candidate
        var timedOut = false
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: configuration.connectTimeout) } catch { return }
            timedOut = true; candidate.close()
        }
        defer { timeout.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await candidate.send(.text(Self.encode(configuration.startFrame(resumeToken: resumeToken, audioFrontend: audioFrontend))))
                var buffered: [DialtEvent] = []
                while true {
                    let event = try Self.decode(await candidate.receive())
                    try check(epoch)
                    if timedOut { throw DialtError("connect_timeout", "Timed out waiting for ready.", retryable: true) }
                    if event.type == "error" { throw Self.serverError(event) }
                    if event.type == "ready" {
                        if configuration.modality == .voice {
                            guard event["audio"]?["output_encoding"] == "pcm16", event["audio"]?["output_sr"] == 16000 else {
                                throw DialtError("unsupported_audio", "Expected negotiated PCM16 mono at 16 kHz.")
                            }
                        }
                        resumeToken = event["resume_token"]?.string
                        sessionUUID = event["session_uuid"]?.string
                        // The lifecycle boundary reaches native audio before any buffered audio.
                        try emit(DialtEvent(type: reconnecting ? "reconnected" : "ready", fields: event.fields))
                        for pending in buffered { try emit(pending) }
                        return
                    }
                    guard buffered.count < 32, event.audio == nil else {
                        throw DialtError("invalid_handshake", "Unexpected audio or too many events before ready.")
                    }
                    buffered.append(event)
                }
            } onCancel: {
                Task { @MainActor in candidate.close() }
            }
        } catch {
            candidate.close()
            if timedOut { throw DialtError("connect_timeout", "Timed out waiting for ready.", retryable: true) }
            throw error
        }
    }

    private func readLoop(epoch: Int) async {
        while generation == epoch, state != .closed {
            guard let current = wire else { return }
            do {
                let event = try Self.decode(await current.receive())
                try check(epoch)
                if event.type == "ready" { throw DialtError("invalid_frame", "Unexpected second ready frame.") }
                try emit(event)
                if event.type == "session_end" {
                    finish(error: nil)
                    return
                }
            } catch {
                guard generation == epoch, state != .closed else { return }
                if error is CancellationError { finish(error: nil); return }
                if error is DialtError || error is DecodingError {
                    finish(error: error); return
                }
                if current.closeCode == 1000, state != .reconnecting {
                    try? emit(DialtEvent(type: "session_end", fields: ["code": 1000]))
                    finish(error: nil); return
                }
                guard configuration.autoReconnect, let token = resumeToken, !token.isEmpty else {
                    finish(error: DialtError("connection_closed", "Connection lost without a resumable session.")); return
                }
                state = .reconnecting; current.close()
                do {
                    try emit(DialtEvent(type: "reconnecting"))
                    var restored = false
                    for attempt in 0..<configuration.maxReconnectAttempts {
                        try check(epoch)
                        if attempt > 0 {
                            let factor = 1 << min(attempt - 1, 5)
                            try await Task.sleep(for: min(.seconds(5), configuration.reconnectBaseDelay * factor))
                        }
                        do {
                            try await handshake(epoch: epoch, reconnecting: true)
                            try check(epoch); state = .live; restored = true; break
                        } catch let failure as DialtError {
                            if !failure.retryable { throw failure }
                        } catch is CancellationError { throw CancellationError() }
                        catch { /* Transport failures retry within the fixed attempt limit. */ }
                    }
                    if !restored { throw DialtError("reconnect_failed", "Session could not be resumed.") }
                } catch {
                    if generation == epoch {
                        if let failure = error as? DialtError, failure.code == "resume_failed" {
                            try? emit(DialtEvent(type: "resume_failed"))
                        }
                        finish(error: error)
                    }
                    return
                }
            }
        }
    }

    /// Audio captured during recovery is discarded, never replayed into a later turn.
    public func sendAudio(_ pcm16: Data) async throws {
        guard configuration.modality == .voice else { throw DialtError("wrong_modality", "Text sessions cannot send audio.") }
        guard pcm16.count % 2 == 0, pcm16.count <= 32_000 else {
            throw DialtError("invalid_audio", "Send at most one second of aligned PCM16 per frame.")
        }
        if state == .reconnecting { return }
        guard !pcm16.isEmpty else { return }
        do { try await send(.binary(pcm16)) }
        catch let error as DialtError where error.code == "reconnecting" {
            // The reader owns recovery. Lost microphone frames must not end the call
            // or be replayed after the connection resumes.
        }
    }

    public func sendText(_ text: String) async throws {
        guard configuration.modality == .text else { throw DialtError("wrong_modality", "sendText requires a text session.") }
        try await sendControl(type: "input_text", fields: ["text": .string(text)])
    }

    public enum ToolOutcome: String, Sendable { case succeeded, failed, cancelled, timedOut = "timed_out", unknown }
    public func sendToolResult(id: String, content: JSONValue, outcome: ToolOutcome = .unknown, verified: Bool = false) async throws {
        guard !verified || outcome == .succeeded else { throw DialtError("invalid_result", "Only successful results may be verified.") }
        try await sendControl(type: "tool_result", fields: ["id": .string(id), "content": content, "outcome": .string(outcome.rawValue), "verified": .bool(verified)])
    }
    public func sendToolProgress(id: String, note: String) async throws {
        try await sendControl(type: "tool_progress", fields: ["id": .string(id), "note": .string(note)])
    }
    public func deferTool(id: String, handle: String) async throws {
        try await sendControl(type: "tool_deferred", fields: ["id": .string(id), "handle": .string(handle)])
    }
    public func cancelTool(id: String) async throws {
        try await sendControl(type: "tool_cancel", fields: ["id": .string(id)])
    }
    public func finishInputTurn() async throws {
        try await sendControl(type: "client_event", fields: ["event": "input_audio_done"])
    }

    /// Advanced wire operations. Read the corresponding acknowledgement from events.
    /// Mode mutations are intentionally excluded until their acknowledgement/replay contracts
    /// have typed SDK support; a reconnect must never silently replay obsolete configuration.
    public func sendControl(type: String, fields: [String: JSONValue] = [:]) async throws {
        let allowed: Set<String> = ["input_text", "tool_result", "tool_progress", "tool_deferred", "tool_cancel",
            "tool_partial_result", "tool_interaction_update", "resolve_tool_permission", "client_event", "inject_context", "wrap_up"]
        guard allowed.contains(type), fields["type"] == nil else { throw DialtError("unsupported_control", "Unsupported control frame or reserved type field.") }
        var frame = fields; frame["type"] = .string(type)
        try await send(.text(Self.encode(frame)))
    }

    private func send(_ message: WireMessage) async throws {
        guard state == .live, let current = wire else {
            throw DialtError(state == .reconnecting ? "reconnecting" : "connection_closed", "Session is not live.", retryable: state == .reconnecting)
        }
        let epoch = generation
        do { try await current.send(message) }
        catch {
            try check(epoch)
            guard !(error is CancellationError), !(error is DialtError) else { throw error }
            if configuration.autoReconnect, let token = resumeToken, !token.isEmpty {
                if wire === current {
                    state = .reconnecting
                    current.close() // Wake receive(); its single reader performs recovery.
                }
                throw DialtError("reconnecting", "Send failed; session recovery is in progress. The frame was not replayed.", retryable: true)
            }
            finish(error: error)
            throw error
        }
        try check(epoch)
    }

    static func encode(_ frame: [String: JSONValue]) throws -> String {
        String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)
    }
    static func decode(_ raw: WireMessage) throws -> DialtEvent {
        switch raw {
        case .binary(let data):
            guard data.count % 2 == 0 else { throw DialtError("invalid_audio", "Unaligned PCM16 received.") }
            return DialtEvent(type: "audio", audio: data)
        case .text(let text):
            let fields = try JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8))
            guard let type = fields["type"]?.string, !type.isEmpty else { throw DialtError("invalid_frame", "Event has no type.") }
            return DialtEvent(type: type, fields: fields)
        }
    }
    private static func serverError(_ event: DialtEvent) -> DialtError {
        DialtError(event["code"]?.string ?? "server_error", event["detail"]?.string ?? "Session rejected.", retryable: event["retryable"]?.bool ?? false)
    }
}
