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

The streaming endpoint is **bulk, not isochronous**. Interface 4 carries a single endpoint,
`0x84`, with `bmAttributes` transfer type 2. A class-compliant webcam almost always streams
isochronous so the host reserves bandwidth and tolerates dropped packets. Bulk streaming
instead delivers each frame as an exact, retried byte sequence terminated by a short packet,
which means the 308480-byte payload is byte-exact rather than a best-effort reassembly. A
layout search can therefore trust the byte count and offsets completely; corruption is not a
candidate explanation for the strips.

The UVC descriptor declares the stream as YUY2, 640x241, `bBitsPerPixel` 16,
`dwMaxVideoFrameBufferSize` 308480. AVFoundation reports that verbatim, so `yuvs` is the
device's own claim rather than a macOS guess.

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
so the frames are of the real scene and the horizontal strips were purely a byte-layout
problem.

This test is necessary rather than optional. The supporting spatial statistics below are
consistent with real imagery but do not prove it on their own: if the stream were a packed
raw format such as 10-bit MIPI, adjacent bytes would share bits from the same pixel and
produce high horizontal smoothness with no scene imaged at all. Occlusion is what separated
the two cases, and it is what kept the search pointed at decoding rather than at sensor
initialisation.

Smoothness metric — fraction of adjacent byte pairs differing by <= 6:

| Source | horizontal | vertical |
|---|---|---|
| Camera frames | 0.69 | 0.53 |
| Random noise baseline | 0.05 | 0.05 |

Auto-exposure convergence is visible across the first ~25 frames: mean brightness climbs
0 -> 27 -> 40 -> 54 and settles near 51. The first 3–4 frames after stream start are all
zero (sensor warmup) and must be discarded.

## Solved: the payload is a block-permuted 480x640 greyscale frame

The image is not scrambled at the pixel level. The 307200 image bytes are **128 blocks of
2400 bytes**, permuted by a fixed table. Inside a block the bytes are already in order, which
is why the frame looked like correctly-sized horizontal strips in the wrong places and why
row means were near-identical — each strip samples a different part of the scene.

The permutation is constant, but its phase rotates every frame. Logical block `t` lives in
raw block `REORDER[(align + t) % 128]`.

Phase recovery needs no state. Score each raw block by the sum of its first 128 bytes and
take the minimum: the sensor's first readout line sits in the fisheye lens's black vignette,
so that block is always logical block 0. Invert through the table to get `align`.

After un-permuting, the 640-byte lines are **columns** of the upright image. The sensors are
mounted rotated 90 degrees, so `upright[r][c] = scan[c*640 + r]` yields **480x640 portrait,
8-bit greyscale, one byte per pixel**. The `yuvs` / 640x241 / bpp=16 descriptor is packaging
only: 241 rows x 2 bytes per pixel = 482 byte rows.

The two sensors are mounted 180 degrees apart, so camera `0x20` needs the transpose rotated
as well: `upright[639-r][479-c] = scan[c*640 + r]`. Applying the same transpose to both eyes
leaves one image upside down. Confirmed visually — both eyes now show the same room right
way up, offset by the stereo baseline.

Verified on this hardware, live and offline. A stored frame decodes to a recognisable fisheye
view of the room, and the live path produces upright stereo pairs. V/H gradient ratio goes
from 2.13 undecoded to 1.24 decoded, inside the 0.93–1.16 band natural photographs occupy.

    bytes      0 .. 307199   image, 128 x 2400 permuted blocks
    byte row   480           per-frame metadata  (307200 .. 307839)
    byte row   481           constant 0x5C padding

Frame arithmetic: 308480 bytes = 640 x 482 = 640 x 480 + 1280 = 640 x 241 x 2. All three
decompositions hold, and the first one is the real structure.

## Stereo is frame-alternating, keyed by metadata

One UVC frame carries one complete camera, so 60 fps yields ~30 stereo pairs per second.
Arrival order does not identify the eye. The metadata row does:

| Metadata offset | Meaning |
|---|---|
| `+0x00` .. `+0x07` | uint64 LE nanosecond timestamp, differs per camera |
| `+0x12` .. `+0x13` | int16 LE sequence number, **shared by both frames of a pair** |
| `+0x3A` | camera ID — `0x20` / `0x21` |
| `+0x3E` .. `+0x45` | uint64 LE microsecond timestamp, same for both cameras |

Pair frames by matching sequence number, then assign eyes by camera ID.

Upstream implementations read the camera ID at `+0x3B`. On this unit the ID is at `+0x3A`
and `+0x3B` reads `0x00`. Checked across nine live frames as well as the stored capture, so
the disagreement is real on this hardware rather than an artefact of one frame.

Two further observations from the live run that upstream does not describe:

- The sequence number steps by 256 per stereo pair, not by 1. Pairing by equality still
  works; treating the field as a frame counter does not.
- The nanosecond timestamp at `+0x00` is not monotonic across frames. It may not be a plain
  uint64 nanosecond value. Pairing does not depend on it, so this is unresolved rather than
  blocking.

## Ruled out along the way

Recorded so the search is not repeated: plain 640x480 with a 1280-byte header; two 640x240
frames stacked; row deinterleave and field split; serpentine scan; YUY2 even/odd byte-plane
separation at every width 64–900; exhaustive width sweep 64–1300 at offsets 0 and 1280;
column-major transpose of the raw stream; RAW10 unpacking; per-row DC and gain normalisation;
inter-row shear. None of these help, because the corruption is block order, not pixel order.

## Provenance

The reorder table originates in `mazeasdamien/myXreal` (Windows / DirectShow,
`src/driver/stereo_camera.cpp`) and appears byte-identical in three independent
reimplementations: `DeskUnreal/xreal-vio-vr` (GStreamer element `xrealultra2dec`),
`vladoshub/xr-gate` (V4L2, feeds Basalt VIO), and `sean9061/xreal-air2ultra-camera`
(macOS / AVFoundation, and the best written up). Public disclosure point is
`badicsalex/ar-drivers-rs` issue #16, comment by Benjamin Berg, 2025-05-09.

Monado, XRLinuxDriver, OpenHMD, and ar-drivers-rs all remain IMU-only for this device.

## Open

- UVC extension unit on interface 3, unit 4, GUID `41769ea2-04de-e347-8b2b-f4341aff003b`.
  Every selector probed upstream returned a PIPE error, so its function is unknown.
- Why the blocks are permuted at all. DMA artefact and deliberate obfuscation are both
  consistent with the evidence.
- The `+0x3A` versus `+0x3B` camera ID discrepancy above.

## Tools

- `capture-raw.swift` — writes one frame to `/tmp/xreal_raw.bin`
- `descramble.swift` — the decoder. With no argument it opens the live camera, pairs frames
  by sequence number and writes four upright stereo pairs to
  `/tmp/xreal_{left,right}_N.png`. Given a path it decodes one 308480-byte raw frame to a
  single PNG.
- `layout-search.swift` — scores candidate layouts by smoothness against a noise baseline
- `temporal-analysis.swift` — frame-to-frame and per-row brightness statistics
- `occlusion-test.swift` — prompts through a cover/uncover sequence and reports whether the
  sensor responds to light; the decisive test for real imaging
- `../../Scripts/probe-usb-descriptors.sh` — dumps USB interface and endpoint descriptors

Build any of them with `swiftc -o /tmp/<name> <file>.swift`. Camera permission is required;
the first run triggers the TCC prompt.
