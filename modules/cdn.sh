# shellcheck shell=bash
# Neko - CDN / reverse proxy inspection (Nginx, Caddy, HAProxy, Apache).
# Read-only: findings and suggestions only, configuration files are never edited.

[[ -n ${_NEKO_CDN_LOADED:-} ]] && return 0
_NEKO_CDN_LOADED=1

CDN_FINDINGS=0

cdn_find() { # cdn_find <good|warn|info> <text>
  ((CDN_FINDINGS++))
  case $1 in
    good) ui_ok "$2" ;;
    warn) ui_warn "$2" ;;
    *) ui_info "$2" ;;
  esac
}

cdn_web_state() { # cdn_web_state <binary> <unit> -> text
  local bin=$1 unit=$2 st
  if ! has_cmd "$bin" && ! svc_exists "$unit"; then
    echo none
    return
  fi
  st=$(svc_state "$unit")
  if [[ $st == active || -n $(proc_find "$bin") ]]; then echo running; else echo stopped; fi
}

cdn_nginx() {
  local st conf ver
  st=$(cdn_web_state nginx nginx)
  [[ $st == none ]] && return 1
  ui_section "Nginx"
  ver=$(nginx -v 2>&1 | sed 's/^nginx version: //')
  ui_kv "版本" "${ver:-未知}"
  ui_kv "状态" "$( [[ $st == running ]] && ui_status good 运行中 || ui_status warn 已安装未运行)"
  if ! conf=$(nginx -T 2>/dev/null) || [[ -z $conf ]]; then
    if is_root; then ui_warn "nginx -T 执行失败（配置可能存在语法错误）。"; else ui_note "读取完整配置需要 root（nginx -T）。"; fi
    return 0
  fi
  conf=$(sed 's/#.*$//' <<<"$conf")
  cdn_nginx_analyze "$conf" "$ver"
}

cdn_nginx_analyze() { # cdn_nginx_analyze <config text> <version>
  local conf=$1 ver=$2
  if grep -Eq 'listen[^;]*\bhttp2\b|^\s*http2\s+on' <<<"$conf"; then cdn_find good "已启用 HTTP/2。"; else
    grep -Eq 'listen[^;]*\bssl\b' <<<"$conf" && cdn_find warn "存在 TLS 监听但未启用 HTTP/2（1.25.1+ 使用 'http2 on;'，旧版本在 listen 中加 http2）。"
  fi
  if grep -Eq 'listen[^;]*\bquic\b|^\s*http3\s+on' <<<"$conf"; then
    cdn_find good "已启用 HTTP/3（QUIC）。请确认防火墙放行 UDP 443。"
    grep -Eq 'add_header\s+Alt-Svc' <<<"$conf" || cdn_find warn "启用了 QUIC 但未发现 Alt-Svc 响应头，浏览器可能不会切换到 HTTP/3。"
  else
    cdn_find info "未启用 HTTP/3（需要 nginx 1.25+ 编译了 http_v3_module）。"
  fi
  if grep -Eq 'ssl_protocols[^;]*TLSv1\.3' <<<"$conf"; then
    cdn_find good "ssl_protocols 包含 TLSv1.3。"
  elif grep -Eq 'ssl_protocols' <<<"$conf"; then
    cdn_find warn "ssl_protocols 未包含 TLSv1.3，建议：ssl_protocols TLSv1.2 TLSv1.3;"
  fi
  grep -Eq 'ssl_protocols[^;]*(SSLv3|TLSv1(\s|;)|TLSv1\.1)' <<<"$conf" && cdn_find warn "启用了已废弃的 TLSv1/TLSv1.1/SSLv3，建议移除。"
  grep -Eq 'ssl_session_cache' <<<"$conf" || { grep -Eq 'listen[^;]*\bssl\b' <<<"$conf" && cdn_find warn "未设置 ssl_session_cache，建议：ssl_session_cache shared:SSL:10m; 以复用 TLS 会话。"; }
  grep -Eq 'ssl_early_data\s+on' <<<"$conf" && cdn_find warn "启用了 TLS 0-RTT（ssl_early_data），存在重放风险，仅对幂等请求安全。"
  if grep -Eq 'proxy_pass' <<<"$conf"; then
    if grep -Eq 'proxy_set_header\s+Upgrade' <<<"$conf"; then
      cdn_find good "反向代理已透传 WebSocket Upgrade 头。"
    else
      cdn_find warn "存在 proxy_pass 但未设置 Upgrade/Connection 头，WebSocket 将无法建立："
      ui_note "proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \"upgrade\";"
    fi
    grep -Eq 'proxy_http_version\s+1\.1' <<<"$conf" || cdn_find warn "未设置 proxy_http_version 1.1，上游连接无法 keepalive / WebSocket。"
    if grep -Eq 'proxy_buffering\s+off' <<<"$conf"; then
      cdn_find info "部分 location 关闭了 proxy_buffering（适合 gRPC/流式传输/WebSocket 代理）。"
    fi
    grep -Eq 'proxy_read_timeout' <<<"$conf" || cdn_find info "未设置 proxy_read_timeout（默认 60s），长连接代理（WebSocket/gRPC）空闲 60 秒会被断开。"
  fi
  grep -Eq 'grpc_pass' <<<"$conf" && { grep -Eq 'grpc_read_timeout' <<<"$conf" || cdn_find info "存在 grpc_pass 但未设置 grpc_read_timeout（默认 60s）。"; }
  if grep -Eq 'keepalive_timeout\s+0' <<<"$conf"; then cdn_find warn "keepalive_timeout 为 0，客户端 keepalive 被关闭。"; fi
  grep -Eq '^\s*gzip\s+on' <<<"$conf" && cdn_find good "已启用 gzip。" || cdn_find info "未启用 gzip（仅对网站文本内容有意义，代理流量无需压缩）。"
  grep -Eq '^\s*brotli\s+on' <<<"$conf" && cdn_find good "已启用 Brotli。"
  grep -Eq 'worker_connections\s+([0-9]+)' <<<"$conf" && {
    local wc
    wc=$(grep -Eo 'worker_connections\s+[0-9]+' <<<"$conf" | head -n 1 | grep -Eo '[0-9]+')
    ((wc < 1024)) && cdn_find warn "worker_connections=${wc} 偏小，高并发代理建议 ≥ 4096。"
  }
}

