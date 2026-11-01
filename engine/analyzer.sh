# shellcheck shell=bash
# Neko - fact collection for the recommendation engine. Only local reads:
# no network requests, no changes. Unreadable values stay empty and the rules
# that depend on them are skipped instead of guessed.

[[ -n ${_NEKO_ANALYZER_LOADED:-} ]] && return 0
_NEKO_ANALYZER_LOADED=1

declare -gA FACT=()

analyzer_collect() {
  FACT=()
  ((SYS_DETECTED)) || sys_detect
  FACT[kernel]=$SYS_KERNEL
  FACT[virt_kind]=$SYS_VIRT_KIND
  FACT[mem_kb]=$SYS_MEM_TOTAL_KB
  FACT[cc]=$(net_tcp_cc 2>/dev/null)
  FACT[cc_avail]=$(net_tcp_cc_available 2>/dev/null)
  FACT[bbr_state]=$(net_bbr_state)
  FACT[qdisc]=$(net_default_qdisc 2>/dev/null)
  FACT[rmem_max]=$(sysctl_get net.core.rmem_max 2>/dev/null)
  FACT[wmem_max]=$(sysctl_get net.core.wmem_max 2>/dev/null)
  local v
  v=$(sysctl_get net.ipv4.tcp_rmem 2>/dev/null) && FACT[tcp_rmem_max]=${v##* }
  v=$(sysctl_get net.ipv4.tcp_wmem 2>/dev/null) && FACT[tcp_wmem_max]=${v##* }
  FACT[mtu_probing]=$(sysctl_get net.ipv4.tcp_mtu_probing 2>/dev/null)
  FACT[ssai]=$(sysctl_get net.ipv4.tcp_slow_start_after_idle 2>/dev/null)
  local def
  def=$(net_default_iface) && FACT[iface]=$def && FACT[mtu]=$(net_iface_mtu "$def")

  if udp_read_stats; then
    FACT[udp_in]=$(($(udp_stat Udp.InDatagrams) + $(udp_stat Udp6.InDatagrams)))
    FACT[udp_rcvbuf_err]=$(($(udp_stat Udp.RcvbufErrors) + $(udp_stat Udp6.RcvbufErrors)))
  fi
  if sysctl_exists net.netfilter.nf_conntrack_max; then
    FACT[ct_count]=$(sysctl_get net.netfilter.nf_conntrack_count)
    FACT[ct_max]=$(sysctl_get net.netfilter.nf_conntrack_max)
  fi
  local tcp o r
  if tcp=$(nt_tcp_counters 2>/dev/null) && [[ -n $tcp ]]; then
    read -r o r <<<"$tcp"
    FACT[tcp_out]=$o FACT[tcp_retrans]=$r
  fi

  dns_detect >/dev/null 2>&1
  FACT[dns_manager]=$DNS_MANAGER
  FACT[dns_count]=${#DNS_UPSTREAM[@]}
  ((${#DNS_UPSTREAM[@]})) || FACT[dns_count]=${#DNS_NAMESERVERS[@]}
  FACT[dns_list]="${DNS_UPSTREAM[*]:-${DNS_NAMESERVERS[*]}}"

  proxy_scan >/dev/null 2>&1
  local core quic=0
  for core in "${PROXY_CORES[@]}"; do FACT[px_$core]=${PX_STATE[$core]}; done
  if proxy_any_config_ok && has_cmd jq; then
    export_collect >/dev/null 2>&1
    quic=$(jq '[.[] | select(.type == "hysteria2" or .type == "tuic")] | length' <<<"$EXPORT_NODES" 2>/dev/null || echo 0)
    export_cleanup
  fi
  FACT[quic_inbounds]=$quic

  # Neko-managed sysctl keys overridden by files loaded later at boot
  local -A managed=()
  managed_sysctl_load managed
  local k c='' f val when
  for k in "${!managed[@]}"; do
    while IFS=$'\t' read -r f val when; do
      [[ $when == after ]] && c+="${c:+; }${f} 覆盖 ${k}=${val}"
    done < <(sysctl_conflicts "$k" "${managed[$k]}")
  done
  FACT[sysctl_conflicts]=$c
}
