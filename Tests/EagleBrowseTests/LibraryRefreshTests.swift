import XCTest
@testable import EagleBrowse

final class LibraryRefreshTests: XCTestCase {
    private var root: URL!
    private let connection = RemoteConnection(host: "https://nas.local", transport: .webdav, path: "/Test.library")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func testIncrementalRefreshDetectsChangedAddedRemovedAndMissingMtimeEntries() async throws {
        let service = MutableLibraryService()
        await service.setAssets(["a": "旧名称", "b": "不变", "c": "移除"], times: #"{"a":1,"b":1,"c":1}"#)
        let repository = makeRepository(service)
        _ = try await repository.refresh(connection)
        await service.resetReads()
        await service.setAssets(["a": "新名称", "b": "不变", "d": "新增"], times: #"{"a":2,"b":"1"}"#)
        let index = try await repository.refresh(connection)
        XCTAssertEqual(index.assets.map(\.name), ["新名称", "不变", "新增"])
        let reads = await service.reads
        XCTAssertTrue(reads.contains("images/a.info/metadata.json"))
        XCTAssertTrue(reads.contains("images/d.info/metadata.json"))
        XCTAssertFalse(reads.contains("images/b.info/metadata.json"))
        let cached = await repository.cachedIndex(connection)
        XCTAssertEqual(cached, index)

        await service.resetReads()
        _ = try await repository.refresh(connection, force: true)
        let forced = await service.reads
        XCTAssertTrue(forced.contains("images/b.info/metadata.json"))
    }

    func testAbsentMalformedAndPartialMtimeNeverSkipsMetadata() async throws {
        let service = MutableLibraryService()
        let repository = makeRepository(service)
        for times in [nil, "invalid JSON", #"{"a":true,"b":null}"#, #"{"unrelated":12}"#] as [String?] {
            await service.setAssets(["a": "名称"], times: times)
            _ = try await repository.refresh(connection)
            await service.resetReads()
            _ = try await repository.refresh(connection)
            let reads = await service.reads
            XCTAssertTrue(reads.contains("images/a.info/metadata.json"))
        }
    }

    func testRefreshInvalidatesChangedImageButKeepsUnchangedImage() async throws {
        let service = MutableLibraryService()
        await service.setAssets(["a": "名称", "b": "不变"], times: #"{"a":1,"b":1}"#)
        let repository = makeRepository(service)
        _ = try await repository.refresh(connection)
        let a = "images/a.info/名称_thumbnail.png"
        let b = "images/b.info/不变_thumbnail.png"
        _ = try await repository.thumbnail(path: a, connection: connection)
        _ = try await repository.thumbnail(path: b, connection: connection)
        await service.setAssets(["a": "名称", "b": "不变"], times: #"{"a":2,"b":1}"#)
        await service.setImageBytes(Data([9]))
        _ = try await repository.refresh(connection)
        await service.resetReads()
        let newImage = try await repository.thumbnail(path: a, connection: connection)
        let oldImage = try await repository.thumbnail(path: b, connection: connection)
        XCTAssertEqual(newImage, Data([9]))
        XCTAssertEqual(oldImage, Data([1]))
        let reads = await service.reads
        XCTAssertEqual(reads, [a])
    }

    @MainActor
    func testModelDisplaysCacheBeforeRefreshAndPreservesItWhenOffline() async throws {
        let service = MutableLibraryService()
        await service.setAssets(["a": "离线素材"], times: #"{"a":1}"#)
        let repository = makeRepository(service)
        let cached = try await repository.refresh(connection)
        let suite = "LibraryRefreshTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ConnectionPreferences(defaults: defaults)
        preferences.save(connections: [connection], currentID: connection.id)
        let model = LibraryModel(arguments: [], preferences: preferences, repository: repository)
        await service.holdNextRootRead()
        let refresh = Task { await model.refresh() }
        await service.waitUntilRootIsHeld()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.index, cached)
        XCTAssertTrue(model.isRefreshing)
        await service.releaseRoot(offline: true)
        await refresh.value
        XCTAssertEqual(model.index, cached)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNotNil(model.refreshError)
        XCTAssertFalse(model.isRefreshing)
    }

    func testClearingDuringRefreshPreventsSnapshotFromReappearing() async throws {
        let service = MutableLibraryService()
        await service.setAssets(["a": "名称"], times: #"{"a":1}"#)
        let repository = makeRepository(service)
        await service.holdNextRootRead()
        let refresh = Task { try await repository.refresh(connection) }
        await service.waitUntilRootIsHeld()
        try await repository.clearCache()
        await service.releaseRoot()
        do { _ = try await refresh.value; XCTFail("Cleared refresh should be rejected") }
        catch is CancellationError { }
        let cached = await repository.cachedIndex(connection)
        XCTAssertNil(cached)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testFailedRefreshDoesNotReplaceLastGoodSnapshot() async throws {
        let service = MutableLibraryService()
        await service.setAssets(["a": "名称"], times: #"{"a":1}"#)
        let repository = makeRepository(service)
        let before = try await repository.refresh(connection)
        await service.setAssets(["a": "更新", "b": "新增"], times: #"{"a":2,"b":1}"#)
        await service.fail(path: "images/b.info/metadata.json")
        do { _ = try await repository.refresh(connection); XCTFail("Expected read failure") }
        catch { }
        let after = await repository.cachedIndex(connection)
        XCTAssertEqual(after, before)
    }

    func testRefreshSkipsMissingAssetMetadataAndReportsProgress() async throws {
        let service = MutableLibraryService()
        await service.setAssets(["a": "甲", "b": "乙", "c": "丙"], times: #"{"a":1,"b":1,"c":1}"#)
        await service.setMissingAssets(["b"])
        let repository = makeRepository(service)
        let recorder = ProgressRecorder()

        let index = try await repository.refresh(connection) { progress in
            await recorder.append(progress)
        }

        XCTAssertEqual(index.assets.map(\.id).sorted(), ["a", "c"])
        XCTAssertEqual(index.assets.map(\.name).sorted(), ["丙", "甲"])
        let values = await recorder.values
        XCTAssertEqual(values.map(\.completed), [0, 1, 2, 3])
        let progress = values.last
        XCTAssertEqual(progress?.completed, 3)
        XCTAssertEqual(progress?.total, 3)
        XCTAssertEqual(progress?.skipped, 1)
        XCTAssertEqual(progress?.text, "正在建立索引：已完成 3 / 3，已跳过 1")
        let cached = await repository.cachedIndex(connection)
        XCTAssertEqual(cached, index)

        let readOptions = await service.readOptions
        let listOptions = await service.listOptions
        XCTAssertEqual(readOptions["metadata.json"]?.timeout, 60)
        XCTAssertEqual(readOptions["metadata.json"]?.maxAttempts, 2)
        XCTAssertEqual(listOptions?.timeout, 60)
        XCTAssertEqual(listOptions?.maxAttempts, 2)
        for id in ["a", "b", "c"] {
            XCTAssertEqual(readOptions["images/\(id).info/metadata.json"]?.timeout, 20)
            XCTAssertEqual(readOptions["images/\(id).info/metadata.json"]?.maxAttempts, 2)
        }

        // The skipped entry must be retried even when its mtime has not changed.
        await service.setMissingAssets([])
        await service.resetReads()
        let recovered = try await repository.refresh(connection)
        XCTAssertEqual(recovered.assets.map(\.id).sorted(), ["a", "b", "c"])
        let reads = await service.reads
        XCTAssertTrue(reads.contains("images/b.info/metadata.json"))
        XCTAssertFalse(reads.contains("images/a.info/metadata.json"))
        XCTAssertFalse(reads.contains("images/c.info/metadata.json"))
    }

    func testRootMetadata404IsLibraryNotFound() async throws {
        let service = MutableLibraryService()
        await service.setRootError(.httpStatus(404))
        let repository = makeRepository(service)

        do {
            _ = try await repository.refresh(connection)
            XCTFail("Expected a missing library error")
        } catch let error as RemoteServiceError {
            XCTAssertEqual(error, .libraryNotFound)
        }
        let cached = await repository.cachedIndex(connection)
        let reads = await service.reads
        XCTAssertNil(cached)
        XCTAssertEqual(reads, ["metadata.json"])
    }

    func testRefreshSkipsCorruptAndMismatchedAssetMetadata() async throws {
        let service = MutableLibraryService()
        await service.setAssets(["a": "正常", "b": "坏 JSON", "c": "非对象", "d": "错误 ID", "e": "空名称"], times: nil)
        await service.setAssetMetadata([
            "b": Data("invalid JSON".utf8),
            "c": Data("[]".utf8),
            "d": Data(#"{"id":"other","name":"错配","ext":"png"}"#.utf8),
            "e": Data(#"{"id":"e","name":"","ext":"png"}"#.utf8)
        ])
        let repository = makeRepository(service)
        let recorder = ProgressRecorder()

        let index = try await repository.refresh(connection) { await recorder.append($0) }

        XCTAssertEqual(index.assets.map(\.id), ["a"])
        let progress = await recorder.values.last
        XCTAssertEqual(progress, LibraryScanProgress(completed: 5, total: 5, skipped: 4))
    }

    func testMissingImagesDirectoryProducesEmptyIndex() async throws {
        let service = MutableLibraryService()
        await service.setListingError(RemoteServiceError.httpStatus(404))
        let repository = makeRepository(service)
        let recorder = ProgressRecorder()

        let index = try await repository.refresh(connection) { await recorder.append($0) }

        XCTAssertTrue(index.assets.isEmpty)
        let progress = await recorder.values.last
        XCTAssertEqual(progress, LibraryScanProgress(completed: 0, total: 0, skipped: 0))
    }

    func testListingNetworkErrorsPropagateAndPreserveSnapshot() async throws {
        let service = MutableLibraryService()
        await service.setAssets(["a": "已缓存"], times: nil)
        let repository = makeRepository(service)
        let before = try await repository.refresh(connection)
        for code in [URLError.Code.timedOut, .networkConnectionLost, .cannotConnectToHost] {
            await service.setListingError(URLError(code))
            do {
                _ = try await repository.refresh(connection)
                XCTFail("Expected the original listing error")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, code)
                XCTAssertNotEqual(LibraryErrorMessage.text(error), "路径不存在")
            }
            let cached = await repository.cachedIndex(connection)
            XCTAssertEqual(cached, before)
        }
        await service.setListingError(RemoteServiceError.timeout)
        do {
            _ = try await repository.refresh(connection)
            XCTFail("Expected the original service timeout")
        } catch {
            XCTAssertEqual(error as? RemoteServiceError, .timeout)
        }
    }

    @MainActor
    func testModelBrowsesPartialResultAndClearsWarningAfterRecovery() async throws {
        let service = MutableLibraryService()
        await service.setAssets(["a": "甲", "b": "乙", "c": "丙"], times: #"{"a":1,"b":1,"c":1}"#)
        await service.setMissingAssets(["b"])
        let repository = makeRepository(service)
        let suite = "LibraryPartialRefreshTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ConnectionPreferences(defaults: defaults)
        preferences.save(connections: [connection], currentID: connection.id)
        let model = LibraryModel(arguments: [], preferences: preferences, repository: repository)

        await model.refresh()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.index?.assets.map(\.id).sorted(), ["a", "c"])
        XCTAssertEqual(model.refreshError, "已跳过 1 个损坏或缺失的素材")
        XCTAssertEqual(model.skippedAssetCount, 1)
        XCTAssertFalse(model.isRefreshing)
        XCTAssertNil(model.scanProgress)

        await service.setMissingAssets([])
        await model.refresh()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.index?.assets.count, 3)
        XCTAssertNil(model.refreshError)
        XCTAssertEqual(model.skippedAssetCount, 0)
    }

    func testUpgradeCanReadLegacyOfflineIndexAndImageThenMigratesAfterRefresh() async throws {
        let service = MutableLibraryService()
        let repository = makeRepository(service)
        let identity = "\(connection.host)|\(connection.port ?? 0)|\(connection.path)|\(connection.account)|\(connection.transport.rawValue)"
        let legacy = root.appendingPathComponent(connection.id.uuidString)
            .appendingPathComponent(LibraryFileCache.digest(identity))
        let asset = EagleAssetMetadata(id: "a", name: "名称", ext: "png")
        let oldIndex = EagleLibraryIndex(folders: [], assets: [asset], tags: [], tagAssetIDs: [:], folderAssetIDs: [:], thumbnailPaths: [:])
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("thumbnails"), withIntermediateDirectories: true)
        try JSONEncoder().encode(oldIndex).write(to: legacy.appendingPathComponent("index.json"))
        let legacyImage = legacy.appendingPathComponent("thumbnails/\(LibraryFileCache.digest(asset.thumbnailRelativePath))")
        try Data([8]).write(to: legacyImage)
        let cached = await repository.cachedIndex(connection)
        XCTAssertEqual(cached, oldIndex)
        let image = try await repository.thumbnail(path: asset.thumbnailRelativePath, connection: connection)
        XCTAssertEqual(image, Data([8]))
        let reads = await service.reads
        XCTAssertTrue(reads.isEmpty)

        await service.setAssets(["a": "名称"], times: #"{"a":1}"#)
        _ = try await repository.refresh(connection)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        let updatedImage = try await repository.thumbnail(path: asset.thumbnailRelativePath, connection: connection)
        XCTAssertEqual(updatedImage, Data([1]))
    }

    func testClearingDuringImageDownloadRejectsLateBytes() async throws {
        let service = MutableLibraryService()
        let repository = makeRepository(service)
        await service.holdNextRootRead()
        let download = Task { try await repository.thumbnail(path: "metadata.json", connection: connection) }
        await service.waitUntilRootIsHeld()
        try await repository.clearCache()
        await service.releaseRoot()
        do { _ = try await download.value; XCTFail("Download from before cache clear must be rejected") }
        catch is CancellationError { }
        let bytes = await repository.cacheUsage()
        XCTAssertEqual(bytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor
    func testSwitchingLibrariesCannotDisplayPreviousLibraryCache() async throws {
        let service = MutableLibraryService()
        await service.setAssets(["a": "第一个库"], times: #"{"a":1}"#)
        let repository = makeRepository(service)
        _ = try await repository.refresh(connection)
        let second = RemoteConnection(host: "https://other.local", transport: .webdav, path: "/Other.library")
        let suite = "LibrarySwitchTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ConnectionPreferences(defaults: defaults)
        preferences.save(connections: [connection, second], currentID: connection.id)
        let model = LibraryModel(arguments: [], preferences: preferences, repository: repository)
        await model.refresh()
        XCTAssertEqual(model.index?.assets.first?.name, "第一个库")
        await service.holdNextRootRead()
        model.switchConnection(second)
        await service.waitUntilRootIsHeld()
        XCTAssertNil(model.index)
        XCTAssertEqual(model.phase, .loading)
        await service.releaseRoot(offline: true)
        await model.refresh()
        XCTAssertNil(model.index)
        if case .failed = model.phase { } else { XCTFail("Second library should fail without exposing the first library") }
    }

    func testLatestRefreshWinsWhenRequestsOverlap() async throws {
        let service = MutableLibraryService()
        await service.setAssets(["a": "名称"], times: #"{"a":1}"#)
        let repository = makeRepository(service)
        await service.holdNextRootRead()
        let first = Task { try await repository.refresh(connection) }
        await service.waitUntilRootIsHeld()
        let second = try await repository.refresh(connection)
        await service.releaseRoot()
        do { _ = try await first.value; XCTFail("Obsolete refresh should be rejected") }
        catch is CancellationError { }
        let cached = await repository.cachedIndex(connection)
        XCTAssertEqual(cached, second)
    }

    func testDiskCacheEvictsLeastRecentlyUsedAndEnforcesLimitAcrossLaunches() throws {
        var clock = Date(timeIntervalSince1970: 1)
        let cache = LibraryFileCache(root: root, diskLimit: 6, memoryLimit: 0, now: { clock })
        cache.write(Data([1, 1]), key: "a")
        clock += 1
        cache.write(Data([2, 2]), key: "b")
        clock += 1
        cache.write(Data([3, 3]), key: "c")
        clock += 1
        XCTAssertNotNil(cache.read(key: "a"))
        clock += 1
        cache.write(Data([4, 4]), key: "d")
        XCTAssertNil(cache.read(key: "b"))
        XCTAssertLessThanOrEqual(cache.usage(), 6)
        let reopened = LibraryFileCache(root: root, diskLimit: 4, memoryLimit: 0)
        XCTAssertEqual(reopened.usage(), 4)
        XCTAssertNil(reopened.read(key: "c"))
        XCTAssertEqual(reopened.read(key: "a"), Data([1, 1]))
        XCTAssertEqual(reopened.read(key: "d"), Data([4, 4]))
        reopened.write(Data(repeating: 5, count: 8), key: "too-large")
        XCTAssertNil(reopened.read(key: "too-large"))
        XCTAssertEqual(reopened.usage(), 4)
        try reopened.clear()
        XCTAssertEqual(reopened.usage(), 0)
        XCTAssertNil(reopened.read(key: "a"))
    }

    private func makeRepository(_ service: MutableLibraryService) -> LibraryRepository {
        LibraryRepository(cacheRoot: root, makeService: { _ in service })
    }
}

private actor MutableLibraryService: RemoteFileService {
    private var assets: [String: String] = [:]
    private var times: String?
    private var imageBytes = Data([1])
    private var failingPath: String?
    private var missingAssets: Set<String> = []
    private var rootError: RemoteServiceError?
    private var listingError: Error?
    private var assetMetadata: [String: Data] = [:]
    private var holdRoot = false
    private var rootContinuation: CheckedContinuation<Void, Never>?
    private var rootWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var reads: [String] = []
    private(set) var readOptions: [String: RequestOptions] = [:]
    private(set) var listOptions: RequestOptions?

    func setAssets(_ assets: [String: String], times: String?) { self.assets = assets; self.times = times }
    func setImageBytes(_ data: Data) { imageBytes = data }
    func setMissingAssets(_ ids: Set<String>) { missingAssets = ids }
    func setRootError(_ error: RemoteServiceError?) { rootError = error }
    func setListingError(_ error: Error?) { listingError = error }
    func setAssetMetadata(_ metadata: [String: Data]) { assetMetadata = metadata }
    func resetReads() { reads = [] }
    func fail(path: String) { failingPath = path }
    func holdNextRootRead() { holdRoot = true }
    func waitUntilRootIsHeld() async {
        if rootContinuation != nil { return }
        await withCheckedContinuation { rootWaiters.append($0) }
    }
    func releaseRoot(offline: Bool = false) {
        if offline { failingPath = "metadata.json" }
        rootContinuation?.resume()
        rootContinuation = nil
    }

    func listDirectory(at path: String, options: RequestOptions) async throws -> [RemoteEntry] {
        XCTAssertEqual(path, "images")
        listOptions = options
        if let listingError { throw listingError }
        return assets.keys.sorted().map { RemoteEntry(path: "images/\($0).info", name: $0, isDirectory: true) }
    }
    func readFile(at path: String, options: RequestOptions) async throws -> Data {
        try await readData(at: path, options: options)
    }
    func readData(at path: String, options: RequestOptions) async throws -> Data {
        reads.append(path)
        readOptions[path] = options
        if path == "metadata.json", holdRoot {
            holdRoot = false
            await withCheckedContinuation { continuation in
                rootContinuation = continuation
                rootWaiters.forEach { $0.resume() }
                rootWaiters = []
            }
        }
        if failingPath == path { throw URLError(.notConnectedToInternet) }
        if path == "metadata.json", let rootError { throw rootError }
        switch path {
        case "metadata.json": return Data(#"{"folders":[]}"#.utf8)
        case "mtime.json":
            guard let times else { throw RemoteServiceError.httpStatus(404) }
            return Data(times.utf8)
        case "tags.json": throw RemoteServiceError.httpStatus(404)
        default:
            if path.hasSuffix("_thumbnail.png") { return imageBytes }
            let id = String(path.split(separator: "/")[1].dropLast(5))
            if missingAssets.contains(id) { throw RemoteServiceError.httpStatus(404) }
            if let data = assetMetadata[id] { return data }
            guard let name = assets[id] else { throw RemoteServiceError.httpStatus(404) }
            return try JSONSerialization.data(withJSONObject: ["id": id, "name": name, "ext": "png"])
        }
    }
}

private actor ProgressRecorder {
    private(set) var values: [LibraryScanProgress] = []

    func append(_ progress: LibraryScanProgress) {
        values.append(progress)
    }
}
