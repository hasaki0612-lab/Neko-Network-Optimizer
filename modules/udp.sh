# shellcheck shell=bash
# Neko - UDP diagnostics and buffer tuning (QUIC, Hysteria 2, TUIC).

[[ -n ${_NEKO_UDP_LOADED:-} ]] && return 0
_NEKO_UDP_LOADED=1

# quic-go (used by Hysteria 2, sing-box QUIC, Xray QUIC/XHTTP-H3) asks for at
# least ~7.5 MB socket buffers; below that it logs "failed to sufficiently
# increase receive buffer size".
UDP_QUIC_MIN_BUF=$(awk -F= '$1 == "net.core.rmem_max" { print $2 }' "${NEKO_HOME:-.}/data/profiles/quic-udp.conf" 2>/dev/null)
[[ $UDP_QUIC_MIN_BUF =~ ^[0-9]+$ ]] || UDP_QUIC_MIN_BUF=7500000

declare -gA UDP_STAT=()

# Reads Udp: / Udp6 counters into UDP_STAT[Udp.InDatagrams] etc.
udp_read_stats() {
  UDP_STAT=()
  local f h v i
  f=$(sysp /proc/net/snmp)
  if [[ -r $f ]]; then
    local -a hdr=() val=()
    while read -r h v; do
      [[ $h == Udp: ]] || continue
      if ((${#hdr[@]} == 0)); then read -ra hdr <<<"$v"; else read -ra val <<<"$v"; fi
    done <"$f"
    for i in "${!hdr[@]}"; do UDP_STAT[Udp.${hdr[i]}]=${val[i]:-0}; done
  fi
  f=$(sysp /proc/net/snmp6)
  if [[ -r $f ]]; then
    while read -r h v; do
      [[ $h == Udp6* ]] && UDP_STAT[Udp6.${h#Udp6}]=$v
    done <"$f"
  fi
  ((${#UDP_STAT[@]}))
}

udp_stat() { printf '%s' "${UDP_STAT[$1]:-0}"; }

udp_status() {
  ui_header "UDP 状态与统计"
  ui_section "缓冲区参数"
  local k
  for k in net.core.rmem_max net.core.wmem_max net.core.rmem_default net.core.wmem_default net.ipv4.udp_mem net.ipv4.udp_rmem_min net.ipv4.udp_wmem_min; do
    ui_kv "$k" "$(sysctl_get "$k" || echo 无法读取)" 26
  done
  local rmax
  rmax=$(num_or "$(sysctl_get net.core.rmem_max)" 0)
  if ((rmax < UDP_QUIC_MIN_BUF)); then
    ui_warn "rmem_max（${rmax}）低于 QUIC 实现建议的 ${UDP_QUIC_MIN_BUF} 字节，高速 QUIC 传输可能丢包。"
  else
    ui_ok "rmem_max 满足 QUIC 建议值（≥ ${UDP_QUIC_MIN_BUF}）。"
  fi

  ui_section "UDP 计数器（自开机累计）"
  if ! udp_read_stats; then
    ui_warn "无法读取 /proc/net/snmp。"
  else
    local fam
    for fam in Udp Udp6; do
      [[ -n ${UDP_STAT[$fam.InDatagrams]+x} ]] || continue
      ui_kv "$fam 收到" "$(udp_stat "$fam.InDatagrams")" 22
      ui_kv "$fam 发送" "$(udp_stat "$fam.OutDatagrams")" 22
      ui_kv "$fam 接收错误" "$(udp_stat "$fam.InErrors")" 22
      ui_kv "$fam 接收缓冲溢出" "$(udp_stat "$fam.RcvbufErrors")" 22
      ui_kv "$fam 发送缓冲溢出" "$(udp_stat "$fam.SndbufErrors")" 22
      ui_kv "$fam 无监听端口" "$(udp_stat "$fam.NoPorts")" 22
    done
    local rb=$(($(udp_stat Udp.RcvbufErrors) + $(udp_stat Udp6.RcvbufErrors)))
    if ((rb > 0)); then
      ui_warn "存在 ${rb} 次接收缓冲区溢出（数据包因缓冲区已满被丢弃），建议增大 UDP 缓冲区。"
    else
      ui_ok "未发现接收缓冲区溢出。"
    fi
  fi

  ui_section "按端口统计的套接字丢包（/proc/net/udp）"
  udp_socket_drops

  if ui_confirm "是否采样 5 秒统计实时增量？" n; then
    udp_sample 5
  fi
}

# Sums the "drops" column of /proc/net/udp{,6} per local port.
udp_socket_drops() {
  local out
  out=$(cat "$(sysp /proc/net/udp)" "$(sysp /proc/net/udp6)" 2>/dev/null | awk '
    $1 ~ /^[0-9]+:$/ {
      split($2, a, ":"); port = strtonum_hex(a[2]); d[port] += $NF
    }
    function strtonum_hex(h,   i, c, n) {
      n = 0; h = toupper(h)
      for (i = 1; i <= length(h); i++) { c = index("0123456789ABCDEF", substr(h, i, 1)) - 1; n = n * 16 + c }
      return n
    }
    END { for (p in d) if (d[p] > 0) printf "%d\t%d\n", p, d[p] }' | sort -n)
  if [[ -z $out ]]; then
    ui_note "没有套接字级丢包记录。"
  else
    local port drops
    while IFS=$'\t' read -r port drops; do ui_kv "UDP 端口 ${port}" "丢弃 ${drops} 个数据包" 18; done <<<"$out"
  fi
}

udp_sample() { # udp_sample <seconds>
  local s=$1 k
  udp_read_stats || return 1
  local -A a=()
  for k in "${!UDP_STAT[@]}"; do a[$k]=${UDP_STAT[$k]}; done
  ui_info "采样中（${s} 秒）..."
  sleep "$s"
  udp_read_stats || return 1
  for k in Udp.InDatagrams Udp.OutDatagrams Udp.RcvbufErrors Udp.SndbufErrors Udp.InErrors Udp6.InDatagrams Udp6.RcvbufErrors; do
    [[ -n ${a[$k]+x} ]] || continue
    local d=$((${UDP_STAT[$k]:-0} - ${a[$k]:-0}))
    ui_kv "$k" "+${d}（$((d / s))/秒）" 22
  done
}

udp_buffer_tune() {
  ui_header "UDP 缓冲区优化"
  require_root "调整 UDP 缓冲区" || return 1
  ui_note "QUIC 协议栈（quic-go 等）在用户态实现，需要较大的套接字缓冲区以承接突发流量。"
  ui_note "该修改提高 net.core.rmem_max / wmem_max 上限（TCP 共用此上限，Neko 不会把已有值调小）。"
  ui_kv "当前 rmem_max" "$(sysctl_get net.core.rmem_max)"
  ui_kv "当前 wmem_max" "$(sysctl_get net.core.wmem_max)"
  echo
  ui_item 1 "标准：7.5 MB（quic-go 建议值，适合 ≤ 500 Mbps）"
  ui_item 2 "高带宽：16 MB（适合 ≥ 1 Gbps 且内存 ≥ 1 GB）"
  ui_item 3 "自定义"
  ui_back_item 返回
  ui_read_choice 3 || return 0
  local want
  case $REPLY_CHOICE in
    0) return 0 ;;
    1) want=$UDP_QUIC_MIN_BUF ;;
    2) want=16777216 ;;
    3)
      ui_prompt "缓冲区字节数（1048576-67108864）" 16777216 || return 0
      want=$REPLY_INPUT
      validate_int_range "$want" 1048576 67108864 || { ui_err "超出范围。"; return 1; }
      ;;
  esac
  local rmax wmax
  rmax=$(num_or "$(sysctl_get net.core.rmem_max)" 0)
  wmax=$(num_or "$(sysctl_get net.core.wmem_max)" 0)
  ((rmax > want)) && ui_note "当前 rmem_max 已大于目标值，保持不变。" && want=$rmax
  local wwant=$want
  ((wmax > wwant)) && wwant=$wmax
  apply_sysctl "udp-buffers" "UDP 缓冲区 → $(human_bytes "$want")" \
    "net.core.rmem_max=$want" "net.core.wmem_max=$wwant"
}

conntrack_status() {
  ui_header "Conntrack 连接跟踪"
  if ! sysctl_exists net.netfilter.nf_conntrack_max; then
    ui_info "nf_conntrack 模块未加载（未启用有状态防火墙/NAT），无需关注。"
    return 0
  fi
  local cnt max pct
  cnt=$(num_or "$(sysctl_get net.netfilter.nf_conntrack_count)" 0)
  max=$(num_or "$(sysctl_get net.netfilter.nf_conntrack_max)" 0)
  ((max > 0)) && pct=$((cnt * 100 / max)) || pct=0
  ui_kv "当前连接数" "$cnt"
  ui_kv "最大连接数" "$max"
  ui_kv "使用率" "${pct}%"
  ui_kv "UDP 超时" "$(sysctl_get net.netfilter.nf_conntrack_udp_timeout || echo ?)s / stream $(sysctl_get net.netfilter.nf_conntrack_udp_timeout_stream || echo ?)s"
  ui_kv "哈希桶" "$(sysctl_get net.netfilter.nf_conntrack_buckets || echo ?)"
  if ((pct >= 80)); then
    ui_warn "连接跟踪表使用率达到 ${pct}%，表满后新连接会被丢弃（dmesg: nf_conntrack: table full）。"
    local mem_cap=$((SYS_MEM_TOTAL_KB * 1024 / 4096)) target=$((max * 2))
    ((target > mem_cap)) && target=$mem_cap
    if ((target > max)) && ui_confirm "是否将 nf_conntrack_max 提高到 ${target}？" n; then
      APPLY_ASSUME_YES=1 apply_sysctl "udp-conntrack" "nf_conntrack_max → ${target}" "net.netfilter.nf_conntrack_max=$target"
    fi
  else
    ui_ok "连接跟踪表容量充足。"
  fi
}

udp_cc_explain() {
  ui_header "拥塞控制机制说明"
  cat <<'EOF'
  1) TCP BBR（内核）
     由 net.ipv4.tcp_congestion_control 决定，只作用于内核 TCP 连接，
     例如 VLESS/Trojan/VMess over TCP。它不影响任何 UDP 流量。

  2) QUIC 拥塞控制（用户态）
     QUIC 运行在 UDP 之上，拥塞控制由程序自身实现，与内核设置无关。
     - TUIC：服务端与客户端的 congestion_control 字段（cubic / new_reno / bbr）
     - Hysteria 2：客户端未声明带宽时使用 BBR（QUIC 层实现）

  3) Brutal（应用层，Hysteria 2）
     客户端声明带宽（up/down）后，Hysteria 2 按该速率固定发送，不因丢包降速。
     带宽填写过高会造成严重丢包与线路拥塞；服务端可用 ignore_client_bandwidth
     强制使用 BBR。

  因此：修改内核 BBR 不会提升 Hysteria 2 / TUIC 的速度；
  对 QUIC 类协议有效的系统侧优化是 UDP 缓冲区、MTU 和防火墙/Conntrack。
EOF
}

udp_menu() {
  while true; do
    ui_header "UDP / QUIC 优化"
    ui_kv "rmem_max" "$(sysctl_get net.core.rmem_max || echo 无法读取)"
    ui_kv "wmem_max" "$(sysctl_get net.core.wmem_max || echo 无法读取)"
    echo
    ui_item 1 "UDP 状态与统计"
    ui_item 2 "UDP 缓冲区优化（QUIC / Hysteria 2 / TUIC）"
    ui_item 3 "Conntrack 连接跟踪"
    ui_item 4 "QUIC 服务专项分析"
    ui_item 5 "拥塞控制机制说明（BBR / QUIC / Brutal）"
    ui_back_item
    ui_read_choice 5 || return 0
    case $REPLY_CHOICE in
      0) return 0 ;;
      1) udp_status ;;
      2) udp_buffer_tune ;;
      3) conntrack_status ;;
      4) quic_analyze ;;
      5) udp_cc_explain ;;
    esac
    ui_pause
  done
}
