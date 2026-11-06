import Foundation

public struct EagleFolderNode: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let children: [EagleFolderNode]
    public let assetIDs: [String]
    public let iconColor: String?

    public init(id: String, name: String, children: [EagleFolderNode] = [], assetIDs: [String] = [], iconColor: String? = nil) {
        self.id = id; self.name = name; self.children = children; self.assetIDs = assetIDs; self.iconColor = iconColor
    }
}

public struct EagleLibraryMetadata: Codable, Equatable, Sendable {
    public let folders: [EagleFolderNode]
    public let historyTags: [String]
    public let starredTags: [String]
    public var tags: [String] { Array(Set(historyTags + starredTags)).sorted() }

    public init(folders: [EagleFolderNode] = [], historyTags: [String] = [], starredTags: [String] = []) {
        self.folders = folders; self.historyTags = historyTags; self.starredTags = starredTags
    }

    private enum CodingKeys: String, CodingKey { case folders, historyTags, starredTags, tags }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folders = (try? c.decode([EagleFolderNode].self, forKey: .folders)) ?? []
        historyTags = (try? c.decode([String].self, forKey: .historyTags)) ?? ((try? c.decode([String].self, forKey: .tags)) ?? [])
        starredTags = (try? c.decode([String].self, forKey: .starredTags)) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(folders, forKey: .folders); try c.encode(historyTags, forKey: .historyTags); try c.encode(starredTags, forKey: .starredTags)
    }
}

public struct EagleAssetMetadata: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let ext: String
    public let size: Int64?
    public let width: Int?
    public let height: Int?
    public let tags: [String]
    public let folders: [String]
    public let star: Bool?
    public let annotation: String?
    public let url: String?
    public let isDeleted: Bool
    public let modificationTime: Date?

    public var rating: Int? { star == true ? 1 : (star == false ? 0 : nil) }
    public var note: String? { annotation }
    public var thumbnailRelativePath: String { "images/\(id).info/\(name)_thumbnail.png" }
    public var thumbnailPath: String { thumbnailRelativePath }
    public var originalRelativePath: String { "images/\(id).info/\(name).\(ext)" }

    public init(id: String, name: String, ext: String = "", size: Int64? = nil, width: Int? = nil, height: Int? = nil,
                tags: [String] = [], folders: [String] = [], star: Bool? = nil, annotation: String? = nil,
                url: String? = nil, isDeleted: Bool = false, modificationTime: Date? = nil) {
        self.id=id; self.name=name; self.ext=ext; self.size=size; self.width=width; self.height=height; self.tags=tags; self.folders=folders; self.star=star; self.annotation=annotation; self.url=url; self.isDeleted=isDeleted; self.modificationTime=modificationTime
    }

    private enum CodingKeys: String, CodingKey { case id,name,ext,size,width,height,tags,folders,star,annotation,url,isDeleted,modificationTime,description,note,rating }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        ext = (try? c.decode(String.self, forKey: .ext)) ?? ""
        size = Self.int64(c, .size); width = Self.int(c, .width); height = Self.int(c, .height)
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        folders = (try? c.decode([String].self, forKey: .folders)) ?? []
        if let b = try? c.decode(Bool.self, forKey: .star) { star = b } else if let n = Self.int(c, .star) { star = n != 0 } else { star = nil }
        annotation = (try? c.decode(String.self, forKey: .annotation)) ?? (try? c.decode(String.self, forKey: .description)) ?? (try? c.decode(String.self, forKey: .note))
        url = try? c.decode(String.self, forKey: .url)
        isDeleted = (try? c.decode(Bool.self, forKey: .isDeleted)) ?? false
        if let s = try? c.decode(String.self, forKey: .modificationTime) { modificationTime = Self.date(s) } else if let d = try? c.decode(Date.self, forKey: .modificationTime) { modificationTime = d } else { modificationTime = nil }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(ext, forKey: .ext)
        try c.encodeIfPresent(size, forKey: .size); try c.encodeIfPresent(width, forKey: .width); try c.encodeIfPresent(height, forKey: .height)
        try c.encode(tags, forKey: .tags); try c.encode(folders, forKey: .folders); try c.encodeIfPresent(star, forKey: .star)
        try c.encodeIfPresent(annotation, forKey: .annotation); try c.encodeIfPresent(url, forKey: .url); try c.encode(isDeleted, forKey: .isDeleted); try c.encodeIfPresent(modificationTime, forKey: .modificationTime)
    }
    private static func int64(_ c: KeyedDecodingContainer<CodingKeys>, _ k: CodingKeys) -> Int64? { if let x=try? c.decode(Int64.self,forKey:k){return x}; if let x=try? c.decode(Double.self,forKey:k){return Int64(x)}; if let x=try? c.decode(String.self,forKey:k){return Int64(x)}; return nil }
    private static func int(_ c: KeyedDecodingContainer<CodingKeys>, _ k: CodingKeys) -> Int? { if let x=try? c.decode(Int.self,forKey:k){return x}; if let x=try? c.decode(Double.self,forKey:k){return Int(x)}; if let x=try? c.decode(String.self,forKey:k){return Int(x)}; return nil }
    private static func date(_ s: String) -> Date? { ISO8601DateFormatter().date(from: s) ?? { let f=DateFormatter(); f.locale=Locale(identifier:"en_US_POSIX"); f.dateFormat="yyyy-MM-dd HH:mm:ss"; return f.date(from:s) }() }
}

