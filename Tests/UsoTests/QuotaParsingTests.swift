import Foundation
import Testing

@testable import Uso

struct QuotaParsingTests {
    private func parse(_ json: String) -> [String: Any] {
        JSON.object(from: Data(json.utf8))!
    }

    @Test func grokBotUsesItsOwnWeeklyPercentage() {
        let snapshot = QuotaParsing.grokBot(
            parse(
                """
                {"usagePercent":63.9694,"nextResetTimestampUtc":"2026-10-13T22:55:39.818Z","grokPlanLabel":"Grok Bot Plan","cursorPlanName":"Ultra"}
                """))
        #expect(snapshot.tone == .ready)
        #expect(snapshot.bars.first?.usedPercent == 63.9694)
        #expect(snapshot.headline == "36% left")
        #expect(MenuTicker.lines(from: [snapshot]) == ["Grok Bot 36%"])
        #expect(snapshot.note?.contains("Separate from Grok Build") == true)
    }

    @Test(arguments: [
        "{}", "{\"usagePercent\":null}", "{\"usagePercent\":true}", "{\"usagePercent\":-1}",
        "{\"usagePercent\":\"nan\"}",
    ])
    func grokBotNeverInventsUnusedQuota(json: String) {
        let snapshot = QuotaParsing.grokBot(parse(json))
        #expect(snapshot.tone == .failed)
        #expect(snapshot.bars.isEmpty)
        #expect(MenuTicker.lines(from: [snapshot]).isEmpty)
    }

