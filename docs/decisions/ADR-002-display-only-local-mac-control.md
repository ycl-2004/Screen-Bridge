# ADR-002: Display-Only iPad Receiver With Local Mac Control

## Status

Accepted

## Date

2026-05-17

## Context

ScreenBridge's current private workflow uses the iPad as an extended display for a Mac. In practice, iPadOS system gestures such as the app switcher/home gestures remain local to the iPad, while Mac control is most predictable when the user keeps using the Mac keyboard, trackpad, mouse, and clipboard.

The previous design allowed authenticated iPad-originated touch, pointer, scroll, and keyboard input to be injected into macOS through Accessibility. That made the permission model heavier and blurred whether "control" belonged to the iPad or the local Mac.

## Decision

Make the Mac-to-iPad product path display-only:

- The macOS sender does not expose an iPad Control toggle.
- The sender clears the legacy `iPadInputEnabled` user default and keeps that path disabled.
- The iPad receiver does not register touch-control gestures on the video renderer.
- The iPad receiver does not forward local touch events to the Mac.
- Authenticated receiver commands remain in scope for connection health, keyframe requests, and screen-size updates.
- Screen Recording remains required for display capture. Accessibility is no longer required for the display-only workflow.

## Alternatives Considered

### Keep Optional iPad Control

This preserves remote touch, scroll, mouse, and keyboard control from the iPad.

Rejected because the current goal is a plain second-screen experience where all direct control stays on the local Mac.

### Disable Only On The Mac

The sender could keep dropping input when the toggle is off while the receiver still emits touch events.

Rejected because it leaves misleading UI and unnecessary input traffic. The receiver should also behave like a display-only surface.

## Consequences

- iPad gestures remain iPadOS gestures; ScreenBridge does not try to suppress system-level iPad app switching or home gestures.
- Copy/paste is not a ScreenBridge control feature. Use the Mac clipboard for the streamed Mac display; Universal Clipboard remains an OS-level feature outside ScreenBridge.
- The security surface is smaller because the normal workflow no longer needs macOS Accessibility input injection.
