# XREAL Air 2 Ultra camera access — findings

Measured on Apple Silicon macOS 26.0, Swift 6.3.3, glasses `0x3318:0x0426`, 2026-09-20.

## The cameras are host-accessible without a custom driver

The Air 2 Ultra exposes its environment cameras as a **standard USB Video Class device**.
macOS binds them with no third-party driver, and `AVCaptureDevice` enumerates them as an
external camera.

Full interface map:

| Interface | bInterfaceClass | Purpose |
|---|---|---|
| 0 | 3 (HID) | MCU |
| 1 | 3 (HID) | unidentified |
| 2 | 3 (HID) | IMU |
| 3 | 14 (UVC) | `UVC Camera 0` — video control |
| 4 | 14 (UVC) | `Video Streaming 0` — video streaming |
| 5–7 | 1 (Audio) | speakers / mic |
| 8 | 3 (HID) | consumer controls |

`AVCaptureDevice` reports `id=0x110000033180426`,
`model=UVC Camera VendorID_13080 ProductID_1062`, and exactly one capture format:

    640x241 'yuvs' @ 59.99988 fps

This contradicts the widely repeated claim that Air 2 Ultra camera access requires NRSDK,
Nebula, or a Snapdragon host. XREAL's documented Snapdragon requirement concerns their IMU
sensor-fusion pipeline, not the cameras, which are class-compliant.

## Frames carry real image content

Smoothness metric — fraction of adjacent byte pairs differing by <= 6:

| Source | horizontal | vertical |
|---|---|---|
| Camera frames | 0.69 | 0.53 |
| Random noise baseline | 0.05 | 0.05 |

Auto-exposure convergence is visible across the first ~25 frames: mean brightness climbs
0 -> 27 -> 40 -> 54 and settles near 51. The first 3–4 frames after stream start are all
zero (sensor warmup) and must be discarded.

## Unsolved: the byte layout is not raster

Every raster interpretation renders as horizontal strips. Confirmed ruled out:

- plain 640x480 (307200 bytes) with a 1280-byte header
- two 640x240 frames stacked
- row deinterleave, and field split (top/bottom halves interleaved)
- serpentine scan — vertical smoothness collapses to 0.15
- YUY2 even/odd byte-plane separation at every width 64–900
- exhaustive width sweep 64–1300 at offsets 0 and 1280

Natural photographs score V/H gradient ratio 0.93–1.16. Every candidate layout scores
2.1–2.6, so rows hold image data but are not arranged as a raster.

The decisive measurement: **across-row brightness spread is 0.86 while the same row varies
13.22 over time.** In a raster image of a natural scene, rows differ substantially from each
other. Near-identical row means indicate each 640-byte chunk samples the entire scene rather
than one scanline — consistent with block interleaving or a packed raw sensor format
(e.g. 10-bit MIPI) being mislabelled as `yuvs` in the UVC descriptor. SLAM sensors commonly
emit formats never intended for a generic video pipeline.

Frame arithmetic worth noting: 308480 bytes = 640 x 482 = 640 x 480 + 1280 = 640 x 241 x 2.
All three decompositions are numerically consistent, so byte count alone does not settle the
layout.

## Next steps

1. Sweep block sizes rather than row widths — test 8x8, 16x16, and 32x32 tile interleave.
2. Try 10-bit packed MIPI unpacking (4 pixels per 5 bytes).
3. Probe UVC extension units on interface 3 for a format or mode selector.
4. Compare against a Linux `v4l2-ctl --list-formats-ext` dump, which reports raw UVC
   descriptors more completely than AVFoundation does.

## Tools

- `capture-raw.swift` — writes one frame to `/tmp/xreal_raw.bin`
- `layout-search.swift` — scores candidate layouts by smoothness against a noise baseline
- `temporal-analysis.swift` — distinguishes live imaging from fixed pattern output
- `../../Scripts/probe-usb-descriptors.sh` — dumps USB interface and endpoint descriptors

Build any of them with `swiftc -o /tmp/<name> <file>.swift`. Camera permission is required;
the first run triggers the TCC prompt.
