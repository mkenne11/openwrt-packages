TARGET ?= mediatek/filogic
MODE ?= docker
PACKAGE ?= all
OPENWRT_VERSION ?= 25.12.6
CTRLD_VERSION ?=
CTRLD_BRANCH ?=
SIGN_KEY ?=
REQUIRE_SIGNING ?=
IPV4 ?=
ROUTER ?=
CD_UID ?=
CONFIG_FILE ?=
APK_FILE ?=

.PHONY: help list-packages build build-signed build-sdk install update-version check clean

help:
	@echo "OpenWrt 25.12+ APK v3 Package Feed Builder"
	@echo "Supported TARGET values: mediatek/filogic (default), mediatek/mt7622"
	@echo ""
	@echo "Targets:"
	@echo "  make list-packages                               List packages in this OpenWrt feed"
	@echo "  make build [TARGET=mediatek/filogic]             Build .apk packages using Docker OpenWrt SDK"
	@echo "  make build-signed [TARGET=mediatek/mt7622]       Generate ECDSA key (if needed) & build signed .apk"
	@echo "  make build-sdk [TARGET=mediatek/filogic]         Build .apk using native OpenWrt $(OPENWRT_VERSION) SDK tarball"
	@echo "  make install ROUTER=root@192.168.1.1 CD_UID=...  Install built ctrld .apk onto OpenWrt 25.12+ router"
	@echo "  make update-version [CTRLD_VERSION=1.5.11]       Pin latest/given ctrld release & SHA-256 in net/ctrld/Makefile"
	@echo "  make check                                       Validate shell syntax, formatting & feed structure"
	@echo "  make clean                                       Remove dist/, public/, and .build/ directories"

list-packages:
	@find . -mindepth 3 -maxdepth 3 -name Makefile \
		-not -path './.*/*' -not -path './dist/*' -not -path './public/*' \
		-exec grep -lE 'call (BuildPackage|KernelPackage)' {} + \
		| sed -e 's|^\./||' -e 's|/Makefile$$||' | sort

build:
	./scripts/build-apk.sh \
		--mode "$(MODE)" \
		--target "$(TARGET)" \
		--package "$(PACKAGE)" \
		--openwrt-version "$(OPENWRT_VERSION)" \
		$(if $(CTRLD_VERSION),--ctrld-version "$(CTRLD_VERSION)") \
		$(if $(CTRLD_BRANCH),--ctrld-branch "$(CTRLD_BRANCH)") \
		$(if $(SIGN_KEY),--sign-key "$(SIGN_KEY)") \
		$(if $(REQUIRE_SIGNING),--require-signing) \
		$(if $(IPV4),--ipv4)

build-signed:
	./scripts/build-apk.sh \
		--mode "$(MODE)" \
		--target "$(TARGET)" \
		--package "$(PACKAGE)" \
		--openwrt-version "$(OPENWRT_VERSION)" \
		--generate-key \
		$(if $(CTRLD_VERSION),--ctrld-version "$(CTRLD_VERSION)") \
		$(if $(CTRLD_BRANCH),--ctrld-branch "$(CTRLD_BRANCH)") \
		$(if $(IPV4),--ipv4)

build-sdk:
	$(MAKE) build MODE=sdk TARGET="$(TARGET)" PACKAGE="$(PACKAGE)" OPENWRT_VERSION="$(OPENWRT_VERSION)" CTRLD_VERSION="$(CTRLD_VERSION)" CTRLD_BRANCH="$(CTRLD_BRANCH)" SIGN_KEY="$(SIGN_KEY)" REQUIRE_SIGNING="$(REQUIRE_SIGNING)" IPV4="$(IPV4)"

install:
	@test -n "$(ROUTER)" || { echo "ERROR: set ROUTER=root@192.168.1.1"; exit 1; }
	./net/ctrld/scripts/install-openwrt.sh \
		--host "$(ROUTER)" \
		$(if $(APK_FILE),--apk "$(APK_FILE)") \
		$(if $(CD_UID),--cd "$(CD_UID)") \
		$(if $(CONFIG_FILE),--config "$(CONFIG_FILE)")

update-version:
	./net/ctrld/scripts/update-version.sh $(CTRLD_VERSION)

check:
	bash -n scripts/build-apk.sh scripts/merge-feed.sh scripts/generate-pages.sh net/ctrld/scripts/install-openwrt.sh net/ctrld/scripts/update-version.sh .agents/skills/privacy-secret-audit/scripts/audit-tracked.sh
	sh -n net/ctrld/scripts/router-install.sh net/ctrld/files/ctrld.init net/ctrld/files/ctrld.uci-defaults
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck scripts/build-apk.sh scripts/merge-feed.sh scripts/generate-pages.sh net/ctrld/scripts/install-openwrt.sh net/ctrld/scripts/update-version.sh net/ctrld/scripts/router-install.sh .agents/skills/privacy-secret-audit/scripts/audit-tracked.sh; \
		shellcheck -s sh net/ctrld/files/ctrld.uci-defaults; \
		shellcheck -s sh -e SC2034,SC3043,SC2154 net/ctrld/files/ctrld.init; \
	fi
	@echo "All syntax checks passed."

clean:
	rm -rf dist public .build
