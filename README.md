<h1 align="center">Screen Bridge</h1>

<p align="center">
  <strong>Turn an iPad into a display-only extended screen for your Mac.</strong>
</p>

<p align="center">
  <a href="https://github.com/ycl-2004/Screen-Bridge/releases/tag/v1"><img src="https://img.shields.io/badge/release-v1-111111" alt="Screen Bridge v1 release"></a>
  <img src="https://img.shields.io/badge/macOS-14.0%2B-111111?logo=apple&logoColor=white" alt="macOS 14.0 or later">
  <img src="https://img.shields.io/badge/iPadOS-13.0%2B-111111?logo=apple&logoColor=white" alt="iPadOS 13.0 or later">
  <img src="https://img.shields.io/badge/Swift-SwiftUI%20%C2%B7%20Network.framework-F05138?logo=swift&logoColor=white" alt="Built with Swift and Apple frameworks">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-111111" alt="MIT License"></a>
</p>

<p align="center">
  <a href="#quick-start">Quick start</a>
  ·
  <a href="https://github.com/ycl-2004/Screen-Bridge/releases/download/v1/Screen-Bridge-v1.dmg">Mac DMG</a>
  ·
  <a href="#features">Features</a>
  ·
  <a href="#privacy-and-security">Privacy &amp; security</a>
  ·
  <a href="#current-release">Current release</a>
  ·
  <a href="#build-from-source">Build from source</a>
</p>

Screen Bridge turns an iPad into a real extended display for a Mac. The Mac
creates a virtual display, captures it, and streams it over a local Apple
device path; the Mac's keyboard, trackpad, mouse, clipboard, and system control
stay on the Mac.

The active product path is a macOS sender plus an iPadOS receiver. This is a
private, self-use project focused on one Mac and one iPad on a trusted local
network.

> **Current distribution status:** `v1` includes source and a universal Mac
> DMG signed with the owner's Apple Development identity. The DMG is a
> non-notarized self-use build, not a general public installer. The iPad app is
> built from Xcode with device-specific provisioning; no public IPA is shipped.

## Quick start

Screen Bridge is currently source-first. You need both the Mac sender and the
iPad receiver, the same pairing code on both devices, and a local network path
that the two devices can use.

Clone the repository and enter the project directory:

```bash
git clone https://github.com/ycl-2004/Screen-Bridge.git
cd Screen-Bridge
```

### Mac

