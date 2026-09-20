#!/bin/sh
set -u

VENDOR_ID=0x3318

echo "=== ioreg: XREAL USB tree ==="
ioreg -p IOUSB -l -w 0 | awk '/XREAL|NREAL|0x3318|12568/,/^$/'

echo
echo "=== ioreg: interfaces and endpoints under vendor 3318 ==="
ioreg -r -c IOUSBHostInterface -l -w 0 \
  | grep -E "idVendor|idProduct|bInterfaceNumber|bInterfaceClass|bInterfaceSubClass|bNumEndpoints|bAlternateSetting|IOClass|USB Interface Name"

echo
echo "=== system_profiler ==="
system_profiler SPUSBDataType 2>/dev/null \
  | awk '/XREAL|NREAL/,/^$/'

echo
echo "=== UVC video devices visible to macOS ==="
system_profiler SPCameraDataType 2>/dev/null

echo
echo "Interface class 0x0e = video (UVC). Class 0x03 = HID."
echo "Known Air 2 Ultra (0x0426): interface 0 = MCU, interface 2 = IMU."
echo "Any other interface is the thing worth chasing."
