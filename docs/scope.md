# Initial SDK scope

Purpose: let native Mac and iPhone apps add Dialt voice without implementing audio capture,
echo cancellation, playback or the session transport themselves. macOS 14 and iOS 17 keep
the initial device matrix manageable while allowing a shared Swift 6 concurrency model.

One public package, `Dialt`, owns the native audio and protocol client. No private server
implementation or credentials belong in this repository. The browser SDK informs playback
and interruption semantics; the Python SDK informs the headless session and reconnect
contract. The public API documentation is the wire reference.

Included: voice/text, scoped credentials, server events, declarative tools/results/progress,
microphone conversion, native AEC, streamed PCM playback, mute, interruption reports,
bounded buffering, reconnect/resume, native Mac example, acoustic diagnostic, automated
contract tests and a live service diagnostic.

Deferred: WebRTC, dynamic agent handoff and mode updates, provisional playback holds,
ambience, CallKit/background calls, automatic hardware-route recovery, MCP discovery, and
other operating systems. These are not required for a native foreground voice integration.
The server remains unchanged. App-specific tools and MCP logic stay in the integrating app.

Release acceptance: automated Mac and iOS builds/tests, live API/tool round trip, real Mac
speaker/microphone AEC check, and an explicit account of device tests not yet completed.
Ship as alpha until double-talk and physical iPhone coverage are measured.
