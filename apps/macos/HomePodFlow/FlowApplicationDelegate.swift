import AppKit

@MainActor final class FlowApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var worker: WorkerStore?
    weak var systemAudio: SystemAudioStore?
    private var terminationPending = false
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A plain SIGTERM (kill, logout script, our own installer) bypasses
        // AppKit's termination path and would leave Core Audio on the virtual
        // device. Route it through the normal cleanup instead.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                NSApplication.shared.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }
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
