# shellcheck shell=bash
# Neko - network performance tests. Every test states its target and expected
# traffic; nothing heavy runs without an explicit confirmation.

[[ -n ${_NEKO_NETTEST_LOADED:-} ]] && return 0
_NEKO_NETTEST_LOADED=1

nt_ping() { # nt_ping <4|6> <target> <count> -> raw ping output
  local fam=$1 target=$2 count=$3
  if [[ $fam == 6 ]]; then
    if ping -6 -c 1 -W 1 ::1 >/dev/null 2>&1; then
      ping -6 -n -c "$count" -i 0.3 -W 2 "$target" 2>&1
    else
      ping6 -n -c "$count" -i 0.3 -W 2 "$target" 2>&1
    fi
  else
    ping -4 -n -c "$count" -i 0.3 -W 2 "$target" 2>&1
  fi
}

# Parses ping output: prints "loss avg_ms min max mdev" or fails.
nt_ping_parse() {
  awk '
    /packet loss/ { for (i = 1; i <= NF; i++) if ($i ~ /%$/) loss = $i }
    /min\/avg\/max/ { split($4, a, "/"); min = a[1]; avg = a[2]; max = a[3]; mdev = a[4] }
    END { if (loss == "") exit 1; print loss, (avg == "" ? "-" : avg), (min == "" ? "-" : min), (max == "" ? "-" : max), (mdev == "" ? "-" : mdev) }'
}

nt_tcp_connect_ms() { # nt_tcp_connect_ms <host> <port>
  local t0 t1
  t0=$(now_ms)
  # shellcheck disable=SC2016
  if run_timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$1" "$2" 2>/dev/null; then
    t1=$(now_ms)
    printf '%s' $((t1 - t0))
    return 0
  fi
  return 1
}

nt_connectivity() {
  ui_header "IPv4 / IPv6 连通性"
  local v4 v6 out res ms
  v4=$(config_get PING_TARGET_V4 1.1.1.1)
  v6=$(config_get PING_TARGET_V6 2606:4700:4700::1111)
  ui_note "目标：${v4} / ${v6}（ICMP 各 4 次 + TCP 443 连接，流量 < 2 KB）"
  if has_cmd ping; then
    out=$(nt_ping 4 "$v4" 4)
    if res=$(nt_ping_parse <<<"$out"); then
      read -r loss avg _ <<<"$res"
      ui_kv "IPv4 ICMP" "丢包 ${loss}，平均 RTT ${avg} ms"
    else
      ui_kv "IPv4 ICMP" "$(ui_status bad 不可用)"
    fi
    if net_has_default_v6; then
      out=$(nt_ping 6 "$v6" 4)
      if res=$(nt_ping_parse <<<"$out"); then
        read -r loss avg _ <<<"$res"
        ui_kv "IPv6 ICMP" "丢包 ${loss}，平均 RTT ${avg} ms"
      else
        ui_kv "IPv6 ICMP" "$(ui_status bad 不可用)"
      fi
    else
      ui_kv "IPv6" "无 IPv6 默认路由，跳过"
    fi
  else
    ui_note "未找到 ping（iputils-ping），跳过 ICMP 测试。"
  fi
  if ms=$(nt_tcp_connect_ms "$v4" 443); then ui_kv "IPv4 TCP 443" "${ms} ms"; else ui_kv "IPv4 TCP 443" "$(ui_status bad 连接失败)"; fi
  if net_has_default_v6; then
    if ms=$(nt_tcp_connect_ms "$v6" 443); then ui_kv "IPv6 TCP 443" "${ms} ms"; else ui_kv "IPv6 TCP 443" "$(ui_status bad 连接失败)"; fi
  fi
}

nt_ask_target() { # nt_ask_target <label> <default>  -> REPLY_INPUT validated host
  ui_prompt "$1" "$2" || return 1
  validate_host "$REPLY_INPUT" || { ui_err "无效的目标：${REPLY_INPUT}"; return 1; }
}

nt_tcp_test() {
  ui_header "TCP 连接测试"
  nt_ask_target "目标主机" "$(config_get TEST_HOST www.cloudflare.com)" || return 0
  local host=$REPLY_INPUT
  ui_prompt "端口" 443 || return 0
  validate_port "$REPLY_INPUT" || { ui_err "无效端口。"; return 1; }
  local port=$REPLY_INPUT ms ok=0 sum=0 res=''
  ui_note "向 ${host}:${port} 建立 5 次 TCP 连接（仅握手，无数据传输）。"
  for _ in 1 2 3 4 5; do
    if ms=$(nt_tcp_connect_ms "$host" "$port"); then
      res+="${ms}ms "
      ((ok++, sum += ms))
    else
      res+="失败 "
    fi
  done
  ui_kv "结果" "$res"
  ((ok)) && ui_kv "成功率 / 平均" "${ok}/5，$((sum / ok)) ms（含 DNS 解析）"
}

