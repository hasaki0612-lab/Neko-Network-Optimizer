# Neko — VPS Network Optimizer

Neko 是一个面向 Linux VPS 的轻量级交互式 Shell 工具，用于网络诊断、网络优化和代理配置导出。

**先检测，再分析；先备份，再修改；所有优化必须有依据。**

- 检测系统、硬件、虚拟化、网卡、TCP/UDP 协议栈、DNS 和代理服务
- 依据实测数据给出优化建议，每条建议写明当前值、推荐值、理由、风险和回滚方式
- 管理 BBR / FQ / TCP 缓冲区 / TFO / ECN / MTU Probing / Keepalive / UDP 缓冲区
- 自动识别 DNS 由谁管理（systemd-resolved、resolvconf、NetworkManager、dhclient 或静态文件），按对应方式修改；支持 DoT，修改失败会自动回滚
- 只读检测 sing-box / Xray，导出分享链接、聚合订阅、Sing-box 与 Mihomo 客户端配置、二维码
- 所有修改先进入统一的事务式备份，可查看差异，可按版本恢复，也可以完整回滚

Neko **不会**部署、安装、启动、停止、重启或修改代理服务端。

## 安装

> 仓库地址目前仍是占位符 `<OWNER>/<REPO>`。正式发布前请替换为真实仓库地址（安装器也支持 `--repo OWNER/REPO`）。

```bash
bash <(wget -qO- https://raw.githubusercontent.com/<OWNER>/<REPO>/main/install.sh)
```

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPO>/main/install.sh)
```

非 root 用户：

```bash
wget -qO- https://raw.githubusercontent.com/<OWNER>/<REPO>/main/install.sh | sudo bash
```

安装器会检测系统、架构、Bash 版本和依赖。缺少依赖时，它会列出缺失项和用途，经你确认后再安装；随后从 GitHub Release 下载发行包，**SHA256 校验通过后**才安装。安装、升级、卸载和发布流程见 [docs/INSTALL.md](docs/INSTALL.md)。

## 使用

```bash
neko          # 只读检测（普通用户即可）
sudo neko     # 修改系统配置需要 root
neko --report # 非交互输出系统检测报告
```

```text
╔══════════════════════════════════════════════╗
║                   N E K O                    ║
║         VPS NETWORK OPTIMIZER v0.1.0         ║
╚══════════════════════════════════════════════╝

系统：Debian GNU/Linux 13 (trixie)
内核：6.12.48+deb13-amd64
架构：amd64
虚拟化：KVM

网络状态：
TCP算法：cubic
Qdisc：fq_codel
DNS：1.1.1.1
DoT：未启用
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  1. 系统环境检测
  2. TCP 网络优化
  3. UDP / QUIC 优化
  4. DNS 管理
  5. CDN / 反向代理优化
  6. 代理服务检测
  7. 网络性能测试
  8. 智能优化建议
  9. 配置备份与回滚
 10. 节点与订阅导出
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  0. 退出脚本
```

菜单中显示的系统信息都在运行时读取（上例来自测试环境）。

## 功能模块

| 菜单 | 内容 | 是否修改系统 |
|---|---|---|
| 1 系统环境检测 | OS、内核、架构、CPU/内存、虚拟化、网卡/MTU/驱动、GSO/GRO、IPv4/IPv6、拥塞控制、Qdisc、DNS、网络服务、代理核心；可保存报告 | 否 |
| 2 TCP 网络优化 | BBR+FQ、拥塞控制切换、默认 Qdisc、按 BDP 计算缓冲区、TFO、ECN、MTU Probing、Keepalive | 是（需确认） |
| 3 UDP / QUIC 优化 | UDP 计数器与按端口丢包、缓冲区优化、Conntrack、Hysteria 2 / TUIC 专项分析、BBR / QUIC CC / Brutal 机制说明 | 是（需确认） |
| 4 DNS 管理 | Cloudflare / Google / Quad9 / 自定义、IPv4/IPv6、DoT、DoH 检测、延迟测试、恢复 | 是（带自动回滚） |
| 5 CDN / 反向代理 | Nginx / Caddy / HAProxy / Apache 配置检查，可选的域名在线检测（HTTP/2、HTTP/3、TLS 1.3、CDN、压缩） | 否 |
| 6 代理服务检测 | sing-box / Xray 的安装、运行、配置状态，监听端口，内核自带校验器 | 否 |
| 7 网络性能测试 | 连通性、DNS 延迟、TCP 连接、UDP、RTT/丢包、PMTU、路由、重传、网卡流量、iperf3（需确认流量） | 否 |
| 8 智能优化建议 | 汇总上述检测结果，生成有依据的建议，可逐条应用 | 按条确认 |
| 9 配置备份与回滚 | 变更历史、差异、撤销最近一次、恢复到指定版本、完整回滚、手动快照 | 恢复时确认 |
| 10 节点与订阅导出 | 分享链接、Base64 订阅、Sing-box 配置、Mihomo 配置、二维码、批量导出 | 只写导出目录 |

支持导出的协议：VLESS（REALITY / TLS / WS / gRPC / HTTPUpgrade / XHTTP）、VMess、Trojan、Shadowsocks（含 2022 多用户）、Hysteria 2、TUIC、AnyTLS。
不能从服务端配置可靠推导的节点会被跳过，并显示原因，例如只监听 127.0.0.1、端口范围、VLESS Encryption、未启用 TLS。Neko 不会猜测节点参数。

## 安全承诺

- 不覆盖未备份的系统配置，不执行 `apt upgrade` / `dist-upgrade`，不修改软件源，不安装内核
- 不关闭防火墙或 SELinux，不修改 SSH，不重启网络服务（DNS 只重启 systemd-resolved，且事先说明）
- 不直接覆盖由其他程序管理的 `/etc/resolv.conf`；DNS 修改会先验证，失败自动回滚，确认超时（默认 120 秒）也会自动回滚
- 日志会对 UUID、密码、密钥和分享链接做脱敏；REALITY 只导出公钥（在本地由私钥推导），私钥不写入任何导出文件
- 默认不开放任何端口，不使用第三方订阅转换服务
- 只读检测可用普通用户运行，修改操作才需要 root

## 文档

- [docs/INSTALL.md](docs/INSTALL.md)：安装、升级、卸载与发布
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)：架构与模块职责
- [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)：依赖清单
- [docs/LIMITATIONS.md](docs/LIMITATIONS.md)：已知限制与兼容性
- [docs/TEST-REPORT.md](docs/TEST-REPORT.md)：测试报告

## 开发

```bash
bash tests/run.sh             # 全部测试（使用模拟的 /proc、/sys、/etc 和系统命令）
bash tests/run.sh proxy_export  # 单个测试集：core proxy_export apply dns install recommend
shellcheck -x neko.sh install.sh lib/*.sh core/*.sh engine/*.sh modules/*.sh
bash tools/build-release.sh   # 生成 dist/neko-vX.Y.Z.tar.gz 与 .sha256
```

测试不会读取或修改运行测试的机器上的真实网络配置。

## 许可证

本项目经由**MIT许可证**开源
