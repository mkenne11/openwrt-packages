#!/usr/bin/env bash
set -euo pipefail

PUBLIC_DIR=""

usage() {
	cat <<'EOF'
Generate a 3-level hierarchical static HTML index for the OpenWrt APK v3
GitHub Pages feed:
  1. <public-dir>/index.html                     - OpenWrt versions (major.minor)
  2. <public-dir>/<series>/index.html            - Target architectures
  3. <public-dir>/<series>/<arch>/index.html     - Detailed package list

Usage:
  scripts/generate-pages.sh --public-dir <dir>

Options:
      --public-dir <dir>  Root directory of the assembled GitHub Pages site (required)
  -h, --help              Show this help message
EOF
}

log() {
	printf '[generate-pages] %s\n' "$*"
}

die() {
	printf '[generate-pages] ERROR: %s\n' "$*" >&2
	exit 1
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

html_escape() {
	local s="$1"
	s="${s//&/&amp;}"
	s="${s//</&lt;}"
	s="${s//>/&gt;}"
	s="${s//\"/&quot;}"
	printf '%s' "$s"
}

write_html_head() {
	local title
	title="$(html_escape "$1")"
	cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>${title}</title>
  <style>
    body { font-family: system-ui, sans-serif; max-width: 860px; margin: 2rem auto; padding: 0 1rem; line-height: 1.5; }
    code { font-family: ui-monospace, monospace; }
    nav.breadcrumb { font-size: 0.9rem; color: #57606a; margin-bottom: 1rem; }
    nav.breadcrumb a { color: inherit; text-decoration: none; }
    nav.breadcrumb a:hover { text-decoration: underline; }
    ul { padding-left: 1.25rem; }
    li { margin: 0.35rem 0; }
    table { width: 100%; border-collapse: collapse; margin: 0.75rem 0 1.5rem; }
    th, td { text-align: left; padding: 0.5rem 0.75rem; border-bottom: 1px solid #d0d7de; }
    th { background: #f6f8fa; font-weight: 600; }
    td.num, th.num { text-align: right; white-space: nowrap; }
    td.date, th.date { white-space: nowrap; }
  </style>
</head>
<body>
HTML
}

write_html_foot() {
	cat <<'HTML'
</body>
</html>
HTML
}

while [ $# -gt 0 ]; do
	case "$1" in
		--public-dir)
			PUBLIC_DIR="${2:?missing value for $1}"
			shift 2
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

[ -n "$PUBLIC_DIR" ] || die "Missing required --public-dir"
[ -d "$PUBLIC_DIR" ] || die "Public directory not found: $PUBLIC_DIR"
PUBLIC_DIR="${PUBLIC_DIR%/}"

require_cmd find
require_cmd sort
require_cmd stat
require_cmd numfmt
require_cmd date

# Discover OpenWrt major.minor version directories (e.g. 25.12), newest first
mapfile -t SERIES_LIST < <(
	find "$PUBLIC_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
		| grep -E '^[0-9]+\.[0-9]+$' \
		| sort -V -r
)

[ "${#SERIES_LIST[@]}" -gt 0 ] || die "No OpenWrt major.minor directories found in ${PUBLIC_DIR}"

for series in "${SERIES_LIST[@]}"; do
	series_dir="${PUBLIC_DIR}/${series}"
	series_esc="$(html_escape "$series")"

	mapfile -t ARCH_LIST < <(
		find "$series_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
			| LC_ALL=C sort
	)

	# Level 3: Detailed package list per target architecture
	for arch in "${ARCH_LIST[@]}"; do
		arch_dir="${series_dir}/${arch}"
		arch_esc="$(html_escape "$arch")"

		{
			write_html_head "OpenWrt ${series} / ${arch} — APK v3 Package Feed"
			cat <<HTML
  <nav class="breadcrumb"><a href="../../">Feed</a> / <a href="../"><code>${series_esc}</code></a> / <code>${arch_esc}</code></nav>
  <h1>OpenWrt ${series_esc} &mdash; <code>${arch_esc}</code></h1>
  <p><a href="packages.adb">packages.adb</a> | <a href="SHA256SUMS">SHA256SUMS</a> | <a href="../../public-key.pem">public-key.pem</a></p>
  <table>
    <thead>
      <tr>
        <th>Package</th>
        <th class="num">Size</th>
        <th class="date">Build Date (UTC)</th>
      </tr>
    </thead>
    <tbody>
HTML
			while IFS= read -r apk_file; do
				[ -n "$apk_file" ] || continue
				apk_path="${arch_dir}/${apk_file}"
				apk_esc="$(html_escape "$apk_file")"
				apk_size="$(numfmt --to=iec-i --suffix=B "$(stat -c '%s' "$apk_path")")"
				apk_date="$(date -u -d "@$(stat -c '%Y' "$apk_path")" '+%Y-%m-%d %H:%M UTC')"
				printf '      <tr><td><a href="%s"><code>%s</code></a></td><td class="num">%s</td><td class="date">%s</td></tr>\n' \
					"$apk_esc" "$apk_esc" "$apk_size" "$apk_date"
			done < <(find "$arch_dir" -maxdepth 1 -type f -name '*.apk' -printf '%f\n' | sort -V -r)
			cat <<'HTML'
    </tbody>
  </table>
HTML
			write_html_foot
		} > "${arch_dir}/index.html"

		log "Generated ${arch_dir}/index.html"
	done

	# Level 2: Target architectures for this OpenWrt version
	{
		write_html_head "OpenWrt ${series} — APK v3 Package Feed"
		cat <<HTML
  <nav class="breadcrumb"><a href="../">Feed</a> / <code>${series_esc}</code></nav>
  <h1>OpenWrt ${series_esc} APK v3 Package Feed</h1>
  <p>Public signing key: <a href="../public-key.pem">public-key.pem</a></p>
  <h2>Target Architectures</h2>
  <ul>
HTML
		for arch in "${ARCH_LIST[@]}"; do
			arch_esc="$(html_escape "$arch")"
			printf '    <li><a href="%s/"><code>%s</code></a></li>\n' "$arch_esc" "$arch_esc"
		done
		cat <<'HTML'
  </ul>
HTML
		write_html_foot
	} > "${series_dir}/index.html"

	log "Generated ${series_dir}/index.html"
done

# Level 1: Top-level OpenWrt versions (major.minor)
{
	write_html_head "OpenWrt APK v3 Package Feed"
	cat <<'HTML'
  <h1>OpenWrt APK v3 Package Feed</h1>
  <p>Public signing key: <a href="public-key.pem">public-key.pem</a></p>
  <h2>OpenWrt Versions</h2>
  <ul>
HTML
	for series in "${SERIES_LIST[@]}"; do
		series_esc="$(html_escape "$series")"
		printf '    <li><a href="%s/"><code>%s</code></a></li>\n' "$series_esc" "$series_esc"
	done
	cat <<'HTML'
  </ul>
HTML
	write_html_foot
} > "${PUBLIC_DIR}/index.html"

log "Generated ${PUBLIC_DIR}/index.html"
