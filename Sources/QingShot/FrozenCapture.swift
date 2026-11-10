import AppKit
import ScreenCaptureKit

extension NSScreen {
    var displayID: CGDirectDisplayID? { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
}

extension NSImage {
    // NSImage(cgImage:size:) creates an NSCGImageSnapshotRep whose pixelsWide follows the
    // current display scale on Retina (e.g. a 1512 px image reports 3024 px). Wrap the
    // CGImage in a bitmap rep so pixelSize always describes the real pixels.
    convenience init(pixelImage cgImage: CGImage) {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(width: cgImage.width, height: cgImage.height)
        self.init(size: rep.size)
        addRepresentation(rep)
    }
}

// A display frozen at the moment the capture was triggered. `frame` uses NSScreen's
// bottom-left global coordinate space; image pixels are top-left based.
struct FrozenFrame {
    let displayID: CGDirectDisplayID
    let frame: NSRect
    let image: NSImage
    let cgImage: CGImage
    // The CGImage is the source of truth: never derive this from NSImage.pixelSize.
    var scale: CGFloat { frame.width > 0 ? CGFloat(cgImage.width) / frame.width : 1 }
}

struct FrozenWindow {
    let id: CGWindowID
    let owner: String
    let title: String
    let frame: NSRect
}

enum FrozenCapture {
    struct Snapshot {
        let frames: [FrozenFrame]
        let windows: [FrozenWindow]
    }

    // Grabs every connected display at once, plus the on-screen window list, so the
    // selection UI never shows anything that happened after the trigger.
    @MainActor
    static func take() async throws -> Snapshot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excluded = content.applications.filter { $0.processID == ownPID }
        var screens: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens { if let id = screen.displayID { screens[id] = screen } }
        // Snapshot the window list before grabbing displays so both describe the same moment.
        let visible = Set(content.windows.filter { $0.isOnScreen && $0.windowLayer == 0 && $0.owningApplication?.processID != ownPID }.map(\.windowID))
        let windows = onScreenWindows(ids: visible)
        let shots = try await withThrowingTaskGroup(of: (CGDirectDisplayID, CGImage).self) { group -> [(CGDirectDisplayID, CGImage)] in
            for display in content.displays {
                group.addTask {
                    let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
                    // SCDisplay.width/height are points; SCStreamConfiguration width/height
                    // are pixels. Scale by the filter's point-to-pixel factor for native output.
                    let pixelScale = CGFloat(filter.pointPixelScale)
                    let config = SCStreamConfiguration()
                    config.width = max(1, Int((CGFloat(display.width) * pixelScale).rounded()))
                    config.height = max(1, Int((CGFloat(display.height) * pixelScale).rounded()))
                    config.captureResolution = .best
                    config.showsCursor = false
                    return (display.displayID, try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config))
                }
            }
            var result: [(CGDirectDisplayID, CGImage)] = []
            for try await shot in group { result.append(shot) }
            return result
        }
        let frames = shots.compactMap { id, cg -> FrozenFrame? in
            guard let screen = screens[id] else { return nil }
            return FrozenFrame(displayID: id, frame: screen.frame, image: NSImage(pixelImage: cg), cgImage: cg)
        }
        guard !frames.isEmpty else { throw CocoaError(.featureUnsupported) }
        return Snapshot(frames: frames, windows: windows)
    }

    // CGWindowListCopyWindowInfo is documented front-to-back, which gives us both the
    // hit-testing order and plain window frames. Intersect with ScreenCaptureKit's list
    // so only windows visible in the frozen space are considered.
    private static func onScreenWindows(ids: Set<CGWindowID>) -> [FrozenWindow] {
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  ids.contains(number),
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.01,
                  let raw = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: raw as CFDictionary),
                  rect.width >= 20, rect.height >= 20 else { return nil }
            return FrozenWindow(id: number,
                                owner: info[kCGWindowOwnerName as String] as? String ?? "",
                                title: info[kCGWindowName as String] as? String ?? "",
                                frame: NSRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height))
        }
    }

    // Crops a global (NSScreen space) rectangle out of the frozen frames at native pixel
    // resolution. Windows spanning displays are composited from each frozen frame.
    static func crop(_ frames: [FrozenFrame], rect: NSRect) -> NSImage? {
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let parts = frames.compactMap { source -> (FrozenFrame, CGRect, CGRect)? in
            let overlap = source.frame.intersection(rect)
            guard !overlap.isEmpty else { return nil }
            let scale = source.scale
            let crop = CGRect(x: (overlap.minX - source.frame.minX) * scale,
                              y: (source.frame.maxY - overlap.maxY) * scale,
                              width: overlap.width * scale,
                              height: overlap.height * scale).integral
                .intersection(CGRect(x: 0, y: 0, width: source.cgImage.width, height: source.cgImage.height))
            guard !crop.isEmpty else { return nil }
            return (source, crop, CGRect(x: overlap.minX - rect.minX, y: rect.maxY - overlap.maxY, width: overlap.width, height: overlap.height))
        }
        guard let primary = parts.max(by: { $0.2.width * $0.2.height < $1.2.width * $1.2.height }) else { return nil }
        let scale = primary.0.scale
        return Renderer.bitmap(size: CGSize(width: rect.width * scale, height: rect.height * scale)) {
            for (source, crop, dest) in parts {
                guard let piece = source.cgImage.cropping(to: crop) else { continue }
                let image = NSImage(pixelImage: piece)
                Renderer.drawImage(image, in: CGRect(x: dest.minX * scale, y: dest.minY * scale, width: dest.width * scale, height: dest.height * scale))
            }
        }
    }
}

