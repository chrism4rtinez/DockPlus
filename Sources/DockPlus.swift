// DockPlus.swift
//
// Two Dock behaviors macOS doesn't offer:
//   • Double-click a running app's Dock icon → minimize its most recent window;
//     double-click again → restore it (the most recently minimized window).
//     Once an app has no windows left on screen, the next window in front gets focus, or
//     Finder when every window is minimized.
//   • Hover a running app's Dock icon → a panel with thumbnails of all its windows.
//     Click a thumbnail to focus that window (restoring it if minimized);
//     ⌥-click a thumbnail to minimize / restore just that window.
//     A minimized window shows how it looked when it was last on screen.
//     Right-click or Control-click the icon to close the panel. It stays closed while the
//     Dock's menu is open, and until the pointer moves to another icon or leaves the Dock.
//     The same panel opens when the Dock is used from the keyboard (Fn/Globe-A or
//     Control-F3, then the arrow keys) for the icon that has keyboard focus.
//
// How it works
//   • The Dock's Accessibility tree marks the icon under the pointer as "selected", and an
//     AXObserver on the Dock's icon list (kAXSelectedChildrenChangedNotification) fires
//     whenever that changes. On each change DockPlus records the hovered app and the state
//     of its windows, and after a short delay shows the hover panel.
//   • When the Dock is used from the keyboard, it reports the icon with keyboard focus as its
//     focused UI element (kAXFocusedUIElementChangedNotification on the Dock). DockPlus shows
//     the panel for that icon and keeps it open while the icon stays focused. It reads this
//     from the Dock's Accessibility tree only; it never watches the keyboard itself.
//   • A CGEventTap on its own thread sees every left and right mouse-down before the Dock
//     does. It only reads the state recorded on hover and never calls into other apps, so a
//     hung app can't stall mouse input. On the second click of a double-click
//     (mouseEventClickState == 2) it swallows that click and its matching mouse-up, and the
//     main thread toggles the window. A right-click or Control-click closes the preview and
//     passes through, so the Dock still opens its menu; while that icon's menu is open (an
//     AXMenu child of the icon in the Dock's Accessibility tree), no preview is shown.
//   • Private APIs, resolved at runtime with dlsym (the same calls AltTab and DockDoor use):
//       _AXUIElementGetWindow          AX window → CGWindowID
//       CGSHWCaptureWindowList         window thumbnails, even for covered windows
//       _SLPSSetFrontProcessWithOptions + SLPSPostEventRecordTo
//                                      focus one specific window of another app
//       GetProcessForPID               pid → ProcessSerialNumber for the SkyLight calls
//     They're only called on macOS versions where these signatures are known to work
//     (SPI.knownVersions). On any other version, or if a symbol is missing, DockPlus falls
//     back to public APIs: no thumbnails, plain app activation.
//
// Security notes
//   • DockPlus holds Accessibility and Screen Recording, so build.sh signs it with Hardened
//     Runtime, which stops other programs from injecting code into it to borrow those rights.
//   • No network access and no third-party code. Nothing is written to disk except two on/off
//     settings; window titles and thumbnails stay in memory and are never logged.
//   • The hover panel is excluded from screen sharing where macOS honors that, and never
//     captures the windows of hidden apps.
//   • For those minimized-window pictures, DockPlus keeps a small, downscaled thumbnail of a
//     window when it is clicked, focused, or shown in the panel (one per window, at most 64,
//     in memory only). Each is dropped when its app quits, or sooner if the user chose a
//     time limit. This only happens while hover previews are on.
//   • Nothing asks for a permission at launch. A setup window explains each permission first
//     and asks only when the user presses its button; Screen Recording is optional.
//   • DockPlus only runs (event tap, Dock and app observers) once setup is finished and
//     Accessibility is allowed. If Accessibility is taken away, it removes the event tap and
//     stops at once, and the menu bar icon turns into a warning sign. If Screen Recording is
//     taken away, cached window pictures are dropped.
//
// Permissions: Accessibility (required), Screen Recording (thumbnails only).
// Build: ./build.sh — see that file. Start the app from Finder or `open`, not from Terminal.

