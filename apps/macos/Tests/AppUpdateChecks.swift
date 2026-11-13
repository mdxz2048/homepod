import Foundation
import CryptoKit

@main struct AppUpdateChecks {
    @MainActor static func main() throws {
        let key = Curve25519.Signing.PrivateKey()
        let feed = URL(string: "https://updates.example/updates/latest.json")!
        let package = Data("package".utf8)
        let digest = SHA256.hash(data: package).map { String(format: "%02x", $0) }.joined()
        func release(version: String = "0.3.3", build: Int = 4, host: String = "updates.example") -> AppUpdateRelease {
            .init(schemaVersion: 1, version: version, build: build, minimumSystemVersion: "15.0",
                  architecture: "arm64", packageURL: URL(string: "https://\(host)/downloads/update.pkg")!,
                  sha256: digest, bytes: Int64(package.count), notes: "改进")
        }
        func envelope(_ release: AppUpdateRelease, signer: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
            let raw = try JSONEncoder().encode(release)
            return try JSONSerialization.data(withJSONObject: ["payload": raw.base64EncodedString(),
                "signature": try (signer ?? key).signature(for: raw).base64EncodedString()])
        }
        func decode(_ data: Data, os: String = "26.5.2", arch: String = "arm64") throws -> AppUpdateRelease {
            try AppUpdateValidation.decode(data, publicKey: key.publicKey.rawRepresentation,
                                            feedURL: feed, architecture: arch, systemVersion: os)
        }
        func rejects(_ operation: () throws -> Void) {
            do { try operation(); preconditionFailure("invalid update accepted") } catch { }
        }
        let valid = try decode(envelope(release()))
        let newer1 = try AppUpdateValidation.isNewer(valid, currentVersion: "0.3.2", currentBuild: 3)
        precondition(newer1)
        let newer2 = try !AppUpdateValidation.isNewer(valid, currentVersion: "0.3.3", currentBuild: 4)
        precondition(newer2)
        let newer3 = try AppUpdateValidation.isNewer(release(build: 5), currentVersion: "0.3.3", currentBuild: 4)
        precondition(newer3)
        let newer4 = try !AppUpdateValidation.isNewer(release(version: "0.3.2", build: 999), currentVersion: "0.3.3", currentBuild: 4)
        precondition(newer4)
        rejects { _ = try decode(envelope(release(), signer: Curve25519.Signing.PrivateKey())) }
        var changed = try JSONSerialization.jsonObject(with: envelope(release())) as! [String: String]
        changed["payload"] = try JSONEncoder().encode(release(build: 9)).base64EncodedString()
        rejects { _ = try decode(JSONSerialization.data(withJSONObject: changed)) }
        rejects { _ = try decode(envelope(release(host: "other.example"))) }
        rejects { _ = try decode(envelope(release()), os: "14.6") }
        rejects { _ = try decode(envelope(release()), arch: "x86_64") }
        rejects { _ = try AppUpdateValidation.version("0.3.$(command)") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("package.pkg")
        try package.write(to: url)
        try AppUpdateValidation.verifyPackage(url, release: valid)
        try Data("changed".utf8).write(to: url)
        rejects { try AppUpdateValidation.verifyPackage(url, release: valid) }
        try Data("x".utf8).write(to: url)
        rejects { try AppUpdateValidation.verifyPackage(url, release: valid) }
        precondition(AppUpdateService.shellQuote("a'b") == "'a'\\''b'")
        print("AppUpdateChecks: signature/tamper, version/build/downgrade, origin, OS/architecture, package hash/size and shell quoting passed; no installation executed")
    }
}
