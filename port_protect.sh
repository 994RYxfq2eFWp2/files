#!/usr/bin/env bash
# port_protect.sh - 使用 nftables 保护指定端口 (默认 65530)
# 支持同时保护多个端口，每个端口独立配置允许访问的 IPv4/IPv6 白名单；
# install 支持按端口覆盖更新允许的 IP；
# 其余未授权来源返回 TCP RST / ICMP Port Unreachable，扫描特征与“未监听端口 (closed)”完全一致。

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_PATH="/usr/local/bin/port_protect.sh"
CONF_DIR="/etc/port-protect"
CONF_FILE="${CONF_DIR}/port_protect.conf"
SYSTEMD_SERVICE="/etc/systemd/system/port-protect.service"
CRON_FILE="/etc/cron.d/port-protect"
NFT_TABLE="port_protect"
DEFAULT_PORT=65530

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<'EOF'
用法:
  bash port_protect.sh install [-p <端口>] -i <IP1,IP2...> [-p <端口2> -i <IP3...>] [--replace-all]
  bash port_protect.sh remove -p <端口> [-p <端口2>...]
  bash port_protect.sh apply
  bash port_protect.sh status
  bash port_protect.sh uninstall

操作说明:
  install    按端口配置/覆盖允许的 IP 列表并立即生效 (未指定的已保护端口保持不变)
  remove     移除指定端口的保护规则 (保留其余端口规则)
  apply      根据配置文件重新加载所有端口的 nftables 规则 (供开机自启调用)
  status     查看当前所有受保护端口配置、nftables 规则及命中计数
  uninstall  移除所有 nftables 规则、开机自启服务及配置文件

参数:
  -p, --port <端口>     指定要配置或移除的端口号 (install 未指定时默认: 65530)
  -i, --ip <IP/CIDR>    当前端口允许访问的 IPv4/IPv6 地址或 CIDR 网段 (可多次指定或用逗号分隔)
  --replace-all         install 时清空其它旧端口配置，仅保留本次命令指定的端口
  -h, --help            显示此帮助信息

示例:
  # 1. 保护默认 65530 端口 (若已存在 65530 配置则覆盖更新其允许的 IP)
  sudo bash port_protect.sh install -i 47.86.8.165

  # 2. 新增或覆盖更新其它端口 (不影响已配置的 65530 端口)
  sudo bash port_protect.sh install -p 9876 -i 1.2.3.4,2001:db8::1

  # 3. 一次性配置/更新多个端口，每个端口各自独立设置允许的 IP
  sudo bash port_protect.sh install -p 65530 -i 47.86.8.165 -p 9876 -i 1.2.3.4,5.6.7.8

  # 4. 仅移除单个端口的保护
  sudo bash port_protect.sh remove -p 9876

  # 5. 查看状态或完全卸载
  sudo bash port_protect.sh status
  sudo bash port_protect.sh uninstall
EOF
}

require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        log_error "请使用 root 权限运行此脚本"
        exit 1
    fi
}

ensure_dependencies() {
    if ! command -v nft >/dev/null 2>&1; then
        log_info "未检测到 nftables，正在安装..."
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y nftables
        elif command -v yum >/dev/null 2>&1; then
            yum install -y nftables
        else
            log_error "无法自动安装 nftables，请手动安装后重试"
            exit 1
        fi
    fi
}

