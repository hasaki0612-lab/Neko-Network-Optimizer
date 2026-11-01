# 已知限制与兼容性

## 系统支持

| 系统 | 状态 |
|---|---|
| Debian 12 / 13，Ubuntu 22.04 / 24.04（x86_64、ARM64） | 首批目标平台。修改类功能直接可用 |
| 其他 Debian / Ubuntu 版本 | 「未经测试」：修改前需要额外确认 |
| 其他 Linux（RHEL 系、Alpine 等） | 只读检测可用，修改类功能被禁止；安装器对 dnf/yum/apk 的支持是实验性的 |

**v0.1.0 尚未在真实的 Debian/Ubuntu VPS 上运行过。** 目前的测试全部是在 Windows（Git Bash）下用模拟的 `/proc`、`/sys`、`/etc` 和模拟命令完成的，详见 [TEST-REPORT.md](TEST-REPORT.md)。正式发布前，请先在 Debian 12/13 和 Ubuntu 22.04/24.04 的 KVM 与 LXC 实例上做一轮实机验证。

## 虚拟化

- **KVM / Xen / VMware / Hyper-V**：所有功能都可用
- **LXC / Docker**：`net.core.default_qdisc`、`net.core.rmem_max` 等全局参数在容器内通常只读，Neko 会跳过它们并说明原因。拥塞控制只能使用宿主机已加载的算法，容器内不会尝试 `modprobe`
- **OpenVZ**：通常无法使用 BBR，能否修改 sysctl 取决于宿主机

## TCP / UDP

- `default_qdisc` 只影响之后新建的队列。只有当网卡是单队列根 Qdisc 时，Neko 才会提供「立即替换」（`tc qdisc replace`，可回滚）；对于 `mq` 多队列网卡，需要重启或重新初始化网卡后才会生效
- 加载 `tcp_bbr` 模块后，回滚时不会卸载模块（卸载可能影响正在使用 BBR 的连接）。回滚只恢复 sysctl 值和 modules-load 文件
- 持久化的 `nf_conntrack_max` 依赖开机时 nf_conntrack 模块已经加载
- Neko 不修改网卡、路由或 MTU 本身，只调整 `tcp_mtu_probing`

## DNS

- 支持自动修改的管理方式：systemd-resolved、resolvconf（Debian 版 / openresolv）、NetworkManager（nmcli）、dhclient、无管理程序的静态文件
- dhcpcd、netconfig，以及无法识别的符号链接目标：只检测并给出手动操作指引，不自动修改
- systemd-resolved 模式下写入的是全局 DNS，链路上由 DHCP 下发的 DNS 仍然会一起参与解析。Neko 不修改 netplan 和 networkd 的配置
- 设置了 `chattr +i` 的 resolv.conf 会被识别出来，Neko 拒绝修改，也不会自动去掉 immutable 属性
- DoT 依赖 systemd-resolved；DoH 需要用户自行安装本地转发器
- glibc 最多只使用 3 个 nameserver，所以静态文件模式下最多写入 3 个
- DNS 修改通过 `getent ahosts` 验证；自动回滚守护优先使用 `systemd-run` 定时器，没有时使用 `setsid nohup` 后台进程

## 代理检测与导出

- 只解析 JSON 格式的配置（允许 `//` 和 `/* */` 注释），YAML/TOML 格式的 Xray 配置会报告为「格式不受支持」
- 独立运行的 hysteria、tuic-server、mihomo 等程序只检测进程，不解析配置
- 以下节点会被**跳过**（显示原因，不会猜测参数）：
  - 只监听回环地址的入站（通常由 Nginx/Caddy 反向代理转发，实际的公网端口和 TLS 参数无法从代理配置中确定）
  - 端口范围或非数字端口
  - VLESS Encryption（`decryption` 不是 `none`）
  - TCP HTTP 伪装、mKCP、旧版 QUIC 传输
  - 未启用 TLS 的 Trojan / Hysteria 2 / TUIC / AnyTLS
  - 无法推导 REALITY 公钥（同时缺少 openssl 1.1+ 和 xray）
- 用 `xray x25519 -i` 推导公钥时，私钥会短暂出现在进程参数中；优先使用的 openssl 方案通过 stdin 传入私钥，没有这个问题
- XHTTP 节点只导出分享链接，生成的 Sing-box 和 Mihomo 配置中会省略这些节点
- 生成的 Sing-box 配置面向 **sing-box 1.12 及以上**（新版 DNS server 格式、rule action），旧版本客户端需要自行调整
- 客户端指纹固定为 `chrome`；节点地址默认取本机网卡上的公网 IP（不访问外部服务），位于 NAT 之后的机器需要手动填写
- 「订阅二维码」需要你自己提供 HTTPS 地址。Neko 只生成本地文件，不托管订阅，也不开放端口
- 生成的链接和配置格式依据各项目公开的格式规范实现，**尚未用真实的 sing-box、Mihomo 或 v2rayN 客户端验证导入**

## CDN / 反向代理

- 只读：只给出检测结果和建议，不修改 Nginx、Caddy、HAProxy 或 Apache 的配置
- Nginx 的分析基于 `nginx -T` 输出的文本匹配，`include` 展开后的复杂配置可能出现误判

## 其他

- 界面只有中文
- 「清理旧备份」暂未提供（删除备份会导致无法回滚到更早的状态）；需要清理时，可以在完整回滚之后手动删除 `/var/lib/neko/backups`
- 回滚事务只记录文件和 sysctl 的状态；通过 nmcli 修改的 DNS，撤销之后不能再「重做」
