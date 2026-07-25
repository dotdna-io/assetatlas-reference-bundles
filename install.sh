#!/usr/bin/env bash
# deploy/bootstrap/install.sh — pipeable one-line bootstrap for AssetAtlas (online).
#   curl -fsSL https://get.assetatlas.com | sudo bash [-s -- <install.sh args>]
#
# Downloads + sha256-verifies the online installer bundle, then execs it with
# stdin bound to the terminal so the interactive prompts survive the pipe.
# ALL logic lives in main(), called on the LAST line — a truncated download
# cannot execute a partial script.
set -euo pipefail

BASE_URL="${ASSETATLAS_INSTALL_BASE_URL:-https://get.assetatlas.com}"
MANIFEST_URL="${ASSETATLAS_MANIFEST_URL:-${BASE_URL}/latest.json}"
BUNDLE_BASE="${ASSETATLAS_BUNDLE_BASE:-${BASE_URL}/dl}"

_err()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
_have() { command -v "$1" >/dev/null 2>&1; }
_sha256() { if _have sha256sum; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
_json_field() {
    printf '%s' "$1" | grep -Eo "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
        | head -1 | sed -E "s/.*:[[:space:]]*\"([^\"]*)\"/\1/" || true
}

main() {
    [ "$(id -u)" -eq 0 ] || _err "Run as root: curl -fsSL $BASE_URL | sudo bash"
    [ "$(uname -s)" = "Linux" ] || _err "The online installer supports Linux only."
    _have curl || _err "curl is required."
    _have tar  || _err "tar is required."
    { _have sha256sum || _have shasum; } || _err "sha256sum or shasum is required."

    local manifest version expected
    manifest=$(curl -fsSL --max-time 15 "$MANIFEST_URL") || _err "Could not fetch $MANIFEST_URL"
    version=$(_json_field "$manifest" version)
    [ -n "$version" ] || _err "Manifest has no version: $MANIFEST_URL"
    expected=$(_json_field "$manifest" online_sha256)

    local tmp name url out
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    name="assetatlas-online-${version}.sh"
    url="${BUNDLE_BASE}/${name}"
    out="${tmp}/${name}"
    printf 'Downloading AssetAtlas %s ...\n' "$version"
    curl -fsSL --max-time 300 -o "$out" "$url" || _err "Download failed: $url"

    if [ -z "$expected" ]; then
        expected=$(curl -fsSL --max-time 30 "${url}.sha256" 2>/dev/null | awk '{print $1}' | head -1) || true
    fi
    [ -n "$expected" ] || _err "No sha256 available to verify $name."
    local actual; actual=$(_sha256 "$out")
    [ "$actual" = "$expected" ] || _err "sha256 mismatch for $name (expected $expected, got $actual)."
    printf 'Verified %s.\n' "$name"

    # Hand off with stdin on the terminal so the installer's prompts work.
    # Run it as a CHILD rather than exec'ing: `exec` replaces this process, which
    # skips the EXIT trap above and strands the downloaded bundle in $tmp. The
    # `</dev/tty` redirect is what makes the prompts work — not the exec — and a
    # child inherits it identically, so cleanup (including on Ctrl-C, which hits
    # the whole process group) costs nothing.
    if [ -e /dev/tty ] && (exec </dev/tty) 2>/dev/null; then
        bash "$out" "$@" </dev/tty
        exit $?
    fi
    local a
    for a in "$@"; do
        if [ "$a" = "--unattended" ]; then
            bash "$out" "$@"
            exit $?
        fi
    done
    _err "No terminal for interactive prompts. Re-run attached to a terminal, or pass --unattended: curl -fsSL $BASE_URL | sudo bash -s -- --unattended"
}

main "$@"