is_valid_port() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_ipv4() {
    local ip="${1%/*}"
    local cidr="${1#*/}"
    if [[ "$1" == */* ]]; then
        [[ "$cidr" =~ ^[0-9]{1,2}$ ]] && [ "$cidr" -ge 0 ] && [ "$cidr" -le 32 ] || return 1
    fi
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    read -r -a octets <<< "$ip"
    local o
    for o in "${octets[@]}"; do
        [ "$o" -ge 0 ] && [ "$o" -le 255 ] || return 1
    done
    return 0
}

is_ipv6() {
    local ip="${1%/*}"
    local cidr="${1#*/}"
    if [[ "$1" == */* ]]; then
        [[ "$cidr" =~ ^[0-9]{1,3}$ ]] && [ "$cidr" -ge 0 ] && [ "$cidr" -le 128 ] || return 1
    fi
    # 至少包含两个冒号且仅含合法十六进制字符与冒号
    [[ "$ip" == *:*:* ]] && [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]]
}

# 清理旧版 xbn_protect 遗留资源
cleanup_legacy_xbn() {
    if command -v nft >/dev/null 2>&1 && nft list table inet xbn_protect >/dev/null 2>&1; then
        nft delete table inet xbn_protect >/dev/null 2>&1 || true
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now xbn-protect.timer >/dev/null 2>&1 || true
        systemctl disable --now xbn-protect.service >/dev/null 2>&1 || true
    fi
    rm -f /etc/systemd/system/xbn-protect.timer \
          /etc/systemd/system/xbn-protect.service \
          /etc/cron.d/xbn-protect \
          /etc/xboard-node/xbn_protect.conf \
          /usr/local/bin/xbn_protect.sh
}

# 全局关联数组：PORT_RULES[port]="ip1 ip2 ..."
declare -A PORT_RULES=()

load_config() {
    PORT_RULES=()
    if [ ! -f "$CONF_FILE" ]; then
        return 0
    fi
    local line port ips_str
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(echo "$line" | sed 's/#.*//' | xargs)
        [ -z "$line" ] && continue
        port=$(echo "$line" | awk '{print $1}')
        ips_str=$(echo "$line" | cut -d' ' -f2- | xargs)
        if is_valid_port "$port" && [ -n "$ips_str" ] && [ "$ips_str" != "$port" ]; then
            PORT_RULES["$port"]="$ips_str"
        fi
    done < "$CONF_FILE"
}

save_config() {
    mkdir -p "$CONF_DIR"
    local tmp_file="${CONF_FILE}.tmp.$$"
    {
        echo "# port_protect 配置文件 (格式: <端口> <IP1> <IP2> ...)"
        if [ "${#PORT_RULES[@]}" -gt 0 ]; then
            local p
            while IFS= read -r p; do
                [ -n "$p" ] && echo "${p} ${PORT_RULES[$p]}"
            done < <(printf '%s\n' "${!PORT_RULES[@]}" | sort -n)
        fi
    } > "$tmp_file"
    chmod 600 "$tmp_file"
    mv -f "$tmp_file" "$CONF_FILE"
}

apply_nft_rules() {
    load_config

    # 若当前没有任何受保护端口，删除表即可
    if [ "${#PORT_RULES[@]}" -eq 0 ]; then
        if nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
            nft delete table inet "$NFT_TABLE"
        fi
        log_info "当前无受保护端口，已清空 nftables 表 inet ${NFT_TABLE}"
        return 0
    fi

    local sorted_ports=()
    mapfile -t sorted_ports < <(printf '%s\n' "${!PORT_RULES[@]}" | sort -n)
    local all_ports_csv
    all_ports_csv=$(IFS=', '; echo "${sorted_ports[*]}")

    local sets_block=""
    local rules_block=""
    local summary_msgs=()
    local p item

    for p in "${sorted_ports[@]}"; do
        local v4_list=()
        local v6_list=()
        for item in ${PORT_RULES[$p]}; do
            if is_ipv4 "$item"; then
                v4_list+=("$item")
            elif is_ipv6 "$item"; then
                v6_list+=("$item")
            else
                log_error "端口 ${p} 包含无效的 IP 格式: ${item}"
                exit 1
            fi
        done

        local uniq_v4=()
        local uniq_v6=()
        if [ "${#v4_list[@]}" -gt 0 ]; then
            mapfile -t uniq_v4 < <(printf '%s\n' "${v4_list[@]}" | sort -u)
        fi
        if [ "${#v6_list[@]}" -gt 0 ]; then
            mapfile -t uniq_v6 < <(printf '%s\n' "${v6_list[@]}" | sort -u)
        fi

        if [ "${#uniq_v4[@]}" -gt 0 ]; then
            local joined_v4
            joined_v4=$(IFS=', '; echo "${uniq_v4[*]}")
            sets_block+="
    set allow_v4_${p} {
        type ipv4_addr
        flags interval
        elements = { ${joined_v4} }
    }
"
            rules_block+="        ip saddr @allow_v4_${p} tcp dport ${p} counter accept
        ip saddr @allow_v4_${p} udp dport ${p} counter accept
"
        fi

        if [ "${#uniq_v6[@]}" -gt 0 ]; then
            local joined_v6
            joined_v6=$(IFS=', '; echo "${uniq_v6[*]}")
            sets_block+="
    set allow_v6_${p} {
        type ipv6_addr
        flags interval
        elements = { ${joined_v6} }
    }
"
            rules_block+="        ip6 saddr @allow_v6_${p} tcp dport ${p} counter accept
        ip6 saddr @allow_v6_${p} udp dport ${p} counter accept
"
        fi

        summary_msgs+=("端口 ${p} -> [IPv4: ${uniq_v4[*]:-无} | IPv6: ${uniq_v6[*]:-无}]")
    done

    # 原子替换 table inet port_protect
    nft -f - <<EOF
table inet ${NFT_TABLE}
delete table inet ${NFT_TABLE}

table inet ${NFT_TABLE} {${sets_block}
    chain input {
        type filter hook input priority -10; policy accept;

        # 允许本机回环访问所有受保护端口
        iifname "lo" tcp dport { ${all_ports_csv} } accept
        iifname "lo" udp dport { ${all_ports_csv} } accept

        # 各端口独立白名单放行规则
${rules_block}
        # 其余所有来源伪装成“端口未监听 (closed)”状态：
        # TCP 直接返回 RST，UDP 返回 ICMP Port Unreachable
        meta l4proto tcp tcp dport { ${all_ports_csv} } counter reject with tcp reset
        meta l4proto udp udp dport { ${all_ports_csv} } counter reject with icmpx type port-unreachable
    }
}
EOF

    log_info "已更新 nftables 端口保护规则："
    local msg
    for msg in "${summary_msgs[@]}"; do
        echo -e "  - ${msg}"
    done
}

setup_boot_service() {
    local current_script
    current_script=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")
    if [ "$current_script" != "$SCRIPT_PATH" ]; then
        install -m 755 "$current_script" "$SCRIPT_PATH"
    else
        chmod 755 "$SCRIPT_PATH"
    fi

    cleanup_legacy_xbn

    if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        cat > "$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Apply port_protect nftables rules
After=network-pre.target
Before=network.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH} apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable port-protect.service >/dev/null 2>&1 || true
        rm -f "$CRON_FILE"
        log_info "已配置 systemd 开机自动加载 (port-protect.service)"
    else
        cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
@reboot root ${SCRIPT_PATH} apply >/dev/null 2>&1
EOF
        chmod 644 "$CRON_FILE"
        log_info "已配置 /etc/cron.d/port-protect 开机自动加载"
    fi
}

cmd_install() {
    local current_port=""
    local pending_ips=()
    local replace_all=0
    declare -A new_port_ips=()

    while [ $# -gt 0 ]; do
        case "$1" in
            -p|--port)
                if [ -z "${2:-}" ] || ! is_valid_port "$2"; then
                    log_error "无效的端口号: ${2:-}"
                    exit 1
                fi
                current_port="$2"
                if [ -z "${new_port_ips[$current_port]+x}" ]; then
                    new_port_ips["$current_port"]=""
                fi
                if [ "${#pending_ips[@]}" -gt 0 ]; then
                    new_port_ips["$current_port"]="${new_port_ips[$current_port]} ${pending_ips[*]}"
                    pending_ips=()
                fi
                shift 2
                ;;
            -i|--ip)
                if [ -z "${2:-}" ]; then
                    log_error "参数 $1 需要指定 IP 地址"
                    exit 1
                fi
                IFS=',' read -r -a split_ips <<< "$2"
                local item
                for item in "${split_ips[@]}"; do
                    item=$(echo "$item" | xargs)
                    [ -z "$item" ] && continue
                    if [ -n "$current_port" ]; then
                        new_port_ips["$current_port"]="${new_port_ips[$current_port]} ${item}"
                    else
                        pending_ips+=("$item")
                    fi
                done
                shift 2
                ;;
            --replace-all)
                replace_all=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                # 支持位置参数传入 IP 列表
                IFS=',' read -r -a split_ips <<< "$1"
                local item
                for item in "${split_ips[@]}"; do
                    item=$(echo "$item" | xargs)
                    [ -z "$item" ] && continue
                    if [ -n "$current_port" ]; then
                        new_port_ips["$current_port"]="${new_port_ips[$current_port]} ${item}"
                    else
                        pending_ips+=("$item")
                    fi
                done
                shift
                ;;
        esac
    done

    # 若未指定 -p，默认归属到 DEFAULT_PORT (65530)
    if [ "${#pending_ips[@]}" -gt 0 ]; then
        local target_port="${current_port:-$DEFAULT_PORT}"
        new_port_ips["$target_port"]="${new_port_ips[$target_port]:-} ${pending_ips[*]}"
    fi

    if [ "${#new_port_ips[@]}" -eq 0 ]; then
        log_error "请至少指定一个端口和允许访问的 IP，例如: bash port_protect.sh install -p 65530 -i 1.2.3.4"
        usage
        exit 1
    fi

    # 校验每个端口的 IP 列表合法性并去重
    local p ip
    for p in "${!new_port_ips[@]}"; do
        local raw_ips="${new_port_ips[$p]}"
        local valid_ips=()
        for ip in $raw_ips; do
            if ! is_ipv4 "$ip" && ! is_ipv6 "$ip"; then
                log_error "端口 ${p} 包含无效的 IP 地址或 CIDR 格式: ${ip} (仅接受 IPv4/IPv6)"
                exit 1
            fi
            valid_ips+=("$ip")
        done
        if [ "${#valid_ips[@]}" -eq 0 ]; then
            log_error "端口 ${p} 未指定允许访问的 IP 地址 (-i)"
            exit 1
        fi
        local dedup_ips
        dedup_ips=$(printf '%s\n' "${valid_ips[@]}" | sort -u | xargs)
        new_port_ips["$p"]="$dedup_ips"
    done

    require_root
    ensure_dependencies

    if [ "$replace_all" -eq 1 ]; then
        PORT_RULES=()
    else
        load_config
    fi

    # 按端口覆盖更新允许的 IP
    for p in "${!new_port_ips[@]}"; do
        PORT_RULES["$p"]="${new_port_ips[$p]}"
    done

    save_config
    apply_nft_rules
    setup_boot_service
    log_info "配置完成！可通过 'port_protect.sh status' 查看运行状态"
}

