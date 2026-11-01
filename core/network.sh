# shellcheck shell=bash
# Neko - network interface, address, offload and kernel network stack detection.

[[ -n ${_NEKO_NETWORK_LOADED:-} ]] && return 0
_NEKO_NETWORK_LOADED=1

# Interface carrying the IPv4 default route (falls back to the IPv6 one).
net_default_iface() {
  local f iface dest plen _
  f=$(sysp /proc/net/route)
  if [[ -r $f ]]; then
    while read -r iface dest _; do
      [[ $dest == 00000000 ]] && { printf '%s' "$iface"; return 0; }
    done <"$f"
  fi
  f=$(sysp /proc/net/ipv6_route)
  if [[ -r $f ]]; then
    while read -r dest plen _ _ _ _ _ _ _ iface; do
      if [[ $dest == 00000000000000000000000000000000 && $plen == 00 && $iface != lo ]]; then
        printf '%s' "$iface"
        return 0
      fi
    done <"$f"
  fi
  return 1
}

net_has_default_v6() {
  local f dest plen _ iface
  f=$(sysp /proc/net/ipv6_route)
  [[ -r $f ]] || return 1
  while read -r dest plen _ _ _ _ _ _ _ iface; do
    [[ $dest == 00000000000000000000000000000000 && $plen == 00 && $iface != lo ]] && return 0
  done <"$f"
  return 1
}

net_ifaces() { # all interfaces except lo
  local d
  for d in "$(sysp /sys/class/net)"/*; do
    [[ -e $d ]] || continue
    d=${d##*/}
    [[ $d == lo ]] && continue
    printf '%s\n' "$d"
  done
}

net_iface_attr() { read_first_line "/sys/class/net/$1/$2"; }

net_iface_mtu() { net_iface_attr "$1" mtu; }

net_iface_driver() {
  local link
  link=$(readlink "$(sysp "/sys/class/net/$1/device/driver")" 2>/dev/null) || true
  if [[ -n $link ]]; then
    printf '%s' "${link##*/}"
  elif has_cmd ethtool; then
    ethtool -i "$1" 2>/dev/null | awk -F': ' '/^driver:/{print $2; exit}'
  fi
}

net_iface_txqueues() {
  local n=0 q
  for q in "$(sysp "/sys/class/net/$1/queues")"/tx-*; do
    [[ -e $q ]] && ((n++))
  done
  printf '%d' "$n"
}

net_iface_is_virtual() {
  [[ ! -e $(sysp "/sys/class/net/$1/device") ]]
}

# Global IPv4 addresses ("iface addr/prefix" per line).
net_ipv4_addrs() {
  has_cmd ip || return 1
  ip -o -4 addr show scope global 2>/dev/null | awk '{print $2, $4}'
}

# Global IPv6 addresses from /proc/net/if_inet6 (scope 00 = global).
net_ipv6_addrs() {
  local f addr _ plen scope _ iface
  f=$(sysp /proc/net/if_inet6)
  [[ -r $f ]] || return 1
  while read -r addr _ plen scope _ iface; do
    [[ $scope == 00 ]] || continue
    printf '%s %s/%d\n' "$iface" "$(net_hex_to_ipv6 "$addr")" "$((16#$plen))"
  done <"$f"
}

