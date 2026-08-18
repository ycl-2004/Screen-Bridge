# ADR-005: Adopt Screen Bridge as the Product Name

## Status

Accepted

## Date

2026-08-18

## Context

The project currently presents itself as YC Cast, while the product's central promise is more specific: a Mac creates an extended display and Screen Bridge renders that display on an iPad. “Cast” suggests media casting or screen mirroring, which is less precise for a true second-screen workflow.

The repository also contains historical BetterCast module names, bundle identifiers, Keychain identifiers, and the `_yc-cast._tcp` Bonjour service. Changing those identifiers would create compatibility and migration risk without improving the user's understanding of the product.

## Decision

Adopt **Screen Bridge** as the user-facing product name. Use
`Screen-Bridge` for the GitHub repository slug because repository URLs cannot
preserve a literal space.

Use the descriptor:

> Turn your iPad into a second display for your Mac.

Update the app display names, packaging names, permission text, UI copy, README, release notes, current operational documentation, and GitHub repository path. Preserve BetterCast source/module names, bundle identifiers, Keychain identifiers, protocol labels, and Bonjour service identifiers as internal compatibility identifiers.

## Alternatives Considered

### Orbit Display

More brandable, but “Orbit” requires the additional word “Display” and does not communicate the Mac-to-iPad relationship by itself.

### YC Cast

Preserves the existing identity, but “Cast” is easily interpreted as mirroring or streaming media rather than extending the Mac desktop.

### Mac-to-iPad Display

Maximally explicit, but too generic to serve as a durable product identity.

## Consequences

- New users can infer the product's bridge/second-display role from the name and descriptor.
- Existing app installs and pairing state remain compatible because bundle, Keychain, protocol, and Bonjour identifiers do not change.
- Historical audit entries may continue to mention YC Cast or BetterCast when describing the state at the time of that record.
- The GitHub repository URL changes to `https://github.com/ycl-2004/Screen-Bridge`; GitHub's old repository URL redirect should preserve existing links, while local clones should update their `origin` URL.
