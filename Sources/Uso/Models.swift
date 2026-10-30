import Foundation

struct MeterBar: Identifiable, Sendable, Equatable {
    var id: String
    var label: String
    var usedPercent: Double
    var detail: String
}

struct StatChip: Identifiable, Sendable, Equatable {
    var id: String
    var label: String
    var value: String
    var hint: String
}

enum ProviderTone: Sendable, Equatable {
    case ready
    case missing
    case failed
    case loading
}

enum AccountConnection: Sendable, Equatable {
    case unverified
    case keychainPermission
    /// This Mac has a session, but the service rejected it or Uso can't open it.
    case signInRequired
}

/// How a source relates to The X Subscription's shared weekly pool.
enum SharedPool: Sendable, Equatable {
    case none
    /// Canonical week meter for the unified plan.
    case owner
    /// Same pool as the owner; not a second leftover quota.
    case member
}

struct ProviderSnapshot: Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var plan: String
    var headline: String
    var bars: [MeterBar]
    var chips: [StatChip]
    var lines: [String]
    var note: String?
    var warning: String?
    var tone: ProviderTone
    var readAt: Date? = nil
    var connection: AccountConnection? = nil
    var sharedPool: SharedPool = .none

    var isCurrent: Bool { tone == .ready && warning == nil }

    /// Whether this Mac has a session for the source, even one that needs attention. Drives default visibility.
    var isDetected: Bool {
        switch tone {
        case .ready, .failed: return true
        case .missing: return connection != nil
        case .loading: return false
        }
    }

    func keepingLastReading(_ previous: ProviderSnapshot?) -> ProviderSnapshot {
        guard tone == .failed, let previous, previous.tone == .ready else { return self }
        var kept = previous
        let time = previous.readAt.map { $0.formatted(date: .omitted, time: .shortened) }
        let label = time.map { "Last reading at \($0)." } ?? "Last reading."
        kept.warning = "\(label) \(note ?? "Couldn't refresh.")"
        return kept
    }

    var tightestUsed: Double? {
        bars.map(\.usedPercent).max()
    }

    var debugSummary: String {
        let meters = bars.map { "\($0.label) \(Format.percent($0.usedPercent))" }.joined(separator: ", ")
        let extra = (lines + chips.map { "\($0.label) \($0.value)" }).joined(separator: " | ")
        return "\(name) [\(plan)] \(headline) :: \(meters) :: \(extra) :: \(note ?? "")"
    }

    static func loading(id: String, name: String) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id,
            name: name,
            plan: "",
            headline: "…",
            bars: [],
            chips: [],
            lines: [],
            note: nil,
            warning: nil,
            tone: .loading
        )
    }

    static let placeholders: [ProviderSnapshot] = [
        .loading(id: "grok", name: "Grok"),
        .loading(id: "grok-bot", name: "Grok Bot"),
        .loading(id: "cursor", name: "Cursor"),
        .loading(id: "openai", name: "Codex"),
        .loading(id: "claude", name: "Claude"),
        .loading(id: "gemini", name: "Gemini"),
        .loading(id: "opencode", name: "OpenCode"),
    ]

    static func problem(id: String, name: String, tone: ProviderTone, note: String) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id,
            name: name,
            plan: "",
            headline: "No data",
            bars: [],
            chips: [],
            lines: [],
            note: note,
            warning: nil,
            tone: tone
        )
    }

    static func signInRequired(id: String, name: String, note: String) -> ProviderSnapshot {
        var snapshot = problem(id: id, name: name, tone: .missing, note: note)
        snapshot.connection = .signInRequired
        return snapshot
    }
}

struct HeroState: Equatable {
    var kicker: String
    var name: String
    var value: String
    var detail: String
    var usedPercent: Double
}

enum Pressure {
    static func hero(from providers: [ProviderSnapshot]) -> HeroState? {
        let points = providers.filter(\.isCurrent).compactMap { provider -> (ProviderSnapshot, MeterBar)? in
            guard let bar = provider.bars.first else { return nil }
            return (provider, bar)
        }
        guard let (provider, bar) = points.max(by: { $0.1.usedPercent < $1.1.usedPercent }) else {
            return nil
        }
        let left = max(0, 100 - bar.usedPercent)
        let kicker: String
        if left <= 0 {
            kicker = "Maxed out"
        } else if left < 15 {
            kicker = "Almost out"
        } else if left < 40 {
            kicker = "Running low"
        } else {
            kicker = "Tightest"
        }
        let value = left <= 0 ? "0%" : Format.percent(left)
        var detailParts = [bar.label]
        if provider.headline.contains("$") {
            detailParts.append(provider.headline)
        } else if !provider.plan.isEmpty {
            detailParts.append(provider.plan)
        }
        if !bar.detail.isEmpty, !provider.headline.contains(bar.detail) {
            detailParts.append(bar.detail)
        }
        return HeroState(
            kicker: kicker,
            name: provider.name,
            value: value,
            detail: detailParts.joined(separator: " · "),
            usedPercent: bar.usedPercent
        )
    }

