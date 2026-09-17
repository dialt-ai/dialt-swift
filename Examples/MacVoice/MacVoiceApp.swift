#if os(macOS)
import SwiftUI
import Dialt

@main struct MacVoiceApp: App {
    var body: some Scene { WindowGroup { VoiceView() }.defaultSize(width: 680, height: 560) }
}

@MainActor final class VoiceModel: ObservableObject {
    @Published var key = ""
    @Published var sessionID = UUID().uuidString
    @Published var status = "Ready"
    @Published var lines: [String] = []
    @Published var active = false
    @Published var muted = false
    private var client: DialtVoiceClient?
    private var task: Task<Void, Never>?

    func start() {
        guard !active else { return }
        active = true; status = "Connecting…"; lines.removeAll()
        let tool: JSONValue = ["name": "lookup_test_colour", "description": "Look up the demo's test colour.",
                               "parameters": ["type": "object", "properties": [:]], "read_only": true]
        let config = DialtConfiguration(apiKey: key, sessionID: sessionID,
            mode: ["instructions": "Help the caller. Use lookup_test_colour if they ask for the test colour.", "tools": .array([tool])])
        let voice = DialtVoiceClient(configuration: config)
        client = voice
        task = Task { [weak self] in
            do {
                try await voice.connect()
                self?.status = "Listening"; voice.setMuted(self?.muted ?? false)
                for try await event in voice.events {
                    if ["asr", "utterance"].contains(event.type), let text = event["text"]?.string {
                        self?.append("\(event.type == "asr" ? "You" : "Dialt"): \(text)")
                    }
                    if event.type == "tool_call", event["name"] == "lookup_test_colour", let id = event["id"]?.string {
                        try await voice.session.sendToolResult(id: id, content: ["colour": "turquoise"], outcome: .succeeded, verified: true)
                        self?.append("Tool: lookup_test_colour completed")
                    }
                    if event.type == "error" { self?.append("Error: \(event["detail"]?.string ?? "Server error")") }
                    if event.type == "reconnecting" { self?.status = "Reconnecting…" }
                    if event.type == "reconnected" { self?.status = "Listening" }
                }
                self?.status = "Call ended"
            } catch is CancellationError { self?.status = "Stopped" }
            catch { self?.status = error.localizedDescription }
            voice.close(); self?.active = false
        }
    }
    func append(_ line: String) { lines.append(line); if lines.count > 200 { lines.removeFirst() } }
    func stop() { task?.cancel(); task = nil; client?.close(); client = nil; active = false; status = "Stopped" }
    func toggleMute() { muted.toggle(); client?.setMuted(muted) }
}

struct VoiceView: View {
    @StateObject private var model = VoiceModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Dialt Voice").font(.largeTitle.bold())
            Text("Native Mac voice with echo cancellation and a sample tool.").foregroundStyle(.secondary)
            SecureField("Scoped session key", text: $model.key).textFieldStyle(.roundedBorder).disabled(model.active)
            TextField("Matching session ID", text: $model.sessionID).textFieldStyle(.roundedBorder).disabled(model.active)
            HStack {
                Button(model.active ? "End call" : "Start call") { model.active ? model.stop() : model.start() }
                    .buttonStyle(.borderedProminent).disabled(!model.active && model.key.isEmpty)
                Button(model.muted ? "Unmute" : "Mute") { model.toggleMute() }.disabled(!model.active)
                Text(model.status).font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(model.lines.joined(separator: "\n\n")).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            Text("Credentials are kept in memory. Ask “What is the test colour?” to exercise the tool.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 560, minHeight: 440).onDisappear { model.stop() }
    }
}
#else
@main struct UnsupportedExample { static func main() {} }
#endif
