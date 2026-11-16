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

/// If the frontmost app has no windows left on this Space, focuses the frontmost window of
/// the next app in z-order, so focus doesn't stay on an app with nothing on screen. If no
/// app has a window on screen any more, Finder (the desktop) gets focus instead.
func focusNextWindowIfNoneLeft(in app: NSRunningApplication) {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
          !app.isHidden,
          !appWindows(app).contains(where: { !$0.minimized }) else { return }
    guard let found = frontmostWindow(excluding: app.processIdentifier) else {
        // Every window is minimized. Activating Finder this way doesn't open a new window.
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
           finder.processIdentifier != app.processIdentifier {
            _ = finder.activate(options: [])
        }
        return
    }
    let (next, window) = found
    if let window {
        focusWindow(window, of: next)
    } else {
        _ = next.activate(options: [])
    }
}

/// The frontmost on-screen app window not owned by `pid` (or DockPlus), as its app and,
/// when it can be matched, its Accessibility element.
func frontmostWindow(excluding pid: pid_t) -> (NSRunningApplication, AXUIElement?)? {
    let ownPID = ProcessInfo.processInfo.processIdentifier
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] else { return nil }
    for info in list { // front to back
        guard (info[kCGWindowLayer as String] as? Int) == 0,
              let owner = info[kCGWindowOwnerPID as String] as? pid_t,
              owner != pid, owner != ownPID,
              (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict),
              bounds.width >= 50, bounds.height >= 50,
              let app = NSRunningApplication(processIdentifier: owner),
              app.activationPolicy != .prohibited, !app.isHidden else { continue }
        let id = info[kCGWindowNumber as String] as? CGWindowID ?? 0
        let match = appWindows(app).first { $0.id == id && !$0.minimized }?.element
        guard match != nil || SPI.axGetWindow == nil else { continue } // not a user window
        return (app, match)
    }
    return nil
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

/// A copy of `image` no larger than a hover tile needs (at 2x), so cached thumbnails stay small.
func downscaled(_ image: CGImage, maxSize: CGSize = CGSize(width: 440, height: 320)) -> CGImage {
    let scale = min(1, maxSize.width / CGFloat(image.width), maxSize.height / CGFloat(image.height))
    guard scale < 1 else { return image }
    let width = max(1, Int(CGFloat(image.width) * scale))
    let height = max(1, Int(CGFloat(image.height) * scale))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return image }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage() ?? image
}

// MARK: - Last-seen thumbnails

/// The last thumbnail captured of each window while it was on screen. A minimized window
/// can't be captured reliably, so the hover panel shows what it looked like when it was
/// last seen, ideally just before it was minimized. Main thread only; kept in memory only,
/// downscaled, one per window, limited in number, and dropped once older than the lifetime
/// the user chose ("thumbnailLifetime").
final class ThumbnailCache {
    private static let limit = 64
    private var entries: [CGWindowID: (pid: pid_t, image: CGImage, stamp: UInt64, captured: UInt64)] = [:]
    private var counter: UInt64 = 0

    /// Choices offered for how long a picture is kept, in seconds; 0 keeps it until the app
    /// quits (or DockPlus does).
    static let lifetimes: [(seconds: Int, title: String)] = [
        (5 * 60, "5 Minutes"),
        (15 * 60, "15 Minutes"),
        (60 * 60, "1 Hour"),
        (24 * 60 * 60, "1 Day"),
        (0, "Until the App Quits"),
    ]
    static let defaultLifetime = 0 // until the app quits

