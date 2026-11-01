# Neko 架构

## 目录结构

```text
Neko/
├── install.sh              安装器（独立运行：检测环境、依赖、下载、校验、安装、卸载）
├── neko.sh                 主程序入口：加载模块、参数解析、主菜单
├── VERSION
├── lib/                    通用基础设施
│   ├── ui.sh               ASCII 边框、颜色、菜单、确认/输入（统一处理 EOF）
│   ├── logger.sh           日志与凭据脱敏
│   ├── utils.sh            sysp 路径映射、权限、sysctl 读取、锁、配置文件解析
│   └── validator.sh        IP / 域名 / URL / 端口 / sysctl 值校验
├── core/                   只读检测与备份核心
│   ├── system.sh           系统、内核、架构、CPU/内存、虚拟化、支持矩阵
│   ├── network.sh          网卡、地址、路由、卸载能力、拥塞控制、Qdisc、内核模块
│   ├── services.sh         systemd 单元、ExecStart、进程、监听端口
│   ├── dns_detect.sh       DNS 管理方式识别（resolved / resolvconf / NM / dhclient / 静态）
│   └── backup.sh           事务式备份、历史记录、按状态回滚
├── engine/
│   ├── apply.sh            sysctl 事务应用、冲突检测、自动回滚守护（guard）
│   ├── analyzer.sh         只读收集事实（FACT）
│   ├── recommender.sh      基于事实的建议规则
│   └── rollback.sh         备份与回滚菜单
├── modules/                各功能菜单
│   ├── tcp.sh  udp.sh  quic.sh  dns.sh  cdn.sh
│   ├── proxy.sh            sing-box / Xray 检测（只读）
│   ├── network_test.sh     网络性能测试
│   └── export.sh           节点解析、链接 / 订阅 / Sing-box / Mihomo 生成
├── data/
│   ├── dns-providers.tsv   内置 DNS 服务商
│   └── profiles/           sysctl 预设（bbr-fq.conf、quic-udp.conf）
├── tools/build-release.sh  构建发行包与 SHA256
├── tests/                  Mock 测试（不随发行包分发）
└── docs/
```

## 运行时目录

| 路径 | 内容 | 权限 |
|---|---|---|
| `/opt/neko/` | 程序文件（升级时整体替换） | 755 / 644 |
| `/usr/local/bin/neko` | 启动脚本（`exec bash /opt/neko/neko.sh`） | 755 |
| `/etc/neko/neko.conf` | 用户配置，升级时保留；`neko.conf.default` 为默认值参考 | 644 |
| `/var/lib/neko/` | `history.tsv`、`backups/`、`guard/`、`reports/`、`install.info` | 700 |
| `/var/log/neko/neko.log` | 日志（已脱敏） | 750 |

普通用户运行时，日志写入 `~/.local/state/neko/`，报告写入 `~/neko-reports/`。

## 设计要点

### 1. 可测试的系统访问

所有系统文件都通过 `sysp /path` 访问。生产环境中 `NEKO_SYSROOT` 为空；测试时它指向一个伪造的根目录。会产生副作用的命令（`sysctl`、`systemctl`、`modprobe`、`tc`、`nmcli`、`resolvconf`）都通过 PATH 调用，测试时由 mock 替换。

### 2. 托管文件，而不是追加修改

- sysctl：`/etc/sysctl.d/99-zz-neko.conf` 由一张键值表整体重新生成，重复执行不会产生重复项。文件名排在 Debian 的 `99-sysctl.conf`（指向 `/etc/sysctl.conf`）之后，因此开机时 Neko 的值生效；如果还有更晚加载的文件覆盖了这些键，Neko 会提示。
- DNS：systemd-resolved 使用 drop-in `/etc/systemd/resolved.conf.d/99-neko-dns.conf`；dhclient 和 resolvconf 使用带 `BEGIN/END NEKO DNS` 标记的配置块，重写时先删除旧块再写入新块。

### 3. 事务式备份（core/backup.sh）

每次修改都是一个事务，编号形如 `00003-20261101-120000`：

```text
backup_begin → backup_add_file / backup_record_sysctl / backup_add_restore / backup_add_hook
            → 修改系统 → backup_commit（记录修改后的内容和 diff）
```

回滚是**基于状态**的：恢复到「事务 X 之前」时，对 X 及其之后的事务涉及的每个文件、每个 sysctl 键和每个资源（如 nmcli 连接），取 X 之后最早记录的「修改前」状态写回。因此「撤销最近一次」「恢复到指定版本」「完整回滚」都使用同一个算法。回滚本身也会记录为事务，所以回滚也能撤销。

回滚前会做漂移检测：如果文件在 Neko 写入之后又被其他程序或人工修改过，会列出这些文件并要求确认。DNS 恢复使用 `dns` 范围，只回滚 DNS 事务，不影响之后的 TCP/UDP 修改。

### 4. 高风险修改的自动恢复（guard）

DNS 修改流程：

1. 备份并写入
2. 立即验证解析（`getent ahosts`），失败则自动回滚
3. 启动守护：优先使用 `systemd-run --on-active=120s neko --guard-rollback <id>`，没有 systemd 时退回到 `setsid nohup`
4. 询问是否保留：选「是」则撤销守护；选「否」或超时则回滚。即使 SSH 断开，守护也会在超时后回滚

### 5. 节点导出流水线（modules/export.sh）

```text
proxy_scan（进程参数 > 服务 ExecStart > 默认路径）
  → json_load（兼容 // 和 /* */ 注释）
  → jq 解析为统一节点结构（sing-box / Xray 各一套规则）
  → 校验，标记无法导出的节点及原因
  → REALITY：用 openssl 在本地由 X25519 私钥推导公钥（备用方案：xray x25519 -i），随后删除私钥字段
  → TLS 证书：自签名证书设置 insecure；没有 SNI 时从证书 SAN/CN 取
  → 生成：分享链接 / Base64 订阅 / Sing-box 1.12+ 配置 / Mihomo 配置 / 二维码
```

凭据只通过 stdin 和 here-string 传递，从不出现在命令行参数中（命令行参数对其他用户可见）。导出文件的权限为 600，目录为 700。

### 6. 权限模型

- 只读检测：任何用户都能运行
- 修改：每个修改入口都会调用 `require_root`，之后由 `sys_allow_modify` 检查支持矩阵：受支持的系统直接继续，未经测试的系统需要额外确认，不受支持的系统禁止修改
- 并发：修改期间持有 `flock`（`$NEKO_STATE_DIR/.lock`）

### 7. 错误与 EOF 处理

交互输入都经过 `ui_read_choice`、`ui_confirm`、`ui_prompt`。stdin 关闭时，它们返回「退出 / 否」，菜单逐层退出，不会陷入死循环。
