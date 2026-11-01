#!/usr/bin/env bash
# Neko - VPS Network Optimizer
#
# Interactive network diagnostics, optimisation and proxy configuration export
# for Linux VPS. Detect first, analyse second; back up before every change.
#
# Usage: neko [--version] [--help] [--report] [--no-color]

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Neko 需要 Bash 运行：bash neko.sh" >&2
  exit 1
fi
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  echo "Neko 需要 Bash 4.4 或更高版本（当前 ${BASH_VERSION}），推荐 Bash 5.x。" >&2
  exit 1
fi

set -o pipefail
set -u

NEKO_HOME=${NEKO_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)}
NEKO_ETC_DIR=${NEKO_ETC_DIR:-/etc/neko}
NEKO_STATE_DIR=${NEKO_STATE_DIR:-/var/lib/neko}
NEKO_LOG_DIR=${NEKO_LOG_DIR:-/var/log/neko}
NEKO_BIN=${NEKO_BIN:-/usr/local/bin/neko}
[[ -x $NEKO_BIN ]] || NEKO_BIN="$NEKO_HOME/neko.sh"
NEKO_VERSION=$(cat "$NEKO_HOME/VERSION" 2>/dev/null || echo 0.1.0)
NEKO_VERSION=${NEKO_VERSION#v}

neko_setup_locale() {
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8* | *utf8* | *UTF8* | *utf-8*) return 0 ;;
  esac
  local l
  for l in C.UTF-8 C.utf8 en_US.UTF-8; do
    if locale -a 2>/dev/null | grep -qix "${l/UTF-8/utf8}" || locale -a 2>/dev/null | grep -qix "$l"; then
      export LC_ALL=$l
      return 0
    fi
  done
}

neko_load() {
  local f
  for f in lib/utils.sh lib/ui.sh lib/logger.sh lib/validator.sh \
    core/system.sh core/network.sh core/services.sh core/dns_detect.sh core/backup.sh \
    engine/apply.sh engine/analyzer.sh engine/recommender.sh engine/rollback.sh \
    modules/tcp.sh modules/udp.sh modules/quic.sh modules/dns.sh modules/cdn.sh \
    modules/proxy.sh modules/network_test.sh modules/export.sh; do
    # shellcheck source=/dev/null
    source "$NEKO_HOME/$f" || {
      echo "无法加载 $NEKO_HOME/$f，安装可能已损坏，请重新运行安装器。" >&2
      exit 1
    }
  done
}

neko_check_runtime() {
  local missing=() c
  for c in awk sed grep sort cut tr od base64 sha256sum mktemp; do
    has_cmd "$c" || missing+=("$c")
  done
  if ((${#missing[@]})); then
    ui_err "缺少基础命令：${missing[*]}，请重新运行安装器检查依赖。"
    exit 1
  fi
  has_cmd jq || ui_warn "未安装 jq：代理配置解析与节点导出不可用（apt install jq）。"
  has_cmd ip || ui_warn "未安装 iproute2：部分网络检测不可用（apt install iproute2）。"
}

neko_cleanup() {
  export_cleanup 2>/dev/null
  neko_unlock 2>/dev/null
}

# ------------------------------------------------------------ main menu ----
main_status() {
  ((SYS_DETECTED)) || sys_detect
  dns_detect >/dev/null 2>&1
  local cc q
  cc=$(net_tcp_cc 2>/dev/null) || cc='无法读取'
  q=$(net_default_qdisc 2>/dev/null) || q='无法读取'
  echo
  printf '系统：%s\n' "$SYS_OS_PRETTY"
  printf '内核：%s\n' "$SYS_KERNEL"
  printf '架构：%s\n' "$SYS_ARCH"
  printf '虚拟化：%s\n' "$(sys_virt_label)"
  echo
  printf '网络状态：\n'
  printf 'TCP算法：%s\n' "$cc"
  printf 'Qdisc：%s\n' "$q"
  printf 'DNS：%s\n' "$(dns_summary)"
  printf 'DoT：%s\n' "$(dns_dot_label)"
  if [[ $SYS_SUPPORT != supported ]]; then
    echo
    printf '支持状态：%s\n' "$(sys_support_label)"
  fi
  is_root || printf '\n%s当前为普通用户：只读检测可用，修改配置请使用 sudo neko%s\n' "$C_DIM" "$C_RESET"
}

main_menu() {
  while true; do
    [[ -t 1 && ${NEKO_NO_CLEAR:-0} != 1 ]] && clear
    ui_box "N E K O" "VPS NETWORK OPTIMIZER v${NEKO_VERSION}"
    main_status
    ui_line
    ui_item 1 "系统环境检测"
    ui_item 2 "TCP 网络优化"
    ui_item 3 "UDP / QUIC 优化"
    ui_item 4 "DNS 管理"
    ui_item 5 "CDN / 反向代理优化"
    ui_item 6 "代理服务检测"
    ui_item 7 "网络性能测试"
    ui_item 8 "智能优化建议"
    ui_item 9 "配置备份与回滚"
    ui_item 10 "节点与订阅导出"
    ui_line
    ui_item 0 "退出脚本"
    ui_read_choice 10 || break
    case $REPLY_CHOICE in
      0) break ;;
      1)
        system_detect_menu
        ui_pause
        ;;
      2) tcp_menu ;;
      3) udp_menu ;;
      4) dns_menu ;;
      5) cdn_menu ;;
      6) proxy_menu ;;
      7) network_test_menu ;;
      8)
        recommender_menu
        ui_pause
        ;;
      9) rollback_menu ;;
      10) export_menu ;;
    esac
  done
  echo
  printf '感谢使用 Neko！\n'
}

