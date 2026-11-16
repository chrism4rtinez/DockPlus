import Cocoa
import ApplicationServices

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
    // Set while the panel was opened from the keyboard: it stays open while this returns true,
    // even with the pointer elsewhere.
    private var keepOpen: (() -> Bool)?
    var openedFromKeyboard: Bool { panel.isVisible && keepOpen != nil }
    /// Called with the panel's frame in Quartz coordinates when it appears, and nil when it hides.
    var onFrameChange: ((CGRect?) -> Void)?
    /// Whether the Dock is on screen. Unless the pointer is on the panel, the panel closes as
    /// soon as this turns false, when an automatically hidden Dock starts to slide away.
    var dockIsShown: (() -> Bool)?

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

    /// Shows the panel for `app` next to its Dock icon. Opened from a hover, it closes once the
    /// pointer has left the icon and the panel. Opened from the keyboard, pass `keepOpen`: the
    /// panel then also stays open while that returns true (the Dock still has that icon focused).
    func show(app: NSRunningApplication, anchor quartzAnchor: CGRect, dockFrame: CGRect?,
              keepOpen: (() -> Bool)? = nil) {
        let windows = appWindows(app)
        guard !windows.isEmpty else { hide(); return }
        self.keepOpen = keepOpen
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
        keepOpen = nil
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

    /// Re-checks at once whether the panel should still be open, instead of at the next tick.
    func recheck() {
        guard panel.isVisible else { return }
        checkPointer()
    }

    // The panel stays open while the pointer is on it. Otherwise it closes as soon as the Dock
    // hides, and once the pointer has left both the icon and the panel for a moment. A panel
    // opened from the keyboard closes as soon as the Dock no longer has that icon focused.
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
        // The pointer on the panel always keeps it open, even while the Dock hides.
        if frame.insetBy(dx: -6, dy: -6).contains(pointer) {
            outsideSince = nil
            return
        }
        if dockIsShown?() == false { hide(); return }
        if let keepOpen {
            if keepOpen() { outsideSince = nil } else { hide() }
            return
        }
        let bridge: NSRect // the icon plus the gap between it and the panel
        switch edge {
        case .minX: bridge = NSRect(x: anchor.minX, y: anchor.minY, width: frame.minX - anchor.minX, height: anchor.height)
        case .maxX: bridge = NSRect(x: frame.maxX, y: anchor.minY, width: anchor.maxX - frame.maxX, height: anchor.height)
        default: bridge = NSRect(x: anchor.minX, y: anchor.minY, width: anchor.width, height: frame.minY - anchor.minY)
        }
        if bridge.insetBy(dx: -6, dy: -6).contains(pointer) {
            outsideSince = nil
        } else if let since = outsideSince {
            if Date().timeIntervalSince(since) > 0.2 { hide() }
        } else {
            outsideSince = Date()
        }
    }
}
