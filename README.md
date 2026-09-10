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

1. **顶级协议 4 合 1 黄金矩阵 (集成 TCP Brutal & Salamander 混淆)**：
   * **VLESS-Reality (TCP Brutal 暴击加速)**：基于 [chika0801/sing-box-examples](https://github.com/chika0801/sing-box-examples/tree/main/TCP_Brutal) 规范，在 Reality 基础上挂载 Linux 内核级 **TCP Brutal** 多路复用拥塞控制算法，即使在最恶劣丢包线路下也能强制拉满带宽！
   * **VLESS-Reality-gRPC (TCP)**：多路复用备用线路。
   * **Hysteria 2 (UDP/QUIC, 含 Salamander 混淆)**：内置 Brutal 拥塞控制与 Salamander 双向混淆保护，有效免疫运营商对 UDP 流量的主动 QoS 限速。
   * **TUIC v5 (UDP/QUIC)**：原生标准 QUIC 协议，0-RTT 极速握手，底层集成 BBR。
2. **端到端智能带宽对齐 (Bandwidth Symmetrical Matching)**：
   * 安装时允许自定义或默认设置 VPS 上行（`up_mbps`）与下行（`down_mbps`）带宽上限。
   * **客户端与服务端数值严格对齐**：服务端的上传对应客户端的下载，服务端的下载对应客户端的上传，自动互为倒置匹配，确保 Brutal 算法发挥最大效益。
3. **中国大陆域名路由阻断保护 (Ruleset)**：
   * 原生引入 SagerNet 官方 `geosite-cn.srs` 规则集，**全面阻断向中国大陆域名的出站请求**（放行 Googleapis 等必要 API），防止 VPS 被当成回国中继跳板，节省 VPS 宝贵带宽并降低 IP 风险。
   * 原生规则继续阻断 BitTorrent (BT/PT) 版权下载，防止机房 DMCA 投诉。
4. **纯粹原生无 DNS 依赖架构**：
   * 服务端彻底剔除繁琐且易版本不兼容的 DNS 块，直接交由底层 Linux 系统解析，完全免受 Sing-box 各版本 DNS 语法弃用影响。
5. **智能无缝平滑升级（保留旧配置 / UUID / 端口 / 密钥）**：
   * 重新运行安装脚本或升级核心时，脚本**自动识别已有节点配置**，提示用户一键保留原域名、UUID、端口和密钥。
   * **手机与电脑客户端无需重新扫码或更改配置**，服务重启即可完成无缝升级！
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
bash <(curl -fsSL https://raw.githubusercontent.com/luckyjamesriver/VPS-Sing-box/main/install.sh)
```

安装完成后，随时在终端输入快捷命令 **`sb`** 即可唤出交互式管理菜单：

```text
====================================================
         Sing-box 极简全能安装管理脚本               
    GitHub: https://github.com/luckyjamesriver/VPS-Sing-box
====================================================
服务状态: 正在运行
----------------------------------------------------
1. 安装 / 重新配置 Sing-box (4合1强力协议)
2. 查看 节点连接链接 与 二维码
3. 开启 浏览器临时一键下载 客户端配置 (🌟 推荐)
4. 查看并复制 客户端完整配置文件 (client_config.json)
5. 重启 Sing-box 服务
6. 停止 Sing-box 服务
7. 查看 实时运行日志 (退出按 Ctrl+C)
8. 单独更新 Sing-box 核心版本
9. 完全卸载 Sing-box
0. 退出菜单
----------------------------------------------------
```

---

## 📱 客户端配置与使用指南

### 方式 1：通过分享链接导入（最简单）
在终端运行 `sb` -> 选择 `2. 查看 节点连接链接 与 二维码`：
* **手机端（Shadowrocket / Sing-box / v2rayN 等）**：直接扫描屏幕上的 ASCII 二维码即可导入。
* **电脑端（v2rayN / Clash Verge / Flclash 等）**：复制链接后直接通过剪贴板添加节点。

### 方式 2：浏览器临时一键下载 `config.json`（🌟 强烈推荐，体验最佳）
脚本内置了极简零依赖的临时 Web 下载服务：
1. 在终端运行 `sb` -> 选择 `3. 开启 浏览器临时一键下载 客户端配置`（或直接执行 `sb download`）。
2. 脚本会给出一个临时链接，例如：`http://你的VPS公网IP:52189/config.json`。
3. 在电脑或手机浏览器打开该链接，即可**一键将完整的配置文件保存到本地下载文件夹**，无需繁琐的复制粘贴！
4. 下载完成后回车，临时下载服务立即关闭并自动销毁端口，安全无痕。

### 方式 3：终端查看或通过 SFTP 拖取
* **终端复制**：运行 `sb` -> 选择 `4. 查看并复制 客户端完整配置文件`，全选终端文本保存为本地文件。
* **SFTP 拖取**：使用 FinalShell / Termius 等工具，直接下载 `/etc/sing-box/client_config.json`。
3. 该配置已内置：
   * 本地混合代理入站（`127.0.0.1:2080`，同时支持 HTTP 与 SOCKS5）。
   * 自动测速节点组（`auto`，智能选择延迟最低的节点）。
   * 节点选择组（`select`，可自由切换 Reality-Vision、Reality-gRPC、Hysteria2、TUIC）。
   * 私有内网地址直连，保障安全与体验。

---

## 📂 常用系统文件路径

| 功能 | 路径 |
| :--- | :--- |
| 服务端配置文件 | `/etc/sing-box/config.json` |
| 客户端配置文件 | `/etc/sing-box/client_config.json` |
| 节点凭据与端口存档 | `/etc/sing-box/node_info.json` |
| 10年自签证书/私钥 | `/etc/sing-box/cert.pem` / `cert.key` |
| Sing-box 核心二进制 | `/usr/local/bin/sing-box` |
| Systemd 守护服务 | `/etc/systemd/system/sing-box.service` |

---

## ❓ 常见问题 (FAQ)

#### Q1: 为什么 Hysteria 2 / TUIC 客户端提示证书不信任？
* 这是正常现象。因为脚本采用了自签长效 ECC 证书以彻底规避 90 天证书续期问题。
* **解决方法**：在客户端对应的节点设置中勾选 **“允许不安全证书”**（或配置中的 `"insecure": true` / `"allow_insecure": 1`）即可。数据依然全程经过高强度 TLS 1.3 / QUIC 算法加密传输，安全无虞。

#### Q2: 为什么 Reality 节点借用的是 `www.apple.com`？
* Reality 的核心技术是“偷取借用”顶级权威网站的 TLS 证书与握手特征。借用 Apple、Microsoft 等高信誉域名的 TLS 1.3 特征可以提供极佳的伪装，任何外部审查人员主动探测只会看到真正的官方网站。

#### Q3: 为什么端口都是一万多以上的高位端口？
* 默认 80 和 443 是全网爬虫和端口扫描器最密集光顾的目标。使用随机高位端口能大大降低被针对性扫描和风控的几率。

---

## 📄 开源许可证

本项目基于 [MIT License](LICENSE) 开源，欢迎 Fork、Star 和自由修改。
