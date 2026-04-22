# Here

A tiny native macOS menu bar app that tells you, at a glance, **where you currently are on the internet** — the country and region your outbound traffic actually leaves from, plus a rich popover with the details behind it.

<p align="center">
  <em>🇺🇸 CA&nbsp;&nbsp;·&nbsp;&nbsp;38.175.104.131&nbsp;&nbsp;·&nbsp;&nbsp;San Jose, United States</em>
</p>

Built for people who hop between VPNs, proxies, and networks. One glance at the menu bar tells you which country your egress is in today — no browser trip needed.

## Features

- **Menu bar pill** with country + region code (configurable: `US CA`, `🇺🇸 CA`, flag only, region only, text only). Rounded border tints red when the latency probe goes poor (timeout / > 2 s) so you know the network's actually broken without opening anything.
- **Real rectangular flag icons** (not wavy emoji) for 252 countries and territories — rendered monochrome against the menu bar tint, full-color inside the popover.
- **Clickable popover** with four reorderable modules:
  - **Location** — large copyable IP, mini MapKit preview (tap to open in Maps), timezone + live local clock, and an expandable Network drawer (CIDR, ASN + organization, RIR).
  - **History** — right-anchored chain of recent egress changes with "time ago" labels; newest chip on the right, aligned with the Latency bar's time axis.
  - **Latency** — horizontal bar of up to 60 probes with color-coded tiers (green < 500 ms, yellow < 1 s, orange < 2 s, red ≥ 2 s / timeout). Header shows last / avg / max. Hover a cell for an instant tooltip. Configurable target (Cloudflare / Google), interval, slot count.
  - **Throughput** — on-demand download speed test against Cachefly (default), Cloudflare, or your own HTTPS URL. Live Mbps + real progress bar during the transfer; last result persists.
- Flag on the hero row **follows the geo-country, not the ASN country** — a VPN whose ASN is registered in HK but serves nodes in TW shows the TW flag.
- **Unknown-state pill** — when the egress isn't verified yet (`.idle / .loading / .error`), the pill shows a random flag + the sentinel text `OO`, so you know at a glance the data isn't current. Red border surfaces when the latency probe is in the red tier.
- **Smart re-fetch triggers** — picks up every meaningful network state change:
  - `NWPathMonitor` for interface / online-offline transitions
  - `SCDynamicStore` for primary IPv4 / DNS / proxy config changes (catches WiFi-SSID switches and Clash "system proxy" toggles that `NWPathMonitor` misses)
  - Wake-from-sleep
  - Single-attempt fetch, no retry storm; coalesces bursts, cools down after a failure so it doesn't re-try on its own.
- **Periodic refresh** — configurable 1 m / 5 m / 10 m / 30 m / 1 h.
- **Offline-aware** — caches last known data; widget transitions to the unknown pill when offline so it stops asserting a stale country.
- **Launch at login** via `SMAppService`.
- **Native only** — Swift 6, SwiftUI + AppKit, MapKit, `NWPathMonitor`, `SCDynamicStore`, CoreLocation; zero third-party dependencies.

## Install

Download the latest `.dmg` from [Releases](https://github.com/bikekoala/here-macos/releases), open it, drag **Here** into **Applications**, launch.

The app is distributed without an Apple Developer ID signature. On first launch macOS will show a Gatekeeper warning — right-click the app → **Open** → **Open** to authorize it.

## Build from source

Requires **Xcode 16** (Swift 6 + macOS 15 SDK) on **macOS 15 Sequoia** or later.

```sh
git clone https://github.com/bikekoala/here-macos.git
cd here-macos
open Here.xcodeproj
# Cmd-R to run, Cmd-U to test.
```

Command-line build:

```sh
xcodebuild -project Here.xcodeproj -scheme Here -configuration Debug build
xcodebuild -project Here.xcodeproj -scheme Here test
```

Regenerate bundled flag PNGs (needs network):

```sh
./scripts/download_flags.sh           # skip existing
./scripts/download_flags.sh --force   # re-fetch all
```

## Data

Powered by [ip.guide](https://ip.guide/) — free, unauthenticated, returns IP + network + location in a single JSON call. Thank you.

Flag icons from [flagcdn.com](https://flagcdn.com/) (national flags are public domain).

## Architecture

See [CLAUDE.md](CLAUDE.md) for the living architecture overview, conventions, and known gotchas. High-level layout:

- `Here/App/` — entry point + dependency container.
- `Here/StatusBar/` — `NSStatusItem` + `NSPopover` host (AppKit shell, SwiftUI content).
- `Here/Networking/` — actor-based `IPService`, `NWPathMonitor`-based `NetworkMonitor`, `SCDynamicStore`-based `SystemNetworkObserver`, latency + throughput probes.
- `Here/Models/` — Codable data model + display enums + latency bucket classification.
- `Here/Scheduling/` — refresh loop, sleep/wake observer, network-triggered refresh with snapshot-scoped coalesce and post-error cooldown.
- `Here/Persistence/` — disk cache + `@Observable` `SettingsStore` (UserDefaults-backed).
- `Here/Services/` — CoreLocation region mapper, `SMAppService` login helper, clipboard, flag renderer, bundled-flag catalog.
- `Here/UI/` — SwiftUI views for popover and Settings scenes.

## License

[MIT](LICENSE)
