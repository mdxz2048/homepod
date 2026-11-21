import Foundation

/// Append-only diagnostics for failures that happen outside calibration.
/// Kept in Application Support so the next occurrence has the worker's own
/// stderr instead of only the generic UI message.
enum FlowDiagnosticsLog {
    private static let limit = 512 * 1024

    static func append(_ file: String, _ message: String) {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first else { return }
        let directory = support.appendingPathComponent("HomePod Flow/Diagnostics", isDirectory: true)
        let url = directory.appendingPathComponent(file)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\n=== \(stamp) ===\n\(message)\n"
        guard let data = text.data(using: .utf8) else { return }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? NSNumber, size.intValue > limit {
            try? FileManager.default.removeItem(at: url)
        }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
