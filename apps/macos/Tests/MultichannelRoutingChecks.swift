import Foundation

// Standalone harness: no XCTest target exists in apps/macos.
// Run from apps/macos with:
//   swiftc -swift-version 6 -parse-as-library \
//     HomePodFlow/Models/MultichannelRouting.swift \
//     Tests/MultichannelRoutingChecks.swift \
//     -o /tmp/homepod-flow-multichannel-checks
//   /tmp/homepod-flow-multichannel-checks

@main
struct MultichannelRoutingChecks {
    static func main() {
        sourceDescriptors()
        sourceNativeClaim()
        canonicalLayoutOrders()
        stereoNative()
        stereoPadded()
        fiveOneToSevenOne()
        sevenOneDownmix()
        quadRemap()
        monoRoutes()
        downmixToTwoHomePods()
        frontPair()
        sideBackRemap()
        unsupportedCombinations()
        ambiguousUnknownHeight()
        twoHomePodHardLimit()
        upmix()
        endpointValidation()
        containerValidation()
        modelValidation()
        latencySeparation()
        invariants()
        print("PASS: 21 sections, contract v1 matrices and two-HomePod limits")
    }
}

// MARK: - Assertions

private func check(
    _ condition: @autoclosure () -> Bool,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    if !condition() {
        fatalError("FAIL: \(message) (\(file):\(line))")
    }
}

private func checkClose(
    _ actual: Double,
    _ expected: Double,
    _ message: String,
    tolerance: Double = 1e-9,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    if !actual.isFinite || abs(actual - expected) > tolerance {
        fatalError("FAIL: \(message): expected \(expected), got \(actual) (\(file):\(line))")
    }
}

private func expectFailure(
    _ plan: FlowRoutePlan,
    _ code: RouteErrorCode,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    check(!plan.accepted, "\(message): plan must be rejected", file: file, line: line)
    check(plan.error?.code == code, "\(message): expected \(code.rawValue), got \(plan.error?.code.rawValue ?? "nil")", file: file, line: line)
    check(plan.mode == .unsupported, "\(message): rejected plan mode must be unsupported", file: file, line: line)
    check(plan.provenance == nil, "\(message): rejected plan must not claim provenance", file: file, line: line)
    check(plan.matrices.isEmpty && plan.endpointPlans.isEmpty, "\(message): rejected plan must be empty", file: file, line: line)
}

// MARK: - Fixtures

private func source(
    _ layout: ChannelLayout,
    authority: SourceAuthority = .decoder,
    verified: Bool = true
) -> SourceLayout {
    try! SourceLayout(
        layout: layout,
        authority: authority,
        origin: authority == .decoder ? .decoder : .playerOutput,
        verified: verified,
        upstreamTransform: verified ? .noneKnown : .unknown
    )
}

private func endpoint(
    _ id: String,
    _ position: EndpointPosition,
    lfe: Bool = false,
    confirmed: Bool = true
) -> EndpointLayout {
    try! EndpointLayout(
        id: id,
        position: position,
        positionConfirmed: confirmed,
        supportsLowFrequency: lfe
    )
}

private func pairs(_ count: Int) -> [EndpointLayout] {
    (1...count).map { endpoint("homepod-\($0)", .pair) }
}

private func endpoints(for layout: ChannelLayout, lfeCapable: Bool = true) -> [EndpointLayout] {
    layout.channelOrder.map { label in
        let position = EndpointPosition(rawValue: label.rawValue)!
        return endpoint("ep-\(label.rawValue.lowercased())", position, lfe: lfeCapable && label == .lfe)
    }
}

private func makePlan(
    _ source: SourceLayout,
    _ endpoints: [EndpointLayout],
    mode: RouteMode? = nil,
    upmix: Bool = false,
    container: ContainerLayout? = nil
) -> FlowRoutePlan {
    FlowRoutePlanner.plan(
        source: source,
        endpoints: endpoints,
        options: RouteOptions(
            session: "checks-session",
            requestedMode: mode,
            allowUpmix: upmix,
            container: container
        )
    )
}

private func row(_ plan: FlowRoutePlan, _ output: ChannelLabel) -> Transformation? {
    plan.transformations.first { $0.output == output }
}

private func gain(_ plan: FlowRoutePlan, _ output: ChannelLabel, _ input: ChannelLabel) -> Double {
    row(plan, output)?.gain(for: input) ?? 0
}

private func rowL1(_ plan: FlowRoutePlan, _ output: ChannelLabel) -> Double {
    row(plan, output)?.l1Norm ?? 0
}

private func matrixID(_ plan: FlowRoutePlan) -> String? {
    plan.matrices.first?.id
}

// MARK: - Source descriptors

