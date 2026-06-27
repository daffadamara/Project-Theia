// Theia CLI — the thin Swift "shell" over the C++ core (TheiaCore), called
// through Swift/C++ interop. For now it only exposes the M0 GPU smoke test.

import TheiaCore

// std::string does not bridge to Swift.String on this toolchain, so the C++
// core hands strings back by copying into a caller buffer. This wraps that.
private func readCxxString(
    _ accessor: (UnsafeMutablePointer<CChar>?, Int) -> Int
) -> String {
    var buf = [CChar](repeating: 0, count: 1024)
    let n = buf.withUnsafeMutableBufferPointer { accessor($0.baseAddress, $0.count) }
    let len = min(max(n, 0), buf.count - 1)
    return String(decoding: buf[0..<len].map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func usage() {
    print("""
    theia — node-based procedural terrain generator (core CLI)

    USAGE:
      theia-cli smoke [count] [value]   Run the GPU compute smoke test.
                                        Defaults: count=1024, value=42.0

      theia-cli demo [--size N] [--out PATH] [--seed S]
                                        Generate an fBm Perlin heightfield and
                                        write a PNG preview + PFM float export.
                                        Defaults: size=1024, out=terrain.png, seed=1337

      theia-cli run GRAPH.json [--sink ID] [--size N] [--out PATH]
                                        Evaluate a node graph and write outputs.
                                        sink/size default to values in the JSON.
                                        Default out=terrain.png

    """)
}

func runGraph(jsonPath: String, sink: String, size: UInt32, outPNG: String) -> Int32 {
    guard let g = theia.graph_create() else {
        print("❌ failed to create graph")
        return 1
    }
    defer { theia.graph_destroy(g) }

    if !theia.graph_load_json_file(g, jsonPath) {
        let err = readCxxString { theia.graph_last_error(g, $0, $1) }
        print("❌ failed to load \(jsonPath): \(err)")
        return 1
    }

    let pfmPath = outPNG.hasSuffix(".png")
        ? String(outPNG.dropLast(4)) + ".pfm"
        : outPNG + ".pfm"

    let r = theia.graph_evaluate(g, sink, size, size, outPNG, pfmPath)
    if r.ok {
        print("✅ Evaluated graph \(jsonPath)")
        print("   resolution:   \(r.width)x\(r.height)")
        print("   nodes run:    \(r.evaluated) (reused \(r.reused) from cache)")
        print("   height range: [\(r.minHeight), \(r.maxHeight)]")
        print("   mean / var:   \(r.mean) / \(r.variance)")
        print("   PNG preview:  \(outPNG)")
        print("   PFM export:   \(pfmPath)")
        return 0
    } else {
        let err = readCxxString { theia.graph_last_error(g, $0, $1) }
        print("❌ Evaluation FAILED: \(err)")
        return 1
    }
}

func runDemo(size: UInt32, outPNG: String, seed: UInt32) -> Int32 {
    var params = theia.PerlinParams()
    params.width = size
    params.height = size
    params.seed = seed

    let pfmPath = outPNG.hasSuffix(".png")
        ? String(outPNG.dropLast(4)) + ".pfm"
        : outPNG + ".pfm"

    let r = theia.generate_perlin(params, outPNG, pfmPath)
    if r.ok {
        print("✅ Generated \(r.width)x\(r.height) Perlin fBm terrain")
        print("   height range: [\(r.minHeight), \(r.maxHeight)]")
        print("   mean:         \(r.mean)")
        print("   variance:     \(r.variance)")
        print("   PNG preview:  \(outPNG)")
        print("   PFM export:   \(pfmPath)")
        return 0
    } else {
        let err = readCxxString { theia.generate_error(r, $0, $1) }
        print("❌ Generation FAILED: \(err)")
        return 1
    }
}

func runSmoke(count: UInt32, value: Float) -> Int32 {
    let r = theia.gpu_smoke_fill(count, value)
    let device = readCxxString { theia.smoke_device_name(r, $0, $1) }

    if r.ok {
        print("✅ GPU smoke test passed")
        print("   device:     \(device)")
        print("   count:      \(r.count)")
        print("   value:      \(value)")
        print("   out[0]:     \(r.first)")
        print("   out[last]:  \(r.last)")
        print("   all match:  \(r.allMatch)")
        return 0
    } else {
        let err = readCxxString { theia.smoke_error(r, $0, $1) }
        print("❌ GPU smoke test FAILED")
        print("   device: \(device.isEmpty ? "<none>" : device)")
        print("   error:  \(err)")
        return 1
    }
}

// --- argument parsing --------------------------------------------------------
let args = Array(CommandLine.arguments.dropFirst())

guard let command = args.first else {
    usage()
    exit(2)
}

switch command {
case "smoke":
    let count = args.count > 1 ? (UInt32(args[1]) ?? 1024) : 1024
    let value = args.count > 2 ? (Float(args[2]) ?? 42.0) : 42.0
    exit(runSmoke(count: count, value: value))
case "demo":
    var size: UInt32 = 1024
    var out = "terrain.png"
    var seed: UInt32 = 1337
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--size": if i + 1 < args.count { size = UInt32(args[i + 1]) ?? size; i += 1 }
        case "--out": if i + 1 < args.count { out = args[i + 1]; i += 1 }
        case "--seed": if i + 1 < args.count { seed = UInt32(args[i + 1]) ?? seed; i += 1 }
        default: print("ignoring unknown option: \(args[i])")
        }
        i += 1
    }
    exit(runDemo(size: size, outPNG: out, seed: seed))
case "run":
    guard args.count > 1, !args[1].hasPrefix("--") else {
        print("usage: theia-cli run GRAPH.json [--sink ID] [--size N] [--out PATH]")
        exit(2)
    }
    let jsonPath = args[1]
    var sink = ""
    var size: UInt32 = 0  // 0 => use graph default resolution
    var out = "terrain.png"
    var i = 2
    while i < args.count {
        switch args[i] {
        case "--sink": if i + 1 < args.count { sink = args[i + 1]; i += 1 }
        case "--size": if i + 1 < args.count { size = UInt32(args[i + 1]) ?? size; i += 1 }
        case "--out": if i + 1 < args.count { out = args[i + 1]; i += 1 }
        default: print("ignoring unknown option: \(args[i])")
        }
        i += 1
    }
    exit(runGraph(jsonPath: jsonPath, sink: sink, size: size, outPNG: out))
case "-h", "--help", "help":
    usage()
    exit(0)
default:
    print("unknown command: \(command)\n")
    usage()
    exit(2)
}
