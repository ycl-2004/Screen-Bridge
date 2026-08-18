# ScreenBridge / BetterCast Project Entry

Use this file as the first stop when handing the repository to Claude Code or another coding agent. It explains what the project is, which path is current, where the important code lives, and how the remaining modules relate to the main product.

## One-Line Summary

ScreenBridge turns an iPad into a display-only extended screen for a Mac. The Mac creates a virtual display, captures it, encodes video/audio, and streams it over a local authenticated connection to an iPad receiver.

## Naming Reality

- User-facing product name: `ScreenBridge`.
- Historical source/package name: `BetterCast`.
- Many Swift targets, folders, Android packages, and C++ files still use `BetterCast*`.
- Do not assume `BetterCast` means a separate product. In this repository it is mostly legacy naming for the ScreenBridge codebase.

## Current Product Path

The current focus is only the Mac-to-iPad workflow. macOS sender and iPad receiver are the main product. Windows, Linux, Android, and other receiver/sender variants are not active product priorities right now; keep them as historical/reference or possible future expansion unless the task explicitly says otherwise.

The current active path is:

1. macOS sender discovers local receivers by Bonjour service `_yc-cast._tcp`.
2. macOS sender and iPad receiver must share the same pairing code.
3. Sender and receiver run a nonce-based HMAC pairing handshake.
4. Only after authentication succeeds does the sender create/capture the display pipeline.
5. The iPad renders the streamed display and sends authenticated control messages only for receiver health, keyframe requests, and screen-size updates.
6. Direct Mac control stays local to the Mac. The current iPad workflow is display-only.

The design rationale is recorded in:

- `docs/decisions/ADR-002-display-only-local-mac-control.md`
- `README.md`

`docs/decisions/ADR-001-private-mac-ipad-authenticated-p2p.md` is historical and marked superseded.

## Start Here

Read these files first, in this order:

1. `README.md` - product behavior, quick start, current security model, build commands.
2. `docs/decisions/ADR-002-display-only-local-mac-control.md` - why the iPad receiver is display-only.
3. `Package.swift` - SwiftPM targets and the macOS/iOS source layout.
4. `Sources/BetterCastShared/` - shared authentication, constants, and Keychain pairing storage.
5. `Sources/BetterCastSender/BetterCastSenderApp.swift` - macOS sender UI, discovery, pairing, connection activation, and streaming orchestration.
6. `Sources/BetterCastReceiverIOS/` - iPad receiver app, listener, video rendering, audio playback, and pairing-side handshake.

Before editing, always run:

```bash
git status --short
```

This repository often has local, user-owned changes. Do not revert unrelated changes.

## Core Code Map

### Shared Security

Path: `Sources/BetterCastShared/`

- `PrivateBetterCastConstants.swift` defines the private service type `_yc-cast._tcp`, protocol version, bundle IDs, and Keychain identifiers.
- `PairingAuthenticator.swift` implements normalized pairing secrets, nonce creation, sender/receiver HMAC proofs, derived session keys, and authenticated envelopes.
- `PairingSecretStore.swift` stores the pairing secret in Keychain behind a small protocol.

Tests:

- `Tests/BetterCastSharedTests/PairingAuthenticatorTests.swift`
- `Tests/BetterCastSharedTests/PairingSecretStoreTests.swift`

Run:

```bash
swift test --filter BetterCastSharedTests
```

### macOS Sender

Path: `Sources/BetterCastSender/`

Primary file:

- `BetterCastSenderApp.swift`

Important responsibilities inside `BetterCastSenderApp.swift`:

- SwiftUI app shell, onboarding, sidebar, settings, logs, and device detail panels.
- `NetworkClient` handles Bonjour browsing, evidence-backed route selection,
  pairing, connection state, stream settings, quality selection, display
  placement, and pipeline lifecycle.
- `performPairingHandshake(...)` sends `SenderHello`, verifies `ReceiverHello`, sends `SenderProof`, and derives the session key.
- `activateAuthenticatedConnection(...)` only creates the pipeline after pairing succeeds.
- `startPipeline(for:)` creates the virtual display, chooses capture size, applies adaptive quality, starts video/audio encoders, and starts `ScreenRecorder`.

