#!/bin/sh
set -e

# ==============================================================================
# AmneziaWG Switch Pro — Автоматический установщик для OpenWrt (в один клик)
# Репозиторий: https://github.com/Y3KOV/luci-app-awg-switch
# ==============================================================================

echo "=========================================================="
echo "   AmneziaWG Switch Pro — Установка в 1 клик для OpenWrt  "
echo "=========================================================="

# 1. Проверка окружения
if ! command -v opkg >/dev/null 2>&1; then
    echo "[!] Ошибка: opkg не найден. Поддерживается только OpenWrt."
    exit 1
fi

TARGET=$(ubus call system board 2>/dev/null | jsonfilter -e '@.release.target' | cut -d '/' -f 1)
SUBTARGET=$(ubus call system board 2>/dev/null | jsonfilter -e '@.release.target' | cut -d '/' -f 2)
VERSION=$(ubus call system board 2>/dev/null | jsonfilter -e '@.release.version')
PKGARCH=$(ubus call system board 2>/dev/null | jsonfilter -e '@.release.arch')
[ -z "$PKGARCH" ] && PKGARCH=$(opkg print-architecture 2>/dev/null | awk 'BEGIN {max=0} {if ($3 > max) {max = $3; arch = $2}} END {print arch}')

echo "[*] Версия OpenWrt: $VERSION"
echo "[*] Платформа: $TARGET/$SUBTARGET"
echo "[*] Архитектура пакетов: $PKGARCH"

MAJOR_VER=$(echo "$VERSION" | cut -d '.' -f 1)
PATCH_VER=$(echo "$VERSION" | cut -d '.' -f 3)
LUCI_PKG="luci-proto-amneziawg"
if [ "$MAJOR_VER" -eq 23 ] 2>/dev/null && [ "$PATCH_VER" -lt 6 ] 2>/dev/null; then
    LUCI_PKG="luci-app-amneziawg"
fi

DL_DIR="/tmp/awg_installer"
mkdir -p "$DL_DIR"

download() {
    URL="$1"
    DEST="$2"
    rm -f "$DEST"

    if command -v curl >/dev/null 2>&1; then
        curl -k -fsSL --max-time 20 -A "Mozilla/5.0" "$URL" -o "$DEST" >/dev/null 2>&1 && [ -s "$DEST" ] && return 0
    fi
    if command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch --no-check-certificate --timeout=15 -qO "$DEST" "$URL" >/dev/null 2>&1 && [ -s "$DEST" ] && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget --no-check-certificate -T 15 -qO "$DEST" "$URL" >/dev/null 2>&1 && [ -s "$DEST" ] && return 0
    fi
    return 1
}

# 2. Проверка и установка зависимостей AmneziaWG (2Grey для поддержки AWG 3.1)
POSTFIX="_v${VERSION}_${PKGARCH}_${TARGET}_${SUBTARGET}.ipk"
BASE_URL="https://github.com/2Grey/awg-openwrt/releases/download/v${VERSION}/"
MIRROR_URL="https://mirror.ghproxy.com/https://github.com/2Grey/awg-openwrt/releases/download/v${VERSION}/"

install_dep() {
    PKG_NAME="$1"
    FILE_NAME="${PKG_NAME}${POSTFIX}"

    if opkg list-installed 2>/dev/null | grep -q "^${PKG_NAME} "; then
        echo "[✓] $PKG_NAME уже установлен."
        return 0
    fi

    echo "[*] Загрузка и установка $PKG_NAME..."
    if download "${BASE_URL}${FILE_NAME}" "$DL_DIR/$FILE_NAME" || download "${MIRROR_URL}${FILE_NAME}" "$DL_DIR/$FILE_NAME"; then
        opkg install --force-overwrite "$DL_DIR/$FILE_NAME" || opkg install --force-depends "$DL_DIR/$FILE_NAME"
        echo "[✓] $PKG_NAME успешно установлен."
    else
        echo "[!] Не удалось автоматически скачать $FILE_NAME."
        echo "    Рекомендуется установить его вручную или использовать официальный скрипт:"
        echo "    sh <(wget -O - https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/refs/heads/master/amneziawg-install.sh) -en"
    fi
}

echo ""
echo "=== 1. Проверка базовых компонентов AmneziaWG ==="
install_dep "kmod-amneziawg" || true
install_dep "amneziawg-tools" || true
install_dep "$LUCI_PKG" || true

echo ""
echo "=== 2. Установка плагина управления AmneziaWG Switch Pro ==="
IPK_FILE="luci-app-awg-switch_2.3.0-1_all.ipk"
REPO_RAW="https://raw.githubusercontent.com/Y3KOV/luci-app-awg-switch/main/release/${IPK_FILE}"
MIRROR_RAW="https://mirror.ghproxy.com/${REPO_RAW}"
FALLBACK_RAW="https://raw.githubusercontent.com/Y3KOV/luci-app-awg-switch/main/${IPK_FILE}"

if [ -f "/tmp/$IPK_FILE" ]; then
    echo "[*] Найден локальный пакет /tmp/$IPK_FILE, выполняем установку..."
    opkg install --force-overwrite "/tmp/$IPK_FILE"
elif download "$REPO_RAW" "$DL_DIR/$IPK_FILE" || download "$MIRROR_RAW" "$DL_DIR/$IPK_FILE" || download "$FALLBACK_RAW" "$DL_DIR/$IPK_FILE"; then
    echo "[*] Пакет плагина скачан, установка..."
    opkg install --force-overwrite "$DL_DIR/$IPK_FILE"
else
    echo "[!] Ошибка: Не удалось скачать $IPK_FILE."
    echo "    Вы можете собрать или скачать его вручную и положить в /tmp/$IPK_FILE"
    exit 1
fi

# Очистка
rm -rf "$DL_DIR"

# Перезапуск сервисов интерфейса
echo ""
echo "=== 3. Перезагрузка веб-сервисов LuCI ==="
/etc/init.d/rpcd reload >/dev/null 2>&1 || true
rm -rf /tmp/luci-*

echo "=========================================================="
echo "🎉 AmneziaWG Switch Pro успешно установлен!"
echo ""
echo "👉 Откройте панель LuCI в браузере:"
echo "   Меню: VPN -> AmneziaWG Switch Pro"
echo "=========================================================="

