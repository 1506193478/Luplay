import SwiftUI

/// 设置中心（对标稿 v-set：浅色 Infuse 风，彩色图标 chip + 白色圆角卡片分组）
struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var editTarget: ProviderConfig?
    @State private var showAdd = false
    @State private var showSecrets = false
    @State private var engineOverride = UserDefaults.standard.string(forKey: "engine.override") ?? "auto"
    // 子页切换（iOS 16 无 NavigationStack，模式同 LibraryView：@State 枚举 + ZStack）
    @State private var subPage: SettingsSubPage? = nil
    // 密钥状态缓存：Keychain 是同步 IO，不在 body 渲染路径反复读
    @State private var dandanConfigured = false
    @State private var tmdbConfigured = false

    var body: some View {
        ZStack {
            if let page = subPage {
                subPageContent(page)
                    .transition(.opacity)
            } else {
                mainShell
                    .transition(.opacity)
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
        .onAppear {
            refreshSecretStatus()
            // 子页内可能改过引擎覆盖，回主壳时同步显示
            engineOverride = UserDefaults.standard.string(forKey: "engine.override") ?? "auto"
        }
    }

    // MARK: 主壳（稿 v-set）

    private var mainShell: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                Text("设置")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(.dsLightInk)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                appSection
                syncSection
                providerSection
                playbackSection
                historySection
                secretsSection
                aboutSection
                Color.clear.frame(height: 120)
            }
        }
    }

    /// 子页路由：switch 拆小，避免 WMO 下大 body 泛型推断
    @ViewBuilder
    private func subPageContent(_ page: SettingsSubPage) -> some View {
        switch page {
        case .app:
            AppSettingsPage(onBack: { closeSub() })
        case .playback:
            // 弹幕设置 / 弹幕 API 入口并入播放子页底部（稿 spDanm / dmApi 同层）
            PlaybackSettingsPage(onBack: { closeSub() },
                                 onOpenDanmaku: { withAnimation(.dsEaseOut) { subPage = .danmaku } },
                                 onOpenDanmakuAPI: { withAnimation(.dsEaseOut) { subPage = .danmakuAPI } })
        case .danmaku:
            DanmakuSettingsPage(onBack: { closeSub() },
                                onOpenAPI: { withAnimation(.dsEaseOut) { subPage = .danmakuAPI } })
        case .danmakuAPI:
            DanmakuAPIPage(onBack: { closeSub() })
        case .gestures:
            GestureHelpPage(onBack: { closeSub() })
        case .ui:
            InterfaceSettingsPage(onBack: { closeSub() },
                                  onOpenButtons: { withAnimation(.dsEaseOut) { subPage = .playerButtons } })
        case .playerButtons:
            PlayerButtonsPage(onBack: { closeSub() })
        case .history:
            HistorySettingsPage(onBack: { closeSub() })
        case .about:
            AboutPage(onBack: { closeSub() })
        }
    }

    private func openSub(_ page: SettingsSubPage) {
        withAnimation(.dsEaseOut) { subPage = page }
    }

    private func closeSub() {
        withAnimation(.dsEaseOut) { subPage = nil }
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

    // MARK: 应用（稿 SETMODS[0]：应用 · 外观与触感）

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("应用")
            lightCard {
                Button { openSub(.app) } label: {
                    lightRow(icon: "square.grid.2x2", tint: Color(red: 0.23, green: 0.51, blue: 0.96),
                             title: "应用", subtitle: "外观与触感") {
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

    // MARK: 观看记录（稿 SETMODS[5]：观看记录 · 由服务器记录）

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("观看记录")
            lightCard {
                Button { openSub(.history) } label: {
                    lightRow(icon: "clock", tint: Color(red: 0.35, green: 0.62, blue: 0.32),
                             title: "观看记录", subtitle: "由服务器记录") {
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
                Button { openSub(.playback) } label: {
                    lightRow(icon: "4k.tv.hfill", tint: Color(red: 0.55, green: 0.35, blue: 0.85),
                             title: "播放", subtitle: "跳转、缓存与解码") {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundStyle(.dsLightInk2.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)
                cardDivider
                Button { openSub(.gestures) } label: {
                    lightRow(icon: "hand.draw", tint: Color(red: 0.91, green: 0.57, blue: 0.18),
                             title: "手势", subtitle: "双击、滑动与长按") {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundStyle(.dsLightInk2.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)
                cardDivider
                Button { openSub(.ui) } label: {
                    lightRow(icon: "rectangle.split.2x1", tint: Color(red: 0.20, green: 0.62, blue: 0.62),
                             title: "界面", subtitle: "播放器显示") {
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

    // MARK: 关于（版本 / 开源致谢 / 免责声明）

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("关于")
            lightCard {
                Button { openSub(.about) } label: {
                    lightRow(icon: "info.circle", tint: Color(red: 0.23, green: 0.51, blue: 0.96),
                             title: "关于 Luplay", subtitle: "版本 · 开源致谢 · 免责声明") {
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

// MARK: - 设置子页（对标稿 lpage/lnav：浅色二级页 · ‹ 返回 + 居中标题）
// 导航模式同 LibraryView：@State 枚举 + ZStack 切换（iOS 16，不依赖 NavigationStack）。
// 子页全部拆独立 struct，避免 WMO 泛型推断风险。

/// 设置子页路由枚举
private enum SettingsSubPage {
    case app, playback, danmaku, danmakuAPI, gestures, ui, playerButtons, history, about
}

/// 浅色二级页导航条（稿 lnav/lback：‹ 返回 + 居中标题）
private struct SettingsNavBar: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.dsLightInk)
                .lineLimit(1)
            HStack(spacing: 0) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.dsAccent)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }
}

/// 子页页头（稿 sttl/ssub：大标题 + 说明）
private struct SubPageHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 26, weight: .heavy))
                .foregroundStyle(.dsLightInk)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.dsLightInk2)
            }
        }
    }
}

/// 子页分组标题
private struct SubPageSectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.dsLightInk2)
            .padding(.horizontal, 8)
    }
}

/// 子页彩色图标 chip（与主壳 lightRow 的 chip 同款）
private struct SubPageChip: View {
    let icon: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(tint)
            .frame(width: 28, height: 28)
            .overlay(Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white))
    }
}

