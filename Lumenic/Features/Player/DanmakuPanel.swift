import SwiftUI
import UniformTypeIdentifiers

/// 弹幕玻璃面板：显示开关/密度/字号/透明度/显示区域/字幕避让/时间轴校正
/// + 弹弹play 自动匹配、手动换绑搜索、B站 XML 导入（M5）
struct DanmakuPanel: View {
    @ObservedObject var engine: DanmakuEngine
    let client: DandanplayClient
    var onClose: () -> Void

    @State private var showImporter = false
    @State private var searchKeyword = ""
    @State private var searchResults: [DandanAnime] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var newBlockWord = ""

    var body: some View {
        GlassPanelSheet(title: "弹幕", icon: "text.bubble", onClose: onClose) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    statusRow
                    toggles
                    steppers
                    blocklistSection
                    sourceSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 30)
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [UTType(filenameExtension: "xml") ?? UTType.xml, UTType.data],
                      allowsMultipleSelection: false) { result in
            importXML(result)
        }
    }

    // MARK: 状态行

    @ViewBuilder
    private var statusRow: some View {
        switch engine.status {
        case .idle:
            statusLabel("未加载弹幕", color: .dsInk2)
        case .loading:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.8)
                Text("正在匹配弹幕库…").font(.dsCaption).foregroundStyle(.dsInk2)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.dsGlassBorder.opacity(0.5)))
        case .ready(let count, let source):
            statusLabel("已载入 \(count) 条 · \(source)", color: .green)
        case .failed(let reason):
            statusLabel(reason, color: .orange)
        }
    }

    private func statusLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.dsCaption).foregroundStyle(color)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.dsGlassBorder.opacity(0.5)))
    }

    // MARK: 开关

    private var toggles: some View {
        VStack(spacing: 0) {
            toggleRow(icon: "text.bubble", title: "显示弹幕",
                      subtitle: engine.isEnabled ? "弹幕池渲染中" : "已暂停显示，挂载记录仍会保留",
                      isOn: $engine.isEnabled)
            Divider().overlay(Color.dsGlassBorder).padding(.leading, 52)
            toggleRow(icon: "caption.2.bubble.fill", title: "字幕区避让",
                      subtitle: "底部固定弹幕抬到字幕带之上，不压字幕",
                      isOn: $engine.avoidSubtitle)
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.dsGlassBorder.opacity(0.5)))
    }

    @ViewBuilder
    private func toggleRow(icon: String, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(.dsInk2).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(.dsInk)
                Text(subtitle).font(.dsCaption).foregroundStyle(.dsInk2)
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().tint(.accentColor)
        }
        .padding(14)
    }

    // MARK: 数值调节

    private var steppers: some View {
        VStack(spacing: 0) {
            stepperRow("不透明度", value: String(Int(engine.opacity * 100)), unit: "%",
                       minus: { engine.opacity = max(0.2, engine.opacity - 0.05) },
                       plus: { engine.opacity = min(1, engine.opacity + 0.05) })
            Divider().overlay(Color.dsGlassBorder).padding(.leading, 52)
            stepperRow("字号", value: String(Int(engine.fontSize)), unit: "pt",
                       minus: { engine.fontSize = max(12, engine.fontSize - 1) },
                       plus: { engine.fontSize = min(32, engine.fontSize + 1) })
            Divider().overlay(Color.dsGlassBorder).padding(.leading, 52)
            stepperRow("显示区域", value: String(Int(engine.areaRatio * 100)), unit: "%",
                       minus: { engine.areaRatio = max(0.25, engine.areaRatio - 0.25) },
                       plus: { engine.areaRatio = min(1.0, engine.areaRatio + 0.25) })
            Divider().overlay(Color.dsGlassBorder).padding(.leading, 52)
            stepperRow("弹幕密度", value: String(Int(engine.density * 100)), unit: "%",
                       minus: { engine.density = max(0.2, engine.density - 0.2) },
                       plus: { engine.density = min(3, engine.density + 0.2) })
            Divider().overlay(Color.dsGlassBorder).padding(.leading, 52)
            stepperRow("时间轴校正", value: Int(engine.offset * 10), unit: "s",
                       minus: { engine.offset -= 0.5 },
                       plus: { engine.offset += 0.5 })
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.dsGlassBorder.opacity(0.5)))
    }

    @ViewBuilder
    private func stepperRow(_ title: String, value: String, unit: String,
                            minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 15)).foregroundStyle(.dsInk)
            Spacer()
            HStack(spacing: 10) {
                stepButton("minus", action: minus)
                Text("\(value) \(unit)")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.dsInk)
                    .frame(minWidth: 56)
                stepButton("plus", action: plus)
            }
        }
        .padding(14)
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.dsInk)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.dsGlassBorder))
        }
    }

    // MARK: 屏蔽词（命中关键词的弹幕不入池，即时生效并持久化）

    private var blocklistSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("屏蔽词").font(.system(size: 15, weight: .medium)).foregroundStyle(.dsInk)
            if engine.blocklist.isEmpty {
                Text("添加关键词，命中的弹幕不再显示")
                    .font(.dsCaption).foregroundStyle(.dsInk3)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)],
                          alignment: .leading, spacing: 8) {
                    ForEach(engine.blocklist, id: \.self) { word in
                        HStack(spacing: 6) {
                            Text(word).font(.system(size: 12)).foregroundStyle(.dsInk)
                                .lineLimit(1)
                            Button {
                                engine.blocklist.removeAll { $0 == word }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12)).foregroundStyle(.dsInk3)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Color.dsGlassBorder))
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("输入关键词后回车添加", text: $newBlockWord)
                    .font(.system(size: 14)).foregroundStyle(.dsInk)
                    .autocorrectionDisabled()
                    .onSubmit(addBlockWord)
                Button(action: addBlockWord) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.accentColor))
                }
                .disabled(newBlockWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.dsGlassBorder.opacity(0.5)))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.dsGlassBorder.opacity(0.5)))
    }

    private func addBlockWord() {
        let w = newBlockWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }
        if !engine.blocklist.contains(w) { engine.blocklist.append(w) }
        newBlockWord = ""
    }

    // MARK: 弹幕来源（自动匹配 / 手动换绑 / XML 导入）

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            actionButton("arrow.triangle.2.circlepath", "重新自动匹配", accent: true) {
                Task { await engine.rematch(client: client) }
            }
            actionButton("square.and.arrow.down", "导入 B站 XML 弹幕文件") {
                showImporter = true
            }

            Text("手动换绑（弹弹play 关键词搜索）")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.dsInk2)
                .padding(.top, 4)
            HStack(spacing: 8) {
                TextField("作品名", text: $searchKeyword)
                    .font(.system(size: 14))
                    .foregroundStyle(.dsInk)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await search() } }
                Button {
                    Task { await search() }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.accentColor))
                }
                .disabled(searchKeyword.isEmpty || isSearching)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.dsGlassBorder.opacity(0.5)))

            if isSearching {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("搜索中…").font(.dsCaption).foregroundStyle(.dsInk2)
                }
            }
            if let searchError {
                Text(searchError).font(.dsCaption).foregroundStyle(.orange)
            }
            ForEach(searchResults) { anime in
                VStack(alignment: .leading, spacing: 4) {
                    Text(anime.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.dsInk)
                    ForEach(anime.episodes) { ep in
                        Button {
                            Task { await bind(episodeId: ep.episodeId, label: "\(anime.title) · \(ep.title)") }
                        } label: {
                            HStack {
                                Text(ep.title).font(.dsCaption).foregroundStyle(.dsInk2)
                                Spacer()
                                Image(systemName: "link").font(.system(size: 11)).foregroundStyle(Color.accentColor)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.dsGlassBorder.opacity(0.4)))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.dsGlassBorder.opacity(0.5)))
    }

    private func actionButton(_ icon: String, _ title: String, accent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14))
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(accent ? .white : .dsInk)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(accent ? Color.accentColor : Color.dsGlassBorder.opacity(0.6)))
        }
    }

    // MARK: 动作

    private func search() async {
        guard !searchKeyword.isEmpty else { return }
        isSearching = true
        searchError = nil
        searchResults = []
        defer { isSearching = false }
        do {
            searchResults = try await client.searchEpisodes(keyword: searchKeyword)
            if searchResults.isEmpty { searchError = "没有匹配的作品" }
        } catch {
            searchError = "搜索失败：\((error as? DandanplayClient.DanmakuError)?.description ?? "网络异常")"
        }
    }

    private func bind(episodeId: Int, label: String) async {
        do {
            let list = try await client.comments(episodeId: episodeId)
            engine.load(list, source: "弹弹play · \(label)")
        } catch {
            searchError = "挂载失败：\((error as? DandanplayClient.DanmakuError)?.description ?? "网络异常")"
        }
    }

    private func importXML(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let list = DanmakuImporter.parseBilibiliXML(data)
            if list.isEmpty {
                engine.setFailed("XML 中未解析到弹幕")
            } else {
                engine.load(list, source: "B站 XML · \(url.lastPathComponent)")
            }
        } catch {
            engine.setFailed("导入失败：读取文件异常")
        }
    }
}
