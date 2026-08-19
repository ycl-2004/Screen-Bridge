# ADR-010: Per-Application Audio Routing with Local Fail-Safe

- Status: Accepted
- Date: 2026-08-19

## Context

The sender previously exposed one global Chrome-audio switch and matched a
small Chromium bundle-ID allowlist. That made Chrome appear supported while
Safari, Spotify, and other applications were absent or inconsistently captured.
It also could not express which receiver should own an application's audio when
more than one display was connected.

Core Audio process taps operate on process object IDs, not user-facing app
identities. Chromium moves output through helper processes, while Safari can
surface a shared `com.apple.WebKit.GPU` XPC process whose localized process name
identifies Safari as the host. Process object IDs also change whenever an app or
one of its helpers restarts.

The most important safety requirement is that selecting a receiver must never
make an app silent on both devices when the auxiliary connection is unavailable.

## Decision

- The sender builds a dynamic catalog from Core Audio's process object list,
  bundle ID, PID, and running-output properties. The UI shows applications that
  are producing audio plus inactive applications with a saved route.
- Helper processes are grouped under a stable user-facing application identity:
  first by their outer `.app`, then by a localized host-app name for shared XPC
  services such as WebKit, and finally by the longest matching regular-app
  bundle-ID prefix.
- Each application has exactly one destination: `This Mac` (represented by no
  assignment) or one canonical receiver device ID. Assignments persist across
  launches and remain visible while the app or receiver is offline.
- Each connected receiver owns an independent selected-app process tap, AAC
  encoder, and authenticated auxiliary TCP transport. Changing an assignment or
  observing a process-object replacement rebuilds only the affected audio
  branch, not the virtual display or video encoder.
- The auxiliary transport must authenticate before capture starts. A selected
  process tap uses `CATapMuteBehavior.mutedWhenTapped`; disconnect, send failure,
  receiver backgrounding, route removal, and pipeline teardown stop the tap
  immediately so the app returns to local playback.
- Every auxiliary `contentProcessed` send has a three-second completion
  watchdog. A half-open socket therefore tears down the tap and retries the
  audio branch instead of indefinitely dropping its bounded AAC queue while the
  selected app remains muted locally.
- The wire protocol and receiver audio decoder remain unchanged. Routing is a
  sender-side policy over the existing timed AAC stream.

## Consequences

Safari, Spotify, Chrome, and other Core Audio clients can use the same routing
path without product-specific allowlists. Routes survive app and receiver
restarts, and transport failure favors audible local playback over silent loss.

Routing is application-level. It cannot separate tabs, windows, or multiple
audio streams owned by one app, and one app cannot intentionally fan out to two
receivers. Shared framework helpers still require an AppKit ownership heuristic,
so real-app regression coverage remains necessary as macOS and applications
change. Process taps require macOS 14.2 or later even though display-only
streaming continues to support macOS 14.0.

## References

- https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
- https://developer.apple.com/documentation/coreaudio/audiohardwareprocess
- https://developer.apple.com/documentation/coreaudio/audiohardwareprocess/isrunningoutput
- https://developer.apple.com/documentation/coreaudio/catapmutebehavior
- https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription
- https://developer.apple.com/documentation/network/nwconnection/sendcompletion/contentprocessed(_:)
