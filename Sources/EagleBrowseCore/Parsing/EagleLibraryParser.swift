import Foundation

public struct EagleLibraryParser: Sendable {
    public init() {}
    public func parseRootMetadata(_ data: Data) throws -> EagleLibraryMetadata {
        let object = try jsonObject(data)
        let folders = (object["folders"] as? [Any] ?? []).compactMap { Self.folder(from: $0) }
        let history = Self.strings(object["historyTags"] ?? object["tags"])
        let starred = Self.strings(object["starredTags"])
        return EagleLibraryMetadata(folders: folders, historyTags: history, starredTags: starred)
    }
    public func parseAssetMetadata(_ data: Data) throws -> EagleAssetMetadata {
        let o = try jsonObject(data)
        let id = Self.string(o["id"]) ?? ""
        let name = Self.string(o["name"]) ?? ""
        let ext = Self.string(o["ext"]) ?? ""
        let star: Bool? = (o["star"] as? Bool) ?? (Self.number(o["star"]).map { $0 != 0 })
        let modified: Date? = { if let s=Self.string(o["modificationTime"]) { return Self.date(s) }; if let n=Self.number(o["modificationTime"]) { return Date(timeIntervalSince1970:n) }; return nil }()
        return EagleAssetMetadata(id:id, name:name, ext:ext, size:Self.number(o["size"]).map(Int64.init), width:Self.number(o["width"]).map(Int.init), height:Self.number(o["height"]).map(Int.init), tags:Self.strings(o["tags"]), folders:Self.strings(o["folders"]), star:star, annotation:Self.string(o["annotation"]) ?? Self.string(o["description"]) ?? Self.string(o["note"]), url:Self.string(o["url"]), isDeleted:(o["isDeleted"] as? Bool) ?? false, modificationTime:modified)
    }
    public func buildIndex(rootMetadata: Data, assetMetadata: [Data]) throws -> EagleLibraryIndex {
        let root=try parseRootMetadata(rootMetadata)
        let assets=assetMetadata.compactMap { data -> EagleAssetMetadata? in guard let a=try? parseAssetMetadata(data), !a.isDeleted else{return nil}; return a }
        return makeIndex(root:root, assets:assets, libraryURL:nil)
    }
    public func parseLibrary(at libraryURL: URL) throws -> EagleLibraryIndex {
        var root=try parseRootMetadata(Data(contentsOf:libraryURL.appendingPathComponent("metadata.json")))
        let tagsURL=libraryURL.appendingPathComponent("tags.json")
        if let tagData=try? Data(contentsOf: tagsURL), let tagObject=try? JSONSerialization.jsonObject(with: tagData) as? [String:Any] {
            root=EagleLibraryMetadata(folders: root.folders, historyTags: root.historyTags + Self.strings(tagObject["historyTags"]), starredTags: root.starredTags + Self.strings(tagObject["starredTags"]))
        }
        var assets:[EagleAssetMetadata]=[]; let images=libraryURL.appendingPathComponent("images",isDirectory:true)
        if let e=FileManager.default.enumerator(at:images,includingPropertiesForKeys:nil) { for case let f as URL in e where f.lastPathComponent=="metadata.json" { if let d=try? Data(contentsOf:f), let a=try? parseAssetMetadata(d), !a.isDeleted { assets.append(a) } } }
        return makeIndex(root:root, assets:assets, libraryURL:libraryURL)
    }
    private func makeIndex(root:EagleLibraryMetadata, assets:[EagleAssetMetadata], libraryURL:URL?) -> EagleLibraryIndex {
        var tagIDs:[String:[String]]=[:], folderIDs:[String:[String]]=[:], thumbs:[String:String]=[:]
        for a in assets { for t in a.tags where !t.isEmpty { if !tagIDs[t,default:[]].contains(a.id){tagIDs[t,default:[]].append(a.id)} }; for f in a.folders where !f.isEmpty { if !folderIDs[f,default:[]].contains(a.id){folderIDs[f,default:[]].append(a.id)} }; thumbs[a.id]=thumbnailPath(for:a,libraryURL:libraryURL) }
        let folders=root.folders.map { attachAssets($0,folderIDs:folderIDs) }; return EagleLibraryIndex(folders:folders,assets:assets,tags:Array(Set(root.tags).union(tagIDs.keys)).sorted(),tagAssetIDs:tagIDs,folderAssetIDs:folderIDs,thumbnailPaths:thumbs)
    }
    private func thumbnailPath(for a:EagleAssetMetadata, libraryURL:URL?) -> String { guard let u=libraryURL else{return a.thumbnailRelativePath}; let thumb=u.appendingPathComponent(a.thumbnailRelativePath); return FileManager.default.fileExists(atPath:thumb.path) ? a.thumbnailRelativePath : a.originalRelativePath }
    private func attachAssets(_ n:EagleFolderNode,folderIDs:[String:[String]]) -> EagleFolderNode { EagleFolderNode(id:n.id,name:n.name,children:n.children.map{attachAssets($0,folderIDs:folderIDs)},assetIDs:folderIDs[n.id] ?? n.assetIDs,iconColor:n.iconColor) }
    private func jsonObject(_ data:Data) throws -> [String:Any] { let x=try JSONSerialization.jsonObject(with:data); guard let o=x as? [String:Any] else { throw DecodingError.dataCorrupted(.init(codingPath:[],debugDescription:"JSON object expected")) }; return o }
    private static func folder(from value:Any) -> EagleFolderNode? { guard let o=value as? [String:Any] else{return nil}; let id=string(o["id"]) ?? UUID().uuidString; let name=string(o["name"]) ?? "未命名文件夹"; let children=(o["children"] as? [Any] ?? []).compactMap(folder); return EagleFolderNode(id:id,name:name,children:children,assetIDs:strings(o["assetIDs"] ?? o["items"]),iconColor:string(o["iconColor"])) }
    private static func strings(_ value:Any?) -> [String] { (value as? [Any] ?? []).compactMap(string) }
    private static func string(_ value:Any?) -> String? { value as? String }
    private static func number(_ value:Any?) -> Double? { if let n=value as? NSNumber{return n.doubleValue}; if let s=value as? String{return Double(s)}; return nil }
    private static func date(_ s:String)->Date? { ISO8601DateFormatter().date(from:s) ?? {let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.dateFormat="yyyy-MM-dd HH:mm:ss";return f.date(from:s)}() }
}
