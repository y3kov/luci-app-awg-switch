#!/bin/sh

ACTION="$1"
ARG1="$2"
ARG2="$3"

CONF="/etc/awgswitch/current.conf"
BKP_DIR="/etc/awgswitch/backup"

get_val() {
    grep -i "^[[:space:]]*$1[[:space:]]*=" "$CONF" 2>/dev/null | head -n 1 | cut -d'=' -f2- | sed -e 's/[#;].*$//' | tr -d ' \r\n'
}

clean_awg_uci() {
    # Удаляем все правила policy routing с lookup 100
    while true; do
        RULE_ID=$(uci show network 2>/dev/null | grep "\.lookup='100'" | head -n 1 | cut -d'.' -f2)
        [ -z "$RULE_ID" ] && break
        uci -q delete network.$RULE_ID
    done
    uci -q delete network.awg_local_192
    uci -q delete network.awg_local_10
    uci -q delete network.awg_local_172
    while uci -q delete network.@amneziawg_awg0[0]; do :; done
    uci -q delete network.awg0
    uci commit network

    # Очищаем секции firewall для awg
    uci -q delete firewall.zone_awg
    uci -q delete firewall.fwd_lan_awg
    for Z in $(uci show firewall 2>/dev/null | grep "\.name='awg'" | cut -d'.' -f2); do
        uci -q delete firewall.$Z
    done
    for F in $(uci show firewall 2>/dev/null | grep "\.dest='awg'" | cut -d'.' -f2); do
        uci -q delete firewall.$F
    done
    uci commit firewall

    ip rule flush table 100 2>/dev/null
    ip route flush table 100 2>/dev/null
}

is_valid_archive() {
    F="$1"
    [ -f "$F" ] && [ -s "$F" ] || return 1
    # Проверка целостности tar/gzip
    if command -v gzip >/dev/null 2>&1; then
        gzip -t "$F" >/dev/null 2>&1 && return 0
    fi
    if command -v tar >/dev/null 2>&1; then
        tar -tzf "$F" >/dev/null 2>&1 && return 0
    fi
    # Отсекаем HTML страницы ошибок (504, 404, etc.)
    if head -n 3 "$F" 2>/dev/null | grep -E -i -q '<html|<!doctype|error|504|gateway'; then
        return 1
    fi
    return 0
}

download_file() {
    U="$1"
    D="$2"
    rm -f "$D"

    # 1. curl с флагом -f (не записывать ответ при ошибках HTTP 4xx/5xx)
    if command -v curl >/dev/null 2>&1; then
        curl -k -fsSL --max-time 15 -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" "$U" -o "$D" >/dev/null 2>&1
        is_valid_archive "$D" && return 0
        rm -f "$D"
    fi

    # 2. uclient-fetch (нативный клиент OpenWrt)
    if command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch --no-check-certificate --timeout=12 -qO "$D" "$U" >/dev/null 2>&1
        is_valid_archive "$D" && return 0
        rm -f "$D"
    fi

    # 3. wget
    if command -v wget >/dev/null 2>&1; then
        wget --no-check-certificate -T 12 -qO "$D" "$U" >/dev/null 2>&1
        is_valid_archive "$D" && return 0
        rm -f "$D"
    fi

    return 1
}

