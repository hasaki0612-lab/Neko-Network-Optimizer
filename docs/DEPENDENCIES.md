# 依赖清单

## 必要依赖

安装器会检查以下依赖，缺失时列出并询问是否安装。

| 命令 | Debian/Ubuntu 包 | RHEL 系 | Alpine | 用途 |
|---|---|---|---|---|
| bash ≥ 4.4（推荐 5.x） | bash | bash | bash | 主程序 |
| curl 或 wget | curl | curl | curl | HTTPS 下载 |
| jq | jq | jq | jq | 解析代理 JSON 配置、生成导出文件 |
| ip / ss / tc | iproute2 | iproute / iproute-tc | iproute2 | 网卡地址、监听端口、Qdisc |
| ps / sysctl | procps | procps-ng | procps | 进程与内核参数 |
| sha256sum、mktemp、stat、od、base64 | coreutils | coreutils | coreutils | 校验与基础操作 |
| grep / sed / awk | grep / sed / gawk（mawk 也可） | 同左 | 同左 | 文本处理 |
| tar / gzip | tar / gzip | tar / gzip | tar / gzip | 解压发行包 |
| flock | util-linux | util-linux | util-linux | 防止并发修改的锁 |
| diff | diffutils | diffutils | diffutils | 记录变更差异 |
| CA 证书 | ca-certificates | ca-certificates | ca-certificates | HTTPS 证书验证 |

Debian/Ubuntu 的最小安装通常已经自带 coreutils、grep、sed、mawk、tar、gzip、diffutils、util-linux 和 procps。云镜像中最常缺少的是 jq。

## 可选依赖

缺少可选依赖时只会禁用对应功能，并提示安装方法，Neko 其余部分照常运行。

| 命令 | 包（Debian/Ubuntu） | 缺少时受影响的功能 |
|---|---|---|
| qrencode | qrencode | 节点 / 订阅二维码 |
| openssl | openssl | REALITY 公钥推导（没有时尝试 `xray x25519 -i`，也不可用就跳过该节点）、TLS 证书自签名检测与 SNI 推导 |
| ethtool | ethtool | GSO / GRO / UDP GSO 检测 |
| tracepath | iputils-tracepath | PMTU 检测（没有时退回到 ping 二分法） |
| ping | iputils-ping | RTT / 丢包测试 |
| mtr / traceroute | mtr-tiny / traceroute | 路由分析（任选其一，tracepath 也可） |
| iperf3 | iperf3 | 吞吐量测试 |
| dig | dnsutils（bind9-dnsutils） | DNS 延迟测试（没有时使用内置的 bash /dev/udp 查询） |
| curl | curl | DoH 测试、CDN 在线检测 |
| DoH 转发器 | dnscrypt-proxy / dnsproxy / AdGuardHome / cloudflared | 本地 DoH：Neko 只负责检测和对接，不负责安装 |
| ShellCheck | shellcheck | 仅开发时使用 |

关于 cloudflared：新版 cloudflared 已弃用 `proxy-dns` 功能，用它做 DoH 转发前，请先查阅所装版本的文档。

## 不会安装的软件

- 代理服务端（sing-box、Xray 等）
- 第三方内核（例如 BBRplus、XanMod 等）
- 任何系统升级（`apt upgrade` / `dist-upgrade`）
