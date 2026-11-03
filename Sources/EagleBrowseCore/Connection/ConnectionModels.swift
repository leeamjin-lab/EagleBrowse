import Foundation

public enum RemoteTransport: String, Codable, CaseIterable, Sendable {
    case smb
    case webdav
}

public struct RemoteConnection: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var host: String
    public var transport: RemoteTransport
    public var path: String
    public var account: String
    public var port: Int?

    public init(
        id: UUID = UUID(),
        host: String,
        transport: RemoteTransport,
        path: String = "/",
        account: String = "",
        port: Int? = nil
    ) {
        self.id = id
        self.host = host
        self.transport = transport
        self.path = path
        self.account = account
        self.port = port
    }
}

public struct RemoteEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let path: String
    public let name: String
    public let isDirectory: Bool

    public var id: String { path }

    public init(path: String, name: String, isDirectory: Bool) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
    }
}

public enum RemoteServiceError: Error, LocalizedError, Equatable, Sendable {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case missingCredential
    case notImplemented(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "远程地址无效"
        case .invalidResponse:
            return "远程服务返回了无效响应"
        case let .httpStatus(status):
            return "远程服务返回 HTTP 状态码 \(status)"
        case .missingCredential:
            return "缺少 Keychain 凭据"
        case let .notImplemented(message):
            return message
        }
    }
}

public struct RequestOptions: Sendable {
    public var timeout: TimeInterval
    public var maxAttempts: Int
    public var retryDelayNanoseconds: UInt64
    public var retryHook: (@Sendable (_ attempt: Int, _ error: Error) async -> Void)?

    public init(
        timeout: TimeInterval = 30,
        maxAttempts: Int = 1,
        retryDelayNanoseconds: UInt64 = 250_000_000,
        retryHook: (@Sendable (_ attempt: Int, _ error: Error) async -> Void)? = nil
    ) {
        self.timeout = timeout
        self.maxAttempts = max(1, maxAttempts)
        self.retryDelayNanoseconds = retryDelayNanoseconds
        self.retryHook = retryHook
    }
}

public protocol RemoteFileService: Sendable {
    func listDirectory(at path: String, options: RequestOptions) async throws -> [RemoteEntry]
    func readFile(at path: String, options: RequestOptions) async throws -> Data
    func readData(at path: String, options: RequestOptions) async throws -> Data
}

public extension RemoteFileService {
    func listDirectory(at path: String) async throws -> [RemoteEntry] {
        try await listDirectory(at: path, options: RequestOptions())
    }

    func readFile(at path: String) async throws -> Data {
        try await readFile(at: path, options: RequestOptions())
    }

    func readData(at path: String) async throws -> Data {
        try await readData(at: path, options: RequestOptions())
    }
}

enum RetryExecutor {
    static func run<Value: Sendable>(
        options: RequestOptions,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        var attempt = 1

        while true {
            do {
                return try await operation()
            } catch {
                guard attempt < options.maxAttempts else { throw error }
                if let retryHook = options.retryHook {
                    await retryHook(attempt, error)
                }
                if options.retryDelayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: options.retryDelayNanoseconds)
                }
                attempt += 1
            }
        }
    }
}
