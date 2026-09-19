import Foundation
import AVFoundation
import Testing
@testable import Dialt

struct PCMTests {
    @Test func clipsHandlesNonfiniteAndPreservesEndian() throws {
        let pcm = DialtPCM.encode([-2, -1, 0, 0.5, 1, 2, .nan, .infinity])
        #expect(Array(pcm) == [0,128,0,128,0,0,0,64,255,127,255,127,0,0,0,0])
        let decoded = try DialtPCM.decode(pcm)
        #expect(decoded[0] == -1); #expect(decoded[3] == 0.5)
        #expect(throws: DialtError.self) { try DialtPCM.decode(Data([0])) }
    }
    @Test func playbackAccountingExcludesJitterAndHandlesPartialChunks() {
        var timeline = PlaybackTimeline()
        #expect(timeline.schedule(frames: 1600, cursor: 0, lead: 960) == 960)
        #expect(timeline.schedule(frames: 800, cursor: 400, lead: 0) == 2560)
        #expect(timeline.pendingFrames(cursor: 0) == 2400)
        #expect(timeline.remainingFrames(cursor: 0) == 3360)
        #expect(timeline.pendingFrames(cursor: 1760) == 1600)
        #expect(timeline.pendingFrames(cursor: 4000) == 0)
        timeline.clear()
        #expect(timeline.schedule(frames: 320, cursor: 0, lead: 960) == 960)
    }
    @Test func resamplesStereo48kToPacedMono16k() async throws {
        let pair = AsyncThrowingStream<Data, any Error>.makeStream()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let processor = try CaptureProcessor(inputFormat: format, continuation: pair.continuation)
        for frame in 0..<50 {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
            buffer.frameLength = 960
            for c in 0..<2 { for i in 0..<960 { buffer.floatChannelData![c][i] = Float(sin(2 * .pi * 440 * Double(frame * 960 + i) / 48000)) * 0.2 } }
            processor.process(buffer)
        }
        pair.continuation.finish()
        var packets: [Data] = []
        for try await packet in pair.stream { packets.append(packet) }
        #expect((24...25).contains(packets.count))
        #expect(packets.allSatisfy { $0.count == 1280 })
        let signal = try DialtPCM.decode(packets.dropFirst().reduce(Data(), +))
        let rms = sqrt(signal.reduce(0.0) { $0 + Double($1 * $1) } / Double(signal.count))
        #expect(rms > 0.12 && rms < 0.16)
    }
}

@Suite @MainActor struct VoiceTests {
    @Test func microphoneSendFailureResumesWithoutStoppingCapture() async throws {
        let first = MockWire(); first.ready()
        let second = MockWire()
        var wires = [first, second]
        let audio = FakeAudio()
        let client = DialtVoiceClient(configuration: .init(apiKey: "test"), audio: audio, factory: { _ in wires.removeFirst() })
        defer { client.close() }
        try await client.connect()
        first.failNextSend = true
        audio.continuation.yield(Data([1, 0]))
        try await eventually { client.session.state != .live }
        #expect(client.session.state == .reconnecting)
        #expect(!audio.stopped)
        guard client.session.state == .reconnecting else { return }
        try await eventually { !second.frames.isEmpty }
        second.ready()
        try await eventually { client.session.state == .live }
        audio.continuation.yield(Data([2, 0]))
        try await eventually { second.sent.count == 2 }
        #expect(second.sent.count == 2) // Only start + new mic audio; failed audio is never replayed.
    }

    @Test func interruptClearReportsDiscardAndDrainRetainsQueue() async throws {
        let wire = MockWire(); wire.ready()
        let audio = FakeAudio()
        let client = DialtVoiceClient(configuration: .init(apiKey: "test"), audio: audio, factory: { _ in wire })
        defer { client.close() }
        try await client.connect()
        wire.push(["type": "turn"]); wire.audio(Data([0, 0]))
        wire.push(["type": "interrupted", "clear": true, "barge_seq": 7])
        wire.audio(Data([1, 0]))
        try await eventually { wire.frames.contains { $0["barge_seq"] == 7 } }
        #expect(audio.clearCount == 1)
        #expect(audio.played == [Data([0, 0])])
        let report = try #require(wire.frames.last)
        #expect(report["discarded_ms"] == 200)
        #expect(report["remaining_ms"] == 10)
        wire.push(["type": "interrupted", "clear": false, "barge_seq": 8])
        try await eventually { wire.frames.last?["barge_seq"] == 8 }
        #expect(wire.frames.last?["discarded_ms"] == 0)
        #expect(wire.frames.last?["remaining_ms"] == 270)
        #expect(audio.clearCount == 1)
    }

    @Test func lostPlaybackReportDoesNotPreventRecovery() async throws {
        let first = MockWire(); first.ready()
        let second = MockWire()
        var wires = [first, second]
        let audio = FakeAudio()
        let client = DialtVoiceClient(configuration: .init(apiKey: "test"), audio: audio, factory: { _ in wires.removeFirst() })
        defer { client.close() }
        try await client.connect()
        first.failNextSend = true
        first.push(["type": "interrupted", "clear": true, "barge_seq": 3])
        try await eventually { client.session.state != .live }
        #expect(client.session.state == .reconnecting)
        #expect(!audio.stopped)
        guard client.session.state == .reconnecting else { return }
        second.ready()
        try await eventually { client.session.state == .live }
        #expect(second.frames.count == 1)
    }

    @Test func explicitSessionEndIsLastVoiceEventAndDrainsFarewell() async throws {
        let wire = MockWire(); wire.ready()
        let audio = FakeAudio()
        let client = DialtVoiceClient(configuration: .init(apiKey: "test"), audio: audio, factory: { _ in wire })
        defer { client.close() }
        try await client.connect()
        wire.push(["type": "turn"])
        wire.audio(Data([0, 0]))
        wire.push(["type": "done"])
        wire.push(["type": "tool_call", "id": "before", "name": "fixture", "args": [:]])
        wire.push(["type": "session_end", "reason": "ended_by_model"])
        wire.push(["type": "tool_call", "id": "after", "name": "fixture", "args": [:]])
        try await eventually { client.session.state == .closed }
        var events: [DialtEvent] = []
        for try await event in client.events { events.append(event) }
        #expect(events.map(\.type) == ["ready", "turn", "done", "tool_call", "session_end"])
        #expect(events[3]["id"] == "before")
        #expect(audio.played == [Data([0, 0])])
        #expect(audio.clearCount == 0)
        #expect(audio.stopped)
    }

    @Test func cancellationClearsAndDeviceFailureClosesSession() async throws {
        let wire = MockWire(); wire.ready()
        let audio = FakeAudio()
        let client = DialtVoiceClient(configuration: .init(apiKey: "test"), audio: audio, factory: { _ in wire })
        try await client.connect()
        wire.push(["type": "canceled"])
        try await eventually { audio.clearCount == 1 }
        audio.continuation.finish(throwing: DialtError("audio_route_changed", "route changed"))
        try await eventually { audio.stopped && wire.closed }
        #expect(client.session.state == .closed)
    }
}
