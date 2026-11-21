import SwiftUI

/// 片源录入/编辑（服务器地址 + 账号密码，Keychain 存储；支持保存前测试连接）
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

    /// 校验必须带 http/https 协议头且有主机名，防止 "nas:8096" 这类地址存进配置
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
                VStack(alignment: .leading, spacing: 14) {
                    kindPicker
                    fieldRow(title: "显示名（可选）", text: $name, placeholder: defaultName, secure: false, urlKeyboard: false)
                    fieldRow(title: "服务器地址", text: $serverURL,
                             placeholder: kind == .emby ? "http://nas:8096" : "http://nas:5244", secure: false, urlKeyboard: true)
                    fieldRow(title: "账号", text: $username, placeholder: "用户名", secure: false, urlKeyboard: false)
                    fieldRow(title: "密码", text: $password, placeholder: "密码", secure: true, urlKeyboard: false)
                    if kind == .webdav || kind == .alist {
                        fieldRow(title: "起始目录（可选）", text: $rootPath, placeholder: "/媒体库", secure: false, urlKeyboard: false)
                    }

                    testSection

                    if existing != nil {
                        Button(role: .destructive) {
                            env.removeProvider(existing!.id)
                            dismiss()
                        } label: {
                            Text("删除此片源")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(GlassSurface(shape: .rounded(14)) { Color.clear })
                        }
                    }
                    Color.clear.frame(height: 30)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
            .background(Color.dsPage.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(existing == nil ? "添加片源" : "编辑片源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        env.upsertProvider(draft)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("类型").font(.system(size: 14, weight: .semibold)).foregroundStyle(.dsInk2)
            HStack(spacing: 8) {
                ForEach(ProviderKind.allCases, id: \.self) { k in
                    Button {
                        kind = k
                        testResult = nil
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: k.iconName).font(.system(size: 16))
                            Text(k.title).font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(kind == k ? .white : .dsInk)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(kind == k ? Color.accentColor : Color.dsGlassBorder.opacity(0.6))
                        )
                    }
                }
            }
        }
    }

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
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(GlassSurface(shape: .rounded(14)) { Color.accentColor.opacity(0.85) })
            }
            .disabled(!canSave || isTesting)

            if let testResult {
                HStack(spacing: 6) {
                    Image(systemName: testFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    Text(testResult).font(.dsCaption)
                }
                .foregroundStyle(testFailed ? .orange : .green)
                .padding(.horizontal, 4)
            }
        }
    }

    private func test() async {
        isTesting = true
        testResult = nil
        defer { isTesting = false }
        do {
            let msg = try await ProviderFactory.make(draft).testConnection()
            testResult = msg
            testFailed = false
        } catch {
            testResult = (error as? ProviderError).map {
                if case .badResponse(let m) = $0 { return m }
                return "连接失败"
            } ?? "连接失败：\(String(describing: error))"
            testFailed = true
        }
    }

    private func fieldRow(title: String, text: Binding<String>, placeholder: String, secure: Bool,
                          urlKeyboard: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.dsInk2)
            GlassSurface(shape: .rounded(12), interactive: true) {
                Group {
                    if secure {
                        SecureField(placeholder, text: text)
                    } else {
                        TextField(placeholder, text: text)
                    }
                }
                .foregroundStyle(.dsInk)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(urlKeyboard ? .URL : .default)
            }
            .frame(height: 44)
            .padding(.horizontal, 12)
        }
    }
}