/// 子页白卡片（与主壳 lightCard 同款）
private struct SubPageCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.dsLightCard)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.dsLightBorder, lineWidth: 1))
            )
    }
}

/// 子页通用行（subtitle 可空；trailing 自定义）
private struct SubPageRow<Trailing: View>: View {
    let icon: String
    let tint: Color
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            SubPageChip(icon: icon, tint: tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.dsLightInk)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.dsLightInk2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// 子页静态说明行（无交互；右侧可选灰色说明值）
private struct SubPageInfoRow: View {
    let icon: String
    let tint: Color
    let title: String
    var subtitle: String? = nil
    var value: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            SubPageChip(icon: icon, tint: tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.dsLightInk)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.dsLightInk2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer()
            if let value {
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.dsLightInk2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - 播放设置子页（稿 v-setplay 精选项）

/// 播放设置子页（稿 v-setplay）：引擎 / 硬解 / 启动续播 / 倍速记忆 + 弹幕入口，全部真实持久化
private struct PlaybackSettingsPage: View {
    let onBack: () -> Void
    // 弹幕设置 / 弹幕 API 已并入本页底部入口（主壳不再单列）
    let onOpenDanmaku: () -> Void
    let onOpenDanmakuAPI: () -> Void

    // 引擎覆盖：PlayerEngine.swift 已读取 "engine.override"，真实生效
    @AppStorage("engine.override") private var engine = "auto"
    // TODO: MPVEngine 目前写死 videotoolbox 硬解（MPVEngine.swift hwdec），待播放器接入读取此开关
    @AppStorage("playback.hwdec") private var hwdec = true
    // TODO: 待播放器启动流程接入（打开 App 恢复进度前判断此开关）
    @AppStorage("playback.resumeOnLaunch") private var resumeOnLaunch = true
    // TODO: 待 SpeedPanel 接入（记住上次倍速，下个视频自动应用）
    @AppStorage("playback.rateMemory") private var rateMemory = true

    var body: some View {
        VStack(spacing: 0) {
            SettingsNavBar(title: "播放设置", onBack: onBack)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    SubPageHeader(title: "播放", subtitle: "跳转、缓存与解码")
                    SubPageCard {
                        SubPageRow(icon: "cpu", tint: Color(red: 0.23, green: 0.51, blue: 0.96),
                                   title: "播放引擎", subtitle: engineHint) {
                            Picker("播放引擎", selection: $engine) {
                                Text("自动").tag("auto")
                                Text("AVPlayer").tag("avplayer")
                                Text("mpv").tag("mpv")
                            }
                            .pickerStyle(.menu)
                            .tint(Color.dsAccent)
                        }
                        subDivider
                        SubPageRow(icon: "4k.tv.hfill", tint: Color(red: 0.55, green: 0.35, blue: 0.85),
                                   title: "硬件解码", subtitle: "视频工具箱硬解，更省电；关闭后软解，兼容性更好") {
                            Toggle("", isOn: $hwdec)
                                .labelsHidden()
                                .tint(Color.dsAccent)
                        }
                        subDivider
                        SubPageRow(icon: "clock.arrow.circlepath", tint: Color(red: 0.35, green: 0.62, blue: 0.32),
                                   title: "启动时续播", subtitle: "打开 App 自动恢复上次播放进度") {
                            Toggle("", isOn: $resumeOnLaunch)
                                .labelsHidden()
                                .tint(Color.dsAccent)
                        }
                        subDivider
                        SubPageRow(icon: "speedometer", tint: Color(red: 0.95, green: 0.56, blue: 0.16),
                                   title: "倍速记忆", subtitle: "记住上次选择的倍速，下个视频自动应用") {
                            Toggle("", isOn: $rateMemory)
                                .labelsHidden()
                                .tint(Color.dsAccent)
                        }
                    }

                    // 弹幕设置 / 弹幕 API 入口（稿 spDanm：并入播放子页底部）
                    SubPageSectionLabel(text: "弹幕")
                    SubPageCard {
                        Button(action: onOpenDanmaku) {
                            SubPageRow(icon: "text.bubble", tint: Color(red: 0.20, green: 0.62, blue: 0.62),
                                       title: "弹幕设置", subtitle: "显示 · 字号 · 不透明度 · 速度") {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.dsLightInk2.opacity(0.5))
                            }
                        }
                        .buttonStyle(.plain)
                        subDivider
                        Button(action: onOpenDanmakuAPI) {
                            SubPageRow(icon: "globe", tint: Color(red: 0.85, green: 0.47, blue: 0.05),
                                       title: "弹幕 API", subtitle: "弹弹play 密钥与接口") {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.dsLightInk2.opacity(0.5))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Color.clear.frame(height: 40)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
        }
        .background(Color.dsLightPage.ignoresSafeArea())
    }

    private var subDivider: some View {
        Divider().overlay(Color.dsLightBorder).padding(.leading, 56)
    }

    private var engineHint: String {
        switch engine {
        case "avplayer": return "总是 AVPlayer（HLS / 杜比视界优先）"
        case "mpv": return "总是 mpv（MKV / ASS 特效字幕优先）"
        default: return "自动（按片源选择）"
        }
    }
}

// MARK: - 弹幕设置子页（稿 v-danm 精选项）

/// 弹幕设置子页：显示开关 / 字号 / 不透明度 / 显示区域 / 速度 + API 入口
private struct DanmakuSettingsPage: View {
    let onBack: () -> Void
    let onOpenAPI: () -> Void

    // TODO: DanmakuEngine 的 isEnabled/fontSize/opacity/areaRatio 目前是内存态 @Published，
    // 待播放器接入：启动时用这些键初始化引擎；已持久化的仅 "luplay.danmaku.blocklist"（屏蔽词）
    @AppStorage("danmaku.enabled") private var enabled = true
    @AppStorage("danmaku.fontsize") private var fontSize = 18
    @AppStorage("danmaku.opacity") private var opacity = 90
    @AppStorage("danmaku.area") private var areaPercent = 50
    @AppStorage("danmaku.speed") private var speedPercent = 100

    var body: some View {
        VStack(spacing: 0) {
            SettingsNavBar(title: "弹幕设置", onBack: onBack)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    SubPageHeader(title: "弹幕", subtitle: "弹幕服务与显示")

                    SubPageSectionLabel(text: "弹幕")
                    SubPageCard {
                        SubPageRow(icon: "text.bubble", tint: Color(red: 0.20, green: 0.62, blue: 0.62),
                                   title: "播放时显示弹幕", subtitle: "关闭后播放器不再加载与渲染弹幕") {
                            Toggle("", isOn: $enabled)
                                .labelsHidden()
                                .tint(Color.dsAccent)
                        }
                    }

                    SubPageSectionLabel(text: "文字")
                    SubPageCard {
                        sliderRow(icon: "circle.lefthalf.filled", tint: Color(red: 0.95, green: 0.56, blue: 0.16),
                                  title: "不透明度", valueText: "\(opacity)%",
                                  value: Binding(get: { Double(opacity) }, set: { opacity = Int($0.rounded()) }),
                                  range: 10...100, step: 5)
                        subDivider
                        sliderRow(icon: "textformat.size", tint: Color(red: 0.23, green: 0.51, blue: 0.96),
                                  title: "字号", valueText: "\(fontSize) pt",
                                  value: Binding(get: { Double(fontSize) }, set: { fontSize = Int($0.rounded()) }),
                                  range: 12...42, step: 1)
                    }

                    SubPageSectionLabel(text: "布局与速度")
                    SubPageCard {
                        SubPageRow(icon: "rectangle.split.2x1", tint: Color(red: 0.55, green: 0.35, blue: 0.85),
                                   title: "显示区域", subtitle: "弹幕覆盖的画面高度") {
                            Picker("显示区域", selection: $areaPercent) {
                                Text("半屏").tag(50)
                                Text("全屏").tag(100)
                            }
                            .pickerStyle(.menu)
                            .tint(Color.dsAccent)
                        }
                        subDivider
                        sliderRow(icon: "hare", tint: Color(red: 0.35, green: 0.62, blue: 0.32),
                                  title: "速度", valueText: "\(speedPercent)%",
                                  value: Binding(get: { Double(speedPercent) }, set: { speedPercent = Int($0.rounded()) }),
                                  range: 50...200, step: 10)
                    }

                    SubPageSectionLabel(text: "弹幕服务")
                    SubPageCard {
                        Button(action: onOpenAPI) {
                            SubPageRow(icon: "globe", tint: Color(red: 0.85, green: 0.47, blue: 0.05),
                                       title: "弹幕 API", subtitle: "弹弹play 密钥与接口") {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.dsLightInk2.opacity(0.5))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Color.clear.frame(height: 40)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
        }
        .background(Color.dsLightPage.ignoresSafeArea())
    }

    private var subDivider: some View {
        Divider().overlay(Color.dsLightBorder).padding(.leading, 56)
    }

    /// 标题行 + 行内滑杆（稿 stepRow 的滑杆实现）
    private func sliderRow(icon: String, tint: Color, title: String, valueText: String,
                           value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(spacing: 0) {
            SubPageRow(icon: icon, tint: tint, title: title) {
                Text(valueText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dsAccent)
            }
            Slider(value: value, in: range, step: step)
                .tint(Color.dsAccent)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
        }
    }
}

// MARK: - 弹幕 API 子页（稿 v-dapi 最小实现：入口跳现有密钥编辑）

/// 弹幕 API 子页：弹弹play 配置状态 + 跳转 SecretsEditView 编辑（密钥仍在 Keychain）
private struct DanmakuAPIPage: View {
    let onBack: () -> Void
    @State private var showSecrets = false
    // Keychain 同步 IO，进页读一次即可
    @State private var configured = DandanplayConfig.isConfigured

    var body: some View {
        VStack(spacing: 0) {
            SettingsNavBar(title: "弹幕 API", onBack: onBack)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    SubPageHeader(title: "弹幕 API", subtitle: "弹弹play 开放平台签名")

                    SubPageCard {
                        Button { showSecrets = true } label: {
                            SubPageRow(icon: "key.fill", tint: Color(red: 0.85, green: 0.47, blue: 0.05),
                                       title: "弹弹play AppId / AppSecret",
                                       subtitle: configured ? "已配置 AppId：\(DandanplayConfig.appId)"
                                                            : "未配置 · 弹弹play 开放平台申请") {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.dsLightInk2.opacity(0.5))
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    Text("弹幕匹配调用弹弹play v2 接口，需要 AppId 与 AppSecret 签名；在 app.dandanplay.net 开放平台注册申请。密钥保存在 iOS Keychain，不会写入 UserDefaults 或代码仓库。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.dsLightInk2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                    Color.clear.frame(height: 40)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
        }
        .background(Color.dsLightPage.ignoresSafeArea())
        .sheet(isPresented: $showSecrets, onDismiss: { configured = DandanplayConfig.isConfigured }) {
            SecretsEditView()
        }
    }
}

// MARK: - 手势与按钮子页（稿 v-ges：静态说明）

/// 手势与按钮说明子页：静态说明列表（播放器手势暂未开放自定义）
private struct GestureHelpPage: View {
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SettingsNavBar(title: "手势与按钮", onBack: onBack)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    SubPageHeader(title: "手势", subtitle: "双击、滑动与长按")

                    SubPageSectionLabel(text: "横向滑动")
                    SubPageCard {
                        SubPageInfoRow(icon: "arrow.left.and.right", tint: Color(red: 0.23, green: 0.51, blue: 0.96),
                                       title: "拖动进度条", subtitle: "左右滑动快进 / 快退，下滑取消")
                    }

                    SubPageSectionLabel(text: "双击屏幕")
                    SubPageCard {
                        SubPageInfoRow(icon: "hand.tap", tint: Color(red: 0.35, green: 0.62, blue: 0.32),
                                       title: "左侧", value: "快退 10 秒")
                        subDivider
                        SubPageInfoRow(icon: "hand.tap", tint: Color(red: 0.35, green: 0.62, blue: 0.32),
                                       title: "中间", value: "播放 / 暂停")
                        subDivider
                        SubPageInfoRow(icon: "hand.tap", tint: Color(red: 0.35, green: 0.62, blue: 0.32),
                                       title: "右侧", value: "快进 10 秒")
                    }

                    SubPageSectionLabel(text: "纵向滑动")
                    SubPageCard {
                        SubPageInfoRow(icon: "sun.max", tint: Color(red: 0.95, green: 0.56, blue: 0.16),
                                       title: "左半屏", subtitle: "上下滑动调节亮度")
                        subDivider
                        SubPageInfoRow(icon: "speaker.wave.2", tint: Color(red: 0.20, green: 0.62, blue: 0.62),
                                       title: "右半屏", subtitle: "上下滑动调节音量")
                    }

                    SubPageSectionLabel(text: "长按")
                    SubPageCard {
                        SubPageInfoRow(icon: "speedometer", tint: Color(red: 0.55, green: 0.35, blue: 0.85),
                                       title: "滑动调速", subtitle: "按住后左右滑动临时调速，松开恢复原速")
                    }

                    SubPageSectionLabel(text: "其他")
                    SubPageCard {
                        SubPageInfoRow(icon: "plus.magnifyingglass", tint: Color(red: 0.91, green: 0.57, blue: 0.18),
                                       title: "双指缩放", subtitle: "在适应与填充之间切换画面比例")
                        subDivider
                        SubPageInfoRow(icon: "hand.draw", tint: Color(red: 0.23, green: 0.51, blue: 0.96),
                                       title: "单指拖动画面", subtitle: "在画面内移动缩放后的视频窗口")
                    }
                    Color.clear.frame(height: 40)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
        }
        .background(Color.dsLightPage.ignoresSafeArea())
    }

    private var subDivider: some View {
        Divider().overlay(Color.dsLightBorder).padding(.leading, 56)
    }
}

// MARK: - 关于子页

/// 关于子页：应用信息 / 版本号 / 开源致谢 / 免责声明（静态文本）
private struct AboutPage: View {
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SettingsNavBar(title: "关于", onBack: onBack)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    // 应用图标 + 名称 + 版本（稿 setfoot 风格的居中头部）
                    VStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 22)
                            .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.72, blue: 0.24),
                                                          Color(red: 0.95, green: 0.45, blue: 0.15)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 88, height: 88)
                            .overlay(Image(systemName: "play.fill")
                                .font(.system(size: 34, weight: .bold))
                                .foregroundStyle(.white))
                            .shadow(color: Color.black.opacity(0.12), radius: 12, y: 6)
                        Text("Luplay")
                            .font(.system(size: 22, weight: .heavy))
                            .foregroundStyle(.dsLightInk)
                        Text("版本 \(versionText)")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.dsLightInk2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)

                    SubPageSectionLabel(text: "开源致谢")
                    SubPageCard {
                        Text(acknowledgement)
                            .font(.system(size: 13))
                            .foregroundStyle(.dsLightInk2)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }

                    SubPageSectionLabel(text: "免责声明")
                    SubPageCard {
                        Text(disclaimer)
                            .font(.system(size: 13))
                            .foregroundStyle(.dsLightInk2)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    Color.clear.frame(height: 40)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
        }
        .background(Color.dsLightPage.ignoresSafeArea())
    }

    /// 版本号：CFBundleShortVersionString（CFBundleVersion）
    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    private var acknowledgement: String {
        "播放内核基于开源项目 mpv（含 FFmpeg / libass）构建，界面与弹幕渲染基于 SwiftUI 自研。感谢 mpv、FFmpeg、libass 及所有开源社区贡献者。"
    }

    private var disclaimer: String {
        "本应用是一款本地播放器工具，自身不提供、不存储、不传播任何影视内容；所有媒体与弹幕数据均来自用户自行配置的第三方服务。请遵守所在地区法律法规，仅用于获取合法授权的内容。使用第三方服务产生的数据与行为责任由用户自行承担。"
    }
}

// MARK: - 应用子页（稿 v-setapp：外观与触感）

/// 分段选项（稿 segb：图标 + 文字）
private struct SegmentOption: Identifiable {
    let value: String
    let icon: String
    let label: String
    var id: String { value }
}

/// 子页分段选择器（稿 segc：圆角容器内多选一）
private struct SubPageSegment: View {
    let options: [SegmentOption]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { opt in
                Button {
                    selection = opt.value
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: opt.icon)
                            .font(.system(size: 12, weight: .semibold))
                        Text(opt.label)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(selection == opt.value ? Color.dsAccent.opacity(0.14) : Color.clear)
                    )
                    .foregroundStyle(selection == opt.value ? Color.dsAccent : Color.dsLightInk2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.dsLightPage)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.dsLightBorder, lineWidth: 1))
        )
    }
}

