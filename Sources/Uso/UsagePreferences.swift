import Foundation

struct UsagePreferences: Equatable {
    var hiddenPanelProviders: Set<String> = []
    var hiddenMenuProviders: Set<String> = []
    var animatesPanel = true

    func showsInPanel(_ id: String) -> Bool { !hiddenPanelProviders.contains(id) }
    func showsInMenu(_ id: String) -> Bool { !hiddenMenuProviders.contains(id) }

    static func load(from defaults: UserDefaults) -> UsagePreferences {
        UsagePreferences(
            hiddenPanelProviders: Set(defaults.stringArray(forKey: "uso.hiddenPanelProviders") ?? []),
            hiddenMenuProviders: Set(defaults.stringArray(forKey: "uso.hiddenMenuProviders") ?? []),
            animatesPanel: defaults.object(forKey: "uso.animatesPanel") as? Bool ?? true
        )
    }

    func save(to defaults: UserDefaults) {
        defaults.set(hiddenPanelProviders.sorted(), forKey: "uso.hiddenPanelProviders")
        defaults.set(hiddenMenuProviders.sorted(), forKey: "uso.hiddenMenuProviders")
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
            id: "grok-bot", name: "Grok Bot", signInHint: "Sign in to Cursor with the account you use in Grok Bot.",
            accountURL: URL(string: "https://cursor.com/dashboard/spending")!),
        ProviderAccount(
            id: "cursor", name: "Cursor", signInHint: "Open Cursor and sign in, then check again.",
            accountURL: URL(string: "https://cursor.com/dashboard")!),
        ProviderAccount(
            id: "openai", name: "Codex", signInHint: "Sign in with Codex, then check again.",
            accountURL: URL(string: "https://chatgpt.com/settings/usage")!),
        ProviderAccount(
            id: "claude", name: "Claude", signInHint: "Sign in with Claude Code, then check again.",
            accountURL: URL(string: "https://claude.ai/settings/usage")!),
        ProviderAccount(
            id: "opencode", name: "OpenCode",
            signInHint: "Use OpenCode on this Mac to detect local activity or your Go plan.",
            accountURL: URL(string: "https://opencode.ai/auth")!),
    ]
}
