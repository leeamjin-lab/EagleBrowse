import SwiftUI

private struct ConnectionEditor: Identifiable {
    let id = UUID()
    var connection: RemoteConnection?
}

struct SettingsView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var editor: ConnectionEditor?
    @State private var isClearing = false
    @State private var cacheBytes = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let connection = model.currentConnection {
                    section("当前库") {
                        HStack(spacing: 14) {
                            Image(systemName: "externaldrive.fill").font(.system(size: 28)).foregroundStyle(AppTheme.blue)
                                .frame(width: 48, height: 48).background(AppTheme.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(connection.libraryName).font(.headline)
                                Text(model.isDemo ? "Demo · 本地示例库" : "\(connection.transport.rawValue.uppercased()) · 只读")
                                    .font(.footnote).foregroundStyle(AppTheme.secondary)
                            }
                            Spacer()
                        }.padding(16)
                        InsetSeparator()
                        info("服务器", connection.serverDescription)
                        InsetSeparator()
                        info("路径", connection.path)
                        InsetSeparator()
                        info("账号", connection.account.isEmpty ? "匿名" : connection.account)
                        InsetSeparator()
                        action("编辑连接", symbol: "slider.horizontal.3") { editor = ConnectionEditor(connection: connection) }
                        InsetSeparator()
                        action("断开连接", symbol: "eject", color: .red) { model.disconnect() }
                    }
                }
                section("素材库") {
                    ForEach(model.connections) { connection in
                        Button { model.switchConnection(connection) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder").foregroundStyle(AppTheme.blue)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(connection.libraryName).foregroundStyle(.white)
                                    Text(connection.serverDescription).font(.footnote).foregroundStyle(AppTheme.secondary).lineLimit(1)
                                }
                                Spacer()
                                if model.currentID == connection.id { Image(systemName: "checkmark").foregroundStyle(AppTheme.blue) }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        InsetSeparator()
                    }
                    action("添加连接", symbol: "plus") { editor = ConnectionEditor() }
                }
                section("索引与缓存") {
                    info("图片缓存", ByteCountFormatter.string(fromByteCount: Int64(cacheBytes), countStyle: .file))
                    InsetSeparator()
                    action(model.isRefreshing ? (model.scanProgress?.text ?? "正在扫描索引…") : "重新扫描索引", symbol: "arrow.clockwise") { model.reload(rescan: true) }
                        .disabled(model.isRefreshing)
                    InsetSeparator()
                    action(isClearing ? "正在清除…" : "清除缓存", symbol: "internaldrive") {
                        isClearing = true
                        Task { await model.clearCache(); isClearing = false }
                    }.disabled(isClearing)
                }
                Text("图片缓存上限 1 GB，空间不足时自动清理最久未查看的图片。")
                    .font(.footnote).foregroundStyle(AppTheme.secondary)
                if case .failed(let message) = model.phase {
                    Label(message, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.red)
                }
                Text("只读访问素材库，原始文件始终保留在 NAS。")
                    .font(.system(size: 13)).foregroundStyle(AppTheme.secondary).frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 24)
        }
        .libraryScreen().navigationTitle("设置")
        .task(id: model.thumbnailRevision) { cacheBytes = await model.repository.cacheUsage() }
        .sheet(item: $editor) { request in
            NavigationStack { ConnectionView(connection: request.connection, isSheet: true) }
                .preferredColorScheme(.dark).tint(AppTheme.blue)
        }
        .alert("缓存", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("好", role: .cancel) { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13)).foregroundStyle(AppTheme.secondary).padding(.leading, 16)
            GroupCard(content: content)
        }
    }

    private func info(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title).fixedSize()
            Spacer(minLength: 0)
            Text(value).foregroundStyle(AppTheme.secondary).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.system(size: 15)).padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func action(_ title: String, symbol: String, color: Color = AppTheme.blue, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 20)
                Text(title)
                Spacer()
            }
            .foregroundStyle(color).font(.system(size: 17))
            .padding(.horizontal, 16).frame(minHeight: 48).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
