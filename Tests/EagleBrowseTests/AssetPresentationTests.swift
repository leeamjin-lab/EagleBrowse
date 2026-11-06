import XCTest
import UIKit
@testable import EagleBrowse

final class AssetPresentationTests: XCTestCase {
    func testSearchMatchesNameTagOrNoteAndComposesWithTagFilterAndSort() {
        let assets = [
            EagleAssetMetadata(id: "name", name: "Blue 10", tags: ["参考"]),
            EagleAssetMetadata(id: "tag", name: "素材 2", tags: ["BLUE", "参考"]),
            EagleAssetMetadata(id: "note", name: "素材 3", annotation: "a blue light"),
            EagleAssetMetadata(id: "none", name: "其他", tags: ["灰"])
        ]
        let index = EagleLibraryIndex(folders: [], assets: assets, tags: [], tagAssetIDs: [:], folderAssetIDs: [:], thumbnailPaths: [:])
        XCTAssertEqual(index.search(query: "  bLuE\n").map(\.id), ["name", "tag", "note"])
        XCTAssertEqual(index.search(query: " \n").count, 4)
        XCTAssertTrue(index.search(query: "missing").isEmpty)
        let query = LibraryGridQuery(searchQuery: "blue", selectedTags: ["参考"], sort: .name)
        let filtered = query.assets(in: index)
        XCTAssertEqual(Set(filtered.map(\.id)), ["name", "tag"])
        let preview = AssetPreviewSelection(assets: filtered, selectedID: "tag")
        XCTAssertEqual(preview.assets.count, 2)
    }

    func testGridScopesIntersectTagsAndKeepStableSortOrder() {
        let assets = [
            EagleAssetMetadata(id: "z", name: "素材 2", tags: ["蓝", "夜间"], folders: ["cockpit"], modificationTime: Date(timeIntervalSince1970: 2)),
            EagleAssetMetadata(id: "a", name: "素材 10", tags: ["蓝"], folders: ["cockpit"], modificationTime: Date(timeIntervalSince1970: 4)),
            EagleAssetMetadata(id: "b", name: "素材 2", tags: ["蓝", "夜间"], folders: ["cockpit"], modificationTime: Date(timeIntervalSince1970: 2)),
            EagleAssetMetadata(id: "c", name: "其他", tags: ["蓝", "夜间"], folders: ["other"])
        ]
        let index = EagleLibraryIndex(folders: [], assets: assets, tags: [], tagAssetIDs: [:], folderAssetIDs: [:], thumbnailPaths: [:])
        var query = LibraryGridQuery(folderID: "cockpit")
        XCTAssertEqual(query.assets(in: index).map(\.id), ["a", "b", "z"])
        query.sort = .name
        XCTAssertEqual(query.assets(in: index).map(\.id), ["b", "z", "a"])
        query.selectedTags = ["蓝", "夜间"]
        let filtered = query.assets(in: index)
        XCTAssertEqual(filtered.map(\.id), ["b", "z"])
        let preview = AssetPreviewSelection(assets: filtered, selectedID: "z")
        XCTAssertEqual(preview.assets.map(\.id), ["b", "z"])
        XCTAssertEqual(preview.selectedID, "z")
        XCTAssertEqual(LibraryGridQuery(baseTag: "夜间").assets(in: index).map(\.id), ["b", "z", "c"])
        query.selectedTags = ["不存在"]
        XCTAssertTrue(query.assets(in: index).isEmpty)
    }

