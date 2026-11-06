import Foundation

/// Real Swift store -> owned Python process -> actual native library. Offline
/// only: no discovery, target hosts, microphone, or speaker playback.
@main struct NativeWorkerStoreChecks {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        precondition(args.count == 6, "python project library wav output.json")
        let store = WorkerStore()
        await store.connectWorker(pythonURL: URL(fileURLWithPath: args[1]),
                                  projectURL: URL(fileURLWithPath: args[2]),
                                  libraryURL: URL(fileURLWithPath: args[3]))
        precondition(store.serviceReady, store.workerStatus)
        await store.selectAudioFile(URL(fileURLWithPath: args[4]))
        precondition(store.audioInfo?.channels == 3, store.workerStatus)
        guard let info = store.audioInfo else { preconditionFailure("Missing WAV metadata") }
        store.routeSelections = (0..<3).map { channel in
            DeviceRouteSelection(id: "offline-\(channel)", name: "Offline \(channel)",
                                 host: "", isSelected: true,
                                 leftChannel: channel, rightChannel: channel)
        }
        await store.runOfflineCheck(mode: .cinema)
        precondition(store.serviceReady && !store.isWorkerBusy && !store.hasActiveSession,
                     store.workerStatus + " / " + store.offlineCheckStatus)
        let first = store.lastResultPayload
        guard let report = first["report"]?.object, let outputs = report["outputs"]?.array else {
            preconditionFailure(store.workerStatus + " / " + store.offlineCheckStatus)
        }
        precondition(first["state"]?.string == "completed")
        precondition(report["native_core_used"]?.bool == true)
        precondition(report["network_used"]?.bool == false)
        precondition(report["acoustic_sync_verified"]?.bool == false)
        precondition(report["cleanup_complete"]?.bool == true && report["hub_stopped"]?.bool == true)
        precondition(outputs.count == 3)
        let hashes = outputs.compactMap { $0.object?["native_pcm_sha256"]?.string }
        precondition(Set(hashes).count == 3, "Different channels must yield different output PCM")
        let starts = outputs.compactMap { $0.object?["first_presentation_ns"]?.number }
        precondition(starts.count == 3 && Set(starts).count == 1, "A common native timeline is required")
        for output in outputs {
            precondition(output.object?["native_frames"]?.number == Double(info.frames))
            precondition(output.object?["consumed_frames"]?.number == Double(info.frames))
            precondition(output.object?["native_pcm_sha256"] == output.object?["consumed_pcm_sha256"])
        }
        // A second session uses the same worker and synchronized stereo routes.
        await store.runOfflineCheck(mode: .synchronized)
        guard let secondReport = store.lastResultPayload["report"]?.object,
              let secondOutputs = secondReport["outputs"]?.array else {
            preconditionFailure(store.workerStatus + " / " + store.offlineCheckStatus)
        }
        precondition(secondOutputs.count == 3)
        let identical = secondOutputs.compactMap { $0.object?["native_pcm_sha256"]?.string }
        precondition(identical.count == 3 && Set(identical).count == 1)
        let second = store.lastResultPayload
        await store.disconnectWorker()
        precondition(!store.serviceReady && !store.isWorkerBusy && !store.realIsPlaying)
        precondition(store.workerStatus.contains("清理已确认"), store.workerStatus)
        let evidence: [String: JSONValue] = ["status": .string("passed"),
            "network_used": .bool(false), "speaker_playback_started": .bool(false),
            "cinema_result": .object(first), "synchronized_result": .object(second),
            "shutdown_status": .string(store.workerStatus)]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evidence).write(to: URL(fileURLWithPath: args[5]))
        print("PASS: real Swift store/managed Python/native library; distinct and identical routes; same-worker restart; confirmed shutdown; no network/audio")
    }
}
