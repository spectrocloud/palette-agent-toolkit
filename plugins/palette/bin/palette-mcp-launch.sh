#!/bin/sh
# palette-mcp launcher: fetch + verify + cache the release binary, then exec it
# as the MCP server. Self-contained — no manual binary install.
# Integrity = SHA-256 of the TLS-fetched tarball vs the published checksums
# (corruption/tamper detection, not signed provenance; signed releases TODO).
# stdout is the MCP JSON-RPC channel: diagnostics go to stderr, never stdout.
set -eu

VERSION="v0.6.1"
REPO="spectrocloud/palette-agent-toolkit"

tmp=""
log()     { printf '[palette-mcp-launch] %s\n' "$*" >&2; }
die()     { log "ERROR: $*"; exit 1; }
cleanup() { if [ -n "${tmp}" ]; then rm -rf "${tmp}"; fi; }
trap 'cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The cache below is an *executable trust boundary*: the fast path execs whatever
# binary is there if it matches the digest sidecar sitting beside it. Both files
# are therefore only as trustworthy as the directory holding them — in a shared
# or predictable location (the old `/tmp` fallback) a local user could pre-seed a
# malicious binary *and* a matching digest, and we would exec it. So: no private
# directory, no launch. Resolved after die() exists so the failure is actionable.
if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then
  DATA_DIR="${CLAUDE_PLUGIN_DATA}"
elif [ -n "${HOME:-}" ]; then
  DATA_DIR="${HOME}/.cache/palette-mcp"
else
  die "neither CLAUDE_PLUGIN_DATA nor HOME is set — refusing to cache an executable in a world-writable location. Set CLAUDE_PLUGIN_DATA to a user-private directory."
fi

# credential pre-flight: when the plugin isn't configured yet, userConfig
# substitutes empty strings — fail fast with an actionable message instead of a
# cryptic downstream connection failure. (stderr only; stdout is the RPC channel.)
if [ -z "${PALETTE_HOST:-}" ] || { [ -z "${PALETTE_API_KEY:-}" ] && [ -z "${PALETTE_AUTH_TOKEN:-}" ]; }; then
  die "Palette credentials not configured. In Claude Code run: /plugin -> palette -> Configure options (set host + API key). Other MCP clients: set PALETTE_HOST and PALETTE_API_KEY (or PALETTE_AUTH_TOKEN)."
fi
if [ -n "${PALETTE_API_KEY:-}" ] && [ -n "${PALETTE_AUTH_TOKEN:-}" ]; then
  log "warning: both PALETTE_API_KEY and PALETTE_AUTH_TOKEN are set; configure only one."
fi

# Defensive: if Claude Code's userConfig substitution ever produces an empty
# value for an untouched boolean toggle, the arg arrives as e.g.
# `--allow-write=` with nothing after `=`. Confirmed directly: the binary's
# own flag parser then exits 2 ("invalid boolean value \"\" for -allow-write:
# parse error") instead of falling back to its documented default. Drop any
# such empty-valued flag here, before either exec path below forwards "$@",
# so it falls through to the binary's own default instead of crashing.
_argc=0
for _arg in "$@"; do
  case "${_arg}" in
    # any future toggle (e.g. --allow-tunnel-ssh) needs adding here too, or it reintroduces this crash
    --allow-write=|--allow-direct-ssh=)
      log "dropping empty-valued flag: ${_arg} (falls through to binary default)"
      continue ;;
  esac
  if [ "${_argc}" -eq 0 ]; then
    set -- "${_arg}"
  else
    set -- "$@" "${_arg}"
  fi
  _argc=$((_argc + 1))
done
if [ "${_argc}" -eq 0 ]; then
  set --
fi

# tools needed on every path (incl. offline cache hit)
for t in uname tr awk cat mkdir chmod rm; do
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

# Secure the cache directory BEFORE the fast path reads anything out of it —
# verifying after the exec would be pointless. `mkdir -m` only applies when mkdir
# actually creates the directory, so an already-existing one keeps whatever mode
# it has; chmod it explicitly. chmod also fails when we are not the owner, which
# is precisely the case to refuse: someone else's directory must never be the
# source of a binary we exec.
# umask first: `-m 700` applies only to the DEEPEST component, so with
# DATA_DIR=$HOME/.cache/palette-mcp and no existing ~/.cache, that parent is
# created with the ambient umask. A parent another local user can write lets
# them replace the whole palette-mcp directory entry — supplying a binary and
# a matching digest sidecar together — which the fast path below would exec.
# The sibling generate_ro_kubeconfig.sh sets this for the same reason.
umask 077
mkdir -p -m 700 "${DATA_DIR}" || die "cannot create data dir: ${DATA_DIR}"
chmod 700 "${DATA_DIR}" || die "cannot secure data dir (not owned by this user?): ${DATA_DIR}"

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
# DATA_DIR was already created and mode-verified above, before the fast path.
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
