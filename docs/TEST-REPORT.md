# Neko v0.1.0 测试报告

日期：2026-11-01
结论：**自动化测试 331 项全部通过；尚未在真实 Linux VPS 上运行。**

## 1. 测试环境

| 项目 | 版本 |
|---|---|
| 主机 | Windows 11（10.0.22631） |
| Shell | Git for Windows Bash 5.3.15（MSYS2 运行时） |
| jq | 1.8.2（Windows 原生版） |
| ShellCheck | 0.11.0 |
| OpenSSL | 3.5.7 |

开发机上没有可用的 Linux 虚拟机或 WSL 发行版，所以全部测试都通过 **Mock 和隔离环境**完成：

- `NEKO_SYSROOT` 指向一个临时的伪造根目录，其中包含按 Debian 13 / KVM 构造的 `/proc`、`/sys`、`/etc`、`/run`、`/lib/modules`
- `systemctl`、`sysctl`、`ps`、`ss`、`ip`、`uname`、`systemd-detect-virt`、`getent`、`modprobe`、`tc`、`nmcli`、`resolvconf`、`qrencode`、`ethtool` 都由 mock 脚本代替，副作用写入伪造根目录，调用记录写入日志供断言检查
- sing-box 和 Xray 由伪造根目录中的模拟二进制、systemd 单元和真实格式的配置文件代替
- 每个测试用例都会重建环境，临时文件写在项目内的 `.test-tmp/`，测试结束后清理
- 为了模拟 Linux 的行为，测试中给 Windows 版 jq 和 openssl 套了一层把 CRLF 转成 LF 的 shim（只存在于测试中）

测试**没有**读取或修改本机的真实网络配置。

运行方式：

```bash
bash tests/run.sh                      # 全部
bash tests/run.sh core proxy_export    # 指定测试集
```

各测试集的原始输出保存在 `test-logs/run-<suite>.log`。

## 2. 结果汇总

| 测试集 | 检查项 | 结果 | 覆盖内容 |
|---|---|---|---|
| core | 84 | 全部通过 | 系统、虚拟化（KVM/LXC/OpenVZ）、架构映射、支持矩阵、网卡/IPv6/BBR 状态、DNS 管理方式识别、输入校验、日志脱敏、主菜单 UI、EOF 处理、报告保存 |
| proxy_export | 87 | 全部通过 | 代理状态六种情况，sing-box 与 Xray 共 16 个入站的解析，七种协议的分享链接，REALITY 公钥推导，证书推导，Sing-box/Mihomo 配置，订阅，二维码，导出菜单 |
| apply | 51 | 全部通过 | BBR+FQ、幂等性、缓冲区合并、撤销/指定版本/完整回滚/撤销回滚、快照与符号链接恢复、漂移检测、应用失败自动回滚、权限、旧内核、容器、sysctl 冲突 |
| dns | 39 | 全部通过 | 静态文件、systemd-resolved + DoT、dhclient、resolvconf、NetworkManager、未知管理方式、验证失败回滚、超时回滚、拒绝保留回滚、恢复、非法输入、非 root |
| install | 50 | 全部通过 | 发布包构建、SHA256 校验与固定值、安装、相同版本重装、升级保留数据、安装锁、卸载与 --purge、篡改/越界/不完整安装包、仓库占位符、系统兼容性 |
| recommend | 20 | 全部通过 | 各条规则的触发与不触发、从建议列表应用、已优化系统不虚构问题 |
| **合计** | **331** | **0 失败** | |

静态检查：

- `shellcheck -x -S warning`（所有脚本，包括测试）：**0 条警告**。剩余 20 条为 info/style 级别（主要是 SC2015 `A && B || C` 写法，均已检查，确认是预期行为）
- `bash -n`：所有脚本语法正确
- 换行符：所有文件均为 LF（发布脚本在打包前会再检查一次 CRLF）

## 3. 按需求清单核对