private func sourceDescriptors() {
    let decoded = try! JSONDecoder().decode(
        SourceLayout.self,
        from: Data("""
        {
          "schemaVersion": 2,
          "channels": 6,
          "layout": "5_1_side",
          "channelOrder": ["FL", "FR", "FC", "LFE", "SL", "SR"],
          "authority": "decoder",
          "origin": "decoder",
          "verified": true,
          "nativeClaim": true,
          "upstreamTransform": "none_known",
          "evidence": "fixture"
        }
        """.utf8)
    )
    check(decoded.channels == 6, "decoded source channels")
    check(decoded.layout == .surround51Side, "decoded source layout")
    check(decoded.channelOrder == [.fl, .fr, .fc, .lfe, .sl, .sr], "decoded source order")
    check(decoded.nativeClaim, "decoder+verified must claim source-native")

    var channelMismatchRejected = false
    do {
        _ = try JSONDecoder().decode(
            SourceLayout.self,
            from: Data("""
            {"schemaVersion":2,"channels":8,"layout":"5_1_side",
             "channelOrder":["FL","FR","FC","LFE","SL","SR"]}
            """.utf8)
        )
    } catch {
        channelMismatchRejected = true
    }
    check(channelMismatchRejected, "declared channels must equal channelOrder count")

    print("PASS: source descriptor JSON and channel-count validation")
}

private func sourceNativeClaim() {
    let decoder = source(.surround51Side)
    check(decoder.nativeClaim, "decoder + verified nativeClaim")

    let player = source(.surround51Side, authority: .playerOutput)
    check(!player.nativeClaim, "player_output must never claim source-native")

    let device = source(.surround51Side, authority: .device)
    check(device.nativeClaim, "device + verified nativeClaim")

    let override = source(.surround51Side, authority: .userOverride)
    check(!override.nativeClaim, "user_override must never claim source-native")

    let unverified = source(.surround51Side, verified: false)
    check(!unverified.nativeClaim, "unverified source must not claim native")

    print("PASS: source-native is derived from authority + verified")
}

private func canonicalLayoutOrders() {
    check(ChannelLayout.mono.channelOrder == [.m], "mono order M")
    check(ChannelLayout.stereo.channelOrder == [.fl, .fr], "stereo order FL FR")
    check(ChannelLayout.surround30.channelOrder == [.fl, .fr, .fc], "3.0 order")
    check(ChannelLayout.quad40.channelOrder == [.fl, .fr, .bl, .br], "4.0 is quad back")
    check(ChannelLayout.surround51Side.channelOrder == [.fl, .fr, .fc, .lfe, .sl, .sr], "5.1 side order")
    check(ChannelLayout.surround51Back.channelOrder == [.fl, .fr, .fc, .lfe, .bl, .br], "5.1 back order")
    check(
        ChannelLayout.surround71.channelOrder == [.fl, .fr, .fc, .lfe, .sl, .sr, .bl, .br],
        "7.1 must contain both side and back pairs in HAL order"
    )
    check(ChannelLayout.surround51Side.channelOrder != ChannelLayout.surround51Back.channelOrder, "5.1 side != back")

    print("PASS: canonical channel labels and orders")
}

// MARK: - Native and padded

private func stereoNative() {
    let plan = makePlan(source(.stereo), pairs(2))
    check(plan.accepted, "stereo → 2 HomePods accepted")
    check(plan.mode == .native, "stereo → 2 HomePods is native")
    check(plan.provenance == .native, "provenance native")
    check(plan.endpointLayout == .stereo && plan.isStereoPairSet, "pair set resolves to ST")
    check(matrixID(plan) == "M_ID_stereo", "stereo identity matrix")
    check(plan.matrices.first?.version == 1, "matrix version 1")
    check(plan.endpointPlans.count == 2, "two endpoint plans")
    check(plan.losses.isEmpty, "stereo native has no loss")
    check(gain(plan, .left, .fl) == 1 && gain(plan, .right, .fr) == 1, "stereo L/R identity")
    check(!plan.claimsNativeSurround, "stereo is not a surround native claim")
    check(plan.uiLabel.contains("直通"), "stereo label says direct")

    print("PASS: stereo → two HomePods native")
}

private func stereoPadded() {
    let to51 = makePlan(source(.stereo), endpoints(for: .surround51Side))
    check(to51.accepted && to51.mode == .padded, "stereo → 5.1 Side is padded")
    check(matrixID(to51) == "M_PAD_stereo_5_1_side", "stereo → 5.1 Side pad matrix")
    check(to51.losses.silent == [.fc, .lfe, .sl, .sr], "stereo → 5.1 Side silent FC/LFE/SL/SR")
    check(gain(to51, .fl, .fl) == 1 && gain(to51, .fr, .fr) == 1, "stereo FL/FR placed")
    check(gain(to51, .fc, .fl) == 0 && gain(to51, .sl, .fl) == 0, "stereo does not upmix by default")
    check(to51.uiLabel.contains("仅前置 L/R") && to51.uiLabel.contains("静音"), "stereo pad label")
    check(!to51.claimsNativeSurround, "stereo pad never native surround")

    let to71 = makePlan(source(.stereo), endpoints(for: .surround71))
    check(to71.accepted && to71.mode == .padded, "stereo → 7.1 is padded")
    check(matrixID(to71) == "M_PAD_stereo_7_1", "stereo → 7.1 pad matrix")
    check(to71.losses.silent == [.fc, .lfe, .sl, .sr, .bl, .br], "stereo → 7.1 silent six channels")

    let to30 = makePlan(source(.stereo), endpoints(for: .surround30))
    check(to30.accepted && to30.mode == .padded && to30.losses.silent == [.fc], "stereo → 3.0 pad only FC")

    print("PASS: stereo padded into 3.0 / 5.1 / 7.1")
}