cmd_remove() {
    local remove_ports=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -p|--port)
                if [ -z "${2:-}" ]; then
                    log_error "参数 $1 需要指定端口号"
                    exit 1
                fi
                IFS=',' read -r -a split_ports <<< "$2"
                local p
                for p in "${split_ports[@]}"; do
                    p=$(echo "$p" | xargs)
                    if ! is_valid_port "$p"; then
                        log_error "无效的端口号: ${p}"
                        exit 1
                    fi
                    remove_ports+=("$p")
                done
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                IFS=',' read -r -a split_ports <<< "$1"
                local p
                for p in "${split_ports[@]}"; do
                    p=$(echo "$p" | xargs)
                    if ! is_valid_port "$p"; then
                        log_error "无效的端口号: ${p}"
                        exit 1
                    fi
                    remove_ports+=("$p")
                done
                shift
                ;;
        esac
    done

    if [ "${#remove_ports[@]}" -eq 0 ]; then
        log_error "请指定要移除保护的端口号，例如: bash port_protect.sh remove -p 65530"
        exit 1
    fi

    require_root
    ensure_dependencies
    load_config

    local p
    for p in "${remove_ports[@]}"; do
        if [ -n "${PORT_RULES[$p]+x}" ]; then
            unset 'PORT_RULES[$p]'
            log_info "已移除端口 ${p} 的保护配置"
        else
            log_warn "端口 ${p} 未在受保护列表中"
        fi
    done

    save_config
    apply_nft_rules
}

