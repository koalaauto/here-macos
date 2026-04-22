import SwiftUI

struct StaleBadge: View {
    let fetchedAt: Date
    let threshold: TimeInterval

    var body: some View {
        if Date().timeIntervalSince(fetchedAt) > threshold {
            Circle()
                .fill(.orange)
                .frame(width: 6, height: 6)
                .help(String(localized: "Data may be out of date"))
        }
    }
}
