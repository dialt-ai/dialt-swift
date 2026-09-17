import Foundation

public enum DialtPCM {
    public static let sampleRate: Double = 16_000
    public static func encode(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let finite = sample.isFinite ? sample : 0
            let value = Int16(max(-32768, min(32767, (finite * 32768).rounded())))
            let bits = UInt16(bitPattern: value)
            data.append(UInt8(truncatingIfNeeded: bits)); data.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return data
    }
    public static func decode(_ data: Data) throws -> [Float] {
        guard data.count.isMultiple(of: 2) else { throw DialtError("invalid_audio", "PCM16 must contain complete samples.") }
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count, by: 2).map {
            Float(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)) / 32768
        }
    }
}

/// Sample-clock accounting excludes jitter gaps from discarded speech.
struct PlaybackTimeline {
    struct Span { let start: Int64; let end: Int64 }
    private(set) var spans: [Span] = []
    mutating func schedule(frames: Int, cursor: Int64, lead: Int64) -> Int64 {
        spans.removeAll { $0.end <= cursor }
        let start = max(spans.last?.end ?? 0, cursor + lead)
        spans.append(Span(start: start, end: start + Int64(frames)))
        return start
    }
    func pendingFrames(cursor: Int64) -> Int64 {
        spans.reduce(0) { $0 + max(0, $1.end - max(cursor, $1.start)) }
    }
    func remainingFrames(cursor: Int64) -> Int64 { max(0, (spans.last?.end ?? cursor) - cursor) }
    mutating func clear() { spans.removeAll() }
}

public struct PlaybackSnapshot: Sendable, Equatable {
    public var pendingMilliseconds: Double
    public var remainingMilliseconds: Double
    public var deviceLatencyMilliseconds: Double
    public init(pendingMilliseconds: Double, remainingMilliseconds: Double, deviceLatencyMilliseconds: Double) {
        self.pendingMilliseconds = pendingMilliseconds; self.remainingMilliseconds = remainingMilliseconds
        self.deviceLatencyMilliseconds = deviceLatencyMilliseconds
    }
}
