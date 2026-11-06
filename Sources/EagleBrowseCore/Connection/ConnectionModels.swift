import Foundation

public enum RemoteTransport: String, Codable, CaseIterable, Sendable { case smb, webdav }
public struct RemoteConnection: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID; public var host: String; public var transport: RemoteTransport; public var path: String; public var account: String; public var port: Int?
    public init(id: UUID = UUID(), host: String, transport: RemoteTransport, path: String = "/", account: String = "", port: Int? = nil) { self.id=id; self.host=host; self.transport=transport; self.path=path; self.account=account; self.port=port }
}
public struct RemoteEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let path: String; public let name: String; public let isDirectory: Bool; public let contentLength: Int64?; public let lastModified: Date?
    public var id: String { path }
    public init(path: String, name: String, isDirectory: Bool, contentLength: Int64? = nil, lastModified: Date? = nil) { self.path=path; self.name=name; self.isDirectory=isDirectory; self.contentLength=contentLength; self.lastModified=lastModified }
}
public enum RemoteServiceError: Error, LocalizedError, Equatable, Sendable {
    case invalidURL, invalidResponse, httpStatus(Int), missingCredential, authenticationFailed, libraryNotFound, timeout, addressError
    case cannotConnectToHost, cannotFindHost, networkConnectionLost, secureConnectionFailed
    case serverCertificateUntrusted(host: String, fingerprint: String)
    case serverCertificateMismatch(host: String, expected: String, fingerprint: String)
    case notImplemented(String)
    public var errorDescription: String? {
        switch self {
        case .invalidURL, .addressError: return "地址错误"
        case .invalidResponse: return "远程服务返回了无效响应"
        case .httpStatus(let s): return "远程服务返回 HTTP 状态码 \(s)"
        case .missingCredential: return "缺少 Keychain 凭据"
        case .authenticationFailed: return "认证失败"
        case .libraryNotFound: return "找不到库（不是 .library）"
        case .timeout: return "超时"
        case .cannotConnectToHost: return "端口未开放或服务未启动"
        case .cannotFindHost: return "找不到主机"
        case .networkConnectionLost: return "网络断开"
        case .secureConnectionFailed: return "安全连接失败：Tailscale/飞牛可试端口 5005，服务器填 http://地址；HTTPS(5006) 需弹出证书信任"
        case .serverCertificateUntrusted(let host, let fingerprint):
            return "HTTPS 证书不受信任（\(host)，SHA-256：\(fingerprint)）"
        case .serverCertificateMismatch(let host, let expected, let fingerprint):
            return "HTTPS 证书指纹不匹配（\(host)，已保存：\(expected)，当前：\(fingerprint)）"
        case .notImplemented(let m): return m
        }
    }
}
public struct RequestOptions: Sendable {
    public var timeout: TimeInterval; public var maxAttempts: Int; public var retryDelayNanoseconds: UInt64; public var retryHook: (@Sendable (_ attempt: Int, _ error: Error) async -> Void)?
    public init(timeout: TimeInterval = 20, maxAttempts: Int = 3, retryDelayNanoseconds: UInt64 = 250_000_000, retryHook: (@Sendable (_ attempt: Int, _ error: Error) async -> Void)? = nil) { self.timeout=timeout; self.maxAttempts=max(1,maxAttempts); self.retryDelayNanoseconds=retryDelayNanoseconds; self.retryHook=retryHook }
}

/// Stores only certificate fingerprints. Passwords continue to live in Keychain.
public struct TrustedCertificateStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "EagleBrowse.trustedCertificates.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func fingerprint(for authority: String) -> String? {
        let values = defaults.dictionary(forKey: key) as? [String: String]
        return values?[Self.normalizedAuthority(authority)]
    }

    public func save(fingerprint: String, for authority: String) {
        var values = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        values[Self.normalizedAuthority(authority)] = Self.normalizedFingerprint(fingerprint)
        defaults.set(values, forKey: key)
    }

    public func removeFingerprint(for authority: String) {
        var values = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        values.removeValue(forKey: Self.normalizedAuthority(authority))
        defaults.set(values, forKey: key)
    }

    public static func matches(stored: String, presented: String) -> Bool {
        normalizedFingerprint(stored).caseInsensitiveCompare(normalizedFingerprint(presented)) == .orderedSame
    }

    public static func normalizedFingerprint(_ fingerprint: String) -> String {
        fingerprint.filter { !$0.isWhitespace && $0 != ":" }.uppercased()
    }

    private static func normalizedAuthority(_ authority: String) -> String {
        authority.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public protocol RemoteFileService: Sendable { func listDirectory(at path: String, options: RequestOptions) async throws -> [RemoteEntry]; func readFile(at path: String, options: RequestOptions) async throws -> Data; func readData(at path: String, options: RequestOptions) async throws -> Data }
public extension RemoteFileService { func listDirectory(at path: String) async throws -> [RemoteEntry] { try await listDirectory(at:path,options:RequestOptions()) }; func readFile(at path: String) async throws -> Data { try await readFile(at:path,options:RequestOptions()) }; func readData(at path: String) async throws -> Data { try await readData(at:path,options:RequestOptions()) } }
enum RetryExecutor { static func run<Value: Sendable>(options: RequestOptions, operation: @escaping @Sendable () async throws -> Value) async throws -> Value { var attempt=1; while true { do { return try await operation() } catch { guard attempt < options.maxAttempts else { throw error }; await options.retryHook?(attempt,error); if options.retryDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: options.retryDelayNanoseconds * UInt64(1 << min(attempt-1, 10))) }; attempt += 1 } } } }
