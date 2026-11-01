# shellcheck shell=bash
# Neko - system DNS management.
#
# The change is written through whatever component owns DNS on this host
# (systemd-resolved drop-in, resolvconf head, dhclient supersede, nmcli, or a
# static resolv.conf). Every change is backed up, verified, and protected by an
# automatic rollback timer. Proxy-core internal DNS is shown but never touched.

[[ -n ${_NEKO_DNS_LOADED:-} ]] && return 0
_NEKO_DNS_LOADED=1

NEKO_RESOLVED_DROPIN=/etc/systemd/resolved.conf.d/99-neko-dns.conf
DNS_BLOCK_BEGIN='# BEGIN NEKO DNS (managed by neko, do not edit)'
DNS_BLOCK_END='# END NEKO DNS'

DNS_SEL_NAME='' DNS_SEL_V4=() DNS_SEL_V6=() DNS_SEL_DOT=''

dns_providers() { grep -v '^#' "$NEKO_HOME/data/dns-providers.tsv" 2>/dev/null; }

# ------------------------------------------------------------ status -------
dns_status() {
  ui_header "DNS 状态"
  dns_detect
  dns_report
  dns_proxy_internal_report
  dns_manager_advice
}

dns_manager_advice() {
  case $DNS_MANAGER in
    systemd-resolved) ui_note "Neko 将通过 ${NEKO_RESOLVED_DROPIN} 设置全局 DNS，不直接改写 resolv.conf。" ;;
    resolvconf) ui_note "Neko 将通过 resolvconf 配置（head / resolvconf.conf）写入，并执行 resolvconf -u。" ;;
    NetworkManager) ui_note "Neko 将通过 nmcli 修改当前连接的 DNS 并 reapply，不重启 NetworkManager。" ;;
    dhclient) ui_note "Neko 将在 dhclient.conf 中写入 supersede 规则，防止续租时覆盖，并同步更新 resolv.conf。" ;;
    static) ui_note "resolv.conf 为普通文件且无管理程序，Neko 将备份后重写（保留 search/options）。" ;;
    dhcpcd) ui_warn "dhcpcd 管理 DNS：Neko 暂不支持自动修改，请在 /etc/dhcpcd.conf 中设置 static domain_name_servers。" ;;
    *) ui_warn "无法识别 DNS 管理方式，Neko 不会自动修改 DNS，以免被覆盖或破坏解析。" ;;
  esac
  ((${#DNS_NETPLAN_FILES[@]})) && ui_note "netplan 中的 nameservers 设置不会被修改；如与 Neko 设置冲突，以链路 DNS 与全局 DNS 共同生效。"
}

# Internal DNS of the proxy cores: reported separately, never modified.
dns_proxy_internal_report() {
  has_cmd jq || return 0
  ((PX_SCANNED)) || proxy_scan >/dev/null 2>&1
  local core f json servers shown=0
  for core in "${PROXY_CORES[@]}"; do
    [[ ${PX_CONF_STATE[$core]} == ok ]] || continue
    while IFS= read -r f; do
      [[ -n $f ]] || continue
      json=$(json_load "$(sysp "$f")") || continue
      servers=$(jq -r '[(.dns.servers // [])[] | if type == "string" then .
        else (.address // ((.type // "") + "://" + (.server // "")) ) end] | join(", ")' <<<"$json" 2>/dev/null)
      [[ -n $servers ]] || continue
      ((shown++)) || ui_section "代理核心内部 DNS（与系统 DNS 分开管理，Neko 不修改）"
      ui_kv "${PX_LABEL[$core]}" "$servers"
    done <<<"${PX_CONF_FILES[$core]}"
  done
}

# ------------------------------------------------------------ selection ----
dns_select() {
  ui_header "选择 DNS 服务商"
  local -a names=() v4s=() v6s=() dots=()
  local name v4 v6 dot _doh i
  while IFS=$'\t' read -r name v4 v6 dot _doh; do
    [[ -n $name ]] || continue
    names+=("$name") v4s+=("$v4") v6s+=("$v6") dots+=("$dot")
  done < <(dns_providers)
  for i in "${!names[@]}"; do
    ui_item $((i + 1)) "$(ui_pad "${names[i]}" 12) ${v4s[i]}"
  done
  ui_item $((${#names[@]} + 1)) "自定义 DNS"
  ui_back_item 返回
  ui_read_choice $((${#names[@]} + 1)) || return 1
  ((REPLY_CHOICE == 0)) && return 1
  DNS_SEL_V4=() DNS_SEL_V6=() DNS_SEL_DOT=''
  if ((REPLY_CHOICE <= ${#names[@]})); then
    i=$((REPLY_CHOICE - 1))
    DNS_SEL_NAME=${names[i]} DNS_SEL_DOT=${dots[i]}
    read -ra DNS_SEL_V4 <<<"${v4s[i]}"
    local -a six=()
    read -ra six <<<"${v6s[i]}"
    local def=n
    net_has_default_v6 && def=y
    if ui_confirm "是否同时配置 IPv6 DNS（${six[*]}）？" "$def"; then
      DNS_SEL_V6=("${six[@]}")
    fi
  else
    DNS_SEL_NAME=自定义
    ui_prompt "输入 DNS 服务器（IPv4/IPv6，空格分隔，最多 3 个）" || return 1
    local s
    local -a toks=()
    read -ra toks <<<"$REPLY_INPUT"
    for s in "${toks[@]}"; do
      if validate_ipv4 "$s"; then
        DNS_SEL_V4+=("$s")
      elif validate_ipv6 "$s"; then
        DNS_SEL_V6+=("$s")
      else
        ui_err "无效的 IP 地址：${s}"
        return 1
      fi
    done
    ((${#DNS_SEL_V4[@]} + ${#DNS_SEL_V6[@]} > 0)) || { ui_err "未输入 DNS 服务器。"; return 1; }
    ui_prompt "DoT 证书主机名（不使用 DoT 可留空）" || return 1
    if [[ -n $REPLY_INPUT ]]; then
      validate_domain "$REPLY_INPUT" || { ui_err "无效的主机名。"; return 1; }
      DNS_SEL_DOT=$REPLY_INPUT
    fi
  fi
  return 0
}

dns_selected_list() { # up to 3 entries (glibc MAXNS), IPv4 first
  local -a all=("${DNS_SEL_V4[@]}" "${DNS_SEL_V6[@]}")
  if ((${#DNS_SEL_V6[@]} && ${#DNS_SEL_V4[@]} >= 2)); then
    all=("${DNS_SEL_V4[0]}" "${DNS_SEL_V4[1]}" "${DNS_SEL_V6[0]}")
  fi
  printf '%s\n' "${all[@]:0:3}"
}

# ------------------------------------------------------------ writers ------
# Replaces (or appends) the Neko block in a file, content read from stdin.
managed_block_write() { # managed_block_write <system path>
  local f tmp content
  f=$(sysp "$1")
  content=$(cat)
  mkdir -p "$(dirname "$f")" || return 1
  tmp=$(mktemp "${f}.neko.XXXXXX") || return 1
  if [[ -f $f ]]; then
    awk -v b="$DNS_BLOCK_BEGIN" -v e="$DNS_BLOCK_END" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' "$f" >"$tmp"
    chmod --reference="$f" "$tmp" 2>/dev/null || chmod 644 "$tmp"
  else
    chmod 644 "$tmp"
  fi
  if [[ -n $content ]]; then
    {
      printf '%s\n' "$DNS_BLOCK_BEGIN"
      printf '%s\n' "$content"
      printf '%s\n' "$DNS_BLOCK_END"
    } >>"$tmp"
  fi
  mv -f "$tmp" "$f"
}

dns_write_static_resolv() { # dns_write_static_resolv <server>...
  local f tmp s
  f=$(sysp /etc/resolv.conf)
  dns_parse_resolv "$f" 2>/dev/null
  local search=$DNS_SEARCH options=$DNS_OPTIONS
  tmp=$(mktemp "$(dirname "$f")/.resolv.neko.XXXXXX") || return 1
  {
    echo "# Generated by Neko VPS Network Optimizer ${NEKO_VERSION:-}"
    echo "# Previous version is backed up; restore with: neko -> 4 -> 恢复 DNS"
    for s in "$@"; do echo "nameserver $s"; done
    [[ -n $search ]] && echo "search $search"
    [[ -n $options ]] && echo "options $options"
  } >"$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$f" # replaces a symlink rather than writing through it
}

dns_write_resolved() { # dns_write_resolved <dot: no|yes|opportunistic> <server>...
  local dot=$1 f tmp s list=''
  shift
  for s in "$@"; do
    if [[ $dot != no && -n $DNS_SEL_DOT ]]; then list+="${list:+ }${s}#${DNS_SEL_DOT}"; else list+="${list:+ }$s"; fi
  done
  f=$(sysp "$NEKO_RESOLVED_DROPIN")
  mkdir -p "$(dirname "$f")" || return 1
  tmp=$(mktemp "${f}.XXXXXX") || return 1
  {
    echo "# Generated by Neko VPS Network Optimizer ${NEKO_VERSION:-}"
    echo "[Resolve]"
    echo "DNS=$list"
    echo "Domains=~."
    echo "DNSOverTLS=$dot"
  } >"$tmp"
  chmod 644 "$tmp" && mv -f "$tmp" "$f"
}

dns_nm_connection() { # active NetworkManager connection of the default interface
  local dev con
  dev=$(net_default_iface) || return 1
  con=$(nmcli -g GENERAL.CONNECTION device show "$dev" 2>/dev/null | head -n 1)
  [[ -n $con && $con != -- ]] || return 1
  printf '%s\t%s' "$dev" "$con"
}

# ------------------------------------------------------------ verify -------
dns_verify() {
  local host
  host=$(config_get TEST_HOST www.cloudflare.com)
  if has_cmd getent; then
    run_timeout 8 getent ahosts "$host" >/dev/null 2>&1 && return 0
  fi
  if has_cmd resolvectl && [[ $DNS_MANAGER == systemd-resolved ]]; then
    run_timeout 8 resolvectl query "$host" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# ------------------------------------------------------------ apply --------
# dns_apply <dot: no|yes|opportunistic>
dns_apply() {
  local dot=${1:-no}
  require_root "修改 DNS" || return 1
  sys_allow_modify || return 1
  dns_detect
  local -a servers=()
  mapfile -t servers < <(dns_selected_list)
  ((${#servers[@]})) || { ui_err "没有选择 DNS 服务器。"; return 1; }

  case $DNS_MANAGER in
    systemd-resolved | static | dhclient | resolvconf | NetworkManager) ;;
    *)
      ui_err "当前 DNS 管理方式（$(dns_manager_label)）不支持自动修改。"
      dns_manager_advice
      return 1
      ;;
  esac
  if [[ $dot != no && $DNS_MANAGER != systemd-resolved ]]; then
    ui_err "DoT 需要 systemd-resolved，当前 DNS 由 $(dns_manager_label) 管理。"
    return 1
  fi
  if ((DNS_IMMUTABLE)); then
    ui_err "/etc/resolv.conf 设置了 immutable（chattr +i）属性，可能由服务商或其他脚本锁定。"
    ui_note "Neko 不会自动解除该属性；如确认需要修改，请先执行 chattr -i /etc/resolv.conf。"
    return 1
  fi

  ui_section "DNS 变更预览"
  ui_kv "管理方式" "$(dns_manager_label)"
  ui_kv "当前 DNS" "$(dns_summary)"
  ui_kv "目标 DNS" "${DNS_SEL_NAME}：${servers[*]}"
  ui_kv "DoT" "$dot"
  case $DNS_MANAGER in
    systemd-resolved) ui_kv "写入" "$NEKO_RESOLVED_DROPIN，并重启 systemd-resolved" ;;
    static) ui_kv "写入" "/etc/resolv.conf" ;;
    dhclient) ui_kv "写入" "/etc/dhcp/dhclient.conf（supersede）与 /etc/resolv.conf" ;;
    resolvconf) ui_kv "写入" "resolvconf 配置，并执行 resolvconf -u" ;;
    NetworkManager) ui_kv "执行" "nmcli connection modify + device reapply" ;;
  esac
  ui_note "修改前自动备份；验证失败或 $(config_get GUARD_TIMEOUT 120) 秒内未确认将自动回滚。"
  ui_confirm "确认修改系统 DNS 吗？" n || { ui_info "已取消，未做任何修改。"; return 1; }

  neko_lock || return 1
  backup_begin "dns-set" "DNS → ${DNS_SEL_NAME}（${servers[*]}，DoT ${dot}）" || { neko_unlock; return 1; }
  local tx=$BK_TX_ID ok=1
  case $DNS_MANAGER in
    systemd-resolved)
      backup_add_file "$NEKO_RESOLVED_DROPIN" && backup_add_hook resolved-restart &&
        dns_write_resolved "$dot" "${servers[@]}" &&
        systemctl restart systemd-resolved >/dev/null 2>&1 || ok=0
      ;;
    static)
      backup_add_file /etc/resolv.conf && dns_write_static_resolv "${servers[@]}" || ok=0
      ;;
    dhclient)
      local v4list v6list block
      v4list=$(printf '%s, ' "${DNS_SEL_V4[@]}")
      v6list=$(printf '%s, ' "${DNS_SEL_V6[@]}")
      block=''
      ((${#DNS_SEL_V4[@]})) && block+="supersede domain-name-servers ${v4list%, };"
      ((${#DNS_SEL_V6[@]})) && block+="${block:+$'\n'}supersede dhcp6.name-servers ${v6list%, };"
      backup_add_file /etc/dhcp/dhclient.conf && backup_add_file /etc/resolv.conf &&
        managed_block_write /etc/dhcp/dhclient.conf <<<"$block" &&
        dns_write_static_resolv "${servers[@]}" || ok=0
      ;;
    resolvconf)
      local s content=''
      backup_add_hook resolvconf-update
      if [[ $DNS_RESOLVCONF_FLAVOR == openresolv ]]; then
        content="name_servers=\"${servers[*]}\""
        backup_add_file /etc/resolvconf.conf && managed_block_write /etc/resolvconf.conf <<<"$content" || ok=0
      else
        for s in "${servers[@]}"; do content+="${content:+$'\n'}nameserver $s"; done
        backup_add_file /etc/resolvconf/resolv.conf.d/head &&
          managed_block_write /etc/resolvconf/resolv.conf.d/head <<<"$content" || ok=0
      fi
      ((ok)) && { resolvconf -u >/dev/null 2>&1 || ok=0; }
      ;;
    NetworkManager)
      local pair dev con old4 oldign4 old6 oldign6
      if ! pair=$(dns_nm_connection); then
        ui_err "无法确定默认网卡对应的 NetworkManager 连接。"
        ok=0
      else
        dev=${pair%%$'\t'*} con=${pair#*$'\t'}
        old4=$(nmcli -g ipv4.dns connection show "$con" 2>/dev/null)
        oldign4=$(nmcli -g ipv4.ignore-auto-dns connection show "$con" 2>/dev/null)
        old6=$(nmcli -g ipv6.dns connection show "$con" 2>/dev/null)
        oldign6=$(nmcli -g ipv6.ignore-auto-dns connection show "$con" 2>/dev/null)
        backup_add_restore "nm-${dev}" nmcli connection modify "$con" \
          ipv4.dns "${old4//\\/}" ipv4.ignore-auto-dns "${oldign4:-no}" \
          ipv6.dns "${old6//\\/}" ipv6.ignore-auto-dns "${oldign6:-no}"
        backup_add_restore "nm-${dev}" nmcli device reapply "$dev"
        local -a args=(connection modify "$con")
        ((${#DNS_SEL_V4[@]})) && args+=(ipv4.dns "${DNS_SEL_V4[*]}" ipv4.ignore-auto-dns yes)
        ((${#DNS_SEL_V6[@]})) && args+=(ipv6.dns "${DNS_SEL_V6[*]}" ipv6.ignore-auto-dns yes)
        nmcli "${args[@]}" >/dev/null 2>&1 && nmcli device reapply "$dev" >/dev/null 2>&1 || ok=0
      fi
      ;;
  esac
  backup_commit
  neko_unlock

  if ((!ok)); then
    ui_err "写入 DNS 配置失败，正在自动回滚..."
    backup_restore_to "$tx" auto dns
    return 1
  fi
  sleep "${NEKO_DNS_SETTLE:-1}"
  if ! dns_verify; then
    ui_err "DNS 解析验证失败（$(config_get TEST_HOST www.cloudflare.com) 无法解析），正在自动回滚..."
    log_error "dns verify failed after tx ${tx}, rolling back"
    backup_restore_to "$tx" auto dns
    return 1
  fi
  ui_ok "DNS 解析验证通过（变更编号 ${tx}）。"
  guard_confirm "$tx" "$(config_get GUARD_TIMEOUT 120)" || return 1
  log_info "dns set ${DNS_SEL_NAME} ${servers[*]} dot=${dot} tx=${tx}"
}

dns_set_plain() {
  require_root "修改 DNS" || return 1
  dns_select || return 0
  dns_apply no
}

dns_set_dot() {
  ui_header "启用 DoT（DNS over TLS）"
  require_root "启用 DoT" || return 1
  dns_detect
  if [[ $DNS_MANAGER != systemd-resolved ]]; then
    ui_err "DoT 需要 systemd-resolved 管理 DNS，当前为：$(dns_manager_label)。"
    ui_note "Neko 不会擅自切换系统的 DNS 管理方式。"
    return 1
  fi
  ui_note "DoT 使用 TCP 853 端口加密 DNS 查询。若出口屏蔽 853，严格模式将导致解析失败（会被自动回滚）。"
  dns_select || return 0
  [[ -n $DNS_SEL_DOT ]] || { ui_err "未提供 DoT 证书主机名，无法启用严格 DoT。"; return 1; }
  echo
  ui_item 1 "严格模式（DNSOverTLS=yes，证书校验失败即不解析）"
  ui_item 2 "机会模式（DNSOverTLS=opportunistic，失败时降级为明文）"
  ui_back_item 返回
  ui_read_choice 2 || return 0
  case $REPLY_CHOICE in
    1) dns_apply yes ;;
    2) dns_apply opportunistic ;;
  esac
}

dns_doh_info() {
  ui_header "DoH（DNS over HTTPS）"
  dns_detect
  ui_note "systemd-resolved 不支持 DoH。使用 DoH 需要本地转发器（如 dnscrypt-proxy、dnsproxy、AdGuardHome、cloudflared）。"
  ui_note "注意：新版 cloudflared 已弃用 proxy-dns 功能，请以所安装版本的文档为准。Neko 不会自动安装转发器。"
  local lst
  lst=$(ss -Hlnup 2>/dev/null | awk '{n = split($4, a, ":"); if (a[n] == "53") print $4, $0}' | grep -Eo '^[^ ]+|users:\(\("[^"]+"' | paste - - 2>/dev/null)
  if [[ $DNS_DOH != none ]]; then
    ui_ok "检测到本地 DNS 转发程序：${DNS_DOH}"
  else
    ui_info "未检测到本地 DoH 转发程序。"
  fi
  [[ -n $lst ]] && ui_kv "UDP 53 监听" "$(tr '\n\t' ' ' <<<"$lst")"
  if has_cmd curl && ui_confirm "是否测试 Cloudflare DoH（https://cloudflare-dns.com/dns-query）的连通性与耗时？" n; then
    local t
    t=$(curl -s -o /dev/null -m 8 -w '%{http_code} %{time_total}' -H 'accept: application/dns-json' \
      'https://cloudflare-dns.com/dns-query?name=example.com&type=A' 2>/dev/null)
    if [[ ${t%% *} == 200 ]]; then
      ui_ok "DoH 可用，耗时 ${t#* } 秒（含 TLS 握手）。"
    else
      ui_warn "DoH 请求失败（HTTP ${t%% *}）。"
    fi
  fi
  if [[ $DNS_DOH != none ]] && ui_confirm "是否将系统 DNS 指向本机 127.0.0.1 上的转发器？" n; then
    DNS_SEL_NAME="本地 DoH 转发器（${DNS_DOH}）" DNS_SEL_V4=(127.0.0.1) DNS_SEL_V6=() DNS_SEL_DOT=''
    dns_apply no
  fi
}

# ------------------------------------------------------------ latency ------
dns_build_query() { # dns_build_query <name> -> hex
  local name=$1 hex id label l c i
  printf -v id '%04x' $((RANDOM % 65536))
  hex="${id}01000001000000000000"
  local -a labels
  IFS=. read -ra labels <<<"$name"
  for label in "${labels[@]}"; do
    printf -v l '%02x' "${#label}"
    hex+=$l
    for ((i = 0; i < ${#label}; i++)); do
      printf -v c '%02x' "'${label:i:1}"
      hex+=$c
    done
  done
  printf '%s' "${hex}0000010001"
}

# dns_query_ms <server> [name]: query latency in ms over UDP, using dig when
# available and bash /dev/udp otherwise. Prints nothing and fails on timeout.
dns_query_ms() {
  local server=$1 name=${2:-example.com} out t0 t1
  if has_cmd dig; then
    out=$(dig +tries=1 +time=2 @"$server" "$name" A 2>/dev/null | awk '/Query time:/ {print $4}')
    [[ -n $out ]] && { printf '%s' "$out"; return 0; }
    return 1
  fi
  local q
  q=$(dns_build_query "$name")
  t0=$(now_ms)
  # shellcheck disable=SC2016
  if run_timeout 3 bash -c 'exec 3<>"/dev/udp/$1/53" || exit 1; printf "$2" >&3; IFS= read -r -t 2 -N 1 _ <&3' _ "$server" "$(dns_hex_fmt "$q")" 2>/dev/null; then
    t1=$(now_ms)
    printf '%s' $((t1 - t0))
    return 0
  fi
  return 1
}

dns_hex_fmt() { # hex -> printf format string of \xHH escapes (single write = single datagram)
  local hex=$1 i fmt=''
  for ((i = 0; i < ${#hex}; i += 2)); do fmt+="\\x${hex:i:2}"; done
  printf '%s' "$fmt"
}

dns_latency_test() {
  ui_header "DNS 延迟测试"
  local name
  name=$(config_get TEST_HOST www.cloudflare.com)
  ui_note "每个服务器发送 3 次 A 记录查询（${name}），每次约 100 字节流量。"
  has_cmd dig || ui_note "未安装 dnsutils（dig），使用内置 UDP 查询测量。"
  dns_detect
  local -a targets=()
  local s _n v4 v6 _d _h
  for s in "${DNS_NAMESERVERS[@]}"; do targets+=("$s|当前系统"); done
  while IFS=$'\t' read -r _n v4 v6 _d _h; do
    for s in $v4; do targets+=("$s|$_n"); done
    if net_has_default_v6; then for s in $v6; do targets+=("$s|$_n"); done; fi
  done < <(dns_providers)
  printf '  %s %s %s\n' "$(ui_pad 服务器 28)" "$(ui_pad 来源 12)" "延迟（3 次）"
  local entry srv label i ms res best
  for entry in "${targets[@]}"; do
    srv=${entry%%|*} label=${entry#*|}
    res='' best=''
    for i in 1 2 3; do
      if ms=$(dns_query_ms "$srv" "$name"); then
        res+="${ms}ms "
        [[ -z $best || $ms -lt $best ]] && best=$ms
      else
        res+="超时 "
      fi
    done
    printf '  %s %s %s\n' "$(ui_pad "$srv" 28)" "$(ui_pad "$label" 12)" "$res"
  done
  if has_cmd getent; then
    local t0 t1
    t0=$(now_ms)
    if run_timeout 5 getent ahosts "$name" >/dev/null 2>&1; then
      t1=$(now_ms)
      ui_kv "系统解析器" "$((t1 - t0))ms（含缓存，getent ahosts）"
    else
      ui_kv "系统解析器" "$(ui_status bad 解析失败)"
    fi
  fi
  if has_cmd timeout; then
    local dot t0 t1
    for dot in 1.1.1.1 8.8.8.8 9.9.9.9; do
      t0=$(now_ms)
      if timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/853"' _ "$dot" 2>/dev/null; then
        t1=$(now_ms)
        ui_kv "DoT ${dot}:853" "TCP 连接 $((t1 - t0))ms"
      else
        ui_kv "DoT ${dot}:853" "$(ui_status bad 无法连接（853 可能被屏蔽）)"
      fi
    done
  fi
}

# ------------------------------------------------------------ restore ------
dns_restore() {
  ui_header "恢复 DNS 配置"
  require_root "恢复 DNS" || return 1
  local -a ids=()
  local id label
  while IFS=$'\t' read -r id _ _ label _; do
    [[ $label == dns-* ]] && ids+=("$id")
  done <"$(backup_history_file)" 2>/dev/null
  if ((${#ids[@]} == 0)); then
    ui_info "没有 Neko 的 DNS 修改记录，当前 DNS 未被 Neko 修改过。"
    return 0
  fi
  ui_item 1 "撤销最近一次 DNS 修改（${ids[-1]}）"
  ui_item 2 "恢复到 Neko 首次修改 DNS 之前（${ids[0]}）"
  ui_back_item 返回
  ui_read_choice 2 || return 0
  case $REPLY_CHOICE in
    1) backup_restore_to "${ids[-1]}" interactive dns ;;
    2) backup_restore_to "${ids[0]}" interactive dns ;;
  esac
  dns_detect
  if dns_verify; then ui_ok "DNS 解析正常。"; else ui_warn "当前 DNS 解析验证失败，请检查。"; fi
}

dns_menu() {
  while true; do
    dns_detect
    ui_header "DNS 管理"
    ui_kv "管理方式" "$(dns_manager_label)"
    ui_kv "当前 DNS" "$(dns_summary)"
    ui_kv "DoT" "$(dns_dot_label)"
    echo
    ui_item 1 "查看 DNS 状态"
    ui_item 2 "设置系统 DNS（Cloudflare / Google / Quad9 / 自定义）"
    ui_item 3 "启用 DoT（DNS over TLS）"
    ui_item 4 "DoH 检测与本地转发器"
    ui_item 5 "DNS 延迟测试"
    ui_item 6 "恢复 DNS 配置"
    ui_back_item
    ui_read_choice 6 || return 0
    case $REPLY_CHOICE in
      0) return 0 ;;
      1) dns_status ;;
      2) dns_set_plain ;;
      3) dns_set_dot ;;
      4) dns_doh_info ;;
      5) dns_latency_test ;;
      6) dns_restore ;;
    esac
    ui_pause
  done
}