case "$ACTION" in
    status)
        VERSION=$(ubus call system board 2>/dev/null | jsonfilter -e '@.release.version')
        TARGET=$(ubus call system board 2>/dev/null | jsonfilter -e '@.release.target' | cut -d '/' -f 1)
        SUBTARGET=$(ubus call system board 2>/dev/null | jsonfilter -e '@.release.target' | cut -d '/' -f 2)
        PKGARCH=$(ubus call system board 2>/dev/null | jsonfilter -e '@.release.arch')
        [ -z "$PKGARCH" ] && PKGARCH=$(opkg print-architecture 2>/dev/null | awk 'BEGIN {max=0} {if ($3 > max) {max = $3; arch = $2}} END {print arch}')

        MAJOR_VER=$(echo "$VERSION" | cut -d '.' -f 1)
        PATCH_VER=$(echo "$VERSION" | cut -d '.' -f 3)
        LUCI_PKG_NAME="luci-proto-amneziawg"
        if [ "$MAJOR_VER" -eq 23 ] 2>/dev/null && [ "$PATCH_VER" -lt 6 ] 2>/dev/null; then
            LUCI_PKG_NAME="luci-app-amneziawg"
        fi

        HAS_TOOLS=0
        if command -v awg >/dev/null 2>&1 || [ -x /usr/bin/awg ] || [ -x /bin/awg ] || opkg list-installed 2>/dev/null | grep -q "^amneziawg-tools "; then
            HAS_TOOLS=1
        fi

        HAS_PROTO=0
        if [ -f /lib/netifd/proto/amneziawg.sh ] || opkg list-installed 2>/dev/null | grep -E -q "^(luci-proto-amneziawg|luci-app-amneziawg) "; then
            HAS_PROTO=1
        fi

        HAS_KMOD=0
        if [ -d /sys/module/amneziawg ] || ls /lib/modules/*/amneziawg.ko >/dev/null 2>&1 || opkg list-installed 2>/dev/null | grep -q "^kmod-amneziawg "; then
            HAS_KMOD=1
            [ ! -d /sys/module/amneziawg ] && modprobe amneziawg 2>/dev/null
        fi

        HAS_CURL=0; command -v curl >/dev/null 2>&1 && HAS_CURL=1

        PKG_OK=0
        [ "$HAS_TOOLS" -eq 1 ] && [ "$HAS_PROTO" -eq 1 ] && [ "$HAS_KMOD" -eq 1 ] && PKG_OK=1

        MISSING=""
        [ "$HAS_KMOD" -eq 0 ] && MISSING="${MISSING}kmod-amneziawg "
        [ "$HAS_TOOLS" -eq 0 ] && MISSING="${MISSING}amneziawg-tools "
        [ "$HAS_PROTO" -eq 0 ] && MISSING="${MISSING}${LUCI_PKG_NAME} "
        [ "$HAS_CURL" -eq 0 ] && MISSING="${MISSING}curl "
        MISSING=$(echo "$MISSING" | sed 's/ $//')

        BKP_TIME="Нет бэкапа"
        [ -f "$BKP_DIR/timestamp" ] && BKP_TIME=$(cat "$BKP_DIR/timestamp")

        IF_DISABLED=$(uci -q get network.awg0.disabled || echo "0")
        IF_EXISTS=0
        uci -q get network.awg0 >/dev/null 2>&1 && IF_EXISTS=1

        WG_UP=0
        HANDSHAKE="Никогда"
        RX="0 B"
        TX="0 B"
        ENDPOINT="-"

        if [ "$HAS_TOOLS" -eq 1 ] && ip link show awg0 >/dev/null 2>&1; then
            WG_UP=1
            DUMP=$(awg show awg0 dump 2>/dev/null | tail -n +2 | head -n 1)
            if [ -n "$DUMP" ]; then
                EP=$(echo "$DUMP" | awk '{print $3}')
                HS_TS=$(echo "$DUMP" | awk '{print $5}')
                RX_B=$(echo "$DUMP" | awk '{print $6}')
                TX_B=$(echo "$DUMP" | awk '{print $7}')
                ENDPOINT="$EP"
                if [ "$HS_TS" != "0" ] && [ -n "$HS_TS" ]; then
                    NOW=$(date +%s)
                    DIFF=$((NOW - HS_TS))
                    if [ "$DIFF" -ge 86400 ]; then
                        HANDSHAKE="$((DIFF / 86400)) дн. назад"
                    elif [ "$DIFF" -ge 3600 ]; then
                        HANDSHAKE="$((DIFF / 3600)) ч. назад"
                    elif [ "$DIFF" -ge 60 ]; then
                        HANDSHAKE="$((DIFF / 60)) мин. назад"
                    else
                        HANDSHAKE="${DIFF} сек. назад"
                    fi
                fi
                RX=$(awk -v b="$RX_B" 'BEGIN{if(b>1073741824)printf "%.2f GB",b/1073741824; else if(b>1048576)printf "%.2f MB",b/1048576; else if(b>1024)printf "%.1f KB",b/1024; else printf "%d B",b}')
                TX=$(awk -v b="$TX_B" 'BEGIN{if(b>1073741824)printf "%.2f GB",b/1073741824; else if(b>1048576)printf "%.2f MB",b/1048576; else if(b>1024)printf "%.1f KB",b/1024; else printf "%d B",b}')
            fi
        fi

        printf '{"pkg_installed":%d,"missing_pkgs":"%s","has_curl":%d,"if_exists":%d,"if_disabled":%d,"wg_up":%d,"endpoint":"%s","handshake":"%s","rx":"%s","tx":"%s","backup_time":"%s","version":"%s","target":"%s","subtarget":"%s","arch":"%s"}\n' \
            "$PKG_OK" "$MISSING" "$HAS_CURL" "$IF_EXISTS" "$IF_DISABLED" "$WG_UP" "$ENDPOINT" "$HANDSHAKE" "$RX" "$TX" "$BKP_TIME" "$VERSION" "$TARGET" "$SUBTARGET" "$PKGARCH"
        ;;

    start_install)
        # Проверяем, не выполняется ли уже установка
        if [ -f /tmp/awg_install.pid ] && kill -0 "$(cat /tmp/awg_install.pid 2>/dev/null)" 2>/dev/null; then
            echo '{"status":"running"}'
            exit 0
        fi

        echo "running" > /tmp/awg_install.status
        echo "[*] Инициализация процесса установки пакетов AmneziaWG..." > /tmp/awg_install.log

        # Полное отвязывание фонового процесса от rpcd pipes во избежание таймаутов LuCI XHR
        ( /usr/libexec/awgswitch/ctl.sh run_install </dev/null >/tmp/awg_install.log 2>&1 & echo $! > /tmp/awg_install.pid ) </dev/null >/dev/null 2>&1

        echo '{"status":"started"}'
        ;;

    install_status)
        STATUS="idle"
        [ -f /tmp/awg_install.status ] && STATUS=$(cat /tmp/awg_install.status 2>/dev/null | tr -d '\r\n')
        LOG=""
        [ -f /tmp/awg_install.log ] && LOG=$(tail -n 60 /tmp/awg_install.log 2>/dev/null)

        if [ "$STATUS" = "running" ] && [ -f /tmp/awg_install.pid ]; then
            PID=$(cat /tmp/awg_install.pid 2>/dev/null)
            if [ -n "$PID" ] && ! kill -0 "$PID" 2>/dev/null; then
                if command -v awg >/dev/null 2>&1 || [ -x /usr/bin/awg ] || opkg list-installed 2>/dev/null | grep -q "^amneziawg-tools "; then
                    STATUS="done"
                else
                    STATUS="error"
                fi
                echo "$STATUS" > /tmp/awg_install.status
            fi
        fi

        CLEAN_LOG=$(echo "$LOG" | awk '{gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); printf "%s\\n", $0}')
        printf '{"status":"%s","log":"%s"}\n' "$STATUS" "$CLEAN_LOG"
        ;;

    install_b64)
        PKG_NAME="$ARG1"
        B64_FILE="/tmp/awg_upload.b64"
        OUT_FILE="/tmp/$PKG_NAME"
        [ -z "$PKG_NAME" ] && { echo "Missing package name"; exit 1; }
        if [ -f "$B64_FILE" ]; then
            echo "[*] Декодирование загруженного пакета $PKG_NAME..."
            if command -v openssl >/dev/null 2>&1; then
                openssl base64 -d -A -in "$B64_FILE" -out "$OUT_FILE" 2>/dev/null || openssl base64 -d -in "$B64_FILE" -out "$OUT_FILE" 2>/dev/null
            elif command -v base64 >/dev/null 2>&1; then
                base64 -d "$B64_FILE" > "$OUT_FILE" 2>/dev/null
            fi
            rm -f "$B64_FILE"
            if is_valid_archive "$OUT_FILE"; then
                echo "[+] Пакет успешно декодирован, установка..."
                opkg install --force-overwrite "$OUT_FILE" 2>&1 || opkg install --force-depends "$OUT_FILE" 2>&1
                rm -f "$OUT_FILE"
                /etc/init.d/rpcd reload >/dev/null 2>&1
                echo "OK"
                exit 0
            else
                echo "[!] Ошибка: декодированный файл поврежден или не является gzip архивом."
                rm -f "$OUT_FILE"
                exit 1
            fi
        fi
        echo "Файл загрузки не найден"
        exit 1
        ;;

    run_install)
        echo "running" > /tmp/awg_install.status
        echo "=========================================================="
        echo "=== [1/5] Проверка системы и сбор информации об устройстве ==="
        echo "=========================================================="

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
        LUCI_PKG_NAME="luci-proto-amneziawg"
        if [ "$MAJOR_VER" -eq 23 ] 2>/dev/null && [ "$PATCH_VER" -lt 6 ] 2>/dev/null; then
            LUCI_PKG_NAME="luci-app-amneziawg"
        fi

        # 0. Проверяем локальные .ipk файлы в /tmp (если пользователь загрузил их вручную)
        LOCAL_IPKS=$(ls /tmp/amneziawg*.ipk /tmp/kmod-amneziawg*.ipk /tmp/luci-app-amneziawg*.ipk /tmp/luci-proto-amneziawg*.ipk 2>/dev/null)
        if [ -n "$LOCAL_IPKS" ]; then
            echo ""
            echo "[*] Обнаружены пакеты в /tmp, выполняем локальную установку..."
            for P in $LOCAL_IPKS; do
                echo "[+] Установка $P..."
                opkg install --force-overwrite "$P" 2>&1 || opkg install --force-depends "$P" 2>&1 || true
            done
        fi

        # Обновляем opkg если нет кэша
        if [ ! -d /var/opkg-lists ] || [ -z "$(ls -A /var/opkg-lists 2>/dev/null)" ]; then
            echo "[*] Проверка списков opkg..."
            opkg update 2>&1 || echo "[!] opkg update завершился с предупреждением (продолжаем)."
        fi

        if ! command -v curl >/dev/null 2>&1; then
            echo "[*] Установка curl и ca-bundle..."
            opkg install curl ca-bundle 2>&1 || true
        fi

        AWG_TMP="/tmp/awg_dl"
        mkdir -p "$AWG_TMP"

        REPOS="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v${VERSION}/ https://mirror.ghproxy.com/https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v${VERSION}/ https://github.com/2Grey/awg-openwrt/releases/download/v${VERSION}/"
        PKG_POSTFIX="_v${VERSION}_${PKGARCH}_${TARGET}_${SUBTARGET}.ipk"

        echo ""
        echo "=========================================================="
        echo "=== [2/5] Модуль ядра: kmod-amneziawg ==="
        echo "=========================================================="
        if [ -d /sys/module/amneziawg ] || ls /lib/modules/*/amneziawg.ko >/dev/null 2>&1 || opkg list-installed 2>/dev/null | grep -q "^kmod-amneziawg "; then
            echo "[✓] kmod-amneziawg уже установлен."
        else
            KMOD_PKG="kmod-amneziawg${PKG_POSTFIX}"
            DOWNLOADED=0
            for BASE_URL in $REPOS; do
                echo "[*] Скачивание ${BASE_URL}${KMOD_PKG}..."
                if download_file "${BASE_URL}${KMOD_PKG}" "$AWG_TMP/$KMOD_PKG"; then
                    echo "[+] Скачан $KMOD_PKG, установка..."
                    opkg install --force-overwrite "$AWG_TMP/$KMOD_PKG" 2>&1 || opkg install --force-depends "$AWG_TMP/$KMOD_PKG" 2>&1
                    DOWNLOADED=1
                    break
                fi
            done
            [ "$DOWNLOADED" -eq 0 ] && echo "[!] Не удалось скачать $KMOD_PKG напрямую из релизов."
        fi

        echo ""
        echo "=========================================================="
        echo "=== [3/5] Утилиты управления: amneziawg-tools ==="
        echo "=========================================================="
        if command -v awg >/dev/null 2>&1 || [ -x /usr/bin/awg ] || opkg list-installed 2>/dev/null | grep -q "^amneziawg-tools "; then
            echo "[✓] amneziawg-tools уже установлен."
        else
            TOOLS_PKG="amneziawg-tools${PKG_POSTFIX}"
            DOWNLOADED=0
            for BASE_URL in $REPOS; do
                echo "[*] Скачивание ${BASE_URL}${TOOLS_PKG}..."
                if download_file "${BASE_URL}${TOOLS_PKG}" "$AWG_TMP/$TOOLS_PKG"; then
                    echo "[+] Скачан $TOOLS_PKG, установка..."
                    opkg install --force-overwrite "$AWG_TMP/$TOOLS_PKG" 2>&1 || opkg install --force-depends "$AWG_TMP/$TOOLS_PKG" 2>&1
                    DOWNLOADED=1
                    break
                fi
            done
            [ "$DOWNLOADED" -eq 0 ] && echo "[!] Прямое скачивание $TOOLS_PKG не удалось (возможен 504 таймаут GitHub)."
        fi

        echo ""
        echo "=========================================================="
        echo "=== [4/5] Модуль интерфейса: $LUCI_PKG_NAME ==="
        echo "=========================================================="
        if [ -f /lib/netifd/proto/amneziawg.sh ] || opkg list-installed 2>/dev/null | grep -E -q "^(luci-proto-amneziawg|luci-app-amneziawg) "; then
            echo "[✓] Протокол amneziawg уже зарегистрирован в системе."
        else
            PROTO_PKG="${LUCI_PKG_NAME}${PKG_POSTFIX}"
            DOWNLOADED=0
            for BASE_URL in $REPOS; do
                echo "[*] Скачивание ${BASE_URL}${PROTO_PKG}..."
                if download_file "${BASE_URL}${PROTO_PKG}" "$AWG_TMP/$PROTO_PKG"; then
                    echo "[+] Установка $PROTO_PKG..."
                    opkg install --force-overwrite "$AWG_TMP/$PROTO_PKG" 2>&1 || opkg install --force-depends "$AWG_TMP/$PROTO_PKG" 2>&1
                    DOWNLOADED=1
                    break
                fi
            done
        fi

        # Если amneziawg-tools все еще не встал, пробуем официальный скрипт amneziawg-install.sh
        if ! command -v awg >/dev/null 2>&1 && [ ! -x /usr/bin/awg ] && ! opkg list-installed 2>/dev/null | grep -q "^amneziawg-tools "; then
            echo ""
            echo "[*] Запуск установщика amneziawg-install.sh..."
            SCRIPT_F="/tmp/amneziawg-install.sh"
            if download_file "https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/refs/heads/master/amneziawg-install.sh" "$SCRIPT_F" || \
               download_file "https://mirror.ghproxy.com/https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/refs/heads/master/amneziawg-install.sh" "$SCRIPT_F"; then
                chmod +x "$SCRIPT_F"
                sed -i 's/check_repo/true/g' "$SCRIPT_F" 2>/dev/null || true
                sed -i 's/exit 1/true/g' "$SCRIPT_F" 2>/dev/null || true
                sh "$SCRIPT_F" -en 2>&1 || true
            fi
        fi

        rm -rf "$AWG_TMP"

        echo ""
        echo "=========================================================="
        echo "=== [5/5] Загрузка ядра и мягкая перезагрузка служб ==="
        echo "=========================================================="
        modprobe amneziawg 2>/dev/null || true
        rm -rf /tmp/luci-*
        /etc/init.d/rpcd reload >/dev/null 2>&1
        /etc/init.d/network reload >/dev/null 2>&1

        # Итоговая проверка
        FINAL_TOOLS=0
        if command -v awg >/dev/null 2>&1 || [ -x /usr/bin/awg ] || [ -x /bin/awg ] || opkg list-installed 2>/dev/null | grep -q "^amneziawg-tools "; then
            FINAL_TOOLS=1
        fi

        echo ""
        if [ "$FINAL_TOOLS" -eq 1 ]; then
            echo "=========================================================="
            echo "[+] УСПЕШНО: Пакет amneziawg-tools установлен и активен!"
            echo "=========================================================="
            echo "done" > /tmp/awg_install.status
        else
            echo "=========================================================="
            echo "[!] Автоматическое скачивание заблокировано (ошибка 504 / таймаут GitHub)."
            echo ""
            echo "Для ручной установки без SSH:"
            echo "1. Скачайте пакеты на ваш ПК по ссылкам в веб-интерфейсе LuCI."
            echo "2. Выберите скачанный .ipk файл прямо внизу в форме 'Загрузка пакета',"
            echo "   или загрузите его через 'Система -> Программное обеспечение -> Загрузить пакет'."
            echo "3. Нажмите кнопку 'Установить' снова — он установится локально из /tmp!"
            echo "=========================================================="
            echo "error" > /tmp/awg_install.status
        fi
        ;;

    apply_conf)
        [ ! -f "$CONF" ] && { echo "Конфиг не найден: $CONF"; exit 1; }

        if [ ! -f /lib/netifd/proto/amneziawg.sh ] && ! opkg list-installed 2>/dev/null | grep -E -q "^(luci-proto-amneziawg|luci-app-amneziawg) "; then
            echo "[!] Ошибка: Пакет протокола AmneziaWG не установлен!"
            exit 1
        fi
        [ ! -d /sys/module/amneziawg ] && modprobe amneziawg 2>/dev/null

        PRIV_KEY=$(get_val "PrivateKey")
        JC=$(get_val "Jc")
        JMIN=$(get_val "Jmin")
        JMAX=$(get_val "Jmax")
        S1=$(get_val "S1")
        S2=$(get_val "S2")
        H1=$(get_val "H1")
        H2=$(get_val "H2")
        H3=$(get_val "H3")
        H4=$(get_val "H4")
        PUB_KEY=$(get_val "PublicKey")
        PSK=$(get_val "PresharedKey")
        MTU=$(get_val "MTU")

        ENDPOINT=$(get_val "Endpoint")
        EP_PORT="${ENDPOINT##*:}"
        EP_HOST="${ENDPOINT%:*}"
        EP_HOST=$(echo "$EP_HOST" | tr -d '[]')

        [ -z "$PRIV_KEY" ] && { echo "[!] Ошибка: В секции [Interface] отсутствует PrivateKey"; exit 1; }
        [ -z "$PUB_KEY" ] && { echo "[!] Ошибка: В секции [Peer] отсутствует PublicKey"; exit 1; }
        [ -z "$EP_HOST" ] && { echo "[!] Ошибка: В секции [Peer] отсутствует Endpoint"; exit 1; }

        uci -q delete network.awg0
        uci set network.awg0=interface
        uci set network.awg0.proto='amneziawg'
        uci set network.awg0.private_key="$PRIV_KEY"
        uci set network.awg0.defaultroute='0'
        uci set network.awg0.ip4table='100'
        uci set network.awg0.disabled='0'
        [ -n "$MTU" ] && uci set network.awg0.mtu="$MTU"

        # Настройка IP адресов интерфейса (с добавлением маски /32 при отсутствии)
        RAW_ADDR=$(grep -i "^[[:space:]]*Address[[:space:]]*=" "$CONF" 2>/dev/null | head -n 1 | cut -d'=' -f2- | sed -e 's/[#;].*$//' | tr -d ' \r\n')
        OLD_IFS="$IFS"
        IFS=','
        for ADDR in $RAW_ADDR; do
            [ -z "$ADDR" ] && continue
            case "$ADDR" in
                */*) ;;
                *) ADDR="$ADDR/32" ;;
            esac
            uci add_list network.awg0.addresses="$ADDR"
        done
        IFS="$OLD_IFS"

        # Параметры маскировки AmneziaWG
        [ -n "$JC" ] && uci set network.awg0.awg_jc="$JC"
        [ -n "$JMIN" ] && uci set network.awg0.awg_jmin="$JMIN"
        [ -n "$JMAX" ] && uci set network.awg0.awg_jmax="$JMAX"
        [ -n "$S1" ] && uci set network.awg0.awg_s1="$S1"
        [ -n "$S2" ] && uci set network.awg0.awg_s2="$S2"
        [ -n "$H1" ] && uci set network.awg0.awg_h1="$H1"
        [ -n "$H2" ] && uci set network.awg0.awg_h2="$H2"
        [ -n "$H3" ] && uci set network.awg0.awg_h3="$H3"
        [ -n "$H4" ] && uci set network.awg0.awg_h4="$H4"

        # Настройка пира AmneziaWG
        while uci -q delete network.@amneziawg_awg0[0]; do :; done
        PEER=$(uci add network amneziawg_awg0)
        uci set network.$PEER.public_key="$PUB_KEY"
        [ -n "$PSK" ] && uci set network.$PEER.preshared_key="$PSK"
        uci set network.$PEER.endpoint_host="$EP_HOST"
        uci set network.$PEER.endpoint_port="$EP_PORT"
        uci set network.$PEER.persistent_keepalive='25'
        uci set network.$PEER.route_allowed_ips='1'
        uci add_list network.$PEER.allowed_ips='0.0.0.0/0'

        # DNS из конфига (если задан)
        RAW_DNS=$(grep -i "^[[:space:]]*DNS[[:space:]]*=" "$CONF" 2>/dev/null | head -n 1 | cut -d'=' -f2- | sed -e 's/[#;].*$//' | tr -d ' \r\n')
        if [ -n "$RAW_DNS" ]; then
            OLD_IFS="$IFS"
            IFS=','
            for D in $RAW_DNS; do
                [ -n "$D" ] && uci add_list network.awg0.dns="$D"
            done
            IFS="$OLD_IFS"
        fi

        # Исключение локальных сетей (LAN/NAS/Router) из VPN туннеля (priorities 90-92)
        if ! uci -q get network.awg_local_192 >/dev/null; then
            uci set network.awg_local_192=rule
            uci set network.awg_local_192.dest='192.168.0.0/16'
            uci set network.awg_local_192.lookup='main'
            uci set network.awg_local_192.priority='90'
        fi
        if ! uci -q get network.awg_local_10 >/dev/null; then
            uci set network.awg_local_10=rule
            uci set network.awg_local_10.dest='10.0.0.0/8'
            uci set network.awg_local_10.lookup='main'
            uci set network.awg_local_10.priority='91'
        fi
        if ! uci -q get network.awg_local_172 >/dev/null; then
            uci set network.awg_local_172=rule
            uci set network.awg_local_172.dest='172.16.0.0/12'
            uci set network.awg_local_172.lookup='main'
            uci set network.awg_local_172.priority='92'
        fi

        uci commit network

        # Настройка Firewall зоны и форвардинга
        if ! uci -q get firewall.zone_awg >/dev/null && ! uci show firewall 2>/dev/null | grep -E "\.name='?awg'?" >/dev/null; then
            uci set firewall.zone_awg=zone
            uci set firewall.zone_awg.name='awg'
            uci set firewall.zone_awg.input='REJECT'
            uci set firewall.zone_awg.output='ACCEPT'
            uci set firewall.zone_awg.forward='REJECT'
            uci set firewall.zone_awg.masq='1'
            uci set firewall.zone_awg.mtu_fix='1'
            uci add_list firewall.zone_awg.network='awg0'

            uci set firewall.fwd_lan_awg=forwarding
            uci set firewall.fwd_lan_awg.src='lan'
            uci set firewall.fwd_lan_awg.dest='awg'
            uci commit firewall
            /etc/init.d/firewall reload
        fi

        /sbin/ifup awg0
        echo "OK"
        ;;

    master_toggle)
        uci set network.awg0.disabled="$ARG1"
        for R in $(uci show network 2>/dev/null | grep "\.lookup='100'" | cut -d'.' -f2); do
            if [ "$ARG1" = "1" ]; then
                uci set network.$R.enabled='0'
            else
                uci set network.$R.enabled='1'
            fi
        done
        uci commit network
        if [ "$ARG1" = "1" ]; then
            /sbin/ifdown awg0
        else
            /sbin/ifup awg0
        fi
        /etc/init.d/network reload
        echo "OK"
        ;;

    reset_rules)
        # Сброс всех правил переключения устройств (все идут напрямую)
        while true; do
            RULE_ID=$(uci show network 2>/dev/null | grep "\.lookup='100'" | head -n 1 | cut -d'.' -f2)
            [ -z "$RULE_ID" ] && break
            uci -q delete network.$RULE_ID
        done
        uci commit network
        /etc/init.d/network reload
        echo "OK"
        ;;

    fix_dns)
        echo "=== Настройка безопасных DNS в dnsmasq ==="
        echo "Настройка Cloudflare (1.1.1.1, 1.0.0.1) и Google (8.8.8.8) в dnsmasq..."
        uci -q delete dhcp.@dnsmasq[0].server
        uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'
        uci add_list dhcp.@dnsmasq[0].server='1.0.0.1'
        uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'
        uci set dhcp.@dnsmasq[0].noresolv='1'
        uci commit dhcp
        /etc/init.d/dnsmasq restart
        echo "[+] Безопасные DNS успешно применены! Блокировки DNS провайдера устранены."
        ;;

    backup_now)
        mkdir -p "$BKP_DIR"
        cp /etc/config/network "$BKP_DIR/network.orig"
        cp /etc/config/firewall "$BKP_DIR/firewall.orig"
        cp /etc/config/dhcp "$BKP_DIR/dhcp.orig"
        date "+%Y-%m-%d %H:%M:%S" > "$BKP_DIR/timestamp"
        echo "Точка отката обновлена"
        ;;

    restore_backup)
        if [ -f "$BKP_DIR/network.orig" ]; then
            /sbin/ifdown awg0 2>/dev/null
            cp "$BKP_DIR/network.orig" /etc/config/network
            cp "$BKP_DIR/firewall.orig" /etc/config/firewall
            [ -f "$BKP_DIR/dhcp.orig" ] && cp "$BKP_DIR/dhcp.orig" /etc/config/dhcp
            /etc/init.d/network reload
            /etc/init.d/firewall reload
            echo "Конфигурация успешно восстановлена из бэкапа"
        else
            echo "Бэкап не найден!"
            exit 1
        fi
        ;;

    test_target)
        echo "=== ТЕСТ СОЕДИНЕНИЯ ($(date '+%H:%M:%S')) ==="
        if ! command -v curl >/dev/null 2>&1; then
            echo "[!] Утилита 'curl' не установлена на роутере."
            echo "    Нажмите кнопку 'Установить недостающие модули' вверху страницы."
            exit 1
        fi

        if ! ip link show awg0 >/dev/null 2>&1; then
            echo "[!] ВНИМАНИЕ: Интерфейс awg0 сейчас выключен. Тест через туннель невозможен."
        fi

        case "$ARG1" in
            ipinfo)
                echo "--- 1. Прямой выход провайдера (WAN) ---"
                curl -4 -sS --max-time 5 https://ipinfo.io/json | grep -E '"ip"|"country"|"org"|"city"' | tr -d ',"'
                echo ""
                echo "--- 2. Выход через туннель (AmneziaWG awg0) ---"
                curl --interface awg0 -4 -sS --max-time 6 https://ipinfo.io/json | grep -E '"ip"|"country"|"org"|"city"' | tr -d ',"' || echo "Ошибка соединения через awg0"
                echo ""
                echo "--- 3. Проверка DNS-резолвера роутера ---"
                nslookup anthropic.com 127.0.0.1 2>/dev/null | tail -n +3
                ;;
            anthropic)
                echo "--- Cloudflare / Anthropic trace через VPN (awg0) ---"
                curl --interface awg0 -4 -sS --max-time 6 https://claude.ai/cdn-cgi/trace | grep -E 'ip=|loc=|colo=|tls=|http='
                echo ""
                echo "--- HTTP-статус API Anthropic (api.anthropic.com) через VPN ---"
                curl --interface awg0 -4 -sS -o /dev/null -w "HTTP: %{http_code} | Время: %{time_total}s | IP: %{remote_ip}\n" --max-time 6 https://api.anthropic.com
                echo "--- Для сравнения: тот же запрос НАПРЯМУЮ (WAN) ---"
                curl -4 -sS -o /dev/null -w "HTTP: %{http_code} | Время: %{time_total}s | IP: %{remote_ip}\n" --max-time 6 https://api.anthropic.com
                ;;
            openai)
                echo "--- OpenAI (chatgpt.com) trace через VPN (awg0) ---"
                curl --interface awg0 -4 -sS --max-time 6 https://chatgpt.com/cdn-cgi/trace | grep -E 'ip=|loc=|colo=|tls='
                echo ""
                echo "--- API OpenAI (api.openai.com) HTTP Code через VPN ---"
                curl --interface awg0 -4 -sS -o /dev/null -w "HTTP: %{http_code} | Время: %{time_total}s | IP: %{remote_ip}\n" --max-time 6 https://api.openai.com/v1/models
                ;;
            youtube)
                echo "--- Тест доступности YouTube & Google Video через VPN (awg0) ---"
                curl --interface awg0 -4 -sS -o /dev/null -w "youtube.com -> HTTP: %{http_code} | Время: %{time_total}s | IP: %{remote_ip}\n" --max-time 6 https://www.youtube.com
                curl --interface awg0 -4 -sS -o /dev/null -w "googlevideo -> HTTP: %{http_code} | Время: %{time_total}s | IP: %{remote_ip}\n" --max-time 6 https://manifest.googlevideo.com
                ;;
            custom)
                CLEAN_DOM=$(echo "$ARG2" | sed -e 's|^https\?://||' -e 's|/.*$||')
                echo "--- Проверка домена: $CLEAN_DOM ---"
                echo "[DNS Lookup]:"
                nslookup "$CLEAN_DOM" 127.0.0.1 2>/dev/null | tail -n +3
                echo ""
                echo "[Через VPN (awg0)]:"
                curl --interface awg0 -4 -L -sS -o /dev/null -w "HTTP: %{http_code} | Время: %{time_total}s | IP: %{remote_ip}\n" --max-time 7 "https://$CLEAN_DOM"
                echo "[Напрямую (WAN)]:"
                curl -4 -L -sS -o /dev/null -w "HTTP: %{http_code} | Время: %{time_total}s | IP: %{remote_ip}\n" --max-time 7 "https://$CLEAN_DOM"
                ;;
        esac
        ;;

    uninstall)
        /sbin/ifdown awg0 2>/dev/null
        if [ -f "$BKP_DIR/network.orig" ]; then
            cp "$BKP_DIR/network.orig" /etc/config/network
            cp "$BKP_DIR/firewall.orig" /etc/config/firewall
        else
            clean_awg_uci
        fi
        /etc/init.d/network reload
        /etc/init.d/firewall reload

        if [ "$ARG1" = "full_purge" ]; then
            opkg remove luci-proto-amneziawg luci-app-amneziawg amneziawg-tools kmod-amneziawg --force-removal-of-dependent-packages 2>/dev/null
            rm -rf /etc/awgswitch
        fi

        opkg remove luci-app-awg-switch 2>/dev/null
        rm -f /usr/share/luci/menu.d/luci-app-awg-switch.json
        rm -f /usr/share/rpcd/acl.d/luci-app-awg-switch.json
        rm -rf /www/luci-static/resources/view/awgswitch
        rm -rf /usr/libexec/awgswitch
        rm -rf /tmp/luci-*
        /etc/init.d/rpcd reload >/dev/null 2>&1
        echo "UNINSTALLED"
        ;;
esac
