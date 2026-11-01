# shellcheck shell=bash
# Neko - evidence-based recommendations. Each rule fires only on facts read
# from this machine; every recommendation states the current value, the
# proposal, the reason, the risk and how to roll it back.

[[ -n ${_NEKO_RECOMMENDER_LOADED:-} ]] && return 0
_NEKO_RECOMMENDER_LOADED=1

REC_TITLE=() REC_CUR=() REC_WANT=() REC_WHY=() REC_RISK=() REC_REBOOT=() REC_ACTION=() REC_ROLLBACK=()

rec_add() { # title current wanted why risk reboot action rollback
  REC_TITLE+=("$1") REC_CUR+=("$2") REC_WANT+=("$3") REC_WHY+=("$4")
  REC_RISK+=("$5") REC_REBOOT+=("$6") REC_ACTION+=("$7") REC_ROLLBACK+=("${8:-菜单 9「配置备份与回滚」撤销对应变更}")
}

rec_build() {
  REC_TITLE=() REC_CUR=() REC_WANT=() REC_WHY=() REC_RISK=() REC_REBOOT=() REC_ACTION=() REC_ROLLBACK=()
  local cc=${FACT[cc]:-} bbr=${FACT[bbr_state]:-} q=${FACT[qdisc]:-}

  # 1. Congestion control
  if [[ -n $cc && $cc != bbr ]]; then
    case $bbr in
      available | module)
        if [[ $bbr == module && ${FACT[virt_kind]} == container ]]; then
          rec_add "BBR 不可用（容器环境）" "$cc" "bbr" \
            "内核带有 tcp_bbr 模块但容器内无法加载，需要宿主机加载后才能使用。" 无 否 "" "无需回滚"
        else
          rec_add "启用 BBR 拥塞控制" "$cc" "bbr + fq" \
            "当前使用 ${cc}（基于丢包），在高延迟或存在随机丢包的跨境线路上吞吐量容易下降；内核已支持 BBR。" \
            低 否 tcp_enable_bbr_fq
        fi
        ;;
      unsupported)
        rec_add "内核不支持 BBR" "内核 ${FACT[kernel]}" "内核 ≥ 4.9" \
          "BBR 需要 Linux 4.9 及以上。请通过发行版官方渠道升级内核，Neko 不会安装第三方内核。" 高 是 "" "由发行版包管理器回退内核"
        ;;
    esac
  fi

  # 2. Qdisc paired with BBR
  if [[ $cc == bbr && -n $q ]]; then
    case $q in
      fq | fq_codel | cake) ;;
      *)
        rec_add "默认 Qdisc 改为 fq" "$q" "fq" \
          "BBR 搭配 fq 可获得逐流公平排队与精确 pacing；${q} 不具备公平队列能力。" 低 否 rec_apply_fq
        ;;
    esac
  fi

  # 3. UDP buffers for QUIC
  local rmax=${FACT[rmem_max]:-} wmax=${FACT[wmem_max]:-} err=${FACT[udp_rcvbuf_err]:-0}
  if [[ $rmax =~ ^[0-9]+$ && $wmax =~ ^[0-9]+$ ]]; then
    if ((rmax < UDP_QUIC_MIN_BUF || wmax < UDP_QUIC_MIN_BUF)); then
      if ((${FACT[quic_inbounds]:-0} > 0 || err > 0)); then
        local why="rmem_max/wmem_max 低于 quic-go 建议值 ${UDP_QUIC_MIN_BUF} 字节"
        ((${FACT[quic_inbounds]:-0} > 0)) && why+="；配置中有 ${FACT[quic_inbounds]} 个 Hysteria 2 / TUIC 入站"
        ((err > 0)) && why+="；已发生 ${err} 次 UDP 接收缓冲溢出"
        rec_add "增大 UDP 缓冲区上限" "${rmax} / ${wmax}" "${UDP_QUIC_MIN_BUF} / ${UDP_QUIC_MIN_BUF}" "${why}。" 低 否 rec_apply_udp
      fi
    elif ((err > 0 && ${FACT[mem_kb]:-0} >= 1000000 && rmax < 16777216)); then
      rec_add "进一步增大 UDP 缓冲区" "${rmax}" "16777216" \
        "缓冲区已达到建议值，但仍累计 ${err} 次 UDP 接收缓冲溢出，说明突发流量超过当前缓冲。" 低 否 rec_apply_udp_16m
    fi
  fi

  # 4. TCP buffer ceiling vs. high-RTT throughput
  local trm=${FACT[tcp_rmem_max]:-}
  if [[ $trm =~ ^[0-9]+$ ]] && ((trm <= 6291456 && ${FACT[mem_kb]:-0} >= 1000000)); then
    local ceiling=$((trm * 8 / 150000))
    rec_add "提高 TCP 缓冲区上限（可选）" "tcp_rmem 最大 $(human_bytes "$trm")" "按带宽 × RTT 计算（菜单 2 → 5）" \
      "单连接吞吐上限约为 窗口 / RTT：在 150 ms RTT 下约 ${ceiling} Mbps。若客户端到本机延迟较高且带宽更大，该上限会成为瓶颈。" \
      低 否 tcp_buffers
  fi

  # 5. MTU probing on reduced-MTU links
  local mtu=${FACT[mtu]:-} mp=${FACT[mtu_probing]:-}
  if [[ $mtu =~ ^[0-9]+$ && $mp == 0 ]] && ((mtu < 1500)); then
    rec_add "启用 TCP MTU Probing" "tcp_mtu_probing=0（${FACT[iface]} MTU ${mtu}）" "tcp_mtu_probing=1" \
      "网卡 MTU 小于 1500，通常位于隧道/封装网络中，遇到 PMTU 黑洞时连接会卡住；启用后内核可自动降低 MSS。" 低 否 rec_apply_mtu_probing
  fi

  # 6. Slow start after idle on proxy servers
  if [[ ${FACT[ssai]:-} == 1 ]] && [[ ${FACT[px_singbox]:-} != not_installed || ${FACT[px_xray]:-} != not_installed ]] && [[ -n ${FACT[px_singbox]:-}${FACT[px_xray]:-} ]]; then
    rec_add "关闭空闲后慢启动" "tcp_slow_start_after_idle=1" "tcp_slow_start_after_idle=0" \
      "检测到代理服务端。代理长连接常有空闲间隔，默认设置会在空闲后把拥塞窗口重置为初始值，恢复传输时速度骤降。" 低 否 rec_apply_ssai
  fi

  # 7. Conntrack pressure
  if [[ ${FACT[ct_count]:-} =~ ^[0-9]+$ && ${FACT[ct_max]:-} =~ ^[0-9]+$ ]] && ((FACT[ct_max] > 0)); then
    local pct=$((FACT[ct_count] * 100 / FACT[ct_max]))
    if ((pct >= 80)); then
      rec_add "提高连接跟踪上限" "${FACT[ct_count]} / ${FACT[ct_max]}（${pct}%）" "nf_conntrack_max × 2（受内存限制）" \
        "连接跟踪表接近满载，表满后新连接会被内核丢弃。" 中 否 conntrack_status
    fi
  fi

  # 8. Retransmissions (informational)
  if [[ ${FACT[tcp_out]:-} =~ ^[0-9]+$ && ${FACT[tcp_retrans]:-} =~ ^[0-9]+$ ]] && ((FACT[tcp_out] > 100000)); then
    local rp=$((FACT[tcp_retrans] * 1000 / FACT[tcp_out]))
    if ((rp >= 20)); then
      rec_add "TCP 重传率偏高" "自开机累计 $((rp / 10)).$((rp % 10))%" "< 2%" \
        "较高的重传率通常来自线路拥塞或丢包。可使用菜单 7 进行 RTT/丢包与路由分析定位问题。" 无 否 "" "无需回滚"
    fi
  fi

  # 9. DNS
  case ${FACT[dns_count]:-0} in
    0)
      rec_add "未配置 DNS 服务器" "无 nameserver" "Cloudflare 1.1.1.1 / 1.0.0.1" \
        "系统没有可用的 DNS 服务器，域名解析将失败。" 中 否 dns_set_plain "菜单 4 → 恢复 DNS 配置"
      ;;
    1)
      rec_add "DNS 缺少冗余" "${FACT[dns_list]}" "至少 2 个 DNS 服务器" \
        "只有一个 DNS 服务器，该服务器故障时解析会完全中断。" 中 否 dns_set_plain "菜单 4 → 恢复 DNS 配置"
      ;;
  esac

  # 10. Proxy installed but not running (Neko never starts services)
  local core
  for core in "${PROXY_CORES[@]}"; do
    if [[ ${FACT[px_$core]:-} == stopped ]]; then
      rec_add "${PX_LABEL[$core]} 已安装但未运行" "已停止" "按需手动启动" \
        "Neko 不会启动代理服务。如需运行，请检查后手动执行 systemctl start（由你决定）。" 无 否 "" "无需回滚"
    fi
  done

  # 11. Boot-time overrides of Neko settings
  if [[ -n ${FACT[sysctl_conflicts]:-} ]]; then
    rec_add "Neko 的 sysctl 设置会在重启后被覆盖" "${FACT[sysctl_conflicts]}" "移除冲突项或统一配置" \
      "这些文件在 Neko 配置之后加载，重启后 Neko 的设置不会生效。请手动检查（Neko 不修改其他程序的配置）。" 低 是 "" "无需回滚"
  fi
}

