import AppKit
import SwiftUI

extension Notification.Name {
    static let ipGuidePopoverCloseRequested = Notification.Name("app.ipguide.popover.closeRequested")
}

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let environment: AppEnvironment
    private let statusItem: NSStatusItem
    private let popoverHost: PopoverHost
    private var stateTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?
    private var globalMouseMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var appearanceObserver: NSObjectProtocol?
    private var closeRequestObserver: NSObjectProtocol?
    private var latestState: IPState = .idle
    private var latestRegion: String?
    private var popoverOpen = false

    init(environment: AppEnvironment) {
        self.environment = environment
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popoverHost = PopoverHost(environment: environment)
        super.init()

        // Persist the status item's position/visibility across launches so the
        // system keeps it in the same slot — helps when the menu bar is tight
        // (notched displays, many status items).
        statusItem.autosaveName = "app.ipguide.statusItem"
        statusItem.isVisible = true
        statusItem.behavior = []

        popoverHost.popover.behavior = .applicationDefined
        popoverHost.popover.delegate = self

        configureButton()
        render()
        observeState()
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

        let quitItem = NSMenuItem(title: String(localized: "Quit IP Guide"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        let bordered: Bool
    }

    private func settingsSnapshot() -> SettingsSnapshot {
        SettingsSnapshot(
            show: environment.settings.showMode,
            style: environment.settings.countryStyle,
            bordered: environment.settings.widgetBordered
        )
    }

    // MARK: - Rendering

    private func render() {
        guard let button = statusItem.button else { return }
        let settings = environment.settings

        guard let model = latestState.model else {
            button.image = NSImage(systemSymbolName: "globe.badge.chevron.backward", accessibilityDescription: "No IP data")
            button.attributedTitle = NSAttributedString(
                string: " " + StatusBarTitleRenderer.placeholder,
                attributes: [.font: NSFont.menuBarFont(ofSize: 0)]
            )
            button.imagePosition = .imageLeft
            return
        }

        let input = StatusBarTitleRenderer.Input(
            countryAlpha2: model.countryAlpha2,
            regionCode: latestRegion,
            showMode: settings.showMode,
            countryStyle: settings.countryStyle,
            bordered: settings.widgetBordered,
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
}