    static func menuTitle(from providers: [ProviderSnapshot]) -> String {
        MenuTicker.lines(from: providers).first ?? "Usage"
    }
}

/// Legacy Grok / Grok Bot / Cursor rows stay as they are. When The X Subscription is detected,
/// the panel shows one week (the Cursor reading) and folds Grok mix, prepaid, and Grok Bot into it.
enum UnifiedBilling {
    static func present(_ providers: [ProviderSnapshot], keepMember: (String) -> Bool) -> [ProviderSnapshot] {
        guard providers.contains(where: { $0.sharedPool == .owner && $0.tone == .ready }) else {
            return providers
        }
        let hidden = providers.filter { $0.sharedPool == .member && $0.tone == .ready && !keepMember($0.id) }
        return providers.compactMap { item in
            if item.sharedPool == .owner { return fold(hidden, into: item) }
            if item.sharedPool == .member, !keepMember(item.id) { return nil }
            if item.sharedPool == .member { return demoteWeek(item) }
            return item
        }
    }

    private static func fold(_ members: [ProviderSnapshot], into owner: ProviderSnapshot) -> ProviderSnapshot {
        var next = owner
        next.name = "X Subscription"
        var planParts = bits(owner.plan)
        var lines = owner.lines
        for member in members {
            for part in bits(member.plan) where !planParts.contains(part) && !skipPlan.contains(part) {
                planParts.append(part)
            }
            for line in member.lines where !line.isEmpty && !lines.contains(line) {
                lines.append(line)
            }
        }
        next.plan = planParts.joined(separator: " · ")
        next.lines = lines
        return next
    }

    private static func demoteWeek(_ item: ProviderSnapshot) -> ProviderSnapshot {
        guard item.id == "grok" else { return item }
        var next = item
        next.bars = item.bars.filter { $0.id != "credits" }
        return next
    }

    private static func bits(_ plan: String) -> [String] {
        plan.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static let skipPlan: Set<String> = ["Grok", "Grok Bot", "Grok Bot Plan"]
}

enum MenuTicker {
    static func lines(from providers: [ProviderSnapshot]) -> [String] {
        let current = providers.filter(\.isCurrent)
        let cursorOwnsSharedWeek = current.contains {
            $0.id == "cursor" && $0.bars.contains(where: { $0.id == "week" })
        }
        return current.flatMap { provider -> [String] in
            if cursorOwnsSharedWeek, provider.id == "grok" { return [] }
            return lines(for: provider)
        }
    }

    private static func lines(for provider: ProviderSnapshot) -> [String] {
        switch provider.id {
        case "grok":
            guard let bar = provider.bars.first else { return [] }
            return ["Grok \(remaining(bar))"]
        case "cursor":
            var lines: [String] = []
            if let week = provider.bars.first(where: { $0.id == "week" }) {
                let label = provider.sharedPool == .owner ? "X" : "Cursor"
                lines.append("\(label) \(remaining(week))")
            }
            if let auto = provider.bars.first(where: { $0.id == "auto" }) {
                lines.append("Cursor Auto \(remaining(auto))")
            }
            if provider.headline.contains("$") {
                lines.append("Cursor \(provider.headline.replacingOccurrences(of: " left", with: ""))")
            } else if let included = provider.bars.first(where: { $0.id == "included" }) {
                let money = included.detail
                lines.append(money.contains("$") ? "Cursor \(money)" : "Cursor \(remaining(included))")
            }
            return lines
        case "openai":
            return provider.bars.map { bar in
                bar.label == "Week" && provider.bars.count == 1
                    ? "Codex \(remaining(bar))"
                    : "Codex \(short(bar)) \(remaining(bar))"
            }
        case "claude":
            let order = ["session", "five", "weekly_all", "week"]
            var lines = order.compactMap { id -> String? in
                guard let bar = provider.bars.first(where: { $0.id == id }) else { return nil }
                let tag = (id == "session" || id == "five") ? "5h" : "wk"
                return "Claude \(tag) \(remaining(bar))"
            }
            if let api = provider.bars.first(where: { $0.id == "api" }),
                let money = api.detail.split(separator: " ").first, money.hasPrefix("$")
            {
                lines.append("Claude API \(money)")
            }
            return lines
        case "gemini":
            return ["session", "week"].compactMap { id in
                guard let bar = provider.bars.first(where: { $0.id == id }) else { return nil }
                let tag = id == "session" ? "5h" : "wk"
                return "Gemini \(tag) \(remaining(bar))"
            }
        case "opencode":
            guard let week = provider.chips.first(where: { $0.id == "week" }) else { return [] }
            return ["OpenCode \(week.value)"]
        default:
            guard let bar = provider.bars.first else { return [] }
            return ["\(provider.name) \(remaining(bar))"]
        }
    }

    private static func short(_ bar: MeterBar) -> String {
        switch bar.label {
        case "Week": return "wk"
        case "5 hours": return "5h"
        case "Day": return "day"
        default: return bar.label
        }
    }

    private static func remaining(_ bar: MeterBar) -> String {
        if bar.usedPercent >= 99.5 { return "0%" }
        return Format.percent(max(0, 100 - bar.usedPercent))
    }
}
