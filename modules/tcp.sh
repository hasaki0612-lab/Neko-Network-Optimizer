# shellcheck shell=bash
# Neko - TCP optimisation: congestion control, qdisc, buffers, TFO, ECN,
# MTU probing and keepalive. Kernel capabilities are checked first; Neko never
# installs third-party kernels.

[[ -n ${_NEKO_TCP_LOADED:-} ]] && return 0
_NEKO_TCP_LOADED=1

tcp_val() { sysctl_get "$1" || echo '无法读取'; }

tcp_status() {
  ui_header "TCP 状态"
  local def q
  def=$(net_default_iface) || def=''
  ui_kv "内核版本" "$SYS_KERNEL"
  ui_kv "拥塞控制" "$(tcp_val net.ipv4.tcp_congestion_control)"
  ui_kv "可用算法" "$(tcp_val net.ipv4.tcp_available_congestion_control)"
  ui_kv "BBR" "$(net_bbr_label)"
  ui_kv "默认 Qdisc" "$(tcp_val net.core.default_qdisc)"
  if [[ -n $def ]]; then
    q=$(net_iface_qdisc "$def") || q=''
    ui_kv "网卡 Qdisc" "${def}：${q:-未知（需要 tc）}"
  fi
  ui_kv "tcp_rmem" "$(tcp_val net.ipv4.tcp_rmem)"
  ui_kv "tcp_wmem" "$(tcp_val net.ipv4.tcp_wmem)"
  ui_kv "rmem_max" "$(tcp_val net.core.rmem_max)"
  ui_kv "wmem_max" "$(tcp_val net.core.wmem_max)"
  ui_kv "Fast Open" "$(tcp_val net.ipv4.tcp_fastopen)（1=客户端 2=服务端 3=两者）"
  ui_kv "ECN" "$(tcp_val net.ipv4.tcp_ecn)（0=关闭 1=主动 2=仅响应）"
  ui_kv "MTU Probing" "$(tcp_val net.ipv4.tcp_mtu_probing)（0=关闭 1=检测到黑洞时 2=始终）"
  ui_kv "Keepalive" "time $(tcp_val net.ipv4.tcp_keepalive_time)s / intvl $(tcp_val net.ipv4.tcp_keepalive_intvl)s / probes $(tcp_val net.ipv4.tcp_keepalive_probes)"
  ui_kv "空闲后慢启动" "$(tcp_val net.ipv4.tcp_slow_start_after_idle)"
  if sys_is_container; then
    ui_warn "容器环境：default_qdisc、rmem_max 等全局参数通常只读，拥塞控制取决于宿主机已加载的模块。"
  fi
}

# Load tcp_bbr when the kernel ships it as a module that is not loaded yet.
tcp_prepare_bbr() {
  local st
  st=$(net_bbr_state)
  case $st in
    active | available) return 0 ;;
    unsupported)
      ui_err "当前内核 ${SYS_KERNEL} 低于 4.9，不支持 BBR。"
      ui_note "请通过发行版官方渠道升级内核；Neko 不会安装第三方内核。"
      return 1
      ;;
    module)
      if sys_is_container; then
        ui_err "容器环境无法加载内核模块，请联系宿主机提供商启用 tcp_bbr。"
        return 1
      fi
      ui_info "内核包含 tcp_bbr 模块但尚未加载。"
      ui_confirm "是否加载 tcp_bbr 模块（modprobe tcp_bbr）？" y || return 1
      if ! modprobe tcp_bbr 2>/dev/null; then
        ui_err "modprobe tcp_bbr 失败。"
        return 1
      fi
      [[ " $(net_tcp_cc_available) " == *' bbr '* ]] || { ui_err "加载后 bbr 仍不可用。"; return 1; }
      ui_ok "tcp_bbr 已加载。"
      ;;
    *)
      ui_err "当前内核未提供 BBR（可用算法：$(net_tcp_cc_available)）。"
      ui_note "Neko 不会安装第三方内核，请使用发行版官方内核（Debian/Ubuntu 默认内核均包含 BBR）。"
      return 1
      ;;
  esac
}

