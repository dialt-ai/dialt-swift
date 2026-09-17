import Foundation
import Testing
@testable import Dialt

@MainActor final class MockWire: DialtTransport {
    var closeCode: Int?
    var sent: [WireMessage] = []
    var closed = false
    private let stream: AsyncThrowingStream<WireMessage, any Error>
    private let continuation: AsyncThrowingStream<WireMessage, any Error>.Continuation
    private var iterator: AsyncThrowingStream<WireMessage, any Error>.Iterator
    init() {
        let pair = AsyncThrowingStream<WireMessage, any Error>.makeStream()
        stream = pair.stream; continuation = pair.continuation; iterator = stream.makeAsyncIterator()
    }
    func send(_ message: WireMessage) async throws {
        if closed { throw URLError(.networkConnectionLost) }
        sent.append(message)
    }
    func receive() async throws -> WireMessage {
        var it = iterator
        guard let value = try await it.next() else { throw URLError(.networkConnectionLost) }
        iterator = it
        return value
    }
    func close() { closed = true; continuation.finish() }
    func push(_ frame: [String: JSONValue]) { continuation.yield(.text(try! DialtSession.encode(frame))) }
    func audio(_ data: Data) { continuation.yield(.binary(data)) }
    func ready(token: String = "resume-one", encoding: String = "pcm16", rate: Int = 16000) {
        push(["type": "ready", "resume_token": .string(token), "session_uuid": "server-uuid",
              "audio": ["output_encoding": .string(encoding), "output_sr": .number(Double(rate))]])
    }
    func disconnect(code: Int = 1006) { closeCode = code; continuation.finish(throwing: URLError(.networkConnectionLost)) }
    var frames: [[String: JSONValue]] { sent.compactMap { if case .text(let s) = $0 { return try? JSONDecoder().decode([String: JSONValue].self, from: Data(s.utf8)) }; return nil } }
}

@MainActor func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Condition was not reached within one second")
}

@MainActor final class FakeAudio: VoiceAudio {
    let microphone: AsyncThrowingStream<Data, any Error>
    let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    var voiceProcessingEnabled = true
    var started = false
    var stopped = false
    var clearCount = 0
    var played: [Data] = []
    var pending = PlaybackSnapshot(pendingMilliseconds: 200, remainingMilliseconds: 260, deviceLatencyMilliseconds: 10)
    init() {
        let pair = AsyncThrowingStream<Data, any Error>.makeStream()
        microphone = pair.stream; continuation = pair.continuation
    }
    func start() async throws { started = true }
    func stop() { stopped = true; continuation.finish() }
    func enqueue(_ data: Data) throws { played.append(data) }
    func snapshot() -> PlaybackSnapshot { pending }
    func clearPlayback() { clearCount += 1 }
}
