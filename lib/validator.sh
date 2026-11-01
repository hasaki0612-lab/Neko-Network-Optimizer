# shellcheck shell=bash
# Neko - input validation. Every user-supplied value is checked here before it
# reaches a config file or a command line.

[[ -n ${_NEKO_VALIDATOR_LOADED:-} ]] && return 0
_NEKO_VALIDATOR_LOADED=1

validate_uint() { [[ $1 =~ ^[0-9]{1,18}$ ]]; }

validate_int_range() { # validate_int_range <value> <min> <max>
  validate_uint "$1" && ((10#$1 >= $2 && 10#$1 <= $3))
}

validate_port() { validate_int_range "$1" 1 65535; }

validate_ipv4() {
  local o
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do
    ((10#$o <= 255)) || return 1
  done
}

validate_ipv6() {
  local ip=$1 tmp groups g
  [[ $ip == *:* && ${#ip} -le 45 ]] || return 1
  [[ $ip =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
  [[ $ip != *:::* ]] || return 1
  tmp=${ip//::/}
  ((${#ip} - ${#tmp} <= 2)) || return 1
  IFS=: read -ra groups <<<"$ip"
  ((${#groups[@]} <= 8)) || return 1
  for g in "${groups[@]}"; do
    [[ -z $g || $g =~ ^[0-9A-Fa-f]{1,4}$ ]] && continue
    # embedded IPv4 is only allowed as the last group
    [[ $g == "${groups[-1]}" ]] && validate_ipv4 "$g" && continue
    return 1
  done
  [[ $ip == *::* ]] || ((${#groups[@]} == 8)) || [[ ${groups[-1]} == *.* ]]
}

validate_ip() { validate_ipv4 "$1" || validate_ipv6 "$1"; }

validate_domain() {
  [[ ${#1} -le 253 && $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z][A-Za-z0-9-]{0,61}[A-Za-z0-9]$ ]]
}

validate_host() { validate_ip "$1" || validate_domain "$1"; }

validate_https_url() {
  [[ $1 =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~:/?#@!\$\&\'()*+,\;=%-]*)?$ ]]
}

validate_uuid() {
  [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

validate_sysctl_key() { [[ $1 =~ ^[a-z0-9_]+(\.[A-Za-z0-9_-]+)+$ ]]; }

validate_sysctl_value() { [[ $1 =~ ^[A-Za-z0-9_.:-]+(\ [A-Za-z0-9_.:-]+)*$ ]]; }

validate_iface() { [[ $1 =~ ^[A-Za-z0-9_.@:-]{1,15}$ ]]; }
