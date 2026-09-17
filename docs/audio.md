# Native audio and AEC

The native path deliberately uses one `AVAudioEngine` for capture and assistant playback.
Voice processing is enabled before inspecting the input format. The capture tap and
mixer-to-output connection use matching mono formats at the input hardware rate.
Leaving output stereo while configuring a mono input reproduced CoreAudio `-10875`
on the tested Mac. Apple's input/output
voice-processing nodes must both report enabled; a failure does not fall back to an
uncancelled microphone. The input is never connected to the speaker as a monitor.

Apple voice processing includes suppression as well as echo cancellation. It is not
equivalent to Chrome's AEC3, and enabling it does not establish double-talk quality.
Automatic gain control is disabled; no extra software boost or noise suppression is
layered over Apple's processing. Incoming hardware audio uses a stateful
`AVAudioConverter` and is packetized into 40 ms PCM16 chunks.

Replies use the same engine's player/mixer/output chain so the canceller has a playback
reference. A 60 ms startup/underrun lead absorbs network jitter. Subsequent contiguous
chunks have no inserted gap. Queued speech is limited to ten seconds. Playback accounting
uses the player's sample clock, excludes jitter gaps from discarded speech, and reports
device presentation latency separately. These are playback accounting values, **not
conversational latency benchmarks**.

On `interrupted` with `clear: true`, playback stops and queued speech is reported as
discarded, echoing `barge_seq`. Without `clear`, the existing queue drains and discarded
speech is zero. `canceled` clears speculative audio. A reconnect clears stale playback.
The SDK does not advertise `playback_pause_v1` because retained provisional holds are
not implemented.

## Acoustic A/B diagnostic

Use built-in speakers and microphone, fixed audible volume, and a quiet room. Do not use
headphones: an inaudible raw echo makes the comparison inconclusive. Use a 4–20 second
mono 16 kHz WAV speech sample. The diagnostic plays it four times (raw, processed,
processed, raw) and records the microphone locally.

```sh
swift run dialt-diagnostics aec speech.wav artifacts/aec
```

Inspect all four WAVs and `report.json`. The check requires raw echo to exceed baseline
noise by 10 dB and average processed capture to be at least 10 dB below raw capture.
This is a local engineering acceptance threshold, not a claimed industry benchmark.
The initial convergence interval is excluded. The reported reduction includes Apple's
noise suppression and differences between takes; it is not a pure ERLE measurement.
All artifacts are ignored by Git. No audio is uploaded by this command.

`dialt-diagnostics audio-check` separately exercises live capture, paced muted silence,
playback queue accounting, clearing playback and microphone shutdown. It uploads and
saves no microphone audio.

## Required device checks before a production release

1. Far-end-only speech: no recognisable assistant echo in capture and no false user turn.
2. Near-end-only speech: normal and soft speech remain intelligible.
3. Double-talk: a real person speaks while assistant audio plays; normal/soft interruptions
   must survive. An independent physical speaker can substitute for the person in a
   repeatable lab fixture. Mixing a signal into the render graph does not simulate this:
   it becomes part of the canceller's far-end reference.
4. Stop/restart, permission denial, mute, speaker/headphone/Bluetooth routes, route changes,
   iOS calls/interruption, and foreground/background behavior.

Apple voice processing requires hardware rendering and cannot be validated by feeding
offline fixtures into AVAudioEngine manual-rendering mode. Offline conversion/unit tests
cannot replace the above. Quantitative ASR and interruption-quality comparisons require
reviewed recordings; latency benchmarks use forced-aligned word boundaries.

References: [Apple voice processing](https://developer.apple.com/videos/play/wwdc2019/510/),
[voice-processing updates](https://developer.apple.com/videos/play/wwdc2023/10235/),
[Dialt WebSocket protocol](https://dialt.com/docs/api/websocket/).
