#!/usr/bin/env bash
# Neko VPS Network Optimizer - installer
#
#   bash <(wget -qO- https://raw.githubusercontent.com/<OWNER>/<REPO>/main/install.sh)
#   bash <(curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPO>/main/install.sh)
#   wget -qO- https://raw.githubusercontent.com/<OWNER>/<REPO>/main/install.sh | sudo bash
#
# The installer only checks the environment, installs dependencies (after you
# confirm), downloads a release, verifies its SHA256 and installs the files.
# It never upgrades the system, edits package sources, touches firewalls or
# SELinux, and never installs proxy servers.
#
# Options:
#   --version vX.Y.Z   install a specific release (default: latest release)
#   --local PATH       install from a local release tarball or source directory
#   --sha256 HASH      expected SHA256 of the release tarball (pinning)
#   --repo OWNER/REPO  GitHub repository to download from
#   --yes              answer "yes" to dependency installation prompts
#   --force            reinstall even if the same version is installed
#   --uninstall        remove Neko (keeps config, backups and logs)
#   --purge            with --uninstall: also delete config, backups and logs
#   -h, --help         show this help

if [ -z "${BASH_VERSION:-}" ]; then
  echo "请使用 bash 运行安装器：bash install.sh" >&2
  exit 1
fi
set -o pipefail
set -u

# Repository placeholders are intentionally left unfilled until the project is
# published; use --repo or NEKO_REPO to point at the real repository.
NEKO_REPO=${NEKO_REPO:-'<OWNER>/<REPO>'}
ROOT=${NEKO_INSTALL_ROOT:-}
OS_RELEASE=${NEKO_OS_RELEASE:-/etc/os-release}
PREFIX="$ROOT/opt/neko"
BIN="$ROOT/usr/local/bin/neko"
ETC="$ROOT/etc/neko"
STATE="$ROOT/var/lib/neko"
LOGDIR="$ROOT/var/log/neko"

OPT_VERSION='' OPT_LOCAL='' OPT_SHA256='' ASSUME_YES=0 FORCE=0 MODE=install PURGE=0
WORKDIR='' LOCK_DIR='' PKG_MGR='' OS_ID='' OS_VER='' OS_PRETTY=''

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  R=$'\e[31m' G=$'\e[32m' Y=$'\e[33m' B=$'\e[34m' C=$'\e[36m' W=$'\e[1m' N=$'\e[0m'
else
  R='' G='' Y='' B='' C='' W='' N=''
fi