/// 应用子页：外观模式 / 启动页 / 触感反馈，真实持久化（本版本仅存偏好，不接入主题引擎）
private struct AppSettingsPage: View {
    let onBack: () -> Void

    // 外观模式：跟随系统 / 浅色 / 深色（TODO: 待主题引擎接入后读取此键）
    @AppStorage("appearance.mode") private var appearanceMode = "system"
    // 启动页：首页 / 媒体库（TODO: 待根页签接入后读取此键）
    @AppStorage("launch.tab") private var launchTab = "home"
    // 触感反馈总开关（TODO: 待触感管理器接入后读取此键）
    @AppStorage("haptics.enabled") private var hapticsEnabled = true

    var body: some View {
        VStack(spacing: 0) {
            SettingsNavBar(title: "应用", onBack: onBack)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    SubPageHeader(title: "应用", subtitle: "外观与触感")

                    SubPageSectionLabel(text: "应用")
                    SubPageCard {
                        SubPageInfoRow(icon: "square.grid.2x2", tint: Color(red: 0.23, green: 0.51, blue: 0.96),
                                       title: "软件图标", subtitle: "暂未开放", value: "开发中")
                    }

                    SubPageSectionLabel(text: "外观")
                    SubPageCard {
                        SubPageSegment(options: Self.appearanceOptions, selection: $appearanceMode)
                            .padding(12)
                    }

                    SubPageSectionLabel(text: "启动时打开")
                    SubPageCard {
                        SubPageSegment(options: Self.launchOptions, selection: $launchTab)
                            .padding(12)
                    }

                    SubPageSectionLabel(text: "触感")
                    SubPageCard {
                        SubPageRow(icon: "waveform", tint: Color(red: 0.95, green: 0.56, blue: 0.16),
                                   title: "触感反馈", subtitle: "操作与播放控制时提供震动反馈") {
                            Toggle("", isOn: $hapticsEnabled)
                                .labelsHidden()
                                .tint(Color.dsAccent)
                        }
                    }
                    Color.clear.frame(height: 40)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
        }
        .background(Color.dsLightPage.ignoresSafeArea())
    }

