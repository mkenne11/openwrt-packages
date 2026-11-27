#!/usr/bin/env bash
set -euo pipefail

FEED_DIR=""
UPSTREAM_URL=""
APK_BIN=""
KEEP_VERSIONS=5
SIGN_KEY=""
REQUIRE_SIGNING=0

usage() {
	cat <<'EOF'
Merge newly built OpenWrt APK v3 packages with previously published packages
from an upstream feed URL, prune old versions per package, and regenerate
signed packages.adb and SHA256SUMS.

Usage:
  scripts/merge-feed.sh --feed-dir <dir> --apk-bin <path> [options]

Options:
      --feed-dir <dir>        Directory containing newly built *.apk files (required)
      --upstream-url <url>    Existing live feed arch URL (e.g. https://.../25.12/aarch64_cortex-a53)
      --apk-bin <path>        Path to OpenWrt 25.12+ host `apk` v3 binary (required)
      --keep-versions <N>     Max versions to retain per package (default: 5; 0 = keep all)
      --sign-key <path>       ECDSA P-256 private key (.pem) for signing packages.adb
                              (defaults to APK_SIGNING_PRIVATE_KEY env var when set)
      --require-signing       Fail if no signing key is configured
  -h, --help                  Show this help message
EOF
}

log() {
	printf '[merge-feed] %s\n' "$*"
}

die() {
	printf '[merge-feed] ERROR: %s\n' "$*" >&2
	exit 1
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

while [ $# -gt 0 ]; do
	case "$1" in
		--feed-dir)
			FEED_DIR="${2:?missing value for $1}"
			shift 2
			;;
		--upstream-url)
			UPSTREAM_URL="${2:?missing value for $1}"
			shift 2
			;;
		--apk-bin)
			APK_BIN="${2:?missing value for $1}"
			shift 2
			;;
		--keep-versions)
			KEEP_VERSIONS="${2:?missing value for $1}"
			shift 2
			;;
		--sign-key)
			SIGN_KEY="${2:?missing value for $1}"
			shift 2
			;;
		--require-signing)
			REQUIRE_SIGNING=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "Unknown option: $1 (use --help for usage)"
			;;
	esac
done

[ -n "$FEED_DIR" ] || die "Missing required --feed-dir"
[ -d "$FEED_DIR" ] || die "Feed directory not found: $FEED_DIR"
[ -n "$APK_BIN" ] || die "Missing required --apk-bin"
[ -x "$APK_BIN" ] || die "apk binary not executable: $APK_BIN"
APK_BIN="$(cd -- "$(dirname -- "$APK_BIN")" && pwd)/$(basename -- "$APK_BIN")"

case "$KEEP_VERSIONS" in
	''|*[!0-9]*)
		die "--keep-versions must be a non-negative integer (got: $KEEP_VERSIONS)"
		;;
esac

require_cmd curl
require_cmd sha256sum
require_cmd sort

TMP_DIR="$(mktemp -d)"
cleanup() {
	if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
		rm -rf "$TMP_DIR"
	fi
}
trap cleanup EXIT

if [ -n "$SIGN_KEY" ]; then
	[ -f "$SIGN_KEY" ] || die "Signing key not found: $SIGN_KEY"
	SIGN_KEY="$(cd -- "$(dirname -- "$SIGN_KEY")" && pwd)/$(basename -- "$SIGN_KEY")"
elif [ -n "${APK_SIGNING_PRIVATE_KEY:-}" ]; then
	SIGN_KEY="${TMP_DIR}/env-private-key.pem"
	(
		umask 077
		printf '%s\n' "$APK_SIGNING_PRIVATE_KEY" | tr -d '\r' > "$SIGN_KEY"
	)
	log "Loaded APK signing private key from APK_SIGNING_PRIVATE_KEY environment variable"
fi

if [ "$REQUIRE_SIGNING" -eq 1 ] && [ -z "$SIGN_KEY" ]; then
	die "Signing is required (--require-signing), but no key was provided via --sign-key or APK_SIGNING_PRIVATE_KEY"
fi

if [ -n "$SIGN_KEY" ] && command -v openssl >/dev/null 2>&1; then
	openssl pkey -in "$SIGN_KEY" -pubout >/dev/null 2>&1 \
		|| die "Invalid private signing key (failed openssl pkey validation)"
fi

