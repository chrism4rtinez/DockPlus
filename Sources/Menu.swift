import Cocoa
import ServiceManagement

// MARK: - Menu bar

extension DockPlus: NSMenuDelegate {
    func setUpMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self // rebuilt each time it opens, so permission status is current
        item.menu = menu
        statusItem = item
        updateStatusIcon(needsAttention: false)
    }

    /// The app icon's glyph (a Dock outline with a plus above a bar), drawn as a template
    /// image so macOS colors it for a light or dark menu bar. The numbers are the glyph's
    /// measurements in Icon/AppIcon-1024.png before it was scaled onto its tile: an 824 x 650
    /// shape with its top-left corner at (100, 187).
    private static let menuBarIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: true) { rect in
            let scale = rect.width / 824
            let transform = NSAffineTransform()
            transform.translateX(by: 0, yBy: (rect.height - 650 * scale) / 2)
            transform.scale(by: scale)
            transform.translateX(by: -100, yBy: -187)
            transform.concat()
            NSColor.black.set()
            let outline = NSBezierPath(roundedRect: NSRect(x: 133, y: 220, width: 758, height: 584),
                                       xRadius: 117, yRadius: 117)
            outline.lineWidth = 66
            outline.stroke()
            NSBezierPath(roundedRect: NSRect(x: 400, y: 397, width: 224, height: 64), xRadius: 32, yRadius: 32).fill()
            NSBezierPath(roundedRect: NSRect(x: 480, y: 317, width: 64, height: 224), xRadius: 32, yRadius: 32).fill()
            NSBezierPath(roundedRect: NSRect(x: 259, y: 605, width: 509, height: 109), xRadius: 28, yRadius: 28).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "DockPlus"
        return image
    }()

    /// The menu bar icon is the app icon's glyph. It becomes a warning symbol while DockPlus
    /// can't work: setup isn't finished, Accessibility isn't allowed, or the event tap couldn't
    /// be created.
    func updateStatusIcon(needsAttention: Bool) {
        guard let button = statusItem?.button else { return }
        let description = needsAttention ? "DockPlus needs attention" : "DockPlus"
        if !needsAttention {
            button.image = Self.menuBarIcon
            button.title = ""
        } else if let image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: description) {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "Dock+ !"
        }
        button.toolTip = description
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let trusted = AXIsProcessTrusted()
        let canCapture = CGPreflightScreenCaptureAccess()

        // What needs fixing comes first.
        if !setupComplete {
            menu.addItem(actionItem("Finish Setting Up DockPlus…", #selector(openSetup)))
            menu.addItem(.separator())
        } else if !trusted {
            menu.addItem(infoItem("DockPlus is off: it needs Accessibility"))
            menu.addItem(actionItem("Allow Accessibility…", #selector(openSetupPermissions)))
            menu.addItem(.separator())
        } else if tapFailed {
            menu.addItem(infoItem("DockPlus can't see Dock clicks. Try quitting and reopening it."))
            menu.addItem(.separator())
        }
        if !SPI.enabled {
            menu.addItem(infoItem("Limited mode: untested macOS version"))
            menu.addItem(.separator())
        }

        menu.addItem(toggleItem("Double-click icon: minimize / restore window", key: "doubleClickToggle"))
        menu.addItem(toggleItem("Hover icon: show all windows", key: "hoverPreviews"))
        menu.addItem(lifetimeMenu())
        menu.addItem(.separator())

        // Permission status. Each row opens the place to change it.
        menu.addItem(actionItem(trusted ? "Accessibility: Allowed" : "Accessibility: Not allowed",
                                #selector(openAccessibilitySettings),
                                state: trusted ? .on : .off))
        menu.addItem(actionItem(canCapture ? "Screen Recording: Allowed"
                                           : "Screen Recording: Not allowed (no thumbnails)",
                                #selector(openScreenRecordingSettings),
                                state: canCapture ? .on : .off))
        menu.addItem(.separator())

        let login = actionItem("Open at Login", #selector(toggleLogin(_:)))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        if setupComplete {
            menu.addItem(actionItem("Setup Guide…", #selector(openSetup)))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DockPlus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector, state: NSControl.StateValue = .off) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = state
        return item
    }

    private func toggleItem(_ title: String, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(toggleSetting(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = key
        item.state = defaults.bool(forKey: key) ? .on : .off
        return item
    }

    @objc private func toggleSetting(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        setSetting(key, !defaults.bool(forKey: key))
    }

    /// Changes one of the two feature settings, from the menu or the setup window.
    func setSetting(_ key: String, _ value: Bool) {
        defaults.set(value, forKey: key)
        if key == "hoverPreviews" && !value {
            preview.hide()
            preview.thumbnails.removeAll() // no window pictures are kept while previews are off
        }
    }

    func isSettingOn(_ key: String) -> Bool { defaults.bool(forKey: key) }

    var thumbnailLifetime: Int { defaults.integer(forKey: "thumbnailLifetime") }

    /// How long window pictures are kept. A shorter time drops older pictures right away.
    func setThumbnailLifetime(_ seconds: Int) {
        defaults.set(seconds, forKey: "thumbnailLifetime")
        preview.thumbnails.removeExpired()
    }

    private func lifetimeMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Keep preview thumbnails for…", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for choice in ThumbnailCache.lifetimes {
            let option = actionItem(choice.title, #selector(chooseLifetime(_:)),
                                    state: choice.seconds == thumbnailLifetime ? .on : .off)
            option.tag = choice.seconds
            submenu.addItem(option)
        }
        item.submenu = submenu
        item.isEnabled = defaults.bool(forKey: "hoverPreviews") // no pictures are kept otherwise
        return item
    }

    @objc private func chooseLifetime(_ sender: NSMenuItem) { setThumbnailLifetime(sender.tag) }

    @objc private func openSetup() { showSetup(.welcome) }
    @objc private func openSetupPermissions() { showSetup(.setup) }
    @objc private func openAccessibilitySettings() { requestAccessibility() }
    @objc private func openScreenRecordingSettings() { requestScreenRecording() }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        setOpenAtLogin(SMAppService.mainApp.status != .enabled)
    }

    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    /// Registers or removes the login item. macOS can require the user to approve it in
    /// System Settings first; then that page is opened, and any other failure is shown.
    func setOpenAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Never interpolate into NSLog's format string; pass values as arguments.
            NSLog("DockPlus: could not change login item: %@", error as NSError)
            if SMAppService.mainApp.status != .requiresApproval {
                let alert = NSAlert()
                alert.messageText = on ? "DockPlus couldn't be set to open at login."
                                       : "DockPlus couldn't be removed from your login items."
                alert.informativeText = "You can change this in System Settings › General › Login Items."
                NSApp.activate()
                alert.runModal()
            }
        }
        if on && SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
