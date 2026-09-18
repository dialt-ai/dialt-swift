import Dialt
import Foundation
import AVFoundation

@main struct Diagnostics {
    @MainActor static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    static func log(_ message: String) { FileHandle.standardOutput.write(Data((message + "\n").utf8)) }
    @MainActor static func run() async throws {
        let args = CommandLine.arguments
        switch args.dropFirst().first {
        case "aec":
            guard args.count == 4 else { throw DialtError("usage", "Usage: dialt-diagnostics aec speech.wav output-directory") }
            try await aec(input: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]))
        case "live": try await live()
        case "audio-check": try await audioCheck()
        case "live-voice":
            guard args.count == 3 else { throw DialtError("usage", "Usage: dialt-diagnostics live-voice synthetic-question.wav") }
            try await live(speech: readSpeech(URL(fileURLWithPath: args[2])))
        default:
            print("""
            dialt-diagnostics aec speech.wav output-directory
              Plays speech through the selected speakers and records raw/processed microphone
              locally, twice each. Use built-in speakers and mic, quiet room, fixed volume.
              No network requests. AEC does not run in offline/manual rendering mode.
            dialt-diagnostics live
              Opens a short paid text session, exercises a harmless tool call and verifies reply.
              Reads DIALT_API_KEY, optional DIALT_ENDPOINT and DIALT_SESSION_ID from environment.
            dialt-diagnostics live-voice synthetic-question.wav
              Uploads the provided synthetic speech to test ASR, tool dispatch and reply audio.
              Ask 'What is the diagnostic test colour?' in mono 16 kHz WAV. No microphone.
            dialt-diagnostics audio-check
              Tests native capture, mute, playback accounting, clear and stop locally.
            """)
        }
    }

    @MainActor static func audioCheck() async throws {
        // Back-to-back calls exercise VPIO teardown as well as a single call's lifecycle.
        for _ in 0..<3 { try await audioCheckOnce() }
        print("PASS: three native AEC capture/mute/playback/clear/shutdown cycles.")
    }

    @MainActor static func audioCheckOnce() async throws {
        @MainActor final class CaptureCheck {
            var packets = 0
            var checkMute = false
            var mutedPackets = 0
            var nonzeroMutedPackets = 0
        }
        let audio = NativeAudioEngine()
        defer { audio.stop() }
        try await audio.start()
        let check = CaptureCheck()
        let capture = Task { @MainActor in
            for try await packet in audio.microphone {
                check.packets += 1
                if check.checkMute {
                    check.mutedPackets += 1
                    if packet.contains(where: { $0 != 0 }) { check.nonzeroMutedPackets += 1 }
                }
            }
        }
        defer { capture.cancel() }
        try await Task.sleep(for: .seconds(1))
        guard check.packets >= 10, audio.voiceProcessingEnabled else { throw DialtError("capture_missing", "Native AEC capture did not produce paced frames.") }
        audio.setMuted(true)
        try await Task.sleep(for: .milliseconds(250))
        check.checkMute = true
        try await Task.sleep(for: .milliseconds(500))
        guard check.mutedPackets >= 5, check.nonzeroMutedPackets == 0 else { throw DialtError("mute_failed", "Muted microphone did not emit silence.") }
        // Queue silence: this checks real renderer accounting without adding room noise.
        try audio.enqueue(Data(repeating: 0, count: 32000))
        guard audio.snapshot().pendingMilliseconds > 500 else { throw DialtError("playback_failed", "Queued playback was not accounted for.") }
        audio.clearPlayback()
        guard audio.snapshot().pendingMilliseconds == 0 else { throw DialtError("clear_failed", "Playback remained queued after clear.") }
        audio.stop()
        try await capture.value
        guard !audio.voiceProcessingEnabled else { throw DialtError("stop_failed", "Audio remained enabled after stop.") }
    }

    @MainActor static func live(speech: Data? = nil) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["DIALT_API_KEY"], !key.isEmpty else { throw DialtError("missing_key", "Set DIALT_API_KEY via your local credential loader.") }
        let tool: JSONValue = ["name": "lookup_test_colour", "description": "Look up the diagnostic test colour.", "parameters": ["type": "object", "properties": [:]], "read_only": true]
        let config = DialtConfiguration(apiKey: key, sessionID: env["DIALT_SESSION_ID"] ?? UUID().uuidString,
            modality: speech == nil ? .text : .voice, mode: ["greeting": false, "turn_detection": "client", "instructions": "Use lookup_test_colour to answer the test colour question, then state the result briefly.", "tools": .array([tool])],
            endpoint: env["DIALT_ENDPOINT"].flatMap(URL.init(string:)) ?? DialtConfiguration.defaultEndpoint)
        let session = DialtSession(configuration: config)
        defer { session.close() }
        try await session.connect()
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(45))
            if !Task.isCancelled { session.close() }
        }
        defer { timeout.cancel() }
        let upload = Task { @MainActor in
            if let speech {
                // Keep the capture clock running through ASR's trailing context, as a
                // live microphone and the Python SDK's voice fixtures do.
                let padded = Data(repeating: 0, count: 6400) + speech + Data(repeating: 0, count: 32000)
                for offset in stride(from: 0, to: padded.count, by: 1280) {
                    try await session.sendAudio(Data(padded[offset..<min(offset + 1280, padded.count)]))
                    try await Task.sleep(for: .milliseconds(40))
                }
                try await session.finishInputTurn()
            } else { try await session.sendText("What is the diagnostic test colour?") }
        }
        defer { upload.cancel() }
        var toolCalled = false
        var transcript = ""
        var recognizedSpeech = false
        var replySamples = 0
        var received: [String] = []
        for try await event in session.events {
            if received.count < 80 { received.append(event.type) }
            if event.type == "error" { throw DialtError("server_error", event["detail"]?.string ?? "Server error") }
            if event.type == "tool_call", event["name"] == "lookup_test_colour", let id = event["id"]?.string {
                toolCalled = true
                try await session.sendToolResult(id: id, content: ["colour": "turquoise"], outcome: .succeeded, verified: true)
            }
            if event.type == "utterance" { transcript += event["text"]?.string ?? "" }
            if event.type == "asr", let text = event["text"]?.string {
                log("Recognized synthetic question: \(text)")
                recognizedSpeech = recognizedSpeech || text.lowercased().contains("colour") || text.lowercased().contains("color")
            }
            if let audio = event.audio { replySamples += try DialtPCM.decode(audio).filter { abs($0) > 0.001 }.count }
            if event.type == "done", toolCalled, transcript.lowercased().contains("turquoise"),
               speech == nil || (recognizedSpeech && replySamples > 1600) {
                try await upload.value
                print("PASS: live authentication, \(speech == nil ? "text turn" : "synthetic speech ASR and reply PCM"), tool dispatch/result, final reply, clean client close.")
                return
            }
        }
        try await upload.value
        throw DialtError("live_test_failed", "Deadline: tool=\(toolCalled), ASR=\(recognizedSpeech), replySamples=\(replySamples), transcript=\(transcript), events=\(received.joined(separator: ",")).")
    }

    static func readSpeech(_ url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
              file.length > 0, file.length <= 320_000,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw DialtError("invalid_fixture", "Use up to 20 seconds of mono 16 kHz WAV speech.")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw DialtError("invalid_fixture", "Cannot decode speech.") }
        return DialtPCM.encode(Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
    }

    @MainActor static func aec(input: URL, output: URL) async throws {
        let stimulus = try readSpeech(input)
        guard stimulus.count >= 128_000 else {
            throw DialtError("invalid_fixture", "Use 4–20 seconds of 16 kHz mono speech in a WAV file.")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var measures: [[String: JSONValue]] = []
        for (index, enabled) in [false, true, true, false].enumerated() {
            log("Take \(index + 1)/4: voice processing \(enabled ? "ON" : "OFF"). Please stay quiet.")
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
                let end = min(decoded.count, 16_000 + stimulus.count / 2)
                guard end > 48_000 else { throw DialtError("capture_missing", "Too little microphone audio was captured.") }
                let speech = Array(decoded[48_000..<end]) // Exclude convergence/startup.
                let rms = sqrt(speech.reduce(0.0) { $0 + Double($1 * $1) } / Double(speech.count))
                let noise = Array(decoded.prefix(12_000))
                let noiseRMS = sqrt(noise.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, noise.count)))
                let db = 20 * log10(max(rms, 1e-9))
                measures.append(["take": .number(Double(index + 1)), "aec": .bool(enabled), "confirmed_enabled": .bool(wasEnabled),
                                 "capture_samples": .number(Double(decoded.count)), "speech_rms_dbfs": .number(db),
                                 "noise_rms_dbfs": .number(20 * log10(max(noiseRMS, 1e-9)))])
                log("Captured \(decoded.count) samples, RMS \(String(format: "%.1f", db)) dBFS.")
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
