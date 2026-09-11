#!/usr/bin/env bash
# ==============================================================================
# Project: VPS-Sing-box
# Script: clean.sh (VPS 环境除旧与旧代理清理工具)
# Description: 智能扫描、识别并清理 VPS 上的旧代理残留与无效配置，严格保护网站、数据库及 Tailscale 等业务服务
# Repository: https://github.com/luckyjamesriver/VPS-Sing-box
# License: MIT
# ==============================================================================

set -e

# --- Color Constants ---
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PURPLE="\033[35m"
CYAN="\033[1;36m"
PLAIN="\033[0m"

# --- Output Helpers ---
info()    { echo -e "${GREEN}[INFO]${PLAIN} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${PLAIN} $*"; }
error()   { echo -e "${RED}[ERROR]${PLAIN} $*" >&2; }
tip()     { echo -e "${BLUE}[TIP]${PLAIN} $*"; }
success() { echo -e "${CYAN}[SUCCESS]${PLAIN} $*"; }
title()   { echo -e "\n${PURPLE}====================================================${PLAIN}\n${PURPLE}  $*${PLAIN}\n${PURPLE}====================================================${PLAIN}"; }

# --- Check Environment ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本必须以 root 用户运行！请执行: sudo -i 或 sudo bash $0"
        exit 1
    fi
}

# --- Service Definitions & Whitelist ---
# 严格保护的生产/业务/VPN/系统服务关键字（绝对不主动清理）
PROTECTED_SERVICES=(
    "tailscale" "tailscaled" "wireguard" "wg-quick"
    "nginx" "caddy" "apache2" "httpd" "lighttpd" "openresty"
    "mysql" "mariadb" "mysqld" "postgresql" "postgres" "redis" "redis-server" "mongod" "mongodb"
    "php" "php7.4-fpm" "php8.0-fpm" "php8.1-fpm" "php8.2-fpm" "php8.3-fpm" "php-fpm"
    "docker" "dockerd" "containerd" "podman"
    "ssh" "sshd" "dropbear"
    "ufw" "firewalld" "nftables" "iptables" "fail2ban"
    "cron" "crond" "systemd" "rsyslog" "network" "networking" "resolved" "timesyncd"
)

# 已知的常见旧代理服务服务名
LEGACY_PROXY_SERVICES=(
    "xray" "xray@*" "v2ray" "v2ray@*"
    "hysteria-server" "hysteria" "hysteria-server@*" "hysteria2"
    "tuic" "tuic-server" "tuic@*"
    "shadowsocks" "shadowsocks-libev" "shadowsocks-rust" "shadowsocks-server" "ss-server"
    "trojan" "trojan-go" "naiveproxy" "naive" "brook" "gost" "snell"
    "clash" "mihomo" "v2bx" "xrayr"
)

# 常见旧代理二进制路径
LEGACY_BIN_PATHS=(
    "/usr/local/bin/xray" "/usr/bin/xray"
    "/usr/local/bin/v2ray" "/usr/bin/v2ray"
    "/usr/local/bin/hysteria" "/usr/bin/hysteria"
    "/usr/local/bin/tuic-server" "/usr/local/bin/tuic"
    "/usr/local/bin/trojan-go" "/usr/local/bin/trojan"
    "/usr/local/bin/ss-server" "/usr/local/bin/ssserver"
    "/usr/local/bin/naive" "/usr/bin/naive"
    "/usr/local/bin/brook" "/usr/bin/brook"
    "/usr/local/bin/gost" "/usr/bin/gost"
    "/usr/local/bin/snell-server"
    "/usr/local/bin/clash" "/usr/local/bin/mihomo"
    "/usr/local/bin/XrayR" "/usr/local/bin/V2bX"
)

# 常见旧代理配置目录
LEGACY_CONFIG_DIRS=(
    "/etc/xray" "/usr/local/etc/xray"
    "/etc/v2ray" "/usr/local/etc/v2ray"
    "/etc/hysteria" "/usr/local/etc/hysteria"
    "/etc/tuic" "/usr/local/etc/tuic"
    "/etc/trojan-go" "/etc/trojan"
    "/etc/shadowsocks" "/etc/shadowsocks-libev" "/etc/shadowsocks-rust"
    "/etc/clash" "/etc/mihomo"
    "/etc/XrayR" "/etc/V2bX"
    "/var/log/xray" "/var/log/v2ray" "/var/log/hysteria"
)

