import Foundation
import Testing

@testable import Uso

struct UsagePreferencesTests {
    @Test func firstLaunchShowsOnlyDetectedSourcesAndEnablesAnimations() {
        let name = "UsoTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = UsagePreferences.load(from: defaults)
        #expect(
            ProviderAccount.all.allSatisfy {
                preferences.showsInPanel($0.id, detected: true) && preferences.showsInMenu($0.id, detected: true)
            })
        #expect(
            ProviderAccount.all.allSatisfy {
                !preferences.showsInPanel($0.id, detected: false) && !preferences.showsInMenu($0.id, detected: false)
            })
        #expect(preferences.animatesPanel)
    }

    @Test func explicitChoicesOverrideDetectionBothWays() {
        var preferences = UsagePreferences()
        preferences.setShownInPanel(false, id: "claude")
        preferences.setShownInPanel(true, id: "grok")
        #expect(!preferences.showsInPanel("claude", detected: true))
        #expect(preferences.showsInPanel("grok", detected: false))
        #expect(preferences.showsInMenu("claude", detected: true))
        preferences.setShownInPanel(true, id: "claude")
        #expect(preferences.showsInPanel("claude", detected: false))
        preferences.followDetection()
        #expect(!preferences.showsInPanel("grok", detected: false))
        #expect(preferences.showsInPanel("claude", detected: true))
    }

    @Test func showAllIncludesSourcesNotFoundOnThisMac() {
        var preferences = UsagePreferences(hiddenPanelProviders: ["claude"], hiddenMenuProviders: ["openai"])
        preferences.showAll(ProviderAccount.all.map(\.id))
        #expect(
            ProviderAccount.all.allSatisfy {
                preferences.showsInPanel($0.id, detected: false) && preferences.showsInMenu($0.id, detected: false)
            })
    }

    @Test func upgradeKeepsHiddenSourcesAndFollowsDetectionForTheRest() {
        let name = "UsoTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["opencode"], forKey: "uso.hiddenPanelProviders")
        defaults.set([String](), forKey: "uso.hiddenMenuProviders")
        let upgraded = UsagePreferences.load(from: defaults)
        #expect(!upgraded.showsInPanel("opencode", detected: true))
        #expect(upgraded.showsInPanel("claude", detected: true))
        #expect(!upgraded.showsInPanel("grok-bot", detected: false))
    }

    @Test @MainActor func panelUsesLastDetectionUntilEachSourceIsRead() {
        let name = "UsoTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        UsagePreferences(detectedProviders: ["claude", "cursor"]).save(to: defaults)
        let store = UsageStore(defaults: defaults)
        store.providers = ProviderSnapshot.placeholders
        #expect(store.visibleProviders.map(\.id) == ["cursor", "claude"])
        store.providers[2] = .problem(id: "cursor", name: "Cursor", tone: .missing, note: "Signed out.")
        store.providers[0] = .signInRequired(id: "grok", name: "Grok", note: "Run grok login.")
        #expect(store.visibleProviders.map(\.id) == ["grok", "claude"])
    }

    @Test func detectionCountsSessionsThatNeedAttention() {
        let ready = QuotaParsing.grokBot(["usagePercent": 10])
        let offline = ProviderSnapshot.problem(id: "grok", name: "Grok", tone: .failed, note: "Can't reach Grok.")
        let rejected = ProviderSnapshot.signInRequired(id: "openai", name: "Codex", note: "Run codex login.")
        var permission = ProviderSnapshot.problem(id: "claude", name: "Claude", tone: .missing, note: "Allow.")
        permission.connection = .keychainPermission
        let absent = ProviderSnapshot.problem(id: "opencode", name: "OpenCode", tone: .missing, note: "None.")
        #expect([ready, offline, rejected, permission].allSatisfy { $0.isDetected })
        #expect(!absent.isDetected)
        #expect(!ProviderSnapshot.loading(id: "grok", name: "Grok").isDetected)
    }

    @Test func independentDisplayChoicesSurviveRelaunch() {
        let name = "UsoTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("preserved", forKey: "unrelatedPreference")
        let preferences = UsagePreferences(
            hiddenPanelProviders: ["claude"], hiddenMenuProviders: ["grok-bot"], shownPanelProviders: ["opencode"],
            detectedProviders: ["claude", "grok-bot"], animatesPanel: false)
        preferences.save(to: defaults)
        let relaunched = UsagePreferences.load(from: UserDefaults(suiteName: name)!)
        #expect(relaunched == preferences)
        #expect(!relaunched.showsInPanel("claude", detected: true))
        #expect(relaunched.showsInMenu("claude", detected: true))
        #expect(relaunched.showsInPanel("grok-bot", detected: true))
        #expect(!relaunched.showsInMenu("grok-bot", detected: true))
        #expect(relaunched.showsInPanel("opencode", detected: false))
        #expect(!relaunched.animatesPanel)
        #expect(defaults.string(forKey: "unrelatedPreference") == "preserved")
    }

    @Test func showingOneSourceKeepsOtherChoices() {
        let name = "UsoTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var preferences = UsagePreferences(hiddenPanelProviders: ["grok", "opencode"], hiddenMenuProviders: ["claude"])
        preferences.save(to: defaults)
        preferences.setShownInPanel(true, id: "grok")
        preferences.save(to: defaults)
        let relaunched = UsagePreferences.load(from: defaults)
        #expect(relaunched.showsInPanel("grok", detected: false))
        #expect(!relaunched.showsInPanel("opencode", detected: true))
        #expect(!relaunched.showsInMenu("claude", detected: true))
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
