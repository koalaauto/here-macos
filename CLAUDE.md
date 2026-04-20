# IP Guide — AI Assistant Notes

Long-term menu bar macOS app showing public-IP geolocation from https://ip.guide.

## Architecture at a glance

- Entry: `IPGuide/App/IPGuideApp.swift` (SwiftUI `App`, settings-only scene)
- `AppDelegate` builds `AppEnvironment` + `StatusBarController`
- `StatusBarController` owns `NSStatusItem` + `NSPopover` (AppKit-managed)
- Popover content rendered with SwiftUI via `NSHostingController`
- All networking in `IPService` (actor); retry + coalesce + emit `IPState` via `AsyncStream`
- Settings use `@AppStorage` under an `@Observable` `SettingsStore`
- Cache at `~/Library/Containers/app.ipguide/Data/Library/Application Support/IPGuide/last_ip.json`

## Prerequisites

- **Xcode 16+** (only Command Line Tools won't build an `.app` bundle)
- **macOS 15+** runtime
- Swift 6 strict concurrency enabled

Install full Xcode from the Mac App Store or developer.apple.com. `xcode-select -s /Applications/Xcode.app/Contents/Developer` points `xcodebuild` at it.

## Build & run

- Open `IPGuide.xcodeproj` in Xcode, Cmd-R.
- CLI: `xcodebuild -project IPGuide.xcodeproj -scheme IPGuide -configuration Debug build`
- Unit tests: Cmd-U in Xcode, or `xcodebuild -project IPGuide.xcodeproj -scheme IPGuide test`
- Tail logs: `log stream --predicate 'subsystem == "app.ipguide"' --info --debug`

## Conventions

- Swift 6 strict concurrency — actors for shared mutable state, `@MainActor` for UI.
- One concern per file; target under ~200 LOC.
- No third-party UI libraries. Core Services only (`URLSession`, `NWPathMonitor`, `CLGeocoder`, `SMAppService`, `NSStatusItem`, `NSPopover`, `MapKit`).
- Prefer `async/await` over Combine.
- Log with `os.Logger` (via `Log` enum), never `print`. IP addresses masked (`.private`) in logs.
- All user-visible strings via `String(localized:)` → `IPGuide/Resources/Localization/en.lproj/Localizable.strings`.
- Tests use Swift Testing (`import Testing`) with `@Test` and `#expect`.

## Known gotchas

- `SMAppService.mainApp.register()` works from any signed bundle path on macOS 13+, including Debug builds running from DerivedData. Earlier-era "must live in /Applications" guidance is no longer accurate; don't re-add that gate. Surface registration errors inline only when `register()` actually throws.
- `ip.guide` returns no ISO 3166-2 region code. `RegionMapper` uses `CLGeocoder` with a city-initials fallback. See `Services/RegionMapper.swift` for the ordering.
- `@AppStorage` + `@Observable` requires manual `access(keyPath:)` / `withMutation(keyPath:)` bridging. `SettingsStore` already has this — don't remove it or observation will break.
- Flag emoji for Taiwan (TW) may render as "TW" text on some system configurations — offer text fallback via `CountryStyle.text`.
- `NSPopover` `.transient` dismiss timing can be flaky under focus steal. If reported, look at `NSEvent.addGlobalMonitorForEvents` as a workaround.
- `CLGeocoder` is rate-limited by Apple; always rely on `RegionMapper`'s in-actor cache before issuing a new request.
- The hand-written `project.pbxproj` uses a consistent ID scheme (`AA0000...`). When Xcode adds new files, it will insert its own UUIDs — fine; don't try to enforce the old scheme.

## Where things live

- New IP provider → implement `IPProvider` (in `Networking/IPProvider.swift`), register in `AppEnvironment`.
- Change display formats → `StatusBar/StatusBarTitleRenderer.swift` + `Models/DisplayStyle.swift`.
- Tweak popover UI → `UI/Popover/`; settings UI → `UI/Settings/`.
- Add a metric to the popover → extend `IPDataModel` (may need derived property), add a `CopyableRow` in the appropriate card.
- Add a new settings toggle → add `@AppStorage` + observable bridge in `SettingsStore`, bind to a control in the relevant `*SettingsView.swift`.
- Add a new refresh trigger → observe inside `RefreshScheduler`; don't sprinkle triggers elsewhere.

## When adding features

1. Write the test first (Swift Testing; fixtures in `IPGuideTests/Fixtures/`).
2. Keep `AppEnvironment` as the single DI container; no hidden singletons.
3. Background work: decide between the refresh loop / `NetworkMonitor` trigger / new `AsyncStream` source — state the choice in the PR description.
4. New user-visible strings: add to both `String(localized:)` call sites AND `Localization/en.lproj/Localizable.strings` (keys must match).

## Roadmap (v2+)

- IPv6 dual stack
- IP change history + Swift Charts sparkline
- Multiple IP providers with failover
- App Intents / Shortcuts integration
- Chinese localization (scaffolding is ready; only translation pending)
- Sparkle auto-updater for notarized distribution

## Versioning

Two fields in `IPGuide/Resources/Info.plist`:
- `CFBundleShortVersionString` (marketing version) — semver `MAJOR.MINOR.PATCH`.
  Pre-1.0 rule: bump **MINOR** (`0.X.0`) for any user-visible feature or UX change; bump **PATCH** (`0.x.Y`) for pure bug fixes. Reserve MAJOR for a deliberate 1.0 ship.
- `CFBundleVersion` (build number) — strictly increasing integer. **+1 every time the Info.plist is touched for a release/test build.** Never decreases, never resets.

**Whenever a code change ships out of this repo (rebuild to test or tag), bump both fields in the same commit.** The About dialog shows `0.2.0 (2)` — short version in parens around build number.

### GitHub release format (standard)

Keep release title and tag **identical**: `vMAJOR.MINOR.PATCH` (e.g. `v0.3.0`). No tagline, no date, no suffix — the substance goes in the body. This keeps the Releases page uniform, scriptable (`gh release view vX.Y.Z`), and easy to reference from PRs/commits.

Release body template:

```markdown
## Install
1. Download IPGuide-X.Y.Z.dmg below.
2. Open and drag IP Guide into Applications.
3. First launch: right-click → Open → Open (unsigned build).

## Changes
- ...

## System requirements
- macOS 15 Sequoia or later.
```

## Reference

- Project plan: `/Users/koala/.claude/plans/ip-guide-rippling-barto.md`
- API: `GET https://ip.guide/` returns `{ ip, network, location }` JSON (no auth)
