# shellcheck shell=bash
# Installer: release build, checksum verification, install, upgrade, uninstall.
# Runs in staging-root mode (NEKO_INSTALL_ROOT) so nothing is written to the
# real /opt, /usr/local/bin, /etc or /var.

inst() { # inst <args...>  -> runs install.sh into $T/inst
  NEKO_INSTALL_ROOT="$T/inst" NEKO_OS_RELEASE="$R/etc/os-release" bash "$REPO/install.sh" "$@" </dev/null 2>&1
}

section "安装器：发布包构建"
(
  cd "$REPO" || exit 1
  out=$(bash tools/build-release.sh 2>&1)
  assert_rc $? 0 "构建发布包"
  assert_file "$REPO/dist/neko-v0.1.0.tar.gz" "生成 neko-v0.1.0.tar.gz"
  assert_file "$REPO/dist/neko-v0.1.0.tar.gz.sha256" "生成 .sha256 校验文件"
  list=$(tar -tzf "$REPO/dist/neko-v0.1.0.tar.gz")
  assert_contains "$list" "neko/neko.sh" "发布包包含主程序"
  assert_not_contains "$list" "neko/tests/" "发布包不包含测试"
  (cd "$REPO/dist" && sha256sum -c neko-v0.1.0.tar.gz.sha256 >/dev/null 2>&1)
  assert_rc $? 0 "校验文件与发布包一致"
)

PKG="$REPO/dist/neko-v0.1.0.tar.gz"

section "安装器：安装、升级、重复运行"
(
  t_setup
  out=$(inst --local "$PKG" --yes)
  assert_rc $? 0 "从本地发布包安装"
  assert_contains "$out" "SHA256 校验通过" "安装前校验 SHA256"
  assert_contains "$out" "Neko 已成功安装！" "安装成功提示"
  assert_contains "$out" "版本：v0.1.0" "显示版本"
  assert_contains "$out" "命令：neko" "显示命令"
  assert_contains "$out" "安装验证通过：Neko v0.1.0" "安装后验证"
  for f in opt/neko/neko.sh opt/neko/lib/ui.sh opt/neko/data/profiles/bbr-fq.conf usr/local/bin/neko etc/neko/neko.conf etc/neko/neko.conf.default var/lib/neko/install.info; do
    assert_file "$T/inst/$f" "安装 $f"
  done
  assert_no_file "$T/inst/opt/neko/tests" "不安装测试文件"
  out=$(printf '0\n' | "$T/inst/usr/local/bin/neko" 2>&1)
  assert_contains "$out" "VPS NETWORK OPTIMIZER v0.1.0" "neko 命令启动主菜单"

  echo 'EXPORT_SERVER=node.example.com' >>"$T/inst/etc/neko/neko.conf"
  mkdir -p "$T/inst/var/lib/neko/backups/00001-20260101-000000"
  printf '00001-20260101-000000\t2026-01-01 00:00:00\tcommitted\ttcp-bbr\tx\n' >"$T/inst/var/lib/neko/history.tsv"
  out=$(inst --local "$PKG" --yes)
  assert_contains "$out" "已安装相同版本 v0.1.0" "检测到已安装相同版本"
  assert_contains "$out" "保留现有配置" "升级时保留配置"
  assert_contains "$(cat "$T/inst/etc/neko/neko.conf")" "EXPORT_SERVER=node.example.com" "用户配置未被覆盖"
  assert_file "$T/inst/var/lib/neko/backups/00001-20260101-000000" "备份目录保留"
  assert_contains "$(cat "$T/inst/var/lib/neko/history.tsv")" "00001-20260101-000000" "变更历史保留"
  assert_no_file "$T/inst/var/lib/.neko-install.lock" "安装锁已释放"
  assert_eq "$(ls -d "$T/inst/opt"/.neko.* 2>/dev/null | wc -l | tr -d ' ')" 0 "无残留临时目录"

  out=$(inst --uninstall --yes)
  assert_contains "$out" "不会因卸载而恢复" "卸载前提示系统修改不会自动恢复"
  assert_no_file "$T/inst/opt/neko" "卸载：删除程序目录"
  assert_no_file "$T/inst/usr/local/bin/neko" "卸载：删除启动命令"
  assert_file "$T/inst/etc/neko/neko.conf" "卸载：保留配置"
  assert_file "$T/inst/var/lib/neko/history.tsv" "卸载：保留备份与历史"
  out=$(inst --uninstall --purge --yes)
  assert_no_file "$T/inst/var/lib/neko" "--purge 删除数据"
  assert_no_file "$T/inst/etc/neko" "--purge 删除配置"
  t_teardown
)

