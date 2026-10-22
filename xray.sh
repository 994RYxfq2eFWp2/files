#!/usr/bin/env bash

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF_DIR="/usr/local/etc/xray"
XRAY_MAIN_CONF="${XRAY_CONF_DIR}/config.json"
# 文件名必须包含 "tail"，触发 Xray-core 源码中 strings.Contains(fn, "tail") 逻辑，
# 确保 blackhole 出站追加在末尾，而不会抢占第一位默认出站 (direct)。
XRAY_BLOCK_CONF="${XRAY_CONF_DIR}/block_tail.json"
XRAY_SHARE_DIR="/usr/local/share/xray"
BLOCKLIST_URL="https://raw.githubusercontent.com/994RYxfq2eFWp2/files/refs/heads/main/blocklist"

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "需要管理员权限 (root)"
        return 1
    fi
}

detect_os() {
    OS=""
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    elif [ -f /etc/alpine-release ]; then
        OS="alpine"
    else
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    fi

    IS_ALPINE=false
    case "$OS" in
        debian|ubuntu)
            IS_ALPINE=false
            ;;
        alpine)
            IS_ALPINE=true
            ;;
        *)
            echo "仅支持 debian/ubuntu 和 alpine 系统 (当前: $OS)"
            return 1
            ;;
    esac
}

detect_arch() {
    local ARCH
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)   XRAY_ASSET="Xray-linux-64.zip" ;;
        aarch64|arm64)  XRAY_ASSET="Xray-linux-arm64-v8a.zip" ;;
        armv7l|armv7)   XRAY_ASSET="Xray-linux-arm32-v7a.zip" ;;
        i686|i386)      XRAY_ASSET="Xray-linux-32.zip" ;;
        *)
            echo "不支持的架构: $ARCH"
            return 1
            ;;
    esac
}

install_deps() {
    echo "==> 安装依赖..."
    if $IS_ALPINE; then
        apk update >/dev/null
        apk add --no-cache curl unzip openssl ca-certificates openrc >/dev/null
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq curl unzip openssl ca-certificates >/dev/null
    fi
}

download_and_install_xray() {
    detect_arch || return 1

    echo "==> 获取 Xray-core 最新版本..."
    LATEST_VERSION=$(curl -fsSL --max-time 15 https://api.github.com/repos/XTLS/Xray-core/releases/latest \
        | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | head -n1 \
        | sed -E 's/.*"([^"]+)"$/\1/')
    if [ -z "$LATEST_VERSION" ]; then
        echo "获取最新版本失败，请检查网络"
        return 1
    fi
    echo "最新版本: $LATEST_VERSION"

    local DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/${XRAY_ASSET}"
    echo "==> 下载: $DOWNLOAD_URL"

    local TMPDIR
    TMPDIR=$(mktemp -d)
    if ! curl -fL --retry 3 --max-time 300 -o "$TMPDIR/xray.zip" "$DOWNLOAD_URL"; then
        echo "下载失败"
        rm -rf "$TMPDIR"
        return 1
    fi

    if ! unzip -o "$TMPDIR/xray.zip" -d "$TMPDIR/xray" >/dev/null; then
        echo "解压失败"
        rm -rf "$TMPDIR"
        return 1
    fi

    echo "==> 安装 xray 到 ${XRAY_BIN} ..."
    if [ ! -f "$TMPDIR/xray/xray" ]; then
        echo "安装失败: 压缩包内未找到 xray 二进制"
        rm -rf "$TMPDIR"
        return 1
    fi
    install -m 755 "$TMPDIR/xray/xray" "$XRAY_BIN"

    mkdir -p "$XRAY_SHARE_DIR"
    local dat
    for dat in geoip.dat geosite.dat; do
        [ -f "$TMPDIR/xray/$dat" ] && install -m 644 "$TMPDIR/xray/$dat" "${XRAY_SHARE_DIR}/$dat"
    done
    rm -rf "$TMPDIR"

    if [ ! -x "$XRAY_BIN" ]; then
        echo "安装失败: 未找到可执行文件 ${XRAY_BIN}"
        return 1
    fi
}

