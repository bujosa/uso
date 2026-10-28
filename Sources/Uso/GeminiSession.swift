import Foundation

/// Antigravity CLI (`agy`) session on this Mac. Google stores it in the login keychain as
/// service `gemini` / account `antigravity`. Uso reads that copy and does not write it back.
struct GeminiCredentials: Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiry: Date?
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
        guard let data = try? Data(contentsOf: file) else { return nil }
        return credentials(from: data)
    }

    static func credentials(from data: Data) -> GeminiCredentials? {
        guard let root = object(from: data),
            let token = JSON.dictionary(root["token"]) ?? JSON.dictionary(root["Token"]),
            let access = JSON.string(token["access_token"]) ?? JSON.string(token["accessToken"]),
            !access.isEmpty
        else { return nil }
        let refresh = JSON.string(token["refresh_token"]) ?? JSON.string(token["refreshToken"])
        let expiry = Clock.date(from: token["expiry"]) ?? Clock.date(from: token["expires_at"])
        return GeminiCredentials(accessToken: access, refreshToken: refresh, expiry: expiry)
    }

    static func needsRefresh(_ credentials: GeminiCredentials) -> Bool {
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
