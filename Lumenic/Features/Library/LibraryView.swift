import SwiftUI

/// 媒体库：分类宫格 + 筛选条
struct LibraryView: View {
    @State private var filter = "全部"

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
                    ForEach(MockStore.libraries, id: \.0) { item in
                        bigCard(item)
                    }
                }
                .padding(.horizontal, 20)

                sectionGrid("最近添加")
                sectionGrid("未看完")
                Color.clear.frame(height: 120)
            }
        }
        .background(Color.dsPage.ignoresSafeArea())
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

    private func bigCard(_ item: (String, String, Color)) -> some View {
        ZStack(alignment: .bottomLeading) {
            CoverPlaceholder(gradient: [item.2, .black])
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.0).font(.system(size: 17, weight: .heavy)).foregroundStyle(.white)
                Text(item.1).font(.dsCaption).foregroundStyle(.white.opacity(0.7))
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func sectionGrid(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.dsSection).foregroundStyle(.dsInk)
                .padding(.horizontal, 20)
                .padding(.top, 26)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 16) {
                ForEach(MockStore.popular) { m in
                    VStack(alignment: .leading, spacing: 6) {
                        CoverPlaceholder(gradient: m.gradient)
                            .frame(height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        Text(m.title).font(.dsCardTitle).foregroundStyle(.dsInk).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }
}
