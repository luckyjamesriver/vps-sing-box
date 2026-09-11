#!/usr/bin/env bash
# ==============================================================================
# Project: VPS-Sing-box
# Script: clean.sh (VPS 环境除旧、安全扫描、完整备份与一键恢复工具)
# Description: 智能扫描 VPS 旧代理残留，提供一键完整备份与一键恢复功能，
#              全方位保护 Tailscale、WordPress、Web 网站及数据库等生产服务。
# Repository: https://github.com/luckyjamesriver/VPS-Sing-box
# License: MIT
# ==============================================================================

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

check_dependencies() {
    local missing=()
    for cmd in jq curl ss tar gzip; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            missing+=("${cmd}")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        info "正在检测并配置基础工具 (${missing[*]})..."
        if command -v apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y >/dev/null 2>&1 || true
            apt-get install -y --no-install-recommends "${missing[@]}" >/dev/null 2>&1 || true
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "${missing[@]}" >/dev/null 2>&1 || true
        fi
    fi
}

# --- Service Definitions & Whitelist ---
PROTECTED_SERVICES=(
    "tailscaled" "tailscale" "wg-quick@*" "wireguard"
    "nginx" "caddy" "apache2" "httpd" "lighttpd" "openresty"
    "mysql" "mariadb" "postgresql" "redis" "redis-server" "mongod"
    "docker" "containerd" "podman"
    "ssh" "sshd" "dropbear"
    "ufw" "firewalld" "fail2ban" "cron"
)

LEGACY_PROXY_SERVICES=(
    "xray" "xray@*" "v2ray" "v2ray@*"
    "hysteria-server" "hysteria" "hysteria-server@*" "hysteria2"
    "tuic" "tuic-server" "tuic@*"
    "shadowsocks" "shadowsocks-libev" "shadowsocks-rust" "shadowsocks-server" "ss-server"
    "trojan" "trojan-go" "naiveproxy" "naive" "brook" "gost" "snell"
    "clash" "mihomo" "v2bx" "xrayr" "v2ray-agent"
)

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
    "/etc/v2ray-agent/sing-box/sing-box"
    "/etc/v2ray-agent/xray/xray"
    "/etc/v2ray-agent/v2ray/v2ray"
)

