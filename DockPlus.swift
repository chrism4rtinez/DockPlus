// DockPlus.swift
//
// Two Dock behaviors macOS doesn't offer:
//   • Double-click a running app's Dock icon → minimize its most recent window;
//     double-click again → restore it (the most recently minimized window).
//   • Hover a running app's Dock icon → a panel with thumbnails of all its windows.
//     Click a thumbnail to focus that window (restoring it if minimized);
//     ⌥-click a thumbnail to minimize / restore just that window.
//     Right-click or Control-click the icon to close the panel. It stays closed while the
//     Dock's menu is open, and until the pointer moves to another icon or leaves the Dock.
//
// How it works
//   • The Dock's Accessibility tree marks the icon under the pointer as "selected", and an
//     AXObserver on the Dock's icon list (kAXSelectedChildrenChangedNotification) fires
//     whenever that changes. On each change DockPlus records the hovered app and the state
//     of its windows, and after a short delay shows the hover panel.
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
//   • Screen Recording is only requested the first time a hover preview is about to appear.
//
// Permissions: Accessibility (required), Screen Recording (thumbnails only).
// Build: ./build.sh — see that file. Start the app from Finder or `open`, not from Terminal.

import Cocoa
import ApplicationServices
import ServiceManagement

// MARK: - Private APIs

/// ProcessSerialNumber layout (two UInt32s), declared locally to avoid SDK availability issues.
struct PSN {
    var high: UInt32 = 0
    var low: UInt32 = 0
}

enum SPI {
    typealias AXGetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    typealias MainConnection = @convention(c) () -> UInt32
    typealias CaptureWindows = @convention(c) (UInt32, UnsafePointer<UInt32>, UInt32, UInt32) -> UnsafeMutableRawPointer?
    typealias GetPSN = @convention(c) (pid_t, UnsafeMutableRawPointer) -> OSStatus
    typealias SetFrontProcess = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> CGError
    typealias PostEventRecord = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>) -> CGError

    /// macOS major versions where these private signatures are known to work (AltTab and
    /// DockDoor ship them). On any other version nothing private is called, so a changed ABI
    /// can't corrupt memory in this highly privileged process. Widen after testing a new release.
    static let knownVersions = 14...27
    static let enabled = knownVersions.contains(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)

    static let skyLight = enabled ? dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) : nil
    static let anyImage = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT

    static func load<T>(_ handle: UnsafeMutableRawPointer?, _ names: String...) -> T? {
        guard enabled, let handle else { return nil }
        for name in names {
            if let symbol = dlsym(handle, name) { return unsafeBitCast(symbol, to: T.self) }
        }
        return nil
    }

    static let axGetWindow: AXGetWindow? = load(anyImage, "_AXUIElementGetWindow")
    static let getPSN: GetPSN? = load(anyImage, "GetProcessForPID")
    static let mainConnection: MainConnection? = load(skyLight, "SLSMainConnectionID", "CGSMainConnectionID")
    static let captureWindows: CaptureWindows? = load(skyLight, "SLSHWCaptureWindowList", "CGSHWCaptureWindowList")
    static let setFrontProcess: SetFrontProcess? = load(skyLight, "_SLPSSetFrontProcessWithOptions")
    static let postEventRecord: PostEventRecord? = load(skyLight, "SLPSPostEventRecordTo")
}

// MARK: - Accessibility helpers

func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
}

func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let value = axValue(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func axElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
    axValue(element, attribute) as? [AXUIElement] ?? []
}

func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    axValue(element, attribute) as? String
}

func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
    axValue(element, attribute) as? Bool
}

@discardableResult
func axSet(_ element: AXUIElement, _ attribute: String, _ value: Bool) -> AXError {
    AXUIElementSetAttributeValue(element, attribute as CFString, NSNumber(value: value))
}

/// Frame in global "Quartz" coordinates (origin at the top-left of the main display).
func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let position = axValue(element, kAXPositionAttribute),
          let size = axValue(element, kAXSizeAttribute),
          CFGetTypeID(position) == AXValueGetTypeID(),
          CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
          AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
    return CGRect(origin: origin, size: extent)
}

