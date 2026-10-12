import Foundation
import Testing

@testable import Uso

private final class Fixture: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var tokens: [String] = []
    private var responses: [HTTP.Response?]
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    let rotates: Bool

    init(_ responses: [HTTP.Response?], rotates: Bool = false) {
        self.responses = responses
        self.rotates = rotates
    }

    func read(_ prompt: Bool) -> ClaudeCredentialRead {
        lock.withLock {
            reads += 1
            return .available(
                ClaudeCredentials(
                    accessToken: rotates && reads > 1 ? "fixture-session-b" : "fixture-session-a", plan: "Max"))
        }
    }

    func send(_ token: String) -> HTTP.Response? {
        lock.withLock {
            tokens.append(token)
            return responses.isEmpty ? nil : responses.removeFirst()
        }
    }

    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: Double) { lock.withLock { date += seconds } }
    var recorded: [String] { lock.withLock { tokens } }
}

struct ClaudeUsageClientTests {
    private func response(_ status: Int, retryAfter: String? = nil) -> HTTP.Response {
        HTTP.Response(
            status: status, data: Data("{\"five_hour\":{\"utilization\":5},\"seven_day\":{\"utilization\":11}}".utf8),
            retryAfter: retryAfter)
    }

    @Test func everyRefreshReadsCurrentCredentials() async {
        let fixture = Fixture([response(200), response(200)], rotates: true)
        let client = ClaudeUsageClient(readCredentials: { fixture.read($0) }, sendUsage: { fixture.send($0) })
        #expect(await client.load().tone == .ready)
        #expect(await client.load().tone == .ready)
        #expect(fixture.recorded == ["fixture-session-a", "fixture-session-b"])
    }

    @Test func unauthorizedRequestRetriesOnlyWithRotatedCredentials() async {
        let fixture = Fixture([response(401), response(200)], rotates: true)
        let client = ClaudeUsageClient(readCredentials: { fixture.read($0) }, sendUsage: { fixture.send($0) })
        #expect(await client.load().tone == .ready)
        #expect(fixture.recorded == ["fixture-session-a", "fixture-session-b"])
    }

    @Test func rejectedUnchangedSessionIsNotRetried() async {
        let fixture = Fixture([response(401)])
        let client = ClaudeUsageClient(readCredentials: { fixture.read($0) }, sendUsage: { fixture.send($0) })
        #expect(await client.load().tone == .missing)
        #expect(fixture.recorded.count == 1)
    }

    @Test func rateLimitHonorsRetryAfterEvenForManualRefresh() async {
        let fixture = Fixture([response(429, retryAfter: "600"), response(200)])
        let client = ClaudeUsageClient(
            readCredentials: { fixture.read($0) }, sendUsage: { fixture.send($0) }, now: { fixture.now() })
        #expect(await client.load().tone == .failed)
        #expect(await client.load(prompt: true).tone == .failed)
        #expect(fixture.recorded.count == 1)
        fixture.advance(600)
        #expect(await client.load().tone == .ready)
        #expect(fixture.recorded.count == 2)
    }

    @Test func retryAfterSupportsHTTPDateAndFallback() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(ClaudeUsageClient.retryDate("Thu, 01 Jan 1970 00:10:00 GMT", now: now) == now.addingTimeInterval(600))
        #expect(ClaudeUsageClient.retryDate(nil, now: now) == now.addingTimeInterval(180))
        #expect(ClaudeUsageClient.retryDate("nan", now: now) == now.addingTimeInterval(180))
    }

    @Test func permissionDeniedDoesNotMakeANetworkRequest() async {
        let fixture = Fixture([])
        let client = ClaudeUsageClient(readCredentials: { _ in .needsPermission }, sendUsage: { fixture.send($0) })
        let snapshot = await client.load()
        #expect(snapshot.tone == .missing)
        #expect(snapshot.note?.hasPrefix("Claude Code is signed in") == true)
        #expect(fixture.recorded.isEmpty)
    }

    @Test func networkAndInvalidPayloadFailuresAreExplicit() async {
        let fixture = Fixture([nil, HTTP.Response(status: 200, data: Data("{}".utf8))])
        let client = ClaudeUsageClient(readCredentials: { fixture.read($0) }, sendUsage: { fixture.send($0) })
        #expect(await client.load().tone == .failed)
        #expect(await client.load().tone == .failed)
    }
}
