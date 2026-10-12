import CryptoKit
import Foundation

enum MuseCredentialRead: Sendable {
    case oauth(String)
    case apiKey
    case needsPermission
    case missing
}

enum MuseSession {
    private struct AuthFile: Decodable {
        struct Providers: Decodable {
            struct Entry: Decodable {
                var mechanism: String?
                var storage: String?
                var accessToken: String?
                enum CodingKeys: String, CodingKey {
                    case mechanism, storage
                    case accessToken = "access_token"
                }
            }
            var meta: Entry?
        }
        var providers: Providers?
    }

    private struct Secret: Decodable {
        var accessToken: String?
        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }

    static func read(prompt: Bool) -> MuseCredentialRead {
        let environment = ProcessInfo.processInfo.environment
        if let key = environment["META_API_KEY"], !key.isEmpty { return .apiKey }
        let file: URL
        if let path = environment["MUSE_AUTH_PATH"], !path.isEmpty {
            file = URL(fileURLWithPath: path)
        } else {
            let directory = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? Paths.file(".config")
            file = directory.appendingPathComponent("muse/auth.json")
        }
        return resolve(metadata: try? Data(contentsOf: file)) {
            Keychain.password(service: "ai.meta.dev.credentials", account: "meta", prompt: prompt)
        }
    }

    static func resolve(metadata: Data?, readSecret: () -> KeychainRead) -> MuseCredentialRead {
        guard let metadata,
            let entry = try? JSONDecoder().decode(AuthFile.self, from: metadata).providers?.meta
        else { return .missing }
        if entry.mechanism == "api_key" { return .apiKey }
        guard entry.mechanism == "oauth" else { return .missing }
        if let token = entry.accessToken, !token.isEmpty { return credential(token) }
        guard entry.storage == "keychain" else { return .missing }
        switch readSecret() {
        case .data(let data):
            guard let token = try? JSONDecoder().decode(Secret.self, from: data).accessToken else { return .missing }
            return credential(token)
        case .needsPermission: return .needsPermission
        case .missing: return .missing
        }
    }

    static func credential(_ token: String) -> MuseCredentialRead {
        // Inference keys cannot read the account's subscription endpoint.
        guard token.hasPrefix("dca:"), token.count > 4 else { return .missing }
        return .oauth(token)
    }
}

struct MuseQuotaResponse: Decodable, Sendable {
    struct Usage: Decodable, Sendable {
        struct Window: Decodable, Sendable {
            var usedPercent: Double
            var resetsAt: Double?
            var windowDurationMins: Double?
            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case resetsAt = "resets_at"
                case windowDurationMins = "window_duration_mins"
            }
        }
        var window: Window
        var weekly: Window
    }
    var isSubsActive: Bool
    var subsTierName: String?
    var subsUsage: Usage?
    var requirePayment: Bool?
    enum CodingKeys: String, CodingKey {
        case isSubsActive = "is_subs_active"
        case subsTierName = "subs_tier_name"
        case subsUsage = "subs_usage"
        case requirePayment = "require_payment"
    }

    // Unknown response fields, including the returned inference key and account
    // identity, are skipped by Decodable and never retained in a snapshot.
    func snapshot(now: Date) -> ProviderSnapshot {
        let name = "Muse Code"
        let plan = subsTierName?.trimmingCharacters(in: .whitespacesAndNewlines)
        var snapshot = ProviderSnapshot(
            id: "muse", name: name,
            plan: plan.flatMap { $0.isEmpty ? nil : $0 }
                ?? (isSubsActive ? "Muse Code subscription" : "Pay as you go"),
            headline: "Quota unavailable", bars: [], chips: [], lines: [], note: nil,
            warning: nil, tone: .ready, readAt: now
        )
        if requirePayment == true, !isSubsActive {
            snapshot.plan = "Billing setup needed"
            snapshot.headline = "Billing needed"
            snapshot.note =
                "Meta reports no active Muse Code subscription. Complete billing or choose a plan at dev.meta.ai."
            return snapshot
        }
        guard isSubsActive else {
            snapshot.headline = "Pay as you go"
            snapshot.note =
                "No active Muse Code subscription. API token spending is separate from a subscription quota."
            return snapshot
        }
        guard let usage = subsUsage else {
            snapshot.note =
                "Meta verified your plan but did not include its quota in this response. Check /usage in Muse CLI."
            return snapshot
        }
        guard usage.window.usedPercent.isFinite, usage.window.usedPercent >= 0,
            usage.weekly.usedPercent.isFinite, usage.weekly.usedPercent >= 0,
            let minutes = usage.window.windowDurationMins, minutes.isFinite, minutes > 0,
            minutes.rounded() == minutes, minutes < Double(Int.max)
        else {
            return .problem(id: "muse", name: name, tone: .failed, note: "Muse returned invalid usage windows.")
        }
        let count = Int(minutes)
        let label = count % 60 == 0 ? "\(count / 60) hours" : "\(count) min"
        for (id, label, window) in [("session", label, usage.window), ("week", "Week", usage.weekly)] {
            let reset = window.resetsAt.flatMap { seconds -> Date? in
                guard seconds.isFinite, seconds > 0, seconds < 4_102_444_800 else { return nil }
                return Date(timeIntervalSince1970: seconds)
            }
            // A passed reset is not evidence of a fresh zero-usage window.
            if let reset, reset <= now { continue }
            snapshot.bars.append(
                MeterBar(id: id, label: label, usedPercent: window.usedPercent, detail: Format.reset(reset)))
        }
        if let first = snapshot.bars.first {
            snapshot.headline = "\(Format.percent(max(0, 100 - first.usedPercent))) left"
            snapshot.note = "Muse Code subscription usage. Separate from Meta Model API token spending."
        } else {
            snapshot.note = "Meta returned expired usage windows. Check /usage in Muse CLI and refresh later."
        }
        return snapshot
    }
}

