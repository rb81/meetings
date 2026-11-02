import AppKit
import SwiftUI

@main
struct MeetingsApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        Window("Meetings", id: "main") {
            RootView()
                .environment(store)
                .tint(Theme.blue)
                .preferredColorScheme(store.settings.appearance.colorScheme)
                .appChrome()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environment(store)
                .tint(Theme.blue)
                .preferredColorScheme(store.settings.appearance.colorScheme)
                .appChrome()
        }

        MenuBarExtra {
            MenuBarView()
                .environment(store)
                .tint(Theme.blue)
                .preferredColorScheme(store.settings.appearance.colorScheme)
                .appChrome()
        } label: {
            MenuBarLabel()
                .environment(store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar icon. It is always on screen, so it also brings the main window forward when the app needs
/// to ask something, such as whether to download the speaker models for a meeting started from the menu bar.
private struct MenuBarLabel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Image(systemName: store.recorder.isRecording ? "record.circle.fill" : "waveform")
            .task(id: store.settings.offlineMode || !store.settings.automaticallyCheckForUpdates) {
                guard !store.settings.offlineMode, store.settings.automaticallyCheckForUpdates else { return }
                await store.updates.monitor()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await store.updates.check() }
                }
            }
            .onChange(of: store.windowRequest) {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
    }
}
