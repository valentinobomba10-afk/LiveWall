#!/bin/bash
# Builds LiveWall.saver — the screen saver bundle that carries the live wallpaper
# onto the lock screen. Output: LockScreen/build/LiveWall.saver
#
# The main app ships this bundle in its Resources and copies it (plus the selected
# media) into ~/Library/Screen Savers on demand — see LockScreenService.swift.
set -euo pipefail

cd "$(dirname "$0")"
OUT="build/LiveWall.saver"
MACOS="$OUT/Contents/MacOS"
RES="$OUT/Contents/Resources"

rm -rf build
mkdir -p "$MACOS" "$RES"
cp Info.plist "$OUT/Contents/Info.plist"

FRAMEWORKS=(-framework ScreenSaver -framework AVFoundation -framework AppKit -framework CoreImage)
SLICES=()

for arch in arm64 x86_64; do
  # A .saver is a loadable bundle (MH_BUNDLE), not a dylib — hence -Xlinker -bundle.
  if swiftc -target "${arch}-apple-macos13.0" \
      -module-name LiveWallSaver \
      -emit-library -Xlinker -bundle \
      "${FRAMEWORKS[@]}" \
      -o "build/LiveWallSaver-${arch}" \
      LiveWallSaverView.swift 2>"build/${arch}.log"; then
    SLICES+=("build/LiveWallSaver-${arch}")
  else
    echo "warning: ${arch} slice failed to build (see build/${arch}.log)" >&2
  fi
done

if [ ${#SLICES[@]} -eq 0 ]; then
  echo "error: no architecture built" >&2
  exit 1
fi

lipo -create "${SLICES[@]}" -output "$MACOS/LiveWallSaver"
rm -f "${SLICES[@]}"

# Ad-hoc signature. The screen saver host refuses to load an unsigned bundle.
codesign --force --sign - --timestamp=none "$OUT"

echo "built $OUT"
lipo -info "$MACOS/LiveWallSaver"