# Sing-box 相关路径
SB_SERVICE_FILE="/etc/systemd/system/sing-box.service"
SB_BIN="/usr/local/bin/sing-box"
SB_DIR="/etc/sing-box"
SB_CLIENT_DIR="/etc/sing-box/client"

# 临时扫描缓存数组
FOUND_PROTECTED=()
FOUND_LEGACY_SERVICES=()
FOUND_LEGACY_BINS=()
FOUND_LEGACY_DIRS=()
FOUND_SB=()

# --- 1. 扫描与探测引擎 ---
scan_system() {
    FOUND_PROTECTED=()
    FOUND_LEGACY_SERVICES=()
    FOUND_LEGACY_BINS=()
    FOUND_LEGACY_DIRS=()
    FOUND_SB=()

    # 1. 扫描正在运行及已启用的 systemd 服务
    local all_units
    all_units=$(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' || true)

    for unit in ${all_units}; do
        local unit_base="${unit%.service}"
        
        # 检查是否为保护服务
        local is_prot=0
        for p in "${PROTECTED_SERVICES[@]}"; do
            if [[ "${unit_base}" == "${p}"* || "${unit}" == "${p}"* ]]; then
                is_prot=1
                local active_state
                active_state=$(systemctl is-active "${unit}" 2>/dev/null || echo "inactive")
                FOUND_PROTECTED+=("${unit} [${active_state}]")
                break
            fi
        done
        [[ ${is_prot} -eq 1 ]] && continue

        # 检查是否为 Sing-box 服务
        if [[ "${unit}" == "sing-box.service" || "${unit_base}" == "sing-box" ]]; then
            local sb_state
            sb_state=$(systemctl is-active "${unit}" 2>/dev/null || echo "inactive")
            FOUND_SB+=("${unit} [${sb_state}]")
            continue
        fi

        # 检查是否为已知旧代理服务
        for l in "${LEGACY_PROXY_SERVICES[@]}"; do
            if [[ "${unit_base}" == ${l} || "${unit}" == ${l}.service ]]; then
                local l_state
                l_state=$(systemctl is-active "${unit}" 2>/dev/null || echo "inactive")
                FOUND_LEGACY_SERVICES+=("${unit} [${l_state}]")
                break
            fi
        done
    done

    # 2. 扫描旧代理二进制文件
    for bin in "${LEGACY_BIN_PATHS[@]}"; do
        if [[ -f "${bin}" ]]; then
            FOUND_LEGACY_BINS+=("${bin}")
        fi
    done

    # 3. 扫描旧代理配置目录
    for dir in "${LEGACY_CONFIG_DIRS[@]}"; do
        if [[ -d "${dir}" ]]; then
            FOUND_LEGACY_DIRS+=("${dir}")
        fi
    done
}

# --- 2. 展示系统网络监听端口 ---
show_network_ports() {
    title "当前 VPS 网络监听端口与进程分布"
    echo -e "${YELLOW}扫描正在监听的 TCP / UDP 网络端口:${PLAIN}\n"
    
    if command -v ss >/dev/null 2>&1; then
        echo -e "${CYAN}%-6s %-25s %-25s %-20s${PLAIN}" "协议" "本地监听地址:端口" "进程信息" "服务推断"
        echo -e "----------------------------------------------------------------------------------"
        ss -tulnp 2>/dev/null | awk 'NR>1 {
            proto=$1;
            addr=$5;
            proc=$7;
            if (addr ~ /:22$/ || addr ~ /:2222$/) hint="[SSH 远程管理]";
            else if (addr ~ /:80$/ || addr ~ /:443$/) hint="[Web 网站服务 (Nginx/Caddy)]";
            else if (addr ~ /:3306$/ || addr ~ /:5432$/ || addr ~ /:6379$/) hint="[数据库服务]";
            else if (proc ~ /sing-box/) hint="[Sing-box 节点入站]";
            else if (proc ~ /tailscaled/) hint="[Tailscale Mesh VPN]";
            else if (proc ~ /xray|v2ray|hysteria|tuic|trojan/) hint="[⚠️ 旧代理服务]";
            else hint="[系统/其他应用]";
            printf "%-6s %-25s %-25s %-20s\n", proto, addr, proc, hint;
        }'
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tulnp 2>/dev/null
    else
        warn "未检测到 ss 或 netstat 命令，跳过端口列表打印。"
    fi
    echo ""
}

