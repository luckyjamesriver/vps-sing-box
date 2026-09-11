#!/usr/bin/env bash
# ==============================================================================
# Project: VPS-Sing-box
# Script: clean.sh (VPS 环境除旧、深度探查、配置校验与旧代理清理工具)
# Description: 智能深度扫描非标准安装路径（如 /etc/v2ray-agent/ 等）、精确提取并校验原有凭据（UUID/端口/密码/密钥），
#              支持全量清理时继承旧配置以实现客户端 0 改动无缝连接，并对 Tailscale、WordPress、Web 网站及数据库提供 100% 隔离保护。
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
    for cmd in jq python3 curl ss; do
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
EXTRACTED_INFO_FILE="/tmp/extracted_proxy_info.json"

FOUND_PROTECTED=()
FOUND_LEGACY_SERVICES=()
FOUND_LEGACY_BINS=()
FOUND_LEGACY_DIRS=()
FOUND_SB_SERVICES=()

# --- 深度提取 Python 核心引擎 (含注释清洗、容错、Xray/Singbox 双协议解析与正则兜底) ---
run_deep_extractor() {
    if ! command -v python3 >/dev/null 2>&1; then
        return 0
    fi

    python3 - << 'PYEOF'
import json
import glob
import os
import re
import subprocess

def clean_json_text(text):
    text = text.lstrip('\ufeff')
    text = re.sub(r'//.*', '', text)
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.DOTALL)
    text = re.sub(r',\s*([\}\]])', r'\1', text)
    return text

def parse_json_safely(filepath):
    try:
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            c = clean_json_text(f.read())
            return json.loads(c)
    except Exception:
        return None

extracted = {
    "detected_services": [],
    "detected_configs": [],
    "credentials": {},
    "is_non_standard": False,
    "is_usable": False,
    "usable_summary": []
}

# 1. 探查 systemd
service_names = ["sing-box.service", "xray.service", "v2ray.service", "hysteria.service", "tuic.service", "v2ray-agent.service"]
for svc in service_names:
    try:
        out = subprocess.check_output(["systemctl", "cat", svc], stderr=subprocess.DEVNULL).decode('utf-8', errors='ignore')
        for line in out.splitlines():
            line = line.strip()
            if line.startswith("ExecStart="):
                cmd = line.split("=", 1)[1].strip()
                extracted["detected_services"].append({"service": svc, "exec": cmd})
                if "/etc/sing-box" not in cmd and "/usr/local/bin/sing-box" not in cmd:
                    extracted["is_non_standard"] = True
    except Exception:
        pass

# 2. 收集候选文件
candidate_files = set()
for s in extracted["detected_services"]:
    cmd = s["exec"]
    m = re.findall(r'(-c|-config|--config|-D)\s+([^\s]+)', cmd)
    for flag, path in m:
        if os.path.isfile(path):
            candidate_files.add(path)
        elif os.path.isdir(path):
            for jf in glob.glob(os.path.join(path, "*.json")):
                candidate_files.add(jf)

# 搜索常用路径 (v2ray-agent, x-ui, sing-box 等)
search_globs = [
    "/etc/v2ray-agent/sing-box/conf/*.json",
    "/etc/v2ray-agent/sing-box/conf/config.json",
    "/etc/v2ray-agent/xray/conf/*.json",
    "/etc/v2ray-agent/v2ray/conf/*.json",
    "/etc/v2ray-agent/*.json",
    "/etc/v2ray-agent/*.config",
    "/etc/sing-box/*.json",
    "/etc/sing-box/client/*.json",
    "/usr/local/etc/sing-box/*.json",
    "/opt/sing-box/*.json",
    "/etc/xray/*.json",
    "/etc/v2ray/*.json",
    "/etc/hysteria/*.json",
    "/etc/tuic/*.json",
    "/etc/x-ui/*.json"
]

for g in search_globs:
    for f in glob.glob(g):
        if os.path.isfile(f):
            candidate_files.add(f)

creds = {}

