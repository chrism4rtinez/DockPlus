import Cocoa
import ApplicationServices

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
