import Foundation
import Darwin

/// Nonblocking fd writes on a dedicated queue. Queue admission is bounded and
/// never waits for the receiver; timeout/failure is visible to the controller.
public final class BoundedPipeWriter: @unchecked Sendable {
    private let descriptor: Int32
    private let limit: Int
    private let deadline: TimeInterval
    private let queue = DispatchQueue(label: "HomePodFlow.capture.stdout")
    private let lock = NSLock()
    private var pending = 0
    private var errorText: String?
    public var failure: String? { lock.withLock { errorText } }
    public var pendingBytes: Int { lock.withLock { pending } }
    public init(descriptor: Int32, capacity: Int = 262144, writeTimeout: TimeInterval = 1) throws {
        guard capacity >= 65536, capacity <= 2097152, writeTimeout.isFinite, (0.05...2).contains(writeTimeout) else {
            throw HostFailure.invalid("Invalid bounded writer configuration")
        }
        self.descriptor = descriptor; limit = capacity; deadline = writeTimeout
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0,
              fcntl(descriptor, F_SETNOSIGPIPE, 1) >= 0 else { throw HostFailure.output("Cannot configure nonblocking capture pipe") }
    }
    public func enqueue(_ record: Data) throws {
        try lock.withLock {
            guard errorText == nil else { throw HostFailure.output(errorText!) }
            guard !record.isEmpty, record.count <= limit, pending + record.count <= limit else {
                errorText = "stdout queue overflow"; throw HostFailure.output("stdout queue overflow")
            }
            pending += record.count
        }
        queue.async { [self] in
            defer { lock.withLock { pending -= record.count } }
            if failure != nil { return }
            do { try write(record) }
            catch { lock.withLock { errorText = error.localizedDescription } }
        }
    }
    public func flush(timeout: TimeInterval = 2) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while pendingBytes > 0, failure == nil, Date() < end {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return pendingBytes == 0 && failure == nil
    }
    private func write(_ data: Data) throws {
        let end = Date().addingTimeInterval(deadline)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0, errno == EINTR { continue }
                if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    guard Date() < end else { throw HostFailure.output("stdout write deadline exceeded") }
                    var item = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    let result = poll(&item, 1, 20)
                    if result < 0, errno != EINTR { throw HostFailure.output("stdout poll failed") }
                    continue
                }
                throw HostFailure.output("stdout closed or write failed")
            }
        }
    }
}