    /// 外观选项（稿 saLook：跟随系统 / 浅色 / 深色）
    private static let appearanceOptions: [SegmentOption] = [
        SegmentOption(value: "system", icon: "circle.lefthalf.filled", label: "跟随系统"),
        SegmentOption(value: "light", icon: "sun.max", label: "浅色"),
        SegmentOption(value: "dark", icon: "moon", label: "深色"),
    ]

    /// 启动页选项（首页 / 媒体库）
    private static let launchOptions: [SegmentOption] = [
        SegmentOption(value: "home", icon: "house", label: "首页"),
        SegmentOption(value: "library", icon: "film.stack", label: "媒体库"),
    ]
}

// MARK: - 界面子页（稿 v-ui：播放器显示）

/// 界面子页：记住画面比例 + 播放器按钮入口
private struct InterfaceSettingsPage: View {
    let onBack: () -> Void
    let onOpenButtons: () -> Void

    // TODO: 待播放器接入（画面比例切换时写入/读取此键，跨视频沿用）
    @AppStorage("player.rememberAspect") private var rememberAspect = false

    var body: some View {
        VStack(spacing: 0) {
            SettingsNavBar(title: "界面", onBack: onBack)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    SubPageHeader(title: "界面", subtitle: "播放器显示")

                    SubPageSectionLabel(text: "播放器")
                    SubPageCard {
                        SubPageRow(icon: "arrow.up.left.and.arrow.down.right",
                                   tint: Color(red: 0.55, green: 0.35, blue: 0.85),
                                   title: "记住画面比例",
                                   subtitle: "播放器里切换的「铺满屏幕 / 完整画面」沿用到之后的视频；关闭时只对当前视频生效") {
                            Toggle("", isOn: $rememberAspect)
                                .labelsHidden()
                                .tint(Color.dsAccent)
                        }
                        subDivider
                        Button(action: onOpenButtons) {
                            SubPageRow(icon: "square.grid.2x2", tint: Color(red: 0.23, green: 0.51, blue: 0.96),
                                       title: "播放器按钮", subtitle: "顶栏 · 轮盘 · 底栏 · 更多菜单") {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.dsLightInk2.opacity(0.5))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Color.clear.frame(height: 40)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
        }
        .background(Color.dsLightPage.ignoresSafeArea())
    }

    private var subDivider: some View {
        Divider().overlay(Color.dsLightBorder).padding(.leading, 56)
    }
}

// MARK: - 播放器按钮子页（稿 v-btns：位置与顺序，本版本静态展示）

/// 播放器按钮子页：按稿 BTN 结构静态分组展示（顶栏 / 轮盘 / 底栏 / 更多菜单）
private struct PlayerButtonsPage: View {
    let onBack: () -> Void

    /// 按钮条目
    private struct ButtonItem: Identifiable {
        let icon: String
        let name: String
        let tint: Color
        var id: String { name }
    }

    /// 按钮分区（稿 BTNZ 顺序：顶栏 / 轮盘 / 底栏 / 更多菜单）
    private struct ButtonGroup: Identifiable {
        let zone: String
        let items: [ButtonItem]
        var id: String { zone }
    }

    // TODO: 拖拽排序与跨区移动待接入播放器后开放，当前为静态展示
    private static let groups: [ButtonGroup] = [
        ButtonGroup(zone: "顶栏", items: [
            ButtonItem(icon: "rectangle.on.rectangle", name: "画中画",
                       tint: Color(red: 0.23, green: 0.51, blue: 0.96)),
            ButtonItem(icon: "arrow.up.left.and.arrow.down.right", name: "画面比例",
                       tint: Color(red: 0.95, green: 0.56, blue: 0.16)),
        ]),
        ButtonGroup(zone: "轮盘", items: [
            ButtonItem(icon: "text.bubble", name: "字幕",
                       tint: Color(red: 0.20, green: 0.62, blue: 0.62)),
            ButtonItem(icon: "waveform", name: "音轨",
                       tint: Color(red: 0.35, green: 0.62, blue: 0.32)),
            ButtonItem(icon: "message", name: "弹幕",
                       tint: Color(red: 0.55, green: 0.35, blue: 0.85)),
            ButtonItem(icon: "shippingbox", name: "资源版本",
                       tint: Color(red: 0.91, green: 0.57, blue: 0.18)),
            ButtonItem(icon: "airplayvideo", name: "投屏",
                       tint: Color(red: 0.23, green: 0.51, blue: 0.96)),
        ]),
        ButtonGroup(zone: "底栏", items: [
            ButtonItem(icon: "arrow.clockwise", name: "旋转屏幕",
                       tint: Color(red: 0.95, green: 0.56, blue: 0.16)),
            ButtonItem(icon: "lock", name: "锁定手势",
                       tint: Color(red: 0.20, green: 0.62, blue: 0.62)),
        ]),
        ButtonGroup(zone: "更多菜单", items: [
            ButtonItem(icon: "forward.end", name: "片头片尾",
                       tint: Color(red: 0.55, green: 0.35, blue: 0.85)),
        ]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            SettingsNavBar(title: "播放器按钮", onBack: onBack)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    SubPageHeader(title: "播放器按钮", subtitle: "位置与顺序")
                    zoneSections
                    Text("TODO：拖拽排序与跨区移动待接入播放器后开放，当前为静态展示。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.dsLightInk2)
                        .padding(.horizontal, 8)
                    Color.clear.frame(height: 40)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
        }
        .background(Color.dsLightPage.ignoresSafeArea())
    }

    /// 按分区静态分组展示（行尾灰色值标注所属分区）
    @ViewBuilder
    private var zoneSections: some View {
        ForEach(Self.groups) { group in
            SubPageSectionLabel(text: group.zone)
            SubPageCard {
                ForEach(group.items) { item in
                    if item.id != group.items.first?.id {
                        Divider().overlay(Color.dsLightBorder).padding(.leading, 56)
                    }
                    SubPageInfoRow(icon: item.icon, tint: item.tint,
                                   title: item.name, value: group.zone)
                }
            }
        }
    }
}

// MARK: - 观看记录子页（稿 SETMODS[5]：由服务器记录）

/// 观看记录子页：说明文案 + 清除本地观看记录（AppDatabase 尚无清空 playback_progress 接口，按钮禁用待接入）
private struct HistorySettingsPage: View {
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SettingsNavBar(title: "观看记录", onBack: onBack)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    SubPageHeader(title: "观看记录", subtitle: "由服务器记录")

                    SubPageSectionLabel(text: "观看记录")
                    SubPageCard {
                        SubPageInfoRow(icon: "clock", tint: Color(red: 0.35, green: 0.62, blue: 0.32),
                                       title: "云端观看进度",
                                       subtitle: "观看进度由服务器记录，同一账号的设备间自动同步")
                    }

                    SubPageSectionLabel(text: "本地数据")
                    SubPageCard {
                        // TODO: AppDatabase 尚未提供清空 playback_progress 的接口，接入后启用按钮
                        Button { } label: {
                            SubPageRow(icon: "trash", tint: Color(red: 0.85, green: 0.30, blue: 0.25),
                                       title: "清除本地观看记录",
                                       subtitle: "删除本机保存的播放进度，不影响服务器记录") {
                                Text("暂不可用")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.dsLightInk2.opacity(0.5))
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(true)
                    }
                    Color.clear.frame(height: 40)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
        }
        .background(Color.dsLightPage.ignoresSafeArea())
    }
}
