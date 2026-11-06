import Foundation
import CoreFoundation

struct LibraryScanProgress: Equatable, Sendable {
    let completed: Int
    let total: Int
    let skipped: Int
    var text: String { "正在建立索引：已完成 \(completed) / \(total)，已跳过 \(skipped)" }
}

actor LibraryRepository {
    typealias ServiceFactory = @Sendable (RemoteConnection) -> any RemoteFileService
    typealias ProgressHandler = @Sendable (LibraryScanProgress) async -> Void

    private enum AssetFetchResult: Sendable {
        case loaded(folder: String, data: Data)
        case skipped
    }

    private struct Snapshot: Codable {
        let version: Int
        let index: EagleLibraryIndex
        let metadata: [String: Data]
        let modificationTimes: [String: String]
    }

    private let cacheRoot: URL
    private let indexRoot: URL
    private let files: LibraryFileCache
    private let makeService: ServiceFactory
    private var cacheGeneration = UUID()
    private var mediaGeneration = UUID()
    private var refreshIDs: [String: UUID] = [:]

    init(cacheRoot: URL? = nil, indexRoot: URL? = nil,
         diskLimit: Int = 1_073_741_824, memoryLimit: Int = 32 * 1_024 * 1_024,
         makeService: @escaping ServiceFactory = { WebDAVClient(connection: $0) }) {
        let root = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EagleBrowse", isDirectory: true)
        self.cacheRoot = root
        self.indexRoot = indexRoot ?? cacheRoot?.appendingPathComponent("indexes", isDirectory: true)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("EagleBrowse/indexes", isDirectory: true)
        files = LibraryFileCache(root: root.appendingPathComponent("files"), diskLimit: diskLimit, memoryLimit: memoryLimit)
        self.makeService = makeService
    }

    /// Also reads the v1 index, so upgrading can show cached content while rebuilding the snapshot.
    func cachedIndex(_ connection: RemoteConnection) -> EagleLibraryIndex? {
        if let snapshot = snapshot(connection) { return snapshot.index }
        let legacy = legacyDirectory(connection).appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: legacy) else { return nil }
        return try? JSONDecoder().decode(EagleLibraryIndex.self, from: data)
    }

    func load(_ connection: RemoteConnection, rescan: Bool = false, demo: Bool = false) async throws -> EagleLibraryIndex {
        if demo {
            guard let library = Bundle.main.url(forResource: "demo", withExtension: "library") else {
                throw RemoteServiceError.libraryNotFound
            }
            return try EagleLibraryParser().parseLibrary(at: library)
        }
        if !rescan, let cached = cachedIndex(connection) { return cached }
        return try await refresh(connection, force: rescan)
    }

    /// Always lists folders to detect additions/removals, even if mtime.json is incomplete.
    func refresh(_ connection: RemoteConnection, force: Bool = false,
                 progress: ProgressHandler? = nil) async throws -> EagleLibraryIndex {
        guard connection.transport == .webdav else { throw RemoteServiceError.notImplemented("SMB 暂未实现，请使用 WebDAV") }
        let generation = cacheGeneration
        let identity = connectionKey(connection)
        let requestID = UUID()
        refreshIDs[identity] = requestID
        let previous = snapshot(connection)
        let service = makeService(connection)
        let rootOptions = RequestOptions(timeout: 60, maxAttempts: 2)
        let assetOptions = RequestOptions(timeout: 20, maxAttempts: 2)
        let root: Data
        do {
            root = try await service.readFile(at: "metadata.json", options: rootOptions)
        } catch RemoteServiceError.httpStatus(404) {
            throw RemoteServiceError.libraryNotFound
        }
        try Task.checkCancellation()
        let entries: [RemoteEntry]
        do {
            entries = try await service.listDirectory(at: "images", options: rootOptions)
        } catch RemoteServiceError.httpStatus(404) {
            entries = []
        }
        let folders = Set(entries.filter(\.isDirectory).map { URL(fileURLWithPath: $0.path).lastPathComponent })
            .filter { $0.hasSuffix(".info") && $0 != ".info" }.sorted()
        let times = try await modificationTimes(service)
        var metadata: [String: Data] = [:]
        var changed: [String] = []
        for folder in folders {
            let assetID = String(folder.dropLast(5))
            if !force, let stamp = times[assetID], previous?.modificationTimes[assetID] == stamp,
               let data = previous?.metadata[folder] {
                metadata[folder] = data
            } else {
                changed.append(folder)
            }
        }
        let reusedCount = metadata.count
        await progress?(LibraryScanProgress(completed: reusedCount, total: folders.count, skipped: 0))
        let changedFolders = changed
        let fetched = try await withThrowingTaskGroup(of: AssetFetchResult.self) { group in
            var next = 0
            var result: [String: Data] = [:]
            var skippedCount = 0
            func enqueue(_ position: Int) {
                let folder = changedFolders[position]
                group.addTask {
                    try Task.checkCancellation()
                    let data: Data
                    do {
                        data = try await service.readFile(at: "images/\(folder)/metadata.json", options: assetOptions)
                    } catch RemoteServiceError.httpStatus(404) {
                        return .skipped
                    }
                    try Task.checkCancellation()
                    // A missing or corrupt asset must not invalidate the entire library.
                    // Other read errors (including cancellation and loss of connectivity) propagate.
                    guard let asset = try? EagleLibraryParser().parseAssetMetadata(data),
                          asset.id == String(folder.dropLast(5)), !asset.name.isEmpty else {
                        return .skipped
                    }
                    return .loaded(folder: folder, data: data)
                }
            }
            while next < min(6, changedFolders.count) { enqueue(next); next += 1 }
            while let outcome = try await group.next() {
                try Task.checkCancellation()
                switch outcome {
                case let .loaded(folder, data): result[folder] = data
                case .skipped: skippedCount += 1
                }
                await progress?(LibraryScanProgress(completed: reusedCount + result.count + skippedCount,
                                                    total: folders.count,
                                                    skipped: skippedCount))
                if next < changedFolders.count { enqueue(next); next += 1 }
            }
            return result
        }
        metadata.merge(fetched) { _, new in new }
        var mergedRoot = root
        if let tags = try await optionalFile("tags.json", service: service),
           var object = try JSONSerialization.jsonObject(with: root) as? [String: Any],
           let tagObject = try JSONSerialization.jsonObject(with: tags) as? [String: Any] {
            for key in ["historyTags", "starredTags"] {
                let existing = object[key] as? [String] ?? (key == "historyTags" ? object["tags"] as? [String] : nil) ?? []
                object[key] = existing + (tagObject[key] as? [String] ?? [])
            }
            mergedRoot = try JSONSerialization.data(withJSONObject: object)
        }
        try Task.checkCancellation()
        guard cacheGeneration == generation, refreshIDs[identity] == requestID else { throw CancellationError() }
        let index = try EagleLibraryParser().buildIndex(rootMetadata: mergedRoot, assetMetadata: folders.compactMap { metadata[$0] })
        let result = Snapshot(version: 2, index: index, metadata: metadata, modificationTimes: times)
        // No suspension between the final generation check and atomic commit.
        if let data = try? JSONEncoder().encode(result) {
            let url = snapshotURL(connection)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        invalidateMedia(previous: previous, current: result, refreshedFolders: Set(changedFolders), connection: connection)
        // Only remove the legacy cache after a replacement snapshot exists.
        if FileManager.default.fileExists(atPath: snapshotURL(connection).path) {
            try? FileManager.default.removeItem(at: legacyDirectory(connection))
        }
        return index
    }

    func thumbnail(path: String, connection: RemoteConnection, demo: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        if demo {
            guard let library = Bundle.main.url(forResource: "demo", withExtension: "library") else {
                throw RemoteServiceError.libraryNotFound
            }
            return try Data(contentsOf: library.appendingPathComponent(path))
        }
        let generation = mediaGeneration
        let key = fileKey(path, connection)
        if let cached = files.read(key: key) { return cached }
        let legacyFile = legacyDirectory(connection).appendingPathComponent("thumbnails/\(LibraryFileCache.digest(path))")
        if let cached = try? Data(contentsOf: legacyFile) {
            files.write(cached, key: key)
            return cached
        }
        let data = try await makeService(connection).readData(at: path, options: RequestOptions(timeout: 30, maxAttempts: 1))
        try Task.checkCancellation()
        guard mediaGeneration == generation else { throw CancellationError() }
        files.write(data, key: key)
        return data
    }

    func cacheUsage() -> Int { files.usage() }

    func clearCache() throws {
        cacheGeneration = UUID()
        mediaGeneration = UUID()
        refreshIDs.removeAll()
        try files.clear()
        for url in [cacheRoot, indexRoot] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func invalidateMedia(previous: Snapshot?, current: Snapshot,
                                 refreshedFolders: Set<String>, connection: RemoteConnection) {
        let removed = Set(previous?.metadata.keys.map { $0 } ?? []).subtracting(current.metadata.keys)
        // Without a usable mtime every re-read is conservatively considered a change,
        // including replacement images whose metadata bytes stayed the same.
        let invalidated = refreshedFolders.union(removed)
        guard !invalidated.isEmpty else { return }
        mediaGeneration = UUID()
        for folder in invalidated {
            for data in [previous?.metadata[folder], current.metadata[folder]].compactMap({ $0 }) {
                if let asset = try? EagleLibraryParser().parseAssetMetadata(data) {
                    files.remove(key: fileKey(asset.thumbnailRelativePath, connection))
                    files.remove(key: fileKey(asset.originalRelativePath, connection))
                }
            }
            files.remove(key: fileKey("images/\(folder)/metadata.json", connection))
        }
    }

    private func modificationTimes(_ service: any RemoteFileService) async throws -> [String: String] {
        guard let data = try await optionalFile("mtime.json", service: service),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.reduce(into: [:]) { result, pair in
            if let number = pair.value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
                result[pair.key] = number.stringValue
            } else if let string = pair.value as? String, let number = Double(string), number.isFinite {
                result[pair.key] = NSNumber(value: number).stringValue
            }
        }
    }

    private func optionalFile(_ path: String, service: any RemoteFileService) async throws -> Data? {
        do { return try await service.readFile(at: path, options: RequestOptions(maxAttempts: 1)) }
        catch RemoteServiceError.httpStatus(404) { return nil }
    }

    private func snapshot(_ connection: RemoteConnection) -> Snapshot? {
        guard let data = try? Data(contentsOf: snapshotURL(connection)),
              let result = try? JSONDecoder().decode(Snapshot.self, from: data), result.version == 2 else { return nil }
        return result
    }

    private func snapshotURL(_ connection: RemoteConnection) -> URL {
        indexRoot.appendingPathComponent(connectionKey(connection)).appendingPathComponent("snapshot-v2.json")
    }

    private func fileKey(_ path: String, _ connection: RemoteConnection) -> String { "\(connectionKey(connection))|\(path)" }

    private func connectionKey(_ connection: RemoteConnection) -> String {
        "\(connection.id.uuidString)/\(endpointDigest(connection))"
    }

    private func endpointDigest(_ connection: RemoteConnection) -> String {
        LibraryFileCache.digest("\(connection.host)|\(connection.port ?? 0)|\(connection.path)|\(connection.account)|\(connection.transport.rawValue)")
    }

    private func legacyDirectory(_ connection: RemoteConnection) -> URL {
        cacheRoot.appendingPathComponent(connectionKey(connection))
    }
}
