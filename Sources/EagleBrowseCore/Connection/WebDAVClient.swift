import Foundation
import CryptoKit
import Security

public final class WebDAVClient: RemoteFileService, @unchecked Sendable {
    private let connection: RemoteConnection
    private let passwordStore: PasswordStore
    private let session: URLSession
    private let authDelegate: WebDAVAuthDelegate?

    public init(connection: RemoteConnection,
                passwordStore: PasswordStore = KeychainPasswordStore(),
                trustedCertificateStore: TrustedCertificateStore = TrustedCertificateStore(),
                session: URLSession? = nil) {
        self.connection=connection; self.passwordStore=passwordStore
        if let session {
            self.session=session
            self.authDelegate=nil
        } else {
            let delegate = WebDAVAuthDelegate(connection: connection,
                                              passwordStore: passwordStore,
                                              trustedCertificateStore: trustedCertificateStore)
            self.authDelegate = delegate
            let configuration = URLSessionConfiguration.default
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        }
    }
    public func listDirectory(at path: String, options: RequestOptions = RequestOptions()) async throws -> [RemoteEntry] {
        try await RetryExecutor.run(options: options) {
            var request=try self.makeRequest(path:path,method:"PROPFIND",options:options); request.setValue("1",forHTTPHeaderField:"Depth"); request.setValue("application/xml",forHTTPHeaderField:"Content-Type"); request.httpBody=Data("<?xml version=\"1.0\"?><propfind xmlns=\"DAV:\"><prop><displayname/><resourcetype/><getcontentlength/><getlastmodified/></prop></propfind>".utf8)
            return DAVResponseParser.parse(data: try await self.perform(request))
        }
    }
    public func readFile(at path: String, options: RequestOptions = RequestOptions()) async throws -> Data { try await readData(at:path,options:options) }
    public func readData(at path: String, options: RequestOptions = RequestOptions()) async throws -> Data { try await RetryExecutor.run(options:options) { try await self.perform(self.makeRequest(path:path,method:"GET",options:options)) } }
    public func testConnection(options: RequestOptions = RequestOptions()) async throws -> Bool {
        guard connection.path.lowercased().hasSuffix(".library") else { throw RemoteServiceError.libraryNotFound }
        do { _ = try await readData(at:"metadata.json",options:options); return true } catch { throw Self.classify(error) }
    }
    private static func classify(_ error: Error) -> RemoteServiceError {
        if let e=error as? RemoteServiceError {
            switch e {
            case .httpStatus(401), .httpStatus(403): return .authenticationFailed
            case .httpStatus(404): return .libraryNotFound
            case .invalidURL: return .addressError
            default: return e
            }
        }
        if let e=error as? URLError {
            switch e.code {
            case .timedOut: return .timeout
            case .cannotConnectToHost: return .cannotConnectToHost
            case .cannotFindHost, .dnsLookupFailed: return .cannotFindHost
            case .notConnectedToInternet, .networkConnectionLost: return .networkConnectionLost
            case .secureConnectionFailed, .appTransportSecurityRequiresSecureConnection: return .secureConnectionFailed
            default: break
            }
        }
        return .invalidResponse
    }
    private func makeRequest(path: String, method: String, options: RequestOptions) throws -> URLRequest {
        guard var url=Self.endpointURL(for: connection) else { throw RemoteServiceError.addressError }
        let base=connection.path.trimmingCharacters(in: CharacterSet(charactersIn:"/")); let rel=path.trimmingCharacters(in: CharacterSet(charactersIn:"/")); if !base.isEmpty { url.appendPathComponent(base) }; if !rel.isEmpty { url.appendPathComponent(rel) }
        var r=URLRequest(url:url, cachePolicy: .reloadIgnoringLocalCacheData); r.httpMethod=method; r.timeoutInterval=options.timeout; r.setValue("EagleBrowse/1.0",forHTTPHeaderField:"User-Agent"); return r
    }

    /// The endpoint is normalized so a host port and a port-field value never produce two ports.
    static func endpointURL(for connection: RemoteConnection) -> URL? {
        var value = connection.host
        if !value.contains("://") {
            let scheme: String
            switch connection.port {
            case 80, 5005: scheme = "http"
            case 443, 5006: scheme = "https"
            default: scheme = "https"
            }
            value = "\(scheme)://\(value)"
        }
        guard var components = URLComponents(string: value),
              let host = components.host, !host.isEmpty else { return nil }
        if let port = connection.port { components.port = port }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard components.host == host else { return nil }
        return components.url
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        do {
            let (data,response)=try await session.data(for:request)
            guard let http=response as? HTTPURLResponse else { throw RemoteServiceError.invalidResponse }
            guard (200...299).contains(http.statusCode) else { throw RemoteServiceError.httpStatus(http.statusCode) }
            return data
        } catch {
            throw Self.errorPreferringPendingTrust(error,
                                                    pendingTrustError: authDelegate?.takePendingTrustError())
        }
    }

    static func errorPreferringPendingTrust(_ error: Error,
                                            pendingTrustError: RemoteServiceError?) -> Error {
        if let pendingTrustError { return pendingTrustError }
        return error
    }
}