actor MuseUsageClient {
    typealias ReadCredentials = @Sendable (Bool) -> MuseCredentialRead
    typealias SendUsage = @Sendable (String) async -> HTTP.Response?

    private let readCredentials: ReadCredentials
    private let sendUsage: SendUsage
    private let now: @Sendable () -> Date
    private var credentialDigest: Data?
    private var nextRequestAt: Date?
    private var lastResult: ProviderSnapshot?
    private var lastPayload: MuseQuotaResponse?

    init(
        readCredentials: @escaping ReadCredentials = { MuseSession.read(prompt: $0) },
        sendUsage: @escaping SendUsage = { token in
            await HTTP.sendResponse(
                URL(string: "https://api.meta.ai/muse-code/key")!, method: "POST",
                headers: [
                    "Authorization": "Bearer \(token)", "Accept": "application/json",
                    "Content-Type": "application/json", "x-api-version": "1.0.0", "User-Agent": "Uso/1.1.0",
                ],
                body: Data("{\"onboard\":false}".utf8))
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.readCredentials = readCredentials
        self.sendUsage = sendUsage
        self.now = now
    }

    func load(prompt: Bool = false) async -> ProviderSnapshot {
        let reading = readCredentials(prompt)
        guard case .oauth(var token) = reading else {
            credentialDigest = nil
            lastResult = nil
            lastPayload = nil
            nextRequestAt = nil
            switch reading {
            case .apiKey:
                return ProviderSnapshot(
                    id: "muse", name: "Muse Code", plan: "API key · pay as you go", headline: "Pay as you go",
                    bars: [], chips: [], lines: [],
                    note:
                        "An API key is selected in Muse CLI. Sign in with muse login to check a Muse Code subscription.",
                    warning: nil, tone: .ready, readAt: now())
            case .needsPermission:
                return problem(.missing, "Muse CLI is signed in. Allow access to read its subscription.")
            default: return problem(.missing, "No Muse CLI account session. Run muse login, then check again.")
            }
        }
        var digest = Data(SHA256.hash(data: Data(token.utf8)))
        if credentialDigest == digest, let nextRequestAt, nextRequestAt > now() {
            if let lastPayload, let lastResult {
                var cached = lastPayload.snapshot(now: now())
                cached.readAt = lastResult.readAt
                return cached
            }
            return lastResult ?? problem(.failed, "Muse usage check is already in progress.")
        }
        credentialDigest = digest
        lastResult = nil
        lastPayload = nil
        nextRequestAt = now().addingTimeInterval(300)
        var response = await sendUsage(token)
        if response?.status == 401, case .oauth(let newer) = readCredentials(prompt), newer != token {
            token = newer
            digest = Data(SHA256.hash(data: Data(newer.utf8)))
            credentialDigest = digest
            response = await sendUsage(newer)
        }
        let result: ProviderSnapshot
        if let response {
            if response.status == 401 || response.status == 403 {
                result = problem(.missing, "Muse session rejected. Sign in again with muse login.")
            } else if response.status == 429 {
                let retry = ClaudeUsageClient.retryDate(response.retryAfter, now: now())
                nextRequestAt = max(nextRequestAt ?? retry, retry)
                result = problem(.failed, "Muse asked to wait. Retry \(Format.reset(nextRequestAt)).")
            } else if response.status == 200 {
                if let body = try? JSONDecoder().decode(MuseQuotaResponse.self, from: response.data) {
                    result = body.snapshot(now: now())
                    if result.tone == .ready { lastPayload = body }
                } else {
                    result = problem(.failed, "Muse returned an unreadable quota response.")
                }
            } else {
                result = problem(.failed, "Couldn't read Muse usage (HTTP \(response.status)).")
            }
        } else {
            result = problem(.failed, "Can't reach Muse.")
        }
        lastResult = result
        return result
    }

    private func problem(_ tone: ProviderTone, _ note: String) -> ProviderSnapshot {
        .problem(id: "muse", name: "Muse Code", tone: tone, note: note)
    }
}
