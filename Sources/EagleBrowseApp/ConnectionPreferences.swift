import Foundation

/// Passwords are deliberately absent from this UserDefaults payload.
struct ConnectionPreferences {
    private let defaults: UserDefaults
    private let key = "EagleBrowse.connections.v1"

    struct Snapshot: Codable {
        var connections: [RemoteConnection] = []
        var currentID: UUID?
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> Snapshot {
        guard let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return Snapshot() }
        return snapshot
    }

    func save(connections: [RemoteConnection], currentID: UUID?) {
        let snapshot = Snapshot(connections: connections, currentID: currentID)
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: key) }
    }
}

struct ConnectionDraft {
    var id = UUID()
    var transport: RemoteTransport = .webdav
    var host = ""
    var port = "443"
    var path = ""
    var account = ""
    var password = ""

    init(connection: RemoteConnection? = nil) {
        guard let connection else { return }
        id = connection.id
        transport = connection.transport
        host = connection.host
        if let port = connection.port {
            self.port = String(port)
        } else {
            let scheme = connection.transport == .webdav ? "https" : "smb"
            self.port = URLComponents(string: connection.host.contains("://") ? connection.host : "\(scheme)://\(connection.host)")?.port.map(String.init) ?? ""
        }
        path = connection.path
        account = connection.account
    }

    func connection() throws -> RemoteConnection {
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let portText = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = portText.isEmpty ? nil : Int(portText)
        guard portText.isEmpty || (number != nil && (1...65535).contains(number!)) else {
            throw RemoteServiceError.addressError
        }
        let effectivePortPreview = number
        let scheme: String
        if transport == .smb {
            scheme = "smb"
        } else if address.contains("://") {
            scheme = "https" // placeholder; real scheme comes from address
        } else {
            scheme = Self.webDAVScheme(port: effectivePortPreview)
        }
        let urlString = address.contains("://") ? address : "\(scheme)://\(address)"
        guard var url = URLComponents(string: urlString),
              let hostname = url.host, !hostname.isEmpty,
              !hostname.contains(where: { $0.isWhitespace }),
              (transport == .webdav ? ["http", "https"] : ["smb"]).contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { throw RemoteServiceError.addressError }
        let effectivePort = number ?? url.port
        guard effectivePort == nil || (1...65535).contains(effectivePort!) else { throw RemoteServiceError.addressError }
        url.port = nil
        url.path = ""
        var libraryPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while libraryPath.hasSuffix("/") { libraryPath.removeLast() }
        guard libraryPath.lowercased().hasSuffix(".library"),
              !libraryPath.split(separator: "/").contains("..") else { throw RemoteServiceError.libraryNotFound }
        if !libraryPath.hasPrefix("/") { libraryPath = "/" + libraryPath }
        guard let normalizedHost = url.string else { throw RemoteServiceError.addressError }
        return RemoteConnection(id: id, host: normalizedHost, transport: transport, path: libraryPath,
                                account: account.trimmingCharacters(in: .whitespacesAndNewlines), port: effectivePort)
    }

    static func webDAVScheme(port: Int?) -> String {
        switch port {
        case 80, 5005: return "http"
        case 443, 5006: return "https"
        default: return "https"
        }
    }
}

extension RemoteConnection {
    var libraryName: String {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return name.isEmpty ? "Eagle 素材库" : name
    }
    var serverDescription: String {
        guard var components = URLComponents(string: host.contains("://") ? host : "https://\(host)") else { return host }
        if components.port == nil { components.port = port }
        return components.string ?? host
    }
}

enum LibraryErrorMessage {
    static func skippedAssets(_ count: Int) -> String {
        "已跳过 \(count) 个损坏或缺失的素材"
    }

    static func text(_ error: Error) -> String {
        if let error = error as? RemoteServiceError {
            switch error {
            case .authenticationFailed, .missingCredential, .httpStatus(401), .httpStatus(403): return "账号或密码错误"
            case .libraryNotFound: return "路径不存在"
            case .httpStatus(404): return "请求的资源不存在"
            case .timeout: return "连接超时：请确认手机和 NAS 在同一局域网、端口正确，并已在设置-隐私-本地网络中允许 EagleBrowse"
            case .cannotConnectToHost: return "端口未开放或服务未启动"
            case .cannotFindHost: return "找不到主机"
            case .networkConnectionLost: return "网络断开"
            case .secureConnectionFailed: return "安全连接失败：Tailscale/飞牛可试端口 5005，服务器填 http://地址；HTTPS(5006) 需弹出证书信任"
            case .serverCertificateUntrusted: return "HTTPS 证书不受信任，请确认后选择是否信任"
            case .serverCertificateMismatch: return "HTTPS 证书指纹不匹配，已拒绝连接"
            case .addressError, .invalidURL: return "地址错误"
            default: return error.localizedDescription
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return "连接超时：请确认手机和 NAS 在同一局域网、端口正确，并已在设置-隐私-本地网络中允许 EagleBrowse"
            case .userAuthenticationRequired: return "账号或密码错误"
            case .cannotConnectToHost: return "端口未开放或服务未启动"
            case .cannotFindHost, .dnsLookupFailed: return "找不到主机"
            case .notConnectedToInternet, .networkConnectionLost: return "网络断开"
            case .secureConnectionFailed, .appTransportSecurityRequiresSecureConnection: return "安全连接失败：Tailscale/飞牛可试端口 5005，服务器填 http://地址；HTTPS(5006) 需弹出证书信任"
            case .badURL, .unsupportedURL: return "地址错误"
            default: return "连接失败，请检查服务器后重试"
            }
        }
        if error is DecodingError || (error as NSError).domain == NSCocoaErrorDomain { return "无法读取库数据，请检查路径后重试" }
        return error.localizedDescription
    }
}

/// A failed connection test never replaces a saved password.
struct DraftPasswordStore: PasswordStore {
    let password: String
    func readPassword(for connectionID: UUID) throws -> String? { password }
    func savePassword(_ password: String, for connectionID: UUID) throws {}
    func deletePassword(for connectionID: UUID) throws {}
}
