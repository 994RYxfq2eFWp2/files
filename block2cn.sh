#!/usr/bin/env bash
# ==============================================================================
# block2cn.sh - 使用 nftables 禁止 VPS 主动向中国大陆发起出站连接
#
# 特性：
#   1. 仅拦截本机主动发起的新出站连接 (ct state new)，放行已建立连接回包
#      (ct state established,related)，不影响中国大陆客户端连接节点及 SSH 登录
#   2. 同时支持 IPv4 与 IPv6 中国大陆地址段拦截
#   3. 采用小批次 (Chunked) 写入机制，完美兼容 LXC 容器受限的 Netlink 缓冲区
#   4. 通过 systemd timer 每天自动更新中国大陆 IP 库并无缝重载
#   5. 提供 install / uninstall / update / apply / status 命令，安装后自动检测
#
# 用法：
#   sudo bash block2cn.sh install     # 安装并启用拦截，自动检测是否生效
#   sudo bash block2cn.sh uninstall   # 卸载并清理所有规则与定时任务
#   sudo bash block2cn.sh update      # 手动立即更新中国大陆 IP 库并重载
#   sudo bash block2cn.sh status      # 查看状态并执行拦截测试
# ==============================================================================

set -euo pipefail

TABLE_NAME="block2cn"
DATA_DIR="/etc/nftables.d/block2cn"
IPV4_FILE="${DATA_DIR}/cn_ipv4.txt"
IPV6_FILE="${DATA_DIR}/cn_ipv6.txt"
BIN_PATH="/usr/local/bin/block2cn.sh"
SERVICE_FILE="/etc/systemd/system/block2cn.service"
UPDATE_SERVICE_FILE="/etc/systemd/system/block2cn-update.service"
UPDATE_TIMER_FILE="/etc/systemd/system/block2cn-update.timer"

# 每批次写入 nftables 的最大 IP 数量（避免 LXC 容器触发 netlink: Message too long）
BATCH_SIZE=500

# 中国大陆 IPv4 CIDR 下载源（按优先级排列，自动故障切换）
IPV4_URLS=(
    "https://raw.githubusercontent.com/misakaio/chnroutes2/master/chnroutes.txt"
    "https://raw.githubusercontent.com/Loyalsoldier/geoip/release/text/cn.txt"
    "https://ispip.clang.cn/all_cn_cidr.txt"
    "https://www.ipdeny.com/ipblocks/data/countries/cn.zone"
)

# 中国大陆 IPv6 CIDR 下载源（按优先级排列，自动故障切换）
IPV6_URLS=(
    "https://ispip.clang.cn/all_cn_ipv6.txt"
    "https://raw.githubusercontent.com/Loyalsoldier/geoip/release/text/cn.txt"
    "https://www.ipdeny.com/ipv6/ipaddresses/blocks/cn.zone"
)

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[FAIL]${NC} $*" >&2; }

TMP_DIR=""
cleanup() {
    if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR}" ]]; then
        rm -rf "${TMP_DIR}"
    fi
}
trap cleanup EXIT

check_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        log_error "请使用 root 权限运行此脚本 (例如: sudo bash $0 $*)"
        exit 1
    fi
}

install_dependencies() {
    local missing=()
    command -v nft >/dev/null 2>&1 || missing+=("nftables")
    command -v curl >/dev/null 2>&1 || missing+=("curl")

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    log_info "正在安装必要依赖: ${missing[*]} ..."
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" ca-certificates
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q "${missing[@]}" ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q "${missing[@]}" ca-certificates
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache "${missing[@]}" ca-certificates
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm "${missing[@]}" ca-certificates
    else
        log_error "无法识别包管理器，请手动安装: ${missing[*]}"
        exit 1
    fi
}

check_nft_permission() {
    local err_msg
    if ! err_msg=$(nft list tables 2>&1); then
        log_error "当前环境无法操作 nftables 内核防火墙！"
        log_error "内核返回错误: ${err_msg}"
        if [[ "$err_msg" == *"Operation not permitted"* ]]; then
            echo "" >&2
            log_warn "原因分析：当前处于受限容器环境（如未授予 CAP_NET_ADMIN 权限的 Podman/Docker 容器）。"
            log_warn "解决建议："
            log_warn "  1. 若你拥有宿主机权限，请在宿主机直接运行本脚本，或在启动容器时添加 --cap-add=NET_ADMIN"
            log_warn "  2. 若这是受限容器型 VPS（无宿主机权限），无法使用系统层防火墙，请改用 Xboard-Node / Xray 应用层路由拦截方案（geosite:cn + geoip:cn）。"
        fi
        exit 1
    fi
}

