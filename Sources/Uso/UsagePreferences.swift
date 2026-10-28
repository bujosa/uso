import Foundation

/// A source the user switched on or off keeps that choice; every other source appears only once this Mac
/// has a session for it.
struct UsagePreferences: Equatable {
    var hiddenPanelProviders: Set<String> = []
    var hiddenMenuProviders: Set<String> = []
    var shownPanelProviders: Set<String> = []
    var shownMenuProviders: Set<String> = []
    /// Sources found by the last check, so the panel opens with the right rows before the next one finishes.
    var detectedProviders: Set<String> = []
    var animatesPanel = true

    func showsInPanel(_ id: String, detected: Bool) -> Bool {
        !hiddenPanelProviders.contains(id) && (detected || shownPanelProviders.contains(id))
    }

    func showsInMenu(_ id: String, detected: Bool) -> Bool {
        !hiddenMenuProviders.contains(id) && (detected || shownMenuProviders.contains(id))
    }

    mutating func setShownInPanel(_ shown: Bool, id: String) {
        Self.choose(shown, id: id, shown: &shownPanelProviders, hidden: &hiddenPanelProviders)
    }

    mutating func setShownInMenu(_ shown: Bool, id: String) {
        Self.choose(shown, id: id, shown: &shownMenuProviders, hidden: &hiddenMenuProviders)
    }

    mutating func followDetection() {
        hiddenPanelProviders = []
        hiddenMenuProviders = []
        shownPanelProviders = []
        shownMenuProviders = []
    }

    mutating func showAll(_ ids: [String]) {
        followDetection()
        shownPanelProviders = Set(ids)
        shownMenuProviders = Set(ids)
    }

    private static func choose(_ visible: Bool, id: String, shown: inout Set<String>, hidden: inout Set<String>) {
        if visible {
            hidden.remove(id)
            shown.insert(id)
        } else {
            shown.remove(id)
            hidden.insert(id)
        }
    }

    static func load(from defaults: UserDefaults) -> UsagePreferences {
        UsagePreferences(
            hiddenPanelProviders: Set(defaults.stringArray(forKey: "uso.hiddenPanelProviders") ?? []),
            hiddenMenuProviders: Set(defaults.stringArray(forKey: "uso.hiddenMenuProviders") ?? []),
            shownPanelProviders: Set(defaults.stringArray(forKey: "uso.shownPanelProviders") ?? []),
            shownMenuProviders: Set(defaults.stringArray(forKey: "uso.shownMenuProviders") ?? []),
            detectedProviders: Set(defaults.stringArray(forKey: "uso.detectedProviders") ?? []),
            animatesPanel: defaults.object(forKey: "uso.animatesPanel") as? Bool ?? true
        )
    }

    func save(to defaults: UserDefaults) {
        defaults.set(hiddenPanelProviders.sorted(), forKey: "uso.hiddenPanelProviders")
        defaults.set(hiddenMenuProviders.sorted(), forKey: "uso.hiddenMenuProviders")
        defaults.set(shownPanelProviders.sorted(), forKey: "uso.shownPanelProviders")
        defaults.set(shownMenuProviders.sorted(), forKey: "uso.shownMenuProviders")
        defaults.set(detectedProviders.sorted(), forKey: "uso.detectedProviders")
        defaults.set(animatesPanel, forKey: "uso.animatesPanel")
    }
}

struct ProviderAccount: Identifiable {
    var id: String
    var name: String
    var signInHint: String
    var accountURL: URL

    static let all: [ProviderAccount] = [
        ProviderAccount(
            id: "grok", name: "Grok", signInHint: "Sign in with Grok Build, then check again.",
            accountURL: URL(string: "https://grok.com/?_s=billing")!),
        ProviderAccount(
            id: "grok-bot", name: "Grok Bot",
            signInHint: "Open Grok Bot on this Mac, and run cursor-agent login with the same account.",
            accountURL: URL(string: "https://cursor.com/dashboard/spending")!),
        ProviderAccount(
            id: "cursor", name: "Cursor", signInHint: "Run cursor-agent login, or sign in to Cursor, then check again.",
            accountURL: URL(string: "https://cursor.com/dashboard")!),
        ProviderAccount(
            id: "openai", name: "Codex", signInHint: "Sign in with Codex, then check again.",
            accountURL: URL(string: "https://chatgpt.com/settings/usage")!),
        ProviderAccount(
            id: "claude", name: "Claude", signInHint: "Sign in with Claude Code, then check again.",
            accountURL: URL(string: "https://claude.ai/settings/usage")!),
        ProviderAccount(
            id: "gemini", name: "Gemini",
            signInHint: "Run agy, then sign in with the Google account that has Google AI Pro.",
            accountURL: URL(string: "https://one.google.com/")!),
        ProviderAccount(
            id: "opencode", name: "OpenCode",
            signInHint: "Use OpenCode on this Mac to detect local activity or your Go plan.",
            accountURL: URL(string: "https://opencode.ai/auth")!),
    ]
}
