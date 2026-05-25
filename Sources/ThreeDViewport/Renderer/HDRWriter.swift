import Foundation

// Minimal Radiance RGBE (.hdr) writer — the counterpart to HDRImage's reader.
// Emits flat (uncompressed) "-Y H +X W" scanlines, which HDRImage and every
// common tool read back.  Used by EnvironmentBaker to save a baked environment.
enum HDRWriter {

    /// Writes a linear RGBA float buffer (`width*height*4`, row-major, top row
    /// first) as a Radiance `.hdr` file.  Alpha is ignored.  Returns false on
    /// bad input or a write error.
    @discardableResult
    static func write(rgba: [Float], width: Int, height: Int, to url: URL) -> Bool {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else {
            print("[DEBUG] HDRWriter: invalid input (\(width)×\(height), \(rgba.count) floats)")
            return false
        }

        var out = Data()
        out.append(Data("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y \(height) +X \(width)\n".utf8))

        var row = [UInt8](repeating: 0, count: width * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let (r, g, b, e) = Self.toRGBE(max(0, rgba[o]),
                                               max(0, rgba[o + 1]),
                                               max(0, rgba[o + 2]))
                row[x * 4 + 0] = r
                row[x * 4 + 1] = g
                row[x * 4 + 2] = b
                row[x * 4 + 3] = e
            }
            out.append(contentsOf: row)
        }

        do {
            try out.write(to: url, options: .atomic)
            print("[DEBUG] HDRWriter: wrote \(width)×\(height) → \(url.lastPathComponent)")
            return true
        } catch {
            print("[DEBUG] HDRWriter: write failed — \(error)")
            return false
        }
    }

    /// Encodes one linear RGB triple to a shared-exponent RGBE byte quad — the
    /// exact inverse of HDRImage's `scalbn(1, e-136)` decode, so it round-trips.
    private static func toRGBE(_ r: Float, _ g: Float, _ b: Float) -> (UInt8, UInt8, UInt8, UInt8) {
        let m = max(r, max(g, b))
        if m < 1e-32 { return (0, 0, 0, 0) }
        var e: Int32 = 0
        let frac  = frexpf(m, &e)            // m = frac · 2^e,  frac ∈ [0.5, 1)
        let scale = frac * 256.0 / m
        func byte(_ v: Float) -> UInt8 { UInt8(min(255, max(0, Int(v * scale)))) }
        return (byte(r), byte(g), byte(b), UInt8(min(255, max(0, Int(e + 128)))))
    }
}
