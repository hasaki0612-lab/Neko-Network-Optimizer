# shellcheck shell=bash
# Neko - logging with credential redaction.
#
# Log lines never contain secrets: UUIDs, passwords, keys and share links are
# masked before they are written.

[[ -n ${_NEKO_LOGGER_LOADED:-} ]] && return 0
_NEKO_LOGGER_LOADED=1

NEKO_LOG_FILE=''

log_init() {
  local dir
  for dir in "${NEKO_LOG_DIR:-}" "${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/neko"; do
    [[ -n $dir ]] || continue
    if mkdir -p "$dir" 2>/dev/null && [[ -w $dir ]]; then
      NEKO_LOG_FILE="$dir/neko.log"
      [[ -e $NEKO_LOG_FILE ]] || (umask 027 && : >"$NEKO_LOG_FILE") 2>/dev/null
      return 0
    fi
  done
  NEKO_LOG_FILE=''
}

log_redact() {
  local s=$1
  local re='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
  while [[ $s =~ $re ]]; do
    s=${s//"${BASH_REMATCH[0]}"/<uuid>}
  done
  printf '%s' "$s" | sed -E \
    -e 's#(vless|vmess|trojan|ss|hysteria2|hy2|tuic|anytls)://[^[:space:]]+#\1://<redacted>#g' \
    -e 's/((password|passwd|psk|private_?key|privateKey|public_?key|token|secret|short_?id|uuid)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?)[^"'"'"'&[:space:],}]+/\1<redacted>/Ig'
}

log_write() { # log_write <LEVEL> <message...>
  [[ -n $NEKO_LOG_FILE ]] || return 0
  local level=$1 msg
  shift
  msg=$(log_redact "$*")
  printf '%(%F %T)T %-5s [%s] %s\n' -1 "$level" "$$" "$msg" >>"$NEKO_LOG_FILE" 2>/dev/null || true
}

log_info() { log_write INFO "$@"; }
log_warn() { log_write WARN "$@"; }
log_error() { log_write ERROR "$@"; }