tcp_enable_bbr_fq() {
  ui_header "启用 BBR + FQ"
  ui_note "BBR 根据带宽与 RTT 估计控制发送速率，适合高延迟、存在随机丢包的跨境链路。"
  ui_note "FQ 为每条流提供公平排队与 pacing；内核 4.13+ 的 BBR 即使不配合 FQ 也能自行 pacing。"
  ui_note "注意：TCP BBR 只作用于 TCP，不影响 QUIC / Hysteria 2 / TUIC 等基于 UDP 的协议。"
  require_root "启用 BBR" || return 1
  tcp_prepare_bbr || return 1
  local modules='' args=()
  net_kernel_module_exists tcp_bbr && modules=tcp_bbr
  mapfile -t args < <(profile_args bbr-fq)
  ((${#args[@]})) || { ui_err "缺少配置模板 data/profiles/bbr-fq.conf"; return 1; }
  APPLY_MODULES=$modules apply_sysctl tcp-bbr "启用 BBR + FQ" "${args[@]}" || return 1
  tcp_offer_qdisc_now fq
}

# default_qdisc only applies to qdiscs created later; offer to switch the
# default interface now when it uses a single root qdisc.
tcp_offer_qdisc_now() {
  local want=$1 def cur
  has_cmd tc || return 0
  def=$(net_default_iface) || return 0
  cur=$(net_iface_qdisc "$def") || return 0
  [[ -n $cur && $cur != "$want" ]] || return 0
  case $cur in
    mq | mqprio | noqueue)
      ui_note "网卡 ${def} 当前根 Qdisc 为 ${cur}，新的默认 Qdisc 将在网卡重新初始化或重启后生效。"
      return 0
      ;;
  esac
  ui_info "网卡 ${def} 当前根 Qdisc 为 ${cur}。default_qdisc 只影响之后创建的队列。"
  ui_confirm "是否立即将 ${def} 的根 Qdisc 替换为 ${want}（可能造成毫秒级抖动）？" n || {
    ui_note "保持不变，重启后生效。"
    return 0
  }
  neko_lock || return 1
  backup_begin tcp-qdisc-iface "网卡 ${def} 根 Qdisc ${cur} → ${want}" || { neko_unlock; return 1; }
  backup_add_restore "tc-$def" tc qdisc replace dev "$def" root "$cur"
  local tx=$BK_TX_ID
  if tc qdisc replace dev "$def" root "$want" 2>/dev/null; then
    backup_commit
    ui_ok "${def} 根 Qdisc 已替换为 ${want}（变更编号 ${tx}）。"
  else
    backup_commit
    backup_set_status "$tx" rolled_back
    ui_err "tc qdisc replace 执行失败，未做修改。"
  fi
  neko_unlock
}

tcp_switch_cc() {
  ui_header "切换拥塞控制算法"
  require_root "切换拥塞控制" || return 1
  local avail opts=() a i
  avail=$(net_tcp_cc_available) || { ui_err "无法读取可用算法列表。"; return 1; }
  read -ra opts <<<"$avail"
  if [[ " $avail " != *' bbr '* ]] && [[ $(net_bbr_state) == module ]]; then
    opts+=(bbr)
  fi
  ui_kv "当前算法" "$(net_tcp_cc)"
  for i in "${!opts[@]}"; do
    a=${opts[i]}
    case $a in
      bbr) ui_item $((i + 1)) "bbr    - 基于带宽/RTT 模型，适合高延迟跨境线路" ;;
      cubic) ui_item $((i + 1)) "cubic  - Linux 默认，基于丢包，适合低延迟稳定网络" ;;
      reno) ui_item $((i + 1)) "reno   - 经典算法，一般不推荐" ;;
      *) ui_item $((i + 1)) "$a" ;;
    esac
  done
  ui_back_item 返回
  ui_read_choice "${#opts[@]}" || return 0
  ((REPLY_CHOICE == 0)) && return 0
  a=${opts[REPLY_CHOICE - 1]}
  local modules=''
  if [[ $a == bbr ]]; then
    tcp_prepare_bbr || return 1
    net_kernel_module_exists tcp_bbr && modules=tcp_bbr
  fi
  APPLY_MODULES=$modules apply_sysctl "tcp-cc" "拥塞控制 → ${a}" "net.ipv4.tcp_congestion_control=$a"
}