cmd_apply() {
    require_root
    ensure_dependencies
    apply_nft_rules
}

cmd_status() {
    require_root
    echo -e "${CYAN}=== 配置文件 (${CONF_FILE}) ===${NC}"
    if [ -f "$CONF_FILE" ]; then
        cat "$CONF_FILE"
    else
        echo "未找到配置文件"
    fi

    echo ""
    echo -e "${CYAN}=== 当前 nftables 规则 (table inet ${NFT_TABLE}) ===${NC}"
    if command -v nft >/dev/null 2>&1 && nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        nft list table inet "$NFT_TABLE"
    else
        echo "未加载 (table inet ${NFT_TABLE} 不存在)"
    fi
}

cmd_uninstall() {
    require_root
    cleanup_legacy_xbn
    if command -v nft >/dev/null 2>&1 && nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        nft delete table inet "$NFT_TABLE"
        log_info "已移除 nftables 表 inet ${NFT_TABLE}"
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now port-protect.service >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_SERVICE"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    rm -f "$CRON_FILE" "$CONF_FILE" "$SCRIPT_PATH"
    rmdir "$CONF_DIR" 2>/dev/null || true
    log_info "已卸载 port_protect"
}

main() {
    local action="${1:-}"
    case "$action" in
        install|set|add)
            shift
            cmd_install "$@"
            ;;
        remove|del|delete)
            shift
            cmd_remove "$@"
            ;;
        apply|reload|update)
            cmd_apply
            ;;
        status)
            cmd_status
            ;;
        uninstall|purge)
            cmd_uninstall
            ;;
        -h|--help|"")
            usage
            ;;
        *)
            cmd_install "$@"
            ;;
    esac
}

main "$@"
