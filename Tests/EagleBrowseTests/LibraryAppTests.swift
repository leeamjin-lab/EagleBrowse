import XCTest
@testable import EagleBrowse

final class LibraryAppTests: XCTestCase {
    func testDraftNormalizesAddressAndRejectsInvalidInputs() throws {
        var draft = ConnectionDraft()
        draft.host = " http://nas.local:5005 "
        draft.port = "5006"
        draft.path = "eagle/素材.library/"
        let connection = try draft.connection()
        XCTAssertEqual(connection.host, "http://nas.local")
        XCTAssertEqual(connection.port, 5006)
        XCTAssertEqual(connection.path, "/eagle/素材.library")
        draft.port = "65536"
        XCTAssertThrowsError(try draft.connection()) { XCTAssertEqual($0 as? RemoteServiceError, .addressError) }
        draft.port = "443"
        draft.host = "https://user:password@nas.local"
        XCTAssertThrowsError(try draft.connection())
        draft.host = "nas.local"
        draft.path = "/not-a-library"
        XCTAssertThrowsError(try draft.connection()) { XCTAssertEqual($0 as? RemoteServiceError, .libraryNotFound) }
    }

    func testPreferencesRoundTripMultipleLibrariesAndDisconnect() throws {
        let suite = "EagleBrowseTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ConnectionPreferences(defaults: defaults)
        let first = RemoteConnection(host: "https://first.local", transport: .webdav, path: "/One.library")
        let second = RemoteConnection(host: "https://second.local", transport: .webdav, path: "/Two.library")
        preferences.save(connections: [first, second], currentID: second.id)
        XCTAssertEqual(preferences.load().connections, [first, second])
        XCTAssertEqual(preferences.load().currentID, second.id)
        let data = try XCTUnwrap(defaults.data(forKey: "EagleBrowse.connections.v1"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("password"))
        preferences.save(connections: [first, second], currentID: nil)
        XCTAssertNil(preferences.load().currentID)
        XCTAssertEqual(preferences.load().connections.count, 2)
    }

    func testChineseConnectionErrors() {
        XCTAssertEqual(LibraryErrorMessage.text(RemoteServiceError.httpStatus(401)), "账号或密码错误")
        XCTAssertEqual(LibraryErrorMessage.text(RemoteServiceError.libraryNotFound), "路径不存在")
        XCTAssertEqual(LibraryErrorMessage.text(RemoteServiceError.httpStatus(404)), "请求的资源不存在")
        XCTAssertEqual(LibraryErrorMessage.skippedAssets(2), "已跳过 2 个损坏或缺失的素材")
        XCTAssertEqual(LibraryErrorMessage.text(URLError(.timedOut)), "连接超时：请确认手机和 NAS 在同一局域网、端口正确，并已在设置-隐私-本地网络中允许 EagleBrowse")
        XCTAssertEqual(LibraryErrorMessage.text(URLError(.cannotConnectToHost)), "端口未开放或服务未启动")
        XCTAssertEqual(LibraryErrorMessage.text(URLError(.cannotFindHost)), "找不到主机")
        XCTAssertEqual(LibraryErrorMessage.text(URLError(.networkConnectionLost)), "网络断开")
        XCTAssertEqual(LibraryErrorMessage.text(URLError(.secureConnectionFailed)), "安全连接失败：Tailscale/飞牛可试端口 5005，服务器填 http://地址；HTTPS(5006) 需弹出证书信任")
    }


    func testWebDAVSchemeByPort() throws {
        var draft = ConnectionDraft()
        draft.transport = .webdav
        draft.host = "100.84.241.67"
        draft.path = "/Eagle/Lamp Design.library"
        draft.port = "5005"
        let httpConn = try draft.connection()
        XCTAssertTrue(httpConn.host.hasPrefix("http://"), httpConn.host)
        XCTAssertEqual(httpConn.port, 5005)

        draft.port = "5006"
        let httpsConn = try draft.connection()
        XCTAssertTrue(httpsConn.host.hasPrefix("https://"), httpsConn.host)
        XCTAssertEqual(httpsConn.port, 5006)

        draft.host = "http://100.84.241.67"
        draft.port = "5006"
        let explicit = try draft.connection()
        XCTAssertTrue(explicit.host.hasPrefix("http://"), explicit.host)
    }

    func testRepositoryReadsRelativePathsCachesRescansAndClears() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = FixtureRemoteService()
        let repository = LibraryRepository(cacheRoot: root, makeService: { _ in service })
        let connection = RemoteConnection(host: "https://nas.local", transport: .webdav, path: "/设计.library")
        let index = try await repository.load(connection)
        XCTAssertEqual(index.count(inFolder: "folder"), 1)
        XCTAssertEqual(index.count(forTag: "蓝"), 1)
        XCTAssertTrue(index.tags.contains("空标签"))
        let cover = try XCTUnwrap(index.coverAssetID(inFolder: "folder"))
        XCTAssertEqual(index.thumbnailPaths[cover], "images/asset.info/封面_thumbnail.png")
        let firstReads = await service.reads
        _ = try await repository.load(connection)
        let cachedReads = await service.reads
        XCTAssertEqual(cachedReads, firstReads)
        _ = try await repository.load(connection, rescan: true)
        let rescannedReads = await service.reads
        XCTAssertGreaterThan(rescannedReads.count, cachedReads.count)
        _ = try await repository.thumbnail(path: "images/asset.info/封面_thumbnail.png", connection: connection)
        try await repository.clearCache()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        _ = try await repository.load(connection)
        let finalReads = await service.reads
        XCTAssertGreaterThan(finalReads.count, rescannedReads.count)
    }

    func testChangedConnectionCannotReuseOldCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = FixtureRemoteService()
        let repository = LibraryRepository(cacheRoot: root, makeService: { _ in service })
        var connection = RemoteConnection(host: "https://first.local", transport: .webdav, path: "/One.library")
        _ = try await repository.load(connection)
        let before = await service.reads.count
        connection.host = "https://second.local"
        _ = try await repository.load(connection)
        let after = await service.reads.count
        XCTAssertGreaterThan(after, before)
    }

    @MainActor
    func testDemoScreensNeverReadCredentialsOrOverwritePreferences() throws {
        let suite = "EagleBrowseTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ConnectionPreferences(defaults: defaults)
        let real = RemoteConnection(host: "real.local", transport: .webdav, path: "/Real.library")
        preferences.save(connections: [real], currentID: real.id)
        let model = LibraryModel(arguments: ["-demo", "-demoScreen", "settings"], preferences: preferences, passwords: ForbiddenPasswordStore())
        XCTAssertTrue(model.isDemo)
        XCTAssertEqual(model.selectedTab, .settings)
        XCTAssertNotEqual(model.currentID, real.id)
        XCTAssertEqual(try model.password(for: XCTUnwrap(model.currentConnection)), "")
        model.disconnect()
        XCTAssertEqual(preferences.load().currentID, real.id)
        let connect = LibraryModel(arguments: ["-demoScreen", "connect"], preferences: preferences)
        XCTAssertTrue(connect.showDemoConnect)
        let browse = LibraryModel(arguments: ["-demo"], preferences: preferences)
        XCTAssertEqual(browse.selectedTab, .browse)
        XCTAssertFalse(browse.showDemoConnect)
    }

    func testEmbeddedDemoLibraryHasFoldersTagsAndNoDeletedAssets() async throws {
        let repository = LibraryRepository(makeService: { _ in
            XCTFail("Demo must never construct a network service")
            return FixtureRemoteService()
        })
        let connection = RemoteConnection(host: "demo.local", transport: .webdav)
        let index = try await repository.load(connection, demo: true)
        XCTAssertEqual(index.folders.count, 5)
        XCTAssertEqual(index.assets.count, 18)
        XCTAssertEqual(index.count(inFolder: "reference"), 4)
        XCTAssertTrue(index.tags.contains("夜间"))
        XCTAssertFalse(index.assets.contains(where: \.isDeleted))
    }
}

private struct ForbiddenPasswordStore: PasswordStore {
    func readPassword(for connectionID: UUID) throws -> String? { XCTFail("Demo accessed Keychain"); return nil }
    func savePassword(_ password: String, for connectionID: UUID) throws { XCTFail("Demo wrote Keychain") }
    func deletePassword(for connectionID: UUID) throws { XCTFail("Demo deleted Keychain") }
}

private actor FixtureRemoteService: RemoteFileService {
    private(set) var reads: [String] = []
    func listDirectory(at path: String, options: RequestOptions) async throws -> [RemoteEntry] {
        XCTAssertEqual(path, "images")
        return [RemoteEntry(path: "/设计.library/images", name: "images", isDirectory: true),
                RemoteEntry(path: "/设计.library/images/asset.info", name: "a different displayname", isDirectory: true)]
    }
    func readFile(at path: String, options: RequestOptions) async throws -> Data { try await readData(at: path, options: options) }
    func readData(at path: String, options: RequestOptions) async throws -> Data {
        reads.append(path)
        switch path {
        case "mtime.json": throw RemoteServiceError.httpStatus(404)
        case "metadata.json": return Data(#"{"folders":[{"id":"folder","name":"参考"}]}"#.utf8)
        case "images/asset.info/metadata.json": return Data(#"{"id":"asset","name":"封面","ext":"png","folders":["folder"],"tags":["蓝"]}"#.utf8)
        case "tags.json": return Data(#"{"historyTags":["空标签"]}"#.utf8)
        case "images/asset.info/封面_thumbnail.png": return Data([1, 2, 3])
        default: XCTFail("Unexpected path: \(path)"); throw RemoteServiceError.httpStatus(404)
        }
    }
}