full_report() {
  ui_box "NEKO SYSTEM REPORT" "v${NEKO_VERSION}  $(date '+%F %T')"
  sys_report
  net_report
  dns_detect
  dns_report
  svc_report_network
  proxy_scan
  ui_section "代理核心"
  local core
  for core in "${PROXY_CORES[@]}"; do
    case ${PX_STATE[$core]} in
      not_installed) ui_kv "${PX_LABEL[$core]}" "未安装" ;;
      *) ui_kv "${PX_LABEL[$core]}" "$(px_state_text "${PX_STATE[$core]}")，版本 ${PX_VERSION[$core]:-未知}，配置 $(px_conf_text "$core")" ;;
    esac
  done
  ((${#PX_OTHER[@]})) && ui_kv "其他" "${PX_OTHER[*]}"
}

system_detect_menu() {
  ui_header "系统环境检测"
  full_report
  echo
  if ui_confirm "是否将报告保存到文件？" n; then
    local dir f
    if is_root; then dir="$NEKO_STATE_DIR/reports"; else dir="${HOME:-/tmp}/neko-reports"; fi
    (umask 077 && mkdir -p "$dir") || { ui_err "无法创建目录 ${dir}"; return 1; }
    printf -v f '%s/report-%(%Y%m%d-%H%M%S)T.txt' "$dir" -1
    (NEKO_NO_COLOR=1 ui_init && full_report) >"$f" 2>&1
    sed -i 's/\x1b\[[0-9;]*m//g' "$f"
    chmod 600 "$f"
    ui_ok "报告已保存：${f}"
  fi
}

usage() {
  cat <<EOF
Neko VPS Network Optimizer v${NEKO_VERSION}

用法：
  neko              启动交互式主菜单
  sudo neko         以管理员身份运行（修改配置需要）
  neko --report     输出系统检测报告（只读）
  neko --version    显示版本
  neko --no-color   禁用彩色输出

数据目录：
  程序 ${NEKO_HOME}
  配置 ${NEKO_ETC_DIR}
  状态 ${NEKO_STATE_DIR}（备份与变更记录）
  日志 ${NEKO_LOG_DIR}
EOF
}

main() {
  neko_setup_locale
  neko_load
  local arg mode=menu guard_tx=''
  while (($#)); do
    arg=$1
    shift
    case $arg in
      -v | --version)
        echo "Neko v${NEKO_VERSION}"
        return 0
        ;;
      -h | --help)
        usage
        return 0
        ;;
      --no-color) NEKO_NO_COLOR=1 ;;
      --report) mode=report ;;
      --guard-rollback)
        mode=guard
        guard_tx=${1:-}
        shift || true
        ;;
      *)
        echo "未知参数：$arg（使用 --help 查看用法）" >&2
        return 2
        ;;
    esac
  done
  ui_init
  log_init
  config_load
  trap neko_cleanup EXIT
  trap 'echo; exit 130' INT TERM
  case $mode in
    guard)
      NEKO_NO_COLOR=1
      ui_init
      guard_fire "$guard_tx"
      return $?
      ;;
    report)
      neko_check_runtime
      full_report
      return 0
      ;;
  esac
  neko_check_runtime
  log_info "neko ${NEKO_VERSION} started (euid $(neko_euid))"
  sys_detect
  main_menu
}

# Run only when executed (the test-suite sources this file).
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
