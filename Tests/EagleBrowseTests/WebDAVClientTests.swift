import XCTest
@testable import EagleBrowse

final class WebDAVClientTests: XCTestCase {
    func testReadsBypassHTTPResponseCacheSoRescansSeeChangedFiles() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            return StubURLProtocol.result(request, status: 200, body: Data([7]))
        }
        let data = try await makeClient().readFile(at: "metadata.json", options: RequestOptions(maxAttempts: 1))
        XCTAssertEqual(data, Data([7]))
    }

    func testPropfindMultistatusParsesProperties() async throws {
        StubURLProtocol.handler = { request in
            let xml = """
            <D:multistatus xmlns:D="DAV:"><D:response><D:href>/library.library/</D:href><D:propstat><D:prop><D:displayname>Library</D:displayname><D:resourcetype><D:collection/></D:resourcetype><D:getcontentlength>0</D:getcontentlength><D:getlastmodified>Wed, 01 Jan 2025 00:00:00 GMT</D:getlastmodified></D:prop></D:propstat></D:response><D:response><D:href>/library.library/metadata.json</D:href><D:propstat><D:prop><D:displayname>metadata.json</D:displayname><D:resourcetype/><D:getcontentlength>12</D:getcontentlength></D:prop></D:propstat></D:response></D:multistatus>
            """
            return StubURLProtocol.result(request, status: 207, body: Data(xml.utf8))
        }
        let client = makeClient()
        let entries = try await client.listDirectory(at: "", options: RequestOptions(maxAttempts: 1, retryDelayNanoseconds: 0))
        XCTAssertEqual(entries.count, 2); XCTAssertTrue(entries[0].isDirectory); XCTAssertEqual(entries[1].contentLength, 12)
    }
    func testConnectionClassifies401And404() async {
        for (status, expected) in [(401, RemoteServiceError.authenticationFailed), (404, RemoteServiceError.libraryNotFound)] {
            StubURLProtocol.handler = { request in StubURLProtocol.result(request, status: status, body: Data()) }
            do { _ = try await makeClient().testConnection(options: RequestOptions(maxAttempts: 1, retryDelayNanoseconds: 0)); XCTFail("expected error") }
            catch let error as RemoteServiceError { XCTAssertEqual(error, expected) }
            catch { XCTFail("unexpected error: \(error)") }
        }
    }
    func testConnectionClassifiesTimeout() async {
        StubURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do { _ = try await makeClient().testConnection(options: RequestOptions(maxAttempts: 1, retryDelayNanoseconds: 0)); XCTFail("expected timeout") }
        catch let error as RemoteServiceError { XCTAssertEqual(error, .timeout) }
        catch { XCTFail("unexpected error: \(error)") }
    }

    func testPendingCertificateErrorWinsOverSecureConnectionFailure() {
        let expected = RemoteServiceError.serverCertificateUntrusted(
            host: "100.84.241.67:5006",
            fingerprint: "AA:BB"
        )
        let error = WebDAVClient.errorPreferringPendingTrust(
            URLError(.secureConnectionFailed),
            pendingTrustError: expected
        )
        XCTAssertEqual(error as? RemoteServiceError, expected)
    }

    func testCertificateFingerprintMatchingRequiresExactDigest() {
        XCTAssertTrue(TrustedCertificateStore.matches(
            stored: "AA:bb:01 02",
            presented: "AABB0102"
        ))
        XCTAssertFalse(TrustedCertificateStore.matches(
            stored: "AA:BB:01:02",
            presented: "AA:BB:01:03"
        ))
    }

    func testEndpointURLUsesOnePortAndPortFieldWins() throws {
        var draft = ConnectionDraft()
        draft.host = "https://1.2.3.4:5006"
        draft.port = "443"
        draft.path = "/Eagle.library"
        let connection = try draft.connection()
        XCTAssertEqual(connection.host, "https://1.2.3.4")
        XCTAssertEqual(connection.port, 443)
        let url = try XCTUnwrap(WebDAVClient.endpointURL(for: connection))
        XCTAssertEqual(url.absoluteString, "https://1.2.3.4:443")
        XCTAssertFalse(url.absoluteString.contains(":443:5006"))
    }

    func testEndpointURLUsesHTTPForPort5005() throws {
        let httpURL = try XCTUnwrap(WebDAVClient.endpointURL(for: RemoteConnection(host: "100.84.241.67", transport: .webdav, path: "/x.library", port: 5005)))
        XCTAssertEqual(httpURL.scheme, "http")
        XCTAssertEqual(httpURL.host, "100.84.241.67")
        XCTAssertEqual(httpURL.port, 5005)

        let httpsURL = try XCTUnwrap(WebDAVClient.endpointURL(for: RemoteConnection(host: "100.84.241.67", transport: .webdav, path: "/x.library", port: 5006)))
        XCTAssertEqual(httpsURL.scheme, "https")
        XCTAssertEqual(httpsURL.port, 5006)
    }

    private func makeClient() -> WebDAVClient {
        let c=RemoteConnection(host:"https://example.invalid",transport:.webdav,path:"/library.library")
        let config=URLSessionConfiguration.ephemeral; config.protocolClasses=[StubURLProtocol.self]
        return WebDAVClient(connection:c,passwordStore:MemoryPasswordStore(),session:URLSession(configuration:config))
    }
}
private final class MemoryPasswordStore: PasswordStore, @unchecked Sendable { func readPassword(for: UUID)throws->String?{nil}; func savePassword(_:String,for:UUID)throws{}; func deletePassword(for:UUID)throws{} }
private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse,Data))?
    static func result(_ request:URLRequest,status:Int,body:Data)->(HTTPURLResponse,Data) { (HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/xml"])!,body) }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() { do { let (response,data)=try Self.handler!(request); client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed); client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self) } catch { client?.urlProtocol(self,didFailWithError:error) } }
    override func stopLoading() {}

}
