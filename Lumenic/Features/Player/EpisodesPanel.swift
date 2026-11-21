import SwiftUI

/// 剧集列表面板：全集网格 + 当前集高亮，点按切集（进度按集保存，同引擎重载不重建渲染）
struct EpisodesPanel: View {
    let titles: [String]
    let currentIndex: Int
    var onSelect: (Int) -> Void = { _ in }
    var onClose: () -> Void

    var body: some View {
        GlassPanelSheet(title: "剧集", icon: "list.bullet.rectangle.portrait", onClose: onClose) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("共 \(titles.count) 集 · 进度按集保存，切换不丢失")
                        .font(.dsCaption).foregroundStyle(.dsInk2)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 10)], spacing: 10) {
                        ForEach(Array(titles.enumerated()), id: \.offset) { idx, title in
                            Button { onSelect(idx) } label: {
                                VStack(spacing: 3) {
                                    Text(title)
                                        .font(.system(size: 13, weight: .bold))
                                        .lineLimit(1).minimumScaleFactor(0.75)
                                    if idx == currentIndex {
                                        Text("播放中")
                                            .font(.system(size: 9, weight: .heavy))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .foregroundStyle(idx == currentIndex ? Color.accentColor : Color.dsInk)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(idx == currentIndex
                                              ? Color.accentColor.opacity(0.16)
                                              : Color.dsGlassBorder.opacity(0.5))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(idx == currentIndex ? Color.accentColor : Color.dsGlassBorder,
                                                      lineWidth: idx == currentIndex ? 1.5 : 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 30)
            }
        }
    }
}
