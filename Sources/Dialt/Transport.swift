import Foundation

enum WireMessage: Sendable { case text(String), binary(Data) }

@MainActor protocol DialtTransport: AnyObject, Sendable {
    var closeCode: Int? { get }
    func send(_ message: WireMessage) async throws
    func receive() async throws -> WireMessage
    func close()
}

@MainActor final class WebSocketTransport: DialtTransport {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    var closeCode: Int? {
        socket.closeCode == .invalid ? nil : socket.closeCode.rawValue
    }
    init(url: URL) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        session = URLSession(configuration: config)
        socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 1_048_576
        socket.resume()
    }
    func send(_ message: WireMessage) async throws {
        switch message {
        case .text(let value): try await socket.send(.string(value))
        case .binary(let value): try await socket.send(.data(value))
        }
    }
    func receive() async throws -> WireMessage {
        switch try await socket.receive() {
        case .string(let value): return .text(value)
        case .data(let value): return .binary(value)
        @unknown default: throw DialtError("invalid_frame", "Unsupported WebSocket message.")
        }
    }
    func close() {
        socket.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}