// Optional diagnostics: `defaults write local.qingshot.capture debugCapture -bool true`
// writes frozen displays, frames/scales, the selection and the crop to ~/Library/Caches/QingShot/debug.
@MainActor enum CaptureDebug {
    static var enabled: Bool { UserDefaults.standard.bool(forKey:"debugCapture") }
    private static var folder: URL?

    private static var baseURL: URL {
        FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("QingShot/debug",isDirectory:true)
    }

    static func begin(_ snapshot:FrozenCapture.Snapshot, mode:String) {
        guard enabled else { return }
        let stamp = ISO8601DateFormatter().string(from:Date()).replacingOccurrences(of:":",with:"-")
        let dir = baseURL.appendingPathComponent("\(stamp)-\(mode)",isDirectory:true)
        guard (try? FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)) != nil else { return }
        folder = dir
        var lines = ["QingShot capture debug","date: \(Date())","mode: \(mode)","","screens:"]
        for screen in NSScreen.screens {
            lines.append("  id=\(screen.displayID ?? 0) frame=\(screen.frame) visible=\(screen.visibleFrame) scale=\(screen.backingScaleFactor)")
        }
        lines += ["","frozen frames:"]
        for frame in snapshot.frames {
            lines.append("  id=\(frame.displayID) frame=\(frame.frame) cg=\(frame.cgImage.width)x\(frame.cgImage.height) image=\(frame.image.pixelSize) scale=\(frame.scale)")
            if let data = frame.image.png { try? data.write(to:dir.appendingPathComponent("display-\(frame.displayID).png")) }
        }
        lines += ["","windows:"]
        for window in snapshot.windows {
            lines.append("  id=\(window.id) frame=\(window.frame) owner=\(window.owner) title=\(window.title)")
        }
        try? lines.joined(separator:"\n").write(to:dir.appendingPathComponent("snapshot.txt"),atomically:true,encoding:.utf8)
    }

    static func finish(selection:NSRect?, output:NSImage?) {
        guard let dir = folder else { return }
        folder = nil
        var lines = ["selection: \(selection.map { "\($0)" } ?? "none")"]
        if let selection {
            for screen in NSScreen.screens {
                let overlap = selection.intersection(screen.frame)
                let local = NSRect(x:selection.minX-screen.frame.minX,y:screen.frame.maxY-selection.maxY,width:selection.width,height:selection.height)
                lines.append("  screen id=\(screen.displayID ?? 0) frame=\(screen.frame) scale=\(screen.backingScaleFactor) overlap=\(overlap) local=\(local)")
            }
        }
        lines.append("output: \(output.map { "\($0.pixelSize)" } ?? "none")")
        try? lines.joined(separator:"\n").write(to:dir.appendingPathComponent("selection.txt"),atomically:true,encoding:.utf8)
        if let output,let data = output.png { try? data.write(to:dir.appendingPathComponent("output.png")) }
    }

    static func fail(_ error:Error) {
        guard enabled else { return }
        try? FileManager.default.createDirectory(at:baseURL,withIntermediateDirectories:true)
        try? "error: \(error)".write(to:baseURL.appendingPathComponent("last-error.txt"),atomically:true,encoding:.utf8)
    }
}

// Keeps the frozen frames on screen while the user picks a region or window.
@MainActor final class FrozenCaptureSession {
    private let snapshot: FrozenCapture.Snapshot
    private let mode: String
    private let completion: (NSImage?) -> Void
    private var windows: [FrozenOverlayWindow] = []
    private var finished = false
    private static let overlayLevel = NSWindow.Level.screenSaver

    init(snapshot: FrozenCapture.Snapshot, mode: String, completion: @escaping (NSImage?) -> Void) {
        self.snapshot = snapshot
        self.mode = mode
        self.completion = completion
    }

