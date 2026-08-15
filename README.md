# ScreenBridge

> Turn your iPad into a second display for your Mac.

ScreenBridge turns an iPad into a display-only extended screen for a Mac. The Mac creates a virtual display and streams it to the iPad over a local Apple device path, while keyboard, trackpad, mouse, clipboard, and app control stay on the Mac.

The current product path is a macOS sender plus an iPadOS receiver.

## Features

- Mac virtual display streaming to iPad over authenticated TCP.
- Default display placement on the right side of the Mac display, with a setting for right, left, above, or below.
- HiDPI resolution presets, including a larger-text `1024 x 768` option for easier reading on iPad.
- Network modes for Auto, Apple P2P/AWDL, Router/WiFi, and USB/Thunderbolt-style wired paths.
- Adaptive stream quality: every TCP path has bounded backpressure and adjusts bitrate from observed send latency/drops without exceeding the selected quality.
- Optional Chrome audio routing to the receiver, with bounded low-latency delivery, visible waiting/connecting/streaming/retry state, and automatic recovery when Chrome restarts or changes audio processes.
- Pairing-code based authentication before streaming starts.
- Display-only receiver behavior: iPad touch gestures are not forwarded as Mac input.
- Device de-duplication, hidden device records, and manual device removal.
- iPad disconnected screen when the Mac stops sharing or the network drops.
- Automatic reconnect after unexpected wireless drops: the Mac retries up to 3 times (2s/4s/8s backoff). Manual disconnects are never retried.
- Background grace period: backgrounding the iPad receiver pauses the stream for up to 5 minutes without destroying the Mac virtual display; returning resumes the session in place.
- Fast stream recovery: the iPad requests a fresh keyframe after decode errors and when returning to the foreground.
- Clear connection states on both sides: the Mac sidebar shows a live status indicator (discovering, connecting, authenticating, connected, reconnecting, failed), and the iPad distinguishes waiting, connecting, connected, device disconnected, and connection lost.
- The iPad never treats unrelated bytes as a healthy picture: heartbeat, video arrival, decode, and renderer progress are tracked independently. A static rendered desktop stays healthy through the media heartbeat, while real decoder/renderer stalls surface as connection loss.

## Network Modes

ScreenBridge exposes the transport preference in Settings:

- `Auto (Apple Default)` lets Network.framework pick the best available path and can fall back when P2P is unavailable.
- `Force P2P (WiFi Direct)` asks macOS/iPadOS to use Apple AWDL peer-to-peer networking. This keeps traffic between the Mac and iPad instead of routing through the home router when AWDL is available.
- `Force Router/WiFi` uses the normal infrastructure WiFi path through the local network.
- `USB / Thunderbolt Cable` disables WiFi/P2P for new connections and asks the system to use a wired-style network path such as iPad USB networking, Ethernet, or Thunderbolt Bridge.

For the best second-screen experience, prefer `USB / Thunderbolt Cable` when available. If running wirelessly, keep both devices nearby and try `Force P2P (WiFi Direct)` before falling back to router WiFi.

### Wireless Behavior and Troubleshooting

- Backgrounding the receiver app (app switcher, swiping home, locking the iPad) is safe for short breaks. The iPad tells the Mac it is backgrounding, and the Mac holds the session in a 5-minute grace period: streaming pauses but the virtual display and connection stay alive. Returning within 5 minutes resumes the same session with a fresh keyframe and no display rearrangement. After 5 minutes the Mac disconnects cleanly and removes the virtual display.
- Force-quitting the receiver, disconnecting manually on either device, or a real network failure skips the grace period and disconnects immediately.
- iPadOS system gestures (app switcher, Slide Over, Stage Manager) only change how the receiver app is presented on the iPad. They are never forwarded to the Mac. Mac-side gestures such as Mission Control change the streamed content because the iPad shows a real Mac display.
- After an unexpected wireless drop the Mac retries the connection 3 times with backoff. The sender log shows `Auto-reconnect to ... in Ns`. If all attempts fail, reconnect manually from the sidebar.
- For diagnosing drops, the sender log records the connection class (`P2P Direct Link (AWDL)`, `Wired/cable link`, or `Router/infrastructure link`), bitrate adjustments, and the disconnect reason.
- If discovery was denied, ScreenBridge retries Bonjour with bounded backoff and then exposes `Local Network Settings…` plus `Retry Discovery` in Settings.

## Gestures

The iPad is a second screen, not a second gesture controller. All control of the Mac — including system gestures — happens on the Mac itself.

