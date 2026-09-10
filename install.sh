#!/usr/bin/env bash
# ==============================================================================
# Project: VPS-Sing-box
# Description: Minimalist, High-Performance, Zero-Maintenance Sing-box Installer
# Repository: https://github.com/luckyjamesriver/VPS-Sing-box
# License: MIT
#
# Supported Protocols (4-in-1):
#   1. VLESS-Reality-Vision (TCP)
#   2. VLESS-Reality-gRPC (TCP)
#   3. Hysteria 2 (UDP)
#   4. TUIC v5 (UDP)
# ==============================================================================

set -e

# --- Color Constants ---
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PURPLE="\033[35m"
PLAIN="\033[0m"

# --- Global Paths ---
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CLIENT_FILE="${CONFIG_DIR}/client_config.json"
INFO_FILE="${CONFIG_DIR}/node_info.json"
CERT_KEY="${CONFIG_DIR}/cert.key"
CERT_PEM="${CONFIG_DIR}/cert.pem"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
BIN_PATH="/usr/local/bin/sing-box"
SCRIPT_PATH="/etc/sing-box/manage.sh"
CLI_LINK="/usr/local/bin/sb"

# --- Helper Output Functions ---
info()    { echo -e "${GREEN}[INFO]${PLAIN} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${PLAIN} $*"; }
error()   { echo -e "${RED}[ERROR]${PLAIN} $*" >&2; }
tip()     { echo -e "${BLUE}[TIP]${PLAIN} $*"; }
title()   { echo -e "\n${PURPLE}====================================================${PLAIN}\n${PURPLE}  $*${PLAIN}\n${PURPLE}====================================================${PLAIN}"; }

# --- Check Environment ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本必须以 root 用户运行！请执行: sudo -i 或 sudo bash $0"
        exit 1
    fi
}

check_system() {
    if [[ ! -f /etc/os-release ]]; then
        error "无法识别当前操作系统！仅支持 Debian / Ubuntu 系统。"
        exit 1
    fi

    # shellcheck source=/dev/null
    source /etc/os-release
    OS_ID="${ID}"
    OS_VERSION="${VERSION_ID}"

    if [[ "${OS_ID}" != "debian" && "${OS_ID}" != "ubuntu" ]]; then
        error "当前系统 (${OS_ID}) 暂不受支持！本项目专为 Debian 11/12 与 Ubuntu 20.04+ 精简优化。"
        exit 1
    fi

    ARCH=$(uname -m)
    case "${ARCH}" in
        x86_64 | amd64)
            PKG_ARCH="amd64"
            ;;
        aarch64 | arm64)
            PKG_ARCH="arm64"
            ;;
        *)
            error "不支持的 CPU 架构: ${ARCH}，仅支持 x86_64 / arm64。"
            exit 1
            ;;
    esac
    info "检测到系统: ${NAME} ${OS_VERSION} (${PKG_ARCH})"
}

# --- Install Dependencies ---
install_dependencies() {
    title "正在安装系统基础依赖"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends \
        curl wget jq tar openssl qrencode vim sudo lsof ufw ca-certificates
    info "基础依赖安装完成。"
}

# --- Enable Linux BBR ---
enable_bbr() {
    info "检查并配置原生 Linux BBR 拥塞控制算法..."
    if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        info "系统已启用 BBR 加速。"
        return 0
    fi

    sed -i "/net.core.default_qdisc/d" /etc/sysctl.conf
    sed -i "/net.ipv4.tcp_congestion_control/d" /etc/sysctl.conf

    echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || true

    if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        info "BBR 拥塞控制已成功激活！"
    else
        warn "BBR 激活可能需要重启内核生效，已写入配置文件。"
    fi
}