Other sender files:

- `VirtualDisplayManager.swift` and `VirtualDisplay/` create/manage the macOS virtual display.
- `ScreenRecorder.swift` captures the selected display through ScreenCaptureKit.
- `VideoEncoder.swift` encodes video.
- `AudioEncoder.swift` and `ProcessAudioTapCapture.swift` handle optional Chrome audio routing.
- `InputHandler.swift` only stores each connection's virtual-display bounds. The name is historical; it handles no input, and the Mac-to-iPad path is display-only.

Build local Mac app/DMG:

```bash
SIGN_IDENTITY="Apple Development: <your identity>" ./make_app.sh
```

An Apple-issued identity is required. macOS tracks Screen Recording and Local
Network permission by signing identity, so an ad-hoc build loses both every time
it is rebuilt — it is available only via an explicit `ALLOW_AD_HOC=1` opt-in.

### iPad Receiver

Path: `Sources/BetterCastReceiverIOS/`

Main entry files:

- `main.swift`
- `AppDelegate.swift`
- `ViewController.swift`

Important receiver files:

- `NetworkListenerIOS.swift` advertises the receiver, accepts connections, performs the receiver side of pairing, receives length-prefixed stream frames, detects video/audio framing, sends heartbeat/keyframe/screen-size control messages, and wraps outbound control messages in authenticated envelopes.
- `VideoDecoder.swift` decodes H.264 frames.
- `VideoRendererViewIOS.swift` renders decoded frames.
- `AudioPlayerIOS.swift` plays AAC audio frames when the sender routes audio.
- `InputEvent.swift` defines command/input message shape. In the current display-only path, iPad-originated pointer/touch control is not a feature.
- `Constants.swift` maps iOS constants to the shared private service type.

Build for a real iPad:

```bash
xcodebuild -project BetterCastIOS.xcodeproj \
  -scheme BetterCastReceiverIOS \
  -destination 'generic/platform=iOS' \
  -configuration Debug \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build
```

Package IPA after building:

```bash
./package_ios_ipa.sh
```

### macOS Receiver Target (removed)

The `Sources/BetterCastReceiver/` target has been deleted. It predated the
private pairing protocol: it advertised `_bettercast._tcp`, performed no pairing
handshake, and did not link `BetterCastShared`, so the current sender could
neither discover nor authenticate it. Keeping it around implied macOS could act
as a receiver, which was not true.

Recover it from git history if a macOS receiver is ever wanted again; it would
need a protocol v2 listener written from scratch (see `NetworkListenerIOS.swift`
for the receiver side of the handshake).

### Android Receiver/Sender

Path: `Sources/BetterCastReceiverAndroid/`

This is a Kotlin/Jetpack Compose Android module under the historical BetterCast package name. It has receiver networking, sender/screen-capture code, input models, and Android-specific UI.

Use it only when the task is explicitly Android-related. For the current ScreenBridge Mac+iPad workflow, treat Android as dormant/secondary.

Potential command from the Android folder:

```bash
./gradlew assembleDebug
```

### Windows/Linux Desktop Receiver

Path: `Sources/BetterCastReceiverDesktop/`

This is a Qt/C++ receiver with FFmpeg decode and OpenGL rendering. It also contains sender-oriented C++ files under `Sources/BetterCastReceiverDesktop/sender/`.

Read `Sources/BetterCastReceiverDesktop/BUILD.md` before working here. Treat this as secondary unless the task is explicitly Windows/Linux desktop support.

### Packaging, Assets, and Release Notes

- `make_app.sh` builds the macOS app bundle and DMG.
- `package_ios_ipa.sh` packages an already-built iOS receiver binary into an IPA-style payload.
- `BetterCastSender-Info.plist` defines macOS bundle metadata. The app currently
  requests no restricted entitlements, so `make_app.sh` signs without embedding
  an empty entitlement blob.
