# Validation

Work in progress. This file will contain the executed commands, results, toolchain,
hardware coverage and remaining limitations after validation completes.

| Check | Scope | Required resources | Purpose | Execution |
| --- | --- | --- | --- | --- |
| Swift protocol/state/audio tests | Component | Local Apple SDK | Contract/functional | CI |
| Loopback URLSession WebSocket test | Component | Loopback sockets | Integration | CI |
| Live API and tool round trip | System | Dialt credential/network | Functional | Manual |
| Acoustic A/B attenuation check | System | Real speakers/microphone | Audio quality eval | Manual |
| Physical double-talk and device routes | System | Mac/iPhone and a near-end speaker | Audio quality eval | Manual |