# --- Get Public IP ---
get_public_ip() {
    local ip
    ip=$(curl -s4m 5 https://api.ipify.org || curl -s4m 5 https://ip.sb || curl -s4m 5 https://checkip.amazonaws.com || true)
    if [[ -z "${ip}" ]]; then
        ip=$(curl -s6m 5 https://api6.ipify.org || true)
    fi
    echo "${ip}"
}

# --- Port Collision Detection ---
get_random_port() {
    local port
    while true; do
        port=$((RANDOM % 50000 + 10000))
        # Exclude common sensitive ports
        if [[ "${port}" -eq 80 || "${port}" -eq 443 || "${port}" -eq 8080 || "${port}" -eq 8443 ]]; then
            continue
        fi
        if ! ss -tuln 2>/dev/null | grep -q ":${port} "; then
            echo "${port}"
            return 0
        fi
    done
}

# --- Install / Upgrade Sing-box Binary ---
install_singbox_core() {
    title "下载并安装 Sing-box 核心"
    mkdir -p "${CONFIG_DIR}"

    local latest_tag
    info "正在获取 Sing-box 最新稳定版本..."
    latest_tag=$(curl -sSL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r ".tag_name" 2>/dev/null || true)

    if [[ -z "${latest_tag}" || "${latest_tag}" == "null" ]]; then
        warn "通过 GitHub API 获取版本失败，使用备用兜底稳定版本 v1.11.4"
        latest_tag="v1.11.4"
    fi

    local version_no_v="${latest_tag#v}"
    local tar_name="sing-box-${version_no_v}-linux-${PKG_ARCH}.tar.gz"
    local download_url="https://github.com/SagerNet/sing-box/releases/download/${latest_tag}/${tar_name}"

    info "下载版本: ${latest_tag} (${PKG_ARCH})..."
    local temp_dir
    temp_dir=$(mktemp -d)
    if ! wget -q --show-progress -O "${temp_dir}/${tar_name}" "${download_url}"; then
        warn "直接下载较慢或超时，尝试镜像加速源..."
        wget -q --show-progress -O "${temp_dir}/${tar_name}" "https://ghproxy.net/${download_url}" || {
            error "下载 Sing-box 失败，请检查 VPS 网络连接！"
            rm -rf "${temp_dir}"
            exit 1
        }
    fi

    tar -zxvf "${temp_dir}/${tar_name}" -C "${temp_dir}" >/dev/null
    cp -f "${temp_dir}/sing-box-${version_no_v}-linux-${PKG_ARCH}/sing-box" "${BIN_PATH}"
    chmod +x "${BIN_PATH}"
    rm -rf "${temp_dir}"

    info "Sing-box 核心安装成功: $(${BIN_PATH} version | head -n 1)"

    # Setup Systemd service
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=${BIN_PATH} run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1 || true
}

# --- Generate 10-Year Self-Signed Certificate ---
generate_cert() {
    local domain="$1"
    info "为域名 [${domain}] 生成 10 年免维护高强度 ECC 证书 (供 Hysteria2 / TUIC 使用)..."
    openssl ecparam -genkey -name prime256v1 -out "${CERT_KEY}" >/dev/null 2>&1
    openssl req -new -x509 -days 3650 -key "${CERT_KEY}" -out "${CERT_PEM}" \
        -subj "/CN=${domain}" -addext "subjectAltName=DNS:${domain}" >/dev/null 2>&1
    chmod 600 "${CERT_KEY}"
    chmod 644 "${CERT_PEM}"
    info "证书生成完毕，自签有效期为 10 年。"
}

# --- Open Firewall Ports ---
allow_ports() {
    local tcp_ports=("$@")
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        info "正在放行 UFW 防火墙端口..."
        for p in "${tcp_ports[@]}"; do
            ufw allow "${p}" >/dev/null 2>&1 || true
        done
    fi

    if command -v iptables >/dev/null 2>&1; then
        for p in "${tcp_ports[@]}"; do
            iptables -I INPUT -p tcp --dport "${p}" -j ACCEPT >/dev/null 2>&1 || true
            iptables -I INPUT -p udp --dport "${p}" -j ACCEPT >/dev/null 2>&1 || true
        done
    fi
}

# --- Main Configuration Generator ---
generate_configs() {
    local domain="$1"
    local public_ip="$2"

    title "正在生成专属随机高强度凭证与端口"

    local port_reality_tcp
    local port_reality_grpc
    local port_hy2
    local port_tuic

    port_reality_tcp=$(get_random_port)
    port_reality_grpc=$(get_random_port)
    port_hy2=$(get_random_port)
    port_tuic=$(get_random_port)

    info "分配端口 (已避开常用端口):"
    echo -e "  - VLESS-Reality-Vision (TCP) : ${GREEN}${port_reality_tcp}${PLAIN}"
    echo -e "  - VLESS-Reality-gRPC   (TCP) : ${GREEN}${port_reality_grpc}${PLAIN}"
    echo -e "  - Hysteria 2           (UDP) : ${GREEN}${port_hy2}${PLAIN}"
    echo -e "  - TUIC v5              (UDP) : ${GREEN}${port_tuic}${PLAIN}"

    allow_ports "${port_reality_tcp}" "${port_reality_grpc}" "${port_hy2}" "${port_tuic}"

    # Credentials
    local uuid
    uuid=$("${BIN_PATH}" generate uuid)

    # Reality Keypair
    local reality_keypair
    reality_keypair=$("${BIN_PATH}" generate reality-keypair)
    local private_key
    private_key=$(echo "${reality_keypair}" | awk '/PrivateKey:/ {print $2}')
    local public_key
    public_key=$(echo "${reality_keypair}" | awk '/PublicKey:/ {print $2}')
    local short_id
    short_id=$(openssl rand -hex 8)

    # Passwords for Hy2 & TUIC
    local hy2_password
    hy2_password=$(openssl rand -hex 16)
    local tuic_password
    tuic_password=$(openssl rand -hex 16)

    # Reality Camouflage SNI
    local reality_sni="www.apple.com"

    # Generate Cert for Hy2 & Tuic
    generate_cert "${domain}"

    # 1. Server Configuration
    cat > "${CONFIG_FILE}" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "dns-remote",
        "address": "https://1.1.1.1/dns-query",
        "detour": "direct"
      }
    ]
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-vision-in",
      "listen": "::",
      "listen_port": ${port_reality_tcp},
      "users": [
        {
          "uuid": "${uuid}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${reality_sni}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${reality_sni}",
            "server_port": 443
          },
          "private_key": "${private_key}",
          "short_id": [
            "${short_id}"
          ]
        }
      }
    },
    {
      "type": "vless",
      "tag": "vless-reality-grpc-in",
      "listen": "::",
      "listen_port": ${port_reality_grpc},
      "users": [
        {
          "uuid": "${uuid}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${reality_sni}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${reality_sni}",
            "server_port": 443
          },
          "private_key": "${private_key}",
          "short_id": [
            "${short_id}"
          ]
        }
      },
      "transport": {
        "type": "grpc",
        "service_name": "grpc-service"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2-in",
      "listen": "::",
      "listen_port": ${port_hy2},
      "users": [
        {
          "password": "${hy2_password}"
        }
      ],
      "ignore_client_bandwidth": false,
      "tls": {
        "enabled": true,
        "certificate_path": "${CERT_PEM}",
        "key_path": "${CERT_KEY}"
      }
    },
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": ${port_tuic},
      "users": [
        {
          "uuid": "${uuid}",
          "password": "${tuic_password}"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "certificate_path": "${CERT_PEM}",
        "key_path": "${CERT_KEY}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "bittorrent",
        "outbound": "block"
      },
      {
        "ip_is_private": true,
        "outbound": "block"
      }
    ]
  }
}
EOF

    # 2. Client Complete Configuration (JSON for Sing-box Client)
    cat > "${CLIENT_FILE}" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 2080
    }
  ],
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "outbounds": [
        "VLESS-Reality-Vision",
        "VLESS-Reality-gRPC",
        "Hysteria2",
        "TUIC-v5",
        "auto"
      ],
      "default": "VLESS-Reality-Vision"
    },
    {
      "type": "urltest",
      "tag": "auto",
      "outbounds": [
        "VLESS-Reality-Vision",
        "VLESS-Reality-gRPC",
        "Hysteria2",
        "TUIC-v5"
      ],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "3m",
      "tolerance": 50
    },
    {
      "type": "vless",
      "tag": "VLESS-Reality-Vision",
      "server": "${domain}",
      "server_port": ${port_reality_tcp},
      "uuid": "${uuid}",
      "flow": "xtls-rprx-vision",
      "network": "tcp",
      "tls": {
        "enabled": true,
        "server_name": "${reality_sni}",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "${public_key}",
          "short_id": "${short_id}"
        }
      }
    },
    {
      "type": "vless",
      "tag": "VLESS-Reality-gRPC",
      "server": "${domain}",
      "server_port": ${port_reality_grpc},
      "uuid": "${uuid}",
      "network": "tcp",
      "tls": {
        "enabled": true,
        "server_name": "${reality_sni}",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "${public_key}",
          "short_id": "${short_id}"
        }
      },
      "transport": {
        "type": "grpc",
        "service_name": "grpc-service"
      }
    },
    {
      "type": "hysteria2",
      "tag": "Hysteria2",
      "server": "${domain}",
      "server_port": ${port_hy2},
      "password": "${hy2_password}",
      "tls": {
        "enabled": true,
        "server_name": "${domain}",
        "insecure": true
      }
    },
    {
      "type": "tuic",
      "tag": "TUIC-v5",
      "server": "${domain}",
      "server_port": ${port_tuic},
      "uuid": "${uuid}",
      "password": "${tuic_password}",
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "server_name": "${domain}",
        "insecure": true
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "ip_is_private": true,
        "outbound": "direct"
      },
      {
        "clash_mode": "Global",
        "outbound": "select"
      },
      {
        "clash_mode": "Direct",
        "outbound": "direct"
      }
    ],
    "auto_detect_interface": true
  }
}
EOF

    # 3. Save Node Metadata File for Easy Retrieval
    cat > "${INFO_FILE}" <<EOF
{
  "domain": "${domain}",
  "public_ip": "${public_ip}",
  "uuid": "${uuid}",
  "reality_sni": "${reality_sni}",
  "public_key": "${public_key}",
  "short_id": "${short_id}",
  "port_reality_tcp": ${port_reality_tcp},
  "port_reality_grpc": ${port_reality_grpc},
  "port_hy2": ${port_hy2},
  "hy2_password": "${hy2_password}",
  "port_tuic": ${port_tuic},
  "tuic_password": "${tuic_password}"
}
EOF

    info "配置语法校验..."
    "${BIN_PATH}" check -c "${CONFIG_FILE}"
    info "校验通过，配置保存至: ${CONFIG_FILE}"
}

