import CoreGraphics
import Foundation

enum MaskBrushRasterizer {
    static func interpolatedPoints(from start: CGPoint, to end: CGPoint,
                                   spacing: Double) -> [CGPoint] {
        let dx = Double(end.x - start.x)
        let dy = Double(end.y - start.y)
        let distance = hypot(dx, dy)
        let safeSpacing = max(spacing, 0.0001)
        guard distance >= safeSpacing else { return [] }

        let steps = max(1, Int(ceil(distance / safeSpacing)))
        return (1...steps).map { step in
            let t = Double(step) / Double(steps)
            return CGPoint(x: start.x + CGFloat(dx * t),
                           y: start.y + CGFloat(dy * t))
        }
    }

    @discardableResult
    static func apply(stroke: GraphMaskEraseStroke,
                      to values: UnsafeMutableBufferPointer<Float>,
                      width: Int, height: Int) -> Int {
        guard width > 0, height > 0, values.count >= width * height else { return 0 }
        let xDenom = Double(max(1, width - 1))
        let yDenom = Double(max(1, height - 1))
        let centerX = min(max(stroke.x, 0), 1)
        let centerY = min(max(stroke.y, 0), 1)
        let radius = min(max(stroke.radius, 0.0001), 1)
        let radiusSquared = radius * radius
        let strength = min(max(stroke.strength, 0), 1)
        let minX = max(0, Int(floor((centerX - radius) * xDenom)))
        let maxX = min(width - 1, Int(ceil((centerX + radius) * xDenom)))
        let minY = max(0, Int(floor((centerY - radius) * yDenom)))
        let maxY = min(height - 1, Int(ceil((centerY + radius) * yDenom)))
        var touched = 0

        for y in minY...maxY {
            let v = Double(y) / yDenom
            for x in minX...maxX {
                let u = Double(x) / xDenom
                let dx = u - centerX
                let dy = v - centerY
                let distanceSquared = dx * dx + dy * dy
                if distanceSquared > radiusSquared { continue }
                let t = 1 - min(max(sqrt(distanceSquared) / radius, 0), 1)
                let falloff = t * t * (3 - 2 * t)
                let erase = Float(min(max(strength * falloff, 0), 1))
                let index = y * width + x
                values[index] = max(0, values[index] * (1 - erase))
                touched += 1
            }
        }
        return touched
    }

    @discardableResult
    static func apply(strokes: [GraphMaskEraseStroke],
                      to values: UnsafeMutableBufferPointer<Float>,
                      width: Int, height: Int) -> Int {
        strokes.reduce(into: 0) { touched, stroke in
            touched += apply(stroke: stroke, to: values,
                             width: width, height: height)
        }
    }
}