- Mac trackpad gestures (five-finger pinch for Launchpad, Mission Control, App Exposé, Spaces switching, multi-finger swipes) always remain native macOS gestures. ScreenBridge installs no event taps, no event monitors, and never changes `presentationOptions`, so it cannot block, swallow, or reinterpret them — before, during, or after a connection.
- macOS applies these gestures to the display where the pointer currently is. If the pointer is on the ScreenBridge virtual display, Launchpad or Mission Control appears on that display (and is therefore visible on the iPad). That is standard macOS multi-display behavior — the same thing happens with a cabled external monitor — not input forwarding, and ScreenBridge does not override it.
- Touches and gestures on the iPad are never sent to the Mac. A five-finger pinch on the iPad is an iPadOS system gesture: it minimizes the receiver app on the iPad (starting the background grace period) and cannot trigger Launchpad on the Mac. No app can intercept iPadOS system gestures. The only iPad gesture ScreenBridge registers is a local three-finger tap that reveals the settings button.
- Copy/paste on the streamed display uses the Mac clipboard, because the virtual display is the Mac. Use the Mac keyboard and trackpad as usual.

## Security Model

- Pairing codes are normalized, hashed, and stored locally in Keychain on both Mac and iPad.
- Mac and iPad perform a nonce-based HMAC-SHA256 handshake before streaming starts.
- Protocol v2 gives the media/control and Chrome-audio transports explicit roles under one receiver-generated session ID; an audio connection cannot create or join a stale video session.
- A session key derived from the pairing secret and both nonces authenticates receiver control messages such as heartbeat and screen-size updates.
- The Mac ignores iPad-originated pointer, scroll, touch, and keyboard input. Local Mac input remains the only control path.
- Bonjour discovery uses the ScreenBridge service type `_yc-cast._tcp`.

ScreenBridge still needs sensitive macOS permissions. Screen Recording is required to capture the virtual display, and Audio Recording is required only when app audio routing is enabled. Accessibility is not required for the display-only Mac-to-iPad workflow.

Video and audio frames are intended for trusted local networks and are not encrypted beyond the local transport. Use a private pairing code and avoid untrusted networks.

## Quick Start

For this trusted, self-use workflow, a unique six-digit code is supported for convenience. It is not resistant to offline enumeration, so use ScreenBridge only on a trusted local network; use a longer generated code if that tradeoff is not acceptable. Save the exact same code on both devices.

### Mac

1. Build the app with `./make_app.sh`, or open a release zip/DMG.
2. Move `ScreenBridge.app` to `/Applications`.
3. Open ScreenBridge and save the pairing code in Settings.
4. Keep `Use as` set to `Extended Display`.
5. Choose the network mode for the connection. `Auto` is easiest, `Force P2P (WiFi Direct)` is usually better for nearby wireless devices, and `USB / Thunderbolt Cable` is best when a cable path is active.
6. Grant Screen Recording when prompted.
7. Control the extended display from the Mac's keyboard, trackpad, mouse, and normal macOS clipboard.
8. Grant Audio Recording if you enable Chrome audio routing.

### iPad

1. Open `BetterCastIOS.xcodeproj` in Xcode.
2. Select the `BetterCastReceiverIOS` scheme and your iPad as the run destination.
3. Let Xcode automatically manage signing with your Apple Personal Team, then click Run.
4. If Xcode asks, trust the iPad and enable Developer Mode on iPadOS versions that require it.
5. Enter and save the same pairing code used on the Mac.
6. Leave the receiver open.
7. When the iPad appears in the Mac sidebar, connect from the Mac.

The iPad receiver supports iPadOS multitasking and windowed presentation, so
another iPad window can temporarily sit above it. ScreenBridge still reports the
full physical iPad screen size to the Mac so the virtual display resolution
does not shrink when the receiver window is resized.

## Build Commands

Run the shared authentication tests:

```bash
swift test --filter BetterCastSharedTests
```

Build the Mac app and DMG locally:

```bash
ALLOW_AD_HOC=1 ./make_app.sh
```

This explicit opt-in is for disposable local testing. Use an Apple-issued
signing identity for a build whose macOS Local Network permission identity must
remain stable.

Build the iPad receiver for a real device:

```bash
xcodebuild -project BetterCastIOS.xcodeproj \
  -scheme BetterCastReceiverIOS \
  -destination 'generic/platform=iOS' \
  -configuration Debug \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build
```

For a local iPad install, open `BetterCastIOS.xcodeproj`, choose the real iPad as the run destination, and use Product > Run.

## Distribution Notes

