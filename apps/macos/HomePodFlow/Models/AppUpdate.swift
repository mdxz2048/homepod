import Foundation
import CryptoKit

struct AppUpdateRelease: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let version: String
    let build: Int
    let minimumSystemVersion: String
    let architecture: String
    let packageURL: URL
    let sha256: String
    let bytes: Int64
    let notes: String
}

enum AppUpdateError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let detail): "更新未完成：\(detail)" }
    }
}

enum AppUpdateValidation {
    private struct Envelope: Decodable { let payload: String; let signature: String }

    static func version(_ text: String) throws -> [Int] {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.allSatisfy({ Int($0) != nil }) else { throw AppUpdateError.invalid("版本号格式无效") }
        return parts.map { Int($0)! } + Array(repeating: 0, count: 4 - parts.count)
    }

    static func decode(_ data: Data, publicKey: Data, feedURL: URL,
                       architecture: String, systemVersion: String) throws -> AppUpdateRelease {
        guard data.count <= 1_048_576 else { throw AppUpdateError.invalid("版本信息过大") }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let payload = Data(base64Encoded: envelope.payload),
              let signature = Data(base64Encoded: envelope.signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: payload) else {
            throw AppUpdateError.invalid("版本信息签名不匹配")
        }
        let release = try JSONDecoder().decode(AppUpdateRelease.self, from: payload)
        guard release.schemaVersion == 1, release.build > 0,
              release.bytes > 0, release.bytes <= 2_147_483_648,
              release.sha256.count == 64,
              release.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              release.packageURL.scheme == "https", release.packageURL.host == feedURL.host,
              release.packageURL.user == nil, release.packageURL.password == nil,
              release.packageURL.pathExtension == "pkg",
              release.architecture == architecture || release.architecture == "universal" else {
            throw AppUpdateError.invalid("安装包地址、架构或校验信息无效")
        }
        _ = try version(release.version)
        guard try !version(systemVersion).lexicographicallyPrecedes(version(release.minimumSystemVersion)) else {
            throw AppUpdateError.invalid("新版需要 macOS \(release.minimumSystemVersion) 或更高版本")
        }
        return release
    }

    static func isNewer(_ release: AppUpdateRelease, currentVersion: String, currentBuild: Int) throws -> Bool {
        let available = try version(release.version), current = try version(currentVersion)
        return current.lexicographicallyPrecedes(available) || (current == available && release.build > currentBuild)
    }

    static func verifyPackage(_ url: URL, release: AppUpdateRelease) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == release.bytes else {
            throw AppUpdateError.invalid("安装包大小不匹配，请重新下载")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        let hex = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard hex == release.sha256 else { throw AppUpdateError.invalid("安装包校验失败，当前版本保持不变") }
    }
}
