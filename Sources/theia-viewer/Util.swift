import TheiaCore

// std::string does not bridge to Swift.String on this toolchain; the C++ core
// returns strings by copying into a caller buffer. (Mirrors theia-cli.)
func readCxxString(_ accessor: (UnsafeMutablePointer<CChar>?, Int) -> Int) -> String {
    var buf = [CChar](repeating: 0, count: 1024)
    let n = buf.withUnsafeMutableBufferPointer { accessor($0.baseAddress, $0.count) }
    let len = min(max(n, 0), buf.count - 1)
    return String(decoding: buf[0..<len].map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func readCxxLongString(_ accessor: (UnsafeMutablePointer<CChar>?, Int) -> Int) -> String {
    var cap = 4096
    while true {
        var buf = [CChar](repeating: 0, count: cap)
        let n = buf.withUnsafeMutableBufferPointer { accessor($0.baseAddress, $0.count) }
        if n < cap {
            let len = max(n, 0)
            return String(decoding: buf[0..<len].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        cap = max(cap * 2, n + 1)
    }
}
