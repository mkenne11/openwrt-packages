#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# Defaults
TARGET_SPEC="mediatek/filogic"
BUILD_MODE="docker"
OPENWRT_VERSION="25.12.6"
OPENWRT_SERIES=""
FEED_NAME="custom"
PACKAGES_SPEC="all"
DOCKER_REGISTRY="ghcr.io"
DOCKER_TAG_SUFFIX="openwrt-25.12"
DOCKER_IMAGE=""
CTRLD_VERSION=""
CTRLD_BRANCH=""
PKG_RELEASE=""
SIGN_KEY=""
GENERATE_KEY=0
REQUIRE_SIGNING=0
OUT_DIR=""
USE_CACHE=1
FORCE_IPV4=0
JOBS="$(nproc 2>/dev/null || echo 4)"
VERBOSE=0

usage() {
	cat <<'EOF'
Build OpenWrt 25.12+ APK v3 packages (.apk + packages.adb) from this feed.

The repository is registered into the OpenWrt SDK as a local feed (src-link),
ensuring full OpenWrt feed compatibility and accurate package origin metadata.

Usage:
  scripts/build-apk.sh [options]

Options:
  -t, --target <target/subtarget>  OpenWrt target/subtarget (default: mediatek/filogic)
                                   Supported targets: mediatek/filogic, mediatek/mt7622
  -p, --package <name|all>         Package name(s) to build (comma-separated, or 'all'; default: all)
      --feed-name <name>           OpenWrt feed name for src-link registration (default: custom)
  -m, --mode <docker|sdk>          Build backend:
                                     docker - official OpenWrt 25.12 SDK image (default)
                                     sdk    - native OpenWrt 25.12 SDK tarball on Linux/WSL
  -o, --openwrt-version <ver>      OpenWrt release for native SDK mode (default: 25.12.6)
      --openwrt-series <series>    OpenWrt series label for output dir (default: derived, e.g. 25.12)
      --registry <registry>        Container registry for openwrt/sdk (default: ghcr.io)
      --docker-tag <suffix>        Docker SDK branch/release suffix (default: openwrt-25.12)
      --image <image>              Full Docker image override (ignores --registry/--docker-tag)
  -v, --ctrld-version <ver>        Override ctrld PKG_VERSION (e.g. 1.5.11)
      --ctrld-branch <ref>         Build ctrld from a git branch/tag/commit instead of release tarball
      --pkg-release <num>          Override OpenWrt PKG_RELEASE (e.g. 1)
      --sign-key <path>            ECDSA P-256 private key (.pem) to sign .apk and packages.adb
                                   (defaults to APK_SIGNING_PRIVATE_KEY env var when set)
      --generate-key               Generate keys/{private,public}-key.pem if missing and sign
      --require-signing            Fail if no signing key is configured (--sign-key, --generate-key,
                                   or APK_SIGNING_PRIVATE_KEY)
      --out-dir <dir>              Output directory (default: dist/<series>/<arch>)
      --no-cache                   Disable download / SDK caching
      --ipv4                       Force IPv4 in curl downloads (helps with slow/broken IPv6 DNS)
  -j, --jobs <N>                   Parallel build jobs (default: nproc)
      --verbose                    Enable verbose OpenWrt make output (V=s)
  -h, --help                       Show this help message

Examples:
  # Build all feed packages for MediaTek Filogic (aarch64_cortex-a53) using Docker SDK
  ./scripts/build-apk.sh --target mediatek/filogic

  # Build and sign for MediaTek MT7622 (aarch64_cortex-a53) with an auto-generated ECDSA keypair
  ./scripts/build-apk.sh --target mediatek/mt7622 --generate-key

  # Build natively on Linux/WSL2 using the OpenWrt 25.12.6 SDK tarball
  ./scripts/build-apk.sh --mode sdk --target mediatek/filogic --openwrt-version 25.12.6 --ipv4
EOF
}

log() {
	printf '[build-apk] %s\n' "$*"
}

