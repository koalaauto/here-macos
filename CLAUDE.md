# Here — AI Assistant Notes

Long-term menu bar macOS app showing your current egress country/region from https://ip.guide.

(Originally shipped as "IP Guide" through v0.23.x; renamed to **Here** at v0.24.0. The data source is unchanged.)

## Architecture at a glance

- Entry: `Here/App/HereApp.swift` (SwiftUI `App`, settings-only scene)
- `AppDelegate` builds `AppEnvironment` + `StatusBarController`
- `StatusBarController` owns `NSStatusItem` + `NSPopover` (AppKit-managed)
- Popover content rendered with SwiftUI via `NSHostingController`
- All ip.guide networking in `IPService` (actor); emits `IPState` via `AsyncStream`
- Network state change detection split across two observers:
  - `NetworkMonitor` — `NWPathMonitor`, for online/offline + interface-type shifts + same-type path updates (debounced)
  - `SystemNetworkObserver` — `SCDynamicStore` watching `State:/Network/Global/IPv4`, `…/DNS`, `…/Proxies`; catches WiFi-SSID changes and Clash "system proxy" flips that NWPathMonitor doesn't surface
- `RefreshScheduler` is the single place that turns those signals into `ipService.refresh(force: true)`; snapshot-scoped burst coalesce + post-error cooldown so a single network change produces exactly one probe
- Settings use an `@Observable` `SettingsStore` with UserDefaults-backed properties (manual `didSet` persistence)
- Cache at `~/Library/Containers/app.here-macos/Data/Library/Application Support/Here/last_ip.json`

## Prerequisites

