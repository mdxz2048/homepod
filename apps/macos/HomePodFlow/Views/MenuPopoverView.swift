import SwiftUI

// 1:1 replica of the theater layout popover. All geometry is a uniform scale
// of the 1122x1402 reference canvas (factor 360/1122). The five regions are
// rebuilt natively; only the HomePod artwork, the two minis and the app logo
// are isolated/masked PNG layers from Assets.xcassets.
struct MenuPopoverView: View {
    @Bindable var state: AppState
    var onOpenSettings: () -> Void

    /// Single source of the natural fixed canvas; the debug capture host and
    /// the production MenuBarExtra host share exactly this size.
    static let naturalSize = CGSize(width: Theater.canvas.width, height: Theater.canvas.height)

    var body: some View {
        ZStack(alignment: .topLeading) {
            pointer
            panelField
            header
            modePicker
            theaterCard
            volumeRow
            settingsRow
        }
        .frame(width: Theater.canvas.width, height: Theater.canvas.height, alignment: .topLeading)
        .background(LinearGradient(colors: [Theater.fieldTop, Theater.fieldBottom],
                                   startPoint: .top, endPoint: .bottom))
        .environment(\.colorScheme, .light)
    }

    // MARK: - Outer pale blue field with smooth pointer
    private var pointer: some View {
        PointerShape()
            .fill(LinearGradient(colors: [Theater.fieldTop, Theater.panelTop],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(PointerShape()
                .stroke(Theater.fieldBorder, lineWidth: 0.75))
            .frame(width: Theater.P(100), height: Theater.P(36))
            .offset(x: Theater.P(511), y: Theater.P(15))
    }

    // MARK: - Panel background
    private var panelField: some View {
        RoundedRectangle(cornerRadius: Theater.P(39), style: .continuous)
            .fill(LinearGradient(colors: [Theater.panelTop, Theater.panelBottom],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: Theater.P(39), style: .continuous)
                .stroke(Theater.panelBorder, lineWidth: 1))
            .frame(width: Theater.P(1028), height: Theater.P(1299))
            .offset(x: Theater.P(47), y: Theater.P(49))
            .shadow(color: Theater.panelShadow, radius: Theater.P(18), x: 0, y: Theater.P(6))
            .shadow(color: Color.white.opacity(0.55), radius: 1, x: 0, y: 1)
    }

    // MARK: - Header (logo, title, subtitle, toggle)
    private var header: some View {
        ZStack(alignment: .topLeading) {
            Image("app_logo").resizable().interpolation(.high)
                .frame(width: Theater.P(116), height: Theater.P(114))
                .offset(x: Theater.P(93), y: Theater.P(91))

            Text("HomePod Flow")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theater.ink)
                .lineLimit(1)
                .frame(width: Theater.P(464), height: Theater.P(48), alignment: .leading)
                .offset(x: Theater.P(235), y: Theater.P(97) - 1.5)

            Text(subtitleText)
                .font(.system(size: 10.5, weight: .regular))
                .foregroundStyle(Theater.gray)
                .lineLimit(1)
                .frame(width: Theater.P(472), height: Theater.P(30), alignment: .leading)
                .offset(x: Theater.P(236), y: Theater.P(160))

            Toggle("系统声音", isOn: state.visualDemo ? demoRunningBinding : systemAudioBinding)
                .labelsHidden()
                .toggleStyle(TheaterToggleStyle())
                .frame(width: Theater.P(138), height: Theater.P(68))
                .offset(x: Theater.P(887), y: Theater.P(114))
                .disabled(!state.visualDemo && !state.systemAudio.desiredEnabled &&
                          (state.systemAudio.isBusy || state.layout.devices.isEmpty ||
                           !state.audioComponent.allowsStart))
                .accessibilityLabel(state.visualDemo
                    ? (state.isRunning ? "系统声音演示运行中" : "系统声音演示已停止")
                    : "系统声音")
                .accessibilityValue(state.visualDemo
                    ? (state.isRunning ? "开" : "关")
                    : (state.systemAudio.desiredEnabled ? "开" : "关"))
                .help(toggleHelp)
        }
    }

    private var subtitleText: String {
        if state.visualDemo { return "界面演示 · 3 台示例设备" }
        switch state.audioComponent.snapshot.state {
        case .notInstalled: return "需要安装音频组件"
        case .installedNeedsReload: return "音频组件等待加载"
        case .conflict: return "音频组件有冲突"
        case .invalid: return "音频组件需要修复"
        case .checking, .ready: break
        }
        let status = state.systemAudio.statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !status.isEmpty { return status }
        return state.statusText
    }

    private var toggleHelp: String {
        if state.visualDemo {
            return "演示开关只改变界面状态，不会接管真实音频。"
        }
        if !state.audioComponent.allowsStart {
            return "系统声音 · \(state.audioComponent.snapshot.message)"
        }
        let status = state.systemAudio.statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        return "系统声音 · \(state.deviceCount) 台设备" + (status.isEmpty ? "" : " · \(status)")
    }

    private var demoRunningBinding: Binding<Bool> {
        Binding(get: { state.isRunning }, set: { running in
            guard state.visualDemo else { return }
            state.setRunning(running)
        })
    }

    private var systemAudioBinding: Binding<Bool> {
        Binding(get: { state.systemAudio.desiredEnabled }, set: { enabled in
            if enabled { Task { await state.startSystemAudio() } }
            else { state.systemAudio.requestStop() }
        })
    }

    // MARK: - Mode picker
    private var modePicker: some View {
        HStack(spacing: Theater.P(3)) {
            ModeSegmentButton(selected: state.mode == .cinema, title: "影院模式") { select(.cinema) }
            ModeSegmentButton(selected: state.mode == .synchronized, title: "同步播放") { select(.synchronized) }
        }
        .padding(.horizontal, Theater.P(4))
        .padding(.vertical, Theater.P(6))
        .background(Capsule().fill(Theater.segmentTrack))
        .overlay(Capsule().stroke(Color.white.opacity(0.75), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1)
        .frame(width: Theater.P(519), height: Theater.P(81))
        .offset(x: Theater.P(302), y: Theater.P(235))
        .disabled(state.sessionControlsLocked)
    }

    private func select(_ mode: PlaybackMode) {
        guard !state.sessionControlsLocked else { return }
        state.mode = mode
    }

    // MARK: - Theater card
    private var theaterCard: some View {
        ZStack(alignment: .topLeading) {
            cardBackground
            if state.visualDemo {
                demoCardContent
            } else {
                RoomCanvas(layout: .constant(state.layout),
                           selectedDeviceID: $state.selectedDeviceID,
                           editable: false, compact: false, showsDeviceLabels: false)
                    .frame(width: Theater.P(956), height: Theater.P(709))
            }
        }
        .frame(width: Theater.P(956), height: Theater.P(709))
        .clipShape(RoundedRectangle(cornerRadius: Theater.P(40), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theater.P(40), style: .continuous)
            .stroke(Color.white, lineWidth: Theater.P(2)))
        .shadow(color: Color.black.opacity(0.08), radius: 5, x: 0, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: Theater.P(40), style: .continuous))
        .onTapGesture { cardTapped() }
        .offset(x: Theater.P(83), y: Theater.P(344))
    }

    private func cardTapped() {
        guard state.mode == .cinema else { return }
        state.selectedPage = .layout
        onOpenSettings()
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Theater.P(40), style: .continuous)
            .fill(LinearGradient(colors: [Theater.cardTop, Theater.cardBottom],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                ZStack(alignment: .topLeading) {
                    ForEach(Theater.rings) { ring in
                        Circle()
                            .fill(Theater.sound.opacity(ring.opacity))
                            .frame(width: Theater.P(ring.radius * 2), height: Theater.P(ring.radius * 2))
                            .position(x: Theater.P(477), y: Theater.P(593))
                    }
                }
            }
    }

    private var demoCardContent: some View {
        ZStack(alignment: .topLeading) {
            tvGlow
            tv
            speakerShadows
            speakers
            sofa
            listener
        }
    }

    private var tvGlow: some View {
        Ellipse()
            .fill(Theater.tvPurple.opacity(0.28))
            .frame(width: Theater.P(430), height: Theater.P(24))
            .blur(radius: Theater.P(10))
            .position(x: Theater.P(477), y: Theater.P(120))
    }

    private var tv: some View {
        UnevenRoundedRectangle(topLeadingRadius: Theater.P(14), bottomLeadingRadius: Theater.P(10),
                               bottomTrailingRadius: Theater.P(10), topTrailingRadius: Theater.P(14),
                               style: .continuous)
            .fill(LinearGradient(colors: [Theater.tvViolet, Theater.tvMagenta, Theater.tvBlue],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: Theater.P(504), height: Theater.P(87))
            .overlay(UnevenRoundedRectangle(topLeadingRadius: Theater.P(14), bottomLeadingRadius: Theater.P(10),
                                            bottomTrailingRadius: Theater.P(10), topTrailingRadius: Theater.P(14),
                                            style: .continuous)
                .stroke(Theater.tvFrame, lineWidth: Theater.P(8)))
            .offset(x: Theater.P(309 - 83), y: Theater.P(377 - 344))
    }

    private var speakerShadows: some View {
        ZStack(alignment: .topLeading) {
            Ellipse().fill(Color.black.opacity(0.16))
                .frame(width: Theater.P(146), height: Theater.P(20))
                .blur(radius: 2)
                .position(x: Theater.P(477), y: Theater.P(325))
            Ellipse().fill(Color.black.opacity(0.12))
                .frame(width: Theater.P(86), height: Theater.P(14))
                .blur(radius: 2)
                .position(x: Theater.P(174), y: Theater.P(506))
            Ellipse().fill(Color.black.opacity(0.12))
                .frame(width: Theater.P(86), height: Theater.P(14))
                .blur(radius: 2)
                .position(x: Theater.P(780), y: Theater.P(506))
        }
    }

    private var speakers: some View {
        ZStack(alignment: .topLeading) {
            Image("large_homepod").resizable().interpolation(.high)
                .frame(width: Theater.P(177), height: Theater.P(193))
                .offset(x: Theater.P(472 - 83), y: Theater.P(474 - 344))
            Image("mini_left").resizable().interpolation(.high)
                .frame(width: Theater.P(76), height: Theater.P(74))
                .offset(x: Theater.P(219 - 83), y: Theater.P(769 - 344))
            Image("mini_right").resizable().interpolation(.high)
                .frame(width: Theater.P(76), height: Theater.P(74))
                .offset(x: Theater.P(825 - 83), y: Theater.P(769 - 344))
        }
    }

    // MARK: - Listener and sofa (sofa behind listener)
    private var listener: some View {
        ZStack(alignment: .topLeading) {
            Ellipse()
                .fill(LinearGradient(colors: [Theater.blueDark, Theater.blue],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Ellipse().stroke(Color.white.opacity(0.92), lineWidth: Theater.P(2)))
                .frame(width: Theater.P(79), height: Theater.P(92))
                .position(x: Theater.P(477.5), y: Theater.P(577))

            TheaterEarpiece()
                .frame(width: Theater.P(17), height: Theater.P(34))
                .position(x: Theater.P(434.5), y: Theater.P(579))
            TheaterEarpiece()
                .frame(width: Theater.P(15), height: Theater.P(34))
                .position(x: Theater.P(521.5), y: Theater.P(579))

            Ellipse()
                .fill(Theater.listenerGlow)
                .frame(width: Theater.P(89), height: Theater.P(24))
                .position(x: Theater.P(477.5), y: Theater.P(623))
        }
    }

    private var sofa: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Theater.P(22), style: .continuous)
                .fill(Theater.sofaFill)
                .frame(width: Theater.P(438), height: Theater.P(59))
                .overlay(RoundedRectangle(cornerRadius: Theater.P(22), style: .continuous)
                    .stroke(Color.white.opacity(0.85), lineWidth: Theater.P(2)))
                .shadow(color: Color.black.opacity(0.10), radius: Theater.P(6), x: 0, y: Theater.P(4))
                .offset(x: Theater.P(342 - 83), y: Theater.P(962 - 344))
        }
    }

