#!/bin/sh
# palette-mcp launcher: fetch + verify + cache the release binary, then exec it
# as the MCP server. Self-contained — no manual binary install.
# Integrity = SHA-256 of the TLS-fetched tarball vs the published checksums
# (corruption/tamper detection, not signed provenance; signed releases TODO).
# stdout is the MCP JSON-RPC channel: diagnostics go to stderr, never stdout.
set -eu

VERSION="v0.4.2"
REPO="spectrocloud/palette-agent-toolkit"
DATA_DIR="${CLAUDE_PLUGIN_DATA:-${HOME:-/tmp}/.cache/palette-mcp}"

tmp=""
log()     { printf '[palette-mcp-launch] %s\n' "$*" >&2; }
die()     { log "ERROR: $*"; exit 1; }
cleanup() { if [ -n "${tmp}" ]; then rm -rf "${tmp}"; fi; }
trap 'cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# credential pre-flight: when the plugin isn't configured yet, userConfig
# substitutes empty strings — fail fast with an actionable message instead of a
# cryptic downstream connection failure. (stderr only; stdout is the RPC channel.)
if [ -z "${PALETTE_HOST:-}" ] || { [ -z "${PALETTE_API_KEY:-}" ] && [ -z "${PALETTE_AUTH_TOKEN:-}" ]; }; then
  die "Palette credentials not configured. In Claude Code run: /plugin -> palette -> Configure options (set host + API key). Other MCP clients: set PALETTE_HOST and PALETTE_API_KEY (or PALETTE_AUTH_TOKEN)."
fi
if [ -n "${PALETTE_API_KEY:-}" ] && [ -n "${PALETTE_AUTH_TOKEN:-}" ]; then
  log "warning: both PALETTE_API_KEY and PALETTE_AUTH_TOKEN are set; configure only one."
fi

# tools needed on every path (incl. offline cache hit)
for t in uname tr awk cat; do
  command -v "${t}" >/dev/null 2>&1 || die "required tool not found on PATH: ${t}"
done
if command -v sha256sum >/dev/null 2>&1; then _sha=sha256sum
elif command -v shasum >/dev/null 2>&1; then _sha=shasum
else die "no SHA-256 tool found (need sha256sum or shasum)"; fi
sha256() {
  if [ "${_sha}" = sha256sum ]; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# OS/arch are part of the cache key so a shared home never execs a wrong-arch binary.
os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
case "${arch}" in
  x86_64|amd64) arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) die "unsupported architecture: ${arch}" ;;
esac
case "${os}" in
  darwin|linux) ;;
  *) die "unsupported OS: ${os}" ;;
esac
bin="${DATA_DIR}/palette-mcp-${VERSION}-${os}-${arch}"
sha_file="${bin}.sha256"

# fast path: trust the cache only if it is a regular file matching its recorded
# digest; anything else falls through to a clean reinstall (self-healing).
if [ -f "${bin}" ] && [ ! -L "${bin}" ] && [ -r "${sha_file}" ]; then
  want=$(cat "${sha_file}" 2>/dev/null || true)
  have=$(sha256 "${bin}")
  if [ -n "${want}" ] && [ "${want}" = "${have}" ]; then
    exec "${bin}" "$@"
  fi
fi

# (re)install
for t in curl tar mktemp mkdir mv chmod; do
  command -v "${t}" >/dev/null 2>&1 || die "required tool not found on PATH: ${t}"
done
mkdir -p "${DATA_DIR}" || die "cannot create data dir: ${DATA_DIR}"
[ -w "${DATA_DIR}" ] || die "data dir not writable: ${DATA_DIR}"

asset="palette-mcp_${os}_${arch}.tar.gz"
base="https://github.com/${REPO}/releases/download/${VERSION}"
# stage inside DATA_DIR so the final install is a same-fs atomic rename
tmp=$(mktemp -d "${DATA_DIR}/.dl.XXXXXX") || die "cannot create temp dir under ${DATA_DIR}"

# bounded: --connect-timeout caps a dropped SYN; --max-time (per attempt) and
# --retry-max-time (cumulative) cap a stalled transfer and the retry loop.
log "fetching ${asset} (${VERSION})"
curl -fsSL --connect-timeout 10 --max-time 120 --retry 3 --retry-connrefused --retry-max-time 120 \
  -o "${tmp}/${asset}" "${base}/${asset}" \
  || die "download failed: ${base}/${asset} (check network/proxy or asset availability)"
curl -fsSL --connect-timeout 10 --max-time 120 --retry 3 --retry-connrefused --retry-max-time 120 \
  -o "${tmp}/sums" "${base}/palette-mcp_${VERSION#v}_checksums.txt" \
  || die "checksums download failed: ${base}"

# verify tarball; tolerate a binary-mode '*' filename prefix
expected=$(awk -v a="${asset}" '{ n=$2; sub(/^\*/, "", n) } n == a { print $1 }' "${tmp}/sums")
[ -n "${expected}" ] || die "no checksum entry for ${asset}"
have=$(sha256 "${tmp}/${asset}")
[ "${expected}" = "${have}" ] || die "checksum mismatch for ${asset}"

# extract only the expected member; reject a symlink/dir member
tar xzf "${tmp}/${asset}" -C "${tmp}" palette-mcp \
  || die "extract failed (archive did not contain palette-mcp?)"
{ [ -f "${tmp}/palette-mcp" ] && [ ! -L "${tmp}/palette-mcp" ]; } \
  || die "extracted palette-mcp is a symlink/dir/missing — refusing"

chmod +x "${tmp}/palette-mcp" || die "chmod failed"
digest=$(sha256 "${tmp}/palette-mcp")
# clear a non-regular file (e.g. a pre-existing dir) at the cache path, else
# `mv` would move INTO it and exec would fail permanently.
if [ -e "${bin}" ] && [ ! -f "${bin}" ]; then
  rm -rf "${bin}" || die "cannot clear non-regular cache path: ${bin}"
fi
mv -f "${tmp}/palette-mcp" "${bin}" || die "install failed: ${bin}"
printf '%s\n' "${digest}" > "${tmp}/sha" || die "sidecar write failed"
mv -f "${tmp}/sha" "${sha_file}" || die "sidecar write failed: ${sha_file}"

cleanup; tmp=""
log "installed ${VERSION} -> ${bin}"
exec "${bin}" "$@"
