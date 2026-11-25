# OpenWrt 25.12+ APK v3 Package Feed

> [!WARNING]
> This is a personal OpenWRT package feed. It has only been tested on router target I use.
> Use at your own risk.

Custom OpenWrt package feed targeting **OpenWrt 25.12 and newer** (using Alpine's **`apk` v3** package manager, `.apk` packages, `packages.adb` repository indexes, and ECDSA NIST P-256 PEM signing keys).

This repository works both as:
1. A **hosted APK v3 binary repository** (published via GitHub Pages) that OpenWrt 25.12+ routers can add directly to `/etc/apk/repositories.d/`.
2. A standard **OpenWrt source feed** (`<category>/<package>/Makefile`) that OpenWrt Buildroot and SDK users can add to `feeds.conf`.

---

## Available Packages

| Package | Category | Description | Documentation |
| :--- | :--- | :--- | :--- |
| `ctrld` | `net` | Control D multi-protocol DNS forwarding proxy (DoH/DoT/DoQ/DoH3) with UCI & `procd` integration | [net/ctrld/README.md](net/ctrld/README.md) |

---

## Repository Layout

```text
.
├── net/
│   └── ctrld/
│       ├── Makefile               # OpenWrt 25.12+ Go package definition (golang-package.mk)
│       ├── README.md              # Package-specific usage & UCI documentation
│       ├── files/
│       │   ├── ctrld.config       # Default UCI config (/etc/config/ctrld)
│       │   ├── ctrld.init         # OpenWrt procd service script (/etc/init.d/ctrld)
│       │   └── ctrld.toml         # Default template (/usr/share/ctrld/ctrld.toml.default)
│       └── scripts/
│           ├── install-openwrt.sh # Push, verify, install & configure ctrld via SSH
│           ├── router-install.sh  # Standalone POSIX sh installer for OpenWrt 25.12+ routers
│           └── update-version.sh  # Pin latest/specific Control-D-Inc/ctrld release + SHA-256
├── keys/
│   └── public-key.pem             # ECDSA P-256 public key for verifying signed APK v3 packages
├── scripts/
│   └── build-apk.sh               # Build .apk + packages.adb via SDK feed registration
├── .github/workflows/
│   ├── ci.yml                     # PR/push syntax, lint & SDK feed compilation checks
│   └── publish-feed.yml           # Multi-arch build, signing & GitHub Pages APK v3 feed deploy
├── Makefile                       # Convenience wrapper targets
└── LICENSE                        # GPL-2.0-only (packaging definitions & scripts)
```

---

## 1. Install Packages on an OpenWrt 25.12+ Router (Hosted APK v3 Feed)

Replace `<OWNER>` and `<REPO>` with your GitHub username and repository name (and adjust `25.12` if targeting a newer OpenWrt release series):

```sh
# 1. Check your router's APK architecture (e.g. aarch64_cortex-a53, x86_64, mipsel_24kc)
ARCH="$(apk print-arch)"
echo "Detected architecture: $ARCH"

# 2. Install the feed's ECDSA P-256 public signing key
mkdir -p /etc/apk/keys
uclient-fetch -qO /etc/apk/keys/custom-feed.pem \
  "https://<OWNER>.github.io/<REPO>/public-key.pem"

# 3. Register the APK v3 repository index
mkdir -p /etc/apk/repositories.d
echo "https://<OWNER>.github.io/<REPO>/25.12/${ARCH}/packages.adb" \
  > /etc/apk/repositories.d/custom-feed.list

# 4. Update package indexes and install
apk update
apk add ctrld
```

### Supported Targets & Architecture (CI Matrix)

This feed targets MediaTek Filogic and MT7622 devices (both share the `aarch64_cortex-a53` OpenWrt package architecture):

| OpenWrt Target | OpenWrt Architecture (`apk print-arch`) | Example Devices |
| :--- | :--- | :--- |
| `mediatek/filogic` | `aarch64_cortex-a53` | GL.iNet Flint 2 (MT6000), OpenWrt One, Banana Pi BPi-R3/R4, Asus TUF-AX4200 |
| `mediatek/mt7622` | `aarch64_cortex-a53` | Linksys E8450 / Belkin RT3200, Xiaomi Redmi Router AX6S, Banana Pi BPi-R64 |

---

## 2. Use as an OpenWrt Source Feed (`feeds.conf`)

To compile packages directly inside an OpenWrt 25.12+ Buildroot or SDK:

```text
# Add to feeds.conf (pin to openwrt-25.12 branch when available)
src-git custom https://github.com/<OWNER>/<REPO>.git;openwrt-25.12
```

Then update and install the feed:

```bash
./scripts/feeds update packages custom
./scripts/feeds install -p packages golang
./scripts/feeds install -a -p custom
make menuconfig
```

---

## 3. Build Locally

`scripts/build-apk.sh` registers this repository into the OpenWrt SDK via `src-link`, compiles selected (or all) feed packages, and writes architecture-indexed APK v3 outputs to `dist/<series>/<arch>/`.

### Option A: Docker OpenWrt 25.12 SDK (Recommended)

```bash
# Build all feed packages for MediaTek Filogic (aarch64_cortex-a53)
make build TARGET=mediatek/filogic

# Build and sign with ECDSA NIST P-256 keypair (keys/private-key.pem)
make build-signed TARGET=mediatek/filogic
```

### Option B: Native OpenWrt 25.12 SDK (Linux / WSL2 without Docker)

Requires `curl`, `tar`, `zstd`, `make`, `gcc`, `g++`, `git`, `python3`:

```bash
make build-sdk TARGET=mediatek/filogic
# If your host has slow/broken IPv6 DNS resolution:
make build-sdk TARGET=mediatek/filogic IPV4=1
```

### Build Outputs

Artifacts are written to `dist/<openwrt-series>/<arch>/` (for example, `dist/25.12/aarch64_cortex-a53/`):
- `<pkg>-<version>-r<release>.apk` — OpenWrt 25.12+ APK v3 package
- `packages.adb` — APK v3 repository index covering all built packages
- `SHA256SUMS` — SHA-256 checksums
- `public-key.pem` — ECDSA public key (present when signed)

---

## 4. Publishing the Feed on GitHub

1. **Configure signing secret**: Generate an ECDSA NIST P-256 private key (`openssl ecparam -name prime256v1 -genkey -noout -out keys/private-key.pem`), store its contents in GitHub repository secret **`APK_SIGNING_PRIVATE_KEY`**, and commit only the matching public key at `keys/public-key.pem`. Never commit `keys/private-key.pem`.
2. **Enable GitHub Pages**: In repository **Settings -> Pages**, set **Source** to **GitHub Actions**.
3. **Branching**: Maintain a release branch per OpenWrt series (e.g. `openwrt-25.12`) alongside `main`.
4. **Publish**: Pushing package changes to `main` / `openwrt-*`, triggering **Publish OpenWrt APK v3 Feed** manually, or letting the weekly schedule run will build, sign, index, and deploy the repository to GitHub Pages.

---

## Adding New Packages

1. Create `<category>/<package-name>/Makefile` (e.g. `net/<pkg>/Makefile` or `utils/<pkg>/Makefile`) following [OpenWrt Package Policies](https://openwrt.org/docs/guide-developer/package-policies).
2. Run `make list-packages` and `make check` to verify discovery and syntax.
3. Build locally with `make build TARGET=mediatek/filogic PACKAGE=<package-name>`.
