#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"

ROUTER_HOST=""
SSH_PORT="22"
SSH_IDENTITY=""
APK_PATH=""
PUB_KEY_PATH=""
ALLOW_UNTRUSTED=0
CD_UID=""
CONFIG_FILE=""
IFACE=""
IFACE_SET=0
FIX_DNSMASQ_CONFDIR=""
ENABLE_SERVICE=0
SKIP_UPDATE=0

usage() {
	cat <<'EOF'
Install a built ctrld OpenWrt 25.12+ .apk package onto a router over SSH.

Usage:
  net/ctrld/scripts/install-openwrt.sh --host <root@router-ip> [options]

Options:
  -H, --host <host>           Router SSH target (e.g. 192.168.1.1 or root@192.168.1.1)
  -p, --port <port>           SSH port (default: 22)
  -i, --identity <keyfile>    SSH private key file
  -f, --apk <file.apk>        Path to ctrld-*.apk (auto-detected in dist/<series>/<arch> if omitted)
  -k, --pub-key <file.pem>    ECDSA public key to install into /etc/apk/keys/custom-feed.pem
      --allow-untrusted       Force `apk add --allow-untrusted` (default when no public key is provided)
      --cd <resolver-id>      Configure Control D Resolver ID in UCI, enable & start ctrld
      --config <ctrld.toml>   Upload local ctrld.toml to /etc/controld/ctrld.toml, enable & start ctrld
      --iface <iface>         Set UCI ctrld.main.iface (e.g. auto, br-lan, or "" to disable)
      --fix-dnsmasq-confdir   Set UCI ctrld.main.fix_dnsmasq_confdir='1' (opt-in dnsmasq helper)
      --no-dnsmasq-fix        Set UCI ctrld.main.fix_dnsmasq_confdir='0'
      --enable                Enable and start /etc/init.d/ctrld after installation
      --skip-update           Skip running `apk update` before `apk add`
  -h, --help                  Show this help message

Examples:
  # Auto-detect router arch, upload matching APK from dist/, configure Control D Resolver ID
  ./net/ctrld/scripts/install-openwrt.sh --host root@192.168.1.1 --cd abc123def4

  # Install explicit APK file with a local ctrld.toml config
  ./net/ctrld/scripts/install-openwrt.sh --host 192.168.1.1 --apk dist/25.12/aarch64_cortex-a53/ctrld-1.5.11-r1.apk --config ./ctrld.toml
EOF
}

log() {
	printf '[install-openwrt] %s\n' "$*"
}

die() {
	printf '[install-openwrt] ERROR: %s\n' "$*" >&2
	exit 1
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

while [ $# -gt 0 ]; do
	case "$1" in
		-H|--host)
			ROUTER_HOST="${2:?missing value for $1}"
			shift 2
			;;
		-p|--port)
			SSH_PORT="${2:?missing value for $1}"
			shift 2
			;;
		-i|--identity)
			SSH_IDENTITY="${2:?missing value for $1}"
			shift 2
			;;
		-f|--apk)
			APK_PATH="${2:?missing value for $1}"
			shift 2
			;;
		-k|--pub-key)
			PUB_KEY_PATH="${2:?missing value for $1}"
			shift 2
			;;
		--allow-untrusted)
			ALLOW_UNTRUSTED=1
			shift
			;;
		--cd)
			CD_UID="${2:?missing value for $1}"
			ENABLE_SERVICE=1
			shift 2
			;;
		--config)
			CONFIG_FILE="${2:?missing value for $1}"
			ENABLE_SERVICE=1
			shift 2
			;;
		--iface)
			[ $# -ge 2 ] || die "missing value for $1"
			IFACE="$2"
			IFACE_SET=1
			shift 2
			;;
		--fix-dnsmasq-confdir)
			FIX_DNSMASQ_CONFDIR="1"
			shift
			;;
		--no-dnsmasq-fix)
			FIX_DNSMASQ_CONFDIR="0"
			shift
			;;
		--enable)
			ENABLE_SERVICE=1
			shift
			;;
		--skip-update)
			SKIP_UPDATE=1
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

require_cmd ssh
require_cmd sha256sum

[ -n "$ROUTER_HOST" ] || die "Missing required --host option (use --help for usage)"

case "$ROUTER_HOST" in
	*@*) SSH_TARGET="$ROUTER_HOST" ;;
	*)   SSH_TARGET="root@${ROUTER_HOST}" ;;
esac

if [ -n "$CONFIG_FILE" ] && [ ! -f "$CONFIG_FILE" ]; then
	die "Config file not found: $CONFIG_FILE"
