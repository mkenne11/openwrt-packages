## Repository Layout

Detailed description of the repository layout and the purpose of each file and directory.

```text
.
├── net/
│   └── ctrld/
│       ├── Makefile               # OpenWrt 25.12+ Go package definition (golang-package.mk)
│       ├── README.md              # Package-specific usage & UCI documentation
│       ├── files/
│       │   ├── ctrld.config       # Default UCI config template (/usr/share/ctrld/ctrld.config.default)
│       │   ├── ctrld.init         # OpenWrt procd service script (/etc/init.d/ctrld)
│       │   ├── ctrld.toml         # Default template (/usr/share/ctrld/ctrld.toml.default)
│       │   └── ctrld.uci-defaults # Seeds /etc/config/ctrld on install if absent (/etc/uci-defaults/99-ctrld)
│       └── scripts/
│           ├── install-openwrt.sh # Push, verify, install & configure ctrld via SSH
│           ├── router-install.sh  # Standalone POSIX sh installer for OpenWrt 25.12+ routers
│           └── update-version.sh  # Pin latest/specific Control-D-Inc/ctrld release + SHA-256
├── keys/
│   └── public-key.pem             # ECDSA P-256 public key for verifying signed APK v3 packages
├── scripts/
│   ├── build-apk.sh               # Build .apk + packages.adb via SDK feed registration
│   └── merge-feed.sh              # Merge prior published APKs, prune old versions & re-sign packages.adb
├── .github/workflows/
│   ├── ci.yml                     # PR/push syntax, lint & SDK feed compilation checks
│   └── publish-feed.yml           # Multi-arch build, signing & GitHub Pages APK v3 feed deploy
├── Makefile                       # Convenience wrapper targets
└── LICENSE                        # GPL-2.0-only (packaging definitions & scripts)
```