# 1. Fetch previously published APKs from the live feed URL (if available)
UPSTREAM_URL="${UPSTREAM_URL%/}"
if [ -n "$UPSTREAM_URL" ]; then
	UPSTREAM_SUMS="${TMP_DIR}/upstream.SHA256SUMS"
	HTTP_CODE="$(curl -sSL -w '%{http_code}' -o "$UPSTREAM_SUMS" "${UPSTREAM_URL}/SHA256SUMS" || printf '000')"
	if [ "$HTTP_CODE" = "200" ] && [ -s "$UPSTREAM_SUMS" ]; then
		log "Fetched upstream SHA256SUMS from ${UPSTREAM_URL}/SHA256SUMS"
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			expected_sha="${line%%[[:space:]]*}"
			fname="${line#*[[:space:]]}"
			fname="${fname#"${fname%%[![:space:]]*}"}"
			fname="${fname#\*}"
			fname="$(basename -- "$fname")"

			case "$fname" in
				*.apk) ;;
				*) continue ;;
			esac

			if [ -f "${FEED_DIR}/${fname}" ]; then
				log "Keeping newly built ${fname} (supersedes upstream copy)"
				continue
			fi

			dl_tmp="${TMP_DIR}/${fname}"
			log "Fetching previous package ${fname}..."
			if curl -fsSL "${UPSTREAM_URL}/${fname}" -o "$dl_tmp"; then
				actual_sha="$(sha256sum "$dl_tmp" | awk '{print $1}')"
				if [ "$actual_sha" = "$expected_sha" ]; then
					mv "$dl_tmp" "${FEED_DIR}/${fname}"
					log "Retained previous package ${fname} (SHA-256 verified)"
				else
					log "WARNING: SHA-256 mismatch for upstream ${fname} (expected=${expected_sha}, got=${actual_sha}); skipping"
					rm -f "$dl_tmp"
				fi
			else
				log "WARNING: Failed to download upstream ${fname}; skipping"
				rm -f "$dl_tmp"
			fi
		done < "$UPSTREAM_SUMS"
	else
		log "No existing upstream feed found at ${UPSTREAM_URL}/SHA256SUMS (HTTP ${HTTP_CODE}); indexing newly built packages only"
	fi
fi

# 2. Prune older versions beyond KEEP_VERSIONS per package name
shopt -s nullglob
ALL_APKS=("${FEED_DIR}"/*.apk)
[ "${#ALL_APKS[@]}" -gt 0 ] || die "No .apk files found in ${FEED_DIR}"

if [ "$KEEP_VERSIONS" -gt 0 ]; then
	declare -A PKG_GROUPS=()
	for apk_path in "${ALL_APKS[@]}"; do
		base="$(basename -- "$apk_path")"
		pkg_name="$(printf '%s\n' "$base" | sed -E 's/-[0-9][0-9A-Za-z._~+]*-r[0-9]+\.apk$//')"
		if [ -z "$pkg_name" ] || [ "$pkg_name" = "$base" ]; then
			pkg_name="${base%.apk}"
		fi
		if [ -n "${PKG_GROUPS[$pkg_name]:-}" ]; then
			PKG_GROUPS[$pkg_name]="${PKG_GROUPS[$pkg_name]}"$'\n'"${base}"
		else
			PKG_GROUPS[$pkg_name]="${base}"
		fi
	done

	for pkg_name in "${!PKG_GROUPS[@]}"; do
		mapfile -t sorted_apks < <(printf '%s\n' "${PKG_GROUPS[$pkg_name]}" | sort -V -r)
		total="${#sorted_apks[@]}"
		if [ "$total" -gt "$KEEP_VERSIONS" ]; then
			log "Pruning ${pkg_name}: keeping newest ${KEEP_VERSIONS} of ${total} versions"
			for ((i = KEEP_VERSIONS; i < total; i++)); do
				old_apk="${sorted_apks[$i]}"
				log "  - removing old package: ${old_apk}"
				rm -f "${FEED_DIR}/${old_apk}"
			done
		fi
	done
fi

# 3. Rebuild packages.adb and SHA256SUMS over all retained .apk files
RETAINED_APKS=("${FEED_DIR}"/*.apk)
[ "${#RETAINED_APKS[@]}" -gt 0 ] || die "No .apk files remaining in ${FEED_DIR} after pruning"

log "Indexing ${#RETAINED_APKS[@]} package(s) in ${FEED_DIR}..."
(
	cd "$FEED_DIR"
	rm -f packages.adb SHA256SUMS
	if [ -n "$SIGN_KEY" ]; then
		"$APK_BIN" mkndx --allow-untrusted --sign-key "$SIGN_KEY" \
			--output packages.adb ./*.apk
	else
		"$APK_BIN" mkndx --allow-untrusted \
			--output packages.adb ./*.apk
	fi
	sha256sum ./*.apk packages.adb > SHA256SUMS
)

log "Feed index updated successfully:"
ls -lh "$FEED_DIR"
