# GitHub Readiness Notes

This repository is close to being presentable as Screen Bridge, but there are two different cleanup levels:

## Ready Now

- The public README describes Screen Bridge and the Mac-to-iPad workflow.
- The GitHub repository uses the URL-safe `Screen-Bridge` path; local clones should point `origin` at the renamed URL.
- `make_app.sh` no longer contains a personal Developer ID or Team ID.
- `package_ios_ipa.sh` no longer contains a personal DerivedData path.
- Generated distribution artifacts are ignored through `/dist/`, `*.app`, `*.dmg`, `*.ipa`, and related build rules.
- The user-facing macOS and iOS bundle display names are `Screen Bridge`.
- The local discovery service is `_yc-cast._tcp`.
- The repository declares MIT, but the source-provenance compatibility question tracked as K5 still requires owner/legal evidence before public redistribution.
- Current release notes describe Screen Bridge v1; historical v8 notes remain as repository history.

## Still Worth Doing Before A Fully Public Launch

- Rename internal SwiftPM targets and source folders from `BetterCast*` to `YCCast*` if you want the source tree itself to be fully branded.
- Remove or archive dormant Android, Windows, Linux, and desktop receiver modules if Screen Bridge will stay Mac+iPad only.
- Add an automated GitHub release workflow after you have a Developer ID certificate and notarization credentials.
- Add screenshots or a short demo GIF to the README after the UI is stable.
- Resolve K5 in `docs/audits/2026-08-15-change-review-known-issues.md` before treating the current license declaration as public-release clearance.

## Release Asset Policy

Do not commit built apps, DMGs, IPAs, or zip files. Put them in GitHub Releases so the source repository stays clean and reviewable.

The current v1 Mac DMG is an Apple Development-signed, non-notarized self-use
artifact. Do not describe it as a general public installer. Do not upload a
Personal Team iPad IPA because its provisioning is account/device-specific and
short-lived.