die() {
	printf '[build-apk] ERROR: %s\n' "$*" >&2
	exit 1
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

discover_feed_packages() {
	local mf pkg_dir
	while IFS= read -r mf; do
		if grep -qE 'call (BuildPackage|KernelPackage)' "$mf"; then
			pkg_dir="${mf#"${REPO_ROOT}/"}"
			pkg_dir="${pkg_dir%/Makefile}"
			printf '%s\n' "$pkg_dir"
		fi
	done < <(find "$REPO_ROOT" -mindepth 3 -maxdepth 3 -name Makefile \
		-not -path "${REPO_ROOT}/.*/*" \
		-not -path "${REPO_ROOT}/dist/*" \
		-not -path "${REPO_ROOT}/public/*" \
		-not -path "${REPO_ROOT}/scripts/*" \
		-not -path "${REPO_ROOT}/keys/*" | sort)
}

while [ $# -gt 0 ]; do
	case "$1" in
		-t|--target)
			TARGET_SPEC="${2:?missing value for $1}"
			shift 2
			;;
		-p|--package)
			PACKAGES_SPEC="${2:?missing value for $1}"
			shift 2
			;;
		--feed-name)
			FEED_NAME="${2:?missing value for $1}"
			shift 2
			;;
		-m|--mode)
			BUILD_MODE="${2:?missing value for $1}"
			shift 2
			;;
		-o|--openwrt-version)
			OPENWRT_VERSION="${2:?missing value for $1}"
			shift 2
			;;
		--openwrt-series)
			OPENWRT_SERIES="${2:?missing value for $1}"
			shift 2
			;;
		--registry)
			DOCKER_REGISTRY="${2:?missing value for $1}"
			shift 2
			;;
		--docker-tag)
			DOCKER_TAG_SUFFIX="${2:?missing value for $1}"
			shift 2
			;;
		--image)
			DOCKER_IMAGE="${2:?missing value for $1}"
			shift 2
			;;
		-v|--ctrld-version)
			CTRLD_VERSION="${2:?missing value for $1}"
			CTRLD_VERSION="${CTRLD_VERSION#v}"
			shift 2
			;;
		--ctrld-branch)
			CTRLD_BRANCH="${2:?missing value for $1}"
			shift 2
			;;
		--pkg-release)
			PKG_RELEASE="${2:?missing value for $1}"
			shift 2
			;;
		--sign-key)
			SIGN_KEY="${2:?missing value for $1}"
			shift 2
			;;
		--generate-key)
			GENERATE_KEY=1
			shift
			;;
		--require-signing)
			REQUIRE_SIGNING=1
			shift
			;;
		--out-dir)
			OUT_DIR="${2:?missing value for $1}"
			shift 2
			;;
		--no-cache)
			USE_CACHE=0
			shift
			;;
		--ipv4)
			FORCE_IPV4=1
			shift
			;;
		-j|--jobs)
			JOBS="${2:?missing value for $1}"
			shift 2
			;;
		--verbose)
			VERBOSE=1
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

case "$TARGET_SPEC" in
	mediatek/filogic|mediatek/mt7622)
		TARGET="${TARGET_SPEC%%/*}"
		SUBTARGET="${TARGET_SPEC#*/}"
		;;
	*)
		die "Unsupported --target '${TARGET_SPEC}': only 'mediatek/filogic' and 'mediatek/mt7622' are supported"
		;;
esac

if [ -z "$OPENWRT_SERIES" ]; then
	if [ "$BUILD_MODE" = "docker" ] && [[ "$DOCKER_TAG_SUFFIX" == openwrt-* ]]; then
		OPENWRT_SERIES="${DOCKER_TAG_SUFFIX#openwrt-}"
	else
		OPENWRT_SERIES="$(printf '%s\n' "$OPENWRT_VERSION" | awk -F. '{print $1 "." $2}')"
	fi
fi

# Discover all feed packages (<category>/<package>)
mapfile -t ALL_PKG_PATHS < <(discover_feed_packages)
[ "${#ALL_PKG_PATHS[@]}" -gt 0 ] || die "No OpenWrt packages found under ${REPO_ROOT}/<category>/<package>/Makefile"

SELECTED_PKGS=()
if [ "$PACKAGES_SPEC" = "all" ]; then
	for p in "${ALL_PKG_PATHS[@]}"; do
		SELECTED_PKGS+=("$(basename "$p")")
	done
