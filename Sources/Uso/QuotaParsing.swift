import CoreFoundation
import Foundation

enum QuotaParsing {
    private static func percent(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        guard let number = JSON.double(value), number.isFinite, number >= 0 else { return nil }
        return number
    }

    static func grokBot(_ body: [String: Any]) -> ProviderSnapshot {
        if JSON.bool(body["usesPooledEnterpriseAllowance"]) == true {
            return .problem(
                id: "grok-bot", name: "Grok Bot", tone: .missing,
                note: "Managed team allowance. Check Usage & Billing in Grok Bot.")
        }
        let grokPlan = JSON.string(body["grokPlanLabel"]).flatMap { $0.isEmpty ? nil : $0 }
        let cursorPlan = JSON.string(body["cursorPlanName"]).flatMap {
            $0.isEmpty ? nil : Format.planName($0)
        }
        let unified = JSON.bool(body["isUnified"]) == true
        if unified {
            let plan = [cursorPlan, grokPlan].compactMap { $0 }.joined(separator: " · ")
            return ProviderSnapshot(
                id: "grok-bot", name: "Grok Bot", plan: plan.isEmpty ? "Grok Bot" : plan,
                headline: "Shared weekly pool",
                bars: [], chips: [], lines: [],
                note:
                    "On The X Subscription, Grok Bot draws from the same weekly pool as Cursor and Grok. It is not a separate quota.",
                warning: nil, tone: .ready, sharedPool: .member)
        }
        guard let used = percent(body["usagePercent"]) else {
            return .problem(
                id: "grok-bot", name: "Grok Bot", tone: .failed,
                note: "Grok Bot didn't return a weekly quota. Check Usage & Billing in Grok Bot.")
        }
        let trialEnd = Clock.date(from: body["sandTrialExpiresAt"])
        let isTrial = trialEnd.map { $0 > Date() } ?? false
        let legacyCursor = cursorPlan.map { "Cursor \($0)" }
        let plan = [grokPlan, legacyCursor].compactMap { $0 }.joined(separator: " · ")
        return ProviderSnapshot(
            id: "grok-bot", name: "Grok Bot", plan: plan.isEmpty ? "Grok Bot" : plan,
            headline: "\(Format.percent(max(0, 100 - used))) left",
            bars: [
                MeterBar(
                    id: "weekly", label: isTrial ? "Trial" : "Week", usedPercent: used,
                    detail: Format.reset(Clock.date(from: body["nextResetTimestampUtc"]) ?? trialEnd))
            ],
            chips: [], lines: [],
            note:
                "Quota for the account signed in to Cursor on this Mac. Use the same account in Grok Bot. Separate from Grok Build credits.",
            warning: nil, tone: .ready
        )
    }

    static func grok(_ config: [String: Any], plan: String) -> ProviderSnapshot {
        let used = JSON.double(config["creditUsagePercent"]) ?? 0
        let period = JSON.dictionary(config["currentPeriod"]) ?? [:]
        let resets = Clock.date(from: period["end"]) ?? Clock.date(from: config["billingPeriodEnd"])
        let window = windowName(JSON.string(period["type"]))
        let unified = JSON.bool(config["isUnifiedBillingUser"]) == true
        var bars = [
            MeterBar(id: "credits", label: window, usedPercent: used, detail: Format.reset(resets))
        ]
        var lines: [String] = []
        let mix = JSON.array(config["productUsage"]).compactMap { item -> String? in
            guard let product = JSON.dictionary(item),
                let usedProduct = percent(product["usagePercent"]), usedProduct > 0,
                let name = JSON.string(product["product"])
            else { return nil }
            return "\(grokProductName(name)) \(Format.percent(usedProduct))"
        }
        if unified {
            if !mix.isEmpty { lines.append("Mix · " + mix.joined(separator: " · ")) }
        } else {
            for product in JSON.array(config["productUsage"]) {
                guard let row = JSON.dictionary(product), let usedProduct = percent(row["usagePercent"]),
                    let name = JSON.string(row["product"])
                else { continue }
                bars.append(
                    MeterBar(id: name, label: grokProductName(name), usedPercent: usedProduct, detail: ""))
            }
        }
        if let prepaid = JSON.double(JSON.value(config["prepaidBalance"], key: "val")), prepaid > 0 {
            lines.append("Prepaid \(Format.money(cents: prepaid))")
        }
        if let onDemand = JSON.double(JSON.value(config["onDemandUsed"], key: "val")), onDemand > 0 {
            lines.append("On demand \(Format.money(cents: onDemand))")
        }
        return ProviderSnapshot(
            id: "grok", name: "Grok", plan: plan.isEmpty ? "Grok" : plan,
            headline: "\(Format.percent(max(0, 100 - used))) left",
            bars: bars, chips: [], lines: lines,
            note: unified
                ? "On The X Subscription this is the shared weekly pool with Cursor and Grok Bot." : nil,
            warning: nil, tone: .ready, sharedPool: unified ? .member : .none)
    }

