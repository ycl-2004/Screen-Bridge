# GitHub Readiness Notes

This repository is close to being presentable as ScreenBridge, but there are two different cleanup levels:

## Ready Now

- The public README describes ScreenBridge and the Mac-to-iPad workflow.
- The GitHub repository is intended to use the `screenbridge` path; local clones should point `origin` at the renamed URL.
- `make_app.sh` no longer contains a personal Developer ID or Team ID.
- `package_ios_ipa.sh` no longer contains a personal DerivedData path.
- Generated distribution artifacts are ignored through `/dist/`, `*.app`, `*.dmg`, `*.ipa`, and related build rules.
- The user-facing macOS and iOS bundle display names are `ScreenBridge`.
- The local discovery service is `_yc-cast._tcp`.
- The repository declares MIT, but the source-provenance compatibility question tracked as K5 still requires owner/legal evidence before public redistribution.
- Release notes now describe the current ScreenBridge v8 work instead of old product history.

## Still Worth Doing Before A Fully Public Launch

- Rename internal SwiftPM targets and source folders from `BetterCast*` to `YCCast*` if you want the source tree itself to be fully branded.
- Remove or archive dormant Android, Windows, Linux, and desktop receiver modules if ScreenBridge will stay Mac+iPad only.
- Add a GitHub release workflow after you have a Developer ID certificate and notarization credentials.
- Add screenshots or a short demo GIF to the README after the UI is stable.
- Resolve K5 in `docs/audits/2026-08-15-change-review-known-issues.md` before treating the current license declaration as public-release clearance.

## Release Asset Policy

Do not commit built apps, DMGs, IPAs, or zip files. Put them in GitHub Releases so the source repository stays clean and reviewable.