else
	IFS=',' read -r -a REQUESTED_PKGS <<< "$PACKAGES_SPEC"
	for req in "${REQUESTED_PKGS[@]}"; do
		found=0
		for p in "${ALL_PKG_PATHS[@]}"; do
			if [ "$(basename "$p")" = "$req" ]; then
				SELECTED_PKGS+=("$req")
				found=1
				break
			fi
		done
		[ "$found" -eq 1 ] || die "Requested package '${req}' not found in feed (available: ${ALL_PKG_PATHS[*]})"
	done
fi
SELECTED_PKGS_STR="${SELECTED_PKGS[*]}"
log "Feed '${FEED_NAME}' packages to build: ${SELECTED_PKGS_STR}"

CLEANUP_TMP_DIR=""
CLEANUP_CONTAINER_ID=""

cleanup_all() {
	if [ -n "${CLEANUP_CONTAINER_ID:-}" ]; then
		docker rm -f "$CLEANUP_CONTAINER_ID" >/dev/null 2>&1 || true
		CLEANUP_CONTAINER_ID=""
	fi
	if [ -n "${CLEANUP_TMP_DIR:-}" ] && [ -d "$CLEANUP_TMP_DIR" ]; then
		rm -rf "$CLEANUP_TMP_DIR"
		CLEANUP_TMP_DIR=""
	fi
}
trap cleanup_all EXIT

CLEANUP_TMP_DIR="$(mktemp -d)"
TMP_DIR="$CLEANUP_TMP_DIR"

# Handle ECDSA P-256 signing key generation / env loading / validation
PUB_KEY=""
if [ "$GENERATE_KEY" -eq 1 ]; then
	require_cmd openssl
	KEYS_DIR="${REPO_ROOT}/keys"
	mkdir -p "$KEYS_DIR"
	if [ -z "$SIGN_KEY" ]; then
		SIGN_KEY="${KEYS_DIR}/private-key.pem"
	fi
	PUB_KEY="${KEYS_DIR}/public-key.pem"
	if [ ! -f "$SIGN_KEY" ]; then
		log "Generating ECDSA NIST P-256 signing keypair in ${KEYS_DIR}/"
		openssl ecparam -name prime256v1 -genkey -noout -out "$SIGN_KEY"
		chmod 600 "$SIGN_KEY"
	fi
	openssl pkey -in "$SIGN_KEY" -pubout -out "$PUB_KEY" 2>/dev/null \
		|| die "Invalid ECDSA private key: $SIGN_KEY"
	log "Using signing key: ${SIGN_KEY} (public key: ${PUB_KEY})"
elif [ -n "$SIGN_KEY" ]; then
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
	die "APK signing is required (--require-signing), but no key was provided via --sign-key, --generate-key, or APK_SIGNING_PRIVATE_KEY"
fi

if [ -n "$SIGN_KEY" ] && [ "$GENERATE_KEY" -eq 0 ] && command -v openssl >/dev/null 2>&1; then
	DERIVED_PUB_KEY="${TMP_DIR}/derived-public-key.pem"
	openssl pkey -in "$SIGN_KEY" -pubout -out "$DERIVED_PUB_KEY" 2>/dev/null \
		|| die "Invalid private signing key (failed openssl pkey validation)"
	PUB_KEY="$DERIVED_PUB_KEY"
	REPO_PUB_KEY="${REPO_ROOT}/keys/public-key.pem"
	if [ -f "$REPO_PUB_KEY" ] && ! cmp -s "$DERIVED_PUB_KEY" "$REPO_PUB_KEY"; then
		if [ "$REQUIRE_SIGNING" -eq 1 ]; then
			die "Signing private key does not match committed ${REPO_PUB_KEY}"
		else
			log "WARNING: signing private key does not match ${REPO_PUB_KEY}"
		fi
	fi
fi

if [ "$FORCE_IPV4" -eq 1 ]; then
	mkdir -p "${TMP_DIR}/curl-home"
	printf 'ipv4\n' > "${TMP_DIR}/curl-home/.curlrc"
	export CURL_HOME="${TMP_DIR}/curl-home"
	log "Forcing IPv4 for curl downloads"
fi