private func fiveOneToSevenOne() {
    let side = makePlan(source(.surround51Side), endpoints(for: .surround71))
    check(side.accepted && side.mode == .padded, "5.1 Side → 7.1 padded")
    check(matrixID(side) == "M_51S_8", "5.1 Side → 7.1 matrix")
    check(gain(side, .sl, .sl) == 1 && gain(side, .sr, .sr) == 1, "SL/SR survive")
    check(row(side, .bl)?.isSilent == true && row(side, .br)?.isSilent == true, "BL/BR silent")
    check(side.losses.silent == [.bl, .br], "5.1 Side → 7.1 silent BL/BR")

    let back = makePlan(source(.surround51Back), endpoints(for: .surround71))
    check(back.accepted && back.mode == .padded, "5.1 Back → 7.1 padded")
    check(matrixID(back) == "M_51B_8", "5.1 Back → 7.1 matrix")
    check(gain(back, .bl, .bl) == 1 && gain(back, .br, .br) == 1, "BL/BR survive")
    check(row(back, .sl)?.isSilent == true && row(back, .sr)?.isSilent == true, "SL/SR silent")
    check(back.losses.silent == [.sl, .sr], "5.1 Back → 7.1 silent SL/SR")

    print("PASS: 5.1 Side/Back padded into 7.1")
}

private func sevenOneDownmix() {
    let side = makePlan(source(.surround71), endpoints(for: .surround51Side))
    check(side.accepted && side.mode == .downmix, "7.1 → 5.1 Side downmix")
    check(matrixID(side) == "M_71_6", "7.1 → 5.1 Side matrix")
    checkClose(gain(side, .sl, .sl), 0.5, "SL = 0.5*SL")
    checkClose(gain(side, .sl, .bl), 0.5, "SL += 0.5*BL")
    checkClose(gain(side, .sr, .sr), 0.5, "SR = 0.5*SR")
    checkClose(gain(side, .sr, .br), 0.5, "SR += 0.5*BR")
    check(gain(side, .lfe, .lfe) == 1, "7.1 → 5.1 retains LFE")
    check(side.losses.downmixed == [.bl, .br], "7.1 → 5.1 Side downmixed BL/BR")
    check(side.losses.discarded.isEmpty, "7.1 → 5.1 Side keeps LFE")
    checkClose(rowL1(side, .sl), 1.0, "7.1 → 5.1 Side SL row L1")

    let back = makePlan(source(.surround71), endpoints(for: .surround51Back))
    check(back.accepted && back.mode == .downmix, "7.1 → 5.1 Back downmix")
    check(matrixID(back) == "M_71_6B", "7.1 → 5.1 Back matrix")
    checkClose(gain(back, .bl, .bl), 0.5, "BL = 0.5*BL")
    checkClose(gain(back, .bl, .sl), 0.5, "BL += 0.5*SL")
    check(back.losses.downmixed == [.sl, .sr], "7.1 → 5.1 Back downmixed SL/SR")

    print("PASS: 7.1 → 5.1 Side/Back downmix")
}

private func quadRemap() {
    let plan = makePlan(source(.quad40), endpoints(for: .surround51Side))
    check(plan.accepted && plan.mode == .remap, "4.0 → 5.1 Side is layout remap")
    check(matrixID(plan) == "M_40_51S", "4.0 → 5.1 Side matrix")
    check(gain(plan, .fl, .fl) == 1 && gain(plan, .fr, .fr) == 1, "FL/FR identity")
    check(gain(plan, .sl, .bl) == 1 && gain(plan, .sr, .br) == 1, "BL→SL, BR→SR")
    check(row(plan, .fc)?.isSilent == true && row(plan, .lfe)?.isSilent == true, "FC/LFE silent")
    check(plan.losses.silent == [.fc, .lfe], "4.0 remap silent FC/LFE")
    check(plan.uiLabel.contains("位置重映射") && plan.uiLabel.contains("非原生"), "remap label")

    let padded = makePlan(source(.quad40), endpoints(for: .surround51Back))
    check(padded.accepted && padded.mode == .padded && matrixID(padded) == "M_PAD_4_0_5_1_back", "4.0 → 5.1 Back pad")
    check(gain(padded, .bl, .bl) == 1 && gain(padded, .br, .br) == 1, "4.0 back pair survives")
    check(padded.losses.silent == [.fc, .lfe], "4.0 → 5.1 Back silent FC/LFE")

    print("PASS: 4.0 → 5.1 Side remap and 4.0 → 5.1 Back pad")
}