cdn_caddy() {
  local st conf f
  st=$(cdn_web_state caddy caddy)
  [[ $st == none ]] && return 1
  ui_section "Caddy"
  ui_kv "版本" "$(caddy version 2>/dev/null | awk '{print $1}')"
  ui_kv "状态" "$( [[ $st == running ]] && ui_status good 运行中 || ui_status warn 已安装未运行)"
  cdn_find info "Caddy 默认启用 HTTP/1.1、HTTP/2、HTTP/3 与 TLS 1.2/1.3，reverse_proxy 自动支持 WebSocket。"
  f=$(sysp /etc/caddy/Caddyfile)
  if [[ ! -r $f ]]; then
    ui_note "无法读取 /etc/caddy/Caddyfile。"
    return 0
  fi
  conf=$(sed 's/#.*$//' "$f")
  grep -Eq '^\s*encode\b' <<<"$conf" && cdn_find good "已配置 encode 压缩。" || cdn_find info "未配置 encode（网站内容可加 encode zstd gzip）。"
  if grep -Eq 'protocols\s+' <<<"$conf" && ! grep -Eq 'protocols[^\n]*h3' <<<"$conf"; then
    cdn_find warn "servers.protocols 中未包含 h3，HTTP/3 被关闭。"
  fi
  grep -Eq 'flush_interval\s+-1' <<<"$conf" && cdn_find info "reverse_proxy 设置了 flush_interval -1（适合流式/gRPC）。"
  cdn_find info "如使用 HTTP/3，请确认防火墙放行 UDP 443。"
}

cdn_haproxy() {
  local st f conf
  st=$(cdn_web_state haproxy haproxy)
  [[ $st == none ]] && return 1
  ui_section "HAProxy"
  ui_kv "版本" "$(haproxy -v 2>/dev/null | head -n 1 | awk '{print $3}')"
  ui_kv "状态" "$( [[ $st == running ]] && ui_status good 运行中 || ui_status warn 已安装未运行)"
  f=$(sysp /etc/haproxy/haproxy.cfg)
  [[ -r $f ]] || { ui_note "无法读取 /etc/haproxy/haproxy.cfg。"; return 0; }
  conf=$(sed 's/#.*$//' "$f")
  grep -Eq 'alpn\s+h2' <<<"$conf" && cdn_find good "TLS 监听已协商 h2。" || { grep -Eq '\sssl\s' <<<"$conf" && cdn_find warn "bind ... ssl 未设置 alpn h2,http/1.1，HTTP/2 未启用。"; }
  grep -Eq 'quic4@|quic6@' <<<"$conf" && cdn_find good "已配置 QUIC（HTTP/3）监听。"
  grep -Eq 'timeout\s+tunnel' <<<"$conf" || cdn_find warn "未设置 timeout tunnel，WebSocket 等长连接会按 timeout client/server 被断开。"
  grep -Eq 'ssl-min-ver\s+TLSv1\.[23]' <<<"$conf" || cdn_find info "未设置 ssl-min-ver，建议 ssl-min-ver TLSv1.2。"
  grep -Eq 'http-reuse' <<<"$conf" || cdn_find info "未设置 http-reuse（默认 safe）。"
}