# Stage a clean copy of feed packages so src-link never scans .build/, .git/, or dist/
stage_feed_dir() {
	local dest="$1"
	mkdir -p "$dest"
	local rel_path cat_dir
	for rel_path in "${ALL_PKG_PATHS[@]}"; do
		cat_dir="$(dirname "$rel_path")"
		mkdir -p "${dest}/${cat_dir}"
		cp -a "${REPO_ROOT}/${rel_path}" "${dest}/${rel_path}"
	done
	chmod -R a+rX "$dest"
}

# Generate the inner build runner executed inside either the Docker SDK or native SDK directory
generate_sdk_runner() {
	local runner_path="$1"
	cat <<'EOF' > "$runner_path"
#!/usr/bin/env bash
set -euo pipefail

SDK_DIR="${SDK_DIR:-/builder}"
FEED_SRC="${FEED_SRC:-/tmp/openwrt-feed}"
FEED_NAME="${FEED_NAME:-custom}"
PACKAGES_LIST="${PACKAGES_LIST:-ctrld}"
EXPORT_DIR="${EXPORT_DIR:-/builder/export}"
SIGN_KEY_FILE="${SIGN_KEY_FILE:-}"
CTRLD_VERSION="${CTRLD_VERSION:-}"
CTRLD_BRANCH="${CTRLD_BRANCH:-}"
PKG_RELEASE="${PKG_RELEASE:-}"
JOBS="${JOBS:-4}"
VERBOSE="${VERBOSE:-0}"

cd "$SDK_DIR"

# OpenWrt 24.10+ / 25.12 Docker SDK containers start lean and fetch the SDK via setup.sh
if [ ! -d "./scripts" ] && [ -x "./setup.sh" ]; then
	echo "[sdk] Running ./setup.sh to initialize OpenWrt 25.12 SDK..."
	./setup.sh
fi

[ -x "./scripts/feeds" ] || { echo "[sdk] ERROR: ./scripts/feeds not found in $SDK_DIR" >&2; exit 1; }

# Apply optional version/branch overrides to the staged feed copy (never mutates repo tree)
CTRLD_MK="${FEED_SRC}/net/ctrld/Makefile"
if [ -f "$CTRLD_MK" ]; then
	if [ -n "$CTRLD_VERSION" ]; then
		CURRENT_VERSION="$(sed -nE 's|^PKG_VERSION:=(.*)$|\1|p' "$CTRLD_MK" | head -n 1)"
		echo "[sdk] Overriding ctrld PKG_VERSION=${CTRLD_VERSION}"
		sed -i -E "s|^PKG_VERSION:=.*|PKG_VERSION:=${CTRLD_VERSION}|" "$CTRLD_MK"
		if [ -z "$CTRLD_BRANCH" ] && [ "$CTRLD_VERSION" != "$CURRENT_VERSION" ]; then
			echo "[sdk] Setting ctrld PKG_HASH:=skip for unpinned version override"
			sed -i -E "s|^PKG_HASH:=.*|PKG_HASH:=skip|" "$CTRLD_MK"
		fi
	fi

	if [ -n "$CTRLD_BRANCH" ]; then
		echo "[sdk] Switching ctrld source to git ref ${CTRLD_BRANCH} (PKG_MIRROR_HASH:=skip)"
		sed -i -E \
			-e 's|^PKG_SOURCE:=.*|PKG_SOURCE_PROTO:=git|' \
			-e 's|^PKG_SOURCE_URL:=.*|PKG_SOURCE_URL:=https://github.com/Control-D-Inc/ctrld.git|' \
			-e "s|^PKG_HASH:=.*|PKG_SOURCE_VERSION:=${CTRLD_BRANCH}\nPKG_MIRROR_HASH:=skip|" \
			"$CTRLD_MK"
	fi
fi

if [ -n "$PKG_RELEASE" ]; then
	for pkg in $PACKAGES_LIST; do
		pkg_mk="$(find "$FEED_SRC" -mindepth 3 -maxdepth 3 -path "*/${pkg}/Makefile" | head -n 1 || true)"
		if [ -n "$pkg_mk" ]; then
			echo "[sdk] Overriding ${pkg} PKG_RELEASE=${PKG_RELEASE}"
			sed -i -E "s|^PKG_RELEASE:=.*|PKG_RELEASE:=${PKG_RELEASE}|" "$pkg_mk"
		fi
	done
fi

# Register the staged feed via src-cpy in feeds.conf so OpenWrt produces clean origin metadata (feeds/<name>/<pkg>)
echo "[sdk] Registering feed '${FEED_NAME}' via src-cpy (${FEED_SRC})..."
cp -f feeds.conf.default feeds.conf
grep -vE "^src-(link|cpy)[[:space:]]+${FEED_NAME}[[:space:]]" feeds.conf > feeds.conf.tmp || true
mv feeds.conf.tmp feeds.conf
printf 'src-cpy %s %s\n' "$FEED_NAME" "$FEED_SRC" >> feeds.conf

# Clean any stale manual copy or cached package metadata from older builds
rm -rf "${SDK_DIR}/package/ctrld" "${SDK_DIR}/tmp/.packageinfo" "${SDK_DIR}/tmp/info"

echo "[sdk] Updating OpenWrt feeds and installing packages..."
if grep -qE '^[[:space:]]*src-[^[:space:]]+[[:space:]]+base[[:space:]]' feeds.conf.default 2>/dev/null; then
	./scripts/feeds update base packages "$FEED_NAME"
	./scripts/feeds install -p base ca-certificates
	./scripts/feeds install -p packages golang
else
	./scripts/feeds update packages "$FEED_NAME"
	./scripts/feeds install -p packages golang
fi

for pkg in $PACKAGES_LIST; do
	./scripts/feeds install -f -p "$FEED_NAME" "$pkg"
done

{
	cat <<'CFG'
CONFIG_USE_APK=y
CONFIG_ALL=n
CONFIG_ALL_KMODS=n
CONFIG_ALL_NONSHARED=n
CONFIG_DEVEL=y
CONFIG_SIGNED_PACKAGES=n
CFG
	for pkg in $PACKAGES_LIST; do
		printf 'CONFIG_PACKAGE_%s=m\n' "$pkg"
	done
} > .config

make defconfig

if ! grep -q '^CONFIG_USE_APK=y' .config; then
	echo "[sdk] ERROR: CONFIG_USE_APK=y is not active. Ensure you are using an OpenWrt 25.12+ SDK." >&2
	exit 1
fi

MAKE_VERBOSE=""
if [ "$VERBOSE" -eq 1 ]; then
	MAKE_VERBOSE="V=s"
fi

# Clean prior feed build outputs inside SDK to avoid exporting stale packages
rm -rf "${SDK_DIR}"/bin/packages/*/"${FEED_NAME}"

for pkg in $PACKAGES_LIST; do
	echo "[sdk] Downloading ${pkg} sources..."
	pkg_mk="$(find "$FEED_SRC" -mindepth 3 -maxdepth 3 -path "*/${pkg}/Makefile" | head -n 1 || true)"
	if [ -n "$pkg_mk" ] && grep -qE '^PKG_(MIRROR_)?HASH:=skip$' "$pkg_mk"; then
		rm -f "${SDK_DIR}/dl/${pkg}"-*.tar.*
	fi
	make "package/feeds/${FEED_NAME}/${pkg}/download" ${MAKE_VERBOSE}

	echo "[sdk] Compiling ${pkg} APK package (jobs=${JOBS})..."
	make "package/feeds/${FEED_NAME}/${pkg}/compile" -j"${JOBS}" ${MAKE_VERBOSE}
done

echo "[sdk] Locating generated .apk packages under bin/packages/*/${FEED_NAME}..."
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"

mapfile -t APK_FILES < <(find "${SDK_DIR}/bin/packages" -path "*/${FEED_NAME}/*.apk" -type f | sort)
if [ "${#APK_FILES[@]}" -eq 0 ]; then
	echo "[sdk] ERROR: No .apk packages found under ${SDK_DIR}/bin/packages/*/${FEED_NAME}" >&2
	exit 1
fi

# Extract OpenWrt package architecture from bin/packages/<arch>/<feed_name>/
FIRST_APK="${APK_FILES[0]}"
FEED_DIR_PARENT="$(dirname "$FIRST_APK")"
PKG_ARCH="$(basename "$(dirname "$FEED_DIR_PARENT")")"
printf '%s\n' "$PKG_ARCH" > "${EXPORT_DIR}/.arch"
echo "[sdk] Detected OpenWrt package architecture: ${PKG_ARCH}"

for apk_file in "${APK_FILES[@]}"; do
	cp -f "$apk_file" "${EXPORT_DIR}/"
done

APK_BIN="${SDK_DIR}/staging_dir/host/bin/apk"
if [ ! -x "$APK_BIN" ]; then
	APK_BIN="$(command -v apk || true)"
fi

if [ -x "$APK_BIN" ]; then
	cd "$EXPORT_DIR"
	if [ -n "$SIGN_KEY_FILE" ] && [ -f "$SIGN_KEY_FILE" ]; then
		echo "[sdk] Signing .apk package(s) and generating signed packages.adb index..."
		for f in *.apk; do
			"$APK_BIN" adbsign --allow-untrusted --sign-key "$SIGN_KEY_FILE" "$f"
		done
		"$APK_BIN" mkndx --allow-untrusted --sign-key "$SIGN_KEY_FILE" \
			--output packages.adb ./*.apk
	else
		echo "[sdk] Generating unsigned packages.adb repository index..."
		"$APK_BIN" mkndx --allow-untrusted --output packages.adb ./*.apk
	fi
else
	if [ -n "$SIGN_KEY_FILE" ]; then
		echo "[sdk] ERROR: host apk binary not found; cannot sign packages or generate signed packages.adb." >&2
		exit 1
	fi
	echo "[sdk] WARNING: host apk binary not found; skipping packages.adb generation." >&2
fi

cd "$EXPORT_DIR"
SUM_FILES=(*.apk)
if [ -f packages.adb ]; then
	SUM_FILES+=(packages.adb)
fi
sha256sum "${SUM_FILES[@]}" > SHA256SUMS

echo "[sdk] Build artifacts ready (arch=${PKG_ARCH}):"
ls -lh "$EXPORT_DIR"
EOF
	chmod 755 "$runner_path"
}

STAGED_EXPORT_DIR="${TMP_DIR}/export"
mkdir -p "$STAGED_EXPORT_DIR"

build_with_docker() {
	require_cmd docker

	local tag_target="${TARGET}-${SUBTARGET}"
	if [ -z "$DOCKER_IMAGE" ]; then
		if [ "$DOCKER_REGISTRY" = "docker.io" ]; then
			DOCKER_IMAGE="openwrt/sdk:${tag_target}-${DOCKER_TAG_SUFFIX}"
		else
			DOCKER_IMAGE="${DOCKER_REGISTRY}/openwrt/sdk:${tag_target}-${DOCKER_TAG_SUFFIX}"
		fi
	fi

	log "Building feed packages in Docker using ${DOCKER_IMAGE}"

	CLEANUP_CONTAINER_ID="openwrt-apk-build-$$-$(date +%s)"
	local cid="$CLEANUP_CONTAINER_ID"

	local runner_script="${TMP_DIR}/run-build.sh"
	generate_sdk_runner "$runner_script"
	stage_feed_dir "${TMP_DIR}/openwrt-feed"

	local -a docker_create_args=(
		--name "$cid"
		-e "SDK_DIR=/builder"
		-e "FEED_SRC=/tmp/openwrt-feed"
		-e "FEED_NAME=${FEED_NAME}"
		-e "PACKAGES_LIST=${SELECTED_PKGS_STR}"
		-e "EXPORT_DIR=/builder/export"
		-e "CTRLD_VERSION=${CTRLD_VERSION}"
		-e "CTRLD_BRANCH=${CTRLD_BRANCH}"
		-e "PKG_RELEASE=${PKG_RELEASE}"
		-e "JOBS=${JOBS}"
		-e "VERBOSE=${VERBOSE}"
	)

	if [ "$USE_CACHE" -eq 1 ]; then
		docker_create_args+=(-v "openwrt-${OPENWRT_SERIES}-apk-dl-cache:/builder/dl")
	fi

	if [ -n "$SIGN_KEY" ]; then
		docker_create_args+=(-e "SIGN_KEY_FILE=/tmp/private-key.pem")
	fi

	docker pull "$DOCKER_IMAGE"
	docker create "${docker_create_args[@]}" "$DOCKER_IMAGE" bash /tmp/run-build.sh >/dev/null

	docker cp "${TMP_DIR}/openwrt-feed" "${cid}:/tmp/openwrt-feed"
	docker cp "$runner_script" "${cid}:/tmp/run-build.sh"

	if [ -n "$SIGN_KEY" ]; then
		cp "$SIGN_KEY" "${TMP_DIR}/private-key.pem"
		chmod 644 "${TMP_DIR}/private-key.pem"
		docker cp "${TMP_DIR}/private-key.pem" "${cid}:/tmp/private-key.pem"
		rm -f "${TMP_DIR}/private-key.pem"
	fi

	docker start -a "$cid"

	docker cp "${cid}:/builder/export/." "${STAGED_EXPORT_DIR}/"
}

build_with_native_sdk() {
	require_cmd curl
	require_cmd tar
	require_cmd sha256sum
	require_cmd make

	if ! command -v zstd >/dev/null 2>&1; then
		die "zstd is required to extract OpenWrt 25.12 .tar.zst SDK archives (install package: zstd)"
	fi

	local base_url="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${TARGET}/${SUBTARGET}"
	local cache_root="${REPO_ROOT}/.build/sdk/${OPENWRT_VERSION}/${TARGET}-${SUBTARGET}"
	mkdir -p "$cache_root"

	log "Fetching OpenWrt ${OPENWRT_VERSION} SDK metadata from ${base_url}/sha256sums"
	local sums_file="${cache_root}/sha256sums"
	curl -fsSL "${base_url}/sha256sums" -o "$sums_file" \
		|| die "Failed to fetch ${base_url}/sha256sums (verify --openwrt-version and --target)"

	local sdk_line sdk_sha sdk_archive
	sdk_line="$(grep -E "openwrt-sdk-${OPENWRT_VERSION}-.*\.tar\.(zst|xz)$" "$sums_file" | head -n 1 || true)"
	[ -n "$sdk_line" ] || die "Could not locate openwrt-sdk-${OPENWRT_VERSION} tarball in sha256sums"

	sdk_sha="$(printf '%s\n' "$sdk_line" | awk '{print $1}')"
	sdk_archive="$(printf '%s\n' "$sdk_line" | awk '{print $2}' | sed 's/^\*//')"

	local archive_path="${cache_root}/${sdk_archive}"
	if [ "$USE_CACHE" -eq 0 ] || [ ! -f "$archive_path" ]; then
		log "Downloading ${sdk_archive}..."
		curl -fL --progress-bar "${base_url}/${sdk_archive}" -o "$archive_path"
	else
		log "Using cached SDK archive: ${archive_path}"
	fi

	log "Verifying SHA-256 checksum for ${sdk_archive}..."
	printf '%s  %s\n' "$sdk_sha" "$archive_path" | sha256sum -c -

	local sdk_dir="${cache_root}/sdk"
	if [ "$USE_CACHE" -eq 0 ] || [ ! -d "${sdk_dir}/scripts" ]; then
		log "Extracting SDK into ${sdk_dir}..."
		rm -rf "$sdk_dir"
		mkdir -p "$sdk_dir"
		case "$sdk_archive" in
			*.tar.zst)
				zstd -dc "$archive_path" | tar -xf - --strip-components=1 -C "$sdk_dir"
				;;
			*.tar.xz)
				tar -xJf "$archive_path" --strip-components=1 -C "$sdk_dir"
				;;
			*)
				die "Unsupported SDK archive extension: $sdk_archive"
				;;
		esac
	fi

	local runner_script="${TMP_DIR}/run-build.sh"
	generate_sdk_runner "$runner_script"
	stage_feed_dir "${TMP_DIR}/openwrt-feed"

	SDK_DIR="$sdk_dir" \
	FEED_SRC="${TMP_DIR}/openwrt-feed" \
	FEED_NAME="$FEED_NAME" \
	PACKAGES_LIST="$SELECTED_PKGS_STR" \
	EXPORT_DIR="$STAGED_EXPORT_DIR" \
	SIGN_KEY_FILE="$SIGN_KEY" \
	CTRLD_VERSION="$CTRLD_VERSION" \
	CTRLD_BRANCH="$CTRLD_BRANCH" \
	PKG_RELEASE="$PKG_RELEASE" \
	JOBS="$JOBS" \
	VERBOSE="$VERBOSE" \
	bash "$runner_script"
}