// MARK: - Mono

private func monoRoutes() {
    let stereo = makePlan(source(.mono), pairs(2))
    check(stereo.accepted && stereo.mode == .monoCenter, "mono → stereo is mono map")
    check(matrixID(stereo) == "M_MONO_2", "mono → stereo matrix")
    checkClose(gain(stereo, .left, .m), MatrixConstants.e, "L = 1/√2 * M")
    checkClose(gain(stereo, .right, .m), MatrixConstants.e, "R = 1/√2 * M")
    check(stereo.losses.isEmpty, "mono → stereo no loss")

    let fiveOne = makePlan(source(.mono), endpoints(for: .surround51Side))
    check(fiveOne.accepted && fiveOne.mode == .monoCenter, "mono → 5.1 is center map")
    check(matrixID(fiveOne) == "M_MONO_FC", "mono → 5.1 matrix")
    check(gain(fiveOne, .fc, .m) == 1, "mono enters FC")
    check(row(fiveOne, .fl)?.isSilent == true, "mono does not enter FL")
    check(fiveOne.losses.silent == [.fl, .fr, .lfe, .sl, .sr], "mono → 5.1 silent non-FC")
    check(fiveOne.uiLabel.contains("中置分配"), "mono → 5.1 label")

    let three = makePlan(source(.mono), endpoints(for: .surround30))
    check(three.accepted && three.mode == .monoCenter && matrixID(three) == "M_MONO_FC", "mono → 3.0 FC")
    check(three.losses.silent == [.fl, .fr], "mono → 3.0 silent FL/FR")

    let four = makePlan(source(.mono), endpoints(for: .quad40))
    check(four.accepted && four.mode == .monoCenter, "mono → 4.0 is mono map")
    check(matrixID(four) == "M_MONO_40", "mono → 4.0 matrix")
    for label in [ChannelLabel.fl, .fr, .bl, .br] {
        checkClose(gain(four, label, .m), 0.5, "mono → 4.0 \(label) = 0.5*M")
    }
    check(four.losses.isEmpty, "mono → 4.0 uses every endpoint")
    check(four.uiLabel.contains("四端点均分") && four.uiLabel.contains("非原生"), "mono → 4.0 label")
    check(!four.claimsNativeSurround, "mono → 4.0 is not native 4.0")

    print("PASS: mono → stereo / FC / 4.0 allocations")
}

// MARK: - Two HomePods

private func downmixToTwoHomePods() {
    let fiveSide = makePlan(source(.surround51Side), pairs(2))
    check(fiveSide.accepted && fiveSide.mode == .downmix, "5.1 Side → two HomePods downmix")
    check(matrixID(fiveSide) == "M_51S_2", "5.1 Side → two matrix")
    checkClose(gain(fiveSide, .left, .fl), MatrixConstants.a, "5.1 L FL coefficient")
    checkClose(gain(fiveSide, .left, .fc), MatrixConstants.b, "5.1 L FC coefficient")
    checkClose(gain(fiveSide, .left, .sl), MatrixConstants.b, "5.1 L SL coefficient")
    checkClose(gain(fiveSide, .right, .fr), MatrixConstants.a, "5.1 R FR coefficient")
    checkClose(gain(fiveSide, .right, .fc), MatrixConstants.b, "5.1 R FC coefficient")
    checkClose(gain(fiveSide, .right, .sr), MatrixConstants.b, "5.1 R SR coefficient")
    checkClose(rowL1(fiveSide, .left), 1.0, "5.1 L row L1 = 1")
    check(fiveSide.losses.downmixed == [.sl, .sr], "5.1 → stereo downmixed SL/SR")
    check(fiveSide.losses.discarded == [.lfe], "5.1 → stereo discards LFE")
    check(fiveSide.uiLabel.contains("立体声下混") && fiveSide.uiLabel.contains("LFE 丢弃"), "5.1 → stereo label")
    check(fiveSide.endpointPlans.count == 2, "5.1 → two endpoint plans")
    check(fiveSide.endpointPlans.allSatisfy { $0.outputLabels == [.left, .right] }, "endpoint output L/R")
    check(!fiveSide.claimsNativeSurround, "two HomePods never native surround")

    let fiveBack = makePlan(source(.surround51Back), pairs(2))
    check(fiveBack.mode == .downmix && matrixID(fiveBack) == "M_51B_2", "5.1 Back → two")
    checkClose(gain(fiveBack, .left, .bl), MatrixConstants.b, "5.1 Back L BL coefficient")
    check(fiveBack.losses.downmixed == [.bl, .br] && fiveBack.losses.discarded == [.lfe], "5.1 Back losses")

    let seven = makePlan(source(.surround71), pairs(2))
    check(seven.mode == .downmix && matrixID(seven) == "M_71_2", "7.1 → two")
    checkClose(gain(seven, .left, .fl), MatrixConstants.a, "7.1 L FL coefficient")
    checkClose(gain(seven, .left, .fc), MatrixConstants.b, "7.1 L FC coefficient")
    checkClose(gain(seven, .left, .sl), MatrixConstants.c, "7.1 L SL coefficient")
    checkClose(gain(seven, .left, .bl), MatrixConstants.c, "7.1 L BL coefficient")
    check(seven.losses.downmixed == [.sl, .sr, .bl, .br], "7.1 downmixed all surrounds")
    check(seven.losses.discarded == [.lfe], "7.1 discards LFE")
    check(seven.uiLabel.contains("7.1") && seven.uiLabel.contains("下混"), "7.1 → two label")

    let three = makePlan(source(.surround30), pairs(2))
    check(three.mode == .downmix && matrixID(three) == "M_30_2", "3.0 → two")
    checkClose(gain(three, .left, .fl), MatrixConstants.d, "3.0 L FL normalized")
    checkClose(gain(three, .left, .fc), MatrixConstants.a, "3.0 L FC normalized")
    check(three.losses.downmixed == [.fc], "3.0 downmixed FC")

    let four = makePlan(source(.quad40), pairs(2))
    check(four.mode == .downmix && matrixID(four) == "M_40_2", "4.0 → two")
    checkClose(gain(four, .left, .fl), MatrixConstants.d, "4.0 L FL normalized")
    checkClose(gain(four, .left, .bl), MatrixConstants.a, "4.0 L BL normalized")
    check(four.losses.downmixed == [.bl, .br], "4.0 downmixed BL/BR")

    let threePairs = makePlan(source(.surround51Side), pairs(3))
    check(threePairs.accepted && threePairs.mode == .downmix, "three pair endpoints still downmix")
    check(threePairs.endpointPlans.count == 3, "three endpoint plans")
    check(!threePairs.claimsNativeSurround, "three pairs still not native")

    print("PASS: any known source → two HomePods downmix (LFE discarded)")
}

