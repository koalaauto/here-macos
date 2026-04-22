import Foundation
import SystemConfiguration

/// Observes macOS configd's dynamic store for network-level state changes
/// that `NWPathMonitor` doesn't reliably surface.
///
/// `NWPathMonitor` prioritises high-level connectivity (online/offline,
/// interface types). It's unreliable for same-interface-type transitions
/// — switching WiFi SSIDs on the same `en0` adapter, DHCP rotations,
/// default-route flips — because the path stays "satisfied" and the
/// interface-type set stays `{.wifi}`. We'd silently miss most WiFi
/// hops if we only relied on that source.
///
/// `SCDynamicStore` is the mature signal for this: the kernel's configd
/// writes these keys every time the effective network plane changes, and
/// VPN clients / monitoring tools on macOS all wire into it.
///
/// Watched keys:
/// - `State:/Network/Global/IPv4` — primary IPv4 service / default
///   gateway. The single most useful trigger: fires on every WiFi
///   hop, cable in/out, VPN up/down.
/// - `State:/Network/Global/DNS` — DNS resolver config.
/// - `State:/Network/Global/Proxies` — HTTP/HTTPS/SOCKS proxy config.
///   Clash's "system proxy" mode toggle only moves this.
///
/// All three collapse into a single `.networkStateChanged` event — the
/// scheduler doesn't care which key moved, it just re-probes the egress.
/// The callback lands on the main runloop (we add the source to
/// `CFRunLoopGetMain()`); we hop into a `Task { @MainActor in … }` to
/// preserve observer-state visibility.
@MainActor
final class SystemNetworkObserver {
    enum Event: Sendable {
        case networkStateChanged
    }

    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var store: SCDynamicStore?
    private var runLoopSource: CFRunLoopSource?
    private var started = false

    private static let watchedKeys: [String] = [
        "State:/Network/Global/IPv4",
        "State:/Network/Global/DNS",
        "State:/Network/Global/Proxies",
    ]

    func start() {
        guard !started else { return }
        started = true

        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let observer = Unmanaged<SystemNetworkObserver>
                .fromOpaque(info)
                .takeUnretainedValue()
            Task { @MainActor in observer.emit(.networkStateChanged) }
        }

        guard let store = SCDynamicStoreCreate(
            nil,
            "app.here-macos.system-network-observer" as CFString,
            callback,
            &context
        ) else {
            Log.network.error("Failed to create SCDynamicStore")
            started = false
            return
        }
        self.store = store

        SCDynamicStoreSetNotificationKeys(store, Self.watchedKeys as CFArray, nil)

        guard let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else {
            Log.network.error("Failed to create runloop source for network observer")
            self.store = nil
            started = false
            return
        }
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        store = nil
        for c in continuations.values { c.finish() }
        continuations.removeAll()
        started = false
    }

    func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let id = UUID()
            self.continuations[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { @MainActor [weak self] in
                    self?.continuations.removeValue(forKey: id)
                }
            }
        }
    }

    fileprivate func emit(_ event: Event) {
        Log.network.info("System network state changed")
        for c in continuations.values { c.yield(event) }
    }

    /// Snapshot of the primary IPv4 plane as `"<interface>:<router>"`.
    /// Used by the scheduler to tell "same network flapped" apart from
    /// "user switched networks". Returns `""` when offline / airplane
    /// mode / no primary service (the key is absent from the store).
    func primaryIPv4Snapshot() -> String {
        guard let store,
              let raw = SCDynamicStoreCopyValue(
                store,
                "State:/Network/Global/IPv4" as CFString
              ),
              let dict = raw as? [String: Any]
        else { return "" }
        let iface = dict["PrimaryInterface"] as? String ?? ""
        let router = dict["Router"] as? String ?? ""
        return "\(iface):\(router)"
    }
}
