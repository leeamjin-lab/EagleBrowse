import SwiftUI

@main
struct EagleBrowseApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    var body: some View {
        Text("界面等 Design")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }
}

#Preview {
    RootView()
}
