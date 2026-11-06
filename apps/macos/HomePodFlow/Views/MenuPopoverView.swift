import SwiftUI

struct MenuPopoverView: View {
    @Bindable var state: AppState
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 15) {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 24, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading,
                                               endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("HomePod Flow").font(.system(size: 19, weight: .bold))
                    Text(state.systemAudio.statusText)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 3)
                Toggle("系统声音", isOn: Binding(get: { state.systemAudio.desiredEnabled }, set: { enabled in
                    if enabled { Task { await state.startSystemAudio() } }
                    else { state.systemAudio.requestStop() }
                }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.regular)
                    .disabled(!state.systemAudio.desiredEnabled &&
                              (state.systemAudio.isBusy || state.layout.devices.isEmpty))
            }

            Picker("播放模式", selection: $state.mode) {
                Label("影院模式", systemImage: "film").tag(PlaybackMode.cinema)
                Label("同步播放", systemImage: "dot.radiowaves.left.and.right").tag(PlaybackMode.synchronized)
            }.labelsHidden().pickerStyle(.segmented).controlSize(.large).tint(.blue)
                .disabled(state.sessionControlsLocked)

            RoomCanvas(layout: .constant(state.layout), selectedDeviceID: .constant(nil), compact: true)
                .frame(height: 272)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard state.mode == .cinema else { return }
                    state.selectedPage = .layout
                    onOpenSettings()
                }
                .help(state.mode == .cinema ? "打开空间布局" : "同步播放不使用空间位置，布局只读")
                .accessibilityLabel("房间布局预览")

            if state.layout.devices.isEmpty {
                Button("设置音箱…") { onOpenSettings() }
            }
            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2.fill").font(.title3).foregroundStyle(.secondary)
                Slider(value: $state.volume, in: 0...100, step: 1).accessibilityLabel("音量")
                Text("\(Int(state.volume))%")
                    .font(.system(.body, design: .rounded).monospacedDigit()).frame(width: 40, alignment: .trailing)
            }

            Divider()
            AVOffsetControl(value: $state.avOffsetMS).disabled(true)
                .help("系统声音的音画偏移尚未接入；此控件当前不可用")
            Text(state.systemAudio.volumeStatus.isEmpty ? "系统声音 · 音画延迟暂不可用" : state.systemAudio.volumeStatus)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onOpenSettings) {
                HStack {
                    Label("设置…", systemImage: "gearshape").font(.body.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }.padding(12).contentShape(Rectangle())
            }.buttonStyle(.plain).flowCard()
        }
        .padding(17).frame(width: 372)
        .background(.regularMaterial)
    }
}

struct AVOffsetControl: View {
    @Binding var value: Double
    private var bounded: Binding<Double> {
        Binding(get: { value }, set: { value = $0.isFinite ? min(3500, max(-3500, $0)) : 0 })
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Label("音画延迟", systemImage: "clock").font(.system(size: 12, weight: .medium))
                .padding(.top, 4)
            VStack(spacing: 2) {
                Slider(value: bounded, in: -3500...3500, step: 1).accessibilityLabel("音画延迟，毫秒")
                HStack {
                    Text("−3.500 s")
                    Spacer()
                    Text("+3.500 s")
                }.font(.system(size: 9)).foregroundStyle(.secondary)
            }
            HStack(spacing: 2) {
                TextField("0", value: bounded, format: .number.precision(.fractionLength(0)))
                    .multilineTextAlignment(.trailing).textFieldStyle(.plain)
                    .accessibilityLabel("音画延迟数值，负3500到3500毫秒")
                Text("ms").foregroundStyle(.secondary)
            }.font(.system(size: 11).monospacedDigit()).padding(6)
                .frame(width: 76).flowCard()
        }
    }
}
