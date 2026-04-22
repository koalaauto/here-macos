import Foundation
import SystemConfiguration

/// Observes macOS system proxy configuration changes via `SCDynamicStore`.
///
/// `NWPathMonitor` does not fire when the system HTTP/HTTPS proxy flips
/// (e.g. Clash "system proxy" mode): the network interface is unchanged
/// and the path is still "satisfied", so no `pathUpdateHandler` arrives.
/// But the egress IP changes drastically — suddenly outbound HTTP goes
/// through the proxy's exit. We need a separate signal.
///
/// `SCDynamicStore` with a watch on `State:/Network/Global/Proxies` fires
/// every time the kernel-visible proxy configuration changes, which is
/// exactly what we want. The callback runs on the main runloop (we add
/// the source to `CFRunLoopGetMain()`), so hopping through a `Task
/// { @MainActor in … }` just guarantees visibility to the observer's
/// state.
@MainActor
final class ProxyConfigObserver {
    enum Event: Sendable {
        case proxyChanged
    }

    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var store: SCDynamicStore?
    private var runLoopSource: CFRunLoopSource?
    private var started = false

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
            let observer = Unmanaged<ProxyConfigObserver>
                .fromOpaque(info)
                .takeUnretainedValue()
            Task { @MainActor in observer.emit(.proxyChanged) }
        }

        guard let store = SCDynamicStoreCreate(
            nil,
            "app.ipguide.proxy-observer" as CFString,
            callback,
            &context
        ) else {
            Log.network.error("Failed to create SCDynamicStore for proxy observation")
            started = false
            return
        }
        self.store = store

        let keys = ["State:/Network/Global/Proxies"] as CFArray
        SCDynamicStoreSetNotificationKeys(store, keys, nil)

        guard let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else {
            Log.network.error("Failed to create runloop source for proxy observer")
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
        Log.network.info("Proxy config changed")
        for c in continuations.values { c.yield(event) }
    }
}
