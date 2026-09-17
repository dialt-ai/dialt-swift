import Foundation
import Testing
@testable import Dialt

@MainActor final class MockWire: DialtTransport {
    var closeCode: Int?
    var sent: [WireMessage] = []
    var closed = false
    var failNextSend = false
    private var queued: [WireMessage] = []
    private var waiter: CheckedContinuation<WireMessage, any Error>?
    func send(_ message: WireMessage) async throws {
        if failNextSend { failNextSend = false; throw URLError(.networkConnectionLost) }
        if closed { throw URLError(.networkConnectionLost) }
        sent.append(message)
    }
    func receive() async throws -> WireMessage {
        if !queued.isEmpty { return queued.removeFirst() }
        if closed { throw URLError(.networkConnectionLost) }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close() { closeCode = closeCode ?? 1000; closed = true; waiter?.resume(throwing: URLError(.networkConnectionLost)); waiter = nil }
    private func yield(_ message: WireMessage) {
        guard !closed else { return }
        if let pending = waiter { waiter = nil; pending.resume(returning: message) }
        else { queued.append(message) }
    }
    func push(_ frame: [String: JSONValue]) { yield(.text(try! DialtSession.encode(frame))) }
    func audio(_ data: Data) { yield(.binary(data)) }
    func ready(token: String = "resume-one", encoding: String = "pcm16", rate: Int = 16000) {
        push(["type": "ready", "resume_token": .string(token), "session_uuid": "server-uuid",
              "audio": ["output_encoding": .string(encoding), "output_sr": .number(Double(rate))]])
    }
    func disconnect(code: Int = 1006) { closeCode = code; close() }
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
