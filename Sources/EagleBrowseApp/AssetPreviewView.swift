import SwiftUI
import UIKit

struct AssetPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let selection: AssetPreviewSelection
    @State private var selectedID: String
    @State private var showInfo = true

    init(selection: AssetPreviewSelection) {
        self.selection = selection
        _selectedID = State(initialValue: selection.selectedID)
    }

    private var selectedAsset: EagleAssetMetadata? {
        selection.assets.first { $0.id == selectedID }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    TabView(selection: $selectedID) {
                        ForEach(selection.assets) { asset in
                            PreviewAssetPage(asset: asset, isActive: selectedID == asset.id)
                                .tag(asset.id)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .accessibilityIdentifier("preview.pages")

                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .frame(width: 30, height: 30)
                                .background(Color(red: 60/255, green: 60/255, blue: 67/255).opacity(0.6), in: Circle())
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("关闭预览")
                        .accessibilityIdentifier("preview.close")
                        Spacer()
                        Text("\((selection.assets.firstIndex { $0.id == selectedID } ?? 0) + 1) / \(selection.assets.count)")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(8)
                            .background(.black.opacity(0.45), in: Capsule())
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showInfo.toggle() }
                        } label: {
                            Image(systemName: showInfo ? "info.circle.fill" : "info.circle")
                                .font(.system(size: 22))
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(showInfo ? "收起素材信息" : "显示素材信息")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 9)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                if showInfo, let selectedAsset {
                    PreviewInfoSheet(asset: selectedAsset)
                        .id(selectedAsset.id)
                        .frame(height: min(340, geometry.size.height * 0.48))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .background(Color.black.ignoresSafeArea())
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }
}

private struct PreviewAssetPage: View {
    @EnvironmentObject private var model: LibraryModel
    let asset: EagleAssetMetadata
    let isActive: Bool
    @State private var image: UIImage?
    @State private var failed = false
    @State private var retry = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            if let image {
                ZoomablePreviewImage(image: image, isActive: isActive)
                    .accessibilityLabel(asset.name)
            } else if failed {
                VStack(spacing: 14) {
                    Image(systemName: "photo").font(.system(size: 36))
                    Text("无法加载素材").font(.subheadline)
                    Button("重试") { retry += 1 }.buttonStyle(.bordered)
                }
                .foregroundStyle(AppTheme.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let label = AssetMediaKind(extension: asset.ext).label {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.black.opacity(0.65), in: Capsule())
                    .padding(.bottom, 14)
            }
        }
        .task(id: "\(isActive)|\(retry)|\(model.thumbnailRevision)") {
            guard isActive else {
                image = nil
                return
            }
            failed = false
            guard let connection = model.currentConnection else { failed = true; return }
            let loaded = await AssetImageLoader.load(paths: AssetImageLoader.previewPaths(for: asset)) { path in
                try await model.repository.thumbnail(path: path, connection: connection, demo: model.isDemo)
            }
            guard !Task.isCancelled else { return }
            image = loaded
            failed = loaded == nil
        }
    }
}

/// Bounded two-finger zoom and one-finger pan. At 1x, horizontal swipes reach the page container.
private struct ZoomablePreviewImage: UIViewRepresentable {
    let image: UIImage
    let isActive: Bool

    func makeUIView(context: Context) -> ImageZoomScrollView {
        let scroll = ImageZoomScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.bouncesZoom = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.panGestureRecognizer.isEnabled = false
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: ImageZoomScrollView, context: Context) {
        if scroll.imageView.image !== image {
            scroll.setZoomScale(1, animated: false)
            scroll.imageView.image = image
            scroll.setNeedsLayout()
        }
        if !isActive { scroll.setZoomScale(1, animated: false) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ImageZoomScrollView)?.imageView
        }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            scrollView.panGestureRecognizer.isEnabled = scrollView.zoomScale > 1.01
            (scrollView as? ImageZoomScrollView)?.centerImage()
        }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? ImageZoomScrollView else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: scroll.imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                      width: size.width, height: size.height), animated: true)
            }
        }
    }
}

private final class ImageZoomScrollView: UIScrollView {
    let imageView = UIImageView()
    private var viewport = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if viewport != bounds.size || imageView.bounds.size == .zero {
            viewport = bounds.size
            setZoomScale(1, animated: false)
            imageView.frame = CGRect(origin: .zero, size: viewport)
            contentSize = viewport
        }
        centerImage()
    }

    func centerImage() {
        imageView.center = CGPoint(x: max(contentSize.width, bounds.width) / 2,
                                   y: max(contentSize.height, bounds.height) / 2)
    }
}

private struct PreviewInfoSheet: View {
    @EnvironmentObject private var model: LibraryModel
    let asset: EagleAssetMetadata
    @State private var rating: Int?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                Capsule()
                    .fill(Color(red: 235/255, green: 235/255, blue: 245/255).opacity(0.3))
                    .frame(width: 36, height: 5)
                    .padding(.top, 12).padding(.bottom, 12)
                Text(asset.name)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 6)
                    .accessibilityIdentifier("preview.name")
                infoBlock("标签") {
                    if asset.tags.isEmpty {
                        Text("无标签").foregroundStyle(AppTheme.secondary)
                    } else {
                        PreviewTagLayout(spacing: 8) {
                            ForEach(Array(Set(asset.tags)).sorted(), id: \.self) { tag in
                                Text(tag).font(.system(size: 15))
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(Color(red: 120/255, green: 120/255, blue: 128/255).opacity(0.24), in: Capsule())
                            }
                        }
                    }
                }
                separator
                infoBlock("星级") {
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { value in
                            Image(systemName: "star.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(value <= (rating ?? asset.rating ?? 0)
                                    ? Color(red: 1, green: 214/255, blue: 10/255)
                                    : Color(red: 235/255, green: 235/255, blue: 245/255).opacity(0.18))
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(rating ?? asset.rating ?? 0) 星，只读")
                }
                separator
                infoBlock("备注") {
                    Text(asset.annotation.flatMap { $0.isEmpty ? nil : $0 } ?? "无备注")
                        .font(.system(size: 17))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 8)
        }
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12)
                .fill(AppTheme.group.opacity(0.92))
                .ignoresSafeArea(edges: .bottom)
        }
        .task(id: "\(asset.id)|\(model.thumbnailRevision)") {
            guard let connection = model.currentConnection else { return }
            let data = try? await model.repository.thumbnail(
                path: "images/\(asset.id).info/metadata.json", connection: connection, demo: model.isDemo)
            guard !Task.isCancelled else { return }
            rating = AssetRating.decode(data, fallback: asset.rating)
        }
    }

    private var separator: some View {
        Color(red: 84/255, green: 84/255, blue: 88/255).opacity(0.45).frame(height: 0.33)
    }

    private func infoBlock<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13))
                .foregroundStyle(Color(red: 235/255, green: 235/255, blue: 245/255).opacity(0.6))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 14)
    }
}

private struct PreviewTagLayout: Layout {
    let spacing: CGFloat

    private func arrangement(width: CGFloat, subviews: Subviews) -> (CGSize, [CGPoint]) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        var origins: [CGPoint] = []
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width.isFinite ? width : usedWidth, height: y + rowHeight), origins)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width ?? .infinity, subviews: subviews).0
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let origins = arrangement(width: bounds.width, subviews: subviews).1
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + origins[index].x, y: bounds.minY + origins[index].y),
                          proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}