private final class WebDAVAuthDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let connection: RemoteConnection
    let passwordStore: PasswordStore
    let trustedCertificateStore: TrustedCertificateStore
    private let lock = NSLock()
    private var pendingTrustError: RemoteServiceError?

    init(connection: RemoteConnection,
         passwordStore: PasswordStore,
         trustedCertificateStore: TrustedCertificateStore) {
        self.connection=connection
        self.passwordStore=passwordStore
        self.trustedCertificateStore=trustedCertificateStore
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handleAuthChallenge(challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handleAuthChallenge(challenge, completionHandler: completionHandler)
    }

    private func handleAuthChallenge(_ challenge: URLAuthenticationChallenge,
                                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust {
            handleServerTrust(challenge, completionHandler: completionHandler)
            return
        }
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest,
              !connection.account.isEmpty,
              let password = (try? passwordStore.readPassword(for: connection.id)) ?? nil,
              !password.isEmpty else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(user: connection.account, password: password, persistence: .forSession))
    }

    func takePendingTrustError() -> RemoteServiceError? {
        lock.lock(); defer { lock.unlock() }
        let error = pendingTrustError
        pendingTrustError = nil
        return error
    }

    private func handleServerTrust(_ challenge: URLAuthenticationChallenge,
                                   completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        var evaluationError: CFError?
        if SecTrustEvaluateWithError(trust, &evaluationError) {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let authority = Self.authority(for: connection)
        let fingerprint = Self.fingerprint(for: trust) ?? ""
        if let stored = trustedCertificateStore.fingerprint(for: authority),
           !fingerprint.isEmpty,
           TrustedCertificateStore.matches(stored: stored, presented: fingerprint) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        let error: RemoteServiceError
        if let stored = trustedCertificateStore.fingerprint(for: authority), !fingerprint.isEmpty {
            error = .serverCertificateMismatch(host: authority, expected: stored, fingerprint: fingerprint)
        } else {
            error = .serverCertificateUntrusted(host: authority, fingerprint: fingerprint)
        }
        lock.lock()
        pendingTrustError = error
        lock.unlock()
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    private static func authority(for connection: RemoteConnection) -> String {
        var value = connection.host
        if !value.contains("://") {
            let scheme: String
            switch connection.port {
            case 80, 5005: scheme = "http"
            case 443, 5006: scheme = "https"
            default: scheme = "https"
            }
            value = "\(scheme)://\(value)"
        }
        let components = URLComponents(string: value)
        let scheme = components?.scheme?.lowercased() ?? "https"
        let host = (components?.host ?? value).lowercased()
        let port = connection.port ?? components?.port ?? (scheme == "http" ? 80 : 443)
        let formattedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(formattedHost):\(port)"
    }

    private static func fingerprint(for trust: SecTrust) -> String? {
        guard let certificate = SecTrustGetCertificateAtIndex(trust, 0) else { return nil }
        let data = SecCertificateCopyData(certificate) as Data
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

private final class DAVResponseParser: NSObject, XMLParserDelegate {
    struct Item { var href=""; var displayName=""; var isDirectory=false; var length:Int64?; var modified:Date? }
    var items:[Item]=[]; var current:Item?; var element=""; var text=""
    static func parse(data:Data) -> [RemoteEntry] { let d=DAVResponseParser(); let p=XMLParser(data:data); p.delegate=d; guard p.parse() else{return []}; return d.items.compactMap { i in guard !i.href.isEmpty else{return nil}; let decoded=i.href.removingPercentEncoding ?? i.href; let path=URL(string:decoded)?.path ?? decoded; let clean=path.hasSuffix("/") && path.count>1 ? String(path.dropLast()) : path; let name=i.displayName.isEmpty ? URL(fileURLWithPath:clean).lastPathComponent : i.displayName; return RemoteEntry(path:clean,name:name,isDirectory:i.isDirectory,contentLength:i.length,lastModified:i.modified) } }
    func parser(_ parser:XMLParser,didStartElement name:String,namespaceURI:String?,qualifiedName qName:String?,attributes:[String:String]=[:]) { let n=(qName ?? name).split(separator:":").last.map(String.init)!.lowercased(); element=n; text=""; if n=="response" { current=Item() } }
    func parser(_ parser:XMLParser,foundCharacters string:String){text += string}
    func parser(_ parser:XMLParser,didEndElement name:String,namespaceURI:String?,qualifiedName qName:String?){ let n=(qName ?? name).split(separator:":").last.map(String.init)!.lowercased(); guard var item=current else{return}; let value=text.trimmingCharacters(in:.whitespacesAndNewlines); switch n { case "href": item.href=value; case "displayname": item.displayName=value; case "getcontentlength": item.length=Int64(value); case "getlastmodified": item.modified=HTTPDateFormatter.date(value); case "collection": item.isDirectory=true; case "response": items.append(item); current=nil; text=""; return; default: break }; current=item; text="" }
}
private enum HTTPDateFormatter { static func date(_ s:String)->Date? { let f=DateFormatter(); f.locale=Locale(identifier:"en_US_POSIX"); f.dateFormat="EEE, dd MMM yyyy HH:mm:ss zzz"; return f.date(from:s) } }
