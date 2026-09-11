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
CLIENT_DIR="${CONFIG_DIR}/client"
CLIENT_FILE="${CLIENT_DIR}/config.json"
INFO_FILE="${CONFIG_DIR}/node_info.json"
CERT_KEY="${CONFIG_DIR}/cert.key"
CERT_PEM="${CONFIG_DIR}/cert.pem"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
BIN_PATH="/usr/local/bin/sing-box"
SCRIPT_PATH="/etc/sing-box/manage.sh"
CLI_LINK="/usr/local/bin/vps"

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
        curl wget jq tar openssl qrencode vim sudo lsof ufw ca-certificates python3
    info "基础依赖安装完成。"
}

# --- Enable Linux BBR and TCP Brutal ---
enable_bbr() {
    info "检查并配置原生 Linux BBR 拥塞控制算法..."
    if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        info "系统已启用 BBR 加速。"
    else
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1 || true
        if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
            info "BBR 拥塞控制已成功激活！"
        else
            warn "BBR 激活可能需要重启内核生效，已写入配置文件。"
        fi
    fi

    # Install TCP Brutal kernel module for VLESS TCP Brutal acceleration
    info "检查并安装 Linux TCP Brutal 拥塞控制内核模块..."
    if ! lsmod | grep -q "tcp_brutal"; then
        info "正在执行 TCP Brutal 官方内核模块安装脚本 (https://tcp.hy2.sh/)..."
        bash <(curl -fsSL https://tcp.hy2.sh/) || {
            warn "TCP Brutal 内核模块自动安装未完成，建议使用 Linux 5.8+ 内核。"
        }
    fi
    if lsmod | grep -q "tcp_brutal"; then
        info "TCP Brutal 内核模块已加载！"
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
    local server_up_mbps="${3:-50}"
    local server_down_mbps="${4:-500}"
    local is_reuse="${5:-false}"

    local client_up_mbps="${server_down_mbps}"
    local client_down_mbps="${server_up_mbps}"

    title "正在配置专属高强度凭证与端口"

    local port_reality_tcp=""
    local port_reality_grpc=""
    local port_hy2=""
    local port_tuic=""
    local uuid=""
    local private_key=""
    local public_key=""
    local short_id=""
    local hy2_password=""
    local tuic_password=""
    local salamander_pwd=""
    local reality_sni="www.apple.com"

    if [[ "${is_reuse}" == "true" ]]; then
        info "正在读取已存在的凭证与端口..."
        if [[ -f "${INFO_FILE}" ]]; then
            port_reality_tcp=$(jq -r '.port_reality_tcp // empty' "${INFO_FILE}")
            port_reality_grpc=$(jq -r '.port_reality_grpc // empty' "${INFO_FILE}")
            port_hy2=$(jq -r '.port_hy2 // empty' "${INFO_FILE}")
            port_tuic=$(jq -r '.port_tuic // empty' "${INFO_FILE}")
            uuid=$(jq -r '.uuid // empty' "${INFO_FILE}")
            private_key=$(jq -r '.private_key // empty' "${INFO_FILE}")
            public_key=$(jq -r '.public_key // empty' "${INFO_FILE}")
            short_id=$(jq -r '.short_id // empty' "${INFO_FILE}")
            hy2_password=$(jq -r '.hy2_password // empty' "${INFO_FILE}")
            tuic_password=$(jq -r '.tuic_password // empty' "${INFO_FILE}")
            salamander_pwd=$(jq -r '.salamander_pwd // empty' "${INFO_FILE}")
            reality_sni=$(jq -r '.reality_sni // "www.apple.com"' "${INFO_FILE}")
        fi

        if [[ -f "${CONFIG_FILE}" ]]; then
            [[ -z "${uuid}" ]] && uuid=$(jq -r '.inbounds[] | select(.type=="vless") | .users[0].uuid' "${CONFIG_FILE}" 2>/dev/null | head -n 1)
            [[ -z "${private_key}" ]] && private_key=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.reality.private_key' "${CONFIG_FILE}" 2>/dev/null | head -n 1)
            [[ -z "${short_id}" ]] && short_id=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.reality.short_id[-1]' "${CONFIG_FILE}" 2>/dev/null | head -n 1)
            [[ -z "${port_reality_tcp}" ]] && port_reality_tcp=$(jq -r '.inbounds[] | select(.tag=="VLESSReality" or .tag=="vless-reality-vision-in") | .listen_port' "${CONFIG_FILE}" 2>/dev/null | head -n 1)
            [[ -z "${port_reality_grpc}" ]] && port_reality_grpc=$(jq -r '.inbounds[] | select(.tag=="VLESSRealityGRPC" or .tag=="vless-reality-grpc-in") | .listen_port' "${CONFIG_FILE}" 2>/dev/null | head -n 1)
            [[ -z "${port_hy2}" ]] && port_hy2=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port' "${CONFIG_FILE}" 2>/dev/null | head -n 1)
            [[ -z "${port_tuic}" ]] && port_tuic=$(jq -r '.inbounds[] | select(.type=="tuic") | .listen_port' "${CONFIG_FILE}" 2>/dev/null | head -n 1)
            [[ -z "${hy2_password}" ]] && hy2_password=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .users[0].password' "${CONFIG_FILE}" 2>/dev/null | head -n 1)
            [[ -z "${tuic_password}" ]] && tuic_password=$(jq -r '.inbounds[] | select(.type=="tuic") | .users[0].password' "${CONFIG_FILE}" 2>/dev/null | head -n 1)
            [[ -z "${salamander_pwd}" ]] && salamander_pwd=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .obfs.password // empty' "${CONFIG_FILE}" 2>/dev/null | head -n 1)
        fi

        if [[ -z "${public_key}" ]]; then
            if [[ -f "${CLIENT_FILE}" ]]; then
                public_key=$(jq -r '.outbounds[] | select(.type=="vless") | .tls.reality.public_key' "${CLIENT_FILE}" 2>/dev/null | head -n 1)
            elif [[ -f "${CONFIG_DIR}/client_config.json" ]]; then
                public_key=$(jq -r '.outbounds[] | select(.type=="vless") | .tls.reality.public_key' "${CONFIG_DIR}/client_config.json" 2>/dev/null | head -n 1)
            fi
        fi
    fi

    # 兜底生成缺少的字段
    [[ -z "${port_reality_tcp}" ]] && port_reality_tcp=$(get_random_port)
    [[ -z "${port_reality_grpc}" ]] && port_reality_grpc=$(get_random_port)
    [[ -z "${port_hy2}" ]] && port_hy2=$(get_random_port)
    [[ -z "${port_tuic}" ]] && port_tuic=$(get_random_port)

    [[ -z "${uuid}" ]] && uuid=$("${BIN_PATH}" generate uuid)

    if [[ -z "${private_key}" || -z "${public_key}" ]]; then
        local reality_keypair
        reality_keypair=$("${BIN_PATH}" generate reality-keypair)
        private_key=$(echo "${reality_keypair}" | awk '/PrivateKey:/ {print $2}')
        public_key=$(echo "${reality_keypair}" | awk '/PublicKey:/ {print $2}')
    fi

    [[ -z "${short_id}" ]] && short_id=$(openssl rand -hex 8)
    [[ -z "${hy2_password}" ]] && hy2_password=$(openssl rand -hex 16)
    [[ -z "${tuic_password}" ]] && tuic_password=$(openssl rand -hex 16)
    [[ -z "${salamander_pwd}" ]] && salamander_pwd=$(openssl rand -hex 8)

    info "应用端口配置:"
    echo -e "  - VLESS-Reality (TCP Brutal) : ${GREEN}${port_reality_tcp}${PLAIN}"
    echo -e "  - VLESS-Reality-gRPC (TCP)   : ${GREEN}${port_reality_grpc}${PLAIN}"
    echo -e "  - Hysteria 2         (UDP)   : ${GREEN}${port_hy2}${PLAIN}"
    echo -e "  - TUIC v5            (UDP)   : ${GREEN}${port_tuic}${PLAIN}"

    allow_ports "${port_reality_tcp}" "${port_reality_grpc}" "${port_hy2}" "${port_tuic}"

    # 证书处理：如果证书已存在且匹配域名则复用，否则重新生成
    if [[ -f "${CERT_PEM}" && -f "${CERT_KEY}" ]] && openssl x509 -in "${CERT_PEM}" -text -noout 2>/dev/null | grep -q "${domain}"; then
        info "复用已存在的 10 年自签 ECC 证书。"
    else
        generate_cert "${domain}"
    fi

    # 1. Server Configuration (No DNS block, TCP Brutal on VLESS, CN Geosite Rule-set Block)
    cat > "${CONFIG_FILE}" <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "hysteria2",
      "listen": "::",
      "listen_port": ${port_hy2},
      "up_mbps": ${server_up_mbps},
      "down_mbps": ${server_down_mbps},
      "users": [
        {
          "name": "singbox_hysteria2",
          "password": "${hy2_password}"
        }
      ],
      "obfs": {
        "type": "salamander",
        "password": "${salamander_pwd}"
      },
      "tls": {
        "enabled": true,
        "server_name": "${domain}",
        "alpn": [
          "h3"
        ],
        "certificate_path": "${CERT_PEM}",
        "key_path": "${CERT_KEY}"
      }
    },
    {
      "type": "vless",
      "tag": "VLESSReality",
      "listen": "::",
      "listen_port": ${port_reality_tcp},
      "users": [
        {
          "name": "VLESS_Reality_Brutal",
          "uuid": "${uuid}",
          "flow": ""
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
            "",
            "${short_id}"
          ]
        }
      },
      "multiplex": {
        "enabled": true,
        "padding": false,
        "brutal": {
          "enabled": true,
          "up_mbps": ${server_up_mbps},
          "down_mbps": ${server_down_mbps}
        }
      }
    },
    {
      "type": "vless",
      "tag": "VLESSRealityGRPC",
      "listen": "::",
      "listen_port": ${port_reality_grpc},
      "users": [
        {
          "name": "VLESS_Reality_gRPC",
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
            "",
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
      "type": "tuic",
      "tag": "singbox-tuic-in",
      "listen": "::",
      "listen_port": ${port_tuic},
      "users": [
        {
          "name": "singbox_tuic",
          "uuid": "${uuid}",
          "password": "${tuic_password}"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "server_name": "${domain}",
        "alpn": [
          "h3"
        ],
        "certificate_path": "${CERT_PEM}",
        "key_path": "${CERT_KEY}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "01_direct_outbound"
    },
    {
      "type": "block",
      "tag": "cn_block_outbound"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "bittorrent",
        "outbound": "cn_block_outbound"
      },
      {
        "domain_suffix": [
          "googleapis.cn",
          "googleapis.com",
          "gstatic.com",
          "xn--ngstr-lra8j.com"
        ],
        "outbound": "01_direct_outbound"
      },
      {
        "rule_set": "cn_cn_block_route",
        "outbound": "cn_block_outbound"
      }
    ],
    "rule_set": [
      {
        "type": "remote",
        "tag": "cn_cn_block_route",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
        "download_detour": "01_direct_outbound"
      }
    ]
  }
}
EOF

    # 2. Client Complete Configuration (Matched Bandwidth Values, Brutal, Salamander OBFS)
    mkdir -p "${CLIENT_DIR}"
    cat > "${CLIENT_FILE}" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "dns-remote",
        "type": "udp",
        "server": "1.1.1.1"
      },
      {
        "tag": "dns-local",
        "type": "local"
      }
    ]
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
        "VLESS-Reality-Brutal",
        "VLESS-Reality-gRPC",
        "Hysteria2",
        "TUIC-v5",
        "auto"
      ],
      "default": "VLESS-Reality-Brutal"
    },
    {
      "type": "urltest",
      "tag": "auto",
      "outbounds": [
        "VLESS-Reality-Brutal",
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
      "tag": "VLESS-Reality-Brutal",
      "server": "${public_ip}",
      "server_port": ${port_reality_tcp},
      "uuid": "${uuid}",
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
      "packet_encoding": "xudp",
      "multiplex": {
        "enabled": true,
        "protocol": "h2mux",
        "max_connections": 1,
        "min_streams": 4,
        "padding": false,
        "brutal": {
          "enabled": true,
          "up_mbps": ${client_up_mbps},
          "down_mbps": ${client_down_mbps}
        }
      }
    },
    {
      "type": "vless",
      "tag": "VLESS-Reality-gRPC",
      "server": "${public_ip}",
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
      "server": "${public_ip}",
      "server_port": ${port_hy2},
      "up_mbps": ${client_up_mbps},
      "down_mbps": ${client_down_mbps},
      "password": "${hy2_password}",
      "obfs": {
        "type": "salamander",
        "password": "${salamander_pwd}"
      },
      "tls": {
        "enabled": true,
        "server_name": "${domain}",
        "alpn": [
          "h3"
        ],
        "insecure": true
      }
    },
    {
      "type": "tuic",
      "tag": "TUIC-v5",
      "server": "${public_ip}",
      "server_port": ${port_tuic},
      "uuid": "${uuid}",
      "password": "${tuic_password}",
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "server_name": "${domain}",
        "alpn": [
          "h3"
        ],
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
    "default_domain_resolver": "dns-remote",
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

    ln -sf "${CLIENT_FILE}" "${CONFIG_DIR}/client_config.json"

    # 3. Save Node Metadata File for Easy Retrieval
    cat > "${INFO_FILE}" <<EOF
{
  "domain": "${domain}",
  "public_ip": "${public_ip}",
  "uuid": "${uuid}",
  "reality_sni": "${reality_sni}",
  "private_key": "${private_key}",
  "public_key": "${public_key}",
  "short_id": "${short_id}",
  "port_reality_tcp": ${port_reality_tcp},
  "port_reality_grpc": ${port_reality_grpc},
  "port_hy2": ${port_hy2},
  "hy2_password": "${hy2_password}",
  "salamander_pwd": "${salamander_pwd}",
  "port_tuic": ${port_tuic},
  "tuic_password": "${tuic_password}",
  "server_up_mbps": ${server_up_mbps},
  "server_down_mbps": ${server_down_mbps},
  "client_up_mbps": ${client_up_mbps},
  "client_down_mbps": ${client_down_mbps}
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
    local port_reality_tcp port_reality_grpc port_hy2 hy2_password salamander_pwd port_tuic tuic_password
    local server_up_mbps server_down_mbps client_up_mbps client_down_mbps

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
    salamander_pwd=$(jq -r ".salamander_pwd" "${INFO_FILE}")
    port_tuic=$(jq -r ".port_tuic" "${INFO_FILE}")
    tuic_password=$(jq -r ".tuic_password" "${INFO_FILE}")
    server_up_mbps=$(jq -r ".server_up_mbps" "${INFO_FILE}")
    server_down_mbps=$(jq -r ".server_down_mbps" "${INFO_FILE}")
    client_up_mbps=$(jq -r ".client_up_mbps" "${INFO_FILE}")
    client_down_mbps=$(jq -r ".client_down_mbps" "${INFO_FILE}")

    # Standard Share Links (Using Public IP for direct connection)
    local uri_reality_tcp="vless://${uuid}@${public_ip}:${port_reality_tcp}?encryption=none&security=reality&sni=${reality_sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp#VLESS-Reality-Brutal"
    local uri_reality_grpc="vless://${uuid}@${public_ip}:${port_reality_grpc}?encryption=none&security=reality&sni=${reality_sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=grpc&serviceName=grpc-service#VLESS-Reality-gRPC"
    local uri_hy2="hysteria2://${hy2_password}@${public_ip}:${port_hy2}/?insecure=1&sni=${domain}&obfs=salamander&obfs-password=${salamander_pwd}#Hysteria2"
    local uri_tuic="tuic://${uuid}:${tuic_password}@${public_ip}:${port_tuic}?congestion_control=bbr&alpn=h3&sni=${domain}&allow_insecure=1#TUIC-v5"

    title "Sing-box 专属节点与连接链接"
    echo -e "${YELLOW}绑定域名:${PLAIN} ${domain}  |  ${YELLOW}VPS 连接 IP:${PLAIN} ${public_ip}"
    echo -e "${YELLOW}带宽限量设置:${PLAIN} 服务端上行 ${server_up_mbps} Mbps, 下行 ${server_down_mbps} Mbps | 客户端对应上行 ${client_up_mbps} Mbps, 下行 ${client_down_mbps} Mbps"
    echo -e "${YELLOW}客户端配置文件:${PLAIN} ${CLIENT_FILE}\n"

    echo -e "${GREEN}1. VLESS-Reality (TCP Brutal 强力拥塞控制):${PLAIN}"
    echo -e "   ${BLUE}${uri_reality_tcp}${PLAIN}\n"

    echo -e "${GREEN}2. VLESS-Reality-gRPC (TCP 多路复用备用):${PLAIN}"
    echo -e "   ${BLUE}${uri_reality_grpc}${PLAIN}\n"

    echo -e "${GREEN}3. Hysteria 2 (UDP 晚高峰暴力加速, 含 Salamander 混淆):${PLAIN}"
    echo -e "   ${BLUE}${uri_hy2}${PLAIN}\n"

    echo -e "${GREEN}4. TUIC v5 (UDP 0-RTT 极速 QUIC):${PLAIN}"
    echo -e "   ${BLUE}${uri_tuic}${PLAIN}\n"

    title "VLESS-Reality (TCP Brutal) 二维码 (手机扫码即可导入)"
    qrencode -t ANSIUTF8 "${uri_reality_tcp}" || true

    echo -e "\n${YELLOW}提示:${PLAIN} 随时输入快捷管理命令 ${GREEN}vps${PLAIN} 即可唤出管理菜单！"
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
    mkdir -p "${CONFIG_DIR}"
    if [[ -f "$0" && "$0" != /dev/fd/* && "$0" != /proc/* ]]; then
        cp -f "$0" "${SCRIPT_PATH}"
    else
        info "正在安装管理脚本至 ${SCRIPT_PATH}..."
        curl -fsSL "https://raw.githubusercontent.com/luckyjamesriver/VPS-Sing-box/main/install.sh?v=$(date +%s)" -o "${SCRIPT_PATH}"
    fi
    chmod +x "${SCRIPT_PATH}"

    # 同步安装 clean.sh 脚本
    local clean_script_path="${CONFIG_DIR}/clean.sh"
    if [[ -f "$(dirname "$0")/clean.sh" ]]; then
        cp -f "$(dirname "$0")/clean.sh" "${clean_script_path}"
    else
        curl -fsSL "https://raw.githubusercontent.com/luckyjamesriver/VPS-Sing-box/main/clean.sh?v=$(date +%s)" -o "${clean_script_path}" || true
    fi
    [[ -f "${clean_script_path}" ]] && chmod +x "${clean_script_path}"

    # 创建快捷命令软链接，覆盖 /usr/bin 与 /usr/local/bin，确保 100% 识别
    ln -sf "${SCRIPT_PATH}" "/usr/bin/vps"
    ln -sf "${SCRIPT_PATH}" "/usr/local/bin/vps"
    ln -sf "${SCRIPT_PATH}" "/usr/bin/sb"
    ln -sf "${SCRIPT_PATH}" "/usr/local/bin/sb"

    info "快捷命令 [vps] 已就绪。"
}

# --- Interactive Install Entrypoint ---
install_flow() {
    check_root
    check_system
    install_dependencies
    enable_bbr

    local public_ip
    public_ip=$(get_public_ip)

    local is_reuse="false"
    local user_domain=""
    local old_uuid=""
    local old_up="50"
    local old_down="500"

    # 如果存在本机标准安装配置，支持平滑升级/保留
    if [[ -f "${INFO_FILE}" ]]; then
        user_domain=$(jq -r '.domain // empty' "${INFO_FILE}" 2>/dev/null)
        old_uuid=$(jq -r '.uuid // empty' "${INFO_FILE}" 2>/dev/null)
        old_up=$(jq -r '.server_up_mbps // 50' "${INFO_FILE}" 2>/dev/null)
        old_down=$(jq -r '.server_down_mbps // 500' "${INFO_FILE}" 2>/dev/null)
    elif [[ -f "${CONFIG_FILE}" ]]; then
        old_uuid=$(jq -r '.inbounds[] | select(.type=="vless") | .users[0].uuid // empty' "${CONFIG_FILE}" 2>/dev/null | head -n 1)
        user_domain=$(jq -r '.inbounds[] | select(.type=="hysteria2" or .type=="tuic") | .tls.server_name // empty' "${CONFIG_FILE}" 2>/dev/null | head -n 1)
    fi

    if [[ -n "${old_uuid}" && -n "${user_domain}" ]]; then
        title "检测到现有 Sing-box 节点配置"
        echo -e "已记录配置:"
        echo -e "  - 域名: ${GREEN}${user_domain}${PLAIN}"
        echo -e "  - UUID: ${GREEN}${old_uuid}${PLAIN}"
        echo ""
        read -r -p "是否保留现有配置进行平滑升级？[Y/n]: " keep_choice < /dev/tty
        if [[ "${keep_choice}" != "n" && "${keep_choice}" != "N" ]]; then
            is_reuse="true"
            info "已选择保留现有配置平滑升级。"
        else
            info "已选择重新生成全新配置与密钥。"
            user_domain=""
            old_uuid=""
        fi
    fi

    if [[ "${is_reuse}" == "true" && -n "${user_domain}" ]]; then
        read -r -p "确认或修改解析域名 [回车保持为 ${user_domain}]: " input_domain < /dev/tty
        user_domain="${input_domain:-${user_domain}}"
    else
        title "配置 Cloudflare 域名"
        echo -e "提示: 请确保你已经在 Cloudflare 将该域名解析到 VPS IP (${GREEN}${public_ip}${PLAIN})。"
        echo -e "注意: 请保持 Cloudflare 上的代理状态为 ${YELLOW}仅限 DNS (灰色云朵)${PLAIN}。\n"

        while true; do
            read -r -p "请输入你的域名 (如 node.yourdomain.com): " user_domain < /dev/tty
            user_domain=$(echo "${user_domain}" | tr -d "[:space:]")
            if [[ -n "${user_domain}" ]]; then
                break
            fi
            warn "域名不能为空，请重新输入！"
        done
    fi

    title "配置 TCP Brutal 与带宽限速参数"
    echo -e "提示: 服务端上行对应客户端下行，服务端下行对应客户端上行。"
    read -r -p "请输入 VPS 上行带宽限制 up_mbps [回车默认 ${old_up}]: " input_up < /dev/tty
    local server_up_mbps="${input_up:-${old_up}}"
    read -r -p "请输入 VPS 下行带宽限制 down_mbps [回车默认 ${old_down}]: " input_down < /dev/tty
    local server_down_mbps="${input_down:-${old_down}}"
    info "设定带宽限制: VPS 上行 ${server_up_mbps} Mbps / 下行 ${server_down_mbps} Mbps"

    install_singbox_core
    generate_configs "${user_domain}" "${public_ip}" "${server_up_mbps}" "${server_down_mbps}" "${is_reuse}"
    start_service
    setup_shortcut

    # 安装完成后自动为用户生成初始安全备份
    backup_singbox >/dev/null 2>&1 || true

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

# --- Update Management Script ---
update_script() {
    info "正在从 GitHub 获取最新版本管理脚本..."
    local temp_file
    temp_file=$(mktemp)
    if curl -fsSL "https://raw.githubusercontent.com/luckyjamesriver/VPS-Sing-box/main/install.sh?v=$(date +%s)" -o "${temp_file}"; then
        if [[ -s "${temp_file}" ]]; then
            mv -f "${temp_file}" "${SCRIPT_PATH}"
            chmod +x "${SCRIPT_PATH}"
            ln -sf "${SCRIPT_PATH}" "/usr/bin/vps"
            ln -sf "${SCRIPT_PATH}" "/usr/local/bin/vps"
            ln -sf "${SCRIPT_PATH}" "/usr/bin/sb"
            ln -sf "${SCRIPT_PATH}" "/usr/local/bin/sb"
            info "管理脚本已成功更新至最新版本！"
            sleep 1
            exec "${SCRIPT_PATH}"
        else
            error "下载的脚本为空，取消更新！"
            rm -f "${temp_file}"
        fi
    else
        error "获取最新脚本失败，请检查网络连接！"
        rm -f "${temp_file}"
    fi
}

# --- Update Core Only ---
update_core() {
    check_root
    check_system
    install_singbox_core
    systemctl restart sing-box
    info "Sing-box 核心更新完毕并已重启服务。"
}

# --- Call Clean.sh ---
clean_flow() {
    check_root
    info "正在调用一键环境除旧与深度探查工具..."
    if [[ -f "$(dirname "$0")/clean.sh" ]]; then
        bash "$(dirname "$0")/clean.sh"
    elif [[ -f "${CONFIG_DIR}/clean.sh" ]]; then
        bash "${CONFIG_DIR}/clean.sh"
    else
        bash <(curl -fsSL "https://raw.githubusercontent.com/luckyjamesriver/VPS-Sing-box/main/clean.sh?v=$(date +%s)")
    fi
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
    rm -f "/usr/bin/vps" "/usr/local/bin/vps"
    rm -f "/usr/bin/sb" "/usr/local/bin/sb"

    info "Sing-box 已完全从系统中卸载干净。"
}


# --- Backup & Restore Handlers ---
BACKUP_DIR="/var/backups/sing-box"

backup_singbox() {
    title "执行 Sing-box 一键完整备份"
    mkdir -p "${BACKUP_DIR}"

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/sing-box-backup-${timestamp}.tar.gz"

    local backup_items=()
    [[ -d "${CONFIG_DIR}" ]] && backup_items+=("${CONFIG_DIR}")
    [[ -f "${BIN_PATH}" ]] && backup_items+=("${BIN_PATH}")
    [[ -f "${SERVICE_FILE}" ]] && backup_items+=("${SERVICE_FILE}")

    if [[ ${#backup_items[@]} -eq 0 ]]; then
        warn "未检测到 Sing-box 相关的配置文件或程序，无需创建备份。"
        return 0
    fi

    info "正在打包以下核心文件至备份档案:"
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
    echo -e "  - 备份内容包含: 配置目录(/etc/sing-box), 客户端订阅, 证书密钥, 主程序, Systemd 服务"
    tip "您可以在任何时候使用【一键恢复】功能将节点完全还原！"
    echo ""
}

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
    [[ -f "${BIN_PATH}" ]] && chmod +x "${BIN_PATH}"
    [[ -f "${SCRIPT_PATH}" ]] && chmod +x "${SCRIPT_PATH}"
    [[ -f "${CERT_KEY}" ]] && chmod 600 "${CERT_KEY}"

    setup_shortcut
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1 || true
    systemctl restart sing-box >/dev/null 2>&1 || true

    sleep 1

    if systemctl is-active --quiet sing-box; then
        success "🎉 恭喜！Sing-box 已从备份成功完整恢复并恢复运行！"
        echo ""
        show_nodes
    else
        warn "Sing-box 文件已解压恢复，但服务启动未通过。请执行: journalctl -u sing-box -e 查看日志。"
    fi
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
    echo -e "${GREEN}3.${PLAIN} 查看并复制 客户端完整配置文件 (/etc/sing-box/client/config.json)"
    echo -e "${GREEN}4.${PLAIN} 重启 Sing-box 服务"
    echo -e "${GREEN}5.${PLAIN} 停止 Sing-box 服务"
    echo -e "${GREEN}6.${PLAIN} 查看 实时运行日志 (退出按 Ctrl+C)"
    echo -e "${GREEN}7.${PLAIN} 📦 【一键完整备份】Sing-box (配置+证书+密钥+程序)"
    echo -e "${GREEN}8.${PLAIN} 🔄 【一键恢复备份】从历史备份还原 Sing-box"
    echo -e "${GREEN}9.${PLAIN} 一键环境除旧 / 扫描清理第三方旧代理 (Clean)"
    echo -e "${GREEN}10.${PLAIN} 单独更新 Sing-box 核心版本"
    echo -e "${GREEN}11.${PLAIN} 更新 管理脚本自身 (Update Script)"
    echo -e "${GREEN}12.${PLAIN} 完全卸载 Sing-box"
    echo -e "${GREEN}0.${PLAIN} 退出菜单"
    echo -e "----------------------------------------------------"

    read -r -p "请输入选项 [0-12]: " choice < /dev/tty
    case "${choice}" in
        1) install_flow ;;
        2) show_nodes ;;
        3) show_client_config ;;
        4) service_restart ;;
        5) service_stop ;;
        6) service_logs ;;
        7) backup_singbox ;;
        8) restore_singbox ;;
        9) clean_flow ;;
        10) update_core ;;
        11) update_script ;;
        12) uninstall_flow ;;
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
        backup)
            backup_singbox
            ;;
        restore)
            restore_singbox
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
        upgrade|update-script)
            update_script
            ;;
        update)
            update_core
            ;;
        clean|purge)
            clean_flow
            ;;
        uninstall)
            uninstall_flow
            ;;
        *)
            echo "用法: $0 {install|show|client|backup|restore|restart|stop|status|logs|upgrade|update|clean|uninstall}"
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
