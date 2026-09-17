# Dialt for Swift

Native voice and text sessions for macOS 14+ and iOS 17+, using Swift 6 and Apple's
audio frameworks. No third-party runtime dependencies. The SDK connects to the
[Dialt realtime API](https://dialt.com/docs/api/websocket/).

This is an initial **alpha**. See [validation](docs/validation.md) for checks actually
performed and device coverage. A passing protocol suite is not acoustic certification.

## Install

In Xcode, choose **File → Add Package Dependencies** and add
`https://github.com/dialt-ai/dialt-swift`. Select the `Dialt` library product.
For local development, add this repository as a local Swift package.

## Native voice

Your backend issues a scoped session credential using
`POST https://api.dialt.com/v1/session-keys`. Pass both its `api_key` and matching
`session_id` to the app. Never embed your account's persistent API key in a distributed app.

```swift
import Dialt

// Run on MainActor; keep the client alive for the call.
let voice = DialtVoiceClient(configuration: DialtConfiguration(
    apiKey: credential.apiKey,
    sessionID: credential.sessionID,
    mode: ["instructions": "Help the caller with their questions."]
))
try await voice.connect()
for try await event in voice.events {
    switch event.type {
    case "asr", "utterance": print(event["text"]?.string ?? "")
    case "error": print(event["detail"]?.string ?? "Server error")
    default: break
    }
}
voice.close()
```

Always call `close()` when leaving a call, including on cancellation/error. The client
owns microphone capture, 16 kHz PCM conversion, streaming playback, Apple voice
processing and interruption reports. `setMuted(true)` sends silence while retaining
the capture clock. `done` means the server finished producing a reply, not that the
speaker finished playing it. A clean server close allows the queued farewell to drain.

Add `NSMicrophoneUsageDescription` to the application's Info.plist. A sandboxed Mac
app also needs `com.apple.security.device.audio-input` and
`com.apple.security.network.client`. Permission denial is an explicit error.
The iOS audio path activates a `.playAndRecord` / `.voiceChat` audio session; coordinate
ownership with any other audio components in your app. This release does not implement
CallKit or background-call lifecycle support.

The [Mac example](Examples/MacVoice/MacVoiceApp.swift) includes a native SwiftUI call screen,
mute control, transcripts and a harmless example tool. Package it with your app's
Info.plist and signing settings; running a bare executable is not a substitute for
microphone permissions in an app bundle.

## Tools

Declare tools in `mode["tools"]` using the public wire schema. Arguments, results and
schemas use `JSONValue`, a Sendable/Codable JSON value with Swift literal support.

```swift
let tools: JSONValue = [[
    "name": "lookup_order",
    "description": "Look up an order by ID.",
    "parameters": [
        "type": "object",
        "properties": ["order_id": ["type": "string"]],
        "required": ["order_id"]
    ],
    "read_only": true
]]
```

On a `tool_call`, execute the tool in your application and send a result:

```swift
try await voice.session.sendToolResult(
    id: toolCallID,
    content: ["status": "shipped"],
    outcome: .succeeded,
    verified: true
)
```

Set `verified` only after your application verifies success. Run slow tools in separate
tasks so the event consumer keeps reading. Your app owns task cancellation and permission
checks. Execute only broker-dispatched `tool_call` events, never a permission request.
Interruption of speech does not cancel a tool. Deferred tools, progress and cancellation
have helpers; other supported operations use `session.sendControl(type:fields:)` and
their corresponding acknowledgement events. This is not an MCP client: your app bridges
the declared tools to its existing MCP integration.

## Text and custom audio

`DialtSession` provides the same protocol without owning audio hardware:

```swift
let session = DialtSession(configuration: .init(
    apiKey: credential.apiKey, sessionID: credential.sessionID, modality: .text,
    mode: ["greeting": false]
))
try await session.connect()
try await session.sendText("Hello")
// Consume session.events from one task, and close on exit.
```

In voice mode, `sendAudio(_:)` accepts little-endian PCM16, mono, 16 kHz, paced by the
caller in 20–100 ms frames. Received `audio` events contain that same format. Custom
players must implement the documented `playback_stopped` contract; use
`DialtVoiceClient` to get that automatically. `NativeAudioEngine` is also available
independently for capture/playback and diagnostics.

## Recovery and limits

- Abnormal transport loss resumes the same session when the server supplies a resume
  token. A clean close, rejected resume or exhausted retry budget ends the session.
- Captured audio during reconnect is dropped. Controls during reconnect throw with
  `code == "reconnecting"`. No tool result or side effect is automatically retried.
- Microphone, event and playback buffers are bounded. Overload ends the call with an
  explicit error rather than silently corrupting audio or dropping protocol events.
- Each client is single-use. Create a new instance for a deliberately new call.
- Device reconfiguration or an OS audio interruption ends capture with
  `audio_route_changed`; start a new call once the route is ready. Transparent route
  recovery is not implemented in this alpha.
- WebSocket is the only transport. WebRTC, provisional playback holds, ambience,
  dynamic agent handoff/mode mutation and SDK-managed MCP connections are out of scope.
  No unsupported capabilities are advertised to the server.
- Unknown server event fields/types are retained. Voice events omit raw audio because
  the voice client already owns playback; use `DialtSession` for raw frames.

## Build and test

```sh
swift build
swift test
swift build -c release
```

Tests cover the wire contract, actual local WebSocket framing, reconnects, cancellation,
buffer limits, resampling, and interruption playback accounting. They do not use a mic
or consume API credit. [Audio checks](docs/audio.md) require real hardware and explicit
microphone access. A live service check is available with `dialt-diagnostics live`.

Licensed under Apache-2.0.
