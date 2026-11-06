import Foundation
import CryptoKit

/// Owned by LibraryRepository's actor. Only regenerable media lives under this root.
final class LibraryFileCache {
    struct Entry {
        let url: URL
        let size: Int
        var lastAccess: Date
    }

    let root: URL
    let diskLimit: Int
    private let memoryLimit: Int
    private let now: () -> Date
    private let memory = NSCache<NSString, NSData>()
    private var entries: [String: Entry]?
    private var bytes = 0

    init(root: URL, diskLimit: Int = 1_073_741_824, memoryLimit: Int = 32 * 1_024 * 1_024,
         now: @escaping () -> Date = Date.init) {
        self.root = root
        self.diskLimit = max(0, diskLimit)
        self.memoryLimit = max(0, memoryLimit)
        self.now = now
        memory.totalCostLimit = max(1, memoryLimit)
        memory.countLimit = 256
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func read(key: String) -> Data? {
        prepare()
        let id = Self.digest(key)
        guard var entry = entries?[id] else { return nil }
        let data = memory.object(forKey: id as NSString).map { $0 as Data }
            ?? (try? Data(contentsOf: entry.url))
        guard let data else {
            remove(id: id)
            return nil
        }
        entry.lastAccess = now()
        entries?[id] = entry
        try? FileManager.default.setAttributes([.modificationDate: entry.lastAccess], ofItemAtPath: entry.url.path)
        remember(data, id: id)
        return data
    }

    func write(_ data: Data, key: String) {
        prepare()
        let id = Self.digest(key)
        remove(id: id)
        // Large originals can still be displayed, but must not displace the whole cache.
        guard diskLimit > 0, data.count <= diskLimit else { return }
        let url = root.appendingPathComponent(id)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            let access = now()
            try? FileManager.default.setAttributes([.modificationDate: access], ofItemAtPath: url.path)
            entries?[id] = Entry(url: url, size: data.count, lastAccess: access)
            bytes += data.count
            remember(data, id: id)
            trim()
        } catch {
            // A cache write failure must not prevent viewing downloaded data.
        }
    }

    func remove(key: String) {
        prepare()
        remove(id: Self.digest(key))
    }

    func usage() -> Int {
        prepare()
        return bytes
    }

    func clear() throws {
        memory.removeAllObjects()
        entries = nil
        bytes = 0
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    private func remember(_ data: Data, id: String) {
        guard memoryLimit > 0, data.count <= memoryLimit else { return }
        memory.setObject(data as NSData, forKey: id as NSString, cost: data.count)
    }

    private func prepare() {
        guard entries == nil else { return }
        entries = [:]
        bytes = 0
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys))) ?? []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            entries?[url.lastPathComponent] = Entry(url: url, size: size, lastAccess: values.contentModificationDate ?? .distantPast)
            bytes += size
        }
        trim()
    }

    private func trim() {
        guard bytes > diskLimit else { return }
        let oldest = (entries ?? [:]).sorted {
            $0.value.lastAccess == $1.value.lastAccess ? $0.key < $1.key : $0.value.lastAccess < $1.value.lastAccess
        }
        for (id, _) in oldest where bytes > diskLimit { remove(id: id) }
    }

    private func remove(id: String) {
        memory.removeObject(forKey: id as NSString)
        guard let entry = entries?[id] else { return }
        do {
            if FileManager.default.fileExists(atPath: entry.url.path) {
                try FileManager.default.removeItem(at: entry.url)
            }
            entries?.removeValue(forKey: id)
            bytes -= entry.size
        } catch {
            // Keep accounting for files the OS did not allow us to delete.
        }
    }
}