rec_apply_fq() { apply_sysctl tcp-qdisc "默认 Qdisc → fq（建议）" net.core.default_qdisc=fq; }
rec_apply_udp() {
  local r w
  r=$(num_or "${FACT[rmem_max]}" 0) w=$(num_or "${FACT[wmem_max]}" 0)
  ((r < UDP_QUIC_MIN_BUF)) && r=$UDP_QUIC_MIN_BUF
  ((w < UDP_QUIC_MIN_BUF)) && w=$UDP_QUIC_MIN_BUF
  apply_sysctl udp-buffers "UDP 缓冲区 → QUIC 建议值（建议）" "net.core.rmem_max=$r" "net.core.wmem_max=$w"
}
rec_apply_udp_16m() {
  local w
  w=$(num_or "${FACT[wmem_max]}" 0)
  ((w < 16777216)) && w=16777216
  apply_sysctl udp-buffers "UDP 缓冲区 → 16 MB（建议）" net.core.rmem_max=16777216 "net.core.wmem_max=$w"
}
rec_apply_mtu_probing() { apply_sysctl tcp-mtu-probing "MTU Probing → 1（建议）" net.ipv4.tcp_mtu_probing=1; }
rec_apply_ssai() { apply_sysctl tcp-ssai "空闲后慢启动 → 关闭（建议）" net.ipv4.tcp_slow_start_after_idle=0; }

