import Foundation

// Minimal Radiance RGBE (.hdr) reader.
// Handles the new-style adaptive RLE scanline encoding (what Poly Haven and most
// tools export) with a flat-scanline fallback.  Produces a linear float RGBA
// buffer ready to upload as an .rgba32Float 2D texture.
//
// Not a general-purpose loader: assumes 32-bit_rle_rgbe and the common
// "-Y height +X width" orientation, which covers the bundled studio HDRIs.
struct HDRImage {

    let width:  Int
    let height: Int
    let rgba:   [Float]   // count = width * height * 4, linear, alpha = 1

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let bytes = [UInt8](data)
        let n = bytes.count
        var p = 0

        // ── Header ──────────────────────────────────────────────────────────
        func readLine() -> String? {
            var chars = [UInt8]()
            while p < n {
                let b = bytes[p]; p += 1
                if b == 0x0A { break }            // newline
                chars.append(b)
            }
            return String(bytes: chars, encoding: .ascii)
        }

        guard let magic = readLine(), magic.hasPrefix("#?") else { return nil }

        // Consume variable header lines until the blank separator.
        while let line = readLine() {
            if line.isEmpty { break }
        }

        // ── Resolution line: "-Y H +X W" ───────────────────────────────────
        guard let resLine = readLine() else { return nil }
        let toks = resLine.split(separator: " ").map(String.init)
        guard toks.count == 4, toks[0] == "-Y", toks[2] == "+X",
              let h = Int(toks[1]), let w = Int(toks[3]),
              w > 0, h > 0 else { return nil }

        // ── Pixel data ──────────────────────────────────────────────────────
        var out  = [Float](repeating: 0, count: w * h * 4)
        var scan = [UInt8](repeating: 0, count: w * 4)   // RGBE for one row

        for y in 0..<h {
            guard p + 4 <= n else { return nil }
            let b0 = bytes[p], b1 = bytes[p+1], b2 = bytes[p+2], b3 = bytes[p+3]
            let declaredWidth = (Int(b2) << 8) | Int(b3)
            let newRLE = (b0 == 2 && b1 == 2 && declaredWidth == w && w >= 8 && w < 32768)

            if newRLE {
                p += 4
                // Four channels (R,G,B,E), each RLE-encoded across the row.
                for c in 0..<4 {
                    var x = 0
                    while x < w {
                        guard p < n else { return nil }
                        let count = Int(bytes[p]); p += 1
                        if count > 128 {
                            guard p < n else { return nil }
                            let val = bytes[p]; p += 1
                            let run = count - 128
                            var k = 0
                            while k < run && x < w { scan[x*4 + c] = val; x += 1; k += 1 }
                        } else {
                            var k = 0
                            while k < count {
                                guard p < n else { return nil }
                                if x < w { scan[x*4 + c] = bytes[p]; x += 1 }
                                p += 1; k += 1
                            }
                        }
                    }
                }
            } else {
                // Flat RGBE scanline.
                for x in 0..<w {
                    guard p + 4 <= n else { return nil }
                    scan[x*4+0] = bytes[p+0]
                    scan[x*4+1] = bytes[p+1]
                    scan[x*4+2] = bytes[p+2]
                    scan[x*4+3] = bytes[p+3]
                    p += 4
                }
            }

            // RGBE → linear float.
            for x in 0..<w {
                let e = scan[x*4+3]
                let o = (y * w + x) * 4
                if e == 0 {
                    out[o] = 0; out[o+1] = 0; out[o+2] = 0; out[o+3] = 1
                } else {
                    let f = Float(scalbn(1.0, Int(e) - (128 + 8)))
                    out[o]   = Float(scan[x*4+0]) * f
                    out[o+1] = Float(scan[x*4+1]) * f
                    out[o+2] = Float(scan[x*4+2]) * f
                    out[o+3] = 1
                }
            }
        }

        width  = w
        height = h
        rgba   = out
    }
}
