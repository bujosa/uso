import Foundation
import Testing

@testable import Uso

struct UsagePreferencesTests {
    @Test func firstLaunchShowsEverySourceAndEnablesAnimations() {
        let name = "UsoTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = UsagePreferences.load(from: defaults)
        #expect(ProviderAccount.all.allSatisfy { preferences.showsInPanel($0.id) && preferences.showsInMenu($0.id) })
        #expect(preferences.animatesPanel)
    }

    @Test func independentDisplayChoicesSurviveRelaunch() {
        let name = "UsoTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("preserved", forKey: "unrelatedPreference")
        let preferences = UsagePreferences(
            hiddenPanelProviders: ["claude"], hiddenMenuProviders: ["grok-bot"], animatesPanel: false)
        preferences.save(to: defaults)
        let relaunched = UsagePreferences.load(from: UserDefaults(suiteName: name)!)
        #expect(!relaunched.showsInPanel("claude"))
        #expect(relaunched.showsInMenu("claude"))
        #expect(relaunched.showsInPanel("grok-bot"))
        #expect(!relaunched.showsInMenu("grok-bot"))
        #expect(!relaunched.animatesPanel)
        #expect(defaults.string(forKey: "unrelatedPreference") == "preserved")
    }

    @Test func showingOneSourceKeepsOtherChoices() {
        let name = "UsoTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var preferences = UsagePreferences(hiddenPanelProviders: ["grok", "opencode"], hiddenMenuProviders: ["claude"])
        preferences.save(to: defaults)
        preferences.hiddenPanelProviders.remove("grok")
        preferences.save(to: defaults)
        let relaunched = UsagePreferences.load(from: defaults)
        #expect(relaunched.showsInPanel("grok"))
        #expect(!relaunched.showsInPanel("opencode"))
        #expect(!relaunched.showsInMenu("claude"))
    }

    @Test func invalidPreferencesFallBackToUsableDefaults() {
        let name = "UsoTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("invalid", forKey: "uso.hiddenPanelProviders")
        defaults.set(12, forKey: "uso.hiddenMenuProviders")
        defaults.set("invalid", forKey: "uso.animatesPanel")
        #expect(UsagePreferences.load(from: defaults) == UsagePreferences())
    }

    @Test func claudePlanUsesOnlyKnownTiers() {
        #expect(Format.claudePlan(subscription: "max", tier: "default_claude_max_20x") == "Max (20×)")
        #expect(Format.claudePlan(subscription: "max", tier: "default_claude_max_5x") == "Max (5×)")
        #expect(Format.claudePlan(subscription: "pro", tier: "default_claude_max_20x") == "Pro")
        #expect(Format.claudePlan(subscription: "max", tier: "unknown_20x") == "Max")
        #expect(Format.claudePlan(subscription: "", tier: nil) == "Claude")
    }

    @Test func grokBotKeepsLinkedPlanAndCursorTierDistinct() {
        let snapshot = QuotaParsing.grokBot([
            "usagePercent": 64, "grokPlanLabel": "Grok Bot Plan", "cursorPlanName": "Ultra",
        ])
        #expect(snapshot.plan == "Grok Bot Plan · Cursor Ultra")
    }
}