rec_risk_text() {
  case $1 in
    低) ui_status good 低 ;;
    中) ui_status warn 中 ;;
    高) ui_status bad 高 ;;
    *) printf '%s' "$1" ;;
  esac
}

rec_print() {
  local i n=${#REC_TITLE[@]}
  if ((n == 0)); then
    ui_ok "未发现需要优化的项目。"
    ui_note "已检查：拥塞控制、Qdisc、TCP/UDP 缓冲区、MTU Probing、空闲慢启动、Conntrack、重传率、DNS、代理服务、sysctl 冲突。"
    return 1
  fi
  for ((i = 0; i < n; i++)); do
    echo
    printf ' %s[%d]%s %s%s%s    风险：%s\n' "$C_GREEN" $((i + 1)) "$C_RESET" "$C_BOLD" "${REC_TITLE[i]}" "$C_RESET" "$(rec_risk_text "${REC_RISK[i]}")"
    printf '     当前配置：%s\n' "${REC_CUR[i]}"
    printf '     推荐配置：%s\n' "${REC_WANT[i]}"
    printf '     优化理由：%s\n' "${REC_WHY[i]}"
    printf '     需要重启：%s    自动应用：%s\n' "${REC_REBOOT[i]}" "$([[ -n ${REC_ACTION[i]} ]] && echo 支持 || echo 不支持)"
    printf '     回滚方式：%s\n' "${REC_ROLLBACK[i]}"
  done
  return 0
}

recommender_menu() {
  ui_header "智能优化建议"
  ui_info "正在分析本机配置（仅本地读取，不发起网络请求）..."
  analyzer_collect
  rec_build
  if ! rec_print; then
    return 0
  fi
  while true; do
    echo
    ui_line
    ui_note "输入建议编号应用该项（每项都会先预览并确认，修改前自动备份）。"
    ui_item 0 返回主菜单
    ui_line
    ui_read_choice "${#REC_TITLE[@]}" || return 0
    ((REPLY_CHOICE == 0)) && return 0
    local i=$((REPLY_CHOICE - 1))
    if [[ -z ${REC_ACTION[i]} ]]; then
      ui_info "该建议不支持自动应用，请参照说明手动处理。"
      continue
    fi
    "${REC_ACTION[i]}"
    ui_pause
    analyzer_collect
    rec_build
    ui_header "智能优化建议"
    rec_print || return 0
  done
}