    /// Seconds since an arbitrary point, counting time asleep and unaffected by clock changes,
    /// so a picture expires on time even across sleep or a changed system clock.
    private static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000_000_000 }

    private var lifetime: UInt64 { UInt64(max(0, UserDefaults.standard.integer(forKey: "thumbnailLifetime"))) }

    func image(for id: CGWindowID) -> CGImage? {
        removeExpired()
        return entries[id]?.image
    }

    /// Drops pictures older than the chosen lifetime. Runs every 2 seconds, when the lifetime
    /// is changed, and before any picture is shown.
    func removeExpired() {
        let lifetime = self.lifetime
        guard lifetime > 0, !entries.isEmpty else { return }
        let now = Self.now()
        entries = entries.filter { now - $0.value.captured < lifetime }
    }

    func store(_ image: CGImage, for id: CGWindowID, pid: pid_t) {
        // A capture can finish after its app quit or previews were turned off; don't keep it then.
        guard id != 0, UserDefaults.standard.bool(forKey: "hoverPreviews"),
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        counter += 1
        entries[id] = (pid, image, counter, Self.now())
        if entries.count > Self.limit, let oldest = entries.min(by: { $0.value.stamp < $1.value.stamp }) {
            entries[oldest.key] = nil
        }
    }

    func forget(_ pid: pid_t) {
        entries = entries.filter { $0.value.pid != pid }
    }

    /// Drops every picture, e.g. when hover previews are turned off.
    func removeAll() {
        entries.removeAll()
        lastClickCapture = .distantPast
    }

    private var lastClickCapture = Date.distantPast

    /// Captures a window now, on the calling (main) thread. Used right before DockPlus itself
    /// minimizes a window, so the cached image is exactly what was on screen.
    func captureNow(_ window: AXUIElement) {
        var id: CGWindowID = 0
        _ = SPI.axGetWindow?(window, &id)
        guard id != 0, let image = captureWindow(id) else { return }
        store(downscaled(image), for: id, pid: axPID(window))
    }

    /// Captures the normal app window under a screen point (Quartz coordinates), off the main
    /// thread. Uses only the window server, never Accessibility, since it runs on every click.
    func refreshWindow(at point: CGPoint) {
        // At most one click capture per half second, so rapid clicking stays cheap.
        guard Date().timeIntervalSince(lastClickCapture) > 0.5 else { return }
        lastClickCapture = Date()
        let me = getpid()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                        kCGNullWindowID) as? [[String: Any]] else { return }
            // Front to back: the first window containing the point is the one clicked.
            guard let hit = list.first(where: { info in
                guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return false }
                return bounds.contains(point)
            }),
                  (hit[kCGWindowLayer as String] as? Int) == 0,
                  let pid = (hit[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != me,
                  let number = hit[kCGWindowNumber as String] as? NSNumber else { return }
            let id = CGWindowID(number.uint32Value)
            guard let image = captureWindow(id).map({ downscaled($0) }) else { return }
            // Minimized while this was being captured: keep the earlier, clean image.
            let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]]
            guard (info?.first?[kCGWindowIsOnscreen as String] as? Bool) == true else { return }
            DispatchQueue.main.async { self?.store(image, for: id, pid: pid) }
        }
    }

    /// Captures a window that is on screen, off the main thread, and caches the result.
    func refresh(_ window: AXUIElement) {
        var id: CGWindowID = 0
        _ = SPI.axGetWindow?(window, &id)
        // Only standard windows: sheets, panels and dialogs would just use up cache slots.
        guard id != 0, CGPreflightScreenCaptureAccess(),
              axString(window, kAXSubroleAttribute) == kAXStandardWindowSubrole,
              axBool(window, kAXMinimizedAttribute) != true else { return }
        let pid = axPID(window)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let image = captureWindow(id).map({ downscaled($0) }) else { return }
            DispatchQueue.main.async {
                // Minimized while this was being captured: keep the earlier, clean image.
                guard axBool(window, kAXMinimizedAttribute) != true else { return }
                self?.store(image, for: id, pid: pid)
            }
        }
    }
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
            if (notification as String) == kAXFocusedWindowChangedNotification {
                // Remember what a window looks like whenever the user switches to it, so a
                // later minimize has a recent picture to show in the hover panel.
                DockPlus.shared.cacheThumbnail(of: element, after: 0.3)
                return
            }
            let minimized = (notification as String) == kAXWindowMiniaturizedNotification
            DockPlus.shared.tracker.record(element, minimized: minimized)
            DockPlus.shared.refreshHoverSnapshot()
            if minimized { DockPlus.shared.windowMinimized(in: axPID(element)) }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let axApp = AXUIElementCreateApplication(pid)
        let a = AXObserverAddNotification(observer, axApp, kAXWindowMiniaturizedNotification as CFString, nil)
        let b = AXObserverAddNotification(observer, axApp, kAXWindowDeminiaturizedNotification as CFString, nil)
        guard a == .success || b == .success else { return }
        _ = AXObserverAddNotification(observer, axApp, kAXFocusedWindowChangedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    func forget(_ pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        history[pid] = nil
    }

    /// Stops watching every app, e.g. when Accessibility is taken away.
    func forgetAll() {
        for pid in Array(observers.keys) { forget(pid) }
        history.removeAll()
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
        // Minimized windows show their last-seen picture slightly faded (or the app icon
        // when none was captured), alongside the "(minimized)" label.
        imageView.alphaValue = ref.minimized ? 0.7 : 1

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
    let thumbnails = ThumbnailCache()
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
        let skipCapture = app.isHidden
        for (index, window) in windows.enumerated() {
            let row = index / cols
            let col = index % cols
            let frame = NSRect(x: pad + CGFloat(col) * (tile.width + gap),
                               y: pad + CGFloat(rows - 1 - row) * (tile.height + gap),
                               width: tile.width, height: tile.height)
            // A minimized window shows how it looked when it was last on screen.
            let lastSeen = window.minimized && !skipCapture
                ? thumbnails.image(for: window.id).map { NSImage(cgImage: $0, size: .zero) } : nil
            let view = WindowTile(window: window, placeholder: lastSeen ?? icon, frame: frame) { [weak self] picked, option in
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

        // Capture thumbnails off the main thread, then swap them in, and remember each one for
        // when that window is later minimized. Minimized windows aren't reliably capturable, so
        // they keep the cached picture set above. Hidden apps keep the app icon: their windows
        // were deliberately put out of sight.
        let ids = windows.map { skipCapture || $0.minimized ? nil : $0.id }
        let pid = app.processIdentifier
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let images = ids.map { id in id.flatMap(captureWindow) }
            let small = images.map { $0.map { downscaled($0) } }
            DispatchQueue.main.async {
                guard let self else { return }
                for (id, image) in zip(ids, small) {
                    if let id, let image { self.thumbnails.store(image, for: id, pid: pid) }
                }
                guard self.generation == thisGeneration else { return }
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
            if !window.minimized && !app.isHidden { thumbnails.captureNow(window.element) } // picture for later
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

final class DockPlus: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
    private var pendingHandoff: DispatchWorkItem?
    private var suppressedItem: AXUIElement? // Dock icon last right-clicked; no previews for now
    private var statusItem: NSStatusItem?
    private var started = false
    private var tapFailed = false            // the event tap couldn't be created
    private var workspaceObservers: [NSObjectProtocol] = []
    private var dockTimer: Timer?
    private var couldCapture = false         // Screen Recording at the last permission check
    private var promptedForAccessibility = false
    private var setup: SetupWindow?

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

    // MARK: Permissions and setup

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
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let self, self.started else { return }
                self.tracker.watch(app)
            }
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
    private func stop() {
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

    // MARK: Menu bar

    private func setUpMenu() {
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
    private func updateStatusIcon(needsAttention: Bool) {
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

// MARK: - Entry point

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = DockPlus.shared
application.run()