func axPID(_ element: AXUIElement) -> pid_t {
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    return pid
}

// MARK: - Windows

struct WindowRef {
    let element: AXUIElement
    let id: CGWindowID
    let title: String
    let minimized: Bool
}

func isUserWindow(_ window: AXUIElement) -> Bool {
    let subrole = axString(window, kAXSubroleAttribute)
    return subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
}

/// The app's windows on the current Space (including minimized ones), front to back.
func appWindows(_ app: NSRunningApplication) -> [WindowRef] {
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    return axElements(axApp, kAXWindowsAttribute).compactMap { (window: AXUIElement) -> WindowRef? in
        guard isUserWindow(window) else { return nil }
        var id: CGWindowID = 0 // stays 0 when the private API is off: listed, but no thumbnail
        if let getWindow = SPI.axGetWindow {
            _ = getWindow(window, &id)
            guard id != 0 else { return nil }
        }
        let title = axString(window, kAXTitleAttribute) ?? ""
        return WindowRef(element: window,
                         id: id,
                         title: title.isEmpty ? (app.localizedName ?? "Window") : title,
                         minimized: axBool(window, kAXMinimizedAttribute) ?? false)
    }
}

/// The window the user was last working in, if it is currently on screen.
func visibleFocusedWindow(of app: NSRunningApplication) -> AXUIElement? {
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
        if let window = axElement(axApp, attribute), axBool(window, kAXMinimizedAttribute) != true {
            return window
        }
    }
    return axElements(axApp, kAXWindowsAttribute).first {
        isUserWindow($0) && axBool($0, kAXMinimizedAttribute) != true
    }
}

/// Brings one specific window of another app to the front and makes it key.
/// Uses SkyLight directly because NSRunningApplication.activate() can't pick a window
/// and is often refused for background agents under cooperative activation.
func focusWindow(_ window: AXUIElement, of app: NSRunningApplication) {
    var windowID: CGWindowID = 0
    _ = SPI.axGetWindow?(window, &windowID)
    var psn = PSN()
    if windowID != 0,
       let getPSN = SPI.getPSN,
       let setFront = SPI.setFrontProcess,
       getPSN(app.processIdentifier, &psn) == 0 {
        _ = setFront(&psn, windowID, 0x200) // kCPSUserGenerated
        makeKeyWindow(&psn, windowID)
    } else {
        _ = app.activate(options: [])
    }
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    axSet(window, kAXMainAttribute, true)
    // Also tell the app itself which window is focused. Without this, an app that is already
    // frontmost can keep its previous window key when switching between its own windows.
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                 kAXFocusedWindowAttribute as CFString, window)
}

/// Posts the synthetic window-server event record that makes a window key
/// (ported via DockDoor/AltTab from Hammerspoon issue #370).
func makeKeyWindow(_ psn: inout PSN, _ windowID: CGWindowID) {
    guard let post = SPI.postEventRecord else { return }
    var bytes = [UInt8](repeating: 0, count: 0xF8)
    bytes[0x04] = 0xF8
    bytes[0x3A] = 0x10
    withUnsafeBytes(of: UInt32(windowID)) { bytes.replaceSubrange(0x3C..<0x40, with: $0) }
    // The location field must be all 0xFF bytes, as in Hammerspoon and AltTab. Writing
    // CGPoint(-1, -1) stores the doubles -1.0 instead, which the window server reads as a real
    // position, so the window was only sometimes made key.
    bytes.replaceSubrange(0x20..<0x30, with: repeatElement(0xFF, count: 0x10))
    bytes[0x08] = 0x01
    _ = post(&psn, &bytes)
    bytes[0x08] = 0x02
    _ = post(&psn, &bytes)
}

