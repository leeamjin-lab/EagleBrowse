import SwiftUI

enum LibraryGridRoute: Hashable {
    case all
    case folder(id: String, name: String)
    case tag(String)
    case search(String)

    var isTag: Bool {
        if case .tag = self { return true }
        return false
    }
}
struct LibraryTabsView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var browsePath: [LibraryGridRoute] = []
    @State private var tagPath: [LibraryGridRoute] = []
    @State private var preview: AssetPreviewSelection?
    @State private var didOpenDemoScreen = false

    var body: some View {
        Group {
            switch model.selectedTab {
            case .browse:
                NavigationStack(path: $browsePath) {
                    BrowseView(tagsOnly: false)
                        .navigationDestination(for: LibraryGridRoute.self) { route in
                            gridDestination(route)
                        }
                }
            case .tags:
                NavigationStack(path: $tagPath) {
                    BrowseView(tagsOnly: true)
                        .navigationDestination(for: LibraryGridRoute.self) { route in
                            gridDestination(route)
                        }
                }
            case .settings:
                NavigationStack { SettingsView() }
            }
        }
        .onChange(of: model.phase) { _, phase in
            if phase == .ready { openDemoScreenIfNeeded() }
        }
        .task {
            model.startIfNeeded()
            openDemoScreenIfNeeded()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 24) {
                ForEach(LibraryTab.allCases, id: \.self) { tab in
                    Button { model.selectedTab = tab } label: {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(model.selectedTab == tab ? Color.white : AppTheme.secondary)
                            .frame(width: 44, height: 44)
                            .background(model.selectedTab == tab ? AppTheme.blue.opacity(0.35) : .clear, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.title)
                    .accessibilityIdentifier("tab.\(tab.rawValue)")
                    .accessibilityAddTraits(model.selectedTab == tab ? .isSelected : [])
                }
            }
            .frame(width: 220, height: 62)
            .floatingGlass()
            .shadow(color: .black.opacity(0.45), radius: 20, y: 10)
            .padding(.top, 8)
        }
        .background(Color.black.ignoresSafeArea())
        .fullScreenCover(item: $preview) { selection in
            AssetPreviewView(selection: selection)
        }
    }

    @ViewBuilder
    private func gridDestination(_ route: LibraryGridRoute) -> some View {
        switch route {
        case .all:
            AssetGridView(title: "全部素材", folderID: nil, baseTag: nil, openPreview: { preview = $0 })
        case .folder(let id, let name):
            AssetGridView(title: name, folderID: id, baseTag: nil, openPreview: { preview = $0 })
        case .tag(let tag):
            AssetGridView(title: tag, folderID: nil, baseTag: tag, openPreview: { preview = $0 })
        case .search(let query):
            AssetGridView(title: "搜索：\(query)", folderID: nil, baseTag: nil, searchQuery: query,
                          openPreview: { preview = $0 })
        }
    }

    private func openDemoScreenIfNeeded() {
        guard !didOpenDemoScreen, model.isDemo, model.phase == .ready,
              ["grid", "preview"].contains(model.demoScreen ?? ""),
              let index = model.index,
              let folder = findFolder(named: "座舱", in: index.folders) else { return }
        didOpenDemoScreen = true
        let assets = LibraryGridQuery(folderID: folder.id).assets(in: index)
        browsePath = [.folder(id: folder.id, name: folder.name)]
        if model.demoScreen == "preview", let first = assets.first {
            preview = AssetPreviewSelection(assets: assets, selectedID: first.id)
        }
    }

    private func findFolder(named name: String, in folders: [EagleFolderNode]) -> EagleFolderNode? {
        for folder in folders {
            if folder.name == name { return folder }
            if let match = findFolder(named: name, in: folder.children) { return match }
        }
        return nil
    }
}

private struct AssetGridView: View {
    @EnvironmentObject private var model: LibraryModel
    let title: String
    let folderID: String?
    let baseTag: String?
    var searchQuery: String?
    let openPreview: (AssetPreviewSelection) -> Void
    @State private var selectedTags: Set<String> = []
    @State private var sortOption: LibraryGridSort = .time