- `Sources/BetterCastReceiverIOS/Info.plist` defines iOS receiver metadata.
- `assets/branding/BetterCastIcon.icns` is the macOS app icon asset.
- `docs/release-notes/v8.md` contains release notes for the current v8 work.
- `docs/github-readiness.md` captures public-readiness cleanup notes.

## Protocol and Runtime Relationship

The important dependency chain is:

```text
Pairing code
  -> BetterCastShared pairing secret and HMAC proofs
  -> Bonjour discovery on _yc-cast._tcp
  -> authenticated NWConnection session
  -> virtual display creation on Mac
  -> ScreenCaptureKit capture
  -> VideoToolbox/AAC encoding
  -> length-prefixed TCP stream frames
  -> iPad decode/render/playback
  -> authenticated heartbeat, keyframe, and screen-size commands back to Mac
```

Special command codes in the current path:

- `555` announces the receiver is entering the background; the sender holds the session and virtual display in a ~5 minute grace period with streaming paused. Any later authenticated message from the receiver ends the grace period and resumes the stream.
- `777` reports the receiver's full screen dimensions to the sender.
- `888` is heartbeat.
- `999` requests a keyframe.

Do not add unauthenticated control messages. If a receiver sends data back to the Mac after pairing, it should go through the authenticated envelope flow.

## Current Behavior Constraints

- The current Mac-to-iPad workflow is display-only.
- Do not reintroduce iPad touch/pointer/keyboard control unless the product decision changes and the ADR/README are updated.
- Screen Recording is required for display capture.
- Accessibility should not be required for the current display-only workflow.
- Video/audio stream contents are local-transport only and not independently encrypted; pairing authenticates devices/control messages rather than providing full media confidentiality.
- Generated apps, DMGs, IPAs, zips, and packaging folders should not be committed.

## Common Task Routing

- Product behavior, setup, or user-facing copy: start with `README.md`, then check sender/iPad UI text.
- Pairing/security: start with `Sources/BetterCastShared/` and the two handshake implementations in sender/iPad listener.
- Mac app UI/settings: start with `Sources/BetterCastSender/BetterCastSenderApp.swift`.
- Virtual display/resolution/placement: start with `VirtualDisplayManager.swift`, `VirtualDisplay/`, and `startPipeline(for:)`.
- Streaming quality/latency: start with `startPipeline(for:)`, `VideoEncoder.swift`, `ScreenRecorder.swift`, and `NetworkListenerIOS.swift`.
- iPad connection/rendering issues: start with `ViewController.swift`, `NetworkListenerIOS.swift`, `VideoDecoder.swift`, and `VideoRendererViewIOS.swift`.
- Audio routing: start with `ProcessAudioTapCapture.swift`, `AudioEncoder.swift`, `AudioPlayerIOS.swift`, and audio-related settings in `BetterCastSenderApp.swift`.
- Public release cleanup: start with `docs/github-readiness.md`, `make_app.sh`, `package_ios_ipa.sh`, `.gitignore`, and the README.

## Verification Checklist

Use the narrowest verification that matches the change:

```bash
swift test --filter BetterCastSharedTests
```

```bash
swift build
```

```bash
SIGN_IDENTITY="Apple Development: <your identity>" ./make_app.sh
```

```bash
xcodebuild -project BetterCastIOS.xcodeproj \
  -scheme BetterCastReceiverIOS \
  -destination 'generic/platform=iOS' \
  -configuration Debug \
  build
```

For Android-only work:

```bash
cd Sources/BetterCastReceiverAndroid
./gradlew assembleDebug
```

For Windows/Linux desktop work, follow `Sources/BetterCastReceiverDesktop/BUILD.md`.

## Agent Notes

- Prefer small, scoped changes. This repository mixes active and dormant modules.
- Preserve the current user-facing `ScreenBridge` wording unless the task is explicitly about renaming internal code.
- Do not do broad internal renames from `BetterCast*` to `YCCast*` as an incidental cleanup.
- If changing behavior or setup, update `README.md` or an ADR as appropriate.
- If changing security semantics, update tests under `Tests/BetterCastSharedTests/` and the relevant ADR.
- If touching existing files, first inspect the current diff so user-owned edits are not overwritten.