generate_connection_config() {
    if [ ! -x "$XRAY_BIN" ]; then
        echo "未检测到 Xray，请先安装 Xray"
        return 1
    fi

    echo "==> 生成 UUID 与 VLESS Encryption 密钥..."
    UUID=$("$XRAY_BIN" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)

    # 使用 `xray vlessenc` 生成配对的 decryption / encryption
    # 采用 ML-KEM-768(后量子, Post-Quantum) 认证组；密钥串仅含 [A-Za-z0-9._-]，可直接用于 URL
    local ENC_OUT PQ_OUT
    ENC_OUT=$("$XRAY_BIN" vlessenc 2>/dev/null)
    PQ_OUT=$(printf '%s\n' "$ENC_OUT" | awk '/ML-KEM-768/{flag=1} flag')
    [ -z "$PQ_OUT" ] && PQ_OUT="$ENC_OUT"
    ENCRYPTION=$(printf '%s\n' "$PQ_OUT" | grep -oE 'mlkem768x25519plus\.[^"[:space:]]+' | grep '\.0rtt\.' | tail -n1)
    DECRYPTION=$(printf '%s\n' "$PQ_OUT" | grep -oE 'mlkem768x25519plus\.[^"[:space:]]+' | grep -v '\.0rtt\.' | tail -n1)

    if [ -z "$DECRYPTION" ] || [ -z "$ENCRYPTION" ]; then
        echo "生成 VLESS Encryption 密钥失败（当前 Xray 版本可能过旧，未提供 vlessenc 命令）"
        return 1
    fi

    PORT=$(shuf -i 10000-65000 -n 1 2>/dev/null \
        || awk -v min=10000 -v max=65000 'BEGIN{srand(); print int(min+rand()*(max-min+1))}')

    echo "==> 生成连接配置文件 ${XRAY_MAIN_CONF} ..."
    mkdir -p "$XRAY_CONF_DIR"
    cat > "$XRAY_MAIN_CONF" <<EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "listen": "::",
            "port": ${PORT},
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "${UUID}",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "${DECRYPTION}"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "none"
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls",
                    "quic"
                ],
                "routeOnly": true
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        }
    ]
}
EOF
    chmod 600 "$XRAY_MAIN_CONF"
}