section "安装器：校验与安全检查"
(
  t_setup
  inst --local "$PKG" --yes >/dev/null
  cp "$PKG" "$T/bad.tar.gz"
  printf '%064d  bad.tar.gz\n' 0 >"$T/bad.tar.gz.sha256"
  out=$(inst --local "$T/bad.tar.gz" --yes --force)
  assert_rc $? 1 "校验失败时中止"
  assert_contains "$out" "SHA256 校验失败" "提示 SHA256 不匹配"
  assert_file "$T/inst/opt/neko/neko.sh" "校验失败不影响已安装版本"
  good=$(sha256sum "$PKG" | awk '{print $1}')
  cp "$PKG" "$T/pinned.tar.gz"
  out=$(inst --local "$T/pinned.tar.gz" --sha256 "$good" --yes --force)
  assert_contains "$out" "SHA256 校验通过：$good" "--sha256 固定校验值"
  out=$(inst --sha256 1234)
  assert_contains "$out" "--sha256 需要 64 位十六进制值" "拒绝非法 --sha256"
  out=$(inst --version latest!)
  assert_contains "$out" "版本号格式无效" "拒绝非法版本号"
  out=$(inst --yes)
  assert_rc $? 1 "未配置仓库时中止"
  assert_contains "$out" "安装源未配置" "仓库占位符未替换时给出明确错误"

  mkdir -p "$T/evil/neko" && cp -R "$REPO/lib" "$T/evil/neko/" && echo x >"$T/evil/outside.txt"
  tar -C "$T/evil" -czf "$T/evil.tar.gz" neko outside.txt
  (cd "$T" && sha256sum evil.tar.gz >evil.tar.gz.sha256)
  out=$(inst --local "$T/evil.tar.gz" --yes --force)
  assert_contains "$out" "安装包结构异常" "拒绝包含 neko/ 以外路径的安装包"
  tar -C "$T/evil" -czf "$T/partial.tar.gz" neko
  (cd "$T" && sha256sum partial.tar.gz >partial.tar.gz.sha256)
  out=$(inst --local "$T/partial.tar.gz" --yes --force)
  assert_contains "$out" "安装包不完整" "拒绝不完整的安装包"
  cp "$PKG" "$T/nosum.tar.gz"
  out=$(inst --local "$T/nosum.tar.gz")
  assert_contains "$out" "无法校验安装包" "无校验文件时提示"
  assert_contains "$out" "已取消安装" "非交互时默认拒绝未校验的安装包"
  t_teardown
)

section "安装器：系统兼容性"
(
  t_setup
  w etc/os-release 'PRETTY_NAME="Arch Linux"
ID=arch'
  out=$(inst --local "$PKG" --yes)
  if has_cmd dnf || has_cmd yum || has_cmd apk; then
    echo "  skip 不支持系统（本机存在 dnf/yum/apk）"
  else
    assert_contains "$out" "不支持的系统：Arch Linux" "不支持的系统明确提示"
  fi
  w etc/os-release 'PRETTY_NAME="Debian GNU/Linux 11 (bullseye)"
ID=debian
VERSION_ID="11"'
  out=$(inst --local "$PKG")
  assert_contains "$out" "未经测试" "未测试的 Debian 版本提示"
  assert_contains "$out" "已取消安装" "非交互时默认不在未测试系统上安装"
  t_teardown
)
