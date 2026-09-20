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

## The cameras image the real scene

Verified by occlusion. Mean frame brightness across three 8-second phases, discarding the
first 3 seconds of each so auto-exposure settles:

| Phase | Mean brightness |
|---|---|
| Lenses uncovered, pointed at the room | 67.25 |
| Both lenses covered by a palm | 18.47 |
| Uncovered again | 53.70 |

A 48.78 drop under occlusion, recovering on uncover. The sensor responds to incident light,
so the frames are of the real scene and the horizontal strips are purely a byte-layout
problem.

This test is necessary rather than optional. The supporting spatial statistics below are
consistent with real imagery but do not prove it on their own: if the stream were a packed
raw format such as 10-bit MIPI, adjacent bytes would share bits from the same pixel and
produce high horizontal smoothness with no scene imaged at all. Occlusion is what separates
the two cases.

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

Occlusion has ruled out the sensor-initialisation branch, so all remaining work is decoding.

1. Take a Linux `v4l2-ctl --list-formats-ext` dump first — it reports raw UVC descriptors
   more completely than AVFoundation, and a packed raw format would show up directly,
   settling the layout without further search.
2. Sweep block sizes rather than row widths — test 8x8, 16x16, and 32x32 tile interleave.
3. Try 10-bit packed MIPI unpacking (4 pixels per 5 bytes).
4. Probe UVC extension units on interface 3 for a format or mode selector.

Validate any candidate layout against a controlled scene rather than by eye: capture with
the lenses covered and uncovered, and require that the decoded image go uniformly dark under
occlusion.

## Tools

- `capture-raw.swift` — writes one frame to `/tmp/xreal_raw.bin`
- `layout-search.swift` — scores candidate layouts by smoothness against a noise baseline
- `temporal-analysis.swift` — frame-to-frame and per-row brightness statistics
- `occlusion-test.swift` — prompts through a cover/uncover sequence and reports whether the
  sensor responds to light; the decisive test for real imaging
- `../../Scripts/probe-usb-descriptors.sh` — dumps USB interface and endpoint descriptors

Build any of them with `swiftc -o /tmp/<name> <file>.swift`. Camera permission is required;
the first run triggers the TCC prompt.