# --- Restart Sing-box Service ---
start_service() {
    title "正在启动 Sing-box 服务"
    systemctl daemon-reload
    systemctl restart sing-box
    sleep 1

    if systemctl is-active --quiet sing-box; then
        info "Sing-box 服务已成功运行！"
    else
        error "Sing-box 启动失败！请检查日志: journalctl -u sing-box -n 20 --no-pager"
        exit 1
    fi
}

# --- Display Node URLs and QR Codes ---
show_nodes() {
    if [[ ! -f "${INFO_FILE}" ]]; then
        error "未找到配置信息，请先执行安装！"
        return 1
    fi

    local domain public_ip uuid reality_sni public_key short_id
    local port_reality_tcp port_reality_grpc port_hy2 hy2_password port_tuic tuic_password

    domain=$(jq -r ".domain" "${INFO_FILE}")
    public_ip=$(jq -r ".public_ip" "${INFO_FILE}")
    uuid=$(jq -r ".uuid" "${INFO_FILE}")
    reality_sni=$(jq -r ".reality_sni" "${INFO_FILE}")
    public_key=$(jq -r ".public_key" "${INFO_FILE}")
    short_id=$(jq -r ".short_id" "${INFO_FILE}")
    port_reality_tcp=$(jq -r ".port_reality_tcp" "${INFO_FILE}")
    port_reality_grpc=$(jq -r ".port_reality_grpc" "${INFO_FILE}")
    port_hy2=$(jq -r ".port_hy2" "${INFO_FILE}")
    hy2_password=$(jq -r ".hy2_password" "${INFO_FILE}")
    port_tuic=$(jq -r ".port_tuic" "${INFO_FILE}")
    tuic_password=$(jq -r ".tuic_password" "${INFO_FILE}")

    # Standard Share Links
    local uri_reality_tcp="vless://${uuid}@${domain}:${port_reality_tcp}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reality_sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp#VLESS-Reality-Vision"
    local uri_reality_grpc="vless://${uuid}@${domain}:${port_reality_grpc}?encryption=none&security=reality&sni=${reality_sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=grpc&serviceName=grpc-service#VLESS-Reality-gRPC"
    local uri_hy2="hysteria2://${hy2_password}@${domain}:${port_hy2}/?insecure=1&sni=${domain}#Hysteria2"
    local uri_tuic="tuic://${uuid}:${tuic_password}@${domain}:${port_tuic}?congestion_control=bbr&alpn=h3&sni=${domain}&allow_insecure=1#TUIC-v5"

    title "Sing-box 专属节点与连接链接"
    echo -e "${YELLOW}绑定域名:${PLAIN} ${domain}  |  ${YELLOW}VPS 公网 IP:${PLAIN} ${public_ip}"
    echo -e "${YELLOW}客户端配置文件:${PLAIN} ${CLIENT_FILE}\n"

    echo -e "${GREEN}1. VLESS-Reality-Vision (TCP 主力抗封锁):${PLAIN}"
    echo -e "   ${BLUE}${uri_reality_tcp}${PLAIN}\n"

    echo -e "${GREEN}2. VLESS-Reality-gRPC (TCP 多路复用备用):${PLAIN}"
    echo -e "   ${BLUE}${uri_reality_grpc}${PLAIN}\n"

    echo -e "${GREEN}3. Hysteria 2 (UDP 晚高峰暴力加速):${PLAIN}"
    echo -e "   ${BLUE}${uri_hy2}${PLAIN}\n"

    echo -e "${GREEN}4. TUIC v5 (UDP 0-RTT 极速 QUIC):${PLAIN}"
    echo -e "   ${BLUE}${uri_tuic}${PLAIN}\n"

    title "VLESS-Reality-Vision 二维码 (手机扫码即可导入)"
    qrencode -t ANSIUTF8 "${uri_reality_tcp}" || true

    echo -e "\n${YELLOW}提示:${PLAIN} 随时输入快捷管理命令 ${GREEN}sb${PLAIN} 即可唤出管理菜单！"
}