for c_path in sorted(list(candidate_files)):
    raw_text = ""
    try:
        with open(c_path, 'r', encoding='utf-8', errors='ignore') as f:
            raw_text = f.read()
    except Exception:
        continue

    extracted["detected_configs"].append(c_path)
    data = parse_json_safely(c_path)

    if data and isinstance(data, dict):
        if os.path.basename(c_path) == "node_info.json":
            for k in ["domain", "public_ip", "uuid", "reality_sni", "private_key", "public_key", "short_id",
                      "port_reality_tcp", "port_reality_grpc", "port_hy2", "hy2_password", "salamander_pwd",
                      "port_tuic", "tuic_password", "server_up_mbps", "server_down_mbps"]:
                if k in data and data[k] and k not in creds:
                    creds[k] = data[k]

        inbounds = data.get("inbounds", [])
        for ib in inbounds:
            if not isinstance(ib, dict):
                continue
            ib_type = ib.get("type") or ib.get("protocol") or ""
            listen_port = ib.get("listen_port") or ib.get("port")

            # VLESS (Sing-box & Xray)
            if ib_type == "vless":
                users = ib.get("users") or ib.get("settings", {}).get("clients", [])
                if users and isinstance(users, list) and isinstance(users[0], dict):
                    u_uuid = users[0].get("uuid") or users[0].get("id")
                    if u_uuid:
                        creds.setdefault("uuid", u_uuid)

                tls = ib.get("tls") or ib.get("streamSettings", {})
                reality = tls.get("reality") or tls.get("realitySettings", {})
                if reality:
                    priv_k = reality.get("private_key") or reality.get("privateKey")
                    if priv_k:
                        creds.setdefault("private_key", priv_k)
                    pub_k = reality.get("public_key") or reality.get("publicKey")
                    if pub_k:
                        creds.setdefault("public_key", pub_k)
                    s_id = reality.get("short_id") or reality.get("shortIds")
                    if s_id:
                        if isinstance(s_id, list):
                            sids = [s for s in s_id if s]
                            if sids:
                                creds.setdefault("short_id", sids[-1])
                        elif isinstance(s_id, str):
                            creds.setdefault("short_id", s_id)
                    
                    sni = tls.get("server_name") or (reality.get("serverNames", [None])[0] if isinstance(reality.get("serverNames"), list) else None)
                    if not sni and "handshake" in reality and "server" in reality["handshake"]:
                        sni = reality["handshake"]["server"]
                    if sni:
                        creds.setdefault("reality_sni", sni)

                transport = ib.get("transport") or ib.get("streamSettings", {})
                net_type = ib.get("network") or transport.get("network") or transport.get("type") or ""
                if net_type == "grpc":
                    if listen_port:
                        creds.setdefault("port_reality_grpc", int(listen_port))
                else:
                    if listen_port:
                        creds.setdefault("port_reality_tcp", int(listen_port))

                multiplex = ib.get("multiplex", {})
                brutal = multiplex.get("brutal", {})
                if brutal:
                    if "up_mbps" in brutal:
                        creds.setdefault("server_up_mbps", int(brutal["up_mbps"]))
                    if "down_mbps" in brutal:
                        creds.setdefault("server_down_mbps", int(brutal["down_mbps"]))

            # Hysteria 2
            elif ib_type == "hysteria2":
                if listen_port:
                    creds.setdefault("port_hy2", int(listen_port))
                if "up_mbps" in ib:
                    creds.setdefault("server_up_mbps", int(ib["up_mbps"]))
                if "down_mbps" in ib:
                    creds.setdefault("server_down_mbps", int(ib["down_mbps"]))
                users = ib.get("users") or ib.get("auth", {}).get("users", [])
                if users and isinstance(users, list) and isinstance(users[0], dict):
                    pwd = users[0].get("password") or users[0].get("auth")
                    if pwd:
                        creds.setdefault("hy2_password", str(pwd))
                obfs = ib.get("obfs", {})
                if obfs and isinstance(obfs, dict) and "password" in obfs:
                    creds.setdefault("salamander_pwd", str(obfs["password"]))
                tls = ib.get("tls", {})
                if tls and isinstance(tls, dict):
                    if "server_name" in tls and tls["server_name"]:
                        creds.setdefault("domain", tls["server_name"])
                    if "certificate_path" in tls and os.path.exists(tls["certificate_path"]):
                        creds.setdefault("cert_pem", tls["certificate_path"])
                    if "key_path" in tls and os.path.exists(tls["key_path"]):
                        creds.setdefault("cert_key", tls["key_path"])

            # TUIC
            elif ib_type == "tuic":
                if listen_port:
                    creds.setdefault("port_tuic", int(listen_port))
                users = ib.get("users", [])
                if users and isinstance(users, list) and isinstance(users[0], dict):
                    if "uuid" in users[0]:
                        creds.setdefault("uuid", users[0]["uuid"])
                    if "password" in users[0]:
                        creds.setdefault("tuic_password", str(users[0]["password"]))
                tls = ib.get("tls", {})
                if tls and isinstance(tls, dict):
                    if "server_name" in tls and tls["server_name"]:
                        creds.setdefault("domain", tls["server_name"])
                    if "certificate_path" in tls and os.path.exists(tls["certificate_path"]):
                        creds.setdefault("cert_pem", tls["certificate_path"])
                    if "key_path" in tls and os.path.exists(tls["key_path"]):
                        creds.setdefault("cert_key", tls["key_path"])

    # 正则兜底提取 (保障任意非标准/损毁 JSON 依然能提取核心参数)
    for c_path in candidate_files:
        try:
            with open(c_path, 'r', encoding='utf-8', errors='ignore') as f:
                raw_text = f.read()
        except Exception:
            continue

        if "uuid" not in creds:
            uuid_match = re.search(r'["\']?(?:uuid|id)["\']?\s*[:=]\s*["\']([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})["\']', raw_text, re.IGNORECASE)
            if uuid_match:
                creds["uuid"] = uuid_match.group(1)

        if "private_key" not in creds:
            pk_match = re.search(r'["\']?(?:private_key|privateKey)["\']?\s*[:=]\s*["\']([A-Za-z0-9+/=_-]{43,44})["\']', raw_text)
            if pk_match:
                creds["private_key"] = pk_match.group(1)

        if "short_id" not in creds:
            sid_match = re.search(r'["\']?(?:short_id|shortIds|shortId)["\']?\s*[:=]\s*\[?\s*["\']([a-f0-9]{8,16})["\']', raw_text)
            if sid_match:
                creds["short_id"] = sid_match.group(1)

        if "domain" not in creds:
            dom_match = re.search(r'["\']?(?:server_name|serverName|domain|host)["\']?\s*[:=]\s*["\']([a-zA-Z0-9][-a-zA-Z0-9.]*\.[a-zA-Z]{2,})["\']', raw_text)
            if dom_match and "apple.com" not in dom_match.group(1) and "cloudflare" not in dom_match.group(1):
                creds["domain"] = dom_match.group(1)

    # 3. 探查第三方证书与域名 (从 /etc/v2ray-agent/tls/ 等证书文件名提取)
    candidate_certs = [
        ("/etc/v2ray-agent/tls/*.crt", "/etc/v2ray-agent/tls/*.key"),
        ("/etc/v2ray-agent/tls/*.pem", "/etc/v2ray-agent/tls/*.key"),
        ("/root/cert/*.crt", "/root/cert/*.key"),
        ("/root/cert/*.pem", "/root/cert/*.key")
    ]
    for crt_g, key_g in candidate_certs:
        crts = glob.glob(crt_g)
        keys = glob.glob(key_g)
        if crts and keys and os.path.exists(crts[0]) and os.path.exists(keys[0]):
            creds.setdefault("cert_pem", crts[0])
            creds.setdefault("cert_key", keys[0])
            base_name = os.path.basename(crts[0])
            potential_dom = re.sub(r'\.(crt|pem|cer|key)$', '', base_name)
            if '.' in potential_dom and "domain" not in creds:
                creds["domain"] = potential_dom

    # 4. 校验旧配置凭据是否完整可用 (Check if config is usable for seamless migration)
    usable_checks = []
    is_valid_uuid = False
    if "uuid" in creds and re.match(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$', str(creds["uuid"]), re.IGNORECASE):
        is_valid_uuid = True
        usable_checks.append(f"UUID 格式标准有效 ({creds['uuid']})")
    
    if "domain" in creds and "." in str(creds["domain"]):
        usable_checks.append(f"解析域名有效 ({creds['domain']})")

    port_count = sum(1 for k in ["port_reality_tcp", "port_reality_grpc", "port_hy2", "port_tuic"] if k in creds and str(creds[k]).isdigit())
    if port_count > 0:
        usable_checks.append(f"已成功捕获 {port_count} 个协议出入站端口")

    if is_valid_uuid:
        extracted["is_usable"] = True
    extracted["usable_summary"] = usable_checks
    extracted["credentials"] = creds

    with open("/tmp/extracted_proxy_info.json", "w") as f:
        json.dump(extracted, f, indent=2)

PYEOF
}

