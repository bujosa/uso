import Foundation

struct ClaudeCredentials: Sendable {
    var accessToken: String
    var plan: String
}

enum ClaudeCredentialRead: Sendable {
    case available(ClaudeCredentials)
    /// Claude Code is signed in, but its access token ran out. Only Claude Code renews it, the next time it runs.
    case expired
    case needsPermission
    case missing
    case unavailable
}

/// Where Claude Code's session can be read. Tests swap these for fixtures.
struct ClaudeCredentialSources: Sendable {
    var viaSecurity: @Sendable () -> KeychainRead
    var keychain: @Sendable (_ prompt: Bool) -> KeychainRead
    var file: @Sendable () -> Data?

    static let live = ClaudeCredentialSources(
        viaSecurity: { Keychain.passwordViaSecurity(service: "Claude Code-credentials") },
        keychain: { Keychain.password(service: "Claude Code-credentials", prompt: $0) },
        file: {
            let directory =
                ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
                ?? Paths.file(".claude")
            return try? Data(contentsOf: directory.appendingPathComponent(".credentials.json"))
        })
}

enum ClaudeSession {
    private static let backoffKey = "claudeKeychainBackoffUntil"

    private enum Parsed {
        case valid(ClaudeCredentials)
        case expired
        case unreadable
    }

    static func read(prompt: Bool, from sources: ClaudeCredentialSources = .live) -> ClaudeCredentialRead {
        // macOS Claude Code's keychain is authoritative. Never read Uso's old copy.
        switch parse(sources.viaSecurity()) {
        case .valid(let credentials):
            UserDefaults.standard.removeObject(forKey: backoffKey)
            return .available(credentials)
        case .expired:
            // Asking for keychain access can't help: Uso would read the same expired token, and Claude Code's
            // next renewal rewrites the item and drops any Always Allow given to Uso.
            return fileCredentials(sources).map(ClaudeCredentialRead.available) ?? .expired
        case .unreadable:
            break
        }
        if !prompt, Date().timeIntervalSince1970 < UserDefaults.standard.double(forKey: backoffKey) {
            return fileCredentials(sources).map(ClaudeCredentialRead.available) ?? .needsPermission
        }
        switch sources.keychain(prompt) {
        case .data(let data):
            switch parse(.data(data)) {
            case .valid(let credentials):
                UserDefaults.standard.removeObject(forKey: backoffKey)
                return .available(credentials)
            case .expired:
                return fileCredentials(sources).map(ClaudeCredentialRead.available) ?? .expired
            case .unreadable:
                return .missing
            }
        case .needsPermission:
            if !prompt {
                UserDefaults.standard.set(
                    Date().addingTimeInterval(6 * 60 * 60).timeIntervalSince1970, forKey: backoffKey)
            }
            return fileCredentials(sources).map(ClaudeCredentialRead.available) ?? .needsPermission
        case .missing:
            return fileCredentials(sources).map(ClaudeCredentialRead.available) ?? .missing
        case .unavailable:
            return fileCredentials(sources).map(ClaudeCredentialRead.available) ?? .unavailable
        }
    }

    private static func parse(_ read: KeychainRead) -> Parsed {
        guard case .data(let data) = read, let root = JSON.object(from: data),
            let oauth = JSON.dictionary(root["claudeAiOauth"]),
            let token = JSON.string(oauth["accessToken"]), !token.isEmpty
        else { return .unreadable }
        guard let expires = Clock.date(from: oauth["expiresAt"]) else { return .unreadable }
        guard expires > Date() else { return .expired }
        let subscription = JSON.string(oauth["subscriptionType"]) ?? ""
        return .valid(
            ClaudeCredentials(
                accessToken: token,
                plan: Format.claudePlan(subscription: subscription, tier: JSON.string(oauth["rateLimitTier"]))))
    }

    private static func fileCredentials(_ sources: ClaudeCredentialSources) -> ClaudeCredentials? {
        guard let data = sources.file(), case .valid(let credentials) = parse(.data(data)) else { return nil }
        return credentials
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
                    "anthropic-beta": "oauth-2025-04-20", "User-Agent": AppVersion.userAgent,
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
            if case .unavailable = reading {
                var result = problem(
                    .failed, "The Claude Code session could not be read in time. Try checking again later.")
                result.connection = .unverified
                return result
            }
            if case .expired = reading {
                // Nothing to fix: Claude Code renews the session the next time it runs. A failed reading keeps
                // the last numbers on the row.
                return problem(.failed, "Claude Code is idle. Usage updates the next time you use it.")
            }
            if case .needsPermission = reading {
                var result = problem(.missing, "Claude Code is signed in. Tap and choose Always Allow.")
                result.connection = .keychainPermission
                return result
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
            var result = problem(.missing, "Claude session rejected. Sign in again with the Claude Code CLI.")
            result.connection = .signInRequired
            return result
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