download_ipv4_list() {
    local out_file="$1"
    local raw_file="${out_file}.raw"

    for url in "${IPV4_URLS[@]}"; do
        if curl -fsSL --retry 2 --connect-timeout 10 --max-time 30 "$url" -o "$raw_file" 2>/dev/null; then
            tr -d '\r' < "$raw_file" \
                | grep -E '^[0-9]+(\.[0-9]+){3}/[0-9]+$' \
                > "$out_file" || true
            local count
            count=$(wc -l < "$out_file")
            if [[ "$count" -gt 1000 ]]; then
                log_ok "已获取中国大陆 IPv4 地址段 (${count} 条，来源: ${url})"
                return 0
            fi
        fi
    done

    log_error "无法从任何数据源下载有效的中国大陆 IPv4 列表"
    return 1
}

download_ipv6_list() {
    local out_file="$1"
    local raw_file="${out_file}.raw"

    for url in "${IPV6_URLS[@]}"; do
        if curl -fsSL --retry 2 --connect-timeout 10 --max-time 30 "$url" -o "$raw_file" 2>/dev/null; then
            tr -d '\r' < "$raw_file" \
                | grep -E '^[0-9a-fA-F:]+/[0-9]+$' \
                | grep ':' \
                > "$out_file" || true
            local count
            count=$(wc -l < "$out_file")
            if [[ "$count" -gt 100 ]]; then
                log_ok "已获取中国大陆 IPv6 地址段 (${count} 条，来源: ${url})"
                return 0
            fi
        fi
    done

    log_error "无法从任何数据源下载有效的中国大陆 IPv6 列表"
    return 1
}

# 分批向 nftables set 写入地址段，避免 LXC 容器单次 Netlink 消息过大报 Message too long
load_set_in_batches() {
    local set_name="$1"
    local ip_file="$2"
    local batch_dir="$3"

    rm -f "${batch_dir}/chunk_"*
    split -l "$BATCH_SIZE" "$ip_file" "${batch_dir}/chunk_"

    for chunk in "${batch_dir}/chunk_"*; do
        [[ -f "$chunk" ]] || continue
        local batch_nft="${chunk}.nft"
        {
            echo "add element inet ${TABLE_NAME} ${set_name} {"
            awk '{print "    " $1 ","}' "$chunk"
            echo "}"
        } > "$batch_nft"
        nft -f "$batch_nft"
    done
}

apply_rules_from_files() {
    if [[ ! -s "$IPV4_FILE" ]] || [[ ! -s "$IPV6_FILE" ]]; then
        log_error "本地 IP 库文件不存在或为空，请先运行 update"
        return 1
    fi

    TMP_DIR="$(mktemp -d)"
    local base_nft="${TMP_DIR}/base.nft"

    log_info "正在初始化 nftables 表结构与分批加载规则 (兼容 LXC 容器)..."

    # 1. 创建基础表结构、空集合与输出链（极小消息体，任何容器都不会超限）
    cat > "$base_nft" << EOF
add table inet ${TABLE_NAME}
delete table inet ${TABLE_NAME}

table inet ${TABLE_NAME} {
    set cn_v4 {
        type ipv4_addr
        flags interval
        auto-merge
    }

    set cn_v6 {
        type ipv6_addr
        flags interval
        auto-merge
    }

    chain output {
        type filter hook output priority 0; policy accept;

        # 1. 放行本地回环接口
        oifname "lo" accept

        # 2. 放行所有已建立连接或关联连接的回包（确保国内客户端连接节点、SSH 登录正常）
        ct state established,related accept

        # 3. 拦截本机主动向中国大陆 IPv4/IPv6 发起的新出站连接
        ct state new ip daddr @cn_v4 counter reject with icmpx type admin-prohibited
        ct state new ip6 daddr @cn_v6 counter reject with icmpx type admin-prohibited
    }
}
EOF

    nft -f "$base_nft"

    # 2. 分批加载 IPv4 和 IPv6 地址段（每批 BATCH_SIZE 条，避免触发 Message too long）
    load_set_in_batches "cn_v4" "$IPV4_FILE" "$TMP_DIR"
    load_set_in_batches "cn_v6" "$IPV6_FILE" "$TMP_DIR"

    rm -rf "$TMP_DIR"
    TMP_DIR=""
    log_ok "nftables 规则已成功加载 (表名: inet ${TABLE_NAME})"
}