case "$BUILD_MODE" in
	docker)
		build_with_docker
		;;
	sdk)
		build_with_native_sdk
		;;
	*)
		die "Unsupported --mode '${BUILD_MODE}': expected 'docker' or 'sdk'"
		;;
esac

DETECTED_ARCH=""
if [ -f "${STAGED_EXPORT_DIR}/.arch" ]; then
	DETECTED_ARCH="$(cat "${STAGED_EXPORT_DIR}/.arch")"
	rm -f "${STAGED_EXPORT_DIR}/.arch"
fi

if [ -z "$OUT_DIR" ]; then
	if [ -n "$DETECTED_ARCH" ]; then
		OUT_DIR="${REPO_ROOT}/dist/${OPENWRT_SERIES}/${DETECTED_ARCH}"
	else
		OUT_DIR="${REPO_ROOT}/dist/${OPENWRT_SERIES}/${TARGET}-${SUBTARGET}"
	fi
fi
mkdir -p "$OUT_DIR"

rm -f "${OUT_DIR}"/*.apk "${OUT_DIR}/packages.adb" "${OUT_DIR}/SHA256SUMS" "${OUT_DIR}/public-key.pem"
cp -a "${STAGED_EXPORT_DIR}/." "${OUT_DIR}/"

if [ -n "$SIGN_KEY" ] && [ -z "$PUB_KEY" ] && command -v openssl >/dev/null 2>&1; then
	PUB_KEY="${OUT_DIR}/public-key.pem"
	openssl pkey -in "$SIGN_KEY" -pubout -out "$PUB_KEY" 2>/dev/null \
		|| die "Invalid ECDSA private key: $SIGN_KEY"
elif [ -n "$PUB_KEY" ] && [ -f "$PUB_KEY" ] && [ "${PUB_KEY}" != "${OUT_DIR}/public-key.pem" ]; then
	cp -f "$PUB_KEY" "${OUT_DIR}/public-key.pem"
fi

BUILT_APKS=("${OUT_DIR}"/*.apk)
[ -f "${BUILT_APKS[0]}" ] || die "Expected .apk package(s) not found in ${OUT_DIR}"

log "Success! Package(s) generated in: ${OUT_DIR} (arch=${DETECTED_ARCH:-unknown})"
for apk_f in "${BUILT_APKS[@]}"; do
	log "  - ${apk_f}"
done

BUILT_CTRLD="$(find "$OUT_DIR" -maxdepth 1 -type f -name 'ctrld-*.apk' | sort | tail -n 1 || true)"
if [ -n "$BUILT_CTRLD" ]; then
	printf '\nNext step - install ctrld on your OpenWrt 25.12+ router:\n'
	printf '  ./net/ctrld/scripts/install-openwrt.sh --host root@192.168.1.1 --apk "%s" --cd YOUR_RESOLVER_ID\n' "$BUILT_CTRLD"
	if [ -f "${OUT_DIR}/public-key.pem" ]; then
		printf '\nOr manually (signed package):\n'
		printf '  ssh root@192.168.1.1 "cat > /etc/apk/keys/custom-feed.pem" < "%s/public-key.pem"\n' "$OUT_DIR"
		printf '  ssh root@192.168.1.1 "cat > /tmp/%s" < "%s"\n' "$(basename "$BUILT_CTRLD")" "$BUILT_CTRLD"
		printf '  ssh root@192.168.1.1 "apk update && apk add /tmp/%s"\n' "$(basename "$BUILT_CTRLD")"
	else
		printf '\nOr manually (unsigned local package):\n'
		printf '  ssh root@192.168.1.1 "cat > /tmp/%s" < "%s"\n' "$(basename "$BUILT_CTRLD")" "$BUILT_CTRLD"
		printf '  ssh root@192.168.1.1 "apk update && apk add --allow-untrusted /tmp/%s"\n' "$(basename "$BUILT_CTRLD")"
	fi
fi
