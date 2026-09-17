import Foundation
@preconcurrency import Network
import Testing
@testable import Dialt

/// Real loopback WebSocket handshake/framing; no network service or credentials required.
@MainActor final class LoopbackServer {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private(set) var port: UInt16?
    private(set) var received: [[String: JSONValue]] = []
    private(set) var binary = Data()
    private(set) var failure: String?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.setClientRequestHandler(.main) { _, _ in .init(status: .accept, subprotocol: nil) }
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .ready = state { self?.port = self?.listener.port?.rawValue }
                if case .failed(let error) = state { self?.failure = error.localizedDescription }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.connections.append(connection)
                connection.start(queue: .main)
                self?.receive(connection)
            }
        }
        listener.start(queue: .main)
    }

    func stop() { listener.cancel(); connections.forEach { $0.cancel() } }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            Task { @MainActor in
                guard let self, error == nil else { return }
                let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata)?.opcode
                if opcode == .close { return }
                if let data {
                    if opcode == .binary {
                        self.binary.append(data)
                        self.send(data, opcode: .binary, on: connection)
                    } else if opcode == .text, let frame = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
                        self.received.append(frame)
                        if frame["type"] == "start" {
                            let ready: [String: JSONValue] = ["type": "ready", "session_uuid": "loopback", "resume_token": "opaque", "audio": ["output_encoding": "pcm16", "output_sr": 16000]]
                            self.send(try! JSONEncoder().encode(ready), opcode: .text, on: connection)
                        } else if frame["type"] == "input_text" {
                            self.send(Data("{\"type\":\"utterance\",\"text\":\"loopback reply\"}".utf8), opcode: .text, on: connection)
                        }
                    }
                }
                self.receive(connection)
            }
        }
    }
    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode, on connection: NWConnection) {
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
}

@Suite @MainActor struct WebSocketTests {
    @Test func nativeURLSessionTextAndBinaryRoundTrip() async throws {
        let server = try LoopbackServer()
        defer { server.stop() }
        try await eventually { server.port != nil || server.failure != nil }
        #expect(server.failure == nil)
        let port = try #require(server.port)
        let endpoint = try #require(URL(string: "ws://127.0.0.1:\(port)/v1/realtime"))
        let session = DialtSession(configuration: .init(apiKey: "loopback-key", endpoint: endpoint))
        defer { session.close() }
        try await session.connect()
        let data = DialtPCM.encode([0.25, -0.25, 0])
        try await session.sendAudio(data)
        var events = session.events.makeAsyncIterator()
        #expect(try await events.next()?.type == "ready")
        #expect(try await events.next()?.audio == data)
        #expect(server.binary == data)
        let text = DialtSession(configuration: .init(apiKey: "loopback-key", modality: .text, endpoint: endpoint))
        defer { text.close() }
        try await text.connect(); try await text.sendText("hello")
        var replies = text.events.makeAsyncIterator()
        #expect(try await replies.next()?.type == "ready")
        #expect(try await replies.next()?["text"] == "loopback reply")
    }
}