update_rules() {
    check_nft_permission

    TMP_DIR="$(mktemp -d)"
    log_info "正在拉取最新中国大陆 IPv4 / IPv6 地址库..."
    download_ipv4_list "${TMP_DIR}/cn_ipv4.txt"
    download_ipv6_list "${TMP_DIR}/cn_ipv6.txt"

    mkdir -p "$DATA_DIR"
    cp -f "${TMP_DIR}/cn_ipv4.txt" "$IPV4_FILE"
    cp -f "${TMP_DIR}/cn_ipv6.txt" "$IPV6_FILE"
    chmod 600 "$IPV4_FILE" "$IPV6_FILE"

    rm -rf "$TMP_DIR"
    TMP_DIR=""

    apply_rules_from_files
}

setup_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        log_warn "当前系统未检测到 systemd，跳过开机自启与定时任务配置"
        return 0
    fi

    log_info "正在配置 systemd 开机自启与每日 IP 库自动更新任务..."

    local self_path
    self_path="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
    if [[ "$self_path" != "$BIN_PATH" ]]; then
        cp -f "$self_path" "$BIN_PATH"
    fi
    sed -i 's/\r$//' "$BIN_PATH"
    chmod 755 "$BIN_PATH"

    # 1. 开机自启加载规则服务（使用 apply 分批加载本地缓存，不存在则自动 update）
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Block Outbound Connections to China Mainland (nftables)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'if [ -s "${IPV4_FILE}" ] && [ -s "${IPV6_FILE}" ]; then "${BIN_PATH}" apply; else "${BIN_PATH}" update; fi'
ExecStop=/bin/sh -c 'nft delete table inet ${TABLE_NAME} 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    # 2. 每日更新 IP 库服务
    cat > "$UPDATE_SERVICE_FILE" << EOF
[Unit]
Description=Daily Update of China Mainland IP List for block2cn
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${BIN_PATH} update
EOF

    # 3. 每日更新 Timer
    cat > "$UPDATE_TIMER_FILE" << 'EOF'
[Unit]
Description=Daily Timer to Update China Mainland IP List (block2cn)

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1800

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now block2cn.service >/dev/null
    systemctl enable --now block2cn-update.timer >/dev/null
    log_ok "systemd 服务已启用，IP 库将每天 (daily) 自动更新"
}

verify_installation() {
    echo ""
    log_info "==================== 开始自动检测拦截效果 ===================="
    local pass_all=0

    # 检测 1：检查 nftables 表是否存在
    if nft list table inet "$TABLE_NAME" >/dev/null 2>&1; then
        log_ok "[检测 1/4] 内核 nftables 表 (inet ${TABLE_NAME}) 已加载"
    else
        log_error "[检测 1/4] 内核中未找到 nftables 表 (inet ${TABLE_NAME})"
        pass_all=1
    fi

    # 检测 2：检查 systemd 定时器状态
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet block2cn-update.timer; then
            log_ok "[检测 2/4] 每日自动更新定时器 (block2cn-update.timer) 运行正常"
        else
            log_error "[检测 2/4] 每日自动更新定时器 (block2cn-update.timer) 未启动"
            pass_all=1
        fi
    else
        log_warn "[检测 2/4] 无 systemd 环境，已跳过定时器检查"
    fi

    # 检测 3：测试向中国大陆 IP 发起出站连接（预期应当被立即拦截失败）
    local cn_test_ips=("223.5.5.5" "119.29.29.29")
    local blocked_count=0
    for ip in "${cn_test_ips[@]}"; do
        if ! curl -fsSL --connect-timeout 3 --max-time 4 "https://${ip}" >/dev/null 2>&1; then
            blocked_count=$((blocked_count + 1))
        else
            log_error "警告：向中国大陆 IP (${ip}) 的出站连接未被阻断！"
        fi
    done

    local pkt_counter
    pkt_counter=$((nft list chain inet "$TABLE_NAME" output 2>/dev/null || true) | awk '{for(i=1;i<=NF;i++) if($i=="packets") sum+=$(i+1)} END {print sum+0}')

    if [[ "$blocked_count" -eq "${#cn_test_ips[@]}" ]]; then
        log_ok "[检测 3/4] 中国大陆 IP (${cn_test_ips[*]}) 出站连接已被成功阻断 (累计已拦截数据包: ${pkt_counter})"
    else
        log_error "[检测 3/4] 中国大陆 IP 出站拦截测试未完全通过"
        pass_all=1
    fi

    # 检测 4：测试向境外 IP 发起出站连接（预期应当正常连通）
    if curl -fsSLI --connect-timeout 5 --max-time 8 "https://1.1.1.1" >/dev/null 2>&1 || \
       curl -fsSLI --connect-timeout 5 --max-time 8 "https://8.8.8.8" >/dev/null 2>&1; then
        log_ok "[检测 4/4] 境外 IP (1.1.1.1 / 8.8.8.8) 出站连接正常，未受影响"
    else
        log_warn "[检测 4/4] 境外测试 IP 连接超时，请检查 VPS 本身国际网络连通性"
    fi

    echo -e "${BLUE}==============================================================${NC}"
    if [[ "$pass_all" -eq 0 ]]; then
        log_ok "结论：禁止出站连接到中国大陆已成功生效！"
    else
        log_error "结论：部分检测项未通过，请检查上方日志输出。"
        return 1
    fi
}