/// Thumbnail of one window via SkyLight; nil without Screen Recording permission.
func captureWindow(_ id: CGWindowID) -> CGImage? {
    guard id != 0,
          CGPreflightScreenCaptureAccess(),
          let capture = SPI.captureWindows,
          let connection = SPI.mainConnection else { return nil }
    var windowID = UInt32(id)
    let options: UInt32 = (1 << 11) | (1 << 9) // ignoreGlobalClipShape | nominalResolution
    guard let raw = capture(connection(), &windowID, 1, options) else { return nil }
    let images = Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue() as NSArray
    guard let first = images.firstObject,
          CFGetTypeID(first as CFTypeRef) == CGImage.typeID else { return nil }
    return (first as! CGImage)
}

// MARK: - Minimize history

/// Remembers the order windows were minimized in, so "restore" brings back the most recent one.
final class MinimizeTracker {
    private static let historyLimit = 32 // per app; windows closed while minimized age out
    private var history: [pid_t: [AXUIElement]] = [:] // oldest → newest
    private var observers: [pid_t: AXObserver] = [:]

    func watch(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != getpid(), observers[pid] == nil else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, _ in
            DockPlus.shared.tracker.record(element,
                                           minimized: (notification as String) == kAXWindowMiniaturizedNotification)
            DockPlus.shared.refreshHoverSnapshot()
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let axApp = AXUIElementCreateApplication(pid)
        let a = AXObserverAddNotification(observer, axApp, kAXWindowMiniaturizedNotification as CFString, nil)
        let b = AXObserverAddNotification(observer, axApp, kAXWindowDeminiaturizedNotification as CFString, nil)
        guard a == .success || b == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    func forget(_ pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        history[pid] = nil
    }

    func record(_ window: AXUIElement, minimized: Bool) {
        let pid = axPID(window)
        var list = history[pid] ?? []
        list.removeAll { CFEqual($0, window) }
        if minimized { list.append(window) }
        if list.count > Self.historyLimit { list.removeFirst(list.count - Self.historyLimit) }
        history[pid] = list
    }

    func mostRecentlyMinimized(_ pid: pid_t, among candidates: [AXUIElement]) -> AXUIElement? {
        history[pid]?.last { window in candidates.contains { CFEqual($0, window) } }
    }
}

// MARK: - Hover preview panel

final class WindowTile: NSView {
    let ref: WindowRef
    private let onPick: (WindowRef, Bool) -> Void
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(window ref: WindowRef, placeholder: NSImage?, frame: NSRect, onPick: @escaping (WindowRef, Bool) -> Void) {
        self.ref = ref
        self.onPick = onPick
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8

        imageView.frame = NSRect(x: 6, y: 24, width: frame.width - 12, height: frame.height - 30)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = placeholder
        imageView.alphaValue = ref.minimized ? 0.55 : 1

        label.frame = NSRect(x: 6, y: 4, width: frame.width - 12, height: 16)
        label.font = .systemFont(ofSize: 11)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.textColor = ref.minimized ? .secondaryLabelColor : .labelColor
        label.stringValue = ref.minimized ? "(minimized) \(ref.title)" : ref.title

        addSubview(imageView)
        addSubview(label)
        toolTip = ref.title
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setThumbnail(_ image: NSImage) { imageView.image = image }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
    }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
    // Act on mouse-up, like a button: acting on mouse-down hid the panel while the button was
    // still held, and the stray mouse-up then landed on the app's current window.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPick(ref, event.modifierFlags.contains(.option))
    }
}

final class WindowPreview {
    private let panel: NSPanel
    private let background = NSVisualEffectView()
    private var tiles: [WindowTile] = []
    private var anchor: NSRect = .zero      // hovered Dock icon, Cocoa coordinates
    private var edge: NSRectEdge = .minY    // which screen edge the Dock is on
    private var trackTimer: Timer?
    private var outsideSince: Date?
    private var generation = 0
    private(set) var shownPID: pid_t?
    /// Called with the panel's frame in Quartz coordinates when it appears, and nil when it hides.
    var onFrameChange: ((CGRect?) -> Void)?

