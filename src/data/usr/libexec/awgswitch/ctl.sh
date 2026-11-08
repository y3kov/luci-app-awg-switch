#!/bin/sh

ACTION="$1"
ARG1="$2"
ARG2="$3"

CONF="/etc/awgswitch/current.conf"
BKP_DIR="/etc/awgswitch/backup"

get_val() {
    grep -i "^[[:space:]]*$1[[:space:]]*=" "$CONF" 2>/dev/null | head -n 1 | cut -d'=' -f2- | sed -e 's/[#;].*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' | tr -d ' \r\n'
}

get_val_raw() {
    # Сохраняет пробелы внутри значения (критично для тегов I1..I5: '<b 0x...><r ...>')
    grep -i "^[[:space:]]*$1[[:space:]]*=" "$CONF" 2>/dev/null | head -n 1 | cut -d'=' -f2- | sed -e 's/[#;].*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' | tr -d '\r\n'
}

clean_num() {
    # Извлечение первого числа / нижней границы диапазона: '25-35' -> '25'
    echo "$1" | sed -e 's/-.*//' | tr -cd '0-9'
}

get_wg_cmd() {
    if command -v awg >/dev/null 2>&1 || [ -x /usr/bin/awg ]; then
        echo "awg"
    elif command -v amneziawg >/dev/null 2>&1 || [ -x /usr/bin/amneziawg ]; then
        echo "amneziawg"
    else
        echo "awg"
    fi
}

clean_awg_uci() {
    # Удаляем все правила policy routing с lookup 100
    for R in $(uci show network 2>/dev/null | grep "\.lookup='100'" | cut -d'.' -f2); do
        uci -q delete network.$R
    done
    uci -q delete network.awg_route100
    uci -q delete network.awg_self
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
    nft flush set inet fw4 awg_vpn_devices 2>/dev/null || true
}