update_blocklist_config() {
    echo "==> 拉取 blocklist: ${BLOCKLIST_URL} ..."
    mkdir -p "$XRAY_CONF_DIR"

    local TMP_DIR TMP_RAW TMP_JSON
    TMP_DIR=$(mktemp -d)
    TMP_RAW="${TMP_DIR}/blocklist.txt"
    TMP_JSON="${TMP_DIR}/block_tail.json"

    if ! curl -fsSL --retry 3 --max-time 30 -o "$TMP_RAW" "$BLOCKLIST_URL"; then
        echo "拉取 blocklist 失败，请检查网络连接"
        rm -rf "$TMP_DIR"
        return 1
    fi

    # 解析域名列表并生成 Xray 路由拦截配置 (加 domain: 前缀以启用子域名精确匹配，避免默认 keyword 子串误杀)
    local RULE_COUNT
    RULE_COUNT=$(awk '
        {
            gsub(/\r/, "")
            sub(/^[[:space:]]+/, "")
            sub(/[[:space:]]+$/, "")
            if ($0 == "" || $0 ~ /^#/) next
            sub(/^\*\./, "")
            if ($0 !~ /^(domain:|full:|keyword:|regexp:|geosite:|ext:|ext-domain:|ext-site:|dotless:)/) {
                $0 = "domain:" $0
            }
            if (!seen[$0]++) {
                domains[++n] = $0
            }
        }
        END {
            print n + 0
        }
    ' "$TMP_RAW")

    if [ "$RULE_COUNT" -eq 0 ] 2>/dev/null; then
        echo "解析 blocklist 失败: 未提取到有效域名规则"
        rm -rf "$TMP_DIR"
        return 1
    fi

    awk '
        BEGIN {
            print "{"
            print "    \"outbounds\": ["
            print "        {"
            print "            \"tag\": \"block\","
            print "            \"protocol\": \"blackhole\""
            print "        }"
            print "    ],"
            print "    \"routing\": {"
            print "        \"domainStrategy\": \"AsIs\","
            print "        \"rules\": ["
            print "            {"
            print "                \"type\": \"field\","
            print "                \"ruleTag\": \"blocklist\","
            print "                \"outboundTag\": \"block\","
            print "                \"domain\": ["
        }
        {
            gsub(/\r/, "")
            sub(/^[[:space:]]+/, "")
            sub(/[[:space:]]+$/, "")
            if ($0 == "" || $0 ~ /^#/) next
            sub(/^\*\./, "")
            if ($0 !~ /^(domain:|full:|keyword:|regexp:|geosite:|ext:|ext-domain:|ext-site:|dotless:)/) {
                $0 = "domain:" $0
            }
            gsub(/\\/, "\\\\")
            gsub(/"/, "\\\"")
            if (!seen[$0]++) {
                lines[++n] = $0
            }
        }
        END {
            for (i = 1; i <= n; i++) {
                comma = (i < n) ? "," : ""
                printf "                    \"%s\"%s\n", lines[i], comma
            }
            print "                ]"
            print "            }"
            print "        ]"
            print "    }"
            print "}"
        }
    ' "$TMP_RAW" > "$TMP_JSON"

    # 若 xray 与主配置已存在，先进行语法与规则自检
    if [ -x "$XRAY_BIN" ] && [ -f "$XRAY_MAIN_CONF" ]; then
        if ! XRAY_LOCATION_ASSET="$XRAY_SHARE_DIR" "$XRAY_BIN" run -test -c "$XRAY_MAIN_CONF" -c "$TMP_JSON" >/dev/null 2>&1; then
            echo "拦截配置校验未通过，中止覆盖:"
            XRAY_LOCATION_ASSET="$XRAY_SHARE_DIR" "$XRAY_BIN" run -test -c "$XRAY_MAIN_CONF" -c "$TMP_JSON"
            rm -rf "$TMP_DIR"
            return 1
        fi
    fi

    install -m 600 "$TMP_JSON" "$XRAY_BLOCK_CONF"
    rm -rf "$TMP_DIR"
    echo "==> 拦截配置已更新至 ${XRAY_BLOCK_CONF} (共 ${RULE_COUNT} 条规则)"
}

setup_service() {
    detect_os || return 1

    if $IS_ALPINE; then
        echo "==> 配置 OpenRC 服务 (多 -c 模式)..."
        cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run

name="xray"
description="Xray Service (VLESS Encryption)"
command="${XRAY_BIN}"
command_args="run -c ${XRAY_MAIN_CONF} -c ${XRAY_BLOCK_CONF}"
command_background="yes"
pidfile="/run/xray.pid"
output_log="/var/log/xray.log"
error_log="/var/log/xray.log"
rc_ulimit="-n 51200"

export XRAY_LOCATION_ASSET=${XRAY_SHARE_DIR}

depend() {
    need net
    after firewall
}
EOF
        chmod +x /etc/init.d/xray
        rc-update add xray default >/dev/null 2>&1
    else
        echo "==> 配置 systemd 服务 (多 -c 模式)..."
        cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service (VLESS Encryption)
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=XRAY_LOCATION_ASSET=${XRAY_SHARE_DIR}
ExecStart=${XRAY_BIN} run -c ${XRAY_MAIN_CONF} -c ${XRAY_BLOCK_CONF}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable xray >/dev/null 2>&1
    fi
}

restart_xray_service() {
    detect_os || return 1

    if [ -x "$XRAY_BIN" ] && [ -f "$XRAY_MAIN_CONF" ] && [ -f "$XRAY_BLOCK_CONF" ]; then
        echo "==> 校验配置文件..."
        if ! XRAY_LOCATION_ASSET="$XRAY_SHARE_DIR" "$XRAY_BIN" run -test -c "$XRAY_MAIN_CONF" -c "$XRAY_BLOCK_CONF"; then
            echo "配置校验失败，请检查配置文件！"
            return 1
        fi
    fi

    echo "==> 重启 Xray 服务..."
    if $IS_ALPINE; then
        rc-service xray restart
        sleep 1
        rc-service xray status || true
    else
        systemctl restart xray
        sleep 1
        systemctl status xray --no-pager -l || true
    fi
}

print_connection_info() {
    local PUBLIC_IP VLESS_URL
    PUBLIC_IP=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null \
        || curl -fsSL --max-time 5 https://ipinfo.io/ip 2>/dev/null \
        || echo "YOUR_SERVER_IP")

    VLESS_URL="vless://${UUID}@${PUBLIC_IP}:${PORT}?encryption=${ENCRYPTION}&flow=xtls-rprx-vision&security=none&type=tcp#vless-enc-pq"

    echo ""
    echo "=========================================="
    echo "vless-enc (Xray-core) 配置信息"
    echo "=========================================="
    [ -n "$LATEST_VERSION" ] && echo "版本:        ${LATEST_VERSION}"
    echo "服务器地址:  ${PUBLIC_IP}"
    echo "端口:        ${PORT}"
    echo "UUID:        ${UUID}"
    echo "传输:        tcp (RAW)"
    echo "流控 flow:   xtls-rprx-vision"
    echo "认证方式:    ML-KEM-768 (后量子 Post-Quantum)"
    echo "外层安全:    none (加密由 VLESS Encryption 提供，无需 TLS 证书)"
    echo ""
    echo "服务端 decryption:"
    echo "${DECRYPTION}"
    echo ""
    echo "客户端 encryption:"
    echo "${ENCRYPTION}"
    echo ""
    echo "vless:// 链接:"
    echo "${VLESS_URL}"
    echo "=========================================="
    echo "主配置文件:  ${XRAY_MAIN_CONF}"
    echo "拦截配置:    ${XRAY_BLOCK_CONF}"
    if $IS_ALPINE; then
        echo "服务管理:    rc-service xray {start|stop|restart|status}"
        echo "日志文件:    /var/log/xray.log"
    else
        echo "服务管理:    systemctl {start|stop|restart|status} xray"
        echo "查看日志:    journalctl -u xray -f"
    fi
    echo "=========================================="
}

install_xray() {
    check_root || return 1
    detect_os || return 1
    install_deps || return 1
    download_and_install_xray || return 1
    generate_connection_config || return 1
    update_blocklist_config || return 1
    setup_service || return 1
    restart_xray_service || return 1
    print_connection_info
}

update_xray() {
    check_root || return 1
    detect_os || return 1

    if [ ! -x "$XRAY_BIN" ]; then
        echo "未检测到已安装的 Xray，请先执行安装"
        return 1
    fi

    local CURRENT_VERSION
    CURRENT_VERSION=$("$XRAY_BIN" version 2>/dev/null | head -n1 | awk '{print "v"$2}')
    echo "当前版本: ${CURRENT_VERSION:-未知}"

    install_deps || return 1
    download_and_install_xray || return 1

    # 若尚未生成拦截配置则自动拉取一份
    if [ ! -f "$XRAY_BLOCK_CONF" ]; then
        update_blocklist_config || return 1
    fi

    setup_service || return 1
    restart_xray_service || return 1
    echo ""
    echo "Xray 已更新至 ${LATEST_VERSION}"
}

configure_xray() {
    check_root || return 1
    detect_os || return 1

    if [ ! -x "$XRAY_BIN" ]; then
        echo "未检测到已安装的 Xray，请先执行安装"
        return 1
    fi

    echo ""
    echo "========== 配置 Xray =========="
    echo "1) 更新连接配置 (重新生成端口 / UUID / 密钥)"
    echo "2) 更新 blocklist 拦截配置"
    echo "3) 同时更新连接配置与 blocklist"
    echo "0) 返回"
    echo "==============================="
    read -p "请输入选项数字: " sub_choice
    case "$sub_choice" in
        1)
            generate_connection_config || return 1
            [ ! -f "$XRAY_BLOCK_CONF" ] && { update_blocklist_config || return 1; }
            setup_service || return 1
            restart_xray_service || return 1
            print_connection_info
            ;;
        2)
            update_blocklist_config || return 1
            setup_service || return 1
            restart_xray_service || return 1
            ;;
        3)
            generate_connection_config || return 1
            update_blocklist_config || return 1
            setup_service || return 1
            restart_xray_service || return 1
            print_connection_info
            ;;
        0)
            return 0
            ;;
        *)
            echo "无效选项"
            return 1
            ;;
    esac
}