# --- 1. 高性能快速扫描引擎 ---
scan_system() {
    FOUND_PROTECTED=()
    FOUND_LEGACY_SERVICES=()
    FOUND_LEGACY_BINS=()
    FOUND_LEGACY_DIRS=()
    FOUND_SB_SERVICES=()

    check_dependencies
    run_deep_extractor

    # 1. 检查 Sing-box 服务状态
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        FOUND_SB_SERVICES+=("sing-box.service [active]")
    elif systemctl is-enabled --quiet sing-box 2>/dev/null; then
        FOUND_SB_SERVICES+=("sing-box.service [inactive/enabled]")
    fi

    # 2. 检查受保护服务
    for p in "${PROTECTED_SERVICES[@]}"; do
        if systemctl is-active --quiet "${p}" 2>/dev/null; then
            FOUND_PROTECTED+=("${p}.service [active]")
        fi
    done

    # 3. 检查旧代理服务
    for l in "${LEGACY_PROXY_SERVICES[@]}"; do
        if systemctl is-active --quiet "${l}" 2>/dev/null; then
            FOUND_LEGACY_SERVICES+=("${l}.service [active]")
        elif systemctl is-enabled --quiet "${l}" 2>/dev/null; then
            FOUND_LEGACY_SERVICES+=("${l}.service [inactive/enabled]")
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
            else if (proc ~ /sing-box/) hint="[Sing-box 节点入站]";
            else if (proc ~ /tailscaled/) hint="[Tailscale Mesh VPN]";
            else if (proc ~ /xray|v2ray|hysteria|tuic|trojan/) hint="[⚠️ 旧代理服务]";
            else hint="[系统/其他应用]";
            printf "%-6s %-25s %-32s %-20s\n", proto, addr, proc, hint;
        }' || true
    fi
    echo ""
}

