import SwiftUI

/// 设置页（账号/片源/播放/弹幕分区；片源管理接入真实配置）
struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var editTarget: ProviderConfig?
    @State private var showAdd = false

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
                group("弹幕", items: [
                    ("key.fill", "弹弹play API",
                     DandanplayConfig.isConfigured ? "已配置 AppId：\(DandanplayConfig.appId)" : "未配置 · 点击查看申请指引"),
                ])
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
    private func group(_ title: String, items: [(String, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
