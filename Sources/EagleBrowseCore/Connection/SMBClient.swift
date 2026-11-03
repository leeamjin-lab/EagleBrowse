import Foundation

/// SMB transport seam. A real SMB client can be plugged in here later.
public final class SMBClient: RemoteFileService, @unchecked Sendable {
    private let connection: RemoteConnection

    public init(connection: RemoteConnection) {
        self.connection = connection
    }

    public func listDirectory(at path: String, options: RequestOptions) async throws -> [RemoteEntry] {
        throw RemoteServiceError.notImplemented(
            "TODO: 接入真实 SMB 客户端后实现目录读取（主机：\(connection.host)）"
        )
    }

    public func readFile(at path: String, options: RequestOptions) async throws -> Data {
        throw RemoteServiceError.notImplemented("TODO: 接入真实 SMB 客户端后实现文件读取")
    }

    public func readData(at path: String, options: RequestOptions) async throws -> Data {
        throw RemoteServiceError.notImplemented("TODO: 接入真实 SMB 客户端后实现 Data 读取")
    }
}
