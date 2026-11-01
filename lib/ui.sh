# shellcheck shell=bash
# Neko - terminal UI: ASCII boxes, colors, menus and prompts.
#
# All interactive input goes through ui_read_choice / ui_confirm / ui_prompt so
# that EOF (closed stdin) always unwinds the menus instead of looping forever.

[[ -n ${_NEKO_UI_LOADED:-} ]] && return 0
_NEKO_UI_LOADED=1

NEKO_UI_WIDTH=46
UI_LINE=''
UI_DLINE=''
REPLY_CHOICE=''
REPLY_INPUT=''

ui_init() {
  if [[ -t 1 && -z ${NO_COLOR:-} && ${NEKO_NO_COLOR:-0} != 1 ]]; then
    C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m'
    C_MAGENTA=$'\e[35m' C_CYAN=$'\e[36m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RESET=$'\e[0m'
  else
    C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_MAGENTA='' C_CYAN='' C_BOLD='' C_DIM='' C_RESET=''
  fi
  UI_LINE=$(ui_repeat '━' "$NEKO_UI_WIDTH")
  UI_DLINE=$(ui_repeat '═' "$NEKO_UI_WIDTH")
}

ui_repeat() {
  local s=$1 n=$2 out='' i
  for ((i = 0; i < n; i++)); do out+=$s; done
  printf '%s' "$out"
}

# Display width of a string: ASCII = 1 column, CJK (3-byte UTF-8) = 2 columns.
ui_strwidth() {
  local s=$1 chars bytes
  chars=${#s}
  bytes=$(LC_ALL=C; printf '%s' "${#s}")
  printf '%d' $((chars + (bytes - chars) / 2))
}

ui_pad() { # ui_pad <text> <width>: left-aligned, padded by display width
  local w
  w=$(ui_strwidth "$1")
  printf '%s%*s' "$1" $(($2 > w ? $2 - w : 0)) ''
}

ui_box() { # ui_box <line>...
  local line w pl pr
  printf '%s╔%s╗%s\n' "$C_CYAN" "$UI_DLINE" "$C_RESET"
  for line in "$@"; do
    w=$(ui_strwidth "$line")
    pl=$(((NEKO_UI_WIDTH - w) / 2))
    ((pl < 0)) && pl=0
    pr=$((NEKO_UI_WIDTH - w - pl))
    ((pr < 0)) && pr=0
    printf '%s║%s%*s%s%s%s%*s%s║%s\n' "$C_CYAN" "$C_RESET" "$pl" '' "$C_BOLD" "$line" "$C_RESET" "$pr" '' "$C_CYAN" "$C_RESET"
  done
  printf '%s╚%s╝%s\n' "$C_CYAN" "$UI_DLINE" "$C_RESET"
}

ui_line() { printf '%s%s%s\n' "$C_CYAN" "$UI_LINE" "$C_RESET"; }

ui_header() { # ui_header <title>
  local w pl
  w=$(ui_strwidth "$1")
  pl=$(((NEKO_UI_WIDTH - w) / 2))
  ((pl < 0)) && pl=0
  echo
  ui_line
  printf '%*s%s%s%s\n' "$pl" '' "$C_BOLD" "$1" "$C_RESET"
  ui_line
}

ui_section() { printf '\n%s▸ %s%s\n' "$C_BOLD" "$1" "$C_RESET"; }

ui_info() { printf '%s[信息]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ui_ok() { printf '%s[成功]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
ui_warn() { printf '%s[警告]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
ui_err() { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*"; }
ui_note() { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

ui_kv() { # ui_kv <key> <value> [key width]
  printf '  %s：%s\n' "$(ui_pad "$1" "${3:-14}")" "$2"
}

ui_item() { # ui_item <number> <text>
  printf ' %s%2s.%s %s\n' "$C_GREEN" "$1" "$C_RESET" "$2"
}

# Colorize a status word for reports.
ui_status() { # ui_status <good|warn|bad|info> <text>
  case $1 in
    good) printf '%s%s%s' "$C_GREEN" "$2" "$C_RESET" ;;
    warn) printf '%s%s%s' "$C_YELLOW" "$2" "$C_RESET" ;;
    bad) printf '%s%s%s' "$C_RED" "$2" "$C_RESET" ;;
    *) printf '%s' "$2" ;;
  esac
}

# ui_read_choice <max>: reads a menu number into REPLY_CHOICE.
# Returns 1 on EOF (REPLY_CHOICE=0) so callers can unwind.
ui_read_choice() {
  local max=$1 ans
  while true; do
    printf '\n请输入数字 [0-%d]：' "$max"
    if ! IFS= read -r ans; then
      echo
      REPLY_CHOICE=0
      return 1
    fi
    ans=$(trim "$ans")
    if [[ $ans =~ ^[0-9]{1,3}$ ]] && ((10#$ans <= max)); then
      REPLY_CHOICE=$((10#$ans))
      return 0
    fi
    ui_warn "无效输入，请输入 0 到 ${max} 之间的数字。"
  done
}

# ui_confirm <question> [y|n default]
ui_confirm() {
  local q=$1 def=${2:-n} ans hint='y/N'
  [[ $def == y ]] && hint='Y/n'
  printf '%s [%s]：' "$q" "$hint"
  if ! IFS= read -r ans; then
    echo
    return 1
  fi
  ans=$(trim "${ans,,}")
  [[ -z $ans ]] && ans=$def
  [[ $ans == y || $ans == yes || $ans == 是 ]]
}

# ui_prompt <label> [default]: reads a line into REPLY_INPUT. Returns 1 on EOF.
ui_prompt() {
  local label=$1 def=${2:-} ans
  if [[ -n $def ]]; then
    printf '%s [默认 %s]：' "$label" "$def"
  else
    printf '%s：' "$label"
  fi
  if ! IFS= read -r ans; then
    echo
    REPLY_INPUT=''
    return 1
  fi
  ans=$(trim "$ans")
  REPLY_INPUT=${ans:-$def}
  return 0
}

ui_pause() {
  [[ ${NEKO_NO_PAUSE:-0} == 1 ]] && return 0
  printf '\n%s按回车键返回...%s' "$C_DIM" "$C_RESET"
  IFS= read -r _ || echo
}

ui_back_item() { # ui_back_item [text]
  ui_line
  ui_item 0 "${1:-返回主菜单}"
  ui_line
}
