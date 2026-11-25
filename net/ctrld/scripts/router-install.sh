#!/bin/sh
# Standalone POSIX sh installer to run directly ON an OpenWrt 25.12 router.
set -eu

APK_SOURCE=""
REPO_URL=""
PUB_KEY_SRC=""
ALLOW_UNTRUSTED=0
CD_UID=""
CONFIG_PATH=""
IFACE=""
IFACE_SET=0
FIX_DNSMASQ_CONFDIR=""
ENABLE_SERVICE=0
SKIP_UPDATE=0

usage() {
	cat <<'EOF'
Install and configure ctrld directly on an OpenWrt 25.12 router using apk.

Usage:
  sh router-install.sh (--apk <path-or-url> | --repo <packages.adb-url>) [options]

Options:
  --apk <path-or-url>       Local path or HTTP(S) URL to ctrld-*.apk
  --repo <url>              Custom APK repository packages.adb URL to register in /etc/apk/repositories.d/ctrld.list
  --pub-key <path-or-url>   ECDSA public key (.pem) to install in /etc/apk/keys/ctrld-custom.pem
  --allow-untrusted         Pass --allow-untrusted to `apk add`
  --cd <resolver-id>        Set Control D Resolver ID in UCI, enable & start service
  --config <path>           Set UCI config_file path, enable & start service
  --iface <iface>           Set UCI iface ('auto', 'br-lan', or empty)
  --fix-dnsmasq-confdir     Enable automatic dhcp.@dnsmasq[0].confdir=/tmp/dnsmasq.d helper
  --no-dnsmasq-fix          Disable automatic dhcp.@dnsmasq[0].confdir=/tmp/dnsmasq.d helper
  --enable                  Enable and start /etc/init.d/ctrld
  --skip-update             Skip `apk update`
  -h, --help                Show this help

Examples:
  # Install a local .apk uploaded to /tmp
  sh router-install.sh --apk /tmp/ctrld-1.5.11-r1.apk --allow-untrusted --cd YOUR_RESOLVER_ID

  # Install from a hosted OpenWrt 25.12 APK repository with signing key
  sh router-install.sh \
    --repo https://example.com/openwrt-25.12/mediatek/filogic/packages.adb \
    --pub-key https://example.com/openwrt-25.12/public-key.pem \
    --cd YOUR_RESOLVER_ID
EOF
}

log() {
	printf '[ctrld-router-install] %s\n' "$*"
}

die() {
	printf '[ctrld-router-install] ERROR: %s\n' "$*" >&2
	exit 1
}

fetch_to() {
	src="$1"
	dst="$2"
	case "$src" in
		http://*|https://*)
			if command -v curl >/dev/null 2>&1; then
				curl -fsSL "$src" -o "$dst"
			elif command -v uclient-fetch >/dev/null 2>&1; then
				uclient-fetch -qO "$dst" "$src"
			elif command -v wget >/dev/null 2>&1; then
				wget -qO "$dst" "$src"
			else
				die "No HTTP client (curl, uclient-fetch, or wget) available to fetch $src"
			fi
			;;
		*)
			[ -f "$src" ] || die "File not found: $src"
			cp -f "$src" "$dst"
			;;
	esac
}

while [ $# -gt 0 ]; do
	case "$1" in
		--apk)
			APK_SOURCE="${2:?missing value for $1}"
			shift 2
			;;
		--repo)
			REPO_URL="${2:?missing value for $1}"
			shift 2
			;;
		--pub-key)
			PUB_KEY_SRC="${2:?missing value for $1}"
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
			CONFIG_PATH="${2:?missing value for $1}"
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
			die "Unknown option: $1"
			;;
	esac
done

command -v apk >/dev/null 2>&1 || die "'apk' command not found. This script requires OpenWrt 25.12+."

if [ -z "$APK_SOURCE" ] && [ -z "$REPO_URL" ]; then
	die "Specify either --apk <path-or-url> or --repo <packages.adb-url> (use --help for usage)"
fi

if [ -n "$PUB_KEY_SRC" ]; then
	log "Installing public signing key to /etc/apk/keys/ctrld-custom.pem"
	mkdir -p /etc/apk/keys
	fetch_to "$PUB_KEY_SRC" /etc/apk/keys/ctrld-custom.pem
	chmod 0644 /etc/apk/keys/ctrld-custom.pem
fi

if [ -n "$REPO_URL" ]; then
	log "Registering repository in /etc/apk/repositories.d/ctrld.list"
	mkdir -p /etc/apk/repositories.d
	printf '%s\n' "$REPO_URL" > /etc/apk/repositories.d/ctrld.list
fi

if [ "$SKIP_UPDATE" -eq 0 ]; then
	log "Running apk update..."
	if [ "$ALLOW_UNTRUSTED" -eq 1 ]; then
		apk update --allow-untrusted
	else
		apk update
	fi
fi

if [ -n "$APK_SOURCE" ]; then
	TMP_APK="/tmp/ctrld-install.apk"
	trap 'rm -f "$TMP_APK"' EXIT
	case "$APK_SOURCE" in
		http://*|https://*)
			log "Downloading ${APK_SOURCE}..."
			fetch_to "$APK_SOURCE" "$TMP_APK"
			TARGET_APK="$TMP_APK"
			;;
		*)
			[ -f "$APK_SOURCE" ] || die "APK file not found: $APK_SOURCE"
			TARGET_APK="$APK_SOURCE"
			;;
	esac

	log "Installing ${TARGET_APK}..."
	if [ "$ALLOW_UNTRUSTED" -eq 1 ]; then
		apk add --allow-untrusted "$TARGET_APK"
	else
		apk add "$TARGET_APK"
	fi
else
	log "Installing ctrld from configured APK repositories..."
	if [ "$ALLOW_UNTRUSTED" -eq 1 ]; then
		apk add --allow-untrusted ctrld
	else
		apk add ctrld
	fi
fi

UCI_UPDATED=0
if [ -n "$CD_UID" ] || [ -n "$CONFIG_PATH" ] || [ "$IFACE_SET" -eq 1 ] || [ -n "$FIX_DNSMASQ_CONFDIR" ] || [ "$ENABLE_SERVICE" -eq 1 ]; then
	log "Updating UCI configuration (/etc/config/ctrld)..."
	if [ -n "$CD_UID" ]; then
		uci set "ctrld.main.cd_uid=${CD_UID}"
	fi
	if [ -n "$CONFIG_PATH" ]; then
		uci set "ctrld.main.config_file=${CONFIG_PATH}"
	fi
	if [ "$IFACE_SET" -eq 1 ]; then
		uci set "ctrld.main.iface=${IFACE}"
	fi
	if [ -n "$FIX_DNSMASQ_CONFDIR" ]; then
		uci set "ctrld.main.fix_dnsmasq_confdir=${FIX_DNSMASQ_CONFDIR}"
	fi
	if [ "$ENABLE_SERVICE" -eq 1 ]; then
		uci set ctrld.main.enabled='1'
	fi
	uci commit ctrld
	UCI_UPDATED=1
fi

if [ "$ENABLE_SERVICE" -eq 1 ] || [ "$UCI_UPDATED" -eq 1 ]; then
	log "Enabling and restarting ctrld service..."
	/etc/init.d/ctrld enable
	/etc/init.d/ctrld restart
fi

log "Installed version: $(/usr/sbin/ctrld --version 2>&1 || echo unknown)"
if /etc/init.d/ctrld running; then
	log "ctrld is RUNNING."
else
	log "ctrld is installed and stopped. Check logs with 'logread -e ctrld' or verify /etc/config/ctrld."
fi
