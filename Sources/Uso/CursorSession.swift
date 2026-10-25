import Foundation

/// Cursor's sign-in on this Mac, shared by the Cursor and Grok Bot rows.
///
/// Cursor 3.27 seals the desktop token with Electron safe storage. Only Cursor.app may open that key, so Uso
/// never tries. The Cursor CLI keeps its own token in the login keychain, readable through `/usr/bin/security`
/// without a prompt, and that is the fallback.
struct CursorSession: Sendable {
    /// Bearer tokens to try, best first.
    var tokens: [String]
    /// The desktop app is signed in, but its token is sealed.
    var isSealed: Bool
    var membership: String

    static let sealedPrefix = "cursor-safe-storage:"

    static func read() -> CursorSession {
        let values = desktopValues()
        return resolve(
            desktop: values["cursorAuth/accessToken"], membership: values["cursorAuth/stripeMembershipType"] ?? "",
            cli: cliToken)
    }

    static func resolve(desktop: String?, membership: String, cli: () -> String?) -> CursorSession {
        let stored = desktop?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sealed = stored.hasPrefix(sealedPrefix)
        var tokens = stored.isEmpty || sealed ? [] : [stored]
        if let cli = cli()?.trimmingCharacters(in: .whitespacesAndNewlines), !cli.isEmpty, !tokens.contains(cli) {
            tokens.append(cli)
        }
        return CursorSession(tokens: tokens, isSealed: sealed, membership: membership)
    }

    private static func desktopValues() -> [String: String] {
        let database = Paths.file("Library", "Application Support", "Cursor", "User", "globalStorage", "state.vscdb")
        guard FileManager.default.fileExists(atPath: database.path),
            let rows = SQLite.query(
                path: database.path,
                sql:
                    "SELECT key, value FROM ItemTable WHERE key IN ('cursorAuth/accessToken', 'cursorAuth/stripeMembershipType')"
            )
        else { return [:] }
        return Dictionary(rows.map { ($0["key"] ?? "", $0["value"] ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    private static func cliToken() -> String? {
        guard case .data(let data) = Keychain.passwordViaSecurity(service: "cursor-access-token") else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
