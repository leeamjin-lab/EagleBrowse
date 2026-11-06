import Foundation
import CoreFoundation
import UIKit
import ImageIO

enum LibraryGridSort: String, CaseIterable {
    case time = "时间"
    case name = "名称"
}

struct LibraryGridQuery {
    var folderID: String?
    var baseTag: String?
    var searchQuery: String?
    var selectedTags: Set<String> = []
    var sort: LibraryGridSort = .time

    func baseAssets(in index: EagleLibraryIndex) -> [EagleAssetMetadata] {
        if let folderID { return index.assets(inFolder: folderID) }
        if let baseTag { return index.search(tag: baseTag) }
        if let searchQuery { return index.search(query: searchQuery) }
        return index.assets
    }

    func assets(in index: EagleLibraryIndex) -> [EagleAssetMetadata] {
        baseAssets(in: index)
            .filter { selectedTags.isSubset(of: Set($0.tags)) }
            .sorted {
                if sort == .time {
                    let lhs = $0.modificationTime ?? .distantPast
                    let rhs = $1.modificationTime ?? .distantPast
                    if lhs != rhs { return lhs > rhs }
                }
                let comparison = $0.name.localizedStandardCompare($1.name)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
    }
}

struct AssetPreviewSelection: Identifiable {
    let id = UUID()
    let assets: [EagleAssetMetadata]
    let selectedID: String
}

enum AssetMediaKind {
    case image, video, pdf

    init(extension ext: String) {
        switch ext.lowercased() {
        case "pdf": self = .pdf
        case "mp4", "mov", "m4v", "avi", "webm", "mkv", "mpg", "mpeg": self = .video
        default: self = .image
        }
    }

    var label: String? {
        switch self {
        case .image: return nil
        case .video: return "视频 · 缩略图预览"
        case .pdf: return "PDF · 缩略图预览"
        }
    }
}

enum AssetImageLoader {
    /// A successful download can still contain invalid image bytes. Fall back on either failure.
    static func load(paths: [String], maxPixelSize: Int? = nil, read: (String) async throws -> Data) async -> UIImage? {
        var visited = Set<String>()
        for path in paths where visited.insert(path).inserted {
            guard !Task.isCancelled else { return nil }
            if let data = try? await read(path), let image = decode(data, maxPixelSize: maxPixelSize) {
                guard !Task.isCancelled else { return nil }
                return image
            }
        }
        return nil
    }

    private static func decode(_ data: Data, maxPixelSize: Int?) -> UIImage? {
        guard let maxPixelSize else { return UIImage(data: data) }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize)
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    static func previewPaths(for asset: EagleAssetMetadata) -> [String] {
        AssetMediaKind(extension: asset.ext) == .image
            ? [asset.originalRelativePath, asset.thumbnailRelativePath]
            : [asset.thumbnailRelativePath]
    }
}

enum AssetRating {
    /// Core stores star as Bool. Preserve numeric ratings for display without changing core.
    static func decode(_ data: Data?, fallback: Int?) -> Int? {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return fallback
        }
        for key in ["rating", "star"] {
            if let number = object[key] as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? 1 : 0 }
                return min(5, max(0, number.intValue))
            }
            if let text = object[key] as? String, let number = Int(text) {
                return min(5, max(0, number))
            }
        }
        return fallback
    }
}