# --- 3. 展示 Sing-box 详细配置内容 ---
show_singbox_details() {
    title "Sing-box 当前服务与配置详情"
    
    if [[ ! -f "${SB_BIN}" && ! -f "${SB_DIR}/config.json" ]]; then
        echo -e "${YELLOW}未检测到安装中的 Sing-box 服务。${PLAIN}\n"
        return 0
    fi

    if [[ -f "${SB_BIN}" ]]; then
        local sb_ver
        sb_ver=$("${SB_BIN}" version 2>/dev/null | head -n 1 || echo "未知版本")
        echo -e " Sing-box 核心程序 : ${GREEN}${SB_BIN}${PLAIN} (${sb_ver})"
    fi

    local sb_status="未运行"
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        sb_status="${GREEN}正在运行 (Active)${PLAIN}"
    else
        sb_status="${RED}已停止 (Inactive)${PLAIN}"
    fi
    echo -e " Systemd 服务状态  : ${sb_status}"
    echo -e " 服务端配置目录    : ${BLUE}${SB_DIR}${PLAIN}"
    
    if [[ -f "${SB_DIR}/node_info.json" ]]; then
        echo -e "\n${CYAN}[当前节点配置摘要]${PLAIN}"
        local domain uuid pt_tcp pt_grpc pt_hy2 pt_tuic
        domain=$(jq -r '.domain // "未记录"' "${SB_DIR}/node_info.json" 2>/dev/null)
        uuid=$(jq -r '.uuid // "未记录"' "${SB_DIR}/node_info.json" 2>/dev/null)
        pt_tcp=$(jq -r '.port_reality_tcp // "未配置"' "${SB_DIR}/node_info.json" 2>/dev/null)
        pt_grpc=$(jq -r '.port_reality_grpc // "未配置"' "${SB_DIR}/node_info.json" 2>/dev/null)
        pt_hy2=$(jq -r '.port_hy2 // "未配置"' "${SB_DIR}/node_info.json" 2>/dev/null)
        pt_tuic=$(jq -r '.port_tuic // "未配置"' "${SB_DIR}/node_info.json" 2>/dev/null)
        
        echo -e "  - 绑定域名       : ${YELLOW}${domain}${PLAIN}"
        echo -e "  - 核心 UUID      : ${YELLOW}${uuid}${PLAIN}"
        echo -e "  - Reality TCP 端口: ${GREEN}${pt_tcp}${PLAIN}"
        echo -e "  - Reality gRPC 端口: ${GREEN}${pt_grpc}${PLAIN}"
        echo -e "  - Hysteria 2 端口: ${GREEN}${pt_hy2}${PLAIN}"
        echo -e "  - TUIC v5 端口   : ${GREEN}${pt_tuic}${PLAIN}"
    fi

    if [[ -f "${SB_DIR}/cert.pem" ]]; then
        local cert_exp
        cert_exp=$(openssl x509 -enddate -noout -in "${SB_DIR}/cert.pem" 2>/dev/null | cut -d= -f2 || echo "未知")
        echo -e "  - 10年自签证书   : ${GREEN}${SB_DIR}/cert.pem${PLAIN} (有效期至: ${cert_exp})"
    fi

    if [[ -f "${SB_CLIENT_DIR}/config.json" ]]; then
        echo -e "  - 客户端配置文件 : ${GREEN}${SB_CLIENT_DIR}/config.json${PLAIN} (已生成)"
    fi
    echo ""
}

