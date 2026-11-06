import SwiftUI
import AppKit

@main
struct HomePodFlowApp: App {
    @NSApplicationDelegateAdaptor(FlowApplicationDelegate.self) private var appDelegate
    @State private var state: AppState
    init() {
        let initialState = DebugCapture.makeState()
        _state = State(initialValue: initialState)
        appDelegate.worker = initialState.worker
        appDelegate.systemAudio = initialState.systemAudio
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--show-settings") {
            DispatchQueue.main.async {
                DebugCapture.showInspectionWindow(state: initialState)
            }
        }
        #endif
    }
    var body: some Scene {
        MenuBarExtra("HomePod Flow", systemImage: "hifispeaker.fill") {
            MenuContent(state: state)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appSettings) {
                Button("退出 HomePod Flow") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }

        Window("HomePod Flow", id: "settings") { settingsContent }
            .defaultSize(width: 960, height: 650)
            .defaultLaunchBehavior(.suppressed)
    }
    private var settingsContent: some View {
        SettingsRootView(state: state)
            .frame(minWidth: 900, minHeight: 620)
            .onAppear {
                #if DEBUG
                DebugCapture.configure(state)
                DebugCapture.captureIfRequested(state: state)
                DebugCapture.runCaptureCheckIfRequested()
                #endif
            }
    }
}

private struct MenuContent: View {
    @Bindable var state: AppState
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        MenuPopoverView(state: state, onOpenSettings: openSettings)
    }
    private func openSettings() {
        openWindow(id: "settings")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

/* The default launch contains only MenuBarExtra; its sole settings Window is
   suppressed until explicitly requested. DEBUG inspection can opt into it. */
