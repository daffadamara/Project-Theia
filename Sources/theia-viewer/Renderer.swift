import CoreGraphics
import Foundation
import ImageIO
import Metal
import MetalKit
import UniformTypeIdentifiers
import simd

struct Uniforms {
    var mvp: float4x4
    var lightDirection: SIMD4<Float>
    var heightScale: Float
    var gridW: UInt32
    var gridH: UInt32
    var pad: UInt32
}

// Renders a heightfield as a lit, displaced triangle grid. Shared by the live
// MTKView path and the offscreen --shot path.
final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let colorFormat: MTLPixelFormat
    let depthFormat: MTLPixelFormat = .depth32Float

    private var pipeline: MTLRenderPipelineState
    private var depthState: MTLDepthStencilState

    private var heightBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var indexCount = 0
    private(set) var gridW: UInt32 = 0
    private(set) var gridH: UInt32 = 0
    private let maxViewerGrid = 768

    var camera = OrbitCamera.framed(heightExaggeration: 0.5)
    var heightExaggeration: Float = 0.5
    private var lightAzimuthDegrees: Float = 35.0
    private var lightElevationDegrees: Float = 58.0
    var wireframeEnabled = false
    var clear = MTLClearColor(red: 0.09, green: 0.11, blue: 0.14, alpha: 1.0)

    init?(device: MTLDevice, colorFormat: MTLPixelFormat) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.colorFormat = colorFormat
        do {
            let lib = try device.makeLibrary(source: terrainShaderSource, options: nil)
            guard let vfn = lib.makeFunction(name: "terrain_vertex"),
                  let ffn = lib.makeFunction(name: "terrain_fragment") else { return nil }
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = vfn
            pd.fragmentFunction = ffn
            pd.colorAttachments[0].pixelFormat = colorFormat
            pd.depthAttachmentPixelFormat = depthFormat
            pipeline = try device.makeRenderPipelineState(descriptor: pd)
        } catch {
            FileHandle.standardError.write(Data("shader build failed: \(error)\n".utf8))
            return nil
        }
        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        guard let ds = device.makeDepthStencilState(descriptor: dd) else { return nil }
        depthState = ds
    }

    func setHeights(_ heights: [Float], width: Int, height: Int) {
        guard width > 1, height > 1, heights.count >= width * height else { return }
        let sampled = Self.viewerHeights(heights, width: width, height: height,
                                         maxGrid: maxViewerGrid)
        heightBuffer = device.makeBuffer(bytes: sampled.values,
                                         length: sampled.values.count * MemoryLayout<Float>.stride,
                                         options: .storageModeShared)
        if gridW != UInt32(sampled.width) || gridH != UInt32(sampled.height) ||
            indexBuffer == nil {
            buildIndices(width: sampled.width, height: sampled.height)
            gridW = UInt32(sampled.width)
            gridH = UInt32(sampled.height)
        }
    }

    private static func viewerHeights(_ heights: [Float], width: Int, height: Int,
                                      maxGrid: Int) -> (values: [Float], width: Int, height: Int) {
        guard max(width, height) > maxGrid else {
            return (heights, width, height)
        }

        let scale = Double(maxGrid) / Double(max(width, height))
        let outW = max(2, Int((Double(width) * scale).rounded()))
        let outH = max(2, Int((Double(height) * scale).rounded()))
        let xScale = Double(width - 1) / Double(outW - 1)
        let yScale = Double(height - 1) / Double(outH - 1)
        var out = [Float](repeating: 0, count: outW * outH)
        for y in 0..<outH {
            let sy = min(height - 1, Int((Double(y) * yScale).rounded()))
            for x in 0..<outW {
                let sx = min(width - 1, Int((Double(x) * xScale).rounded()))
                out[y * outW + x] = heights[sy * width + sx]
            }
        }
        return (out, outW, outH)
    }

    private func buildIndices(width: Int, height: Int) {
        var idx = [UInt32]()
        idx.reserveCapacity((width - 1) * (height - 1) * 6)
        for z in 0..<(height - 1) {
            for x in 0..<(width - 1) {
                let i = UInt32(z * width + x)
                let r = i + 1
                let d = UInt32((z + 1) * width + x)
                let dr = d + 1
                idx.append(contentsOf: [i, d, r, r, d, dr])
            }
        }
        indexBuffer = device.makeBuffer(bytes: idx,
                                        length: idx.count * MemoryLayout<UInt32>.stride,
                                        options: .storageModeShared)
        indexCount = idx.count
    }

    func encode(commandBuffer: MTLCommandBuffer, passDescriptor: MTLRenderPassDescriptor,
                viewportSize: CGSize) {
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }
        if let hb = heightBuffer, let ib = indexBuffer, indexCount > 0 {
            let aspect = Float(viewportSize.width / max(1, viewportSize.height))
            var u = Uniforms(mvp: camera.viewProjection(aspect: aspect),
                             lightDirection: lightDirection(),
                             heightScale: heightExaggeration,
                             gridW: gridW, gridH: gridH, pad: 0)
            enc.setRenderPipelineState(pipeline)
            enc.setDepthStencilState(depthState)
            enc.setCullMode(.none)
            enc.setTriangleFillMode(wireframeEnabled ? .lines : .fill)
            enc.setVertexBuffer(hb, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount,
                                      indexType: .uint32, indexBuffer: ib,
                                      indexBufferOffset: 0)
        }
        enc.endEncoding()
    }

    func applyViewportSettings(heightExaggeration: Double,
                               lightAzimuthDegrees: Double,
                               lightElevationDegrees: Double,
                               wireframeEnabled: Bool) {
        self.heightExaggeration = Float(heightExaggeration)
        self.lightAzimuthDegrees = Float(lightAzimuthDegrees)
        self.lightElevationDegrees = Float(lightElevationDegrees)
        self.wireframeEnabled = wireframeEnabled
    }

    func resetCamera() {
        camera.reset(heightExaggeration: heightExaggeration)
    }

    private func lightDirection() -> SIMD4<Float> {
        let az = lightAzimuthDegrees * .pi / 180
        let el = lightElevationDegrees * .pi / 180
        let ce = cos(el)
        return SIMD4<Float>(sin(az) * ce, sin(el), cos(az) * ce, 0)
    }

    // Offscreen render of a single frame to a PNG. No window required.
    func renderToPNG(path: String, width: Int, height: Int) -> Bool {
        let cd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorFormat, width: width, height: height, mipmapped: false)
        cd.usage = [.renderTarget]
        cd.storageMode = .shared
        let dd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: depthFormat, width: width, height: height, mipmapped: false)
        dd.usage = [.renderTarget]
        dd.storageMode = .private
        guard let color = device.makeTexture(descriptor: cd),
              let depth = device.makeTexture(descriptor: dd),
              let cb = queue.makeCommandBuffer() else { return false }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = color
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.depthAttachment.texture = depth
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1.0
        rpd.depthAttachment.storeAction = .dontCare

        encode(commandBuffer: cb, passDescriptor: rpd,
               viewportSize: CGSize(width: width, height: height))
        cb.commit()
        cb.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        color.getBytes(&bytes, bytesPerRow: width * 4,
                       from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return Self.writeBGRAtoPNG(bytes, width: width, height: height, path: path)
    }

    static func writeBGRAtoPNG(_ bytes: [UInt8], width: Int, height: Int,
                               path: String) -> Bool {
        let cs = CGColorSpaceCreateDeviceRGB()
        // bgra8 in memory == byteOrder32Little + alphaFirst-skipped == RGB
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let img = CGImage(width: width, height: height, bitsPerComponent: 8,
                                bitsPerPixel: 32, bytesPerRow: width * 4, space: cs,
                                bitmapInfo: info, provider: provider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent)
        else { return false }
        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(
            url, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }
}
