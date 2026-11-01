# shellcheck shell=bash
# Proxy detection states and node/subscription export.

section "代理服务检测：未安装"
(
  t_setup
  out=$(neko_run '6\n0\n0\n')
  assert_contains "$out" "[错误] 未检测到受支持的代理服务端。" "未安装时的错误提示"
  assert_contains "$out" "  sing-box：未安装" "列出 sing-box 未安装"
  assert_contains "$out" "  Xray Core：未安装" "列出 Xray 未安装"
  assert_contains "$out" "代理服务检测及节点导出功能暂不可用。" "功能不可用说明"
  assert_contains "$out" "其他网络优化功能不受影响。" "其他功能不受影响说明"
  assert_not_contains "$out" "未运行" "未安装不会被误报为停止"
  out=$(neko_run '10\n0\n0\n')
  assert_contains "$out" "[错误] 无法执行节点导出。" "导出：服务端缺失错误"
  assert_contains "$out" "Neko 不会自动安装代理服务端。" "导出：不自动安装说明"
  t_teardown
)

section "代理服务检测：状态区分"
(
  t_setup
  t_install_singbox
  neko_source
  proxy_scan
  assert_eq "${PX_STATE[singbox]}" stopped "已安装但未运行"
  assert_eq "${PX_STATE[xray]}" not_installed "Xray 未安装"
  assert_eq "${PX_CONF_STATE[singbox]}" ok "配置可识别"
  assert_eq "${PX_INBOUNDS[singbox]}" 10 "入站数量（含注释的 JSON）"
  assert_eq "${PX_CONF_SRC[singbox]}" "sing-box.service" "配置来源：服务 ExecStart"
  assert_eq "${PX_VERSION[singbox]}" 1.12.4 "sing-box 版本"
  out=$(proxy_report)
  assert_contains "$out" "代理服务已安装，但当前未运行" "停止状态提示"
  t_teardown
)
(
  t_setup
  t_install_singbox running
  t_install_xray
  neko_source
  proxy_scan
  assert_eq "${PX_STATE[singbox]}" running "正在运行"
  assert_eq "${PX_PIDS[singbox]}" 1234 "进程 PID"
  assert_eq "${PX_CONF_SRC[singbox]}" "进程参数" "配置来源：进程参数优先"
  assert_eq "${PX_PORTS[singbox]}" "tcp:443 udp:8443" "监听端口"
  assert_eq "${PX_STATE[xray]}" stopped "Xray 已安装未运行"
  assert_eq "${PX_CONF_FILES[xray]}" "/usr/local/etc/xray/config.json" "Xray -config 参数解析"
  assert_eq "${PX_VERSION[xray]}" 25.10.15 "Xray 版本"
  out=$(proxy_report)
  assert_contains "$out" "代理服务正常运行（PID 1234）" "运行状态提示"
  px_config_test singbox
  assert_rc $? 0 "sing-box check 校验"
  assert_contains "$(cat "$M/calls")" "sing-box check -c" "调用 sing-box check（只读）"
  assert_not_contains "$(cat "$M/calls")" "systemctl start" "未启动任何服务"
  assert_not_contains "$(cat "$M/calls")" "systemctl restart" "未重启任何服务"
  t_teardown
)
(
  t_setup
  t_install_singbox
  rm -f "$R/etc/sing-box/config.json"
  neko_source
  proxy_scan
  assert_eq "${PX_CONF_STATE[singbox]}" missing "配置不存在"
  out=$(proxy_report)
  assert_contains "$out" "未找到可识别配置文件" "配置不存在提示"
  out=$(export_prepare)
  assert_contains "$out" "已安装，但未找到可识别的配置文件" "导出：配置缺失原因"
  t_teardown
)
(
  t_setup
  t_install_singbox
  echo '{ "inbounds": [ { "type": "vless", ' >"$R/etc/sing-box/config.json"
  neko_source
  proxy_scan
  assert_eq "${PX_CONF_STATE[singbox]}" parse_error "配置解析失败"
  assert_contains "$(proxy_report)" "配置解析失败" "解析失败提示"
  t_teardown
)
(
  t_setup
  t_install_singbox
  winpath=$(cygpath -w "$R/etc/sing-box/config.json" 2>/dev/null)
  if [[ -n $winpath ]] && MSYS2_ARG_CONV_EXCL='*' icacls "$winpath" /deny "${USERNAME}:(R)" >/dev/null 2>&1; then
    neko_source
    proxy_scan
    assert_eq "${PX_CONF_STATE[singbox]}" unreadable "配置不可读取（ACL 拒绝读取）"
    out=$(export_prepare)
    assert_contains "$out" "配置文件不可读取" "导出：不可读取原因"
    MSYS2_ARG_CONV_EXCL='*' icacls "$winpath" /remove:d "$USERNAME" >/dev/null 2>&1
  else
    echo "  skip 配置不可读取（当前平台无法模拟读取拒绝）"
  fi
  t_teardown
)

