import Foundation
import Testing

@testable import Uso

struct CredentialReadDeadlineTests {
    @Test func completedReadReturnsTheResultWithoutCachingIt() {
        let reader = CredentialReadDeadline()
        guard case .data(let first) = reader.read(id: "fixture", timeout: 1, operation: { .data(Data("first".utf8)) })
        else {
            Issue.record("Expected first reading")
            return
        }
        guard case .data(let second) = reader.read(id: "fixture", timeout: 1, operation: { .data(Data("second".utf8)) })
        else {
            Issue.record("Expected new reading")
            return
        }
        #expect(first != second)
    }

    @Test func timeoutDoesNotAdmitAnotherReadWhileTheSystemCallIsStillPending() {
        let reader = CredentialReadDeadline()
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let first = reader.read(id: "fixture", timeout: 0.02) {
            release.wait()
            finished.signal()
            return .data(Data("late fixture".utf8))
        }
        guard case .unavailable = first else {
            Issue.record("Expected deadline")
            return
        }
        let second = reader.read(id: "fixture", timeout: 1) {
            Issue.record("A second blocked read was launched")
            return .missing
        }
        guard case .unavailable = second else {
            Issue.record("Expected pending-read guard")
            return
        }
        release.signal()
        #expect(finished.wait(timeout: .now() + 1) == .success)
    }

    @Test func unavailableCredentialsDoNotMakeRequestsOrPretendToBeSignedOut() async {
        let claude = ClaudeUsageClient(
            readCredentials: { _ in .unavailable },
            sendUsage: { _ in
                Issue.record("An unavailable credential must not be sent")
                return nil
            })
        let result = await claude.load()
        #expect(result.tone == .failed && result.connection == .unverified)
    }
}
