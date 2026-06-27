import MetalKit

// MTKView subclass that turns mouse/scroll/trackpad input into orbit-camera
// changes on the renderer.
final class TerrainMTKView: MTKView {
    weak var rendererRef: Renderer?
    private var lastDrag: NSPoint?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with e: NSEvent) { lastDrag = e.locationInWindow }
    override func mouseUp(with e: NSEvent) { lastDrag = nil }

    override func mouseDragged(with e: NSEvent) {
        guard let r = rendererRef else { return }
        let p = e.locationInWindow
        if let l = lastDrag {
            r.camera.azimuth -= Float(p.x - l.x) * 0.01
            let el = r.camera.elevation + Float(p.y - l.y) * 0.01
            r.camera.elevation = max(0.05, min(.pi / 2 - 0.02, el))
        }
        lastDrag = p
    }

    override func scrollWheel(with e: NSEvent) {
        guard let r = rendererRef else { return }
        r.camera.distance = clampDist(r.camera.distance * Float(1 - e.scrollingDeltaY * 0.01))
    }

    override func magnify(with e: NSEvent) {
        guard let r = rendererRef else { return }
        r.camera.distance = clampDist(r.camera.distance * Float(1 - e.magnification))
    }

    private func clampDist(_ d: Float) -> Float { max(0.6, min(20, d)) }
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
