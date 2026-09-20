import Foundation
let d = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: "/tmp/xreal_raw.bin")))
let n = d.count

func smooth(_ b: [UInt8], _ w: Int) -> (Double, Double, Int)? {
    let h = b.count / w
    if h < 40 || w < 32 { return nil }
    var hs = 0, vs = 0, c = 0
    var y = 1
    while y < h { var x = 1
        while x < w { let i = y*w+x
            if abs(Int(b[i]) - Int(b[i-1])) <= 6 { hs += 1 }
            if abs(Int(b[i]) - Int(b[i-w])) <= 6 { vs += 1 }
            c += 1; x += 2 }
        y += 2 }
    return (Double(hs)/Double(c), Double(vs)/Double(c), h)
}

let raw = d
var evenP = [UInt8](); for i in stride(from: 0, to: n-1, by: 2) { evenP.append(d[i]) }
var oddP  = [UInt8](); for i in stride(from: 1, to: n,   by: 2) { oddP.append(d[i]) }

func report(_ label: String, _ b: [UInt8], _ widths: [Int]) {
    print("\n=== \(label) ===")
    var rows: [(Int, Double, Double, Int)] = []
    for w in widths { if let (hh, vv, h) = smooth(b, w) { rows.append((w, hh, vv, h)) } }
    rows.sort { min($0.1,$0.2) > min($1.1,$1.2) }
    for (w, hh, vv, h) in rows.prefix(6) {
        print(String(format: "  w=%4d h=%4d  Hsmooth=%.3f Vsmooth=%.3f  min=%.3f", w, h, hh, vv, min(hh,vv)))
    }
}
report("RAW bytes", raw, Array(64...1300))
report("EVEN plane (Y of YUY2)", evenP, Array(64...800))
report("ODD plane", oddP, Array(64...800))

var serp = [UInt8](repeating: 0, count: (n/640)*640)
let R = n/640
for r in 0..<R {
    for x in 0..<640 {
        serp[r*640 + x] = (r % 2 == 0) ? d[r*640 + x] : d[r*640 + (639 - x)]
    }
}
if let (hh, vv, h) = smooth(serp, 640) {
    print(String(format: "\nSERPENTINE 640 wide: h=%d Hsmooth=%.3f Vsmooth=%.3f", h, hh, vv))
}
var rng = SystemRandomNumberGenerator()
var noise = [UInt8](); for _ in 0..<307200 { noise.append(UInt8.random(in: 0...255, using: &rng)) }
if let (hh, vv, _) = smooth(noise, 640) {
    print(String(format: "NOISE baseline 640 wide: Hsmooth=%.3f Vsmooth=%.3f", hh, vv))
}