    var isVisible: Bool { panel.isVisible }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        // Thumbnails can show windows that are covered, so keep the panel out of screen sharing
        // and recordings. Not every capture tool honors this on recent macOS versions.
        panel.sharingType = .none

        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = WindowPreview.roundedMask(radius: 14)
        panel.contentView = background
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let size = NSSize(width: radius * 2 + 1, height: radius * 2 + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    func show(app: NSRunningApplication, anchor quartzAnchor: CGRect, dockFrame: CGRect?) {
        let windows = appWindows(app)
        guard !windows.isEmpty else { hide(); return }
        generation += 1
        let thisGeneration = generation
        shownPID = app.processIdentifier

        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        func toCocoa(_ r: CGRect) -> NSRect {
            NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
        }
        anchor = toCocoa(quartzAnchor)
        let center = NSPoint(x: anchor.midX, y: anchor.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }

        let dock = dockFrame.map(toCocoa) ?? anchor
        if dock.width >= dock.height {
            edge = .minY
        } else if dock.midX < screen.frame.midX {
            edge = .minX
        } else {
            edge = .maxX
        }

        // Grid of tiles: a row along a bottom Dock, a column along a side Dock.
        let tile = NSSize(width: 220, height: 160)
        let gap: CGFloat = 8, pad: CGFloat = 10, header: CGFloat = 24
        let limit = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let count = windows.count
        let cols: Int
        let rows: Int
        if edge == .minY {
            let fit = max(1, Int((limit.width - 2 * pad + gap) / (tile.width + gap)))
            cols = min(count, fit)
            rows = (count + cols - 1) / cols
        } else {
            let fit = max(1, Int((limit.height - 2 * pad - header + gap) / (tile.height + gap)))
            rows = min(count, fit)
            cols = (count + rows - 1) / rows
        }
        let gridWidth = CGFloat(cols) * tile.width + CGFloat(cols - 1) * gap
        let gridHeight = CGFloat(rows) * tile.height + CGFloat(rows - 1) * gap
        let size = NSSize(width: gridWidth + 2 * pad, height: gridHeight + 2 * pad + header)

        background.subviews.forEach { $0.removeFromSuperview() }
        tiles = []

        let title = NSTextField(labelWithString: app.localizedName ?? "")
        title.font = .boldSystemFont(ofSize: 12)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: pad + 4, y: pad + gridHeight + 4, width: size.width - 2 * pad - 8, height: 16)
        background.addSubview(title)

        let icon = app.icon
        for (index, window) in windows.enumerated() {
            let row = index / cols
            let col = index % cols
            let frame = NSRect(x: pad + CGFloat(col) * (tile.width + gap),
                               y: pad + CGFloat(rows - 1 - row) * (tile.height + gap),
                               width: tile.width, height: tile.height)
            let view = WindowTile(window: window, placeholder: icon, frame: frame) { [weak self] picked, option in
                self?.pick(picked, of: app, toggleMinimize: option)
            }
            background.addSubview(view)
            tiles.append(view)
        }

        var origin: NSPoint
        switch edge {
        case .minX: origin = NSPoint(x: anchor.maxX + 10, y: anchor.midY - size.height / 2)
        case .maxX: origin = NSPoint(x: anchor.minX - 10 - size.width, y: anchor.midY - size.height / 2)
        default: origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 10)
        }
        origin.x = min(max(origin.x, limit.minX), limit.maxX - size.width)
        origin.y = min(max(origin.y, screen.frame.minY + 4), screen.frame.maxY - size.height - 4)

        let panelFrame = NSRect(origin: origin, size: size)
        panel.setFrame(panelFrame, display: true)
        panel.orderFrontRegardless()
        onFrameChange?(CGRect(x: panelFrame.minX, y: primaryHeight - panelFrame.maxY,
                              width: panelFrame.width, height: panelFrame.height))
        panel.invalidateShadow()
        startTracking()

