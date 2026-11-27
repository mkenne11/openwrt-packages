#!/usr/bin/env bash
set -euo pipefail

INCLUDE_PLACEHOLDERS=0
STRICT=0
COMMIT_LIMIT=20
ALLOWED_EMAIL="12181805+mkenne11@users.noreply.github.com"

usage() {
	cat <<'EOF'
Audit git-tracked files and recent commit metadata for secrets, sensitive
network details, and personal information.

Usage:
  .agents/skills/privacy-secret-audit/scripts/audit-tracked.sh [options]

Options:
      --include-placeholders  Do not filter standard doc placeholders (192.168.1.1, 76.76.2.11, etc.)
      --commits <N>           Number of recent commits to check for non-noreply emails (default: 20)
      --strict                Exit non-zero if any findings are reported
  -h, --help                  Show this help message
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--include-placeholders)
			INCLUDE_PLACEHOLDERS=1
			shift
			;;
		--commits)
			COMMIT_LIMIT="${2:?missing value for $1}"
			shift 2
			;;
		--strict)
			STRICT=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			printf '[privacy-audit] ERROR: Unknown option: %s\n' "$1" >&2
			exit 2
			;;
	esac
done

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# Exclude this skill's own pattern definitions from content scans
PATHSPECS=(-- . ':!.agents/skills/privacy-secret-audit/')
FINDINGS=0

section() {
	printf '\n=== %s ===\n' "$1"
}

record_finding() {
	FINDINGS=$((FINDINGS + 1))
}

# 1. Secrets: forbidden filenames, private key headers, tokens, passwords
section "1. SECRETS (PRIVATE KEYS, API KEYS, TOKENS, PASSWORDS)"

FORBIDDEN_FILES="$(git ls-files | grep -iE '(private-key|\.key$|\.p12$|\.pfx$|mcp_config\.json$|(^|/)\.env($|\.)|(^|/)id_(rsa|ed25519|ecdsa)$)' || true)"
if [ -n "$FORBIDDEN_FILES" ]; then
	printf '[HIGH] Sensitive filename(s) tracked in git:\n%s\n' "$FORBIDDEN_FILES"
	record_finding
fi