info() { printf '%s[信息]%s %s\n' "$B" "$N" "$*"; }
ok() { printf '%s[成功]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$Y" "$N" "$*"; }
err() { printf '%s[错误]%s %s\n' "$R" "$N" "$*" >&2; }
die() {
  err "$*"
  exit 1
}
has() { command -v "$1" >/dev/null 2>&1; }

banner() {
  printf '%s╔══════════════════════════════════════════════╗%s\n' "$C" "$N"
  printf '%s║%s%s             NEKO INSTALLER                   %s%s║%s\n' "$C" "$N" "$W" "$N" "$C" "$N"
  printf '%s╚══════════════════════════════════════════════╝%s\n' "$C" "$N"
}

usage() {
  cat <<'EOF'
Neko 安装器

用法：bash install.sh [选项]

  --version vX.Y.Z   安装指定版本（默认最新 Release）
  --local PATH       从本地发行包（.tar.gz）或源码目录安装
  --sha256 HASH      指定发行包的期望 SHA256（固定校验值）
  --repo OWNER/REPO  指定 GitHub 发布仓库
  --yes              自动确认依赖安装提示
  --force            同版本也重新安装
  --uninstall        卸载 Neko（保留配置、备份与日志）
  --purge            与 --uninstall 一起使用：同时删除配置、备份与日志
  -h, --help         显示帮助
EOF
}

# Works for "curl ... | sudo bash" too, where stdin is the script itself.
ask() { # ask <question> [y|n]
  local q=$1 def=${2:-n} hint='y/N' ans=''
  [[ $def == y ]] && hint='Y/n'
  if ((ASSUME_YES)); then
    printf '%s [%s]：y（--yes）\n' "$q" "$hint"
    return 0
  fi
  if [[ -t 0 ]]; then
    read -r -p "$q [$hint]：" ans || ans=''
  elif { exec 3</dev/tty; } 2>/dev/null; then
    read -r -p "$q [$hint]：" ans <&3 || ans=''
    exec 3<&-
  else
    warn "没有可交互的终端，按默认选择「${def}」处理（可使用 --yes）。"
    ans=$def
  fi
  ans=${ans,,}
  [[ -z $ans ]] && ans=$def
  [[ $ans == y || $ans == yes ]]
}

cleanup() {
  [[ -n $WORKDIR && -d $WORKDIR ]] && rm -rf "$WORKDIR"
  [[ -n $LOCK_DIR && -d $LOCK_DIR ]] && rmdir "$LOCK_DIR" 2>/dev/null
  return 0
}
trap cleanup EXIT
trap 'echo; err "安装已中断，未完成的临时文件已清理。"; exit 130' INT TERM

parse_args() {
  while (($#)); do
    case $1 in
      --version)
        OPT_VERSION=${2:-}
        shift
        ;;
      --local)
        OPT_LOCAL=${2:-}
        shift
        ;;
      --sha256)
        OPT_SHA256=${2:-}
        shift
        ;;
      --repo)
        NEKO_REPO=${2:-}
        shift
        ;;
      --yes | -y) ASSUME_YES=1 ;;
      --force) FORCE=1 ;;
      --uninstall) MODE=uninstall ;;
      --purge) PURGE=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "未知参数：$1（使用 --help 查看用法）" ;;
    esac
    shift
  done
  if [[ -n $OPT_VERSION ]]; then
    [[ $OPT_VERSION =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?$ ]] || die "版本号格式无效：${OPT_VERSION}"
    [[ $OPT_VERSION == v* ]] || OPT_VERSION="v$OPT_VERSION"
  fi
  if [[ -n $OPT_SHA256 && ! $OPT_SHA256 =~ ^[0-9a-fA-F]{64}$ ]]; then
    die "--sha256 需要 64 位十六进制值。"
  fi
}

# ------------------------------------------------------------- checks -----
check_root() {
  if [[ -n $ROOT ]]; then
    warn "安装到暂存根目录：${ROOT}（测试模式，不检查 root，不安装依赖）"
    return 0
  fi
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "安装需要 root 权限。"
    echo "  请使用：sudo bash install.sh"
    echo "  或者：wget -qO- https://raw.githubusercontent.com/${NEKO_REPO}/main/install.sh | sudo bash"
    exit 1
  fi
}

check_os() {
  [[ -r $OS_RELEASE ]] || die "无法读取 ${OS_RELEASE}，无法识别操作系统。"
  local k v
  while IFS='=' read -r k v; do
    v=${v%\"} v=${v#\"}
    case $k in
      ID) OS_ID=$v ;;
      VERSION_ID) OS_VER=$v ;;
      PRETTY_NAME) OS_PRETTY=$v ;;
      ID_LIKE) OS_LIKE=$v ;;
    esac
  done <"$OS_RELEASE"
  [[ $(uname -s) == Linux || -n $ROOT ]] || die "Neko 仅支持 Linux。"
  info "操作系统：${OS_PRETTY:-$OS_ID $OS_VER}"
  case "$OS_ID:$OS_VER" in
    debian:12 | debian:13 | ubuntu:22.04 | ubuntu:24.04)
      ok "系统受支持。"
      ;;
    debian:* | ubuntu:*)
      warn "${OS_PRETTY} 未经测试（首批支持 Debian 12/13、Ubuntu 22.04/24.04）。"
      ask "仍要继续安装吗？" n || die "已取消安装。"
      ;;
    *)
      if [[ " ${OS_LIKE:-} " == *' debian '* ]] || has dnf || has yum || has apk; then
        warn "${OS_PRETTY:-$OS_ID} 不在首批支持范围内：Neko 只读检测可用，修改类功能会被禁用。"
        ask "仍要继续安装吗？" n || die "已取消安装。"
      else
        die "不支持的系统：${OS_PRETTY:-$OS_ID}。首批支持 Debian 12/13、Ubuntu 22.04/24.04。"
      fi
      ;;
  esac
  if has apt-get; then PKG_MGR=apt; elif has dnf; then PKG_MGR=dnf; elif has yum; then PKG_MGR=yum; elif has apk; then PKG_MGR=apk; fi
}

