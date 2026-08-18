# ADR-003: One Logical Receiver Session With Typed Transports

- Status: Accepted
- Date: 2026-08-15

## Context

Screen Bridge opens a primary TCP connection for video/control and may open a second
TCP connection for Chrome audio. The iPad previously stored both in one array.
Any connection could publish the receiver's global UI state, and control
messages were broadcast to both. As a result, an auxiliary audio timeout could
make a healthy video session appear disconnected, while resetting the pairing
code left already authenticated transports alive.

The sender also learned the iPad's pixel dimensions from a control message sent
after streaming began. Best Fit therefore created a default virtual display,
then destroyed and replaced it when the dimensions arrived.

## Decision

Private protocol version 2 models one logical receiver session:

- A `mediaControl` handshake creates a receiver-generated session UUID.
- An `audio` handshake must present that UUID and may only join the currently
  active media session.
- Only the media/control connection drives receiver UI state, watchdog teardown,
  heartbeats, keyframe requests, background notices, and screen-info commands.
- The receiver sends its current pixel dimensions in `ReceiverHello`, before the
  sender creates its virtual display.
- A new authenticated media connection atomically replaces the old session and
  its auxiliary audio transport.
- Reset Pairing stops listeners, cancels pending and authenticated transports,
  resets decoder/audio state, and leaves the receiver in `pairingRequired` until
  a new code is stored.
- Pending handshake capacity is reserved when a connection is accepted, not
  after it reaches `ready`, and every terminal path releases that reservation
  exactly once.

Both ends of the private Mac-to-iPad product ship together, so version 1
compatibility is intentionally not retained.

## Consequences

The auxiliary audio path can fail or reconnect without changing the visible
video session state. Initial Best Fit setup has the receiver dimensions before
display creation. Pairing reset becomes an actual revocation boundary rather
than a Keychain-only preference change.

The protocol still uses the existing user-entered short pairing code and proof
exchange. PAKE, offline-guess resistance, media encryption, and hostile-LAN
hardening remain explicit non-goals for the single-user local-network product.

Runtime orientation changes still use command 777. Those changes may require a
display reconfiguration; the initial connection no longer does.
