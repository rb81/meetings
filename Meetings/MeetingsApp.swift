import AppKit
import SwiftUI

@main
struct MeetingsApp: App {
    @State private var store = AppStore()
    @State private var updateMonitor: Task<Void, Never>?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        @Bindable var settings = store.settings

        Window("Meetings", id: "main") {
            RootView()
                .environment(store)
                .tint(Theme.blue)
                .preferredColorScheme(store.settings.appearance.colorScheme)
                .appChrome()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .onChange(of: store.windowRequest) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .onChange(of: settings.offlineMode || !settings.automaticallyCheckForUpdates, initial: true) {
            updateMonitor?.cancel()
            updateMonitor = nil
            guard !settings.offlineMode, settings.automaticallyCheckForUpdates else { return }
            updateMonitor = Task { await store.updates.monitor() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.updates.check() }
            }
        }

        Settings {
            SettingsView()
                .environment(store)
                .tint(Theme.blue)
                .preferredColorScheme(store.settings.appearance.colorScheme)
                .appChrome()
        }

        MenuBarExtra(isInserted: $settings.showMenuBarIcon) {
            MenuBarView()
                .environment(store)
                .tint(Theme.blue)
                .preferredColorScheme(store.settings.appearance.colorScheme)
                .focusEffectDisabled()
        } label: {
            Image(systemName: store.recorder.isRecording ? "record.circle.fill" : "waveform")
                .accessibilityLabel("Meetings")
        }
        .menuBarExtraStyle(.window)
    }
}