import Cocoa
import ApplicationServices

// MARK: - App

/// What an app looked like just before a click, so a double-click knows whether to
/// minimize or restore.
struct ClickSnapshot {
    let pid: pid_t
    let wasFrontmost: Bool
    let wasHidden: Bool
    let visibleWindow: AXUIElement?
}

/// The running app whose Dock icon is under the pointer, recorded on the main thread.
struct HoverInfo {
    let item: AXUIElement
    let itemFrame: CGRect?             // the icon's frame when the Dock selected it, Quartz coordinates
    let app: NSRunningApplication
    var snapshot: ClickSnapshot
}

/// State shared between the main thread and the event-tap thread. Always accessed through
/// `Locked`, and the lock is never held across a call into another process.
struct TapState {
    var hover: HoverInfo?
    var selectedItem: AXUIElement?     // any Dock icon under the pointer, running app or not
    var dockListFrame: CGRect?
    var magnificationSlack: CGFloat = 128 // how far a magnified icon can grow past its resting frame
    var previewFrame: CGRect?          // hover panel while visible, Quartz coordinates
    // Where the hover panel last appeared for the current Dock selection, kept after it hides.
    // Cleared when the Dock selects another icon or none.
    var lastPreviewFrame: CGRect?
    var armed: ClickSnapshot?          // taken at the first click of a possible double-click
    var swallowEventNumber: Int64?     // the mouse-up that matches the swallowed mouse-down
}

final class Locked<Value> {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func with<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

final class DockPlus: NSObject, NSApplicationDelegate {
    static let shared = DockPlus()

    let tracker = MinimizeTracker()
    let preview = WindowPreview()

    let defaults = UserDefaults.standard // thread-safe; also read on the tap thread
    private var doubleClickEnabled: Bool { defaults.bool(forKey: "doubleClickToggle") }
    private var hoverEnabled: Bool { defaults.bool(forKey: "hoverPreviews") }

    // Main thread only
    private var dockPID: pid_t = 0
    private var dockList: AXUIElement?
    private var dockApp: AXUIElement?
    private var dockObserver: AXObserver?
    private var pendingShow: DispatchWorkItem?
    private var pendingHandoff: DispatchWorkItem?
    private var suppressedItem: AXUIElement? // Dock icon last right-clicked; no previews for now
    var statusItem: NSStatusItem?
    var started = false
    var tapFailed = false            // the event tap couldn't be created
    private var workspaceObservers: [NSObjectProtocol] = []
    private var dockTimer: Timer?
    var couldCapture = false         // Screen Recording at the last permission check
    var promptedForAccessibility = false
    var setup: SetupWindow?

    // Shared with the event-tap thread
    private let tapState = Locked(TapState())
    private let eventTap = Locked<CFMachPort?>(nil)
    private let tapRunLoop = Locked<CFRunLoop?>(nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        preview.onFrameChange = { [tapState = self.tapState] frame in
            tapState.with { s in
                s.previewFrame = frame
                if let frame { s.lastPreviewFrame = frame }
            }
        }
        migrateLegacySettings()
        defaults.register(defaults: ["doubleClickToggle": true, "hoverPreviews": true,
                                     "thumbnailLifetime": ThumbnailCache.defaultLifetime])
        setUpMenu()
        couldCapture = CGPreflightScreenCaptureAccess()

        // Nothing asks for a permission at launch. The setup window explains each one first and
        // asks only when the user presses its button. DockPlus starts working (event tap, Dock
        // and app observers) only once setup is finished and Accessibility is allowed.
        if !setupComplete {
            showSetup(.welcome)
        } else if !AXIsProcessTrusted() {
            showSetup(.setup)
        }
        checkPermissions()
        // Permissions can be granted or taken away in System Settings at any time.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.checkPermissions()
        }
    }