nt_udp_test() {
  ui_header "UDP 可用性"
  ui_note "通过向公共 DNS 发送 UDP 查询验证出站 UDP（每次约 100 字节）。"
  local s ms
  for s in 1.1.1.1 8.8.8.8 9.9.9.9; do
    if ms=$(dns_query_ms "$s" example.com); then
      ui_kv "UDP → ${s}:53" "$(ui_status good 可用)（${ms} ms）"
    else
      ui_kv "UDP → ${s}:53" "$(ui_status bad 无响应)"
    fi
  done
  ui_note "入站 UDP（如 Hysteria 2 端口）无法从本机自测，请在客户端侧验证并检查云厂商安全组。"
}

nt_rtt_loss() {
  ui_header "RTT 与丢包"
  has_cmd ping || { ui_err "未找到 ping（apt install iputils-ping）。"; return 1; }
  nt_ask_target "目标主机" "$(config_get PING_TARGET_V4 1.1.1.1)" || return 0
  local host=$REPLY_INPUT out res fam=4
  validate_ipv6 "$host" && fam=6
  ui_note "向 ${host} 发送 20 个 ICMP 包（约 2 KB）。"
  out=$(nt_ping "$fam" "$host" 20)
  if ! res=$(nt_ping_parse <<<"$out"); then
    ui_err "ping 失败：$(tail -n 1 <<<"$out")"
    return 1
  fi
  local loss avg min max mdev
  read -r loss avg min max mdev <<<"$res"
  ui_kv "丢包率" "$loss"
  ui_kv "RTT 最小/平均/最大" "${min} / ${avg} / ${max} ms"
  ui_kv "抖动（mdev）" "${mdev} ms"
  local l=${loss%\%}
  l=${l%%.*}
  ((l >= 5)) && ui_warn "丢包率较高，BBR 在随机丢包场景下通常优于 CUBIC。"
}

nt_mtu() {
  ui_header "MTU / PMTU 检测"
  nt_ask_target "目标主机" "$(config_get PING_TARGET_V4 1.1.1.1)" || return 0
  local host=$REPLY_INPUT def
  def=$(net_default_iface) || def=''
  [[ -n $def ]] && ui_kv "${def} MTU" "$(net_iface_mtu "$def")"
  if has_cmd tracepath; then
    ui_note "使用 tracepath 探测路径 MTU（逐跳 UDP 探测，流量很小）。"
    local out pmtu
    out=$(run_timeout 30 tracepath -n -m 20 "$host" 2>&1)
    pmtu=$(grep -Eo 'pmtu [0-9]+' <<<"$out" | tail -n 1 | awk '{print $2}')
    ui_kv "路径 MTU" "${pmtu:-未知}"
    return 0
  fi
  has_cmd ping || { ui_err "需要 tracepath 或 ping（apt install iputils-tracepath iputils-ping）。"; return 1; }
  validate_ipv4 "$host" || validate_domain "$host" || { ui_err "ping 二分法仅支持 IPv4。"; return 1; }
  ui_note "使用 DF 标志的 ping 二分查找（约 10 个包）。"
  local lo=1200 hi=1500 mid best=0
  while ((lo <= hi)); do
    mid=$(((lo + hi) / 2))
    if ping -4 -n -c 1 -W 2 -M 'do' -s $((mid - 28)) "$host" >/dev/null 2>&1; then
      best=$mid lo=$((mid + 1))
    else
      hi=$((mid - 1))
    fi
  done
  if ((best > 0)); then
    ui_kv "路径 MTU" "${best}"
    ((best < 1500)) && ui_note "路径 MTU 小于 1500，可考虑启用 TCP MTU Probing（菜单 2 → 8）。"
  else
    ui_warn "无法探测（ICMP 可能被过滤）。"
  fi
}

nt_route() {
  ui_header "路由分析"
  nt_ask_target "目标主机" "$(config_get PING_TARGET_V4 1.1.1.1)" || return 0
  local host=$REPLY_INPUT
  if has_cmd mtr; then
    ui_note "mtr 报告模式，10 轮（约 30 KB）。"
    run_timeout 90 mtr -n -r -c 10 "$host"
  elif has_cmd traceroute; then
    run_timeout 60 traceroute -n -w 2 -q 1 "$host"
  elif has_cmd tracepath; then
    run_timeout 60 tracepath -n "$host"
  else
    ui_err "未安装 mtr / traceroute / tracepath（apt install mtr-tiny 或 iputils-tracepath）。"
  fi
}

nt_tcp_counters() { # prints "OutSegs RetransSegs"
  awk '$1 == "Tcp:" { if (!h) { for (i = 2; i <= NF; i++) idx[$i] = i; h = 1 } else print $idx["OutSegs"], $idx["RetransSegs"] }' "$(sysp /proc/net/snmp)"
}