    // MARK: - Volume row
    private var volumeRow: some View {
        ZStack(alignment: .topLeading) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: Theater.P(46), weight: .regular))
                .foregroundStyle(Theater.gray)
                .frame(width: Theater.P(56), height: Theater.P(42))
                .offset(x: Theater.P(94), y: Theater.P(1103))

            VolumeRail(value: $state.volume)
                .frame(width: Theater.P(721), height: Theater.P(55))
                .offset(x: Theater.P(185), y: Theater.P(1096))

            Text("\(Int(state.volume))%")
                .font(.system(size: Theater.P(40), weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(Theater.ink)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: Theater.P(120), height: Theater.P(44), alignment: .trailing)
                .offset(x: Theater.P(915), y: Theater.P(1107))
        }
    }

    // MARK: - Settings row
    private var settingsRow: some View {
        Button(action: onOpenSettings) {
            HStack(spacing: 0) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(Theater.settingsInk)
                    .frame(width: Theater.P(70), alignment: .leading)
                    .padding(.leading, Theater.P(42))
                Text("设置…")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theater.settingsInk)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theater.gray)
                    .padding(.trailing, Theater.P(41))
            }
            .frame(width: Theater.P(952), height: Theater.P(110))
            .background(RoundedRectangle(cornerRadius: Theater.P(36), style: .continuous)
                .fill(Theater.settingsFill))
            .overlay(RoundedRectangle(cornerRadius: Theater.P(36), style: .continuous)
                .stroke(Color.white.opacity(0.75), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .frame(width: Theater.P(952), height: Theater.P(110))
        .offset(x: Theater.P(85), y: Theater.P(1186))
    }
}