tcp_set_qdisc() {
  ui_header "设置默认队列算法（Qdisc）"
  require_root "设置 Qdisc" || return 1
  local opts=() q i
  for q in fq fq_codel cake pfifo_fast; do
    net_qdisc_supported "$q" && opts+=("$q")
  done
  ui_kv "当前默认 Qdisc" "$(net_default_qdisc)"
  for i in "${!opts[@]}"; do
    case ${opts[i]} in
      fq) ui_item $((i + 1)) "fq         - 公平队列 + pacing，推荐与 BBR 搭配" ;;
      fq_codel) ui_item $((i + 1)) "fq_codel   - 公平队列 + CoDel 主动队列管理，多数发行版默认" ;;
      cake) ui_item $((i + 1)) "cake       - 综合整形算法，CPU 开销较高" ;;
      pfifo_fast) ui_item $((i + 1)) "pfifo_fast - 传统 FIFO，不推荐" ;;
    esac
  done
  ui_back_item 返回
  ui_read_choice "${#opts[@]}" || return 0
  ((REPLY_CHOICE == 0)) && return 0
  q=${opts[REPLY_CHOICE - 1]}
  apply_sysctl "tcp-qdisc" "默认 Qdisc → ${q}" "net.core.default_qdisc=$q" || return 1
  tcp_offer_qdisc_now "$q"
}

# Buffer sizing from the bandwidth-delay product, capped by memory.
tcp_calc_buffer() { # tcp_calc_buffer <mbps> <rtt_ms> -> bytes
  local mbps=$1 rtt=$2 bdp target cap mem
  bdp=$((mbps * 1000 * rtt / 8)) # bytes = Mbit/s * ms * 1000 / 8
  target=$((bdp * 2))
  mem=$((SYS_MEM_TOTAL_KB * 1024))
  cap=$((mem / 32))
  ((cap > 67108864)) && cap=67108864
  ((cap < 4194304)) && cap=4194304
  ((target > cap)) && target=$cap
  ((target < 4194304)) && target=4194304
  printf '%d' "$target"
}

tcp_buffers() {
  ui_header "TCP 缓冲区调优"
  require_root "调整 TCP 缓冲区" || return 1
  ui_note "依据带宽时延积（BDP = 带宽 × RTT）计算单连接所需窗口，取 2×BDP 并按内存设置上限。"
  ui_note "带宽和 RTT 应填写客户端到本机的实际数值，可用菜单 7 测试 RTT。"
  ui_kv "当前 tcp_rmem" "$(tcp_val net.ipv4.tcp_rmem)"
  ui_kv "当前 tcp_wmem" "$(tcp_val net.ipv4.tcp_wmem)"
  ui_kv "内存总量" "$(human_bytes $((SYS_MEM_TOTAL_KB * 1024)))"
  local mbps rtt buf rmax wmax
  ui_prompt "VPS 带宽（Mbps）" 1000 || return 0
  mbps=$REPLY_INPUT
  validate_int_range "$mbps" 1 100000 || { ui_err "带宽需为 1-100000 的整数。"; return 1; }
  ui_prompt "客户端到 VPS 的 RTT（毫秒）" 150 || return 0
  rtt=$REPLY_INPUT
  validate_int_range "$rtt" 1 2000 || { ui_err "RTT 需为 1-2000 的整数。"; return 1; }
  buf=$(tcp_calc_buffer "$mbps" "$rtt")
  ui_kv "BDP" "$(human_bytes $((mbps * 1000 * rtt / 8)))"
  ui_kv "建议最大缓冲" "$(human_bytes "$buf")（${buf} 字节）"
  # never shrink net.core.*_max below what is already configured (UDP tuning shares them)
  rmax=$(num_or "$(sysctl_get net.core.rmem_max)" 0)
  wmax=$(num_or "$(sysctl_get net.core.wmem_max)" 0)
  ((rmax < buf)) && rmax=$buf
  ((wmax < buf)) && wmax=$buf
  apply_sysctl "tcp-buffers" "TCP 缓冲区（${mbps}Mbps / ${rtt}ms）" \
    "net.core.rmem_max=$rmax" "net.core.wmem_max=$wmax" \
    "net.ipv4.tcp_rmem=4096 131072 $buf" "net.ipv4.tcp_wmem=4096 16384 $buf"
}

tcp_pick_value() { # tcp_pick_value <title> <key> <option-text>... ; options are "value|description"
  local title=$1 key=$2 i
  shift 2
  ui_header "$title"
  require_root "修改 ${title}" || return 1
  ui_kv "当前值" "$(tcp_val "$key")"
  local opts=("$@")
  for i in "${!opts[@]}"; do ui_item $((i + 1)) "${opts[i]#*|}"; done
  ui_back_item 返回
  ui_read_choice "${#opts[@]}" || return 1
  ((REPLY_CHOICE == 0)) && return 1
  REPLY_INPUT=${opts[REPLY_CHOICE - 1]%%|*}
}