    static func cursor(
        period: [String: Any], plan: String, merged: Bool, includedReset: Date?, tokenLine: String,
        modelLine: String?
    ) -> ProviderSnapshot {
        let planUsage = JSON.dictionary(period["planUsage"]) ?? [:]
        let limit = JSON.double(planUsage["limit"]) ?? 0
        let spent = JSON.double(planUsage["includedSpend"]) ?? JSON.double(planUsage["totalSpend"]) ?? 0
        let remaining = JSON.double(planUsage["remaining"])
        let reset = includedReset ?? Clock.date(from: period["billingCycleEnd"])
        var bars: [MeterBar] = []
        if let auto = JSON.double(planUsage["autoPercentUsed"]) {
            if merged {
                bars.append(
                    MeterBar(id: "week", label: "Week", usedPercent: auto, detail: Format.reset(reset)))
            } else {
                bars.append(MeterBar(id: "auto", label: "Auto", usedPercent: auto, detail: "Other models"))
            }
        }
        if !merged, limit > 0 {
            let used = min(100, spent / limit * 100)
            let detail: String
            if let remaining {
                detail = Format.money(cents: remaining)
            } else {
                detail = "\(Format.money(cents: spent)) of \(Format.money(cents: limit))"
            }
            bars.append(MeterBar(id: "included", label: "Included", usedPercent: used, detail: detail))
        }
        if !merged, let api = JSON.double(planUsage["apiPercentUsed"]) {
            bars.append(MeterBar(id: "api", label: "API", usedPercent: api, detail: ""))
        }
        var lines: [String] = []
        if !tokenLine.isEmpty { lines.append(tokenLine) }
        if let modelLine, !modelLine.isEmpty { lines.append(modelLine) }
        let headline: String
        if let week = bars.first(where: { $0.id == "week" || $0.id == "auto" }) {
            headline = "\(Format.percent(max(0, 100 - week.usedPercent))) left"
        } else if let remaining {
            headline = "\(Format.money(cents: remaining)) left"
        } else if let first = bars.first {
            headline = "\(Format.percent(max(0, 100 - first.usedPercent))) left"
        } else {
            headline = "No allowance"
        }
        return ProviderSnapshot(
            id: "cursor", name: "Cursor", plan: plan, headline: headline, bars: bars, chips: [], lines: lines,
            note: merged
                ? "On The X Subscription this week is shared with Grok and Grok Bot. Third-party models bill from prepaid, not this pool."
                : nil, warning: nil, tone: .ready, sharedPool: merged ? .owner : .none)
    }

    private static func windowName(_ raw: String?) -> String {
        switch raw {
        case "USAGE_PERIOD_TYPE_WEEKLY": return "Week"
        case "USAGE_PERIOD_TYPE_MONTHLY": return "Month"
        case "USAGE_PERIOD_TYPE_DAILY": return "Day"
        default: return "Period"
        }
    }

    private static func grokProductName(_ name: String) -> String {
        switch name {
        case "GrokBuild": return "Build"
        case "GrokImagine": return "Imagine"
        case "GrokChat": return "Chat"
        case "GrokVoice": return "Voice"
        case "GrokBot": return "Grok Bot"
        default: return name
        }
    }