check_arch() {
  local m
  m=$(uname -m)
  case $m in
    x86_64 | amd64) ok "CPU 架构：x86_64" ;;
    aarch64 | arm64) ok "CPU 架构：ARM64" ;;
    *)
      warn "CPU 架构 ${m} 未经测试（首批支持 x86_64 / ARM64）。Neko 为纯 Shell 程序，通常仍可运行。"
      ask "仍要继续安装吗？" n || die "已取消安装。"
      ;;
  esac
}

check_bash() {
  if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
    die "Bash 版本过低（${BASH_VERSION}），Neko 需要 Bash 4.4+（推荐 5.x）。"
  fi
  if ((BASH_VERSINFO[0] < 5)); then
    warn "Bash ${BASH_VERSION}：可以运行，推荐 Bash 5.x。"
  else
    ok "Bash ${BASH_VERSION}"
  fi
}

# command|apt package|dnf/yum package|apk package|purpose
REQUIRED_DEPS=(
  "curl|curl|curl|curl|HTTPS 下载（与 wget 二选一）"
  "jq|jq|jq|jq|JSON 解析（代理配置、节点导出）"
  "ip|iproute2|iproute|iproute2|网络接口、路由"
  "ss|iproute2|iproute|iproute2|监听端口检测"
  "tc|iproute2|iproute-tc|iproute2|Qdisc 检测"
  "ps|procps|procps-ng|procps|进程检测"
  "sysctl|procps|procps-ng|procps|内核参数"
  "sha256sum|coreutils|coreutils|coreutils|下载校验"
  "grep|grep|grep|grep|文本处理"
  "sed|sed|sed|sed|文本处理"
  "awk|gawk|gawk|gawk|文本处理"
  "tar|tar|tar|tar|安装包解压"
  "gzip|gzip|gzip|gzip|安装包解压"
  "flock|util-linux|util-linux|util-linux|并发修改锁"
  "diff|diffutils|diffutils|diffutils|变更差异记录"
)
OPTIONAL_DEPS=(
  "qrencode|qrencode|qrencode|libqrencode-tools|二维码生成"
  "openssl|openssl|openssl|openssl|REALITY 公钥推导、证书检测"
  "ethtool|ethtool|ethtool|ethtool|网卡 GSO/GRO 检测"
  "tracepath|iputils-tracepath|iputils|iputils|路由与 MTU 检测"
  "ping|iputils-ping|iputils|iputils|RTT / 丢包测试"
  "iperf3|iperf3|iperf3|iperf3|吞吐量测试"
  "dig|dnsutils|bind-utils|bind-tools|DNS 诊断"
)

dep_pkg() { # dep_pkg <entry>
  local cmd apt rpm apk _p
  IFS='|' read -r cmd apt rpm apk _p <<<"$1"
  case $PKG_MGR in
    apt) echo "$apt" ;;
    dnf | yum) echo "$rpm" ;;
    apk) echo "$apk" ;;
    *) echo "$apt" ;;
  esac
}

dep_missing() { # dep_missing <entry>: true if the command is absent
  local cmd=${1%%|*}
  if [[ $cmd == curl ]]; then
    has curl || has wget && return 1
    return 0
  fi
  ! has "$cmd"
}