public struct EagleLibraryIndex: Codable, Equatable, Sendable {
    public let folders: [EagleFolderNode]
    public let assets: [EagleAssetMetadata]
    public let tags: [String]
    public let tagAssetIDs: [String: [String]]
    public let folderAssetIDs: [String: [String]]
    public let thumbnailPaths: [String: String]

    public init(folders: [EagleFolderNode], assets: [EagleAssetMetadata], tags: [String], tagAssetIDs: [String:[String]], folderAssetIDs: [String:[String]], thumbnailPaths: [String:String]) {
        self.folders=folders; self.assets=assets; self.tags=tags; self.tagAssetIDs=tagAssetIDs; self.folderAssetIDs=folderAssetIDs; self.thumbnailPaths=thumbnailPaths
    }
    public func assets(inFolder id: String) -> [EagleAssetMetadata] { assets.filter { $0.folders.contains(id) } }
    public func assetIDs(forTag tag: String) -> [String] { tagAssetIDs[tag] ?? [] }
    public func count(forTag tag: String) -> Int { tagAssetIDs[tag]?.count ?? 0 }
    public func count(inFolder id: String) -> Int { folderAssetIDs[id]?.count ?? 0 }
    public func coverAssetID(inFolder id: String) -> String? { folderAssetIDs[id]?.first }
    public func search(name: String? = nil, tag: String? = nil, annotation: String? = nil) -> [EagleAssetMetadata] {
        let n=name?.lowercased(), a=annotation?.lowercased()
        return assets.filter { asset in
            (n == nil || asset.name.lowercased().contains(n!)) && (tag == nil || asset.tags.contains(tag!)) && (a == nil || (asset.annotation?.lowercased().contains(a!) ?? false))
        }
    }
    public func sorted(by key: SortKey, ascending: Bool = false) -> [EagleAssetMetadata] {
        assets.sorted { lhs, rhs in
            let result: Bool
            switch key { case .name: result = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .modificationTime: result = (lhs.modificationTime ?? .distantPast) < (rhs.modificationTime ?? .distantPast) }
            if lhs.name == rhs.name && key == .name { return false }
            if lhs.modificationTime == rhs.modificationTime && key == .modificationTime { return false }
            return ascending ? result : !result
        }
    }
    public func search(query: String) -> [EagleAssetMetadata] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return assets }
        return assets.filter { asset in
            asset.name.lowercased().contains(needle)
                || asset.tags.contains { $0.lowercased().contains(needle) }
                || (asset.annotation?.lowercased().contains(needle) ?? false)
        }
    }
    public func sortedByName(ascending: Bool = true) -> [EagleAssetMetadata] { sorted(by: .name, ascending: ascending) }
    public func sortedByModificationTime(ascending: Bool = false) -> [EagleAssetMetadata] { sorted(by: .modificationTime, ascending: ascending) }
    public var tagCounts: [String: Int] { tagAssetIDs.mapValues(\.count) }
    public var folderCounts: [String: Int] { folderAssetIDs.mapValues(\.count) }
    public enum SortKey: Sendable, Equatable { case name, modificationTime }
}
