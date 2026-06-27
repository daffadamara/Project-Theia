// Self-contained test runner for TheiaCore.
//
// `swift test` (XCTest) is unavailable in a Command-Line-Tools-only environment,
// so this is a plain executable: it runs checks, prints a report, and exits
// non-zero if anything fails. Run with `swift run theia-tests`.

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

print("\n\(h.checks) checks, \(h.failures) failure(s)")
exit(h.failures == 0 ? 0 : 1)
