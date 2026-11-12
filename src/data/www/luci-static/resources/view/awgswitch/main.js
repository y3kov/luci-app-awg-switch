'use strict';
'require view';
'require fs';
'require uci';
'require ui';
'require poll';

return view.extend({
    _installTimer: null,

    load: function() {
        return Promise.all([
            uci.load('network'),
            uci.load('dhcp'),
            fs.trimmed('/tmp/dhcp.leases').catch(function() { return ''; }),
            fs.read('/etc/awgswitch/current.conf').catch(function() { return ''; }),
            fs.exec('/usr/libexec/awgswitch/ctl.sh', ['status']).then(function(r) {
                try { return JSON.parse(r.stdout); } catch(e) { return {}; }
            }),
            fs.read('/proc/net/arp').catch(function() { return ''; }),
            fs.read('/etc/awgswitch/aliases.json').catch(function() { return '{}'; })
        ]);
    },

    render: function(data) {
        var leasesRaw = data[2] || '';
        var currentConf = data[3] || '';
        var st = data[4] || {};
        var arpRaw = data[5] || '';
        var aliases = {};
        try { aliases = JSON.parse(data[6] || '{}'); } catch(e) {}
        var self = this;

        poll.add(function() {
            return fs.exec('/usr/libexec/awgswitch/ctl.sh', ['status']).then(function(r) {
                try {
                    var s = JSON.parse(r.stdout);
                    var elPkg = document.getElementById('awg_live_pkg');
                    var elState = document.getElementById('awg_live_state');
                    var elHs = document.getElementById('awg_live_hs');
                    var elTraffic = document.getElementById('awg_live_traffic');
                    var elEp = document.getElementById('awg_live_ep');
                    var elAlert = document.getElementById('awg_waiting_alert');

                    if (elPkg) {
                        elPkg.innerHTML = s.pkg_installed
                            ? '<span style="color:#2ea043;font-weight:bold;">✅ Все модули активны</span>'
                            : '<span style="color:#d9534f;font-weight:bold;">⚠️ Отсутствуют: ' + (s.missing_pkgs || 'модули AmneziaWG') + '</span>';
                    }
                    if (elState) {
                        if (!s.wg_up) {
                            elState.innerHTML = '<span style="color:#888;font-weight:bold;">○ ОСТАНОВЛЕН (DOWN)</span>';
                        } else if (s.handshake === 'Никогда' || s.rx === '0 B' || s.rx_bytes === 0) {
                            elState.innerHTML = '<span style="color:#e6a23c;font-weight:bold;" title="Туннель поднят локально, но сервер не ответил на handshake">⚠️ ОЖИДАНИЕ СЕРВЕРА (0 B)</span>';
                        } else {
                            elState.innerHTML = '<span style="color:#2ea043;font-weight:bold;">● ПОДКЛЮЧЕН (ONLINE)</span>';
                        }
                    }
                    if (elAlert) {
                        elAlert.style.display = (s.wg_up && (s.handshake === 'Никогда' || s.rx === '0 B' || s.rx_bytes === 0)) ? 'block' : 'none';
                    }
                    if (elHs) elHs.textContent = s.handshake || '-';
                    if (elTraffic) elTraffic.textContent = '↓ ' + (s.rx || '0 B') + ' / ↑ ' + (s.tx || '0 B');
                    if (elEp) elEp.textContent = s.endpoint || '-';
                } catch(e) {}
            });
        }, 3);

        var devices = {};

        // 1. Устройства из DHCP Leases
        leasesRaw.split('\n').forEach(function(line) {
            var p = line.trim().split(/\s+/);
            if (p.length >= 4) {
                devices[p[2]] = { ip: p[2], mac: p[1].toUpperCase(), name: (p[3] !== '*') ? p[3] : 'Устройство (' + p[2] + ')' };
            }
        });

        var staticIpMap = {};
        // 2. Статические хосты из DHCP
        uci.sections('dhcp', 'host', function(s) {
            if (s.ip) {
                staticIpMap[s.ip] = true;
                devices[s.ip] = {
                    ip: s.ip,
                    mac: s.mac ? (Array.isArray(s.mac) ? s.mac[0] : s.mac).toUpperCase() : '-',
                    name: s.name || (devices[s.ip] ? devices[s.ip].name : 'Static (' + s.ip + ')')
                };
            }
        });

        // 3. Активные устройства из ARP
        arpRaw.split('\n').forEach(function(line) {
            var p = line.trim().split(/\s+/);
            if (p.length >= 6 && p[0].indexOf('.') !== -1 && p[3] !== '00:00:00:00:00:00') {
                var arpIp = p[0];
                var arpMac = p[3].toUpperCase();
                if (!devices[arpIp]) {
                    devices[arpIp] = { ip: arpIp, mac: arpMac, name: 'LAN-устройство (' + arpIp + ')' };
                } else if (devices[arpIp].mac === '-') {
                    devices[arpIp].mac = arpMac;
                }
            }
        });

        var rules = uci.sections('network', 'rule');
        var vpnEnabledMap = {};
        rules.forEach(function(r) {
            // Пропускаем служебное правило самого роутера и локальные исключения
            if (r['.name'] === 'awg_self' || (r['.name'] && r['.name'].indexOf('awg_local') === 0)) return;
            if (r.src && (r.src.indexOf('100.') === 0 || r.comment === 'awg_self')) return;
            if (r.lookup == '100' && r.src && r.enabled !== '0') {
                var ipOnly = r.src.split('/')[0];
                vpnEnabledMap[ipOnly] = r['.name'];
            }
        });

        var directMap = {};
        if (st.direct_ips) {
            st.direct_ips.split(',').forEach(function(dip) {
                var d = dip.trim();
                if (d) directMap[d] = true;
            });
        }

        // 4. Добавляем устройства, для которых уже есть правила (кроме внутренних адресов туннеля CGNAT)
        Object.keys(vpnEnabledMap).forEach(function(ip) {
            if (ip.indexOf('100.') === 0) return;
            if (!devices[ip]) {
                devices[ip] = { ip: ip, mac: '-', name: 'Вручную добавленный IP (' + ip + ')' };
            }
        });
        Object.keys(directMap).forEach(function(ip) {
            if (!devices[ip]) {
                devices[ip] = { ip: ip, mac: '-', name: 'Вручную добавленный IP (' + ip + ')' };
            }
        });

        this._currentDevices = devices;

        var isRandomMac = function(mac) {
            if (!mac || mac === '-' || mac.length < 2) return false;
            var c1 = mac.charAt(1).toUpperCase();
            return (c1 === '2' || c1 === '6' || c1 === 'A' || c1 === 'E');
        };

        var getVendorOrHint = function(mac, ip) {
            if (!mac || mac === '-') return '';
            var m = mac.toUpperCase();
            var prefix = m.substring(0, 8);
            if (prefix === 'C8:7F:54') return 'ASUSTeK (Этот ПК)';
            if (prefix === '00:D8:61') return 'Micro-Star MSI (DESKTOP-S0JQ192)';
            if (prefix === '3C:0B:4F') return 'Яндекс (Станция Макс)';
            if (prefix === 'D4:D2:D6') return 'FN-Link (ТВ / Smart-устройство)';
            if (prefix === 'B8:27:EB' || prefix === 'DC:A6:32' || prefix === 'E4:5F:01') return 'Raspberry Pi';
            if (prefix.indexOf('BC:D0:74') === 0 || prefix.indexOf('64:90:C1') === 0) return 'Xiaomi';
            if (prefix.indexOf('AC:C1:EE') === 0 || prefix.indexOf('50:01:D9') === 0) return 'Samsung';
            if (prefix.indexOf('28:6D:CD') === 0 || prefix.indexOf('A4:83:E7') === 0) return 'Apple';
            if (isRandomMac(m)) {
                return '📱 Смартфон / Планшет (Случайный MAC — IP может меняться)';
            }
            return '';
        };

        var rows = Object.keys(devices).sort().map(function(ip) {
            var dev = devices[ip];
            if (aliases[dev.ip]) {
                dev.name = aliases[dev.ip];
            } else if (aliases[dev.mac]) {
                dev.name = aliases[dev.mac];
            }

            var hint = getVendorOrHint(dev.mac, dev.ip);
            var isCurrentPc = (dev.ip === '192.168.1.195');
            var isStatic = !!staticIpMap[ip];
            var mode = vpnEnabledMap[ip] ? 'vpn' : (directMap[ip] ? 'direct' : 'standard');

            var modeBadge;
            if (mode === 'vpn') {
                modeBadge = E('span', { 'style': 'color:#2ea043; font-weight:bold;' }, '🚀 VPN (AmneziaWG)');
            } else if (mode === 'direct') {
                modeBadge = E('span', { 'style': 'color:#e6a23c; font-weight:bold;' }, '🌐 Без ничего (Чистый WAN)');
            } else {
                modeBadge = E('span', { 'style': 'color:#58a6ff; font-weight:bold;' }, '🛡 Zapret + GeoHide DoH');
            }

            var btnStyleBase = 'padding:4px 8px; font-size:12px;';

            return E('tr', { 'class': 'tr' }, [
                E('td', { 'class': 'td' }, [
                    E('div', { 'style': 'display:flex; align-items:center; gap:6px; flex-wrap:wrap;' }, [
                        E('strong', {}, dev.name),
                        E('button', {
                            'class': 'btn cbi-button cbi-button-neutral',
                            'style': 'padding: 1px 5px; font-size: 11px; line-height: 1.2;',
                            'title': 'Переименовать устройство',
                            'click': ui.createHandlerFn(self, 'handleRenameDevice', dev.ip, dev.name)
                        }, '✏️'),
                        isStatic
                            ? E('span', { 'style': 'background:#238636; color:#fff; padding:1px 5px; border-radius:3px; font-size:10px;', 'title': 'Закрепленный статический IP' }, '📌 Стат. IP')
                            : (dev.mac && dev.mac !== '-' ? E('button', {
                                'class': 'btn cbi-button cbi-button-neutral',
                                'style': 'padding: 1px 5px; font-size: 10px; line-height: 1.2;',
                                'title': 'Закрепить этот IP за MAC-адресом в DHCP',
                                'click': ui.createHandlerFn(self, 'handlePinDevice', dev.ip, dev.mac, dev.name)
                            }, '📌 Закрепить IP') : null)
                    ]),
                    hint ? E('div', { 'style': 'font-size:11px; color:#888; margin-top:2px;' }, [
                        E('span', {}, hint),
                        isCurrentPc ? E('span', { 'style': 'background:#1f6feb; color:#fff; padding:1px 5px; border-radius:3px; margin-left:6px; font-size:10px; font-weight:bold;' }, 'Этот ПК (Сессия Ассистента)') : null
                    ]) : (isCurrentPc ? E('div', { 'style': 'font-size:11px; margin-top:2px;' }, E('span', { 'style': 'background:#1f6feb; color:#fff; padding:1px 5px; border-radius:3px; font-size:10px; font-weight:bold;' }, 'Этот ПК (Сессия Ассистента)')) : null)
                ]),
                E('td', { 'class': 'td' }, dev.ip),
                E('td', { 'class': 'td' }, dev.mac),
                E('td', { 'class': 'td' }, modeBadge),
                E('td', { 'class': 'td' }, E('div', { 'style': 'display:flex; gap:4px; flex-wrap:wrap;' }, [
                    E('button', {
                        'class': mode === 'vpn' ? 'btn cbi-button cbi-button-apply' : 'btn cbi-button cbi-button-neutral',
                        'style': btnStyleBase + (mode === 'vpn' ? 'font-weight:bold;' : 'opacity:0.75;'),
                        'click': ui.createHandlerFn(self, 'handleSetMode', ip, 'vpn', mode)
                    }, '🚀 VPN'),
                    E('button', {
                        'class': mode === 'standard' ? 'btn cbi-button cbi-button-action' : 'btn cbi-button cbi-button-neutral',
                        'style': btnStyleBase + (mode === 'standard' ? 'font-weight:bold;' : 'opacity:0.75;'),
                        'click': ui.createHandlerFn(self, 'handleSetMode', ip, 'standard', mode)
                    }, '🛡 Zapret + DoH'),
                    E('button', {
                        'class': mode === 'direct' ? 'btn cbi-button cbi-button-reset' : 'btn cbi-button cbi-button-neutral',
                        'style': btnStyleBase + (mode === 'direct' ? 'font-weight:bold;' : 'opacity:0.75;'),
                        'click': ui.createHandlerFn(self, 'handleSetMode', ip, 'direct', mode)
                    }, '🌐 Без ничего')
                ]))
            ]);
        });

        var isMasterOff = (st.if_disabled === 1);

        return E('div', { 'class': 'cbi-map' }, [
            E('h2', {}, 'AmneziaWG Switch Pro — Управление, Мониторинг и Диагностика'),

            E('div', { 'class': 'cbi-section' }, [
                E('h3', {}, '1. Статус-монитор в реальном времени (обновление каждые 3 сек)'),
                E('div', { 'class': 'cbi-section-node', 'style': 'padding:12px;' }, [
                    E('div', { 'style': 'display:grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap:12px; margin-bottom:15px;' }, [
                        E('div', { 'style': 'padding:10px; border:1px solid #444; border-radius:6px;' }, [
                            E('div', { 'style': 'font-size:11px; color:#888;' }, 'МОДУЛИ AMNEZIAWG'),
                            E('div', { 'id': 'awg_live_pkg', 'style': 'font-size:14px; margin-top:4px; font-weight:bold;' },
                                st.pkg_installed
                                    ? E('span', { 'style': 'color:#2ea043;' }, '✅ Все модули активны')
                                    : E('span', { 'style': 'color:#d9534f;' }, '⚠️ Отсутствуют: ' + (st.missing_pkgs || 'модули AmneziaWG')))
                        ]),
                        E('div', { 'style': 'padding:10px; border:1px solid #444; border-radius:6px;' }, [
                            E('div', { 'style': 'font-size:11px; color:#888;' }, 'СОСТОЯНИЕ ТУННЕЛЯ (awg0)'),
                            E('div', { 'id': 'awg_live_state', 'style': 'font-size:14px; margin-top:4px;' },
                                (!st.wg_up)
                                    ? E('span', { 'style': 'color:#888; font-weight:bold;' }, '○ ОСТАНОВЛЕН (DOWN)')
                                    : ((st.handshake === 'Никогда' || st.rx === '0 B' || st.rx_bytes === 0)
                                        ? E('span', { 'style': 'color:#e6a23c; font-weight:bold;', 'title': 'Туннель запущен локально, но сервер не ответил на handshake' }, '⚠️ ОЖИДАНИЕ СЕРВЕРА (0 B)')
                                        : E('span', { 'style': 'color:#2ea043; font-weight:bold;' }, '● ПОДКЛЮЧЕН (ONLINE)')))
                        ]),
                        E('div', { 'style': 'padding:10px; border:1px solid #444; border-radius:6px;' }, [
                            E('div', { 'style': 'font-size:11px; color:#888;' }, 'ПОСЛЕДНИЙ HANDSHAKE'),
                            E('div', { 'id': 'awg_live_hs', 'style': 'font-size:14px; margin-top:4px; font-weight:bold;' }, st.handshake || '-')
                        ]),
                        E('div', { 'style': 'padding:10px; border:1px solid #444; border-radius:6px;' }, [
                            E('div', { 'style': 'font-size:11px; color:#888;' }, 'ТРАФИК ТУННЕЛЯ (RX / TX)'),
                            E('div', { 'id': 'awg_live_traffic', 'style': 'font-size:14px; margin-top:4px; font-weight:bold;' },
                                '↓ ' + (st.rx || '0 B') + ' / ↑ ' + (st.tx || '0 B'))
                        ]),
                        E('div', { 'style': 'padding:10px; border:1px solid #444; border-radius:6px;' }, [
                            E('div', { 'style': 'font-size:11px; color:#888;' }, 'ENDPOINT СЕРВЕРА'),
                            E('div', { 'id': 'awg_live_ep', 'style': 'font-size:14px; margin-top:4px;' }, st.endpoint || '-')
                        ])
                    ]),
                    E('div', { 'style': 'display:flex; gap:10px; flex-wrap:wrap; align-items:center;' }, [
                        E('button', {
                            'class': isMasterOff ? 'btn cbi-button cbi-button-apply' : 'btn cbi-button cbi-button-reset',
                            'click': ui.createHandlerFn(self, 'handleMasterToggle', isMasterOff ? '0' : '1')
                        }, isMasterOff ? '▶ Включить туннель AmneziaWG' : '⏸ Отключить туннель (все устройства в обычный режим)'),
                        E('button', {
                            'class': 'btn cbi-button cbi-button-action',
                            'click': ui.createHandlerFn(self, 'handleRestartTunnel')
                        }, '🔄 Перезапустить awg0'),
                        !st.pkg_installed ? E('button', {
                            'id': 'awg_btn_install',
                            'class': 'btn cbi-button cbi-button-action',
                            'click': ui.createHandlerFn(self, 'handleInstallPkg')
                        }, '⬇ Установить недостающие модули автоматически') : E('span'),
                        !st.pkg_installed ? E('button', {
                            'class': 'btn cbi-button cbi-button-save',
                            'click': ui.createHandlerFn(self, 'handleFixDns')
                        }, '🛡 Применить безопасные DNS (1.1.1.1)') : E('span')
                    ]),
                    E('div', { 'style': 'margin-top:10px; font-size:12px; color:#aaa; display:flex; gap:14px; flex-wrap:wrap;' }, [
                        E('span', {}, '🌐 DoH (GeoHide): ' + (st.doh_active ? '✅ Активен' : '⚠️ Не запущен')),
                        E('span', {}, '🛡 Zapret (DPI): ' + (st.zapret_active ? '✅ Активен' : '○ Не обнаружен')),
                        E('span', {}, '📡 DNS провайдера (для режима «Без ничего»): ' + (st.isp_dns || '1.1.1.1'))
                    ]),
                    E('div', {
                        'id': 'awg_waiting_alert',
                        'style': 'margin-top:14px; padding:12px; background:#2a2111; border:1px solid #e6a23c; border-radius:6px; font-size:12px; line-height:1.6; display:' + ((st.wg_up && (st.handshake === 'Никогда' || st.rx === '0 B' || st.rx_bytes === 0)) ? 'block' : 'none') + ';'
                    }, [
                        E('strong', { 'style': 'color:#e6a23c; font-size:13px;' }, '⚠️ Внимание: Интерфейс awg0 запущен, но входящий трафик от сервера равен 0 B (рукопожатие не завершено)'),
                        E('p', { 'style': 'margin:6px 0;' },
                            'Пакеты отправляются, но сервер пока не ответил. Возможные причины:'),
                        E('ul', { 'style': 'margin:6px 0 6px 20px;' }, [
                            E('li', {}, 'Сервер из вашего .conf файла недоступен или устарел (проверьте новый .conf от Amnezia).'),
                            E('li', {}, 'Конфиг активен на другом устройстве (телефоне или ПК). В WireGuard нельзя использовать одну сессию на двух устройствах одновременно.'),
                            E('li', {}, 'Провайдер или ТСПУ блокирует UDP-порт или адрес сервера.')
                        ])
                    ]),
                    !st.pkg_installed ? (function() {
                        var ver = st.version || '24.10.0';
                        var arch = st.arch || 'mipsel_24kc';
                        var tgt = st.target || 'ramips';
                        var subtgt = st.subtarget || 'mt7621';
                        var pfix = '_v' + ver + '_' + arch + '_' + tgt + '_' + subtgt + '.ipk';
                        var base = 'https://github.com/2Grey/awg-openwrt/releases/download/v' + ver + '/';
                        var kmodUrl = base + 'kmod-amneziawg' + pfix;
                        var toolsUrl = base + 'amneziawg-tools' + pfix;
                        var luciPkg = 'luci-proto-amneziawg';
                        var luciUrl = base + luciPkg + pfix;

                        return E('div', { 'style': 'margin-top:14px; padding:12px; background:#1e1e1e; border:1px solid #444; border-radius:6px; font-size:12px; line-height:1.6;' }, [
                            E('strong', { 'style': 'color:#e6a23c; font-size:13px;' }, '⚠️ Не удается скачать с GitHub автоматически (ошибка 504 / блокировка)?'),
                            E('p', { 'style': 'margin:6px 0;' }, [
                                'Если провайдер блокирует GitHub релизы, скачайте необходимые пакеты AmneziaWG 3.1 прямо на ваш компьютер:'
                            ]),
                            E('ul', { 'style': 'margin:6px 0 10px 20px;' }, [
                                E('li', {}, [
                                    E('a', { 'href': kmodUrl, 'target': '_blank', 'class': 'cbi-button-link', 'style': 'font-weight:bold; color:#58a6ff;' },
                                        '⬇ Скачать kmod-amneziawg' + pfix)
                                ]),
                                E('li', {}, [
                                    E('a', { 'href': toolsUrl, 'target': '_blank', 'class': 'cbi-button-link', 'style': 'font-weight:bold; color:#58a6ff;' },
                                        '⬇ Скачать amneziawg-tools' + pfix)
                                ]),
                                E('li', {}, [
                                    E('a', { 'href': luciUrl, 'target': '_blank', 'class': 'cbi-button-link', 'style': 'font-weight:bold; color:#58a6ff;' },
                                        '⬇ Скачать ' + luciPkg + pfix)
                                ])
                            ]),
                            E('div', { 'style': 'margin-top:10px; padding-top:10px; border-top:1px dashed #444;' }, [
                                E('strong', {}, '📁 Загрузить скачанный файл (.ipk) прямо через браузер:'),
                                E('div', { 'style': 'display:flex; gap:10px; align-items:center; margin-top:8px; flex-wrap:wrap;' }, [
                                    E('input', {
                                        'type': 'file',
                                        'id': 'awg_upload_input',
                                        'accept': '.ipk',
                                        'class': 'cbi-input-file'
                                    }),
                                    E('button', {
                                        'id': 'awg_btn_upload',
                                        'class': 'btn cbi-button cbi-button-apply',
                                        'click': ui.createHandlerFn(self, 'handleUploadIpk')
                                    }, '📤 Загрузить и установить на роутер')
                                ]),
                                E('div', { 'style': 'font-size:11px; color:#888; margin-top:6px;' },
                                    'Либо вы можете загрузить пакет через стандартное меню OpenWrt: «Система → Программное обеспечение → Загрузить пакет».')
                            ])
                        ]);
                    })() : E('span')
                ])
            ]),

            E('div', { 'class': 'cbi-section' }, [
                E('h3', {}, '2. Переключение устройств в VPN одной кнопкой'),
                E('div', { 'class': 'cbi-section-node', 'style': 'padding:10px 12px; margin-bottom:10px; display:flex; gap:10px; flex-wrap:wrap; align-items:center; justify-content:space-between;' }, [
                    E('div', { 'style': 'display:flex; gap:8px; flex-wrap:wrap;' }, [
                        E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': ui.createHandlerFn(self, 'handleToggleAll', true) }, '🚀 Направить ВСЕ устройства в VPN'),
                        E('button', { 'class': 'btn cbi-button cbi-button-reset', 'click': ui.createHandlerFn(self, 'handleToggleAll', false) }, '⏹ Снять ВСЕ устройства с VPN')
                    ]),
                    E('div', { 'style': 'display:flex; gap:8px; align-items:center;' }, [
                        E('input', {
                            'id': 'awg_custom_ip',
                            'type': 'text',
                            'class': 'cbi-input-text',
                            'style': 'max-width:180px;',
                            'placeholder': '192.168.1.55'
                        }),
                        E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': ui.createHandlerFn(self, 'handleAddCustomIp') }, '➕ Добавить IP')
                    ])
                ]),
                E('table', { 'class': 'table' }, [
                    E('tr', { 'class': 'tr table-titles' }, [
                        E('th', { 'class': 'th' }, 'Устройство'),
                        E('th', { 'class': 'th' }, 'IP-адрес'),
                        E('th', { 'class': 'th' }, 'MAC-адрес'),
                        E('th', { 'class': 'th' }, 'Текущий режим'),
                        E('th', { 'class': 'th' }, 'Управление')
                    ])
                ].concat(rows.length ? rows : [
                    E('tr', { 'class': 'tr' }, [
                        E('td', { 'class': 'td', 'colspan': 5, 'style': 'text-align:center; color:#888;' },
                            'Активных DHCP-клиентов не обнаружено. Подключите устройство к роутеру или добавьте статическую аренду DHCP.')
                    ])
                ]))
            ]),

            E('div', { 'class': 'cbi-section' }, [
                E('h3', {}, '3. Диагностика: IP, DNS и проверка доступности сервисов (Anthropic, OpenAI, YouTube)'),
                E('div', { 'class': 'cbi-section-node', 'style': 'padding:12px;' }, [
                    E('div', { 'style': 'display:flex; gap:8px; flex-wrap:wrap; margin-bottom:10px;' }, [
                        E('button', { 'class': 'btn cbi-button cbi-button-reset', 'click': ui.createHandlerFn(self, 'handleRunTest', 'diag', '') },
                            '🩺 Полная диагностика туннеля (Debug)'),
                        E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': ui.createHandlerFn(self, 'handleRunTest', 'ipinfo', '') },
                            '🌐 Сравнить IP / Гео / ASN (WAN vs VPN) + DNS'),
                        E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': ui.createHandlerFn(self, 'handleRunTest', 'anthropic', '') },
                            '🤖 Тест Anthropic / Claude (Trace & API)'),
                        E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': ui.createHandlerFn(self, 'handleRunTest', 'openai', '') },
                            '🧠 Тест OpenAI / ChatGPT'),
                        E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': ui.createHandlerFn(self, 'handleRunTest', 'youtube', '') },
                            '▶ Тест YouTube & Google Video'),
                        E('button', { 'class': 'btn cbi-button cbi-button-save', 'click': ui.createHandlerFn(self, 'handleFixDns') },
                            '🛡 Настроить чистый DNS (1.1.1.1 / 8.8.8.8)')
                    ]),
                    E('div', { 'style': 'display:flex; gap:8px; margin-bottom:10px; align-items:center;' }, [
                        E('input', {
                            'id': 'awg_custom_domain',
                            'type': 'text',
                            'class': 'cbi-input-text',
                            'style': 'max-width:320px;',
                            'placeholder': 'Введите домен (напр. claude.ai или rutracker.org)'
                        }),
                        E('button', { 'class': 'btn cbi-button cbi-button-save', 'click': ui.createHandlerFn(self, 'handleRunCustomTest') },
                            '🔍 Проверить домен')
                    ]),
                    E('pre', {
                        'id': 'awg_test_output',
                        'style': 'background:#111; color:#0f0; padding:12px; border-radius:6px; min-height:120px; font-family:monospace; font-size:12px; white-space:pre-wrap; max-height:360px; overflow-y:auto;'
                    }, 'Нажмите любую кнопку теста выше или запустите установку модулей...')
                ])
            ]),

            E('div', { 'class': 'cbi-section' }, [
                E('h3', {}, '4. Загрузка / смена конфигурации (.conf)'),
                E('div', { 'class': 'cbi-section-node', 'style': 'padding:12px;' }, [
                    E('textarea', {
                        'id': 'awg_conf_input',
                        'class': 'cbi-input-textarea',
                        'style': 'width:100%; height:150px; font-family:monospace; font-size:12px;',
                        'placeholder': '[Interface]\nPrivateKey = ...\nAddress = ...\n# Параметры AmneziaWG:\nJc = 4\nJmin = 40\nJmax = 70\nS1 = 15\nS2 = 39\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\n\n[Peer]\nPublicKey = ...\nEndpoint = ...'
                    }, currentConf),
                    E('div', { 'style': 'margin-top:10px;' }, [
                        E('button', {
                            'class': 'btn cbi-button cbi-button-save',
                            'click': ui.createHandlerFn(self, 'handleSetupConf')
                        }, '💾 Применить .conf и настроить туннель awg0')
                    ])
                ])
            ]),

            E('div', { 'class': 'cbi-section' }, [
                E('h3', {}, '5. Управление конфигурацией сети и резервные копии'),
                E('div', { 'class': 'cbi-section-node', 'style': 'padding:12px;' }, [
                    E('p', { 'style': 'margin-bottom:12px; color:#ccc;' }, [
                        'ℹ️ ', E('strong', {}, 'Резервная копия сети: '),
                        'Плагин автоматически сохраняет снимок файлов network, firewall и dhcp до внесения изменений. ',
                        'Дата текущего снимка: ', E('strong', { 'style': 'color:#2ea043;' }, st.backup_time || 'Нет')
                    ]),
                    E('div', { 'style': 'display:flex; gap:10px; flex-wrap:wrap; margin-bottom:15px;' }, [
                        E('button', {
                            'class': 'btn cbi-button cbi-button-apply',
                            'click': ui.createHandlerFn(self, 'handleResetRules')
                        }, '🔄 Сбросить правила VPN (все устройства напрямую)'),
                        E('button', {
                            'class': 'btn cbi-button cbi-button-save',
                            'click': ui.createHandlerFn(self, 'handleBackupNow')
                        }, '📸 Создать новую точку отката сети'),
                        E('button', {
                            'class': 'btn cbi-button cbi-button-reset',
                            'click': ui.createHandlerFn(self, 'handleRebootRouter')
                        }, '⚡ Перезагрузить роутер (reboot)')
                    ]),

                    E('details', { 'style': 'background:#222; border:1px solid #444; border-radius:6px; padding:10px;' }, [
                        E('summary', { 'style': 'cursor:pointer; font-weight:bold; color:#ff9800;' }, '⚠️ Дополнительно: Откат настроек сети и удаление плагина'),
                        E('div', { 'style': 'margin-top:12px; font-size:12px; line-height:1.6;' }, [
                            E('p', {}, 'Используйте эти действия только в случае необходимости вернуть сетевые настройки роутера в исходное состояние.'),
                            E('div', { 'style': 'display:flex; gap:10px; flex-wrap:wrap; margin-top:8px;' }, [
                                E('button', {
                                    'class': 'btn cbi-button cbi-button-action',
                                    'click': ui.createHandlerFn(self, 'handleRestoreBackup')
                                }, '⏪ Восстановить network и firewall из снимка'),
                                E('button', {
                                    'class': 'btn cbi-button cbi-button-reset',
                                    'click': ui.createHandlerFn(self, 'handleUninstall', 'switcher_only')
                                }, '🗑 Удалить плагин Switcher'),
                                E('button', {
                                    'class': 'btn cbi-button cbi-button-negative',
                                    'click': ui.createHandlerFn(self, 'handleUninstall', 'full_purge')
                                }, '☢ Полное удаление (Switcher + пакеты AmneziaWG)')
                            ])
                        ])
                    ])
                ])
            ])
        ]);
    },

    handleInstallPkg: function() {
        var btn = document.getElementById('awg_btn_install');
        var out = document.getElementById('awg_test_output');
        var self = this;

        if (btn) {
            btn.disabled = true;
            btn.textContent = '⏳ Идет установка...';
        }
        if (out) {
            out.textContent = '[ИНФО] Запуск фонового процесса установки пакетов AmneziaWG...\nПожалуйста, подождите, проверяются локальные пакеты и репозитории...';
            out.scrollIntoView({ behavior: 'smooth', block: 'center' });
        }

        if (this._installTimer) {
            clearInterval(this._installTimer);
            this._installTimer = null;
        }

        var pollLog = function() {
            fs.exec('/usr/libexec/awgswitch/ctl.sh', ['install_status']).then(function(r) {
                try {
                    var st = JSON.parse(r.stdout || '{}');
                    if (out && st.log) {
                        out.textContent = st.log;
                        out.scrollTop = out.scrollHeight;
                    }

                    if (st.status === 'done') {
                        if (self._installTimer) {
                            clearInterval(self._installTimer);
                            self._installTimer = null;
                        }
                        ui.addNotification(null, E('p', 'Все модули AmneziaWG успешно установлены!'), 'info');
                        if (btn) btn.textContent = '✅ Установка завершена';
                        setTimeout(function() { window.location.reload(); }, 2000);
                    } else if (st.status === 'error') {
                        if (self._installTimer) {
                            clearInterval(self._installTimer);
                            self._installTimer = null;
                        }
                        ui.addNotification(null, E('p', 'Не удалось автоматически скачать пакеты с GitHub (ошибка 504). См. лог ниже.'), 'danger');
                        if (btn) {
                            btn.disabled = false;
                            btn.textContent = '🔄 Повторить попытку';
                        }
                    }
                } catch(e) {}
            });
        };

        // Стартуем опрос каждые 1.5 сек
        self._installTimer = setInterval(pollLog, 1500);

        return fs.exec('/usr/libexec/awgswitch/ctl.sh', ['start_install']).then(function() {
            pollLog();
        }).catch(function(err) {
            pollLog();
        });
    },

    handleResetRules: function() {
        if (!confirm('Отключить все устройства от VPN и вернуть их на прямой интернет?')) return;
        return fs.exec('/usr/libexec/awgswitch/ctl.sh', ['reset_rules']).then(function() {
            window.location.reload();
        });
    },

    handleFixDns: function() {
        var out = document.getElementById('awg_test_output');
        if (out) {
            out.textContent = 'Применение безопасных DNS в dnsmasq...';
            out.scrollIntoView({ behavior: 'smooth', block: 'center' });
        }
        return fs.exec('/usr/libexec/awgswitch/ctl.sh', ['fix_dns']).then(function(r) {
            if (out) out.textContent = (r.stdout || '') + (r.stderr ? '\n' + r.stderr : '');
            ui.addNotification(null, E('p', 'Безопасные DNS (1.1.1.1) успешно настроены!'), 'info');
        });
    },

    handleUploadIpk: function() {
        var fileInput = document.getElementById('awg_upload_input');
        var out = document.getElementById('awg_test_output');
        var btn = document.getElementById('awg_btn_upload');

        if (!fileInput || !fileInput.files || fileInput.files.length === 0) {
            ui.addNotification(null, E('p', 'Пожалуйста, сначала выберите скачанный файл .ipk на компьютере.'), 'warning');
            return;
        }

        var file = fileInput.files[0];
        if (!file.name.endsWith('.ipk')) {
            ui.addNotification(null, E('p', 'Выбранный файл должен иметь расширение .ipk!'), 'danger');
            return;
        }

        if (btn) {
            btn.disabled = true;
            btn.textContent = '⏳ Передача на роутер...';
        }
        if (out) {
            out.textContent = '[ИНФО] Чтение файла ' + file.name + ' (' + file.size + ' байт)...\nПередача на роутер через браузер...';
            out.scrollIntoView({ behavior: 'smooth', block: 'center' });
        }

        var reader = new FileReader();
        reader.onload = function(e) {
            try {
                var bytes = new Uint8Array(e.target.result);
                var binary = '';
                var chunkSize = 8192;
                for (var i = 0; i < bytes.length; i += chunkSize) {
                    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunkSize));
                }
                var b64 = window.btoa(binary);

                if (out) out.textContent += '\nФайл прочитан. Сохранение в буфер роутера...';

                fs.write('/tmp/awg_upload.b64', b64).then(function() {
                    if (out) out.textContent += '\nПередача завершена! Установка пакета ' + file.name + '...\n';
                    return fs.exec('/usr/libexec/awgswitch/ctl.sh', ['install_b64', file.name]);
                }).then(function(res) {
                    if (out) {
                        out.textContent += '\n' + (res.stdout || '') + (res.stderr ? '\n' + res.stderr : '');
                    }
                    if (res.code === 0) {
                        ui.addNotification(null, E('p', 'Пакет ' + file.name + ' успешно установлен!'), 'info');
                        if (btn) btn.textContent = '✅ Установлено!';
                        setTimeout(function() { window.location.reload(); }, 2000);
                    } else {
                        ui.addNotification(null, E('p', 'Ошибка установки: ' + (res.stderr || res.stdout)), 'danger');
                        if (btn) {
                            btn.disabled = false;
                            btn.textContent = '📤 Загрузить и установить на роутер';
                        }
                    }
                }).catch(function(err) {
                    if (out) out.textContent += '\n[ОШИБКА]: ' + err.message;
                    ui.addNotification(null, E('p', 'Ошибка: ' + err.message), 'danger');
                    if (btn) {
                        btn.disabled = false;
                        btn.textContent = '📤 Загрузить и установить на роутер';
                    }
                });
            } catch(ex) {
                if (out) out.textContent += '\n[ОШИБКА]: ' + ex.message;
                if (btn) {
                    btn.disabled = false;
                    btn.textContent = '📤 Загрузить и установить на роутер';
                }
            }
        };
        reader.readAsArrayBuffer(file);
    },

    handleRebootRouter: function() {
        if (!confirm('Перезагрузить роутер сейчас? После перезагрузки ядро OpenWrt активирует все новые модули AmneziaWG.')) return;
        ui.addNotification(null, E('p', 'Роутер перезагружается. Подождите около 60 секунд, затем обновите страницу.'), 'info');
        fs.exec('/sbin/reboot').catch(function() {});
        setTimeout(function() { window.location.reload(); }, 50000);
    },

    handleMasterToggle: function(disableFlag) {
        return fs.exec('/usr/libexec/awgswitch/ctl.sh', ['master_toggle', disableFlag]).then(function() {
            window.location.reload();
        });
    },

    handleRunTest: function(type, domain) {
        var out = document.getElementById('awg_test_output');
        if (out) {
            out.textContent = 'Выполняется проверка (' + type + ')...';
            out.scrollIntoView({ behavior: 'smooth', block: 'center' });
        }
        return fs.exec('/usr/libexec/awgswitch/ctl.sh', ['test_target', type, domain || '']).then(function(r) {
            if (out) out.textContent = (r.stdout || '') + (r.stderr ? '\n' + r.stderr : '');
        });
    },

    handleRunCustomTest: function() {
        var dom = document.getElementById('awg_custom_domain').value.trim();
        if (!dom) return;
        return this.handleRunTest('custom', dom);
    },

    handleSetupConf: function() {
        var text = document.getElementById('awg_conf_input').value;
        if (!text || text.indexOf('[Interface]') === -1 || text.indexOf('[Peer]') === -1) {
            ui.addNotification(null, E('p', 'Вставьте корректный конфигурационный файл .conf (должны присутствовать секции [Interface] и [Peer])!'), 'danger');
            return;
        }
        var out = document.getElementById('awg_test_output');
        if (out) out.textContent = 'Применение новой конфигурации .conf...';
        return fs.write('/etc/awgswitch/current.conf', text.trim() + '\n').then(function() {
            return fs.exec('/usr/libexec/awgswitch/ctl.sh', ['apply_conf']);
        }).then(function(r) {
            if (r.stdout && r.stdout.indexOf('OK') !== -1) {
                ui.addNotification(null, E('p', 'Конфигурация успешно применена, интерфейс awg0 запущен!'), 'info');
                setTimeout(function() { window.location.reload(); }, 1500);
            } else {
                if (out) out.textContent = (r.stdout || '') + (r.stderr ? '\n' + r.stderr : '');
                ui.addNotification(null, E('p', 'Ошибка при применении конфигурации. См. вывод терминала.'), 'danger');
            }
        });
    },

    handleRenameDevice: function(ip, currentName) {
        var newName = window.prompt('Введите понятное имя для устройства (' + ip + '):', currentName || '');
        if (newName === null) return;
        return fs.read('/etc/awgswitch/aliases.json').catch(function() { return '{}'; }).then(function(raw) {
            var d = {};
            try { d = JSON.parse(raw || '{}'); } catch(e) {}
            if (newName.trim() === '') {
                delete d[ip];
            } else {
                d[ip] = newName.trim();
            }
            return fs.write('/etc/awgswitch/aliases.json', JSON.stringify(d, null, 2) + '\n');
        }).then(function() {
            window.location.reload();
        });
    },

    handleRestartTunnel: function() {
        var out = document.getElementById('awg_test_output');
        if (out) out.textContent = 'Перезапуск туннеля awg0 и синхронизация правил...';
        return fs.exec('/usr/libexec/awgswitch/ctl.sh', ['restart_tunnel']).then(function() {
            ui.addNotification(null, E('p', 'Туннель awg0 перезапущен!'), 'info');
            setTimeout(function() { window.location.reload(); }, 1000);
        });
    },

    handlePinDevice: function(ip, mac, name) {
        if (!confirm('Закрепить постоянный IP ' + ip + ' за устройством «' + name + '» (' + mac + ') в настройках DHCP роутера?')) return;
        return fs.exec('/usr/libexec/awgswitch/ctl.sh', ['pin_ip', ip, mac, name]).then(function() {
            ui.addNotification(null, E('p', 'IP ' + ip + ' закреплен за MAC ' + mac + '!'), 'info');
            setTimeout(function() { window.location.reload(); }, 800);
        });
    },

    handleSetMode: function(ip, newMode, currentMode) {
        if (newMode === currentMode) return;
        if (ip === '192.168.1.195' && currentMode === 'vpn' && newMode !== 'vpn') {
            if (!confirm('Внимание: На этом ПК может быть активна сессия AI-ассистента через VPN. Вы действительно хотите переключить этот ПК в режим "' + newMode + '"?')) {
                return;
            }
        }
        return fs.exec('/usr/libexec/awgswitch/ctl.sh', ['set_mode', ip, newMode]).then(function() {
            window.location.reload();
        });
    },

    handleToggleDevice: function(ip, currentlyOn) {
        return this.handleSetMode(ip, currentlyOn ? 'standard' : 'vpn', currentlyOn ? 'vpn' : 'standard');
    },

    handleToggleAll: function(enable) {
        if (!enable && this._currentDevices && this._currentDevices['192.168.1.195']) {
            if (!confirm('Внимание: "Выключить для всех" отключит VPN в том числе на ПК, где работает AI-ассистент Antigravity, что может прервать доступ. Вы уверены?')) {
                return;
            }
        }
        var args = ['toggle_all', enable ? '1' : '0'];
        if (enable && this._currentDevices) {
            Object.keys(this._currentDevices).forEach(function(ip) {
                args.push(ip);
            });
        }
        return fs.exec('/usr/libexec/awgswitch/ctl.sh', args).then(function() {
            window.location.reload();
        });
    },

    handleAddCustomIp: function() {
        var input = document.getElementById('awg_custom_ip');
        if (!input) return;
        var ip = input.value.trim();
        var ipRegex = /^(\d{1,3}\.){3}\d{1,3}$/;
        if (!ipRegex.test(ip)) {
            ui.addNotification(null, E('p', 'Введите корректный IPv4-адрес (например, 192.168.1.55)'), 'danger');
            return;
        }
        return this.handleSetMode(ip, 'vpn', 'standard');
    },

    handleBackupNow: function() {
        return fs.exec('/usr/libexec/awgswitch/ctl.sh', ['backup_now']).then(function() {
            window.location.reload();
        });
    },

    handleRestoreBackup: function() {
        if (!confirm('Откатить настройки network, firewall и dhcp к сохраненной копии?')) return;
        return fs.exec('/usr/libexec/awgswitch/ctl.sh', ['restore_backup']).then(function() {
            window.location.reload();
        });
    },

    handleUninstall: function(mode) {
        var msg = (mode === 'full_purge')
            ? 'Удалить плагин, откатить настройки роутера и полностью удалить пакеты AmneziaWG?'
            : 'Удалить только плагин Switcher и восстановить оригинальные настройки сети?';
        if (!confirm(msg)) return;
        return fs.exec('/usr/libexec/awgswitch/ctl.sh', ['uninstall', mode]).then(function() {
            window.location.href = '/cgi-bin/luci/';
        });
    },

    handleSaveApply: null,
    handleSave: null,
    handleReset: null
});
