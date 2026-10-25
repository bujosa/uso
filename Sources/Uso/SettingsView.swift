import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: UsageStore
    @State private var section = Section.accounts

    private enum Section: Hashable { case accounts, general }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                        .resizable().frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Make Uso yours").font(.title2.weight(.semibold))
                        Text("Your accounts, plans, and what you see.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Picker("Settings section", selection: $section) {
                    Text("Accounts & plans").tag(Section.accounts)
                    Text("General").tag(Section.general)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(24)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if section == .accounts { accounts } else { general }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text("Saved automatically").foregroundStyle(.secondary)
                Spacer()
                Text("Uso \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .padding(.horizontal, 24).padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 520, minHeight: 440)
    }

    private var accounts: some View {
        Group {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.isRefreshing ? "Checking your accounts…" : detectionSummary)
                        .font(.headline)
                    Text(
                        "Uso shows the services signed in on this Mac. Switch any source on or off; your choice sticks."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    store.refresh(force: true)
                } label: {
                    if store.isRefreshing { ProgressView().controlSize(.small) } else { Text("Check now") }
                }
                .disabled(store.isRefreshing)
                .accessibilityLabel("Check accounts now")
            }
            HStack {
                let panelCount = ProviderAccount.all.filter { store.showsInPanel($0.id) }.count
                let menuCount = ProviderAccount.all.filter { store.showsInMenu($0.id) }.count
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(panelCount) in panel · \(menuCount) in menu bar")
                    if store.updatedAt != nil { Text("Last checked \(store.updatedLabel)") }
                }
                .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show detected only") { store.showDetectedOnly() }
                    .buttonStyle(.link)
                    .disabled(store.isRefreshing || store.providers.isEmpty)
            }
            ForEach(ProviderAccount.all) { account in
                AccountSettingsRow(
                    account: account,
                    snapshot: store.providers.first { $0.id == account.id }
                        ?? .loading(id: account.id, name: account.name)
                )
            }
            Text(
                "Manage account opens the service's website. Your plans and sign-ins stay with each service; Uso saves your display choices."
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var detectionSummary: String {
        let count = ProviderAccount.all.filter { store.isDetected($0.id) }.count
        if count == 0 { return "No sources verified yet" }
        return "\(count) \(count == 1 ? "source" : "sources") detected"
    }

    private var general: some View {
        Group {
            settingsCard {
                Text("Startup").font(.headline)
                Toggle(
                    "Open Uso at login",
                    isOn: Binding(
                        get: { store.opensAtLogin }, set: { store.setOpensAtLogin($0) }
                    )
                )
                .disabled(!store.showsLoginToggle)
                Text("Keep your usage a click away in the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = store.loginMessage {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
            settingsCard {
                Text("Appearance").font(.headline)
                Toggle(
                    "Animate panel opening",
                    isOn: Binding(
                        get: { store.preferences.animatesPanel }, set: { store.setAnimatesPanel($0) }
                    ))
                Text("A soft spring, staggered rows, and a light sweep. macOS Reduce Motion always takes priority.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            settingsCard {
                Text("Display choices").font(.headline)
                Text("Show every supported source in both the panel and menu bar, even ones not found on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show all sources") { store.showAllSources() }
            }
            Label(
                "Accounts are checked every 3 minutes. Check now requests a fresh reading when the service allows it.",
                systemImage: "arrow.clockwise"
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
    }
}

private struct AccountSettingsRow: View {
    @EnvironmentObject private var store: UsageStore
    let account: ProviderAccount
    let snapshot: ProviderSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(Accent.color(for: account.id)).frame(width: 9, height: 9).padding(.top, 5)
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.name).font(.headline)
                    Text(planDescription).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(status).font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(statusColor.opacity(0.10)))
            }
            if let message = snapshot.warning ?? (snapshot.tone == .failed ? snapshot.note : nil) {
                Text(message).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if snapshot.tone == .missing {
                Text(snapshot.note ?? account.signInHint).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if account.id == "grok-bot", snapshot.tone == .ready {
                Text("Uses the same account as Cursor. Its weekly allowance is separate from Grok Build.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let readAt = snapshot.readAt {
                let time = readAt.formatted(
                    date: Calendar.current.isDateInToday(readAt) ? .omitted : .abbreviated, time: .shortened)
                Text("Last reading at \(time)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                Toggle(
                    "Panel",
                    isOn: Binding(
                        get: { store.showsInPanel(account.id) },
                        set: { store.setShownInPanel($0, id: account.id) }
                    )
                )
                .accessibilityLabel("Show \(account.name) in panel")
                Toggle(
                    "Menu bar",
                    isOn: Binding(
                        get: { store.showsInMenu(account.id) },
                        set: { store.setShownInMenu($0, id: account.id) }
                    )
                )
                .accessibilityLabel("Show \(account.name) in menu bar")
                Spacer(minLength: 0)
                if account.id == "claude", snapshot.connection == .keychainPermission {
                    Button("Allow access") { store.allowClaudeKeychain() }
                } else {
                    Button("Manage account") { NSWorkspace.shared.open(account.accountURL) }
                        .accessibilityLabel("Manage \(account.name) account")
                }
            }
            .toggleStyle(.switch).controlSize(.mini).font(.caption)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
    }

    private var planDescription: String {
        if snapshot.tone == .loading { return "Looking for a signed-in account" }
        if account.id == "claude", snapshot.connection == .keychainPermission {
            return "Allow access to verify your plan"
        }
        if snapshot.plan == "Local" { return "Local activity · no plan quota" }
        if !snapshot.plan.isEmpty {
            return snapshot.warning == nil ? snapshot.plan : "Last detected: \(snapshot.plan)"
        }
        return snapshot.tone == .missing ? "No verified plan yet" : "Plan could not be verified"
    }

    private var status: String {
        if snapshot.warning != nil { return "Needs refresh" }
        if snapshot.tone != .loading, let connection = snapshot.connection {
            switch connection {
            case .unverified: return "Not verified"
            case .keychainPermission: return "Access needed"
            case .signInRequired: return "Sign in needed"
            }
        }
        switch snapshot.tone {
        case .ready: return snapshot.plan == "Local" ? "Local" : "Detected"
        case .loading: return "Checking"
        case .missing: return "Not connected"
        case .failed: return "Couldn't check"
        }
    }

    private var statusColor: Color {
        if snapshot.warning != nil || snapshot.connection == .signInRequired { return .orange }
        switch snapshot.tone {
        case .ready: return snapshot.plan == "Local" ? .secondary : .green
        case .loading: return .secondary
        case .missing: return .secondary
        case .failed: return .orange
        }
    }

}
