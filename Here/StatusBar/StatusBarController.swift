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

    private func openPopover() {
        guard let button = statusItem.button else { return }
        let popover = popoverHost.popover
        popoverOpen = true
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        installDismissMonitors()
        render()
    }

    private func closePopover() {
        removeDismissMonitors()
        popoverOpen = false
        popoverHost.popover.performClose(nil)
        render()
    }

    // MARK: - Dismiss-on-outside-click (works across displays)

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
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
    }

    private func settingsSnapshot() -> SettingsSnapshot {
        SettingsSnapshot(
            show: environment.settings.showMode,
            style: environment.settings.countryStyle,
            latencyEnabled: environment.settings.latencyEnabled,
            widgetLatencyAlert: environment.settings.widgetLatencyAlert
        )
    }

    /// Border tint for the pill. Binary: neutral most of the time, red
    /// only when the most recent latency probe landed in `.poor`
    /// (timeout or > 2 s — effectively "network isn't working"). The
    /// healthy tiers intentionally don't colour the border; an
    /// always-coloured pill is too noisy in the menu bar.
    private func currentBorderTint() -> StatusBarTitleRenderer.BorderTint {
        guard environment.settings.latencyEnabled,
              environment.settings.widgetLatencyAlert,
              latestLatencyBucket == .poor
        else { return .neutral }
        return .alert
    }

    // MARK: - Rendering

    private func render() {
        guard let button = statusItem.button else { return }
        let settings = environment.settings

        // Anything other than a fresh `.loaded` reading goes to the
        // placeholder pill. During `.loading` we're actively re-checking
        // the egress and the previous flag may already be stale; during
        // `.error / .idle` we just don't know. In both cases, silently
        // continuing to assert the old flag would mislead the user.
        // Popover still shows cached data + context.
        guard case .loaded(let model, _) = latestState else {
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
