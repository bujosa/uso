import Foundation

struct ClaudeCredentials: Sendable {
    var accessToken: String
    var plan: String
}

enum ClaudeCredentialRead: Sendable {
    case available(ClaudeCredentials)
    case needsPermission
    case missing
}

enum ClaudeSession {
    private static let backoffKey = "claudeKeychainBackoffUntil"

    static func read(prompt: Bool) -> ClaudeCredentialRead {
        // macOS Claude Code's keychain is authoritative. Never read Uso's old copy.
        if let credentials = credentials(from: Keychain.passwordViaSecurity(service: "Claude Code-credentials")) {
            UserDefaults.standard.removeObject(forKey: backoffKey)
            return .available(credentials)
        }
        if !prompt, Date().timeIntervalSince1970 < UserDefaults.standard.double(forKey: backoffKey) {
            return fileCredentials().map(ClaudeCredentialRead.available) ?? .needsPermission
        }
        switch Keychain.password(service: "Claude Code-credentials", prompt: prompt) {
        case .data(let data):
            if let credentials = credentials(from: .data(data)) {
                UserDefaults.standard.removeObject(forKey: backoffKey)
                return .available(credentials)
            }
            return .missing
        case .needsPermission:
            if !prompt {
                UserDefaults.standard.set(
                    Date().addingTimeInterval(6 * 60 * 60).timeIntervalSince1970, forKey: backoffKey)
            }
            return fileCredentials().map(ClaudeCredentialRead.available) ?? .needsPermission
        case .missing:
            return fileCredentials().map(ClaudeCredentialRead.available) ?? .missing
        }
    }

    private static func credentials(from read: KeychainRead) -> ClaudeCredentials? {
        guard case .data(let data) = read, let root = JSON.object(from: data),
            let oauth = JSON.dictionary(root["claudeAiOauth"]),
            let token = JSON.string(oauth["accessToken"]), !token.isEmpty,
            let expires = Clock.date(from: oauth["expiresAt"]), expires > Date()
        else { return nil }
        let subscription = JSON.string(oauth["subscriptionType"]) ?? ""
        return ClaudeCredentials(
            accessToken: token,
            plan: Format.claudePlan(subscription: subscription, tier: JSON.string(oauth["rateLimitTier"])))
    }

    private static func fileCredentials() -> ClaudeCredentials? {
        let directory =
            ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? Paths.file(".claude")
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(".credentials.json")) else {
            return nil
        }
        return credentials(from: .data(data))
    }
}

actor ClaudeUsageClient {
    typealias ReadCredentials = @Sendable (Bool) -> ClaudeCredentialRead
    typealias SendUsage = @Sendable (String) async -> HTTP.Response?

    private let readCredentials: ReadCredentials
    private let sendUsage: SendUsage
    private let now: @Sendable () -> Date
    private var retryAt: Date?

    init(
        readCredentials: @escaping ReadCredentials = { ClaudeSession.read(prompt: $0) },
        sendUsage: @escaping SendUsage = { token in
            await HTTP.sendResponse(
                URL(string: "https://api.anthropic.com/api/oauth/usage")!,
                headers: [
                    "Accept": "application/json", "Authorization": "Bearer \(token)",
                    "anthropic-beta": "oauth-2025-04-20", "User-Agent": "Uso/1.1.0",
                    "Cache-Control": "no-cache",
                ])
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.readCredentials = readCredentials
        self.sendUsage = sendUsage
        self.now = now
    }

    func load(prompt: Bool = false) async -> ProviderSnapshot {
        if let retryAt, retryAt > now() {
            return problem(.failed, "Claude asked to wait. Retry \(Format.reset(retryAt)).")
        }
        let reading = readCredentials(prompt)
        guard case .available(var credentials) = reading else {
            if case .needsPermission = reading {
                return problem(.missing, "Claude Code is signed in. Tap and choose Always Allow.")
            }
            return problem(.missing, "No current Claude Code session. Sign in with the Claude Code CLI.")
        }
        var response = await sendUsage(credentials.accessToken)
        if response?.status == 401,
            case .available(let newer) = readCredentials(prompt), newer.accessToken != credentials.accessToken
        {
            credentials = newer
            response = await sendUsage(newer.accessToken)
        }
        guard let response else { return problem(.failed, "Can't reach Claude.") }
        if response.status == 429 {
            retryAt = Self.retryDate(response.retryAfter, now: now())
            return problem(.failed, "Claude asked to wait. Retry \(Format.reset(retryAt)).")
        }
        if response.status == 401 || response.status == 403 {
            return problem(.missing, "Claude session rejected. Sign in again with the Claude Code CLI.")
        }
        guard response.status == 200, let body = JSON.object(from: response.data) else {
            return problem(.failed, "Couldn't read Claude usage (HTTP \(response.status)).")
        }
        return QuotaParsing.claude(body, plan: credentials.plan)
    }

    static func retryDate(_ header: String?, now: Date) -> Date {
        if let header, let seconds = Double(header), seconds.isFinite, seconds > 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        if let header, let date = formatter.date(from: header), date > now { return date }
        return now.addingTimeInterval(180)
    }

    private func problem(_ tone: ProviderTone, _ note: String) -> ProviderSnapshot {
        .problem(id: "claude", name: "Claude", tone: tone, note: note)
    }
}
