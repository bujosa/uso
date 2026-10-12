import Foundation
import Testing

@testable import Uso

private final class MuseFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    private var responses: [HTTP.Response?]
    private var calls = 0
    private var token = "dca:fixture-account-a"

    init(_ responses: [HTTP.Response?]) { self.responses = responses }
    func read() -> MuseCredentialRead { lock.withLock { .oauth(token) } }
    func send() -> HTTP.Response? {
        lock.withLock {
            calls += 1
            return responses.isEmpty ? nil : responses.removeFirst()
        }
    }
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: Double) { lock.withLock { date += seconds } }
    func changeAccount() { lock.withLock { token = "dca:fixture-account-b" } }
    var callCount: Int { lock.withLock { calls } }
}

struct MuseUsageClientTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let quota = """
        {"is_subs_active":true,"subs_tier_name":"Muse Code Power Usage","subs_usage":{
        "window":{"used_percent":24,"window_duration_mins":300,"resets_at":1800000200},
        "weekly":{"used_percent":61,"resets_at":1800600000}}}
        """

    private func response(_ body: String, status: Int = 200, retryAfter: String? = nil) -> HTTP.Response {
        HTTP.Response(status: status, data: Data(body.utf8), retryAfter: retryAfter)
    }

    private func snapshot(_ body: String) throws -> ProviderSnapshot {
        try JSONDecoder().decode(MuseQuotaResponse.self, from: Data(body.utf8)).snapshot(now: now)
    }

    @Test func subscriptionReportsPlanAndBothRemainingWindows() throws {
        let result = try snapshot(quota)
        #expect(result.plan == "Muse Code Power Usage")
        #expect(result.headline == "76% left")
        #expect(result.bars.map(\.label) == ["5 hours", "Week"])
        #expect(result.bars.map(\.usedPercent) == [24, 61])
        #expect(MenuTicker.lines(from: [result]) == ["Muse 5h 76%", "Muse wk 39%"])
        #expect(result.readAt == now)
    }

    @Test func advertisedDurationIsNotAssumedToBeFiveHours() throws {
        let result = try snapshot(quota.replacingOccurrences(of: ":300", with: ":90"))
        #expect(result.bars.first?.label == "90 min")
    }

    @Test func overQuotaReportsZeroRemainingWithoutDroppingTheReading() throws {
        let result = try snapshot(quota.replacingOccurrences(of: ":24", with: ":140"))
        #expect(result.headline == "0% left")
        #expect(result.bars.first?.usedPercent == 140)
    }

    @Test(arguments: ["", ",\"subs_usage\":null"])
    func omittedQuotaKeepsTheVerifiedPlanWithoutInventingPercentages(extra: String) throws {
        let result = try snapshot("{\"is_subs_active\":true,\"subs_tier_name\":\"Muse Code Power Usage\"\(extra)}")
        #expect(result.tone == .ready)
        #expect(result.plan == "Muse Code Power Usage")
        #expect(result.headline == "Quota unavailable")
        #expect(result.bars.isEmpty)
    }

    @Test func billingAndPayAsYouGoHaveNoSubscriptionMeters() throws {
        let billing = try snapshot("{\"is_subs_active\":false,\"require_payment\":true}")
        let metered = try snapshot("{\"is_subs_active\":false}")
        #expect(billing.headline == "Billing needed")
        #expect(metered.plan == "Pay as you go")
        #expect(billing.bars.isEmpty && metered.bars.isEmpty)
    }

    @Test func expiredWindowIsNotReplacedWithAnAssumedFullAllowance() throws {
        let result = try snapshot(quota.replacingOccurrences(of: "1800000200", with: "1799999900"))
        #expect(result.bars.map(\.id) == ["week"])
        #expect(result.headline == "39% left")
    }

    @Test(arguments: [":-1", ":true", ":\"24\""])
    func invalidPercentagesAreRejected(value: String) async {
        let fixture = MuseFixture([response(quota.replacingOccurrences(of: ":24", with: value))])
        let client = MuseUsageClient(
            readCredentials: { _ in fixture.read() }, sendUsage: { _ in fixture.send() }, now: { fixture.now() })
        #expect(await client.load().tone == .failed)
    }

    @Test func malformedQuotaDoesNotBecomeAnEmptySuccessfulReading() async {
        let fixture = MuseFixture([response("{\"is_subs_active\":true,\"subs_usage\":{}}")])
        let client = MuseUsageClient(readCredentials: { _ in fixture.read() }, sendUsage: { _ in fixture.send() })
        #expect(await client.load().tone == .failed)
    }

    @Test func manualRefreshIsBoundedAndPreservesTheOriginalReadingTime() async {
        let fixture = MuseFixture([response(quota), response(quota)])
        let client = MuseUsageClient(
            readCredentials: { _ in fixture.read() }, sendUsage: { _ in fixture.send() }, now: { fixture.now() })
        let first = await client.load()
        fixture.advance(30)
        #expect(await client.load(prompt: true).readAt == first.readAt)
        #expect(fixture.callCount == 1)
        fixture.advance(270)
        #expect(await client.load().readAt == fixture.now())
        #expect(fixture.callCount == 2)
    }

    @Test func cachedWindowsAreReevaluatedAfterTheirResetPasses() async {
        let fixture = MuseFixture([response(quota)])
        let client = MuseUsageClient(
            readCredentials: { _ in fixture.read() }, sendUsage: { _ in fixture.send() }, now: { fixture.now() })
        let first = await client.load()
        fixture.advance(210)
        let cached = await client.load()
        #expect(cached.bars.map(\.id) == ["week"])
        #expect(cached.readAt == first.readAt)
        #expect(fixture.callCount == 1)
    }

    @Test func changingAccountsDoesNotReuseTheOtherAccountsQuota() async {
        let fixture = MuseFixture([response(quota), response("{\"is_subs_active\":false}")])
        let client = MuseUsageClient(
            readCredentials: { _ in fixture.read() }, sendUsage: { _ in fixture.send() }, now: { fixture.now() })
        #expect(await client.load().bars.count == 2)
        fixture.changeAccount()
        #expect(await client.load().bars.isEmpty)
        #expect(fixture.callCount == 2)
    }

    @Test func rejectedSessionClearsQuotaAndRateLimitHonorsRetryAfter() async {
        let rejected = MuseFixture([response("", status: 401)])
        let invalid = MuseUsageClient(readCredentials: { _ in rejected.read() }, sendUsage: { _ in rejected.send() })
        #expect(await invalid.load().tone == .missing)
        let fixture = MuseFixture([response("", status: 429, retryAfter: "600"), response(quota)])
        let limited = MuseUsageClient(
            readCredentials: { _ in fixture.read() }, sendUsage: { _ in fixture.send() }, now: { fixture.now() })
        #expect(await limited.load().tone == .failed)
        fixture.advance(300)
        #expect(await limited.load(prompt: true).tone == .failed)
        #expect(fixture.callCount == 1)
        fixture.advance(300)
        #expect(await limited.load().tone == .ready)
        #expect(fixture.callCount == 2)
    }

    @Test func unavailableCredentialMakesNoProviderRequest() async {
        let fixture = MuseFixture([])
        let denied = MuseUsageClient(readCredentials: { _ in .needsPermission }, sendUsage: { _ in fixture.send() })
        #expect(await denied.load().tone == .missing)
        let api = MuseUsageClient(readCredentials: { _ in .apiKey }, sendUsage: { _ in fixture.send() })
        #expect(await api.load().plan == "API key · pay as you go")
        #expect(fixture.callCount == 0)
    }

    @Test func inlineLoginOwnsTheAccountAndInferenceKeysAreNeverSentAsOAuth() {
        let metadata = Data(
            "{\"providers\":{\"meta\":{\"mechanism\":\"oauth\",\"access_token\":\"dca:fixture-inline\",\"storage\":\"keychain\"}}}"
                .utf8)
        let result = MuseSession.resolve(metadata: metadata) {
            Issue.record("Inline login should not access Keychain")
            return .missing
        }
        guard case .oauth(let token) = result else {
            Issue.record("Expected inline account")
            return
        }
        #expect(token == "dca:fixture-inline")
        guard case .missing = MuseSession.credential("LLM|fixture-inference-key") else {
            Issue.record("Inference key accepted as OAuth")
            return
        }
    }

    @Test func keychainLoginRequiresMetadataAndPreservesPermissionState() {
        let metadata = Data("{\"providers\":{\"meta\":{\"mechanism\":\"oauth\",\"storage\":\"keychain\"}}}".utf8)
        guard case .needsPermission = MuseSession.resolve(metadata: metadata, readSecret: { .needsPermission }) else {
            Issue.record("Expected explicit permission state")
            return
        }
        guard
            case .missing = MuseSession.resolve(
                metadata: nil,
                readSecret: {
                    Issue.record("No metadata should not access Keychain")
                    return .missing
                })
        else {
            Issue.record("Expected missing login")
            return
        }
    }
}
