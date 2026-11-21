import Foundation

/// Hardware integration check: never calls beginProbe, so every frame is zero.
@main struct CalibrationProbePlayerChecks {
    @MainActor static func main() async throws {
        let player = CalibrationProbePlayer()
        defer { player.stop() }
        for channels in [1, 1, 1, 3, 8] {
            try player.start(channels: channels, kind: .sweep)
            try await Task.sleep(for: .milliseconds(250))
            precondition(!player.clockFailed && player.clockLeadMS != nil)
            precondition(player.injectionNS == nil)
            player.silence()
        }
        print("PASS: sequential rearming and group output share a silent, clocked HAL client")
    }
}
