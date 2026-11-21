import SwiftUI

/// 调试面板（方案 §5.2-8）：内核/缓冲/FPS/码率/片源信息——排障神器。
struct DebugPanel: View {
    @ObservedObject var session: PlaybackSession
    let option: StreamOption?
    let onClose: () -> Void

    var body: some View {
        GlassPanelSheet(title: "调试信息", icon: "stethoscope", onClose: onClose) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows, id: \.0) { row in
                        HStack(alignment: .top) {
                            Text(row.0)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.dsInk2)
                                .frame(width: 96, alignment: .leading)
                            Text(row.1)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.dsInk)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 7)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 30)
            }
        }
    }

    private var rows: [(String, String)] {
        var result: [(String, String)] = []
        let tick = session.tick

        result.append(("内核", session.engineKind == .avplayer ? "AVPlayer（系统管线）" : "libmpv"))
        result.append(("状态", session.isPlaying ? "播放中 \(String(format: "%g", session.rate))×" : "已暂停"))
        if let tick {
            result.append(("进度", "\(Self.time(tick.position)) / \(Self.time(tick.duration))"))
            let buf = max(0, tick.buffered - tick.position)
            result.append(("缓冲余量", String(format: "%.1fs（健康度 %@）", buf, health(buf, duration: tick.duration))))
        }
        if let fps = tick?.fps, fps > 0 {
            result.append(("帧率", String(format: "%.2f fps", fps)))
        }
        if let bps = tick?.bitrateBps, bps > 0 {
            result.append(("视频码率", String(format: "%.2f Mbps", bps / 1_000_000)))
        }
        if let info = option {
            result.append(("片源", "\(info.serverName) · \(info.providerId)"))
            result.append(("媒体", "\(info.info.container.uppercased()) · \(info.info.resolution) · \(info.info.hdr)"))
            if info.info.bitrateMbps > 0 {
                result.append(("标称码率", String(format: "%.1f Mbps", info.info.bitrateMbps)))
            }
            result.append(("地址", info.info.url.absoluteString))
            if !info.info.headers.isEmpty {
                result.append(("注入头", info.info.headers.map { "\($0.key)" }.joined(separator: ", ")))
            }
        } else {
            result.append(("片源", "无（演示流）"))
        }
        return result
    }

    /// 缓冲健康度：余量 / 时长 阈值分档（对标参考图调试条）
    private func health(_ buffered: Double, duration: Double) -> String {
        if duration > 0, buffered >= duration - 1 { return "充足" }
        switch buffered {
        case ..<5: return "告急"
        case ..<30: return "一般"
        default: return "健康"
        }
    }

    private static func time(_ t: Double) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let total = Int(t), h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
