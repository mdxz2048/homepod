import Foundation

// MARK: - Channel identity

/// Canonical channel label. The raw value is the contract token (for example
/// `FL`, `LFE`, `SL`, `BL`). `L`/`R` are endpoint-pair outputs only and never
/// appear in a container or source channel order.
public struct ChannelLabel: RawRepresentable, Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static let m = ChannelLabel("M")
    public static let fl = ChannelLabel("FL")
    public static let fr = ChannelLabel("FR")
    public static let fc = ChannelLabel("FC")
    public static let lfe = ChannelLabel("LFE")
    public static let sl = ChannelLabel("SL")
    public static let sr = ChannelLabel("SR")
    public static let bl = ChannelLabel("BL")
    public static let br = ChannelLabel("BR")
    public static let tfl = ChannelLabel("TFL")
    public static let tfr = ChannelLabel("TFR")
    public static let trl = ChannelLabel("TRL")
    public static let trr = ChannelLabel("TRR")

    /// Endpoint-plan output label for the left half of a HomePod stereo pair.
    public static let left = ChannelLabel("L")
    /// Endpoint-plan output label for the right half of a HomePod stereo pair.
    public static let right = ChannelLabel("R")

    public static func unknown(_ index: Int) -> ChannelLabel {
        ChannelLabel("unknown_\(index)")
    }

    public static let canonical: Set<ChannelLabel> = [
        .m, .fl, .fr, .fc, .lfe, .sl, .sr, .bl, .br, .tfl, .tfr, .trl, .trr
    ]

    public var isCanonical: Bool {
        Self.canonical.contains(self)
    }

    public var isPlaceholder: Bool {
        rawValue.hasPrefix("unknown_")
    }

    public var description: String { rawValue }

    public static func < (lhs: ChannelLabel, rhs: ChannelLabel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Layouts

/// Fixed layout tokens from contract §3.1. `unknown` and
/// `surround51Ambiguous` are source-only descriptors; the RES height tokens
/// are reserved and rejected by this model.
public enum ChannelLayout: String, Codable, Sendable, CaseIterable {
    case mono
    case stereo
    case surround30 = "3_0"
    case quad40 = "4_0"
    case surround51Side = "5_1_side"
    case surround51Back = "5_1_back"
    case surround71 = "7_1"
    case surround51Ambiguous = "5_1_ambiguous"
    case height512 = "5_1_2"
    case height712 = "7_1_2"
    case height714 = "7_1_4"
    case unknown

    /// Canonical interleaved order. `unknown` has no canonical order and
    /// returns an empty array; callers must supply an explicit order.
    public var channelOrder: [ChannelLabel] {
        switch self {
        case .mono: [.m]
        case .stereo: [.fl, .fr]
        case .surround30: [.fl, .fr, .fc]
        case .quad40: [.fl, .fr, .bl, .br]
        case .surround51Side: [.fl, .fr, .fc, .lfe, .sl, .sr]
        case .surround51Back: [.fl, .fr, .fc, .lfe, .bl, .br]
        case .surround71: [.fl, .fr, .fc, .lfe, .sl, .sr, .bl, .br]
        case .height512: [.fl, .fr, .fc, .lfe, .sl, .sr, .tfl, .tfr]
        case .height712: [.fl, .fr, .fc, .lfe, .sl, .sr, .bl, .br, .tfl, .tfr]
        case .height714: [.fl, .fr, .fc, .lfe, .sl, .sr, .bl, .br, .tfl, .tfr, .trl, .trr]
        case .surround51Ambiguous, .unknown: []
        }
    }

    public var channelCount: Int {
        channelOrder.count
    }

    public var isHeight: Bool {
        switch self {
        case .height512, .height712, .height714: true
        default: false
        }
    }

    /// R1 container layouts. No ambiguous, unknown or RES height token may be
    /// used as a container identity.
    public var isR1Container: Bool {
        switch self {
        case .mono, .stereo, .surround30, .quad40,
             .surround51Side, .surround51Back, .surround71:
            true
        default:
            false
        }
    }

    /// R1 source layouts that have a defined route plan.
    public var isR1Source: Bool {
        isR1Container
    }

    public var displayName: String {
        switch self {
        case .mono: "单声道"
        case .stereo: "立体声"
        case .surround30: "3.0"
        case .quad40: "4.0"
        case .surround51Side: "5.1 Side"
        case .surround51Back: "5.1 Back"
        case .surround71: "7.1"
        case .surround51Ambiguous: "5.1（环绕位置未确认）"
        case .height512: "5.1.2"
        case .height712: "7.1.2"
        case .height714: "7.1.4"
        case .unknown: "未知布局"
        }
    }
}

// MARK: - Source descriptor

public enum SourceAuthority: String, Codable, Sendable, CaseIterable {
    case decoder
    case playerOutput = "player_output"
    case device
    case userOverride = "user_override"
    case none
}

public enum SourceOrigin: String, Codable, Sendable, CaseIterable {
    case decoder
    case playerOutput = "player_output"
    case osMix = "os_mix"
    case userOverride = "user_override"
    case unknown
}

public enum UpstreamTransform: String, Codable, Sendable, CaseIterable {
    case noneKnown = "none_known"
    case playerMapPossible = "player_map_possible"
    case playerDownmixPossible = "player_downmix_possible"
    case playerUpmixPossible = "player_upmix_possible"
    case osMixPossible = "os_mix_possible"
    case unknown
}

/// Contract §4.1 SourceLayoutDescriptor.
///
/// `nativeClaim` is derived, never trusted from input: only
/// `decoder + verified` or `device + verified` on an R1 source layout may
/// claim source-native. This says nothing about containers or endpoints.
public struct SourceLayout: Codable, Equatable, Sendable {
    public var channels: Int
    public var layout: ChannelLayout
    public var channelOrder: [ChannelLabel]
    public var authority: SourceAuthority
    public var origin: SourceOrigin
    public var verified: Bool
    public var upstreamTransform: UpstreamTransform
    public var evidence: String?

    public var schemaVersion: Int { 2 }

    public var nativeClaim: Bool {
        guard verified, layout.isR1Source else { return false }
        switch authority {
        case .decoder, .device: return true
        case .playerOutput, .userOverride, .none: return false
        }
    }

    public init(
        layout: ChannelLayout,
        authority: SourceAuthority = .none,
        origin: SourceOrigin = .unknown,
        verified: Bool = false,
        upstreamTransform: UpstreamTransform = .unknown,
        evidence: String? = nil,
        channelOrder: [ChannelLabel]? = nil
    ) throws {
        let order: [ChannelLabel]
        switch layout {
        case .unknown:
            guard let channelOrder, !channelOrder.isEmpty else {
                throw MultichannelModelError.missingChannelOrder(layout)
            }
            order = channelOrder
        case .surround51Ambiguous:
            order = channelOrder ?? [.fl, .fr, .fc, .lfe, .unknown(5), .unknown(6)]
        default:
            let canonical = layout.channelOrder
            if let channelOrder, channelOrder != canonical {
                throw MultichannelModelError.channelOrderMismatch(layout)
            }
            order = canonical
        }

        guard MultichannelModelError.allowedChannelCounts.contains(order.count) else {
            throw MultichannelModelError.invalidChannelCount(order.count)
        }
        guard Set(order).count == order.count else {
            throw MultichannelModelError.duplicateChannelLabel
        }
        if let evidence, evidence.count > 1024 {
            throw MultichannelModelError.evidenceTooLong
        }

        self.channels = order.count
        self.layout = layout
        self.channelOrder = order
        self.authority = authority
        self.origin = origin
        self.verified = verified
        self.upstreamTransform = upstreamTransform
        self.evidence = evidence
    }

    /// Convenience for a verified decoder source of a known R1 layout.
    public static func decoder(_ layout: ChannelLayout, evidence: String? = nil) throws -> SourceLayout {
        try SourceLayout(
            layout: layout,
            authority: .decoder,
            origin: .decoder,
            verified: true,
            upstreamTransform: .noneKnown,
            evidence: evidence
        )
    }

    public var isWellFormed: Bool {
        channels == channelOrder.count
            && Set(channelOrder).count == channelOrder.count
            && MultichannelModelError.allowedChannelCounts.contains(channels)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, channels, layout, channelOrder, authority, origin,
             verified, nativeClaim, upstreamTransform, evidence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        if let schema, schema != 2 {
            throw MultichannelModelError.unsupportedSchemaVersion(schema)
        }
        let layout = try container.decode(ChannelLayout.self, forKey: .layout)
        let order = try container.decode([ChannelLabel].self, forKey: .channelOrder)
        let authority = try container.decodeIfPresent(SourceAuthority.self, forKey: .authority) ?? .none
        let origin = try container.decodeIfPresent(SourceOrigin.self, forKey: .origin) ?? .unknown
        let verified = try container.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        let upstream = try container.decodeIfPresent(UpstreamTransform.self, forKey: .upstreamTransform) ?? .unknown
        let evidence = try container.decodeIfPresent(String.self, forKey: .evidence)
        let declaredChannels = try container.decodeIfPresent(Int.self, forKey: .channels)

        let value = try SourceLayout(
            layout: layout,
            authority: authority,
            origin: origin,
            verified: verified,
            upstreamTransform: upstream,
            evidence: evidence,
            channelOrder: order
        )
        if let declaredChannels, declaredChannels != value.channels {
            throw MultichannelModelError.channelCountMismatch(expected: value.channels, actual: declaredChannels)
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(channels, forKey: .channels)
        try container.encode(layout, forKey: .layout)
        try container.encode(channelOrder, forKey: .channelOrder)
        try container.encode(authority, forKey: .authority)
        try container.encode(origin, forKey: .origin)
        try container.encode(verified, forKey: .verified)
        try container.encode(nativeClaim, forKey: .nativeClaim)
        try container.encode(upstreamTransform, forKey: .upstreamTransform)
        try container.encodeIfPresent(evidence, forKey: .evidence)
    }
}

// MARK: - Container descriptor

/// Contract §4.1 ContainerDescriptor. Only R1 container layouts are legal.
public struct ContainerLayout: Codable, Equatable, Sendable {
    public var deviceUID: String
    public var channels: Int
    public var layout: ChannelLayout
    public var channelOrder: [ChannelLabel]
    public var authority: SourceAuthority
    public var verified: Bool

    public init(
        deviceUID: String,
        layout: ChannelLayout,
        verified: Bool = true,
        channelOrder: [ChannelLabel]? = nil,
        authority: SourceAuthority = .device
    ) throws {
        guard !deviceUID.isEmpty, deviceUID.count <= 512 else {
            throw MultichannelModelError.invalidDeviceUID
        }
        guard layout.isR1Container else {
            throw MultichannelModelError.unsupportedContainerLayout(layout)
        }
        let canonical = layout.channelOrder
        if let channelOrder, channelOrder != canonical {
            throw MultichannelModelError.channelOrderMismatch(layout)
        }

        self.deviceUID = deviceUID
        self.channels = canonical.count
        self.layout = layout
        self.channelOrder = canonical
        self.authority = authority
        self.verified = verified
    }

    public var isWellFormed: Bool {
        layout.isR1Container
            && channels == layout.channelCount
            && channelOrder == layout.channelOrder
            && !deviceUID.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case deviceUID, channels, layout, channelOrder, authority, verified
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let deviceUID = try container.decode(String.self, forKey: .deviceUID)
        let layout = try container.decode(ChannelLayout.self, forKey: .layout)
        let order = try container.decodeIfPresent([ChannelLabel].self, forKey: .channelOrder)
        let authority = try container.decodeIfPresent(SourceAuthority.self, forKey: .authority) ?? .device
        let verified = try container.decodeIfPresent(Bool.self, forKey: .verified) ?? true
        let declaredChannels = try container.decodeIfPresent(Int.self, forKey: .channels)

        let value = try ContainerLayout(
            deviceUID: deviceUID,
            layout: layout,
            verified: verified,
            channelOrder: order,
            authority: authority
        )
        if let declaredChannels, declaredChannels != value.channels {
            throw MultichannelModelError.channelCountMismatch(expected: value.channels, actual: declaredChannels)
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceUID, forKey: .deviceUID)
        try container.encode(channels, forKey: .channels)
        try container.encode(layout, forKey: .layout)
        try container.encode(channelOrder, forKey: .channelOrder)
        try container.encode(authority, forKey: .authority)
        try container.encode(verified, forKey: .verified)
    }
}

// MARK: - Endpoint descriptor

public enum EndpointKind: String, Codable, Sendable, CaseIterable {
    case homePodStereo = "homepod_stereo"
}

/// Positions allowed by contract §5.1. Height positions are accepted by the
/// descriptor but rejected by the R1 planner.
public enum EndpointPosition: String, Codable, Sendable, CaseIterable {
    case fl = "FL"
    case fr = "FR"
    case fc = "FC"
    case lfe = "LFE"
    case sl = "SL"
    case sr = "SR"
    case bl = "BL"
    case br = "BR"
    case tfl = "TFL"
    case tfr = "TFR"
    case trl = "TRL"
    case trr = "TRR"
    case pair
    case unknown

    public var channelLabel: ChannelLabel? {
        switch self {
        case .fl: .fl
        case .fr: .fr
        case .fc: .fc
        case .lfe: .lfe
        case .sl: .sl
        case .sr: .sr
        case .bl: .bl
        case .br: .br
        case .tfl: .tfl
        case .tfr: .tfr
        case .trl: .trl
        case .trr: .trr
        case .pair, .unknown: nil
        }
    }

    public var isStereoPair: Bool {
        self == .pair || self == .unknown
    }

    public var isHeight: Bool {
        switch self {
        case .tfl, .tfr, .trl, .trr: true
        default: false
        }
    }
}

/// A downstream HomePod endpoint. Contract fixes `homepod_stereo` at 2ch.
/// `positionConfirmed` must be user/install-confirmed before a discrete
/// position may be used. `supportsLowFrequency` is never inferred from the
/// product name; an LFE-bearing route requires an endpoint that explicitly
/// confirms it.
public struct EndpointLayout: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: EndpointKind
    public var channels: Int
    public var position: EndpointPosition
    public var positionConfirmed: Bool
    public var supportsLowFrequency: Bool

    public init(
        id: String,
        kind: EndpointKind = .homePodStereo,
        position: EndpointPosition,
        positionConfirmed: Bool = true,
        supportsLowFrequency: Bool = false,
        channels: Int = 2
    ) throws {
        guard !id.isEmpty, id.count <= 128 else {
            throw MultichannelModelError.invalidEndpointID
        }
        guard kind == .homePodStereo, channels == 2 else {
            throw MultichannelModelError.unsupportedEndpointChannels(channels)
        }
        self.id = id
        self.kind = kind
        self.channels = 2
        self.position = position
        self.positionConfirmed = positionConfirmed
        self.supportsLowFrequency = supportsLowFrequency
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, channels, position, positionConfirmed, supportsLowFrequency
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let kind = try container.decodeIfPresent(EndpointKind.self, forKey: .kind) ?? .homePodStereo
        let channels = try container.decodeIfPresent(Int.self, forKey: .channels) ?? 2
        let position = try container.decode(EndpointPosition.self, forKey: .position)
        let confirmed = try container.decodeIfPresent(Bool.self, forKey: .positionConfirmed) ?? true
        let lfe = try container.decodeIfPresent(Bool.self, forKey: .supportsLowFrequency) ?? false
        self = try EndpointLayout(
            id: id,
            kind: kind,
            position: position,
            positionConfirmed: confirmed,
            supportsLowFrequency: lfe,
            channels: channels
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(channels, forKey: .channels)
        try container.encode(position, forKey: .position)
        try container.encode(positionConfirmed, forKey: .positionConfirmed)
        try container.encode(supportsLowFrequency, forKey: .supportsLowFrequency)
    }
}

// MARK: - Route mode and loss

public enum RouteMode: String, Codable, Sendable, CaseIterable {
    case native
    case padded
    case remap = "layout_remap"
    case downmix
    case frontPair = "front_pair"
    case upmix
    case monoCenter = "mono_map"
    case unsupported

    public var title: String {
        switch self {
        case .native: "直通"
        case .padded: "补位"
        case .remap: "位置重映射"
        case .downmix: "下混"
        case .frontPair: "仅前置"
        case .upmix: "上混"
        case .monoCenter: "单声道分配"
        case .unsupported: "不可路由"
        }
    }
}

public struct Loss: Codable, Equatable, Sendable {
    public var downmixed: [ChannelLabel]
    public var discarded: [ChannelLabel]
    public var silent: [ChannelLabel]

    public init(
        downmixed: [ChannelLabel] = [],
        discarded: [ChannelLabel] = [],
        silent: [ChannelLabel] = []
    ) {
        self.downmixed = downmixed
        self.discarded = discarded
        self.silent = silent
    }

    public static let none = Loss()

    public var isEmpty: Bool {
        downmixed.isEmpty && discarded.isEmpty && silent.isEmpty
    }
}

// MARK: - Transformation and endpoint plan

public struct WeightedInput: Codable, Equatable, Sendable {
    public var label: ChannelLabel
    public var gain: Double

    public init(label: ChannelLabel, gain: Double) {
        self.label = label
        self.gain = gain
    }
}

/// One output row of a registered matrix.
public struct Transformation: Codable, Equatable, Sendable {
    public var output: ChannelLabel
    public var inputs: [WeightedInput]

    public init(output: ChannelLabel, inputs: [WeightedInput]) {
        self.output = output
        self.inputs = inputs
    }

    public var isSilent: Bool {
        inputs.allSatisfy { $0.gain == 0 }
    }

    /// Contract §5.4 requires every output row to have L1 <= 1.
    public var l1Norm: Double {
        inputs.reduce(0) { $0 + abs($1.gain) }
    }

    public func gain(for input: ChannelLabel) -> Double {
        inputs.reduce(0) { partial, term in
            term.label == input ? partial + term.gain : partial
        }
    }
}

public struct MatrixReference: Codable, Equatable, Sendable {
    public var id: String
    public var version: Int

    public init(id: String, version: Int = 1) {
        self.id = id
        self.version = version
    }
}

public struct EndpointPlan: Codable, Equatable, Sendable {
    public var id: String
    public var matrixId: String
    public var inputLabels: [ChannelLabel]
    public var outputLabels: [ChannelLabel]
    public var gains: [Double]
    public var duplicate: Bool

    public init(
        id: String,
        matrixId: String,
        inputLabels: [ChannelLabel],
        outputLabels: [ChannelLabel],
        gains: [Double],
        duplicate: Bool
    ) {
        self.id = id
        self.matrixId = matrixId
        self.inputLabels = inputLabels
        self.outputLabels = outputLabels
        self.gains = gains
        self.duplicate = duplicate
    }
}

// MARK: - Errors

public enum RouteErrorCode: String, Codable, Sendable, CaseIterable {
    case unsupportedLayout = "unsupported_layout"
    case sourceLayoutAmbiguous = "source_layout_ambiguous"
    case routeUnsupported = "route_unsupported"
    case insufficientEndpoints = "insufficient_endpoints"
    case endpointLayoutUnconfirmed = "endpoint_layout_unconfirmed"
    case containerLayoutMismatch = "container_layout_mismatch"
    case layoutUnverified = "layout_unverified"
    case transformUnavailable = "transform_unavailable"
    case channelMapMismatch = "channel_map_mismatch"
}

public struct RouteError: Error, Codable, Equatable, Sendable {
    public var code: RouteErrorCode
    public var message: String

    public init(_ code: RouteErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

public enum MultichannelModelError: Error, Equatable, CustomStringConvertible, Sendable {
    case missingChannelOrder(ChannelLayout)
    case channelOrderMismatch(ChannelLayout)
    case invalidChannelCount(Int)
    case channelCountMismatch(expected: Int, actual: Int)
    case duplicateChannelLabel
    case evidenceTooLong
    case invalidDeviceUID
    case invalidEndpointID
    case unsupportedContainerLayout(ChannelLayout)
    case unsupportedEndpointChannels(Int)
    case unsupportedSchemaVersion(Int)

    public static let allowedChannelCounts: Set<Int> = [1, 2, 3, 4, 6, 8, 10, 12]

    public var description: String {
        switch self {
        case .missingChannelOrder(let layout):
            "Layout \(layout.rawValue) requires an explicit channelOrder."
        case .channelOrderMismatch(let layout):
            "channelOrder does not match canonical order for \(layout.rawValue)."
        case .invalidChannelCount(let count):
            "Unsupported channel count \(count)."
        case .channelCountMismatch(let expected, let actual):
            "Declared channels \(actual) do not match channelOrder count \(expected)."
        case .duplicateChannelLabel:
            "channelOrder contains a duplicate label."
        case .evidenceTooLong:
            "evidence exceeds 1024 characters."
        case .invalidDeviceUID:
            "deviceUID is empty or too long."
        case .invalidEndpointID:
            "endpoint id is empty or too long."
        case .unsupportedContainerLayout(let layout):
            "\(layout.rawValue) is not an R1 container layout."
        case .unsupportedEndpointChannels(let channels):
            "homepod_stereo endpoints must be 2ch, got \(channels)."
        case .unsupportedSchemaVersion(let version):
            "Unsupported schemaVersion \(version)."
        }
    }
}

// MARK: - Route plan

/// Contract §5.1 FlowRoutePlan v1. Deliberately contains no latency state.
public struct FlowRoutePlan: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var session: String
    public var source: SourceLayout
    public var container: ContainerLayout?
    public var endpoints: [EndpointLayout]
    public var mode: RouteMode
    public var allowUpmix: Bool
    public var accepted: Bool
    public var routeId: String
    public var provenance: RouteMode?
    public var matrices: [MatrixReference]
    public var transformations: [Transformation]
    public var endpointPlans: [EndpointPlan]
    public var losses: Loss
    public var uiLabel: String
    public var error: RouteError?
    /// Resolved downstream layout. `.stereo` means one or more HomePod stereo
    /// pairs, never a native 5.1/7.1 claim.
    public var endpointLayout: ChannelLayout?

    public init(
        schemaVersion: Int = 1,
        session: String,
        source: SourceLayout,
        container: ContainerLayout?,
        endpoints: [EndpointLayout],
        mode: RouteMode,
        allowUpmix: Bool,
        accepted: Bool,
        routeId: String,
        provenance: RouteMode?,
        matrices: [MatrixReference],
        transformations: [Transformation],
        endpointPlans: [EndpointPlan],
        losses: Loss,
        uiLabel: String,
        error: RouteError?,
        endpointLayout: ChannelLayout?
    ) {
        self.schemaVersion = schemaVersion
        self.session = session
        self.source = source
        self.container = container
        self.endpoints = endpoints
        self.mode = mode
        self.allowUpmix = allowUpmix
        self.accepted = accepted
        self.routeId = routeId
        self.provenance = provenance
        self.matrices = matrices
        self.transformations = transformations
        self.endpointPlans = endpointPlans
        self.losses = losses
        self.uiLabel = uiLabel
        self.error = error
        self.endpointLayout = endpointLayout
    }

    /// A native multichannel claim is legal only for an exact multichannel
    /// endpoint layout, never for a pair set.
    public var claimsNativeSurround: Bool {
        accepted
            && mode == .native
            && source.channels > 2
            && endpointLayout == source.layout
    }

    public var isStereoPairSet: Bool {
        endpointLayout == .stereo
    }
}

// MARK: - Route options and latency

public struct RouteOptions: Equatable, Sendable {
    public var session: String
    public var requestedMode: RouteMode?
    public var allowUpmix: Bool
    public var container: ContainerLayout?

    public init(
        session: String = UUID().uuidString,
        requestedMode: RouteMode? = nil,
        allowUpmix: Bool = false,
        container: ContainerLayout? = nil
    ) {
        self.session = session
        self.requestedMode = requestedMode
        self.allowUpmix = allowUpmix
        self.container = container
    }
}

public enum InputPermission: String, Codable, Sendable, CaseIterable {
    case granted
    case denied
    case unknown
    case notDetermined = "not_determined"
}

/// Latency is intentionally outside FlowRoutePlan. The route plan is a pure
/// channel decision; latency/revision is a separate session concern.
public struct InputLatencyStatus: Codable, Equatable, Sendable {
    public var deviceUID: String
    public var hflr: UInt64
    public var reportedFrames: Int
    public var rate: Double
    public var calibrationFrames: Int
    public var permission: InputPermission

    public init(
        deviceUID: String,
        hflr: UInt64,
        reportedFrames: Int,
        rate: Double,
        calibrationFrames: Int = 0,
        permission: InputPermission = .unknown
    ) {
        self.deviceUID = deviceUID
        self.hflr = hflr
        self.reportedFrames = reportedFrames
        self.rate = rate
        self.calibrationFrames = calibrationFrames
        self.permission = permission
    }

    private enum CodingKeys: String, CodingKey {
        case deviceUID, hflr, reportedFrames, rate
        case calibrationFrames = "calibration"
        case permission
    }

    public var isConsistent: Bool {
        !deviceUID.isEmpty
            && hflr >= 1
            && reportedFrames >= 0
            && rate.isFinite
            && rate > 0
            && calibrationFrames >= 0
    }
}

// MARK: - Matrix constants

public enum MatrixConstants {
    public static let a: Double = sqrt(2.0) - 1.0                 // √2 − 1
    public static let b: Double = 1.0 - sqrt(2.0) / 2.0           // 1 − √2/2
    public static let c: Double = b / 2.0                         // b/2
    public static let d: Double = 1.0 / (1.0 + 1.0 / sqrt(2.0))
    public static let e: Double = 1.0 / sqrt(2.0)
    public static let f: Double = 1.0 / (2.0 * sqrt(2.0))
}

// MARK: - Planner

public enum FlowRoutePlanner {
    private enum EndpointCapability: Equatable, Sendable {
        case stereoPairs(Int)
        case layout(ChannelLayout)

        var planLayout: ChannelLayout {
            switch self {
            case .stereoPairs(_): .stereo
            case .layout(let layout): layout
            }
        }

        var token: String {
            switch self {
            case .stereoPairs(_): "stereo2"
            case .layout(let layout): layout.rawValue
            }
        }
    }

    private struct Selection {
        var mode: RouteMode
        var matrixId: String
        var targetOrder: [ChannelLabel]
        var transformations: [Transformation]
        var losses: Loss
    }

    // MARK: Public API

    /// Pure route decision for one source and the currently available
    /// endpoints. This is the contract's `plan(source:endpoints:)` entry point.
    public static func plan(source: SourceLayout, endpoints: [EndpointLayout]) -> FlowRoutePlan {
        plan(source: source, endpoints: endpoints, options: RouteOptions())
    }

    public static func plan(
        source: SourceLayout,
        endpoints: [EndpointLayout],
        options: RouteOptions
    ) -> FlowRoutePlan {
        if let error = validateSource(source) {
            return rejected(source: source, endpoints: endpoints, options: options, capability: nil, error: error)
        }
        if let error = validateContainer(options.container, source: source) {
            return rejected(source: source, endpoints: endpoints, options: options, capability: nil, error: error)
        }

        let capability: EndpointCapability
        switch resolveEndpoints(endpoints) {
        case .success(let resolved):
            capability = resolved
        case .failure(let error):
            return rejected(source: source, endpoints: endpoints, options: options, capability: nil, error: error)
        }

        let selection: Selection
        switch select(source: source, capability: capability, options: options) {
        case .success(let value):
            selection = value
        case .failure(let error):
            return rejected(
                source: source,
                endpoints: endpoints,
                options: options,
                capability: capability,
                error: error
            )
        }

        if let requested = options.requestedMode, requested != selection.mode {
            return rejected(
                source: source,
                endpoints: endpoints,
                options: options,
                capability: capability,
                error: RouteError(
                    .routeUnsupported,
                    "请求的路由模式 \(requested.rawValue) 与源×端点矩阵不符；实际可用模式为 \(selection.mode.rawValue)。"
                )
            )
        }

        if let lfeRow = selection.transformations.first(where: { $0.output == .lfe }), !lfeRow.isSilent {
            let hasLFEEndpoint = endpoints.contains { endpoint in
                endpoint.position == .lfe && endpoint.supportsLowFrequency
            }
            if !hasLFEEndpoint {
                return rejected(
                    source: source,
                    endpoints: endpoints,
                    options: options,
                    capability: capability,
                    error: RouteError(
                        .endpointLayoutUnconfirmed,
                        "该路由保留 LFE，但没有已确认低频能力的 LFE 端点；R1 不静默丢弃 LFE，也不冒充完整 5.1/7.1。"
                    )
                )
            }
        }

        // Hard guard: a pair set can never be a native multichannel claim.
        if case .stereoPairs(_) = capability, source.channels > 2, selection.mode == .native {
            return rejected(
                source: source,
                endpoints: endpoints,
                options: options,
                capability: capability,
                error: RouteError(.routeUnsupported, "两台 HomePod 只能下混或仅前置，不能声称原生 5.1/7.1。")
            )
        }

        let matrixReference = MatrixReference(id: selection.matrixId, version: 1)
        let endpointPlans = buildEndpointPlans(
            endpoints: endpoints,
            source: source,
            capability: capability,
            selection: selection
        )
        let label = uiLabel(
            source: source,
            capability: capability,
            selection: selection
        )

        return FlowRoutePlan(
            session: options.session,
            source: source,
            container: options.container,
            endpoints: endpoints,
            mode: selection.mode,
            allowUpmix: options.allowUpmix,
            accepted: true,
            routeId: "route-\(source.layout.rawValue)-to-\(capability.token)-\(selection.mode.rawValue)-v1",
            provenance: selection.mode,
            matrices: [matrixReference],
            transformations: selection.transformations,
            endpointPlans: endpointPlans,
            losses: selection.losses,
            uiLabel: label,
            error: nil,
            endpointLayout: capability.planLayout
        )
    }

    public static func plan(
        source: SourceLayout,
        endpoints: [EndpointLayout],
        container: ContainerLayout,
        requestedMode: RouteMode? = nil,
        allowUpmix: Bool = false
    ) -> FlowRoutePlan {
        plan(
            source: source,
            endpoints: endpoints,
            options: RouteOptions(
                requestedMode: requestedMode,
                allowUpmix: allowUpmix,
                container: container
            )
        )
    }

    // MARK: Validation

    private static func validateSource(_ source: SourceLayout) -> RouteError? {
        switch source.layout {
        case .unknown:
            return RouteError(
                .unsupportedLayout,
                "源布局未知；R1 只允许用户显式选择的受限前置路由，本模型不发明该路由。"
            )
        case .surround51Ambiguous:
            return RouteError(
                .sourceLayoutAmbiguous,
                "播放器只报告 5.1 而未区分 Side/Back；必须显式覆盖 Side 或 Back，不能默认。"
            )
        case .height512, .height712, .height714:
            return RouteError(.unsupportedLayout, "height 布局为 RES，本轮不采集、不路由。")
        default:
            break
        }

        guard source.isWellFormed else {
            return RouteError(.unsupportedLayout, "源布局通道数或通道顺序不自洽。")
        }
        guard source.channelOrder == source.layout.channelOrder else {
            return RouteError(.unsupportedLayout, "源通道顺序与布局 token 的规范顺序不一致。")
        }
        return nil
    }

    private static func validateContainer(_ container: ContainerLayout?, source: SourceLayout) -> RouteError? {
        guard let container else { return nil }
        guard container.isWellFormed else {
            return RouteError(.containerLayoutMismatch, "容器布局通道数或顺序不自洽。")
        }
        guard container.verified else {
            return RouteError(.layoutUnverified, "容器尚未通过 L1 验证。")
        }
        let sourceLabels = Set(source.channelOrder)
        let containerLabels = Set(container.channelOrder)
        guard sourceLabels.isSubset(of: containerLabels) else {
            return RouteError(
                .containerLayoutMismatch,
                "容器缺少源布局的同名通道；捕获层必须先拒绝，Flow 不能从已丢失的通道恢复。"
            )
        }
        return nil
    }

    // MARK: Endpoint resolution

    private static func resolveEndpoints(_ endpoints: [EndpointLayout]) -> Result<EndpointCapability, RouteError> {
        guard !endpoints.isEmpty else {
            return .failure(RouteError(.insufficientEndpoints, "至少需要 1 个 HomePod 端点。"))
        }
        guard endpoints.allSatisfy({ $0.kind == .homePodStereo && $0.channels == 2 }) else {
            return .failure(RouteError(.channelMapMismatch, "端点必须是固定 2ch 的 HomePod 立体声端点。"))
        }

        if endpoints.allSatisfy({ $0.position.isStereoPair }) {
            return .success(.stereoPairs(endpoints.count))
        }

        guard endpoints.allSatisfy({ $0.position.channelLabel != nil }) else {
            return .failure(
                RouteError(.endpointLayoutUnconfirmed, "端点位置混用了 pair/unknown 与离散声道，无法确认布局。")
            )
        }

        let labels = endpoints.compactMap { $0.position.channelLabel }
        guard Set(labels).count == labels.count else {
            return .failure(RouteError(.endpointLayoutUnconfirmed, "端点位置重复，不能按位置分配。"))
        }
        guard endpoints.allSatisfy({ $0.positionConfirmed }) else {
            return .failure(RouteError(.endpointLayoutUnconfirmed, "端点位置必须由用户/安装配置确认，程序不得猜方向。"))
        }
        guard !endpoints.contains(where: { $0.position.isHeight }) else {
            return .failure(RouteError(.unsupportedLayout, "height 端点位置为 RES，本轮不支持。"))
        }

        let candidates: [ChannelLayout] = [
            .surround30, .quad40, .surround51Side, .surround51Back, .surround71
        ]
        let labelSet = Set(labels)
        for candidate in candidates where Set(candidate.channelOrder) == labelSet
            && candidate.channelCount == labels.count {
            return .success(.layout(candidate))
        }

        if let candidate = candidates.first(where: { labelSet.isSubset(of: Set($0.channelOrder)) }) {
            return .failure(
                RouteError(
                    .insufficientEndpoints,
                    "端点不足（\(labels.count)/\(candidate.channelCount)）；不能用部分端点冒充 \(candidate.displayName)。"
                )
            )
        }
        return .failure(
            RouteError(.endpointLayoutUnconfirmed, "端点位置组合不匹配任何 R1 端点布局（3.0/4.0/5.1S/5.1B/7.1）。")
        )
    }

    // MARK: Matrix selection

    private static func select(
        source: SourceLayout,
        capability: EndpointCapability,
        options: RouteOptions
    ) -> Result<Selection, RouteError> {
        if options.requestedMode == .unsupported {
            return .failure(RouteError(.routeUnsupported, "请求模式为 unsupported。"))
        }
        switch capability {
        case .stereoPairs(let count):
            return selectStereoPairs(source: source, count: count, options: options)
        case .layout(let target):
            return selectLayout(source: source, target: target, options: options)
        }
    }

    private static func selectStereoPairs(
        source: SourceLayout,
        count: Int,
        options: RouteOptions
    ) -> Result<Selection, RouteError> {
        if options.requestedMode == .upmix {
            return .failure(RouteError(.transformUnavailable, "两台 HomePod 没有已注册的上混矩阵。"))
        }

        switch source.layout {
        case .mono:
            if options.requestedMode == .frontPair {
                return .failure(RouteError(.routeUnsupported, "mono 没有 FL/FR，不能选择仅前置。"))
            }
            let e = MatrixConstants.e
            return .success(
                Selection(
                    mode: .monoCenter,
                    matrixId: "M_MONO_2",
                    targetOrder: [.left, .right],
                    transformations: rows(
                        target: [.left, .right],
                        equations: [
                            .left: [(.m, e)],
                            .right: [(.m, e)]
                        ]
                    ),
                    losses: .none
                )
            )

        case .stereo:
            if options.requestedMode == .frontPair {
                return .success(
                    Selection(
                        mode: .frontPair,
                        matrixId: "M_FRONT_PAIR",
                        targetOrder: [.left, .right],
                        transformations: frontPairRows(),
                        losses: .none
                    )
                )
            }
            return .success(
                Selection(
                    mode: .native,
                    matrixId: "M_ID_stereo",
                    targetOrder: [.left, .right],
                    transformations: rows(
                        target: [.left, .right],
                        equations: [
                            .left: [(.fl, 1)],
                            .right: [(.fr, 1)]
                        ]
                    ),
                    losses: .none
                )
            )

        case .surround30, .quad40, .surround51Side, .surround51Back, .surround71:
            if options.requestedMode == .frontPair {
                var discarded = source.channelOrder
                discarded.removeAll { $0 == .fl || $0 == .fr }
                return .success(
                    Selection(
                        mode: .frontPair,
                        matrixId: "M_FRONT_PAIR",
                        targetOrder: [.left, .right],
                        transformations: frontPairRows(),
                        losses: Loss(discarded: discarded)
                    )
                )
            }
            guard options.requestedMode == nil || options.requestedMode == .downmix else {
                return .failure(
                    RouteError(.routeUnsupported, "该源到 \(count) 台 HomePod 只定义了下混或仅前置，不能按请求模式执行。")
                )
            }
            return .success(stereoDownmix(source: source, count: count))

        default:
            return .failure(RouteError(.routeUnsupported, "该源布局在 R1 没有到 HomePod 立体声对的路由。"))
        }
    }

    private static func selectLayout(
        source: SourceLayout,
        target: ChannelLayout,
        options: RouteOptions
    ) -> Result<Selection, RouteError> {
        if options.requestedMode == .frontPair {
            return .failure(RouteError(.routeUnsupported, "仅前置矩阵只定义到 HomePod 立体声对，不用于离散多声道端点。"))
        }
        if options.requestedMode == .upmix, source.layout != .stereo {
            return .failure(RouteError(.transformUnavailable, "R1 只定义了 stereo 的固定线性上混矩阵。"))
        }

        switch (source.layout, target) {
        case (.mono, .surround30), (.mono, .surround51Side),
             (.mono, .surround51Back), (.mono, .surround71):
            let silent = target.channelOrder.filter { $0 != .fc }
            return .success(
                Selection(
                    mode: .monoCenter,
                    matrixId: "M_MONO_FC",
                    targetOrder: target.channelOrder,
                    transformations: rows(
                        target: target.channelOrder,
                        equations: [.fc: [(.m, 1)]]
                    ),
                    losses: Loss(silent: silent)
                )
            )

        case (.mono, .quad40):
            let half = 0.5
            return .success(
                Selection(
                    mode: .monoCenter,
                    matrixId: "M_MONO_40",
                    targetOrder: target.channelOrder,
                    transformations: rows(
                        target: target.channelOrder,
                        equations: [
                            .fl: [(.m, half)],
                            .fr: [(.m, half)],
                            .bl: [(.m, half)],
                            .br: [(.m, half)]
                        ]
                    ),
                    losses: .none
                )
            )

        case (.stereo, .surround30), (.stereo, .quad40):
            if options.requestedMode == .upmix {
                return .failure(RouteError(.transformUnavailable, "stereo→3.0/4.0 没有上混矩阵，只有补位。"))
            }
            return .success(pad(source: source, target: target))

        case (.stereo, .surround51Side):
            if options.requestedMode == .upmix {
                guard options.allowUpmix else {
                    return .failure(RouteError(.transformUnavailable, "影院上混默认关闭；必须显式 allowUpmix=true。"))
                }
                return .success(stereoUpmix(target: .surround51Side, includeBack: false))
            }
            return .success(pad(source: source, target: target))

        case (.stereo, .surround51Back):
            if options.requestedMode == .upmix {
                return .failure(RouteError(.transformUnavailable, "R1 没有 M_ST_51B；stereo→5.1 Back 只能补位。"))
            }
            return .success(pad(source: source, target: target))

        case (.stereo, .surround71):
            if options.requestedMode == .upmix {
                guard options.allowUpmix else {
                    return .failure(RouteError(.transformUnavailable, "影院上混默认关闭；必须显式 allowUpmix=true。"))
                }
                return .success(stereoUpmix(target: .surround71, includeBack: true))
            }
            return .success(pad(source: source, target: target))

        case (.surround30, .surround30),
             (.quad40, .quad40),
             (.surround51Side, .surround51Side),
             (.surround51Back, .surround51Back),
             (.surround71, .surround71):
            return .success(identity(source: source))

        case (.surround30, .surround51Side), (.surround30, .surround51Back),
             (.surround30, .surround71):
            return .success(pad(source: source, target: target))

        case (.quad40, .surround51Side):
            return .success(remap40To51Side())

        case (.quad40, .surround51Back), (.quad40, .surround71):
            return .success(pad(source: source, target: target))

        case (.surround51Side, .surround51Back):
            return .success(remap51SideToBack())

        case (.surround51Side, .surround71):
            return .success(pad(source: source, target: target))

        case (.surround51Back, .surround51Side):
            return .success(remap51BackToSide())

        case (.surround51Back, .surround71):
            return .success(pad(source: source, target: target))

        case (.surround71, .surround51Side):
            return .success(downmix71To51Back(target: .surround51Side))

        case (.surround71, .surround51Back):
            return .success(downmix71To51Back(target: .surround51Back))

        default:
            return .failure(
                RouteError(
                    .routeUnsupported,
                    "\(source.layout.displayName) → \(target.displayName) 在 R1 没有已定义矩阵；拒绝而不临时发明。"
                )
            )
        }
    }

    // MARK: Matrix builders

    private static func identity(source: SourceLayout) -> Selection {
        let target = source.channelOrder
        let equations: [ChannelLabel: [(ChannelLabel, Double)]] = Dictionary(
            uniqueKeysWithValues: target.map { ($0, [($0, 1.0)]) }
        )
        return Selection(
            mode: .native,
            matrixId: "M_ID_\(source.layout.rawValue)",
            targetOrder: target,
            transformations: rows(target: target, equations: equations),
            losses: .none
        )
    }

    private static func pad(source: SourceLayout, target: ChannelLayout) -> Selection {
        let labels = Set(source.channelOrder)
        let matrixId: String
        switch (source.layout, target) {
        case (.surround51Side, .surround71):
            matrixId = "M_51S_8"
        case (.surround51Back, .surround71):
            matrixId = "M_51B_8"
        default:
            matrixId = "M_PAD_\(source.layout.rawValue)_\(target.rawValue)"
        }
        let equations: [ChannelLabel: [(ChannelLabel, Double)]] = Dictionary(
            uniqueKeysWithValues: target.channelOrder.map { output -> (ChannelLabel, [(ChannelLabel, Double)]) in
                if labels.contains(output) {
                    return (output, [(output, 1.0)])
                }
                return (output, [])
            }
        )
        let silent = target.channelOrder.filter { !labels.contains($0) }
        return Selection(
            mode: .padded,
            matrixId: matrixId,
            targetOrder: target.channelOrder,
            transformations: rows(target: target.channelOrder, equations: equations),
            losses: Loss(silent: silent)
        )
    }

    private static func remap51BackToSide() -> Selection {
        Selection(
            mode: .remap,
            matrixId: "M_51B_6",
            targetOrder: ChannelLayout.surround51Side.channelOrder,
            transformations: rows(
                target: ChannelLayout.surround51Side.channelOrder,
                equations: [
                    .fl: [(.fl, 1)],
                    .fr: [(.fr, 1)],
                    .fc: [(.fc, 1)],
                    .lfe: [(.lfe, 1)],
                    .sl: [(.bl, 1)],
                    .sr: [(.br, 1)]
                ]
            ),
            losses: .none
        )
    }

    private static func remap51SideToBack() -> Selection {
        Selection(
            mode: .remap,
            matrixId: "M_51S_6B",
            targetOrder: ChannelLayout.surround51Back.channelOrder,
            transformations: rows(
                target: ChannelLayout.surround51Back.channelOrder,
                equations: [
                    .fl: [(.fl, 1)],
                    .fr: [(.fr, 1)],
                    .fc: [(.fc, 1)],
                    .lfe: [(.lfe, 1)],
                    .bl: [(.sl, 1)],
                    .br: [(.sr, 1)]
                ]
            ),
            losses: .none
        )
    }

    private static func remap40To51Side() -> Selection {
        Selection(
            mode: .remap,
            matrixId: "M_40_51S",
            targetOrder: ChannelLayout.surround51Side.channelOrder,
            transformations: rows(
                target: ChannelLayout.surround51Side.channelOrder,
                equations: [
                    .fl: [(.fl, 1)],
                    .fr: [(.fr, 1)],
                    .sl: [(.bl, 1)],
                    .sr: [(.br, 1)]
                ]
            ),
            losses: Loss(silent: [.fc, .lfe])
        )
    }

    private static func downmix71To51Back(target: ChannelLayout) -> Selection {
        let isSide = target == .surround51Side
        let id = isSide ? "M_71_6" : "M_71_6B"
        let targetOrder = target.channelOrder
        let equations: [ChannelLabel: [(ChannelLabel, Double)]]
        if isSide {
            equations = [
                .fl: [(.fl, 1)],
                .fr: [(.fr, 1)],
                .fc: [(.fc, 1)],
                .lfe: [(.lfe, 1)],
                .sl: [(.sl, 0.5), (.bl, 0.5)],
                .sr: [(.sr, 0.5), (.br, 0.5)]
            ]
        } else {
            equations = [
                .fl: [(.fl, 1)],
                .fr: [(.fr, 1)],
                .fc: [(.fc, 1)],
                .lfe: [(.lfe, 1)],
                .bl: [(.bl, 0.5), (.sl, 0.5)],
                .br: [(.br, 0.5), (.sr, 0.5)]
            ]
        }
        return Selection(
            mode: .downmix,
            matrixId: id,
            targetOrder: targetOrder,
            transformations: rows(target: targetOrder, equations: equations),
            losses: Loss(downmixed: isSide ? [.bl, .br] : [.sl, .sr])
        )
    }

    private static func stereoDownmix(source: SourceLayout, count: Int) -> Selection {
        let a = MatrixConstants.a
        let b = MatrixConstants.b
        let c = MatrixConstants.c
        let d = MatrixConstants.d
        let target: [ChannelLabel] = [.left, .right]
        switch source.layout {
        case .surround30:
            return Selection(
                mode: .downmix,
                matrixId: "M_30_2",
                targetOrder: target,
                transformations: rows(
                    target: target,
                    equations: [
                        .left: [(.fl, d), (.fc, a)],
                        .right: [(.fr, d), (.fc, a)]
                    ]
                ),
                losses: Loss(downmixed: [.fc])
            )
        case .quad40:
            return Selection(
                mode: .downmix,
                matrixId: "M_40_2",
                targetOrder: target,
                transformations: rows(
                    target: target,
                    equations: [
                        .left: [(.fl, d), (.bl, a)],
                        .right: [(.fr, d), (.br, a)]
                    ]
                ),
                losses: Loss(downmixed: [.bl, .br])
            )
        case .surround51Side:
            return Selection(
                mode: .downmix,
                matrixId: "M_51S_2",
                targetOrder: target,
                transformations: rows(
                    target: target,
                    equations: [
                        .left: [(.fl, a), (.fc, b), (.sl, b)],
                        .right: [(.fr, a), (.fc, b), (.sr, b)]
                    ]
                ),
                // Contract §5.1's frozen 5.1→stereo example lists the
                // directional surround fold as "downmixed" and keeps LFE in
                // "discarded". FC is folded by the matrix, but the v1 example
                // does not repeat it in this array.
                losses: Loss(downmixed: [.sl, .sr], discarded: [.lfe])
            )
        case .surround51Back:
            return Selection(
                mode: .downmix,
                matrixId: "M_51B_2",
                targetOrder: target,
                transformations: rows(
                    target: target,
                    equations: [
                        .left: [(.fl, a), (.fc, b), (.bl, b)],
                        .right: [(.fr, a), (.fc, b), (.br, b)]
                    ]
                ),
                losses: Loss(downmixed: [.bl, .br], discarded: [.lfe])
            )
        case .surround71:
            return Selection(
                mode: .downmix,
                matrixId: "M_71_2",
                targetOrder: target,
                transformations: rows(
                    target: target,
                    equations: [
                        .left: [(.fl, a), (.fc, b), (.sl, c), (.bl, c)],
                        .right: [(.fr, a), (.fc, b), (.sr, c), (.br, c)]
                    ]
                ),
                losses: Loss(downmixed: [.sl, .sr, .bl, .br], discarded: [.lfe])
            )
        default:
            // Unreachable because callers gate on the R1 source layouts.
            return Selection(
                mode: .unsupported,
                matrixId: "M_UNSUPPORTED",
                targetOrder: target,
                transformations: [],
                losses: .none
            )
        }
    }

    private static func stereoUpmix(target: ChannelLayout, includeBack: Bool) -> Selection {
        let e = MatrixConstants.e
        let f = MatrixConstants.f
        var equations: [ChannelLabel: [(ChannelLabel, Double)]] = [
            .fl: [(.fl, e)],
            .fr: [(.fr, e)],
            .fc: [(.fl, f), (.fr, f)],
            .sl: [(.fl, 0.5), (.fr, -0.5)],
            .sr: [(.fr, 0.5), (.fl, -0.5)]
        ]
        var silent: [ChannelLabel] = [.lfe]
        if includeBack {
            equations[.bl] = []
            equations[.br] = []
            silent.append(contentsOf: [.bl, .br])
        }
        return Selection(
            mode: .upmix,
            matrixId: includeBack ? "M_ST_71" : "M_ST_51S",
            targetOrder: target.channelOrder,
            transformations: rows(target: target.channelOrder, equations: equations),
            losses: Loss(silent: silent)
        )
    }

    private static func frontPairRows() -> [Transformation] {
        rows(
            target: [.left, .right],
            equations: [
                .left: [(.fl, 1)],
                .right: [(.fr, 1)]
            ]
        )
    }

    private static func rows(
        target: [ChannelLabel],
        equations: [ChannelLabel: [(ChannelLabel, Double)]]
    ) -> [Transformation] {
        target.map { output in
            let inputs = (equations[output] ?? []).map { WeightedInput(label: $0.0, gain: $0.1) }
            return Transformation(output: output, inputs: inputs)
        }
    }

    // MARK: Endpoint plans and labels

    private static func buildEndpointPlans(
        endpoints: [EndpointLayout],
        source: SourceLayout,
        capability: EndpointCapability,
        selection: Selection
    ) -> [EndpointPlan] {
        switch capability {
        case .stereoPairs(_):
            let used = usedLabels(source: source, transformations: selection.transformations)
            return endpoints.map { endpoint in
                EndpointPlan(
                    id: endpoint.id,
                    matrixId: selection.matrixId,
                    inputLabels: used,
                    outputLabels: [.left, .right],
                    gains: [1, 1],
                    duplicate: false
                )
            }

        case .layout(_):
            return endpoints.map { endpoint in
                guard let position = endpoint.position.channelLabel,
                      let row = selection.transformations.first(where: { $0.output == position }) else {
                    return EndpointPlan(
                        id: endpoint.id,
                        matrixId: selection.matrixId,
                        inputLabels: [],
                        outputLabels: [.left, .right],
                        gains: [0, 0],
                        duplicate: true
                    )
                }
                let used = usedLabels(source: source, transformations: [row])
                let gains: [Double] = row.isSilent ? [0, 0] : [1, 1]
                return EndpointPlan(
                    id: endpoint.id,
                    matrixId: selection.matrixId,
                    inputLabels: used,
                    outputLabels: [.left, .right],
                    gains: gains,
                    duplicate: true
                )
            }
        }
    }

    private static func usedLabels(
        source: SourceLayout,
        transformations: [Transformation]
    ) -> [ChannelLabel] {
        let used = Set(
            transformations
                .flatMap(\.inputs)
                .filter { $0.gain != 0 }
                .map(\.label)
        )
        return source.channelOrder.filter { used.contains($0) }
    }

    private static func uiLabel(
        source: SourceLayout,
        capability: EndpointCapability,
        selection: Selection
    ) -> String {
        let endpointName: String
        switch capability {
        case .stereoPairs(let count):
            endpointName = "\(count) 台 HomePod"
        case .layout(let layout):
            endpointName = "\(layout.displayName) 端点"
        }

        let sourceName = source.layout.displayName
        switch selection.mode {
        case .native:
            let authoritySuffix: String
            if source.nativeClaim {
                authoritySuffix = "（源原生）"
            } else {
                authoritySuffix = "（播放器输出，未验证）"
            }
            return "\(sourceName) → \(endpointName) · 直通\(authoritySuffix)"

        case .padded:
            if source.layout == .stereo {
                return "\(sourceName) → \(endpointName) · 补位（仅前置 L/R，其余静音）"
            }
            return "\(sourceName) → \(endpointName) · 补位（多出通道静音）"

        case .remap:
            return "\(sourceName) → \(endpointName) · 位置重映射（非原生）"

        case .downmix:
            if capability.planLayout == .stereo {
                let lfeSuffix = selection.losses.discarded.contains(.lfe) ? "（LFE 丢弃）" : ""
                return "\(sourceName) → \(endpointName) · 立体声下混\(lfeSuffix)"
            }
            if source.layout == .surround71, capability.planLayout == .surround51Side {
                return "7.1 → 5.1 Side 端点 · 下混（后环绕并入侧环绕）"
            }
            if source.layout == .surround71, capability.planLayout == .surround51Back {
                return "7.1 → 5.1 Back 端点 · 下混（侧环绕并入后环绕）"
            }
            return "\(sourceName) → \(endpointName) · 下混"

        case .frontPair:
            return "\(sourceName) → \(endpointName) · 仅前置 L/R（其余丢弃）"

        case .upmix:
            return "\(sourceName) → \(endpointName) · 影院上混（非原生）"

        case .monoCenter:
            if capability.planLayout == .quad40 {
                return "单声道 → 4.0 端点 · 四端点均分（非原生）"
            }
            if capability.planLayout == .stereo {
                return "单声道 → \(endpointName) · 单声道分配"
            }
            return "单声道 → \(endpointName) · 中置分配（其余静音）"

        case .unsupported:
            return "该源与端点组合没有可用路由"
        }
    }

    private static func rejected(
        source: SourceLayout,
        endpoints: [EndpointLayout],
        options: RouteOptions,
        capability: EndpointCapability?,
        error: RouteError
    ) -> FlowRoutePlan {
        FlowRoutePlan(
            session: options.session,
            source: source,
            container: options.container,
            endpoints: endpoints,
            mode: .unsupported,
            allowUpmix: options.allowUpmix,
            accepted: false,
            routeId: "route-rejected-v1",
            provenance: nil,
            matrices: [],
            transformations: [],
            endpointPlans: [],
            losses: .none,
            uiLabel: "该源与端点组合没有可用路由",
            error: error,
            endpointLayout: capability?.planLayout
        )
    }
}

public typealias MultichannelRouter = FlowRoutePlanner