// MARK: - Pointer shape
private struct PointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control: CGPoint(x: rect.minX + rect.width * 0.24, y: rect.minY + rect.height * 0.10))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.maxX - rect.width * 0.24, y: rect.minY + rect.height * 0.10))
        path.closeSubpath()
        return path
    }
}

// MARK: - Custom toggle
private struct TheaterToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let trackWidth = Theater.P(138)
        let trackHeight = Theater.P(68)
        let thumbWidth = Theater.P(75)
        let thumbHeight = Theater.P(57)
        let pad = (trackHeight - thumbHeight) / 2
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? AnyShapeStyle(LinearGradient(colors: [Theater.blueDark, Theater.blue],
                                                                                  startPoint: .top, endPoint: .bottom))
                                                   : AnyShapeStyle(Theater.toggleTrackOff))
                Capsule()
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.18), radius: 2.5, x: 0, y: 1)
                    .frame(width: thumbWidth, height: thumbHeight)
                    .padding(.horizontal, pad)
            }
            .frame(width: trackWidth, height: trackHeight)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .animation(.easeOut(duration: 0.18), value: configuration.isOn)
    }
}

// MARK: - Segments
private struct ModeSegmentButton: View {
    let selected: Bool
    let title: String
    let action: () -> Void

    init(selected: Bool, title: String, action: @escaping () -> Void) {
        self.selected = selected
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.3, weight: .medium))
                .foregroundStyle(selected ? Color.white : Theater.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if selected {
                        Capsule().fill(LinearGradient(colors: [Theater.blueDark, Theater.blue],
                                                      startPoint: .top, endPoint: .bottom))
                    }
                }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

