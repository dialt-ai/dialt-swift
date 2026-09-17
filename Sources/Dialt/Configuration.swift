import Foundation

public struct DialtConfiguration: Sendable {
    public enum Modality: String, Sendable { case voice, text }
    public static let defaultEndpoint = URL(string: "wss://api.dialt.com/v1/realtime")!

    public var endpoint: URL
    /// Use a scoped credential issued by your backend for distributed applications.
    public var apiKey: String
    /// Must match the session ID bound to a scoped credential.
    public var sessionID: String
    public var modality: Modality
    /// Public wire-mode fields: instructions, voice, tools, greeting, policy, etc.
    /// kind and modality are controlled by the SDK.
    public var mode: [String: JSONValue]
    public var user: String?
    public var timezone: String
    public var autoReconnect = true
    public var maxReconnectAttempts = 12
    public var connectTimeout: Duration = .seconds(15)
    public var reconnectBaseDelay: Duration = .milliseconds(500)

    public init(apiKey: String, sessionID: String = UUID().uuidString,
                modality: Modality = .voice, mode: [String: JSONValue] = [:],
                endpoint: URL = defaultEndpoint, user: String? = nil,
                timezone: String = TimeZone.current.identifier) {
        self.apiKey = apiKey; self.sessionID = sessionID; self.modality = modality
        self.mode = mode; self.endpoint = endpoint; self.user = user; self.timezone = timezone
    }

    func validate() throws {
        guard !apiKey.isEmpty, (1...64).contains(sessionID.utf8.count),
              sessionID.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-").contains($0)
              }) else { throw DialtError("invalid_configuration", "Provide a key and a 1–64 character safe session ID.") }
        guard let host = endpoint.host, !host.isEmpty,
              endpoint.scheme == "wss" || (endpoint.scheme == "ws" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)),
              endpoint.user == nil, endpoint.password == nil,
              connectTimeout > .zero, reconnectBaseDelay >= .zero,
              (0...100).contains(maxReconnectAttempts) else {
            throw DialtError("invalid_configuration", "Use wss (or loopback ws), a positive timeout and bounded reconnect attempts.")
        }
        if mode["background_audio"] == true {
            throw DialtError("unsupported_transport", "Server background_audio requires WebRTC; this SDK uses WebSocket.")
        }
        if mode["kind"] != nil || mode["modality"] != nil {
            throw DialtError("invalid_configuration", "Set modality on DialtConfiguration; omit kind from mode.")
        }
    }

    func startFrame(resumeToken: String?, audioFrontend: String) -> [String: JSONValue] {
        var wireMode = mode
        wireMode["kind"] = "dialt"
        if modality == .text { wireMode["modality"] = "text" }
        var client: [String: JSONValue] = ["timezone": .string(timezone), "capabilities": []]
        if let user { client["user"] = .string(user) }
        if modality == .voice { client["audio_frontend"] = .string(audioFrontend) }
        var frame: [String: JSONValue] = [
            "type": "start", "session_id": .string(sessionID), "api_key": .string(apiKey),
            "mode": .object(wireMode), "client": .object(client)
        ]
        if modality == .voice { frame["audio"] = ["sr": 16000, "output_encoding": "pcm16", "output_sr": 16000] }
        if let resumeToken { frame["resume_token"] = .string(resumeToken) }
        return frame
    }
}

public struct DialtEvent: Sendable, Equatable {
    public let type: String
    /// Complete JSON frame, including type. Unknown event types and fields are preserved.
    public let fields: [String: JSONValue]
    /// PCM16 little-endian, mono, 16 kHz. Present only for audio events.
    public let audio: Data?
    public init(type: String, fields: [String: JSONValue] = [:], audio: Data? = nil) {
        self.type = type; self.fields = fields; self.audio = audio
    }
    public subscript(_ key: String) -> JSONValue? { fields[key] }
}