sync_vpn_devices() {
    # Синхронизация активных VPN-устройств с nftables set awg_vpn_devices
    nft flush set inet fw4 awg_vpn_devices 2>/dev/null || true
    for R in $(uci show network 2>/dev/null | grep "\.lookup='100'" | cut -d'.' -f2); do
        [ "$R" = "awg_self" ] && continue
        [ "$(uci -q get network.$R.enabled)" = "0" ] && continue
        SRC=$(uci -q get network.$R.src | cut -d'/' -f1)
        if [ -n "$SRC" ] && [ "${SRC#100.}" = "$SRC" ]; then
            nft add element inet fw4 awg_vpn_devices { "$SRC" } 2>/dev/null || true
        fi
    done
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

        LUCI_PKG_NAME="luci-proto-amneziawg"

        HAS_TOOLS=0
        if command -v awg >/dev/null 2>&1 || [ -x /usr/bin/awg ] || [ -x /bin/awg ] || \
           command -v amneziawg >/dev/null 2>&1 || [ -x /usr/bin/amneziawg ] || \
           opkg list-installed 2>/dev/null | grep -q "^amneziawg-tools "; then
            HAS_TOOLS=1
            [ ! -e /usr/bin/awg ] && [ -x /usr/bin/amneziawg ] && ln -sf /usr/bin/amneziawg /usr/bin/awg 2>/dev/null
        fi

        HAS_PROTO=0
        if [ -f /lib/netifd/proto/amneziawg.sh ]; then
            HAS_PROTO=1
        elif opkg list-installed 2>/dev/null | grep -q "^luci-proto-amneziawg "; then
            HAS_PROTO=1
        fi

        HAS_KMOD=0
        if [ -d /sys/module/amneziawg ]; then
            HAS_KMOD=1
        elif ls /lib/modules/*/amneziawg.ko >/dev/null 2>&1 || opkg list-installed 2>/dev/null | grep -q "^kmod-amneziawg "; then
            # Пытаемся подгрузить модуль ядра в память
            modprobe amneziawg >/dev/null 2>&1 || insmod $(ls /lib/modules/*/amneziawg.ko 2>/dev/null | head -n 1) >/dev/null 2>&1 || true
            [ -d /sys/module/amneziawg ] && HAS_KMOD=1
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
        RX_B=0
        TX_B=0
        ENDPOINT="-"

        if [ "$HAS_TOOLS" -eq 1 ] && ip link show awg0 >/dev/null 2>&1; then
            WG_UP=1
            WG_BIN=$(get_wg_cmd)
            DUMP=$($WG_BIN show awg0 dump 2>/dev/null | tail -n +2 | head -n 1)
            if [ -n "$DUMP" ]; then
                EP=$(echo "$DUMP" | awk '{print $3}')
                HS_TS=$(echo "$DUMP" | awk '{print $5}')
                RX_B=$(echo "$DUMP" | awk '{print $6}')
                TX_B=$(echo "$DUMP" | awk '{print $7}')
                [ -z "$RX_B" ] && RX_B=0
                [ -z "$TX_B" ] && TX_B=0
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

        printf '{"pkg_installed":%d,"missing_pkgs":"%s","has_curl":%d,"if_exists":%d,"if_disabled":%d,"wg_up":%d,"endpoint":"%s","handshake":"%s","rx":"%s","tx":"%s","rx_bytes":%s,"tx_bytes":%s,"backup_time":"%s","version":"%s","target":"%s","subtarget":"%s","arch":"%s"}\n' \
            "$PKG_OK" "$MISSING" "$HAS_CURL" "$IF_EXISTS" "$IF_DISABLED" "$WG_UP" "$ENDPOINT" "$HANDSHAKE" "$RX" "$TX" "${RX_B:-0}" "${TX_B:-0}" "$BKP_TIME" "$VERSION" "$TARGET" "$SUBTARGET" "$PKGARCH"
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

        LUCI_PKG_NAME="luci-proto-amneziawg"

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
        if [ -f /lib/netifd/proto/amneziawg.sh ] && ( opkg list-installed 2>/dev/null | grep -q "^luci-proto-amneziawg " || [ -f /www/luci-static/resources/protocol/amneziawg.js ] ); then
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
            [ "$DOWNLOADED" -eq 0 ] && echo "[!] Прямое скачивание $PROTO_PKG не удалось."
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
        S3=$(get_val "S3")
        S4=$(get_val "S4")
        HPK=$(get_val "HeaderProtectionKey")
        CPA=$(get_val "ContentPaddingAddition")
        RAT=$(get_val "RekeyAfterTime")
        RT=$(get_val "RekeyTimeout")
        REJ=$(get_val "RejectAfterTime")
        KAT=$(get_val "KeepaliveTimeout")
        MHA=$(get_val "MaxHandshakeAttempts")
        RTRAIL=$(get_val "RandomTrailers")
        DCOOK=$(get_val "DisableCookies")

        I1=$(get_val_raw "I1")
        I2=$(get_val_raw "I2")
        I3=$(get_val_raw "I3")
        I4=$(get_val_raw "I4")
        I5=$(get_val_raw "I5")

        PUB_KEY=$(get_val "PublicKey")
        PSK=$(get_val "PresharedKey")
        MTU=$(get_val "MTU")
        LISTEN_PORT=$(get_val "ListenPort")
        FWMARK=$(get_val "FwMark")

        # Fallback: автоматическое извлечение параметров из комментария Keenetic CLI, если они отсутствуют в ключах:
        # Пример: "# Keenetic: interface Wireguard0 wireguard asc 5 10 80 964 230 1 2 3 4"
        if [ -z "$JC" ] || [ -z "$S1" ]; then
            KEENETIC_LINE=$(grep -i -E "wireguard[[:space:]]+asc[[:space:]]+[0-9]+" "$CONF" 2>/dev/null | head -n 1)
            if [ -n "$KEENETIC_LINE" ]; then
                ASC_PARTS=$(echo "$KEENETIC_LINE" | sed -e 's/.*wireguard[[:space:]]\+asc[[:space:]]\+//I')
                set -- $ASC_PARTS
                [ -z "$JC" ] && [ -n "$1" ] && JC="$1"
                [ -z "$JMIN" ] && [ -n "$2" ] && JMIN="$2"
                [ -z "$JMAX" ] && [ -n "$3" ] && JMAX="$3"
                [ -z "$S1" ] && [ -n "$4" ] && S1="$4"
                [ -z "$S2" ] && [ -n "$5" ] && S2="$5"
                [ -z "$H1" ] && [ -n "$6" ] && H1="$6"
                [ -z "$H2" ] && [ -n "$7" ] && H2="$7"
                [ -z "$H3" ] && [ -n "$8" ] && H3="$8"
                [ -z "$H4" ] && [ -n "$9" ] && H4="$9"
            fi
        fi

        # Нормализация чисел и диапазонов (например '25-35' -> '25')
        [ -n "$JC" ] && JC=$(clean_num "$JC")
        [ -n "$JMIN" ] && JMIN=$(clean_num "$JMIN")
        [ -n "$JMAX" ] && JMAX=$(clean_num "$JMAX")
        [ -n "$S1" ] && S1=$(clean_num "$S1")
        [ -n "$S2" ] && S2=$(clean_num "$S2")
        [ -n "$S3" ] && S3=$(clean_num "$S3")
        [ -n "$S4" ] && S4=$(clean_num "$S4")
        [ -n "$H1" ] && H1=$(clean_num "$H1")
        [ -n "$H2" ] && H2=$(clean_num "$H2")
        [ -n "$H3" ] && H3=$(clean_num "$H3")
        [ -n "$H4" ] && H4=$(clean_num "$H4")
        [ -n "$MTU" ] && MTU=$(clean_num "$MTU")
        [ -n "$LISTEN_PORT" ] && LISTEN_PORT=$(clean_num "$LISTEN_PORT")

        ENDPOINT=$(get_val "Endpoint")
        EP_PORT="${ENDPOINT##*:}"
        EP_HOST="${ENDPOINT%:*}"
        EP_HOST=$(echo "$EP_HOST" | tr -d '[]')
        EP_PORT=$(clean_num "$EP_PORT")

        [ -z "$PRIV_KEY" ] && { echo "[!] Ошибка: В секции [Interface] отсутствует PrivateKey"; exit 1; }
        [ -z "$PUB_KEY" ] && { echo "[!] Ошибка: В секции [Peer] отсутствует PublicKey"; exit 1; }
        [ -z "$EP_HOST" ] && { echo "[!] Ошибка: В секции [Peer] отсутствует Endpoint"; exit 1; }

        # Создаем свежую секцию network.awg0, удаляя старые параметры обфускации
        uci -q delete network.awg0
        uci set network.awg0=interface
        uci set network.awg0.proto='amneziawg'
        uci set network.awg0.private_key="$PRIV_KEY"
        uci set network.awg0.defaultroute='0'
        uci set network.awg0.peerdns='0'
        uci set network.awg0.ip4table='100'
        uci set network.awg0.disabled='0'
        [ -n "$MTU" ] && uci set network.awg0.mtu="$MTU"
        [ -n "$LISTEN_PORT" ] && uci set network.awg0.listen_port="$LISTEN_PORT"
        [ -n "$FWMARK" ] && uci set network.awg0.fwmark="$FWMARK"

        # Настройка IP адресов интерфейса
        RAW_ADDR=$(grep -i "^[[:space:]]*Address[[:space:]]*=" "$CONF" 2>/dev/null | head -n 1 | cut -d'=' -f2- | sed -e 's/[#;].*$//' | tr -d ' \r\n')
        uci -q delete network.awg0.addresses
        OLD_IFS="$IFS"
        IFS=','
        FIRST_IP=""
        for ADDR in $RAW_ADDR; do
            ADDR=$(echo "$ADDR" | tr -d ' ')
            [ -z "$ADDR" ] && continue
            case "$ADDR" in
                */*) ;;
                *) ADDR="${ADDR}/32" ;;
            esac
            [ -z "$FIRST_IP" ] && FIRST_IP="${ADDR%%/*}"
            uci add_list network.awg0.addresses="$ADDR"
        done
        IFS="$OLD_IFS"

        # Параметры маскировки AmneziaWG (v1/v2 / Keenetic ASC)
        [ -n "$JC" ] && uci set network.awg0.awg_jc="$JC"
        [ -n "$JMIN" ] && uci set network.awg0.awg_jmin="$JMIN"
        [ -n "$JMAX" ] && uci set network.awg0.awg_jmax="$JMAX"
        [ -n "$S1" ] && uci set network.awg0.awg_s1="$S1"
        [ -n "$S2" ] && uci set network.awg0.awg_s2="$S2"
        [ -n "$H1" ] && uci set network.awg0.awg_h1="$H1"
        [ -n "$H2" ] && uci set network.awg0.awg_h2="$H2"
        [ -n "$H3" ] && uci set network.awg0.awg_h3="$H3"
        [ -n "$H4" ] && uci set network.awg0.awg_h4="$H4"

        # Поддержка расширенных параметров (AmneziaWG 3.1)
        [ -n "$S3" ] && uci set network.awg0.awg_s3="$S3"
        [ -n "$S4" ] && uci set network.awg0.awg_s4="$S4"
        [ -n "$HPK" ] && uci set network.awg0.awg_header_protection_key="$HPK"
        [ -n "$CPA" ] && uci set network.awg0.awg_content_padding_addition="$CPA"
        [ -n "$RAT" ] && uci set network.awg0.awg_rekey_after_time="$RAT"
        [ -n "$RT" ] && uci set network.awg0.awg_rekey_timeout="$RT"
        [ -n "$REJ" ] && uci set network.awg0.awg_reject_after_time="$REJ"
        [ -n "$KAT" ] && uci set network.awg0.awg_keepalive_timeout="$KAT"
        [ -n "$MHA" ] && uci set network.awg0.awg_max_handshake_attempts="$MHA"
        [ -n "$RTRAIL" ] && uci set network.awg0.awg_random_trailers="$RTRAIL"
        [ -n "$DCOOK" ] && uci set network.awg0.awg_disable_cookies="$DCOOK"

        # Пакеты специальной сигнатуры (CPS: I1..I5)
        [ -n "$I1" ] && uci set network.awg0.awg_i1="$I1"
        [ -n "$I2" ] && uci set network.awg0.awg_i2="$I2"
        [ -n "$I3" ] && uci set network.awg0.awg_i3="$I3"
        [ -n "$I4" ] && uci set network.awg0.awg_i4="$I4"
        [ -n "$I5" ] && uci set network.awg0.awg_i5="$I5"

        # Настройка пира AmneziaWG
        while uci -q delete network.@amneziawg_awg0[0]; do :; done
        PEER=$(uci add network amneziawg_awg0)
        uci set network.$PEER=amneziawg_awg0
        uci set network.$PEER.name='awg0_client'
        uci set network.$PEER.description='awg0_peer'
        uci set network.$PEER.public_key="$PUB_KEY"
        [ -n "$PSK" ] && uci set network.$PEER.preshared_key="$PSK"
        uci set network.$PEER.endpoint_host="$EP_HOST"
        uci set network.$PEER.endpoint_port="$EP_PORT"

        RAW_PKA=$(get_val "PersistentKeepalive")
        PKA=$(echo "$RAW_PKA" | tr -cd '0-9-')
        [ -z "$PKA" ] && PKA="25"
        uci set network.$PEER.persistent_keepalive="$PKA"
        uci set network.$PEER.route_allowed_ips='1'

        RAW_ALLOWED=$(grep -i "^[[:space:]]*AllowedIPs[[:space:]]*=" "$CONF" 2>/dev/null | head -n 1 | cut -d'=' -f2- | sed -e 's/[#;].*$//' | tr -d '\r\n')
        uci -q delete network.$PEER.allowed_ips
        if [ -n "$RAW_ALLOWED" ]; then
            OLD_IFS="$IFS"
            IFS=','
            for AIP in $RAW_ALLOWED; do
                AIP=$(echo "$AIP" | tr -d ' ')
                [ -n "$AIP" ] && uci add_list network.$PEER.allowed_ips="$AIP"
            done
            IFS="$OLD_IFS"
        else
            uci add_list network.$PEER.allowed_ips='0.0.0.0/0'
        fi

        # DNS из конфига не инжектируем в интерфейс, чтобы не ломать локальный DoH/dnsmasq
        uci -q delete network.awg0.dns

        # Маршрут по умолчанию для таблицы маршрутизации 100
        uci -q delete network.awg_route100
        uci set network.awg_route100=route
        uci set network.awg_route100.interface='awg0'
        uci set network.awg_route100.target='0.0.0.0'
        uci set network.awg_route100.netmask='0.0.0.0'
        uci set network.awg_route100.table='100'

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

        # Маршрутизация трафика самого роутера через туннель при обращении с IP адреса awg0 (приоритет 95)
        if [ -n "$FIRST_IP" ]; then
            uci -q delete network.awg_self
            uci set network.awg_self=rule
            uci set network.awg_self.src="$FIRST_IP/32"
            uci set network.awg_self.lookup='100'
            uci set network.awg_self.priority='95'
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
            /etc/init.d/firewall reload >/dev/null 2>&1
        fi

        # Подгружаем модуль ядра (если еще не в памяти)
        if [ ! -d /sys/module/amneziawg ]; then
            modprobe amneziawg >/dev/null 2>&1 || insmod $(ls /lib/modules/*/amneziawg.ko 2>/dev/null | head -n 1) >/dev/null 2>&1 || true
        fi

        # Перезагружаем сетевой стек netifd
        /etc/init.d/network reload >/dev/null 2>&1
        sleep 2
        /sbin/ifup awg0 >/dev/null 2>&1
        ip route replace default dev awg0 table 100 2>/dev/null || true
        sync_vpn_devices
        echo "OK"
        ;;

    sync_vpn_devices)
        sync_vpn_devices
        echo "OK"
        ;;

    master_toggle)
        uci set network.awg0.disabled="$ARG1"
        for R in $(uci show network 2>/dev/null | grep "\.lookup='100'" | cut -d'.' -f2); do
            [ "$R" = "awg_self" ] && continue
            if [ "$ARG1" = "1" ]; then
                uci set network.$R.enabled='0'
            else
                uci set network.$R.enabled='1'
            fi
        done
        uci commit network
        if [ "$ARG1" = "1" ]; then
            /sbin/ifdown awg0
            nft flush set inet fw4 awg_vpn_devices 2>/dev/null || true
        else
            /sbin/ifup awg0
            ip route replace default dev awg0 table 100 2>/dev/null || true
            sync_vpn_devices
        fi
        /etc/init.d/network reload
        echo "OK"
        ;;

    toggle_ip)
        IP="$ARG1"
        ENABLE="$ARG2"
        RULE_NAME="awgrule_$(echo "$IP" | tr '.' '_')"

        # 1. Удаляем именованную секцию
        uci -q delete network.$RULE_NAME

        # 2. Удаляем любые анонимные правила для этого IP
        for R in $(uci show network 2>/dev/null | grep "\.src='${IP}/32'" | cut -d'.' -f2); do
            uci -q delete network.$R
        done

        # 3. Если включаем - создаем детерминированную именованную секцию
        if [ "$ENABLE" = "1" ]; then
            uci set network.$RULE_NAME=rule
            uci set network.$RULE_NAME.in='lan'
            uci set network.$RULE_NAME.src="${IP}/32"
            uci set network.$RULE_NAME.lookup='100'
            uci set network.$RULE_NAME.priority='100'
            uci set network.$RULE_NAME.enabled='1'
            uci set network.$RULE_NAME.comment="awgswitch_${IP}"
        fi
        uci commit network

        # 4. Всегда синхронизируем nftables set awg_vpn_devices с реальным состоянием UCI
        sync_vpn_devices

        # 5. Применяем правила маршрутизации ядра
        /etc/init.d/network reload >/dev/null 2>&1
        echo "OK"
        ;;

    toggle_all)
        ENABLE="$ARG1"
        for R in $(uci show network 2>/dev/null | grep "\.lookup='100'" | cut -d'.' -f2); do
            [ "$R" = "awg_self" ] && continue
            uci -q delete network.$R
        done

        if [ "$ENABLE" = "1" ]; then
            shift
            for IP in "$@"; do
                [ -z "$IP" ] && continue
                RULE_NAME="awgrule_$(echo "$IP" | tr '.' '_')"
                uci set network.$RULE_NAME=rule
                uci set network.$RULE_NAME.in='lan'
                uci set network.$RULE_NAME.src="${IP}/32"
                uci set network.$RULE_NAME.lookup='100'
                uci set network.$RULE_NAME.priority='100'
                uci set network.$RULE_NAME.enabled='1'
                uci set network.$RULE_NAME.comment="awgswitch_${IP}"
            done
        fi
        uci commit network
        sync_vpn_devices
        /etc/init.d/network reload >/dev/null 2>&1
        echo "OK"
        ;;

    reset_rules)
        # Сброс всех правил переключения устройств (все идут напрямую)
        for R in $(uci show network 2>/dev/null | grep "\.lookup='100'" | cut -d'.' -f2); do
            [ "$R" = "awg_self" ] && continue
            uci -q delete network.$R
        done
        uci commit network
        sync_vpn_devices
        /etc/init.d/network reload >/dev/null 2>&1
        echo "OK"
        ;;

    fix_dns)
        echo "=== Настройка безопасных DNS в dnsmasq ==="
        if ps | grep -v grep | grep -q https-dns-proxy; then
            echo "[+] Обнаружен активный DoH (https-dns-proxy). Сохранение привязки dnsmasq к 127.0.0.1#5053..."
            uci -q delete dhcp.@dnsmasq[0].server
            uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5053'
        else
            echo "Настройка Cloudflare (1.1.1.1, 1.0.0.1) и Google (8.8.8.8) в dnsmasq..."
            uci -q delete dhcp.@dnsmasq[0].server
            uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'
            uci add_list dhcp.@dnsmasq[0].server='1.0.0.1'
            uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'
        fi
        uci set dhcp.@dnsmasq[0].noresolv='1'
        uci commit dhcp
        /etc/init.d/dnsmasq restart
        echo "[+] DNS успешно применены!"
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
            diag)
                WG_BIN=$(get_wg_cmd)
                echo "=========================================================="
                echo "=== [1/6] Сетевой интерфейс awg0 и IP-адреса ==="
                echo "=========================================================="
                ip addr show awg0 2>&1 || echo "Интерфейс awg0 не поднят"
                echo ""
                echo "=========================================================="
                echo "=== [2/6] Параметры AmneziaWG в ядре ($WG_BIN show) ==="
                echo "=========================================================="
                $WG_BIN show awg0 2>&1 || echo "Команда $WG_BIN show вернула ошибку"
                echo ""
                echo "=========================================================="
                echo "=== [3/6] Политики маршрутизации устройств (ip rule) ==="
                echo "=========================================================="
                ip rule show
                echo ""
                echo "=========================================================="
                echo "=== [4/6] Таблица маршрутизации VPN (таблица 100) ==="
                echo "=========================================================="
                ip route show table 100
                echo ""
                echo "=========================================================="
                echo "=== [5/6] Статус интерфейса в netifd (ubus) ==="
                echo "=========================================================="
                ubus call network.interface.awg0 status 2>/dev/null | grep -E -A 10 '"up"|"route"|"inactive"' | head -n 30
                echo ""
                echo "=========================================================="
                echo "=== [6/6] Журнал ядра и сетевого стека ==="
                echo "=========================================================="
                dmesg | grep -E -i "amnezia|awg" | tail -n 8
                echo "--- netifd / amnezia logread ---"
                logread | grep -E -i "amnezia|awg|netifd" | tail -n 12
                ;;
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
                echo "--- Cloudflare / Anthropic trace через VPN (awg0, Хельсинки) ---"
                CLAUDE_IP=$(curl --interface awg0 -sS "https://dns.google/resolve?name=claude.ai" 2>/dev/null | grep -o '"data":"[0-9.]*"' | head -n 1 | cut -d'"' -f4)
                [ -z "$CLAUDE_IP" ] && CLAUDE_IP=$(nslookup claude.ai 1.1.1.1 2>/dev/null | grep -E '^Address:[[:space:]]+[0-9]+\.[0-9]+' | tail -n 1 | sed -e 's/.*[[:space:]]//')
                if [ -n "$CLAUDE_IP" ]; then
                    curl --interface awg0 --resolve "claude.ai:443:$CLAUDE_IP" -4 -sS --max-time 6 https://claude.ai/cdn-cgi/trace | grep -E 'ip=|loc=|colo=|tls=|http='
                else
                    curl --interface awg0 -4 -sS --max-time 6 https://claude.ai/cdn-cgi/trace | grep -E 'ip=|loc=|colo=|tls=|http='
                fi
                echo ""
                echo "--- HTTP-статус API Anthropic (api.anthropic.com) через VPN (awg0) ---"
                API_IP=$(curl --interface awg0 -sS "https://dns.google/resolve?name=api.anthropic.com" 2>/dev/null | grep -o '"data":"[0-9.]*"' | head -n 1 | cut -d'"' -f4)
                [ -z "$API_IP" ] && API_IP=$(nslookup api.anthropic.com 1.1.1.1 2>/dev/null | grep -E '^Address:[[:space:]]+[0-9]+\.[0-9]+' | tail -n 1 | sed -e 's/.*[[:space:]]//')
                if [ -n "$API_IP" ]; then
                    curl --interface awg0 --resolve "api.anthropic.com:443:$API_IP" -4 -sS -o /dev/null -w "HTTP: %{http_code} (Сервер Anthropic ответил: API доступен) | Время: %{time_total}s | IP: %{remote_ip}\n" --max-time 6 https://api.anthropic.com
                else
                    curl --interface awg0 -4 -sS -o /dev/null -w "HTTP: %{http_code} | Время: %{time_total}s | IP: %{remote_ip}\n" --max-time 6 https://api.anthropic.com
                fi
                echo "--- Для сравнения: тот же запрос НАПРЯМУЮ (WAN через GeoHide/Zapret) ---"
                curl -4 -sS -o /dev/null -w "HTTP: %{http_code} | Время: %{time_total}s | IP: %{remote_ip}\n" --max-time 6 https://api.anthropic.com
                ;;
            openai)
                echo "--- OpenAI (chatgpt.com) trace через VPN (awg0, Хельсинки) ---"
                CHATGPT_IP=$(curl --interface awg0 -sS "https://dns.google/resolve?name=chatgpt.com" 2>/dev/null | grep -o '"data":"[0-9.]*"' | head -n 1 | cut -d'"' -f4)
                [ -z "$CHATGPT_IP" ] && CHATGPT_IP=$(nslookup chatgpt.com 1.1.1.1 2>/dev/null | grep -E '^Address:[[:space:]]+[0-9]+\.[0-9]+' | tail -n 1 | sed -e 's/.*[[:space:]]//')
                if [ -n "$CHATGPT_IP" ]; then
                    curl --interface awg0 --resolve "chatgpt.com:443:$CHATGPT_IP" -4 -sS --max-time 6 https://chatgpt.com/cdn-cgi/trace | grep -E 'ip=|loc=|colo=|tls='
                else
                    curl --interface awg0 -4 -sS --max-time 6 https://chatgpt.com/cdn-cgi/trace | grep -E 'ip=|loc=|colo=|tls='
                fi
                echo ""
                echo "--- API OpenAI (api.openai.com) HTTP Code через VPN (awg0) ---"
                OPENAI_API_IP=$(curl --interface awg0 -sS "https://dns.google/resolve?name=api.openai.com" 2>/dev/null | grep -o '"data":"[0-9.]*"' | head -n 1 | cut -d'"' -f4)
                [ -z "$OPENAI_API_IP" ] && OPENAI_API_IP=$(nslookup api.openai.com 1.1.1.1 2>/dev/null | grep -E '^Address:[[:space:]]+[0-9]+\.[0-9]+' | tail -n 1 | sed -e 's/.*[[:space:]]//')
                if [ -n "$OPENAI_API_IP" ]; then
                    curl --interface awg0 --resolve "api.openai.com:443:$OPENAI_API_IP" -4 -sS -o /dev/null -w "HTTP: %{http_code} (Сервер OpenAI ответил: API доступен) | Время: %{time_total}s | IP: %{remote_ip}\n" --max-time 6 https://api.openai.com/v1/models
                else
                    curl --interface awg0 -4 -sS -o /dev/null -w "HTTP: %{http_code} | Время: %{time_total}s | IP: %{remote_ip}\n" --max-time 6 https://api.openai.com/v1/models
                fi
                echo "--- Для сравнения: тот же запрос НАПРЯМУЮ (WAN через GeoHide/Zapret) ---"
                curl -4 -sS -o /dev/null -w "HTTP: %{http_code} | Время: %{time_total}s | IP: %{remote_ip}\n" --max-time 6 https://api.openai.com/v1/models
                ;;
            youtube)
                echo "--- Тест доступности YouTube & Google Video через VPN (awg0) ---"
                curl --interface awg0 -4 -sS -o /dev/null -w "youtube.com -> HTTP: %{http_code} | Время: %{time_total}s | IP: %{remote_ip}\n" --max-time 6 https://www.youtube.com
                curl --interface awg0 -4 -sS -o /dev/null -w "googlevideo -> HTTP: %{http_code} | Время: %{time_total}s | IP: %{remote_ip}\n" --max-time 6 https://manifest.googlevideo.com
                ;;
            custom)
                CLEAN_DOM=$(echo "$ARG2" | sed -e 's|^https\?://||' -e 's|/.*$||')
                echo "--- Проверка домена: $CLEAN_DOM ---"
                echo "[1. DNS через роутер (GeoHide EU DoH)]:"
                nslookup "$CLEAN_DOM" 127.0.0.1 2>/dev/null | tail -n +3
                echo ""
                echo "[2. DNS через публичный Cloudflare (1.1.1.1 - как видят VPN-клиенты)]:"
                nslookup "$CLEAN_DOM" 1.1.1.1 2>/dev/null | tail -n +3
                echo ""
                CUSTOM_IP=$(nslookup "$CLEAN_DOM" 1.1.1.1 2>/dev/null | grep -E '^Address:[[:space:]]+[0-9]+\.[0-9]+' | tail -n 1 | sed -e 's/.*[[:space:]]//')
                echo "[Через VPN (awg0 - чистый европейский маршрут)]:"
                if [ -n "$CUSTOM_IP" ]; then
                    curl --interface awg0 --resolve "$CLEAN_DOM:443:$CUSTOM_IP" -4 -L -sS -o /dev/null -w "HTTP: %{http_code} | Время: %{time_total}s | IP: %{remote_ip}\n" --max-time 7 "https://$CLEAN_DOM"
                else
                    curl --interface awg0 -4 -L -sS -o /dev/null -w "HTTP: %{http_code} | Время: %{time_total}s | IP: %{remote_ip}\n" --max-time 7 "https://$CLEAN_DOM"
                fi
                echo "[Напрямую (WAN - через провайдера / GeoHide)]:"
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
