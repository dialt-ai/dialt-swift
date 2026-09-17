@preconcurrency import AVFoundation
import Foundation

@MainActor protocol VoiceAudio: AnyObject {
    var microphone: AsyncThrowingStream<Data, any Error> { get }
    var voiceProcessingEnabled: Bool { get }
    func start() async throws
    func enqueue(_ pcm16: Data) throws
    func snapshot() -> PlaybackSnapshot
    func clearPlayback()
    func stop()
}

/// Owns one full-duplex Apple audio graph. Single use; stop releases the microphone.
/// All reply audio must use enqueue() so Apple's echo canceller receives its reference.
@MainActor public final class NativeAudioEngine: VoiceAudio {
    public let microphone: AsyncThrowingStream<Data, any Error>
    public private(set) var voiceProcessingEnabled = false
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private let requestedVoiceProcessing: Bool
    private var timeline = PlaybackTimeline()
    private var tapInstalled = false
    private var started = false
    private var stopped = false
    private var starting = false
    private var observers: [NSObjectProtocol] = []
    private var capture: CaptureProcessor?
    private var scheduledBuffers = 0
    private var playbackEpoch = 0

    /// Disable voiceProcessing only for controlled A/B diagnostics or an external AEC path.
    public init(voiceProcessing: Bool = true) {
        requestedVoiceProcessing = voiceProcessing
        let pair = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(8))
        microphone = pair.stream; continuation = pair.continuation
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.stop() } }
    }

    public func start() async throws {
        guard !stopped, !started, !starting else { throw DialtError("invalid_state", "Create a new audio engine for each call.") }
        starting = true
        defer { starting = false }
        let permitted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: permitted = true
        case .notDetermined: permitted = await AVCaptureDevice.requestAccess(for: .audio)
        default: permitted = false
        }
        guard permitted else { throw DialtError("microphone_denied", "Allow microphone access in System Settings.") }
        guard !stopped else { throw CancellationError() }
        try Task.checkCancellation()
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
            #endif
            let input = engine.inputNode
            // Enable before querying the format: VPIO can change the hardware graph format.
            try input.setVoiceProcessingEnabled(requestedVoiceProcessing)
            voiceProcessingEnabled = input.isVoiceProcessingEnabled && engine.outputNode.isVoiceProcessingEnabled
            guard !requestedVoiceProcessing || voiceProcessingEnabled else {
                throw DialtError("aec_unavailable", "Apple voice processing is unavailable on this audio route.")
            }
            if requestedVoiceProcessing {
                input.isVoiceProcessingAGCEnabled = false
                input.isVoiceProcessingBypassed = false
            }
            let hardwareFormat = input.outputFormat(forBus: 0)
            guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
                  let inputFormat = AVAudioFormat(standardFormatWithSampleRate: hardwareFormat.sampleRate, channels: 1) else {
                throw DialtError("audio_unavailable", "No microphone input format is available.")
            }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            // VPIO's capture and render client formats must match. Its reported input
            // can include aggregate/reference channels; do not downmix those as speech.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: inputFormat)
            let processor = try CaptureProcessor(inputFormat: inputFormat, continuation: continuation)
            capture = processor
            input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { @Sendable buffer, _ in processor.process(buffer) }
            tapInstalled = true
            engine.prepare(); try engine.start(); player.play()
            guard engine.isRunning else { throw DialtError("audio_unavailable", "Audio engine did not start.") }
            started = true
            observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.routeChanged() }
            })
            #if os(iOS)
            for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.routeChanged() }
                })
            }
            #endif
        } catch { stop(); throw error }
    }

    private func routeChanged() {
        guard started else { return }
        continuation.finish(throwing: DialtError("audio_route_changed", "Audio hardware changed or was interrupted. Start a new call when the route is ready."))
        stop()
    }

    /// Muting emits silence, preserving real-time pacing without recording a second mic path.
    public func setMuted(_ muted: Bool) { capture?.setMuted(muted) }

    public func enqueue(_ pcm16: Data) throws {
        guard started else { throw DialtError("audio_unavailable", "Audio engine is not running.") }
        let samples = try DialtPCM.decode(pcm16)
        guard !samples.isEmpty else { return }
        let cursor = sampleCursor()
        guard timeline.pendingFrames(cursor: cursor) + Int64(samples.count) <= 160_000, scheduledBuffers < 512 else {
            throw DialtError("playback_overflow", "More than ten seconds of unplayed audio; refusing unbounded delay.")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw DialtError("audio_allocation", "Cannot allocate playback buffer.") }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        // One 60 ms lead on startup/underrun; contiguous chunks have no extra gap.
        let lead: Int64 = timeline.remainingFrames(cursor: cursor) > 0 ? 0 : 960
        let start = timeline.schedule(frames: samples.count, cursor: cursor, lead: lead)
        let epoch = playbackEpoch
        scheduledBuffers += 1
        player.scheduleBuffer(buffer, at: AVAudioTime(sampleTime: start, atRate: 16_000), options: [], completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self, self.playbackEpoch == epoch else { return }
                self.scheduledBuffers -= 1
            }
        }
    }

    private func sampleCursor() -> Int64 {
        guard let render = player.lastRenderTime, let time = player.playerTime(forNodeTime: render) else { return 0 }
        return max(0, Int64(Double(time.sampleTime) * 16_000 / time.sampleRate))
    }

    public func snapshot() -> PlaybackSnapshot {
        let cursor = sampleCursor()
        return PlaybackSnapshot(
            pendingMilliseconds: Double(timeline.pendingFrames(cursor: cursor)) / 16,
            remainingMilliseconds: Double(timeline.remainingFrames(cursor: cursor)) / 16,
            deviceLatencyMilliseconds: engine.outputNode.presentationLatency * 1000)
    }
    public func clearPlayback() {
        player.stop(); timeline.clear(); playbackEpoch += 1; scheduledBuffers = 0
        if started { player.play() }
    }
    public func stop() {
        guard !stopped else { return }
        stopped = true; started = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        clearPlayback()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine.stop(); capture = nil; voiceProcessingEnabled = false
        continuation.finish()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

/// AVAudioEngine serializes a tap's callbacks. Converter and accumulator are accessed only
/// from that tap; the mute flag is locked. No AVAudioPCMBuffer escapes its callback lifetime.
final class CaptureProcessor: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private var pending = Data()
    private let lock = NSLock()
    private var muted = false
    init(inputFormat: AVAudioFormat, continuation: AsyncThrowingStream<Data, any Error>.Continuation) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw DialtError("unsupported_audio", "Cannot convert microphone to mono 16 kHz.")
        }
        self.converter = converter; self.continuation = continuation
    }
    func setMuted(_ value: Bool) { lock.withLock { muted = value } }
    func process(_ input: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        let source = ConverterInput(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            guard let buffer = source.take() else { status.pointee = .noDataNow; return nil }
            status.pointee = .haveData; return buffer
        }
        guard status != .error, error == nil, let channel = output.floatChannelData?[0] else {
            continuation.finish(throwing: DialtError("audio_conversion", "Microphone conversion failed.")); return
        }
        let samples = lock.withLock { muted }
            ? [Float](repeating: 0, count: Int(output.frameLength))
            : Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        pending.append(DialtPCM.encode(samples))
        // 40 ms packets, yielded from the capture clock. A slow uploader fails explicitly.
        while pending.count >= 1280 {
            let packet = Data(pending.prefix(1280)); pending.removeFirst(1280)
            if case .dropped = continuation.yield(packet) {
                continuation.finish(throwing: DialtError("capture_overflow", "Microphone uploader fell behind.")); return
            }
        }
    }
}

/// AVAudioConverter requests this immutable buffer synchronously. The lock makes the
/// one-shot supply explicit even with the API's Sendable input-block annotation.
private final class ConverterInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var consumed = false
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        lock.withLock {
            guard !consumed else { return nil }
            consumed = true; return buffer
        }
    }
}
