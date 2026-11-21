import SwiftUI

/// 设置页骨架（账号/片源/播放/弹幕等分区，M4 起填充真实功能）
struct SettingsView: View {
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
                group("片源管理", items: [
                    ("server.rack", "Emby / Jellyfin", "已配置 2 个"),
                    ("externaldrive.connected.to.line.below", "WebDAV / Alist", "已配置 1 个"),
                ])
                group("播放", items: [
                    ("play.circle", "默认内核", "自动（按片源选择）"),
                    ("4k.tv.hfill", "解码", "视频工具箱硬解"),
                ])
                group("弹幕", items: [
                    ("key.fill", "弹弹play API", "未配置 · 点击查看申请指引"),
                ])
                Color.clear.frame(height: 120)
            }
        }
        .background(Color.dsPage.ignoresSafeArea())
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
