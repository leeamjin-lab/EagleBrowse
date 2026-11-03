import Foundation

public final class WebDAVClient: RemoteFileService, @unchecked Sendable {
    private let connection: RemoteConnection
    private let passwordStore: PasswordStore
    private let session: URLSession

    public init(
        connection: RemoteConnection,
        passwordStore: PasswordStore = KeychainPasswordStore(),
        session: URLSession = .shared
    ) {
        self.connection = connection
        self.passwordStore = passwordStore
        self.session = session
    }

    public func listDirectory(at path: String, options: RequestOptions) async throws -> [RemoteEntry] {
        try await RetryExecutor.run(options: options) {
            var request = try self.makeRequest(path: path, method: "PROPFIND", options: options)
            request.setValue("1", forHTTPHeaderField: "Depth")
            request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("<?xml version=\"1.0\"?><propfind xmlns=\"DAV:\"><prop><resourcetype/></prop></propfind>".utf8)

            let data = try await self.perform(request)
            return DAVResponseParser.parse(data: data)
        }
    }

    public func readFile(at path: String, options: RequestOptions) async throws -> Data {
        try await readData(at: path, options: options)
    }

    public func readData(at path: String, options: RequestOptions) async throws -> Data {
        try await RetryExecutor.run(options: options) {
            let request = try self.makeRequest(path: path, method: "GET", options: options)
            return try await self.perform(request)
        }
    }

    private func makeRequest(path: String, method: String, options: RequestOptions) throws -> URLRequest {
        guard var url = baseURL() else { throw RemoteServiceError.invalidURL }

        let basePath = connection.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relativePath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !basePath.isEmpty { url.appendPathComponent(basePath) }
        if !relativePath.isEmpty { url.appendPathComponent(relativePath) }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = options.timeout
        request.setValue("EagleBrowse/1.0", forHTTPHeaderField: "User-Agent")

        if !connection.account.isEmpty {
            guard let password = try passwordStore.readPassword(for: connection.id) else {
                throw RemoteServiceError.missingCredential
            }
            let credentials = Data("\(connection.account):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func baseURL() -> URL? {
        if connection.host.contains("://") {
            return URL(string: connection.host)
        }
        return URL(string: "https://\(connection.host)")
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw RemoteServiceError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else {
            throw RemoteServiceError.httpStatus(response.statusCode)
        }
        return data
    }
}

private final class DAVResponseParser: NSObject, XMLParserDelegate {
    private var currentElement = ""
    private var currentText = ""
    private var hrefs: [String] = []

    static func parse(data: Data) -> [RemoteEntry] {
        let parserDelegate = DAVResponseParser()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        guard parser.parse() else { return [] }

        return parserDelegate.hrefs.map { href in
            let path = URL(string: href)?.path ?? href
            let trimmedPath = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
            let name = URL(fileURLWithPath: trimmedPath).lastPathComponent
            return RemoteEntry(path: trimmedPath, name: name, isDirectory: href.hasSuffix("/"))
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName.lowercased()
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.lowercased() == "href" {
            let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { hrefs.append(value) }
        }
        currentElement = ""
        currentText = ""
    }
}