net_hex_to_ipv6() { # 32 hex chars -> RFC 5952 text form
  local h=$1 i g x groups=() best_s=-1 best_l=0 cur_s=-1 cur_l=0
  for ((i = 0; i < 8; i++)); do
    g=$((16#${h:i*4:4}))
    printf -v x '%x' "$g"
    groups+=("$x")
    if ((g == 0)); then
      ((cur_s < 0)) && cur_s=$i
      ((++cur_l > best_l)) && best_l=$cur_l best_s=$cur_s
    else
      cur_s=-1 cur_l=0
    fi
  done
  if ((best_l < 2)); then
    (IFS=:; printf '%s' "${groups[*]}")
    return
  fi
  local left right
  left=$(IFS=:; printf '%s' "${groups[*]:0:best_s}")
  right=$(IFS=:; printf '%s' "${groups[*]:best_s+best_l}")
  printf '%s::%s' "$left" "$right"
}

net_ipv4_is_private() {
  local ip=$1 a b
  IFS=. read -r a b _ _ <<<"$ip"
  ((a == 10 || a == 127 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) || (a == 100 && b >= 64 && b <= 127) || (a == 169 && b == 254)))
}

# First public IPv4 / IPv6 bound to a local interface (no external requests).
net_public_ipv4() {
  local _if addr
  while read -r _if addr; do
    addr=${addr%/*}
    net_ipv4_is_private "$addr" || { printf '%s' "$addr"; return 0; }
  done < <(net_ipv4_addrs)
  return 1
}

net_public_ipv6() {
  local _if addr
  while read -r _if addr; do
    addr=${addr%/*}
    [[ $addr == f[cd]* ]] && continue
    printf '%s' "$addr"
    return 0
  done < <(net_ipv6_addrs)
  return 1
}

# Offload features through ethtool -k (optional dependency).
# Prints "feature=on|off" lines for the features Neko cares about.
net_offload_features() {
  has_cmd ethtool || return 2
  ethtool -k "$1" 2>/dev/null | awk -F': ' '
    /^(generic-segmentation-offload|generic-receive-offload|tcp-segmentation-offload|tx-udp-segmentation|rx-udp-gro-forwarding|rx-gro-list|large-receive-offload):/ {
      split($2, v, " "); print $1 "=" v[1]
    }'
}

net_iface_qdisc() { # root qdisc kind of an interface
  has_cmd tc || return 1
  tc qdisc show dev "$1" 2>/dev/null | awk '/ root/ || / root$/ {print $2; exit}'
}

# ------------------------------------------------------------ TCP stack ----
net_tcp_cc() { sysctl_get net.ipv4.tcp_congestion_control; }
net_tcp_cc_available() { sysctl_get net.ipv4.tcp_available_congestion_control; }
net_default_qdisc() { sysctl_get net.core.default_qdisc; }

net_kernel_module_exists() { # net_kernel_module_exists <name>
  local kver=${SYS_KERNEL:-$(uname -r)} d
  d=$(sysp "/lib/modules/$kver")
  compgen -G "$d/kernel/net/*/$1.ko*" >/dev/null 2>&1 && return 0
  compgen -G "$d/kernel/net/$1.ko*" >/dev/null 2>&1 && return 0
  grep -qs "/$1.ko" "$d/modules.builtin" && return 0
  if [[ -z ${NEKO_SYSROOT:-} ]] && has_cmd modinfo; then
    modinfo "$1" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# BBR state: active | available | module | unsupported | unknown
net_bbr_state() {
  local cc avail
  cc=$(net_tcp_cc) || cc=''
  [[ $cc == bbr ]] && { echo active; return; }
  avail=$(net_tcp_cc_available) || avail=''
  [[ " $avail " == *' bbr '* ]] && { echo available; return; }
  version_ge "${SYS_KERNEL:-0}" 4.9 || { echo unsupported; return; }
  net_kernel_module_exists tcp_bbr && { echo module; return; }
  echo unknown
}

net_bbr_label() {
  case $(net_bbr_state) in
    active) ui_status good '已启用' ;;
    available) ui_status good '可用（未启用）' ;;
    module) ui_status warn '内核模块存在（未加载）' ;;
    unsupported) ui_status bad "不支持（内核 ${SYS_KERNEL} < 4.9）" ;;
    *) ui_status warn '未在可用列表中，且未找到 tcp_bbr 模块' ;;
  esac
}

net_qdisc_supported() { # fq / fq_codel / cake / pfifo_fast
  case $1 in
    pfifo_fast | fq_codel) return 0 ;;
  esac
  [[ -e $(sysp "/sys/module/sch_$1") ]] && return 0
  net_kernel_module_exists "sch_$1"
}

# --------------------------------------------------------------- report ----
net_report() {
  local def ifc mtu drv q feats tx
  def=$(net_default_iface) || def=''
  ui_section "网络接口"
  ui_kv "默认出口网卡" "${def:-未找到默认路由}"
  while IFS= read -r ifc; do
    [[ -n $ifc ]] || continue
    mtu=$(net_iface_mtu "$ifc") || mtu='?'
    drv=$(net_iface_driver "$ifc")
    tx=$(net_iface_txqueues "$ifc")
    q=$(net_iface_qdisc "$ifc") || q=''
    local tag=''
    [[ $ifc == "$def" ]] && tag=' [默认]'
    net_iface_is_virtual "$ifc" && tag+=' [虚拟]'
    ui_kv "$ifc$tag" "MTU ${mtu}，驱动 ${drv:-未知}，TX 队列 ${tx}，Qdisc ${q:-未知}" 24
  done < <(net_ifaces)

  ui_section "IP 地址"
  local v4 v6
  v4=$(net_ipv4_addrs 2>/dev/null | awk '{printf "%s%s(%s)", (NR>1?", ":""), $2, $1}')
  v6=$(net_ipv6_addrs 2>/dev/null | awk '{printf "%s%s(%s)", (NR>1?", ":""), $2, $1}')
  ui_kv "IPv4" "${v4:-无全局 IPv4 地址}"
  ui_kv "IPv6" "${v6:-无全局 IPv6 地址}"
  if net_has_default_v6; then ui_kv "IPv6 默认路由" "存在"; else ui_kv "IPv6 默认路由" "不存在"; fi

  if [[ -n $def ]]; then
    ui_section "网卡卸载能力（${def}）"
    feats=$(net_offload_features "$def")
    case $? in
      2) ui_note "未安装 ethtool，无法检测 GSO/GRO（apt install ethtool）。" ;;
      *)
        if [[ -n $feats ]]; then
          while IFS='=' read -r k v; do ui_kv "$k" "$v" 30; done <<<"$feats"
        else
          ui_note "ethtool 未返回卸载信息（虚拟网卡可能不支持查询）。"
        fi
        ;;
    esac
  fi

  ui_section "内核网络栈"
  ui_kv "TCP 拥塞控制" "$(net_tcp_cc || echo 无法读取)"
  ui_kv "可用算法" "$(net_tcp_cc_available || echo 无法读取)"
  ui_kv "BBR" "$(net_bbr_label)"
  ui_kv "默认 Qdisc" "$(net_default_qdisc || echo 无法读取)"
}
