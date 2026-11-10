import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI

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
    private let completion: ((NSImage?) -> Void)?
    private let onInlineEnd: ((Bool) -> Void)?
    private let model: ShotModel?
    private var windows: [FrozenOverlayWindow] = []
    private var toolbar: NSPanel?
    private var monitor: Any?
    private var activeView: FrozenOverlayView?
    private var inlineSelection: NSRect?
    private var inlineStarted = false
    private var finished = false
    private static let overlayLevel = NSWindow.Level.screenSaver
    private var isInline: Bool {model != nil && onInlineEnd != nil}

    init(snapshot: FrozenCapture.Snapshot, mode: String, completion: @escaping (NSImage?) -> Void) {
        self.snapshot = snapshot
        self.mode = mode
        self.completion = completion
        self.onInlineEnd = nil
        self.model = nil
    }

    init(snapshot: FrozenCapture.Snapshot, mode: String, model: ShotModel, onInlineEnd: @escaping (Bool) -> Void) {
        self.snapshot = snapshot
        self.mode = mode
        self.completion = nil
        self.onInlineEnd = onInlineEnd
        self.model = model
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
            let view = FrozenOverlayView(frame: frame, windows: snapshot.windows, mode: mode, inlineMode: isInline)
            view.onCancel = { [weak self] in self?.cancel() }
            if isInline {
                view.onInlineSelection = { [weak self, weak view] rect in
                    guard let self, let view else { return }
                    self.beginInline(rect, view: view)
                }
                view.onInlineSelectionChanged = { [weak self] rect in self?.updateInline(rect) }
                view.onInlineFinish = { [weak self] in self?.copyAndFinish() }
                view.onInlineCancel = { [weak self] in self?.finishInline(kept: false) }
            } else {
                view.onCapture = { [weak self] rect in self?.finish(rect) }
            }
            window.contentView = view
            window.makeFirstResponder(view)
            window.orderFrontRegardless()
            windows.append(window)
        }
        (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKeyAndOrderFront(nil)
        if isInline {installMonitor()}
    }

    func cancel() {
        if isInline {finishInline(kept: false)} else {finish(nil)}
    }

    private func beginInline(_ rect: NSRect, view: FrozenOverlayView) {
        guard !inlineStarted, let model, let crop = FrozenCapture.crop(snapshot.frames, rect: rect) else {
            finishInline(kept: false); return
        }
        inlineStarted = true
        activeView = view
        inlineSelection = rect
        model.beginInlineCapture(crop, name: mode == "window" ? L("窗口截图") : L("区域截图"))
        model.status = L("在选区上直接标注 · 回车复制 · Esc 取消")
        view.beginInlineAnnotation(model: model)
        showToolbar(selection: rect)
    }

    private func updateInline(_ rect: NSRect) {
        guard inlineStarted, let model, model.marks.isEmpty, let crop = FrozenCapture.crop(snapshot.frames, rect: rect) else { return }
        inlineSelection = rect
        model.updateInlineImage(crop)
        positionToolbar(selection: rect)
    }

    private func copyAndFinish() {
        guard inlineStarted, let model else { return }
        model.copy()
        finishInline(kept: true)
        model.status = L("已复制图片，可粘贴到其他应用")
    }

    private func finishInline(kept: Bool) {
        guard !finished else { return }
        finished = true
        NSColorPanel.shared.level = .floating
        removeMonitor()
        toolbar?.orderOut(nil); toolbar = nil
        CaptureDebug.finish(selection: inlineSelection, output: kept ? model?.output() : nil)
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        onInlineEnd?(kept)
    }

    private func showToolbar(selection: NSRect) {
        guard let model else { return }
        let size = CGSize(width: 820, height: 46)
        let content = InlineToolbarView(
            model: model,
            onCancel: { [weak self] in self?.finishInline(kept: false) },
            onCopy: { [weak self] in self?.copyAndFinish() },
            onSave: { model.save(elevated: true) },
            onPin: { [weak self] in model.pin(); self?.finishInline(kept: true) },
            onOCR: { [weak self] in self?.finishInline(kept: true); model.showWindow(); model.recognize() },
            onMain: { [weak self] in self?.finishInline(kept: true); model.showWindow() }
        )
        let host = NSHostingView(rootView: content)
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        let panel = InlineToolbarPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: Self.overlayLevel.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .aqua)
        panel.contentView = host
        toolbar = panel
        NSColorPanel.shared.level = NSWindow.Level(rawValue: Self.overlayLevel.rawValue + 3)
        NSColorPanel.shared.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        positionToolbar(selection: selection)
        panel.orderFrontRegardless()
    }

    private func positionToolbar(selection: NSRect) {
        guard let toolbar else { return }
        let center = NSPoint(x: selection.midX, y: selection.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? windows.first?.screen
        guard let screen else { return }
        toolbar.setFrame(InlineToolbarLayout.frame(selection: selection, size: toolbar.frame.size, screen: screen.frame), display: true)
    }

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = event.window,
                  self.windows.contains(where: { $0 === window }) || window === self.toolbar,
                  CaptureKeyRouter.isTextInput(window) == false,
                  let action = CaptureKeyRouter.action(event) else { return event }
            switch action {
            case .cancel:
                self.finishInline(kept: false)
            case .copy:
                if self.inlineStarted {self.copyAndFinish()}
            case .save:
                if self.inlineStarted {self.model?.save(elevated: true)}
            case .undo:
                if self.inlineStarted {self.model?.undo()}
            case .redo:
                if self.inlineStarted {self.model?.redo()}
            case .tool(let index):
                if MarkTool.allCases.indices.contains(index - 1) {self.model?.tool = MarkTool.allCases[index - 1]}
            }
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor {NSEvent.removeMonitor(monitor);self.monitor = nil}
    }

    private func finish(_ rect: NSRect?) {
        guard !finished else { return }
        finished = true
        let result = rect.flatMap { FrozenCapture.crop(snapshot.frames, rect: $0) }
        CaptureDebug.finish(selection: rect, output: result)
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        completion?(result)
    }
}