LEGACY_CONFIG_DIRS=(
    "/etc/v2ray-agent" "/usr/local/etc/v2ray-agent"
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

SB_STANDARD_DIR="/etc/sing-box"
SB_STANDARD_BIN="/usr/local/bin/sing-box"
SB_STANDARD_SERVICE="/etc/systemd/system/sing-box.service"
BACKUP_DIR="/var/backups/sing-box"

FOUND_PROTECTED=()
FOUND_LEGACY_SERVICES=()
FOUND_LEGACY_BINS=()
FOUND_LEGACY_DIRS=()
FOUND_SB_SERVICES=()
FOUND_SB_EXECS=()

# --- 1. 高性能系统服务与进程探查 ---
scan_system() {
    FOUND_PROTECTED=()
    FOUND_LEGACY_SERVICES=()
    FOUND_LEGACY_BINS=()
    FOUND_LEGACY_DIRS=()
    FOUND_SB_SERVICES=()
    FOUND_SB_EXECS=()

    check_dependencies

    # 1. 检查 Sing-box 服务状态与运行文件
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        FOUND_SB_SERVICES+=("sing-box.service [运行中]")
    elif systemctl is-enabled --quiet sing-box 2>/dev/null; then
        FOUND_SB_SERVICES+=("sing-box.service [已安装/未运行]")
    fi

    # 探查 sing-box 执行命令
    local sb_exec
    sb_exec=$(systemctl cat sing-box.service 2>/dev/null | grep -E '^ExecStart=' | cut -d'=' -f2- | head -n 1 || true)
    if [[ -n "${sb_exec}" ]]; then
        FOUND_SB_EXECS+=("${sb_exec}")
    fi

    # 2. 检查受保护服务
    for p in "${PROTECTED_SERVICES[@]}"; do
        if systemctl is-active --quiet "${p}" 2>/dev/null; then
            FOUND_PROTECTED+=("${p}.service [运行中]")
        fi
    done

    # 3. 检查旧代理服务
    for l in "${LEGACY_PROXY_SERVICES[@]}"; do
        if systemctl is-active --quiet "${l}" 2>/dev/null; then
            FOUND_LEGACY_SERVICES+=("${l}.service [运行中]")
        elif systemctl is-enabled --quiet "${l}" 2>/dev/null; then
            FOUND_LEGACY_SERVICES+=("${l}.service [已安装/未运行]")
        fi
    done

    # 4. 扫描旧二进制
    for bin in "${LEGACY_BIN_PATHS[@]}"; do
        [[ -f "${bin}" ]] && FOUND_LEGACY_BINS+=("${bin}")
    done

    # 5. 扫描旧目录
    for dir in "${LEGACY_CONFIG_DIRS[@]}"; do
        [[ -d "${dir}" ]] && FOUND_LEGACY_DIRS+=("${dir}")
    done
}

# --- 2. 展示系统网络监听端口 ---
show_network_ports() {
    title "当前 VPS 网络监听端口与进程分布"
    if command -v ss >/dev/null 2>&1; then
        printf "${CYAN}%-6s %-25s %-32s %-20s${PLAIN}\n" "协议" "本地监听地址:端口" "进程信息" "服务推断"
        echo -e "----------------------------------------------------------------------------------"
        ss -tulnp 2>/dev/null | awk 'NR>1 {
            proto=$1;
            addr=$5;
            proc=$7;
            if (addr ~ /:22$/ || addr ~ /:2222$/) hint="[SSH 远程管理]";
            else if (addr ~ /:80$/ || addr ~ /:443$/) hint="[Web 网站服务 (Nginx/Caddy)]";
            else if (addr ~ /:3306$/ || addr ~ /:5432$/ || addr ~ /:6379$/) hint="[数据库服务]";
            else if (proc ~ /sing-box/) hint="[Sing-box 代理入站]";
            else if (proc ~ /tailscaled/) hint="[Tailscale Mesh VPN]";
            else if (proc ~ /xray|v2ray|hysteria|tuic|trojan/) hint="[⚠️ 旧代理服务]";
            else hint="[系统/其他应用]";
            printf "%-6s %-25s %-32s %-20s\n", proto, addr, proc, hint;
        }' || true
    fi
    echo ""
}

