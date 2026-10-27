# VPS-Sing-box 🚀

> 极致精简、原生性能、免证书维护的 Sing-box 四合一全能服务端一键部署脚本。
> 专为追求干净、纯粹、高抗封锁与高速连接的 VPS 用户打造。

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Sing-box Version](https://img.shields.io/badge/Sing--box-Latest-orange.svg)](https://github.com/SagerNet/sing-box)
[![OS: Debian & Ubuntu](https://img.shields.io/badge/OS-Debian_%7C_Ubuntu-green.svg)](#准备条件)

---

## 🌟 核心设计理念

传统的全能脚本往往动辄上万行代码，强行捆绑 Nginx、acme.sh 证书续期、静态伪装站等复杂组件。对于现代的 **Reality、Hysteria 2、TUIC** 协议而言，这些传统组件不仅是冗余的，还会占用额外内存、引发端口冲突或证书过期断连。

**VPS-Sing-box** 剔除了 95% 的历史包袱，以纯粹的 Sing-box 官方核心为基础，提供：

1. **顶级协议 4+1 黄金矩阵 (原生 Vision 零拷贝 + Hysteria2 动态端口跳跃 + TUIC-v5 + NaïveProxy HTTP/3 QUIC)**：
   * **VLESS-Reality-Vision (TCP 原生零拷贝直通)**：对齐 `v2ray-agent` 经典架构标准规范，采用原生 TCP + `xtls-rprx-vision` 流控，深度利用 Linux 内核 `splice` 零拷贝特性，免除任何应用层多路复用（Multiplex/h2mux）封装损耗与流中断异常，配合底层 Linux BBR 实现极速、稳定、低 CPU 占用直通。
   * **VLESS-Reality-gRPC (TCP)**：多路复用备用线路。
   * **Hysteria 2 (UDP/QUIC, 原生端口跳跃 45000:50000 + Salamander 混淆)**：内置 Brutal 拥塞控制与 Salamander 双向混淆保护，有效免疫运营商对 UDP 流量的主动 QoS 限速；**开箱原生支持 45000:50000 动态端口跳跃 (Port Hopping)**，客户端定时自动变换外部端口，彻底消除单一固定端口被风控拉黑或 QoS 掐断的风险。
   * **TUIC v5 (UDP/QUIC)**：原生标准 QUIC 协议，0-RTT 极速握手，底层集成 BBR。
   * **全 UDP/QUIC 隧道矩阵破局能力**：天然免疫 GFW 精准丢弃 TCP SYN-ACK 的单向阻断策略，所有客户端 TCP/UDP 载荷均被封装进 QUIC 数据报中传输，实现全场景无感秒级穿透。
2. **端到端智能带宽对齐 (Bandwidth Symmetrical Matching)**：
   * 安装时允许自定义或默认设置 VPS 上行（默认 500 Mbps）与下行（默认 50 Mbps）带宽上限。
   * **客户端与服务端数值严格对齐**：服务端的上传对应客户端的下载，服务端的下载对应客户端的上传，自动互为倒置匹配，确保 Hysteria 2 Brutal 算法发挥最大效益。
3. **中国大陆域名路由阻断保护 (Ruleset)**：
   * 原生引入 SagerNet 官方 `geosite-cn.srs` 规则集，**全面阻断向中国大陆域名的出站请求**（放行 Googleapis 等必要 API），防止 VPS 被当成回国中继跳板，节省 VPS 宝贵带宽并降低 IP 风险。
   * 原生规则继续阻断 BitTorrent (BT/PT) 版权下载，防止机房 DMCA 投诉。
4. **纯粹原生无 DNS 依赖架构**：
   * 服务端彻底剔除繁琐且易版本不兼容的 DNS 块，直接交由底层 Linux 系统解析，完全免受 Sing-box 各版本 DNS 语法弃用影响。
5. **📦 一键完整备份与一键秒级恢复 (Backup & Restore)**：
   * 支持一键打包**所有服务端/客户端配置、TLS 证书密钥、主程序二进制以及 Systemd 服务单元**至 `/var/backups/sing-box/`。
   * 无论重装系统、机器迁移还是意外误删，随时可通过交互式菜单**一键回滚恢复**！
6. **真正的“零证书维护”体验**：
   * Reality 借用大厂公网证书，完全不需要本地域名证书。
   * Hysteria 2 与 TUIC 采用本地 OpenSSL 生成的 **10 年长效高强度 ECC 证书**，无需申请 Let's Encrypt，**永远不需要担心 90 天证书过期断连**。
7. **安全风控与端口防扫**：
   * 自动分配 **10000 ~ 60000 高位随机端口**，坚决不占用 80 和 443 敏感端口，有效规避全网主动探测。
   * 全套高熵随机凭证（随机 UUID、随机 Reality 密钥对、随机 shortId、随机 Hy2/TUIC 密码）。
8. **原生底层优化与开箱即用**：
   * 原生写入系统内核参数，**自动激活 Linux BBR 拥塞控制**。
   * 终端自动输出各协议通用分享链接（`vless://`, `hysteria2://`, `tuic://`）与手机导入二维码。
   * 自动生成电脑/手机端 Sing-box 客户端开箱即用的完整 `client_config.json` 配置文件。

---

## 📋 准备条件

1. **操作系统**：Debian 11 / 12 或 Ubuntu 20.04 / 22.04 / 24.04（支持 x86_64 / arm64）。
2. **托管在 Cloudflare 上的域名**：
   * 在 Cloudflare 添加一条 A 记录（如 `node.yourdomain.com`）解析到你的 VPS IP。
   * **重要**：请务必将代理状态保持为 **仅限 DNS（灰色云朵）**，不要开启 CDN 代理（黄色云朵）。

---

## ⚡ 一键安装与管理

在你的 VPS 终端（以 root 权限）执行以下命令即可全自动安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/luckyjamesriver/vps-sing-box/main/install.sh)
```

安装完成后，随时在终端输入快捷命令 **`vps`** 或 **`sb`** 即可唤出交互式管理菜单：

```text
====================================================
         Sing-box 极简全能安装管理脚本               
    GitHub: https://github.com/luckyjamesriver/vps-sing-box
====================================================
服务状态: 正在运行
----------------------------------------------------
1. 安装 / 重新配置 Sing-box (4合1强力协议)
2. 查看 节点连接链接 与 二维码
3. 查看并复制 客户端完整配置文件 (/etc/sing-box/client/config.json)
4. 重启 Sing-box 服务
5. 停止 Sing-box 服务
6. 查看 实时运行日志 (退出按 Ctrl+C)
7. 📦 【一键完整备份】Sing-box (配置+证书+密钥+程序)
8. 🔄 【一键恢复备份】从历史备份还原 Sing-box
9. 一键环境除旧 / 扫描清理第三方旧代理 (Clean)
10. 单独更新 Sing-box 核心版本
11. 更新 管理脚本自身 (Update Script)
12. 完全卸载 Sing-box
0. 退出菜单
----------------------------------------------------
```

### 快捷指令大全

| 指令 | 作用说明 |
| :--- | :--- |
| `vps` / `sb` | 唤出管理主菜单 |
| `vps backup` | **一键完整备份当前 Sing-box 环境**（打包至 `/var/backups/sing-box/`） |
| `vps restore` | **一键恢复历史备份**（列出所有备份档案并支持一键回滚） |
| `vps show` | 查看节点分享链接与二维码 |
| `vps client` | 查看客户端完整 `config.json` 配置文件 |
| `vps status` | 查看 Sing-box 当前运行状态 |
| `vps restart` | 重启 Sing-box 服务 |
| `vps stop` | 停止 Sing-box 服务 |
| `vps log` | 实时追踪查看节点运行日志 |
| `vps update` / `update-sing-box` | **智能检查并更新 Sing-box 核心**（先比对本地版本，有更新才下载并在更新后自动删除压缩包） |
| `vps update-config` / `vps reconfig` | **一键平滑更新节点配置**（自动保留全部已有端口、UUID、密钥与证书，将 `config.json` 平滑应用最新架构模板） |
| `vps clean` | 调用环境除旧与旧代理扫描清理工具 |

---

## 📦 备份与一键恢复指南

### 1. 创建完整备份
随时执行 `vps backup` 或在菜单中选择 `7. 📦 一键完整备份`。
脚本将自动打包：
- `/etc/sing-box/` 完整目录（所有服务端/客户端配置、证书密钥 `cert.key`/`cert.pem`）
- `/usr/local/bin/sing-box` 核心主程序
- `/etc/systemd/system/sing-box.service` 守护进程服务单元

备份文件将安全存放于 `/var/backups/sing-box/sing-box-backup-YYYYMMDD_HHMMSS.tar.gz`。

### 2. 一键秒级还原
随时执行 `vps restore` 或在菜单中选择 `8. 🔄 一键恢复备份`。
脚本会自动扫描机器上的所有历史备份档案，用户只需输入对应序号即可瞬间完成所有配置、证书、二进制与服务的完整还原与重启！

---

## 🧹 一键环境除旧与旧代理清理 (`clean.sh`)

如果你的 VPS 之前安装过其他各类一键脚本（如 `v2ray-agent` / `x-ui` / 旧版 Xray / V2Ray / Hysteria / Trojan / Shadowsocks 等），或者希望在重新部署前对环境进行全面体检与纯净化，可随时使用我们专门打造的 **独立一键除旧工具**。

### 🌟 核心设计与安全规范
1. **🛡️ 严格保护生产与建站业务 (Zero Collateral Damage)**：
   - 具备严格的白名单服务隔离机制，**绝对不触碰、不影响、不损坏**用户在 VPS 上运行的 **Tailscale**、**WireGuard**、Web 网站（**Nginx / Caddy / Apache2 / WordPress**）、数据库（**MySQL / MariaDB / PostgreSQL / Redis**）、**Docker** 及 SSH 远程管理等关键生产业务。
2. **🔍 深度探查与清理第三方旧代理**：
   - 快速扫描并清理常见旧代理守护进程、非标准二进制程序及残留配置目录。
3. **📦 清理前强制自动备份**：
   - 任何清理动作执行前均会自动创建完整备份，保障绝对安全，随时可撤销回滚。

### ⚡ 运行方式：
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/luckyjamesriver/vps-sing-box/main/clean.sh)
```

---

## 📱 客户端配置与使用指南

### 方式 1：通过分享链接导入（最简单快捷）
在终端运行 `vps` -> 选择 `2. 查看 节点连接链接 与 二维码`：
* **手机端（Shadowrocket / Sing-box / v2rayN 等）**：直接扫描屏幕上的 ASCII 二维码即可导入。
* **电脑端（v2rayN / Clash Verge / Flclash 等）**：复制链接后直接通过剪贴板添加节点。
* **直连保障**：所有分享链接与客户端配置中的连接地址（`server`）均已**自动配置为 VPS 公网 IP 直连**，彻底解决本地 DNS 污染、解析慢或解析错误导致连不上的烦恼。

### 方式 2：使用专用客户端配置文件（功能最全面）
脚本在服务端独立创建了 `client` 目录，专门存放生成好的客户端配置文件：
* **文件绝对路径**：`/etc/sing-box/client/config.json`
* **查看复制**：终端运行 `vps` -> 选择 `3. 查看并复制 客户端完整配置文件`，复制内容保存到电脑/手机即可开箱即用。
* 该客户端配置已预置：
  - 本地混合代理入站（`127.0.0.1:2080`，同时支持 HTTP 与 SOCKS5）。
  - 自动测速节点组（`auto`，智能选择延迟最低的节点）。
  - 节点选择组（`select`，可自由切换各协议）。
  - 局域网及私有 IP 直连规则。

---

## 📂 常用系统文件路径

| 功能 | 路径 |
| :--- | :--- |
| 服务端配置文件 | `/etc/sing-box/config.json` |
| 客户端专用配置文件 | `/etc/sing-box/client/config.json` |
| 节点凭据与端口存档 | `/etc/sing-box/node_info.json` |
| 10年自签证书/私钥 | `/etc/sing-box/cert.pem` / `cert.key` |
| Sing-box 核心二进制 | `/usr/local/bin/sing-box` |
| Systemd 守护服务 | `/etc/systemd/system/sing-box.service` |
| 历史备份归档目录 | `/var/backups/sing-box/` |

---

## 🛡️ 深度专题：GFW TCP 精准阻断与全 UDP/QUIC 隧道矩阵破局详解

在实际运维与节点对抗中，许多用户常会遇到一种典型而诡异的“半封锁”现象：
> **现象**：本地客户端与 VPS 之间 ping 完全正常（ICMP 畅通），UDP 测速满血无阻，但是所有基于 TCP 的节点（如 VLESS-Reality-Vision、VLESS-Reality-gRPC、Shadowsocks 2022、普通 Trojan 等）甚至连 VPS 的自定义 SSH 端口都彻底连不上，全部提示超时或握手失败！

### 1. 核心机理：GFW 骨干网精准丢弃入华 TCP SYN-ACK

经我们在骨干网链路层抓包（`tcpdump`）实测证实：
1. **客户端出境 TCP SYN 可以顺利抵达境外 VPS**（VPS 服务端能够收到三次握手的第一个 SYN 包并回复 SYN-ACK）；
2. **GFW 在国际出口骨干网对目标 IP 实施了定向 TCP 过滤**：它专门拦截并丢弃所有由该 VPS IP 发往中国大陆客户端的 `SYN-ACK` 应答包；
3. **结果**：客户端始终收不到握手应答，重试超时后连接断开。因为拦截发生在链路层且只丢弃 TCP SYN-ACK，导致 ICMP ping、纯 UDP 流量完全不受影响。

### 2. 为什么 Shadowsocks 2022 即使配置了 UDP 也无法代理网页？

许多人误以为只要将 Shadowsocks 客户端配置为 `"network": "udp"` 即可绕过 TCP 封锁，实测必定全面超时失败。原因如下：
- **Shadowsocks 是应用层 Socks5 协议代理，不是网络层虚拟隧道**；
- 浏览器访问网页（HTTPS）发出的请求本质上是 **TCP 流量**；
- 当 Shadowsocks 客户端收到浏览器的 TCP 请求时，它必须在底层向 VPS 的 Shadowsocks 端口建立一条真正的 TCP 连接来传输数据；
- 此时发出的仍然是底层的 TCP SYN，同样会被 GFW 骨干网丢弃 SYN-ACK，因此根本无法建立连接。

### 3. 破局之道：全 UDP/QUIC 隧道矩阵 (L4/L7 Tunnel over QUIC)

要彻底绕过 GFW 的 TCP 精准丢弃策略，底层通信链路必须**百分之百运行在 UDP 上**，同时具备将客户端的 TCP 流量完整打包封装进 UDP 报文内部的能力：

| 协议 | 底层传输层 | 数据封装机制 | 抗 TCP 阻断能力 | 抗 UDP QoS / 封锁手段 |
| :--- | :--- | :--- | :--- | :--- |
| **Hysteria 2** | 纯 UDP (QUIC) | 将 TCP/UDP 流量封装进 QUIC 数据报 | 🟢 **100% 满血突破** | **动态端口跳跃 (Port Hopping 45000:50000)** + Salamander 混淆 |
| **TUIC v5** | 纯 UDP (QUIC) | 原生 0-RTT QUIC 隧道封装 | 🟢 **100% 满血突破** | BBR 拥塞控制 + 自定义 ALPN |
| **NaïveProxy (QUIC 模式)** | 纯 UDP (HTTP/3) | Chromium 内核 HTTP/3 CONNECT 隧道 | 🟢 **100% 满血突破** | Chromium 原生浏览器指纹伪装（须 `"quic": true`） |
| **VLESS Reality** | 裸 TCP 直连 | 仅对 TCP 握手做伪装，底层仍是 TCP | 🔴 **遇到 TCP 丢包直接瘫痪** | 仅依赖域名与证书伪装，无抗丢包能力 |
| **Shadowsocks 2022** | 裸 TCP (Web) | 载荷加解密，底层仍是裸 TCP 握手 | 🔴 **遇到 TCP 丢包直接瘫痪** | 无抗丢包能力 |

#### A. Hysteria 2 动态端口跳跃 (Port Hopping) 实施原理
- **服务端**：利用 Linux iptables NAT 重定向，将高位端口段（如 `45000:50000`）的 UDP 数据包全数就地转发至 Hysteria 2 监听的固定端口：
  ```bash
  iptables -t nat -A PREROUTING -p udp --dport 45000:50000 -j REDIRECT --to-ports <hy2_listen_port>
  ```
- **客户端**：在 Sing-box 客户端出站配置中指定跳跃范围与周期：
  ```json
  {
    "type": "hysteria2",
    "tag": "Hysteria2-PortHopping",
    "server": "your.vps.ip",
    "server_ports": ["45000:50000"],
    "hop_interval": "30s"
  }
  ```
  客户端每 30 秒自动随机切换通信端口，由于端口不断流转，运营商的 QoS 限速探针和审查阻断规则无法在单一端口上持续收敛，彻底保证长期高速稳定。

#### B. NaïveProxy HTTP/3 QUIC 模式与客户端 libcronet.so
NaïveProxy 是业界公认伪装度极高的协议，但**默认使用 HTTP/2 (TCP) 连接**，在遇到 TCP 阻断时同样会超时。
- 必须在客户端配置中明确开启 `"quic": true` 强制使用 HTTP/3 (UDP)。
- **Linux 旁路由运行依赖**：Linux 环境下 Sing-box 运行 NaiveProxy 客户端需要官方 Chromium 网络库 `libcronet.so`：
  ```bash
  # 下载 libcronet.so 至系统共享库目录
  curl -fsSL https://github.com/SagerNet/cronet-go/releases/download/v150.0.7871.63-2/libcronet-linux-amd64.so -o /usr/local/lib/libcronet.so
  chmod 755 /usr/local/lib/libcronet.so
  ldconfig
  ```

---

## ❓ 常见问题 (FAQ)

#### Q1: 为什么 Hysteria 2 / TUIC 客户端提示证书不信任？
* 这是正常现象。因为脚本采用了自签长效 ECC 证书以彻底规避 90 天证书续期问题。
* **解决方法**：在客户端对应的节点设置中勾选 **“允许不安全证书”**（或配置中的 `"insecure": true` / `"allow_insecure": 1`）即可。数据依然全程经过高强度 TLS 1.3 / QUIC 算法加密传输，安全无虞。

#### Q2: 为什么 Reality 节点借用的是 `www.apple.com`？
* Reality 的核心技术是“偷取借用”顶级权威网站的 TLS 证书与握手特征。借用 Apple、Microsoft 等高信誉域名的 TLS 1.3 特征可以提供极佳的伪装，任何外部审查人员主动探测只会看到真正的官方网站。

#### Q3: 为什么端口都是一万多以上的高位端口？
* 默认 80 和 443 是全网爬虫和端口扫描器最密集光顾的目标。使用随机高位端口能大大降低被针对性扫描和风控的几率。

#### Q4: 服务端升级或重启后，本地客户端为什么无法立刻连通，必须等很久或手动切节点？
* **原因剖析**：
  1. 服务端重启时旧进程终止，但本地客户端连接池里的长连接（Reality TCP 零拷贝直通、gRPC 流、TUIC/Hy2 QUIC 会话）可能处于半开超时等待状态；
  2. 客户端出站组的健康探测（`urltest`）通常有轮询周期（默认 3~5 分钟），在周期到达前客户端仍误认为该节点处于中断状态。
* **最佳解决技巧**：
  - **秒连技巧**：**在服务端更新或重启完成后，立即重启本地客户端**（例如在路由器或客户端 App 中重载/重启服务）。重启会瞬间清空所有半开死连接，并强制触发开机即时测速（Initial Health Check），只要服务端启动完成即可瞬间重连。
  - **客户端配置优化**：将客户端配置中 `urltest` 测速组的 `interval` 缩短为 `1m`（或 30s），`tolerance` 设为 `50`，即可在服务端恢复后 1 分钟内自动探测自愈，无需手动干预。

#### Q5: 为什么在某些运营商网络下，Reality / SSH 连不上，而 Hysteria 2 / TUIC 却秒开？
* 这是非常典型的 **GFW 单向丢弃入华 TCP SYN-ACK** 现象（详见上方《深度专题》）。
* 在此网络环境下，纯 TCP 握手无法完成。请直接在客户端测速组中将 **Hysteria 2（端口跳跃或固定端口）** 或 **TUIC v5** 设为默认节点，或者使用双线热备中的纯 UDP 矩阵，即可无视一切 TCP 阻断满血上网。

---

## 📄 开源许可证

本项目基于 [MIT License](LICENSE) 开源，欢迎 Fork、Star 和自由修改。
