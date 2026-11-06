import SwiftUI
import AppKit
#if DEBUG
import ScreenCaptureKit
import Darwin
#endif

@MainActor enum DebugCapture {
    static func makeState() -> AppState {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--check-system-route") {
            // Scheduled from the normal GUI launch, independent of lazy Window/MenuBarExtra creation.
            DispatchQueue.main.async { runSystemRouteCheckIfRequested() }
        }
        if ProcessInfo.processInfo.arguments.contains("--capture-directory") {
            let suite = "homepod-flow-ui-capture-\(UUID().uuidString)"
            captureSuite = suite
            return AppState(defaults: UserDefaults(suiteName: suite)!,
                visualDemo: !ProcessInfo.processInfo.arguments.contains("--capture-empty-layout"))
        }
        #endif
        return AppState()
    }
    #if DEBUG
    private static var captureSuite: String?
    private static var inspectionWindow: NSWindow?
    private static var didCapture = false
    private static var captureCheckProcess: Process?
    private static var didCheckCapture = false
    private static var routeCheckProcess: Process?
    private static var didCheckRoute = false

    /// Explicit GUI-child diagnosis only. The helper owns scanning, finite quiet test cycles and cleanup.
    static func runSystemRouteCheckIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard !didCheckRoute, arguments.contains("--check-system-route") else { return }
        didCheckRoute = true
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard let path = value("--route-check-directory"), path.hasPrefix("/"),
              let hosts = value("--route-check-hosts"), !hosts.isEmpty,
              let duration = value("--route-check-seconds"), let seconds = Int(duration), (10...120).contains(seconds) else {
            NSLog("DEBUG route check requires absolute directory, explicit hosts and seconds (10...120)"); return
        }
        let targets = hosts.split(separator: ",", omittingEmptySubsequences: false)
        guard (1...8).contains(targets.count), targets.allSatisfy({ !$0.isEmpty && $0.count <= 255 && !$0.contains(where: \.isWhitespace) }),
              Set(targets).count == targets.count else {
            NSLog("DEBUG route check hosts are invalid"); return
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        var stdout: FileHandle?, stderr: FileHandle?
        do {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let runtime = try JSONDecoder().decode(SystemAudioRuntime.self,
                from: Data(contentsOf: support.appendingPathComponent("HomePod Flow/runtime.json")))
            try runtime.validate()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let output = directory.appendingPathComponent("route.json")
            let errors = directory.appendingPathComponent("route.stderr")
            let exitCode = directory.appendingPathComponent("exit-code.txt")
            // Exclusive creation preserves prior evidence even when another process races this launch.
            let outFD = Darwin.open(output.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            guard outFD >= 0 else { throw CocoaError(.fileWriteFileExists) }
            let out = FileHandle(fileDescriptor: outFD, closeOnDealloc: true); stdout = out
            let errFD = Darwin.open(errors.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            guard errFD >= 0 else { throw CocoaError(.fileWriteFileExists) }
            let err = FileHandle(fileDescriptor: errFD, closeOnDealloc: true); stderr = err
            guard !FileManager.default.fileExists(atPath: exitCode.path) else { throw CocoaError(.fileWriteFileExists) }
            let child = Process()
            child.executableURL = URL(fileURLWithPath: runtime.python)
            child.arguments = ["-u", URL(fileURLWithPath: runtime.project).appendingPathComponent("tests/mac_system_route_check.py").path,
                "--python", runtime.python, "--project", runtime.project, "--library", runtime.library,
                "--capture", runtime.capture_host, "--hosts", hosts, "--seconds", String(seconds),
                "--exclude-pid", String(ProcessInfo.processInfo.processIdentifier)]
            if arguments.contains("--route-check-volume") { child.arguments?.append("--check-volume") }
            child.currentDirectoryURL = URL(fileURLWithPath: runtime.project)
            child.standardOutput = out; child.standardError = err
            child.terminationHandler = { process in
                let status = process.terminationStatus
                try? out.close(); try? err.close()
                try? Data("\(status)\n".utf8).write(to: exitCode, options: .withoutOverwriting)
                Task { @MainActor in routeCheckProcess = nil }
            }
            routeCheckProcess = child
            do { try child.run() }
            catch {
                routeCheckProcess = nil
                try? err.write(contentsOf: Data("GUI route helper launch failed: \(error.localizedDescription)\n".utf8))
                try? Data("-1\n".utf8).write(to: exitCode, options: .withoutOverwriting)
                throw error
            }
        } catch {
            try? stdout?.close(); try? stderr?.close()
            NSLog("DEBUG route check failed: %@", error.localizedDescription)
        }
    }

    /// Explicit development-only check launched by the GUI App, so permission
    /// attribution follows the product rather than an SSH login process.
    static func runCaptureCheckIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard !didCheckCapture, arguments.contains("--check-system-capture"),
              let index = arguments.firstIndex(of: "--capture-check-directory"),
              arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/") else { return }
        didCheckCapture = true
        do {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let runtime = try JSONDecoder().decode(SystemAudioRuntime.self,
                from: Data(contentsOf: support.appendingPathComponent("HomePod Flow/runtime.json")))
            try runtime.validate()
            let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let output = directory.appendingPathComponent("capture.json")
            let errors = directory.appendingPathComponent("capture.stderr")
            guard !FileManager.default.fileExists(atPath: output.path),
                  !FileManager.default.fileExists(atPath: errors.path) else { return }
            FileManager.default.createFile(atPath: output.path, contents: nil)
            FileManager.default.createFile(atPath: errors.path, contents: nil)
            let stdout = try FileHandle(forWritingTo: output)
            let stderr = try FileHandle(forWritingTo: errors)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: runtime.python)
            child.arguments = ["-u", URL(fileURLWithPath: runtime.project).appendingPathComponent("tests/mac_live_capture_check.py").path,
                "--capture", runtime.capture_host, "--test-sound", "--permission-wait", "90",
                "--exclude-pid", String(ProcessInfo.processInfo.processIdentifier)]
            child.currentDirectoryURL = URL(fileURLWithPath: runtime.project)
            child.standardOutput = stdout; child.standardError = stderr
            child.terminationHandler = { child in
                let status = child.terminationStatus
                try? stdout.close(); try? stderr.close()
                try? Data("\(status)\n".utf8).write(to: directory.appendingPathComponent("exit-code.txt"))
                Task { @MainActor in captureCheckProcess = nil }
            }
            captureCheckProcess = child
            try child.run()
        } catch { NSLog("DEBUG capture check failed: %@", error.localizedDescription) }
    }

    static func stopCaptureCheck() {
        if let captureCheckProcess, captureCheckProcess.isRunning { captureCheckProcess.terminate() }
        if let routeCheckProcess, routeCheckProcess.isRunning { routeCheckProcess.terminate() }
    }
    static func showInspectionWindow(state: AppState) {
        configure(state)
        let host = NSHostingView(rootView: SettingsRootView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 650),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "HomePod Flow · DEBUG inspection"
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(NSSize(width: 960, height: 650))
        window.center()
        inspectionWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        captureIfRequested(state: state)
        runCaptureCheckIfRequested()
    }
    static func configure(_ state: AppState) {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--mode-cinema") { state.mode = .cinema }
        if arguments.contains("--mode-sync") { state.mode = .synchronized }
        for page in SettingsPage.allCases where arguments.contains("--page-\(page.rawValue)") {
            state.selectedPage = page
        }
        if arguments.contains("--demo-running") { state.setRunning(true) }
        if arguments.contains("--selected-homepod") {
            state.selectedDeviceID = state.draftLayout.devices.first?.id
        }
        if arguments.contains("--selected-mini") {
            state.selectedDeviceID = state.draftLayout.devices.first(where: { $0.kind == .mini })?.id
        }
        if arguments.contains("--moved-layout"), !state.draftLayout.devices.isEmpty {
            state.draftLayout.devices[0].position = .init(x: 0.67, y: 0.38)
            state.draftLayout.listener = .init(x: 0.43, y: 0.8)
        }
    }
    static func captureIfRequested(state: AppState) {
        let arguments = ProcessInfo.processInfo.arguments
        guard !didCapture, let index = arguments.firstIndex(of: "--capture-directory"),
              arguments.indices.contains(index + 1) else { return }
        didCapture = true
        configure(state)
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let settings = inspectionWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.frame.width >= 800 })
                settings?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    Task { @MainActor in
                        do {
                            if let settings {
                                try await writeOwnWindow(settings,
                                    to: directory.appendingPathComponent("settings.png"))
                            }
                            captureMenu(state: state, directory: directory)
                        } catch {
                            NSLog("DEBUG settings capture failed: %@", String(describing: error))
                        }
                    }
                }
            } catch { NSLog("DEBUG UI capture failed: %@", String(describing: error)) }
        }
    }
    /// Enumerates only windows available to the current process without TCC
    /// consent. Never uses the all-process or display capture discovery API.
    private static func writeOwnWindow(_ window: NSWindow, to url: URL) async throws {
        do {
            let content = try await SCShareableContent.currentProcess
            guard let own = content.windows.first(where: {
                $0.windowID == CGWindowID(window.windowNumber)
            }) else { throw CaptureError.windowUnavailable }
            let filter = SCContentFilter(desktopIndependentWindow: own)
            let configuration = SCStreamConfiguration()
            let scale = window.backingScaleFactor
            configuration.width = max(1, Int(window.frame.width * scale))
            configuration.height = max(1, Int(window.frame.height * scale))
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration)
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw CaptureError.encodingFailed
            }
            try data.write(to: url)
            try Data("ScreenCaptureKit current-process window\n".utf8)
                .write(to: url.deletingPathExtension().appendingPathExtension("capture-method.txt"))
        } catch {
            NSLog("DEBUG own-window capture unavailable, falling back to view cache: %@",
                  String(describing: error))
            guard let view = window.contentView else { throw error }
            try write(view: view.superview ?? view, to: url)
            try Data("AppKit view cache fallback; compositor/vibrancy may be absent\n".utf8)
                .write(to: url.deletingPathExtension().appendingPathExtension("capture-method.txt"))
        }
    }
    private enum CaptureError: Error { case windowUnavailable, encodingFailed }
    private static func captureMenu(state: AppState, directory: URL) {
        let menu = NSHostingView(rootView: MenuPopoverView(state: state, onOpenSettings: {}))
        menu.frame = NSRect(x: 0, y: 0, width: 372, height: 650)
        menu.layoutSubtreeIfNeeded()
        let height = max(620, min(1000, menu.fittingSize.height))
        menu.frame = NSRect(x: 0, y: 0, width: 372, height: height)
        let host = DebugMenuWindow(contentRect: menu.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = menu
        host.center()
        host.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            defer {
                host.orderOut(nil)
                if let suite = captureSuite { UserDefaults.standard.removePersistentDomain(forName: suite) }
            }
            do {
                menu.layoutSubtreeIfNeeded()
                try write(view: menu, to: directory.appendingPathComponent("menu-content.png"))
                try Data("AppKit view cache; active temporary host, not system menu popover\n".utf8)
                    .write(to: directory.appendingPathComponent("menu-content.capture-method.txt"))
            } catch { NSLog("DEBUG menu capture failed: %@", String(describing: error)) }
        }
    }
    private static func write(view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try data.write(to: url)
    }
    #endif
}

#if DEBUG
private final class DebugMenuWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
#endif