# Redact matched line content for secret patterns (report file:line only)
SECRET_REGEX='BEGIN (RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|sk-[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]+|Authorization:[[:space:]]*(Bearer|Basic|Token)[[:space:]]+[^[:space:]"$]+|(password|passwd)[[:space:]]*[:=][[:space:]]*["'\'']?[^[:space:]"'\''$]+'
SECRET_HITS="$(git grep -n -I -E "$SECRET_REGEX" "${PATHSPECS[@]}" | cut -d: -f1,2 | sort -u || true)"
if [ -n "$SECRET_HITS" ]; then
	printf '[HIGH] Potential secret pattern(s) detected (values redacted):\n'
	while IFS= read -r hit; do
		[ -n "$hit" ] && printf '  - %s\n' "$hit"
	done <<< "$SECRET_HITS"
	record_finding
fi

# Non-empty, non-placeholder Control D resolver IDs in tracked files
CD_UID_HITS="$(git grep -n -I -E "cd_uid[[:space:]]+['\"][^'\"]+['\"]" "${PATHSPECS[@]}" | grep -vE "YOUR_RESOLVER_ID|abc123def4" || true)"
if [ -n "$CD_UID_HITS" ]; then
	printf '[HIGH] Non-placeholder Control D cd_uid detected (values redacted):\n'
	printf '%s\n' "$CD_UID_HITS" | cut -d: -f1,2 | sed 's/^/  - /'
	record_finding
fi

if [ "$FINDINGS" -eq 0 ]; then
	printf 'Clean (no secrets detected in tracked files).\n'
fi

# 2. Sensitive network details: IPs, VLANs, hostnames, MACs
section "2. SENSITIVE NETWORK DETAILS (IPS, VLANS, HOSTNAMES, MACS)"
NET_FOUND=0

IPV4_HITS="$(git grep -n -I -E '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' "${PATHSPECS[@]}" || true)"
if [ "$INCLUDE_PLACEHOLDERS" -eq 0 ] && [ -n "$IPV4_HITS" ]; then
	IPV4_HITS="$(printf '%s\n' "$IPV4_HITS" | grep -vE '192\.168\.1\.1|0\.0\.0\.0|127\.0\.0\.1|76\.76\.2\.11|255\.255\.255\.|PKG_VERSION|OPENWRT_VERSION|ctrld-1\.5\.|go-1\.' || true)"
fi
if [ -n "$IPV4_HITS" ]; then
	printf '[REVIEW] IPv4 address(es) found:\n%s\n' "$IPV4_HITS"
	NET_FOUND=1
	record_finding
fi

IPV6_HITS="$(git grep -n -I -iE '\b(fe80|fc[0-9a-f]{2}|fd[0-9a-f]{2}):[0-9a-f:]+' "${PATHSPECS[@]}" || true)"
if [ -n "$IPV6_HITS" ]; then
	printf '[REVIEW] Private/link-local IPv6 address(es) found:\n%s\n' "$IPV6_HITS"
	NET_FOUND=1
	record_finding
fi

VLAN_HITS="$(git grep -n -I -iE '\bvlan[._-]?[0-9]+\b|\b(eth|br-lan|wan|lan)[0-9]*\.[0-9]+\b|option[[:space:]]+vid[[:space:]]' "${PATHSPECS[@]}" || true)"
if [ -n "$VLAN_HITS" ]; then
	printf '[REVIEW] VLAN / tagged interface reference(s) found:\n%s\n' "$VLAN_HITS"
	NET_FOUND=1
	record_finding
fi

HOST_HITS="$(git grep -n -I -iE '[a-zA-Z0-9_-]+\.(lan|local|home|internal|corp|home\.arpa)\b' "${PATHSPECS[@]}" || true)"
if [ -n "$HOST_HITS" ]; then
	printf '[REVIEW] Internal hostname(s) found:\n%s\n' "$HOST_HITS"
	NET_FOUND=1
	record_finding
fi

MAC_HITS="$(git grep -n -I -E '\b([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b' "${PATHSPECS[@]}" || true)"
if [ -n "$MAC_HITS" ]; then
	printf '[REVIEW] MAC address(es) found:\n%s\n' "$MAC_HITS"
	NET_FOUND=1
	record_finding
fi

if [ "$NET_FOUND" -eq 0 ]; then
	printf 'Clean (no non-placeholder network details detected).\n'
fi

# 3. Personal details: emails, local user home paths, social account URLs/IDs
section "3. PERSONAL DETAILS (USERNAMES, SOCIAL ACCOUNTS, EMAILS)"
PII_FOUND=0

EMAIL_HITS="$(git grep -n -I -E '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "${PATHSPECS[@]}" || true)"
if [ "$INCLUDE_PLACEHOLDERS" -eq 0 ] && [ -n "$EMAIL_HITS" ]; then
	EMAIL_HITS="$(printf '%s\n' "$EMAIL_HITS" | grep -vF "$ALLOWED_EMAIL" | grep -vE 'example\.(com|org|net)|users\.noreply\.github\.com|root@192\.168\.1\.1' || true)"
fi
if [ -n "$EMAIL_HITS" ]; then
	printf '[REVIEW] Email address(es) found:\n%s\n' "$EMAIL_HITS"
	PII_FOUND=1
	record_finding
fi

HOME_HITS="$(git grep -n -I -E '(/home/|/Users/|C:\\Users\\)[A-Za-z0-9._-]+' "${PATHSPECS[@]}" || true)"
if [ -n "$HOME_HITS" ]; then
	printf '[REVIEW] Local user home path(s) found:\n%s\n' "$HOME_HITS"
	PII_FOUND=1
	record_finding
fi

SOCIAL_HITS="$(git grep -n -I -iE '(twitter\.com|x\.com|linkedin\.com/in|instagram\.com|facebook\.com|reddit\.com/u/|t\.me/|bsky\.app/profile|discord\.gg/)[A-Za-z0-9._-]+' "${PATHSPECS[@]}" || true)"
if [ -n "$SOCIAL_HITS" ]; then
	printf '[REVIEW] Social account link(s) found:\n%s\n' "$SOCIAL_HITS"
	PII_FOUND=1
	record_finding
fi

if [ "$PII_FOUND" -eq 0 ]; then
	printf 'Clean (no personal emails, home paths, or social IDs detected).\n'
fi

# 4. Git commit author/committer metadata
section "4. GIT COMMIT METADATA (LAST ${COMMIT_LIMIT} COMMITS)"
BAD_COMMITS="$(git log -n "$COMMIT_LIMIT" --format='%h %an <%ae> | %cn <%ce> | %s' | grep -vF "<${ALLOWED_EMAIL}>" || true)"
if [ -n "$BAD_COMMITS" ]; then
	printf '[REVIEW] Commit(s) not using %s:\n%s\n' "$ALLOWED_EMAIL" "$BAD_COMMITS"
	record_finding
else
	printf 'Clean (all checked commits use %s).\n' "$ALLOWED_EMAIL"
fi

printf '\nAudit complete: %d category finding(s).\n' "$FINDINGS"
if [ "$STRICT" -eq 1 ] && [ "$FINDINGS" -gt 0 ]; then
	exit 1
fi
