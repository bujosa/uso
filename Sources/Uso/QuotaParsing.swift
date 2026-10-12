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
        guard let used = percent(body["usagePercent"]) else {
            return .problem(
                id: "grok-bot", name: "Grok Bot", tone: .failed,
                note: "Grok Bot didn't return a weekly quota. Check Usage & Billing in Grok Bot.")
        }
        let trialEnd = Clock.date(from: body["sandTrialExpiresAt"])
        let isTrial = trialEnd.map { $0 > Date() } ?? false
        let grokPlan = JSON.string(body["grokPlanLabel"]).flatMap { $0.isEmpty ? nil : $0 }
        let cursorPlan = JSON.string(body["cursorPlanName"]).flatMap {
            $0.isEmpty ? nil : "Cursor \(Format.planName($0))"
        }
        let plan = [grokPlan, cursorPlan].compactMap { $0 }.joined(separator: " · ")
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

    static func claude(_ body: [String: Any], plan: String) -> ProviderSnapshot {
        var bars: [MeterBar] = []
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
            guard !bars.contains(where: { $0.id == id || $0.label == label }),
                let row = JSON.dictionary(body[key]), let used = percent(row["utilization"])
            else { continue }
            bars.append(
                MeterBar(
                    id: id, label: label, usedPercent: used, detail: Format.reset(Clock.date(from: row["resets_at"]))))
        }
        let order = ["session", "weekly_all"]
        bars.sort { (order.firstIndex(of: $0.id) ?? 2) < (order.firstIndex(of: $1.id) ?? 2) }
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
        if let extra = JSON.dictionary(body["extra_usage"]), JSON.bool(extra["is_enabled"]) == true {
            if let used = percent(extra["utilization"]) {
                lines.append("Extra usage \(Format.percent(used)) used")
            }
        }
        return ProviderSnapshot(
            id: "claude", name: "Claude", plan: plan,
            headline: "\(Format.percent(max(0, 100 - first.usedPercent))) left",
            bars: bars, chips: [], lines: lines, note: nil, warning: nil, tone: .ready
        )
    }
}
