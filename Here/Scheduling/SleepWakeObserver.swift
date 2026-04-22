import AppKit
import Foundation

@MainActor
final class SleepWakeObserver {
    enum Event: Sendable {
        case willSleep
        case didWake
    }

    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var observers: [NSObjectProtocol] = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter

        observers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.emit(.willSleep) }
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.emit(.didWake) }
        })
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for obs in observers { center.removeObserver(obs) }
        observers.removeAll()
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

    private func emit(_ event: Event) {
        Log.sleepWake.info("\(String(describing: event), privacy: .public)")
        for c in continuations.values { c.yield(event) }
    }
}