    @MainActor
    func testGridDownsamplesLargeOriginalWhenThumbnailIsMissing() async throws {
        let original = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        }
        let data = try XCTUnwrap(original.pngData())
        let image = await AssetImageLoader.load(paths: ["missing", "original"], maxPixelSize: 512) { path in
            if path == "missing" { throw URLError(.fileDoesNotExist) }
            return data
        }
        let decoded = try XCTUnwrap(image?.cgImage)
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 512)
        XCTAssertEqual(Double(decoded.width) / Double(decoded.height), 1.5, accuracy: 0.01)
    }

    @MainActor
    func testPreviewLoadsOriginalBeforeThumbnail() async throws {
        let png = try imageData()
        var reads: [String] = []
        let image = await AssetImageLoader.load(paths: ["original", "thumbnail"]) {
            reads.append($0)
            return png
        }
        XCTAssertNotNil(image)
        XCTAssertEqual(reads, ["original"])
    }

    @MainActor
    func testPreviewFallsBackOnMissingAndUndecodableOriginal() async throws {
        let png = try imageData()
        for missing in [true, false] {
            var reads: [String] = []
            let image = await AssetImageLoader.load(paths: ["original", "thumbnail"]) { path in
                reads.append(path)
                if path == "original" {
                    if missing { throw URLError(.fileDoesNotExist) }
                    return Data("not an image".utf8)
                }
                return png
            }
            XCTAssertNotNil(image)
            XCTAssertEqual(reads, ["original", "thumbnail"])
        }
        var failedReads: [String] = []
        let missing = await AssetImageLoader.load(paths: ["same", "same"]) {
            failedReads.append($0)
            throw URLError(.fileDoesNotExist)
        }
        XCTAssertNil(missing)
        XCTAssertEqual(failedReads, ["same"])
    }

    func testVideoAndPDFOnlyRequestThumbnails() {
        for ext in ["PDF", "mov", "mp4", "mkv"] {
            let asset = EagleAssetMetadata(id: "asset", name: "素材", ext: ext)
            XCTAssertEqual(AssetImageLoader.previewPaths(for: asset), [asset.thumbnailRelativePath])
            XCTAssertNotNil(AssetMediaKind(extension: ext).label)
        }
        let image = EagleAssetMetadata(id: "asset", name: "素材", ext: "png")
        XCTAssertEqual(AssetImageLoader.previewPaths(for: image), [image.originalRelativePath, image.thumbnailRelativePath])
    }

    func testRatingPreservesNumericStarsWithoutChangingCoreModel() {
        XCTAssertEqual(AssetRating.decode(Data(#"{"star":4}"#.utf8), fallback: 1), 4)
        XCTAssertEqual(AssetRating.decode(Data(#"{"rating":"5","star":true}"#.utf8), fallback: 1), 5)
        XCTAssertEqual(AssetRating.decode(Data(#"{"star":false}"#.utf8), fallback: nil), 0)
        XCTAssertEqual(AssetRating.decode(Data(#"{"star":true}"#.utf8), fallback: nil), 1)
        XCTAssertEqual(AssetRating.decode(Data(#"{"rating":8}"#.utf8), fallback: nil), 5)
        XCTAssertEqual(AssetRating.decode(nil, fallback: 1), 1)
    }

    @MainActor
    func testDemoHasDecodableImagesAndNestedFolder() async throws {
        let repository = LibraryRepository()
        let connection = RemoteConnection(host: "demo.local", transport: .webdav)
        let index = try await repository.load(connection, demo: true)
        let cockpit = try XCTUnwrap(index.folders.first { $0.id == "cockpit" })
        XCTAssertEqual(cockpit.children.first?.name, "夜间座舱")
        XCTAssertEqual(index.assets(inFolder: "cockpit-night").count, 2)
        XCTAssertEqual(LibraryGridQuery(folderID: "cockpit").assets(in: index).first?.id, "cockpit-01")
        for asset in index.assets {
            for path in [asset.thumbnailRelativePath, asset.originalRelativePath] {
                let data = try await repository.thumbnail(path: path, connection: connection, demo: true)
                XCTAssertNotNil(UIImage(data: data), path)
            }
        }
    }

    @MainActor
    func testDemoLaunchScreensRemainAvailable() {
        for screen in ["connect", "connectError", "browse", "settings", "grid", "preview"] {
            let model = LibraryModel(arguments: ["-demo", "-demoScreen", screen])
            XCTAssertTrue(model.isDemo)
            XCTAssertEqual(model.demoScreen, screen)
            XCTAssertEqual(model.showDemoConnect, ["connect", "connectError"].contains(screen))
            XCTAssertEqual(model.selectedTab, screen == "settings" ? .settings : .browse)
        }
    }

    @MainActor
    private func imageData() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        return try XCTUnwrap(image.pngData())
    }
}