# --- 4. 展示综合扫描报告 ---
show_scan_report() {
    title "VPS 环境服务扫描与分类诊断报告"

    # A. 受保护的业务服务
    echo -e "${GREEN}🛡️  受保护业务与系统服务 (严格隔离保护，绝不改动或损坏):${PLAIN}"
    if [[ ${#FOUND_PROTECTED[@]} -gt 0 ]]; then
        for item in "${FOUND_PROTECTED[@]}"; do
            echo -e "   ✔  ${GREEN}${item}${PLAIN}"
        done
    else
        echo -e "   （未检测到常见的独立 Nginx / MySQL / Tailscale 服务）"
    fi
    echo ""

    # B. Sing-box 服务
    echo -e "${CYAN}⚡  Sing-box 核心与管理体系:${PLAIN}"
    if [[ ${#FOUND_SB[@]} -gt 0 || -f "${SB_BIN}" || -d "${SB_DIR}" ]]; then
        for item in "${FOUND_SB[@]}"; do
            echo -e "   ✔  ${CYAN}${item}${PLAIN}"
        done
        [[ -f "${SB_BIN}" ]] && echo -e "   ✔  二进制程序: ${SB_BIN}"
        [[ -d "${SB_DIR}" ]] && echo -e "   ✔  配置目录: ${SB_DIR}"
    else
        echo -e "   （未检测到 Sing-box 运行环境）"
    fi
    echo ""

    # C. 检测到的旧代理残留
    echo -e "${RED}🔍  已检测到的旧代理 / 历史遗留残留 (建议除旧清理):${PLAIN}"
    local legacy_found=0

    if [[ ${#FOUND_LEGACY_SERVICES[@]} -gt 0 ]]; then
        legacy_found=1
        echo -e "   【遗留守护服务】"
        for item in "${FOUND_LEGACY_SERVICES[@]}"; do
            echo -e "   ❌  ${YELLOW}${item}${PLAIN}"
        done
    fi

    if [[ ${#FOUND_LEGACY_BINS[@]} -gt 0 ]]; then
        legacy_found=1
        echo -e "   【遗留二进制程序】"
        for item in "${FOUND_LEGACY_BINS[@]}"; do
            echo -e "   ❌  ${YELLOW}${item}${PLAIN}"
        done
    fi

    if [[ ${#FOUND_LEGACY_DIRS[@]} -gt 0 ]]; then
        legacy_found=1
        echo -e "   【遗留配置与日志目录】"
        for item in "${FOUND_LEGACY_DIRS[@]}"; do
            echo -e "   ❌  ${YELLOW}${item}${PLAIN}"
        done
    fi

    if [[ ${legacy_found} -eq 0 ]]; then
        echo -e "   ${GREEN}✨ 系统非常干净，未发现常见的第三方旧代理残留！${PLAIN}"
    fi
    echo ""
}

# --- 5. 创建自动备份 ---
create_backup() {
    local backup_tar="/root/vps_cleanup_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    local items_to_backup=()

    [[ -d "${SB_DIR}" ]] && items_to_backup+=("${SB_DIR}")
    for d in "${FOUND_LEGACY_DIRS[@]}"; do
        [[ -d "${d}" ]] && items_to_backup+=("${d}")
    done

    if [[ ${#items_to_backup[@]} -gt 0 ]]; then
        info "正在为涉及的配置创建归档备份..."
        tar -czf "${backup_tar}" "${items_to_backup[@]}" 2>/dev/null || true
        success "备份已保存至: ${YELLOW}${backup_tar}${PLAIN}"
    fi
}

# --- 6. 执行清理动作: 仅清理第三方旧代理 ---
clean_legacy_proxies() {
    title "清理第三方旧代理与遗留组件"

    if [[ ${#FOUND_LEGACY_SERVICES[@]} -eq 0 && ${#FOUND_LEGACY_BINS[@]} -eq 0 && ${#FOUND_LEGACY_DIRS[@]} -eq 0 ]]; then
        info "系统中未发现第三方旧代理残留，无需清理。"
        return 0
    fi

    echo -e "即将清理以下第三方旧代理组件:"
    for s in "${FOUND_LEGACY_SERVICES[@]}"; do
        echo -e "  - 停止并禁用服务: ${RED}${s%% *}${PLAIN}"
    done
    for b in "${FOUND_LEGACY_BINS[@]}"; do
        echo -e "  - 删除执行文件  : ${RED}${b}${PLAIN}"
    done
    for d in "${FOUND_LEGACY_DIRS[@]}"; do
        echo -e "  - 删除配置目录  : ${RED}${d}${PLAIN}"
    done

    echo ""
    read -r -p "是否确认清理上述第三方旧代理组件？[y/N]: " confirm
    if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
        warn "已取消清理第三方旧代理。"
        return 0
    fi

    create_backup

    # 1. 停止并禁用服务
    for s in "${FOUND_LEGACY_SERVICES[@]}"; do
        local svc="${s%% *}"
        info "正在停止并清理服务: ${svc}..."
        systemctl stop "${svc}" >/dev/null 2>&1 || true
        systemctl disable "${svc}" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${svc}" "/lib/systemd/system/${svc}" "/usr/lib/systemd/system/${svc}" >/dev/null 2>&1 || true
    done
    systemctl daemon-reload >/dev/null 2>&1 || true

    # 2. 删除旧二进制
    for b in "${FOUND_LEGACY_BINS[@]}"; do
        info "正在删除旧程序: ${b}..."
        rm -f "${b}"
    done

    # 3. 删除旧配置目录
    for d in "${FOUND_LEGACY_DIRS[@]}"; do
        info "正在删除旧目录: ${d}..."
        rm -rf "${d}"
    done

    success "第三方旧代理与遗留组件清理完毕！"
}

# --- 7. 执行清理动作: 重置 / 卸载 Sing-box ---
clean_singbox() {
    title "重置 / 卸载 Sing-box 环境"

    if [[ ! -f "${SB_BIN}" && ! -d "${SB_DIR}" && ! -f "${SB_SERVICE_FILE}" ]]; then
        info "系统中未安装 Sing-box，无需清理。"
        return 0
    fi

    echo -e "${YELLOW}请选择 Sing-box 清理模式:${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN} 仅重置节点与配置（保留自签 10 年证书，方便无缝重新部署）"
    echo -e "  ${GREEN}2.${PLAIN} 完全卸载 Sing-box（删除二进制、所有配置文件、证书及快捷命令）"
    echo -e "  ${GREEN}0.${PLAIN} 取消返回"
    echo ""

    read -r -p "请输入选项 [0-2]: " sb_choice
    case "${sb_choice}" in
        1)
            read -r -p "确认清空 Sing-box 节点配置并重置？[y/N]: " cf
            if [[ "${cf}" == "y" || "${cf}" == "Y" ]]; then
                create_backup
                systemctl stop sing-box >/dev/null 2>&1 || true
                rm -f "${SB_DIR}/config.json" "${SB_DIR}/node_info.json"
                rm -rf "${SB_CLIENT_DIR}" "${SB_DIR}/client_config.json"
                success "Sing-box 节点与客户端配置已清空，保留了证书文件 (${SB_DIR}/cert.pem)。"
                tip "现在可以重新运行安装脚本生成全新节点！"
            else
                info "已取消。"
            fi
            ;;
        2)
            read -r -p "确认完全卸载 Sing-box？[y/N]: " cf
            if [[ "${cf}" == "y" || "${cf}" == "Y" ]]; then
                create_backup
                systemctl stop sing-box >/dev/null 2>&1 || true
                systemctl disable sing-box >/dev/null 2>&1 || true
                rm -f "${SB_SERVICE_FILE}"
                systemctl daemon-reload
                rm -f "${SB_BIN}"
                rm -rf "${SB_DIR}"
                rm -f "/usr/bin/vps" "/usr/local/bin/vps" "/usr/bin/sb" "/usr/local/bin/sb"
                success "Sing-box 已完全从系统中卸载干净！"
            else
                info "已取消。"
            fi
            ;;
        0|*)
            info "已取消 Sing-box 清理。"
            ;;
    esac
}

# --- 8. 执行全量深度除旧 (一键除旧迎新) ---
clean_all_deep() {
    title "全量深度除旧（清理所有旧代理残留 + 完全重置 Sing-box）"
    echo -e "${RED}⚠️  注意：此操作将清理所有第三方旧代理（Xray/V2Ray/Hysteria/Trojan等）以及 Sing-box 服务！${PLAIN}"
    echo -e "${GREEN}🛡️  受保护服务（Tailscale、Nginx、Caddy、WordPress、MySQL 等）将得到 100% 绝对保护！${PLAIN}\n"

    read -r -p "是否确认执行全量深度清理？[y/N]: " confirm
    if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
        warn "已取消全量深度清理。"
        return 0
    fi

    create_backup

    # 1. 清理第三方旧代理
    for s in "${FOUND_LEGACY_SERVICES[@]}"; do
        local svc="${s%% *}"
        info "正在停止并清理服务: ${svc}..."
        systemctl stop "${svc}" >/dev/null 2>&1 || true
        systemctl disable "${svc}" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${svc}" "/lib/systemd/system/${svc}" "/usr/lib/systemd/system/${svc}" >/dev/null 2>&1 || true
    done
    for b in "${FOUND_LEGACY_BINS[@]}"; do
        rm -f "${b}"
    done
    for d in "${FOUND_LEGACY_DIRS[@]}"; do
        rm -rf "${d}"
    done

    # 2. 清理 Sing-box
    systemctl stop sing-box >/dev/null 2>&1 || true
    systemctl disable sing-box >/dev/null 2>&1 || true
    rm -f "${SB_SERVICE_FILE}"
    systemctl daemon-reload
    rm -f "${SB_BIN}"
    rm -rf "${SB_DIR}"
    rm -f "/usr/bin/vps" "/usr/local/bin/vps" "/usr/bin/sb" "/usr/local/bin/sb"

    success "🎉 全量深度除旧完成！VPS 当前代理环境已完全纯净化。"
    tip "您可以立即运行安装脚本部署全新的 Sing-box 四合一服务。"
}

# --- 交互主菜单 ---
clean_menu() {
    check_root
    scan_system

    clear
    echo -e "${PURPLE}====================================================${PLAIN}"
    echo -e "${CYAN}        VPS-Sing-box 智能环境除旧与清理工具         ${PLAIN}"
    echo -e "${BLUE}    GitHub: https://github.com/luckyjamesriver/VPS-Sing-box${PLAIN}"
    echo -e "${PURPLE}====================================================${PLAIN}"

    show_scan_report
    show_singbox_details
    show_network_ports

    echo -e "${PURPLE}====================================================${PLAIN}"
    echo -e "${YELLOW}请选择除旧清理操作:${PLAIN}"
    echo -e "----------------------------------------------------"
    echo -e "${GREEN}1.${PLAIN} 仅清理【第三方旧代理残留】(Xray/V2Ray/Hysteria/Trojan等, 保留 Sing-box)"
    echo -e "${GREEN}2.${PLAIN} 管理与清理【Sing-box 配置 / 卸载】"
    echo -e "${GREEN}3.${PLAIN} 【全量深度除旧】(清理所有旧代理 + 重置 Sing-box, 为全新安装做准备)"
    echo -e "${GREEN}4.${PLAIN} 重新刷新扫描系统服务与端口"
    echo -e "${GREEN}0.${PLAIN} 退出清理脚本"
    echo -e "----------------------------------------------------"

    read -r -p "请输入选项 [0-4]: " menu_choice
    case "${menu_choice}" in
        1)
            clean_legacy_proxies
            ;;
        2)
            clean_singbox
            ;;
        3)
            clean_all_deep
            ;;
        4)
            info "正在重新扫描..."
            sleep 1
            clean_menu
            ;;
        0)
            info "退出清理工具。"
            exit 0
            ;;
        *)
            warn "无效选项，请重新输入！"
            sleep 1
            clean_menu
            ;;
    esac
}

# --- CLI 直接调用入口 ---
if [[ $# -gt 0 ]]; then
    check_root
    scan_system
    case "$1" in
        scan|report|status)
            show_scan_report
            show_singbox_details
            show_network_ports
            ;;
        legacy|old)
            clean_legacy_proxies
            ;;
        sb|singbox)
            clean_singbox
            ;;
        all|deep)
            clean_all_deep
            ;;
        *)
            echo "用法: $0 [scan|legacy|singbox|all]"
            exit 1
            ;;
    esac
else
    clean_menu
fi
