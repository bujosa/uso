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

    @Test func grokBotUnifiedDoesNotInventASecondWeek() {
        let snapshot = QuotaParsing.grokBot(
            parse(
                """
                {"isUnified":true,"usagePercent":8.693925444534706,"grokPlanLabel":"SuperGrok Heavy","cursorPlanName":"Ultra","billingBrand":"SAND_BILLING_BRAND_GROK"}
                """))
        #expect(snapshot.tone == .ready)
        #expect(snapshot.bars.isEmpty)
        #expect(snapshot.headline == "Shared weekly pool")
        #expect(snapshot.plan == "Ultra · SuperGrok Heavy")
        #expect(snapshot.note?.contains("same weekly pool") == true)
        #expect(snapshot.sharedPool == .member)
        #expect(MenuTicker.lines(from: [snapshot]).isEmpty)
    }

    @Test func grokUnifiedTurnsProductSharesIntoMixNotExtraMeters() {
        let snapshot = QuotaParsing.grok(
            parse(
                """
                {"creditUsagePercent":8,"isUnifiedBillingUser":true,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-11-03T22:48:40.363Z"},"productUsage":[{"product":"Cursor","usagePercent":6},{"product":"GrokBot","usagePercent":2}],"prepaidBalance":{"val":1500}}
                """), plan: "SuperGrok Heavy")
        #expect(snapshot.bars.map(\.id) == ["credits"])
        #expect(snapshot.bars.first?.label == "Week")
        #expect(snapshot.bars.first?.usedPercent == 8)
        #expect(snapshot.headline == "92% left")
        #expect(snapshot.lines == ["Mix · Cursor 6% · Grok Bot 2%", "Prepaid $15"])
        #expect(snapshot.note?.contains("shared weekly pool") == true)
        #expect(snapshot.sharedPool == .member)
        #expect(MenuTicker.lines(from: [snapshot]) == ["Grok 92%"])
    }

    @Test func grokLegacyKeepsProductMeters() {
        let snapshot = QuotaParsing.grok(
            ["creditUsagePercent": 12, "productUsage": [["product": "GrokBuild", "usagePercent": 40]]], plan: "Grok")
        #expect(snapshot.bars.map(\.id) == ["credits", "GrokBuild"])
        #expect(snapshot.bars.map(\.label) == ["Period", "Build"])
        #expect(snapshot.note == nil)
    }

    @Test func cursorMergedUsesSharedWeekAndDropsTheDuplicateApiBar() {
        let reset = Date(timeIntervalSince1970: 1_762_207_720)
        let snapshot = QuotaParsing.cursor(
            period: [
                "planUsage": ["autoPercentUsed": 8.693925444534706, "apiPercentUsed": 8.693925444534706]
            ], plan: "Ultra", merged: true, includedReset: reset, tokenLine: "12 in · 4 out · 0 cache",
            modelLine: nil)
        #expect(snapshot.bars.map(\.id) == ["week"])
        #expect(snapshot.bars.first?.label == "Week")
        #expect(snapshot.headline == "91% left")
        #expect(snapshot.lines == ["12 in · 4 out · 0 cache"])
        #expect(snapshot.note?.contains("shared with Grok") == true)
        #expect(snapshot.sharedPool == .owner)
        #expect(MenuTicker.lines(from: [snapshot]) == ["X 91%"])
    }

    @Test func cursorLegacyKeepsAutoIncludedAndApi() {
        let snapshot = QuotaParsing.cursor(
            period: [
                "planUsage": [
                    "autoPercentUsed": 10, "apiPercentUsed": 3, "limit": 2000, "includedSpend": 500,
                    "remaining": 1500,
                ]
            ], plan: "Pro", merged: false, includedReset: nil, tokenLine: "", modelLine: nil)
        #expect(snapshot.bars.map(\.id) == ["auto", "included", "api"])
        #expect(snapshot.bars.first?.detail == "Other models")
        #expect(snapshot.headline == "90% left")
        #expect(snapshot.note == nil)
        #expect(MenuTicker.lines(from: [snapshot]) == ["Cursor Auto 90%", "Cursor $15"])
    }

    @Test func unifiedLayoutFoldsMembersIntoOneWeekAndKeepsGemini() {
        let grok = QuotaParsing.grok(
            parse(
                """
                {"creditUsagePercent":8,"isUnifiedBillingUser":true,"productUsage":[{"product":"Cursor","usagePercent":6},{"product":"GrokBot","usagePercent":2}],"prepaidBalance":{"val":1500}}
                """), plan: "SuperGrok Heavy")
        let bot = QuotaParsing.grokBot(["isUnified": true, "usagePercent": 8.693925444534706])
        let cursor = QuotaParsing.cursor(
            period: ["planUsage": ["autoPercentUsed": 8.693925444534706, "apiPercentUsed": 8.693925444534706]],
            plan: "Ultra", merged: true, includedReset: nil, tokenLine: "12 in · 4 out", modelLine: nil)
        let gemini = QuotaParsing.gemini(
            parse(
                """
                {"groups":[{"displayName":"Gemini models","buckets":[
                  {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":1},
                  {"bucketId":"gemini-5h","window":"5h","remainingFraction":1}
                ]}]}
                """), plan: "Free")
        let presented = UnifiedBilling.present([grok, bot, cursor, gemini], keepMember: { _ in false })
        #expect(presented.map(\.id) == ["cursor", "gemini"])
        #expect(presented[0].name == "X Subscription")
        #expect(presented[0].plan == "Ultra · SuperGrok Heavy")
        #expect(presented[0].lines == ["12 in · 4 out", "Mix · Cursor 6% · Grok Bot 2%", "Prepaid $15"])
        #expect(presented[1].name == "Gemini")
        #expect(MenuTicker.lines(from: presented) == ["X 91%", "Gemini 5h 100%", "Gemini wk 100%"])
        #expect(UnifiedBilling.present([grok, bot], keepMember: { _ in false }).map(\.id) == ["grok", "grok-bot"])
        let shownGrok = UnifiedBilling.present([grok, bot, cursor], keepMember: { $0 == "grok" })
        #expect(shownGrok.map(\.id) == ["grok", "cursor"])
        #expect(shownGrok[0].bars.isEmpty)
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

    @Test func geminiUsesRemainingFractionAndPrefersTheGeminiGroup() {
        let snapshot = QuotaParsing.gemini(
            parse(
                """
                {"groups":[
                  {"displayName":"Claude and GPT models","buckets":[
                    {"bucketId":"3p-weekly","window":"weekly","remainingFraction":0.4,"resetTime":"2026-11-04T02:45:25Z"},
                    {"bucketId":"3p-5h","window":"5h","remainingFraction":0.7,"resetTime":"2026-10-28T07:45:25Z"}
                  ]},
                  {"displayName":"Gemini models","buckets":[
                    {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.2},
                    {"bucketId":"gemini-5h","window":"5h","remainingFraction":0.9}
                  ]}
                ]}
                """), plan: "Google AI Pro")
        #expect(snapshot.tone == .ready)
        #expect(snapshot.plan == "Google AI Pro")
        #expect(snapshot.bars.map(\.id) == ["session", "week", "claude:session", "claude:week"])
        #expect(snapshot.bars.first?.label == "Session")
        #expect(snapshot.bars.first?.usedPercent == 10)
        #expect(snapshot.headline == "90% left")
        #expect(MenuTicker.lines(from: [snapshot]) == ["Gemini 5h 90%", "Gemini wk 20%"])
    }

    @Test func geminiPromotesTheOnlyGroupWhenGeminiIsMissing() {
        let snapshot = QuotaParsing.gemini(
            parse(
                """
                {"groups":[{"displayName":"Claude and GPT models","buckets":[
                  {"bucketId":"3p-weekly","window":"weekly","remainingFraction":1},
                  {"bucketId":"3p-5h","window":"5h","remainingFraction":1}
                ]}]}
                """), plan: "Free")
        #expect(snapshot.bars.map(\.id) == ["session", "week"])
        #expect(snapshot.bars.map(\.usedPercent) == [0, 0])
        #expect(snapshot.headline == "100% left")
        #expect(snapshot.plan == "Free")
    }

    @Test(arguments: ["{}", "{\"groups\":[]}", "{\"groups\":[{\"buckets\":[{\"window\":\"5h\"}]}]}"])
    func geminiInvalidWindowsFailInsteadOfReportingFullQuota(json: String) {
        let snapshot = QuotaParsing.gemini(parse(json), plan: "Free")
        #expect(snapshot.tone == .failed)
        #expect(snapshot.bars.isEmpty)
        #expect(MenuTicker.lines(from: [snapshot]).isEmpty)
    }

    @Test func geminiPlanMapsGoogleAITiers() {
        #expect(Format.geminiPlan(tierID: "g1-pro-tier", name: "Google AI Pro") == "Google AI Pro")
        #expect(Format.geminiPlan(tierID: "g1-ultra-tier", name: "Google AI Ultra") == "Google AI Ultra")
        #expect(Format.geminiPlan(tierID: "free-tier", name: "Antigravity") == "Free")
        #expect(Format.geminiPlan(tierID: "standard-tier", name: "Antigravity") == "Standard")
        #expect(Format.geminiPlan(tierID: nil, name: nil) == "Gemini")
    }

    @Test func geminiPlanPrefersGoogleOnePaidTierOverAntigravityFree() {
        #expect(
            Format.geminiPlan(from: [
                "currentTier": ["id": "free-tier", "name": "Antigravity"],
                "paidTier": ["id": "g1-pro-tier", "name": "Google AI Pro"],
            ]) == "Google AI Pro")
        #expect(
            Format.geminiPlan(from: [
                "currentTier": ["id": "standard-tier", "name": "Antigravity"],
                "paidTier": ["id": "g1-ultra-tier", "name": "Google AI Ultra"],
            ]) == "Google AI Ultra")
        #expect(
            Format.geminiPlan(from: ["currentTier": ["id": "free-tier", "name": "Antigravity"]]) == "Free")
    }

    @Test func geminiOAuthClientIsThePublicAntigravityApp() {
        #expect(GeminiSession.oauthClientID.hasPrefix("1071006060591-"))
        #expect(GeminiSession.oauthClientID.hasSuffix(".apps.googleusercontent.com"))
        #expect(GeminiSession.oauthClientSecret.hasPrefix("GOCSPX-"))
        #expect(GeminiSession.oauthClientSecret.count == 35)
    }

    @Test func geminiSessionReadsGoKeyringJSON() {
        let json = """
            {"token":{"access_token":"ya29.example","refresh_token":"1//abc","expiry":"2026-10-28T00:00:00Z"},"auth_method":"consumer"}
            """
        let wrapped = Data("go-keyring-base64:".utf8) + Data(json.utf8).base64EncodedData()
        let credentials = GeminiSession.credentials(from: wrapped)
        #expect(credentials?.accessToken == "ya29.example")
        #expect(credentials?.refreshToken == "1//abc")
        #expect(credentials?.expiry != nil)
        #expect(GeminiSession.credentials(from: Data(json.utf8))?.accessToken == "ya29.example")
        #expect(GeminiSession.credentials(from: Data("{}".utf8)) == nil)
    }

    @Test func networkCacheIsDisabledForUsageReads() {
        #expect(HTTP.session.configuration.urlCache == nil)
        #expect(HTTP.session.configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    }
}
