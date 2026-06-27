// Self-contained test runner for TheiaCore.
//
// `swift test` (XCTest) is unavailable in a Command-Line-Tools-only environment,
// so this is a plain executable: it runs checks, prints a report, and exits
// non-zero if anything fails. Run with `swift run theia-tests`.

import Foundation
import TheiaCore

// --- tiny assertion harness --------------------------------------------------
final class Harness {
    private(set) var failures = 0
    private(set) var checks = 0

    func expect(_ cond: Bool, _ message: @autoclosure () -> String) {
        checks += 1
        if !cond {
            failures += 1
            print("  ✗ \(message())")
        }
    }

    func test(_ name: String, _ body: () -> Void) {
        let before = failures
        body()
        let mark = failures == before ? "✓" : "✗"
        print("\(mark) \(name)")
    }
}

// std::string does not bridge to Swift.String on this toolchain; read strings
// back through the C++ core's buffer-copy accessors.
private func readCxxString(
    _ accessor: (UnsafeMutablePointer<CChar>?, Int) -> Int
) -> String {
    var buf = [CChar](repeating: 0, count: 1024)
    let n = buf.withUnsafeMutableBufferPointer { accessor($0.baseAddress, $0.count) }
    let len = min(max(n, 0), buf.count - 1)
    return String(decoding: buf[0..<len].map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

let h = Harness()

h.test("GPU fill produces a uniform buffer") {
    let value: Float = 3.5
    let count: UInt32 = 4096
    let r = theia.gpu_smoke_fill(count, value)
    let err = readCxxString { theia.smoke_error(r, $0, $1) }

    h.expect(r.ok, "smoke failed: \(err)")
    h.expect(r.count == count, "count mismatch: \(r.count)")
    h.expect(r.allMatch, "not all elements matched")
    h.expect(r.first == value, "first=\(r.first)")
    h.expect(r.last == value, "last=\(r.last)")

    let device = readCxxString { theia.smoke_device_name(r, $0, $1) }
    h.expect(!device.isEmpty, "empty device name")
}

h.test("Zero-length fill is a successful no-op") {
    let r = theia.gpu_smoke_fill(0, 1.0)
    h.expect(r.ok, "zero-count should succeed")
    h.expect(r.count == 0, "count should be 0")
}

func perlin(seed: UInt32, size: UInt32 = 256) -> theia.GenerateResult {
    var p = theia.PerlinParams()
    p.width = size
    p.height = size
    p.seed = seed
    return theia.generate_perlin(p, nil, nil)  // no file output
}

h.test("Perlin output is well-formed terrain (range + non-degenerate)") {
    let r = perlin(seed: 42)
    let err = readCxxString { theia.generate_error(r, $0, $1) }
    h.expect(r.ok, "generation failed: \(err)")
    h.expect(r.width == 256 && r.height == 256, "wrong dims")
    h.expect(r.minHeight >= 0.0 && r.maxHeight <= 1.0, "out of [0,1]: [\(r.minHeight),\(r.maxHeight)]")
    h.expect(r.maxHeight > r.minHeight, "flat output")
    h.expect(r.variance > 1e-5, "degenerate output, variance=\(r.variance)")
    h.expect(r.mean > 0.3 && r.mean < 0.7, "mean not centered: \(r.mean)")
}

h.test("Perlin is deterministic for a fixed seed") {
    let a = perlin(seed: 7)
    let b = perlin(seed: 7)
    h.expect(a.ok && b.ok, "generation failed")
    h.expect(a.minHeight == b.minHeight, "min differs")
    h.expect(a.maxHeight == b.maxHeight, "max differs")
    h.expect(a.mean == b.mean, "mean differs: \(a.mean) vs \(b.mean)")
    h.expect(a.variance == b.variance, "variance differs")
}

h.test("Different seeds produce different terrain") {
    let a = perlin(seed: 1)
    let b = perlin(seed: 2)
    h.expect(a.ok && b.ok, "generation failed")
    h.expect(a.mean != b.mean || a.variance != b.variance,
             "seeds 1 and 2 produced identical stats")
}

// --- M2: node graph engine ---------------------------------------------------

func graphError(_ g: OpaquePointer) -> String {
    readCxxString { theia.graph_last_error(g, $0, $1) }
}

h.test("Graph evaluates a linear chain (topological order)") {
    guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
    defer { theia.graph_destroy(g) }
    h.expect(theia.graph_add_node(g, "a", "perlin"), "add a")
    h.expect(theia.graph_add_node(g, "b", "scalebias"), "add b")
    h.expect(theia.graph_add_node(g, "c", "scalebias"), "add c")
    h.expect(theia.graph_connect(g, "a", "b", 0), "connect a->b")
    h.expect(theia.graph_connect(g, "b", "c", 0), "connect b->c")

    let r = theia.graph_evaluate(g, "c", 256, 256, nil, nil)
    h.expect(r.ok, "eval failed: \(graphError(g))")
    h.expect(r.evaluated == 3, "expected 3 evaluated, got \(r.evaluated)")
    h.expect(r.reused == 0, "expected 0 reused, got \(r.reused)")
    h.expect(r.variance > 1e-5, "degenerate output")
}

h.test("Incremental cache recomputes only the affected subgraph") {
    guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
    defer { theia.graph_destroy(g) }
    _ = theia.graph_add_node(g, "a", "perlin")
    _ = theia.graph_add_node(g, "b", "scalebias")
    _ = theia.graph_add_node(g, "c", "scalebias")
    _ = theia.graph_connect(g, "a", "b", 0)
    _ = theia.graph_connect(g, "b", "c", 0)

    let r1 = theia.graph_evaluate(g, "c", 256, 256, nil, nil)
    h.expect(r1.evaluated == 3 && r1.reused == 0, "cold: \(r1.evaluated)/\(r1.reused)")

    // No change => full cache hit.
    let r2 = theia.graph_evaluate(g, "c", 256, 256, nil, nil)
    h.expect(r2.evaluated == 0 && r2.reused == 3, "warm: \(r2.evaluated)/\(r2.reused)")

    // Change the sink's param => only the sink recomputes; upstream reused.
    _ = theia.graph_set_param(g, "c", "bias", 0.1)
    let r3 = theia.graph_evaluate(g, "c", 256, 256, nil, nil)
    h.expect(r3.evaluated == 1 && r3.reused == 2, "leaf change: \(r3.evaluated)/\(r3.reused)")

    // Change the root's param => everything downstream recomputes.
    _ = theia.graph_set_param(g, "a", "seed", 4242)
    let r4 = theia.graph_evaluate(g, "c", 256, 256, nil, nil)
    h.expect(r4.evaluated == 3 && r4.reused == 0, "root change: \(r4.evaluated)/\(r4.reused)")
}

h.test("Diamond DAG reuses the unaffected branch") {
    guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
    defer { theia.graph_destroy(g) }
    _ = theia.graph_add_node(g, "a", "perlin")
    _ = theia.graph_add_node(g, "b", "perlin")
    _ = theia.graph_add_node(g, "mix", "combine")
    _ = theia.graph_connect(g, "a", "mix", 0)
    _ = theia.graph_connect(g, "b", "mix", 1)

    let r1 = theia.graph_evaluate(g, "mix", 256, 256, nil, nil)
    h.expect(r1.ok && r1.evaluated == 3, "cold: \(r1.evaluated) (\(graphError(g)))")

    // Change only branch "a": a + mix recompute, b reused.
    _ = theia.graph_set_param(g, "a", "frequency", 8.0)
    let r2 = theia.graph_evaluate(g, "mix", 256, 256, nil, nil)
    h.expect(r2.evaluated == 2 && r2.reused == 1, "after a-change: \(r2.evaluated)/\(r2.reused)")
}

h.test("Cycles are detected and rejected") {
    guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
    defer { theia.graph_destroy(g) }
    _ = theia.graph_add_node(g, "x", "scalebias")
    _ = theia.graph_add_node(g, "y", "scalebias")
    _ = theia.graph_connect(g, "x", "y", 0)
    _ = theia.graph_connect(g, "y", "x", 0)
    let r = theia.graph_evaluate(g, "y", 64, 64, nil, nil)
    h.expect(!r.ok, "cycle should fail evaluation")
    h.expect(graphError(g).contains("cycle"), "error should mention cycle: \(graphError(g))")
}

h.test("Unknown node type and duplicate id are rejected") {
    guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
    defer { theia.graph_destroy(g) }
    h.expect(!theia.graph_add_node(g, "n", "nonsense"), "unknown type should fail")
    h.expect(theia.graph_add_node(g, "n", "perlin"), "first add ok")
    h.expect(!theia.graph_add_node(g, "n", "perlin"), "duplicate id should fail")
}

h.test("JSON round-trip preserves graph behavior") {
    let tmp = NSTemporaryDirectory() + "theia_rt_\(getpid()).json"
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    var original = theia.GraphEvalResult()
    do {
        guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
        defer { theia.graph_destroy(g) }
        _ = theia.graph_add_node(g, "a", "perlin")
        _ = theia.graph_add_node(g, "out", "scalebias")
        _ = theia.graph_set_param(g, "out", "scale", 1.3)
        _ = theia.graph_connect(g, "a", "out", 0)
        original = theia.graph_evaluate(g, "out", 256, 256, nil, nil)
        h.expect(original.ok, "original eval: \(graphError(g))")
        h.expect(theia.graph_save_json_file(g, tmp), "save failed: \(graphError(g))")
    }

    guard let g2 = theia.graph_create() else { h.expect(false, "create2 failed"); return }
    defer { theia.graph_destroy(g2) }
    h.expect(theia.graph_load_json_file(g2, tmp), "load failed: \(graphError(g2))")
    let reloaded = theia.graph_evaluate(g2, "out", 256, 256, nil, nil)
    h.expect(reloaded.ok, "reloaded eval: \(graphError(g2))")
    h.expect(reloaded.minHeight == original.minHeight, "min differs")
    h.expect(reloaded.maxHeight == original.maxHeight, "max differs")
    h.expect(reloaded.mean == original.mean, "mean differs")
    h.expect(reloaded.variance == original.variance, "variance differs")
}

h.test("Loads the bundled example graph") {
    guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
    defer { theia.graph_destroy(g) }
    if theia.graph_load_json_file(g, "examples/terrain.json") {
        let r = theia.graph_evaluate(g, "", 256, 256, nil, nil)  // "" => default sink
        h.expect(r.ok, "example eval: \(graphError(g))")
        h.expect(r.evaluated == 4, "expected 4 nodes, got \(r.evaluated)")
        h.expect(r.variance > 1e-5, "degenerate example output")
    } else {
        print("  (skipping example: \(graphError(g)))")
    }
}

// --- M3: erosion -------------------------------------------------------------

h.test("Hydraulic erosion alters terrain and is deterministic") {
    func run() -> (base: theia.GraphEvalResult, ero: theia.GraphEvalResult)? {
        guard let g = theia.graph_create() else { return nil }
        defer { theia.graph_destroy(g) }
        _ = theia.graph_add_node(g, "p", "perlin")
        _ = theia.graph_set_param(g, "p", "seed", 2024)
        _ = theia.graph_add_node(g, "e", "hydraulic")
        _ = theia.graph_set_param(g, "e", "iterations", 50)
        _ = theia.graph_connect(g, "p", "e", 0)
        let base = theia.graph_evaluate(g, "p", 128, 128, nil, nil)
        let ero = theia.graph_evaluate(g, "e", 128, 128, nil, nil)
        return (base, ero)
    }
    guard let r1 = run(), let r2 = run() else { h.expect(false, "run failed"); return }
    h.expect(r1.ero.ok, "hydraulic eval failed")
    h.expect(r1.ero.variance > 1e-6, "degenerate erosion output")
    h.expect(r1.ero.mean != r1.base.mean, "erosion did not change the terrain")
    h.expect(r1.ero.mean == r2.ero.mean && r1.ero.variance == r2.ero.variance,
             "hydraulic erosion is non-deterministic")
}

h.test("Thermal erosion smooths slopes and lowers peaks") {
    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }
    _ = theia.graph_add_node(g, "p", "perlin")
    _ = theia.graph_set_param(g, "p", "seed", 7)
    _ = theia.graph_add_node(g, "t", "thermal")
    _ = theia.graph_set_param(g, "t", "talusAngle", 12.0)
    _ = theia.graph_set_param(g, "t", "iterations", 80)
    _ = theia.graph_connect(g, "p", "t", 0)

    let base = theia.graph_evaluate(g, "p", 128, 128, nil, nil)
    let th = theia.graph_evaluate(g, "t", 128, 128, nil, nil)
    h.expect(th.ok, "thermal eval failed: \(graphError(g))")
    h.expect(th.variance < base.variance,
             "thermal should reduce variance: \(base.variance) -> \(th.variance)")
    h.expect(th.maxHeight <= base.maxHeight + 1e-4, "thermal should not raise peaks")
}

h.test("Loads the erosion example graph (perlin->hydraulic->thermal)") {
    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }
    if theia.graph_load_json_file(g, "examples/erosion.json") {
        let r = theia.graph_evaluate(g, "", 128, 128, nil, nil)  // default sink
        h.expect(r.ok, "erosion example eval: \(graphError(g))")
        h.expect(r.evaluated == 3, "expected 3 nodes, got \(r.evaluated)")
        h.expect(r.variance > 1e-6, "degenerate erosion-example output")
    } else {
        print("  (skipping erosion example: \(graphError(g)))")
    }
}