cdn_apache() {
  local st bin=apache2 unit=apache2 mods
  has_cmd apache2 || { has_cmd httpd && bin=httpd unit=httpd; }
  st=$(cdn_web_state "$bin" "$unit")
  [[ $st == none ]] && return 1
  ui_section "Apache"
  ui_kv "状态" "$( [[ $st == running ]] && ui_status good 运行中 || ui_status warn 已安装未运行)"
  if has_cmd apache2ctl; then mods=$(apache2ctl -M 2>/dev/null); elif has_cmd apachectl; then mods=$(apachectl -M 2>/dev/null); fi
  [[ -n ${mods:-} ]] || { ui_note "无法列出模块（需要 root）。"; return 0; }
  grep -q http2_module <<<"$mods" && cdn_find good "已加载 mod_http2。" || cdn_find warn "未加载 mod_http2（a2enmod http2，并设置 Protocols h2 http/1.1）。"
  grep -q proxy_wstunnel_module <<<"$mods" && cdn_find good "已加载 mod_proxy_wstunnel（WebSocket 代理）。"
  grep -Eq 'deflate_module|brotli_module' <<<"$mods" && cdn_find good "已加载压缩模块。"
  grep -q mpm_prefork_module <<<"$mods" && cdn_find warn "使用 prefork MPM，与 HTTP/2 不兼容，建议切换到 event MPM。"
}

# Live probe of a public hostname (optional, user supplied).
cdn_probe() {
  has_cmd curl || { ui_warn "未安装 curl。"; return 1; }
  ui_prompt "输入要检测的域名（将向该域名发起 3-4 次 HTTPS 请求，留空跳过）" || return 0
  local host=$REPLY_INPUT
  [[ -n $host ]] || return 0
  validate_domain "$host" || { ui_err "无效的域名。"; return 1; }
  ui_section "在线检测：${host}"
  local hdr code ver
  hdr=$(curl -sS -I -m 10 --http2 "https://$host/" 2>&1)
  if [[ $? -ne 0 ]]; then
    ui_err "HTTPS 请求失败：$(head -n 1 <<<"$hdr")"
    return 1
  fi
  ver=$(head -n 1 <<<"$hdr" | awk '{print $1}')
  code=$(head -n 1 <<<"$hdr" | awk '{print $2}')
  ui_kv "协议" "${ver}（HTTP ${code}）"
  grep -qi '^alt-svc:.*h3' <<<"$hdr" && ui_kv "HTTP/3" "Alt-Svc 声明 h3" || ui_kv "HTTP/3" "未声明"
  if curl -V 2>/dev/null | grep -q HTTP3; then
    curl -s -o /dev/null -m 10 --http3-only "https://$host/" 2>/dev/null && ui_kv "HTTP/3 实测" "$(ui_status good 可用)" || ui_kv "HTTP/3 实测" "不可用"
  fi
  if curl -s -o /dev/null -m 10 --tlsv1.3 --tls-max 1.3 "https://$host/" 2>/dev/null; then
    ui_kv "TLS 1.3" "$(ui_status good 支持)"
  else
    ui_kv "TLS 1.3" "$(ui_status warn 不支持或握手失败)"
  fi
  if grep -qi '^cf-ray:' <<<"$hdr" || grep -qi '^server: cloudflare' <<<"$hdr"; then
    ui_kv "CDN" "Cloudflare"
  elif grep -qiE '^(x-amz-cf-id|via:.*cloudfront)' <<<"$hdr"; then
    ui_kv "CDN" "Amazon CloudFront"
  elif grep -qi '^x-served-by:.*cache' <<<"$hdr"; then
    ui_kv "CDN" "Fastly"
  else
    ui_kv "CDN" "未识别（可能为直连源站）"
  fi
  local enc
  enc=$(curl -s -o /dev/null -m 10 -H 'Accept-Encoding: br, gzip' -w '%{content_type}' -D - "https://$host/" 2>/dev/null | grep -i '^content-encoding:' | awk '{print $2}' | tr -d '\r')
  ui_kv "压缩" "${enc:-无}"
}

cdn_menu() {
  while true; do
    ui_header "CDN / 反向代理优化"
    ui_item 1 "检测本机 Web 服务（Nginx / Caddy / HAProxy / Apache）"
    ui_item 2 "在线检测域名（HTTP/2、HTTP/3、TLS 1.3、CDN、压缩）"
    ui_back_item
    ui_read_choice 2 || return 0
    case $REPLY_CHOICE in
      0) return 0 ;;
      1)
        ui_header "本机 Web 服务检测"
        ui_note "只读检测，不会修改任何配置文件。"
        CDN_FINDINGS=0
        local any=0
        cdn_nginx && any=1
        cdn_caddy && any=1
        cdn_haproxy && any=1
        cdn_apache && any=1
        ((any)) || ui_info "未检测到 Nginx / Caddy / HAProxy / Apache。"
        ;;
      2) cdn_probe ;;
    esac
    ui_pause
  done
}
