# shellcheck shell=bash
# Neko - QUIC service analysis (Hysteria 2, TUIC, HTTP/3). Read-only.

[[ -n ${_NEKO_QUIC_LOADED:-} ]] && return 0
_NEKO_QUIC_LOADED=1

quic_analyze() {
  ui_header "QUIC 服务专项分析"

  ui_section "UDP 监听端口"
  local listeners
  listeners=$(ss_udp_listeners 2>/dev/null) || listeners=''
  if [[ -z $listeners ]]; then
    ui_note "未发现 UDP 监听端口（或缺少 ss / 权限不足以查看进程）。"
  else
    local port proc
    while IFS=$'\t' read -r port proc; do
      case $proc in
        sing-box | xray* | hysteria* | tuic* | caddy | nginx | haproxy | mihomo | juicity*)
          ui_kv "UDP ${port}" "$proc" 14
          ;;
      esac
    done <<<"$listeners"
  fi

  ui_section "代理核心中的 QUIC 入站"
  proxy_scan
  local found=0
  if proxy_any_config_ok && has_cmd jq; then
    export_collect >/dev/null 2>&1
    local name type port up down ign cc obfs
    while IFS=$'\t' read -r name type port up down ign cc obfs; do
      [[ -n $name ]] || continue
      found=1
      if [[ $type == hysteria2 ]]; then
        ui_kv "$name" "Hysteria 2，UDP ${port}${obfs:+，混淆 ${obfs}}" 20
        if [[ $ign == true ]]; then
          ui_note "服务端设置 ignore_client_bandwidth：强制使用 BBR（QUIC 层），忽略客户端声明的带宽。"
        elif ((up > 0 || down > 0)); then
          ui_note "服务端带宽上限 up ${up} / down ${down} Mbps；客户端声明带宽时使用 Brutal 固定速率发送。"
        else
          ui_note "未设置服务端带宽：客户端声明带宽时使用 Brutal，否则使用 BBR（QUIC 层）。"
        fi
        ui_note "提示：Brutal 带宽应填写实测可用带宽，偏高会导致大量丢包与重传。"
      else
        ui_kv "$name" "TUIC，UDP ${port}，拥塞控制 ${cc}" 20
        ui_note "TUIC 的 congestion_control（cubic/new_reno/bbr）在 QUIC 层实现，与内核 TCP 设置无关。"
      fi
    done < <(jq -r '.[] | select(.type == "hysteria2" or .type == "tuic")
      | [.name, .type, (.port | tostring), ((.up_mbps // 0) | tostring), ((.down_mbps // 0) | tostring),
         ((.ignore_client_bandwidth // false) | tostring), (.cc // ""), (.obfs // "")] | @tsv' <<<"$EXPORT_NODES")
    export_cleanup
  fi
  ((found)) || ui_note "未在 sing-box / Xray 配置中发现 Hysteria 2 或 TUIC 入站。"
  local p
  for p in hysteria tuic-server; do
    [[ -n $(proc_find "$p") ]] && ui_note "检测到独立运行的 ${p}（Neko 暂不解析其配置）。"
  done

  ui_section "系统侧检查"
  local rmax wmax rb
  rmax=$(num_or "$(sysctl_get net.core.rmem_max)" 0)
  wmax=$(num_or "$(sysctl_get net.core.wmem_max)" 0)
  if ((rmax >= UDP_QUIC_MIN_BUF && wmax >= UDP_QUIC_MIN_BUF)); then
    ui_ok "UDP 缓冲区上限 ${rmax} / ${wmax}，满足 QUIC 建议值。"
  else
    ui_warn "UDP 缓冲区上限 ${rmax} / ${wmax} 低于建议值 ${UDP_QUIC_MIN_BUF}，可在本菜单第 2 项调整。"
  fi
  if udp_read_stats; then
    rb=$(($(udp_stat Udp.RcvbufErrors) + $(udp_stat Udp6.RcvbufErrors)))
    if ((rb > 0)); then ui_warn "UDP 接收缓冲溢出累计 ${rb} 次。"; else ui_ok "无 UDP 接收缓冲溢出。"; fi
  fi
  local def mtu
  def=$(net_default_iface) || def=''
  if [[ -n $def ]]; then
    mtu=$(net_iface_mtu "$def") || mtu=0
    if ((mtu > 0 && mtu < 1280)); then
      ui_warn "${def} MTU 为 ${mtu}，低于 QUIC 最小要求 1280（QUIC 要求 UDP 载荷至少 1200 字节）。"
    elif ((mtu > 0)); then
      ui_ok "${def} MTU ${mtu} 满足 QUIC 要求。"
    fi
    local feats
    feats=$(net_offload_features "$def" 2>/dev/null) || feats=''
    if [[ -n $feats ]]; then
      local seg
      seg=$(grep '^tx-udp-segmentation=' <<<"$feats" | cut -d= -f2)
      [[ -n $seg ]] && ui_kv "UDP GSO" "$seg（quic-go 可利用 UDP GSO 降低 CPU 占用）"
    fi
  fi
  if sysctl_exists net.netfilter.nf_conntrack_udp_timeout_stream; then
    ui_kv "conntrack UDP 流超时" "$(sysctl_get net.netfilter.nf_conntrack_udp_timeout_stream)s"
  fi
  ui_note "TCP BBR 不影响 QUIC；QUIC 的速度主要取决于程序内拥塞控制、UDP 缓冲区与线路对 UDP 的 QoS。"
}
