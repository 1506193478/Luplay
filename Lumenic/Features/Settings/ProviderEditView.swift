import SwiftUI

/// 添加/编辑提供商（对标稿 v-prov / v-edit：浅色 Infuse 风，先选提供商网格再填表单）
struct ProviderEditView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    let existing: ProviderConfig?

    @State private var kind: ProviderKind = .emby
    @State private var name = ""
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var rootPath = ""
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testFailed = false

    init(existing: ProviderConfig?) {
        self.existing = existing
        if let e = existing {
            _kind = State(initialValue: e.kind)
            _name = State(initialValue: e.name)
            _serverURL = State(initialValue: e.serverURL)
            _username = State(initialValue: e.username)
            _password = State(initialValue: e.password)
            _rootPath = State(initialValue: e.rootPath)
        }
    }

    private var defaultName: String { kind.title }

    /// 地址规范化：无协议头自动补 http://（局域网 NAS 常见省写）
    private var normalizedURL: String {
        var s = serverURL.trimmingCharacters(in: .whitespaces)
        if !s.isEmpty,
           !s.lowercased().hasPrefix("http://"), !s.lowercased().hasPrefix("https://") {
            s = "http://" + s
        }
        return s
    }

    private var draft: ProviderConfig {
        ProviderConfig(id: existing?.id ?? UUID().uuidString,
                       kind: kind,
                       name: name.trimmingCharacters(in: .whitespaces),
                       serverURL: normalizedURL,
                       username: username,
                       password: password,
                       rootPath: rootPath)
    }

    /// 校验必须带 http/https 协议头且有主机名
    private var canSave: Bool {
        guard let url = URL(string: normalizedURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if existing == nil {
                        providerGrid
                    }
                    formSection
                    testSection
                    if existing != nil {
                        deleteButton
                    }
                    Color.clear.frame(height: 30)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(Color.dsLightPage.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(existing == nil ? "添加提供商" : "编辑服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.foregroundStyle(.dsLightInk)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        env.upsertProvider(draft)
                        dismiss()
                    }
                    .font(.system(size: 15, weight: .bold))
                    .disabled(!canSave)
                }
            }
        }
    }

    // MARK: 提供商选择网格（稿 pvgrid：图标 + 名称，选中高亮）

    private var providerGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选择提供商")
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(.dsLightInk)
            Text("选择媒体服务器或存储位置")
                .font(.system(size: 12.5))
                .foregroundStyle(.dsLightInk2)
                .padding(.bottom, 4)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                ForEach(ProviderKind.allCases, id: \.self) { k in
                    providerCell(k)
                }
            }
        }
        .padding(.bottom, 6)
    }

    private func providerCell(_ k: ProviderKind) -> some View {
        Button {
            withAnimation(.dsSpring) {
                kind = k
                testResult = nil
            }
        } label: {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(kindColor(k).opacity(kind == k ? 1 : 0.12))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: k.iconName)
                            .font(.system(size: 19))
                            .foregroundStyle(kind == k ? .white : kindColor(k))
                    )
                Text(k.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(kind == k ? .dsLightInk : .dsLightInk2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.dsLightCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(kind == k ? Color.dsAccent : Color.dsLightBorder, lineWidth: kind == k ? 2 : 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func kindColor(_ k: ProviderKind) -> Color {
        switch k {
        case .emby: return Color(red: 0.32, green: 0.69, blue: 0.26)
        case .jellyfin: return Color(red: 0.48, green: 0.35, blue: 0.91)
        case .alist: return Color(red: 0.23, green: 0.51, blue: 0.96)
        case .webdav: return Color(red: 0.91, green: 0.57, blue: 0.18)
        }
    }

    // MARK: 表单（白色圆角卡片字段）

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            fieldRow(title: "显示名（可选）", text: $name, placeholder: defaultName, secure: false, urlKeyboard: false)
            fieldRow(title: "服务器地址", text: $serverURL,
                     placeholder: kind == .webdav || kind == .alist ? "http://nas:5244" : "http://nas:8096",
                     secure: false, urlKeyboard: true)
            if kind == .webdav || kind == .alist {
                fieldRow(title: "起始目录（可选）", text: $rootPath, placeholder: "/媒体库", secure: false, urlKeyboard: false)
            }
            fieldRow(title: "账号", text: $username, placeholder: "用户名（匿名访问可留空）", secure: false, urlKeyboard: false)
            fieldRow(title: "密码", text: $password, placeholder: "密码", secure: true, urlKeyboard: false)
        }
    }

    // MARK: 测试连接

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await test() }
            } label: {
                HStack {
                    if isTesting { ProgressView().tint(.white) }
                    Image(systemName: "bolt.horizontal.circle")
                    Text(isTesting ? "测试中…" : "测试连接")
                }
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Capsule().fill(Color.dsAccent))
            }
            .disabled(!canSave || isTesting)

            if let testResult {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: testFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    Text(testResult).font(.system(size: 12.5))
                }
                .foregroundStyle(testFailed ? Color(red: 0.85, green: 0.47, blue: 0.05) : .green)
                .padding(.horizontal, 4)
            }
        }
    }

    private func test() async {
        isTesting = true
        testResult = nil
        defer { isTesting = false }
        do {
            testResult = try await ProviderFactory.make(draft).testConnection()
            testFailed = false
        } catch {
            if let pe = error as? ProviderError, case .badResponse(let m) = pe {
                testResult = m
            } else if let urlErr = error as? URLError {
                // 常见根因直说：地址/端口不对、服务器没开、自签名证书
                let hint: String
                switch urlErr.code {
                case .cannotConnectToHost, .cannotFindHost, .timedOut:
                    hint = "连不上服务器，检查地址端口是否正确、设备是否在同一网络"
                case .notConnectedToInternet:
                    hint = "设备当前没有可用网络"
                case .serverCertificateUntrusted, .secureConnectionFailed:
                    hint = "HTTPS 证书不受信任（自签名证书已放行，检查服务器配置）"
                case .httpTooManyRedirects, .badURL:
                    hint = "服务器地址格式不对"
                default:
                    hint = urlErr.localizedDescription
                }
                testResult = hint
            } else {
                testResult = "连接失败：\(String(describing: error))"
            }
            testFailed = true
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            env.removeProvider(existing!.id)
            dismiss()
        } label: {
            Text("删除此服务器")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.dsLightCard))
        }
        .buttonStyle(.plain)
    }

    private func fieldRow(title: String, text: Binding<String>, placeholder: String, secure: Bool,
                          urlKeyboard: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.dsLightInk2)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .font(.system(size: 15))
            .foregroundStyle(.dsLightInk)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(urlKeyboard ? .URL : .default)
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 13)
                    .fill(Color.dsLightCard)
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.dsLightBorder, lineWidth: 1))
            )
        }
    }
}