        // Capture thumbnails off the main thread, then swap them in. Minimized windows and
        // hidden apps keep the app icon: minimized windows aren't reliably capturable, and a
        // hidden app's windows were deliberately put out of sight.
        let skipCapture = app.isHidden
        let ids = windows.map { skipCapture || $0.minimized ? nil : $0.id }
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let images = ids.map { id in id.flatMap(captureWindow) }
            DispatchQueue.main.async {
                guard let self, self.generation == thisGeneration else { return }
                for (tile, image) in zip(self.tiles, images) {
                    if let image { tile.setThumbnail(NSImage(cgImage: image, size: .zero)) }
                }
            }
        }
    }

    func hide() {
        generation += 1
        panel.orderOut(nil)
        shownPID = nil
        stopTracking()
        onFrameChange?(nil)
    }

    private func pick(_ window: WindowRef, of app: NSRunningApplication, toggleMinimize: Bool) {
        hide()
        if toggleMinimize {
            axSet(window.element, kAXMinimizedAttribute, !window.minimized)
            return
        }
        let wasHidden = app.isHidden
        if wasHidden { app.unhide() }
        if window.minimized { axSet(window.element, kAXMinimizedAttribute, false) }
        focusWindow(window.element, of: app)
        // A window that is still animating out of the Dock, or an app that is still unhiding,
        // can ignore the first focus request, so repeat it once that has finished.
        if wasHidden || window.minimized {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focusWindow(window.element, of: app) }
        }
    }

    // Close the panel once the pointer has left both the icon and the panel for a moment.
    private func startTracking() {
        outsideSince = nil
        guard trackTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkPointer() }
        RunLoop.main.add(timer, forMode: .common)
        trackTimer = timer
    }

    private func stopTracking() {
        trackTimer?.invalidate()
        trackTimer = nil
        outsideSince = nil
    }

    private func checkPointer() {
        guard panel.isVisible else { stopTracking(); return }
        let pointer = NSEvent.mouseLocation
        let frame = panel.frame
        let bridge: NSRect // the icon plus the gap between it and the panel
        switch edge {
        case .minX: bridge = NSRect(x: anchor.minX, y: anchor.minY, width: frame.minX - anchor.minX, height: anchor.height)
        case .maxX: bridge = NSRect(x: frame.maxX, y: anchor.minY, width: anchor.maxX - frame.maxX, height: anchor.height)
        default: bridge = NSRect(x: anchor.minX, y: anchor.minY, width: anchor.width, height: frame.minY - anchor.minY)
        }
        if frame.insetBy(dx: -6, dy: -6).contains(pointer) || bridge.insetBy(dx: -6, dy: -6).contains(pointer) {
            outsideSince = nil
        } else if let since = outsideSince {
            if Date().timeIntervalSince(since) > 0.2 { hide() }
        } else {
            outsideSince = Date()
        }
    }
}

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

    private let defaults = UserDefaults.standard // thread-safe; also read on the tap thread
    private var doubleClickEnabled: Bool { defaults.bool(forKey: "doubleClickToggle") }
    private var hoverEnabled: Bool { defaults.bool(forKey: "hoverPreviews") }

    // Main thread only
    private var dockPID: pid_t = 0
    private var dockList: AXUIElement?
    private var dockObserver: AXObserver?
    private var pendingShow: DispatchWorkItem?
    private var askedForScreenCapture = false
    private var suppressedItem: AXUIElement? // Dock icon last right-clicked; no previews for now
    private var statusItem: NSStatusItem?
    private var started = false

    // Shared with the event-tap thread
    private let tapState = Locked(TapState())
    private var eventTap: CFMachPort?  // set once, before the tap thread starts
    private var tapThread: Thread?

    func applicationDidFinishLaunching(_ notification: Notification) {
        preview.onFrameChange = { [tapState = self.tapState] frame in
            tapState.with { s in
                s.previewFrame = frame
                if let frame { s.lastPreviewFrame = frame }
            }
        }
        migrateLegacySettings()
        defaults.register(defaults: ["doubleClickToggle": true, "hoverPreviews": true])
        setUpMenu()
        // Screen Recording is requested later, only when a hover preview is about to appear.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            start()
        } else {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.start()
            }
        }
    }

    /// Copies settings saved under the old bundle ID, local.dockplus. Never overwrites a
    /// setting saved under the current ID, so it's safe on every launch. Must run before
    /// defaults are registered. (Accessibility, Screen Recording and Open at Login are tied
    /// to the ID by macOS and can't be carried over.)
    private func migrateLegacySettings() {
        guard let old = defaults.persistentDomain(forName: "local.dockplus") else { return }
        for key in ["doubleClickToggle", "hoverPreviews"] where defaults.object(forKey: key) == nil {
            if let value = old[key] { defaults.set(value, forKey: key) }
        }
    }

    private func start() {
        guard !started else { return }
        started = true
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        attachToDock()
        installEventTap()

        for app in NSWorkspace.shared.runningApplications { tracker.watch(app) }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.tracker.watch(app) }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.tracker.forget(app.processIdentifier)
            if self.preview.shownPID == app.processIdentifier { self.preview.hide() }
        }
        // Keep the hovered app's snapshot current while the pointer rests on its icon.
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshHoverSnapshot()
            }
        }

        // The Dock restarts on `killall Dock`, display changes, etc. Re-attach when its pid changes.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            let current = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
            if current != self.dockPID || self.dockList == nil { self.attachToDock() } else { self.readMagnification() }
        }
    }

    // MARK: Dock

    private func attachToDock() {
        if let old = dockObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .commonModes)
            dockObserver = nil
        }
        dockList = nil
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
        let listFrame = axFrame(list)
        tapState.with { $0.dockListFrame = listFrame }
        readMagnification()

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, _ in DockPlus.shared.dockSelectionChanged() }
        guard AXObserverCreate(dockPID, callback, &observer) == .success, let observer else { return }
        AXObserverAddNotification(observer, list, kAXSelectedChildrenChangedNotification as CFString, nil)
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

        guard let hover = found else {
            pendingShow?.cancel()
            return // the panel's own pointer tracking decides when to close
        }
        guard hoverEnabled else { return }
        let item = hover.item
        let app = hover.app
        if preview.isVisible && preview.shownPID == app.processIdentifier { return }
        requestScreenCaptureIfNeeded()
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

    /// Screen Recording is only needed for thumbnails, so it's requested the first time a
    /// preview is about to appear rather than at launch.
    private func requestScreenCaptureIfNeeded() {
        guard !askedForScreenCapture, !CGPreflightScreenCaptureAccess() else { return }
        askedForScreenCapture = true
        _ = CGRequestScreenCaptureAccess()
    }

    // MARK: Double-click

    private func installEventTap() {
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
            return
        }
        CGEvent.tapEnable(tap: tap, enable: false) // enabled once its thread is serving it
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        // The tap gets its own thread, so work on the main thread (Accessibility calls into
        // other apps, the preview panel) can never hold up system-wide mouse input.
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "DockPlus event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        tapThread = thread
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
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
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
        }) else { return pass }

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

    // MARK: Menu bar

    private func setUpMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "DockPlus") {
            item.button?.image = image
        } else {
            item.button?.title = "Dock+"
        }
        let menu = NSMenu()
        if !SPI.enabled {
            let note = NSMenuItem(title: "Limited mode: untested macOS version", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
            menu.addItem(.separator())
        }
        menu.addItem(toggleItem("Double-click icon: minimize / restore window", key: "doubleClickToggle"))
        menu.addItem(toggleItem("Hover icon: show all windows", key: "hoverPreviews"))
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let privacy = NSMenuItem(title: "Privacy & Security Settings…", action: #selector(openPrivacy), keyEquivalent: "")
        privacy.target = self
        menu.addItem(privacy)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DockPlus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
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
        let value = !defaults.bool(forKey: key)
        defaults.set(value, forKey: key)
        sender.state = value ? .on : .off
        if key == "hoverPreviews" && !value { preview.hide() }
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // Never interpolate into NSLog's format string; pass values as arguments.
            NSLog("DockPlus: could not change login item: %@", error as NSError)
        }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func openPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Entry point

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = DockPlus.shared
application.run()
