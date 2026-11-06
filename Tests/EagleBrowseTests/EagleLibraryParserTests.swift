import XCTest
@testable import EagleBrowse

final class EagleLibraryParserTests: XCTestCase {
    let parser = EagleLibraryParser()

    func testNestedFoldersOwnershipAndDeletedFiltering() throws {
        let root = try fixture("root-metadata")
        let primary = try fixture("asset-metadata")
        let extrasObject = try JSONSerialization.jsonObject(with: fixture("assets"))
        let extras = try XCTUnwrap(extrasObject as? [[String: Any]])
        var assetData: [Data] = [primary]
        for item in extras {
            assetData.append(try JSONSerialization.data(withJSONObject: item))
        }

        let index = try parser.buildIndex(rootMetadata: root, assetMetadata: assetData)
        XCTAssertEqual(index.assets.count, 3)
        XCTAssertEqual(index.folders[0].children[0].children[0].name, "夜景")
        XCTAssertEqual(index.folders[0].children[0].children[0].assetIDs, ["asset-001"])
        XCTAssertEqual(index.count(forTag: "旅行"), 2)
        XCTAssertEqual(index.coverAssetID(inFolder: "folder-root"), "asset-002")
    }

    func testPathsSearchAndSort() throws {
        let index = try parser.buildIndex(
            rootMetadata: fixture("root-metadata"),
            assetMetadata: [fixture("asset-metadata")]
        )
        let asset = try XCTUnwrap(index.assets.first)
        XCTAssertEqual(asset.thumbnailRelativePath, "images/asset-001.info/城市夜景_thumbnail.png")
        XCTAssertEqual(asset.originalRelativePath, "images/asset-001.info/城市夜景.jpg")
        XCTAssertEqual(index.search(name: "夜景").count, 1)
        XCTAssertEqual(index.search(tag: "旅行").count, 1)
        XCTAssertEqual(index.search(annotation: "备注").count, 1)
        XCTAssertEqual(index.sorted(by: .name).first?.name, "城市夜景")
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
                ?? Bundle(for: Self.self).url(forResource: name, withExtension: "json")
        )
        return try Data(contentsOf: url)
    }
}
