import Foundation

/// Keeps an unresponsive system credential read from holding a refresh forever.
/// Only one outstanding read per service/account/mode is allowed. No result is
/// cached: a late response is discarded when its original caller has timed out.
final class CredentialReadDeadline: @unchecked Sendable {
    static let shared = CredentialReadDeadline()

    private final class Reading: @unchecked Sendable {
        let completion = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var value: KeychainRead = .unavailable

        func finish(_ result: KeychainRead) {
            lock.withLock { value = result }
            completion.signal()
        }

        var result: KeychainRead { lock.withLock { value } }
    }

    private let lock = NSLock()
    private var pending: [String: Reading] = [:]

    func read(id: String, timeout: TimeInterval, operation: @escaping @Sendable () -> KeychainRead) -> KeychainRead {
        let reading = Reading()
        let admitted = lock.withLock {
            guard pending[id] == nil else { return false }
            pending[id] = reading
            return true
        }
        guard admitted else { return .unavailable }
        DispatchQueue.global(qos: .utility).async { [self] in
            let result = operation()
            lock.withLock { pending[id] = nil }
            reading.finish(result)
        }
        guard reading.completion.wait(timeout: .now() + timeout) == .success else { return .unavailable }
        return reading.result
    }
}
