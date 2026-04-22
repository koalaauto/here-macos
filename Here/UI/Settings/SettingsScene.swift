import SwiftUI

struct SettingsScene: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label(String(localized: "General"), systemImage: "gearshape") }
            AppearanceSettingsView()
                .tabItem { Label(String(localized: "Appearance"), systemImage: "eye") }
            ModulesSettingsView()
                .tabItem { Label(String(localized: "Modules"), systemImage: "square.stack.3d.up") }
            AboutView()
                .tabItem { Label(String(localized: "About"), systemImage: "info.circle") }
        }
        .scenePadding()
        .frame(width: 460, height: 380)
    }
}
