import XCTest
@testable import EagleBrowse

final class EagleLibraryParserTests: XCTestCase {
    private let parser = EagleLibraryParser()

    func testRootMetadataBuildsNestedFolderTreeAndTags() throws {
        let metadata = try fixture(named: "root-metadata")
        let root = try parser.parseRootMetadata(metadata)

        XCTAssertEqual(root.tags, ["摄影", "旅行"])
        XCTAssertEqual(root.folders.count, 1)
        XCTAssertEqual(root.folders[0].name, "参考资料")
        XCTAssertEqual(root.folders[0].children[0].name, "城市")
        XCTAssertEqual(root.folders[0].children[0].assetIDs, ["asset-001"])
    }

    func testAssetMetadataParsesTagsRatingNoteAndPaths() throws {
        let metadata = try fixture(named: "asset-metadata")
        let asset = try parser.parseAssetMetadata(metadata)

        XCTAssertEqual(asset.id, "asset-001")
        XCTAssertEqual(asset.tags, ["夜景", "旅行"])
        XCTAssertEqual(asset.rating, 4)
        XCTAssertEqual(asset.note, "测试备注")
        XCTAssertEqual(asset.thumbnailRelativePath, "images/asset-001.info/thumbnail.png")
        XCTAssertEqual(asset.originalRelativePath, "images/asset-001.info/original.jpg")
    }

    func testBuildIndexAggregatesTagsAndThumbnailPaths() throws {
        let root = try fixture(named: "root-metadata")
        let asset = try fixture(named: "asset-metadata")
        let index = try parser.buildIndex(rootMetadata: root, assetMetadata: [asset])

        XCTAssertEqual(index.folders.count, 1)
        XCTAssertEqual(index.tags, ["夜景", "旅行", "摄影"].sorted())
        XCTAssertEqual(index.thumbnailPaths["asset-001"], "images/asset-001.info/thumbnail.png")
    }

    private func fixture(named name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "json")
        return try Data(contentsOf: try XCTUnwrap(url))
    }
}
