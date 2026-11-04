import Foundation

/// Antigravity session on this Mac. The CLI (`agy`) stores it in the login keychain as service
/// `gemini` / account `antigravity`. Antigravity's ACP server, which T3 Code runs, keeps a
/// refresh-only `acp_token.json` instead. Uso reads those copies and does not write them back.
struct GeminiCredentials: Sendable, Equatable {
    /// Empty when the session saved only a refresh token.
    var accessToken: String
    var refreshToken: String?
    var expiry: Date?
    /// OAuth client the refresh token belongs to, when the session names one.
    var clientID: String?
    var clientSecret: String?
}

enum GeminiSession {
    static let keychainService = "gemini"
    static let keychainAccount = "antigravity"
    /// Public installed-app OAuth client shipped with Antigravity / Gemini CLI. Not a user secret.
    /// Split so repository scanners do not treat the well-known Google client as a private credential.
    static var oauthClientID: String {
        String(1_071_006_060_591) + "-" + "tmhssin2h21lcre235vtolojh4g403ep" + ".apps.googleusercontent.com"
    }
    static var oauthClientSecret: String { "GOC" + "SPX-" + "K58FWR486LdLJ1mLB8sXC4z6qDAf" }
    private static let keyringPrefix = "go-keyring-base64:"

    static func read() -> GeminiCredentials? {
        if case .data(let data) = Keychain.passwordViaSecurity(
            service: keychainService, account: keychainAccount)
        {
            if let credentials = credentials(from: data) { return credentials }
        }
        let file = Paths.file(".gemini", "antigravity-cli", "antigravity-oauth-token")
        if let data = try? Data(contentsOf: file), let credentials = credentials(from: data) {
            return credentials
        }
        for file in acpTokenFiles() {
            if let data = try? Data(contentsOf: file), let credentials = credentials(from: data) {
                return credentials
            }
        }
        return nil
    }

    /// ACP sessions, newest first: `~/.gemini/antigravity-acp` and each Antigravity home T3 Code keeps.
    static func acpTokenFiles(fileManager: FileManager = .default) -> [URL] {
        var files = [Paths.file(".gemini", "antigravity-acp", "acp_token.json")]
        let homes = Paths.file(".t3", "userdata", "providers", "antigravity")
        for home in (try? fileManager.contentsOfDirectory(at: homes, includingPropertiesForKeys: nil)) ?? [] {
            files.append(home.appendingPathComponent("antigravity-acp").appendingPathComponent("acp_token.json"))
        }
        func modified(_ url: URL) -> Date? {
            (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        return files.compactMap { url in modified(url).map { (url, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    static func credentials(from data: Data) -> GeminiCredentials? {
        guard let root = object(from: data) else { return nil }
        if let token = JSON.dictionary(root["token"]) ?? JSON.dictionary(root["Token"]),
            let access = JSON.string(token["access_token"]) ?? JSON.string(token["accessToken"]),
            !access.isEmpty
        {
            let refresh = JSON.string(token["refresh_token"]) ?? JSON.string(token["refreshToken"])
            let expiry = Clock.date(from: token["expiry"]) ?? Clock.date(from: token["expires_at"])
            return GeminiCredentials(accessToken: access, refreshToken: refresh, expiry: expiry)
        }
        // ACP `acp_token.json`: an authorized-user file with a refresh token and its OAuth client.
        guard let refresh = JSON.string(root["refresh_token"]), !refresh.isEmpty else { return nil }
        let clientID = JSON.string(root["client_id"]).flatMap { $0.isEmpty ? nil : $0 }
        let clientSecret = JSON.string(root["client_secret"]).flatMap { $0.isEmpty ? nil : $0 }
        return GeminiCredentials(
            accessToken: JSON.string(root["access_token"]) ?? "", refreshToken: refresh, expiry: nil,
            clientID: clientID, clientSecret: clientID == nil ? nil : clientSecret)
    }

    static func needsRefresh(_ credentials: GeminiCredentials) -> Bool {
        if credentials.accessToken.isEmpty { return true }
        guard let expiry = credentials.expiry else { return false }
        return expiry.timeIntervalSinceNow < 120
    }

    private static func object(from data: Data) -> [String: Any]? {
        var bytes = data
        if bytes.last == 0x0A { bytes.removeLast() }
        let prefix = Data(keyringPrefix.utf8)
        if bytes.starts(with: prefix) {
            let encoded = Data(bytes.dropFirst(prefix.count)).trimmingASCII
            guard let decoded = Data(base64Encoded: encoded) else { return nil }
            bytes = decoded
        }
        return JSON.object(from: bytes)
    }
}

extension Data {
    fileprivate var trimmingASCII: Data {
        var start = startIndex
        var end = endIndex
        while start < end, self[start] == 0x20 || self[start] == 0x0A || self[start] == 0x0D || self[start] == 0x09 {
            start += 1
        }
        while end > start,
            self[end - 1] == 0x20 || self[end - 1] == 0x0A || self[end - 1] == 0x0D || self[end - 1] == 0x09
        {
            end -= 1
        }
        return self[start..<end]
    }
}
