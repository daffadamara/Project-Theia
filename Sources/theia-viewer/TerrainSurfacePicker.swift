import Foundation
import simd

enum TerrainSurfacePicker {
    static func intersect(origin: SIMD3<Float>, direction: SIMD3<Float>,
                          heights: [Float], width: Int, height: Int,
                          baseHeight: Float, maxHeight: Float,
                          heightScale: Float) -> CGPoint? {
        guard width > 1, height > 1, heights.count >= width * height else { return nil }
        let worldMaxY = max(0.001, (maxHeight - baseHeight) * heightScale + 0.001)
        guard let interval = rayBoxInterval(origin: origin, direction: direction,
                                            minimum: SIMD3<Float>(-1, -0.001, -1),
                                            maximum: SIMD3<Float>(1, worldMaxY, 1)) else {
            return nil
        }

        let steps = 384
        var previousT = interval.lowerBound
        var previousPoint = origin + direction * previousT
        var previousDelta = previousPoint.y - surfaceHeight(
            x: previousPoint.x, z: previousPoint.z,
            heights: heights, width: width, height: height,
            baseHeight: baseHeight, heightScale: heightScale)

        for step in 1...steps {
            let fraction = Float(step) / Float(steps)
            let t = interval.lowerBound + (interval.upperBound - interval.lowerBound) * fraction
            let point = origin + direction * t
            let delta = point.y - surfaceHeight(
                x: point.x, z: point.z,
                heights: heights, width: width, height: height,
                baseHeight: baseHeight, heightScale: heightScale)
            if previousDelta >= 0, delta <= 0 {
                var low = previousT
                var high = t
                for _ in 0..<14 {
                    let mid = (low + high) * 0.5
                    let samplePoint = origin + direction * mid
                    let sampleDelta = samplePoint.y - surfaceHeight(
                        x: samplePoint.x, z: samplePoint.z,
                        heights: heights, width: width, height: height,
                        baseHeight: baseHeight, heightScale: heightScale)
                    if sampleDelta > 0 {
                        low = mid
                    } else {
                        high = mid
                    }
                }
                let hit = origin + direction * ((low + high) * 0.5)
                guard hit.x >= -1, hit.x <= 1, hit.z >= -1, hit.z <= 1 else { return nil }
                return CGPoint(x: CGFloat((hit.x + 1) * 0.5),
                               y: CGFloat((hit.z + 1) * 0.5))
            }
            previousT = t
            previousPoint = point
            previousDelta = delta
        }
        return nil
    }

    private static func surfaceHeight(x: Float, z: Float,
                                      heights: [Float], width: Int, height: Int,
                                      baseHeight: Float, heightScale: Float) -> Float {
        let u = min(max((x + 1) * 0.5, 0), 1)
        let v = min(max((z + 1) * 0.5, 0), 1)
        let gridX = u * Float(width - 1)
        let gridY = v * Float(height - 1)
        let x0 = Int(floor(gridX))
        let y0 = Int(floor(gridY))
        let x1 = min(width - 1, x0 + 1)
        let y1 = min(height - 1, y0 + 1)
        let fx = gridX - Float(x0)
        let fy = gridY - Float(y0)
        let a = heights[y0 * width + x0]
        let b = heights[y0 * width + x1]
        let c = heights[y1 * width + x0]
        let d = heights[y1 * width + x1]
        let top = a + (b - a) * fx
        let bottom = c + (d - c) * fx
        return ((top + (bottom - top) * fy) - baseHeight) * heightScale
    }

    private static func rayBoxInterval(origin: SIMD3<Float>, direction: SIMD3<Float>,
                                       minimum: SIMD3<Float>, maximum: SIMD3<Float>)
        -> ClosedRange<Float>? {
        var near: Float = 0
        var far = Float.greatestFiniteMagnitude
        for axis in 0..<3 {
            let o = origin[axis]
            let d = direction[axis]
            if abs(d) < 1e-7 {
                if o < minimum[axis] || o > maximum[axis] { return nil }
                continue
            }
            var t0 = (minimum[axis] - o) / d
            var t1 = (maximum[axis] - o) / d
            if t0 > t1 { swap(&t0, &t1) }
            near = max(near, t0)
            far = min(far, t1)
            if near > far { return nil }
        }
        guard far > 0 else { return nil }
        return max(near, 0)...far
    }
}
