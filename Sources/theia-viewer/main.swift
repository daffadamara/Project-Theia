// Theia Viewer — interactive 3D terrain viewport.
//
// Usage:
//   theia-viewer [GRAPH.json]            open an interactive window
//   theia-viewer --shot OUT.png [GRAPH]  render one frame offscreen and exit
//   theia-viewer --size N                evaluate at N x N (default 512)
//   theia-viewer --smoke                 open + auto-close (build/launch self-test)
//   Saving GRAPH.json while the window is open hot-reloads the terrain.
//
// Built as a SwiftPM executable (no Xcode): NSApplication is created
// programmatically. Later milestones host SwiftUI controls via NSHostingView.

import AppKit
import MetalKit
import SwiftUI

struct Args {
    var graphPath: String?
    var shotPath: String?
    var size: UInt32 = 0      // 0 => default (512)
    var smoke = false
    // optional camera overrides (mainly for --shot verification)
    var azimuth: Float?
    var elevation: Float?
    var distance: Float?
}

func parseArgs() -> Args {
    var a = Args()
    let argv = Array(CommandLine.arguments.dropFirst())
    var i = 0
    func nextFloat() -> Float? { i + 1 < argv.count ? Float(argv[i + 1]) : nil }
    while i < argv.count {
        switch argv[i] {
        case "--shot": if i + 1 < argv.count { a.shotPath = argv[i + 1]; i += 1 }
        case "--size": if i + 1 < argv.count { a.size = UInt32(argv[i + 1]) ?? 0; i += 1 }
        case "--az": if let v = nextFloat() { a.azimuth = v * .pi / 180; i += 1 }
        case "--el": if let v = nextFloat() { a.elevation = v * .pi / 180; i += 1 }
        case "--dist": if let v = nextFloat() { a.distance = v; i += 1 }
        case "--smoke": a.smoke = true
        default:
            if !argv[i].hasPrefix("--") { a.graphPath = argv[i] }
        }
        i += 1
    }
    return a
}

func applyCameraOverrides(_ renderer: Renderer) {
    if let a = args.azimuth { renderer.camera.azimuth = a }
    if let e = args.elevation { renderer.camera.elevation = e }
    if let d = args.distance { renderer.camera.distance = d }
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

final class HotReloadController: NSObject {
    let graphPath: String
    let model: TerrainModel
    let view: MTKView
    var timer: Timer?

    init(graphPath: String, model: TerrainModel, view: MTKView) {
        self.graphPath = graphPath
        self.model = model
        self.view = view
        super.init()
        timer = Timer.scheduledTimer(timeInterval: 0.5, target: self,
                                     selector: #selector(tick), userInfo: nil,
                                     repeats: true)
    }

    @MainActor @objc func tick() {
        guard model.hotReloadIfChanged() else { return }
        view.setNeedsDisplay(view.bounds)
        print("reloaded \(graphPath)  \(model.lastStats)")
    }
}

let args = parseArgs()
let viewSize: UInt32 = args.size != 0 ? args.size : 512

guard let device = MTLCreateSystemDefaultDevice() else { fail("no Metal device available") }
guard let engine = TerrainEngine(graphPath: args.graphPath) else { fail("graph init failed") }
guard let eval = engine.evaluate(size: viewSize) else {
    fail("evaluation failed: \(engine.lastError())")
}
let evalW = Int(eval.result.width), evalH = Int(eval.result.height)
print("terrain \(evalW)x\(evalH)  range [\(eval.result.minHeight), \(eval.result.maxHeight)]  nodes run \(eval.result.evaluated)")

// --- Offscreen render mode ---------------------------------------------------
if let shot = args.shotPath {
    guard let renderer = Renderer(device: device, colorFormat: .bgra8Unorm) else {
        fail("renderer init failed")
    }
    renderer.setHeights(eval.heights, width: evalW, height: evalH)
    applyCameraOverrides(renderer)
    let ok = renderer.renderToPNG(path: shot, width: 1200, height: 800)
    print(ok ? "✅ wrote \(shot)" : "❌ offscreen render failed")
    exit(ok ? 0 : 1)
}

// --- Interactive window ------------------------------------------------------
let app = NSApplication.shared
app.setActivationPolicy(.regular)

let frame = NSRect(x: 0, y: 0, width: 1000, height: 680)
let window = NSWindow(
    contentRect: frame,
    styleMask: [.titled, .closable, .resizable, .miniaturizable],
    backing: .buffered, defer: false)
window.title = "Theia Viewer"

let mtkView = TerrainMTKView(frame: frame, device: device)
mtkView.colorPixelFormat = .bgra8Unorm
mtkView.depthStencilPixelFormat = .depth32Float
mtkView.clearColor = MTLClearColor(red: 0.09, green: 0.11, blue: 0.14, alpha: 1.0)

guard let renderer = Renderer(device: device, colorFormat: mtkView.colorPixelFormat) else {
    fail("renderer init failed")
}
renderer.setHeights(eval.heights, width: evalW, height: evalH)
applyCameraOverrides(renderer)
let model = TerrainModel(engine: engine, renderer: renderer, size: viewSize)
model.record(eval.result)

mtkView.rendererRef = renderer
let viewportDelegate = ViewportDelegate(renderer: renderer)
mtkView.delegate = viewportDelegate

let hotReloadController = args.graphPath.map {
    HotReloadController(graphPath: $0, model: model, view: mtkView)
}

let shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
    let chars = event.charactersIgnoringModifiers?.lowercased()
    if event.modifierFlags.contains(.command), chars == "s" {
        model.save()
        return nil
    }
    if event.keyCode == 51 || event.keyCode == 117 {
        model.deleteSelection()
        mtkView.setNeedsDisplay(mtkView.bounds)
        return nil
    }
    return event
}

window.contentView = NSHostingView(
    rootView: ContentView(model: model, viewport: mtkView))
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

if args.smoke {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        print("✅ viewer window launched cleanly")
        NSApp.terminate(nil)
    }
}

app.run()
if let shortcutMonitor {
    NSEvent.removeMonitor(shortcutMonitor)
}