# --- Show Client Config JSON ---
show_client_config() {
    if [[ -f "${CLIENT_FILE}" ]]; then
        title "Sing-box 完整客户端配置 (可直接导入 Sing-box 客户端)"
        cat "${CLIENT_FILE}"
        echo ""
        info "该配置文件保存在: ${CLIENT_FILE}"
    else
        error "未找到客户端配置文件，请先执行安装！"
    fi
}

# --- Create Shortcut CLI Script ---
setup_shortcut() {
    cp -f "$0" "${SCRIPT_PATH}"
    chmod +x "${SCRIPT_PATH}"
    ln -sf "${SCRIPT_PATH}" "${CLI_LINK}"
}

# --- Interactive Install Entrypoint ---
install_flow() {
    check_root
    check_system
    install_dependencies
    enable_bbr

    local public_ip
    public_ip=$(get_public_ip)

    title "配置 Cloudflare 域名"
    echo -e "提示: 请确保你已经在 Cloudflare 将该域名解析到 VPS IP (${GREEN}${public_ip}${PLAIN})。"
    echo -e "注意: 请保持 Cloudflare 上的代理状态为 ${YELLOW}仅限 DNS (灰色云朵)${PLAIN}。\n"

    local user_domain=""
    while true; do
        read -r -p "请输入你的域名 (如 node.yourdomain.com): " user_domain
        user_domain=$(echo "${user_domain}" | tr -d "[:space:]")
        if [[ -n "${user_domain}" ]]; then
            break
        fi
        warn "域名不能为空，请重新输入！"
    done

    install_singbox_core
    generate_configs "${user_domain}" "${public_ip}"
    start_service
    setup_shortcut

    show_nodes
}

