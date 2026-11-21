import SwiftUI

/// 媒体库：已配置片源卡片 + 真实播放记录（最近添加/未看完）
struct LibraryView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var filter = "全部"
    @State private var progressEntries: [PlaybackProgress] = []
    @State private var libraryEntries: [LibraryEntry] = []
    @State private var loaded = false

    private var unfinished: [PlaybackProgress] {
        progressEntries.filter { $0.duration > 0 && $0.position < $0.duration * 0.95 }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text("媒体库")
                    .font(.dsTitle)
                    .foregroundStyle(.dsInk)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 16)

                filters

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 16) {
                    ForEach(env.providers, id: \.id) { provider in
                        providerCard(provider)
                    }
                }
                .padding(.horizontal, 20)

                librarySection
                sectionGrid("最近添加", entries: progressEntries)
                sectionGrid("未看完", entries: unfinished)
                Color.clear.frame(height: 120)
            }
        }
        .background(Color.dsPage.ignoresSafeArea())
        .task {
            guard !loaded else { return }
            loaded = true
            progressEntries = (try? env.database.allProgress()) ?? []
            libraryEntries = (try? env.database.allLibraryEntries()) ?? []
        }
    }

    // MARK: 我的媒体库（详情页打开过的内容自动收藏，TMDB 海报优先）

    @ViewBuilder
    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("我的媒体库").font(.dsSection).foregroundStyle(.dsInk)
                .padding(.horizontal, 20).padding(.top, 26)
            if libraryEntries.isEmpty {
                Text("在聚合搜索中打开过详情的影片会出现在这里")
                    .font(.dsCaption).foregroundStyle(.dsInk3)
                    .padding(.horizontal, 20)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 16) {
                    ForEach(libraryEntries, id: \.tmdbKey) { entry in
                        libraryCard(entry)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func libraryCard(_ entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let path = entry.posterPath, let url = URL(string: path) {
                    AsyncImage(url: url) { phase in
                        if let img = phase.image {
                            img.resizable().scaledToFill()
                        } else {
                            CoverPlaceholder(gradient: CoverPalette.forTitle(entry.title))
                        }
                    }
                } else {
                    CoverPlaceholder(gradient: CoverPalette.forTitle(entry.title))
                }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(entry.title).font(.dsCardTitle).foregroundStyle(.dsInk)
                .lineLimit(1).minimumScaleFactor(0.85)
        }
    }

    private func providerCard(_ provider: SourceProvider) -> some View {
        ZStack(alignment: .bottomLeading) {
            CoverPlaceholder(gradient: [Color.dsAccent.opacity(0.5), .black])
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName).font(.system(size: 17, weight: .heavy)).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text(provider.isConfigured ? "已连接" : "未配置")
                    .font(.dsCaption).foregroundStyle(.white.opacity(0.7))
            }
            .padding(14)
        }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(["全部", "4K", "杜比视界", "HDR10", "未看完"], id: \.self) { f in
                    Button {
                        withAnimation(.dsSpring) { filter = f }
                    } label: {
                        Text(f)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(filter == f ? .white : .dsInk2)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .background {
                        if filter == f {
                            Capsule().fill(Color.accentColor)
                        } else {
                            GlassSurface(shape: .capsule) { Color.clear }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
    }

    @ViewBuilder
    private func sectionGrid(_ title: String, entries: [PlaybackProgress]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.dsSection).foregroundStyle(.dsInk)
                .padding(.horizontal, 20)
                .padding(.top, 26)
            if entries.isEmpty {
                Text("暂无播放记录 · 播放过的内容会出现在这里")
                    .font(.dsCaption).foregroundStyle(.dsInk3)
                    .padding(.horizontal, 20)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 16) {
                    ForEach(entries, id: \.tmdbKey) { entry in
                        progressCard(entry)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func progressCard(_ entry: PlaybackProgress) -> some View {
        let title = entry.tmdbKey.split(separator: "|", maxSplits: 1).first.map(String.init) ?? entry.tmdbKey
        return VStack(alignment: .leading, spacing: 6) {
            CoverPlaceholder(gradient: CoverPalette.forTitle(title))
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottom) {
                    GeometryReader { geo in
                        Capsule().fill(.white.opacity(0.22))
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color.dsAccent)
                                    .frame(width: geo.size.width * (entry.duration > 0 ? min(1, entry.position / entry.duration) : 0))
                            }
                    }
                    .frame(height: 3)
                }
            Text(title).font(.dsCardTitle).foregroundStyle(.dsInk)
                .lineLimit(1).minimumScaleFactor(0.85)
        }
    }
}