// MARK: - Listener earpiece
private struct TheaterEarpiece: View {
    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Theater.blue)
                .overlay(Capsule().stroke(Color.white.opacity(0.9), lineWidth: max(1, proxy.size.width * 0.10)))
        }
    }
}

// MARK: - Volume rail
private struct VolumeRail: View {
    @Binding var value: Double

    private var width: CGFloat { Theater.P(721) }
    private var railHeight: CGFloat { Theater.P(18) }
    private var knob: CGFloat { Theater.P(54) }
    private var railTopOffset: CGFloat { Theater.P(1106 - 1087) }
    private var radius: CGFloat { Theater.P(27) }

    private var fraction: CGFloat {
        CGFloat(min(max(value, 0), 100) / 100)
    }

    private var knobCenterX: CGFloat {
        radius + fraction * (width - knob)
    }

    private var fillWidth: CGFloat {
        // The reference blue fill stops a little short of the thumb at 55%.
        max(knobCenterX - Theater.P(10), radius)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Capsule().fill(Theater.track)
                .frame(width: width, height: railHeight)
                .offset(y: railTopOffset)
            Capsule().fill(LinearGradient(colors: [Theater.blueDark, Theater.blue],
                                          startPoint: .leading, endPoint: .trailing))
                .frame(width: fillWidth, height: railHeight)
                .offset(y: railTopOffset)
            Circle()
                .fill(Color.white)
                .overlay(Circle().stroke(Color.black.opacity(0.08), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.2), radius: 2.5, x: 0, y: 1)
                .frame(width: knob, height: knob)
                .offset(x: knobCenterX - radius)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            let trackWidth = width - knob
            guard trackWidth > 0 else { return }
            let clamped = min(max(0, drag.location.x - radius), trackWidth)
            value = Double(clamped / trackWidth) * 100
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("音量")
        .accessibilityValue("\(Int(value))%")
        .accessibilityAdjustableAction { direction in
            let step: Double = 5
            switch direction {
            case .increment: value = min(100, max(0, value + step))
            case .decrement: value = min(100, max(0, value - step))
            @unknown default: break
            }
        }
    }
}

