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
        let snapshot = await client.load()
        #expect(snapshot.tone == .missing)
        #expect(snapshot.connection == .signInRequired)
        #expect(snapshot.isDetected)
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
        #expect(snapshot.connection == .keychainPermission)
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

private final class KeychainCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var prompts: [Bool] = []
    func record(_ prompt: Bool) { lock.withLock { prompts.append(prompt) } }
    var recorded: [Bool] { lock.withLock { prompts } }
}

struct ClaudeSessionTests {
    private func session(expiresIn seconds: Double) -> KeychainRead {
        let expires = Int((Date().timeIntervalSince1970 + seconds) * 1000)
        return .data(
            Data(
                "{\"claudeAiOauth\":{\"accessToken\":\"fixture-session\",\"expiresAt\":\(expires),\"subscriptionType\":\"max\"}}"
                    .utf8))
    }

    @Test func expiredSessionDoesNotAskForKeychainAccess() {
        let calls = KeychainCalls()
        let stale = session(expiresIn: -60)
        let sources = ClaudeCredentialSources(
            viaSecurity: { stale },
            keychain: {
                calls.record($0)
                return .needsPermission
            }, file: { nil })
        guard case .expired = ClaudeSession.read(prompt: false, from: sources) else {
            Issue.record("An expired session must not be reported as a keychain permission problem.")
            return
        }
        guard case .expired = ClaudeSession.read(prompt: true, from: sources) else {
            Issue.record("Allowing access cannot renew an expired session.")
            return
        }
        #expect(calls.recorded.isEmpty)
    }

    @Test func currentSessionIsUsedWithoutTheKeychainPrompt() {
        let calls = KeychainCalls()
        let current = session(expiresIn: 3600)
        let sources = ClaudeCredentialSources(
            viaSecurity: { current },
            keychain: {
                calls.record($0)
                return .needsPermission
            }, file: { nil })
        guard case .available(let credentials) = ClaudeSession.read(prompt: false, from: sources) else {
            Issue.record("A current session should be available.")
            return
        }
        #expect(credentials.accessToken == "fixture-session")
        #expect(calls.recorded.isEmpty)
    }

    @Test func expiredKeychainSessionFallsBackToACurrentCredentialsFile() {
        let stale = session(expiresIn: -60)
        guard case .data(let current) = session(expiresIn: 3600) else { return }
        let sources = ClaudeCredentialSources(
            viaSecurity: { stale }, keychain: { _ in .needsPermission }, file: { current })
        guard case .available = ClaudeSession.read(prompt: false, from: sources) else {
            Issue.record("A current credentials file should be used.")
            return
        }
    }

    @Test func expiredSessionKeepsTheLastReadingWithoutAskingToSignIn() async {
        let client = ClaudeUsageClient(readCredentials: { _ in .expired }, sendUsage: { _ in nil })
        let snapshot = await client.load()
        #expect(snapshot.tone == .failed)
        #expect(snapshot.connection == nil)
        #expect(snapshot.isDetected)
        let previous = QuotaParsing.claude(["five_hour": ["utilization": 5]], plan: "Max")
        let kept = snapshot.keepingLastReading(previous)
        #expect(kept.tone == .ready)
        #expect(kept.warning?.contains("Claude Code is idle") == true)
    }
}
