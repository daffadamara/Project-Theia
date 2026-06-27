import simd

// Right-handed perspective projection mapping depth to [0,1] (Metal convention),
// column-major (Metal-ready).
func perspectiveRH(fovy: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
    let y = 1 / tan(fovy * 0.5)
    let x = y / aspect
    let z = far / (near - far)
    return float4x4(
        SIMD4<Float>(x, 0, 0, 0),
        SIMD4<Float>(0, y, 0, 0),
        SIMD4<Float>(0, 0, z, -1),
        SIMD4<Float>(0, 0, z * near, 0))
}

func lookAtRH(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
    let z = normalize(eye - center)
    let x = normalize(cross(up, z))
    let y = cross(z, x)
    return float4x4(
        SIMD4<Float>(x.x, y.x, z.x, 0),
        SIMD4<Float>(x.y, y.y, z.y, 0),
        SIMD4<Float>(x.z, y.z, z.z, 0),
        SIMD4<Float>(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1))
}

// Orbit camera: spherical position (azimuth/elevation/distance) around a target.
struct OrbitCamera {
    var target = SIMD3<Float>(0, 0.05, 0)
    var distance: Float = 2.8
    var azimuth: Float = .pi * 0.25
    var elevation: Float = .pi * 0.30
    var fovy: Float = 50 * .pi / 180

    static func framed(heightExaggeration: Float) -> OrbitCamera {
        var c = OrbitCamera()
        c.target = SIMD3<Float>(0, max(0.04, heightExaggeration * 0.35), 0)
        c.distance = max(2.8, 2.45 + heightExaggeration * 1.1)
        c.azimuth = .pi * 0.25
        c.elevation = .pi * 0.28
        c.fovy = 50 * .pi / 180
        return c
    }

    mutating func reset(heightExaggeration: Float) {
        self = Self.framed(heightExaggeration: heightExaggeration)
    }

    func eye() -> SIMD3<Float> {
        let ce = cos(elevation), se = sin(elevation)
        let ca = cos(azimuth), sa = sin(azimuth)
        return target + distance * SIMD3<Float>(ce * sa, se, ce * ca)
    }
    func viewProjection(aspect: Float) -> float4x4 {
        let view = lookAtRH(eye: eye(), center: target, up: SIMD3<Float>(0, 1, 0))
        let proj = perspectiveRH(fovy: fovy, aspect: max(0.01, aspect), near: 0.01, far: 100)
        return proj * view
    }
}
