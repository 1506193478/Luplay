import SwiftUI

/// 聚合详情页：TMDB 信息 + 片源对比面板入口（对标参考图“播放来源”面板）
struct AggregateDetailView: View {
    let media: MockMedia
    @Environment(\.dismiss) private var dismiss
    @State private var showSources = false
    @State private var selectedSource: MockSource?

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    backdrop
                    infoSection
                    episodeStrip
                    Color.clear.frame(height: 140)
                }
            }
            .ignoresSafeArea(edges: .top)

            playButton
        }
        .overlay(alignment: .topLeading) { navBack }
        .overlay {
            if showSources {
                SourceComparePanel(sources: MockStore.playTarget.sources,
                                   selected: $selectedSource,
                                   onClose: { withAnimation(.dsEaseOut) { showSources = false } })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var backdrop: some View {
        CoverPlaceholder(gradient: media.gradient)
            .frame(height: 340)
            .overlay(LinearGradient(colors: [.clear, .dsPage], startPoint: UnitPoint(x: 0.5, y: 0.4), endPoint: .bottom))
            .overlay(alignment: .bottomTrailing) { scoreBadge.padding(18) }
    }

    private var scoreBadge: some View {
        VStack(spacing: 2) {
            Text(String(format: "%.1f", media.score ?? 0))
                .font(.system(size: 20, weight: .heavy)).foregroundStyle(.dsGold)
            Text("TMDB 评分").font(.system(size: 9)).foregroundStyle(.dsInk2)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(GlassSurface(shape: .rounded(14)) { Color.clear })
    }

    private var navBack: some View {
        Button { dismiss() } label: {
            GlassSurface(shape: .capsule, interactive: true) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.dsInk)
                    .frame(width: 40, height: 40)
            }
        }
        .padding(.leading, 16).padding(.top, 60)
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(media.title).font(.system(size: 28, weight: .heavy)).foregroundStyle(.dsInk)
            Text(media.subtitle).font(.system(size: 13)).foregroundStyle(.dsInk2)
            HStack(spacing: 8) {
                qualityTag("4K", highlight: true)
                qualityTag("杜比视界", highlight: false)
                qualityTag("双内核", highlight: false)
            }
        }
        .padding(.horizontal, 20)
    }

    private func qualityTag(_ t: String, highlight: Bool) -> some View {
        Text(t)
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(highlight ? .yellow : .dsInk2)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().strokeBorder(Color.dsGlassBorder))
    }

    private var episodeStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选集").font(.dsSection).foregroundStyle(.dsInk)
                .padding(.horizontal, 20).padding(.top, 24)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(1...24, id: \.self) { e in
                        Text("\(e)")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(e == 14 ? .white : .dsInk)
                            .frame(width: 42, height: 42)
                            .background {
                                if e == 14 { Circle().fill(Color.accentColor) }
                                else { GlassSurface(shape: .capsule) { Color.clear } }
                            }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var playButton: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.dsEaseOut) { showSources = true }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.stack.badge.play.fill")
                    Text("继续播放 · 第14集")
                    Spacer(minLength: 0)
                    Text("3 源").font(.dsCaption)
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(height: 54)
                .background(Capsule().fill(Color.accentColor))
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 30)
    }
}

/// 片源对比玻璃面板（对标参考图：SDR/4K60/码率/服务器 + 推荐标记）
struct SourceComparePanel: View {
    let sources: [MockSource]
    @Binding var selected: MockSource?
    var onClose: () -> Void

    var body: some View {
        GlassPanelSheet(title: "播放来源", icon: "square.stack.3d.up.fill", onClose: onClose) {
            VStack(alignment: .leading, spacing: 10) {
                Text("共 \(sources.count) 个片源，切换后进度不变")
                    .font(.dsCaption).foregroundStyle(.dsInk2)
                    .padding(.horizontal, 20).padding(.top, 14)

                ForEach(sources) { s in
                    sourceRow(s)
                }
                Spacer()
            }
        }
    }

    private func sourceRow(_ s: MockSource) -> some View {
        let isSelected = selected?.id == s.id
        return Button {
            withAnimation(.dsSpring) { selected = s }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    tag(s.hdr, mono: false)
                    tag(s.resolution, mono: false)
                    if s.recommended { tag("推荐", mono: false, highlight: true) }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.dsInk3)
                }
                HStack(spacing: 12) {
                    Label(s.bitrate, systemImage: "gauge.high")
                    Label(s.engine == "AVPlayer" ? "AVPlayer" : "mpv", systemImage: "cpu")
                }
                .font(.system(size: 11.5)).foregroundStyle(.dsInk2)
                Text(s.server).font(.system(size: 14, weight: .semibold)).foregroundStyle(.dsInk)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.dsGlassBorder.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isSelected ? Color.accentColor : Color.dsGlassBorder, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .padding(.horizontal, 20)
    }

    private func tag(_ t: String, mono: Bool, highlight: Bool = false) -> some View {
        Text(t)
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(highlight ? Color.accentColor : .dsInk)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(highlight ? Color.accentColor.opacity(0.2) : Color.dsGlassBorder))
    }
}
