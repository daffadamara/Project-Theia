import MetalKit

// MTKView subclass that turns mouse/scroll/trackpad input into orbit-camera
// changes on the renderer.
final class TerrainMTKView: MTKView {
    weak var rendererRef: Renderer?
    weak var modelRef: TerrainModel?
    private var lastDrag: NSPoint?
    private var dragMode: DragMode?
    private let brushLayer = CAShapeLayer()
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    private enum DragMode {
        case orbit
        case pan
        case dolly
    }

    override init(frame frameRect: NSRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        configureBrushLayer()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        configureBrushLayer()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeInKeyWindow, .mouseMoved,
                                            .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseDown(with e: NSEvent) {
        if eraseMask(with: e, begin: true) { return }
        beginDrag(with: e, mode: leftDragMode(for: e))
    }

    override func mouseUp(with e: NSEvent) {
        endDrag()
    }

    override func mouseDragged(with e: NSEvent) {
        if eraseMask(with: e, begin: false) { return }
        continueDrag(with: e)
    }

    override func rightMouseDown(with e: NSEvent) {
        beginDrag(with: e, mode: e.modifierFlags.contains(.option) ? .dolly : .pan)
    }

    override func rightMouseDragged(with e: NSEvent) {
        continueDrag(with: e)
    }

    override func rightMouseUp(with e: NSEvent) {
        endDrag()
    }

    override func otherMouseDown(with e: NSEvent) {
        beginDrag(with: e, mode: .pan)
    }

    override func otherMouseDragged(with e: NSEvent) {
        continueDrag(with: e)
    }

    override func otherMouseUp(with e: NSEvent) {
        endDrag()
    }

    override func scrollWheel(with e: NSEvent) {
        guard let r = rendererRef else { return }
        if e.modifierFlags.contains(.shift) {
            r.panCamera(delta: CGSize(width: e.scrollingDeltaX + e.scrollingDeltaY,
                                      height: 0),
                        viewportSize: bounds.size)
        } else {
            r.zoomCamera(deltaY: e.scrollingDeltaY)
        }
        modelRef?.viewportCameraDidChange()
        setNeedsDisplay(bounds)
    }

    override func magnify(with e: NSEvent) {
        guard let r = rendererRef else { return }
        r.zoomCamera(deltaY: CGFloat(e.magnification) * 90)
        modelRef?.viewportCameraDidChange()
        setNeedsDisplay(bounds)
    }

    override func mouseMoved(with e: NSEvent) {
        updateBrushCursor(with: e)
    }

    override func mouseExited(with event: NSEvent) {
        brushLayer.isHidden = true
    }

    override func keyDown(with e: NSEvent) {
        guard let model = modelRef else {
            super.keyDown(with: e)
            return
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "f":
            model.resetCamera()
        case "o":
            model.setViewportTool(.orbit)
        case "h":
            model.setViewportTool(.pan)
        case "z":
            model.setViewportTool(.zoom)
        case "g":
            model.setGridVisible(!model.gridVisible)
        case "a":
            model.setAxisVisible(!model.axisVisible)
        case "w":
            model.wireframeEnabled.toggle()
            model.applyViewportSettings()
        case "7":
            model.setCameraPreset(.top)
        default:
            super.keyDown(with: e)
            return
        }
        setNeedsDisplay(bounds)
    }

    private func leftDragMode(for e: NSEvent) -> DragMode {
        if e.modifierFlags.contains(.shift) { return .pan }
        guard let tool = modelRef?.viewportTool else { return .orbit }
        switch tool {
        case .orbit:
            return .orbit
        case .pan:
            return .pan
        case .zoom:
            return .dolly
        }
    }

    private func beginDrag(with e: NSEvent, mode: DragMode) {
        window?.makeFirstResponder(self)
        lastDrag = e.locationInWindow
        dragMode = mode
    }

    private func continueDrag(with e: NSEvent) {
        guard let r = rendererRef,
              let lastDrag,
              let dragMode else { return }
        let p = e.locationInWindow
        let delta = CGSize(width: p.x - lastDrag.x,
                           height: p.y - lastDrag.y)
        switch dragMode {
        case .orbit:
            r.orbitCamera(delta: delta)
        case .pan:
            r.panCamera(delta: delta, viewportSize: bounds.size)
        case .dolly:
            r.zoomCamera(deltaY: delta.height)
        }
        modelRef?.viewportCameraDidChange()
        self.lastDrag = p
        setNeedsDisplay(bounds)
    }

    private func endDrag() {
        modelRef?.endMaskBrush()
        lastDrag = nil
        dragMode = nil
    }

    private func configureBrushLayer() {
        wantsLayer = true
        brushLayer.fillColor = NSColor.systemBlue.withAlphaComponent(0.16).cgColor
        brushLayer.strokeColor = NSColor.systemBlue.withAlphaComponent(0.85).cgColor
        brushLayer.lineWidth = 1.5
        brushLayer.isHidden = true
        layer?.addSublayer(brushLayer)
    }

    private func eraseMask(with e: NSEvent, begin: Bool) -> Bool {
        guard let model = modelRef,
              model.maskBrushEnabled,
              model.canEditActiveMask else { return false }
        guard let uv = terrainUV(for: e) else {
            updateBrushCursor(with: e)
            return true
        }
        let used = begin ? model.beginMaskBrush(at: uv) : model.continueMaskBrush(at: uv)
        if used {
            updateBrushCursor(with: e)
            setNeedsDisplay(bounds)
        }
        return used
    }

    private func terrainUV(for e: NSEvent) -> CGPoint? {
        guard let renderer = rendererRef else { return nil }
        let p = convert(e.locationInWindow, from: nil)
        return renderer.terrainUV(at: p, in: bounds.size)
    }

    private func updateBrushCursor(with e: NSEvent) {
        guard let model = modelRef,
              model.maskBrushEnabled,
              model.canEditActiveMask else {
            brushLayer.isHidden = true
            return
        }
        let p = convert(e.locationInWindow, from: nil)
        let radius = CGFloat(model.maskBrushRadius) * min(bounds.width, bounds.height)
        let rect = CGRect(x: p.x - radius, y: p.y - radius,
                          width: radius * 2, height: radius * 2)
        brushLayer.path = CGPath(ellipseIn: rect, transform: nil)
        brushLayer.isHidden = false
    }
}

// Drives the live MTKView: re-encodes the terrain each frame.
final class ViewportDelegate: NSObject, MTKViewDelegate {
    let renderer: Renderer
    init(renderer: Renderer) { self.renderer = renderer }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = renderer.queue.makeCommandBuffer() else { return }
        renderer.encode(commandBuffer: cb, passDescriptor: rpd,
                        viewportSize: view.drawableSize)
        cb.present(drawable)
        cb.commit()
    }
}
