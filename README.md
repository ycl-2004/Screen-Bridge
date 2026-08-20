<p align="center">
  <img src="assets/branding/AppIcon.png" alt="Screen Bridge app icon" width="120" height="120">
</p>

<h1 align="center">Screen Bridge</h1>

<p align="center">
  <strong>Turn an iPad into a display-only extended screen for your Mac.</strong>
</p>

<p align="center">
  <a href="https://github.com/ycl-2004/Screen-Bridge/releases/tag/v1.1.0"><img src="https://img.shields.io/badge/release-v1.1.0-111111" alt="Screen Bridge v1.1.0 release"></a>
  <img src="https://img.shields.io/badge/macOS-14.0%2B-111111?logo=apple&logoColor=white" alt="macOS 14.0 or later">
  <img src="https://img.shields.io/badge/iPadOS-13.0%2B-111111?logo=apple&logoColor=white" alt="iPadOS 13.0 or later">
  <img src="https://img.shields.io/badge/Mac-Universal-111111" alt="Universal Mac build for Apple silicon and Intel">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-111111" alt="MIT License"></a>
</p>

<p align="center">
  <a href="https://github.com/ycl-2004/Screen-Bridge/releases/download/v1.1.0/Screen-Bridge-v1.1.0-macOS-universal.zip">Download for Mac</a>
  ·
  <a href="https://github.com/ycl-2004/Screen-Bridge/releases">Releases</a>
  ·
  <a href="#features">Features</a>
  ·
  <a href="#privacy-and-security">Privacy &amp; security</a>
  ·
  <a href="#build-from-source">Build from source</a>
</p>

Screen Bridge turns an iPad into a real extended display for a Mac. The Mac
creates a virtual display, captures it, and streams it over a local Apple device
path. Keyboard, trackpad, mouse, clipboard, and system control stay on the Mac.

The active product path is a macOS sender plus an iPadOS receiver. It is built
for one Mac and one iPad on a trusted local network, without an account, cloud
service, analytics, or telemetry.

> **Distribution status:** `v1.1.0` includes a downloadable Universal Mac ZIP
> for Apple silicon and Intel. The app is ad-hoc signed and not notarized because
> this project does not currently have a Developer ID identity. Treat it as a
> self-use/preview build, not a general public installer. The iPad receiver must
> be built with your own Xcode signing; no public IPA is included.

## Quick start

Screen Bridge needs both the Mac sender and the iPad receiver. Save the same
pairing code on both devices before connecting.

### Mac

