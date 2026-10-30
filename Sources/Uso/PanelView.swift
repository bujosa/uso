import AppKit
import SwiftUI

@MainActor
final class PanelPresentation: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var escapeRequest = 0

    func prepare(reduceMotion: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { isPresented = reduceMotion }
    }

    func reveal() { isPresented = true }
    func escape() { escapeRequest += 1 }
}

struct PanelView: View {
    @EnvironmentObject private var store: UsageStore
    @EnvironmentObject private var presentation: PanelPresentation
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var selectedID: String?
    let dismiss: () -> Void
    let openSettings: () -> Void
    let layoutChanged: (Bool) -> Void

    private var reduceMotion: Bool { systemReduceMotion || !store.preferences.animatesPanel }

    private var isLooking: Bool { store.isRefreshing || store.providers.isEmpty }

    private var selected: ProviderSnapshot? {
        guard let selectedID else { return nil }
        return store.visibleProviders.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let provider = selected {
                DetailView(provider: provider)
                    .transition(.opacity)
            } else if store.visibleProviders.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(isLooking ? "Looking for your accounts…" : "Nothing to show")
                        .font(.subheadline.weight(.medium))
                    Text("Uso lists the services signed in on this Mac. Sign in to one, or pick sources in Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Settings", action: openSettings)
                }
                .padding(.horizontal, 16).padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                list
                    .transition(.opacity)
            }
            if selected == nil {
                footer
            }
        }
        .frame(width: Glass.width)
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: selectedID)
        .background {
            ZStack {
                GlassBackground()
                Color.black.opacity(0.42)
                LinearGradient(
                    colors: [Color.white.opacity(0.14), Color.white.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 88)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Glass.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Glass.radius, style: .continuous)
                .strokeBorder(Color.white.opacity(presentation.isPresented ? 0.16 : 0.42), lineWidth: 0.5)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Glass.radius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.65), .clear],
                        startPoint: UnitPoint(x: presentation.isPresented ? 1.4 : -0.8, y: -0.2),
                        endPoint: UnitPoint(x: presentation.isPresented ? 2.4 : 0.2, y: 1.2)
                    ), lineWidth: 1
                )
                .opacity(reduceMotion ? 0 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.7), value: presentation.isPresented)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .scaleEffect(reduceMotion || presentation.isPresented ? 1 : 0.96, anchor: .top)
        .offset(y: reduceMotion || presentation.isPresented ? 0 : -10)
        .animation(reduceMotion ? nil : .spring(duration: 0.42, bounce: 0.22), value: presentation.isPresented)
        .task {
            store.activate()
            if selectedID == nil, let id = Self.requestedDetail,
                store.visibleProviders.contains(where: { $0.id == id })
            {
                selectedID = id
            }
        }
        .onChange(of: store.visibleProviders) { _, _ in
            if let selectedID, !store.visibleProviders.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
            if selectedID == nil, let id = Self.requestedDetail,
                store.visibleProviders.contains(where: { $0.id == id })
            {
                selectedID = id
            }
            requestLayout(animated: false)
        }
        .onChange(of: selectedID) { _, _ in
            requestLayout(animated: true)
        }
        .onChange(of: presentation.escapeRequest) { _, _ in
            if selectedID == nil { dismiss() } else { selectedID = nil }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.visibleProviders.enumerated()), id: \.element.id) { index, provider in
                Button {
                    if provider.id == "claude", provider.connection == .keychainPermission {
                        store.allowClaudeKeychain()
                    } else {
                        selectedID = provider.id
                    }
                } label: {
                    ProviderRow(provider: provider)
                }
                .buttonStyle(RowButtonStyle())
                .opacity(reduceMotion || presentation.isPresented ? 1 : 0)
                .offset(y: reduceMotion || presentation.isPresented ? 0 : 12)
                .animation(
                    reduceMotion ? nil : .spring(duration: 0.38, bounce: 0.12).delay(Double(index) * 0.035),
                    value: presentation.isPresented)
                if index < store.visibleProviders.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 0.5)
                        .padding(.leading, 28)
                        .padding(.trailing, Glass.inset)
                }
            }
        }
        .padding(.bottom, 4)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if selected != nil {
                Button {
                    selectedID = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Usage")
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Text("Usage")
                    .font(.subheadline.weight(.semibold))
            }
            Spacer()
            if selected == nil, !store.updatedLabel.isEmpty {
                Text(store.updatedLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Button {
                store.refresh(force: true)
            } label: {
                Group {
                    if store.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
            .keyboardShortcut("r")
            .help("Refresh")
            .accessibilityLabel("Refresh usage")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
            HStack {
                if store.showsLoginToggle {
                    Toggle(
                        "Open at login",
                        isOn: Binding(
                            get: { store.opensAtLogin },
                            set: { store.setOpensAtLogin($0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: openSettings) {
                    Image(systemName: "gearshape").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Settings")
                .help("Settings (⌘,)")
                Button("Quit") {
                    AppExit.requested = true
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let loginMessage = store.loginMessage {
                Text(loginMessage)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    private static var requestedDetail: String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--detail"),
            CommandLine.arguments.indices.contains(index + 1)
        else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private func requestLayout(animated: Bool) {
        DispatchQueue.main.async {
            layoutChanged(animated)
        }
    }
}

private struct ProviderRow: View {
    let provider: ProviderSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(Accent.color(for: provider.id))
                    .frame(width: 6, height: 6)
                Text(provider.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(amount)
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(amountColor)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            if !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 14)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(listBars) { bar in
                    VStack(alignment: .leading, spacing: 3) {
                        if showsBarLabels {
                            HStack {
                                Text(bar.label)
                                Spacer(minLength: 8)
                                Text(barRemainder(bar))
                                    .monospacedDigit()
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        Meter(used: bar.usedPercent, accent: Accent.color(for: provider.id))
                    }
                }
            }
            .padding(.leading, 14)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private var amount: String {
        if provider.tone == .loading { return "…" }
        if provider.tone != .ready { return "—" }
        if provider.id != "cursor", provider.headline.contains("$") {
            return provider.headline.replacingOccurrences(of: " left", with: "")
        }
        if let used = primaryBar?.usedPercent {
            return Format.percent(max(0, 100 - used))
        }
        if let week = provider.chips.first(where: { $0.id == "week" }) {
            return week.value
        }
        return provider.headline
    }

    private var primaryBar: MeterBar? {
        if provider.id == "cursor" {
            return provider.bars.first { $0.id == "week" || $0.id == "auto" } ?? provider.bars.first
        }
        return provider.bars.first
    }

    private var showsBarLabels: Bool {
        provider.id == "cursor" || provider.id == "claude" || provider.id == "openai" || provider.id == "gemini"
    }

    private var listBars: [MeterBar] {
        switch provider.id {
        case "cursor":
            let order = ["week", "auto", "included"]
            return order.compactMap { id in provider.bars.first { $0.id == id } }
        case "claude":
            let order = ["session", "five", "weekly_all", "week", "api"]
            return provider.bars
                .filter { order.contains($0.id) }
                .sorted { (order.firstIndex(of: $0.id) ?? 9) < (order.firstIndex(of: $1.id) ?? 9) }
        case "gemini":
            let order = ["session", "week"]
            return order.compactMap { id in provider.bars.first { $0.id == id } }
        case "openai":
            return provider.bars.sorted { lhs, rhs in
                (lhs.label == "Week" ? 1 : 0) < (rhs.label == "Week" ? 1 : 0)
            }
        default:
            return Array(provider.bars.prefix(1))
        }
    }

    private func barRemainder(_ bar: MeterBar) -> String {
        if bar.id == "api" { return bar.detail }
        let left = "\(Format.percent(max(0, 100 - bar.usedPercent))) left"
        if bar.detail.hasPrefix("in ") || bar.detail == "just reset" {
            return "\(left) · \(bar.detail)"
        }
        return left
    }

    private var amountColor: Color {
        guard let used = primaryBar?.usedPercent else { return .primary }
        if used >= 90 { return .red }
        if used >= 75 { return .orange }
        return .primary
    }

    private var caption: String {
        if provider.tone == .loading { return "Loading" }
        if let warning = provider.warning, !warning.isEmpty { return warning }
        if provider.tone != .ready {
            return provider.note ?? "No data"
        }
        var bits: [String] = []
        let plan =
            provider.plan.split(separator: "·").first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if !plan.isEmpty, plan != "Local" {
            bits.append(plan)
        }
        let labeled = showsBarLabels
        if !labeled, let hot = provider.bars.dropFirst().first(where: { $0.usedPercent >= 99 }) {
            bits.append("\(hot.label) maxed")
        } else if !labeled, let detail = provider.bars.first?.detail, !detail.isEmpty {
            bits.append(detail)
        } else if provider.bars.isEmpty, let week = provider.chips.first(where: { $0.id == "week" }) {
            bits.append("\(week.hint) in 7 days")
        }
        return bits.joined(separator: " · ")
    }
}

private struct DetailView: View {
    @EnvironmentObject private var store: UsageStore
    let provider: ProviderSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                    .font(.title3.weight(.semibold))
                if !provider.plan.isEmpty {
                    Text(provider.plan)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if provider.tone == .ready {
                Text(provider.headline)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(headlineColor)
            }

            if provider.tone != .ready, let note = provider.note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if provider.id == "claude", provider.connection == .keychainPermission {
                    Button("Allow access") {
                        store.allowClaudeKeychain()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            if !provider.bars.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(provider.bars) { bar in
                        DetailMeter(bar: bar, accent: Accent.color(for: provider.id))
                    }
                }
            }

            if !provider.chips.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(provider.chips) { chip in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chip.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(chip.value)
                                .font(.headline.monospacedDigit())
                            Text(chip.hint)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            if !provider.lines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(provider.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if provider.tone == .ready, let note = provider.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let warning = provider.warning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headlineColor: Color {
        guard let used = provider.bars.first?.usedPercent else { return .primary }
        if used >= 90 { return .red }
        if used >= 75 { return .orange }
        return .primary
    }
}

private struct DetailMeter: View {
    let bar: MeterBar
    let accent: Color

    var body: some View {
        let left = max(0, min(100, 100 - bar.usedPercent))
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(bar.label)
                    .font(.subheadline)
                Spacer(minLength: 8)
                Text("\(Format.percent(left)) left")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Meter(used: bar.usedPercent, accent: accent)
            if !bar.detail.isEmpty {
                Text(bar.detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct Meter: View {
    @EnvironmentObject private var store: UsageStore
    @EnvironmentObject private var presentation: PanelPresentation
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    let used: Double
    let accent: Color

    private var reduceMotion: Bool { systemReduceMotion || !store.preferences.animatesPanel }

    var body: some View {
        let clamped = reduceMotion || presentation.isPresented ? min(max(used, 0), 100) : 0
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(fill)
                    .frame(width: max(clamped > 0 ? 4 : 0, geo.size.width * clamped / 100))
            }
        }
        .frame(height: 6)
        .animation(reduceMotion ? nil : .smooth(duration: 0.55).delay(0.10), value: presentation.isPresented)
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: used)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Used")
        .accessibilityValue(Format.percent(used))
    }

    private var fill: Color {
        if used >= 90 { return .red }
        if used >= 75 { return .orange }
        return accent
    }
}

private struct RowButtonStyle: ButtonStyle {
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : hovered ? 0.05 : 0))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
            )
            .onHover { hovered = $0 }
    }
}

private enum Glass {
    static let width: CGFloat = 328
    static let radius: CGFloat = 22
    static let inset: CGFloat = 14
}

private struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

enum Accent {
    static func color(for id: String) -> Color {
        switch id {
        case "grok": return Color(red: 0.62, green: 0.54, blue: 0.42)
        case "grok-bot": return Color(red: 0.70, green: 0.58, blue: 0.86)
        case "cursor": return Color(red: 0.45, green: 0.62, blue: 0.98)
        case "openai": return Color(red: 0.36, green: 0.72, blue: 0.48)
        case "claude": return Color(red: 0.86, green: 0.48, blue: 0.34)
        case "gemini": return Color(red: 0.33, green: 0.53, blue: 0.96)
        case "opencode": return Color(red: 0.28, green: 0.70, blue: 0.70)
        default: return Color.primary
        }
    }
}
