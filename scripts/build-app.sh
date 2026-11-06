#!/bin/sh
# Builds dist/Orbit.app (menu bar app + bundled mihomo core + seed rule-sets) and dist/orbitctl.
set -eu
cd "$(dirname "$0")/.."
# Rebuild the core when it's missing or a patch / the core build script changed since.
needs_core() {
  [ -x .toolchain/mihomo ] || return 0
  for f in patches/*.patch scripts/build-core.sh; do [ "$f" -nt .toolchain/mihomo ] && return 0; done
  return 1
}
if needs_core; then ./scripts/build-core.sh; fi
if [ ! -f .toolchain/core-licenses.txt ] || [ .toolchain/mihomo -nt .toolchain/core-licenses.txt ]; then
  T="$PWD/.toolchain"
  python3 -I scripts/gen-core-licenses.py "$T/go/bin/go" "$T/mihomo" "$T/gopath/pkg/mod" "$T/mihomo-src" "$T/core-licenses.txt"
fi

swift build -c release --product Orbit
swift build -c release --product orbitctl
BIN="$(swift build -c release --show-bin-path)"

APP=dist/Orbit.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Orbit" "$APP/Contents/MacOS/Orbit"
cp .toolchain/mihomo "$APP/Contents/Resources/mihomo"
cp -R Resources/ruleset "$APP/Contents/Resources/ruleset"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/Licenses"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/Licenses/"
cp .toolchain/core-licenses.txt "$APP/Contents/Resources/Licenses/mihomo-core-licenses.txt"
cp Vendor/Yams/LICENSE "$APP/Contents/Resources/Licenses/Yams-LICENSE.txt"
cp Vendor/Yams/LICENSE-libyaml "$APP/Contents/Resources/Licenses/libyaml-LICENSE.txt"
cp "$BIN/orbitctl" dist/orbitctl

codesign --force --sign - "$APP/Contents/Resources/mihomo"
# The TUN launcher runs the core as root only if it matches this hash (taken after signing).
CORE_SHA=$(shasum -a 256 "$APP/Contents/Resources/mihomo" | cut -d ' ' -f 1)
/usr/libexec/PlistBuddy -c "Add :OrbitCoreSHA256 string $CORE_SHA" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "built $APP"

# Install into /Applications (skip with ORBIT_NO_INSTALL=1). Never replaces a running Orbit
# while it's connected: quitting would drop the connection, and overwriting a running binary
# can crash it with the system proxy still pointing at it.
[ "${ORBIT_NO_INSTALL:-}" = 1 ] && exit 0
DEST=/Applications/Orbit.app
running() { pgrep -f "Orbit.app/Contents/MacOS/Orbit" >/dev/null; }
connected() { ps -axo command | grep "Orbit.app/Contents/Resources/mihomo" | grep -v -e grep -e probe >/dev/null; }
if connected; then
  echo "Orbit is connected; not installing. Disconnect, then run: ditto $APP $DEST"
  exit 0
fi
WAS_RUNNING=0
if running; then
  WAS_RUNNING=1
  for _ in 1 2 3; do  # a dist/ copy and an /Applications copy may both be running
    running || break
    # local.orbit.proxy: the bundle id before 1.0, still on Macs that installed an early build.
    for id in io.github.zhaogezhenshuai.orbit local.orbit.proxy; do
      osascript -e "quit app id \"$id\"" >/dev/null 2>&1 || true
    done
    for _ in $(seq 20); do running || break; sleep 0.5; done
  done
  if running; then echo "Orbit didn't quit; not installing."; exit 1; fi
fi
rm -rf "$DEST"
ditto "$APP" "$DEST"
echo "installed $DEST"
[ "$WAS_RUNNING" = 1 ] && open "$DEST"
exit 0
