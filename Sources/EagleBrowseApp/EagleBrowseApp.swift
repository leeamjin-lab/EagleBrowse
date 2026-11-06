import SwiftUI

@main
struct EagleBrowseApp: App {
    @StateObject private var model = LibraryModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(AppTheme.blue)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: LibraryModel

    var body: some View {
        Group {
            if model.currentConnection == nil || model.showDemoConnect {
                NavigationStack { ConnectionView(connection: nil) }
            } else {
                LibraryTabsView().id(model.currentConnection?.id)
            }
        }
        .task { model.startIfNeeded() }
    }
}
