# shellcheck shell=bash
# Neko - proxy service detection (sing-box, Xray Core). Strictly read-only:
# Neko never installs, starts, stops, restarts or edits proxy services.
#
# Installation, run state and configuration state are tracked separately so
# that "not installed" is never reported as "stopped".

[[ -n ${_NEKO_PROXY_LOADED:-} ]] && return 0
_NEKO_PROXY_LOADED=1

PROXY_CORES=(singbox xray)
declare -gA PX_LABEL=([singbox]='sing-box' [xray]='Xray Core')
declare -gA PX_BIN_NAMES=([singbox]='sing-box' [xray]='xray')
declare -gA PX_BIN_PATHS=(
  [singbox]='/usr/bin/sing-box /usr/local/bin/sing-box /etc/s-box/sing-box /etc/sing-box/sing-box /opt/sing-box/sing-box'
  [xray]='/usr/local/bin/xray /usr/bin/xray /etc/xray/xray /usr/local/x-ui/bin/xray-linux-amd64 /usr/local/x-ui/bin/xray-linux-arm64'
)
declare -gA PX_UNITS=([singbox]='sing-box' [xray]='xray x-ui')
declare -gA PX_PROCS=([singbox]='sing-box' [xray]='xray xray-linux-*')
declare -gA PX_DEFAULT_CONF=(
  [singbox]='/etc/sing-box/config.json /usr/local/etc/sing-box/config.json /etc/s-box/sb.json /etc/sing-box/conf'
  [xray]='/usr/local/etc/xray/config.json /etc/xray/config.json /usr/local/x-ui/bin/config.json'
)
OTHER_PROXY_PROCS=(hysteria tuic-server mihomo clash v2ray trojan-go naive juicity-server shadowsocks-rust ssserver ss-server)

# Scan results
declare -gA PX_STATE=() PX_BIN=() PX_UNIT=() PX_UNIT_STATE=() PX_PIDS=() PX_VERSION=()
declare -gA PX_CONF_STATE=() PX_CONF_MSG=() PX_CONF_FILES=() PX_CONF_SRC=() PX_INBOUNDS=() PX_PORTS=()
PX_OTHER=()
PX_SCANNED=0

# ------------------------------------------------------------ JSON loading -
# Both cores accept // and /* */ comments in JSON configs; jq does not.
json_strip_comments() {
  awk '
    BEGIN { blk = 0 }
    {
      line = $0; out = ""; n = length(line); i = 1; str = 0; esc = 0
      while (i <= n) {
        c = substr(line, i, 1)
        if (blk) { if (c == "*" && substr(line, i + 1, 1) == "/") { blk = 0; i += 2 } else i++; continue }
        if (str) {
          out = out c
          if (esc) esc = 0; else if (c == "\\") esc = 1; else if (c == "\"") str = 0
          i++; continue
        }
        if (c == "\"") { str = 1; out = out c; i++; continue }
        if (c == "/" && substr(line, i + 1, 1) == "/") break
        if (c == "/" && substr(line, i + 1, 1) == "*") { blk = 1; i += 2; continue }
        out = out c; i++
      }
      print out
    }' "$1"
}

# json_load <real path>: prints compact JSON or returns 1 (message in JSON_ERR)
JSON_ERR=''
json_load() {
  local f=$1 out
  JSON_ERR=''
  if out=$(jq -c . "$f" 2>/dev/null); then
    printf '%s' "$out"
    return 0
  fi
  if out=$(json_strip_comments "$f" | jq -c . 2>&1); then
    printf '%s' "$out"
    return 0
  fi
  JSON_ERR=$(printf '%s' "$out" | head -n 1)
  return 1
}