do_install() {
    check_root "$@"
    install_dependencies
    check_nft_permission
    update_rules
    setup_systemd
    verify_installation
}

do_uninstall() {
    check_root "$@"
    log_info "正在卸载 block2cn 并清理规则..."

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop block2cn-update.timer 2>/dev/null || true
        systemctl disable block2cn-update.timer 2>/dev/null || true
        systemctl stop block2cn-update.service 2>/dev/null || true
        systemctl stop block2cn.service 2>/dev/null || true
        systemctl disable block2cn.service 2>/dev/null || true
        rm -f "$UPDATE_TIMER_FILE" "$UPDATE_SERVICE_FILE" "$SERVICE_FILE"
        systemctl daemon-reload 2>/dev/null || true
        log_ok "已移除 systemd 服务与每日更新定时任务"
    fi

    if command -v nft >/dev/null 2>&1; then
        if nft list table inet "$TABLE_NAME" >/dev/null 2>&1; then
            nft delete table inet "$TABLE_NAME"
            log_ok "已从内核移除 nftables 表: inet ${TABLE_NAME}"
        fi
    fi

    rm -rf "$DATA_DIR"
    rm -f "/etc/nftables.d/block2cn.nft"
    rm -f "$BIN_PATH"
    log_ok "已清理数据目录 ${DATA_DIR} 与脚本 ${BIN_PATH}"
    log_ok "卸载完成，已恢复向中国大陆的出站连接。"
}

do_status() {
    check_root "$@"
    check_nft_permission
    if nft list table inet "$TABLE_NAME" >/dev/null 2>&1; then
        log_ok "当前状态：已启用 (表 inet ${TABLE_NAME} 存在)"
        echo ""
        log_info "当前输出链规则与拦截计数："
        nft list chain inet "$TABLE_NAME" output
        echo ""
        if command -v systemctl >/dev/null 2>&1; then
            log_info "定时任务状态："
            systemctl list-timers block2cn-update.timer --no-pager 2>/dev/null || true
        fi
        verify_installation
    else
        log_warn "当前状态：未启用 (内核中不存在表 inet ${TABLE_NAME})"
    fi
}

usage() {
    cat << EOF
用法: sudo bash $(basename "$0") <command>

可用命令:
  install     安装并启用禁止出站连接到中国大陆，配置每天自动更新 IP 库，并自动检测是否生效
  uninstall   卸载并清除所有 nftables 规则、配置文件与定时任务
  update      立即拉取最新中国大陆 IPv4/IPv6 地址库并重载规则
  apply       从本地已缓存的 IP 库文件分批重新加载 nftables 规则
  status      查看当前拦截计数状态并重新运行生效检测
EOF
}

main() {
    local action="${1:-}"
    case "$action" in
        install)
            do_install "$@"
            ;;
        uninstall|remove)
            do_uninstall "$@"
            ;;
        update)
            check_root "$@"
            update_rules
            ;;
        apply)
            check_root "$@"
            check_nft_permission
            apply_rules_from_files
            ;;
        status|test|verify)
            do_status "$@"
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
