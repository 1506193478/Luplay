import SwiftUI

/// 网络链接解析播放面板：粘贴视频直链 → 探测媒体信息 → 确认播放（玻璃风格）
struct URLPlayPanel: View {
    var onPlay: (PlayRequest) -> Void
    var onClose: () -> Void

    @State private var urlString = ""
    @State private var title = ""
    @State private var isResolving = false
    @State private var resolved: StreamInfo?
    @State private var errorText: String?

    var body: some View {
        GlassPanelSheet(title: "链接播放", icon: "link", onClose: onClose) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("粘贴视频直链（mp4 / m3u8 / mkv 等），自动探测格式并播放")
                        .font(.dsCaption).foregroundStyle(.dsInk2)
                        .padding(.horizontal, 20).padding(.top, 14)

                    urlField
                    titleField

                    if let resolved {
                        resolvedCard(resolved)
                    }
                    if let errorText {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(errorText)
                        }
                        .font(.dsCaption).foregroundStyle(.orange)
                        .padding(.horizontal, 20)
                    }
                    resolveButton

                    Color.clear.frame(height: 30)
                }
            }
        }
    }

    // MARK: - 输入区

    private var urlField: some View {
        GlassSurface(shape: .rounded(14), interactive: true) {
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.dsInk2)
                TextField("https://… 视频直链", text: $urlString)
                    .foregroundStyle(.dsInk)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { Task { await resolve() } }
                if !urlString.isEmpty {
                    Button {
                        urlString = ""
                        resolved = nil
                        errorText = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.dsInk3)
                    }
                } else {
                    // 快捷粘贴：直接读取剪贴板并自动预填标题
                    Button {
                        if let s = UIPasteboard.general.string {
                            urlString = s.trimmingCharacters(in: .whitespacesAndNewlines)
                            prefillTitleIfNeeded()
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard").foregroundStyle(.dsInk2)
                    }
                }
            }
            .font(.system(size: 15))
        }
        .frame(height: 48)
        .padding(.horizontal, 16)
    }

    private var titleField: some View {
        GlassSurface(shape: .rounded(14), interactive: true) {
            HStack(spacing: 8) {
                Image(systemName: "tv").foregroundStyle(.dsInk2)
                TextField("标题（可选，留空自动取文件名）", text: $title)
                    .foregroundStyle(.dsInk)
            }
            .font(.system(size: 15))
        }
        .frame(height: 48)
        .padding(.horizontal, 16)
    }

    // MARK: - 解析结果卡（容器/分辨率/HDR/内核徽章）

    private func resolvedCard(_ info: StreamInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                tag(info.container.uppercased())
                tag(info.resolution)
                if info.hdr != "SDR" { tag(info.hdr) }
                tag(info.recommendedEngine == .mpv ? "mpv" : "AVPlayer")
                Spacer()
            }
            Text(info.url.host ?? "")
                .font(.dsCaption).foregroundStyle(.dsInk3)
                .lineLimit(1)
        }
        .padding(14)
        .background(GlassSurface(shape: .rounded(16)) { Color.clear })
        .padding(.horizontal, 16)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(.dsInk)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.dsGlassBorder))
    }

    // MARK: - 解析 / 播放按钮

    private var resolveButton: some View {
        Button {
            if resolved != nil { play() } else { Task { await resolve() } }
        } label: {
            HStack(spacing: 8) {
                if isResolving {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: resolved == nil ? "sparkles" : "play.fill")
                }
                Text(resolved == nil ? "解析链接" : "立即播放")
                    .font(.system(size: 16, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Capsule().fill(Color.accentColor))
        }
        .buttonStyle(.plain)
        .disabled(isResolving)
        .opacity(isResolving ? 0.6 : 1)
        .padding(.horizontal, 16)
    }

    // MARK: - 逻辑

    private func prefillTitleIfNeeded() {
        guard title.trimmingCharacters(in: .whitespaces).isEmpty,
              let url = URLResolver.normalize(urlString) else { return }
        title = URLResolver.guessTitle(url)
    }

    private func resolve() async {
        errorText = nil
        resolved = nil
        isResolving = true
        defer { isResolving = false }
        do {
            let info = try await URLResolver.resolve(urlString)
            prefillTitleIfNeeded()
            withAnimation(.dsSpring) { resolved = info }
        } catch {
            withAnimation(.dsEaseOut) { errorText = error.localizedDescription }
        }
    }

    private func play() {
        guard let info = resolved else { return }
        let raw = urlString
        let displayTitle = title.trimmingCharacters(in: .whitespaces).isEmpty
            ? URLResolver.guessTitle(info.url) : title.trimmingCharacters(in: .whitespaces)
        let option = StreamOption(
            id: "url|\(info.url.absoluteString)",
            providerId: "url",
            serverName: "网络直链",
            info: info,
            // 直链有时效：换源/续播时按原输入重新探测
            refresh: { try await URLResolver.resolve(raw) })
        onClose()
        onPlay(PlayRequest(title: displayTitle, episodeLabel: "正片", options: [option]))
    }
}
