import AVFoundation
import Foundation
setvbuf(stdout, nil, _IONBF, 0)

final class C: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let sess = AVCaptureSession()
    var means: [(Double, Double)] = []
    var t0 = Date()
    let sem = DispatchSemaphore(value: 0)
    let duration = 24.0

    func run() {
        let ds = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
        guard let dev = ds.devices.first(where: { $0.localizedName.contains("UVC Camera") }),
              let inp = try? AVCaptureDeviceInput(device: dev) else { print("glasses not found"); return }
        sess.beginConfiguration(); sess.addInput(inp)
        let out = AVCaptureVideoDataOutput()
        out.setSampleBufferDelegate(self, queue: DispatchQueue(label: "c"))
        sess.addOutput(out); sess.commitConfiguration()

        print("Starting in 3 seconds. Leave the lenses UNCOVERED, pointed at the room.")
        Thread.sleep(forTimeInterval: 3)
        t0 = Date(); sess.startRunning()

        let phases: [(Double, String)] = [
            (0,  ">>> PHASE 1 (8s): lenses UNCOVERED, hold still, point at the room"),
            (8,  ">>> PHASE 2 (8s): COVER BOTH LENSES NOW with your palm, press flat"),
            (16, ">>> PHASE 3 (8s): UNCOVER and wave your hand in front of the lenses"),
        ]
        for (at, msg) in phases {
            let wait = at - Date().timeIntervalSince(t0)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            print(msg)
        }
        Thread.sleep(forTimeInterval: max(0, duration - Date().timeIntervalSince(t0)))
        sess.stopRunning()
        report()
    }

    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard let px = CMSampleBufferGetImageBuffer(sb) else { return }
        CVPixelBufferLockBaseAddress(px, .readOnly)
        let n = CVPixelBufferGetHeight(px) * CVPixelBufferGetBytesPerRow(px)
        var s = 0, k = 0
        if let b = CVPixelBufferGetBaseAddress(px)?.assumingMemoryBound(to: UInt8.self) {
            while k < n { s += Int(b[k]); k += 17 }
        }
        CVPixelBufferUnlockBaseAddress(px, .readOnly)
        means.append((Date().timeIntervalSince(t0), Double(s)/Double(n/17)))
    }

    func report() {
        func avg(_ lo: Double, _ hi: Double) -> Double {
            let v = means.filter { $0.0 >= lo && $0.0 < hi }.map { $0.1 }
            return v.isEmpty ? -1 : v.reduce(0,+)/Double(v.count)
        }
        let open1 = avg(4, 8), covered = avg(11, 16), open2 = avg(19, 24)
        print("\n================ RESULT ================")
        print(String(format: "  uncovered (phase 1): mean = %.2f", open1))
        print(String(format: "  COVERED   (phase 2): mean = %.2f", covered))
        print(String(format: "  uncovered (phase 3): mean = %.2f", open2))
        let drop = open1 - covered
        print(String(format: "\n  brightness drop when covered: %.2f", drop))
        if drop > 10 {
            print("  => REAL IMAGING CONFIRMED. Sensor responds to the scene.")
            print("     The strips are purely a byte-layout problem.")
        } else if drop < 3 {
            print("  => NOT IMAGING THE SCENE. Output ignores light.")
            print("     Sensor needs an MCU init sequence before it produces usable frames.")
        } else {
            print("  => INCONCLUSIVE. Retry with a firmer cover, in a brighter room.")
        }
        print("========================================")
    }
}
let c = C(); c.run()
