# ADR-007: Audio Timing and Offline Pipeline Foundations

- Status: Accepted
- Date: 2026-08-18

## Context

Protocol v3 already carried `sequence`, `sampleTime`, `sampleCount`, `codec`,
and `flags`, but the sender populated `sampleTime` with a synthetic counter.
The Core Audio IO callback provides an input timestamp that was discarded. The
encoder also accumulated PCM in `Data`, shifted it with `removeFirst`, and
allocated its AAC output buffer for every packet. Those choices are safe for a
short playback check but create avoidable real-time allocation and copying.

The source tap format may not always be 48 kHz or interleaved stereo. The
AudioConverter input callback must provide no more packets than it was asked
for, and the amount of source audio represented by one 48 kHz AAC frame varies
with the input sample rate.

Official API contracts used here:

- https://developer.apple.com/documentation/coreaudio/audiodeviceioblock
- https://developer.apple.com/documentation/coreaudio/audiodevicecreateioprocidwithblock%28_%3A_%3A_%3A_%3A%29?language=objc
- https://developer.apple.com/documentation/audiotoolbox/audioconvertercomplexinputdataproc
- https://developer.apple.com/documentation/audiotoolbox/audioconverterfillcomplexbuffer%28_%3A_%3A_%3A_%3A_%3A_%3A%29?changes=latest_bet___5&language=objc

## Decision

- Pass the Core Audio input timestamp through the process-tap callback and
  convert a valid source-domain sample position onto the 48 kHz packet
  timeline. Set the existing v3 `sampleTimeValid` flag for that value.
- Keep the existing synthetic packet counter as a compatibility fallback when
  Core Audio does not mark the timestamp valid or the conversion inputs are
  invalid. No wire header version change is needed.
- Replace the encoder's repeated `Data` prefix/removal path with a reusable
  byte ring buffer. Reuse the interleave scratch storage and AAC output buffer;
  retain one AAC `Data` copy at the delegate boundary because the output buffer
  is reused for the next conversion.
- Calculate the minimum source frames needed for one output AAC frame and make
  the AudioConverter callback cap each request to the currently available
  source frames. Pure timing, frame-count, and ring-order tests cover these
  rules.
- Run Swift tests, a strict macOS package build, and an unsigned generic iOS
  build on every relevant Apple-target change through GitHub Actions.

Adaptive jitter thresholds, Audio Diagnostics snapshots, clock-drift
correction, Opus, and UDP/QUIC remain deferred until real-device and long-run
measurements exist.

## Consequences

The sender now exposes capture timing to later A/V-sync and jitter work, but
this does not by itself synchronize the Mac and iPad hardware clocks. A valid
timestamp is authoritative only for the captured packet timeline; the receiver
does not yet use it for playout scheduling. The reusable buffers reduce steady-
state allocation pressure, while the final AAC `Data` handoff copy remains a
deliberate ownership boundary. The Apple CI job improves regression detection
without requiring a paired or connected device.