`make_app.sh` requires an Apple-issued signing identity by default. Ad-hoc
signing is available only with `ALLOW_AD_HOC=1` and must not be published. For a
downloadable build, sign with a Developer ID certificate and notarize the DMG:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
APPLE_ID="you@example.com" \
APP_PASSWORD="app-specific-password" \
TEAM_ID="TEAMID" \
./make_app.sh
```

The iOS packaging script uses Xcode's archive/export pipeline; it no longer
assembles an unsigned app bundle by hand. Supply an export-options plist whose
method matches your Apple account:

```bash
EXPORT_OPTIONS_PLIST=/absolute/path/ExportOptions.plist \
ALLOW_PROVISIONING_UPDATES=1 \
./package_ios_ipa.sh
```

A free Personal Team still limits device installs to Apple's short-lived
development provisioning period; rebuild and reinstall when that profile
expires.

Generated apps, DMGs, zips, and local sharing folders are ignored by Git and should be uploaded as GitHub release assets instead of committed to the repository.

## License

ScreenBridge is released under the MIT License. See `LICENSE`.

Before public redistribution, resolve the source-provenance/license evidence
tracked as K5 in `docs/audits/2026-08-15-change-review-known-issues.md`; the
runtime stability work does not settle that legal question.

## Manual Acceptance Checklist

- With no pairing code saved on the Mac, connecting to an iPad does not start screen capture.
- With different pairing codes on Mac and iPad, the connection fails during pairing.
- With the same pairing code, the Mac connects and starts streaming only after authentication succeeds.
- The iPad shows the streamed virtual display.
- On iPadOS with Stage Manager or Slide Over, another window can appear over the receiver without changing the Mac virtual display resolution.
- Touch, pointer, scroll, and keyboard input on the iPad are not forwarded to the Mac.
- Copy/paste remains a local OS behavior: use the Mac clipboard for the streamed Mac display, or Universal Clipboard outside ScreenBridge if your Apple devices provide it.
- P2P mode logs an AWDL path when Apple peer-to-peer networking is active.
- USB / Thunderbolt Cable mode logs a wired/iPad USB path when the system selects that interface.
- Chrome audio routing plays selected browser audio on the receiver when audio permissions are granted.
- Enabling Chrome audio before Chrome starts shows `Waiting for Chrome` and begins streaming automatically after Chrome appears; restarting Chrome recovers without recreating the virtual display.
- Clearing pairing on either device prevents future connections until the code is saved again.
- Reset Pairing on the iPad immediately revokes the active and pending logical session, stops listening, clears media state, and returns to pairing UI.
- Stop Sharing on the Mac returns the iPad to the disconnected screen.
- After a forced wireless interruption (e.g. toggling iPad WiFi briefly), the Mac auto-reconnects within ~15 seconds of the network returning.
- A manual disconnect from the Mac sidebar does not trigger auto-reconnect.
- Backgrounding the iPad receiver briefly (under 5 minutes) keeps the Mac virtual display alive; returning to the app resumes the stream in place without a pipeline restart.
- Backgrounding the iPad receiver for over 5 minutes disconnects the Mac cleanly and removes the virtual display, with no reconnect attempts until the user acts.
- Force-quitting the iPad receiver disconnects the Mac within seconds, not after the grace period.
- Connecting works on the first click after saving the pairing code on either device (the dial retries once automatically if the direct link is cold).
- Disconnecting from the Mac immediately shows the disconnected screen on the iPad with no residual video frame.
- Quitting the Mac sender mid-stream shows "Connection lost" on the iPad within ~8 seconds.

## Architecture Notes

The shared security code lives in `Sources/BetterCastShared`:

- `PrivateBetterCastConstants.swift` holds the ScreenBridge service type and protocol constants.
- `PairingAuthenticator.swift` implements nonce generation, HMAC proofs, session key derivation, and authenticated envelopes.
- `PairingSecretStore.swift` stores the local pairing secret through Keychain.
- `ReceiverSessionPolicy.swift`, `PipelineUpdatePolicy.swift`, `MediaLivenessEvaluator`, and `AdaptiveBitratePolicy` hold testable state/health decisions used by the runtime.

The main runtime gates are:

- Mac: `NetworkClient.performPairingHandshake(...)` must succeed before `startPipeline(for:)`.
- iPad: `NetworkListenerIOS.performPairingHandshake(...)` must succeed before a main session is activated or an auxiliary audio transport is admitted to that session.
- Receiver commands: `NetworkClient.receiveTCP(...)` accepts authenticated heartbeat/keyframe/screen-size messages while ignoring iPad input events.
- iPad control: `VideoRendererViewIOS` is display-only and does not register touch-control gestures.

Some internal Swift package targets and source paths still use historical `BetterCast*` names. The user-facing app name, bundle display name, service type, packaging scripts, and release documentation are ScreenBridge.

See `docs/decisions/ADR-002-display-only-local-mac-control.md`, `ADR-003-logical-receiver-session.md`, and `ADR-004-independent-media-health-and-bounded-delivery.md` for the current runtime decisions.
