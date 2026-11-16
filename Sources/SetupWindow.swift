import Cocoa

// MARK: - Setup window

/// The first-run guide, in two screens. The welcome screen says what DockPlus does and how
/// it protects the user. The setup screen explains why DockPlus needs each permission before
/// macOS asks, asks only when the user presses a button, and offers the few settings there
/// are. The setup screen shows again whenever DockPlus launches without Accessibility.
///
/// It only hands off to macOS's own prompts and System Settings: it never looks like a
/// system dialog and never asks for a password.
final class SetupWindow: NSObject, NSWindowDelegate {
    enum Page { case welcome, setup }

    private static let width: CGFloat = 520
    private static let margin: CGFloat = 28

    private unowned let app: DockPlus
    private let window: NSWindow
    private var page: Page
    private let stack = NSStackView()
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private let accessibilityStatus = NSTextField(labelWithString: "")
    private let screenRecordingStatus = NSTextField(labelWithString: "")
    private var accessibilityButton: NSButton?
    private var screenRecordingButton: NSButton?
    private var finished = false

    init(app: DockPlus, page: Page) {
        self.app = app
        self.page = page
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 480),
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Set Up DockPlus"
        window.isReleasedWhenClosed = false
        window.delegate = self

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 24, left: Self.margin, bottom: 0, right: Self.margin)
        stack.translatesAutoresizingMaskIntoConstraints = false

        doneButton.target = self
        doneButton.action = #selector(done)
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.target = self
        backButton.action = #selector(back)
        backButton.bezelStyle = .rounded
        backButton.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        content.addSubview(backButton)
        content.addSubview(doneButton)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doneButton.topAnchor, constant: -16),
            doneButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.margin),
            doneButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            backButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.margin),
            backButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            content.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        window.contentView = content
        build()
        window.layoutIfNeeded()
        window.center()
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func go(to newPage: Page) {
        page = newPage
        build()
    }

    private func build() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        accessibilityButton = nil
        screenRecordingButton = nil
        backButton.isHidden = page == .welcome
        doneButton.title = page == .welcome ? "Continue" : "Done"
        switch page {
        case .welcome: buildWelcome()
        case .setup: buildSetup()
        }
        refresh()
    }

    /// The features and protections here follow the README's feature list and its "Privacy
    /// and security" section. Keep the two in step.
    private func buildWelcome() {
        add(title("Welcome to DockPlus"))
        add(text("A small menu bar app that adds Dock and window behaviors macOS doesn't have."))

        add(heading("What it does"), spaceBefore: 16)
        add(highlight("cursorarrow.click.2", "Double-click to minimize and restore",
                      "Double-click a running app's Dock icon to minimize its most recent window. Double-click again to bring back the window you minimized last."))
        add(highlight("arrow.uturn.forward", "Focus follows minimize",
                      "When you minimize an app's last window on screen, focus moves to the next window in front, so you can type in it right away. With every window minimized, focus goes to Finder."))
        add(highlight("macwindow.on.rectangle", "Hover for window previews",
                      "Rest the pointer on a running app's Dock icon to see a thumbnail of each of its windows. Click one to switch to it, or Option-click to minimize or restore just that window."))

        add(heading("Privacy and security"), spaceBefore: 16)
        add(highlight("wifi.slash", "No network access",
                      "DockPlus never connects to the internet and contains no third-party code."))
        add(highlight("memorychip", "Thumbnails stay in memory",
                      "Window pictures are never written to disk or logged, and you choose how long they're kept. Only your settings are saved."))
        add(highlight("eye.slash", "Private previews",
                      "The hover panel is kept out of screen sharing where macOS allows it, and DockPlus never captures the windows of hidden apps."))
        add(highlight("lock.shield", "Hardened Runtime",
                      "The app is signed so other programs can't inject code into it to borrow its permissions."))
        add(highlight("hand.raised", "You control the permissions",
                      "DockPlus asks only when you press a button, works without Screen Recording, and stops at once if you turn a permission off."))
    }

    private func buildSetup() {
        add(title("Set up DockPlus"))

        add(heading("1. Allow permissions"), spaceBefore: 16)
        let allowAccessibility = button("Allow…", #selector(allowAccessibility))
        accessibilityButton = allowAccessibility
        add(row(accessibilityStatus, allowAccessibility))
        add(note("Required. Lets DockPlus see which Dock icon you're pointing at and minimize, restore and switch windows. macOS calls this controlling your computer; DockPlus uses it only for that."))
        let allowScreenRecording = button("Allow…", #selector(allowScreenRecording))
        screenRecordingButton = allowScreenRecording
        add(row(screenRecordingStatus, allowScreenRecording), spaceBefore: 14)
        add(note("Optional. Only for the thumbnails in the hover preview; without it you get window titles and app icons. Nothing is recorded or saved to disk. macOS may ask you to reopen DockPlus."))
        if app.hasLegacyInstall {
            add(note("Updating from an earlier version? If System Settings lists DockPlus twice, remove the entry that's turned off with the − button."),
                spaceBefore: 14)
        }

        add(heading("2. Choose what DockPlus does"), spaceBefore: 16)
        add(checkbox("Double-click a Dock icon to minimize or restore its window",
                     on: app.isSettingOn("doubleClickToggle"), #selector(toggleDoubleClick(_:))))
        add(checkbox("Hover over a Dock icon to show all of its windows",
                     on: app.isSettingOn("hoverPreviews"), #selector(toggleHover(_:))))
        add(lifetimeRow())
        add(checkbox("Open DockPlus when you log in",
                     on: app.opensAtLogin, #selector(toggleLogin(_:))))
        add(note("You can change all of this later from the DockPlus icon in the menu bar."), spaceBefore: 14)
    }

    /// Updates the live permission status. Done needs Accessibility. Called every 2 seconds.
    func refresh() {
        guard page == .setup else {
            doneButton.isEnabled = true
            doneButton.toolTip = nil
            return
        }
        let trusted = AXIsProcessTrusted()
        setStatus(accessibilityStatus, trusted, "Accessibility")
        accessibilityButton?.isHidden = trusted
        let canCapture = CGPreflightScreenCaptureAccess()
        setStatus(screenRecordingStatus, canCapture, "Screen Recording (optional)")
        screenRecordingButton?.isHidden = canCapture
        doneButton.isEnabled = trusted
        doneButton.toolTip = trusted ? nil : "Allow Accessibility first"
    }

    @objc private func back() { go(to: .welcome) }

    @objc private func done() {
        guard page == .setup else {
            go(to: .setup)
            return
        }
        finished = true
        window.close()
        app.setupFinished()
    }

    @objc private func allowAccessibility() { app.requestAccessibility() }
    @objc private func allowScreenRecording() { app.requestScreenRecording() }
    @objc private func toggleDoubleClick(_ sender: NSButton) { app.setSetting("doubleClickToggle", sender.state == .on) }
    @objc private func toggleHover(_ sender: NSButton) { app.setSetting("hoverPreviews", sender.state == .on) }
    @objc private func chooseLifetime(_ sender: NSPopUpButton) {
        app.setThumbnailLifetime(sender.selectedTag())
    }
    @objc private func toggleLogin(_ sender: NSButton) {
        app.setOpenAtLogin(sender.state == .on)
        sender.state = app.opensAtLogin ? .on : .off
    }

    func windowWillClose(_ notification: Notification) {
        if !finished { app.setupClosed() } // the menu offers to finish setting up
    }

    // MARK: Views

    private func add(_ view: NSView, spaceBefore: CGFloat? = nil) {
        if let spaceBefore, let last = stack.arrangedSubviews.last {
            stack.setCustomSpacing(spaceBefore, after: last)
        }
        stack.addArrangedSubview(view)
    }

    private func title(_ string: String) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        return label
    }

    private func heading(_ string: String) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func text(_ string: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: string)
        label.font = .systemFont(ofSize: 13)
        label.isSelectable = false
        label.preferredMaxLayoutWidth = Self.width - 2 * Self.margin
        return label
    }

    private func note(_ string: String) -> NSTextField {
        let label = text(string)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// One feature or protection on the welcome screen: a symbol, a bold name and a sentence.
    private func highlight(_ symbol: String, _ name: String, _ detail: String) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let detailLabel = note(detail)
        detailLabel.preferredMaxLayoutWidth = Self.width - 2 * Self.margin - 26 - 10
        let words = NSStackView(views: [nameLabel, detailLabel])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 2

        let row = NSStackView(views: [icon, words])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        return row
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    private func checkbox(_ title: String, on: Bool, _ action: Selector) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: self, action: action)
        box.state = on ? .on : .off
        return box
    }

    private func row(_ views: NSView...) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    /// "Keep preview thumbnails for [Until the App Quits]", for minimized windows in the hover preview.
    private func lifetimeRow() -> NSView {
        let label = NSTextField(labelWithString: "Keep preview thumbnails for")
        label.font = .systemFont(ofSize: 13)
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        for choice in ThumbnailCache.lifetimes {
            popUp.addItem(withTitle: choice.title)
            popUp.lastItem?.tag = choice.seconds
        }
        popUp.selectItem(withTag: app.thumbnailLifetime)
        popUp.target = self
        popUp.action = #selector(chooseLifetime(_:))
        let row = row(label, popUp)
        // Indented under the hover checkbox it belongs to.
        row.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        return row
    }

    private func setStatus(_ label: NSTextField, _ on: Bool, _ name: String) {
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.stringValue = on ? "✓ \(name): allowed" : "○ \(name): not allowed yet"
        label.textColor = on ? .systemGreen : .labelColor
    }
}