    func start() {
        let mouse = NSEvent.mouseLocation
        for frame in snapshot.frames {
            let window = FrozenOverlayWindow(contentRect: frame.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.level = Self.overlayLevel
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.acceptsMouseMovedEvents = true
            let view = FrozenOverlayView(frame: frame, windows: snapshot.windows, mode: mode)
            view.onCapture = { [weak self] rect in self?.finish(rect) }
            view.onCancel = { [weak self] in self?.finish(nil) }
            window.contentView = view
            window.makeFirstResponder(view)
            window.orderFrontRegardless()
            windows.append(window)
        }
        (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKeyAndOrderFront(nil)
    }

    func cancel() { finish(nil) }

    private func finish(_ rect: NSRect?) {
        guard !finished else { return }
        finished = true
        let result = rect.flatMap { FrozenCapture.crop(snapshot.frames, rect: $0) }
        CaptureDebug.finish(selection:rect,output:result)
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        completion(result)
    }
}

final class FrozenOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class FrozenOverlayView: NSView {
    private let frozen: FrozenFrame
    private let windows: [FrozenWindow]
    private let mode: String
    var onCapture: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?
    private var hovered: FrozenWindow?

    init(frame: FrozenFrame, windows: [FrozenWindow], mode: String) {
        self.frozen = frame
        self.windows = windows
        self.mode = mode
        super.init(frame: NSRect(origin: .zero, size: frame.frame.size))
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var dragRect: NSRect? {
        guard mode == "area", let start, let current else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    // Selected region in NSScreen global coordinates.
    private var dragGlobalRect: NSRect? {
        guard let rect = dragRect else { return nil }
        return NSRect(x: frozen.frame.minX + rect.minX, y: frozen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        Renderer.drawImage(frozen.image, in: bounds)
        if mode == "area" { drawArea() } else { drawWindows() }
    }

    private func drawArea() {
        NSColor.black.withAlphaComponent(dragRect == nil ? 0.35 : 0.45).setFill()
        guard let rect = dragRect, rect.width >= 1, rect.height >= 1 else {
            NSBezierPath(rect: bounds).fill()
            return
        }
        let r = rect.integral.intersection(bounds)
        for region in [NSRect(x: 0, y: 0, width: bounds.width, height: r.minY),
                       NSRect(x: 0, y: r.maxY, width: bounds.width, height: bounds.height - r.maxY),
                       NSRect(x: 0, y: r.minY, width: r.minX, height: r.height),
                       NSRect(x: r.maxX, y: r.minY, width: bounds.width - r.maxX, height: r.height)] {
            if !region.isEmpty { NSBezierPath(rect: region).fill() }
        }
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: r); border.lineWidth = 2; border.stroke()
        NSColor.black.withAlphaComponent(0.6).setStroke()
        let inner = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1)); inner.lineWidth = 1; inner.stroke()
        drawLabel("\(Int((r.width * frozen.scale).rounded())) × \(Int((r.height * frozen.scale).rounded()))", near: r)
    }

    private func drawWindows() {
        NSColor.black.withAlphaComponent(0.32).setFill()
        NSBezierPath(rect: bounds).fill()
        guard let window = hovered else { return }
        let rect = NSRect(x: window.frame.minX - frozen.frame.minX,
                          y: frozen.frame.maxY - window.frame.maxY,
                          width: window.frame.width,
                          height: window.frame.height).intersection(bounds)
        guard !rect.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        Renderer.drawImage(frozen.image, in: bounds)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.systemBlue.withAlphaComponent(0.16).setFill()
        NSBezierPath(rect: rect).fill()
        NSColor.systemBlue.setStroke()
        let border = NSBezierPath(rect: rect); border.lineWidth = 2.5; border.stroke()
        let title = window.title.isEmpty ? window.owner : "\(window.owner) — \(window.title)"
        drawLabel(title, near: rect)
    }

    private func drawLabel(_ text: String, near rect: NSRect) {
        guard !text.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        var origin = NSPoint(x: rect.minX + 8, y: rect.maxY + 8)
        if origin.y + size.height > bounds.height { origin.y = rect.maxY - size.height - 8 }
        if origin.y < 4 { origin.y = 4 }
        origin.x = min(max(4, origin.x), max(4, bounds.width - size.width - 12))
        let background = NSRect(x: origin.x - 6, y: origin.y - 4, width: min(size.width + 12, bounds.width - 8), height: size.height + 8)
        NSColor.black.withAlphaComponent(0.68).setFill()
        NSBezierPath(roundedRect: background, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }

    private func globalPoint(_ point: NSPoint) -> NSPoint {
        NSPoint(x: frozen.frame.minX + point.x, y: frozen.frame.maxY - point.y)
    }

    private func window(at point: NSPoint) -> FrozenWindow? {
        windows.first { $0.frame.contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if mode == "window" {
            if let target = window(at: globalPoint(point)) { onCapture?(target.frame) }
        } else {
            start = point; current = point; needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == "area", start != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        current = NSPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == "area" else { return }
        if start != nil {
            let point = convert(event.locationInWindow, from: nil)
            current = NSPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
        }
        guard let rect = dragGlobalRect, rect.width >= 3, rect.height >= 3 else {
            start = nil; current = nil; needsDisplay = true; return
        }
        onCapture?(rect)
    }

    override func mouseMoved(with event: NSEvent) {
        guard mode == "window" else { return }
        let target = window(at: globalPoint(convert(event.locationInWindow, from: nil)))
        if target?.id != hovered?.id { hovered = target; needsDisplay = true }
    }

    override func rightMouseDown(with event: NSEvent) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()
        case 36, 76: if let rect = dragGlobalRect, rect.width >= 3, rect.height >= 3 { onCapture?(rect) }
        default: super.keyDown(with: event)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: mode == "window" ? .pointingHand : .crosshair)
    }
}
