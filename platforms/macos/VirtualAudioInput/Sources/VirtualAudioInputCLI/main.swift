import Foundation
import VirtualAudioInput

@main
struct VirtualAudioInputCLI {
    @MainActor static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments == ["--discover"] else {
            print("virtual-audio-input --discover\nRead-only HAL discovery. No capture, writes, installation or output switching.\nWith no arguments, prints this help only.")
            if !arguments.isEmpty && arguments != ["--help"] { exit(2) }
            return
        }
        do {
            let result = try VirtualInputClient(backend: HALVirtualDeviceBackend()).discover()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(result), as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