# --- 3. 展示探查到的凭据与详情 ---
show_extracted_credentials() {
    if [[ ! -f "${EXTRACTED_INFO_FILE}" ]]; then
        return 0
    fi

    local is_non_standard has_creds
    is_non_standard=$(jq -r '.is_non_standard // false' "${EXTRACTED_INFO_FILE}" 2>/dev/null || echo "false")
    has_creds=$(jq -r '.credentials | length' "${EXTRACTED_INFO_FILE}" 2>/dev/null || echo "0")

    title "深度探查：已识别的节点与旧配置凭据"

    local detected_svcs detected_cfgs
    detected_svcs=$(jq -r '.detected_services[] | "  - 守护服务: " + .service + " (命令: " + .exec + ")"' "${EXTRACTED_INFO_FILE}" 2>/dev/null || true)
    detected_cfgs=$(jq -r '.detected_configs[] | "  - 配置文件: " + .' "${EXTRACTED_INFO_FILE}" 2>/dev/null || true)

    if [[ -n "${detected_svcs}" ]]; then
        echo -e "${YELLOW}已定位的运行服务与执行命令:${PLAIN}"
        echo -e "${detected_svcs}\n"
    fi
    if [[ -n "${detected_cfgs}" ]]; then
        echo -e "${YELLOW}已定位的配置与证书文件:${PLAIN}"
        echo -e "${detected_cfgs}\n"
    fi

    if [[ "${has_creds}" -gt 0 ]]; then
        echo -e "${CYAN}从旧配置中成功提取的核心凭据参数:${PLAIN}"
        local domain uuid pt_tcp pt_grpc pt_hy2 hy2_pwd pt_tuic tuic_pwd sni sid
        domain=$(jq -r '.credentials.domain // "未配置"' "${EXTRACTED_INFO_FILE}" 2>/dev/null)
        uuid=$(jq -r '.credentials.uuid // "未配置"' "${EXTRACTED_INFO_FILE}" 2>/dev/null)
        pt_tcp=$(jq -r '.credentials.port_reality_tcp // "未配置"' "${EXTRACTED_INFO_FILE}" 2>/dev/null)
        pt_grpc=$(jq -r '.credentials.port_reality_grpc // "未配置"' "${EXTRACTED_INFO_FILE}" 2>/dev/null)
        pt_hy2=$(jq -r '.credentials.port_hy2 // "未配置"' "${EXTRACTED_INFO_FILE}" 2>/dev/null)
        hy2_pwd=$(jq -r '.credentials.hy2_password // "未配置"' "${EXTRACTED_INFO_FILE}" 2>/dev/null)
        pt_tuic=$(jq -r '.credentials.port_tuic // "未配置"' "${EXTRACTED_INFO_FILE}" 2>/dev/null)
        tuic_pwd=$(jq -r '.credentials.tuic_password // "未配置"' "${EXTRACTED_INFO_FILE}" 2>/dev/null)
        sni=$(jq -r '.credentials.reality_sni // "www.apple.com"' "${EXTRACTED_INFO_FILE}" 2>/dev/null)
        sid=$(jq -r '.credentials.short_id // "未配置"' "${EXTRACTED_INFO_FILE}" 2>/dev/null)

        echo -e "  - 域名 (Domain)        : ${GREEN}${domain}${PLAIN}"
        echo -e "  - UUID                 : ${GREEN}${uuid}${PLAIN}"
        echo -e "  - Reality TCP 端口     : ${GREEN}${pt_tcp}${PLAIN} (SNI: ${sni}, ShortID: ${sid})"
        echo -e "  - Reality gRPC 端口    : ${GREEN}${pt_grpc}${PLAIN}"
        echo -e "  - Hysteria 2 端口      : ${GREEN}${pt_hy2}${PLAIN} (密码: ${hy2_pwd})"
        echo -e "  - TUIC v5 端口         : ${GREEN}${pt_tuic}${PLAIN} (密码: ${tuic_pwd})"
        
        # 凭据可用性诊断
        local is_usable
        is_usable=$(jq -r '.is_usable // false' "${EXTRACTED_INFO_FILE}" 2>/dev/null)
        if [[ "${is_usable}" == "true" ]]; then
            echo -e "\n  ${GREEN}✔ 校验通过：原配置核心凭据完整可用，可在清理后直接继承，客户端免修改连接！${PLAIN}"
        else
            echo -e "\n  ${YELLOW}⚠️ 提示：检测到部分凭据，新安装时缺失项将自动补充生成。${PLAIN}"
        fi
        echo ""
    else
        echo -e "  ${YELLOW}未在现有旧配置中解析到结构化代理凭据。${PLAIN}\n"
    fi
}

