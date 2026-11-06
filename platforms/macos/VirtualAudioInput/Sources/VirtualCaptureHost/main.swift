import Foundation
import Darwin
import TapCaptureHostSupport
import VirtualCaptureHostSupport

@main struct VirtualCaptureHost {
    @MainActor static func main() async {
        guard CommandLine.arguments.dropFirst().elementsEqual(["--serve"]) else {
            print("virtual-audio-host --serve: HPCM stdout / JSONL stdin. Default help never captures. Start is explicit; one session per process.")
            return
        }
        do {
            let writer = try BoundedPipeWriter(descriptor: STDOUT_FILENO)
            let controller = VirtualCaptureHostController(writer: writer)
            guard let usage = Bundle.main.object(forInfoDictionaryKey: "NSAudioCaptureUsageDescription") as? String, !usage.isEmpty else {
                try writer.enqueue(VirtualCaptureHostController.control([
                    "v": 2, "kind": "error", "id": NSNull(), "session": NSNull(),
                    "code": "host_configuration", "message": "Capture host requires NSAudioCaptureUsageDescription",
                    "cleanupComplete": true]))
                _ = await writer.flush(); exit(2)
            }
            let reader = Thread {
                var bytes = [UInt8](repeating: 0, count: 4096)
                var buffer = Data()
                let admission = DispatchSemaphore(value: 0)
                while true {
                    let count = bytes.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
                    if count < 0, errno == EINTR { continue }
                    if count <= 0 {
                        let invalid = count < 0 || !buffer.isEmpty
                        Task { @MainActor in
                            if invalid { await controller.inputFailed("stdin failed or ended with an incomplete command") }
                            else { await controller.endInput() }
                        }
                        return
                    }
                    buffer.append(contentsOf: bytes.prefix(count))
                    while let end = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                        if line.count + 1 > 65536 {
                            Task { @MainActor in await controller.inputFailed("stdin line exceeds 64 KiB") }; return
                        }
                        Task { @MainActor in await controller.command(line); admission.signal() }
                        admission.wait() // Reader only; never RT or control actor.
                    }
                    if buffer.count >= 65536 {
                        Task { @MainActor in await controller.inputFailed("Unterminated stdin exceeds 64 KiB") }; return
                    }
                }
            }
            reader.name = "HomePod Flow capture control"
            reader.start()
            let signals: [any DispatchSourceSignal] = [SIGINT, SIGTERM].map { number in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { Task { @MainActor in await controller.endInput() } }
                source.resume(); return source
            }
            while !controller.shouldExit { try await Task.sleep(for: .milliseconds(5)) }
            let cleanOutput = await writer.flush()
            signals.forEach { $0.cancel() }
            exit(cleanOutput ? controller.exitCode : 3)
        } catch {
            FileHandle.standardError.write(Data((String(error.localizedDescription.prefix(1024)) + "\n").utf8))
            exit(3)
        }
    }
}
