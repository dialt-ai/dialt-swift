# Validation

Local validation performed 2026-09-17 on an Apple Silicon MacBook Pro, macOS 26.2,
using built-in microphone and speakers. Swift 6 language mode; local compiler 6.2.3.
CI uses Xcode 16.4; both macOS and iPhone simulator tests passed on the validation PR.
Check the PR's current Actions results before merging; local results do not substitute
for CI.

| Check | Result | Scope | Required resources | Purpose | Execution |
| --- | --- | --- | --- | --- | --- |
| `swift test` | 22 tests passed | Component | Apple SDK | Functional regression | CI / Local |
| `swift test -c release` | 22 tests passed | Component | Apple SDK | Optimized-build regression | Local |
| `swift build -c release` | Library, diagnostic and Mac example built | Component | Apple SDK | Compatibility | CI / Local |
| URLSession WebSocket round trip | Passed within suite | Component | Loopback sockets | Integration | CI / Local |
| `dialt-diagnostics live` | Passed: authentication, text, tool and final reply | System | Credential/network | Functional | Manual |
| `dialt-diagnostics live-voice` | Passed: synthetic question ASR, tool result, reply text and non-silent PCM | System | Credential/network, synthetic fixture | Functional | Manual |
| `dialt-diagnostics aec` | Passed: mean far-end attenuation 36.1 dB | System | Real speakers/microphone, synthetic fixture | Audio quality eval | Manual |
| `dialt-diagnostics audio-check` | Passed: capture, mute, queue accounting, clear and shutdown | Component | Real speakers/microphone | Functional | Manual |

The local Command Line Tools installation contained incompatible stale Swift package
interfaces and module maps. Local commands used a disposable copy of that toolchain
with the stale files removed, and disabled its missing optional Swift Testing/Foundation
overlay. No system toolchain files were changed. GitHub's clean Xcode installation
provides the independent standard-toolchain check.

## Audio evidence and limits

The acoustic eval played the same 12.3-second synthetic speech fixture four times:
raw, AEC, AEC, raw. The two raw levels were −16.0 / −15.7 dBFS; processed levels were
−55.0 / −48.8 dBFS. Raw echo exceeded room noise by more than 10 dB in both takes.
See [the numerical report](aec-result.json). Recordings remain local and are excluded
from the repository. This is far-end attenuation including suppression, not pure ERLE,
an ASR evaluation, or proof of double-talk quality. No microphone recordings were sent
to the live service; its voice test used a separate synthetic question WAV.

Hardware testing reproduced and fixed two failures absent from mock tests: Swift actor
isolation on an audio callback, and VPIO initialization with mismatched client formats.
The four-take eval also exercised repeated engine startup/shutdown. The session suite
reproduces microphone-send and interruption-report failures before receive detects a
disconnect; recovery keeps capture alive and never replays stale frames.

## Not yet validated

- Human normal/soft near-end speech and double-talk during assistant playback.
- Physical iPhone audio, Bluetooth/headphones, and the minimum supported OS releases.
- Real permission denial, device hot-plug and iOS interruptions (their failure handling
  has component coverage, not physical-device certification).
- The SwiftUI example's interactive UI, sandbox/signing combinations and long calls.

These remain required before a production/stable release. This package is an alpha
for foreground integrations. It does not claim background calling, transparent route
recovery, or production acoustic certification.