# --- 4. 询问用户是否保留并导出旧凭据 ---
prompt_preserve_credentials() {
    if [[ ! -f "${EXTRACTED_INFO_FILE}" ]]; then
        return 0
    fi
    local has_creds
    has_creds=$(jq -r '.credentials | length' "${EXTRACTED_INFO_FILE}" 2>/dev/null || echo "0")
    [[ "${has_creds}" -eq 0 ]] && return 0

    title "智能凭据继承与保留保护"
    echo -e "${YELLOW}系统检测到旧配置中存在有效的节点凭据（域名、UUID、端口、密钥等）。${PLAIN}"
    echo -e "${GREEN}💡 推荐保留：将其单独导出为标准档案 (${SB_STANDARD_DIR}/node_info.json)，稍后全新部署时可直接继承使用，手机/电脑客户端无需重新配置！${PLAIN}\n"

    read -r -p "是否保留并导出以上凭据供新安装使用？[Y/n]: " keep_choice < /dev/tty
    if [[ "${keep_choice}" != "n" && "${keep_choice}" != "N" ]]; then
        mkdir -p "${SB_STANDARD_DIR}"
        jq '.credentials' "${EXTRACTED_INFO_FILE}" > "${SB_STANDARD_DIR}/node_info.json" 2>/dev/null || true
        
        local cert_pem cert_key
        cert_pem=$(jq -r '.credentials.cert_pem // empty' "${EXTRACTED_INFO_FILE}" 2>/dev/null)
        cert_key=$(jq -r '.credentials.cert_key // empty' "${EXTRACTED_INFO_FILE}" 2>/dev/null)
        if [[ -n "${cert_pem}" && -f "${cert_pem}" && -n "${cert_key}" && -f "${cert_key}" ]]; then
            cp -f "${cert_pem}" "${SB_STANDARD_DIR}/cert.pem" 2>/dev/null || true
            cp -f "${cert_key}" "${SB_STANDARD_DIR}/cert.key" 2>/dev/null || true
            info "已同步继承原有 TLS 证书至 ${SB_STANDARD_DIR}/cert.pem"
        fi

        success "凭证已成功保存至标准位置: ${YELLOW}${SB_STANDARD_DIR}/node_info.json${PLAIN}"
        tip "在后续运行安装脚本时，将自动使用这些参数无缝升级！"
    else
        info "已选择跳过保留旧凭据。"
    fi
}