private func frontPair() {
    let plan = makePlan(source(.surround71), pairs(2), mode: .frontPair)
    check(plan.accepted && plan.mode == .frontPair, "7.1 → front pair accepted")
    check(matrixID(plan) == "M_FRONT_PAIR", "front pair matrix")
    check(gain(plan, .left, .fl) == 1 && gain(plan, .right, .fr) == 1, "front pair FL/FR only")
    check(gain(plan, .left, .fc) == 0 && gain(plan, .right, .sl) == 0, "front pair drops other channels")
    check(plan.losses.discarded == [.fc, .lfe, .sl, .sr, .bl, .br], "front pair discarded labels")
    check(plan.uiLabel.contains("仅前置 L/R") && plan.uiLabel.contains("其余丢弃"), "front pair label")
    check(!plan.claimsNativeSurround, "front pair never native surround")

    let stereo = makePlan(source(.stereo), pairs(2), mode: .frontPair)
    check(stereo.accepted && stereo.mode == .frontPair && stereo.losses.isEmpty, "stereo front pair has no discarded labels")

    let mono = makePlan(source(.mono), pairs(2), mode: .frontPair)
    expectFailure(mono, .routeUnsupported, "mono has no FL/FR for front pair")

    print("PASS: explicit front-pair route is discard, not downmix")
}

private func sideBackRemap() {
    let backToSide = makePlan(source(.surround51Back), endpoints(for: .surround51Side))
    check(backToSide.accepted && backToSide.mode == .remap, "5.1 Back → 5.1 Side remap")
    check(matrixID(backToSide) == "M_51B_6", "5.1 Back → Side matrix")
    check(gain(backToSide, .sl, .bl) == 1 && gain(backToSide, .sr, .br) == 1, "BL→SL, BR→SR")
    check(gain(backToSide, .fl, .fl) == 1 && gain(backToSide, .lfe, .lfe) == 1, "FL/LFE identity")
    check(backToSide.losses.isEmpty, "remap has no merged/silent loss")

    let sideToBack = makePlan(source(.surround51Side), endpoints(for: .surround51Back))
    check(sideToBack.accepted && sideToBack.mode == .remap, "5.1 Side → 5.1 Back remap")
    check(matrixID(sideToBack) == "M_51S_6B", "5.1 Side → Back matrix")
    check(gain(sideToBack, .bl, .sl) == 1 && gain(sideToBack, .br, .sr) == 1, "SL→BL, SR→BR")

    print("PASS: 5.1 Side↔Back remap is explicit, not native")
}

// MARK: - Rejections

