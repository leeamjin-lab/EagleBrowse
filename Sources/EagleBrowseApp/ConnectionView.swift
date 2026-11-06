import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let connection: RemoteConnection?
    var isSheet = false
    @State private var draft: ConnectionDraft
    @State private var errorMessage: String?
    @State private var isTesting = false
    @State private var didPopulate = false
    @State private var connectionTask: Task<Void, Never>?
    @State private var certificateRequest: CertificateTrustRequest?

    init(connection: RemoteConnection?, isSheet: Bool = false) {
        self.connection = connection
        self.isSheet = isSheet
        _draft = State(initialValue: ConnectionDraft(connection: connection))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                GroupCard {
                    HStack {
                        Text("协议")
                        Spacer()
                        Picker("协议", selection: $draft.transport) {
                            Text("SMB").tag(RemoteTransport.smb)
                            Text("WebDAV").tag(RemoteTransport.webdav)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 174)
                    }
                    .padding(.horizontal, 16).frame(minHeight: 44)
                    InsetSeparator()
                    field("服务器", placeholder: "例如 fnos.local", text: $draft.host, keyboard: .URL)
                    InsetSeparator()
                    field("端口", placeholder: "443", text: $draft.port, keyboard: .numberPad)
                    Text("飞牛 WebDAV 常见端口：HTTP 5005 / HTTPS 5006")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    InsetSeparator()
                    pathField
                    InsetSeparator()
                    field("用户名", placeholder: "可选", text: $draft.account)
                    InsetSeparator()
                    HStack(spacing: 12) {
                        Text("密码")
                        SecureField("密码", text: $draft.password)
                            .textContentType(.password)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("connection.password")
                    }
                    .padding(.horizontal, 16).frame(minHeight: 44)
                }
                .disabled(isTesting)
                .padding(.bottom, 35)

                if draft.transport == .smb {
                    Text("SMB 暂未实现，请切换到 WebDAV")
                        .font(.footnote).foregroundStyle(AppTheme.secondary).padding(.bottom, 12)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .font(.subheadline).foregroundStyle(.red)
                        .accessibilityIdentifier("connection.error")
                        .padding(.bottom, 12)
                }
                Button(action: testAndConnect) {
                    HStack(spacing: 10) {
                        if isTesting { ProgressView().tint(.white) }
                        Text(isTesting ? "正在测试连接…" : "测试连接")
                    }
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(.white)
                    .background(AppTheme.blue, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(isTesting || draft.transport == .smb)
                .opacity(draft.transport == .smb ? 0.5 : 1)
                .accessibilityIdentifier("connection.test")
                Text("连接成功后保存 · 密码保存在本机钥匙串 · 只读访问")
                    .font(.system(size: 13)).foregroundStyle(AppTheme.secondary.opacity(0.73))
                    .multilineTextAlignment(.center).padding(.top, 12)

                if !isSheet && !model.connections.isEmpty && !model.showDemoConnect {
                    savedConnections.padding(.top, 35)
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .libraryScreen()
        .navigationTitle(connection == nil ? "连接库" : "编辑连接")
        .alert(item: $certificateRequest) { request in
            Alert(
                title: Text("信任 HTTPS 证书？"),
                message: Text("主机：\(request.host)\nSHA-256：\(request.fingerprint)"),
                primaryButton: .default(Text("信任")) {
                    TrustedCertificateStore().save(fingerprint: request.fingerprint, for: request.host)
                    testAndConnect()
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
        .toolbar {
            if isSheet {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
        .task { populate() }
        .onDisappear { connectionTask?.cancel() }
        .onChange(of: draft.transport) { _, value in
            if draft.port == "443" || draft.port == "445" { draft.port = value == .smb ? "445" : "443" }
            errorMessage = nil
        }
        .onChange(of: draft.host) { _, value in
            syncPortFromHost(value)
        }
    }

    private var pathField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("路径").fixedSize()
                TextField("WebDAV 路径，如 /Eagle/Visual Moodboard.library", text: $draft.path)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("路径")
            }
            Text("填 WebDAV 里看到的路径，不是 NAS 磁盘路径（/vol1/...）")
                .font(.footnote)
                .foregroundStyle(AppTheme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if draft.path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("/vol") {
                Text("看起来像 NAS 磁盘路径，请填写 WebDAV 里看到的路径")
                    .font(.footnote)
                    .foregroundStyle(.yellow)
                    .accessibilityIdentifier("connection.pathWarning")
            }
        }
        .font(.system(size: 17))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        HStack(spacing: 12) {
            Text(title).fixedSize()
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(title)
        }
        .font(.system(size: 17)).padding(.horizontal, 16).frame(minHeight: 44)
    }

    private var savedConnections: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("已保存的库").font(.footnote).foregroundStyle(AppTheme.secondary).padding(.leading, 16)
            GroupCard {
                ForEach(model.connections) { saved in
                    Button { model.switchConnection(saved) } label: {
                        HStack {
                            Image(systemName: "externaldrive")
                            Text(saved.libraryName)
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote)
                        }
                        .padding(16)
                    }
                    .buttonStyle(.plain)
                    if saved.id != model.connections.last?.id { InsetSeparator() }
                }
            }
        }
    }

    private func populate() {
        guard !didPopulate else { return }
        didPopulate = true
        if let connection {
            do { draft.password = try model.password(for: connection) }
            catch { errorMessage = "无法读取钥匙串，请重新输入密码" }
        } else if model.isDemo, let demo = model.currentConnection {
            let newID = draft.id
            draft = ConnectionDraft(connection: demo)
            if isSheet { draft.id = newID }
            draft.port = "443"
            if model.demoScreen == "connectError" {
                draft.host = "https://demo.local"
                draft.path = "/vol1/Eagle/Visual Moodboard.library"
                errorMessage = LibraryErrorMessage.text(RemoteServiceError.timeout)
            }
            syncPortFromHost(draft.host)
        }
    }

    private func syncPortFromHost(_ host: String) {
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let candidate = URLComponents(string: value.contains("://") ? value : "https://\(value)")?.port
        if let candidate { draft.port = String(candidate) }
    }

    private func testAndConnect() {
        isTesting = true
        errorMessage = nil
        connectionTask = Task {
            defer { isTesting = false }
            do {
                try await model.connect(draft)
                if isSheet { dismiss() }
            } catch {
                if !Task.isCancelled {
                    if let error = error as? RemoteServiceError {
                        switch error {
                        case .serverCertificateUntrusted(let host, let fingerprint):
                            certificateRequest = CertificateTrustRequest(host: host, fingerprint: fingerprint)
                            errorMessage = LibraryErrorMessage.text(error)
                        case .serverCertificateMismatch:
                            errorMessage = LibraryErrorMessage.text(error)
                        default:
                            errorMessage = LibraryErrorMessage.text(error)
                        }
                    } else {
                        errorMessage = LibraryErrorMessage.text(error)
                    }
                }
            }
        }
    }
}

private struct CertificateTrustRequest: Identifiable {
    let host: String
    let fingerprint: String
    var id: String { "\(host)|\(fingerprint)" }
}
