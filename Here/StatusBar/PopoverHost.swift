import AppKit
import SwiftUI

@MainActor
final class PopoverHost {
    let popover: NSPopover

    init(environment: AppEnvironment) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 360, height: 440)
        let hosting = NSHostingController(
            rootView: PopoverRootView()
                .environment(environment)
                .environment(environment.settings)
        )
        hosting.sizingOptions = [.intrinsicContentSize, .preferredContentSize]
        popover.contentViewController = hosting
        self.popover = popover
    }
}
