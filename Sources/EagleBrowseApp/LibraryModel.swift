import SwiftUI

enum LibraryTab: String, CaseIterable {
    case browse, tags, settings
    var title: String { switch self { case .browse: return "浏览"; case .tags: return "标签"; case .settings: return "设置" } }
    var symbol: String { switch self { case .browse: return "folder.fill"; case .tags: return "tag"; case .settings: return "person.crop.circle" } }
}

@MainActor
final class LibraryModel: ObservableObject {
    enum Phase: Equatable { case idle, loading, ready, failed(String) }
    @Published private(set) var connections: [RemoteConnection]
    @Published private(set) var currentID: UUID?
    @Published private(set) var index: EagleLibraryIndex?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isRefreshing = false
    @Published private(set) var scanProgress: LibraryScanProgress?
    @Published private(set) var refreshError: String?
    @Published private(set) var skippedAssetCount = 0
    @Published var selectedTab: LibraryTab = .browse
    @Published var showDemoConnect = false
    @Published var notice: String?
    @Published private(set) var thumbnailRevision = UUID()
    let isDemo: Bool
    let demoScreen: String?
    let repository: LibraryRepository
    private let preferences: ConnectionPreferences
    private let passwords: any PasswordStore
    private var loadTask: Task<Void, Never>?
    private var loadID = UUID()
    private var loadedConnection: RemoteConnection?

    var currentConnection: RemoteConnection? { connections.first { $0.id == currentID } }

    init(arguments: [String] = ProcessInfo.processInfo.arguments,
         preferences: ConnectionPreferences = ConnectionPreferences(),
         passwords: any PasswordStore = KeychainPasswordStore(),
         repository: LibraryRepository = LibraryRepository()) {
        self.preferences = preferences
        self.passwords = passwords
        self.repository = repository
        let screenIndex = arguments.firstIndex(of: "-demoScreen")
        let screen = screenIndex.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        demoScreen = screen
        isDemo = arguments.contains("-demo") || screen != nil
        if isDemo {
            let connection = RemoteConnection(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                              host: "https://demo.local", transport: .webdav,
                                              path: "/设计素材.library", account: "demo")
            connections = [connection]
            currentID = connection.id
            selectedTab = screen == "settings" ? .settings : .browse
            showDemoConnect = ["connect", "connectError"].contains(screen)
        } else {
            let saved = preferences.load()
            connections = saved.connections
            currentID = saved.currentID
        }
    }

    func startIfNeeded() {
        if phase == .idle, currentConnection != nil, !showDemoConnect { reload() }
    }

    func password(for connection: RemoteConnection) throws -> String {
        isDemo ? "" : try passwords.readPassword(for: connection.id) ?? ""
    }

    func connect(_ draft: ConnectionDraft) async throws {
        let connection = try draft.connection()
        guard connection.transport == .webdav else { throw RemoteServiceError.notImplemented("SMB 暂未实现，请使用 WebDAV") }
        if !isDemo {
            let client = WebDAVClient(connection: connection, passwordStore: DraftPasswordStore(password: draft.password))
            _ = try await client.testConnection(options: RequestOptions(timeout: 15, maxAttempts: 1))
            try Task.checkCancellation()
            try passwords.savePassword(draft.password, for: connection.id)
        }
        try Task.checkCancellation()
        if let position = connections.firstIndex(where: { $0.id == connection.id }) { connections[position] = connection }
        else { connections.append(connection) }
        currentID = connection.id
        showDemoConnect = false
        selectedTab = .browse
        persist()
        reload(rescan: true)
    }

    func switchConnection(_ connection: RemoteConnection) {
        guard currentID != connection.id else { return }
        currentID = connection.id
        selectedTab = .browse
        persist()
        reload()
    }

    func disconnect() {
        loadTask?.cancel()
        loadID = UUID()
        currentID = nil
        index = nil
        loadedConnection = nil
        phase = .idle
        isRefreshing = false
        scanProgress = nil
        refreshError = nil
        skippedAssetCount = 0
        showDemoConnect = false
        persist()
    }

    func reload(rescan: Bool = false) {
        guard let connection = currentConnection else { return }
        loadTask?.cancel()
        let requestID = UUID()
        loadID = requestID
        if loadedConnection != connection {
            index = nil
            loadedConnection = connection
        }
        phase = index == nil ? .loading : .ready
        isRefreshing = true
        scanProgress = nil
        refreshError = nil
        skippedAssetCount = 0
        loadTask = Task {
            defer {
                if loadID == requestID {
                    isRefreshing = false
                    scanProgress = nil
                }
            }
            do {
                if !isDemo, index == nil, let cached = await repository.cachedIndex(connection) {
                    guard !Task.isCancelled, loadID == requestID else { return }
                    index = cached
                    phase = .ready
                }
                let result: EagleLibraryIndex
                if isDemo {
                    result = try await repository.load(connection, demo: true)
                } else {
                    result = try await repository.refresh(connection, force: rescan) { [weak self] progress in
                        await self?.updateProgress(progress, requestID: requestID)
                    }
                }
                guard !Task.isCancelled, loadID == requestID else { return }
                index = result
                phase = .ready
                skippedAssetCount = scanProgress?.skipped ?? 0
                if skippedAssetCount > 0 {
                    refreshError = LibraryErrorMessage.skippedAssets(skippedAssetCount)
                }
                thumbnailRevision = UUID()
            } catch {
                guard !Task.isCancelled, loadID == requestID else { return }
                let message = LibraryErrorMessage.text(error)
                if index != nil {
                    phase = .ready
                    refreshError = message
                } else {
                    phase = .failed(message)
                }
            }
        }
    }

    func refresh() async {
        if !isRefreshing { reload() }
        await loadTask?.value
    }

    private func updateProgress(_ progress: LibraryScanProgress, requestID: UUID) {
        guard loadID == requestID else { return }
        scanProgress = progress
    }

    func clearCache() async {
        loadTask?.cancel()
        loadID = UUID()
        isRefreshing = false
        scanProgress = nil
        refreshError = nil
        skippedAssetCount = 0
        do {
            try await repository.clearCache()
            thumbnailRevision = UUID()
            if phase == .loading { phase = index == nil ? .idle : .ready }
            notice = "缓存已清除，下次打开或重新扫描时将重新读取"
        } catch { notice = "清除缓存失败：\(error.localizedDescription)" }
    }

    private func persist() {
        if !isDemo { preferences.save(connections: connections, currentID: currentID) }
    }
}