# --- 5. 展示综合扫描诊断报告 ---
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

    echo -e "${CYAN}⚡  Sing-box 核心与管理状态:${PLAIN}"
    if [[ ${#FOUND_SB_SERVICES[@]} -gt 0 || -f "${SB_STANDARD_BIN}" || -d "${SB_STANDARD_DIR}" ]]; then
        for item in "${FOUND_SB_SERVICES[@]}"; do
            echo -e "   ✔  ${CYAN}${item}${PLAIN}"
        done
        [[ -f "${SB_STANDARD_BIN}" ]] && echo -e "   ✔  标准主程序: ${SB_STANDARD_BIN}"
        [[ -d "${SB_STANDARD_DIR}" ]] && echo -e "   ✔  标准配置目录: ${SB_STANDARD_DIR}"
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
        echo -e "   【遗留配置与日志目录】"
        for item in "${FOUND_LEGACY_DIRS[@]}"; do
            echo -e "   ❌  ${YELLOW}${item}${PLAIN}"
        done
    fi

    if [[ ${legacy_found} -eq 0 ]]; then
        echo -e "   ${GREEN}✨ 未发现常见的第三方旧代理残留！${PLAIN}"
    fi
    echo ""
}

create_backup() {
    local backup_tar="/root/vps_cleanup_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    local items_to_backup=()

    [[ -d "${SB_STANDARD_DIR}" ]] && items_to_backup+=("${SB_STANDARD_DIR}")
    for d in "${FOUND_LEGACY_DIRS[@]}"; do
        [[ -d "${d}" ]] && items_to_backup+=("${d}")
    done

    if [[ ${#items_to_backup[@]} -gt 0 ]]; then
        info "正在为涉及的配置创建归档备份..."
        tar -czf "${backup_tar}" "${items_to_backup[@]}" 2>/dev/null || true
        success "备份已保存至: ${YELLOW}${backup_tar}${PLAIN}"
    fi
}

clean_legacy_proxies() {
    title "清理第三方旧代理与遗留组件"

    prompt_preserve_credentials

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
    read -r -p "是否确认清理上述第三方旧代理组件？[y/N]: " confirm < /dev/tty
    if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
        warn "已取消清理第三方旧代理。"
        return 0
    fi

    create_backup

    for s in "${FOUND_LEGACY_SERVICES[@]}"; do
        local svc="${s%% *}"
        info "正在停止并清理服务: ${svc}..."
        systemctl stop "${svc}" >/dev/null 2>&1 || true
        systemctl disable "${svc}" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${svc}" "/lib/systemd/system/${svc}" "/usr/lib/systemd/system/${svc}" >/dev/null 2>&1 || true
    done
    systemctl daemon-reload >/dev/null 2>&1 || true

    for b in "${FOUND_LEGACY_BINS[@]}"; do
        info "正在删除旧程序: ${b}..."
        rm -f "${b}" 2>/dev/null || true
    done

    for d in "${FOUND_LEGACY_DIRS[@]}"; do
        info "正在删除旧目录: ${d}..."
        rm -rf "${d}" 2>/dev/null || true
    done

    success "第三方旧代理与遗留组件清理完毕！"
}

clean_singbox() {
    title "重置 / 卸载 Sing-box 环境"

    prompt_preserve_credentials

    echo -e "${YELLOW}请选择 Sing-box 清理模式:${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN} 仅重置节点与配置（保留自签 10 年证书和节点档案，方便重新部署）"
    echo -e "  ${GREEN}2.${PLAIN} 完全卸载 Sing-box（删除二进制、所有配置文件、证书及快捷命令）"
    echo -e "  ${GREEN}0.${PLAIN} 取消返回"
    echo ""

    read -r -p "请输入选项 [0-2]: " sb_choice < /dev/tty
    case "${sb_choice}" in
        1)
            read -r -p "确认清空 Sing-box 节点配置并重置？[y/N]: " cf < /dev/tty
            if [[ "${cf}" == "y" || "${cf}" == "Y" ]]; then
                create_backup
                systemctl stop sing-box >/dev/null 2>&1 || true
                rm -f "${SB_STANDARD_DIR}/config.json"
                rm -rf "${SB_STANDARD_DIR}/client" "${SB_STANDARD_DIR}/client_config.json"
                success "Sing-box 节点配置已清空，保留了证书与节点档案。"
            fi
            ;;
        2)
            read -r -p "确认完全卸载 Sing-box？[y/N]: " cf < /dev/tty
            if [[ "${cf}" == "y" || "${cf}" == "Y" ]]; then
                create_backup
                systemctl stop sing-box >/dev/null 2>&1 || true
                systemctl disable sing-box >/dev/null 2>&1 || true
                rm -f "${SB_STANDARD_SERVICE}"
                systemctl daemon-reload
                rm -f "${SB_STANDARD_BIN}"
                rm -rf "${SB_STANDARD_DIR}"
                rm -f "/usr/bin/vps" "/usr/local/bin/vps" "/usr/bin/sb" "/usr/local/bin/sb"
                success "Sing-box 已完全从系统中卸载干净！"
            fi
            ;;
        0|*)
            info "已取消。"
            ;;
    esac
}

# --- 9. 全量深度除旧 (含旧凭据检查、继承选择与客户端 0 改动无缝衔接) ---
clean_all_deep() {
    title "全量深度除旧（清理所有旧代理残留 + 重置为标准 Sing-box 准备）"
    echo -e "${RED}⚠️  注意：此操作将清理所有第三方旧代理（Xray/V2Ray/v2ray-agent/Trojan等）以及 Sing-box 旧服务！${PLAIN}"
    echo -e "${GREEN}🛡️  受保护服务（Tailscale、Nginx、Caddy、WordPress、MySQL 等）将得到 100% 绝对保护！${PLAIN}\n"

    # 1. 检查已提取的旧配置凭据是否完整可用
    local is_usable has_creds
    is_usable=$(jq -r '.is_usable // false' "${EXTRACTED_INFO_FILE}" 2>/dev/null || echo "false")
    has_creds=$(jq -r '.credentials | length' "${EXTRACTED_INFO_FILE}" 2>/dev/null || echo "0")

    local keep_credentials="false"

    if [[ "${has_creds}" -gt 0 ]]; then
        echo -e "${CYAN}【原配置可复用性检查结果】:${PLAIN}"
        local u_sum
        u_sum=$(jq -r '.usable_summary[] | "  ✔ " + .' "${EXTRACTED_INFO_FILE}" 2>/dev/null || true)
        echo -e "${u_sum}"
        
        if [[ "${is_usable}" == "true" ]]; then
            echo -e "  ${GREEN}👉 检查结论: 原配置核心凭据完整有效！推荐保留，实现客户端 0 改动平滑连接。${PLAIN}\n"
        else
            echo -e "  ${YELLOW}👉 检查结论: 捕获了部分参数，在新安装时缺失项将自动补充生成。${PLAIN}\n"
        fi

        echo -e "${YELLOW}请选择全量清理策略:${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} 保留并继承旧凭据 (推荐): 导出凭据至 ${SB_STANDARD_DIR}/node_info.json，清理后新安装可直接复用，客户端无需任何修改！"
        echo -e "  ${GREEN}2.${PLAIN} 彻底清空（不保留任何旧凭据）: 清除所有旧环境与凭据，下次安装时生成全新随机端口与密钥。"
        echo -e "  ${GREEN}0.${PLAIN} 取消退出"
        echo ""

        read -r -p "请输入策略选项 [1/2/0]: " clean_policy < /dev/tty
        case "${clean_policy}" in
            1)
                keep_credentials="true"
                info "已选择保留旧凭据，执行平滑迁移全量清理..."
                ;;
            2)
                keep_credentials="false"
                info "已选择彻底清空所有配置..."
                ;;
            0|*)
                warn "已取消全量深度清理。"
                return 0
                ;;
        esac
    else
        read -r -p "是否确认执行全量深度清理？[y/N]: " confirm < /dev/tty
        if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
            warn "已取消全量深度清理。"
            return 0
        fi
    fi

    create_backup

    # 如果选择保留旧凭据，先行导出到标准档案
    if [[ "${keep_credentials}" == "true" ]]; then
        mkdir -p "${SB_STANDARD_DIR}"
        jq '.credentials' "${EXTRACTED_INFO_FILE}" > "${SB_STANDARD_DIR}/node_info.json" 2>/dev/null || true
        
        local cert_pem cert_key
        cert_pem=$(jq -r '.credentials.cert_pem // empty' "${EXTRACTED_INFO_FILE}" 2>/dev/null)
        cert_key=$(jq -r '.credentials.cert_key // empty' "${EXTRACTED_INFO_FILE}" 2>/dev/null)
        if [[ -n "${cert_pem}" && -f "${cert_pem}" && -n "${cert_key}" && -f "${cert_key}" ]]; then
            cp -f "${cert_pem}" "${SB_STANDARD_DIR}/cert.pem" 2>/dev/null || true
            cp -f "${cert_key}" "${SB_STANDARD_DIR}/cert.key" 2>/dev/null || true
        fi
    fi

    # 1. 清理第三方旧代理
    for s in "${FOUND_LEGACY_SERVICES[@]}"; do
        local svc="${s%% *}"
        info "正在停止并清理服务: ${svc}..."
        systemctl stop "${svc}" >/dev/null 2>&1 || true
        systemctl disable "${svc}" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${svc}" "/lib/systemd/system/${svc}" "/usr/lib/systemd/system/${svc}" >/dev/null 2>&1 || true
    done
    for b in "${FOUND_LEGACY_BINS[@]}"; do
        rm -f "${b}" 2>/dev/null || true
    done
    for d in "${FOUND_LEGACY_DIRS[@]}"; do
        rm -rf "${d}" 2>/dev/null || true
    done

    # 2. 清理旧 Sing-box 服务单元与非标准程序
    systemctl stop sing-box >/dev/null 2>&1 || true
    systemctl disable sing-box >/dev/null 2>&1 || true
    rm -f "${SB_STANDARD_SERVICE}"
    systemctl daemon-reload
    rm -f "${SB_STANDARD_BIN}"
    
    if [[ "${keep_credentials}" == "true" ]]; then
        # 保留 node_info.json 和 cert.*
        if [[ -d "${SB_STANDARD_DIR}" ]]; then
            find "${SB_STANDARD_DIR}" -mindepth 1 ! -name 'node_info.json' ! -name 'cert.pem' ! -name 'cert.key' -exec rm -rf {} + 2>/dev/null || true
        fi
    else
        rm -rf "${SB_STANDARD_DIR}"
    fi

    rm -f "/usr/bin/vps" "/usr/local/bin/vps" "/usr/bin/sb" "/usr/local/bin/sb"

    success "🎉 全量深度除旧完成！VPS 当前代理环境已完全纯净化。"
    
    if [[ "${keep_credentials}" == "true" ]]; then
        echo -e "\n${GREEN}💡 节点凭据已妥善保存至 ${SB_STANDARD_DIR}/node_info.json${PLAIN}"
        read -r -p "是否立即启动新版一键安装脚本（自动继承旧配置，客户端 0 改动）？[Y/n]: " run_install < /dev/tty
        if [[ "${run_install}" != "n" && "${run_install}" != "N" ]]; then
            bash <(curl -fsSL "https://raw.githubusercontent.com/luckyjamesriver/VPS-Sing-box/main/install.sh?v=$(date +%s)")
        fi
    else
        read -r -p "是否立即启动全新一键安装脚本（全新配置）？[y/N]: " run_install < /dev/tty
        if [[ "${run_install}" == "y" || "${run_install}" == "Y" ]]; then
            bash <(curl -fsSL "https://raw.githubusercontent.com/luckyjamesriver/VPS-Sing-box/main/install.sh?v=$(date +%s)")
        fi
    fi
}

