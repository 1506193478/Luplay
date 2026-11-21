import SwiftUI
import AVKit

/// 投屏面板（方案 §5.2-6 / §7）：
/// - AirPlay：AVPlayer 内核内嵌系统路由选择器；mpv 内核先无缝切内核再投（保进度）
/// - DLNA/Chromecast：局域网扫描推直链；连接后出现遥控区（播放暂停/远端进度/音量）
struct CastPanel: View {
    @ObservedObject var session: PlaybackSession
    let streamInfo: StreamInfo?
    let title: String
    @EnvironmentObject private var env: AppEnvironment
    let onClose: () -> Void

    // 遥控状态（远端）
    @State private var remoteScrubbing = false
    @State private var remoteScrub: Double = 0
    @State private var remoteVolume: Double = 50
    @State private var volumeLoaded = false

    var body: some View {
        GlassPanelSheet(title: "投屏", icon: "tv.fill", onClose: onClose) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if env.cast.connectedDevice != nil {
                        remoteSection
                    }
                    airPlaySection
                    dlnaSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 30)
            }
        }
    }

    // MARK: 遥控（连接后出现：DLNA AVTransport / Chromecast 媒体通道）

    private var remoteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("遥控", icon: "hand.tap.fill")
            GlassSurface(shape: .rounded(16)) {
                VStack(spacing: 14) {
                    // 播放/暂停 + 状态
                    HStack(spacing: 14) {
                        Button {
                            env.cast.remoteStatus?.isPlaying == true
                                ? env.cast.pauseRemote()
                                : env.cast.playRemote()
                        } label: {
                            Image(systemName: env.cast.remoteStatus?.isPlaying == false
                                  ? "play.fill" : "pause.fill")
                                .font(.system(size: 17, weight: .bold))
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(Color.dsGlassBorder))
                        }
                        .foregroundStyle(.dsInk)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(env.cast.connectedDevice?.name ?? "")
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.dsInk)
                                .lineLimit(1).minimumScaleFactor(0.8)
                            Text(env.cast.remoteStatus.map { status in
                                "\(Self.timeString(status.position)) / \(Self.timeString(status.duration))"
                            } ?? "等待设备状态…")
                                .font(.dsCaption).foregroundStyle(.dsInk2)
                        }
                        Spacer()
                    }

                    // 远端进度条（拖动结束才发 Seek）
                    if let duration = env.cast.remoteStatus?.duration, duration > 0 {
                        GeometryReader { geo in
                            progressSlider(duration: duration, width: geo.size.width)
                        }
                        .frame(height: 26)
                    }

                    // 音量（拖动结束才发 SetVolume）
                    HStack(spacing: 10) {
                        Image(systemName: "speaker.fill")
                            .font(.system(size: 12)).foregroundStyle(.dsInk2)
                        Slider(value: $remoteVolume, in: 0...100) { editing in
                            if !editing { env.cast.setRemoteVolume(remoteVolume) }
                        }
                        .tint(Color.dsAccent)
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.system(size: 12)).foregroundStyle(.dsInk2)
                    }
                }
                .padding(14)
            }
        }
        .task {
            // 滑杆初值（DLNA GetVolume；Chromecast 无回读则保持默认）
            guard !volumeLoaded else { return }
            volumeLoaded = true
            if let v = await env.cast.remoteVolume() { remoteVolume = v }
        }
    }

    /// 远端进度滑杆（自绘轨道，与播放器进度条一致的轻量样式）
    private func progressSlider(duration: Double, width: CGFloat) -> some View {
        let position = remoteScrubbing ? remoteScrub : (env.cast.remoteStatus?.position ?? 0)
        let fraction = min(max(position / duration, 0), 1)
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.dsGlassBorder).frame(height: 6)
            Capsule().fill(Color.dsAccent).frame(width: max(6, width * fraction), height: 6)
            Circle().fill(Color.white).frame(width: 14, height: 14)
                .offset(x: width * fraction - 7)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                remoteScrubbing = true
                remoteScrub = min(max(0, v.location.x / width), 1) * duration
            }
            .onEnded { _ in
                env.cast.seekRemote(to: remoteScrub)
                remoteScrubbing = false
            })
    }

    private static func timeString(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: AirPlay（系统路由）

    private var airPlaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("AirPlay", icon: "waveform.circle.fill")
            if session.engine.capabilities.contains(.airplay) {
                HStack(spacing: 14) {
                    AirPlayRoutePicker()
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("系统路由选择器").font(.system(size: 15, weight: .semibold)).foregroundStyle(.dsInk)
                        Text("点击后选择你的 AirPlay 设备，画面无缝接管")
                            .font(.dsCaption).foregroundStyle(.dsInk2)
                    }
                    Spacer()
                }
            } else {
                Button {
                    Task { await session.switchEngine(to: .avplayer) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("切换到 AVPlayer 内核并开启 AirPlay")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.dsGlassBorder))
                }
                .foregroundStyle(.dsInk)
                Text("mpv 内核不支持系统投屏，切换内核会保留当前播放进度")
                    .font(.dsCaption).foregroundStyle(.dsInk2)
            }
        }
    }

    // MARK: DLNA（局域网推送）

    @ViewBuilder
    private var dlnaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("同一 Wi-Fi 下的设备", icon: "dot.radiowaves.left.and.right")
                Spacer()
                if env.cast.isScanning {
                    ProgressView().scaleEffect(0.8)
                }
            }
            if env.cast.devices.isEmpty && !env.cast.isScanning {
                Button {
                    Task { _ = await env.cast.scan() }
                } label: {
                    Text("扫描设备").font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(Color.dsGlassBorder))
                }
                .foregroundStyle(.dsInk)
                Text("DLNA 推送把视频直链交给电视端播放器，本机转为遥控")
                    .font(.dsCaption).foregroundStyle(.dsInk2)
            } else {
                ForEach(env.cast.devices) { device in
                    deviceRow(device)
                }
            }
            if let error = env.cast.lastError {
                Text(error).font(.dsCaption).foregroundStyle(.red.opacity(0.9))
            }
            if let connected = env.cast.connectedDevice {
                Button {
                    Task {
                        await env.cast.disconnect()
                        session.play()
                    }
                } label: {
                    Text("断开 \(connected.name)").font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().strokeBorder(Color.dsGlassBorder))
                }
                .foregroundStyle(.dsInk)
            }
        }
        .task { _ = await env.cast.scan() }
    }

    private func deviceRow(_ device: CastDevice) -> some View {
        let isConnected = env.cast.connectedDevice?.id == device.id
        return Button {
            guard let info = streamInfo else { return }
            Task {
                do {
                    try await env.cast.cast(to: device, stream: info, title: title)
                    session.pause()  // 本机转遥控
                } catch { /* lastError 已在 CastService 发布 */ }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isConnected ? "checkmark.tv.fill" : "tv")
                    .foregroundStyle(isConnected ? Color.dsAccent : Color.dsInk2)
                Text(device.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.dsInk)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer()
                Text(isConnected ? "已连接" : device.kindLabel)
                    .font(.dsCaption).foregroundStyle(isConnected ? Color.dsAccent : Color.dsInk2)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14)
                .fill(isConnected ? Color.dsAccent.opacity(0.12) : Color.dsGlassBorder))
        }
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(.dsAccent)
            Text(title).font(.system(size: 14, weight: .heavy)).foregroundStyle(.dsInk)
        }
    }
}

// MARK: - 系统路由选择器（AirPlay 图标，AVKit 原生）

struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .systemBlue
        view.prioritizesVideoDevices = true
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