# ------------------------------------------------------------ discovery ----
# Extract config files / directories from a command line.
# Output lines: "file <path>" or "dir <path>".
px_args_configs() { # px_args_configs <core> <command line>
  local core=$1 cmd=$2 tok next='' wd=''
  local -a toks out=()
  read -ra toks <<<"$cmd"
  for tok in "${toks[@]}"; do
    if [[ -n $next ]]; then
      case $next in
        wd) wd=$tok ;;
        *) out+=("$next $tok") ;;
      esac
      next=''
      continue
    fi
    case $tok in
      -c | --config | -config | --c) next='file' ;;
      -c=* | --config=* | -config=*) out+=("file ${tok#*=}") ;;
      -C | --config-directory | -confdir | --confdir) next=dir ;;
      -C=* | --config-directory=* | -confdir=*) out+=("dir ${tok#*=}") ;;
      -D | --directory) [[ $core == singbox ]] && next=wd ;;
      -D=* | --directory=*) wd=${tok#*=} ;;
    esac
  done
  local e kind p
  for e in "${out[@]}"; do
    kind=${e%% *} p=${e#* }
    p=${p%\"} p=${p#\"}
    [[ $p == /* ]] || p="${wd:-/}/${p}"
    printf '%s %s\n' "$kind" "${p//\/\//\/}"
  done
}

px_find_bin() { # px_find_bin <core>
  local core=$1 p
  p=$(command -v "${PX_BIN_NAMES[$core]}" 2>/dev/null) && { printf '%s' "$p"; return 0; }
  for p in ${PX_BIN_PATHS[$core]}; do
    [[ -x $(sysp "$p") && -f $(sysp "$p") ]] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

px_scan_core() { # px_scan_core <core>
  local core=$1 bin='' unit='' u pids='' pid args p src=''
  PX_BIN[$core]='' PX_UNIT[$core]='' PX_UNIT_STATE[$core]='' PX_PIDS[$core]='' PX_VERSION[$core]=''
  PX_CONF_STATE[$core]='' PX_CONF_MSG[$core]='' PX_CONF_FILES[$core]='' PX_CONF_SRC[$core]='' PX_INBOUNDS[$core]=0 PX_PORTS[$core]=''

  bin=$(px_find_bin "$core") || bin=''
  for u in ${PX_UNITS[$core]}; do
    if svc_exists "$u"; then
      unit=$u
      break
    fi
  done
  local first_args=''
  # shellcheck disable=SC2086
  while IFS=$'\t' read -r pid args; do
    [[ -n $pid ]] || continue
    pids+="${pids:+ }$pid"
    [[ -z $first_args ]] && first_args=$args
  done < <(proc_find ${PX_PROCS[$core]})

  if [[ -z $bin && -n $first_args ]]; then
    bin=${first_args%% *}
  fi
  PX_BIN[$core]=$bin PX_UNIT[$core]=$unit PX_PIDS[$core]=$pids
  [[ -n $unit ]] && PX_UNIT_STATE[$core]=$(svc_state "$unit")

  if [[ -z $bin && -z $unit && -z $pids ]]; then
    PX_STATE[$core]=not_installed
    return 0
  fi
  if [[ -n $pids || ${PX_UNIT_STATE[$core]} == active ]]; then
    PX_STATE[$core]=running
  else
    PX_STATE[$core]=stopped
  fi

  if [[ -n $bin ]]; then
    PX_VERSION[$core]=$(px_version "$core" "$bin")
  fi

  # Config sources: running process > service ExecStart > well-known paths
  local -a cands=()
  if [[ -n $first_args ]]; then
    mapfile -t cands < <(px_args_configs "$core" "$first_args")
    ((${#cands[@]})) && src='进程参数'
  fi
  if ((${#cands[@]} == 0)) && [[ -n $unit ]]; then
    local es
    if es=$(svc_exec_start "$unit"); then
      mapfile -t cands < <(px_args_configs "$core" "$es")
      ((${#cands[@]})) && src="${unit}.service"
    fi
  fi
  if ((${#cands[@]} == 0)); then
    for p in ${PX_DEFAULT_CONF[$core]}; do
      if [[ -d $(sysp "$p") ]]; then
        cands+=("dir $p")
      elif [[ -e $(sysp "$p") ]]; then
        cands+=("file $p")
      fi
    done
    ((${#cands[@]})) && src='默认路径'
  fi
  PX_CONF_SRC[$core]=$src
  px_check_configs "$core" "${cands[@]}"

  local pp=''
  for pid in $pids; do
    p=$(ss_ports_of_pid "$pid") && [[ -n $p ]] && pp+="${pp:+ }$p"
  done
  PX_PORTS[$core]=$pp
}

px_version() { # px_version <core> <bin>
  local out
  if [[ $1 == singbox ]]; then
    out=$(run_timeout 5 "$(sysp_exec "$2")" version 2>/dev/null | head -n 1)
    out=${out#sing-box version }
  else
    out=$(run_timeout 5 "$(sysp_exec "$2")" version 2>/dev/null | head -n 1)
    out=${out#Xray }
    out=${out%% (*}
  fi
  printf '%s' "${out:-未知}"
}

# Executables found through PATH are already real paths; sysroot ones need mapping.
sysp_exec() {
  if [[ -x $1 ]]; then printf '%s' "$1"; else sysp "$1"; fi
}

# Validates every candidate file; fills PX_CONF_* for the core.
px_check_configs() {
  local core=$1 e kind p real f
  shift
  local -a files=() ok=()
  local unreadable=0 bad=0 unsupported=0 msg='' total=0
  for e in "$@"; do
    kind=${e%% *} p=${e#* }
    real=$(sysp "$p")
    if [[ $kind == dir ]]; then
      if [[ ! -d $real ]]; then
        continue
      elif [[ ! -r $real || ! -x $real ]]; then
        unreadable=1 msg="目录 ${p} 无法读取（权限不足）"
        continue
      fi
      for f in "$real"/*.json; do [[ -f $f ]] && files+=("${f#"${NEKO_SYSROOT:-}"}"); done
    else
      [[ -e $real ]] && files+=("$p")
    fi
  done
  for p in "${files[@]}"; do
    real=$(sysp "$p")
    case $p in
      *.yaml | *.yml | *.toml)
        unsupported=1 msg="${p}：暂不支持 YAML/TOML 格式配置"
        continue
        ;;
    esac
    # access(2) can say "readable" while MAC policies or ACLs still deny the
    # read, so actually read one byte.
    if [[ ! -r $real ]] || ! head -c 1 "$real" >/dev/null 2>&1; then
      unreadable=1 msg="${p}：权限不足或文件读取失败"
      continue
    fi
    local json n
    if ! json=$(json_load "$real"); then
      bad=1 msg="${p}：${JSON_ERR:-JSON 格式错误}"
      continue
    fi
    n=$(jq '(.inbounds // []) | length' <<<"$json" 2>/dev/null || echo 0)
    total=$((total + n))
    ok+=("$p")
  done
  PX_INBOUNDS[$core]=$total
  PX_CONF_FILES[$core]=$(printf '%s\n' "${ok[@]}")
  if ((${#ok[@]})); then
    PX_CONF_STATE[$core]=ok
    ((bad || unreadable)) && PX_CONF_MSG[$core]="部分文件未能读取：${msg}"
  elif ((unreadable)); then
    PX_CONF_STATE[$core]=unreadable PX_CONF_MSG[$core]=$msg
  elif ((bad)); then
    PX_CONF_STATE[$core]=parse_error PX_CONF_MSG[$core]=$msg
  elif ((unsupported)); then
    PX_CONF_STATE[$core]=parse_error PX_CONF_MSG[$core]=$msg
  else
    PX_CONF_STATE[$core]=missing
  fi
}

proxy_scan() {
  local core
  for core in "${PROXY_CORES[@]}"; do px_scan_core "$core"; done
  PX_OTHER=()
  local p
  for p in "${OTHER_PROXY_PROCS[@]}"; do
    [[ -n $(proc_find "$p") ]] && PX_OTHER+=("$p")
  done
  PX_SCANNED=1
}

proxy_any_installed() {
  local core
  for core in "${PROXY_CORES[@]}"; do
    [[ ${PX_STATE[$core]} != not_installed ]] && return 0
  done
  return 1
}

proxy_any_config_ok() {
  local core
  for core in "${PROXY_CORES[@]}"; do
    [[ ${PX_CONF_STATE[$core]} == ok ]] && return 0
  done
  return 1
}

px_state_text() {
  case $1 in
    not_installed) echo '未安装' ;;
    stopped) ui_status warn '代理服务已安装，但当前未运行' ;;
    running) ui_status good '代理服务正常运行' ;;
  esac
}

px_conf_text() { # px_conf_text <core>
  local core=$1
  case ${PX_CONF_STATE[$core]} in
    ok) ui_status good "可识别（${PX_INBOUNDS[$core]} 个入站）" ;;
    missing) ui_status warn '未找到可识别配置文件' ;;
    unreadable) ui_status bad '配置不可读取（权限不足或文件读取失败）' ;;
    parse_error) ui_status bad '配置解析失败（格式不受支持或存在错误）' ;;
    *) echo '-' ;;
  esac
}

# Optional deep validation with the core's own checker (read-only).
px_config_test() { # px_config_test <core>
  local core=$1 bin f args=() out
  bin=${PX_BIN[$core]}
  [[ -n $bin && ${PX_CONF_STATE[$core]} == ok ]] || return 2
  while IFS= read -r f; do
    [[ -n $f ]] && args+=(-c "$(sysp "$f")")
  done <<<"${PX_CONF_FILES[$core]}"
  if [[ $core == singbox ]]; then
    out=$(run_timeout 15 "$(sysp_exec "$bin")" check "${args[@]}" 2>&1)
  else
    out=$(run_timeout 15 "$(sysp_exec "$bin")" run -test "${args[@]}" 2>&1)
  fi
  local rc=$?
  PX_TEST_OUT=$(log_redact "$(printf '%s' "$out" | tail -n 3)")
  return $rc
}

proxy_report() {
  ((PX_SCANNED)) || proxy_scan
  ui_header "代理服务检测"
  if ! proxy_any_installed; then
    echo
    ui_err "未检测到受支持的代理服务端。"
    echo
    echo "已检查："
    local core
    for core in "${PROXY_CORES[@]}"; do
      printf '  %s：未安装\n' "${PX_LABEL[$core]}"
    done
    echo
    echo "当前 VPS 没有可识别的代理服务端。"
    echo
    echo "代理服务检测及节点导出功能暂不可用。"
    echo
    echo "其他网络优化功能不受影响。"
    ((${#PX_OTHER[@]})) && { echo; ui_note "另检测到：${PX_OTHER[*]}（暂不支持）"; }
    echo
    ui_item 0 返回主菜单
    ui_line
    return 1
  fi
  local core f
  for core in "${PROXY_CORES[@]}"; do
    ui_section "${PX_LABEL[$core]}"
    if [[ ${PX_STATE[$core]} == not_installed ]]; then
      ui_kv "安装状态" "未安装"
      continue
    fi
    ui_kv "安装状态" "已安装${PX_BIN[$core]:+（${PX_BIN[$core]}）}"
    [[ -z ${PX_BIN[$core]} ]] && ui_warn "存在服务单元但未找到可执行文件。"
    [[ -n ${PX_VERSION[$core]} ]] && ui_kv "版本" "${PX_VERSION[$core]}"
    if [[ -n ${PX_UNIT[$core]} ]]; then
      ui_kv "服务" "${PX_UNIT[$core]}.service（${PX_UNIT_STATE[$core]}，$(svc_enabled_state "${PX_UNIT[$core]}")）"
    else
      ui_kv "服务" "未找到 systemd 服务单元"
    fi
    ui_kv "运行状态" "$(px_state_text "${PX_STATE[$core]}")${PX_PIDS[$core]:+（PID ${PX_PIDS[$core]}）}"
    [[ ${PX_STATE[$core]} == running ]] && ui_kv "监听端口" "${PX_PORTS[$core]:-未获取（需 root 或 ss）}"
    ui_kv "配置来源" "${PX_CONF_SRC[$core]:-无}"
    while IFS= read -r f; do [[ -n $f ]] && ui_kv "配置文件" "$f"; done <<<"${PX_CONF_FILES[$core]}"
    ui_kv "配置状态" "$(px_conf_text "$core")"
    [[ -n ${PX_CONF_MSG[$core]} ]] && ui_note "${PX_CONF_MSG[$core]}"
    [[ ${PX_CONF_STATE[$core]} == unreadable ]] && ! is_root && ui_note "代理配置通常仅 root 可读，请使用 sudo neko。"
  done
  ((${#PX_OTHER[@]})) && ui_note "另检测到：${PX_OTHER[*]}（暂不支持解析）"
  return 0
}

proxy_menu() {
  proxy_scan
  if ! proxy_report; then
    while true; do
      ui_read_choice 0 || return 0
      ((REPLY_CHOICE == 0)) && return 0
    done
  fi
  echo
  ui_item 1 "使用内核自带校验器检查配置（sing-box check / xray -test）"
  ui_item 2 "重新扫描"
  ui_back_item
  while true; do
    ui_read_choice 2 || return 0
    case $REPLY_CHOICE in
      0) return 0 ;;
      1)
        local core rc
        for core in "${PROXY_CORES[@]}"; do
          [[ ${PX_CONF_STATE[$core]} == ok && -n ${PX_BIN[$core]} ]] || continue
          px_config_test "$core"
          rc=$?
          if ((rc == 0)); then
            ui_ok "${PX_LABEL[$core]} 配置校验通过。"
          else
            ui_err "${PX_LABEL[$core]} 配置校验未通过：${PX_TEST_OUT}"
          fi
        done
        ;;
      2)
        proxy_scan
        proxy_report
        ;;
    esac
  done
}