private func unsupportedCombinations() {
    let cases: [(ChannelLayout, ChannelLayout)] = [
        (.surround30, .quad40),
        (.quad40, .surround30),
        (.surround51Side, .quad40),
        (.surround51Side, .surround30),
        (.surround71, .surround30),
        (.surround71, .quad40)
    ]
    for (sourceLayout, endpointLayout) in cases {
        let result = makePlan(source(sourceLayout), endpoints(for: endpointLayout))
        expectFailure(
            result,
            .routeUnsupported,
            "\(sourceLayout.rawValue) → \(endpointLayout.rawValue) has no R1 matrix"
        )
    }

    print("PASS: undefined source × endpoint combinations are rejected")
}

private func ambiguousUnknownHeight() {
    let unknown = try! SourceLayout(
        layout: .unknown,
        authority: .none,
        origin: .unknown,
        verified: false,
        upstreamTransform: .unknown,
        channelOrder: [.unknown(1), .unknown(2), .unknown(3), .unknown(4), .unknown(5), .unknown(6)]
    )
    expectFailure(makePlan(unknown, pairs(2)), .unsupportedLayout, "unknown source")

    let ambiguous = try! SourceLayout(
        layout: .surround51Ambiguous,
        authority: .userOverride,
        origin: .userOverride,
        verified: false,
        upstreamTransform: .unknown
    )
    expectFailure(makePlan(ambiguous, pairs(2)), .sourceLayoutAmbiguous, "5.1 ambiguous source")

    let height = try! SourceLayout(layout: .height512)
    expectFailure(makePlan(height, pairs(2)), .unsupportedLayout, "height source is RES")

    print("PASS: unknown / ambiguous / height sources are rejected, not guessed")
}

private func twoHomePodHardLimit() {
    for layout in [ChannelLayout.surround30, .quad40, .surround51Side, .surround51Back, .surround71] {
        let result = makePlan(source(layout), pairs(2))
        check(result.accepted, "\(layout.rawValue) → two HomePods is routable")
        check(result.mode != .native, "\(layout.rawValue) → two HomePods must not be native")
        check(result.provenance != .native, "\(layout.rawValue) → two HomePods provenance must not be native")
        check(!result.claimsNativeSurround, "\(layout.rawValue) → two HomePods must not claim native surround")
        check(!result.uiLabel.contains("原生 5.1") && !result.uiLabel.contains("原生 7.1"), "\(layout.rawValue) label must not say native surround")

        let forcedNative = makePlan(source(layout), pairs(2), mode: .native)
        expectFailure(forcedNative, .routeUnsupported, "\(layout.rawValue) → two HomePods native request")
    }

    let singlePair = makePlan(source(.surround71), pairs(1))
    check(singlePair.accepted && singlePair.mode == .downmix, "one HomePod still downmix")
    check(!singlePair.claimsNativeSurround, "one HomePod never native surround")

    print("PASS: two HomePods never yield a native 5.1/7.1 claim")
}

private func upmix() {
    let fiveOne = makePlan(source(.stereo), endpoints(for: .surround51Side), mode: .upmix, upmix: true)
    check(fiveOne.accepted && fiveOne.mode == .upmix, "stereo → 5.1 upmix accepted with allowUpmix")
    check(matrixID(fiveOne) == "M_ST_51S", "stereo → 5.1 upmix matrix")
    checkClose(gain(fiveOne, .fl, .fl), MatrixConstants.e, "upmix FL = 1/√2 L")
    checkClose(gain(fiveOne, .fr, .fr), MatrixConstants.e, "upmix FR = 1/√2 R")
    checkClose(gain(fiveOne, .fc, .fl), MatrixConstants.f, "upmix FC L coefficient")
    checkClose(gain(fiveOne, .fc, .fr), MatrixConstants.f, "upmix FC R coefficient")
    checkClose(gain(fiveOne, .sl, .fl), 0.5, "upmix SL L coefficient")
    checkClose(gain(fiveOne, .sl, .fr), -0.5, "upmix SL -R coefficient")
    checkClose(gain(fiveOne, .sr, .fr), 0.5, "upmix SR R coefficient")
    checkClose(gain(fiveOne, .sr, .fl), -0.5, "upmix SR -L coefficient")
    check(row(fiveOne, .lfe)?.isSilent == true, "upmix does not synthesize LFE")
    check(fiveOne.losses.silent == [.lfe], "upmix marks LFE silent")
    check(fiveOne.uiLabel.contains("上混") && fiveOne.uiLabel.contains("非原生"), "upmix label")
    check(!fiveOne.claimsNativeSurround, "upmix never native")

    let noPermission = makePlan(source(.stereo), endpoints(for: .surround51Side), mode: .upmix, upmix: false)
    expectFailure(noPermission, .transformUnavailable, "upmix without allowUpmix")

    let seven = makePlan(source(.stereo), endpoints(for: .surround71), mode: .upmix, upmix: true)
    check(seven.accepted && matrixID(seven) == "M_ST_71", "stereo → 7.1 upmix matrix")
    check(row(seven, .bl)?.isSilent == true && row(seven, .br)?.isSilent == true, "7.1 upmix leaves BL/BR silent")
    check(seven.losses.silent == [.lfe, .bl, .br], "7.1 upmix silent labels")

    let fiveBack = makePlan(source(.stereo), endpoints(for: .surround51Back), mode: .upmix, upmix: true)
    expectFailure(fiveBack, .transformUnavailable, "no M_ST_51B in contract")

    let surroundUpmix = makePlan(source(.surround51Side), endpoints(for: .surround71), mode: .upmix, upmix: true)
    expectFailure(surroundUpmix, .transformUnavailable, "upmix only defined for stereo source")

    print("PASS: optional stereo upmix is explicit, non-native, LFE=0")
}

