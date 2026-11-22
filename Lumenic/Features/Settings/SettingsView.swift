import SwiftUI

/// 设置中心（对标稿 v-set：浅色 Infuse 风，彩色图标 chip + 白色圆角卡片分组）
struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var editTarget: ProviderConfig?
    @State private var showAdd = false
    @State private var showSecrets = false
    @State private var engineOverride = UserDefaults.standard.string(forKey: "engine.override") ?? "auto"
    // 密钥状态缓存：Keychain 是同步 IO，不在 body 渲染路径反复读
    @State private var dandanConfigured = false
    @State private var tmdbConfigured = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                Text("设置")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(.dsLightInk)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                syncSection
                providerSection
                playbackSection
                secretsSection
                Color.clear.frame(height: 120)
            }
        }
        .background(Color.dsLightPage.ignoresSafeArea())
        .onChange(of: engineOverride) { v in
            UserDefaults.standard.set(v, forKey: "engine.override")
        }
        .sheet(item: $editTarget) { config in
            ProviderEditView(existing: config)
        }
        .sheet(isPresented: $showAdd) {
            ProviderEditView(existing: nil)
        }
        .sheet(isPresented: $showSecrets, onDismiss: { refreshSecretStatus() }) {
            SecretsEditView()
        }
        .onAppear { refreshSecretStatus() }
    }

    private func refreshSecretStatus() {
        dandanConfigured = DandanplayConfig.isConfigured
        tmdbConfigured = env.tmdb.isConfigured
    }

    // MARK: 分区标题

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.dsLightInk2)
            .padding(.horizontal, 8)
    }

    // MARK: 账号与同步（iCloud 真开关）

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("账号与同步")
            lightCard {
                lightRow(icon: "icloud", tint: Color(red: 0.23, green: 0.51, blue: 0.96),
                         title: "iCloud 同步", subtitle: env.cloudSync.statusText) {
                    Toggle("", isOn: Binding(
                        get: { env.cloudSync.enabled },
                        set: { env.cloudSync.enabled = $0 }))
                        .labelsHidden()
                        .tint(Color.dsAccent)
                }
                cardDivider
                lightRow(icon: "arrow.triangle.2.circlepath", tint: Color(red: 0.35, green: 0.62, blue: 0.32),
                         title: "立即同步", subtitle: "播放进度 · 收藏 · 弹幕跳过设置") {
                    if env.cloudSync.syncing { ProgressView().tint(Color.dsAccent) }
                }
                .onTapGesture { Task { await env.cloudSync.syncNow() } }
                .disabled(!env.cloudSync.enabled)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: 片源管理（已配置服务器 + 添加提供商入口）

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("片源管理")
            lightCard {
                if env.providerStore.configs.isEmpty {
                    Text("尚未添加媒体服务器，点击下方「添加提供商」开始")
                        .font(.system(size: 13))
                        .foregroundStyle(.dsLightInk2)
                        .padding(.horizontal, 14).padding(.vertical, 14)
                }
                ForEach(env.providerStore.configs) { config in
                    Button { editTarget = config } label: {
                        lightRow(icon: config.kind.iconName,
                                 tint: kindTint(config.kind),
                                 title: config.displayName,
                                 subtitle: config.serverURL) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12))
                                .foregroundStyle(.dsLightInk2.opacity(0.5))
                        }
                    }
                    .buttonStyle(.plain)
                    if config.id != env.providerStore.configs.last?.id { cardDivider }
                }
                if !env.providerStore.configs.isEmpty { cardDivider }
                Button { showAdd = true } label: {
                    lightRow(icon: "plus", tint: Color.dsAccent,
                             title: "添加提供商", subtitle: "Emby / Jellyfin / Alist / WebDAV") {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundStyle(.dsLightInk2.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    private func kindTint(_ k: ProviderKind) -> Color {
        switch k {
        case .emby: return Color(red: 0.32, green: 0.69, blue: 0.26)
        case .jellyfin: return Color(red: 0.48, green: 0.35, blue: 0.91)
        case .alist: return Color(red: 0.23, green: 0.51, blue: 0.96)
        case .webdav: return Color(red: 0.91, green: 0.57, blue: 0.18)
        }
    }

    // MARK: 播放设置（默认内核真实可切换，EngineSelector 读取覆盖）

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("播放")
            lightCard {
                lightRow(icon: "play.circle", tint: Color(red: 0.95, green: 0.56, blue: 0.16),
                         title: "默认内核", subtitle: engineOverrideHint) {
                    Picker("默认内核", selection: $engineOverride) {
                        Text("自动").tag("auto")
                        Text("AVPlayer").tag("avplayer")
                        Text("mpv").tag("mpv")
                    }
                    .pickerStyle(.menu)
                    .tint(Color.dsAccent)
                }
                cardDivider
                lightRow(icon: "4k.tv.hfill", tint: Color(red: 0.55, green: 0.35, blue: 0.85),
                         title: "解码", subtitle: "视频工具箱硬解") {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundStyle(.dsLightInk2.opacity(0.3))
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var engineOverrideHint: String {
        switch engineOverride {
        case "avplayer": return "总是 AVPlayer（HLS / 杜比视界优先）"
        case "mpv": return "总是 mpv（MKV / ASS 特效字幕优先）"
        default: return "自动（按片源选择）"
        }
    }

    // MARK: 服务密钥（弹弹play / TMDB，均存 Keychain）

    private var secretsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("服务密钥")
            lightCard {
                Button { showSecrets = true } label: {
                    lightRow(icon: "key.fill", tint: Color(red: 0.85, green: 0.47, blue: 0.05),
                             title: "弹弹play API",
                             subtitle: dandanConfigured ? "已配置 AppId：\(DandanplayConfig.appId)"
                                                        : "未配置 · 弹弹play 开放平台申请") {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundStyle(.dsLightInk2.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)
                cardDivider
                Button { showSecrets = true } label: {
                    lightRow(icon: "film.stack", tint: Color(red: 0.20, green: 0.62, blue: 0.62),
                             title: "TMDB API Key",
                             subtitle: tmdbConfigured ? "已配置 · 海报刮削与标题归一化生效"
                                                      : "未配置 · 文件型片源将没有海报") {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundStyle(.dsLightInk2.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: 浅色卡片部件

    private func lightCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.dsLightCard)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.dsLightBorder, lineWidth: 1))
            )
    }

    private var cardDivider: some View {
        Divider()
            .overlay(Color.dsLightBorder)
            .padding(.leading, 56)
    }

    private func lightRow<Trailing: View>(icon: String, tint: Color, title: String,
                                          subtitle: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(tint)
                .frame(width: 28, height: 28)
                .overlay(Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.dsLightInk)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.dsLightInk2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - 服务密钥编辑（弹弹play / TMDB；保存进 Keychain；浅色风与设置中心一致）

struct SecretsEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var dandanAppId = DandanplayConfig.appId
    @State private var dandanSecret = DandanplayConfig.appSecret
    @State private var tmdbKey = ""    // 只显示占位，不回显真实值
    @State private var tmdbConfigured = false
    @State private var saved = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("弹弹play · 弹幕自动匹配签名")
                        fieldRow(title: "AppId", text: $dandanAppId,
                                 placeholder: "app.dandanplay.net 开放平台 AppId", secure: false)
                        fieldRow(title: "AppSecret", text: $dandanSecret,
                                 placeholder: "开放平台 AppSecret", secure: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("TMDB · 标题归一化 + 海报刮削")
                        if tmdbConfigured {
                            Label("已配置，填入新值可覆盖", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 12.5)).foregroundStyle(.green)
                        }
                        fieldRow(title: "API Key（v3 auth）", text: $tmdbKey,
                                 placeholder: tmdbConfigured ? "留空保持现有配置" : "themoviedb.org 获取", secure: true)
                    }

                    if saved {
                        Label("已保存到 Keychain", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12.5)).foregroundStyle(.green)
                            .padding(.horizontal, 4)
                    }

                    Text("密钥保存在 iOS Keychain，不会写入 UserDefaults 或代码仓库。弹弹play 在 app.dandanplay.net 开放平台注册申请；TMDB Key 在 themoviedb.org 设置页 API 获取。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.dsLightInk2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                    Color.clear.frame(height: 30)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
            .background(Color.dsLightPage.ignoresSafeArea())
            .navigationTitle("服务密钥")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.foregroundStyle(.dsLightInk)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .font(.system(size: 15, weight: .bold))
                }
            }
            .onAppear { tmdbConfigured = TMDBService().isConfigured }
        }
    }

    private func save() {
        DandanplayConfig.save(appId: dandanAppId, secret: dandanSecret)
        if !tmdbKey.isEmpty {
            TMDBService().saveApiKey(tmdbKey)
            tmdbConfigured = true
            tmdbKey = ""
        }
        saved = true
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 14, weight: .bold)).foregroundStyle(.dsLightInk2)
    }

    private func fieldRow(title: String, text: Binding<String>, placeholder: String, secure: Bool) -> some View {
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
