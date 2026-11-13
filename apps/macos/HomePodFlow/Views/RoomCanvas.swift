import SwiftUI

/// Shared normalized-coordinate renderer for both the popover and the editor.
struct RoomCanvas: View {
    @Binding var layout: RoomLayout
    @Binding var selectedDeviceID: UUID?
    var editable: Bool = false
    var compact: Bool = false
    var showsDeviceLabels: Bool = true

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                RoomBackground(listener: CGPoint(x: layout.listener.x * size.width,
                                                 y: layout.listener.y * size.height))
                ForEach(layout.devices) { device in
                    speaker(device, size: size)
                }
                ListenerGlyph()
                    .frame(width: compact ? 36 : 52, height: compact ? 42 : 60)
                    .position(x: layout.listener.x * size.width, y: layout.listener.y * size.height)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("room")).onChanged { value in
                        guard editable else { return }
                        layout.listener = point(value.location, size: size)
                    }, including: editable ? .all : .none)
                    .accessibilityLabel("听音位置，朝向前方电视")
            }
            .coordinateSpace(name: "room")
        }
        .clipShape(RoundedRectangle(cornerRadius: compact ? 12 : 16))
        .overlay(RoundedRectangle(cornerRadius: compact ? 12 : 16).stroke(FlowStyle.border))
        .accessibilityElement(children: .contain)
    }

    private func point(_ location: CGPoint, size: CGSize) -> RoomPoint {
        RoomPoint(x: min(0.92, max(0.08, location.x / size.width)),
                  y: min(0.91, max(0.18, location.y / size.height)))
    }

    private func speaker(_ device: RoomDevice, size: CGSize) -> some View {
        /* Official product photography, drawn at a consistent physical scale:
         * HomePod is 168 mm tall, mini is 84 mm, so mini renders at ~0.68 of
         * the HomePod height (true ratio 0.5 would be too small to read here). */
        let photoHeight: CGFloat = compact ? 38 : 58
        let glyphSize: CGSize = device.kind.form == .homePod
            ? CGSize(width: photoHeight * 0.74, height: photoHeight)
            : CGSize(width: photoHeight * 0.62 * 1.058, height: photoHeight * 0.62)
        /* The halo is an editing affordance only: it shows which speaker the
         * inspector edits, so the read-only status-bar canvas never draws it. */
        let selected = editable && selectedDeviceID == device.id
        let haloRadius = min(glyphSize.width, glyphSize.height) * 0.5
        return VStack(spacing: compact ? 4 : 7) {
            SpeakerGlyph(kind: device.kind)
                .frame(width: glyphSize.width, height: glyphSize.height)
                .padding(4)
                .overlay(
                    RoundedRectangle(cornerRadius: haloRadius, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.12) : .clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: haloRadius, style: .continuous)
                                .stroke(selected ? Color.accentColor : .clear,
                                        lineWidth: 1.5)))
            Text(device.name)
                .font(.system(size: compact ? 10 : 12, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, compact ? 6 : 9).padding(.vertical, 4)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                .opacity(showsDeviceLabels ? 1 : 0)
                .accessibilityHidden(!showsDeviceLabels)
        }
        .position(x: device.position.x * size.width, y: device.position.y * size.height)
        .onTapGesture { if editable { selectedDeviceID = device.id } }
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("room")).onChanged { value in
            guard editable, let index = layout.devices.firstIndex(where: { $0.id == device.id }) else { return }
            selectedDeviceID = device.id
            layout.devices[index].position = point(value.location, size: size)
        }, including: editable ? .all : .none)
        .accessibilityLabel("\(device.name)，\(roleLabel(device.role))")
        .accessibilityHint(editable ? "在设备列表中可精确调整位置" : "布局预览")
    }
}

func roleLabel(_ role: SpeakerRole) -> String {
    switch role {
    case .front: "前方"
    case .rearLeft: "后方 · 左"
    case .rearRight: "后方 · 右"
    }
}

