# shellcheck shell=bash
# Neko - node & subscription export.
#
# Reads EXISTING sing-box / Xray server configs and builds client-side data:
# share links, an aggregated subscription, a sing-box client config and a
# Mihomo config. Nothing is guessed: a node is skipped (with the reason shown)
# whenever a value the client needs cannot be derived from the server config.
# REALITY public keys are derived from the private key locally; the private key
# itself never leaves this process.

[[ -n ${_NEKO_EXPORT_LOADED:-} ]] && return 0
_NEKO_EXPORT_LOADED=1

EXPORT_NODES='[]'   # normalised nodes (contains secrets: kept in memory only)
EXPORT_TMP=''

# ------------------------------------------------------------ jq: parsing --
read -r -d '' JQ_COMMON <<'JQ'
def arr: if . == null then [] elif type == "array" then . else [.] end;
def first_or($d): if type == "array" then (.[0] // $d) else (. // $d) end;
def loopback: . as $l | ($l | tostring) | test("^(127\\.|::1$|localhost$|\\[::1\\]$)");
JQ

read -r -d '' JQ_PARSE_SINGBOX <<'JQ'
def tls_info:
  (.tls // {}) as $t
  | { security: (if ($t.enabled // false) then (if ($t.reality.enabled // false) then "reality" else "tls" end) else "none" end),
      sni: ($t.server_name // ($t.acme.domain | arr | .[0]) // ""),
      alpn: ($t.alpn | arr),
      cert_path: ($t.certificate_path // ""),
      reality_private_key: ($t.reality.private_key // ""),
      reality_short_id: ($t.reality.short_id | first_or("")) };
def transport_info:
  (.transport // {}) as $x
  | { transport: ($x.type // "tcp"),
      path: ($x.path // (if ($x.type // "") | IN("ws", "httpupgrade", "http") then "/" else "" end)),
      host: (($x.headers.Host // $x.headers.host // $x.host // "") | first_or("")),
      service_name: ($x.service_name // "") };
(.inbounds // [])[]
| select(.type | IN("vless", "vmess", "trojan", "shadowsocks", "hysteria2", "tuic", "anytls"))
| . as $in
| ({ core: "sing-box", file: $file, tag: (.tag // .type), type: .type,
     listen: (.listen // "::"), port: .listen_port } + tls_info + transport_info) as $base
| if .type == "shadowsocks" then
    if ((.users // []) | length) > 0 then
      .users[] | $base + { user: (.name // ""), method: $in.method,
        password: (if ($in.method | startswith("2022-")) then "\($in.password):\(.password)" else .password end) }
    else $base + { user: "", method: .method, password: .password } end
  else
    (.users // [{}])[] as $u
    | $base + { user: ($u.name // ""), uuid: ($u.uuid // ""), password: ($u.password // ""),
                flow: ($u.flow // ""), alter_id: ($u.alterId // 0) }
    + (if $in.type == "hysteria2" then
         { obfs: ($in.obfs.type // ""), obfs_password: ($in.obfs.password // ""),
           up_mbps: ($in.up_mbps // 0), down_mbps: ($in.down_mbps // 0),
           ignore_client_bandwidth: ($in.ignore_client_bandwidth // false) }
       else {} end)
    + (if $in.type == "tuic" then { cc: ($in.congestion_control // "cubic") } else {} end)
  end
JQ

read -r -d '' JQ_PARSE_XRAY <<'JQ'
(.inbounds // [])[]
| select(.protocol | IN("vless", "vmess", "trojan", "shadowsocks"))
| . as $in
| (.streamSettings // {}) as $s
| (($s.network // "tcp") | if . == "raw" then "tcp" elif . == "splithttp" then "xhttp" elif . == "h2" then "http" else . end) as $net
| ($s.security // "none") as $sec
| { core: "xray", file: $file, tag: (.tag // .protocol), type: .protocol,
    listen: (.listen // "0.0.0.0"),
    port: (if (.port | type) == "number" then .port
           elif ((.port | type) == "string" and (.port | test("^[0-9]+$"))) then (.port | tonumber)
           else .port end),
    security: $sec,
    sni: (if $sec == "reality" then ($s.realitySettings.serverNames | first_or(""))
          elif $sec == "tls" then ($s.tlsSettings.serverName // "") else "" end),
    alpn: (if $sec == "tls" then ($s.tlsSettings.alpn | arr) else [] end),
    cert_path: (if $sec == "tls" then (($s.tlsSettings.certificates // [])[0].certificateFile // "") else "" end),
    reality_private_key: ($s.realitySettings.privateKey // ""),
    reality_short_id: ($s.realitySettings.shortIds | first_or("")),
    transport: $net,
    path: (if $net == "ws" then ($s.wsSettings.path // "/")
           elif $net == "httpupgrade" then ($s.httpupgradeSettings.path // "/")
           elif $net == "xhttp" then ($s.xhttpSettings.path // "/")
           elif $net == "http" then ($s.httpSettings.path // "/") else "" end),
    host: (if $net == "ws" then ($s.wsSettings.host // $s.wsSettings.headers.Host // "")
           elif $net == "httpupgrade" then ($s.httpupgradeSettings.host // "")
           elif $net == "xhttp" then ($s.xhttpSettings.host // "")
           elif $net == "http" then ($s.httpSettings.host | first_or("")) else "" end),
    service_name: ($s.grpcSettings.serviceName // ""),
    xhttp_mode: ($s.xhttpSettings.mode // ""),
    tcp_header: ($s.tcpSettings.header.type // $s.rawSettings.header.type // "none") } as $base
| if .protocol == "shadowsocks" then
    if ((.settings.clients // []) | length) > 0 then
      .settings.clients[] | $base + { user: (.email // ""), method: (.method // $in.settings.method),
        password: (if (($in.settings.method // "") | startswith("2022-")) then "\($in.settings.password):\(.password)" else .password end) }
    else $base + { user: "", method: .settings.method, password: .settings.password } end
  else
    (.settings.clients // [])[] as $c
    | $base + { user: ($c.email // ""), uuid: ($c.id // ""), password: ($c.password // ""),
                flow: ($c.flow // ""), alter_id: ($c.alterId // 0) }
    + (if $in.protocol == "vless" then { vless_decryption: ($in.settings.decryption // "none") } else {} end)
  end
JQ

# Marks nodes that cannot be exported, with a human readable reason.
read -r -d '' JQ_VALIDATE <<'JQ'
map(
  . + { skip: (
    if (.port | type) != "number" then "端口不是固定数字（\(.port)），无法确定客户端端口"
    elif (.listen | loopback) then "仅监听本地回环地址 \(.listen)（可能由反向代理转发），无法确定客户端连接参数"
    elif (.type == "vless" and (.vless_decryption // "none") != "none") then "使用 VLESS Encryption，暂不支持导出"
    elif ((.tcp_header // "none") != "none") then "TCP \(.tcp_header) 伪装暂不支持"
    elif (.transport | IN("tcp", "ws", "grpc", "http", "httpupgrade", "xhttp") | not) then "传输方式 \(.transport) 暂不支持"
    elif (.type | IN("vless", "vmess", "tuic")) and ((.uuid // "") == "") then "缺少 UUID"
    elif (.type | IN("trojan", "shadowsocks", "hysteria2", "tuic", "anytls")) and ((.password // "") == "") then "缺少密码"
    elif .type == "shadowsocks" and ((.method // "") == "") then "缺少加密方式"
    elif (.type | IN("trojan", "hysteria2", "tuic", "anytls")) and .security == "none" then "\(.type) 入站未启用 TLS（可能由反向代理终止 TLS）"
    elif .security == "reality" and (.reality_private_key == "") then "REALITY 配置缺少 private_key"
    else null end) })
JQ

# ------------------------------------------------------------ jq: output ---
read -r -d '' JQ_OUTPUT <<'JQ'
def enc: tostring | @uri;
def hostpart: if (.server | test(":")) then "[\(.server)]" else .server end;
def qs: to_entries | map(select(.value != null and .value != "")) | map("\(.key)=\(.value | enc)") | join("&");
def b64url: @base64 | gsub("\\+"; "-") | gsub("/"; "_") | gsub("=+$"; "");
def nn: if . == "" then null else . end;
def clean: walk(if type == "object" then with_entries(select(.value != null)) else . end);
def std_params:
  { security: .security, sni: .sni, alpn: (.alpn | join(",")),
    fp: (if .security != "none" then "chrome" else null end),
    pbk: (if .security == "reality" then .pbk else null end),
    sid: (if .security == "reality" then .reality_short_id else null end),
    type: .transport, path: (if .transport == "grpc" then null else .path end), host: .host,
    serviceName: (if .transport == "grpc" then .service_name else null end),
    mode: (.xhttp_mode // null),
    allowInsecure: (if .insecure then "1" else null end) };

def uri:
  if .type == "vless" then
    "vless://\(.uuid | enc)@\(hostpart):\(.port)?" + ({ encryption: "none", flow: .flow } + std_params | qs) + "#\(.name | enc)"
  elif .type == "vmess" then
    "vmess://" + ({ v: "2", ps: .name, add: .server, port: (.port | tostring), id: .uuid,
      aid: (.alter_id | tostring), scy: "auto", net: .transport, type: "none", host: .host,
      path: (if .transport == "grpc" then .service_name else .path end),
      tls: (if .security == "tls" then "tls" else "" end), sni: .sni, alpn: (.alpn | join(",")),
      fp: (if .security == "tls" then "chrome" else "" end) } | tojson | @base64)
  elif .type == "trojan" then
    "trojan://\(.password | enc)@\(hostpart):\(.port)?" + (std_params | qs) + "#\(.name | enc)"
  elif .type == "shadowsocks" then
    (if (.method | startswith("2022-")) then "\(.method | enc):\(.password | enc)"
     else ("\(.method):\(.password)" | b64url) end) as $ui
    | "ss://\($ui)@\(hostpart):\(.port)#\(.name | enc)"
  elif .type == "hysteria2" then
    "hysteria2://\(.password | enc)@\(hostpart):\(.port)/?" + ({ sni: .sni,
      obfs: (.obfs | nn), "obfs-password": (if .obfs != "" then .obfs_password else null end),
      alpn: (.alpn | join(",")), insecure: (if .insecure then "1" else "0" end) } | qs) + "#\(.name | enc)"
  elif .type == "tuic" then
    "tuic://\(.uuid | enc):\(.password | enc)@\(hostpart):\(.port)?" + ({ sni: .sni,
      alpn: (.alpn | join(",")), congestion_control: .cc, udp_relay_mode: "native",
      allow_insecure: (if .insecure then "1" else null end) } | qs) + "#\(.name | enc)"
  elif .type == "anytls" then
    "anytls://\(.password | enc)@\(hostpart):\(.port)/?" + ({ sni: .sni,
      insecure: (if .insecure then "1" else null end) } | qs) + "#\(.name | enc)"
  else empty end;

def sb_supported: .transport != "xhttp";
def sb_tls:
  if .security == "none" then null
  else { enabled: true, server_name: (.sni | nn), insecure: (if .insecure then true else null end),
         alpn: (if (.alpn | length) > 0 then .alpn else null end) }
     + (if .security == "reality" then
          { utls: { enabled: true, fingerprint: "chrome" },
            reality: { enabled: true, public_key: .pbk, short_id: .reality_short_id } }
        elif (.type | IN("vless", "vmess", "trojan")) then { utls: { enabled: true, fingerprint: "chrome" } }
        else {} end)
  end;
def sb_transport:
  if .transport == "ws" then { type: "ws", path: .path, headers: (if .host != "" then { Host: .host } else null end) }
  elif .transport == "grpc" then { type: "grpc", service_name: .service_name }
  elif .transport == "httpupgrade" then { type: "httpupgrade", path: .path, host: (.host | nn) }
  elif .transport == "http" then { type: "http", path: .path, host: (if .host != "" then [.host] else null end) }
  else null end;
def sb_outbound:
  ({ tag: .name, server: .server, server_port: .port }
   + (if .type == "vless" then { type: "vless", uuid: .uuid, flow: (.flow | nn), packet_encoding: "xudp", tls: sb_tls, transport: sb_transport }
      elif .type == "vmess" then { type: "vmess", uuid: .uuid, security: "auto", alter_id: .alter_id, tls: sb_tls, transport: sb_transport }
      elif .type == "trojan" then { type: "trojan", password: .password, tls: sb_tls, transport: sb_transport }
      elif .type == "shadowsocks" then { type: "shadowsocks", method: .method, password: .password }
      elif .type == "hysteria2" then { type: "hysteria2", password: .password,
             obfs: (if .obfs != "" then { type: .obfs, password: .obfs_password } else null end), tls: sb_tls }
      elif .type == "tuic" then { type: "tuic", uuid: .uuid, password: .password, congestion_control: .cc,
             udp_relay_mode: "native", tls: sb_tls }
      elif .type == "anytls" then { type: "anytls", password: .password, tls: sb_tls }
      else {} end))
  | clean;
def singbox_config:
  map(select(sb_supported)) as $n
  | ($n | map(.name)) as $names
  | { log: { level: "info", timestamp: true },
      dns: { servers: [ { tag: "remote", type: "https", server: "1.1.1.1", detour: "proxy" },
                        { tag: "local", type: "local" } ],
             final: "remote" },
      inbounds: [ { type: "mixed", tag: "mixed-in", listen: "127.0.0.1", listen_port: 2080 } ],
      outbounds: ([ { type: "selector", tag: "proxy", outbounds: (["auto"] + $names), default: "auto" },
                    { type: "urltest", tag: "auto", outbounds: $names,
                      url: "https://www.gstatic.com/generate_204", interval: "5m" } ]
                  + ($n | map(sb_outbound))
                  + [ { type: "direct", tag: "direct" } ]),
      route: { rules: [ { action: "sniff" },
                        { protocol: "dns", action: "hijack-dns" },
                        { ip_is_private: true, outbound: "direct" } ],
               final: "proxy", auto_detect_interface: true, default_domain_resolver: "local" } };

def mh_supported: .transport != "xhttp";
def mh_proxy:
  ({ name: .name, server: .server, port: .port, udp: true }
   + (if .type == "vless" then { type: "vless", uuid: .uuid, flow: (.flow | nn), "packet-encoding": "xudp" }
      elif .type == "vmess" then { type: "vmess", uuid: .uuid, alterId: .alter_id, cipher: "auto" }
      elif .type == "trojan" then { type: "trojan", password: .password }
      elif .type == "shadowsocks" then { type: "ss", cipher: .method, password: .password }
      elif .type == "hysteria2" then { type: "hysteria2", password: .password, obfs: (.obfs | nn),
             "obfs-password": (if .obfs != "" then .obfs_password else null end) }
      elif .type == "tuic" then { type: "tuic", uuid: .uuid, password: .password,
             "congestion-controller": .cc, "udp-relay-mode": "native" }
      elif .type == "anytls" then { type: "anytls", password: .password }
      else {} end)
   + (if .security == "none" then {}
      else (if (.type | IN("vless", "vmess")) then { tls: true, servername: (.sni | nn) } else { sni: (.sni | nn) } end)
         + { "skip-cert-verify": (if .insecure then true else null end),
             alpn: (if (.alpn | length) > 0 then .alpn else null end) }
         + (if (.type | IN("vless", "vmess", "trojan", "anytls")) then { "client-fingerprint": "chrome" } else {} end)
         + (if .security == "reality" then { "reality-opts": { "public-key": .pbk, "short-id": .reality_short_id } } else {} end)
      end)
   + (if (.type | IN("vless", "vmess", "trojan")) then
        (if .transport == "ws" then { network: "ws", "ws-opts": { path: .path, headers: (if .host != "" then { Host: .host } else null end) } }
         elif .transport == "httpupgrade" then { network: "ws", "ws-opts": { path: .path,
                headers: (if .host != "" then { Host: .host } else null end), "v2ray-http-upgrade": true } }
         elif .transport == "grpc" then { network: "grpc", "grpc-opts": { "grpc-service-name": .service_name } }
         elif .transport == "http" then { network: "h2", "h2-opts": { path: .path, host: (if .host != "" then [.host] else null end) } }
         else { network: "tcp" } end)
      else {} end))
  | clean;
JQ

# --------------------------------------------------------------- helpers ---
export_cleanup() {
  [[ -n $EXPORT_TMP && -d $EXPORT_TMP ]] && rm -rf "$EXPORT_TMP"
  EXPORT_TMP=''
}

export_tmp() {
  if [[ -z $EXPORT_TMP || ! -d $EXPORT_TMP ]]; then
    EXPORT_TMP=$(umask 077 && mktemp_dir) || return 1
  fi
  printf '%s' "$EXPORT_TMP"
}

# REALITY: X25519 public key from the base64url private key, computed locally.
reality_pubkey() { # reality_pubkey <private key> -> base64url public key
  local priv=$1 b64 hex pub out
  b64=${priv//-/+}
  b64=${b64//_//}
  case $((${#b64} % 4)) in
    2) b64+='==' ;;
    3) b64+='=' ;;
    1) return 1 ;;
  esac
  hex=$(printf '%s' "$b64" | base64 -d 2>/dev/null | od -An -v -tx1 | tr -d ' \n')
  [[ ${#hex} -eq 64 ]] || return 1
  if has_cmd openssl; then
    pub=$(hex_to_bin "302e020100300506032b656e04220420$hex" |
      openssl pkey -inform DER -outform DER -pubout 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n')
    [[ ${#pub} -eq 43 ]] && { printf '%s' "$pub"; return 0; }
  fi
  local xb=${PX_BIN[xray]:-}
  if [[ -n $xb ]]; then
    out=$(run_timeout 5 "$(sysp_exec "$xb")" x25519 -i "$priv" 2>/dev/null)
    pub=$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /^(public ?key|password)/ {print $2; exit}')
    [[ ${#pub} -eq 43 ]] && { printf '%s' "$pub"; return 0; }
  fi
  return 1
}

# Certificate facts: "selfsigned=<0|1> name=<first DNS SAN or CN>"
cert_info() {
  local f
  f=$(sysp "$1")
  [[ -r $f ]] && has_cmd openssl || return 1
  local subj iss san
  subj=$(openssl x509 -in "$f" -noout -subject -nameopt RFC2253 2>/dev/null) || return 1
  iss=$(openssl x509 -in "$f" -noout -issuer -nameopt RFC2253 2>/dev/null)
  san=$(openssl x509 -in "$f" -noout -ext subjectAltName 2>/dev/null | grep -o 'DNS:[^,]*' | head -n 1)
  san=${san#DNS:}
  if [[ -z $san && $subj =~ CN=([^,]+) ]]; then san=${BASH_REMATCH[1]}; fi
  printf 'selfsigned=%d name=%s\n' "$([[ ${subj#subject=} == "${iss#issuer=}" ]] && echo 1 || echo 0)" "$san"
}

# --------------------------------------------------------- collect nodes ---
# Parses every readable config of every detected core into EXPORT_NODES.
export_collect() {
  local core f real json out all='' prog
  EXPORT_NODES='[]'
  # Secrets only travel through stdin / here-strings, never through argv.
  for core in "${PROXY_CORES[@]}"; do
    [[ ${PX_CONF_STATE[$core]} == ok ]] || continue
    if [[ $core == singbox ]]; then prog="$JQ_COMMON"$'\n'"$JQ_PARSE_SINGBOX"; else prog="$JQ_COMMON"$'\n'"$JQ_PARSE_XRAY"; fi
    while IFS= read -r f; do
      [[ -n $f ]] || continue
      real=$(sysp "$f")
      json=$(json_load "$real") || continue
      out=$(jq -c --arg file "$f" "$prog" <<<"$json" 2>/dev/null) || {
        log_warn "export parse failed for $f"
        continue
      }
      [[ -n $out ]] && all+="$out"$'\n'
    done <<<"${PX_CONF_FILES[$core]}"
  done
  all=$(jq -sc "$JQ_COMMON"$'\n'"$JQ_VALIDATE" <<<"$all") || return 1

  # REALITY public keys
  local tmp keys k pub pairs=''
  export_tmp >/dev/null || return 1 # not $(...): EXPORT_TMP must be set in this shell
  tmp=$EXPORT_TMP
  keys=$(jq -r '.[] | select(.skip == null and .security == "reality") | .reality_private_key' <<<"$all" | sort -u)
  while IFS= read -r k; do
    [[ -n $k ]] || continue
    if pub=$(reality_pubkey "$k"); then
      pairs+="$k"$'\t'"$pub"$'\n'
    fi
  done <<<"$keys"
  (umask 077 && jq -Rn '[inputs | select(length > 0) | split("\t") | {(.[0]): .[1]}] | add // {}' <<<"$pairs" >"$tmp/reality.json")
  all=$(jq -c --slurpfile m "$tmp/reality.json" '
    map(if .security == "reality" and .skip == null then
          (if $m[0][.reality_private_key] then .pbk = $m[0][.reality_private_key]
           else .skip = "无法推导 REALITY 公钥（需要 openssl 1.1+ 或 xray），已跳过" end)
        else . end
        | del(.reality_private_key))' <<<"$all")
  rm -f "$tmp/reality.json"

  # TLS certificates: self-signed -> insecure; empty SNI -> name from the certificate
  # (facts travel as TSV on stdin and the map is read back from a file, so no
  # path ever goes through argv)
  local certs c info ss name rows=''
  certs=$(jq -r '.[] | select(.security == "tls" and .cert_path != "") | .cert_path' <<<"$all" | sort -u)
  while IFS= read -r c; do
    [[ -n $c ]] || continue
    info=$(cert_info "$c") || continue
    ss=${info#selfsigned=}
    ss=${ss%% *}
    name=${info#*name=}
    rows+="$c"$'\t'"$ss"$'\t'"$name"$'\n'
  done <<<"$certs"
  (umask 077 && jq -Rn '[inputs | select(length > 0) | split("\t")
      | {(.[0]): {selfsigned: (.[1] == "1"), name: (.[2] // "")}}] | add // {}' <<<"$rows" >"$tmp/certs.json")
  all=$(jq -c --slurpfile cms "$tmp/certs.json" '
    $cms[0] as $cm
    | map(. as $n | ($cm[$n.cert_path // ""] // null) as $ci
        | .insecure = (if $ci then $ci.selfsigned else false end)
        | (if .sni == "" and $ci and $ci.name != "" then .sni = $ci.name else . end)
        | del(.cert_path))' <<<"$all")
  rm -f "$tmp/certs.json"

  # Names: tag[-user], unique
  all=$(jq -c '
    reduce .[] as $n ({ out: [], seen: {} };
      ($n.tag + (if ($n.user // "") != "" then "-" + $n.user else "" end)) as $b
      | (.seen[$b] // 0) as $c
      | .seen[$b] = $c + 1
      | .out += [$n + { name: (if $c == 0 then $b else "\($b)-\($c + 1)" end) }])
    | .out' <<<"$all")
  EXPORT_NODES=$all
}

export_count() { jq "[.[] | select(.skip == null)] | length" <<<"$EXPORT_NODES"; }

# Asks for (or confirms) the address clients should connect to.
export_resolve_server() {
  local def
  def=$(config_get EXPORT_SERVER)
  [[ -n $def ]] || def=$(net_public_ipv4) || def=$(net_public_ipv6) || def=''
  if [[ -n ${EXPORT_SERVER_OVERRIDE:-} ]]; then
    def=$EXPORT_SERVER_OVERRIDE
  else
    ui_note "客户端连接地址：可填写域名或公网 IP。默认值来自本机网卡上的公网地址（未访问外部服务）。"
    [[ -z $def ]] && ui_warn "本机网卡上没有公网地址（可能位于 NAT 之后），请手动填写。"
    ui_prompt "节点地址" "$def" || return 1
    def=$REPLY_INPUT
  fi
  def=${def#[}
  def=${def%]}
  if ! validate_host "$def"; then
    ui_err "无效的地址：${def}"
    return 1
  fi
  EXPORT_SERVER_ADDR=$def
  if is_root && [[ $def != "$(config_get EXPORT_SERVER)" ]]; then
    config_set EXPORT_SERVER "$def" || true
  fi
}

export_nodes_with_server() {
  jq -c --arg s "$EXPORT_SERVER_ADDR" '[.[] | select(.skip == null) | .server = $s]' <<<"$EXPORT_NODES"
}

# Common entry: scan, check prerequisites, parse. Returns 1 with a clear message.
export_prepare() {
  proxy_scan
  if ! proxy_any_installed; then
    ui_header "节点与订阅导出"
    echo
    ui_err "无法执行节点导出。"
    echo
    echo "原因："
    echo "未检测到可用的代理服务端及配置文件。"
    echo
    echo "请先确认 VPS 上是否已经部署受支持的代理服务。"
    echo
    echo "Neko 不会自动安装代理服务端。"
    echo
    ui_item 0 返回主菜单
    return 1
  fi
  if ! proxy_any_config_ok; then
    ui_header "节点与订阅导出"
    echo
    ui_err "无法执行节点导出。"
    echo
    echo "原因："
    local core
    for core in "${PROXY_CORES[@]}"; do
      [[ ${PX_STATE[$core]} == not_installed ]] && continue
      case ${PX_CONF_STATE[$core]} in
        missing) echo "${PX_LABEL[$core]} 已安装，但未找到可识别的配置文件。" ;;
        unreadable)
          echo "${PX_LABEL[$core]} 的配置文件不可读取：${PX_CONF_MSG[$core]}"
          is_root || echo "代理配置通常仅 root 可读，请使用 sudo neko 重新运行。"
          ;;
        parse_error) echo "${PX_LABEL[$core]} 的配置解析失败：${PX_CONF_MSG[$core]}" ;;
      esac
    done
    echo
    echo "Neko 不会生成虚假的节点链接或空配置文件。"
    return 1
  fi
  if ! has_cmd jq; then
    ui_err "缺少 jq，无法解析配置（apt install jq）。"
    return 1
  fi
  export_collect || { ui_err "配置解析失败。"; return 1; }
  return 0
}

export_print_table() {
  local n
  n=$(jq 'length' <<<"$EXPORT_NODES")
  ui_section "已识别的入站（共 ${n} 个）"
  if ((n == 0)); then
    ui_warn "配置中没有受支持协议的入站（VLESS/VMess/Trojan/Shadowsocks/Hysteria2/TUIC/AnyTLS）。"
    return 1
  fi
  local i=0 name type port tr sec core skip
  while IFS=$'\t' read -r name type port tr sec core skip; do
    ((i++))
    if [[ -z $skip ]]; then
      printf '  %s%2d.%s %-26s %-11s %-5s %-11s %-8s %s\n' "$C_GREEN" "$i" "$C_RESET" "$name" "$type" "$port" "$tr" "$sec" "$core"
    else
      printf '  %s%2d. %-26s %-11s %-5s 跳过：%s%s\n' "$C_DIM" "$i" "$name" "$type" "$port" "$skip" "$C_RESET"
    fi
  done < <(jq -r '.[] | [.name, .type, (.port | tostring), .transport, .security, .core, (.skip // "")] | @tsv' <<<"$EXPORT_NODES")
  return 0
}

export_dir() {
  local d
  d=$(config_get EXPORT_DIR)
  printf '%s' "${NEKO_EXPORT_DIR:-$d}"
}

export_write_file() { # export_write_file <path> : stdin -> file (0600)
  (umask 077 && mkdir -p "$(dirname "$1")" && cat >"$1") && chmod 600 "$1"
}

export_links() { jq -r "$JQ_OUTPUT"$'\n''.[] | uri' <<<"$1"; }

export_singbox() { jq "$JQ_OUTPUT"$'\n''singbox_config' <<<"$1"; }

export_mihomo() { # export_mihomo <nodes json> -> YAML (proxies as JSON flow mappings)
  local nodes=$1 names
  names=$(jq -c "$JQ_OUTPUT"$'\n''[.[] | select(mh_supported) | .name]' <<<"$nodes")
  cat <<'YAML'
# Generated by Neko VPS Network Optimizer
# Mihomo (Clash.Meta) client configuration. Contains credentials: keep it private.
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: true
unified-delay: true
proxies:
YAML
  jq -c "$JQ_OUTPUT"$'\n''.[] | select(mh_supported) | mh_proxy' <<<"$nodes" | sed 's/^/  - /'
  printf 'proxy-groups:\n'
  printf '  - {"name":"PROXY","type":"select","proxies":%s}\n' "$(jq -c '["AUTO"] + . + ["DIRECT"]' <<<"$names")"
  printf '  - {"name":"AUTO","type":"url-test","url":"https://www.gstatic.com/generate_204","interval":300,"proxies":%s}\n' "$names"
  cat <<'YAML'
rules:
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR6,::1/128,DIRECT,no-resolve
  - IP-CIDR6,fc00::/7,DIRECT,no-resolve
  - MATCH,PROXY
YAML
}

export_unsupported_notes() { # nodes json
  local x
  x=$(jq -r '[.[] | select(.transport == "xhttp") | .name] | join(", ")' <<<"$1")
  [[ -n $x ]] && ui_note "XHTTP 节点（${x}）仅导出分享链接，sing-box / Mihomo 配置中已省略。"
}

export_qr() { # export_qr <text> [png path]
  if ! has_cmd qrencode; then
    ui_warn "未安装 qrencode，无法生成二维码（apt install qrencode）。"
    return 1
  fi
  qrencode -t ANSIUTF8 -m 1 -- "$1"
  if [[ -n ${2:-} ]]; then
    (umask 077 && mkdir -p "$(dirname "$2")") && qrencode -t PNG -s 6 -o "$2" -- "$1" && chmod 600 "$2" &&
      ui_ok "二维码已保存：$2"
  fi
}

export_pick_node() { # sets REPLY_NODE (json) ; uses exportable nodes only
  local nodes=$1 n i=0 name
  n=$(jq 'length' <<<"$nodes")
  ((n > 0)) || { ui_err "没有可导出的节点。"; return 1; }
  while IFS= read -r name; do
    ((i++))
    ui_item "$i" "$name"
  done < <(jq -r '.[] | "\(.name)  (\(.type)/\(.transport)/\(.security) :\(.port))"' <<<"$nodes")
  ui_back_item 返回
  ui_read_choice "$n" || return 1
  ((REPLY_CHOICE == 0)) && return 1
  REPLY_NODE=$(jq -c ".[$((REPLY_CHOICE - 1))]" <<<"$nodes")
}

export_secret_notice() {
  ui_warn "导出内容包含 UUID / 密码等凭据，请勿公开分享。文件权限为 600。"
}

export_write_all() { # export_write_all <nodes json> <dir> [what: all|links|singbox|mihomo]
  local nodes=$1 dir=$2 what=${3:-all}
  case $what in
    all | links)
      export_links "$nodes" | export_write_file "$dir/nodes.txt" || return 1
      base64 -w 0 "$dir/nodes.txt" | export_write_file "$dir/subscription.txt" || return 1
      ui_ok "分享链接：$dir/nodes.txt"
      ui_ok "聚合订阅（Base64）：$dir/subscription.txt"
      ;;&
    all | singbox)
      export_singbox "$nodes" | export_write_file "$dir/singbox-config.json" || return 1
      ui_ok "Sing-box 配置：$dir/singbox-config.json（面向 sing-box 1.12+）"
      ;;&
    all | mihomo)
      export_mihomo "$nodes" | export_write_file "$dir/mihomo-config.yaml" || return 1
      ui_ok "Mihomo 配置：$dir/mihomo-config.yaml"
      ;;
  esac
  [[ $what == links ]] || export_unsupported_notes "$nodes"
  chmod 700 "$dir" 2>/dev/null
  log_info "export ${what} -> ${dir} ($(jq length <<<"$nodes") nodes)"
}

export_menu() {
  if ! export_prepare; then
    while true; do
      ui_read_choice 0 || break
      ((REPLY_CHOICE == 0)) && break
    done
    export_cleanup
    return 0
  fi
  local nodes dir
  while true; do
    ui_header "节点与订阅导出"
    ui_kv "可导出节点" "$(export_count) 个"
    ui_kv "导出目录" "$(export_dir)"
    echo
    ui_item 1 "扫描现有代理配置"
    ui_item 2 "导出单个节点分享链接"
    ui_item 3 "导出聚合订阅"
    ui_item 4 "导出 Sing-box 配置文件"
    ui_item 5 "导出 Mihomo 配置文件"
    ui_item 6 "生成节点二维码"
    ui_item 7 "生成订阅二维码"
    ui_item 8 "批量导出全部内容"
    ui_back_item
    ui_read_choice 8 || break
    ((REPLY_CHOICE == 0)) && break
    local act=$REPLY_CHOICE # sub-prompts overwrite REPLY_CHOICE
    dir=$(export_dir)
    case $act in
      1)
        export_prepare >/dev/null && export_print_table
        ;;
      2 | 6)
        export_resolve_server || { ui_pause; continue; }
        nodes=$(export_nodes_with_server)
        export_pick_node "$nodes" || continue
        local link name
        link=$(export_links "[$REPLY_NODE]")
        name=$(jq -r '.name' <<<"$REPLY_NODE")
        echo
        if ((act == 2)); then
          export_secret_notice
          printf '%s\n' "$link"
        else
          local idx
          idx=$(jq --arg n "$name" 'map(.name) | index($n) + 1' <<<"$nodes")
          printf -v idx '%02d' "$idx"
          export_qr "$link" "$dir/qr/node-${idx}.png"
        fi
        ;;
      3 | 4 | 5 | 8)
        export_resolve_server || { ui_pause; continue; }
        nodes=$(export_nodes_with_server)
        if [[ $(jq length <<<"$nodes") == 0 ]]; then
          ui_err "没有可导出的节点，未生成任何文件。"
          export_print_table
        else
          export_secret_notice
          case $act in
            3) export_write_all "$nodes" "$dir" links ;;
            4) export_write_all "$nodes" "$dir" singbox ;;
            5) export_write_all "$nodes" "$dir" mihomo ;;
            8)
              export_write_all "$nodes" "$dir" all
              if has_cmd qrencode; then
                local i=0 l
                while IFS= read -r l; do
                  ((i++))
                  printf -v n '%02d' "$i"
                  (umask 077 && mkdir -p "$dir/qr") && qrencode -t PNG -s 6 -o "$dir/qr/node-${n}.png" -- "$l" && chmod 600 "$dir/qr/node-${n}.png"
                done <"$dir/nodes.txt"
                ui_ok "节点二维码：$dir/qr/node-*.png（${i} 个）"
              else
                ui_note "未安装 qrencode，跳过二维码生成。"
              fi
              ;;
          esac
        fi
        ;;
      7)
        ui_note "订阅二维码需要一个可公开访问的 HTTPS 地址。Neko 只生成本地文件，不会开放端口托管订阅，"
        ui_note "请先将 subscription.txt 上传到你自己的 HTTPS 服务，再输入其完整 URL。"
        ui_prompt "订阅 URL（https://...，留空取消）" || { ui_pause; continue; }
        if [[ -z $REPLY_INPUT ]]; then
          ui_info "已取消。"
        elif ! validate_https_url "$REPLY_INPUT"; then
          ui_err "必须是有效的 https:// 地址；本地文件路径不能作为订阅链接。"
        else
          export_qr "$REPLY_INPUT" "$dir/qr/subscription.png"
        fi
        ;;
    esac
    ui_pause
  done
  export_cleanup
}
