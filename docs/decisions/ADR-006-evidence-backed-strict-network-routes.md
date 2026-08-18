# ADR-006: Evidence-Backed Strict Network Routes

- Status: Accepted
- Date: 2026-08-18

## Context

The old cable preference prohibited Wi-Fi for one dial, then silently retried
without restrictions. The UI continued to present the user's cable choice even
when the established stream used router Wi-Fi. Discovery also discarded
`NWBrowser.Result.interfaces`, and connection diagnostics treated
`NWPath.availableInterfaces.first` as the active interface even though that
property is a list of interfaces available to the path.

Sidecar's USB transport is a system feature and is not exposed as a reusable
third-party protocol. Screen Bridge must therefore express only what Apple's
public Network.framework APIs can prove.

Official API references:

- https://developer.apple.com/documentation/network/nwbrowser/result/interfaces
- https://developer.apple.com/documentation/network/nwparameters/requiredinterface
- https://developer.apple.com/documentation/network/nwpath
- https://developer.apple.com/documentation/network/nwlistener/init(using:on:)

## Decision

Screen Bridge exposes four modes:

- Auto allows Network.framework to select any non-loopback route.
- Require Cable accepts only Bonjour results with a wired interface and sets
  that exact interface as `NWParameters.requiredInterface`.
- AWDL accepts only Bonjour results observed on `awdl`/`llw` and requires that
  exact interface.
- Wi-Fi accepts only infrastructure Wi-Fi Bonjour results, disables
  peer-to-peer routing, and requires that exact interface.

Changing modes cancels the current browser and pending unauthenticated dials,
clears their endpoints, and starts a new mode-scoped browse. Strict modes fail
visibly and never fall back. Existing authenticated streams are not migrated;
the mode applies to new connections.

The UI reports three separate facts: requested route, Network.framework path
type, and interface evidence. It never labels an item from
`availableInterfaces` as the active interface. Auto intentionally reports that
there is no physical-interface proof.

The iPad keeps one listener. It first binds TCP 51820 and advertises the actual
listener endpoint through Bonjour. If that port is already in use, it retries
with a dynamic port. This preserves Bonjour as the source of truth while making
direct diagnostics and controlled local tests predictable.

## Consequences

Cable and AWDL failures are now honest and actionable, at the cost of no longer
masking unavailable strict routes with a working Wi-Fi connection. Auto remains
the user-friendly choice when reachability matters more than transport.

USB is opportunistic: Require Cable can succeed only when macOS/iPadOS expose a
usable IP interface and Bonjour observes the receiver there. The app does not
claim to reproduce Sidecar or create a USB tunnel itself.