// --- M4: filters + polish ----------------------------------------------------

func perlinThen(_ type: String, configure: (OpaquePointer) -> Void = { _ in })
    -> theia.GraphEvalResult? {
    guard let g = theia.graph_create() else { return nil }
    defer { theia.graph_destroy(g) }
    _ = theia.graph_add_node(g, "p", "perlin")
    _ = theia.graph_set_param(g, "p", "seed", 2024)
    _ = theia.graph_add_node(g, "f", type)
    _ = theia.graph_connect(g, "p", "f", 0)
    configure(g)
    return theia.graph_evaluate(g, "f", 128, 128, nil, nil)
}

h.test("Normalize stretches the range to [0,1]") {
    guard let r = perlinThen("normalize") else { h.expect(false, "run"); return }
    h.expect(r.ok, "normalize eval failed")
    h.expect(r.minHeight < 0.001, "min not ~0: \(r.minHeight)")
    h.expect(r.maxHeight > 0.999, "max not ~1: \(r.maxHeight)")
}

h.test("Terrace produces a valid, non-degenerate field") {
    guard let a = perlinThen("terrace"), let b = perlinThen("terrace") else {
        h.expect(false, "run"); return
    }
    h.expect(a.ok, "terrace eval failed")
    h.expect(a.minHeight >= 0.0 && a.maxHeight <= 1.0, "out of [0,1]")
    h.expect(a.variance > 1e-6, "degenerate terrace")
    h.expect(a.mean == b.mean && a.variance == b.variance, "terrace non-deterministic")
}

