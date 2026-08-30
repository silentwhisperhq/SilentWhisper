import AppKit
import Combine
import SwiftUI

@main
enum SilentWhisperApp {
    static func main() {
        if CommandLine.arguments.contains("--selftest") { runSelfTest(); return }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no dock icon, no menu bar takeover
        app.run()
    }
}

/// Right ⌥. Held down = recording, released = transcribe.
private let pushToTalkKey: UInt16 = 61

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = Engine()
    private let updater = Updater()
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var monitors: [Any] = []
    private var stateWatch: AnyCancellable?

    func applicationDidFinishLaunching(_: Notification) {
        // Both the global hotkey and the auto-paste need this. Ask once, up front.
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)

        buildPanel()
        buildStatusItem()
        updater.startPeriodicChecks()

        // Lets a test instance land straight on the pane that is being measured.
        if CommandLine.arguments.contains("--settings") { openSettings() }
        // After the state watcher below is subscribed, or the reveal never fires.
        if Engine.demo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.engine.startDemo()
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.refreshMotionPreference() }
        }

        // The blob is only ever on screen while something is happening: it fades in on
        // the hotkey and fades out again once the text has landed.
        stateWatch = engine.$state
            .map { $0 != .idle }
            .removeDuplicates()
            .sink { [weak self] busy in self?.reveal(busy) }

        for mask in [NSEvent.EventTypeMask.flagsChanged] {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
                Task { @MainActor in self?.handle(e) }
            }) { monitors.append(m) }
            if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
                self?.handle(e); return e
            }) { monitors.append(m) }
        }
    }

    private func handle(_ e: NSEvent) {
        guard e.keyCode == pushToTalkKey else { return }
        e.modifierFlags.contains(.option) ? engine.startRecording() : engine.stopRecording()
    }

    // MARK: - the floating pill

    private func buildPanel() {
        let size = NSSize(width: 220, height: 120)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: PillView().environmentObject(engine))
        panel.alphaValue = 0
    }

    /// Fades the blob in over whatever you're working in, and back out when it's done.
    private func reveal(_ show: Bool) {
        if show, !panel.isVisible {
            recentre()
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = engine.calmMotion ? 0 : (show ? 0.22 : 0.45)
            ctx.timingFunction = CAMediaTimingFunction(name: show ? .easeOut : .easeIn)
            panel.animator().alphaValue = show ? 1 : 0
        } completionHandler: { [weak self] in
            // Always delivered on the main thread by AppKit.
            MainActor.assumeIsolated {
                guard let self, !show, self.engine.state == .idle else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    /// Bottom centre of whichever screen the pointer is on, clear of the Dock.
    private func recentre() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? .main
        guard let f = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY + 28))
    }

    // MARK: - status menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.hexagongrid.fill",
                                           accessibilityDescription: "Silent Whisper")

        let menu = NSMenu()
        let banner = Updater.isDevBuild
            ? "Silent Whisper \(updater.currentVersion) beta · by Claude"
            : "Silent Whisper \(updater.currentVersion)"
        menu.addItem(withTitle: banner, action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Hold right ⌥ to talk", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Silent Whisper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: .zero,
                                  styleMask: [.titled, .closable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Silent Whisper"
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false

            // The blur has to come from a real NSVisualEffectView: SwiftUI materials only
            // sample within the window, so they cannot pick up the desktop behind it.
            let glass = NSVisualEffectView()
            glass.material = .hudWindow
            glass.blendingMode = .behindWindow
            glass.state = .active

            let host = NSHostingView(rootView: SettingsView()
                .environmentObject(engine)
                .environmentObject(updater)
                .environmentObject(AIPass.shared))
            let size = NSSize(width: 400, height: 620)
            host.autoresizingMask = [.width, .height]
            host.frame = NSRect(origin: .zero, size: size)
            glass.frame = host.frame
            glass.addSubview(host)

            window.contentView = glass
            window.setContentSize(size)
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