final class FrozenOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private enum InlineHandle: CaseIterable {case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left}

final class FrozenOverlayView: NSView {
    private let frozen: FrozenFrame
    private let windows: [FrozenWindow]
    private let mode: String
    private let inlineMode: Bool
    var onCapture: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?
    var onInlineSelection: ((NSRect) -> Void)?
    var onInlineSelectionChanged: ((NSRect) -> Void)?
    var onInlineFinish: (() -> Void)?
    var onInlineCancel: (() -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?
    private var hovered: FrozenWindow?
    private var inlineSelection: NSRect?
    private var inlineModel: ShotModel?
    private var revisionSink: AnyCancellable?
    private var draft: Mark?
    private var resizeHandle: InlineHandle?
    private var dragStart: NSPoint?
    private var dragOriginal: NSRect?

    init(frame: FrozenFrame, windows: [FrozenWindow], mode: String, inlineMode: Bool = false) {
        self.frozen = frame
        self.windows = windows
        self.mode = mode
        self.inlineMode = inlineMode
        super.init(frame: NSRect(origin: .zero, size: frame.frame.size))
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func beginInlineAnnotation(model: ShotModel) {
        inlineModel = model
        revisionSink = model.$revision.sink { [weak self] _ in self?.needsDisplay = true }
        needsDisplay = true
    }

    private var dragRect: NSRect? {
        guard mode == "area", let start, let current else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    // Selected region in NSScreen global coordinates.
    private var dragGlobalRect: NSRect? {
        guard let rect = dragRect else { return nil }
        return NSRect(x: frozen.frame.minX + rect.minX, y: frozen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private func localRect(_ global: NSRect) -> NSRect {
        NSRect(x: global.minX - frozen.frame.minX, y: frozen.frame.maxY - global.maxY, width: global.width, height: global.height)
    }

    private func globalRect(_ local: NSRect) -> NSRect {
        NSRect(x: frozen.frame.minX + local.minX, y: frozen.frame.maxY - local.maxY, width: local.width, height: local.height)
    }

    private func globalPoint(_ point: NSPoint) -> NSPoint {
        NSPoint(x: frozen.frame.minX + point.x, y: frozen.frame.maxY - point.y)
    }

    private func window(at point: NSPoint) -> FrozenWindow? {
        windows.first { $0.frame.contains(point) }
    }

    override func draw(_ dirtyRect: NSRect) {
        Renderer.drawImage(frozen.image, in: bounds)
        if inlineMode {
            if inlineSelection != nil {drawInline()} else if mode == "window" {drawWindows()} else {drawArea()}
            return
        }
        if mode == "area" {drawArea()} else {drawWindows()}
    }

    private func drawArea() {
        NSColor.black.withAlphaComponent(dragRect == nil ? 0.35 : 0.45).setFill()
        guard let rect = dragRect, rect.width >= 1, rect.height >= 1 else {
            NSBezierPath(rect: bounds).fill()
            return
        }
        let r = rect.integral.intersection(bounds)
        dim(around: r)
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: r); border.lineWidth = 2; border.stroke()
        NSColor.black.withAlphaComponent(0.6).setStroke()
        let inner = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1)); inner.lineWidth = 1; inner.stroke()
        drawLabel("\(Int((r.width * frozen.scale).rounded())) × \(Int((r.height * frozen.scale).rounded()))", near: r)
    }

    private func drawInline() {
        guard let selection = inlineSelection else { return }
        let local = localRect(selection).intersection(bounds)
        guard !local.isEmpty else { return }
        NSColor.black.withAlphaComponent(0.5).setFill()
        dim(around: local)
        if let model = inlineModel {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: local).addClip()
            let context = NSGraphicsContext.current!.cgContext
            context.translateBy(x: selection.minX - frozen.frame.minX, y: frozen.frame.maxY - selection.maxY)
            let scale = 1 / frozen.scale
            context.scaleBy(x: scale, y: scale)
            for mark in model.marks {Renderer.drawMark(mark)}
            if let draft {Renderer.drawMark(draft)}
            NSGraphicsContext.restoreGraphicsState()
        }
        NSColor.systemBlue.setStroke()
        let border = NSBezierPath(rect: local); border.lineWidth = 2; border.stroke()
        if (inlineModel?.marks.isEmpty ?? true), mode == "area" {drawHandles(local)}
        drawLabel("\(Int((selection.width * frozen.scale).rounded())) × \(Int((selection.height * frozen.scale).rounded()))", near: local, above: true)
    }

    private func dim(around rect: NSRect) {
        for region in [NSRect(x: 0, y: 0, width: bounds.width, height: rect.minY),
                       NSRect(x: 0, y: rect.maxY, width: bounds.width, height: bounds.height - rect.maxY),
                       NSRect(x: 0, y: rect.minY, width: rect.minX, height: rect.height),
                       NSRect(x: rect.maxX, y: rect.minY, width: bounds.width - rect.maxX, height: rect.height)] {
            if !region.isEmpty {NSBezierPath(rect: region).fill()}
        }
    }

    private func drawHandles(_ rect: NSRect) {
        let points = [NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.midX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY),
                      NSPoint(x: rect.maxX, y: rect.midY), NSPoint(x: rect.maxX, y: rect.maxY), NSPoint(x: rect.midX, y: rect.maxY),
                      NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.minX, y: rect.midY)]
        NSColor.white.setFill(); NSColor.systemBlue.setStroke()
        for point in points {
            let handle = NSRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
            NSBezierPath(rect: handle).fill()
            let border = NSBezierPath(rect: handle); border.lineWidth = 1; border.stroke()
        }
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

