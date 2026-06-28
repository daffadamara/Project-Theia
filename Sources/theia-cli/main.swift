// Theia CLI — the thin Swift "shell" over the C++ core (TheiaCore), called
// through Swift/C++ interop.

import Foundation
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

      theia-cli export GRAPH.json [--sink ID] [--size N]
                       [--out-dir DIR] [--basename NAME]
                       [--maps height,pfm,normal,slope,mask]
                       [--mesh obj] [--vertical-scale V] [--mesh-stride S]
                                        Write production maps and/or OBJ mesh.

      theia-cli nodes                   List available node types.

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

func runExport(jsonPath: String, sink: String, size: UInt32, outDir: String,
               basename: String, maps: Set<String>, mesh: String,
               verticalScale: Float, meshStride: UInt32) -> Int32 {
    guard size >= 2 else {
        print("❌ export size must be >= 2")
        return 2
    }
    guard meshStride > 0 else {
        print("❌ mesh stride must be > 0")
        return 2
    }
    guard verticalScale > 0 else {
        print("❌ vertical scale must be > 0")
        return 2
    }

    let knownMaps: Set<String> = ["height", "pfm", "normal", "slope", "mask"]
    let unknownMaps = maps.subtracting(knownMaps)
    guard unknownMaps.isEmpty else {
        print("❌ unknown map(s): \(unknownMaps.sorted().joined(separator: ","))")
        return 2
    }
    guard mesh.isEmpty || mesh == "obj" else {
        print("❌ unknown mesh format: \(mesh)")
        return 2
    }
    guard !maps.isEmpty || mesh == "obj" else {
        print("❌ choose at least one map or --mesh obj")
        return 2
    }

    do {
        try FileManager.default.createDirectory(atPath: outDir,
                                                withIntermediateDirectories: true)
    } catch {
        print("❌ cannot create \(outDir): \(error.localizedDescription)")
        return 1
    }

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

    func path(_ suffix: String) -> String {
        URL(fileURLWithPath: outDir).appendingPathComponent("\(basename)\(suffix)").path
    }
    let heightPath = maps.contains("height") ? path("_height.png") : ""
    let pfmPath = maps.contains("pfm") ? path(".pfm") : ""
    let normalPath = maps.contains("normal") ? path("_normal.png") : ""
    let slopePath = maps.contains("slope") ? path("_slope.png") : ""
    let maskPath = maps.contains("mask") ? path("_mask.png") : ""
    let objPath = mesh == "obj" ? path(".obj") : ""

    let r = theia.graph_export(g, sink, size, size, heightPath, pfmPath,
                               normalPath, slopePath, maskPath, objPath,
                               verticalScale, meshStride)
    guard r.ok else {
        let err = readCxxString { theia.graph_last_error(g, $0, $1) }
        print("❌ Export FAILED: \(err)")
        return 1
    }

    print("✅ Exported graph \(jsonPath)")
    print("   resolution:   \(r.width)x\(r.height)")
    print("   sink:         \(sink.isEmpty ? "<default>" : sink)")
    print("   height range: [\(r.minHeight), \(r.maxHeight)]")
    if !heightPath.isEmpty { print("   height PNG:   \(heightPath)") }
    if !pfmPath.isEmpty { print("   PFM:          \(pfmPath)") }
    if !normalPath.isEmpty { print("   normal PNG:   \(normalPath)") }
    if !slopePath.isEmpty { print("   slope PNG:    \(slopePath)") }
    if !maskPath.isEmpty { print("   mask PNG:     \(maskPath)") }
    if !objPath.isEmpty { print("   OBJ:          \(objPath)") }
    return 0
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
case "export":
    guard args.count > 1, !args[1].hasPrefix("--") else {
        print("usage: theia-cli export GRAPH.json [--sink ID] [--size N] [--out-dir DIR] [--basename NAME] [--maps height,pfm,normal,slope,mask] [--mesh obj] [--vertical-scale V] [--mesh-stride S]")
        exit(2)
    }
    let jsonPath = args[1]
    var sink = ""
    var size: UInt32 = 1024
    var outDir = "."
    var basename = URL(fileURLWithPath: jsonPath)
        .deletingPathExtension()
        .lastPathComponent
    var maps: Set<String> = ["height", "pfm"]
    var mesh = ""
    var verticalScale: Float = 1.0
    var meshStride: UInt32 = 1
    var i = 2
    while i < args.count {
        switch args[i] {
        case "--sink": if i + 1 < args.count { sink = args[i + 1]; i += 1 }
        case "--size": if i + 1 < args.count { size = UInt32(args[i + 1]) ?? size; i += 1 }
        case "--out-dir": if i + 1 < args.count { outDir = args[i + 1]; i += 1 }
        case "--basename": if i + 1 < args.count { basename = args[i + 1]; i += 1 }
        case "--maps":
            if i + 1 < args.count {
                maps = Set(args[i + 1].split(separator: ",").map { String($0) })
                i += 1
            }
        case "--mesh": if i + 1 < args.count { mesh = args[i + 1]; i += 1 }
        case "--vertical-scale":
            if i + 1 < args.count { verticalScale = Float(args[i + 1]) ?? verticalScale; i += 1 }
        case "--mesh-stride":
            if i + 1 < args.count { meshStride = UInt32(args[i + 1]) ?? meshStride; i += 1 }
        default: print("ignoring unknown option: \(args[i])")
        }
        i += 1
    }
    exit(runExport(jsonPath: jsonPath, sink: sink, size: size, outDir: outDir,
                   basename: basename, maps: maps, mesh: mesh,
                   verticalScale: verticalScale, meshStride: meshStride))
case "nodes":
    let types = readCxxString { theia.node_type_list($0, $1) }
    print("Available node types: \(types)")
    exit(0)
case "-h", "--help", "help":
    usage()
    exit(0)
default:
    print("unknown command: \(command)\n")
    usage()
    exit(2)
}