uninstall_xray() {
    check_root || return 1

    read -p "确认卸载 vless-enc (Xray-core)？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消"
        return 0
    fi

    # remove_systemd_service
    if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/xray.service ]; then
        echo "==> 停止并移除 systemd 服务..."
        systemctl stop xray 2>/dev/null
        systemctl disable xray 2>/dev/null
        rm -f /etc/systemd/system/xray.service
        systemctl daemon-reload
        systemctl reset-failed xray 2>/dev/null || true
    fi

    # remove_openrc_service
    if command -v rc-service >/dev/null 2>&1 && [ -f /etc/init.d/xray ]; then
        echo "==> 停止并移除 OpenRC 服务..."
        rc-service xray stop 2>/dev/null
        rc-update del xray default 2>/dev/null
        rm -f /etc/init.d/xray
    fi

    # remove_binary_config_data_logs
    echo "==> 删除二进制/配置/数据/日志..."
    rm -f "$XRAY_BIN"
    rm -rf "$XRAY_CONF_DIR"
    rm -rf "$XRAY_SHARE_DIR"
    rm -f /var/log/xray.log

    echo ""
    echo "vless-enc (Xray-core) 已卸载完成"
}

show_menu() {
    echo ""
    echo "========== Xray 管理脚本 =========="
    echo "1) 安装 Xray (vless-enc + blocklist)"
    echo "2) 更新 Xray"
    echo "3) 配置 Xray (更新连接配置 / 更新 blocklist)"
    echo "4) 卸载 Xray"
    echo "0) 退出"
    echo "==================================="
    read -p "请输入选项数字: " choice
    case "$choice" in
        1) install_xray ;;
        2) update_xray ;;
        3) configure_xray ;;
        4) uninstall_xray ;;
        0) exit 0 ;;
        *) echo "无效选项" ;;
    esac
}

case "${1:-}" in
    install)        install_xray ;;
    update)         update_xray ;;
    config)         configure_xray ;;
    config-conn)    check_root && detect_os && generate_connection_config && setup_service && restart_xray_service && print_connection_info ;;
    config-block)   check_root && detect_os && update_blocklist_config && setup_service && restart_xray_service ;;
    uninstall)      uninstall_xray ;;
    *)              show_menu ;;
esac
