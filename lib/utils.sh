# shellcheck shell=bash
# Neko - generic helpers: paths, privileges, sysctl access, locking, config.

[[ -n ${_NEKO_UTILS_LOADED:-} ]] && return 0
_NEKO_UTILS_LOADED=1

# Every read/write of a system path goes through sysp so the test-suite can
# point Neko at a fake root filesystem (NEKO_SYSROOT). In production it is empty.
sysp() { printf '%s%s' "${NEKO_SYSROOT:-}" "$1"; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

neko_euid() {
  # NEKO_TEST_EUID is honoured only together with a test sysroot.
  if [[ -n ${NEKO_SYSROOT:-} && -n ${NEKO_TEST_EUID:-} ]]; then
    printf '%s' "$NEKO_TEST_EUID"
  else
    printf '%s' "${EUID:-$(id -u)}"
  fi
}

is_root() { [[ $(neko_euid) == 0 ]]; }

require_root() { # require_root [action description]
  is_root && return 0
  ui_err "${1:-该操作}需要 root 权限。"
  ui_note "请使用 sudo neko 重新运行；只读检测功能无需 root。"
  return 1
}

read_first_line() { # read_first_line <system path>
  local f l=''
  f=$(sysp "$1")
  [[ -r $f && -f $f ]] || return 1
  IFS= read -r l <"$f" || [[ -n $l ]] || return 1
  printf '%s' "$l"
}

# sysctl_get <key>: runtime value with whitespace normalised ("4096 131072 6291456").
sysctl_get() {
  local f v parts
  f=$(sysp "/proc/sys/${1//.//}")
  [[ -r $f && -f $f ]] || return 1
  v=$(<"$f") || return 1
  read -ra parts <<<"$v"
  printf '%s' "${parts[*]}"
}

sysctl_exists() { [[ -e $(sysp "/proc/sys/${1//.//}") ]]; }

# Root on a read-only /proc/sys (typical for containers) gets EROFS from access(2).
sysctl_writable() { [[ -w $(sysp "/proc/sys/${1//.//}") ]]; }

sysctl_set_runtime() { # sysctl_set_runtime <key> <value>
  sysctl -w "$1=$2" >/dev/null 2>&1
}

num_or() { # num_or <value> <fallback>: integer or fallback
  if [[ $1 =~ ^[0-9]+$ ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

human_bytes() { # human_bytes <bytes>
  local b=${1:-0}
  if ((b >= 1073741824)); then
    printf '%d.%d GiB' $((b / 1073741824)) $((b % 1073741824 * 10 / 1073741824))
  elif ((b >= 1048576)); then
    printf '%d.%d MiB' $((b / 1048576)) $((b % 1048576 * 10 / 1048576))
  elif ((b >= 1024)); then
    printf '%d KiB' $((b / 1024))
  else
    printf '%d B' "$b"
  fi
}

# Version compare: version_ge 6.1.0 4.9 -> true
version_ge() {
  local IFS=.-+ a b i
  read -ra a <<<"$1"
  read -ra b <<<"$2"
  for ((i = 0; i < ${#b[@]}; i++)); do
    local x=${a[i]:-0} y=${b[i]:-0}
    x=${x%%[!0-9]*} y=${y%%[!0-9]*}
    x=${x:-0} y=${y:-0}
    ((10#$x > 10#$y)) && return 0
    ((10#$x < 10#$y)) && return 1
  done
  return 0
}

now_ms() { # milliseconds since epoch (bash 5 EPOCHREALTIME, falls back to date)
  if [[ -n ${EPOCHREALTIME:-} ]]; then
    local t=${EPOCHREALTIME/,/.}
    printf '%s' $((${t%.*} * 1000 + 10#${t#*.} / 1000))
  else
    date +%s%3N
  fi
}

hex_to_bin() { # writes raw bytes for a hex string to stdout
  local hex=$1 i
  for ((i = 0; i < ${#hex}; i += 2)); do
    # shellcheck disable=SC2059
    printf "\\x${hex:i:2}"
  done
}

file_sha256() {
  [[ -e $1 || -L $1 ]] || { printf 'none'; return 0; }
  if [[ -L $1 ]]; then
    printf 'link:%s' "$(readlink "$1")"
  else
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  fi
}

mktemp_dir() { mktemp -d "${TMPDIR:-/tmp}/neko.XXXXXX"; }

# Run a command with a timeout when coreutils timeout is available.
run_timeout() { # run_timeout <seconds> <cmd...>
  local t=$1
  shift
  if has_cmd timeout; then timeout "$t" "$@"; else "$@"; fi
}

# ---------------------------------------------------------------- locking ---
NEKO_LOCK_HELD=0

neko_lock() {
  ((NEKO_LOCK_HELD)) && return 0
  local f="${NEKO_STATE_DIR}/.lock"
  mkdir -p "$NEKO_STATE_DIR" 2>/dev/null || true
  if ! has_cmd flock; then
    log_warn "flock 不可用，跳过并发锁"
    NEKO_LOCK_HELD=1
    return 0
  fi
  exec 9>"$f" || return 1
  if ! flock -n 9; then
    ui_err "另一个 Neko 进程正在修改系统配置，请稍后再试。"
    exec 9>&-
    return 1
  fi
  NEKO_LOCK_HELD=1
}

neko_unlock() {
  ((NEKO_LOCK_HELD)) || return 0
  if has_cmd flock; then
    flock -u 9 2>/dev/null
    exec 9>&-
  fi
  NEKO_LOCK_HELD=0
}

# ----------------------------------------------------------------- config ---
# /etc/neko/neko.conf holds KEY=VALUE lines. It is parsed, never sourced.
declare -gA NEKO_CONF=()

config_load() {
  local f="${NEKO_ETC_DIR}/neko.conf" k v
  NEKO_CONF=(
    [EXPORT_DIR]="${HOME:-/root}/Neko-Export"
    [EXPORT_SERVER]=''
    [GUARD_TIMEOUT]=120
    [PING_TARGET_V4]=1.1.1.1
    [PING_TARGET_V6]=2606:4700:4700::1111
    [TEST_HOST]=www.cloudflare.com
  )
  [[ -r $f ]] || return 0
  while IFS='=' read -r k v; do
    k=$(trim "$k")
    [[ $k =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
    v=$(trim "$v")
    v=${v#\"} v=${v%\"}
    NEKO_CONF[$k]=$v
  done <"$f"
}

config_get() { printf '%s' "${NEKO_CONF[$1]:-${2:-}}"; }

config_set() { # config_set <KEY> <VALUE>: persists into neko.conf (root only)
  local f="${NEKO_ETC_DIR}/neko.conf" tmp
  [[ $1 =~ ^[A-Z][A-Z0-9_]*$ && $2 != *$'\n'* ]] || return 1
  mkdir -p "$NEKO_ETC_DIR" 2>/dev/null || return 1
  tmp=$(mktemp "${f}.XXXXXX") || return 1
  if [[ -f $f ]]; then
    grep -v "^[[:space:]]*$1=" "$f" >"$tmp" || true
  fi
  printf '%s=%s\n' "$1" "$2" >>"$tmp"
  chmod 644 "$tmp" && mv -f "$tmp" "$f"
  NEKO_CONF[$1]=$2
}
