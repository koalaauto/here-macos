import SwiftUI

struct RefreshButton: View {
    let isLoading: Bool
    let action: () -> Void

    @State private var angle: Double = 0

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .rotationEffect(.degrees(angle))
                .animation(
                    isLoading
                        ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                        : .default,
                    value: angle
                )
        }
        .keyboardShortcut("r", modifiers: [.command])
        .help(String(localized: "Refresh"))
        .onChange(of: isLoading) { _, newValue in
            if newValue { angle = 360 } else { angle = 0 }
        }
    }
}
