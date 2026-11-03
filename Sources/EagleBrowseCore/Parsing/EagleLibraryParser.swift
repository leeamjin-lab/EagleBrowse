import Foundation

public struct EagleLibraryParser: Sendable {
    public init() {}

    public func parseRootMetadata(_ data: Data) throws -> EagleLibraryMetadata {
        try JSONDecoder().decode(EagleLibraryMetadata.self, from: data)
    }

    public func parseAssetMetadata(_ data: Data) throws -> EagleAssetMetadata {
        try JSONDecoder().decode(EagleAssetMetadata.self, from: data)
    }

    public func buildIndex(
        rootMetadata: Data,
        assetMetadata: [Data]
    ) throws -> EagleLibraryIndex {
        let root = try parseRootMetadata(rootMetadata)
        let assets = try assetMetadata.map(parseAssetMetadata)
        let assetTags = assets.flatMap(\.tags)
        let tags = Array(Set(root.tags + assetTags)).sorted()
        var thumbnails: [String: String] = [:]
        for asset in assets {
            if let path = asset.thumbnailRelativePath {
                thumbnails[asset.id] = path
            }
        }
        return EagleLibraryIndex(folders: root.folders, tags: tags, thumbnailPaths: thumbnails)
    }

    /// Reads `metadata.json` and all `images/<id>.info/metadata.json` files from an Eagle library.
    public func parseLibrary(at libraryURL: URL) throws -> EagleLibraryIndex {
        let rootData = try Data(contentsOf: libraryURL.appendingPathComponent("metadata.json"))
        let imagesURL = libraryURL.appendingPathComponent("images", isDirectory: true)
        var assetData: [Data] = []

        if let enumerator = FileManager.default.enumerator(
            at: imagesURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                guard fileURL.lastPathComponent == "metadata.json", fileURL.pathExtension == "json" else { continue }
                assetData.append(try Data(contentsOf: fileURL))
            }
        }

        return try buildIndex(rootMetadata: rootData, assetMetadata: assetData)
    }
}
