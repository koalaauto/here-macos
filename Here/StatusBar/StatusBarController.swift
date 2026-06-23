import AppKit
import SwiftUI

extension Notification.Name {
    static let ipGuidePopoverCloseRequested = Notification.Name("app.here-macos.popover.closeRequested")
}

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let environment: AppEnvironment
    private let statusItem: NSStatusItem
    private let popoverHost: PopoverHost
    private var stateTask: Task<Void, Never>?
    private var latencyTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?
    private var globalMouseMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var popoverResignKeyObserver: NSObjectProtocol?
    private var appearanceObserver: NSObjectProtocol?
    private var closeRequestObserver: NSObjectProtocol?
    private var latestState: IPState = .idle
    private var latestRegion: String?
    private var latestLatencyBucket: LatencyBucket = .empty
    private var popoverOpen = false
    /// Alpha-2 code currently used for the "unknown egress" placeholder.
    /// Picked once when we enter an unknown state, held stable through
    /// all renders while in unknown, cleared on return to `.loaded` so
    /// the next unknown state rolls a fresh random flag.
    private var currentUnknownFlag: String?

    /// Invisible borderless window placed at the menu-bar widget's
    /// screen frame at popover-open time, used as NSPopover's
    /// positioning view's host. NSPopover tracks the positioning
    /// view's frame and slides itself when the menu-bar widget
    /// reflows. Anchoring to a view inside *this* window — which is
    /// independent of the menu bar and never moves — keeps the
    /// popover stationary for the rest of the session. Re-opened
    /// fresh on every `openPopover()`, so a new session still
    /// centres on the widget's then-current position.
    private var anchorWindow: NSWindow?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popoverHost = PopoverHost(environment: environment)
        super.init()

        // Persist the status item's position/visibility across launches so the
        // system keeps it in the same slot — helps when the menu bar is tight
        // (notched displays, many status items).
        statusItem.autosaveName = "app.here-macos.statusItem"
        statusItem.isVisible = true
        statusItem.behavior = []

        popoverHost.popover.behavior = .applicationDefined
        popoverHost.popover.delegate = self

        configureButton()
        render()
        observeState()
        observeLatency()
        observeSettings()
        observeAppearance()
        observeCloseRequests()
    }

    private func observeCloseRequests() {
        closeRequestObserver = NotificationCenter.default.addObserver(
            forName: .ipGuidePopoverCloseRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.closePopover() }
        }
    }

    // MARK: - Button / click handling

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popoverOpen {
            closePopover()
        } else {
            openPopover()
        }
    }

    /// Open the popover, anchored to an **invisible standalone
    /// NSWindow** placed at the menu-bar widget's current screen
    /// frame.
    ///
    /// ### Why an external anchor window
    /// NSPopover with `popover.show(relativeTo: button.bounds, of: button, ...)`
    /// makes the popover track the positioning view's frame. The
    /// menu-bar button's intrinsic width changes whenever the
    /// rendered flag image changes width (different country, render
    /// state) — and AppKit silently slides the popover sideways to
    /// keep it centred on the new midpoint. To users that reads as
    /// "the popover drifted on its own".
    ///
    /// We sidestep this by giving NSPopover a **stable** positioning
    /// view: a 1x button-sized NSView inside a borderless invisible
    /// window placed at the widget's screen frame at open-time. The
    /// invisible window doesn't respond to layout changes, so the
    /// popover stays put for the rest of the session. Re-opening
    /// recaptures relative to the widget's then-current frame, so
    /// each fresh open feels like a normal popover open.
    ///
    /// ### Compatibility caveats — review on every macOS major bump
    /// 1. **NSPopover positioning behaviour**: this code assumes the
    ///    popover anchors to the positioning view's frame in screen
    ///    coordinates and *doesn't* re-query if the view's frame is
    ///    static. If Apple changes NSPopover to e.g. use the
    ///    positioning view's `window.frame` directly, our hidden
    ///    window's level / orderFront state could matter.
    /// 2. **Window level matters for vertical positioning**:
    ///    NSPopover treats positioning views in **`.statusBar`-level**
    ///    windows as "menu-bar attached" — popover renders flush
    ///    under the bar. Anything below `.statusBar` (e.g. `.normal`)
    ///    flips it into "detached popover" mode and adds ~30 pt of
    ///    arrow-padding before the popover body. So the anchor window
    ///    **must** be `.statusBar`. The window is alpha-0 +
    ///    `ignoresMouseEvents=true`, so sharing that level with the
    ///    real menu bar is harmless visually.
    /// 3. **Status item button frame in screen coordinates**: macOS
    ///    has historically managed status items in a system-private
    ///    window. `button.window` is documented to exist for status-
    ///    bar items but isn't a guaranteed contract. The `guard let
    ///    buttonWindow = button.window` below is the bail-out path.
    /// 4. **Popover content vs anchor window**: NSPopover's actual
    ///    floating window is a separate NSWindow it manages. We only
    ///    own the anchor; we don't reach into the popover window
    ///    directly. Any future Apple change there is independent.
    ///
    /// Verification on macOS upgrade: open popover, click refresh
    /// in the popover several times, watch the popover. If it slides
    /// sideways even one pixel, this whole approach has regressed.
    /// Backup plan: re-implement the popover as a self-managed
    /// NSPanel and skip NSPopover entirely.
    private func openPopover() {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }
        let popover = popoverHost.popover
        popoverOpen = true
        NSApp.activate(ignoringOtherApps: true)

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameInScreen = buttonWindow.convertToScreen(buttonFrameInWindow)
        let anchor = NSWindow(
            contentRect: buttonFrameInScreen,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        anchor.isOpaque = false
        anchor.backgroundColor = .clear
        anchor.hasShadow = false
        anchor.ignoresMouseEvents = true
        // `.statusBar` level is required, not just an aesthetic
        // choice. NSPopover internally treats positioning views in
        // status-bar-level windows as "menu-bar-attached" — the
        // popover renders **flush** under the menu bar with the
        // arrow tucked tight against it. Lowering this to `.normal`
        // makes NSPopover treat the anchor as an ordinary view and
        // adds its default detached-popover padding, which surfaces
        // visually as a 30-ish pt gap between the menu bar and the
        // popover top. The window is alpha-0 + click-through so
        // sharing the `.statusBar` level with the real menu bar
        // doesn't cause any visible interference.
        anchor.level = .statusBar
        let anchorContent = NSView(
            frame: NSRect(origin: .zero, size: buttonFrameInScreen.size)
        )
        anchor.contentView = anchorContent
        anchor.orderFrontRegardless()
        anchorWindow = anchor

        popover.show(
            relativeTo: anchorContent.bounds,
            of: anchorContent,
            preferredEdge: .minY
        )
        popover.contentViewController?.view.window?.makeKey()

        installDismissMonitors()
        render()
    }

    private func closePopover() {
        removeDismissMonitors()
        popoverOpen = false
        popoverHost.popover.performClose(nil)
        anchorWindow?.orderOut(nil)
        anchorWindow = nil
        render()
    }

    // MARK: - Dismiss-on-outside-click (works across displays)

    /// Three signals decide when to dismiss:
    ///
    /// 1. **Global mouse monitor** — `addGlobalMonitorForEvents` fires
    ///    on mouse-downs sent to *other* applications. Catches the
    ///    common case of clicking on another app's window.
    /// 2. **App-resign-active** — fires on Cmd-Tab away, lock screen,
    ///    user activating another app. Belt-and-suspenders for cases
    ///    where the global monitor's event-routing path doesn't see
    ///    the click.
    /// 3. **Popover-window-resign-key** — fires whenever the popover
    ///    loses key-window status. This is the **catch-all** for
    ///    edge cases the first two miss: clicks on system menu-bar
    ///    items (WiFi / battery / Control Center), clicks on
    ///    Spotlight, clicks on Notification Center, clicks routed
    ///    through window servers we don't see at the global-monitor
    ///    level. Any time another window steals focus from the
    ///    popover, we close.
    ///
    /// All three call into the same `closePopover()` which is
    /// idempotent — duplicate fires are harmless.
    private func installDismissMonitors() {
        removeDismissMonitors()
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.closePopover() }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.closePopover() }
        }
        if let popoverWindow = popoverHost.popover.contentViewController?.view.window {
            popoverResignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: popoverWindow,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.closePopover() }
            }
        }
    }

    private func removeDismissMonitors() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        if let observer = resignObserver {
            NotificationCenter.default.removeObserver(observer)
            resignObserver = nil
        }
        if let observer = popoverResignKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            popoverResignKeyObserver = nil
        }
    }

    // MARK: - NSPopoverDelegate

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.popoverOpen = false
            self.removeDismissMonitors()
            self.render()
        }
    }

    // MARK: - Context menu (right click)

    private func showContextMenu() {
        let menu = NSMenu()

        let refreshItem = NSMenuItem(title: String(localized: "Refresh now"), action: #selector(contextRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: String(localized: "Settings…"), action: #selector(contextSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: String(localized: "Quit Here"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func contextRefresh() {
        environment.scheduler.triggerNow()
    }

    @objc private func contextSettings() {
        // SwiftUI's `\.openSettings` action, captured at launch by
        // AppDelegate. Reliable from any context — `NSApp.sendAction
        // (showSettingsWindow:)` is not, in LSUIElement apps with no
        // visible Settings window.
        NSApp.activate(ignoringOtherApps: true)
        environment.openSettingsAction?()
    }

    // MARK: - Observation

    private func observeState() {
        stateTask?.cancel()
        stateTask = Task { [weak self, environment] in
            for await state in environment.ipService.stateStream() {
                guard let self else { return }
                await MainActor.run {
                    self.latestState = state
                    self.render()
                }
                if let model = state.model {
                    let region = await environment.regionMapper.regionCode(for: model)
                    await MainActor.run {
                        self.latestRegion = region
                        self.render()
                    }
                }
            }
        }
    }

    private func observeLatency() {
        latencyTask?.cancel()
        latencyTask = Task { [weak self, environment] in
            for await samples in environment.latencyService.stream() {
                guard let self else { return }
                let bucket = LatencyBucket.classify(samples.last, thresholds: .default)
                await MainActor.run {
                    if self.latestLatencyBucket != bucket {
                        self.latestLatencyBucket = bucket
                        self.render()
                    }
                }
            }
        }
    }

    private func observeSettings() {
        settingsTask?.cancel()
        settingsTask = Task { [weak self] in
            guard let self else { return }
            var last = settingsSnapshot()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                let current = settingsSnapshot()
                if current != last {
                    last = current
                    render()
                }
            }
        }
    }

    private func observeAppearance() {
        appearanceObserver = DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.render() }
        }
    }

    private struct SettingsSnapshot: Equatable {
        let show: ShowMode
        let style: CountryStyle
        let latencyEnabled: Bool
        let widgetLatencyAlert: Bool
        let latencyTargetActive: Bool
    }

    private func settingsSnapshot() -> SettingsSnapshot {
        SettingsSnapshot(
            show: environment.settings.showMode,
            style: environment.settings.countryStyle,
            latencyEnabled: environment.settings.latencyEnabled,
            widgetLatencyAlert: environment.settings.widgetLatencyAlert,
            latencyTargetActive: environment.settings.latencyTargetURL != nil
        )
    }

    /// Border tint for the pill. Binary: neutral most of the time, red
    /// only when the most recent latency probe landed in `.poor`
    /// (timeout or > 600 ms — effectively "network isn't working"). The
    /// healthy tiers intentionally don't colour the border; an
    /// always-coloured pill is too noisy in the menu bar.
    ///
    /// When the user picks `.custom` but leaves the URL blank/invalid we
    /// stop probing — the last bucket from the previous target is now
    /// stale, so suppress the alert until probes resume.
    private func currentBorderTint() -> StatusBarTitleRenderer.BorderTint {
        // `.error` with a usable cached model: flip to alert so the
        // dashed border tells the user "this country is from the
        // cache, the current fetch failed". Without this, a stale
        // reading would look identical to a fresh one. Added v0.33.0
        // alongside the change to render cached country on error
        // instead of the OO placeholder.
        if case .error(_, let cached, _) = latestState, cached != nil {
            return .alert
        }
        guard environment.settings.latencyEnabled,
              environment.settings.widgetLatencyAlert,
              environment.settings.latencyTargetURL != nil,
              latestLatencyBucket == .poor
        else { return .neutral }
        return .alert
    }

    // MARK: - Rendering

    private func render() {
        guard let button = statusItem.button else { return }
        let settings = environment.settings

        // Decide which model (if any) drives the rendered flag.
        //
        // - `.loaded`: real flag, real region.
        // - `.loading(cached: m)` with a cache: keep showing `m`'s
        //   flag. A loading state is "we're re-checking" — most
        //   re-checks succeed and the answer is unchanged, so
        //   strobing the widget to a random placeholder every
        //   refresh would produce constant visual noise. The
        //   manual-refresh path in `IPService` is the only one
        //   that emits `.loading` now (auto refresh is silent),
        //   so this branch only fires while the user is actively
        //   watching the popover anyway.
        // - `.error(cached: m)` **with** a cache: keep showing `m`'s
        //   flag — paired with a dashed border (see
        //   `currentBorderTint()`) so the user can distinguish "fresh
        //   reading: HK" from "last known: HK, we couldn't re-verify
        //   this poll". Changed v0.33.0 from "always random on error";
        //   the failover chain (v0.33.0) means a single failed fetch
        //   is now usually the user's VPN flicking off the primary
        //   AND the fallback for a few seconds, not a real egress
        //   change — silently rolling to a random country every 5 s
        //   of flake was misleading. The dashed border signal alone
        //   carries the "stale" meaning.
        // - `.idle`, `.loading(cached: nil)`, `.error(cached: nil)`:
        //   no data we can stand behind → random.
        let renderModel: IPDataModel?
        switch latestState {
        case .loaded(let m, _):
            renderModel = m
        case .loading(let cached):
            renderModel = cached
        case .error(_, let cached, _):
            renderModel = cached
        case .idle:
            renderModel = nil
        }

        guard let model = renderModel else {
            renderUnknown(on: button)
            return
        }

        // Back to a verified egress — drop the stashed random flag so
        // the next unknown cycle rolls a new one.
        currentUnknownFlag = nil

        let input = StatusBarTitleRenderer.Input(
            countryAlpha2: model.countryAlpha2,
            regionCode: latestRegion,
            showMode: settings.showMode,
            countryStyle: settings.countryStyle,
            borderTint: currentBorderTint(),
            flagMono: !popoverOpen
        )

        if let image = StatusBarTitleRenderer.renderImage(input) {
            button.image = image
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
        } else {
            // Fallback: text-only rendering (shouldn't happen in practice)
            button.image = nil
            button.attributedTitle = NSAttributedString(
                string: StatusBarTitleRenderer.plain(input),
                attributes: [.font: NSFont.menuBarFont(ofSize: 0)]
            )
        }
    }

    /// Render the "we don't know the current egress" state.
    ///
    /// Keeps the pill shape (flag + region code + user's border) so the
    /// widget doesn't visually jump to a different kind of element every
    /// time the network flaps. Flag is a random bundled one, picked
    /// once per unknown cycle; text is the sentinel "OO" (never a real
    /// ISO region, so the user can distinguish placeholder from real
    /// data at a glance). Random flag keeps the pill feeling alive and
    /// makes state transitions visible — a collision with the previous
    /// country would otherwise look like nothing changed.
    private func renderUnknown(on button: NSStatusBarButton) {
        let code: String
        if let stored = currentUnknownFlag {
            code = stored
        } else {
            let excluded = latestState.model?.countryAlpha2
            code = BundledFlags.randomCode(excluding: excluded)
            currentUnknownFlag = code
        }

        let input = StatusBarTitleRenderer.Input(
            countryAlpha2: code,
            regionCode: "OO",
            showMode: .both,
            countryStyle: .flag,
            borderTint: currentBorderTint(),
            flagMono: !popoverOpen
        )
        if let image = StatusBarTitleRenderer.renderImage(input) {
            button.image = image
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
        } else {
            button.image = nil
            button.attributedTitle = NSAttributedString(
                string: StatusBarTitleRenderer.plain(input),
                attributes: [.font: NSFont.menuBarFont(ofSize: 0)]
            )
        }
    }
}
