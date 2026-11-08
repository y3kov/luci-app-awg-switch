include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-awg-switch
PKG_VERSION:=2.0.0
PKG_RELEASE:=1
PKG_ARCH:=all
PKG_LICENSE:=GPL-3.0

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-awg-switch
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for AmneziaWG VPN per-device policy routing
  DEPENDS:=+libc
  PKGARCH:=all
endef

define Package/luci-app-awg-switch/description
  Turnkey LuCI application for AmneziaWG VPN management on OpenWrt:
  - Per-device policy routing switch (toggle devices into VPN with 1 click)
  - Real-time tunnel status, handshake & traffic monitoring
  - Automatic missing modules installer (kmod, tools, luci-app/proto)
  - Safe DNS leak protection & local LAN subnet bypass
  - AmneziaWG .conf configuration importer
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/luci-app-awg-switch/install
	$(INSTALL_DIR) $(1)/usr/libexec/awgswitch
	$(INSTALL_BIN) ./src/data/usr/libexec/awgswitch/ctl.sh $(1)/usr/libexec/awgswitch/ctl.sh
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./src/data/usr/share/luci/menu.d/*.json $(1)/usr/share/luci/menu.d/
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./src/data/usr/share/rpcd/acl.d/*.json $(1)/usr/share/rpcd/acl.d/
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/awgswitch
	$(INSTALL_DATA) ./src/data/www/luci-static/resources/view/awgswitch/*.js $(1)/www/luci-static/resources/view/awgswitch/
endef

$(eval $(call BuildPackage,luci-app-awg-switch))

