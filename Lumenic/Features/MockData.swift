import SwiftUI

// MARK: - Mock 数据模型（M4 接入真实片源后由 SourceItem/TMDB 模型替代）

struct MockMedia: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let subtitle: String
    let score: Double?
    let episodeCount: Int?
    let gradient: [Color]

    static func g(_ a: Color, _ b: Color) -> [Color] { [a, b] }
}

struct MockPlayTarget: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let episode: String
    let badge: String // "4K" / "杜比视界"
    let bitrate: String
    let container: String
    let demoURL: URL   // M2 演示流（真实片源接入后由 SourceProvider 提供）
    let sources: [MockSource]
}

struct MockSource: Identifiable, Hashable {
    let id = UUID()
    let server: String
    let hdr: String    // SDR / HDR10 / 杜比视界
    let resolution: String // 4K60 / 1080P
    let bitrate: String
    let recommended: Bool
    let engine: String // AVPlayer / mpv
}

enum MockStore {
    static let hero = [
        MockMedia(title: "蚀骨时差", subtitle: "悬疑 · 2026 · 24集", score: 8.7, episodeCount: 24,
                  gradient: g(Color(red: 0.55, green: 0.38, blue: 0.12), Color(red: 0.10, green: 0.06, blue: 0.02))),
        MockMedia(title: "好东西", subtitle: "剧情 · 2025", score: 9.1, episodeCount: nil,
                  gradient: g(Color(red: 0.16, green: 0.30, blue: 0.42), .black)),
        MockMedia(title: "星际回声", subtitle: "科幻 · 2026 · 12集", score: 8.4, episodeCount: 12,
                  gradient: g(Color(red: 0.30, green: 0.10, blue: 0.34), .black)),
    ]

    static let continueWatching = [
        MockMedia(title: "法医秦明之蚀骨时差", subtitle: "S01·E14 · 还剩 38 分钟", score: nil, episodeCount: 24,
                  gradient: g(Color(red: 0.42, green: 0.30, blue: 0.10), .black)),
        MockMedia(title: "好东西", subtitle: "看到 37 分钟", score: nil, episodeCount: nil,
                  gradient: g(Color(red: 0.14, green: 0.24, blue: 0.34), .black)),
        MockMedia(title: "漫长的季节", subtitle: "S01·E03", score: nil, episodeCount: 12,
                  gradient: g(Color(red: 0.24, green: 0.32, blue: 0.18), .black)),
    ]

    static let libraries = [
        ("电影", "1,284 部", Color(red: 0.35, green: 0.14, blue: 0.10)),
        ("剧集", "366 部", Color(red: 0.10, green: 0.22, blue: 0.30)),
        ("动漫", "528 部", Color(red: 0.30, green: 0.16, blue: 0.36)),
        ("纪录片", "97 部", Color(red: 0.10, green: 0.30, blue: 0.20)),
    ]

    static let popular = [
        MockMedia(title: "蚀骨时差", subtitle: "悬疑剧 · 4K杜比", score: 8.7, episodeCount: 24,
                  gradient: g(Color(red: 0.50, green: 0.34, blue: 0.10), .black)),
        MockMedia(title: "好东西", subtitle: "电影 · 4K60", score: 9.1, episodeCount: nil,
                  gradient: g(Color(red: 0.16, green: 0.28, blue: 0.40), .black)),
        MockMedia(title: "星际回声", subtitle: "科幻 · HDR10", score: 8.4, episodeCount: 12,
                  gradient: g(Color(red: 0.30, green: 0.12, blue: 0.36), .black)),
        MockMedia(title: "山海小馆", subtitle: "美食纪录片", score: 8.9, episodeCount: 8,
                  gradient: g(Color(red: 0.14, green: 0.34, blue: 0.22), .black)),
        MockMedia(title: "无声证词", subtitle: "犯罪 · 1080P", score: 7.9, episodeCount: 18,
                  gradient: g(Color(red: 0.36, green: 0.12, blue: 0.12), .black)),
    ]

    static let playTarget = MockPlayTarget(
        title: "好东西",
        episode: "S01 · E01",
        badge: "4K",
        bitrate: "22.4Mbps",
        container: "MKV",
        // Apple 官方 HLS 演示流（fMP4，含多音轨/字幕，适合验证 M2 能力）
        demoURL: URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8")!,
        sources: [
            MockSource(server: "BEmby and Cloud", hdr: "SDR", resolution: "4K60", bitrate: "22.4 Mbps", recommended: false, engine: "mpv"),
            MockSource(server: "OkEmby", hdr: "SDR", resolution: "4K60", bitrate: "23.7 Mbps", recommended: true, engine: "mpv"),
            MockSource(server: "WebDAV · 115", hdr: "HDR10", resolution: "4K", bitrate: "18.2 Mbps", recommended: false, engine: "AVPlayer"),
        ]
    )
}

// MARK: - 渐变封面占位（M4 接入 TMDB 海报）
struct CoverPlaceholder: View {
    let gradient: [Color]
    var body: some View {
        ZStack {
            LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "film.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.18))
        }
    }
}