# --- 3. 展示综合扫描诊断报告 ---
show_scan_report() {
    title "VPS 环境服务扫描与分类诊断报告"

    echo -e "${GREEN}🛡️  受保护业务与系统服务 (严格隔离保护，绝不改动或损坏):${PLAIN}"
    if [[ ${#FOUND_PROTECTED[@]} -gt 0 ]]; then
        for item in "${FOUND_PROTECTED[@]}"; do
            echo -e "   ✔  ${GREEN}${item}${PLAIN}"
        done
    else
        echo -e "   （未检测到运行中的独立 Nginx / MySQL / Tailscale 等服务）"
    fi
    echo ""

    echo -e "${CYAN}⚡  Sing-box 状态与环境:${PLAIN}"
    if [[ ${#FOUND_SB_SERVICES[@]} -gt 0 || -f "${SB_STANDARD_BIN}" || -d "${SB_STANDARD_DIR}" ]]; then
        for item in "${FOUND_SB_SERVICES[@]}"; do
            echo -e "   ✔  ${CYAN}${item}${PLAIN}"
        done
        for ex in "${FOUND_SB_EXECS[@]}"; do
            echo -e "   ✔  服务命令: ${ex}"
        done
        [[ -f "${SB_STANDARD_BIN}" ]] && echo -e "   ✔  主程序: ${SB_STANDARD_BIN}"
        [[ -d "${SB_STANDARD_DIR}" ]] && echo -e "   ✔  配置目录: ${SB_STANDARD_DIR}"
    else
        echo -e "   （未检测到 Sing-box 标准运行环境）"
    fi
    echo ""

    echo -e "${RED}🔍  已检测到的旧代理 / 第三方遗留残留 (建议除旧清理):${PLAIN}"
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
        echo -e "   【遗留配置与数据目录】"
        for item in "${FOUND_LEGACY_DIRS[@]}"; do
            echo -e "   ❌  ${YELLOW}${item}${PLAIN}"
        done
    fi

    if [[ ${legacy_found} -eq 0 ]]; then
        echo -e "   ${GREEN}✔ 未检测到已知的第三方旧代理残留，系统环境极度纯净！${PLAIN}"
    fi
    echo ""
}

# --- 4. 核心功能：Sing-box 一键完整备份 ---
backup_singbox() {
    title "执行 Sing-box 一键完整备份"
    mkdir -p "${BACKUP_DIR}"

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/sing-box-backup-${timestamp}.tar.gz"

    local backup_items=()
    [[ -d "${SB_STANDARD_DIR}" ]] && backup_items+=("${SB_STANDARD_DIR}")
    [[ -f "${SB_STANDARD_BIN}" ]] && backup_items+=("${SB_STANDARD_BIN}")
    [[ -f "${SB_STANDARD_SERVICE}" ]] && backup_items+=("${SB_STANDARD_SERVICE}")

    # 同时备份历史证书目录 (如存在)
    if [[ -d "/etc/v2ray-agent/tls" ]]; then
        backup_items+=("/etc/v2ray-agent/tls")
    fi
    if [[ -d "/root/cert" ]]; then
        backup_items+=("/root/cert")
    fi

    if [[ ${#backup_items[@]} -eq 0 ]]; then
        warn "未检测到 Sing-box 相关的配置文件或二进制，无需创建备份。"
        return 0
    fi

    info "正在打包以下文件至备份档案:"
    for bi in "${backup_items[@]}"; do
        echo -e "  - ${bi}"
    done

    tar -czf "${backup_file}" "${backup_items[@]}" 2>/dev/null || {
        error "创建备份失败！请检查磁盘空间与权限。"
        return 1
    }

    local b_size
    b_size=$(du -h "${backup_file}" | awk '{print $1}')
    success "🎉 Sing-box 完整备份创建成功！"
    echo -e "  - 备份档案路径: ${GREEN}${backup_file}${PLAIN}"
    echo -e "  - 档案大小: ${CYAN}${b_size}${PLAIN}"
    echo -e "  - 备份包含: 配置目录(/etc/sing-box), 客户端文件, 证书密钥, 主程序, Systemd 服务"
    tip "您可以在任何时候使用本脚本的【一键恢复】功能将节点完全还原！"
    echo ""
}

# --- 5. 核心功能：Sing-box 一键恢复备份 ---
restore_singbox() {
    title "Sing-box 一键恢复历史备份"

    local backup_files=()
    while IFS= read -r f; do
        [[ -n "${f}" ]] && backup_files+=("${f}")
    done < <(find "${BACKUP_DIR}" /root /var/backups -maxdepth 2 -type f \( -name "*sing-box*.tar.gz" -o -name "*vps_proxy_backup*.tar.gz" -o -name "pre-clean-backup*.tar.gz" \) 2>/dev/null | sort -r || true)

    if [[ ${#backup_files[@]} -eq 0 ]]; then
        warn "未在 ${BACKUP_DIR} 或 /root 下检测到任何历史备份文件 (.tar.gz)！"
        echo ""
        read -r -p "请输入自定义备份档案的完整绝对路径 (直接回车取消): " custom_path < /dev/tty
        if [[ -n "${custom_path}" && -f "${custom_path}" ]]; then
            backup_files=("${custom_path}")
        else
            warn "操作已取消。"
            return 0
        fi
    fi

    echo -e "${CYAN}检测到以下历史备份档案，请选择要恢复的版本:${PLAIN}\n"
    local idx=1
    for bf in "${backup_files[@]}"; do
        local f_size f_date
        f_size=$(du -h "${bf}" 2>/dev/null | awk '{print $1}')
        f_date=$(date -r "${bf}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "未知时间")
        echo -e "  ${GREEN}[${idx}]${PLAIN} ${bf}  (${CYAN}大小: ${f_size}${PLAIN}, 时间: ${f_date})"
        ((idx++))
    done
    echo -e "  ${GREEN}[c]${PLAIN} 手动输入其他备份文件路径"
    echo -e "  ${GREEN}[0]${PLAIN} 取消返回\n"

    read -r -p "请输入选项编号: " sel < /dev/tty
    local selected_file=""

    if [[ "${sel}" == "0" ]]; then
        warn "已取消恢复。"
        return 0
    elif [[ "${sel}" == "c" || "${sel}" == "C" ]]; then
        read -r -p "请输入备份文件绝对路径: " custom_path < /dev/tty
        if [[ -f "${custom_path}" ]]; then
            selected_file="${custom_path}"
        else
            error "文件不存在: ${custom_path}"
            return 1
        fi
    elif [[ "${sel}" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#backup_files[@]} )); then
        selected_file="${backup_files[$((sel-1))]}"
    else
        warn "无效选项！"
        return 1
    fi

    echo ""
    info "已选中备份档案: ${YELLOW}${selected_file}${PLAIN}"
    read -r -p "恢复操作将覆盖现有 Sing-box 配置并重启服务，是否确认恢复？[Y/n]: " confirm_restore < /dev/tty
    if [[ "${confirm_restore}" == "n" || "${confirm_restore}" == "N" ]]; then
        warn "已取消恢复。"
        return 0
    fi

    # 1. 停止当前服务
    info "正在停止当前 Sing-box 服务..."
    systemctl stop sing-box >/dev/null 2>&1 || true

    # 2. 解压还原备份
    info "正在解压并还原文件至根目录..."
    tar -xzf "${selected_file}" -C / 2>/dev/null || {
        error "解压备份失败，请检查文件是否损坏！"
        return 1
    }

    # 3. 修复文件权限与服务
    [[ -f "${SB_STANDARD_BIN}" ]] && chmod +x "${SB_STANDARD_BIN}"
    [[ -f "${SB_STANDARD_DIR}/manage.sh" ]] && chmod +x "${SB_STANDARD_DIR}/manage.sh"
    [[ -f "${SB_STANDARD_DIR}/cert.key" ]] && chmod 600 "${SB_STANDARD_DIR}/cert.key"

    # 设置快捷方式
    if [[ -f "${SB_STANDARD_DIR}/manage.sh" ]]; then
        ln -sf "${SB_STANDARD_DIR}/manage.sh" "/usr/bin/vps"
        ln -sf "${SB_STANDARD_DIR}/manage.sh" "/usr/local/bin/vps"
        ln -sf "${SB_STANDARD_DIR}/manage.sh" "/usr/bin/sb"
        ln -sf "${SB_STANDARD_DIR}/manage.sh" "/usr/local/bin/sb"
    fi

    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1 || true
    systemctl restart sing-box >/dev/null 2>&1 || true

    sleep 1

    if systemctl is-active --quiet sing-box; then
        success "🎉 恭喜！Sing-box 已从备份成功完整恢复并恢复运行！"
        if [[ -f "${SB_STANDARD_DIR}/manage.sh" ]]; then
            echo ""
            bash "${SB_STANDARD_DIR}/manage.sh" show 2>/dev/null || true
        fi
    else
        warn "Sing-box 文件已解压恢复，但服务启动未通过。请执行: journalctl -u sing-box -e 查看日志。"
    fi
}

# --- 6. 清理第三方旧代理 ---
clean_legacy_proxies() {
    title "清理第三方旧代理残留 (Xray / V2Ray / Trojan / v2ray-agent 等)"
    echo -e "${YELLOW}此操作将仅清理第三方旧代理的守护进程、程序文件与配置目录。${PLAIN}"
    echo -e "${GREEN}受保护服务（Tailscale、Nginx、Caddy、WordPress、MySQL 等）将得到 100% 绝对保护！${PLAIN}\n"

    read -r -p "是否确认清理第三方旧代理？[y/N]: " confirm < /dev/tty
    if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
        warn "已取消清理。"
        return 0
    fi

    # 清理前自动执行全局备份
    backup_singbox

    info "正在停止并禁用第三方旧代理服务..."
    for s in "${FOUND_LEGACY_SERVICES[@]}"; do
        local svc="${s%% *}"
        systemctl stop "${svc}" >/dev/null 2>&1 || true
        systemctl disable "${svc}" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${svc}" "/lib/systemd/system/${svc}"
    done
    systemctl daemon-reload

    info "正在清理第三方旧二进制程序..."
    for b in "${FOUND_LEGACY_BINS[@]}"; do
        rm -f "${b}" 2>/dev/null || true
    done

    info "正在清理第三方配置目录..."
    for d in "${FOUND_LEGACY_DIRS[@]}"; do
        rm -rf "${d}" 2>/dev/null || true
    done

    success "第三方旧代理残留清理完毕！"
}

# --- 7. 清理 Sing-box ---
clean_singbox() {
    title "管理与清理 Sing-box 服务"
    echo -e "${YELLOW}请选择 Sing-box 清理方式:${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN} 仅重置配置（保留主程序，重置 /etc/sing-box）"
    echo -e "  ${GREEN}2.${PLAIN} 彻底完全卸载 Sing-box（删除程序、配置与 Systemd 服务）"
    echo -e "  ${GREEN}0.${PLAIN} 取消返回"
    echo ""

    read -r -p "请输入选项 [1/2/0]: " sb_choice < /dev/tty
    case "${sb_choice}" in
        1)
            backup_singbox
            systemctl stop sing-box >/dev/null 2>&1 || true
            rm -rf "${SB_STANDARD_DIR}"
            mkdir -p "${SB_STANDARD_DIR}"
            success "Sing-box 配置目录已重置完毕。"
            ;;
        2)
            backup_singbox
            systemctl stop sing-box >/dev/null 2>&1 || true
            systemctl disable sing-box >/dev/null 2>&1 || true
            rm -f "${SB_STANDARD_SERVICE}"
            systemctl daemon-reload
            rm -f "${SB_STANDARD_BIN}"
            rm -rf "${SB_STANDARD_DIR}"
            rm -f "/usr/bin/vps" "/usr/local/bin/vps" "/usr/bin/sb" "/usr/local/bin/sb"
            success "Sing-box 服务已彻底从系统中卸载完毕。"
            ;;
        *)
            warn "操作已取消。"
            return 0
            ;;
    esac
}

# --- 8. 全量深度除旧 (清理所有旧代理 + 清除 Sing-box，为全新安装做准备) ---
clean_all_deep() {
    title "全量深度除旧（清理所有旧代理残留 + 重置环境为全新安装准备）"
    echo -e "${RED}⚠️  注意：此操作将清理所有第三方旧代理（Xray/V2Ray/v2ray-agent/Trojan等）以及 Sing-box 旧服务！${PLAIN}"
    echo -e "${GREEN}🛡️  受保护服务（Tailscale、Nginx、Caddy、WordPress、MySQL 等）将得到 100% 绝对保护！${PLAIN}\n"

    read -r -p "是否确认执行全量深度清理？[y/N]: " confirm < /dev/tty
    if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
        warn "已取消全量深度清理。"
        return 0
    fi

    # 清理前自动创建完整备份
    backup_singbox

    # 1. 清理第三方旧代理
    info "正在停止并清理所有第三方旧代理服务..."
    for s in "${FOUND_LEGACY_SERVICES[@]}"; do
        local svc="${s%% *}"
        systemctl stop "${svc}" >/dev/null 2>&1 || true
        systemctl disable "${svc}" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${svc}" "/lib/systemd/system/${svc}"
    done
    systemctl daemon-reload

    for b in "${FOUND_LEGACY_BINS[@]}"; do
        rm -f "${b}" 2>/dev/null || true
    done

    for d in "${FOUND_LEGACY_DIRS[@]}"; do
        rm -rf "${d}" 2>/dev/null || true
    done

    # 2. 清理旧 Sing-box 服务单元与程序
    info "正在清理 Sing-box 旧环境..."
    systemctl stop sing-box >/dev/null 2>&1 || true
    systemctl disable sing-box >/dev/null 2>&1 || true
    rm -f "${SB_STANDARD_SERVICE}"
    systemctl daemon-reload
    rm -f "${SB_STANDARD_BIN}"
    rm -rf "${SB_STANDARD_DIR}"
    rm -f "/usr/bin/vps" "/usr/local/bin/vps" "/usr/bin/sb" "/usr/local/bin/sb"

    success "🎉 全量深度除旧完成！VPS 当前代理环境已完全纯净化。"
    echo ""
    read -r -p "是否立即启动新版一键安装脚本部署全新的 4合1 服务？[Y/n]: " run_install < /dev/tty
    if [[ "${run_install}" != "n" && "${run_install}" != "N" ]]; then
        bash <(curl -fsSL "https://raw.githubusercontent.com/luckyjamesriver/VPS-Sing-box/main/install.sh?v=$(date +%s)")
    fi
}

# --- 交互主菜单 ---
clean_menu() {
    clear
    echo -e "${PURPLE}====================================================${PLAIN}"
    echo -e "${GREEN}       VPS 环境安全除旧、完整备份与恢复工具          ${PLAIN}"
    echo -e "${BLUE}    GitHub: https://github.com/luckyjamesriver/VPS-Sing-box${PLAIN}"
    echo -e "${PURPLE}====================================================${PLAIN}"

    scan_system
    show_scan_report
    show_network_ports

    echo -e "----------------------------------------------------"
    echo -e "${GREEN}1.${PLAIN} 仅清理【第三方旧代理残留】(Xray/V2Ray/v2ray-agent/Trojan等)"
    echo -e "${GREEN}2.${PLAIN} 管理与清理【Sing-box 服务 / 卸载】"
    echo -e "${GREEN}3.${PLAIN} 【全量深度除旧】(清理所有旧代理 + 重置环境，为全新安装准备)"
    echo -e "${GREEN}4.${PLAIN} 📦 【一键完整备份】当前 Sing-box (配置+证书+密钥+程序)"
    echo -e "${GREEN}5.${PLAIN} 🔄 【一键恢复备份】从历史备份还原 Sing-box"
    echo -e "${GREEN}6.${PLAIN} 重新刷新扫描系统服务与端口"
    echo -e "${GREEN}0.${PLAIN} 退出工具"
    echo -e "----------------------------------------------------"

    read -r -p "请输入选项 [0-6]: " menu_choice < /dev/tty
    case "${menu_choice}" in
        1) clean_legacy_proxies ;;
        2) clean_singbox ;;
        3) clean_all_deep ;;
        4) backup_singbox ;;
        5) restore_singbox ;;
        6) clean_menu ;;
        0) exit 0 ;;
        *) warn "无效选项，请重新输入！"; sleep 1; clean_menu ;;
    esac
}

# --- 入口处理 ---
check_root

if [[ $# -gt 0 ]]; then
    case "$1" in
        backup)
            backup_singbox
            ;;
        restore)
            restore_singbox
            ;;
        scan)
            scan_system
            show_scan_report
            show_network_ports
            ;;
        clean-legacy)
            scan_system
            clean_legacy_proxies
            ;;
        clean-all)
            scan_system
            clean_all_deep
            ;;
        *)
            echo "用法: $0 {backup|restore|scan|clean-legacy|clean-all}"
            exit 1
            ;;
    esac
else
    clean_menu
fi
