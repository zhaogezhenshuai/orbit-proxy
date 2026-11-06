#!/bin/sh
# Builds the mihomo core from source with a project-local Go toolchain, for this Mac's architecture.
# Defaults to golang.google.cn for Go and goproxy.cn for modules, which are reachable from most
# networks; GO_DL_BASE, GOPROXY and GOSUMDB override them (e.g. GO_DL_BASE=https://go.dev/dl).
set -eu
cd "$(dirname "$0")/.."
ROOT="$PWD/.toolchain"
GO_VERSION="${GO_VERSION:-go1.27.3}"
case "$(uname -m)" in
  arm64) GO_ARCH=arm64; GO_SHA_DEFAULT=dd3908cf20959d798c1e06ebe5b72213f0505ce01373b40ce3110975a6cd99c2 ;;
  x86_64) GO_ARCH=amd64; GO_SHA_DEFAULT=b6f8e931e4ab497fcde6da8ae4499a58f9d258e55c8a80824a516eae5950a750 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac
GO_SHA256="${GO_SHA256:-$GO_SHA_DEFAULT}"
GO_DL_BASE="${GO_DL_BASE:-https://golang.google.cn/dl}"
MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.33}"
mkdir -p "$ROOT"

if [ ! -x "$ROOT/go/bin/go" ]; then
  echo ">> downloading $GO_VERSION ($GO_ARCH)"
  curl -fL -o "$ROOT/go.tgz" "$GO_DL_BASE/$GO_VERSION.darwin-$GO_ARCH.tar.gz"
  echo "$GO_SHA256  $ROOT/go.tgz" | shasum -a 256 -c
  tar xzf "$ROOT/go.tgz" -C "$ROOT" && rm "$ROOT/go.tgz"
fi

export PATH="$ROOT/go/bin:$PATH" GOPATH="$ROOT/gopath" GOMODCACHE="$ROOT/gopath/pkg/mod" GOCACHE="$ROOT/gocache"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}" GOSUMDB="${GOSUMDB:-sum.golang.google.cn}" GOTOOLCHAIN=local

echo ">> fetching mihomo $MIHOMO_VERSION (checksum-verified by GOSUMDB)"
SRC=$(go mod download -json "github.com/metacubex/mihomo@$MIHOMO_VERSION" | python3 -I -c "import json,sys;print(json.load(sys.stdin)['Dir'])")
rm -rf "$ROOT/mihomo-src" && cp -R "$SRC" "$ROOT/mihomo-src" && chmod -R u+w "$ROOT/mihomo-src"
cd "$ROOT/mihomo-src"
for p in "$ROOT"/../patches/mihomo-*.patch; do
  [ -e "$p" ] || continue
  echo ">> applying $(basename "$p")"
  patch -p1 --forward < "$p"
done
# The exact source the core is built from; release binaries ship with it (GPL-3.0).
rm -f "$ROOT"/mihomo-*-orbit-src.tar.gz
tar -czf "$ROOT/mihomo-$MIHOMO_VERSION-orbit-src.tar.gz" -C "$ROOT" mihomo-src
echo ">> building"
go build -tags with_gvisor -trimpath \
  -ldflags "-s -w -X github.com/metacubex/mihomo/constant.Version=$MIHOMO_VERSION" \
  -o "$ROOT/mihomo" .
"$ROOT/mihomo" -v
# Licenses of every module compiled into the core; Orbit.app ships them (scripts/build-app.sh).
python3 -I "$ROOT/../scripts/gen-core-licenses.py" "$ROOT/go/bin/go" "$ROOT/mihomo" "$GOMODCACHE" "$ROOT/mihomo-src" "$ROOT/core-licenses.txt"
