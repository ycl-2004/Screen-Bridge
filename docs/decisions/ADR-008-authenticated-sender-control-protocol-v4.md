# ADR-008: Protocol v4 — authenticated sender control and handshake version enforcement

- Status: Accepted
- Date: 2026-08-19
- Supersedes: none (extends ADR-002's security model)

## Context

A full security review of the v3 protocol found two gaps in the
sender→receiver direction on the plaintext media/control transport:

1. **Unauthenticated sender control.** The sender's media heartbeat (`0x04`)
   and disconnect notice (`0x03`) were single bare type bytes on the wire.
   The receiver→sender direction already carried every control message inside
   an `AuthenticatedEnvelope` (HMAC over a monotonic sequence number), but
   these two sender frames had no integrity protection at all. On a shared
   LAN, an on-path attacker could forge `0x03` to tear down live sessions or
   forge `0x04` to keep zombie sessions past liveness timeouts.
2. **No receiver-side version in the handshake.** `SenderHello` carried a
   protocol version, but `ReceiverHello` did not, and the sender never
   enforced equality. A future protocol change would have had no clean
   negotiation point; mismatches failed later as opaque decode errors.

A related finding: the auxiliary (audio) transport verified envelope MACs but
did not enforce sequence monotonicity, so a captured heartbeat envelope could
be replayed indefinitely to keep a dead receiver's session alive.

The first v4 draft reused one HMAC domain for both control directions. Because
both sides derive the same session key, an on-path peer could reflect a valid
receiver→sender envelope back as sender→receiver control. Even when the JSON
payload was not a valid sender command, advancing the receive sequence before
validating that command allowed the reflection to suppress later legitimate
heartbeats.

## Decision

Bump the protocol version 3 → 4. Sender and receiver must both be updated;
the version check makes old peers fail the handshake with an actionable
message ("check that both devices run the same app version") instead of
failing later on framing.

Concretely, protocol v4:

- Adds type byte `0x05` on the sender→receiver media transport:
  `[length][0x05][JSON AuthenticatedEnvelope]`. The envelope payload is a
  single command byte — `0x04` (heartbeat) or `0x03` (disconnect notice) —
  sealed with the media session key under the sender's own monotonic
  output sequence. The receiver rejects bare `0x03`/`0x04` frames with no
  effect (logged once), closes the transport on envelopes that fail MAC or
  command validation, and ignores stale/replayed sequence numbers.
- Uses separate HMAC domains for sender→receiver and receiver→sender envelopes.
  Direction is supplied by the transport role and is not attacker-controlled
  JSON. An envelope valid in one direction therefore fails verification if it
  is reflected into the opposite direction. The receiver validates the exact
  one-byte sender command before advancing its replay sequence.
- Adds `version` to `ReceiverHello`. The sender now enforces equality with
  `PrivateBetterCastConstants.protocolVersion` in both handshake directions;
  a mismatch fails as `unsupportedProtocol` instead of dead code. A legacy v3
  hello with no field decodes to a version-0 sentinel so it reaches the same
  explicit mismatch path rather than surfacing as an opaque JSON error.
- Enforces per-transport monotonic sequence numbers on **all** envelope
  receivers: the media transport (sender side, receiver→sender), the
  auxiliary audio transport (sender side, previously MAC-only), and the new
  sender-control path (receiver side).

Media payloads (video/audio) remain unencrypted and unauthenticated by
design, as documented in ADR-002 and the README: pairing authenticates
devices and control messages, not media confidentiality.

## Consequences

- A macOS sender v4 cannot pair with an iPad receiver v3 (and vice versa).
  Both apps ship from the same repository and are updated together.
- An on-path attacker can no longer forge or replay control messages in
  either direction without the session key, or reflect a valid envelope from
  the opposite direction to poison replay state.
- Direction separation and the v4 envelope add only control-plane HMAC/JSON
  work. They do not change video resolution, frame rate, bitrate, AAC bitrate,
  or media packet cadence.
- The framing auto-detection on the receiver now treats `0x05` as a
  type-byte marker alongside `0x01`–`0x04`.
- The dormant desktop/Android senders in the repository still speak their
  legacy framing; reviving them against a v4 receiver requires adopting the
  v4 handshake (or keeping them on v3-era receivers).