    private var index: EagleLibraryIndex? { model.index }

    var body: some View {
        let assets = displayedAssets
        ScrollView {
            VStack(spacing: 0) {
                LibraryRefreshStatus()
                if let children = childFolders, !children.isEmpty {
                    childFolderList(children)
                }

                if assets.isEmpty {
                    LibraryStateView(symbol: "photo.on.rectangle.angled", title: "暂无素材")
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                        ForEach(assets) { asset in
                            Button {
                                openPreview(AssetPreviewSelection(assets: assets, selectedID: asset.id))
                            } label: {
                                LibraryThumbnail(
                                    path: index?.thumbnailPaths[asset.id] ?? asset.thumbnailRelativePath,
                                    palette: 0,
                                    symbol: "photo",
                                    cornerRadius: 0
                                )
                                .aspectRatio(1, contentMode: .fit)
                                .clipped()
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(asset.name)
                            .accessibilityIdentifier("asset.\(asset.id)")
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.top, 8)
                }
            }
            .padding(.bottom, 110)
        }
        .refreshable { await model.refresh() }
        .libraryScreen()
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                tagFilterMenu
                sortMenu
            }
        }
    }

    private var childFolders: [EagleFolderNode]? {
        guard let folderID, let folder = findFolder(id: folderID, in: index?.folders ?? []) else { return nil }
        return folder.children
    }

    private var query: LibraryGridQuery {
        LibraryGridQuery(folderID: folderID, baseTag: baseTag, searchQuery: searchQuery,
                         selectedTags: selectedTags, sort: sortOption)
    }

    private var displayedAssets: [EagleAssetMetadata] {
        guard let index else { return [] }
        return query.assets(in: index)
    }

    private var availableTags: [String] {
        guard let index else { return [] }
        return Array(Set(query.baseAssets(in: index).flatMap(\.tags))).sorted()
    }

    private var tagFilterMenu: some View {
        Menu {
            if availableTags.isEmpty {
                Text("当前没有标签")
            } else {
                ForEach(availableTags, id: \.self) { tag in
                    Button { toggleTag(tag) } label: {
                        Label(tag, systemImage: selectedTags.contains(tag) ? "checkmark.circle.fill" : "circle")
                    }
                }
                if !selectedTags.isEmpty {
                    Divider()
                    Button("清除筛选") { selectedTags.removeAll() }
                }
            }
        } label: {
            Image(systemName: selectedTags.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .menuActionDismissBehavior(.disabled)
        .accessibilityLabel("标签筛选")
    }

    private var sortMenu: some View {
        Menu {
            ForEach(LibraryGridSort.allCases, id: \.self) { option in
                Button { sortOption = option } label: {
                    Label(option.rawValue, systemImage: sortOption == option ? "checkmark" : "")
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("排序")
    }

    @ViewBuilder
    private func childFolderList(_ children: [EagleFolderNode]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("子文件夹")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.secondary)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(children, id: \.id) { folder in
                        NavigationLink(value: LibraryGridRoute.folder(id: folder.id, name: folder.name)) {
                            VStack(alignment: .leading, spacing: 5) {
                                LibraryThumbnail(path: folderCoverPath(folder), palette: 0, symbol: "folder")
                                    .frame(width: 78, height: 58)
                                Text(folder.name).font(.system(size: 14)).lineLimit(1)
                                Text("\(index?.count(inFolder: folder.id) ?? 0)")
                                    .font(.system(size: 12)).foregroundStyle(AppTheme.secondary)
                            }
                            .frame(width: 78, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) { selectedTags.remove(tag) } else { selectedTags.insert(tag) }
    }

    private func findFolder(id: String, in folders: [EagleFolderNode]) -> EagleFolderNode? {
        for folder in folders {
            if folder.id == id { return folder }
            if let match = findFolder(id: id, in: folder.children) { return match }
        }
        return nil
    }

    private func folderCoverPath(_ folder: EagleFolderNode) -> String? {
        guard let index else { return nil }
        if let assetID = index.coverAssetID(inFolder: folder.id) { return index.thumbnailPaths[assetID] }
        return folder.children.lazy.compactMap(folderCoverPath).first
    }
}
