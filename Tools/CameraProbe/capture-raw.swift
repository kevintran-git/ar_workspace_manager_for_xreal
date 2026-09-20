import AVFoundation
import AppKit

final class G: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let sess = AVCaptureSession(); var n = 0; let sem = DispatchSemaphore(value: 0)
    func run() {
        let ds = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
        guard let dev = ds.devices.first(where: { $0.localizedName.contains("UVC Camera") }),
              let inp = try? AVCaptureDeviceInput(device: dev) else { return }
        sess.beginConfiguration(); sess.addInput(inp)
        let out = AVCaptureVideoDataOutput()
        out.setSampleBufferDelegate(self, queue: DispatchQueue(label: "g"))
        sess.addOutput(out); sess.commitConfiguration(); sess.startRunning()
        _ = sem.wait(timeout: .now() + 15); sess.stopRunning()
    }
    func writeGray(_ bytes: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ srcRow: Int, _ path: String) {
        var buf = [UInt8](repeating: 0, count: w*h)
        for y in 0..<h { for x in 0..<w { buf[y*w+x] = bytes[y*srcRow + x] } }
        let cs = CGColorSpaceCreateDeviceGray()
        buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue),
                  let cg = ctx.makeImage() else { return }
            if let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path)); print("wrote \(path) \(w)x\(h)")
            }
        }
    }
    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard let px = CMSampleBufferGetImageBuffer(sb) else { return }
        n += 1; guard n == 8 else { return }
        CVPixelBufferLockBaseAddress(px, .readOnly)
        let h = CVPixelBufferGetHeight(px), bpr = CVPixelBufferGetBytesPerRow(px)
        if let base = CVPixelBufferGetBaseAddress(px) {
            let b = base.assumingMemoryBound(to: UInt8.self)
            print("h=\(h) bytesPerRow=\(bpr)  -> treating as \(bpr) gray px per row")
            writeGray(b, bpr, h, bpr, "/tmp/xreal_gray_full.png")
            var lb = [UInt8](repeating:0, count: 640*h), rb = [UInt8](repeating:0, count: 640*h)
            for y in 0..<h { for x in 0..<640 { lb[y*640+x] = b[y*bpr + x]; rb[y*640+x] = b[y*bpr + 640 + x] } }
            lb.withUnsafeMutableBytes { r in
                if let ctx = CGContext(data: r.baseAddress, width: 640, height: h, bitsPerComponent: 8, bytesPerRow: 640,
                                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
                   let cg = ctx.makeImage(), let p = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                    try? p.write(to: URL(fileURLWithPath: "/tmp/xreal_left.png")); print("wrote left 640x\(h)") } }
            rb.withUnsafeMutableBytes { r in
                if let ctx = CGContext(data: r.baseAddress, width: 640, height: h, bitsPerComponent: 8, bytesPerRow: 640,
                                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
                   let cg = ctx.makeImage(), let p = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                    try? p.write(to: URL(fileURLWithPath: "/tmp/xreal_right.png")); print("wrote right 640x\(h)") } }
        }
        CVPixelBufferUnlockBaseAddress(px, .readOnly)
        sem.signal()
    }
}
let g = G(); g.run()
