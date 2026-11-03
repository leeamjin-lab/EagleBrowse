import Foundation

public protocol LocalIndexCache: Sendable {
    func load() async throws -> EagleLibraryIndex?
    func save(_ index: EagleLibraryIndex) async throws
}

public actor JSONFileLocalIndexCache: LocalIndexCache {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() async throws -> EagleLibraryIndex? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(EagleLibraryIndex.self, from: data)
    }

    public func save(_ index: EagleLibraryIndex) async throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(index).write(to: fileURL, options: .atomic)
    }
}