// MARK: - Palette and geometry
private enum Theater {
    static let canvas = CGSize(width: 360, height: 450)
    static func P(_ v: CGFloat) -> CGFloat { v * (360.0 / 1122.0) }

    static let ink = Color(red: 38.0 / 255, green: 41.0 / 255, blue: 46.0 / 255)
    static let gray = Color(red: 113.0 / 255, green: 119.0 / 255, blue: 129.0 / 255)
    static let blue = Color(red: 19.0 / 255, green: 118.0 / 255, blue: 255.0 / 255)
    static let blueDark = Color(red: 13.0 / 255, green: 107.0 / 255, blue: 255.0 / 255)

    static let fieldTop = Color(red: 233.0 / 255, green: 239.0 / 255, blue: 249.0 / 255)
    static let fieldBottom = Color(red: 223.0 / 255, green: 231.0 / 255, blue: 245.0 / 255)
    static let fieldBorder = Color(red: 178.0 / 255, green: 188.0 / 255, blue: 207.0 / 255)
    static let panelBorder = Color(red: 194.0 / 255, green: 202.0 / 255, blue: 216.0 / 255).opacity(0.55)
    static let panelShadow = Color(red: 88.0 / 255, green: 124.0 / 255, blue: 190.0 / 255).opacity(0.34)

    static let panelTop = Color(red: 232.0 / 255, green: 237.0 / 255, blue: 249.0 / 255)
    static let panelBottom = Color(red: 220.0 / 255, green: 229.0 / 255, blue: 244.0 / 255)
    static let cardTop = Color(red: 244.0 / 255, green: 248.0 / 255, blue: 253.0 / 255)
    static let cardBottom = Color(red: 230.0 / 255, green: 237.0 / 255, blue: 249.0 / 255)

    static let sound = Color(red: 169.0 / 255, green: 204.0 / 255, blue: 245.0 / 255)
    static let track = Color(red: 215.0 / 255, green: 220.0 / 255, blue: 230.0 / 255)
    static let toggleTrackOff = Color(red: 202.0 / 255, green: 208.0 / 255, blue: 219.0 / 255)
    static let segmentTrack = Color(red: 226.0 / 255, green: 230.0 / 255, blue: 238.0 / 255)

    static let settingsFill = Color(red: 245.0 / 255, green: 248.0 / 255, blue: 252.0 / 255)
    static let settingsInk = Color(red: 51.0 / 255, green: 56.0 / 255, blue: 66.0 / 255)

    static let tvViolet = Color(red: 98.0 / 255, green: 76.0 / 255, blue: 206.0 / 255)
    static let tvMagenta = Color(red: 160.0 / 255, green: 69.0 / 255, blue: 153.0 / 255)
    static let tvBlue = Color(red: 17.0 / 255, green: 115.0 / 255, blue: 246.0 / 255)
    static let tvFrame = Color(red: 53.0 / 255, green: 58.0 / 255, blue: 70.0 / 255)
    static let tvPurple = Color(red: 126.0 / 255, green: 96.0 / 255, blue: 230.0 / 255)

    static let sofaFill = Color(red: 151.0 / 255, green: 165.0 / 255, blue: 198.0 / 255).opacity(0.52)
    static let listenerGlow = Color(red: 61.0 / 255, green: 151.0 / 255, blue: 255.0 / 255)

    /// Filled concentric sound-field discs, inner layer strongest.
    static let rings: [RingSpec] = [
        RingSpec(id: 0, radius: 440, opacity: 0.10),
        RingSpec(id: 1, radius: 359, opacity: 0.15),
        RingSpec(id: 2, radius: 271, opacity: 0.22),
        RingSpec(id: 3, radius: 185, opacity: 0.32)
    ]
}

private struct RingSpec: Identifiable {
    let id: Int
    let radius: CGFloat
    let opacity: Double
}
