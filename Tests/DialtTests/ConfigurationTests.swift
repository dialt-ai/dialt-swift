import Foundation
import AVFoundation
import Testing
@testable import Dialt

struct ConfigurationTests {
    @Test(arguments: ["http://example.com", "ws://example.com/ws", "wss://user:password@example.com/ws"])
    func rejectsUnsafeEndpoints(url: String) throws {
        let config = DialtConfiguration(apiKey: "test", endpoint: URL(string: url)!)
        #expect(throws: DialtError.self) { try config.validate() }
    }
    @Test func validConfigurationAndReservedFields() throws {
        try DialtConfiguration(apiKey: "test").validate()
        try DialtConfiguration(apiKey: "test", endpoint: URL(string: "ws://127.0.0.1:9999/ws")!).validate()
        for mode: [String: JSONValue] in [["kind": "relay"], ["modality": "text"], ["background_audio": true]] {
            #expect(throws: DialtError.self) { try DialtConfiguration(apiKey: "test", mode: mode).validate() }
        }
    }
    @Test func JSONRoundTripPreservesToolsAndUnknownFields() throws {
        let value: JSONValue = ["name": "tool", "schema": ["required": ["id"], "properties": ["id": ["type": "string"]]],
                               "enabled": true, "count": 3, "nothing": .null]
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) == value)
    }
}

@Suite @MainActor struct LifecycleRegressionTests {
    @Test func voiceClientRejectsTextBeforeRequestingMic() async throws {
        let audio = FakeAudio(); let wire = MockWire(); wire.ready()
        let client = DialtVoiceClient(configuration: .init(apiKey: "test", modality: .text), audio: audio, factory: { _ in wire })
        defer { client.close() }
        await #expect(throws: DialtError.self) { try await client.connect() }
        #expect(!audio.started)
    }
    @Test func mutedCaptureStillEmitsPacedSilence() async throws {
        let pair = AsyncThrowingStream<Data, any Error>.makeStream()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let processor = try CaptureProcessor(inputFormat: format, continuation: pair.continuation)
        processor.setMuted(true)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 640)!
        buffer.frameLength = 640
        for i in 0..<640 { buffer.floatChannelData![0][i] = 0.5 }
        processor.process(buffer); pair.continuation.finish()
        var iterator = pair.stream.makeAsyncIterator()
        #expect(try await iterator.next() == Data(repeating: 0, count: 1280))
    }
}