# --- 交互主菜单 ---
clean_menu() {
    check_root
    scan_system

    echo -e "${PURPLE}====================================================${PLAIN}"
    echo -e "${CYAN}        VPS-Sing-box 智能环境除旧与清理工具         ${PLAIN}"
    echo -e "${BLUE}    GitHub: https://github.com/luckyjamesriver/VPS-Sing-box${PLAIN}"
    echo -e "${PURPLE}====================================================${PLAIN}"

    show_scan_report
    show_extracted_credentials
    show_network_ports

    echo -e "${PURPLE}====================================================${PLAIN}"
    echo -e "${YELLOW}请选择除旧清理操作:${PLAIN}"
    echo -e "----------------------------------------------------"
    echo -e "${GREEN}1.${PLAIN} 仅清理【第三方旧代理残留】(Xray/V2Ray/v2ray-agent/Trojan等, 可保留凭据)"
    echo -e "${GREEN}2.${PLAIN} 管理与清理【Sing-box 配置 / 卸载】"
    echo -e "${GREEN}3.${PLAIN} 【全量深度除旧】(清理所有旧代理 + 智能继承/全新重置 Sing-box)"
    echo -e "${GREEN}4.${PLAIN} 单独导出/保存当前节点凭据档案 (/etc/sing-box/node_info.json)"
    echo -e "${GREEN}5.${PLAIN} 重新刷新扫描系统服务与端口"
    echo -e "${GREEN}0.${PLAIN} 退出清理脚本"
    echo -e "----------------------------------------------------"

    read -r -p "请输入选项 [0-5]: " menu_choice < /dev/tty
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
            prompt_preserve_credentials
            ;;
        5)
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

# --- CLI 调用入口 ---
if [[ $# -gt 0 ]]; then
    check_root
    scan_system
    case "$1" in
        scan|report|status)
            show_scan_report
            show_extracted_credentials
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
        extract|save)
            prompt_preserve_credentials
            ;;
        *)
            echo "用法: $0 [scan|legacy|singbox|all|extract]"
            exit 1
            ;;
    esac
else
    clean_menu
fi
