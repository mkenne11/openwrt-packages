# Project Assumptions & Constraints

## Target Environment
- Targets **OpenWrt 25.12+** using **`apk` v3** (`.apk` packages, `packages.adb`, ECDSA P-256 signing)—do not use `opkg` conventions.

## Packaging Constraints
- All network services must ship **disabled by default** (`option enabled '0'`).
- Every package `Makefile` must include an `SPDX-License-Identifier` header and a pinned `PKG_HASH` / `PKG_MIRROR_HASH`.
- Bump `PKG_RELEASE` whenever packaged files change.

## Security & Hygiene
- Never commit `keys/private-key.pem`, `.agents/plugins/github/mcp_config.json`, or personal email addresses (use `MJ <12181805+mkenne11@users.noreply.github.com>`).
- Run `make check` after modifying any shell script or init file.

## OpenWrt Packaging Guidelines

When developing, modifying, or reviewing OpenWrt packages in this repository, use the following official OpenWrt documentation as references for requirements and best practices:

- [Creating packages](https://openwrt.org/docs/guide-developer/packages)
- [Package policies](https://openwrt.org/docs/guide-developer/package-policies)
- [Overview](https://openwrt.org/docs/guide-developer/overview)
- [Single package](https://openwrt.org/docs/guide-developer/toolchain/single.package)
- [Feeds](https://openwrt.org/docs/guide-developer/feeds)
- [Dependencies](https://openwrt.org/docs/guide-developer/dependencies)