import Foundation
#if canImport(AppKit)
import AppKit
import Network
#endif

enum SystemAudioEnvironmentEvent: Sendable {
    case willSleep, didWake, willTerminate, networkChanged
    case networkAvailable(Bool)
}

/// Notifications never start a first session. The store applies user intent and cleanup gates.
@MainActor final class SystemAudioEnvironmentController {
    private let handler: @MainActor (SystemAudioEnvironmentEvent) -> Void
    private var valid = true
    #if canImport(AppKit)
    private var workspaceObservers: [NSObjectProtocol] = []
    private var appObserver: NSObjectProtocol?
    private let monitor = NWPathMonitor()
    private var lastNetworkAvailable: Bool?
    #endif

    init(handler: @escaping @MainActor (SystemAudioEnvironmentEvent) -> Void) {
        self.handler = handler
        #if canImport(AppKit)
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.deliver(.willSleep) }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.deliver(.didWake) }
        })
        appObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.deliver(.willTerminate) }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.valid else { return }
                let previous = self.lastNetworkAvailable
                self.lastNetworkAvailable = available
                if previous == available {
                    if available { self.deliver(.networkChanged) }
                } else { self.deliver(.networkAvailable(available)) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.homepodflow.session-network"))
        #endif
    }

    func invalidate() {
        guard valid else { return }; valid = false
        #if canImport(AppKit)
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }; workspaceObservers.removeAll()
        if let appObserver { NotificationCenter.default.removeObserver(appObserver) }
        appObserver = nil; monitor.cancel()
        #endif
    }
    private func deliver(_ event: SystemAudioEnvironmentEvent) { if valid { handler(event) } }
}