    @Test(arguments: [0.0, 1.0, 100.0, 125.0])
    func grokBotAcceptsZeroAndOverage(used: Double) {
        let snapshot = QuotaParsing.grokBot(["usagePercent": used])
        #expect(snapshot.tone == .ready)
        #expect(snapshot.bars.first?.usedPercent == used)
        if used >= 100 { #expect(snapshot.headline == "0% left") }
    }

    @Test func grokBotPooledAllowanceDoesNotBecomePersonalQuota() {
        let snapshot = QuotaParsing.grokBot(["usagePercent": 12, "usesPooledEnterpriseAllowance": true])
        #expect(snapshot.tone == .missing)
        #expect(snapshot.bars.isEmpty)
    }

    @Test func grokBotTrialHasExplicitLabel() {
        let snapshot = QuotaParsing.grokBot(["usagePercent": 80, "sandTrialExpiresAt": "2100-01-01T00:00:00Z"])
        #expect(snapshot.bars.first?.label == "Trial")
    }

    @Test func claudeSortsWindowsAndUsesNewPercentages() {
        let snapshot = QuotaParsing.claude(
            parse(
                """
                {"limits":[
                  {"kind":"weekly_scoped","percent":2,"scope":{"model":{"id":"fixture-model","display_name":"Fable"}}},
                  {"kind":"weekly_all","percent":11},
                  {"kind":"session","percent":5}
                ],"five_hour":{"utilization":99},"seven_day":{"utilization":88}}
                """), plan: "Max")
        #expect(snapshot.bars.map(\.label) == ["Session", "Week", "Fable week"])
        #expect(snapshot.bars.map(\.usedPercent) == [5, 11, 2])
        #expect(snapshot.headline == "95% left")
        #expect(MenuTicker.lines(from: [snapshot]) == ["Claude 5h 95%", "Claude wk 89%"])
    }

    @Test func claudePartialLimitsKeepLegacySessionAndWeek() {
        let snapshot = QuotaParsing.claude(
            parse(
                """
                {"limits":[{"kind":"weekly_scoped","percent":27,"scope":{"model":{"display_name":"Fable"}}}],
                 "five_hour":{"utilization":5},"seven_day":{"utilization":11},"seven_day_overage_included":{"utilization":27}}
                """), plan: "Max")
        #expect(snapshot.bars.map(\.label) == ["Session", "Week", "Fable week"])
        #expect(snapshot.bars.map(\.usedPercent) == [5, 11, 27])
    }

    @Test func claudeLegacyIncludesModelAndSurfaceLimits() {
        let snapshot = QuotaParsing.claude(
            parse(
                """
                {"five_hour":{"utilization":0},"seven_day":{"utilization":1},
                 "seven_day_opus":{"utilization":44},"seven_day_sonnet":{"utilization":55},
                 "seven_day_overage_included":{"utilization":66},"seven_day_oauth_apps":{"utilization":77},
                 "seven_day_cowork":{"utilization":88},"extra_usage":{"is_enabled":true,"utilization":12.5}}
                """), plan: "Max")
        #expect(snapshot.bars.map(\.usedPercent) == [0, 1, 44, 55, 66, 77, 88])
        #expect(snapshot.lines == ["Extra usage 13% used"])
    }

    @Test func claudeDifferentModelIDsStayDistinct() {
        let snapshot = QuotaParsing.claude(
            parse(
                """
                {"limits":[
                  {"kind":"weekly_scoped","percent":22,"scope":{"model":{"id":"model-a","display_name":"Model"}}},
                  {"kind":"weekly_scoped","percent":33,"scope":{"model":{"id":"model-b","display_name":"Model"}}}
                ]}
                """), plan: "Max")
        #expect(snapshot.bars.count == 2)
        #expect(Set(snapshot.bars.map(\.id)).count == 2)
    }

    @Test(arguments: [
        "{}", "{\"limits\":[{\"kind\":\"future_kind\",\"percent\":0}]}", "{\"five_hour\":{\"utilization\":true}}",
        "{\"five_hour\":{\"utilization\":\"inf\"}}",
    ])
    func claudeInvalidWindowsFailInsteadOfReportingFullQuota(json: String) {
        let snapshot = QuotaParsing.claude(parse(json), plan: "Max")
        #expect(snapshot.tone == .failed)
        #expect(snapshot.bars.isEmpty)
    }

    @Test func claudeBreakdownDoesNotChangeRemainingQuota() {
        let snapshot = QuotaParsing.claude(
            parse(
                """
                {"five_hour":{"utilization":25},"seven_day_breakdown":{"rows":[
                  {"display_name":"Claude Code","percent":70},{"display_name":"Web","percent":30}]
                }}
                """), plan: "Max")
        #expect(snapshot.headline == "75% left")
        #expect(snapshot.lines == ["Mix · Claude Code 70% · Web 30%"])
    }

    @Test func failedRefreshKeepsTimestampAndRemovesOldDataFromTicker() {
        var previous = QuotaParsing.claude(["five_hour": ["utilization": 40]], plan: "Max")
        previous.readAt = Date(timeIntervalSince1970: 1_000_000)
        let failure = ProviderSnapshot.problem(id: "claude", name: "Claude", tone: .failed, note: "Can't reach Claude.")
        let kept = failure.keepingLastReading(previous)
        #expect(kept.bars == previous.bars)
        #expect(kept.readAt == previous.readAt)
        #expect(kept.warning?.hasPrefix("Last reading at ") == true)
        #expect(!kept.isCurrent)
        #expect(MenuTicker.lines(from: [kept]).isEmpty)
        #expect(Pressure.hero(from: [kept]) == nil)
        #expect(failure.keepingLastReading(kept).readAt == previous.readAt)
    }

    @Test func signingOutClearsPreviousAccountQuota() {
        let previous = QuotaParsing.claude(["five_hour": ["utilization": 40]], plan: "Max")
        let missing = ProviderSnapshot.problem(id: "claude", name: "Claude", tone: .missing, note: "No session.")
        #expect(missing.keepingLastReading(previous) == missing)
    }

    @Test func successfulRefreshClearsStaleWarning() {
        var stale = QuotaParsing.claude(["five_hour": ["utilization": 40]], plan: "Max")
        stale.warning = "Last reading."
        let fresh = QuotaParsing.claude(["five_hour": ["utilization": 45]], plan: "Max")
        #expect(fresh.keepingLastReading(stale) == fresh)
        #expect(fresh.isCurrent)
    }

    @Test func networkCacheIsDisabledForUsageReads() {
        #expect(HTTP.session.configuration.urlCache == nil)
        #expect(HTTP.session.configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    }
}