    static func claude(_ body: [String: Any], plan: String) -> ProviderSnapshot {
        var bars: [MeterBar] = []
        var declared = Set<String>()
        for item in JSON.array(body["limits"]) {
            guard let row = JSON.dictionary(item), let used = percent(row["percent"]),
                let kind = JSON.string(row["kind"])
            else { continue }
            let scope = JSON.dictionary(row["scope"]) ?? [:]
            let model = JSON.dictionary(scope["model"]) ?? [:]
            let name = JSON.string(model["display_name"]) ?? JSON.string(model["id"])
            let id: String
            let label: String
            switch kind {
            case "session":
                id = "session"
                label = "Session"
            case "weekly_all":
                id = "weekly_all"
                label = "Week"
            case "weekly_scoped":
                id = "model:" + (JSON.string(model["id"]) ?? name ?? String(bars.count))
                label = name.map { "\($0) week" } ?? "Model week"
            default: continue
            }
            declared.insert(id)
            // Verified Ultra keeps a leftover session row with is_active=false. Don't show it,
            // and don't let the legacy five_hour field put it back.
            if id == "session", JSON.bool(row["is_active"]) == false { continue }
            guard !bars.contains(where: { $0.id == id }) else { continue }
            bars.append(
                MeterBar(
                    id: id, label: label, usedPercent: used, detail: Format.reset(Clock.date(from: row["resets_at"]))))
        }

        // New limits take precedence, but a partial array must not hide legacy windows.
        let legacy = [
            ("five_hour", "session", "Session"), ("seven_day", "weekly_all", "Week"),
            ("seven_day_opus", "model:Opus", "Opus week"),
            ("seven_day_sonnet", "model:Sonnet", "Sonnet week"),
            ("seven_day_overage_included", "model:Fable", "Fable week"),
            ("seven_day_oauth_apps", "surface:oauth", "OAuth apps week"),
            ("seven_day_cowork", "surface:cowork", "Cowork week"),
        ]
        for (key, id, label) in legacy {
            guard !declared.contains(id), !bars.contains(where: { $0.id == id || $0.label == label }),
                let row = JSON.dictionary(body[key]), let used = percent(row["utilization"])
            else { continue }
            bars.append(
                MeterBar(
                    id: id, label: label, usedPercent: used, detail: Format.reset(Clock.date(from: row["resets_at"]))))
        }
        if let api = apiCreditsBar(from: body) { bars.append(api) }
        let order = ["session", "weekly_all", "api"]
        bars.sort { (order.firstIndex(of: $0.id) ?? 3) < (order.firstIndex(of: $1.id) ?? 3) }
        guard let first = bars.first else {
            return .problem(
                id: "claude", name: "Claude", tone: .failed, note: "Claude didn't return any usage windows.")
        }
        var lines: [String] = []
        if let breakdown = JSON.dictionary(body["seven_day_breakdown"]) {
            let parts = JSON.array(breakdown["rows"]).compactMap { item -> String? in
                guard let row = JSON.dictionary(item), let name = JSON.string(row["display_name"]),
                    let used = percent(row["percent"]), used > 0
                else { return nil }
                return "\(name) \(Format.percent(used))"
            }
            if !parts.isEmpty { lines.append("Mix · " + parts.joined(separator: " · ")) }
        }
        lines.append(contentsOf: extraUsageLines(from: body))
        if let reset = limitResetLine(from: body) { lines.append(reset) }
        return ProviderSnapshot(
            id: "claude", name: "Claude", plan: plan,
            headline: "\(Format.percent(max(0, 100 - first.usedPercent))) left",
            bars: bars, chips: [], lines: lines, note: nil, warning: nil, tone: .ready
        )
    }

    /// Monthly API credits bundled with Max/Ultra. Anthropic currently ships this as an
    /// obfuscated top-level window with `limit_dollars`; we match on that shape, not the key name.
    private static func apiCreditsBar(from body: [String: Any]) -> MeterBar? {
        for (_, value) in body {
            guard let row = JSON.dictionary(value), let limit = JSON.double(row["limit_dollars"]),
                limit.isFinite, limit > 0
            else { continue }
            let used = JSON.double(row["used_dollars"]) ?? 0
            let remaining = JSON.double(row["remaining_dollars"]) ?? max(0, limit - used)
            let usedPercent: Double
            if let utilization = percent(row["utilization"]), utilization <= 100 {
                usedPercent = utilization
            } else {
                usedPercent = min(100, (used / limit) * 100)
            }
            var bits = ["\(Format.dollars(remaining)) left"]
            let reset = Format.reset(Clock.date(from: row["resets_at"]))
            if !reset.isEmpty { bits.append(reset) }
            return MeterBar(
                id: "api", label: "API credits", usedPercent: usedPercent, detail: bits.joined(separator: " · "))
        }
        return nil
    }

    private static func extraUsageLines(from body: [String: Any]) -> [String] {
        guard let extra = JSON.dictionary(body["extra_usage"]) else { return [] }
        if JSON.bool(extra["is_enabled"]) == true {
            if let used = percent(extra["utilization"]) {
                return ["Extra usage \(Format.percent(used)) used"]
            }
            return ["Extra usage on"]
        }
        if JSON.bool(extra["credits_ever_enabled"]) == true {
            return ["Extra usage off"]
        }
        return []
    }

