import Foundation

struct UsageService: Sendable {
    private let claudeClient = ClaudeUsageClient()

    func load() async -> [ProviderSnapshot] {
        var snapshots: [ProviderSnapshot] = []
        for await snapshot in loadIncremental() {
            snapshots.append(snapshot)
        }
        return snapshots.sorted { Self.order[$0.id, default: 9] < Self.order[$1.id, default: 9] }
    }

    func loadIncremental() -> AsyncStream<ProviderSnapshot> {
        AsyncStream { continuation in
            Task {
                await withTaskGroup(of: ProviderSnapshot.self) { group in
                    group.addTask { await self.grok() }
                    group.addTask { await self.grokBot() }
                    group.addTask { await self.cursor() }
                    group.addTask { await self.openai() }
                    group.addTask { await self.claude() }
                    group.addTask { await self.opencode() }
                    for await snapshot in group {
                        continuation.yield(snapshot)
                    }
                }
                continuation.finish()
            }
        }
    }

    private static let order = ["grok": 0, "grok-bot": 1, "cursor": 2, "openai": 3, "claude": 4, "opencode": 5]

    // MARK: Grok

    private func grok() async -> ProviderSnapshot {
        let authURL = Paths.file(".grok", "auth.json")
        guard let raw = try? Data(contentsOf: authURL),
              var root = JSON.object(from: raw),
              let storageKey = root.keys.first,
              var entry = JSON.dictionary(JSON.value(root, key: storageKey))
        else {
            return .problem(id: "grok", name: "Grok", tone: .missing, note: "No session. Run grok login.")
        }

        if let expiry = Clock.date(from: JSON.value(entry, key: "expires_at")), expiry.timeIntervalSinceNow < 120 {
            if let refreshed = await refreshGrok(entry) {
                entry = refreshed
                root[storageKey] = refreshed
                if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: authURL, options: .atomic)
                }
            }
        }

        guard let token = JSON.string(JSON.value(entry, key: "key")), !token.isEmpty else {
            return .problem(id: "grok", name: "Grok", tone: .missing, note: "Grok has no token. Run grok login.")
        }
        let userID = JSON.string(JSON.value(entry, key: "user_id")) ?? ""
        let headers = grokHeaders(token: token, userID: userID)

        async let billingCall = HTTP.send(
            URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!,
            headers: headers
        )
        async let settingsCall = HTTP.send(
            URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!,
            headers: headers
        )
        guard let (status, data) = await billingCall else {
            return .problem(id: "grok", name: "Grok", tone: .failed, note: "Can't reach Grok.")
        }
        guard status == 200, let body = JSON.object(from: data), let config = JSON.dictionary(JSON.value(body, key: "config")) else {
            let tone: ProviderTone = (status == 401 || status == 403) ? .missing : .failed
            let note = tone == .missing ? "Grok session expired. Run grok login." : HTTP.message(status: status, data: data)
            return .problem(id: "grok", name: "Grok", tone: tone, note: note)
        }

        let used = JSON.double(JSON.value(config, key: "creditUsagePercent")) ?? 0
        let period = JSON.dictionary(JSON.value(config, key: "currentPeriod"))
        let resets = Clock.date(from: JSON.value(period ?? [:], key: "end"))
            ?? Clock.date(from: JSON.value(config, key: "billingPeriodEnd"))
        let window = windowLabel(JSON.string(JSON.value(period ?? [:], key: "type")))
        var bars = [
            MeterBar(id: "credits", label: window, usedPercent: used, detail: Format.reset(resets)),
        ]
        for product in JSON.array(JSON.value(config, key: "productUsage")) {
            guard let usedProduct = JSON.double(JSON.value(product, key: "usagePercent")),
                  let name = JSON.string(JSON.value(product, key: "product"))
            else { continue }
            bars.append(MeterBar(id: name, label: grokProduct(name), usedPercent: usedProduct, detail: ""))
        }

        var plan = "Grok"
        if let settings = await settingsCall, settings.0 == 200,
           let settingsBody = JSON.object(from: settings.1),
           let tier = JSON.string(JSON.value(settingsBody, key: "subscription_tier_display")),
           !tier.isEmpty {
            plan = tier
        }

        var lines: [String] = []
        if let prepaid = JSON.double(JSON.value(JSON.value(config, key: "prepaidBalance"), key: "val")), prepaid > 0 {
            lines.append("Prepaid \(Format.money(cents: prepaid))")
        }
        if let onDemand = JSON.double(JSON.value(JSON.value(config, key: "onDemandUsed"), key: "val")), onDemand > 0 {
            lines.append("On demand \(Format.money(cents: onDemand))")
        }

        return ProviderSnapshot(
            id: "grok",
            name: "Grok",
            plan: plan,
            headline: "\(Format.percent(max(0, 100 - used))) left",
            bars: bars,
            chips: [],
            lines: lines,
            note: nil,
            warning: nil,
            tone: .ready
        )
    }

    private func refreshGrok(_ entry: [String: Any]) async -> [String: Any]? {
        guard let refresh = JSON.string(JSON.value(entry, key: "refresh_token")),
              let clientID = JSON.string(JSON.value(entry, key: "oidc_client_id")),
              let url = URL(string: "https://auth.x.ai/oauth2/token")
        else { return nil }
        let body = formEncode([
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": clientID,
        ])
        guard let (status, data) = await HTTP.send(
            url,
            method: "POST",
            headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"],
            body: body
        ), status == 200, let payload = JSON.object(from: data),
              let access = JSON.string(JSON.value(payload, key: "access_token"))
        else { return nil }
        var updated = entry
        updated["key"] = access
        if let nextRefresh = JSON.string(JSON.value(payload, key: "refresh_token")) {
            updated["refresh_token"] = nextRefresh
        }
        let expiresIn = JSON.double(JSON.value(payload, key: "expires_in")) ?? 3600
        updated["expires_at"] = Clock.isoString(Date().addingTimeInterval(expiresIn))
        return updated
    }

    private func grokHeaders(token: String, userID: String) -> [String: String] {
        var headers = [
            "Accept": "application/json",
            "Authorization": "Bearer \(token)",
            "X-XAI-Token-Auth": "xai-grok-cli",
        ]
        if !userID.isEmpty { headers["x-userid"] = userID }
        return headers
    }

    private func grokProduct(_ name: String) -> String {
        switch name {
        case "GrokBuild": return "Build"
        case "GrokImagine": return "Imagine"
        case "GrokChat": return "Chat"
        case "GrokVoice": return "Voice"
        default: return name
        }
    }

    private func windowLabel(_ raw: String?) -> String {
        switch raw {
        case "USAGE_PERIOD_TYPE_WEEKLY": return "Week"
        case "USAGE_PERIOD_TYPE_MONTHLY": return "Month"
        case "USAGE_PERIOD_TYPE_DAILY": return "Day"
        default: return "Period"
        }
    }

    // MARK: Grok Bot

    private func grokBot() async -> ProviderSnapshot {
        let database = Paths.file("Library", "Application Support", "Cursor", "User", "globalStorage", "state.vscdb")
        guard let rows = SQLite.query(path: database.path, sql: "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'"),
              let token = rows.first?["value"], !token.isEmpty else {
            return .problem(id: "grok-bot", name: "Grok Bot", tone: .missing,
                            note: "Open Cursor and sign in with the account you use in Grok Bot.")
        }
        guard let response = await HTTP.send(
            URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!,
            method: "POST", headers: [
                "Authorization": "Bearer \(token)", "Content-Type": "application/json",
                "Connect-Protocol-Version": "1", "x-cursor-client-type": "grok-bot", "x-ghost-mode": "true",
            ], body: Data("{}".utf8)
        ) else {
            return .problem(id: "grok-bot", name: "Grok Bot", tone: .failed, note: "Can't reach Grok Bot.")
        }
        guard response.0 == 200, let body = JSON.object(from: response.1) else {
            let tone: ProviderTone = response.0 == 401 || response.0 == 403 ? .missing : .failed
            return .problem(id: "grok-bot", name: "Grok Bot", tone: tone,
                            note: tone == .missing ? "Cursor session rejected. Sign in again in Cursor." : "Couldn't read Grok Bot usage (HTTP \(response.0)).")
        }
        return QuotaParsing.grokBot(body)
    }

    // MARK: Cursor

    private func cursor() async -> ProviderSnapshot {
        let database = Paths.file("Library", "Application Support", "Cursor", "User", "globalStorage", "state.vscdb")
        guard FileManager.default.fileExists(atPath: database.path),
              let rows = SQLite.query(
                path: database.path,
                sql: "SELECT key, value FROM ItemTable WHERE key IN ('cursorAuth/accessToken', 'cursorAuth/stripeMembershipType')"
              )
        else {
            return .problem(id: "cursor", name: "Cursor", tone: .missing, note: "No Cursor session. Open Cursor and sign in.")
        }
        let values = Dictionary(uniqueKeysWithValues: rows.map { ($0["key"] ?? "", $0["value"] ?? "") })
        let token = values["cursorAuth/accessToken"] ?? ""
        guard !token.isEmpty else {
            return .problem(id: "cursor", name: "Cursor", tone: .missing, note: "Cursor is not signed in on this Mac.")
        }
        let headers = [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
            "Connect-Protocol-Version": "1",
        ]
        let periodURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
        let planURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo")!
        let eventsURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetAggregatedUsageEvents")!
        async let periodCall = HTTP.send(periodURL, method: "POST", headers: headers, body: Data("{}".utf8))
        async let planCall = HTTP.send(planURL, method: "POST", headers: headers, body: Data("{}".utf8))
        async let eventsCall = HTTP.send(eventsURL, method: "POST", headers: headers, body: Data("{}".utf8))

        guard let period = await periodCall else {
            return .problem(id: "cursor", name: "Cursor", tone: .failed, note: "Can't reach Cursor.")
        }
        guard period.0 == 200, let body = JSON.object(from: period.1) else {
            let tone: ProviderTone = (period.0 == 401 || period.0 == 403) ? .missing : .failed
            let note = tone == .missing ? "Cursor session expired. Sign in again in the app." : HTTP.message(status: period.0, data: period.1)
            return .problem(id: "cursor", name: "Cursor", tone: tone, note: note)
        }

        let planUsage = JSON.dictionary(JSON.value(body, key: "planUsage")) ?? [:]
        let limit = JSON.double(JSON.value(planUsage, key: "limit")) ?? 0
        let spent = JSON.double(JSON.value(planUsage, key: "includedSpend"))
            ?? JSON.double(JSON.value(planUsage, key: "totalSpend"))
            ?? 0
        let remaining = JSON.double(JSON.value(planUsage, key: "remaining"))
        var bars: [MeterBar] = []
        if let auto = JSON.double(JSON.value(planUsage, key: "autoPercentUsed")) {
            bars.append(MeterBar(id: "auto", label: "Auto", usedPercent: auto, detail: "Other models"))
        }
        if limit > 0 {
            let used = min(100, spent / limit * 100)
            let detail: String
            if let remaining {
                detail = Format.money(cents: remaining)
            } else {
                detail = "\(Format.money(cents: spent)) of \(Format.money(cents: limit))"
            }
            bars.append(MeterBar(id: "included", label: "Included", usedPercent: used, detail: detail))
        }
        if let api = JSON.double(JSON.value(planUsage, key: "apiPercentUsed")) {
            bars.append(MeterBar(id: "api", label: "API", usedPercent: api, detail: ""))
        }

        var plan = Format.planName(values["cursorAuth/stripeMembershipType"] ?? "")
        var price = ""
        if let planResponse = await planCall, planResponse.0 == 200,
           let planBody = JSON.object(from: planResponse.1),
           let info = JSON.dictionary(JSON.value(planBody, key: "planInfo")) {
            if let name = JSON.string(JSON.value(info, key: "planName")), !name.isEmpty {
                plan = name
            }
            price = JSON.string(JSON.value(info, key: "price")) ?? ""
        }
        if !price.isEmpty {
            plan = plan.isEmpty ? price : "\(plan) · \(price)"
        }

        var lines: [String] = []
        var tokenLine = ""
        if let events = await eventsCall, events.0 == 200, let eventBody = JSON.object(from: events.1) {
            let input = JSON.double(JSON.value(eventBody, key: "totalInputTokens")) ?? 0
            let output = JSON.double(JSON.value(eventBody, key: "totalOutputTokens")) ?? 0
            let cache = JSON.double(JSON.value(eventBody, key: "totalCacheReadTokens")) ?? 0
            tokenLine = "\(Format.count(input)) in · \(Format.count(output)) out · \(Format.count(cache)) cache"
            let models = JSON.array(JSON.value(eventBody, key: "aggregations")).compactMap { item -> (String, Double)? in
                guard let name = JSON.string(JSON.value(item, key: "modelIntent")) else { return nil }
                let cents = JSON.double(JSON.value(item, key: "totalCents")) ?? 0
                return (Format.modelName(name), cents)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(3)
            if !models.isEmpty {
                lines.append(models.map { "\($0.0) \(Format.money(cents: $0.1))" }.joined(separator: " · "))
            }
        }
        if let end = Clock.date(from: JSON.value(body, key: "billingCycleEnd")) {
            let when = Format.reset(end).replacingOccurrences(of: " d", with: " days")
            tokenLine = tokenLine.isEmpty ? "Resets \(when)" : tokenLine + " · resets \(when)"
        }
        if !tokenLine.isEmpty {
            lines.insert(tokenLine, at: 0)
        }

        let headline: String
        if let auto = bars.first(where: { $0.id == "auto" }) {
            headline = "\(Format.percent(max(0, 100 - auto.usedPercent))) left"
        } else if let remaining {
            headline = "\(Format.money(cents: remaining)) left"
        } else if let first = bars.first {
            headline = "\(Format.percent(max(0, 100 - first.usedPercent))) left"
        } else {
            headline = "No allowance"
        }

        return ProviderSnapshot(
            id: "cursor",
            name: "Cursor",
            plan: plan,
            headline: headline,
            bars: bars,
            chips: [],
            lines: lines,
            note: nil,
            warning: nil,
            tone: .ready
        )
    }

    // MARK: OpenAI / Codex

    private func openai() async -> ProviderSnapshot {
        let authURL = Paths.file(".codex", "auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let root = JSON.object(from: data),
              let tokens = JSON.dictionary(JSON.value(root, key: "tokens")),
              let access = JSON.string(JSON.value(tokens, key: "access_token")),
              !access.isEmpty
        else {
            return .problem(id: "openai", name: "Codex", tone: .missing, note: "No Codex session. Run codex login.")
        }
        var headers = [
            "Accept": "application/json",
            "Authorization": "Bearer \(access)",
            "User-Agent": "codex-cli",
        ]
        if let account = JSON.string(JSON.value(tokens, key: "account_id")), !account.isEmpty {
            headers["ChatGPT-Account-Id"] = account
        }
        guard let response = await HTTP.send(URL(string: "https://chatgpt.com/backend-api/wham/usage")!, headers: headers) else {
            return .problem(id: "openai", name: "Codex", tone: .failed, note: "Can't reach Codex.")
        }
        guard response.0 == 200, let body = JSON.object(from: response.1) else {
            let tone: ProviderTone = (response.0 == 401 || response.0 == 403) ? .missing : .failed
            let note = tone == .missing ? "Codex session expired. Run codex login." : HTTP.message(status: response.0, data: response.1)
            return .problem(id: "openai", name: "Codex", tone: tone, note: note)
        }

        let rate = JSON.dictionary(JSON.value(body, key: "rate_limit")) ?? [:]
        var bars: [MeterBar] = []
        if let primary = JSON.dictionary(JSON.value(rate, key: "primary_window")) {
            bars.append(windowBar(id: "primary", window: primary))
        }
        if let secondary = JSON.dictionary(JSON.value(rate, key: "secondary_window")) {
            bars.append(windowBar(id: "secondary", window: secondary))
        }
        let planType = JSON.string(JSON.value(body, key: "plan_type")) ?? ""
        let plan = planType.isEmpty ? "Codex" : "Codex \(Format.planName(planType))"
        let headline: String
        if let first = bars.first {
            headline = "\(Format.percent(max(0, 100 - first.usedPercent))) left"
        } else {
            headline = "No window"
        }
        var lines: [String] = []
        if let credits = JSON.dictionary(JSON.value(body, key: "credits")),
           JSON.bool(JSON.value(credits, key: "has_credits")) == true,
           let balance = JSON.double(JSON.value(credits, key: "balance")),
           balance > 0 {
            lines.append("Credits \(Format.count(balance))")
        }
        return ProviderSnapshot(
            id: "openai",
            name: "Codex",
            plan: plan,
            headline: headline,
            bars: bars,
            chips: [],
            lines: lines,
            note: nil,
            warning: nil,
            tone: .ready
        )
    }

    private func windowBar(id: String, window: [String: Any]) -> MeterBar {
        let used = JSON.double(JSON.value(window, key: "used_percent")) ?? 0
        let seconds = JSON.double(JSON.value(window, key: "limit_window_seconds")) ?? 0
        let reset = Clock.date(from: JSON.value(window, key: "reset_at"))
        return MeterBar(id: id, label: durationLabel(seconds), usedPercent: used, detail: Format.reset(reset))
    }

    private func durationLabel(_ seconds: Double) -> String {
        switch Int(seconds) {
        case 18_000: return "5 hours"
        case 86_400: return "Day"
        case 604_800: return "Week"
        default:
            if seconds <= 0 { return "Window" }
            let hours = Int(seconds / 3600)
            if hours < 48 { return "\(hours) h" }
            return "\(hours / 24) d"
        }
    }

    // MARK: Claude

    func claudeWithPrompt() async -> ProviderSnapshot {
        await claudeClient.load(prompt: true)
    }

    private func claude() async -> ProviderSnapshot {
        await claudeClient.load()
    }

    // MARK: OpenCode

    private func opencode() async -> ProviderSnapshot {
        let database = opencodeDatabase()
        guard let database, FileManager.default.fileExists(atPath: database.path) else {
            return .problem(id: "opencode", name: "OpenCode", tone: .missing, note: "Can't find the local OpenCode database.")
        }

        var bars: [MeterBar] = []
        var plan = "Local"
        var headline = "Local use"
        var note = "Sessions on this Mac. Not a plan quota."
        if let key = opencodeGoKey() {
            if let quota = await openCodeGo(key: key) {
                bars = quota
                plan = "Go"
                if let first = bars.max(by: { $0.usedPercent < $1.usedPercent }) {
                    headline = "\(Format.percent(max(0, 100 - first.usedPercent))) left"
                }
                note = "The bar is OpenCode Go. Local tokens are below."
            } else {
                note = "Couldn't read the OpenCode Go quota. Local tokens are below."
            }
        }

        let now = Date()
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        guard let today = sessionStats(database: database, since: startOfDay),
              let week = sessionStats(database: database, since: weekAgo),
              let all = sessionStats(database: database, since: nil)
        else {
            return .problem(id: "opencode", name: "OpenCode", tone: .failed, note: "OpenCode has the database open, so it couldn't be read.")
        }

        let chips = [
            StatChip(id: "today", label: "Today", value: Format.count(today.tokens), hint: sessionHint(today.sessions)),
            StatChip(id: "week", label: "7 days", value: Format.count(week.tokens), hint: sessionHint(week.sessions)),
            StatChip(id: "all", label: "Total", value: Format.count(all.tokens), hint: sessionHint(all.sessions)),
        ]
        var lines: [String] = []
        if all.cache > 0 {
            lines.append("Cache read \(Format.count(all.cache)) · estimated cost \(Format.money(cents: all.cost * 100))")
        } else if all.cost > 0 {
            lines.append("Estimated cost \(Format.money(cents: all.cost * 100))")
        }
        if let models = modelLine(database: database, since: weekAgo) {
            lines.append(models)
        }

        return ProviderSnapshot(
            id: "opencode",
            name: "OpenCode",
            plan: plan,
            headline: headline,
            bars: bars,
            chips: chips,
            lines: lines,
            note: note,
            warning: nil,
            tone: .ready
        )
    }

    private struct SessionStats {
        var sessions: Double
        var tokens: Double
        var cache: Double
        var cost: Double
    }

    private func sessionStats(database: URL, since: Date?) -> SessionStats? {
        let sql: String
        let binds: [Int64]
        if let since {
            sql = """
            SELECT COUNT(*) AS sessions,
                   COALESCE(SUM(tokens_input + tokens_output + tokens_reasoning), 0) AS tokens,
                   COALESCE(SUM(tokens_cache_read), 0) AS cache,
                   COALESCE(SUM(cost), 0) AS cost
            FROM session
            WHERE time_updated >= ?
            """
            binds = [Int64(since.timeIntervalSince1970 * 1000)]
        } else {
            sql = """
            SELECT COUNT(*) AS sessions,
                   COALESCE(SUM(tokens_input + tokens_output + tokens_reasoning), 0) AS tokens,
                   COALESCE(SUM(tokens_cache_read), 0) AS cache,
                   COALESCE(SUM(cost), 0) AS cost
            FROM session
            """
            binds = []
        }
        guard let row = SQLite.query(path: database.path, sql: sql, binds: binds)?.first else { return nil }
        return SessionStats(
            sessions: Double(row["sessions"] ?? "") ?? 0,
            tokens: Double(row["tokens"] ?? "") ?? 0,
            cache: Double(row["cache"] ?? "") ?? 0,
            cost: Double(row["cost"] ?? "") ?? 0
        )
    }

    private func modelLine(database: URL, since: Date) -> String? {
        let sql = """
        SELECT model,
               SUM(tokens_input + tokens_output + tokens_reasoning) AS tokens
        FROM session
        WHERE time_updated >= ? AND model IS NOT NULL AND model != ''
        GROUP BY model
        ORDER BY tokens DESC
        LIMIT 8
        """
        guard let rows = SQLite.query(
            path: database.path,
            sql: sql,
            binds: [Int64(since.timeIntervalSince1970 * 1000)]
        ), !rows.isEmpty else { return nil }
        var totals: [String: Double] = [:]
        for row in rows {
            let name = Format.modelName(row["model"] ?? "")
            let tokens = Double(row["tokens"] ?? "") ?? 0
            totals[name, default: 0] += tokens
        }
        let parts = totals.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key) \(Format.count($0.value))" }
        return parts.joined(separator: " · ")
    }

    private func sessionHint(_ count: Double) -> String {
        let sessions = Int(count)
        if sessions == 0 { return "no sessions" }
        return sessions == 1 ? "1 session" : "\(sessions) sessions"
    }

    private func opencodeDatabase() -> URL? {
        let candidates = [
            Paths.file(".local", "share", "opencode", "opencode.db"),
            Paths.file("Library", "Application Support", "opencode", "opencode.db"),
        ]
        if let dataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !dataHome.isEmpty {
            let preferred = URL(fileURLWithPath: dataHome).appendingPathComponent("opencode/opencode.db")
            if FileManager.default.fileExists(atPath: preferred.path) { return preferred }
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func opencodeGoKey() -> String? {
        var urls = [Paths.file(".local", "share", "opencode", "auth.json")]
        if let dataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !dataHome.isEmpty {
            urls.insert(URL(fileURLWithPath: dataHome).appendingPathComponent("opencode/auth.json"), at: 0)
        }
        urls.append(Paths.file("Library", "Application Support", "opencode", "auth.json"))
        for url in urls {
            guard let data = try? Data(contentsOf: url), let root = JSON.object(from: data) else { continue }
            for name in ["opencode-go", "opencode"] {
                guard let entry = JSON.dictionary(JSON.value(root, key: name)),
                      JSON.string(JSON.value(entry, key: "type")) == "api",
                      let key = JSON.string(JSON.value(entry, key: "key")),
                      !key.isEmpty
                else { continue }
                return key
            }
        }
        return nil
    }

    private func openCodeGo(key: String) async -> [MeterBar]? {
        guard let response = await HTTP.send(
            URL(string: "https://opencode.ai/zen/go/v1/usage")!,
            headers: ["Accept": "application/json", "Authorization": "Bearer \(key)"]
        ), response.0 == 200, let body = JSON.object(from: response.1),
              let usage = JSON.dictionary(JSON.value(body, key: "usage"))
        else { return nil }
        let windows: [(String, String)] = [("rolling", "5 hours"), ("weekly", "Week"), ("monthly", "Month")]
        var bars: [MeterBar] = []
        for (name, label) in windows {
            guard let window = JSON.dictionary(JSON.value(usage, key: name)),
                  JSON.string(JSON.value(window, key: "status")) == "ok",
                  let percent = JSON.double(JSON.value(window, key: "percent"))
            else { continue }
            bars.append(MeterBar(
                id: name,
                label: label,
                usedPercent: percent,
                detail: Format.reset(Clock.date(from: JSON.value(window, key: "resetsAt")))
            ))
        }
        return bars.isEmpty ? nil : bars
    }
}

private func formEncode(_ items: [String: String]) -> Data {
    let allowed = CharacterSet.alphanumerics
    let body = items.map { key, value in
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(encodedKey)=\(encodedValue)"
    }
    .joined(separator: "&")
    return Data(body.utf8)
}
