import SwiftUI

enum AppTheme {
    static let blue = Color(red: 10 / 255, green: 132 / 255, blue: 1)
    static let group = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    static let secondary = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.55)
    static let separator = Color(red: 84 / 255, green: 84 / 255, blue: 88 / 255).opacity(0.55)
    static let palettes: [[Color]] = [
        [Color(red: 0.10, green: 0.15, blue: 0.27), blue, .cyan],
        [Color(red: 0.16, green: 0.10, blue: 0.06), .orange, .yellow],
        [Color(red: 0.06, green: 0.13, blue: 0.09), .green, .cyan],
        [Color(red: 0.13, green: 0.06, blue: 0.16), .purple, .pink],
        [group, Color(white: 0.28), Color(white: 0.56)]
    ]
}

extension View {
    @ViewBuilder func floatingGlass() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        }
    }

    func libraryScreen() -> some View {
        self.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct GroupCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(AppTheme.group, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct InsetSeparator: View {
    var inset: CGFloat = 16
    var body: some View {
        Rectangle().fill(AppTheme.separator).frame(height: 0.33).padding(.leading, inset)
    }
}

struct LibraryStateView: View {
    let symbol: String
    let title: String
    var message: String = ""
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(AppTheme.secondary)
            Text(title).font(.headline)
            if !message.isEmpty { Text(message).font(.subheadline).foregroundStyle(AppTheme.secondary).multilineTextAlignment(.center) }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent).padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, minHeight: 340)
    }
}

struct LibraryRefreshStatus: View {
    @EnvironmentObject private var model: LibraryModel

    var body: some View {
        if model.isRefreshing {
            HStack(spacing: 10) {
                ProgressView()
                Text(model.scanProgress?.text ?? "正在检查更新…")
                Spacer()
            }
            .font(.footnote).foregroundStyle(AppTheme.secondary).padding(16)
        } else if let message = model.refreshError {
            HStack(spacing: 10) {
                Image(systemName: model.skippedAssetCount > 0 ? "exclamationmark.triangle" : "wifi.exclamationmark")
                Text(model.skippedAssetCount > 0 ? message : "刷新失败：\(message)。正在显示已缓存内容。")
                Spacer()
                Button("重试") { model.reload() }
            }
            .font(.footnote).foregroundStyle(AppTheme.secondary).padding(16)
        }
    }
}