# --- Service Management Handlers ---
service_status() {
    systemctl status sing-box --no-pager
}

service_restart() {
    systemctl restart sing-box
    info "Sing-box 服务已重启。"
}

service_stop() {
    systemctl stop sing-box
    info "Sing-box 服务已停止。"
}

service_logs() {
    journalctl -u sing-box -f -o cat
}

# --- Update Core Only ---
update_core() {
    check_root
    check_system
    install_singbox_core
    systemctl restart sing-box
    info "Sing-box 核心更新完毕并已重启服务。"
}

# --- Uninstall Completely ---
uninstall_flow() {
    check_root
    read -r -p "确定要完全卸载 Sing-box 吗？[y/N]: " confirm
    if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
        info "取消卸载。"
        return 0
    fi

    systemctl stop sing-box >/dev/null 2>&1 || true
    systemctl disable sing-box >/dev/null 2>&1 || true
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload

    rm -f "${BIN_PATH}"
    rm -rf "${CONFIG_DIR}"
    rm -f "${CLI_LINK}"

    info "Sing-box 已完全从系统中卸载干净。"
}

# --- Management Menu ---
menu() {
    clear
    echo -e "${PURPLE}====================================================${PLAIN}"
    echo -e "${GREEN}         Sing-box 极简全能安装管理脚本               ${PLAIN}"
    echo -e "${BLUE}    GitHub: https://github.com/luckyjamesriver/VPS-Sing-box${PLAIN}"
    echo -e "${PURPLE}====================================================${PLAIN}"

    if systemctl is-active --quiet sing-box 2>/dev/null; then
        echo -e "服务状态: ${GREEN}正在运行${PLAIN}"
    else
        echo -e "服务状态: ${RED}未运行或未安装${PLAIN}"
    fi

    echo -e "----------------------------------------------------"
    echo -e "${GREEN}1.${PLAIN} 安装 / 重新配置 Sing-box (4合1强力协议)"
    echo -e "${GREEN}2.${PLAIN} 查看 节点连接链接 与 二维码"
    echo -e "${GREEN}3.${PLAIN} 查看并复制 客户端完整配置文件 (client_config.json)"
    echo -e "${GREEN}4.${PLAIN} 重启 Sing-box 服务"
    echo -e "${GREEN}5.${PLAIN} 停止 Sing-box 服务"
    echo -e "${GREEN}6.${PLAIN} 查看 实时运行日志 (退出按 Ctrl+C)"
    echo -e "${GREEN}7.${PLAIN} 单独更新 Sing-box 核心版本"
    echo -e "${GREEN}8.${PLAIN} 完全卸载 Sing-box"
    echo -e "${GREEN}0.${PLAIN} 退出菜单"
    echo -e "----------------------------------------------------"

    read -r -p "请输入选项 [0-8]: " choice
    case "${choice}" in
        1) install_flow ;;
        2) show_nodes ;;
        3) show_client_config ;;
        4) service_restart ;;
        5) service_stop ;;
        6) service_logs ;;
        7) update_core ;;
        8) uninstall_flow ;;
        0) exit 0 ;;
        *) warn "无效选项，请重新输入！"; sleep 1; menu ;;
    esac
}

# --- Entry Point ---
if [[ $# -gt 0 ]]; then
    case "$1" in
        install)
            install_flow
            ;;
        show)
            show_nodes
            ;;
        client)
            show_client_config
            ;;
        restart)
            service_restart
            ;;
        stop)
            service_stop
            ;;
        status)
            service_status
            ;;
        log|logs)
            service_logs
            ;;
        update)
            update_core
            ;;
        uninstall)
            uninstall_flow
            ;;
        *)
            echo "用法: $0 {install|show|client|restart|stop|status|logs|update|uninstall}"
            exit 1
            ;;
    esac
else
    # If already installed, show menu; otherwise direct to install
    if [[ -f "${CONFIG_FILE}" && -f "${BIN_PATH}" ]]; then
        menu
    else
        install_flow
    fi
fi
