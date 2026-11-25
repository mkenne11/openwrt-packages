#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
PKG_MAKEFILE="${PKG_DIR}/Makefile"

usage() {
	cat <<'EOF'
Fetch the latest (or specified) Control-D-Inc/ctrld release tarball, compute
its SHA-256 checksum, and pin PKG_VERSION, PKG_RELEASE:=1, and PKG_HASH in
net/ctrld/Makefile.

Usage:
  net/ctrld/scripts/update-version.sh [version]

Examples:
  # Pin to the latest GitHub release tag automatically
  ./net/ctrld/scripts/update-version.sh

  # Pin to a specific release version
  ./net/ctrld/scripts/update-version.sh 1.5.11
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
	usage
	exit 0
fi

for cmd in curl sha256sum sed; do
	command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: required command not found: $cmd" >&2; exit 1; }
done

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
	echo "[update-version] Querying latest release tag from github.com/Control-D-Inc/ctrld..."
	TAG="$(curl -fsSL "https://api.github.com/repos/Control-D-Inc/ctrld/releases/latest" \
		| sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n 1)"
	[ -n "$TAG" ] || { echo "ERROR: Failed to determine latest tag from GitHub API" >&2; exit 1; }
	VERSION="${TAG#v}"
else
	VERSION="${VERSION#v}"
fi

TARBALL_URL="https://codeload.github.com/Control-D-Inc/ctrld/tar.gz/v${VERSION}?"
TMP_TAR="$(mktemp)"
trap 'rm -f "$TMP_TAR"' EXIT

echo "[update-version] Downloading ${TARBALL_URL}..."
curl -fL --progress-bar "$TARBALL_URL" -o "$TMP_TAR"

SHA256="$(sha256sum "$TMP_TAR" | awk '{print $1}')"
[ -n "$SHA256" ] || { echo "ERROR: Failed to compute SHA-256" >&2; exit 1; }

echo "[update-version] Updating ${PKG_MAKEFILE}:"
echo "  PKG_VERSION := ${VERSION}"
echo "  PKG_RELEASE := 1"
echo "  PKG_HASH    := ${SHA256}"

sed -i -E "s|^PKG_VERSION:=.*|PKG_VERSION:=${VERSION}|" "$PKG_MAKEFILE"
sed -i -E "s|^PKG_RELEASE:=.*|PKG_RELEASE:=1|" "$PKG_MAKEFILE"
sed -i -E "s|^PKG_HASH:=.*|PKG_HASH:=${SHA256}|" "$PKG_MAKEFILE"

echo "[update-version] Done."