/// Official Apple product photography (transparent PNG), normalised so every
/// finish is framed identically. Sizes come from `speaker(_:size:)`, which
/// scales HomePod and mini to a consistent physical ratio.
struct SpeakerGlyph: View {
    var kind: SpeakerKind

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Ellipse()
                    .fill(Color.black.opacity(0.16))
                    .frame(width: size.width * 0.72, height: max(3, size.height * 0.06))
                    .blur(radius: max(1, size.width * 0.03))
                    .position(x: size.width * 0.5, y: size.height * 0.97)
                Image(kind.assetName)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .frame(width: size.width, height: size.height)
            }
        }
        .accessibilityHidden(true)
    }
}

extension SpeakerKind {
    /// Asset-catalog image for each finish, cut from Apple's store photography.
    var assetName: String {
        switch self {
        case .homePod: "speaker-homepod-white"
        case .homePodMidnight: "speaker-homepod-midnight"
        case .mini: "speaker-mini-white"
        case .miniMidnight: "speaker-mini-midnight"
        case .miniYellow: "speaker-mini-yellow"
        case .miniOrange: "speaker-mini-orange"
        case .miniBlue: "speaker-mini-blue"
        case .miniGreen: "speaker-mini-green"
        case .miniPink: "speaker-mini-pink"
        }
    }
}

struct ListenerGlyph: View {
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack {
                Ellipse().fill(Color.blue.opacity(0.75)).frame(width: width * 0.76, height: height * 0.22)
                    .offset(y: height * 0.38)
                HStack(spacing: width * 0.56) {
                    Ellipse().fill(Color.blue.opacity(0.85)).frame(width: width * 0.16, height: height * 0.26)
                    Ellipse().fill(Color.blue.opacity(0.85)).frame(width: width * 0.16, height: height * 0.26)
                }.overlay {
                    HStack(spacing: width * 0.56) {
                        Ellipse().stroke(.white.opacity(0.9)).frame(width: width * 0.16, height: height * 0.26)
                        Ellipse().stroke(.white.opacity(0.9)).frame(width: width * 0.16, height: height * 0.26)
                    }
                }
                Ellipse().fill(LinearGradient(colors: [.blue.opacity(0.65), .blue.opacity(0.95)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: width * 0.67, height: height * 0.81)
                    .overlay(Ellipse().stroke(.white.opacity(0.95), lineWidth: 1.5)
                        .frame(width: width * 0.67, height: height * 0.81))
            }.frame(width: width, height: height)
        }
    }
}

private struct RoomBackground: View {
    let listener: CGPoint
    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            context.fill(Path(bounds), with: .linearGradient(Gradient(colors: [
                Color(nsColor: .windowBackgroundColor), Color.blue.opacity(0.09)
            ]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            let rug = CGRect(x: size.width * 0.1, y: size.height * 0.27,
                             width: size.width * 0.8, height: size.height * 0.7)
            context.fill(Path(roundedRect: rug, cornerRadius: 10), with: .color(.primary.opacity(0.035)))
            for radius in [0.17, 0.26, 0.37] {
                let r = size.width * radius
                context.fill(Path(ellipseIn: CGRect(x: listener.x - r, y: listener.y - r,
                                                    width: r * 2, height: r * 2)),
                             with: .color(.blue.opacity(0.045)))
                context.stroke(Path(ellipseIn: CGRect(x: listener.x - r, y: listener.y - r,
                                                      width: r * 2, height: r * 2)),
                               with: .color(.blue.opacity(0.15)), lineWidth: 1)
            }
            let tv = CGRect(x: size.width * 0.29, y: size.height * 0.04,
                            width: size.width * 0.42, height: size.height * 0.12)
            context.fill(Path(roundedRect: tv, cornerRadius: 4), with: .color(.primary.opacity(0.8)))
            context.fill(Path(roundedRect: tv.insetBy(dx: 3, dy: 3), cornerRadius: 2),
                         with: .linearGradient(Gradient(colors: [.indigo.opacity(0.8), .purple.opacity(0.4), .blue.opacity(0.7)]),
                                               startPoint: tv.origin, endPoint: CGPoint(x: tv.maxX, y: tv.maxY)))
            let sofa = CGRect(x: size.width * 0.26, y: size.height * 0.9,
                              width: size.width * 0.48, height: size.height * 0.07)
            context.fill(Path(roundedRect: sofa, cornerRadius: 7), with: .color(.gray.opacity(0.2)))
            context.stroke(Path(roundedRect: sofa, cornerRadius: 7), with: .color(.white.opacity(0.7)))
        }
    }
}
