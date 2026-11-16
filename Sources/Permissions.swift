import Cocoa
import ApplicationServices

// MARK: - Permissions and setup

extension DockPlus {
    var setupComplete: Bool { defaults.bool(forKey: "setupComplete") }

    /// Runs every 2 seconds and after each setup step. Starts DockPlus once it may run, stops
    /// it as soon as Accessibility is taken away, and keeps the menu bar icon and the setup
    /// window in step with what macOS reports.
    func checkPermissions() {
        let trusted = AXIsProcessTrusted()
        if trusted && setupComplete {
            start()
            if tapFailed { // try again; it can fail right after Accessibility is allowed
                tapFailed = false
                installEventTap()
            }
        } else if started {
            stop()
        }
        // Thumbnails were captured under Screen Recording. If it's taken away, drop them too.
        let canCapture = CGPreflightScreenCaptureAccess()
        if couldCapture && !canCapture {
            preview.hide()
            preview.thumbnails.removeAll()
        }
        couldCapture = canCapture
        preview.thumbnails.removeExpired()
        updateStatusIcon(needsAttention: !trusted || !setupComplete || tapFailed)
        setup?.refresh()
    }

    func showSetup(_ page: SetupWindow.Page) {
        if let setup {
            setup.go(to: page)
        } else {
            setup = SetupWindow(app: self, page: page)
        }
        setup?.show()
    }

    func setupFinished() {
        defaults.set(true, forKey: "setupComplete")
        setup = nil
        checkPermissions()
    }

    func setupClosed() {
        setup = nil
    }

    /// Shows the system's Accessibility prompt, which adds DockPlus to the list in System
    /// Settings. If that was already shown in this session, opens the list directly.
    func requestAccessibility() {
        if promptedForAccessibility || AXIsProcessTrusted() {
            openPrivacyPane("Privacy_Accessibility")
        } else {
            promptedForAccessibility = true
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    /// macOS shows the Screen Recording prompt only once per app, ever. After that, the only
    /// way to allow it is in System Settings, so open that instead.
    func requestScreenRecording() {
        if defaults.bool(forKey: "requestedScreenRecording") || CGPreflightScreenCaptureAccess() {
            openPrivacyPane("Privacy_ScreenCapture")
        } else {
            defaults.set(true, forKey: "requestedScreenRecording")
            _ = CGRequestScreenCaptureAccess()
        }
    }

    func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// True if DockPlus was used under its old bundle ID, so System Settings may still list an
    /// old DockPlus entry with permissions it no longer needs.
    var hasLegacyInstall: Bool { defaults.persistentDomain(forName: "local.dockplus") != nil }

    /// Copies settings saved under the old bundle ID, local.dockplus. Never overwrites a
    /// setting saved under the current ID, so it's safe on every launch. Must run before
    /// defaults are registered. (Accessibility, Screen Recording and Open at Login are tied
    /// to the ID by macOS and can't be carried over.)
    func migrateLegacySettings() {
        guard let old = defaults.persistentDomain(forName: "local.dockplus") else { return }
        for key in ["doubleClickToggle", "hoverPreviews"] where defaults.object(forKey: key) == nil {
            if let value = old[key] { defaults.set(value, forKey: key) }
        }
    }
}