h.test("Slope mask is a valid [0,1] mask with variation") {
    guard let r = perlinThen("slopemask") else { h.expect(false, "run"); return }
    h.expect(r.ok, "slopemask eval failed")
    h.expect(r.minHeight >= 0.0 && r.maxHeight <= 1.0, "mask out of [0,1]")
    h.expect(r.variance > 1e-6, "mask has no variation")
}

h.test("16-bit PNG export is well-formed") {
    let tmp = NSTemporaryDirectory() + "theia_png16_\(getpid()).png"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }
    _ = theia.graph_add_node(g, "p", "perlin")
    let r = theia.graph_evaluate(g, "p", 64, 64, tmp, nil)
    h.expect(r.ok, "eval failed: \(graphError(g))")

    guard let bytes = FileManager.default.contents(atPath: tmp) else {
        h.expect(false, "png not written"); return
    }
    let sig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    h.expect(Array(bytes.prefix(8)) == sig, "bad PNG signature")
    // IHDR bit-depth byte is at offset 24 (8 sig + 4 len + 4 'IHDR' + 8 w/h).
    h.expect(bytes.count > 24 && bytes[24] == 16, "expected 16-bit depth, got \(bytes.count > 24 ? Int(bytes[24]) : -1)")
}

h.test("Loads the showcase graph (full pipeline)") {
    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }
    if theia.graph_load_json_file(g, "examples/showcase.json") {
        let r = theia.graph_evaluate(g, "", 128, 128, nil, nil)
        h.expect(r.ok, "showcase eval: \(graphError(g))")
        h.expect(r.evaluated == 5, "expected 5 nodes, got \(r.evaluated)")
    } else {
        print("  (skipping showcase: \(graphError(g)))")
    }
}

print("\n\(h.checks) checks, \(h.failures) failure(s)")
exit(h.failures == 0 ? 0 : 1)