tcp_fastopen() {
  ui_note "TFO 可在握手时携带数据减少 1 个 RTT；服务端模式需要应用程序本身支持（如 sing-box 入站 tcp_fast_open）。"
  ui_note "部分运营商中间设备会丢弃带 TFO 的 SYN，内核会自动回退。"
  tcp_pick_value "TCP Fast Open" net.ipv4.tcp_fastopen \
    "3|3 - 客户端与服务端均启用（推荐）" "1|1 - 仅客户端（内核默认）" "0|0 - 关闭" || return 0
  apply_sysctl "tcp-fastopen" "TCP Fast Open → ${REPLY_INPUT}" "net.ipv4.tcp_fastopen=$REPLY_INPUT"
}

tcp_ecn() {
  ui_note "ECN 让路由器以标记代替丢包通知拥塞。主动发起 ECN（1）可能被少数老旧中间设备丢弃。"
  tcp_pick_value "ECN 显式拥塞通知" net.ipv4.tcp_ecn \
    "2|2 - 仅在对端请求时启用（内核默认，最稳妥）" "1|1 - 主动请求 ECN" "0|0 - 完全关闭" || return 0
  apply_sysctl "tcp-ecn" "ECN → ${REPLY_INPUT}" "net.ipv4.tcp_ecn=$REPLY_INPUT"
}

tcp_mtu_probing() {
  ui_note "MTU Probing 可在 PMTU 黑洞（ICMP 被过滤）时自动降低 MSS，隧道/封装网络中较常见。"
  tcp_pick_value "TCP MTU Probing" net.ipv4.tcp_mtu_probing \
    "1|1 - 检测到黑洞时启用（推荐）" "0|0 - 关闭（内核默认）" "2|2 - 始终启用" || return 0
  apply_sysctl "tcp-mtu-probing" "MTU Probing → ${REPLY_INPUT}" "net.ipv4.tcp_mtu_probing=$REPLY_INPUT"
}

tcp_keepalive() {
  ui_header "TCP Keepalive"
  require_root "修改 Keepalive" || return 1
  ui_note "只影响开启 SO_KEEPALIVE 的连接；缩短探测时间可更快清理 NAT 后失效的连接。"
  ui_kv "当前" "time $(tcp_val net.ipv4.tcp_keepalive_time)s / intvl $(tcp_val net.ipv4.tcp_keepalive_intvl)s / probes $(tcp_val net.ipv4.tcp_keepalive_probes)"
  local t i p
  ui_prompt "空闲多少秒后开始探测（60-7200）" 600 || return 0
  t=$REPLY_INPUT
  ui_prompt "探测间隔秒数（5-300）" 30 || return 0
  i=$REPLY_INPUT
  ui_prompt "探测次数（1-20）" 5 || return 0
  p=$REPLY_INPUT
  if ! validate_int_range "$t" 60 7200 || ! validate_int_range "$i" 5 300 || ! validate_int_range "$p" 1 20; then
    ui_err "输入超出范围。"
    return 1
  fi
  apply_sysctl "tcp-keepalive" "Keepalive ${t}/${i}/${p}" \
    "net.ipv4.tcp_keepalive_time=$t" "net.ipv4.tcp_keepalive_intvl=$i" "net.ipv4.tcp_keepalive_probes=$p"
}

tcp_menu() {
  while true; do
    ui_header "TCP 网络优化"
    ui_kv "拥塞控制" "$(tcp_val net.ipv4.tcp_congestion_control)"
    ui_kv "默认 Qdisc" "$(tcp_val net.core.default_qdisc)"
    echo
    ui_item 1 "查看 TCP 状态"
    ui_item 2 "一键启用 BBR + FQ（推荐）"
    ui_item 3 "切换拥塞控制算法（BBR / CUBIC）"
    ui_item 4 "设置默认队列算法（FQ / FQ_CoDel / CAKE）"
    ui_item 5 "TCP 缓冲区调优"
    ui_item 6 "TCP Fast Open"
    ui_item 7 "ECN 显式拥塞通知"
    ui_item 8 "MTU Probing"
    ui_item 9 "TCP Keepalive"
    ui_back_item
    ui_read_choice 9 || return 0
    case $REPLY_CHOICE in
      0) return 0 ;;
      1) tcp_status ;;
      2) tcp_enable_bbr_fq ;;
      3) tcp_switch_cc ;;
      4) tcp_set_qdisc ;;
      5) tcp_buffers ;;
      6) tcp_fastopen ;;
      7) tcp_ecn ;;
      8) tcp_mtu_probing ;;
      9) tcp_keepalive ;;
    esac
    ui_pause
  done
}
