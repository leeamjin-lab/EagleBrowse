import Foundation

public struct EagleFolderNode: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let children: [EagleFolderNode]
    public let assetIDs: [String]

    public init(id: String, name: String, children: [EagleFolderNode] = [], assetIDs: [String] = []) {
        self.id = id
        self.name = name
        self.children = children
        self.assetIDs = assetIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, children, assetIDs, items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "未命名文件夹"
        children = try container.decodeIfPresent([EagleFolderNode].self, forKey: .children) ?? []
        assetIDs = try container.decodeIfPresent([String].self, forKey: .assetIDs)
            ?? container.decodeIfPresent([String].self, forKey: .items)
            ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(children, forKey: .children)
        try container.encode(assetIDs, forKey: .assetIDs)
    }
}

public struct EagleLibraryMetadata: Codable, Equatable, Sendable {
    public let folders: [EagleFolderNode]
    public let tags: [String]

    public init(folders: [EagleFolderNode], tags: [String] = []) {
        self.folders = folders
        self.tags = tags
    }

    private enum CodingKeys: String, CodingKey { case folders, tags }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folders = try container.decodeIfPresent([EagleFolderNode].self, forKey: .folders) ?? []
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(folders, forKey: .folders)
        try container.encode(tags, forKey: .tags)
    }
}

public struct EagleAssetMetadata: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let tags: [String]
    public let rating: Int?
    public let note: String?
    public let thumbnailRelativePath: String?
    public let originalRelativePath: String?

    public init(
        id: String,
        name: String,
        tags: [String] = [],
        rating: Int? = nil,
        note: String? = nil,
        thumbnailRelativePath: String? = nil,
        originalRelativePath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.tags = tags
        self.rating = rating
        self.note = note
        self.thumbnailRelativePath = thumbnailRelativePath
        self.originalRelativePath = originalRelativePath
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, tags, rating, star, note, description
        case thumbnailRelativePath, thumbnailPath, thumbnail
        case originalRelativePath, originalPath, path, url
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "未命名素材"
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        rating = Self.decodeInteger(container, keys: [.rating, .star])
        note = try container.decodeIfPresent(String.self, forKey: .note)
            ?? container.decodeIfPresent(String.self, forKey: .description)
        thumbnailRelativePath = try container.decodeIfPresent(String.self, forKey: .thumbnailRelativePath)
            ?? container.decodeIfPresent(String.self, forKey: .thumbnailPath)
            ?? container.decodeIfPresent(String.self, forKey: .thumbnail)
        originalRelativePath = try container.decodeIfPresent(String.self, forKey: .originalRelativePath)
            ?? container.decodeIfPresent(String.self, forKey: .originalPath)
            ?? container.decodeIfPresent(String.self, forKey: .path)
            ?? container.decodeIfPresent(String.self, forKey: .url)
    }

    private static func decodeInteger(
        _ container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> Int? {
        for key in keys {
            if let value = try? container.decode(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decode(Double.self, forKey: key) {
                return Int(value)
            }
        }
        return nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(rating, forKey: .rating)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encodeIfPresent(thumbnailRelativePath, forKey: .thumbnailRelativePath)
        try container.encodeIfPresent(originalRelativePath, forKey: .originalRelativePath)
    }
}

public struct EagleLibraryIndex: Codable, Equatable, Sendable {
    public let folders: [EagleFolderNode]
    public let tags: [String]
    public let thumbnailPaths: [String: String]

    public init(folders: [EagleFolderNode], tags: [String], thumbnailPaths: [String: String]) {
        self.folders = folders
        self.tags = tags
        self.thumbnailPaths = thumbnailPaths
    }
}
