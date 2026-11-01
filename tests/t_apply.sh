# shellcheck shell=bash
# sysctl apply engine, backups and rollback.

section "TCP 优化：BBR + FQ 与备份"
(
  t_setup
  # 2 (TCP menu) -> 2 (BBR+FQ) -> load module? y -> confirm y -> qdisc now? n -> pause -> 0 -> 0
  out=$(neko_run '2\n2\ny\ny\nn\n\n0\n0\n')
  assert_contains "$out" "内核包含 tcp_bbr 模块但尚未加载" "检测到 BBR 模块未加载"
  assert_contains "$(cat "$M/calls")" "modprobe tcp_bbr" "加载 tcp_bbr 模块"
  assert_eq "$(cat "$R/proc/sys/net/ipv4/tcp_congestion_control")" bbr "运行时拥塞控制 = bbr"
  assert_eq "$(cat "$R/proc/sys/net/core/default_qdisc")" fq "运行时默认 Qdisc = fq"
  conf=$(cat "$R/etc/sysctl.d/99-zz-neko.conf" 2>/dev/null)
  assert_contains "$conf" "net.ipv4.tcp_congestion_control = bbr" "持久化到 99-zz-neko.conf"
  assert_contains "$conf" "net.core.default_qdisc = fq" "持久化 Qdisc"
  assert_eq "$(cat "$R/etc/modules-load.d/neko.conf" | grep -c '^tcp_bbr$')" 1 "开机加载 tcp_bbr"
  hist=$(cat "$T/state/history.tsv")
  assert_contains "$hist" $'\tcommitted\ttcp-bbr\t' "变更记录状态为已生效"
  tx=$(cut -f1 "$T/state/history.tsv" | head -n 1)
  assert_eq "$(cat "$T/state/backups/$tx/sysctl.before" | sort | tr '\n' ' ')" "net.core.default_qdisc=fq_codel net.ipv4.tcp_congestion_control=cubic " "记录修改前运行时参数"
  assert_contains "$(cat "$T/state/backups/$tx/changes.diff")" "+net.ipv4.tcp_congestion_control = bbr" "记录修改前后差异"
  assert_eq "$(cut -f3 "$T/state/backups/$tx/manifest.tsv" | tr '\n' ' ')" "0 0 " "记录文件修改前不存在"

  # running it again must not create duplicates or a new transaction
  out=$(neko_run '2\n2\nn\n0\n0\n')
  assert_contains "$out" "当前配置已是目标值，且已持久化，无需修改。" "重复执行为幂等操作"
  assert_eq "$(grep -c . "$T/state/history.tsv")" 1 "重复执行不新增变更记录"
  assert_eq "$(grep -c 'tcp_congestion_control' "$R/etc/sysctl.d/99-zz-neko.conf")" 1 "配置文件无重复项"
  t_teardown
)

section "TCP 优化：缓冲区与 UDP 共用上限"
(
  t_setup
  # UDP standard buffers first: 3 -> 2 -> 1 -> y
  neko_run '3\n2\n1\ny\n\n0\n0\n' >/dev/null
  assert_eq "$(cat "$R/proc/sys/net/core/rmem_max")" 7500000 "UDP 缓冲区上限 7.5 MB"
  # TCP buffers 1000 Mbps / 20 ms -> 2*BDP = 5 MB -> floor 4 MiB... capped by memory (2 GB / 32 = 64 MiB)
  neko_run '2\n5\n1000\n20\ny\n\n0\n0\n' >/dev/null
  assert_eq "$(cat "$R/proc/sys/net/ipv4/tcp_rmem")" "4096 131072 5000000" "tcp_rmem 按 2×BDP 计算"
  assert_eq "$(cat "$R/proc/sys/net/core/rmem_max")" 7500000 "TCP 调优不会调小 UDP 设置的 rmem_max"
  conf=$(cat "$R/etc/sysctl.d/99-zz-neko.conf")
  assert_contains "$conf" "net.core.rmem_max = 7500000" "合并后的配置文件"
  assert_contains "$conf" "net.ipv4.tcp_wmem = 4096 16384 5000000" "tcp_wmem 持久化"
  t_teardown
)

section "回滚：撤销、指定版本、完整回滚、撤销回滚"
(
  t_setup
  neko_run '2\n2\ny\ny\nn\n\n0\n0\n' >/dev/null # tx1 BBR
  neko_run '2\n8\n1\ny\n\n0\n0\n' >/dev/null    # tx2 mtu probing
  assert_eq "$(cat "$R/proc/sys/net/ipv4/tcp_mtu_probing")" 1 "MTU Probing 已启用"
  # undo last (9 -> 3 -> confirm)
  out=$(neko_run '9\n3\ny\n\n0\n0\n')
  assert_contains "$out" "已恢复到变更 00002" "撤销最近一次变更"
  assert_eq "$(cat "$R/proc/sys/net/ipv4/tcp_mtu_probing")" 0 "运行时参数已恢复"
  assert_eq "$(cat "$R/proc/sys/net/ipv4/tcp_congestion_control")" bbr "更早的变更保持不变"
  assert_not_contains "$(cat "$R/etc/sysctl.d/99-zz-neko.conf")" tcp_mtu_probing "配置文件已恢复"
  # full rollback (9 -> 5 -> confirm)
  out=$(neko_run '9\n5\ny\n\n0\n0\n')
  assert_contains "$out" "已恢复到变更 00001" "完整回滚"
  assert_no_file "$R/etc/sysctl.d/99-zz-neko.conf" "删除 Neko 创建的 sysctl 文件"
  assert_no_file "$R/etc/modules-load.d/neko.conf" "删除 Neko 创建的 modules-load 文件"
  assert_eq "$(cat "$R/proc/sys/net/ipv4/tcp_congestion_control")" cubic "拥塞控制恢复为 cubic"
  assert_eq "$(cat "$R/proc/sys/net/core/default_qdisc")" fq_codel "Qdisc 恢复为 fq_codel"
  st=$(cut -f3 "$T/state/history.tsv" | tr '\n' ' ')
  assert_eq "$st" "rolled_back rolled_back rolled_back committed " "历史状态：全部已回滚 + 新的回滚事务"
  # undo the full rollback: restore to before transaction 00004
  out=$(neko_run '9\n4\n4\ny\n\n0\n0\n')
  assert_eq "$(cat "$R/proc/sys/net/ipv4/tcp_congestion_control")" bbr "撤销回滚：拥塞控制恢复为 bbr"
  assert_file "$R/etc/sysctl.d/99-zz-neko.conf" "撤销回滚：配置文件恢复"
  out=$(neko_run '9\n2\n1\n\n0\n0\n')
  assert_contains "$out" "+net.ipv4.tcp_congestion_control = bbr" "查看变更详情（差异）"
  t_teardown
)

