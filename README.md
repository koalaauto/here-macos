# IP Guide

A tiny native macOS menu bar app that shows your current public-IP geolocation at a glance, with a rich popover for details.

<p align="center">
  <em>🇺🇸 CA&nbsp;&nbsp;·&nbsp;&nbsp;38.175.104.131&nbsp;&nbsp;·&nbsp;&nbsp;San Jose, United States</em>
</p>

Useful when hopping between VPNs, proxies, or traveling — you can tell at a glance which country/region your traffic currently egresses from without opening a browser.

## Features

- **Menu bar widget** with country + region/state code (configurable: `US CA`, `🇺🇸 CA`, flag only, region only, or text only).
- **Rounded pill border** option that keeps the widget visually contained in the menu bar.
- **Real rectangular flag icons** (not wavy emoji) for 252 countries and territories — rendered monochrome against the menu bar tint, full-color inside the popover.
- **Click-through popover** with four modules (reorderable in Settings):
  - **Location** — large copyable IP, mini MapKit preview (tap to open in Maps), timezone + live local clock, and an expandable Network drawer (CIDR, ASN + organization, RIR) with an inline ASN summary when collapsed.
  - **History** — a right-anchored flag-chain of recent egress-IP changes with "how long ago" labels under each chip; tap a chip for IP + ASN + city detail. Newest chip is pinned to the right to match the Latency bar's time axis.
  - **Latency** — horizontal bar of 30 probes with color-coded tiers (green <500 ms, yellow 500–1000 ms, orange 1000–2000 ms, red ≥2000 ms / timeout / network error). Header shows last / avg / max. Hover a cell for an instant tooltip. Configurable target, interval, and slot count.
  - **Throughput** — on-demand download + upload speed test against Cloudflare's speed endpoint. Live Mbps number ticks up during the transfer; last result persists so reopening the popover shows your prior reading.
- Flag on the hero row **follows the IP's geo-country, not the ASN's registered country** — so a VPN whose ASN is registered in HK but runs a node in TW shows the TW flag.
- Manual refresh and "last updated" relative timer that updates every second.
- Click the flag to open [ip.guide](https://ip.guide/) in your browser.
- **Automatic refresh** — configurable every 1m / 5m / 10m / 30m / 1h.
- **Smart re-fetch triggers** on network change (Wi-Fi switch, VPN toggle) and wake-from-sleep.
- **Offline-aware** — caches last known data and shows a staleness badge when readings get old.
- **Launch at login** via `SMAppService`.
- **Native only** — Swift 6, SwiftUI + AppKit, MapKit, Core Location; zero third-party dependencies.

## Install

Download the latest `.dmg` from [Releases](https://github.com/bikekoala/ip-info/releases), open it, drag **IP Guide** into **Applications**, launch.

Since the app is currently distributed without an Apple Developer ID signature, the first launch will show a Gatekeeper warning — right-click the app → **Open** → **Open** to authorize it.

## Build from source

Requires **Xcode 16** (for Swift 6 + macOS 15 SDK) on **macOS 15 Sequoia** or later.

```sh
git clone https://github.com/bikekoala/ip-info.git
cd ip-info
open IPGuide.xcodeproj
# Press Cmd-R to run, Cmd-U to test.
```

Command-line build:

```sh
xcodebuild -project IPGuide.xcodeproj -scheme IPGuide -configuration Debug build
xcodebuild -project IPGuide.xcodeproj -scheme IPGuide test
```

To regenerate the bundled flag PNGs (net access required):

```sh
./scripts/download_flags.sh           # skip existing
./scripts/download_flags.sh --force   # re-fetch all
```

## Data

Powered by [ip.guide](https://ip.guide/) — free, unauthenticated, returns IP + network + location in one JSON call. Thank you.

Flag icons from [flagcdn.com](https://flagcdn.com/) (national flags are in the public domain).

## Architecture

See [CLAUDE.md](CLAUDE.md) for the living architecture overview, conventions, and known gotchas. High-level layout:

- `IPGuide/App/` — entry point + dependency container.
- `IPGuide/StatusBar/` — `NSStatusItem` + `NSPopover` host (AppKit shell, SwiftUI content).
- `IPGuide/Networking/` — actor-based `IPService` with retry, coalescing, AsyncStream of state.
- `IPGuide/Models/` — Codable data model + display enums.
- `IPGuide/Scheduling/` — refresh loop, sleep/wake observer, network-change triggers.
- `IPGuide/Persistence/` — disk cache + `@Observable` `SettingsStore` (`@AppStorage`-backed).
- `IPGuide/Services/` — CoreLocation region mapper, `SMAppService` login helper, clipboard, flag renderer.
- `IPGuide/UI/` — SwiftUI views for popover and settings scenes.

## License

[MIT](LICENSE)