    func start() {
        guard !started else { return }
        started = true
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        attachToDock()
        installEventTap()

        for app in NSWorkspace.shared.runningApplications { tracker.watch(app) }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let self, self.started else { return }
                self.tracker.watch(app)
            }
        })
        // Return or Space in a keyboard-focused Dock opens the app; the panel shouldn't linger.
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.preview.openedFromKeyboard else { return }
            self.pendingShow?.cancel()
            self.preview.hide()
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.tracker.forget(app.processIdentifier)
            self.preview.thumbnails.forget(app.processIdentifier)
            if self.preview.shownPID == app.processIdentifier { self.preview.hide() }
        })
        // Keep the hovered app's snapshot current while the pointer rests on its icon.
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshHoverSnapshot()
            })
        }

        // The Dock restarts on `killall Dock`, display changes, etc. Re-attach when its pid changes.
        dockTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            let current = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
            if current != self.dockPID || self.dockList == nil { self.attachToDock() } else { self.readMagnification() }
        }
    }

    /// Undoes start() when Accessibility is taken away: removes the event tap, so DockPlus no
    /// longer sees any clicks, stops watching the Dock and other apps, and drops every window
    /// picture. start() runs again once Accessibility is allowed again.
    func stop() {
        guard started else { return }
        started = false
        removeEventTap()
        tapFailed = false
        dockTimer?.invalidate()
        dockTimer = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { center.removeObserver(observer) }
        workspaceObservers.removeAll()
        if let observer = dockObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            dockObserver = nil
        }
        dockList = nil
        dockApp = nil
        dockPID = 0
        suppressedItem = nil
        tracker.forgetAll()
        pendingShow?.cancel()
        pendingHandoff?.cancel()
        preview.hide()
        preview.thumbnails.removeAll()
        tapState.with { $0 = TapState() }
    }

    // MARK: Last-seen thumbnails

    /// Caches a picture of an on-screen window, for when it is later minimized. Skipped while
    /// hover previews are off or Screen Recording isn't granted.
    func cacheThumbnail(of window: AXUIElement, after delay: TimeInterval = 0) {
        guard hoverEnabled, CGPreflightScreenCaptureAccess() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.hoverEnabled else { return }
            if let app = NSRunningApplication(processIdentifier: axPID(window)), app.isHidden { return }
            self.preview.thumbnails.refresh(window)
        }
    }

    /// A click outside the Dock: refresh the picture of the window under the pointer.
    /// A click on a window's minimize button lands here on mouse-down, before the window
    /// minimizes on mouse-up, so the cached picture is how the window looked at that moment.
    private func cacheWindow(at point: CGPoint) {
        guard hoverEnabled, CGPreflightScreenCaptureAccess() else { return }
        preview.thumbnails.refreshWindow(at: point)
    }

    // MARK: Dock

    private func attachToDock() {
        if let old = dockObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .commonModes)
            dockObserver = nil
        }
        dockList = nil
        dockApp = nil
        suppressedItem = nil
        tapState.with { s in
            s.hover = nil
            s.selectedItem = nil
            s.dockListFrame = nil
            s.lastPreviewFrame = nil
        }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        dockPID = dock.processIdentifier
        let dockElement = AXUIElementCreateApplication(dockPID)
        guard let list = axElements(dockElement, kAXChildrenAttribute)
            .first(where: { axString($0, kAXRoleAttribute) == kAXListRole }) else { return }
        dockList = list
        dockApp = dockElement
        let listFrame = axFrame(list)
        tapState.with { $0.dockListFrame = listFrame }
        readMagnification()

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, _ in
            if notification as String == kAXFocusedUIElementChangedNotification {
                DockPlus.shared.dockFocusChanged()
            } else {
                DockPlus.shared.dockSelectionChanged()
            }
        }
        guard AXObserverCreate(dockPID, callback, &observer) == .success, let observer else { return }
        AXObserverAddNotification(observer, list, kAXSelectedChildrenChangedNotification as CFString, nil)
        // Keyboard navigation of the Dock (Fn/Globe-A, Control-F3) moves its focused element.
        AXObserverAddNotification(observer, dockElement, kAXFocusedUIElementChangedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        dockObserver = observer
    }

    /// Reads the Dock's magnification setting (it can change without the Dock restarting), so
    /// the event tap knows how far past its resting frame the hovered icon can reach.
    private func readMagnification() {
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)
        func number(_ key: String) -> CGFloat? {
            (CFPreferencesCopyAppValue(key as CFString, domain) as? NSNumber).map { CGFloat($0.doubleValue) }
        }
        let magnifies = (CFPreferencesCopyAppValue("magnification" as CFString, domain) as? NSNumber)?.boolValue ?? false
        // Unknown sizes fall back to the largest magnified size the Dock allows.
        let slack = magnifies ? max(0, (number("largesize") ?? 128) - (number("tilesize") ?? 0)) : 0
        tapState.with { $0.magnificationSlack = slack }
    }

    /// The Dock marks the icon under the pointer as its "selected" child.
    private func hoveredDockItem() -> AXUIElement? {
        guard let list = dockList else { return nil }
        return axElements(list, kAXSelectedChildrenAttribute).first
    }

    /// The Dock icon with keyboard focus, while the Dock is used from the keyboard (Fn/Globe-A
    /// or Control-F3, then the arrow keys), or nil. Only counts while the Dock is the app that
    /// receives keystrokes, so an icon merely hovered with the pointer never qualifies. Asks the
    /// system which app has keyboard focus and the Dock which icon; never the app behind it.
    private func keyboardFocusedDockItem() -> AXUIElement? {
        guard let dockApp, dockPID != 0,
              let focusedApp = axElement(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute),
              axPID(focusedApp) == dockPID else { return nil }
        if let focused = axElement(dockApp, kAXFocusedUIElementAttribute),
           axString(focused, kAXRoleAttribute) == "AXDockItem" {
            return focused
        }
        return hoveredDockItem() // the Dock also marks the focused icon as selected
    }

    private func runningApp(for item: AXUIElement) -> NSRunningApplication? {
        guard axString(item, kAXSubroleAttribute) == "AXApplicationDockItem",
              let nsurl = axValue(item, kAXURLAttribute) as? NSURL else { return nil }
        let url = nsurl as URL
        let path = url.resolvingSymlinksInPath().path
        if let exact = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL?.resolvingSymlinksInPath().path == path
        }) {
            return exact
        }
        if let bundleID = Bundle(url: url)?.bundleIdentifier {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        }
        return nil
    }

    // MARK: Hover

    /// Reads another app's window state over Accessibility. Main thread only — this can be
    /// slow if that app is hung, which is why the event tap never calls it.
    private func takeSnapshot(of app: NSRunningApplication) -> ClickSnapshot {
        ClickSnapshot(pid: app.processIdentifier,
                      wasFrontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                      wasHidden: app.isHidden,
                      visibleWindow: visibleFocusedWindow(of: app))
    }

    /// Called once a window has finished minimizing, however it was minimized. AX only reports
    /// the window as minimized after the animation, so the check can't run any earlier. The short
    /// wait lets a Minimize All finish, so the handoff runs once, after the last window.
    func windowMinimized(in pid: pid_t) {
        pendingHandoff?.cancel()
        let work = DispatchWorkItem {
            guard let app = NSRunningApplication(processIdentifier: pid) else { return }
            focusNextWindowIfNoneLeft(in: app)
        }
        pendingHandoff = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Re-reads the hovered app's state after something may have changed it: a click,
    /// a window minimized or restored, an app activated or hidden.
    func refreshHoverSnapshot() {
        guard let hovered = tapState.with({ $0.hover }) else { return }
        let fresh = takeSnapshot(of: hovered.app) // outside the lock: cross-process call
        tapState.with { s in
            if let current = s.hover, CFEqual(current.item, hovered.item) {
                s.hover?.snapshot = fresh
            }
        }
    }

    func dockSelectionChanged() {
        let selected = hoveredDockItem()
        var found: HoverInfo?
        if let item = selected, let app = runningApp(for: item), app.processIdentifier != getpid() {
            found = HoverInfo(item: item, itemFrame: axFrame(item), app: app, snapshot: takeSnapshot(of: app))
        }
        let listFrame = dockList.flatMap(axFrame)
        tapState.with { s in
            if let listFrame { s.dockListFrame = listFrame }
            let sameItem: Bool
            switch (s.selectedItem, selected) {
            case let (old?, new?): sameItem = CFEqual(old, new)
            case (nil, nil): sameItem = true
            default: sameItem = false
            }
            if !sameItem { s.lastPreviewFrame = nil }
            s.selectedItem = selected
            s.hover = found
        }

        // After a right-click or Control-click, previews stay closed while that icon's Dock menu
        // is open, and for that icon until the pointer moves to another icon or leaves the Dock.
        if let suppressed = suppressedItem {
            let sameIcon = selected.map { CFEqual($0, suppressed) } ?? false
            if sameIcon || dockMenuIsOpen(on: suppressed) {
                pendingShow?.cancel()
                return
            }
            suppressedItem = nil
        }

        // The Dock is being used from the keyboard: follow its keyboard focus instead.
        if let focused = keyboardFocusedDockItem() {
            showForKeyboard(focused)
            return
        }

        guard let hover = found else {
            pendingShow?.cancel()
            return // the panel's own pointer tracking decides when to close
        }
        guard hoverEnabled else { return }
        let item = hover.item
        let app = hover.app
        if preview.isVisible && preview.shownPID == app.processIdentifier { return }
        pendingShow?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.suppressedItem == nil,
                  let current = self.hoveredDockItem(), CFEqual(current, item),
                  let frame = axFrame(item) else { return }
            self.preview.show(app: app, anchor: frame, dockFrame: self.tapState.with { $0.dockListFrame })
        }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (preview.isVisible ? 0.2 : 0.35), execute: work)
    }

    /// The Dock's keyboard focus moved: onto an icon, to another icon, or out of the Dock.
    func dockFocusChanged() {
        // When focus leaves the Dock, a panel opened from the keyboard closes on its next check,
        // and one waiting to open doesn't, as the icon is no longer focused.
        guard let item = keyboardFocusedDockItem() else { return }
        showForKeyboard(item)
    }

    /// Shows the panel for a Dock icon reached from the keyboard, after the same short delay as
    /// a hover. The panel opens only if the Dock still has this icon focused by then, and stays
    /// open while it does (or while the pointer is on it, as for a hover). It shows the same
    /// thumbnails as a hover, under the same privacy rules: hidden apps aren't captured, the
    /// thumbnail lifetime setting applies, and nothing shows while hover previews are off.
    private func showForKeyboard(_ item: AXUIElement) {
        guard hoverEnabled else { return }
        let stillOnItem = { [weak self] () -> Bool in
            self?.keyboardFocusedDockItem().map { CFEqual($0, item) } ?? false
        }
        guard let app = runningApp(for: item), app.processIdentifier != getpid() else {
            // Not a running app (a folder, the Trash, an app that isn't open): nothing to show.
            // An open panel closes on its next check, as the focus has moved off its icon.
            pendingShow?.cancel()
            return
        }
        if preview.openedFromKeyboard && preview.shownPID == app.processIdentifier { return }
        pendingShow?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, stillOnItem(), let frame = axFrame(item) else { return }
            self.preview.show(app: app, anchor: frame,
                              dockFrame: self.tapState.with { $0.dockListFrame },
                              keepOpen: stillOnItem)
        }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (preview.isVisible ? 0.2 : 0.35), execute: work)
    }

    /// Right-click or Control-click on a Dock icon: the Dock is opening that icon's menu, so
    /// close the preview and keep it closed (see dockSelectionChanged for when it reopens).
    private func suppressPreview(for icon: AXUIElement) {
        suppressedItem = icon
        pendingShow?.cancel()
        preview.hide()
    }

    /// The Dock shows an icon's menu as an AXMenu child of that icon. This asks the Dock
    /// (a system process), never the app the icon belongs to.
    private func dockMenuIsOpen(on icon: AXUIElement) -> Bool {
        axElements(icon, kAXChildrenAttribute).contains { axString($0, kAXRoleAttribute) == kAXMenuRole }
    }

    // MARK: Double-click

    func installEventTap() {
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, _ in
            DockPlus.shared.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: nil) else {
            NSLog("DockPlus: could not create the event tap — is Accessibility permission granted?")
            tapFailed = true // shown in the menu bar
            return
        }
        CGEvent.tapEnable(tap: tap, enable: false) // enabled once its thread is serving it
        eventTap.with { $0 = tap }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        // The tap gets its own thread, so work on the main thread (Accessibility calls into
        // other apps, the preview panel) can never hold up system-wide mouse input.
        let thread = Thread { [tapRunLoop = self.tapRunLoop] in
            tapRunLoop.with { $0 = CFRunLoopGetCurrent() }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            // Removed before this thread got here: the source is already invalid, and the run
            // loop below returns at once because it has nothing to serve.
            if CFMachPortIsValid(tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            CFRunLoopRun()
        }
        thread.name = "DockPlus event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Turns the event tap off and lets its thread end. Invalidating the port removes its
    /// source from the tap thread's run loop, which then has nothing left and returns.
    private func removeEventTap() {
        guard let tap = eventTap.with({ t -> CFMachPort? in defer { t = nil }; return t }) else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        if let runLoop = tapRunLoop.with({ r -> CFRunLoop? in defer { r = nil }; return r }) {
            CFRunLoopStop(runLoop)
        }
    }

    /// Runs on the tap thread, and every system-wide left and right click waits for it. It only
    /// reads state recorded on hover and never calls into another process.
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            tapState.with { s in
                s.armed = nil
                s.swallowEventNumber = nil
            }
            // Only if it hasn't been removed meanwhile (Accessibility taken away).
            if let tap = eventTap.with({ $0 }), CFMachPortIsValid(tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .leftMouseUp:
            // Drop only the mouse-up that belongs to the swallowed mouse-down. A mouse-down and
            // its mouse-up share an event number, so a missed mouse-up can't make DockPlus eat
            // an unrelated click somewhere else later.
            let number = event.getIntegerValueField(.mouseEventNumber)
            let swallow = tapState.with { s -> Bool in
                guard s.swallowEventNumber == number else { return false }
                s.swallowEventNumber = nil
                return true
            }
            return swallow ? nil : pass
        case .rightMouseDown:
            handleContextClick(at: event.location)
            return pass // the Dock still gets the click and opens its menu
        case .leftMouseDown:
            if event.flags.contains(.maskControl) { // Control-click opens the same Dock menu
                handleContextClick(at: event.location)
                return pass
            }
        default:
            return pass
        }

        // The Dock marks the icon under the pointer as selected; the frame check (with room for
        // magnification) guards against a stale selection when clicking elsewhere.
        let point = event.location
        // Clicks on the hover panel belong to the panel. The Dock can still report the icon as
        // selected for a moment after the pointer leaves it, and the panel sits within the slack
        // below, so without this check a click on a thumbnail closed the panel before the
        // thumbnail saw it, and the window switch was lost.
        //
        // The Dock doesn't always clear its selection when the pointer moves off an icon into
        // the panel, so once the panel hides, the icon can still look hovered. Clicks where the
        // panel last appeared therefore never count as Dock clicks either; otherwise a
        // double-click on that now empty spot minimized the app's window. The panel never
        // overlaps the icons, so this can't swallow a real Dock click.
        guard let hover = tapState.with({ s -> HoverInfo? in
            if let panel = s.previewFrame ?? s.lastPreviewFrame, panel.contains(point) {
                s.armed = nil
                return nil
            }
            // The click must land on the hovered icon: on the Dock itself, or within reach of
            // that icon once magnified. The Dock can keep an icon selected after the pointer has
            // left the Dock, so a looser area (it used to be 128 pt all around the Dock) let a
            // double-click on empty space near the Dock minimize the app's window.
            let reach = s.magnificationSlack + 4
            guard let hovered = s.hover,
                  let dock = s.dockListFrame,
                  dock.insetBy(dx: -4, dy: -4).contains(point)
                    || (hovered.itemFrame?.insetBy(dx: -reach, dy: -reach).contains(point) ?? false) else {
                s.armed = nil
                return nil
            }
            return hovered
        }) else {
            let point = event.location
            DispatchQueue.main.async { self.cacheWindow(at: point) }
            return pass
        }

        DispatchQueue.main.async {
            self.pendingShow?.cancel()
            if self.preview.isVisible { self.preview.hide() }
        }

        let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        guard doubleClickEnabled, event.flags.intersection(modifiers).isEmpty else {
            tapState.with { $0.armed = nil }
            return pass
        }

        let clicks = event.getIntegerValueField(.mouseEventClickState)
        let number = event.getIntegerValueField(.mouseEventNumber)
        let before = tapState.with { s -> ClickSnapshot? in
            if clicks == 2, let armed = s.armed, armed.pid == hover.snapshot.pid {
                // Second click of a double-click: keep it, and its mouse-up, from the Dock.
                s.armed = nil
                s.swallowEventNumber = number
                return armed
            }
            // First click: the Dock handles it normally. Remember the state from before it.
            s.armed = clicks == 1 ? hover.snapshot : nil
            return nil
        }

        if let before {
            let app = hover.app
            DispatchQueue.main.async {
                self.toggleMostRecentWindow(of: app, before: before)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refreshHoverSnapshot() }
            }
            return nil
        }
        // Once the Dock has acted on this click, re-read the app's state for the next one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refreshHoverSnapshot() }
        return pass
    }

    /// Tap thread. A right-click or Control-click on a Dock icon cancels any double-click in
    /// progress and closes the preview. Clicks on the preview panel itself are ignored: the
    /// Dock has no icon under the pointer then.
    private func handleContextClick(at point: CGPoint) {
        guard let icon = tapState.with({ s -> AXUIElement? in
            s.armed = nil
            if let panel = s.previewFrame, panel.contains(point) { return nil }
            guard let dock = s.dockListFrame, dock.insetBy(dx: -128, dy: -128).contains(point) else { return nil }
            return s.selectedItem
        }) else { return }
        DispatchQueue.main.async { self.suppressPreview(for: icon) }
    }

    private func toggleMostRecentWindow(of app: NSRunningApplication, before: ClickSnapshot) {
        if before.wasHidden {
            app.unhide()
            if let window = visibleFocusedWindow(of: app) { focusWindow(window, of: app) }
            return
        }
        if let window = before.visibleWindow {
            if before.wasFrontmost {
                if hoverEnabled { preview.thumbnails.captureNow(window) } // picture for the hover panel
                axSet(window, kAXMinimizedAttribute, true)  // it was in use → minimize it
            } else {
                focusWindow(window, of: app)                // it was behind other apps → bring it forward
            }
            return
        }
        // Nothing of this app was on screen: bring back the most recently minimized window.
        // (The Dock's first click usually restores it already; then we just focus it.)
        if let shown = visibleFocusedWindow(of: app) {
            focusWindow(shown, of: app)
            return
        }
        let minimized = appWindows(app).filter(\.minimized).map(\.element)
        guard let target = tracker.mostRecentlyMinimized(app.processIdentifier, among: minimized) ?? minimized.first else {
            _ = app.activate(options: [])
            return
        }
        axSet(target, kAXMinimizedAttribute, false)
        focusWindow(target, of: app)
    }
}
