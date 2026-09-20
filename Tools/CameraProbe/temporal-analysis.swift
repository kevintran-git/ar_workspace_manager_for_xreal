import AVFoundation
import Foundation

final class T: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let sess = AVCaptureSession(); var frames: [[UInt8]] = []; let sem = DispatchSemaphore(value: 0)
    let want = 40
    func run() {
        let ds = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
        guard let dev = ds.devices.first(where: { $0.localizedName.contains("UVC Camera") }),
              let inp = try? AVCaptureDeviceInput(device: dev) else { print("no device"); return }
        sess.beginConfiguration(); sess.addInput(inp)
        let out = AVCaptureVideoDataOutput()
        out.setSampleBufferDelegate(self, queue: DispatchQueue(label: "t"))
        sess.addOutput(out); sess.commitConfiguration(); sess.startRunning()
        _ = sem.wait(timeout: .now() + 20); sess.stopRunning()
        analyze()
    }
    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard frames.count < want, let px = CMSampleBufferGetImageBuffer(sb) else { return }
        CVPixelBufferLockBaseAddress(px, .readOnly)
        let h = CVPixelBufferGetHeight(px), bpr = CVPixelBufferGetBytesPerRow(px)
        if let b = CVPixelBufferGetBaseAddress(px)?.assumingMemoryBound(to: UInt8.self) {
            frames.append(Array(UnsafeBufferPointer(start: b, count: h*bpr)))
        }
        CVPixelBufferUnlockBaseAddress(px, .readOnly)
        if frames.count >= want { sem.signal() }
    }
    func analyze() {
        guard frames.count > 5 else { print("only \(frames.count) frames"); return }
        let n = frames[0].count
        print("captured \(frames.count) frames of \(n) bytes")
        print("\n--- frame mean brightness over time ---")
        for (i, f) in frames.enumerated() where i % 4 == 0 {
            var s = 0; var k = 0
            while k < n { s += Int(f[k]); k += 13 }
            print(String(format: "  frame %2d  mean=%6.2f", i, Double(s)/Double(n/13)))
        }
        var tacc = 0.0; var tc = 0
        for i in 1..<frames.count {
            var k = 0
            while k < n { tacc += Double(abs(Int(frames[i][k]) - Int(frames[i-1][k]))); tc += 1; k += 29 }
        }
        print(String(format: "\ntemporal mean-abs-diff between consecutive frames: %.3f", tacc/Double(tc)))
        print("  (a static real scene -> small, e.g. < 5. uninitialized sensor noise -> large)")

        let W = 640, R = n / W
        var rowMeans = [[Double]](repeating: [], count: R)
        for f in frames {
            for r in 0..<R {
                var s = 0
                for x in stride(from: 0, to: W, by: 8) { s += Int(f[r*W + x]) }
                rowMeans[r].append(Double(s)/Double(W/8))
            }
        }
        var acrossRowSpread = 0.0, withinRowSpread = 0.0
        var allMeans = [Double]()
        for r in 0..<R {
            let m = rowMeans[r].reduce(0,+)/Double(rowMeans[r].count)
            allMeans.append(m)
            let v = rowMeans[r].map { abs($0 - m) }.reduce(0,+)/Double(rowMeans[r].count)
            withinRowSpread += v
        }
        withinRowSpread /= Double(R)
        let gm = allMeans.reduce(0,+)/Double(R)
        acrossRowSpread = allMeans.map { abs($0 - gm) }.reduce(0,+)/Double(R)
        print(String(format: "\nrow brightness: across-rows spread=%.2f  within-row over time=%.2f",
                     acrossRowSpread, withinRowSpread))
        print("  across >> within  =>  FIXED horizontal banding (sensor not properly configured)")
        print("  across ~= within  =>  rows vary with the scene (real imaging)")
    }
}
let t = T(); t.run()
