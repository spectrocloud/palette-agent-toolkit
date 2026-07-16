#!/bin/sh
# install.sh — download, verify, and install the palette-mcp MCP binary.
#
# Usage:
#   sh install.sh [--version vX.Y.Z] [--bin-dir DIR]
#   curl -fsSL <url>/install.sh | sh
#
# Options / environment (flag overrides env):
#   --version <vX.Y.Z>   VERSION   install a specific release (default: latest)
#   --bin-dir <dir>      BIN_DIR   install location (default: /usr/local/bin)
#                        NO_COLOR  set to disable colored output
#
# Exit codes: 0 success · 1 runtime error · 2 usage error
set -eu

REPO="spectrocloud/palette-agent-toolkit"
BINARY="palette-mcp"
: "${VERSION:=}"
: "${BIN_DIR:=/usr/local/bin}"

# ---- output helpers (color only on a TTY, honoring NO_COLOR) ----
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_INFO=$(printf '\033[36m'); C_OK=$(printf '\033[32m')
  C_ERR=$(printf '\033[31m');  C_RST=$(printf '\033[0m')
else
  C_INFO=''; C_OK=''; C_ERR=''; C_RST=''
fi
info() { printf '%s==>%s %s\n' "$C_INFO" "$C_RST" "$*" >&2; }
ok()   { printf '%s[ok]%s %s\n' "$C_OK" "$C_RST" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_ERR" "$C_RST" "$*" >&2; exit 1; }

usage() {
  cat >&2 <<EOF
Install the ${BINARY} MCP binary.

Usage: install.sh [options]

Options:
  --version <vX.Y.Z>   install a specific release (default: latest)
  --bin-dir <dir>      install location (default: ${BIN_DIR})
  -h, --help           show this help

Environment: VERSION, BIN_DIR, NO_COLOR
EOF
}

# ---- parse args ----
while [ $# -gt 0 ]; do
  case "$1" in
    --version) shift; [ $# -gt 0 ] || { usage; exit 2; }; VERSION="$1" ;;
    --version=*) VERSION="${1#*=}" ;;
    --bin-dir) shift; [ $# -gt 0 ] || { usage; exit 2; }; BIN_DIR="$1" ;;
    --bin-dir=*) BIN_DIR="${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown option: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
  shift
done

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
need curl; need tar; need uname; need awk; need mktemp

# ---- detect os / arch ----
os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$os" in
  darwin|linux) ;;
  *) die "unsupported OS: ${os} (supported: darwin, linux)" ;;
esac
arch=$(uname -m)
case "$arch" in
  x86_64|amd64)  arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) die "unsupported architecture: ${arch} (supported: amd64, arm64)" ;;
esac
platform="${os}_${arch}"
asset="${BINARY}_${platform}.tar.gz"
info "platform: ${platform}"

# ---- sha-256 tool (Linux ships sha256sum, macOS ships shasum) ----
if command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
elif command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | awk '{print $1}'; }
else
  die "need 'shasum' or 'sha256sum' to verify the download"
fi

# ---- resolve version (empty = latest, via the releases/latest redirect) ----
if [ -z "$VERSION" ]; then
  info "resolving latest release"
  url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    "https://github.com/${REPO}/releases/latest") \
    || die "could not reach GitHub to resolve the latest release"
  VERSION="${url##*/}"
  [ -n "$VERSION" ] && [ "$VERSION" != latest ] || die "could not resolve the latest version"
fi
case "$VERSION" in v*) ;; *) VERSION="v${VERSION}" ;; esac
info "version: ${VERSION}"

base="https://github.com/${REPO}/releases/download/${VERSION}"

# ---- workspace ----
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
cd "$tmp"

# ---- download binary ----
info "downloading ${asset}"
curl -fL --retry 3 -o "$asset" "${base}/${asset}" \
  || die "download failed: ${base}/${asset}"

# ---- download checksums (accept the stable or the versioned name) ----
sums=''
for name in "checksums.txt" "${BINARY}_${VERSION#v}_checksums.txt"; do
  if curl -fsL --retry 3 -o "$name" "${base}/${name}"; then sums="$name"; break; fi
done
[ -n "$sums" ] || die "no checksums file found at ${base}"
info "checksums: ${sums}"

# ---- verify ----
expected=$(awk -v a="$asset" '$2 == a {print $1}' "$sums")
[ -n "$expected" ] || die "no checksum entry for ${asset} in ${sums}"
actual=$(sha256 "$asset")
[ "$expected" = "$actual" ] || die "checksum mismatch for ${asset}
  expected: ${expected}
  actual:   ${actual}"
ok "checksum verified"

# ---- extract ----
tar xzf "$asset"
[ -f "$BINARY" ] || die "archive did not contain ${BINARY}"
chmod +x "$BINARY"

# ---- install ----
dest="${BIN_DIR%/}/${BINARY}"
mkdir -p "$BIN_DIR" 2>/dev/null || true
if [ -w "$BIN_DIR" ]; then
  mv "$BINARY" "$dest"
elif command -v sudo >/dev/null 2>&1; then
  info "writing ${BIN_DIR} via sudo"
  sudo mkdir -p "$BIN_DIR"
  sudo mv "$BINARY" "$dest"
else
  die "cannot write ${BIN_DIR}; re-run with --bin-dir=\"\$HOME/.local/bin\""
fi
ok "installed ${BINARY} ${VERSION} -> ${dest}"

# ---- PATH hint ----
case ":${PATH}:" in
  *":${BIN_DIR%/}:"*) ;;
  *) info "note: ${BIN_DIR%/} is not on your PATH — add it, or move the binary" ;;
esac

# ---- confirm it runs ----
if v=$("$dest" -version 2>&1 | head -n1); then
  ok "$v"
fi
