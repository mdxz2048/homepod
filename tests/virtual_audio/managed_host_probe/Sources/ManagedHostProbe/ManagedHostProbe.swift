import Foundation
import Darwin
import TapCaptureHostSupport
import VirtualCaptureHostSupport
@testable import VirtualAudioInput

/// 015 integration-gate probe entry point.
///
/// Without `--serve` it prints one help line and exits 0 (constructor/default
/// are inert). With `--serve` it owns stdout through a real BoundedPipeWriter
/// and runs the real VirtualCaptureHostController against a deterministic
/// FakeProvider, so stdout carries only HPCM v2 records.
@main
struct ManagedHostProbe {
    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments == ["--serve"] else {
            print("managed-host-probe --serve: fake-provider HPCM v2 capture host (stdout HPCM / stdin JSONL v2).")
            return
        }
        do {
            let writer = try BoundedPipeWriter(descriptor: STDOUT_FILENO)
            let controller = VirtualCaptureHostController(writer: writer, factory: { FakeProvider() })

            let reader = Thread {
                var bytes = [UInt8](repeating: 0, count: 4096)
                var buffer = Data()
                let admission = DispatchSemaphore(value: 0)
                while true {
                    let count = bytes.withUnsafeMutableBytes {
                        Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count)
                    }
                    if count < 0, errno == EINTR { continue }
                    if count <= 0 {
                        let invalid = count < 0 || !buffer.isEmpty
                        Task { @MainActor in
                            if invalid {
                                await controller.inputFailed("stdin failed or ended with an incomplete command")
                            } else {
                                await controller.endInput()
                            }
                        }
                        return
                    }
                    buffer.append(contentsOf: bytes.prefix(count))
                    while let end = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<end])
                        buffer.removeSubrange(...end)
                        if line.count + 1 > 65536 {
                            Task { @MainActor in
                                await controller.inputFailed("stdin line exceeds 64 KiB")
                            }
                            return
                        }
                        Task { @MainActor in
                            await controller.command(line)
                            admission.signal()
                        }
                        admission.wait()
                    }
                    if buffer.count >= 65536 {
                        Task { @MainActor in
                            await controller.inputFailed("Unterminated stdin exceeds 64 KiB")
                        }
                        return
                    }
                }
            }
            reader.name = "ManagedHostProbe control"
            reader.start()

            let signals: [any DispatchSourceSignal] = [SIGINT, SIGTERM].map { number in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler {
                    Task { @MainActor in await controller.endInput() }
                }
                source.resume()
                return source
            }

            while !controller.shouldExit {
                try await Task.sleep(for: .milliseconds(5))
            }
            let cleanOutput = await writer.flush()
            signals.forEach { $0.cancel() }
            exit(cleanOutput ? controller.exitCode : 3)
        } catch {
            FileHandle.standardError.write(Data((String(error.localizedDescription.prefix(1024)) + "\n").utf8))
            exit(3)
        }
    }
}
