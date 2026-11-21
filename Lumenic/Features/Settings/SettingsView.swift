import SwiftUI

/// 设置页（账号/片源/播放/弹幕分区；片源管理接入真实配置）
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
            VStack(alignment: .leading, spacing: 18) {
                Text("设置")
                    .font(.dsTitle)
                    .foregroundStyle(.dsInk)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                syncSection

                providerSection

                playbackSection
                secretsSection
                Color.clear.frame(height: 120)
            }
        }
        .background(Color.dsPage.ignoresSafeArea())
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

    // MARK: 账号与同步（iCloud 真开关：进度/收藏/跳过标记 CloudKit 同步）

    private var syncSection: some View {
        SyncSectionView(cloudSync: env.cloudSync)
    }

    // MARK: 播放设置（默认内核真实可切换，EngineSelector 读取覆盖）

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("播放").font(.system(size: 15, weight: .semibold)).foregroundStyle(.dsInk2)
                .padding(.horizontal, 6)
            GlassSurface(shape: .rounded(16)) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: "play.circle")
                            .font(.system(size: 15)).foregroundStyle(.dsInk2).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("默认内核").font(.system(size: 15, weight: .medium)).foregroundStyle(.dsInk)
                            Text(engineOverrideHint)
                                .font(.dsCaption).foregroundStyle(.dsInk2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Picker("默认内核", selection: $engineOverride) {
                            Text("自动").tag("auto")
                            Text("AVPlayer").tag("avplayer")
                            Text("mpv").tag("mpv")
                        }
                        .pickerStyle(.menu)
                        .tint(Color.accentColor)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    Divider().overlay(Color.dsGlassBorder).padding(.leading, 52)
                    HStack(spacing: 12) {
                        Image(systemName: "4k.tv.hfill")
                            .font(.system(size: 15)).foregroundStyle(.dsInk2).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("解码").font(.system(size: 15, weight: .medium)).foregroundStyle(.dsInk)
                            Text("视频工具箱硬解")
                                .font(.dsCaption).foregroundStyle(.dsInk2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
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

    // MARK: 密钥管理（弹弹play 签名 / TMDB API Key，均存 Keychain）

    private var secretsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("服务密钥").font(.system(size: 15, weight: .semibold)).foregroundStyle(.dsInk2)
                .padding(.horizontal, 6)
            GlassSurface(shape: .rounded(16)) {
                VStack(spacing: 0) {
                    Button { showSecrets = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 15)).foregroundStyle(.dsInk2).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("弹弹play API")
                                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.dsInk)
                                Text(dandanConfigured
                                     ? "已配置 AppId：\(DandanplayConfig.appId)"
                                     : "未配置 · 弹弹play 开放平台申请")
                                    .font(.dsCaption).foregroundStyle(.dsInk2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.dsInk3)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(Color.dsGlassBorder).padding(.leading, 52)
                    Button { showSecrets = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "film.stack")
                                .font(.system(size: 15)).foregroundStyle(.dsInk2).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("TMDB API Key")
                                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.dsInk)
                                Text(tmdbConfigured ? "已配置 · 标题归一化与海报刮削生效"
                                                    : "未配置 · 聚合搜索退化为标题归一")
                                    .font(.dsCaption).foregroundStyle(.dsInk2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.dsInk3)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: 片源管理（动态：已配置服务器 + 添加入口）

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("片源管理").font(.system(size: 15, weight: .semibold)).foregroundStyle(.dsInk2)
                .padding(.horizontal, 6)
            GlassSurface(shape: .rounded(16)) {
                VStack(spacing: 0) {
                    if env.providerStore.configs.isEmpty {
                        Text("尚未配置片源，先添加 Emby / Alist / WebDAV 服务器")
                            .font(.dsCaption).foregroundStyle(.dsInk3)
                            .padding(.horizontal, 14).padding(.vertical, 14)
                    }
                    ForEach(env.providerStore.configs) { config in
                        Button { editTarget = config } label: {
                            HStack(spacing: 12) {
                                Image(systemName: config.kind.iconName)
                                    .font(.system(size: 15))
                                    .foregroundStyle(.dsInk2)
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(config.displayName)
                                        .font(.system(size: 15, weight: .medium)).foregroundStyle(.dsInk)
                                    Text(config.serverURL).font(.dsCaption).foregroundStyle(.dsInk2)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12)).foregroundStyle(.dsInk3)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Color.dsGlassBorder).padding(.leading, 52)
                    }
                    Button { showAdd = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 26)
                            Text("添加片源")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - iCloud 同步区块（直接观察 CloudSyncService，状态实时刷新）

private struct SyncSectionView: View {
    @ObservedObject var cloudSync: CloudSyncService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("账号与同步").font(.system(size: 15, weight: .semibold)).foregroundStyle(.dsInk2)
                .padding(.horizontal, 6)
            GlassSurface(shape: .rounded(16)) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: "icloud")
                            .font(.system(size: 15)).foregroundStyle(.dsInk2).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("iCloud 同步").font(.system(size: 15, weight: .medium)).foregroundStyle(.dsInk)
                            Text(cloudSync.statusText)
                                .font(.dsCaption).foregroundStyle(.dsInk2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Toggle("", isOn: $cloudSync.enabled)
                            .labelsHidden()
                            .tint(Color.accentColor)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)

                    Divider().overlay(Color.dsGlassBorder).padding(.leading, 52)

                    Button {
                        Task { await cloudSync.syncNow() }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 15)).foregroundStyle(.dsInk2).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("立即同步")
                                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.dsInk)
                                Text("播放进度 · 收藏 · 弹幕跳过设置")
                                    .font(.dsCaption).foregroundStyle(.dsInk2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if cloudSync.syncing {
                                ProgressView().tint(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .disabled(!cloudSync.enabled)
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - 服务密钥编辑（弹弹play / TMDB；保存进 Keychain；玻璃风格与片源编辑页一致）

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
                                .font(.dsCaption).foregroundStyle(.green)
                        }
                        fieldRow(title: "API Key（v3 auth）", text: $tmdbKey,
                                 placeholder: tmdbConfigured ? "留空保持现有配置" : "themoviedb.org 获取", secure: true)
                    }

                    if saved {
                        Label("已保存到 Keychain", systemImage: "checkmark.circle.fill")
                            .font(.dsCaption).foregroundStyle(.green)
                            .padding(.horizontal, 4)
                    }

                    Text("密钥保存在 iOS Keychain，不会写入 UserDefaults 或代码仓库。弹弹play 在 app.dandanplay.net 开放平台注册申请；TMDB Key 在 themoviedb.org 设置页 API 获取。")
                        .font(.dsCaption).foregroundStyle(.dsInk2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                    Color.clear.frame(height: 30)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
            .background(Color.dsPage.ignoresSafeArea())
            .navigationTitle("服务密钥")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
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
        Text(text).font(.system(size: 14, weight: .semibold)).foregroundStyle(.dsInk2)
    }

    private func fieldRow(title: String, text: Binding<String>, placeholder: String, secure: Bool) -> some View {
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
            }
            .frame(height: 44)
            .padding(.horizontal, 12)
        }
    }
}
