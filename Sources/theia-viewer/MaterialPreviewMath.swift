import Foundation

// CPU mirror of the audited shader transfer functions. It keeps the
// reference-gate color fixtures executable without moving preview blending out
// of the Metal fragment shader.
enum MaterialPreviewMath {
    static func srgbToLinear(_ value: Double) -> Double {
        value <= 0.04045
            ? value / 12.92
            : pow((value + 0.055) / 1.055, 2.4)
    }

    static func linearToSRGB(_ value: Double) -> Double {
        value <= 0.0031308
            ? value * 12.92
            : 1.055 * pow(max(0, value), 1.0 / 2.4) - 0.055
    }

    static func blend(colorsSRGB: [[Double]], weights: [Double]) -> [Double] {
        (0..<3).map { channel in
            let linear = zip(colorsSRGB, weights).reduce(0.0) { result, pair in
                guard pair.0.indices.contains(channel) else { return result }
                return result + pair.1 * srgbToLinear(pair.0[channel])
            }
            return min(max(linearToSRGB(linear), 0), 1)
        }
    }
}
