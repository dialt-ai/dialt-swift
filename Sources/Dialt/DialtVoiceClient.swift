import Foundation

/// Native duplex voice, including microphone capture, echo cancellation and playback.
/// Own one client per call and explicitly close it when leaving the call screen.
@MainActor public final class DialtVoiceClient {
    public let session: DialtSession
    public let events: AsyncThrowingStream<DialtEvent, any Error>
    private let continuation: AsyncThrowingStream<DialtEvent, any Error>.Continuation
    private let audio: any VoiceAudio
    private var eventTask: Task<Void, Never>?
    private var micTask: Task<Void, Never>?
    private var closed = false
    private var connecting = false
    private var responding = false
    private var reconnecting = false

    public convenience init(configuration: DialtConfiguration) {
        self.init(configuration: configuration, audio: NativeAudioEngine(), factory: { WebSocketTransport(url: $0) })
    }
    init(configuration: DialtConfiguration, audio: any VoiceAudio,
         factory: @escaping @MainActor (URL) -> any DialtTransport) {
        self.audio = audio
        session = DialtSession(configuration: configuration, audioFrontend: "unknown", factory: factory)
        let pair = AsyncThrowingStream<DialtEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        events = pair.stream; continuation = pair.continuation
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.close() } }
    }

    public func connect() async throws {
        guard !closed, !connecting, eventTask == nil else { throw DialtError("invalid_state", "Create a new voice client for each call.") }
        connecting = true
        defer { connecting = false }
        do {
            try await audio.start()
            guard !closed else { throw CancellationError() }
            micTask = Task { [weak self, audio, session] in
                do {
                    for try await packet in audio.microphone {
                        try Task.checkCancellation()
                        if session.state == .live { try await session.sendAudio(packet) }
                    }
                    if self?.closed == false { self?.fail(DialtError("capture_ended", "Microphone capture ended.")) }
                } catch { self?.fail(error) }
            }
            try await session.connect()
            guard !closed else { throw CancellationError() }
            eventTask = Task { [weak self, session] in
                do {
                    for try await event in session.events {
                        guard let self, !self.closed else { return }
                        try await self.handle(event)
                        if event.audio == nil, case .dropped = self.continuation.yield(event) {
                            throw DialtError("event_overflow", "Voice event consumer fell behind.")
                        }
                    }
                    // Clean server end can follow done while the final words are still queued.
                    if let self, !self.closed {
                        let remaining = self.audio.snapshot().remainingMilliseconds + self.audio.snapshot().deviceLatencyMilliseconds
                        try await Task.sleep(for: .milliseconds(min(remaining, 11_000)))
                        self.close()
                    }
                } catch { self?.fail(error) }
            }
        } catch { fail(error); throw error }
    }

    func handle(_ event: DialtEvent) async throws {
        switch event.type {
        case "turn": responding = true
        case "audio":
            if responding, let pcm = event.audio { try audio.enqueue(pcm) }
        case "done": responding = false
        case "canceled": responding = false; audio.clearPlayback()
        case "interrupted":
            responding = false
            let snapshot = audio.snapshot()
            let clear = event["clear"]?.bool ?? false
            if clear { audio.clearPlayback() }
            var fields: [String: JSONValue] = [
                "event": "playback_stopped",
                "remaining_ms": .number((clear ? 0 : snapshot.remainingMilliseconds) + snapshot.deviceLatencyMilliseconds),
                "discarded_ms": .number(clear ? snapshot.pendingMilliseconds : 0)
            ]
            if let sequence = event["barge_seq"] { fields["barge_seq"] = sequence }
            try await session.sendControl(type: "client_event", fields: fields)
        case "reconnecting":
            reconnecting = true; responding = false; audio.clearPlayback()
        case "reconnected": reconnecting = false
        default: break
        }
    }

    public func setMuted(_ muted: Bool) { (audio as? NativeAudioEngine)?.setMuted(muted) }
    public func close() {
        guard !closed else { return }
        closed = true; micTask?.cancel(); eventTask?.cancel()
        micTask = nil; eventTask = nil; audio.stop(); session.close(); continuation.finish()
    }
    private func fail(_ error: any Error) {
        guard !closed else { return }
        continuation.finish(throwing: error); close()
    }
}
