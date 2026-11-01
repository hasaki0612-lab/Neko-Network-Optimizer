# shellcheck shell=bash
# Recommendation engine: rules fire only on observed facts.

section "智能优化建议"
(
  t_setup
  t_install_singbox running
  out=$(neko_run '8\n0\n0\n')
  assert_contains "$out" "[1] 启用 BBR 拥塞控制" "建议启用 BBR（cubic + 模块可用）"
  assert_contains "$out" "当前配置：cubic" "显示当前配置"
  assert_contains "$out" "推荐配置：bbr + fq" "显示推荐配置"
  assert_contains "$out" "增大 UDP 缓冲区上限" "存在 Hysteria2/TUIC 入站时建议增大 UDP 缓冲区"
  assert_contains "$out" "2 个 Hysteria 2 / TUIC 入站" "UDP 建议引用真实入站数量"
  assert_contains "$out" "关闭空闲后慢启动" "检测到代理服务端时建议关闭空闲慢启动"
  assert_contains "$out" "提高 TCP 缓冲区上限（可选）" "TCP 缓冲区上限建议"
  assert_contains "$out" "约 335 Mbps" "按 6 MiB / 150 ms 计算吞吐上限"
  assert_contains "$out" "DNS 缺少冗余" "只有 1 个上游 DNS 时建议冗余"
  assert_contains "$out" "回滚方式：" "每条建议包含回滚方式"
  assert_contains "$out" "需要重启：否    自动应用：支持" "每条建议包含重启与自动应用信息"
  assert_not_contains "$out" "TCP 重传率偏高" "重传率 0.3% 时不报告"
  assert_not_contains "$out" "启用 TCP MTU Probing" "MTU 1500 时不建议 MTU Probing"
  # apply recommendation 1 from the menu
  out=$(neko_run '8\n1\ny\ny\nn\n0\n0\n')
  assert_eq "$(cat "$R/proc/sys/net/ipv4/tcp_congestion_control")" bbr "从建议列表应用 BBR"
  out=$(neko_run '8\n0\n0\n')
  assert_not_contains "$out" "启用 BBR 拥塞控制" "应用后不再建议 BBR"
  t_teardown
)
(
  t_setup
  out=$(neko_run '8\n0\n0\n')
  assert_not_contains "$out" "增大 UDP 缓冲区上限" "无 QUIC 服务且无溢出时不建议 UDP 缓冲区"
  assert_not_contains "$out" "关闭空闲后慢启动" "无代理服务端时不建议空闲慢启动"
  sed -i 's/^Udp: 90000 12 0 88000 0 0 0 0 0$/Udp: 90000 12 0 88000 57 0 0 0 0/' "$R/proc/net/snmp"
  out=$(neko_run '8\n0\n0\n')
  assert_contains "$out" "已发生 57 次 UDP 接收缓冲溢出" "接收缓冲溢出时建议增大 UDP 缓冲区"
  echo 1400 >"$R/sys/class/net/eth0/mtu"
  out=$(neko_run '8\n0\n0\n')
  assert_contains "$out" "启用 TCP MTU Probing" "MTU < 1500 时建议 MTU Probing"
  t_teardown
)
(
  t_setup
  s=$R/proc/sys/net
  echo bbr >"$s/ipv4/tcp_congestion_control"
  echo 'reno cubic bbr' >"$s/ipv4/tcp_available_congestion_control"
  echo fq >"$s/core/default_qdisc"
  echo 16777216 >"$s/core/rmem_max"
  echo 16777216 >"$s/core/wmem_max"
  printf '4096\t131072\t16777216\n' >"$s/ipv4/tcp_rmem"
  echo 0 >"$s/ipv4/tcp_slow_start_after_idle"
  printf 'nameserver 1.1.1.1\nnameserver 1.0.0.1\n' >"$R/run/systemd/resolve/resolv.conf"
  out=$(neko_run '8\n0\n')
  assert_contains "$out" "未发现需要优化的项目" "已优化的系统不虚构问题"
  t_teardown
)