1. Download
   [`Screen-Bridge-v1.1.0-macOS-universal.zip`](https://github.com/ycl-2004/Screen-Bridge/releases/download/v1.1.0/Screen-Bridge-v1.1.0-macOS-universal.zip).
2. Unzip it and move `Screen Bridge.app` to `/Applications`.
3. On first launch, Control-click the app, choose **Open**, then confirm **Open**.
   The preview build is not notarized, so a normal double-click may be blocked.
4. Save a pairing code in Screen Bridge Settings.
5. Keep `Use as` set to **Extended Display**.
6. Choose `Auto`, `Require Cable`, `AWDL`, or `Wi-Fi` for the desired local
   path, then connect to the iPad from the sidebar.
7. Grant **Screen Recording** when macOS asks. Grant **Audio Recording** only
   when routing selected app audio to the iPad.

### iPad

1. Clone the repository and open `BetterCastIOS.xcodeproj` in Xcode.
2. Select the `BetterCastReceiverIOS` scheme and a real iPad destination.
3. Choose your Apple Team for signing, then run the receiver.
4. Enable Developer Mode and trust the developer profile if iPadOS asks.
5. Save the same pairing code used on the Mac.
6. Leave the receiver in the foreground and connect from the Mac.

### System requirements

- macOS 14.0 or later for display streaming.
- macOS 14.2 or later for per-app audio routing.
- iPadOS 13.0 or later on a real iPad receiver.
- A local network path between the Mac and iPad.
- Screen Recording permission on the Mac.
- Audio Recording permission only for per-app audio routing.
- An Apple signing team and provisioning profile for iPad installation.

## Why Screen Bridge

- **A real extended display.** The iPad renders a Mac virtual display, so Mac
  windows can be dragged onto it instead of mirroring the built-in screen.
- **Mac input stays on the Mac.** iPad touch and system gestures are not sent
  back as Mac input.
- **Routes are explicit.** Auto, cable, AWDL, and infrastructure Wi-Fi expose
  the path Screen Bridge requested and the Bonjour interface it observed.
- **Recovery preserves window placement.** Brief iPad backgrounding holds the
  virtual display for up to five minutes while the connection is rebuilt.
- **Audio follows an explicit device choice.** Active apps can remain on This
  Mac or be assigned to one connected iPad; a failed route returns audio locally.

## Features

**Extended display**

- Creates a virtual Mac display and places it to the right, left, above, or
  below the main display.
- Offers HiDPI resolution presets, including a larger-text `1024 × 768` option.
- Supports extended-display and mirror modes while keeping input local.

**Connection and recovery**

- Discovers the iPad through Bonjour service `_yc-cast._tcp`.
- Authenticates both devices before creating the capture pipeline.
- Supports Auto plus strict cable, AWDL, and Wi-Fi routes without silently
  falling back from a strict selection.
- Uses bounded video delivery, adaptive bitrate, keyframe recovery, and bounded
  reconnect attempts.
- Keeps a backgrounded display alive long enough for the same receiver to
  re-adopt it without moving Mac windows home.

**Per-app audio**

- Finds apps currently exposing active Core Audio output.
- Assigns each app to This Mac or one connected receiver.
- Persists routes across app and receiver restarts.
- Authenticates a dedicated audio transport before muting local output.
- Stops the muted tap immediately if the receiver backgrounds, disconnects, or
  loses the audio connection.
- Uses timed AAC packets, a bounded sender queue, and receiver rebuffering.

**Receiver health**

- Tracks transport heartbeat, video arrival, decode, rendering, and audio as
  separate health signals.
- Requests a keyframe after decode errors and when returning to the foreground.
- Rejects stale sessions and unauthenticated control traffic.

## How it works

1. The Mac discovers the iPad over Bonjour.
2. Both sides load the same Keychain-backed pairing secret.
3. A nonce-based HMAC-SHA256 handshake authenticates the session.
4. The Mac creates and captures a virtual display with ScreenCaptureKit.
5. VideoToolbox and AAC encode length-prefixed video and audio frames.
6. The iPad decodes and renders the display and sends authenticated health,
   screen-size, and keyframe control messages.

The media/control connection and optional per-app audio connections have
explicit roles under one logical receiver session. Protocol v4 seals control
messages in both directions with per-transport replay protection. See
[`ADR-008`](docs/decisions/ADR-008-authenticated-sender-control-protocol-v4.md)
and [`ADR-010`](docs/decisions/ADR-010-per-application-audio-routing.md).

## Screenshots

Fresh Screen Bridge product screenshots are not checked in yet. The available
simulator captures are retained only as historical audit evidence because they
show an earlier product name:

- [Historical iPad onboarding capture](docs/audits/2026-08-14-ipad-onboarding.png)
- [Historical iPad landscape capture](docs/audits/2026-08-14-ipad-landscape.png)

## Privacy and security

- Pairing codes are normalized, hashed, and stored locally in Keychain.
- A nonce-based HMAC-SHA256 handshake runs before media starts.
- Authenticated envelopes protect control messages and reject replayed sequence
  numbers.
- No account, cloud sync, analytics, or telemetry service is used.
- Video and audio are local-transport media and are not independently encrypted
  end to end. Use Screen Bridge only on a trusted network.
- Screen Recording is required for display capture. Audio Recording is required
  only when routing app audio. Accessibility and Microphone access are not part
  of the current display-only workflow.

## Current release

The current release is
[`v1.1.0`](https://github.com/ycl-2004/Screen-Bridge/releases/tag/v1.1.0).

| Item | Current state |
| --- | --- |
| Source snapshot | Git tag `v1.1.0` |
| Mac bundle metadata | `1.1.0 (build 2)` |
| iPad bundle metadata | `1.1.0 (build 2)` |
| Mac release asset | `Screen-Bridge-v1.1.0-macOS-universal.zip` |
| Mac architectures | `arm64` + `x86_64` |
| Mac signature | ad-hoc, Hardened Runtime, not notarized |
| Mac ZIP SHA-256 | `1e06b1b8c350094c26c70d094cac1411bd7d5ba50cc49ff342687efd4bb4bda7` |
| iPad release asset | Not published; requires account/device-specific signing |

See the [v1.1.0 release notes](docs/release-notes/v1.1.0.md) for changes and the
verification boundary.

## FAQ

<details>
<summary>Does the Mac download work on Apple silicon and Intel?</summary>

Yes. The executable inside the `v1.1.0` ZIP was inspected with `lipo` and
contains both `arm64` and `x86_64` slices.

</details>

<details>
<summary>Why does macOS warn when I open the app?</summary>

The current ZIP is ad-hoc signed and not notarized. Control-click the app,
choose **Open**, and confirm the one-time prompt. A normal public installer
requires a Developer ID Application certificate and Apple notarization.

</details>

<details>
<summary>Why is there no downloadable iPad IPA?</summary>

iPad installation requires an Apple team, a provisioning profile, and usually
a registered device. A Personal Team profile is short-lived and is not a public
distribution mechanism, so the receiver is installed from Xcode instead.

</details>

<details>
<summary>Is Screen Bridge a mirror or an extended display?</summary>

Extended Display is the intended mode. Drag a Mac window onto the Screen Bridge
display. Mirror mode exists for diagnosis, but it is not the primary workflow.

</details>

<details>
<summary>What happens when the iPad goes into the background?</summary>

The socket is expected to be suspended by iPadOS. Screen Bridge holds the Mac
virtual display for up to five minutes and keeps reconnecting; a returning
authenticated receiver adopts the held display so windows remain in place.

</details>

## Build from source

<details>
<summary>Tests, Mac packaging, and iPad build commands</summary>

Clone the repository:

```bash
git clone https://github.com/ycl-2004/Screen-Bridge.git
cd Screen-Bridge
```

Run the test suite:

```bash
swift test
```

Build an ad-hoc Universal ZIP for local/self-use testing:

```bash
ALLOW_AD_HOC=1 PACKAGE_FORMAT=zip ./make_app.sh
```

`PACKAGE_FORMAT=auto` tries a DMG first and falls back to ZIP. A public Mac
distribution build should use Developer ID signing and notarization:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
APPLE_ID="you@example.com" \
APP_PASSWORD="app-specific-password" \
TEAM_ID="TEAMID" \
PACKAGE_FORMAT=dmg \
./make_app.sh
```

Build the iPad receiver without signing to verify the generic device target:

```bash
xcodebuild -project BetterCastIOS.xcodeproj \
  -scheme BetterCastReceiverIOS \
  -destination 'generic/platform=iOS' \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```

For a real iPad, choose an Apple Team in Xcode and run the same scheme on the
device. A signed IPA can be exported only with a matching export-options plist:

```bash
EXPORT_OPTIONS_PLIST=/absolute/path/ExportOptions.plist \
ALLOW_PROVISIONING_UPDATES=1 \
./package_ios_ipa.sh
```

</details>

## Project layout

- `Sources/BetterCastSender/` — macOS UI, discovery, pairing, virtual display,
  capture, encoding, audio capture, and stream orchestration.
- `Sources/BetterCastSenderSupport/` — Core Audio app discovery and routing
  policy.
- `Sources/BetterCastReceiverIOS/` — iPad listener, pairing, decode, render,
  audio playback, and lifecycle.
- `Sources/BetterCastShared/` — shared authentication, framing, session,
  liveness, retry, and bitrate policies.
- `Tests/` — protocol, policy, Keychain, media, and audio routing tests.
- `BetterCastIOS.xcodeproj/` — iPad app project and signing settings.
- `make_app.sh` — Universal Mac app plus DMG/ZIP packaging.
- `package_ios_ipa.sh` — signed iPad archive/export workflow.
- `docs/decisions/` — architecture decision records.
- `docs/audits/` — audits, known issues, and historical captures.

Internal `BetterCast*` target names, bundle IDs, Keychain IDs, and protocol
identifiers remain for compatibility. The product, app display names, package
names, repository, and release documentation use Screen Bridge.

## Versioning and releases

The current public version is `v1.1.0`. App metadata uses `1.1.0` with build
number `2`; the in-app label, packaging scripts, README, release notes, Git tag,
and GitHub Release use `v1.1.0`.

Release binaries belong in GitHub Releases, not in the source tree. Historical
`v1`, `v1.0`, and `v2.0` tags remain untouched as repository history.

## Verification status

The `v1.1.0` release candidate was verified on macOS 26.6.1 with Swift 6.3.3
and Xcode 26.6:

- `swift test`: 136 tests, 0 failures.
- Universal Release build: succeeded for `arm64` and `x86_64`.
- App bundle: `1.1.0 (2)`, macOS 14.0 minimum, ad-hoc signature verified with
  `codesign --verify --deep --strict`.
- ZIP: integrity test passed; an independently extracted app retained both
  architectures, version metadata, and a valid ad-hoc signature.
- Unsigned generic iOS Release build: succeeded and produced an `arm64`
  `Screen Bridge.app` with `1.1.0 (2)` metadata.
- Plist validation, shell syntax checks, and `git diff --check`: passed.

Swift 6.3's opt-in `-strict-concurrency=complete -warnings-as-errors` check does
not currently pass because existing Core Audio/GCD closures are not fully
annotated `Sendable`. The standard Swift 5 language-mode build and all tests do
pass; this stricter migration item is tracked as a known limitation rather than
being hidden by the release packaging.

## Known limitations

- The Mac ZIP is ad-hoc signed and not notarized. Gatekeeper may require the
  Control-click → **Open** path, and macOS Local Network permission identity may
  not remain stable between rebuilt ad-hoc versions.
- No public iPad IPA is shipped. Install the receiver with your own Xcode team.
- Fresh Screen Bridge screenshots have not yet replaced the historical audit
  captures.
- Swift 6.3 strict concurrency checking exposes existing `Sendable` annotation
  work in the Core Audio/GCD path, although normal builds and tests pass.
- Video and audio are intended for trusted local networks and are not
  independently encrypted end to end.
- The source-provenance question tracked as K5 in
  [the known-issues audit](docs/audits/2026-08-15-change-review-known-issues.md)
  still needs owner/legal evidence before treating the project as cleared for
  unrestricted public redistribution.

## License

Screen Bridge is distributed under the [MIT License](LICENSE). The repository's
license declaration does not replace the unresolved source-provenance evidence
noted above.

## Links

- [GitHub repository](https://github.com/ycl-2004/Screen-Bridge)
- [Current release: v1.1.0](https://github.com/ycl-2004/Screen-Bridge/releases/tag/v1.1.0)
- [Release notes: v1.1.0](docs/release-notes/v1.1.0.md)
- [GitHub readiness notes](docs/github-readiness.md)
- [Architecture decisions](docs/decisions)