1. For the owner's registered Mac, download
   [`Screen-Bridge-v1.dmg`](https://github.com/ycl-2004/Screen-Bridge/releases/download/v1/Screen-Bridge-v1.dmg),
   or build from source with your own signing identity.
2. Open the DMG and drag `Screen Bridge.app` to `/Applications`.
3. Open Screen Bridge and save a pairing code in Settings.
4. Keep `Use as` set to **Extended Display**.
5. Choose `Auto`, `Require Cable`, `AWDL`, or `Wi-Fi` according to the path you
   want to use. Strict modes never silently fall back to another interface.
6. Grant **Screen Recording** when macOS asks. Grant **Audio Recording** only
   when Chrome audio routing is enabled.

### iPad

1. Open `BetterCastIOS.xcodeproj` in Xcode.
2. Select the `BetterCastReceiverIOS` scheme and a real iPad as the destination.
3. Choose your own Apple Team for signing, then run the receiver.
4. Trust the developer profile and enable Developer Mode if iPadOS asks.
5. Save the same pairing code used on the Mac.
6. Leave the receiver open and connect to it from the Mac sidebar.

### System requirements

- macOS 14.0 or later for the Mac sender.
- iPadOS 13.0 or later for the receiver target.
- A Mac and iPad that can reach each other through a local Apple network path.
- Screen Recording permission on the Mac for display capture.
- Audio Recording permission only when optional Chrome audio routing is used.
- An Apple signing identity and provisioning profile for a real-device iPad
  install or a distributable build.

## Why Screen Bridge

- **An extended display, not an input bridge.** The iPad shows a real Mac
  virtual display. Use the Mac keyboard and trackpad to control it; iPad touch
  input is not forwarded to the Mac.
- **A clear local connection model.** Pairing, discovery, authentication,
  streaming, reconnecting, and failure are visible states on both devices.
- **A link-aware transport.** Auto, Apple peer-to-peer, infrastructure Wi-Fi,
  and wired-style paths can be selected and diagnosed separately.
- **Recovery without unnecessary rebuilds.** Short iPad backgrounding pauses
  the stream while preserving the Mac virtual display; unexpected wireless
  drops use bounded reconnect attempts.
- **Self-use by default.** Pairing secrets stay in Keychain, and the product
  does not require an account, cloud service, or telemetry pipeline.

## Features

**Extended display**

- Creates a virtual Mac display and places it to the right, left, above, or
  below the Mac display.
- Offers HiDPI resolution presets, including a larger-text `1024 x 768` option.
- Keeps the receiver display-only: Mac input remains the only control path.

**Connection and recovery**

- Discovers receivers through Bonjour service `_yc-cast._tcp`.
- Authenticates before the Mac creates the capture and streaming pipeline.
- Supports Auto plus strict AWDL, Wi-Fi, and cable routes backed by Bonjour
  interface evidence.
- Uses bounded backpressure, adaptive bitrate, keyframe requests, and bounded
  reconnect attempts after unexpected wireless drops.
- Tracks discovery, connecting, authenticating, connected, reconnecting, and
  failed states instead of reducing every failure to “not found.”

**Optional audio**

- Routes selected Chrome audio to the iPad when the required permission is
  granted.
- Shows waiting, connecting, streaming, retry, and failure states.
- Recovers the audio path when Chrome restarts or its audio processes change.
- Keeps up to eight AAC packets in a FIFO on its dedicated TCP sender; a full
  queue drops the oldest waiting packet instead of overwriting every packet
  that arrives during a send.
- Starts and resumes playback after five decoded packets (~107 ms at 48 kHz),
  so an underrun returns to buffering instead of making later packet arrival
  timing audible.

**Receiver behavior**

- Shows a disconnected state when the Mac stops sharing or the network drops.
- Holds a backgrounded session for up to five minutes before disconnecting.
- Requests a fresh keyframe after decode errors and when returning to the
  foreground.
- Separates heartbeat, video arrival, decode, and renderer health so a static
  desktop is not mistaken for a frozen pipeline.

## How it works

1. The Mac discovers the iPad over Bonjour.
2. Both sides normalize and load the same pairing secret.
3. A nonce-based HMAC-SHA256 handshake authenticates the session before media
   starts.
4. The Mac creates a virtual display, captures it through ScreenCaptureKit,
   encodes video/audio, and sends length-prefixed frames.
5. The iPad decodes and renders the display, while authenticated control
   messages report screen size, heartbeat, and keyframe requests.

The media/control transport and optional Chrome-audio transport have explicit
roles under one receiver-created protocol-v3 session. Version 3 audio packets
carry sequence, sample time, sample count, codec, and flags. An audio connection
cannot create or join a stale video session.

## Network modes

Screen Bridge exposes four transport preferences:

- `Auto` lets Network.framework choose among the receiver's available paths.
- `Require Cable` requires the exact wired interface on which Bonjour observed
  the receiver. It reports failure instead of silently switching to Wi-Fi.
- `AWDL` requires the receiver's Bonjour result on an `awdl`/`llw` interface.
- `Wi-Fi` requires an infrastructure Wi-Fi Bonjour interface and disables
  peer-to-peer routing.

The connected-device panel separates the requested route, Network.framework's
path type, and the concrete Bonjour interface evidence. The iPad listener
prefers TCP port 51820, falls back to a dynamic port only when that port is in
use, and continues to advertise the actual endpoint through Bonjour. Receiver
settings can export a bounded diagnostics log with listener, service, path,
interface, and disconnect events.

## Usage

- Mac trackpad gestures, Mission Control, Spaces, and keyboard shortcuts remain
  native Mac behavior. If the pointer is on the Screen Bridge display, macOS may
  show those system surfaces on the iPad just as it would on a physical monitor.
- iPad touches and iPadOS system gestures are never sent to the Mac. The
  receiver registers only local UI gestures, such as the gesture that reveals
  its settings button.
- Copy and paste on the streamed display use the Mac clipboard, because the
  virtual display belongs to the Mac.
- Backgrounding the iPad receiver pauses streaming for up to five minutes. A
  real network failure, force-quit, or manual disconnect ends the session
  immediately.

## Screenshots

Fresh Screen Bridge-branded product screenshots are not included yet. The
checked-in simulator captures below are historical audit evidence and still
show the old `YC Cast` product name, so they are intentionally not presented as
current marketing screenshots:

- [Historical iPad onboarding capture](docs/audits/2026-08-14-ipad-onboarding.png)
- [Historical iPad landscape capture](docs/audits/2026-08-14-ipad-landscape.png)

Capture new Screen Bridge screenshots after the app branding and real-device
workflow are re-verified.

## Privacy and security

- Pairing codes are normalized, hashed, and stored locally in Keychain on both
  the Mac and iPad.
- The Mac and iPad perform a nonce-based HMAC-SHA256 handshake before streaming
  starts.
- Authenticated session keys protect receiver control messages such as
  heartbeat, keyframe, and screen-size updates.
- Screen Bridge has no account, cloud sync, analytics, or telemetry service.
- Video and audio frames are intended for trusted local networks and are not
  independently encrypted beyond the local transport. Use a private pairing
  code and avoid untrusted networks.
- Screen Recording is required to capture the virtual display. Accessibility
  is not required for the current display-only Mac-to-iPad workflow.

## Current release

The current release is
[`v1`](https://github.com/ycl-2004/Screen-Bridge/releases/tag/v1). Its source,
user-facing UI, bundle metadata, packaging defaults, release notes, and Git tag
share one release identity.

| Item | Current state |
| --- | --- |
| Source snapshot | `v1` |
| Mac bundle metadata | `1.0 (build 1)` |
| iPad bundle metadata | `1.0 (build 1)` |
| Mac release asset | `Screen-Bridge-v1.dmg`, universal, Apple Development-signed, not notarized |
| iPad release asset | Not published; requires device-specific Xcode signing |
| Mac local test build | `ALLOW_AD_HOC=1 ./make_app.sh` |
| Public Mac distribution | Requires Developer ID signing and notarization |
| iPad distribution | Requires a signed Xcode archive/export with valid provisioning |

See the [v1 release notes](docs/release-notes/v1.md) for the shipped behavior
and the verification boundary.

## FAQ

<details>
<summary>Is Screen Bridge a mirror or an extended display?</summary>

It is an extended display. The Mac creates a virtual display and the iPad
renders that display. Drag a Mac window onto the Screen Bridge display instead
of mirroring the built-in Mac screen.

</details>

<details>
<summary>Can iPad touch or system gestures control the Mac?</summary>

No. iPad touches and iPadOS system gestures stay on the iPad. Mac trackpad,
keyboard, mouse, clipboard, Mission Control, and other Mac controls remain
local to the Mac.

</details>

<details>
<summary>Why does Screen Bridge ask for Screen Recording?</summary>

The Mac must capture the virtual display before it can encode and stream it.
Audio Recording is requested only when optional Chrome audio routing is turned
on. Accessibility is not required for the display-only workflow.

</details>

<details>
<summary>What happens when the iPad goes into the background?</summary>

Short backgrounding pauses the stream for up to five minutes while preserving
the Mac virtual display. Returning to the receiver resumes the session with a
fresh keyframe. Force-quitting, manually disconnecting, or exceeding the grace
period ends the session.

</details>

<details>
<summary>Why is the Mac DMG described as self-use?</summary>

The v1 DMG is signed with an Apple Development certificate and is not notarized.
That is sufficient for the owner's verified local workflow, but a general
public installer should be signed with Developer ID, submitted to Apple's
notary service, and have the notarization ticket stapled.

</details>

## Build from source

<details>
<summary>Requirements, tests, Mac packaging, and iPad export</summary>

### Shared tests

Run the shared protocol and policy tests:

```bash
swift test --filter BetterCastSharedTests
```

Build the Swift package:

```bash
swift build
```

### Mac local test build

The following command deliberately creates an ad-hoc local-test build. Do not
publish its DMG; use an Apple-issued signing identity for a distributable build.

```bash
ALLOW_AD_HOC=1 ./make_app.sh
```

For a public distribution build, supply a Developer ID identity and
notarization credentials:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
APPLE_ID="you@example.com" \
APP_PASSWORD="app-specific-password" \
TEAM_ID="TEAMID" \
./make_app.sh
```

### iPad build and install

Build for a generic real-device destination:

```bash
xcodebuild -project BetterCastIOS.xcodeproj \
  -scheme BetterCastReceiverIOS \
  -destination 'generic/platform=iOS' \
  -configuration Debug \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build
```

For local installation, open `BetterCastIOS.xcodeproj`, select a real iPad,
choose your Apple Team, and use Product → Run. An unsigned generic build is not
an installable release artifact.

To create a signed IPA through Xcode's archive/export flow:

```bash
EXPORT_OPTIONS_PLIST=/absolute/path/ExportOptions.plist \
ALLOW_PROVISIONING_UPDATES=1 \
./package_ios_ipa.sh
```

The export-options plist and signing identity must match the Apple account. A
free Personal Team has a short development provisioning lifetime and is not a
public distribution solution.

</details>

## Project layout

- `Sources/BetterCastSender/` — macOS sender UI, discovery, pairing, virtual
  display, capture, encoding, and stream orchestration.
- `Sources/BetterCastReceiverIOS/` — iPad listener, pairing, decode, render,
  audio playback, and receiver lifecycle.
- `Sources/BetterCastShared/` — shared protocol constants, pairing, framing,
  session policies, liveness, and adaptive bitrate decisions.
- `Tests/BetterCastSharedTests/` — shared authentication, framing, lifecycle,
  and policy regression tests.
- `BetterCastIOS.xcodeproj/` — iPad Xcode project and signing/build settings.
- `make_app.sh` — Mac app and DMG build script.
- `package_ios_ipa.sh` — signed iOS archive/export packaging script.
- `docs/decisions/` — architecture decision records.
- `docs/audits/` — verification reports, known issues, and historical captures.

Some internal Swift package targets and source paths retain historical
`BetterCast*` names for compatibility. The user-facing product, bundle display
names, packaging output, and release documentation use Screen Bridge.

## Versioning and releases

The public version is `v1`. App metadata uses semantic version `1.0` with build
number `1`; the in-app label, packaging scripts, release notes, README, and Git
tag use `v1`. Future releases must update those sources together before tagging.

Historical `v1.0`, `v2.0`, and `v8` references describe earlier repository
states and are not the current product release.

## Verification status

The shared test suite currently covers pairing, Keychain storage, framing,
AVCC parsing, session roles, reconnect policy, media liveness, bounded video
delivery, timed audio packets, the sender FIFO, and receiver rebuffering. The
v1 release run completed `102/102` tests with 0 failures.

The following remain outside the current automated evidence boundary:

- Mac-to-iPad real-device discovery, pairing, and extended-display streaming.
- Real AWDL, router Wi-Fi, and USB/Thunderbolt path behavior.
- Chrome audio playback and recovery on a real iPad.
- Signed IPA installation and Developer ID/notarized Mac distribution.

## Known limitations

- The downloadable v1 DMG is Apple Development-signed and not notarized; it is
  a self-use artifact, not a general public installer.
- No public IPA is provided because iPad installation requires provisioning
  tied to an Apple account and registered device.
- The checked-in logo and simulator captures still use the historical `YC`
  branding; fresh Screen Bridge-branded assets are required for public product
  presentation.
- Video and audio are designed for trusted local networks and are not
  independently encrypted end to end.
- The source-provenance/license question tracked as K5 in
  [the known-issues audit](docs/audits/2026-08-15-change-review-known-issues.md)
  still requires owner/legal evidence before public redistribution.

## License

Screen Bridge is released under the [MIT License](LICENSE). The license file
grants broad reuse, but public redistribution should still resolve the
source-provenance evidence tracked as K5 before treating the repository as
cleared for public distribution.

## Links

- [GitHub repository](https://github.com/ycl-2004/Screen-Bridge)
- [Current release: v1](https://github.com/ycl-2004/Screen-Bridge/releases/tag/v1)
- [GitHub readiness notes](docs/github-readiness.md)
- [Architecture decisions](docs/decisions)
- [Release notes: v1](docs/release-notes/v1.md)