- **Xcode 16+** (only Command Line Tools won't build an `.app` bundle)
- **macOS 15+** runtime
- Swift 6 strict concurrency enabled

Install full Xcode from the Mac App Store or developer.apple.com. `xcode-select -s /Applications/Xcode.app/Contents/Developer` points `xcodebuild` at it.

## Build & run

- Open `Here.xcodeproj` in Xcode, Cmd-R.
- CLI: `xcodebuild -project Here.xcodeproj -scheme Here -configuration Debug build`
- Unit tests: Cmd-U in Xcode, or `xcodebuild -project Here.xcodeproj -scheme Here test`
- Tail logs: `log stream --predicate 'subsystem == "app.here-macos"' --info --debug`

## Conventions

- Swift 6 strict concurrency — actors for shared mutable state, `@MainActor` for UI.
- One concern per file; target under ~200 LOC.
- No third-party UI libraries. Core Services only (`URLSession`, `NWPathMonitor`, `SCDynamicStore`, `CLGeocoder`, `SMAppService`, `NSStatusItem`, `NSPopover`, `MapKit`).
- Prefer `async/await` over Combine.
- Log with `os.Logger` (via `Log` enum), never `print`. IP addresses masked (`.private`) in logs.
- All user-visible strings via `String(localized:)` → `Here/Resources/Localization/en.lproj/Localizable.strings`.
- Tests use Swift Testing (`import Testing`) with `@Test` and `#expect`.

## Known gotchas

- `NWPathMonitor` doesn't reliably fire `pathUpdateHandler` for same-interface-type changes (WiFi-A → WiFi-B on the same `en0`). That's why `SystemNetworkObserver` exists alongside it. Don't collapse them into one source; each catches what the other misses.
- `SMAppService.mainApp.register()` works from any signed bundle path on macOS 13+, including Debug builds running from DerivedData. Earlier-era "must live in /Applications" guidance is no longer accurate; don't re-add that gate. Surface registration errors inline only when `register()` actually throws.
- `ip.guide` returns no ISO 3166-2 region code. `RegionMapper` uses `CLGeocoder` with a city-initials fallback. See `Services/RegionMapper.swift` for the ordering.
- Flag emoji for Taiwan (TW) may render as "TW" text on some system configurations — offer text fallback via `CountryStyle.text`.
- `IPDataModel.countryAlpha2` derives from `location.country` (geographic), NOT `network.autonomousSystem.country` (ASN registration, often HK for Asian VPN providers). `CountryNameMapper` handles the English-country-name → alpha-2 lookup. Don't "simplify" by going back to the ASN country — the TW-shown-as-HK bug came from that.
- `CLGeocoder` is rate-limited by Apple; always rely on `RegionMapper`'s in-actor cache before issuing a new request.
- `IPService` does **not** retry internally (single attempt per `refresh()` call). The scheduler is the retry layer — via periodic timer + network events. Don't re-add exponential backoff inside IPService; a failed fetch for an unreachable ip.guide would hammer the host for ~45 s.
- `RefreshScheduler` coalesce is **snapshot-scoped**, not purely time-based. A time-only "post-error cooldown" blocks genuine re-switches to a different network. The scheduler reads `systemNetworkObserver.primaryIPv4Snapshot()` and only suppresses events whose snapshot matches the one that last failed.
- `NSPopover` `.transient` dismiss timing can be flaky under focus steal. If reported, look at `NSEvent.addGlobalMonitorForEvents` as a workaround.
- The hand-written `project.pbxproj` uses a consistent ID scheme (`AA0000...`). When Xcode adds new files, it inserts its own UUIDs — fine; don't try to enforce the old scheme.

## Where things live

- New IP provider → implement `IPProvider` (in `Networking/IPProvider.swift`), register in `AppEnvironment`.
- Change display formats → `StatusBar/StatusBarTitleRenderer.swift` + `Models/DisplayStyle.swift`.
- Tweak popover UI → `UI/Popover/`; settings UI → `UI/Settings/`.
- Add a metric to the popover → extend `IPDataModel` (may need derived property), add a `CopyableRow` in the appropriate card.
- Add a new settings toggle → add a property + UserDefaults key in `SettingsStore`, bind to a control in the relevant `*SettingsView.swift`.
- Add a new refresh trigger → observe inside `RefreshScheduler`; don't sprinkle triggers elsewhere.
- Change widget border tint → `StatusBarTitleRenderer.BorderTint` + `StatusBarController.currentBorderTint()`.

## When adding features

1. Write the test first (Swift Testing; fixtures in `HereTests/Fixtures/`).
2. Keep `AppEnvironment` as the single DI container; no hidden singletons.
3. Background work: decide between the refresh loop / `NetworkMonitor` trigger / `SystemNetworkObserver` trigger / new `AsyncStream` source — state the choice in the PR description.
4. New user-visible strings: add to both `String(localized:)` call sites AND `Localization/en.lproj/Localizable.strings` (keys must match).

## Roadmap (v1+)

- IPv6 dual stack
- Swift Charts sparkline for latency history
- Multiple IP providers with failover
- App Intents / Shortcuts integration
- Chinese localization (scaffolding is ready; only translation pending)
- Sparkle auto-updater for notarized distribution

## Versioning

Two fields in `Here/Resources/Info.plist`:
- `CFBundleShortVersionString` (marketing version) — semver `MAJOR.MINOR.PATCH`.
  Pre-1.0 rule: bump **MINOR** (`0.X.0`) for any user-visible feature or UX change; bump **PATCH** (`0.x.Y`) for pure bug fixes. Reserve MAJOR for a deliberate 1.0 ship.
- `CFBundleVersion` (build number) — strictly increasing integer. **+1 every time the Info.plist is touched for a release/test build.** Never decreases, never resets.

**Whenever a code change ships out of this repo (rebuild to test or tag), bump both fields in the same commit.** The About dialog shows `0.24.0 (55)` — short version in parens around build number.

### GitHub release format (standard)

Keep release title and tag **identical**: `vMAJOR.MINOR.PATCH` (e.g. `v0.24.0`). No tagline, no date, no suffix — the substance goes in the body.

Release body template:

```markdown
## Install
1. Download Here-X.Y.Z.dmg below.
2. Open and drag Here into Applications.
3. First launch: right-click → Open → Open (unsigned build).

## Changes
- ...

## System requirements
- macOS 15 Sequoia or later.
```

## Reference

- API: `GET https://ip.guide/` returns `{ ip, network, location }` JSON (no auth)
