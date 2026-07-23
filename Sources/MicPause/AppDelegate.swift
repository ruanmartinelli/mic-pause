import AppKit
import MicPauseCore
import os.log
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, MicMonitorDelegate {
    private enum DefaultsKey {
        static let enabled = "enabled"
        static let autoResume = "autoResume"
    }

    private static let resumeDebounceInterval: TimeInterval = 1.5

    private let monitor = MicMonitor()
    private let playback = PlaybackController()
    private let resumeDebouncer = Debouncer()
    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: "com.ruan.MicPause", category: "App")

    private var statusItem: NSStatusItem!
    private var statusLineItem: NSMenuItem!
    private var enabledItem: NSMenuItem!
    private var autoResumeItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!

    private var isEnabled: Bool { defaults.bool(forKey: DefaultsKey.enabled) }
    private var isAutoResumeEnabled: Bool { defaults.bool(forKey: DefaultsKey.autoResume) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [
            DefaultsKey.enabled: true,
            DefaultsKey.autoResume: true,
        ])

        setUpStatusItem()

        playback.onAccessibilityPermissionNeeded = { [weak self] in
            self?.showAccessibilityAlert()
        }

        monitor.delegate = self
        monitor.start()
        updateUI()
    }

    // MARK: - Mic events

    func micStateDidChange(active: Bool) {
        if active {
            resumeDebouncer.cancel()
            guard isEnabled else {
                updateUI()
                return
            }
            playback.pauseIfPlaying { [weak self] _ in
                self?.updateUI()
            }
        } else {
            // Debounce the resume: apps often release/reacquire the device briefly
            // (Zoom joining, AirPods switching, Siri). A new ACTIVE cancels this.
            resumeDebouncer.schedule(after: Self.resumeDebounceInterval) { [weak self] in
                guard let self else { return }
                if self.isAutoResumeEnabled {
                    self.playback.resumeIfPaused { _ in self.updateUI() }
                } else {
                    self.playback.clearPausedState()
                    self.updateUI()
                }
            }
        }
        updateUI()
    }

    // MARK: - Menu

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()

        statusLineItem = NSMenuItem(title: "Mic: idle", action: nil, keyEquivalent: "")
        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)
        menu.addItem(.separator())

        enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        menu.addItem(enabledItem)

        autoResumeItem = NSMenuItem(title: "Auto-resume when mic is free",
                                    action: #selector(toggleAutoResume), keyEquivalent: "")
        autoResumeItem.target = self
        menu.addItem(autoResumeItem)

        launchAtLoginItem = NSMenuItem(title: "Launch at Login",
                                       action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())

        let grantItem = NSMenuItem(title: "Grant Permissions…",
                                   action: #selector(grantPermissions), keyEquivalent: "")
        grantItem.target = self
        menu.addItem(grantItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit MicPause", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func toggleEnabled() {
        defaults.set(!isEnabled, forKey: DefaultsKey.enabled)
        if !isEnabled {
            resumeDebouncer.cancel()
            playback.clearPausedState()
        }
        updateUI()
    }

    @objc private func toggleAutoResume() {
        defaults.set(!isAutoResumeEnabled, forKey: DefaultsKey.autoResume)
        updateUI()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            logger.error("Launch at Login toggle failed: \(error, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "Run MicPause from a proper app bundle (e.g. /Applications/MicPause.app) "
                + "to use Launch at Login.\n\n\(error.localizedDescription)"
            alert.runModal()
        }
        updateUI()
    }

    @objc private func grantPermissions() {
        NSApp.activate(ignoringOtherApps: true)
        let status = playback.requestPermissions()

        let alert = NSAlert()
        if status.promptableRunningPlayers.isEmpty {
            alert.messageText = "Open Spotify or Music first"
            alert.informativeText = "To grant permission to pause them, launch Spotify or Apple Music, "
                + "then choose “Grant Permissions…” again. macOS only shows the “control” prompt while "
                + "the player is running.\n\nIf an Accessibility prompt appeared, approve that now to allow "
                + "pausing browsers and other players."
        } else {
            let names = status.promptableRunningPlayers.map(\.displayName).joined(separator: " and ")
            alert.messageText = "Approve the permission prompts"
            alert.informativeText = "macOS should be asking to let MicPause control \(names). Click OK on "
                + "each prompt.\n\nIf an Accessibility prompt also appeared, approve it to allow pausing "
                + "browsers and other players. You only need to do this once."
        }
        alert.runModal()
        updateUI()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - UI state

    private func updateUI() {
        let micActive = monitor.isMicActive
        let paused = playback.pausedSource

        if micActive {
            let apps = monitor.activeCaptureBundleIDs
                .map { $0.components(separatedBy: ".").last ?? $0 }
                .joined(separator: ", ")
            let by = apps.isEmpty ? "" : " by \(apps)"
            if !isEnabled {
                statusLineItem.title = "Mic: in use\(by) (MicPause disabled)"
            } else if let paused {
                statusLineItem.title = "Mic: in use\(by) — paused \(paused.displayName)"
            } else {
                statusLineItem.title = "Mic: in use\(by)"
            }
        } else {
            statusLineItem.title = "Mic: idle"
        }

        enabledItem.state = isEnabled ? .on : .off
        autoResumeItem.state = isAutoResumeEnabled ? .on : .off
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        let symbolNames: [String]
        if paused != nil {
            symbolNames = ["mic.badge.pause", "mic.slash.fill"]
        } else if micActive {
            symbolNames = ["mic.fill"]
        } else {
            symbolNames = ["mic"]
        }
        statusItem.button?.image = firstAvailableSymbol(symbolNames)
        statusItem.button?.appearsDisabled = !isEnabled
    }

    private func firstAvailableSymbol(_ names: [String]) -> NSImage? {
        for name in names {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: "MicPause") {
                image.isTemplate = true
                return image
            }
        }
        return nil
    }

    // MARK: - Permissions

    private var didShowAccessibilityAlert = false

    private func showAccessibilityAlert() {
        guard !didShowAccessibilityAlert else { return }
        didShowAccessibilityAlert = true

        let alert = NSAlert()
        alert.messageText = "MicPause needs Accessibility permission"
        alert.informativeText = "To pause media players via the system play/pause key, enable MicPause in "
            + "System Settings → Privacy & Security → Accessibility, then try again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
