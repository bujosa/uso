import AppKit
import Foundation

enum MuseAppIntegration {
    static func load() -> ProviderSnapshot {
        let installed = [URL(fileURLWithPath: "/Applications/Muse.app"), Paths.file("Applications", "Muse.app")]
            .contains { Bundle(url: $0)?.bundleIdentifier == "com.meta.endo" }
        return .problem(
            id: "muse-app", name: "Muse", tone: .missing,
            note: installed
                ? "Muse is installed. View its account and usage in Muse. App quota detection is not available yet."
                : "Install the Muse app to view its account and usage. App quota detection is not available yet."
        )
    }

    @MainActor
    static func open() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.meta.endo") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init(), completionHandler: nil)
        } else {
            NSWorkspace.shared.open(URL(string: "https://ai.meta.com/muse/")!)
        }
    }
}
