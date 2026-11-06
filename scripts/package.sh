#!/bin/sh
# Packs dist/Orbit.app for a release: a zip made with ditto (Finder or plain zip can break the
# signature), the patched core source that GPL-3.0 asks binaries to come with, and SHA256SUMS.
set -eu
cd "$(dirname "$0")/.."
ORBIT_NO_INSTALL=1 ./scripts/build-app.sh
V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" dist/Orbit.app/Contents/Info.plist)
ZIP="Orbit-$V-$(uname -m).zip"
rm -f dist/*.zip dist/*-orbit-src.tar.gz dist/SHA256SUMS
ditto -c -k --keepParent dist/Orbit.app "dist/$ZIP"
cp .toolchain/mihomo-*-orbit-src.tar.gz dist/
(cd dist && shasum -a 256 "$ZIP" mihomo-*-orbit-src.tar.gz > SHA256SUMS)
ls -l dist