section "节点导出：解析与链接"
(
  t_setup
  t_install_singbox running
  t_install_xray
  neko_source
  export_prepare >/dev/null
  n_all=$(jq length <<<"$EXPORT_NODES")
  n_ok=$(export_count)
  assert_eq "$n_all" 16 "识别 sing-box + Xray 共 16 个入站用户"
  assert_eq "$n_ok" 13 "可导出 13 个，跳过 3 个"
  skip=$(jq -r '.[] | select(.skip) | "\(.name): \(.skip)"' <<<"$EXPORT_NODES")
  assert_contains "$skip" "vless-local: 仅监听本地回环地址" "本地监听入站跳过"
  assert_contains "$skip" "xr-vless-enc: 使用 VLESS Encryption" "VLESS Encryption 跳过"
  assert_contains "$skip" "xr-range: 端口不是固定数字" "端口范围跳过"
  assert_not_contains "$(jq -c . <<<"$EXPORT_NODES")" "dwdtCnMYpX08" "节点数据中不含 REALITY 私钥"

  EXPORT_SERVER_ADDR=203.0.113.10
  nodes=$(export_nodes_with_server)
  links=$(export_links "$nodes")
  pbk=hSDwCYkwp1R0i33ctD73Wg2_Og0mOBr066SpjqqbTmo
  assert_contains "$links" "vless://11111111-2222-4333-8444-555555555555@203.0.113.10:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${pbk}&sid=0123456789abcdef&type=tcp#vless-reality-alice" "VLESS REALITY 链接（公钥由私钥推导，RFC 7748 向量）"
  assert_contains "$links" "trojan://p%40ss%20w0rd%2F%26@203.0.113.10:8444?security=tls&sni=example.com&alpn=h2%2Chttp%2F1.1&fp=chrome&type=tcp#trojan-carol" "Trojan 链接（密码 URL 编码）"
  assert_contains "$links" "ss://2022-blake3-aes-128-gcm:c2VydmVyUFNLMDEyMzQ1Ng%3D%3D%3AdXNlclBTSzAxMjM0NTY3OA%3D%3D@203.0.113.10:8388#ss2022-dave" "SS2022 多用户链接（server:user 密码）"
  assert_contains "$links" "ss://YWVzLTEyOC1nY206c2ltcGxlcGFzcw@203.0.113.10:8389#ss-aead" "SS AEAD 链接（SIP002 base64url）"
  assert_contains "$links" "hysteria2://hy2pass@203.0.113.10:8443/?sni=example.com&obfs=salamander&obfs-password=obfspw&alpn=h3&insecure=1#hy2-erin" "Hysteria2 链接（自签证书 → insecure，SNI 取自证书）"
  assert_contains "$links" "tuic://99999999-8888-4777-8666-555555555555:tuicpw@203.0.113.10:8445?sni=example.com&alpn=h3&congestion_control=bbr&udp_relay_mode=native#tuic-frank" "TUIC 链接"
  assert_contains "$links" "anytls://anypw@203.0.113.10:8446/?sni=example.com#anytls-gina" "AnyTLS 链接"
  assert_contains "$links" "vless://33333333-4444-4555-8666-777777777777@203.0.113.10:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=chrome&pbk=${pbk}&type=tcp#xr-reality-x1" "Xray REALITY 链接（空 shortId 省略 sid）"
  assert_contains "$links" "type=grpc&serviceName=grpcsvc" "Trojan gRPC 参数"
  assert_contains "$links" "type=xhttp&path=%2Fxh&mode=auto" "VLESS XHTTP 参数"
  vm=$(grep '^vmess://' <<<"$links" | head -n 1 | cut -c9- | base64 -d)
  assert_eq "$(jq -r '[.add,.port,.id,.net,.path,.host,.tls,.sni] | join("|")' <<<"$vm")" "203.0.113.10|8443|aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee|ws|/vmws|cdn.example.net|tls|cdn.example.net" "VMess WS TLS 链接（SNI 取自 CA 签发证书）"
  assert_eq "$(jq -r '.tls' <<<"$(grep '^vmess://' <<<"$links" | tail -n 1 | cut -c9- | base64 -d)")" "" "无 TLS 的 VMess"
  assert_not_contains "$links" "allowInsecure=1&type=ws" "CA 签发证书不设置 insecure"

  EXPORT_SERVER_ADDR=2001:db8::10
  nodes6=$(export_nodes_with_server)
  assert_contains "$(export_links "$nodes6")" "@[2001:db8::10]:8444" "IPv6 地址加方括号"
  t_teardown
)

