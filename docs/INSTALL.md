# 安装、升级与卸载

## 一键安装

```bash
bash <(wget -qO- https://raw.githubusercontent.com/<OWNER>/<REPO>/main/install.sh)
bash <(curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPO>/main/install.sh)
wget -qO- https://raw.githubusercontent.com/<OWNER>/<REPO>/main/install.sh | sudo bash
```

`<OWNER>/<REPO>` 是待确定的占位符。在仓库地址确定之前，安装器会拒绝联网安装，并提示「安装源未配置」。可以用 `--repo OWNER/REPO` 或环境变量 `NEKO_REPO` 指定仓库，也可以使用 `--local` 安装本地发行包。

通过管道运行（`… | sudo bash`）时，标准输入就是脚本本身，所以安装器会从 `/dev/tty` 读取确认。没有终端时，所有问题都按默认值处理：依赖安装默认「否」，未校验的安装包默认「拒绝」。如需无人值守安装，请加 `--yes`。

## 安装器执行的步骤

1. 检查 root 权限
2. 读取 `/etc/os-release`：Debian 12/13 和 Ubuntu 22.04/24.04 直接继续；其他 Debian/Ubuntu 版本需要确认；其他发行版只有存在 dnf/yum/apk 时才允许继续（标记为实验性）；其余系统拒绝安装
3. 检查 CPU 架构（x86_64 / ARM64）和 Bash 版本（至少 4.4，推荐 5.x）
4. 检查依赖，列出缺失项、用途和对应的安装命令；经确认后执行 `apt-get update` 和 `apt-get install --no-install-recommends`（**不会**执行 upgrade，也不修改软件源）；安装后重新检测
5. 列出缺失的可选依赖，默认不安装
6. 从 GitHub Release 下载 `neko-vX.Y.Z.tar.gz` 和 `.sha256`（只使用 HTTPS，curl 加 `--proto =https --tlsv1.2`，wget 加 `--https-only`）
7. 校验 SHA256，失败则中止
8. 检查包结构：只允许 `neko/` 下的路径，拒绝包含 `..` 的路径，必需文件必须齐全，`bash -n` 语法检查通过
9. 先在临时目录 `/opt/.neko.new.*` 中准备好，再原子替换 `/opt/neko`；替换失败时恢复旧版本
10. 生成 `/usr/local/bin/neko`，创建 `/etc/neko`、`/var/lib/neko`、`/var/log/neko`
11. 运行 `neko --version` 验证安装

使用安装锁 `/var/lib/.neko-install.lock` 防止同时运行多个安装器。重复运行安装器是安全的：遇到相同版本时会询问是否重新安装。

## 选项

| 选项 | 说明 |
|---|---|
| `--version vX.Y.Z` | 安装指定版本（也可用于降级） |
| `--local PATH` | 从本地 `.tar.gz` 安装：如果存在同名 `.sha256` 文件或提供了 `--sha256`，会先校验；也可以指定源码目录（开发用途，不校验） |
| `--sha256 HASH` | 固定期望的 SHA256 值。比使用同一个 Release 中的 `.sha256` 文件更可靠 |
| `--repo OWNER/REPO` | 指定下载仓库 |
| `--yes` | 自动确认依赖安装等问题 |
| `--force` | 相同版本也重新安装 |
| `--uninstall [--purge]` | 卸载 |

## 升级

再次运行安装命令即可，也可以用 `--version` 指定版本。升级只替换 `/opt/neko` 和启动脚本：

- `/etc/neko/neko.conf` **始终保留**（`neko.conf.default` 会更新为新版本的默认值，供参考）
- `/var/lib/neko`（备份、变更历史、报告）和 `/var/log/neko` 不会被改动

## 卸载

```bash
sudo bash install.sh --uninstall           # 删除程序，保留配置、备份和日志
sudo bash install.sh --uninstall --purge   # 同时删除配置、备份和日志（需再次确认）
```

卸载**不会**撤销 Neko 做过的系统修改（sysctl、DNS 等）。如需恢复，请在卸载前运行 `sudo neko` → `9. 配置备份与回滚` → `5. 完整回滚`。如果变更历史中还有生效的变更，安装器会给出提示。`--purge` 会删除全部备份，删除后就无法再回滚。

## 发布流程（维护者）

```bash
bash tests/run.sh
bash tools/build-release.sh        # → dist/neko-v0.1.0.tar.gz、.sha256、SHA256SUMS
```

1. 更新 `VERSION`
2. 创建 Git 标签 `vX.Y.Z` 和对应的 GitHub Release
3. 上传 `dist/` 下的 `neko-vX.Y.Z.tar.gz` 和 `neko-vX.Y.Z.tar.gz.sha256`
4. 把 `install.sh` 中 `NEKO_REPO` 的默认值以及 README / 本文中的 `<OWNER>/<REPO>` 替换为真实仓库地址

注意：放在同一个 Release 中的 `.sha256` 只能防止下载损坏，不能防止 Release 本身被替换。需要更强保证时，请从可信渠道获取哈希值，并通过 `--sha256` 传入。