// MARK: - Endpoint and container validation

private func endpointValidation() {
    let insufficient = makePlan(
        source(.surround51Side),
        [
            endpoint("fl", .fl),
            endpoint("fr", .fr),
            endpoint("fc", .fc),
            endpoint("lfe", .lfe, lfe: true),
            endpoint("sl", .sl)
        ]
    )
    expectFailure(insufficient, .insufficientEndpoints, "5.1 source with 5/6 discrete endpoints")

    let twoDiscrete = makePlan(
        source(.surround51Side),
        [endpoint("fl", .fl), endpoint("fr", .fr)]
    )
    expectFailure(twoDiscrete, .insufficientEndpoints, "FL/FR only is not promoted to 3.0")

    let duplicate = makePlan(
        source(.surround51Side),
        [
            endpoint("fl1", .fl),
            endpoint("fl2", .fl),
            endpoint("fc", .fc),
            endpoint("lfe", .lfe, lfe: true),
            endpoint("sl", .sl),
            endpoint("sr", .sr)
        ]
    )
    expectFailure(duplicate, .endpointLayoutUnconfirmed, "duplicate endpoint positions")

    let unconfirmed = makePlan(
        source(.surround51Side),
        [
            endpoint("fl", .fl, confirmed: false),
            endpoint("fr", .fr),
            endpoint("fc", .fc),
            endpoint("lfe", .lfe, lfe: true),
            endpoint("sl", .sl),
            endpoint("sr", .sr)
        ]
    )
    expectFailure(unconfirmed, .endpointLayoutUnconfirmed, "unconfirmed endpoint position")

    let noLFECapability = makePlan(
        source(.surround71),
        endpoints(for: .surround51Side, lfeCapable: false)
    )
    expectFailure(noLFECapability, .endpointLayoutUnconfirmed, "LFE-bearing downmix requires confirmed LFE endpoint")

    let silentLFE = makePlan(
        source(.stereo),
        endpoints(for: .surround71, lfeCapable: false)
    )
    check(silentLFE.accepted, "stereo → 7.1 pad does not need an LFE-capable endpoint because LFE is silent")

    let mixed = makePlan(
        source(.surround51Side),
        [
            endpoint("pair", .pair),
            endpoint("fl", .fl),
            endpoint("fr", .fr),
            endpoint("fc", .fc),
            endpoint("lfe", .lfe, lfe: true),
            endpoint("sl", .sl)
        ]
    )
    expectFailure(mixed, .endpointLayoutUnconfirmed, "mixed pair and discrete positions")

    print("PASS: endpoint count, duplicates, confirmation and LFE capability")
}

private func containerValidation() {
    let sevenContainer = try! ContainerLayout(
        deviceUID: "com.homepodflow.virtual-audio.surround71.v1",
        layout: .surround71
    )
    let fiveContainer = try! ContainerLayout(
        deviceUID: "com.homepodflow.virtual-audio.surround51s.v1",
        layout: .surround51Side
    )
    let fiveBackContainer = try! ContainerLayout(
        deviceUID: "com.homepodflow.virtual-audio.surround51b.v1",
        layout: .surround51Back
    )
    let unverified = try! ContainerLayout(
        deviceUID: "com.homepodflow.virtual-audio.surround71.v1",
        layout: .surround71,
        verified: false
    )

    let missingLabels = makePlan(source(.surround71), pairs(2), container: fiveContainer)
    expectFailure(missingLabels, .containerLayoutMismatch, "7.1 source in 5.1 Side container")

    let quadInSide = makePlan(source(.quad40), endpoints(for: .surround51Side), container: fiveContainer)
    expectFailure(quadInSide, .containerLayoutMismatch, "4.0 source in 5.1 Side container")

    let quadInBack = makePlan(source(.quad40), endpoints(for: .surround51Side), container: fiveBackContainer)
    check(quadInBack.accepted && quadInBack.mode == .remap, "4.0 source in 5.1 Back container can remap to 5.1 Side")

    let quadInSeven = makePlan(source(.quad40), endpoints(for: .surround51Side), container: sevenContainer)
    check(quadInSeven.accepted && quadInSeven.mode == .remap, "4.0 source in 7.1 container can remap to 5.1 Side")

    let stereoInFive = makePlan(source(.stereo), endpoints(for: .surround51Side), container: fiveContainer)
    check(stereoInFive.accepted && stereoInFive.mode == .padded, "stereo source may be padded in 5.1 container")

    let notVerified = makePlan(source(.surround71), pairs(2), container: unverified)
    expectFailure(notVerified, .layoutUnverified, "unverified container")

    print("PASS: container must contain every source label and be verified")
}

