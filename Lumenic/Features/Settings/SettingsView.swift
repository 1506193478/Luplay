import SwiftUI

/// 设置页（账号/片源/播放/弹幕分区；片源管理接入真实配置）
struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var editTarget: ProviderConfig?
    @State private var showAdd = false
    @State private var showSecrets = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                Text("设置")
                    .font(.dsTitle)
                    .foregroundStyle(.dsInk)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                group("账号与同步", items: [
                    ("icloud", "iCloud 同步", "开启后进度/设置多设备同步"),
                    ("person.crop.circle", "登录账号", "未登录"),
                ])

                providerSection

                group("播放", items: [
                    ("play.circle", "默认内核", "自动（按片源选择）"),
                    ("4k.tv.hfill", "解码", "视频工具箱硬解"),
                ])
                secretsSection
                Color.clear.frame(height: 120)
            }
        }
        .background(Color.dsPage.ignoresSafeArea())
        .sheet(item: $editTarget) { config in
            ProviderEditView(existing: config)
        }
        .sheet(isPresented: $showAdd) {
            ProviderEditView(existing: nil)
        }
        .sheet(isPresented: $showSecrets) {
            SecretsEditView()
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
                                Text(DandanplayConfig.isConfigured
                                     ? "已配置 AppId：\(DandanplayConfig.appId)"
                                     : "未配置 · 弹弹play 开放平台申请")
                                    .font(.dsCaption).foregroundStyle(.dsInk2)
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
                                Text(env.tmdb.isConfigured ? "已配置 · 标题归一化与海报刮削生效"
                                                           : "未配置 · 聚合搜索退化为标题归一")
                                    .font(.dsCaption).foregroundStyle(.dsInk2)
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

    @ViewBuilder
    private func group(_ title: String, items: [(String, String, String)]) -> some View {        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.dsInk2)
                .padding(.horizontal, 6)
            GlassSurface(shape: .rounded(16)) {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.1.1) { i, item in
                        HStack(spacing: 12) {
                            Image(systemName: item.0)
                                .font(.system(size: 15))
                                .foregroundStyle(.dsInk2)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.1).font(.system(size: 15, weight: .medium)).foregroundStyle(.dsInk)
                                Text(item.2).font(.dsCaption).foregroundStyle(.dsInk2)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.dsInk3)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        if i < items.count - 1 {
                            Divider().overlay(Color.dsGlassBorder).padding(.leading, 52)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - 服务密钥编辑（弹弹play / TMDB；保存进 Keychain）

struct SecretsEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var dandanAppId = DandanplayConfig.appId
    @State private var dandanSecret = DandanplayConfig.appSecret
    @State private var tmdbKey = ""    // 只显示占位，不回显真实值
    @State private var saved = false

    var body: some View {
        NavigationView {
            Form {
                Section("弹弹play（弹幕自动匹配签名）") {
                    TextField("AppId", text: $dandanAppId)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    SecureField("AppSecret", text: $dandanSecret)
                }
                Section("TMDB（标题归一化 + 海报刮削）") {
                    if TMDBService().isConfigured {
                        Label("已配置，填入新值可覆盖", systemImage: "checkmark.circle")
                            .font(.dsCaption).foregroundStyle(.green)
                    }
                    TextField("API Key（v3 auth）", text: $tmdbKey)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                Section {
                    Button("保存到 Keychain") {
                        DandanplayConfig.save(appId: dandanAppId, secret: dandanSecret)
                        if !tmdbKey.isEmpty {
                            TMDBService().saveApiKey(tmdbKey)
                        }
                        saved = true
                    }
                    if saved {
                        Label("已保存", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.dsCaption)
                    }
                }
                Section("说明") {
                    Text("密钥保存在 iOS Keychain，不会写入 UserDefaults 或代码仓库。弹弹play 在 app.dandanplay.net 开放平台注册申请；TMDB Key 在 themoviedb.org 设置页 API 获取。")
                        .font(.dsCaption).foregroundStyle(.dsInk2)
                }
            }
            .navigationTitle("服务密钥")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