    /// Banked "Reset for free" cards. Present only when Anthropic attaches an offer object.
    private static func limitResetLine(from body: [String: Any]) -> String? {
        var offers: [[String: Any]] = []
        for (key, value) in body {
            guard key.localizedCaseInsensitiveContains("offer"), let row = JSON.dictionary(value) else {
                continue
            }
            offers.append(row)
        }
        guard let offer = offers.first else { return nil }
        let title = JSON.string(offer["title"]) ?? JSON.string(offer["name"]) ?? "Limit reset"
        let expiry = Format.reset(Clock.date(from: offer["expires_at"] ?? offer["expiry"]))
        if expiry.isEmpty { return "\(title) available" }
        if expiry.hasPrefix("in ") { return "\(title) available · expires \(expiry)" }
        return "\(title) available · \(expiry)"
    }

    static func gemini(_ body: [String: Any], plan: String) -> ProviderSnapshot {
        struct Group {
            var name: String
            var session: MeterBar?
            var week: MeterBar?
        }
        var groups: [Group] = []
        for item in JSON.array(body["groups"]) {
            guard let row = JSON.dictionary(item) else { continue }
            let name = JSON.string(row["displayName"]) ?? JSON.string(row["name"]) ?? ""
            var session: MeterBar?
            var week: MeterBar?
            for bucket in JSON.array(row["buckets"]) {
                guard let info = JSON.dictionary(bucket), JSON.bool(info["disabled"]) != true,
                    let used = usedFromRemaining(info["remainingFraction"] ?? info["remaining_fraction"])
                else { continue }
                let reset = Clock.date(
                    from: info["resetTime"] ?? info["reset_time"] ?? info["resetAt"] ?? info["reset_at"])
                switch bucketPeriod(info) {
                case "session":
                    if session == nil {
                        session = MeterBar(
                            id: "session", label: "Session", usedPercent: used, detail: Format.reset(reset))
                    }
                case "week":
                    if week == nil {
                        week = MeterBar(id: "week", label: "Week", usedPercent: used, detail: Format.reset(reset))
                    }
                default: continue
                }
            }
            if session != nil || week != nil {
                groups.append(Group(name: name, session: session, week: week))
            }
        }
        guard !groups.isEmpty else {
            return .problem(
                id: "gemini", name: "Gemini", tone: .failed, note: "Gemini didn't return any usage windows.")
        }
        let primaryIndex = groups.firstIndex { $0.name.lowercased().contains("gemini") } ?? 0
        var bars: [MeterBar] = []
        func append(group: Group, primary: Bool) {
            let tag = groupLabel(group.name)
            if var bar = group.session {
                bar.id = primary ? "session" : "\(tag.lowercased()):session"
                bar.label = primary ? "Session" : "\(tag) 5h"
                bars.append(bar)
            }
            if var bar = group.week {
                bar.id = primary ? "week" : "\(tag.lowercased()):week"
                bar.label = primary ? "Week" : "\(tag) week"
                bars.append(bar)
            }
        }
        append(group: groups[primaryIndex], primary: true)
        for (index, group) in groups.enumerated() where index != primaryIndex {
            append(group: group, primary: false)
        }
        guard let first = bars.first else {
            return .problem(
                id: "gemini", name: "Gemini", tone: .failed, note: "Gemini didn't return any usage windows.")
        }
        return ProviderSnapshot(
            id: "gemini", name: "Gemini", plan: plan.isEmpty ? "Gemini" : plan,
            headline: "\(Format.percent(max(0, 100 - first.usedPercent))) left",
            bars: bars, chips: [], lines: [],
            note: "Quota for the Google account signed in to Antigravity (agy) on this Mac.",
            warning: nil, tone: .ready)
    }

    private static func usedFromRemaining(_ value: Any?) -> Double? {
        guard let remaining = percent(value) else { return nil }
        let leftover = remaining <= 1.5 ? remaining * 100 : remaining
        return max(0, 100 - leftover)
    }

    private static func bucketPeriod(_ bucket: [String: Any]) -> String? {
        let label = [
            JSON.string(bucket["window"]), JSON.string(bucket["bucketId"]), JSON.string(bucket["displayName"]),
            JSON.string(bucket["name"]), JSON.string(bucket["id"]),
        ].compactMap { $0 }.joined(separator: " ").lowercased()
        if label.contains("week") || label.contains("7d") || label.contains("seven") { return "week" }
        if label.contains("5h") || label.contains("5 h") || label.contains("hour") || label.contains("session") {
            return "session"
        }
        return nil
    }

    private static func groupLabel(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("claude") || lower.contains("gpt") { return "Claude" }
        if lower.contains("gemini") { return "Gemini" }
        let first = name.split(whereSeparator: { $0 == " " || $0 == "·" }).first.map(String.init) ?? name
        return first.isEmpty ? "Other" : first
    }
}
