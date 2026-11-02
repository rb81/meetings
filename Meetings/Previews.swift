#if DEBUG
import SwiftUI

#Preview("Upcoming") {
    RootView()
        .environment(AppStore.preview(.upcoming))
        .tint(Theme.blue)
        .preferredColorScheme(.dark)
        .appChrome()
}

#Preview("Recording") {
    RootView()
        .environment(AppStore.preview(.recording))
        .tint(Theme.blue)
        .preferredColorScheme(.dark)
        .appChrome()
}

#Preview("Finished meeting") {
    RootView()
        .environment(AppStore.preview(.finished))
        .tint(Theme.blue)
        .preferredColorScheme(.dark)
        .appChrome()
}

#Preview("Upcoming, light") {
    RootView()
        .environment(AppStore.preview(.upcoming))
        .tint(Theme.blue)
        .preferredColorScheme(.light)
        .appChrome()
}

#Preview("Menu bar") {
    MenuBarView()
        .environment(AppStore.preview(.upcoming))
        .tint(Theme.blue)
        .preferredColorScheme(.dark)
        .appChrome()
}
#endif
