# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2026 MJ

include $(TOPDIR)/rules.mk

PKG_NAME:=ctrld
PKG_VERSION:=1.5.11
PKG_RELEASE:=3

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/Control-D-Inc/ctrld/tar.gz/v$(PKG_VERSION)?
PKG_HASH:=2160a086b9113c5edb1df577390d7d4bc0a73b1ad856cc37483cef65889b63ba

PKG_MAINTAINER:=MJ <12181805+mkenne11@users.noreply.github.com>
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE

PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

GO_PKG:=github.com/Control-D-Inc/ctrld
GO_PKG_BUILD_PKG:=github.com/Control-D-Inc/ctrld/cmd/ctrld
GO_PKG_INSTALL_BIN_PATH:=/usr/sbin
GO_PKG_LDFLAGS_X:=$(GO_PKG)/cmd/cli.version=$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/ctrld
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=IP Addresses and Names
  TITLE:=Control D multi-protocol DNS forwarding proxy
  URL:=https://github.com/Control-D-Inc/ctrld
  DEPENDS:=$(GO_ARCH_DEPENDS) +ca-bundle
endef

define Package/ctrld/description
  ctrld is a highly configurable, multi-protocol DNS forwarding proxy
  developed by Control D. It supports DNS-over-HTTPS (DoH), DNS-over-TLS
  (DoT), DNS-over-QUIC (DoQ), and DoH3 with native OpenWrt router and
  dnsmasq integration.
endef

define Package/ctrld/conffiles
/etc/config/ctrld
/etc/controld/
endef

define Package/ctrld/install
	$(call GoPackage/Package/Install/Bin,$(1))

	$(INSTALL_DIR) $(1)/etc/controld
	$(INSTALL_DIR) $(1)/usr/share/ctrld
	$(INSTALL_DATA) $(CURDIR)/files/ctrld.toml $(1)/usr/share/ctrld/ctrld.toml.default
	$(INSTALL_DATA) $(CURDIR)/files/ctrld.config $(1)/usr/share/ctrld/ctrld.config.default
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) $(CURDIR)/files/ctrld.uci-defaults $(1)/etc/uci-defaults/99-ctrld
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(CURDIR)/files/ctrld.init $(1)/etc/init.d/ctrld
endef

$(eval $(call GoBinPackage,ctrld))
$(eval $(call BuildPackage,ctrld))