    private func drawLabel(_ text: String, near rect: NSRect, above: Bool = false) {
        guard !text.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        var origin = above ? NSPoint(x: rect.minX + 8, y: rect.minY - size.height - 12) : NSPoint(x: rect.minX + 8, y: rect.maxY + 8)
        if above && origin.y < 4 {origin.y = rect.minY + 8}
        if !above && origin.y + size.height > bounds.height { origin.y = rect.maxY - size.height - 8 }
        if origin.y < 4 { origin.y = 4 }
        origin.x = min(max(4, origin.x), max(4, bounds.width - size.width - 12))
        let background = NSRect(x: origin.x - 6, y: origin.y - 4, width: min(size.width + 12, bounds.width - 8), height: size.height + 8)
        NSColor.black.withAlphaComponent(0.68).setFill()
        NSBezierPath(roundedRect: background, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }

    private func selectInline(_ rect: NSRect) {
        inlineSelection = rect
        start = nil;current = nil
        needsDisplay = true
        onInlineSelection?(rect)
    }

    private func imagePoint(_ point: NSPoint) -> CGPoint {
        guard let selection = inlineSelection, let model = inlineModel else { return .zero }
        let gx = frozen.frame.minX + point.x
        let gy = frozen.frame.maxY - point.y
        let x = (gx - selection.minX) * frozen.scale
        let y = (selection.maxY - gy) * frozen.scale
        let size = model.image?.pixelSize ?? .zero
        return CGPoint(x: min(size.width, max(0, x)), y: min(size.height, max(0, y)))
    }

    private func beginDraft(at point: NSPoint) {
        guard let model = inlineModel else { return }
        var mark = Mark(tool: model.tool, points: [imagePoint(point)], color: NSColor(model.color), width: model.lineWidth)
        if model.tool == .text {
            let alert = NSAlert(); alert.messageText = L("添加文字"); let field = NSTextField(string: ""); field.frame = NSRect(x: 0, y: 0, width: 300, height: 28); alert.accessoryView = field
            alert.addButton(withTitle: L("添加")); alert.addButton(withTitle: L("取消")); alert.window.initialFirstResponder = field
            alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
            if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {mark.text = field.stringValue;model.add(mark)}
        } else if model.tool == .number {
            mark.text = "\(model.marks.filter {$0.tool == .number}.count + 1)";model.add(mark)
        } else {
            draft = mark;needsDisplay = true
        }
    }

    private func handle(at point: NSPoint, in rect: NSRect) -> InlineHandle? {
        guard rect.width >= 12, rect.height >= 12 else { return nil }
        let candidates: [(InlineHandle, NSPoint)] = [(.topLeft, NSPoint(x: rect.minX, y: rect.minY)), (.top, NSPoint(x: rect.midX, y: rect.minY)), (.topRight, NSPoint(x: rect.maxX, y: rect.minY)),
            (.right, NSPoint(x: rect.maxX, y: rect.midY)), (.bottomRight, NSPoint(x: rect.maxX, y: rect.maxY)), (.bottom, NSPoint(x: rect.midX, y: rect.maxY)),
            (.bottomLeft, NSPoint(x: rect.minX, y: rect.maxY)), (.left, NSPoint(x: rect.minX, y: rect.midY))]
        return candidates.first {abs(point.x - $0.1.x) <= 8 && abs(point.y - $0.1.y) <= 8}?.0
    }

    private func nearBorder(_ point: NSPoint, in rect: NSRect) -> Bool {
        let outer = rect.insetBy(dx: -8, dy: -8), inner = rect.insetBy(dx: 8, dy: 8)
        return outer.contains(point) && !inner.contains(point)
    }

    private func clampSelection(_ rect: NSRect) -> NSRect {
        let minSize: CGFloat = 3
        let minX = min(max(0, rect.minX), bounds.width - minSize)
        let maxX = max(minX + minSize, min(bounds.width, rect.maxX))
        let minY = min(max(0, rect.minY), bounds.height - minSize)
        let maxY = max(minY + minSize, min(bounds.height, rect.maxY))
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func inlineMouseDown(_ point: NSPoint, _ event: NSEvent) {
        guard let selection = inlineSelection else { return }
        let local = localRect(selection).intersection(bounds)
        if (inlineModel?.marks.isEmpty ?? false), mode == "area" {
            if let handle = handle(at: point, in: local) {
                resizeHandle = handle;dragStart = point;dragOriginal = selection;return
            }
            if nearBorder(point, in: local) {
                resizeHandle = nil;dragStart = point;dragOriginal = selection;return
            }
        }
        guard local.contains(point) else { return }
        if event.clickCount == 2 {onInlineFinish?();return}
        beginDraft(at: point)
    }

    private func inlineMouseDragged(_ point: NSPoint) {
        if let dragStart, let original = dragOriginal {
            let delta = CGSize(width: point.x - dragStart.x, height: point.y - dragStart.y)
            let local = localRect(original)
            var minX = local.minX, maxX = local.maxX, minY = local.minY, maxY = local.maxY
            if let resizeHandle {
                switch resizeHandle {
                case .topLeft: minX += delta.width; minY += delta.height
                case .top: minY += delta.height
                case .topRight: maxX += delta.width; minY += delta.height
                case .right: maxX += delta.width
                case .bottomRight: maxX += delta.width; maxY += delta.height
                case .bottom: maxY += delta.height
                case .bottomLeft: minX += delta.width; maxY += delta.height
                case .left: minX += delta.width
                }
            } else {
                minX += delta.width; maxX += delta.width; minY += delta.height; maxY += delta.height
            }
            inlineSelection = globalRect(clampSelection(NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)))
            needsDisplay = true
            return
        }
        guard var mark = draft else { return }
        let point = imagePoint(point)
        if mark.tool == .pen || mark.points.count == 1 {mark.points.append(point)} else {mark.points[mark.points.count - 1] = point}
        draft = mark;needsDisplay = true
    }

    private func inlineMouseUp() {
        if dragOriginal != nil {
            dragStart = nil;dragOriginal = nil;resizeHandle = nil
            if let selection = inlineSelection {onInlineSelectionChanged?(selection)}
            needsDisplay = true
            return
        }
        guard let mark = draft else { return }
        draft = nil
        if mark.tool == .crop {
            if let model = inlineModel, model.marks.isEmpty, let selection = inlineSelection {
                let scale = frozen.scale
                let rect = NSRect(x: selection.minX + mark.rect.minX / scale, y: selection.maxY - mark.rect.maxY / scale, width: mark.rect.width / scale, height: mark.rect.height / scale)
                if rect.width >= 3, rect.height >= 3 {inlineSelection = rect;onInlineSelectionChanged?(rect)}
            }
        } else if mark.tool == .pen || mark.rect.width + mark.rect.height > 3 {
            inlineModel?.add(mark)
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if inlineMode {
            if inlineSelection != nil {inlineMouseDown(point, event);return}
            if mode == "window" {
                if let target = window(at: globalPoint(point)) {selectInline(target.frame)}
                return
            }
            start = point;current = point;needsDisplay = true
            return
        }
        if mode == "window" {
            if let target = window(at: globalPoint(point)) {onCapture?(target.frame)}
        } else {
            start = point;current = point;needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if inlineMode {
            if inlineSelection != nil {inlineMouseDragged(point);return}
            if mode == "area", start != nil {
                current = NSPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height));needsDisplay = true
            }
            return
        }
        guard mode == "area", start != nil else { return }
        current = NSPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if inlineMode {
            if inlineSelection != nil {inlineMouseUp();return}
            guard mode == "area", start != nil else { return }
            let point = convert(event.locationInWindow, from: nil)
            current = NSPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
            if let rect = dragGlobalRect, rect.width >= 3, rect.height >= 3 {selectInline(rect)}
            else {start = nil;current = nil;needsDisplay = true}
            return
        }
        guard mode == "area" else { return }
        if start != nil {
            let point = convert(event.locationInWindow, from: nil)
            current = NSPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
        }
        guard let rect = dragGlobalRect, rect.width >= 3, rect.height >= 3 else {
            start = nil;current = nil;needsDisplay = true;return
        }
        onCapture?(rect)
    }

    override func mouseMoved(with event: NSEvent) {
        guard mode == "window" else { return }
        if inlineMode, inlineSelection != nil { return }
        let target = window(at: globalPoint(convert(event.locationInWindow, from: nil)))
        if target?.id != hovered?.id {hovered = target;needsDisplay = true}
    }

    override func rightMouseDown(with event: NSEvent) {
        if inlineMode {onInlineCancel?()} else {onCancel?()}
    }

    override func keyDown(with event: NSEvent) {
        if inlineMode {
            if event.keyCode == 53 {onInlineCancel?()} else {super.keyDown(with: event)}
            return
        }
        if event.keyCode == 53 {draft = nil;needsDisplay = true} else {super.keyDown(with: event)}
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: mode == "window" && !inlineMode ? .pointingHand : .crosshair)
    }
}
