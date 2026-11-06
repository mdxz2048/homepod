import AppKit

@MainActor final class FlowApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var worker: WorkerStore?
    weak var systemAudio: SystemAudioStore?
    private var terminationPending = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        guard worker != nil || systemAudio != nil else { return .terminateNow }
        // Revoke synchronously before scheduling asynchronous cleanup or returning to AppKit.
        systemAudio?.revokePlaybackIntent()
        terminationPending = true
        Task { @MainActor in
            #if DEBUG
            DebugCapture.stopCaptureCheck()
            #endif
            await systemAudio?.prepareForTermination()
            await worker?.disconnectWorker()
            // Failure text remains truthful: forced exit is not a clean audio
            // shutdown. The managed process already performed bounded escalation.
            NSLog("HomePod Flow termination: %@", systemAudio?.statusText ?? worker?.workerStatus ?? "no worker")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        systemAudio?.revokePlaybackIntent()
    }
}