section "节点导出：配置文件"
(
  t_setup
  t_install_singbox running
  t_install_xray
  neko_source
  export_prepare >/dev/null
  EXPORT_SERVER_ADDR=203.0.113.10
  nodes=$(export_nodes_with_server)
  sb=$(export_singbox "$nodes")
  jq -e . >/dev/null <<<"$sb"
  assert_rc $? 0 "Sing-box 配置为合法 JSON"
  assert_eq "$(jq '[.outbounds[] | select(.server)] | length' <<<"$sb")" 12 "Sing-box 节点数（省略 XHTTP）"
  assert_eq "$(jq -r '.outbounds[] | select(.tag == "vless-reality-alice") | .tls.reality.public_key' <<<"$sb")" hSDwCYkwp1R0i33ctD73Wg2_Og0mOBr066SpjqqbTmo "Sing-box REALITY 公钥"
  assert_eq "$(jq -r '.outbounds[] | select(.tag == "ss2022-dave") | .password' <<<"$sb")" "c2VydmVyUFNLMDEyMzQ1Ng==:dXNlclBTSzAxMjM0NTY3OA==" "Sing-box SS2022 密码"
  assert_eq "$(jq -r '.outbounds[] | select(.tag == "hy2-erin") | [.tls.insecure, .obfs.type] | map(tostring) | join(",")' <<<"$sb")" "true,salamander" "Sing-box Hysteria2 TLS/obfs"
  assert_eq "$(jq -r '.outbounds[0].type + ":" + (.outbounds[0].outbounds | length | tostring)' <<<"$sb")" "selector:13" "selector 包含 auto + 12 个节点"
  assert_eq "$(jq -r '.route.final' <<<"$sb")" proxy "路由默认走代理"
  assert_not_contains "$sb" "private_key" "Sing-box 配置不含服务端私钥"
  assert_not_contains "$sb" "listen_port\": 443" "未复制服务端入站"
  mh=$(export_mihomo "$nodes")
  bad=0
  while IFS= read -r l; do jq -e . >/dev/null 2>&1 <<<"${l#  - }" || bad=1; done < <(grep '^  - {' <<<"$mh")
  assert_eq "$bad" 0 "Mihomo 每个代理条目均为合法 JSON 流式映射"
  assert_eq "$(grep -c '^  - {"name"' <<<"$mh")" 14 "Mihomo 12 个代理 + 2 个策略组"
  assert_contains "$mh" '"reality-opts":{"public-key":"hSDwCYkwp1R0i33ctD73Wg2_Og0mOBr066SpjqqbTmo","short-id":"0123456789abcdef"}' "Mihomo REALITY 参数"
  assert_contains "$mh" '"type":"ss","cipher":"2022-blake3-aes-128-gcm"' "Mihomo SS2022"
  assert_contains "$mh" '"grpc-opts":{"grpc-service-name":"grpcsvc"}' "Mihomo gRPC"
  assert_contains "$mh" "  - MATCH,PROXY" "Mihomo 规则"
  if python -c 'import yaml' 2>/dev/null; then
    python -c 'import sys,yaml; d=yaml.safe_load(sys.stdin); assert len(d["proxies"])==12' <<<"$mh" && pass "PyYAML 解析 Mihomo 配置" || fail "PyYAML 解析 Mihomo 配置"
  fi
  t_teardown
)