nt_retrans() {
  ui_header "TCP 重传统计"
  local out1 out2 o1 r1 o2 r2
  out1=$(nt_tcp_counters) || { ui_err "无法读取 /proc/net/snmp。"; return 1; }
  read -r o1 r1 <<<"$out1"
  ui_kv "累计发送段" "$o1"
  ui_kv "累计重传段" "$r1"
  ((o1 > 0)) && ui_kv "累计重传率" "$(awk -v r="$r1" -v o="$o1" 'BEGIN { printf "%.3f%%", r * 100 / o }')"
  if ui_confirm "是否采样 10 秒计算实时重传率？" y; then
    sleep 10
    out2=$(nt_tcp_counters)
    read -r o2 r2 <<<"$out2"
    local d_o=$((o2 - o1)) d_r=$((r2 - r1))
    ui_kv "10 秒内发送 / 重传" "${d_o} / ${d_r}"
    if ((d_o > 0)); then
      ui_kv "实时重传率" "$(awk -v r="$d_r" -v o="$d_o" 'BEGIN { printf "%.3f%%", r * 100 / o }')"
    else
      ui_note "采样期间几乎没有 TCP 发送，无法计算。"
    fi
  fi
  ui_note "重传率长期 > 2% 通常意味着线路拥塞或丢包；BBR 对此类线路更友好。"
}

nt_iface_stats() {
  ui_header "网卡流量统计"
  local f
  f=$(sysp /proc/net/dev)
  [[ -r $f ]] || { ui_err "无法读取 /proc/net/dev。"; return 1; }
  local -A rx1=() tx1=()
  local name rb re rd tb te td _
  printf '  %s %14s %14s %8s %8s %8s %8s\n' "$(ui_pad 网卡 12)" "接收" "发送" "RX错误" "RX丢弃" "TX错误" "TX丢弃"
  while IFS=': ' read -r name rb _ re rd _ _ _ _ tb _ te td _; do
    [[ $name == Inter-* || $name == face* || -z $name || $name == lo ]] && continue
    rx1[$name]=$rb tx1[$name]=$tb
    printf '  %s %14s %14s %8s %8s %8s %8s\n' "$(ui_pad "$name" 12)" "$(human_bytes "$rb")" "$(human_bytes "$tb")" "$re" "$rd" "$te" "$td"
  done < <(sed 's/:/ /' "$f")
  sleep 1
  ui_section "当前速率（1 秒采样）"
  while IFS=': ' read -r name rb _ _ _ _ _ _ _ tb _; do
    [[ -n ${rx1[$name]+x} ]] || continue
    ui_kv "$name" "↓ $(human_bytes $((rb - rx1[$name])))/s  ↑ $(human_bytes $((tb - tx1[$name])))/s" 12
  done < <(sed 's/:/ /' "$f")
}

nt_throughput() {
  ui_header "吞吐量测试（iperf3）"
  if ! has_cmd iperf3; then
    ui_err "未安装 iperf3（apt install iperf3）。"
    return 1
  fi
  ui_warn "吞吐量测试会产生大量流量（1 Gbps 线路 10 秒约 1.2 GB），可能计入 VPS 流量配额。"
  ui_note "Neko 不内置公共测速服务器，请填写你有权使用的 iperf3 服务端。"
  nt_ask_target "iperf3 服务端地址" || return 0
  local host=$REPLY_INPUT port dur
  ui_prompt "端口" 5201 || return 0
  port=$REPLY_INPUT
  validate_port "$port" || { ui_err "无效端口。"; return 1; }
  ui_prompt "测试时长（秒，3-30）" 10 || return 0
  dur=$REPLY_INPUT
  validate_int_range "$dur" 3 30 || { ui_err "时长需为 3-30 秒。"; return 1; }
  ui_confirm "确认向 ${host}:${port} 进行 ${dur} 秒上传 + ${dur} 秒下载测试吗？" n || return 0
  ui_section "上传（本机 → ${host}）"
  run_timeout $((dur + 15)) iperf3 -c "$host" -p "$port" -t "$dur" -f m 2>&1 | tail -n 4
  ui_section "下载（${host} → 本机）"
  run_timeout $((dur + 15)) iperf3 -c "$host" -p "$port" -t "$dur" -f m -R 2>&1 | tail -n 4
}

network_test_menu() {
  while true; do
    ui_header "网络性能测试"
    ui_item 1 "IPv4 / IPv6 连通性"
    ui_item 2 "DNS 查询延迟"
    ui_item 3 "TCP 连接测试"
    ui_item 4 "UDP 可用性"
    ui_item 5 "RTT 与丢包率"
    ui_item 6 "MTU / PMTU 检测"
    ui_item 7 "路由分析"
    ui_item 8 "TCP 重传统计"
    ui_item 9 "网卡流量统计"
    ui_item 10 "吞吐量测试（iperf3，消耗流量）"
    ui_back_item
    ui_read_choice 10 || return 0
    case $REPLY_CHOICE in
      0) return 0 ;;
      1) nt_connectivity ;;
      2) dns_latency_test ;;
      3) nt_tcp_test ;;
      4) nt_udp_test ;;
      5) nt_rtt_loss ;;
      6) nt_mtu ;;
      7) nt_route ;;
      8) nt_retrans ;;
      9) nt_iface_stats ;;
      10) nt_throughput ;;
    esac
    ui_pause
  done
}
