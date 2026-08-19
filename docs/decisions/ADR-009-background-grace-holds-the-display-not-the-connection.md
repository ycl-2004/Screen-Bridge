# ADR-009: Background grace holds the display, not the connection

- Status: Accepted
- Date: 2026-08-19
- Relates to: ADR-004 (media health and bounded delivery)

## Context

The receiver announces backgrounding with command `555`. The sender responded by
recording a grace start, pausing video and audio sends, and swapping its 15-second
heartbeat timeout for a 5-minute deadline — with the stated intent of keeping the
session and the Mac virtual display alive so a quick app switch on the iPad did
not tear the extended desktop down.

A real-device log shows that intent was never reached:

```
[12:24:40] Receiver ... entered background — grace period started (300s), keeping virtual display
[12:24:40] Sender: Receive error (fatal): POSIXErrorCode(rawValue: 54): Connection reset by peer
[12:24:40] VirtualDisplayManager: Destroyed virtual display 182
[12:24:40] Sender: Disconnected ... Remaining: 0
```

The grace period was defeated inside the same second, every time, and the full
session log contained no resume at all.

The cause is that `backgroundGraceStart` was only consulted by the heartbeat
timeout check. iPadOS suspends a backgrounded app and resets its sockets about a
second after the notice, so the sender always reached the fatal transport-error
path first — and that path destroyed the virtual display unconditionally. Every
window the user had on the extended display was bounced back to the Mac's own
screen, which is precisely what the grace period existed to prevent.

Holding the *connection* open is not available to us: the socket is torn down by
the operating system, not by either app.

## Decision

Express the grace period as a **display hold** rather than a held connection.

- On teardown, a pipeline whose grace window is still open parks its
  `VirtualDisplayManager` in a device-keyed hold instead of destroying the
  display. The hold carries the display ID, the exact geometry it was created
  with, and a deadline derived from the moment the receiver went to the
  background.
- The next authenticated session for the same device **adopts** the held display
  instead of creating one. Adoption is mandatory rather than an optimization:
  WindowServer publishes at most one of these private virtual displays at a
  time, so a second display created alongside a held one is created
  "successfully" and never goes online.
- Adoption requires exact geometry equality. A receiver that rotated, or a Mac
  whose resolution setting changed while the device was away, needs a genuinely
  different display; the hold is released and a fresh display is built.
- Auto-reconnect uses the hold's deadline as its budget instead of stopping at
  three attempts, and its back-off is capped so it keeps polling rather than
  backing off into minutes. Stopping early would strand a held display with
  nothing trying to reclaim it. A reconnect tick that finds a dial already in
  flight re-arms instead of abandoning the chain — an `Auto` chain can run for
  its whole route budget, which outlasts the follow-up timer.
- No disconnect notice is sent while holding. "Sender stopped sharing" is the
  wrong thing to tell a receiver we intend to reconnect to.
- A hold is released on adoption, on geometry mismatch, on expiry, on manual
  disconnect, on pairing reset, when extended display is switched off, and when
  another receiver connects and needs the single display slot. A live connection
  always outranks a parked one.

The state transitions live in `BackgroundDisplayHoldPolicy` in
`BetterCastShared`, alongside `ConnectionRetryPolicy`, because every bug in this
area is a state-transition bug rather than a networking bug. In particular, the
hold deadline returns `nil` once the window has elapsed — that is what stops the
expiry-driven teardown from re-holding the display it is retiring.

## Consequences

- A short app switch on the iPad keeps windows on the extended display. The
  connection still ends and is rebuilt; only the display survives.
- The Mac keeps a virtual display alive, and keeps dialing, for up to five
  minutes after a receiver backgrounds. That is deliberate: it is the entire
  behavior being purchased. It also means an iPad that backgrounds and never
  returns holds one virtual display for the grace window.
- Because WindowServer publishes one private virtual display at a time, a held
  display and a second receiver contend for the same slot. The connecting device
  wins.
- The receiver side is unchanged: it still sends `555` and still resumes with a
  screen-info update and a keyframe request on foreground.
- Covered by `Tests/BetterCastSharedTests/BackgroundDisplayHoldPolicyTests.swift`.
  The end-to-end behavior — backgrounding a real iPad and confirming windows stay
  put — still requires a device pass.
