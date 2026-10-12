import AppKit
import Combine
import SwiftUI

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--print") {
            let group = DispatchGroup()
            group.enter()
            Task.detached {
                let snapshots = await UsageService().load()
                for snapshot in snapshots {
                    print(snapshot.debugSummary)
                }
                group.leave()
            }
            group.wait()
            return
        }
        let application = NSApplication.shared
        let delegate = UsoDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
enum SharedStore {
    static let store = UsageStore()
}

enum AppExit {
    nonisolated(unsafe) static var requested = false
}

@MainActor
final class UsagePanelWindow: NSWindow {
    var onEscape: (() -> Void)?
    var onRefresh: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            onEscape?()
            return true
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.charactersIgnoringModifiers?.lowercased() == "r"
        {
            onRefresh?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class UsoDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: NSWindow?
    private var settingsWindow: NSWindow?
    private var titleWatcher: AnyCancellable?
    private var suppressToggle = false
    private let presentation = PanelPresentation()
    private var presentationGeneration = 0
    private let centered = CommandLine.arguments.contains("--panel")

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppExit.requested ? .terminateNow : .terminateCancel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationMenu()
        SharedStore.store.activate()
        installStatusItem()
        if CommandLine.arguments.contains("--settings") {
            NSApp.setActivationPolicy(.regular)
            showSettings()
        } else if centered {
            NSApp.setActivationPolicy(.regular)
            showPanel()
        }
    }

    private func installApplicationMenu() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Uso")
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        applicationMenu.addItem(settings)
        applicationMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Uso", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        applicationMenu.addItem(quit)
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
    }

    @objc private func quitApplication() {
        AppExit.requested = true
        NSApp.terminate(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if settingsWindow?.isVisible == true {
            settingsWindow?.makeKeyAndOrderFront(nil)
        } else if panel?.isVisible == true {
            panel?.makeKeyAndOrderFront(nil)
        } else {
            showPanel()
        }
        return false
    }

    @objc private func showSettings() {
        hidePanel()
        SharedStore.store.refresh()
        let window: NSWindow
        if let existing = settingsWindow {
            window = existing
        } else {
            let settings = UsagePanelWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 660),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
            )
            settings.title = "Uso Settings"
            settings.identifier = NSUserInterfaceItemIdentifier("uso-settings")
            settings.isReleasedWhenClosed = false
            settings.minSize = NSSize(width: 520, height: 440)
            settings.contentView = NSHostingView(rootView: SettingsView().environmentObject(SharedStore.store))
            settings.onEscape = { [weak settings] in settings?.performClose(nil) }
            settings.onRefresh = { SharedStore.store.refresh(force: true) }
            settings.center()
            settingsWindow = settings
            window = settings
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "UsoUsage"
        item.isVisible = true
        let button = item.button
        button?.image = Self.markImage()
        button?.imagePosition = .imageLeading
        button?.target = self
        button?.action = #selector(togglePanel)
        statusItem = item
        applyTitle(SharedStore.store.menuTitle)
        titleWatcher = SharedStore.store.$menuTitle.sink { [weak self] title in
            self?.applyTitle(title)
        }
    }

    private func applyTitle(_ title: String) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusItem?.button?.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ]
        )
    }

    @objc private func togglePanel() {
        if suppressToggle || panel?.isVisible == true {
            hidePanel()
            return
        }
        showPanel()
    }

    private func showPanel() {
        SharedStore.store.refresh()
        let window = panel ?? makePanel()
        panel = window
        presentationGeneration += 1
        let generation = presentationGeneration
        let reduceMotion =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !SharedStore.store.preferences.animatesPanel
        presentation.prepare(reduceMotion: reduceMotion)
        resize(window)
        if centered {
            center(window)
        } else {
            placeUnderStatusItem(window)
        }
        window.alphaValue = reduceMotion ? 1 : 0
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.contentView?.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.025)) { [weak self, weak window] in
            guard let self, let window, window.isVisible, self.presentationGeneration == generation else { return }
            self.presentation.reveal()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0 : 0.16
                window.animator().alphaValue = 1
            }
        }
        for delay in [0.3, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
                guard let self, let window, window.isVisible, self.presentationGeneration == generation else { return }
                self.resize(window)
                if self.centered {
                    self.center(window)
                } else {
                    self.placeUnderStatusItem(window)
                }
            }
        }
    }

    private func hidePanel() {
        presentationGeneration += 1
        panel?.orderOut(nil)
    }

    private func resizePanel(animated: Bool) {
        guard let panel, panel.isVisible else { return }
        resize(panel, animated: animated)
        if centered { center(panel) } else { placeUnderStatusItem(panel) }
    }

    private func makePanel() -> NSWindow {
        let content = NSHostingView(
            rootView: PanelView(
                dismiss: { [weak self] in self?.hidePanel() },
                openSettings: { [weak self] in self?.showSettings() },
                layoutChanged: { [weak self] animated in self?.resizePanel(animated: animated) }
            ).environmentObject(SharedStore.store).environmentObject(presentation))
        content.sizingOptions = .intrinsicContentSize
        let window = UsagePanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 328, height: 420),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("uso-panel")
        window.title = "Usage"
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar
        window.hidesOnDeactivate = !centered
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.isMovableByWindowBackground = true
        window.contentView = content
        window.onEscape = { [weak self] in
            self?.presentation.escape()
        }
        window.onRefresh = { SharedStore.store.refresh(force: true) }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.centered else { return }
                self.suppressToggle = true
                self.hidePanel()
                DispatchQueue.main.async {
                    self.suppressToggle = false
                }
            }
        }
        return window
    }

    private func resize(_ window: NSWindow, animated: Bool = false) {
        guard let content = window.contentView else { return }
        content.invalidateIntrinsicContentSize()
        let intrinsic = content.intrinsicContentSize.height
        let height = intrinsic > 1 ? intrinsic : content.fittingSize.height
        let size = NSSize(width: 328, height: max(height, 200))
        guard abs(window.frame.height - size.height) > 0.5 else { return }
        let frame = NSRect(
            x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width, height: size.height)
        window.setFrame(
            frame, display: true,
            animate: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                && SharedStore.store.preferences.animatesPanel)
    }

    private func center(_ window: NSWindow) {
        guard let visible = NSScreen.main?.visibleFrame else {
            window.center()
            return
        }
        let size = window.frame.size
        window.setFrameOrigin(
            NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2
            ))
    }

    private func placeUnderStatusItem(_ window: NSWindow) {
        guard let buttonWindow = statusItem?.button?.window else {
            window.center()
            return
        }
        let anchor = buttonWindow.frame
        let size = window.frame.size
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 6)
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let bounds = screen.visibleFrame
            origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
        }
        window.setFrameOrigin(origin)
    }

    private static func markImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 15, height: 8), flipped: false) { _ in
            NSColor.white.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 2.5, width: 15, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 2.5, width: 10, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
