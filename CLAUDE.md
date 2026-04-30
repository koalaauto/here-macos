# Here — AI Assistant Notes

Long-term menu bar macOS app showing your current egress country/region. Default IP-lookup provider: **ipwho.is** (since v0.26.0; previously ip.guide v0.23.x–v0.25.x). The lookup layer is provider-pluggable — see `Here/Networking/IPProvider.swift`.

(Originally shipped as "IP Guide" through v0.23.x; renamed to **Here** at v0.24.0. Default provider switched to ipwho.is at v0.26.0 because ip.guide silently misreported VPN egresses — Korean nodes shown as Cyprus, etc.)

## Architecture at a glance

- Entry: `Here/App/HereApp.swift` (SwiftUI `App`, settings-only scene)
- `AppDelegate` builds `AppEnvironment` + `StatusBarController`
- `StatusBarController` owns `NSStatusItem` + `NSPopover` (AppKit-managed)
- Popover content rendered with SwiftUI via `NSHostingController`
- All IP-lookup networking flows through `IPService` (actor) → an `IPProvider` (`IPWhoIsProvider` is the default); emits `IPState` via `AsyncStream`. Each provider owns its own raw-response shape and a `map(_:)` adapter into the shared `IPDataModel` — swapping providers is mechanical, not a UI / cache rewrite.
- `RefreshScheduler` runs the IP refresh loop on a hardcoded 5 s cadence (30 s while the display is asleep). `NetworkMonitor` (`NWPathMonitor`) fires extra immediate refreshes on `becameReachable` / `pathChanged`; lid-wake does the same. The polling loop is the safety net for everything else — at 5 s, you don't need a custom `SCDynamicStore` observer to catch WiFi hops or proxy toggles.
- `UpdateChecker` (actor) + `UpdateInstaller` (actor) + `UpdateCoordinator` (@MainActor) handle the auto-update pipeline.
  - **Checker**: hits GitHub `releases/latest`, returns `UpdateInfo` (version + release URL + DMG asset URL).
  - **Coordinator**: owns the daily wake-up timer, persists `lastUpdateCheckAt` / `skippedUpdateVersion` in `SettingsStore`, presents the "Update available" alert and the install progress NSPanel.
  - **Installer**: URLSession-downloads the DMG (intentionally avoids `com.apple.quarantine` xattr that browser downloads carry — that's how we skip the Gatekeeper "open anyway" prompt on every upgrade), `hdiutil attach`s it, `ditto`-copies `Here.app` to a staging dir, then writes a tiny bash relauncher that polls our PID, swaps `/Applications/Here.app`, and `open`s the new bundle. We `NSApp.terminate(nil)` ourselves; the script outlives us by being detached from our stdio.
- Picker (Never / Once a day / Once a week) + Check now button live in General settings.
- The popover footer's settings gear opens Settings via SwiftUI's `\.openSettings` env action; the right-click menu's Settings… item calls the same captured action through `AppEnvironment.openSettingsAction`. Don't try to open Settings via `NSApp.sendAction(showSettingsWindow:)` from AppKit code — for LSUIElement apps with no visible main menu it silently no-ops.
- Settings use an `@Observable` `SettingsStore` with UserDefaults-backed properties (manual `didSet` persistence)
- Cache at `~/Library/Application Support/Here/last_ip.json` (we ship without App Sandbox — see `Here/Here.entitlements` for why; the in-app installer needs to spawn `hdiutil` and write outside the container).

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

- `SMAppService.mainApp.register()` works from any signed bundle path on macOS 13+, including Debug builds running from DerivedData. Earlier-era "must live in /Applications" guidance is no longer accurate; don't re-add that gate. Surface registration errors inline only when `register()` actually throws.
- IP providers don't ship ISO 3166-2 region codes. `RegionMapper` uses `CLGeocoder` with a city-initials fallback. See `Services/RegionMapper.swift` for the ordering.
- Flag emoji for Taiwan (TW) may render as "TW" text on some system configurations — offer text fallback via `CountryStyle.text`.
- `IPDataModel.countryAlpha2` is a **stored** field, populated by each provider's `map(_:)` adapter. `IPWhoIsProvider` reads `country_code` directly from the wire payload — there's no English-name lookup in the model layer anymore. (We *did* have a `CountryNameMapper` for the ip.guide era; deleted in v0.26.0 along with `IPGuideProvider`.) When adding a future provider, the rule is: provider returns alpha-2; don't push name-lookup logic into the model.
- Never "fall back" to ASN-registered country for the flag — VPN ASNs routinely register in a different country than their actual egress (NL-registered AS serving KR users, HK-registered AS serving TW users). Use `location` data from the provider; if the provider lies, switch providers.
- `CLGeocoder` is rate-limited by Apple; always rely on `RegionMapper`'s in-actor cache before issuing a new request.
- `IPService` does **not** retry internally (single attempt per `refresh()` call). The scheduler is the retry layer — via periodic timer + network events. Don't re-add exponential backoff inside IPService; a failed fetch for an unreachable upstream would hammer the host for ~45 s.
- `NSPopover` `.transient` dismiss timing can be flaky under focus steal. If reported, look at `NSEvent.addGlobalMonitorForEvents` as a workaround.
- The hand-written `project.pbxproj` uses a consistent ID scheme (`AA0000...`). When Xcode adds new files, it inserts its own UUIDs — fine; don't try to enforce the old scheme.
- The popover anchors to an **invisible NSWindow** rather than directly to the menu-bar button (see `StatusBarController.openPopover`). This is the workaround for NSPopover sliding sideways when the widget reflows. **Re-verify on every macOS major upgrade**: open popover → click refresh several times → popover must stay put. If it drifts even one pixel, the workaround has regressed and we need to fall back to a custom NSPanel implementation.
- `URLProtocolMock` (in `HereTests/Support/`) keeps its `handler` in a class-static slot. Swift Testing's `.serialized` only orders tests **within** a suite — different suites still run in parallel. Two suites both poking that single slot will race (we hit this when `UpdateCheckerTests` and `IPWhoIsProviderTests` collided over a 503 vs URLError handler). When you write a new mocked-URLSession suite, give it its own `URLProtocol` subclass (see `UpdateMockURLProtocol` inside `UpdateCheckerTests.swift`) instead of sharing the global one.
- App Sandbox is **off** (`Here/Here.entitlements` is empty). Don't re-enable `com.apple.security.app-sandbox` without also rewriting the in-app installer — sandboxed processes can't `hdiutil attach` (the system service `diskimagesiod` denies sandbox-originated mount requests) and can't `mv` into `/Applications`. If the app ever needs to ship via the App Store, the installer becomes a privileged helper tool instead.

## Where things live

- New IP provider → implement `IPProvider` (in `Networking/IPProvider.swift`), register in `AppEnvironment`.
- Change display formats → `StatusBar/StatusBarTitleRenderer.swift` + `Models/DisplayStyle.swift`.
- Tweak popover UI → `UI/Popover/`; settings UI → `UI/Settings/`.
- Add a metric to the popover → extend `IPDataModel` (may need derived property), add a `CopyableRow` in the appropriate card.
- Add a new settings toggle → add a property + UserDefaults key in `SettingsStore`, bind to a control in the relevant `*SettingsView.swift`.
- Add a new refresh trigger → observe inside `RefreshScheduler`; don't sprinkle triggers elsewhere.
- Change widget border tint → `StatusBarTitleRenderer.BorderTint` + `StatusBarController.currentBorderTint()`.
- Touch the update flow → wire format + version compare in `Networking/UpdateChecker.swift`; download/mount/copy/relaunch in `Services/UpdateInstaller.swift`; cadence + alert + progress UI in `Services/UpdateCoordinator.swift`; the progress panel's view in `UI/UpdateProgressView.swift`. The frequency picker + Check now button live in `UI/Settings/GeneralSettingsView.swift`.

## When adding features

1. Write the test first (Swift Testing; fixtures in `HereTests/Fixtures/`).
2. Keep `AppEnvironment` as the single DI container; no hidden singletons.
3. Background work: decide between the refresh loop / `NetworkMonitor` trigger / `SystemNetworkObserver` trigger / new `AsyncStream` source — state the choice in the PR description.
4. New user-visible strings: add to both `String(localized:)` call sites AND `Localization/en.lproj/Localizable.strings` (keys must match).

## Roadmap (v1+)

- IPv6 dual stack
- Swift Charts sparkline for latency history
- Multiple IP providers with failover (architecture is in place — `IPProvider` protocol with `map(_:)` adapters; just need a Settings picker + voting/fallback logic in `IPService`)
- App Intents / Shortcuts integration
- Chinese localization (scaffolding is ready; only translation pending)
- Once a Developer ID lands: optionally migrate the in-app installer to Sparkle for ed25519-signed update feeds + delta updates. Today's `UpdateInstaller` already gives a one-click silent upgrade (URLSession download skips the quarantine xattr, so no Gatekeeper prompt) — Sparkle would mostly add provenance verification.

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

- Default provider: `GET https://ipwho.is/` — free, no auth, ~1 req/s per client IP. Returns `{ ip, success, country, country_code, city, latitude, longitude, connection: { asn, org, isp, domain }, timezone: { id, ... }, ... }`. On invalid input or rate-limit, returns HTTP 200 with `{"success": false, "message": "..."}` — `IPWhoIsProvider` translates that into `IPServiceError.transport`.
- The legacy ip.guide schema is preserved in git history if you need to compare; don't re-add it without a strong reason — it was unreliable for VPN egress IPs.