// MARK: - Model validation and latency

private func modelValidation() {
    var badOrderRejected = false
    do {
        _ = try SourceLayout(layout: .stereo, channelOrder: [.fl, .fc])
    } catch {
        badOrderRejected = true
    }
    check(badOrderRejected, "source channelOrder mismatch rejected")

    var duplicateRejected = false
    do {
        _ = try SourceLayout(layout: .stereo, channelOrder: [.fl, .fl])
    } catch {
        duplicateRejected = true
    }
    check(duplicateRejected, "duplicate source labels rejected")

    var endpointChannelsRejected = false
    do {
        _ = try EndpointLayout(id: "bad", position: .fl, channels: 6)
    } catch {
        endpointChannelsRejected = true
    }
    check(endpointChannelsRejected, "homepod_stereo must be 2ch")

    var badContainerRejected = false
    do {
        _ = try ContainerLayout(deviceUID: "x", layout: .unknown)
    } catch {
        badContainerRejected = true
    }
    check(badContainerRejected, "unknown container layout rejected")

    print("PASS: malformed descriptors are rejected at construction")
}

private func latencySeparation() {
    let plan = makePlan(source(.surround51Side), pairs(2))
    let data = try! JSONEncoder().encode(plan)
    let json = String(decoding: data, as: UTF8.self)
    check(!json.contains("latency"), "FlowRoutePlan JSON must not contain latency")
    check(!json.contains("hflr"), "FlowRoutePlan JSON must not contain hflr")
    check(!json.contains("reportedFrames"), "FlowRoutePlan JSON must not contain reportedFrames")
    check(!json.contains("calibration"), "FlowRoutePlan JSON must not contain calibration")

    let latency = InputLatencyStatus(
        deviceUID: "com.homepodflow.virtual-audio.surround51s.v1",
        hflr: 3,
        reportedFrames: 512,
        rate: 48_000,
        calibrationFrames: 0,
        permission: .granted
    )
    check(latency.isConsistent, "latency status is internally consistent")
    let latencyJSON = String(decoding: try! JSONEncoder().encode(latency), as: UTF8.self)
    check(latencyJSON.contains("\"hflr\":3"), "latency JSON carries hflr")
    check(latencyJSON.contains("\"calibration\":0"), "latency JSON names calibration")

    let decoded = try! JSONDecoder().decode(FlowRoutePlan.self, from: data)
    check(decoded == plan, "FlowRoutePlan JSON round-trip")

    print("PASS: latency is separate from FlowRoutePlan")
}

private func invariants() {
    let plans: [FlowRoutePlan] = [
        makePlan(source(.mono), pairs(2)),
        makePlan(source(.mono), endpoints(for: .surround51Side)),
        makePlan(source(.mono), endpoints(for: .quad40)),
        makePlan(source(.stereo), pairs(2)),
        makePlan(source(.stereo), endpoints(for: .surround71)),
        makePlan(source(.surround30), endpoints(for: .surround30)),
        makePlan(source(.quad40), endpoints(for: .quad40)),
        makePlan(source(.surround51Side), endpoints(for: .surround51Side)),
        makePlan(source(.surround51Back), endpoints(for: .surround51Back)),
        makePlan(source(.surround71), endpoints(for: .surround71)),
        makePlan(source(.surround71), pairs(2)),
        makePlan(source(.surround71), endpoints(for: .surround51Side)),
        makePlan(source(.surround71), endpoints(for: .surround51Back)),
        makePlan(source(.stereo), endpoints(for: .surround51Side), mode: .upmix, upmix: true),
        makePlan(source(.stereo), endpoints(for: .surround71), mode: .upmix, upmix: true)
    ]

    for plan in plans {
        check(plan.accepted, "invariant plan accepted: \(plan.routeId)")
        check(plan.schemaVersion == 1, "schemaVersion 1")
        check(plan.matrices.count == 1 && plan.matrices[0].version == 1, "one version-1 matrix")
        check(!plan.endpointPlans.isEmpty, "endpoint plans present")
        check(
            Set(plan.endpointPlans.map(\.id)) == Set(plan.endpoints.map(\.id)),
            "every endpoint is covered by a plan"
        )
        check(plan.endpointPlans.allSatisfy { $0.gains.allSatisfy { $0 >= 0 && $0 <= 1 } }, "endpoint gains in [0,1]")
        check(plan.transformations.allSatisfy { $0.l1Norm <= 1.0 + 1e-9 }, "matrix row L1 <= 1")
        check(!plan.routeId.isEmpty, "route id present")
        check(!plan.uiLabel.isEmpty, "ui label present")
    }

    print("PASS: matrix row L1, endpoint coverage and gain invariants")
}