pkg_install_cmd() {
  case $PKG_MGR in
    apt) echo "apt-get install -y --no-install-recommends $*" ;;
    dnf) echo "dnf install -y $*" ;;
    yum) echo "yum install -y $*" ;;
    apk) echo "apk add $*" ;;
    *) echo "（未识别包管理器，请手动安装：$*）" ;;
  esac
}

pkg_install() {
  local rc=0
  case $PKG_MGR in
    apt)
      if ask "需要刷新软件包索引（apt-get update，不会升级任何软件包），是否继续？" y; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq || warn "apt-get update 失败，尝试直接安装。"
      fi
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" || rc=$?
      ;;
    dnf) dnf install -y "$@" || rc=$? ;;
    yum) yum install -y "$@" || rc=$? ;;
    apk) apk add "$@" || rc=$? ;;
    *) rc=1 ;;
  esac
  return $rc
}

check_ca() {
  local f
  for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
    [[ -s $f ]] && return 0
  done
  return 1
}

check_deps() {
  local e pkgs=() lines=() cmd p purpose
  for e in "${REQUIRED_DEPS[@]}"; do
    dep_missing "$e" || continue
    IFS='|' read -r cmd _ _ _ purpose <<<"$e"
    p=$(dep_pkg "$e")
    lines+=("$(printf '  %-10s %-14s %s' "$cmd" "$p" "$purpose")")
    [[ " ${pkgs[*]} " == *" $p "* ]] || pkgs+=("$p")
  done
  if ! check_ca && [[ -z $ROOT ]]; then
    lines+=("$(printf '  %-10s %-14s %s' "CA 证书" "ca-certificates" "HTTPS 证书验证")")
    pkgs+=(ca-certificates)
  fi
  if ((${#pkgs[@]} == 0)); then
    ok "必要依赖已满足。"
  else
    warn "缺少以下必要依赖："
    printf '  %-10s %-14s %s\n' "命令" "软件包" "用途"
    printf '%s\n' "${lines[@]}"
    echo "  安装命令：$(pkg_install_cmd "${pkgs[@]}")"
    if [[ -n $ROOT ]]; then
      warn "测试模式不安装依赖。"
    elif [[ -z $PKG_MGR ]]; then
      die "未识别包管理器，请手动安装上述依赖后重新运行。"
    elif ask "是否立即安装以上依赖？" y; then
      pkg_install "${pkgs[@]}" || die "依赖安装失败，请检查软件源后手动执行：$(pkg_install_cmd "${pkgs[@]}")"
      hash -r
      local still=()
      for e in "${REQUIRED_DEPS[@]}"; do dep_missing "$e" && still+=("${e%%|*}"); done
      ((${#still[@]})) && die "以下依赖仍不可用：${still[*]}"
      ok "必要依赖已安装。"
    else
      die "缺少必要依赖，已取消安装。"
    fi
  fi

  local opt=() optp=()
  for e in "${OPTIONAL_DEPS[@]}"; do
    dep_missing "$e" || continue
    IFS='|' read -r cmd _ _ _ purpose <<<"$e"
    opt+=("$(printf '  %-10s %-18s %s' "$cmd" "$(dep_pkg "$e")" "$purpose")")
    optp+=("$(dep_pkg "$e")")
  done
  if ((${#opt[@]})); then
    info "以下可选依赖未安装（缺少时仅对应功能不可用）："
    printf '%s\n' "${opt[@]}"
    if [[ -z $ROOT && -n $PKG_MGR ]] && ask "是否安装可选依赖？" n; then
      pkg_install "${optp[@]}" || warn "部分可选依赖安装失败，可稍后手动安装：$(pkg_install_cmd "${optp[@]}")"
    else
      info "可稍后安装：$(pkg_install_cmd "${optp[@]}")"
    fi
  fi
}

# ------------------------------------------------------------- download ---
fetch() { # fetch <url> <dest>
  if has curl; then
    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --connect-timeout 15 -o "$2" "$1"
  elif has wget; then
    wget --https-only -q -T 15 -t 3 -O "$2" "$1"
  else
    return 1
  fi
}

repo_configured() { [[ $NEKO_REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; }

resolve_version() {
  [[ -n $OPT_VERSION ]] && { echo "$OPT_VERSION"; return 0; }
  local api="https://api.github.com/repos/${NEKO_REPO}/releases/latest" tag
  fetch "$api" "$WORKDIR/latest.json" || return 1
  if has jq; then
    tag=$(jq -r '.tag_name // empty' "$WORKDIR/latest.json")
  else
    tag=$(grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' "$WORKDIR/latest.json" | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')
  fi
  [[ $tag =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]] || return 1
  echo "$tag"
}

download_release() { # sets PKG_FILE
  repo_configured || die "安装源未配置（仓库地址仍为占位符 ${NEKO_REPO}）。请使用 --repo OWNER/REPO 指定发布仓库，或使用 --local 从本地安装包安装。"
  local tag base name
  info "查询版本信息：github.com/${NEKO_REPO}"
  tag=$(resolve_version) || die "无法获取最新版本信息，请检查网络或使用 --version 指定版本。"
  name="neko-${tag}.tar.gz"
  base="https://github.com/${NEKO_REPO}/releases/download/${tag}"
  info "下载 ${name}（GitHub Release，HTTPS）"
  fetch "$base/$name" "$WORKDIR/$name" || die "下载失败：$base/$name"
  if [[ -z $OPT_SHA256 ]]; then
    fetch "$base/$name.sha256" "$WORKDIR/$name.sha256" || die "下载校验文件失败：$base/$name.sha256（拒绝安装未校验的文件）"
  fi
  PKG_FILE="$WORKDIR/$name"
}

verify_sha256() { # verify_sha256 <file> [sidecar]
  local file=$1 sidecar=${2:-} want got
  if [[ -n $OPT_SHA256 ]]; then
    want=${OPT_SHA256,,}
  elif [[ -n $sidecar && -f $sidecar ]]; then
    want=$(awk '{print tolower($1); exit}' "$sidecar")
  else
    return 2
  fi
  [[ $want =~ ^[0-9a-f]{64}$ ]] || die "校验文件格式无效。"
  got=$(sha256sum "$file" | awk '{print $1}')
  if [[ $got != "$want" ]]; then
    err "SHA256 校验失败！"
    echo "  期望：$want"
    echo "  实际：$got"
    die "安装包可能已损坏或被篡改，已中止安装。"
  fi
  ok "SHA256 校验通过：${got}"
}

extract_release() { # extract_release <tarball> -> SRC_DIR
  local tb=$1 bad
  bad=$(tar -tzf "$tb" 2>/dev/null | grep -Ev '^neko(/|$)' | head -n 1) || true
  tar -tzf "$tb" >/dev/null 2>&1 || die "安装包损坏：无法读取 tar.gz。"
  [[ -z $bad ]] || die "安装包结构异常（包含 neko/ 以外的路径：${bad}），已拒绝。"
  tar -tzf "$tb" | grep -Eq '(^|/)\.\.(/|$)' && die "安装包包含非法路径（..），已拒绝。"
  mkdir -p "$WORKDIR/extract"
  tar -xzf "$tb" -C "$WORKDIR/extract" --no-same-owner || die "解压失败。"
  SRC_DIR="$WORKDIR/extract/neko"
}

validate_tree() { # validate_tree <dir>
  local d=$1 f
  for f in neko.sh VERSION lib/ui.sh lib/utils.sh core/backup.sh engine/apply.sh modules/export.sh data/dns-providers.tsv; do
    [[ -f $d/$f ]] || die "安装包不完整：缺少 ${f}"
  done
  bash -n "$d/neko.sh" || die "neko.sh 语法检查失败。"
}

# ------------------------------------------------------------- install ----
acquire_lock() {
  mkdir -p "$ROOT/var/lib" 2>/dev/null
  LOCK_DIR="$ROOT/var/lib/.neko-install.lock"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_DIR=''
    die "另一个 Neko 安装器正在运行（如确认没有，请删除 $ROOT/var/lib/.neko-install.lock）。"
  fi
}

write_default_conf() {
  cat <<'EOF'
# Neko configuration (KEY=VALUE). This file is preserved across upgrades.
# Export directory for node links / client configs
EXPORT_DIR=/root/Neko-Export
# Address written into exported nodes (domain or public IP); empty = ask
EXPORT_SERVER=
# Seconds before an unconfirmed DNS change is rolled back automatically
GUARD_TIMEOUT=120
# Targets used by connectivity / latency tests
PING_TARGET_V4=1.1.1.1
PING_TARGET_V6=2606:4700:4700::1111
TEST_HOST=www.cloudflare.com
EOF
}

install_tree() { # install_tree <source dir> <version>
  local src=$1 ver=$2 stage old
  mkdir -p "$ROOT/opt" "$(dirname "$BIN")" || die "无法创建安装目录。"
  stage="$ROOT/opt/.neko.new.$$"
  old="$ROOT/opt/.neko.old.$$"
  rm -rf "$stage"
  mkdir -p "$stage" && cp -R "$src/." "$stage/" || die "复制文件失败。"
  rm -rf "$stage/tests" "$stage/.git" "$stage/dist"
  find "$stage" -type d -exec chmod 755 {} +
  find "$stage" -type f -exec chmod 644 {} +
  chmod 755 "$stage/neko.sh"
  if [[ -d $PREFIX ]]; then
    mv "$PREFIX" "$old" || die "无法替换旧版本。"
  fi
  if ! mv "$stage" "$PREFIX"; then
    [[ -d $old ]] && mv "$old" "$PREFIX"
    die "安装失败，已恢复旧版本。"
  fi
  rm -rf "$old"

  local tmp
  tmp=$(mktemp "${BIN}.XXXXXX") || die "无法写入 ${BIN}"
  {
    echo '#!/usr/bin/env bash'
    echo '# Neko launcher - generated by install.sh'
    printf 'export NEKO_HOME=%q\n' "$PREFIX"
    if [[ -n $ROOT ]]; then
      printf 'export NEKO_ETC_DIR=%q NEKO_STATE_DIR=%q NEKO_LOG_DIR=%q NEKO_BIN=%q\n' "$ETC" "$STATE" "$LOGDIR" "$BIN"
    fi
    printf 'exec bash %q "$@"\n' "$PREFIX/neko.sh"
  } >"$tmp"
  chmod 755 "$tmp" && mv -f "$tmp" "$BIN" || die "无法创建启动命令 ${BIN}"

  mkdir -p "$ETC" "$STATE" "$LOGDIR"
  chmod 755 "$ETC"
  chmod 700 "$STATE"
  chmod 750 "$LOGDIR"
  write_default_conf >"$ETC/neko.conf.default"
  if [[ ! -f $ETC/neko.conf ]]; then
    write_default_conf >"$ETC/neko.conf"
    chmod 644 "$ETC/neko.conf"
  else
    info "保留现有配置：${ETC}/neko.conf"
  fi
  {
    echo "version=$ver"
    echo "installed=$(date '+%F %T')"
    echo "source=${INSTALL_SOURCE:-unknown}"
  } >"$STATE/install.info"
  chmod 600 "$STATE/install.info"
}

verify_install() {
  local want=$1 out
  out=$("$BIN" --version 2>&1) || die "安装验证失败：${out}"
  [[ $out == "Neko ${want}" || $out == "Neko v${want#v}" ]] || die "安装验证失败：期望 ${want}，实际 ${out}"
  ok "安装验证通过：${out}"
}

do_install() {
  banner
  check_root
  check_os
  check_arch
  check_bash
  check_deps
  acquire_lock
  WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/neko-install.XXXXXX") || die "无法创建临时目录。"
  chmod 700 "$WORKDIR"

  local src ver rc
  if [[ -n $OPT_LOCAL ]]; then
    if [[ -d $OPT_LOCAL ]]; then
      warn "从本地源码目录安装：${OPT_LOCAL}（开发用途，不进行 SHA256 校验）"
      src=$OPT_LOCAL
      INSTALL_SOURCE="local-dir:$OPT_LOCAL"
    elif [[ -f $OPT_LOCAL ]]; then
      verify_sha256 "$OPT_LOCAL" "${OPT_LOCAL}.sha256"
      rc=$?
      if ((rc == 2)); then
        warn "未找到 ${OPT_LOCAL}.sha256，也未提供 --sha256，无法校验安装包。"
        ask "仍要安装未校验的本地安装包吗？" n || die "已取消安装。"
      fi
      extract_release "$OPT_LOCAL"
      src=$SRC_DIR
      INSTALL_SOURCE="local:$OPT_LOCAL"
    else
      die "本地路径不存在：${OPT_LOCAL}"
    fi
  else
    download_release
    verify_sha256 "$PKG_FILE" "$PKG_FILE.sha256"
    extract_release "$PKG_FILE"
    src=$SRC_DIR
    INSTALL_SOURCE="github:${NEKO_REPO}"
  fi
  validate_tree "$src"
  ver=$(tr -d ' \r\n' <"$src/VERSION")
  ver="v${ver#v}"

  if [[ -f $PREFIX/VERSION ]]; then
    local cur
    cur="v$(tr -d ' \r\n' <"$PREFIX/VERSION" | sed 's/^v//')"
    if [[ $cur == "$ver" && $FORCE != 1 ]]; then
      info "已安装相同版本 ${ver}。"
      ask "是否重新安装（保留配置、备份与日志）？" n || {
        ok "无需重复安装。运行 neko 即可使用。"
        return 0
      }
    else
      info "升级：${cur} → ${ver}（保留配置、备份与日志）"
    fi
  fi

  install_tree "$src" "$ver"
  verify_install "$ver"

  echo
  banner
  echo
  echo "Neko 已成功安装！"
  echo
  echo "版本：${ver}"
  echo "路径：${PREFIX}"
  echo "命令：neko"
  echo
  echo "运行方式："
  echo
  echo "  neko"
  echo
  echo "管理员模式："
  echo
  echo "  sudo neko"
  echo
  echo "感谢使用 Neko！"
}

do_uninstall() {
  banner
  check_root
  if [[ ! -d $PREFIX && ! -e $BIN ]]; then
    info "未检测到已安装的 Neko。"
  else
    if [[ -s $STATE/history.tsv ]] && grep -q $'\tcommitted\t' "$STATE/history.tsv"; then
      warn "Neko 修改过的系统配置（sysctl、DNS 等）不会因卸载而恢复。"
      echo "  如需恢复，请先运行：sudo neko → 9. 配置备份与回滚 → 5. 完整回滚"
      ask "确认继续卸载吗？" n || die "已取消卸载。"
    fi
    rm -rf "$PREFIX"
    rm -f "$BIN"
    ok "已移除程序文件：${PREFIX}、${BIN}"
  fi
  if ((PURGE)); then
    warn "将永久删除配置、全部备份与日志：${ETC} ${STATE} ${LOGDIR}"
    warn "删除后将无法再回滚 Neko 做过的修改。"
    if ask "确认彻底删除吗？" n; then
      rm -rf "$ETC" "$STATE" "$LOGDIR"
      ok "已删除 Neko 数据。"
    else
      info "已保留数据目录。"
    fi
  else
    info "已保留配置、备份与日志：${ETC}、${STATE}、${LOGDIR}（使用 --uninstall --purge 可一并删除）"
  fi
}

parse_args "$@"
case $MODE in
  uninstall) do_uninstall ;;
  *) do_install ;;
esac
