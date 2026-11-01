# shellcheck shell=bash
# Neko - service, process and listening-socket inspection (read-only).

[[ -n ${_NEKO_SERVICES_LOADED:-} ]] && return 0
_NEKO_SERVICES_LOADED=1

SVC_UNIT_DIRS=(/etc/systemd/system /run/systemd/system /usr/local/lib/systemd/system /lib/systemd/system /usr/lib/systemd/system)

svc_has_systemd() { has_cmd systemctl && [[ -d $(sysp /run/systemd/system) ]]; }

svc_unit_file() { # svc_unit_file <name>: real path of <name>.service (sysroot aware)
  local d f
  for d in "${SVC_UNIT_DIRS[@]}"; do
    f=$(sysp "$d/$1.service")
    [[ -f $f || -L $f ]] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

svc_exists() { svc_unit_file "$1" >/dev/null; }

svc_state() { # active | inactive | failed | activating | unknown
  local s
  has_cmd systemctl || { echo unknown; return; }
  s=$(systemctl is-active "$1" 2>/dev/null) || true
  printf '%s' "${s:-unknown}"
}

svc_is_active() { [[ $(svc_state "$1") == active ]]; }

svc_enabled_state() {
  local s
  has_cmd systemctl || { echo unknown; return; }
  s=$(systemctl is-enabled "$1" 2>/dev/null) || true
  printf '%s' "${s:-unknown}"
}

# Effective ExecStart command line of a unit (drop-ins override the main file).
svc_exec_start() {
  local unit f d line val='' files=()
  unit=$(svc_unit_file "$1") || return 1
  files=("$unit")
  for d in "${SVC_UNIT_DIRS[@]}"; do
    for f in "$(sysp "$d/$1.service.d")"/*.conf; do
      [[ -f $f ]] && files+=("$f")
    done
  done
  for f in "${files[@]}"; do
    while IFS= read -r line; do
      line=$(trim "$line")
      [[ $line == ExecStart=* ]] || continue
      line=${line#ExecStart=}
      line=${line#[-@+!:]}
      line=${line#[-@+!:]}
      val=$line # an empty ExecStart= resets, the last non-empty one wins
    done <"$f"
  done
  [[ -n $val ]] || return 1
  printf '%s' "$val"
}

# Processes whose executable basename matches one of the patterns.
# Output: "pid<TAB>args" lines.
proc_find() { # proc_find <glob>...
  local pid args exe p
  while read -r pid args; do
    [[ -n $pid && -n $args ]] || continue
    exe=${args%% *}
    exe=${exe##*/}
    for p in "$@"; do
      # shellcheck disable=SC2053
      if [[ $exe == $p ]]; then
        printf '%s\t%s\n' "$pid" "$args"
        break
      fi
    done
  done < <(ps -eo pid=,args= 2>/dev/null)
}

# Listening sockets of a PID: "tcp:443 udp:8443" (needs root to see other users' sockets).
ss_ports_of_pid() {
  has_cmd ss || return 1
  ss -Hlntup 2>/dev/null | awk -v pid="pid=$1," '
    index($0, pid) {
      n = split($5, a, ":"); port = a[n]
      key = $1 ":" port
      if (!(key in seen)) { seen[key] = 1; out = out (out ? " " : "") key }
    }
    END { print out }'
}

# UDP listeners: "port<TAB>process" lines.
ss_udp_listeners() {
  has_cmd ss || return 1
  ss -Hulnp 2>/dev/null | awk '{
    n = split($4, a, ":"); port = a[n]; proc = "-"
    if (match($0, /users:\(\("[^"]+"/)) proc = substr($0, RSTART + 9, RLENGTH - 10)
    print port "\t" proc
  }' | sort -u
}

# Network-related services shown in the system report.
NET_SERVICES=(systemd-networkd NetworkManager networking systemd-resolved resolvconf cloud-init ufw firewalld nftables netfilter-persistent dnsmasq unbound cloudflared)

svc_report_network() {
  local s st
  ui_section "网络相关服务"
  if ! has_cmd systemctl; then
    ui_note "未检测到 systemctl，跳过服务状态检测。"
    return
  fi
  for s in "${NET_SERVICES[@]}"; do
    if ! svc_exists "$s"; then
      continue
    fi
    st=$(svc_state "$s")
    case $st in
      active) ui_kv "$s" "$(ui_status good 运行中)" 22 ;;
      failed) ui_kv "$s" "$(ui_status bad 失败)" 22 ;;
      *) ui_kv "$s" "已安装，${st}" 22 ;;
    esac
  done
}
