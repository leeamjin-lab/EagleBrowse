import SwiftUI
import UIKit

struct BrowseView: View {
    @EnvironmentObject private var model: LibraryModel
    let tagsOnly: Bool
    @State private var search = ""
    @State private var showSearch = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if showSearch {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(AppTheme.secondary)
                        TextField(tagsOnly ? "搜索标签" : "搜索素材、文件夹或标签", text: $search)
                            .focused($searchFocused)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        }
                    }
                    .padding(12)
                    .background(AppTheme.group, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

                if let index = model.index {
                    LibraryRefreshStatus()
                    libraryContent(index)
                } else { switch model.phase {
                case .loading:
                    VStack(spacing: 16) {
                        ProgressView()
                        Text(model.scanProgress?.text ?? "正在读取素材库…").foregroundStyle(AppTheme.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 340)
                case .failed(let message):
                    LibraryStateView(symbol: "wifi.exclamationmark", title: message,
                                     message: "请检查连接设置，或重新加载素材库。",
                                     actionTitle: "重试", action: { model.reload(rescan: true) })
                case .idle:
                    LibraryStateView(symbol: "externaldrive", title: "尚未加载素材库",
                                     actionTitle: "加载", action: { model.reload() })
                case .ready:
                    if let index = model.index { libraryContent(index) }
                } }
            }
            .padding(.bottom, 20)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await model.refresh() }
        .libraryScreen()
        .navigationTitle(tagsOnly ? "标签" : model.currentConnection?.libraryName ?? "浏览")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSearch.toggle()
                    if !showSearch { search = "" }
                    searchFocused = showSearch
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("搜索")
                .accessibilityIdentifier("browse.search")
            }
        }
        .task { model.startIfNeeded() }
    }

    @ViewBuilder
    private func libraryContent(_ index: EagleLibraryIndex) -> some View {
        if index.assets.isEmpty && index.folders.isEmpty && index.tags.isEmpty {
            LibraryStateView(symbol: "tray", title: "空库", message: "这个素材库还没有素材。",
                             actionTitle: "重新扫描", action: { model.reload(rescan: true) })
        } else {
            let folders = matchingFolders(index.folders)
            let tags = index.tags.filter { search.isEmpty || $0.localizedStandardContains(search) }
            let assets = !tagsOnly && !search.isEmpty ? index.search(query: search) : []
            if !tagsOnly && search.isEmpty {
                NavigationLink(value: LibraryGridRoute.all) {
                    HStack(spacing: 14) {
                        AllAssetsCover(paths: index.assets.sorted { $0.id < $1.id }.prefix(4).map {
                            index.thumbnailPaths[$0.id] ?? $0.thumbnailRelativePath
                        }).frame(width: 60, height: 60)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("全部素材").font(.system(size: 17))
                            Text("\(index.assets.count.formatted()) 项")
                                .font(.system(size: 15)).foregroundStyle(AppTheme.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !tagsOnly && !search.isEmpty && !assets.isEmpty {
                sectionTitle("素材")
                NavigationLink(value: LibraryGridRoute.search(search)) {
                    HStack(spacing: 14) {
                        AllAssetsCover(paths: assets.prefix(4).map { index.thumbnailPaths[$0.id] ?? $0.thumbnailRelativePath })
                            .frame(width: 60, height: 60)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("搜索结果").font(.system(size: 17))
                            Text("\(assets.count.formatted()) 项")
                                .font(.system(size: 15)).foregroundStyle(AppTheme.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.28))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !tagsOnly && !folders.isEmpty {
                sectionTitle("文件夹")
                LazyVStack(spacing: 0) {
                    ForEach(Array(folders.enumerated()), id: \.element.id) { offset, folder in
                        albumRow(title: folder.name, count: index.count(inFolder: folder.id),
                                 path: coverPath(folder, index: index), palette: offset,
                                 last: offset == folders.count - 1,
                                 route: .folder(id: folder.id, name: folder.name))
                    }
                }
                .padding(.leading, 16)
            }
            if !tags.isEmpty {
                sectionTitle("标签")
                LazyVStack(spacing: 0) {
                    ForEach(Array(tags.enumerated()), id: \.element) { offset, tag in
                        albumRow(title: tag, count: index.count(forTag: tag),
                                 path: index.assetIDs(forTag: tag).first.flatMap { index.thumbnailPaths[$0] },
                                 palette: offset, last: offset == tags.count - 1,
                                 route: .tag(tag))
                    }
                }
                .padding(.leading, 16)
            }
            if (tagsOnly && tags.isEmpty) || (!search.isEmpty && folders.isEmpty && tags.isEmpty && assets.isEmpty) {
                LibraryStateView(symbol: tagsOnly ? "tag" : "magnifyingglass",
                                 title: search.isEmpty ? "暂无标签" : "没有匹配的结果")
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 22, weight: .bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 8)
    }

    private func albumRow(title: String, count: Int, path: String?, palette: Int,
                          last: Bool, route: LibraryGridRoute) -> some View {
        VStack(spacing: 0) {
            NavigationLink(value: route) {
                HStack(spacing: 14) {
                    LibraryThumbnail(path: path, palette: palette, symbol: route.isTag ? "tag" : "folder")
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 17)).lineLimit(1)
                        Text(count.formatted()).font(.system(size: 15)).foregroundStyle(AppTheme.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.28))
                }
                .padding(.trailing, 18).frame(minHeight: 88).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            if !last { InsetSeparator(inset: 74) }
        }
    }

    private func matchingFolders(_ folders: [EagleFolderNode]) -> [EagleFolderNode] {
        if search.isEmpty { return folders }
        return folders.flatMap { folder in
            (folder.name.localizedStandardContains(search) ? [folder] : []) + matchingFolders(folder.children)
        }
    }

    private func coverPath(_ folder: EagleFolderNode, index: EagleLibraryIndex) -> String? {
        if let id = index.coverAssetID(inFolder: folder.id) { return index.thumbnailPaths[id] }
        return folder.children.lazy.compactMap { coverPath($0, index: index) }.first
    }
}

private struct AllAssetsCover: View {
    let paths: [String]
    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 1) { tile(0); tile(1) }
            HStack(spacing: 1) { tile(2); tile(3) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }

    private func tile(_ index: Int) -> some View {
        LibraryThumbnail(path: paths.indices.contains(index) ? paths[index] : nil,
                         palette: index, symbol: "photo", cornerRadius: 0)
    }
}

struct LibraryThumbnail: View {
    @EnvironmentObject private var model: LibraryModel
    let path: String?
    let palette: Int
    let symbol: String
    var cornerRadius: CGFloat = 10
    @State private var image: UIImage?
    @State private var loading = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                AppTheme.group
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if loading {
                    ProgressView().tint(AppTheme.secondary)
                } else {
                    Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped().clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        .accessibilityHidden(true)
        .task(id: "\(model.currentID?.uuidString ?? "")|\(path ?? "")|\(model.thumbnailRevision)") {
            image = nil
            loading = true
            defer { loading = false }
            guard let path, let connection = model.currentConnection else { return }
            var paths = [path]
            if let asset = model.index?.assets.first(where: {
                $0.thumbnailRelativePath == path || model.index?.thumbnailPaths[$0.id] == path
            }), AssetMediaKind(extension: asset.ext) == .image {
                paths.append(asset.originalRelativePath)
            }
            let loaded = await AssetImageLoader.load(paths: paths, maxPixelSize: 512) { candidate in
                try await model.repository.thumbnail(path: candidate, connection: connection, demo: model.isDemo)
            }
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