| 需求中的测试项 | 状态 | 说明 |
|---|---|---|
| Debian 12 / 13 | 模拟 | 用 Debian 13 的 os-release 和内核版本模拟；支持矩阵对 Debian 12 的判断与 13 走同一分支 |
| Ubuntu 22.04 / 24.04 | 模拟 | 测试了 22.04 的识别；24.04 走同一分支 |
| x86_64 / ARM64 | 模拟 | `uname -m` 返回 x86_64 / aarch64 时的映射已测试 |
| KVM / LXC | 模拟 | 包括 LXC 容器内拒绝 modprobe；OpenVZ 的识别也已测试 |
| Root / 普通用户 | 已测 | 普通用户无法修改 TCP/DNS，无法查看备份，只读查看可用 |
| 缺失依赖 | 部分 | 安装器在测试模式下检测并列出缺失依赖（Windows 上本来就缺少 ip/ss/sysctl 等）；**实际执行 apt-get 安装未测试** |
| 没有代理服务端 | 已测 | 输出与需求文档中的错误文本一致；不会被误报为「已停止」 |
| 代理服务停止 | 已测 | 「代理服务已安装，但当前未运行」 |
| 配置文件缺失 / 不可读 / 解析失败 | 已测 | 「不可读」通过 Windows ACL 拒绝读取来模拟（读取检测会实际读一个字节） |
| DNS 修改及恢复 | 模拟 | 五种管理方式下的写入、验证、回滚、恢复都已测试；**真实的 systemd-resolved / nmcli 未测试** |
| BBR / Qdisc 切换 | 模拟 | 通过 mock sysctl 写入伪造的 /proc/sys；**真实内核生效未测试** |
| 节点导出兼容性 | 部分 | 输出格式和字段已与预期逐一核对，REALITY 公钥用 RFC 7748 测试向量验证；**未用真实的 sing-box / Mihomo / v2rayN 客户端验证导入** |
| 安装中断与升级 | 部分 | 升级时保留数据、失败时旧版本不受影响、安装锁、临时目录清理都已测试；**没有模拟进程在中途被杀死的情况** |
| 配置回滚 | 已测 | 状态式回滚的四种用法、漂移检测、符号链接恢复、失败自动回滚 |
| ShellCheck | 已测 | 0 警告 |

## 4. 测试中发现并已修复的问题

| 问题 | 影响 | 修复 |
|---|---|---|
| 备份清单是 TSV 格式，`IFS=$'\t' read` 会合并连续的制表符，导致空字段错位 | **严重**：漂移检测失效；恢复被替换的符号链接时会写入错误的目标 | 空字段写成 `-`；新增「快照与符号链接恢复」测试 |
| `tmp=$(export_tmp)` 在子 shell 中创建临时目录 | 每次导出都会留下一个空临时目录（其中的文件已删除，没有凭据泄露） | 改为在当前 shell 中调用 |
| 导出菜单中选择节点时覆盖了 `REPLY_CHOICE` | 「导出单个节点分享链接」会误入二维码分支 | 先保存菜单选项再处理 |
| resolv.conf 被 Neko 写过之后，再次检测会把 dhclient 环境误判为静态文件 | 第二次修改 DNS 时不会更新 dhclient supersede 规则，续租后被覆盖 | 只要 dhclient 在运行，就仍按 dhclient 处理 |
| 自定义 DNS 输入使用了未加引号的单词拆分 | 输入 `*` 会被当作通配符展开 | 改用 `read -ra` |
| 只用 `[[ -r ]]` 判断配置文件是否可读 | ACL 或 MAC 策略拒绝读取时，会被误报为「解析失败」 | 实际读取一个字节来确认 |
| 证书路径通过 jq 的 `--arg` 传入 | Windows 测试中路径被 MSYS 改写（Linux 上不受影响） | 改为通过 stdin 传入，参数中不出现路径 |

## 5. 未测试或无法在当前环境测试的部分

以下内容**没有**经过验证，请在发布前在真实 VPS 上确认：

1. 在 Debian 12/13、Ubuntu 22.04/24.04 上实际运行（KVM 与 LXC 各一台，x86_64 与 ARM64）
2. 真实的 `sysctl -w`、`modprobe tcp_bbr`、`tc qdisc replace` 是否生效；开机后 `99-zz-neko.conf` 是否生效
3. 真实的 systemd-resolved 重启、DoT（853 端口）、nmcli reapply、resolvconf -u
4. 自动回滚守护通过 `systemd-run` 定时器的路径（测试中用的是后台进程方式，而且在超时前就撤销了）
5. `flock` 并发锁（Windows 上没有 flock，测试时自动跳过）
6. 容器中 `/proc/sys` 只读的情况（Windows 无法模拟只读文件，相关代码使用 `[[ -w ]]` 判断）
7. **CDN / 反向代理模块（菜单 5）、网络性能测试模块（菜单 7）、QUIC 专项分析没有自动化测试**；这几部分依赖真实的 nginx/caddy、网络和 ping/tracepath/iperf3。DNS 查询报文的构造已测试，但没有实际发出网络请求
8. 安装器的联网路径：GitHub API、Release 下载、`apt-get install`（仓库地址仍是占位符）
9. 生成的配置在真实客户端中的导入与连接：sing-box 1.12+、Mihomo、v2rayN 等
10. 中文界面在不同终端和 SSH 客户端中的显示效果

## 6. 建议的实机验收步骤

```bash
# 在一台可以随时重装的测试 VPS 上执行
bash tools/build-release.sh   # 在开发机上构建
scp dist/neko-v0.1.0.tar.gz* root@test-vps:/root/
ssh root@test-vps 'bash -c "tar -xzf neko-v0.1.0.tar.gz && bash neko/install.sh --local neko-v0.1.0.tar.gz"'
sudo neko   # 依次检查 1 → 8，然后在 2 / 4 中做修改，最后在 9 中完整回滚
```

完整回滚后，检查以下内容是否恢复到安装前的状态：`sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc`、`/etc/resolv.conf`、`/etc/sysctl.d/`、`/etc/systemd/resolved.conf.d/`。
