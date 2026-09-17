import Dialt
import Foundation
import AVFoundation

@main struct Diagnostics {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        switch args.dropFirst().first {
        case "aec":
            guard args.count == 4 else { throw DialtError("usage", "Usage: dialt-diagnostics aec speech.wav output-directory") }
            try await aec(input: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]))
        case "live": try await live()
        default:
            print("""
            dialt-diagnostics aec speech.wav output-directory
              Plays speech through the selected speakers and records raw/processed microphone
              locally, twice each. Use built-in speakers and mic, quiet room, fixed volume.
              No network requests. AEC does not run in offline/manual rendering mode.
            dialt-diagnostics live
              Opens a short paid text session, exercises a harmless tool call and verifies reply.
              Reads DIALT_API_KEY, optional DIALT_ENDPOINT and DIALT_SESSION_ID from environment.
            """)
        }
    }

    @MainActor static func live() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["DIALT_API_KEY"], !key.isEmpty else { throw DialtError("missing_key", "Set DIALT_API_KEY via your local credential loader.") }
        let tool: JSONValue = ["name": "lookup_test_colour", "description": "Look up the diagnostic test colour.", "parameters": ["type": "object", "properties": [:]], "read_only": true]
        let config = DialtConfiguration(apiKey: key, sessionID: env["DIALT_SESSION_ID"] ?? UUID().uuidString,
            modality: .text, mode: ["greeting": false, "instructions": "Use lookup_test_colour to answer the test colour question, then state the result briefly.", "tools": .array([tool])],
            endpoint: env["DIALT_ENDPOINT"].flatMap(URL.init(string:)) ?? DialtConfiguration.defaultEndpoint)
        let session = DialtSession(configuration: config)
        defer { session.close() }
        try await session.connect()
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(45))
            if !Task.isCancelled { session.close() }
        }
        defer { timeout.cancel() }
        try await session.sendText("What is the diagnostic test colour?")
        var toolCalled = false
        var transcript = ""
        for try await event in session.events {
            if event.type == "error" { throw DialtError("server_error", event["detail"]?.string ?? "Server error") }
            if event.type == "tool_call", event["name"] == "lookup_test_colour", let id = event["id"]?.string {
                toolCalled = true
                try await session.sendToolResult(id: id, content: ["colour": "turquoise"], outcome: .succeeded, verified: true)
            }
            if event.type == "utterance" { transcript += event["text"]?.string ?? "" }
            if event.type == "done", toolCalled, transcript.lowercased().contains("turquoise") {
                print("PASS: live authentication, text turn, tool dispatch/result, final reply, clean client close.")
                return
            }
        }
        throw DialtError("live_test_failed", "Did not receive the expected tool call and final answer before the deadline.")
    }

    @MainActor static func aec(input: URL, output: URL) async throws {
        let file = try AVAudioFile(forReading: input)
        guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
              file.length >= 64_000, file.length <= 320_000,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw DialtError("invalid_fixture", "Use 4–20 seconds of 16 kHz mono speech in a WAV file.")
        }
        try file.read(into: buffer)
        guard let source = buffer.floatChannelData?[0] else { throw DialtError("invalid_fixture", "Cannot decode speech fixture.") }
        let samples = Array(UnsafeBufferPointer(start: source, count: Int(buffer.frameLength)))
        let stimulus = DialtPCM.encode(samples)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var measures: [[String: JSONValue]] = []
        for (index, enabled) in [false, true, true, false].enumerated() {
            print("Take \(index + 1)/4: voice processing \(enabled ? "ON" : "OFF"). Please stay quiet.")
            let audio = NativeAudioEngine(voiceProcessing: enabled)
            do {
                try await audio.start()
                let capture = Task { @MainActor in
                    var recording = Data()
                    for try await chunk in audio.microphone { recording.append(chunk) }
                    return recording
                }
                try await Task.sleep(for: .seconds(1))
                // Short frames keep exactly the same streaming playback path as a voice session.
                for offset in stride(from: 0, to: stimulus.count, by: 1280) {
                    try audio.enqueue(Data(stimulus[offset..<min(offset + 1280, stimulus.count)]))
                    try await Task.sleep(for: .milliseconds(40))
                }
                try await Task.sleep(for: .seconds(1))
                let wasEnabled = audio.voiceProcessingEnabled
                audio.stop()
                let recording = try await capture.value
                try writeWAV(recording, to: output.appendingPathComponent("take-\(index + 1)-\(enabled ? "aec" : "raw").wav"))
                let decoded = try DialtPCM.decode(recording)
                let end = min(decoded.count, 16_000 + samples.count)
                guard end > 48_000 else { throw DialtError("capture_missing", "Too little microphone audio was captured.") }
                let speech = Array(decoded[48_000..<end]) // Exclude convergence/startup.
                let rms = sqrt(speech.reduce(0.0) { $0 + Double($1 * $1) } / Double(speech.count))
                let noise = Array(decoded.prefix(12_000))
                let noiseRMS = sqrt(noise.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, noise.count)))
                let db = 20 * log10(max(rms, 1e-9))
                measures.append(["take": .number(Double(index + 1)), "aec": .bool(enabled), "confirmed_enabled": .bool(wasEnabled),
                                 "capture_samples": .number(Double(decoded.count)), "speech_rms_dbfs": .number(db),
                                 "noise_rms_dbfs": .number(20 * log10(max(noiseRMS, 1e-9)))])
                print("Captured \(decoded.count) samples, RMS \(String(format: "%.1f", db)) dBFS.")
            } catch { audio.stop(); throw error }
            try await Task.sleep(for: .seconds(1))
        }
        let raw = measures.filter { $0["aec"] == false }.compactMap { $0["speech_rms_dbfs"]?.number }
        let processed = measures.filter { $0["aec"] == true }.compactMap { $0["speech_rms_dbfs"]?.number }
        let reduction = raw.reduce(0, +) / 2 - processed.reduce(0, +) / 2
        let audibleEcho = measures.filter { $0["aec"] == false }.allSatisfy {
            ($0["speech_rms_dbfs"]?.number ?? -180) > ($0["noise_rms_dbfs"]?.number ?? 0) + 10
        }
        let passed = audibleEcho && reduction >= 10
        let report: JSONValue = ["test": "local acoustic far-end-only A/B", "raw_echo_above_noise": .bool(audibleEcho),
            "mean_reduction_db": .number(reduction), "passed": .bool(passed), "takes": .array(measures.map(JSONValue.object)),
            "scope": "This measures far-end attenuation including noise suppression. It does not certify double-talk, ASR quality, Bluetooth or iOS."]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output.appendingPathComponent("report.json"))
        print("\(passed ? "PASS" : "FAIL/INCONCLUSIVE"): far-end reduction \(String(format: "%.1f", reduction)) dB. Report: \(output.path)/report.json")
        if !passed { throw DialtError("aec_test_failed", "AEC reduction below 10 dB or raw echo too close to room noise. Inspect report and recordings.") }
    }

    static func writeWAV(_ pcm: Data, to url: URL) throws {
        var data = Data()
        func text(_ value: String) { data.append(Data(value.utf8)) }
        func word(_ value: UInt32, bytes: Int) { for i in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (i * 8))) } }
        text("RIFF"); word(UInt32(36 + pcm.count), bytes: 4); text("WAVEfmt "); word(16, bytes: 4)
        word(1, bytes: 2); word(1, bytes: 2); word(16000, bytes: 4); word(32000, bytes: 4)
        word(2, bytes: 2); word(16, bytes: 2); text("data"); word(UInt32(pcm.count), bytes: 4); data.append(pcm)
        try data.write(to: url)
    }
}