fi

if [ -n "$PUB_KEY_PATH" ] && [ ! -f "$PUB_KEY_PATH" ]; then
	die "Public key file not found: $PUB_KEY_PATH"
fi

SSH_OPTS=(-p "$SSH_PORT" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
if [ -n "$SSH_IDENTITY" ]; then
	SSH_OPTS+=(-i "$SSH_IDENTITY")
fi

sh_quote() {
	printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

remote_exec() {
	ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$@"
}

# Stream file copy over SSH stdin so it works cleanly with OpenWrt Dropbear (no sftp-server required)
remote_copy() {
	local local_file="$1"
	local remote_path="$2"
	local remote_mode="${3:-0644}"
	local q_path q_mode
	q_path="$(sh_quote "$remote_path")"
	q_mode="$(sh_quote "$remote_mode")"
	ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
		"mkdir -p \"\$(dirname ${q_path})\" && cat > ${q_path} && chmod ${q_mode} ${q_path}" \
		< "$local_file"
}

log "Connecting to ${SSH_TARGET} and inspecting OpenWrt environment..."
ROUTER_INFO="$(remote_exec '
	if ! command -v apk >/dev/null 2>&1; then
		echo "ERR_NO_APK"
		exit 0
	fi
	[ -f /etc/openwrt_release ] && . /etc/openwrt_release
	ARCH="$(apk print-arch 2>/dev/null || echo "${DISTRIB_ARCH:-unknown}")"
	printf "RELEASE=%s\nTARGET=%s\nARCH=%s\n" \
		"${DISTRIB_RELEASE:-unknown}" \
		"${DISTRIB_TARGET:-unknown}" \
		"${ARCH}"
')"

if [ "$ROUTER_INFO" = "ERR_NO_APK" ]; then
	die "Target router does not have 'apk' installed. OpenWrt 25.12+ is required."
fi

ROUTER_RELEASE="$(printf '%s\n' "$ROUTER_INFO" | awk -F= '$1=="RELEASE"{print $2}')"
ROUTER_TARGET="$(printf '%s\n' "$ROUTER_INFO" | awk -F= '$1=="TARGET"{print $2}')"
ROUTER_ARCH="$(printf '%s\n' "$ROUTER_INFO" | awk -F= '$1=="ARCH"{print $2}')"
ROUTER_SERIES="$(printf '%s\n' "$ROUTER_RELEASE" | awk -F. '{if (NF>=2) print $1 "." $2; else print $1}')"

log "Detected router: OpenWrt ${ROUTER_RELEASE} | target=${ROUTER_TARGET} | arch=${ROUTER_ARCH}"

# Auto-locate APK in dist/<series>/<arch>/ (or any matching dist/*/<arch>/) when --apk is omitted
if [ -z "$APK_PATH" ]; then
	for candidate_dir in \
		"${REPO_ROOT}/dist/${ROUTER_SERIES}/${ROUTER_ARCH}" \
		"${REPO_ROOT}/dist/${ROUTER_TARGET}"; do
		if [ -d "$candidate_dir" ]; then
			APK_PATH="$(find "$candidate_dir" -maxdepth 1 -type f -name 'ctrld-*.apk' | sort | tail -n 1 || true)"
			[ -n "$APK_PATH" ] && break
		fi
	done
	if [ -z "$APK_PATH" ] && [ -d "${REPO_ROOT}/dist" ]; then
		APK_PATH="$(find "${REPO_ROOT}/dist" -path "*/${ROUTER_ARCH}/ctrld-*.apk" -type f | sort | tail -n 1 || true)"
	fi
	if [ -z "$APK_PATH" ]; then
		die "No ctrld-*.apk found for router arch '${ROUTER_ARCH}' (target '${ROUTER_TARGET}'). Build it first with:
  ./scripts/build-apk.sh --target ${ROUTER_TARGET}"
	fi
	log "Auto-selected package: ${APK_PATH}"
fi

[ -f "$APK_PATH" ] || die "APK file not found: $APK_PATH"

# Auto-detect sibling public-key.pem unless --allow-untrusted was explicitly requested
if [ -z "$PUB_KEY_PATH" ] && [ "$ALLOW_UNTRUSTED" -eq 0 ]; then
	sibling_key="$(dirname -- "$APK_PATH")/public-key.pem"
	if [ -f "$sibling_key" ]; then
		PUB_KEY_PATH="$sibling_key"
		log "Detected signing public key alongside APK: ${PUB_KEY_PATH}"
	fi
fi

if [ -n "$PUB_KEY_PATH" ]; then
	log "Installing public signing key to /etc/apk/keys/custom-feed.pem"
	remote_copy "$PUB_KEY_PATH" "/etc/apk/keys/custom-feed.pem" "0644"
else
	ALLOW_UNTRUSTED=1
fi

APK_BASENAME="$(basename -- "$APK_PATH")"
REMOTE_APK="/tmp/${APK_BASENAME}"
Q_REMOTE_APK="$(sh_quote "$REMOTE_APK")"
LOCAL_SHA="$(sha256sum "$APK_PATH" | awk '{print $1}')"

log "Uploading ${APK_BASENAME} to ${SSH_TARGET}:${REMOTE_APK}..."
remote_copy "$APK_PATH" "$REMOTE_APK" "0644"

REMOTE_SHA="$(remote_exec "sha256sum ${Q_REMOTE_APK} | awk '{print \$1}'")"
if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
	remote_exec "rm -f ${Q_REMOTE_APK}" || true
	die "SHA-256 verification failed after upload (local=${LOCAL_SHA}, remote=${REMOTE_SHA})"
fi
log "Upload checksum verified (${LOCAL_SHA})"

APK_ADD_FLAGS=""
if [ "$ALLOW_UNTRUSTED" -eq 1 ]; then
	APK_ADD_FLAGS="--allow-untrusted"
fi

if [ "$SKIP_UPDATE" -eq 0 ]; then
	log "Updating router APK package indexes (required for dependencies such as ca-bundle)..."
	remote_exec "apk update"
fi

log "Installing ${APK_BASENAME} via apk add ${APK_ADD_FLAGS}..."
remote_exec "apk add ${APK_ADD_FLAGS} ${Q_REMOTE_APK} && rm -f ${Q_REMOTE_APK}"

if [ -n "$CONFIG_FILE" ]; then
	log "Uploading local config ${CONFIG_FILE} to /etc/controld/ctrld.toml..."
	remote_copy "$CONFIG_FILE" "/etc/controld/ctrld.toml" "0600"
fi

UCI_UPDATED=0
if [ -n "$CD_UID" ] || [ "$IFACE_SET" -eq 1 ] || [ -n "$FIX_DNSMASQ_CONFDIR" ] || [ "$ENABLE_SERVICE" -eq 1 ]; then
	log "Applying UCI configuration to /etc/config/ctrld..."
	UCI_SCRIPT="set -e"
	if [ -n "$CD_UID" ]; then
		UCI_SCRIPT="${UCI_SCRIPT}; uci set ctrld.main.cd_uid=$(sh_quote "$CD_UID")"
	fi
	if [ "$IFACE_SET" -eq 1 ]; then
		UCI_SCRIPT="${UCI_SCRIPT}; uci set ctrld.main.iface=$(sh_quote "$IFACE")"
	fi
	if [ -n "$FIX_DNSMASQ_CONFDIR" ]; then
		UCI_SCRIPT="${UCI_SCRIPT}; uci set ctrld.main.fix_dnsmasq_confdir=$(sh_quote "$FIX_DNSMASQ_CONFDIR")"
	fi
	if [ "$ENABLE_SERVICE" -eq 1 ]; then
		UCI_SCRIPT="${UCI_SCRIPT}; uci set ctrld.main.enabled='1'"
	fi
	UCI_SCRIPT="${UCI_SCRIPT}; uci commit ctrld"
	remote_exec "$UCI_SCRIPT"
	UCI_UPDATED=1
fi

if [ "$ENABLE_SERVICE" -eq 1 ] || [ "$UCI_UPDATED" -eq 1 ] || [ -n "$CONFIG_FILE" ]; then
	log "Enabling and restarting ctrld service..."
	remote_exec "/etc/init.d/ctrld enable && /etc/init.d/ctrld restart"
	sleep 2
fi

log "Verifying installation on router..."
remote_exec '
	echo "--- installed package ---"
	apk info -e ctrld && apk list --installed ctrld
	echo "--- binary version ---"
	/usr/sbin/ctrld --version 2>&1 || true
	echo "--- service status ---"
	if /etc/init.d/ctrld enabled; then
		echo "ctrld service is ENABLED for boot"
	else
		echo "ctrld service is DISABLED for boot"
	fi
	if /etc/init.d/ctrld running; then
		echo "ctrld service is RUNNING"
	else
		echo "ctrld service is STOPPED (check logs with: logread -e ctrld)"
	fi
'

log "Done!"