section "节点导出：菜单与文件"
(
  t_setup
  t_install_singbox running
  export NEKO_EXPORT_DIR="$T/export"
  # 10 -> 8 (export all) -> address prompt (accept default) -> pause -> 0 -> 0
  out=$(neko_run '10\n8\n\n\n0\n0\n')
  assert_contains "$out" "可导出节点    ：8 个" "导出菜单节点统计"
  assert_contains "$out" "导出内容包含 UUID / 密码等凭据" "凭据提示"
  for f in nodes.txt subscription.txt singbox-config.json mihomo-config.yaml qr/node-01.png; do
    assert_file "$T/export/$f" "生成 $f"
  done
  assert_eq "$(base64 -d "$T/export/subscription.txt")" "$(cat "$T/export/nodes.txt")" "订阅为 nodes.txt 的 Base64"
  assert_eq "$(grep -c . "$T/export/nodes.txt")" 8 "nodes.txt 8 行"
  assert_contains "$(cat "$T/export/nodes.txt")" "@203.0.113.10:" "默认地址来自本机公网 IP"
  assert_eq "$(cat "$T/etc/neko.conf" 2>/dev/null | grep -c '^EXPORT_SERVER=203.0.113.10')" 1 "记住导出地址"
  assert_not_contains "$(cat "$T"/log/*.log)" "11111111-2222" "日志中无 UUID"
  assert_not_contains "$(cat "$T"/log/*.log)" "hy2pass" "日志中无密码"
  out=$(neko_run '10\n7\n/root/Neko-Export/subscription.txt\n\n0\n0\n')
  assert_contains "$out" "本地文件路径不能作为订阅链接" "拒绝本地路径作为订阅 URL"
  out=$(neko_run '10\n7\nhttps://sub.example.com/neko.txt\n\n0\n0\n')
  assert_file "$T/export/qr/subscription.png" "订阅二维码（用户提供的 HTTPS URL）"
  out=$(neko_run '10\n2\n\n1\n\n0\n0\n')
  assert_contains "$out" "vless://11111111-2222-4333-8444-555555555555@203.0.113.10:443" "导出单个节点链接"
  t_teardown
)
(
  t_setup
  t_install_singbox running
  printf '{"inbounds":[{"type":"vless","tag":"only-local","listen":"127.0.0.1","listen_port":9000,"users":[{"uuid":"12121212-3434-4565-8787-909090909090"}]}]}\n' >"$R/etc/sing-box/config.json"
  export NEKO_EXPORT_DIR="$T/export"
  out=$(neko_run '10\n8\n\n\n0\n0\n')
  assert_contains "$out" "没有可导出的节点，未生成任何文件。" "无可导出节点时不生成空文件"
  assert_no_file "$T/export/nodes.txt" "未生成空 nodes.txt"
  t_teardown
)
