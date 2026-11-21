import SwiftUI

/// 聚合搜索：搜索框 + 聚合结果（多片源命中合并），对标“聚合搜索与片源对比”
struct SearchView: View {
    @State private var query = ""
    @State private var searched = false
    @State private var detailTarget: MockMedia?

    private var results: [MockMedia] { searched ? MockStore.popular : [] }

    var body: some View {
        VStack(spacing: 0) {
            searchBar.padding(.horizontal, 16).padding(.top, 10)
            if !searched { hotList } else { resultList }
            Spacer(minLength: 0)
        }
        .background(Color.dsPage.ignoresSafeArea())
        .sheet(item: $detailTarget) { _ in
            AggregateDetailView(media: MockStore.popular[0])
                .presentationDetents([.large])
        }
    }

    private var searchBar: some View {
        GlassSurface(shape: .rounded(14), interactive: true) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.dsInk2)
                TextField("搜索片名，聚合全部片源", text: $query)
                    .foregroundStyle(.dsInk)
                    .onSubmit { withAnimation(.dsEaseOut) { searched = true } }
                if !query.isEmpty {
                    Button { query = ""; searched = false } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.dsInk3)
                    }
                }
            }
            .font(.system(size: 15))
        }
        .frame(height: 48)
    }

    private var hotList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("热门搜索").font(.dsSection).foregroundStyle(.dsInk)
                .padding(.horizontal, 20).padding(.top, 22)
            ForEach(["蚀骨时差", "好东西", "星际回声", "漫长的季节"], id: \.self) { kw in
                Button {
                    query = kw; searched = true
                } label: {
                    HStack {
                        Image(systemName: "flame.fill").foregroundStyle(.orange)
                        Text(kw).foregroundStyle(.dsInk)
                        Spacer()
                        Text("3 个片源").font(.dsCaption).foregroundStyle(.dsInk3)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 10)
                }
            }
            Spacer()
        }
    }

    private var resultList: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                ForEach(results) { m in
                    Button { detailTarget = m } label: { aggregateCard(m) }
                }
                Color.clear.frame(height: 120)
            }
            .padding(.horizontal, 16).padding(.top, 14)
        }
    }

    /// 聚合结果卡：TMDB 归一化后，右侧显示命中的片源数
    private func aggregateCard(_ m: MockMedia) -> some View {
        HStack(spacing: 12) {
            CoverPlaceholder(gradient: m.gradient)
                .frame(width: 86, height: 118)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                Text(m.title).font(.system(size: 17, weight: .bold)).foregroundStyle(.dsInk)
                Text(m.subtitle).font(.dsCaption).foregroundStyle(.dsInk2)
                if let s = m.score {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.dsGold)
                        Text(String(format: "%.1f", s)).font(.dsCaption).foregroundStyle(.dsGold)
                    }
                }
                Spacer()
                HStack(spacing: 6) {
                    sourceBadge("BEmby", .blue)
                    sourceBadge("OkEmby", .green)
                    sourceBadge("115", .orange)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(.dsInk3).font(.system(size: 13))
        }
        .padding(12)
        .background(GlassSurface(shape: .rounded(16)) { Color.clear })
    }

    private func sourceBadge(_ name: String, _ color: Color) -> some View {
        Text(name)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.85)))
    }
}