section "回滚：快照与符号链接恢复"
(
  t_setup
  # 9 -> 6 (snapshot of every Neko-managed path, resolv.conf is a symlink here)
  neko_run '9\n6\n0\n0\n' >/dev/null
  assert_contains "$(cat "$T/state/history.tsv")" $'\tcommitted\tsnapshot\t' "创建配置快照"
  rm -f "$R/etc/resolv.conf"
  printf 'nameserver 192.0.2.53\n' >"$R/etc/resolv.conf"
  # restore to before snapshot 00001: drift is reported, then confirmed
  out=$(neko_run '9\n4\n1\ny\n0\n0\n')
  assert_contains "$out" "又被其他程序或人工修改过" "快照后被替换的文件被识别为漂移"
  assert_eq "$(readlink "$R/etc/resolv.conf")" "../run/systemd/resolve/stub-resolv.conf" "恢复符号链接及其目标"
  assert_no_file "$R/etc/sysctl.d/99-zz-neko.conf" "快照时不存在的文件保持不存在"
  t_teardown
)

section "回滚：漂移检测与失败处理"
(
  t_setup
  neko_run '2\n2\ny\ny\nn\n\n0\n0\n' >/dev/null
  echo "# edited by admin" >>"$R/etc/sysctl.d/99-zz-neko.conf"
  out=$(neko_run '9\n3\nn\n\n0\n0\n')
  assert_contains "$out" "又被其他程序或人工修改过" "检测到 Neko 之后的人工修改"
  assert_contains "$out" "已取消回滚" "拒绝确认时不回滚"
  assert_eq "$(cat "$R/proc/sys/net/ipv4/tcp_congestion_control")" bbr "取消后保持原状"
  t_teardown
)
(
  t_setup
  echo net.core.default_qdisc >"$M/sysctl_fail"
  out=$(neko_run '2\n2\ny\ny\ny\n\n0\n0\n')
  assert_contains "$out" "以下参数应用失败：net.core.default_qdisc" "报告应用失败的参数"
  assert_eq "$(cat "$R/proc/sys/net/ipv4/tcp_congestion_control")" cubic "失败后自动回滚运行时参数"
  assert_no_file "$R/etc/sysctl.d/99-zz-neko.conf" "失败后回滚配置文件"
  t_teardown
)

section "权限与兼容性"
(
  t_setup
  export NEKO_TEST_EUID=1000
  out=$(neko_run '2\n2\n\n0\n0\n')
  assert_contains "$out" "启用 BBR需要 root 权限" "普通用户无法修改"
  assert_eq "$(cat "$R/proc/sys/net/ipv4/tcp_congestion_control")" cubic "普通用户未修改任何参数"
  out=$(neko_run '9\n\n0\n')
  assert_contains "$out" "需要 root 权限" "普通用户无法查看备份"
  out=$(neko_run '2\n1\n\n0\n0\n')
  assert_contains "$out" "拥塞控制      ：cubic" "普通用户可以只读查看"
  t_teardown
)
(
  t_setup
  echo '4.4.0-210-generic' >"$R/proc/sys/kernel/osrelease"
  out=$(neko_run '2\n2\n\n0\n0\n')
  assert_contains "$out" "低于 4.9，不支持 BBR" "旧内核拒绝启用 BBR"
  assert_contains "$out" "Neko 不会安装第三方内核" "不安装第三方内核"
  t_teardown
)
(
  t_setup
  export MOCK_VIRT=lxc
  out=$(neko_run '2\n2\n\n0\n0\n')
  assert_contains "$out" "容器环境无法加载内核模块" "容器中不加载内核模块"
  t_teardown
)
(
  t_setup
  printf 'net.ipv4.tcp_congestion_control = cubic\n' >"$R/etc/sysctl.d/zz-provider.conf"
  echo 'reno cubic bbr' >"$R/proc/sys/net/ipv4/tcp_available_congestion_control"
  out=$(neko_run '2\n3\n3\ny\n\n0\n0\n')
  assert_contains "$out" "zz-provider.conf 将 net.ipv4.tcp_congestion_control 设为 cubic，且在 Neko 之后加载" "检测会覆盖 Neko 的 sysctl 文件"
  t_teardown
)
