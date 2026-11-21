import SwiftUI

struct CalibrationSection: View {
    @Bindable var state: AppState
    private var calibrated: Bool { state.calibration.residuals(for: state.layout) != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path").font(.title2).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text("无线音频同步").font(.callout.bold())
                Text(calibrated ? "已保存每台音箱的延迟 · 影院播放时自动补偿"
                     : (state.calibration.saved == nil ? "测量声音抵达的时间，让音箱与画面合拍。" : "音箱或布局已变化 · 请重新测试"))
                    .font(.caption).foregroundStyle(.secondary)
                if state.hasUnsavedLayout { Text("请先保存布局，再开始测试。").font(.caption).foregroundStyle(.secondary) }
                else if state.sessionControlsLocked && !state.calibration.isBusy {
                    Text("请先关闭系统声音，再开始测试。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(calibrated ? "重新测试…" : "测试延迟…") {
                state.openCalibration()
            }
            .disabled(state.sessionControlsLocked || state.hasUnsavedLayout || state.layout.devices.isEmpty)
        }
        if calibrated, let saved = state.calibration.saved {
            DisclosureGroup("查看已保存的校准") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(saved.measurements) { measurement in
                        HStack {
                            Text(measurement.name)
                            Spacer()
                            Text("实测 \(measurement.measuredMS, specifier: "%.1f") ms · 补偿 +\(saved.compensationMS(for: measurement), specifier: "%.1f") ms")
                                .monospacedDigit()
                        }.font(.caption)
                    }
                    HStack {
                        Text(saved.savedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("清除校准") { state.calibration.clear() }
                            .font(.caption).disabled(state.sessionControlsLocked)
                    }.padding(.top, 3)
                }.padding(.top, 8)
            }.font(.caption)
        }
        }
        .padding(14)
        .background(.blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct CalibrationSheet: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var store: CalibrationStore { state.calibration }
    private var profile: AcousticCalibrationProfile? { store.candidate }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("HOMEPOD FLOW", systemImage: "waveform").font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(2.5)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Text("无线音频同步").font(.caption).foregroundStyle(.white.opacity(0.5))
            }.padding(.horizontal, 30).padding(.top, 25)
            Text(profile == nil ? "让每一拍，同时抵达。" : "声音，已找到共同节奏。")
                .font(.system(size: 27, weight: .semibold)).padding(.top, 28)
            Text(store.phase).font(.callout).foregroundStyle(.white.opacity(0.6)).padding(.top, 9)
                .accessibilityAddTraits(.updatesFrequently)
            speakerStage.frame(height: 220)
            VStack(spacing: 14) {
                if let profile {
                    results(profile)
                } else if store.isBusy {
                    ProgressView(value: store.progress).tint(.white).padding(.horizontal, 30)
                    Text("正在使用 \(store.microphoneName) · 当前音量 \(Int(store.currentVolume))%")
                        .font(.caption).foregroundStyle(.white.opacity(0.55))
                    Text("每台连续测量 8 秒、分析 12 个时间窗口，请保持位置不变。")
                        .font(.caption).foregroundStyle(.white.opacity(0.4))
                } else {
                    VStack(spacing: 8) {
                        Text("将 Mac 放在日常听音的位置，保持房间安静。")
                        Text("已绑定的 \(state.layout.devices.count) 台音箱将依次播放 8 秒宽带测试音。")
                        Text("测试通过后自动保存，并在影院播放时加载。")
                    }.font(.callout).foregroundStyle(.white.opacity(0.65))
                    Text("录音只在本机临时分析，结束后删除。")
                        .font(.caption).foregroundStyle(.white.opacity(0.4))
                }
                if !store.isBusy {
                    VStack(spacing: 7) {
                        HStack {
                            Text("录音麦克风")
                            Spacer()
                            Picker("录音麦克风", selection: Binding(
                                get: { store.microphoneUID ?? "" },
                                set: { store.setMicrophone($0.isEmpty ? nil : $0) })) {
                                Text("自动（内置优先）").tag("")
                                ForEach(store.microphones) { mic in Text(mic.name).tag(mic.id) }
                            }.pickerStyle(.menu).labelsHidden().accessibilityLabel("录音麦克风")
                        }
                        Text("iPhone 靠近听音位置时选它；它经 Mac 时钟录音，无需另对对时。")
                            .font(.caption).foregroundStyle(.white.opacity(0.45))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.horizontal, 40)
                }
                if !store.isBusy {
                    VStack(spacing: 7) {
                        Picker("测试音", selection: Binding(get: { store.probeKind },
                                                         set: { store.setProbeKind($0) })) {
                            ForEach(ProbeKind.allCases) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }.pickerStyle(.segmented).labelsHidden()
                        .accessibilityLabel("测试音类型")
                        Text(store.probeKind.detail)
                            .font(.caption).foregroundStyle(.white.opacity(0.45))
                    }.padding(.horizontal, 40)
                }
                if !store.isBusy {
                    VStack(spacing: 7) {
                        HStack {
                            Text("测试音量")
                            Spacer()
                            Text("\(Int(store.testVolume))%").monospacedDigit()
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "speaker.fill")
                            Slider(value: Binding(get: { store.testVolume }, set: { store.setTestVolume($0) }),
                                   in: CalibrationStore.volumeRange, step: 1)
                                .accessibilityLabel("测试音量")
                                .accessibilityValue("\(Int(store.testVolume))%")
                            Image(systemName: "speaker.wave.3.fill")
                        }
                        Text("记住上次音量；测试中保持固定。需要调整时，请先停止再重测。")
                            .font(.caption).foregroundStyle(.white.opacity(0.45))
                    }.font(.callout).padding(.horizontal, 40)
                }
                if !store.errorText.isEmpty {
                    Label(store.errorText, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                }
            }.frame(minHeight: 110)
            Spacer(minLength: 20)
            HStack(spacing: 12) {
                if store.isBusy {
                    Button("停止测试") { store.cancel() }.controlSize(.large)
                } else {
                    Button("关闭") { dismiss() }.controlSize(.large)
                    if profile != nil {
                        Button("重新测试") { store.begin(layout: state.layout) }.controlSize(.large)
                        Button("完成") { dismiss() }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    } else {
                        Button(store.errorText.isEmpty ? "开始测试" : "重试未完成的测试") { store.begin(layout: state.layout) }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(state.sessionControlsLocked || state.hasUnsavedLayout)
                    }
                }
            }.padding(.bottom, 28)
        }
        .frame(width: 680, height: 740)
        .onAppear { store.refreshMicrophones() }
        .foregroundStyle(.white)
        .background(Color(red: 0.035, green: 0.04, blue: 0.055))
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(store.isBusy)

    }

    private var speakerStage: some View {
        GeometryReader { geometry in
            ZStack {
                VStack {
                    Capsule().fill(.white.opacity(0.12)).frame(width: 150, height: 2)
                    Text("屏幕方向").font(.system(size: 9)).tracking(2).foregroundStyle(.white.opacity(0.3))
                    Spacer()
                }.padding(.top, 8)
                ForEach(Array(state.layout.devices.enumerated()), id: \.element.id) { index, device in
                    let active = store.activeDeviceID == device.id || store.verifying || profile != nil
                    let done = store.completed.contains { $0.id == device.id }
                    let colors: [Color] = [.cyan, .orange, .indigo, .pink, .mint, .purple, .yellow, .green]
                    VStack(spacing: 5) {
                        ZStack {
                            if active && (store.pulseIndex >= 0 || profile != nil) {
                                CalibrationRipples(animate: !reduceMotion, color: colors[index % colors.count])
                                    .frame(width: 155, height: 110)
                            }
                            Ellipse().fill(.black.opacity(0.45)).frame(width: 65, height: 10).blur(radius: 7).offset(y: 32)
                            SpeakerGlyph(kind: device.kind).frame(width: 48, height: 68)
                                .opacity(active || done || !store.isBusy ? 1 : 0.32)
                            if done {
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 15))
                                    .foregroundStyle(.green, .black).offset(x: 30, y: 25)
                            }
                        }.frame(height: 72)
                        Text(device.name).font(.caption.weight(.medium)).lineLimit(1)
                            .foregroundStyle(active || done || !store.isBusy ? .white : .white.opacity(0.4))
                        Text(store.verifying ? (store.emitting ? "逐台复验" : "准备复验") : (done ? "测量完成" : (active ? (store.emitting ? "正在聆听" : "准备中") : "等待测试")))
                            .font(.system(size: 9)).foregroundStyle(active ? colors[index % colors.count] : .white.opacity(0.4))
                    }.frame(width: 140)
                    .position(x: 80 + device.position.x * (geometry.size.width - 160),
                              y: 26 + device.position.y * (geometry.size.height - 62))
                    .accessibilityElement(children: .combine)
                }
            }
        }.padding(.horizontal, 16)
    }

    private func results(_ profile: AcousticCalibrationProfile) -> some View {
        ScrollView {
            VStack(spacing: 8) {
                HStack {
                    Text("音箱"); Spacer(); Text("实测延迟").frame(width: 95); Text("同步补偿").frame(width: 95)
                }.font(.caption).foregroundStyle(.white.opacity(0.4))
                ForEach(profile.measurements) { measured in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(measured.name)
                            if let count = measured.sampleCount {
                                Text("\(count) 个时间窗口 · 波动 \(measured.spreadMS, specifier: "%.1f") ms · 匹配度 \(Int((measured.confidence * 100).rounded()))%")
                                    .font(.caption2).foregroundStyle(.white.opacity(0.5))
                            }
                        }
                        Spacer()
                        Text("\(measured.measuredMS, specifier: "%.1f") ms").frame(width: 95)
                        Text("+\(profile.compensationMS(for: measured), specifier: "%.1f") ms").frame(width: 95)
                    }.font(.callout.monospacedDigit())
                }
                Text("已自动保存并写入声卡；以后开启影院模式会自动应用。")
                    .font(.caption).foregroundStyle(.white.opacity(0.45)).padding(.top, 5)
            }.padding(.horizontal, 40)
        }.frame(height: min(190, 70 + CGFloat(profile.measurements.count) * 42))
    }
}

private struct CalibrationRipples: View {
    var animate: Bool
    var color: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animate)) { timeline in
            let time = animate ? timeline.date.timeIntervalSinceReferenceDate : 0.6
            Canvas { context, size in
                context.translateBy(x: size.width / 2, y: size.height / 2)
                context.rotate(by: .degrees(-9))
                for ring in 0..<3 {
                    let phase = (time / 1.7 + Double(ring) * 0.09).truncatingRemainder(dividingBy: 1)
                    let radius = 24 + phase * 44
                    let rect = CGRect(x: -radius, y: -radius * 0.31, width: radius * 2, height: radius * 0.62)
                    let ellipse = Path(ellipseIn: rect)
                    context.drawLayer { glow in
                        glow.addFilter(.blur(radius: 4))
                        glow.stroke(ellipse, with: .color(color.opacity((1 - phase) * 0.55)), lineWidth: 6)
                    }
                    context.stroke(ellipse, with: .color(color.opacity((1 - phase) * 0.85)), lineWidth: 1.8)
                }
            }
        }.accessibilityHidden(true)
    }
}
