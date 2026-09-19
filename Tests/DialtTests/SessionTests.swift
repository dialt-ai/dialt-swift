import Foundation
import Testing
@testable import Dialt

@Suite @MainActor struct SessionTests {
    @Test func handshakeAndToolRoundTrip() async throws {
        let wire = MockWire(); wire.ready()
        let config = DialtConfiguration(apiKey: "scoped-test", sessionID: "bound-id", mode: ["instructions": "Help", "tools": [["name": "lookup", "parameters": ["type": "object"]]]])
        let session = DialtSession(configuration: config, factory: { _ in wire })
        defer { session.close() }
        try await session.connect()
        #expect(session.state == .live)
        #expect(session.sessionUUID == "server-uuid")
        let start = try #require(wire.frames.first)
        #expect(start["api_key"] == "scoped-test")
        #expect(start["session_id"] == "bound-id")
        #expect(start["audio"]?["sr"] == 16000)
        #expect(start["mode"]?["kind"] == "dialt")
        #expect(start["client"]?["capabilities"] == [])
        wire.push(["type": "tool_call", "id": "t1", "name": "lookup", "args": ["customer": "42"]])
        var iterator = session.events.makeAsyncIterator()
        #expect(try await iterator.next()?.type == "ready")
        let call = try #require(try await iterator.next())
        #expect(call["args"]?["customer"] == "42")
        try await session.sendToolResult(id: "t1", content: ["balance": 12], outcome: .succeeded, verified: true)
        #expect(wire.frames.last?["type"] == "tool_result")
        #expect(wire.frames.last?["verified"] == true)
    }

    @Test func textModeOmitsAudioAndRejectsMicrophone() async throws {
        let wire = MockWire(); wire.push(["type": "ready"])
        let session = DialtSession(configuration: .init(apiKey: "test", modality: .text), factory: { _ in wire })
        defer { session.close() }
        try await session.connect()
        #expect(wire.frames[0]["audio"] == nil)
        #expect(wire.frames[0]["mode"]?["modality"] == "text")
        try await session.sendText("hello")
        #expect(wire.frames.last?["text"] == "hello")
        await #expect(throws: DialtError.self) { try await session.sendAudio(Data([0, 0])) }
    }

    @Test(arguments: [("pcm_f32le", 16000), ("pcm16", 24000)])
    func rejectsNegotiatedMismatch(encoding: String, rate: Int) async throws {
        let wire = MockWire(); wire.ready(encoding: encoding, rate: rate)
        let session = DialtSession(configuration: .init(apiKey: "test"), factory: { _ in wire })
        await #expect(throws: DialtError.self) { try await session.connect() }
        #expect(wire.closed); #expect(session.state == .closed)
    }

    @Test func handshakeTimeoutAndCancellationReleaseWire() async throws {
        let wire = MockWire()
        var config = DialtConfiguration(apiKey: "test"); config.connectTimeout = .milliseconds(20)
        let session = DialtSession(configuration: config, factory: { _ in wire })
        await #expect(throws: DialtError.self) { try await session.connect() }
        #expect(wire.closed); #expect(session.state == .closed)
        let other = MockWire()
        config.connectTimeout = .seconds(15)
        let cancelled = DialtSession(configuration: config, factory: { _ in other })
        let task = Task { try await cancelled.connect() }
        try await eventually { !other.sent.isEmpty }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(other.closed)
    }

    @Test func reconnectRotatesTokenAndNeverReplaysMicrophone() async throws {
        let first = MockWire(); first.ready(token: "one")
        let second = MockWire()
        var wires = [first, second]
        let session = DialtSession(configuration: .init(apiKey: "test", mode: ["voice": "classic"]), factory: { _ in wires.removeFirst() })
        defer { session.close() }
        try await session.connect()
        first.disconnect()
        try await eventually { session.state == .reconnecting && !second.frames.isEmpty }
        try await session.sendAudio(Data([1, 0]))
        await #expect(throws: DialtError.self) { try await session.sendToolProgress(id: "x", note: "working") }
        #expect(second.sent.count == 1)
        #expect(second.frames.first?["resume_token"] == "one")
        #expect(second.frames.first?["mode"]?["voice"] == "classic")
        second.ready(token: "two")
        try await eventually { session.state == .live }
        #expect(second.sent.count == 1)
    }

    @Test func cleanCloseDoesNotReconnect() async throws {
        let wire = MockWire(); wire.ready()
        var creations = 0
        let session = DialtSession(configuration: .init(apiKey: "test"), factory: { _ in creations += 1; return wire })
        try await session.connect(); wire.disconnect(code: 1000)
        try await eventually { session.state == .closed }
        #expect(creations == 1)
        var names: [String] = []
        for try await event in session.events { names.append(event.type) }
        #expect(names == ["ready", "session_end"])
    }

    @Test func explicitSessionEndStopsDispatchAndRejectsLateResults() async throws {
        let wire = MockWire(); wire.ready()
        var creations = 0
        let session = DialtSession(configuration: .init(apiKey: "test"), factory: { _ in creations += 1; return wire })
        defer { session.close() }
        try await session.connect()
        wire.push(["type": "tool_call", "id": "before", "name": "fixture", "args": [:]])
        wire.push(["type": "session_end", "reason": "ended_by_model", "extra": "preserved"])
        wire.push(["type": "tool_call", "id": "after", "name": "fixture", "args": [:]])
        try await eventually { session.state == .closed }
        var events: [DialtEvent] = []
        for try await event in session.events { events.append(event) }
        #expect(events.map(\.type) == ["ready", "tool_call", "session_end"])
        #expect(events[1]["id"] == "before")
        #expect(events.last?["extra"] == "preserved")
        #expect(wire.closed)
        #expect(creations == 1)
        do {
            try await session.sendToolResult(id: "before", content: [:])
            Issue.record("A result after session_end must not be sent")
        } catch let error as DialtError { #expect(error.code == "connection_closed") }
        #expect(wire.frames.count == 1)
    }

    @Test func rejectedResumeIsTerminal() async throws {
        let first = MockWire(); first.ready()
        let second = MockWire(); second.push(["type": "error", "code": "resume_failed", "detail": "expired"])
        var wires = [first, second]
        let session = DialtSession(configuration: .init(apiKey: "test"), factory: { _ in wires.removeFirst() })
        try await session.connect(); first.disconnect()
        try await eventually { session.state == .closed }
        #expect(second.closed)
        var events: [String] = []
        do { for try await event in session.events { events.append(event.type) }; Issue.record("Expected terminal error") }
        catch let error as DialtError { #expect(error.code == "resume_failed") }
        #expect(events.contains("resume_failed"))
    }

    @Test func invalidFramesAndOverflowFailExplicitly() async throws {
        let wire = MockWire(); wire.ready()
        let session = DialtSession(configuration: .init(apiKey: "test"), factory: { _ in wire })
        try await session.connect()
        for _ in 0..<270 { wire.push(["type": "future_event", "new_field": 42]) }
        try await eventually { session.state == .closed }
        #expect(wire.closed)
        #expect(throws: DialtError.self) { try DialtSession.decode(.binary(Data([1]))) }
        #expect(throws: DialtError.self) { try DialtSession.decode(.text("{}")) }
    }

    @Test func closeDuringHandshakeCannotResurrectSession() async throws {
        let wire = MockWire()
        let session = DialtSession(configuration: .init(apiKey: "test"), factory: { _ in wire })
        let task = Task { try await session.connect() }
        try await eventually { !wire.sent.isEmpty }
        session.close(); wire.ready()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(session.state == .closed)
    }
}
