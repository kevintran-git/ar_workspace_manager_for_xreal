import AVFoundation
import AppKit

let reorderMap: [Int] = [
    119, 54, 21, 0, 108, 22, 51, 63, 93, 99, 67, 7, 32, 112, 52, 43,
    14, 35, 75, 116, 64, 71, 44, 89, 18, 88, 26, 61, 70, 56, 90, 79,
    87, 120, 81, 101, 121, 17, 72, 31, 53, 124, 127, 113, 111, 36, 48,
    19, 37, 83, 126, 74, 109, 5, 84, 41, 76, 30, 110, 29, 12, 115, 28,
    102, 105, 62, 103, 20, 3, 68, 49, 77, 117, 125, 106, 60, 69, 98, 9,
    16, 78, 47, 40, 2, 118, 34, 13, 50, 46, 80, 85, 66, 42, 123, 122,
    96, 11, 25, 97, 39, 6, 86, 1, 8, 82, 92, 59, 104, 24, 15, 73, 65,
    38, 58, 10, 23, 33, 55, 57, 107, 100, 94, 27, 95, 45, 91, 4, 114,
]

let blockCount = 128
let blockSize = 2400
let imageBytes = blockCount * blockSize
let sensorW = 640, sensorH = 480
let outW = 480, outH = 640
let metaOffset = imageBytes

struct Frame {
    var pixels: [UInt8]
    var cameraID: UInt8
    var sequence: UInt16
    var timestampNS: UInt64
}

func descramble(_ raw: UnsafePointer<UInt8>) -> Frame {
    var best = Int.max, sync = 0
    for b in 0..<blockCount {
        var s = 0
        for i in 0..<128 { s += Int(raw[b * blockSize + i]) }
        if s < best { best = s; sync = b }
    }
    let align = reorderMap.firstIndex(of: sync)!

    var scan = [UInt8](repeating: 0, count: imageBytes)
    scan.withUnsafeMutableBufferPointer { dst in
        for t in 0..<blockCount {
            let src = reorderMap[(align + t) % blockCount]
            dst.baseAddress!.advanced(by: t * blockSize)
                .update(from: raw.advanced(by: src * blockSize), count: blockSize)
        }
    }

    var upright = [UInt8](repeating: 0, count: outW * outH)
    scan.withUnsafeBufferPointer { s in
        upright.withUnsafeMutableBufferPointer { d in
            for c in 0..<sensorH {
                let line = s.baseAddress! + c * sensorW
                for r in 0..<sensorW { d[r * outW + c] = line[r] }
            }
        }
    }

    var ts: UInt64 = 0
    for i in (0..<8).reversed() { ts = (ts << 8) | UInt64(raw[metaOffset + i]) }
    let seq = UInt16(raw[metaOffset + 18]) | (UInt16(raw[metaOffset + 19]) << 8)
    return Frame(pixels: upright, cameraID: raw[metaOffset + 0x3A], sequence: seq, timestampNS: ts)
}

func writePNG(_ px: [UInt8], _ w: Int, _ h: Int, _ path: String) {
    var buf = px
    buf.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let cg = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

final class Capture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let done = DispatchSemaphore(value: 0)
    var seen = 0
    var pending: [UInt16: Frame] = [:]
    var pairsWritten = 0
    let wanted = 4

    func run() {
        let ds = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
        guard let dev = ds.devices.first(where: { $0.localizedName.contains("UVC Camera") }),
              let input = try? AVCaptureDeviceInput(device: dev) else {
            print("no UVC camera"); return
        }
        session.beginConfiguration()
        session.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.setSampleBufferDelegate(self, queue: DispatchQueue(label: "descramble"))
        session.addOutput(out)
        session.commitConfiguration()
        session.startRunning()
        _ = done.wait(timeout: .now() + 20)
        session.stopRunning()
    }

    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        seen += 1
        guard seen > 6 else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let height = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        guard stride * height >= imageBytes + 640, let base = CVPixelBufferGetBaseAddress(pb) else { return }

        let f = descramble(base.assumingMemoryBound(to: UInt8.self))
        print(String(format: "frame %3d  cam=0x%02x  seq=%5d  ts=%llu", seen, f.cameraID, f.sequence, f.timestampNS))

        if let other = pending[f.sequence], other.cameraID != f.cameraID {
            pending.removeValue(forKey: f.sequence)
            let left  = f.cameraID == 0x20 ? f : other
            let right = f.cameraID == 0x20 ? other : f
            writePNG(left.pixels,  outW, outH, "/tmp/xreal_left_\(pairsWritten).png")
            writePNG(right.pixels, outW, outH, "/tmp/xreal_right_\(pairsWritten).png")
            print("  pair \(pairsWritten) seq=\(f.sequence) -> /tmp/xreal_{left,right}_\(pairsWritten).png")
            pairsWritten += 1
            if pairsWritten >= wanted { done.signal() }
        } else {
            pending[f.sequence] = f
        }
    }
}

let args = CommandLine.arguments
if args.count > 1 {
    let url = URL(fileURLWithPath: args[1])
    guard let data = try? Data(contentsOf: url), data.count >= imageBytes + 640 else {
        print("need a \(imageBytes + 1280)-byte raw frame"); exit(1)
    }
    let f = data.withUnsafeBytes { descramble($0.bindMemory(to: UInt8.self).baseAddress!) }
    let out = args.count > 2 ? args[2] : "/tmp/xreal_descrambled.png"
    writePNG(f.pixels, outW, outH, out)
    print(String(format: "cam=0x%02x  seq=%d  ts=%llu  -> %@", f.cameraID, f.sequence, f.timestampNS, out))
} else {
    Capture().run()
}
