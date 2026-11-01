# shellcheck shell=bash
# Neko - unified transactional backup system.
#
# Every modification Neko makes is wrapped in a transaction:
#
#   backup_begin "label" "summary"     # new transaction id
#   backup_add_file /etc/x             # snapshot BEFORE writing
#   backup_record_sysctl key...        # runtime sysctl values before change
#   backup_add_restore <res> cmd...    # command that restores a non-file resource
#   backup_add_hook resolved-restart   # action needed after a restore
#   ... modify the system ...
#   backup_commit                      # snapshot AFTER state + diff
#
# Layout ($NEKO_STATE_DIR, mode 0700):
#   history.tsv                        id  time  status  label  summary
#   backups/<id>/meta                  key=value
#   backups/<id>/manifest.tsv          idx path existed kind mode owner target after_kind after_hash
#   backups/<id>/before/<idx>          file content before the change
#   backups/<id>/after/<idx>           file content after the change
#   backups/<id>/sysctl.before|after   key=value runtime values
#   backups/<id>/restore.d/<res>.sh    restore commands for non-file resources
#   backups/<id>/hooks                 post-restore hooks
#   backups/<id>/changes.diff          unified diff of every file
#
# Restoring "to before transaction X" is state based: for every file / sysctl
# key / resource touched by X or any later transaction, the earliest recorded
# BEFORE state at or after X is put back. A rollback is itself a transaction,
# so it can be undone as well.

[[ -n ${_NEKO_BACKUP_LOADED:-} ]] && return 0
_NEKO_BACKUP_LOADED=1

BK_TX_ID='' BK_TX_DIR='' BK_TX_COUNT=0

backup_root() { printf '%s/backups' "$NEKO_STATE_DIR"; }
backup_history_file() { printf '%s/history.tsv' "$NEKO_STATE_DIR"; }

backup_init() {
  local root
  root=$(backup_root)
  (umask 077 && mkdir -p "$root") || {
    ui_err "无法创建备份目录：${root}"
    return 1
  }
  chmod 700 "$NEKO_STATE_DIR" "$root" 2>/dev/null
  [[ -f $(backup_history_file) ]] || (umask 077 && : >"$(backup_history_file)")
}

backup_next_id() {
  local last seq=0 ts
  last=$(tail -n 1 "$(backup_history_file)" 2>/dev/null | cut -f1)
  [[ $last =~ ^([0-9]{5})- ]] && seq=$((10#${BASH_REMATCH[1]}))
  printf -v ts '%(%Y%m%d-%H%M%S)T' -1
  printf '%05d-%s' $((seq + 1)) "$ts"
}

history_append() { # id status label summary
  local t
  printf -v t '%(%F %T)T' -1
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$t" "$2" "${3//$'\t'/ }" "${4//$'\t'/ }" >>"$(backup_history_file)"
}

backup_set_status() { # id status
  local hf tmp
  hf=$(backup_history_file)
  tmp=$(mktemp "${hf}.XXXXXX") || return 1
  awk -F'\t' -v OFS='\t' -v id="$1" -v st="$2" '$1 == id { $3 = st } { print }' "$hf" >"$tmp" &&
    chmod 600 "$tmp" && mv -f "$tmp" "$hf"
  local meta
  meta="$(backup_root)/$1/meta"
  [[ -f $meta ]] && sed -i "s/^status=.*/status=$2/" "$meta"
}

backup_status_of() {
  awk -F'\t' -v id="$1" '$1 == id { s = $3 } END { print s }' "$(backup_history_file)" 2>/dev/null
}

backup_ids() { # all ids in chronological order
  [[ -f $(backup_history_file) ]] || return 0
  cut -f1 "$(backup_history_file)"
}

backup_exists() { [[ -n $1 && -d "$(backup_root)/$1" && -f "$(backup_root)/$1/manifest.tsv" ]]; }

backup_begin() { # label summary
  backup_init || return 1
  BK_TX_ID=$(backup_next_id)
  BK_TX_DIR="$(backup_root)/$BK_TX_ID"
  BK_TX_COUNT=0
  (umask 077 && mkdir -p "$BK_TX_DIR/before" "$BK_TX_DIR/after" "$BK_TX_DIR/restore.d") || {
    ui_err "无法创建备份：${BK_TX_DIR}"
    BK_TX_ID=''
    return 1
  }
  {
    printf 'id=%s\n' "$BK_TX_ID"
    printf 'time=%(%F %T)T\n' -1
    printf 'label=%s\n' "$1"
    printf 'summary=%s\n' "${2:-}"
    printf 'user=%s\n' "${SUDO_USER:-${USER:-root}}"
    printf 'neko_version=%s\n' "${NEKO_VERSION:-}"
    printf 'status=pending\n'
  } >"$BK_TX_DIR/meta"
  : >"$BK_TX_DIR/manifest.tsv"
  history_append "$BK_TX_ID" pending "$1" "${2:-}"
  log_info "backup begin ${BK_TX_ID} label=$1"
}

backup_add_file() { # backup_add_file <system path>
  local path=$1 real idx existed=0 kind=none mode='' owner='' target=''
  [[ -n $BK_TX_ID ]] || { ui_err "内部错误：没有活动的备份事务"; return 1; }
  awk -F'\t' -v p="$path" '$2 == p { f = 1 } END { exit !f }' "$BK_TX_DIR/manifest.tsv" && return 0
  real=$(sysp "$path")
  idx=$((++BK_TX_COUNT))
  if [[ -L $real ]]; then
    existed=1 kind=symlink target=$(readlink "$real")
  elif [[ -f $real ]]; then
    existed=1 kind=file
    mode=$(stat -c %a "$real" 2>/dev/null || echo 644)
    owner=$(stat -c %u:%g "$real" 2>/dev/null || echo 0:0)
    (umask 077 && cat "$real" >"$BK_TX_DIR/before/$idx") || {
      ui_err "备份失败：无法读取 ${path}"
      return 1
    }
  elif [[ -e $real ]]; then
    ui_err "不支持备份非普通文件：${path}"
    return 1
  fi
  # "-" marks an empty field: `read` with IFS=$'\t' would merge consecutive tabs
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$idx" "$path" "$existed" "$kind" "${mode:--}" "${owner:--}" "${target:--}" >>"$BK_TX_DIR/manifest.tsv"
}

backup_record_sysctl() { # backup_record_sysctl <key>...
  local k v f="$BK_TX_DIR/sysctl.before"
  [[ -n $BK_TX_ID ]] || return 1
  for k in "$@"; do
    grep -q "^${k//./\\.}=" "$f" 2>/dev/null && continue
    v=$(sysctl_get "$k") || continue
    printf '%s=%s\n' "$k" "$v" >>"$f"
  done
}

backup_add_restore() { # backup_add_restore <resource> <cmd> [args...]
  local res=$1 f
  shift
  [[ -n $BK_TX_ID && $res =~ ^[A-Za-z0-9_.@-]+$ ]] || return 1
  f="$BK_TX_DIR/restore.d/$res.sh"
  {
    printf '%q ' "$@"
    printf '\n'
  } >>"$f"
}

backup_add_hook() {
  [[ -n $BK_TX_ID ]] || return 1
  grep -qx "$1" "$BK_TX_DIR/hooks" 2>/dev/null || printf '%s\n' "$1" >>"$BK_TX_DIR/hooks"
}

backup_commit() {
  local tx=$BK_TX_ID dir=$BK_TX_DIR tmp idx path existed kind mode owner target real akind ahash k
  [[ -n $tx ]] || return 1
  tmp=$(mktemp "$dir/manifest.XXXXXX") || return 1
  : >"$dir/changes.diff"
  while IFS=$'\t' read -r idx path existed kind mode owner target _ _; do
    real=$(sysp "$path")
    if [[ -L $real ]]; then
      akind=symlink ahash="link:$(readlink "$real")"
    elif [[ -f $real ]]; then
      akind='file'
      (umask 077 && cat "$real" >"$dir/after/$idx")
      ahash=$(file_sha256 "$real")
    else
      akind=none ahash=none
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$idx" "$path" "$existed" "$kind" "$mode" "$owner" "$target" "$akind" "$ahash" >>"$tmp"
    if has_cmd diff; then
      local a=/dev/null b=/dev/null
      [[ -f $dir/before/$idx ]] && a=$dir/before/$idx
      [[ -f $dir/after/$idx ]] && b=$dir/after/$idx
      [[ $kind == symlink ]] && printf -- '--- a%s (symlink -> %s)\n' "$path" "$target" >>"$dir/changes.diff"
      [[ $akind == symlink ]] && printf -- '+++ b%s (%s)\n' "$path" "$ahash" >>"$dir/changes.diff"
      diff -u --label "a$path" --label "b$path" "$a" "$b" >>"$dir/changes.diff" 2>/dev/null
    fi
  done <"$dir/manifest.tsv"
  mv -f "$tmp" "$dir/manifest.tsv"
  if [[ -f $dir/sysctl.before ]]; then
    : >"$dir/sysctl.after"
    while IFS='=' read -r k _; do
      printf '%s=%s\n' "$k" "$(sysctl_get "$k")" >>"$dir/sysctl.after"
    done <"$dir/sysctl.before"
  fi
  chmod -R go-rwx "$dir" 2>/dev/null
  backup_set_status "$tx" committed
  log_info "backup commit ${tx}"
  BK_TX_ID='' BK_TX_DIR='' BK_TX_COUNT=0
}

# Commit the active transaction and immediately revert it (used when an apply
# step fails half way).
backup_abort_and_restore() {
  local tx=$BK_TX_ID
  [[ -n $tx ]] || return 0
  backup_commit
  ui_warn "正在恢复本次修改前的配置..."
  backup_restore_to "$tx" auto
}

_backup_restore_file() { # src dest mode owner
  local src=$1 dest=$2 mode=$3 owner=$4 tmp
  mkdir -p "$(dirname "$dest")" || return 1
  tmp=$(mktemp "${dest}.neko.XXXXXX") || return 1
  cat "$src" >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod "${mode:-644}" "$tmp" 2>/dev/null
  if is_root && [[ -z ${NEKO_SYSROOT:-} && -n $owner ]]; then chown "$owner" "$tmp" 2>/dev/null; fi
  mv -f "$tmp" "$dest"
}

_backup_run_hook() { # hook mode
  case $1 in
    resolved-restart)
      if [[ $2 == auto ]] || ui_confirm "需要重启 systemd-resolved 以使恢复生效，是否立即重启？" y; then
        systemctl restart systemd-resolved >/dev/null 2>&1 && ui_ok "systemd-resolved 已重启" || ui_warn "systemd-resolved 重启失败，请手动检查"
      fi
      ;;
    resolvconf-update)
      resolvconf -u >/dev/null 2>&1 && ui_ok "resolvconf 已刷新" || ui_warn "resolvconf -u 执行失败"
      ;;
    *) log_warn "unknown restore hook $1" ;;
  esac
}

# backup_restore_to <id> [interactive|auto] [scope]: put the system back into the
# state it had right before transaction <id>. scope "dns" only considers DNS
# transactions (labels dns-*), leaving later TCP/UDP changes in place.
backup_restore_to() {
  local lower=$1 mode=${2:-interactive} scope=${3:-all} root id idx path existed kind fmode owner target akind ahash real f k v
  root=$(backup_root)
  backup_exists "$lower" || { ui_err "备份不存在：${lower}"; return 1; }

  local -a ids=() order=() drift=() failures=() all=()
  local -A src=() latest=() sysv=() res=() hooks=()
  mapfile -t all < <(backup_ids)
  for id in "${all[@]}"; do
    [[ -f $root/$id/manifest.tsv ]] || continue
    # latest known after-state of every path, over the whole history
    while IFS=$'\t' read -r idx path _ _ _ _ _ akind ahash; do
      [[ -n $ahash ]] && latest[$path]=$ahash
    done <"$root/$id/manifest.tsv"
    [[ $id < "$lower" ]] && continue
    if [[ $scope == dns ]] && ! grep -q '^label=dns-' "$root/$id/meta" 2>/dev/null; then
      continue
    fi
    ids+=("$id")
    while IFS=$'\t' read -r idx path existed kind fmode owner target _ _; do
      [[ -n ${src[$path]+x} ]] && continue
      src[$path]="$id"$'\t'"$idx"$'\t'"$existed"$'\t'"$kind"$'\t'"$fmode"$'\t'"$owner"$'\t'"$target"
      order+=("$path")
    done <"$root/$id/manifest.tsv"
    if [[ -f $root/$id/sysctl.before ]]; then
      while IFS='=' read -r k v; do
        [[ -n $k && -z ${sysv[$k]+x} ]] && sysv[$k]=$v
      done <"$root/$id/sysctl.before"
    fi
    for f in "$root/$id/restore.d"/*.sh; do
      [[ -f $f ]] || continue
      k=${f##*/}
      [[ -n ${res[$k]+x} ]] || res[$k]=$f
    done
    if [[ -f $root/$id/hooks ]]; then
      while IFS= read -r k; do [[ -n $k ]] && hooks[$k]=1; done <"$root/$id/hooks"
    fi
  done

  ((${#ids[@]})) || { ui_info "没有需要回滚的变更。"; return 0; }

  for path in "${order[@]}"; do
    real=$(sysp "$path")
    [[ -n ${latest[$path]:-} && $(file_sha256 "$real") != "${latest[$path]}" ]] && drift+=("$path")
  done

  if [[ $mode != auto ]]; then
    ui_section "回滚计划（恢复到变更 ${lower} 之前）"
    ui_kv "涉及变更" "${#ids[@]} 次（${ids[0]} … ${ids[-1]}）"
    for path in "${order[@]}"; do
      IFS=$'\t' read -r id idx existed kind _ <<<"${src[$path]}"
      if [[ $existed == 1 ]]; then ui_note "恢复文件：${path}"; else ui_note "删除 Neko 创建的文件：${path}"; fi
    done
    for k in "${!sysv[@]}"; do ui_note "恢复运行时参数：${k} = ${sysv[$k]}"; done
    for k in "${!res[@]}"; do ui_note "恢复资源：${k%.sh}"; done
    if ((${#drift[@]})); then
      ui_warn "以下文件在 Neko 修改之后又被其他程序或人工修改过，回滚会覆盖这些修改："
      for path in "${drift[@]}"; do ui_note "$path"; done
    fi
    ui_confirm "确认执行回滚吗？" n || { ui_info "已取消回滚。"; return 1; }
  fi

  neko_lock || return 1
  # The rollback is itself a transaction so it can be undone.
  backup_begin rollback "回滚到 ${lower} 之前" || return 1
  for path in "${order[@]}"; do backup_add_file "$path" || true; done
  ((${#sysv[@]})) && backup_record_sysctl "${!sysv[@]}"

  for path in "${order[@]}"; do
    IFS=$'\t' read -r id idx existed kind fmode owner target <<<"${src[$path]}"
    real=$(sysp "$path")
    case "$existed:$kind" in
      1:file) _backup_restore_file "$root/$id/before/$idx" "$real" "$fmode" "$owner" ;;
      1:symlink) rm -f "$real" && ln -s "$target" "$real" ;;
      *) if [[ -e $real || -L $real ]]; then rm -f "$real"; fi ;;
    esac || failures+=("$path")
  done
  for k in "${!sysv[@]}"; do
    if sysctl_exists "$k"; then
      sysctl_set_runtime "$k" "${sysv[$k]}" || failures+=("sysctl $k")
    fi
  done
  for k in "${!res[@]}"; do
    bash "${res[$k]}" >/dev/null 2>&1 || failures+=("资源 ${k%.sh}")
  done
  backup_commit
  for k in "${!hooks[@]}"; do _backup_run_hook "$k" "$mode"; done

  for id in "${ids[@]}"; do backup_set_status "$id" rolled_back; done
  neko_unlock
  if ((${#failures[@]})); then
    ui_warn "回滚完成，但以下项目恢复失败：${failures[*]}"
    log_error "rollback to ${lower} partial failure: ${failures[*]}"
    return 1
  fi
  ui_ok "已恢复到变更 ${lower} 之前的状态。"
  log_info "rollback to ${lower} done (${#ids[@]} transactions)"
}

backup_label_text() {
  case $1 in
    tcp-*) echo "TCP：${1#tcp-}" ;;
    udp-*) echo "UDP：${1#udp-}" ;;
    dns-*) echo "DNS：${1#dns-}" ;;
    rollback) echo "回滚" ;;
    snapshot) echo "手动快照" ;;
    *) echo "$1" ;;
  esac
}

backup_status_text() {
  case $1 in
    committed) ui_status good 已生效 ;;
    rolled_back) ui_status warn 已回滚 ;;
    pending) ui_status bad 未完成 ;;
    *) printf '%s' "$1" ;;
  esac
}

backup_history_print() {
  local id t st label summary n=0
  [[ -s $(backup_history_file) ]] || { ui_info "暂无变更记录。"; return 1; }
  printf '  %-22s %-19s %-8s %s\n' "编号" "时间" "状态" "内容"
  while IFS=$'\t' read -r id t st label summary; do
    printf '  %-20s %-19s %s  %s\n' "$id" "$t" "$(backup_status_text "$st")" "${summary:-$(backup_label_text "$label")}"
    ((n++))
  done <"$(backup_history_file)"
  ui_note "共 ${n} 条记录。"
}

backup_show() { # backup_show <id>
  local dir
  dir="$(backup_root)/$1"
  backup_exists "$1" || { ui_err "备份不存在：$1"; return 1; }
  ui_section "变更 $1"
  local k v
  while IFS='=' read -r k v; do
    case $k in
      time) ui_kv "时间" "$v" ;;
      label) ui_kv "类型" "$(backup_label_text "$v")" ;;
      summary) ui_kv "说明" "$v" ;;
      user) ui_kv "操作用户" "$v" ;;
    esac
  done <"$dir/meta"
  ui_kv "状态" "$(backup_status_text "$(backup_status_of "$1")")"
  if [[ -f $dir/sysctl.before ]]; then
    ui_section "运行时参数（修改前 → 修改后）"
    while IFS='=' read -r k v; do
      ui_note "${k}: ${v} → $(grep "^${k//./\\.}=" "$dir/sysctl.after" 2>/dev/null | cut -d= -f2-)"
    done <"$dir/sysctl.before"
  fi
  if [[ -s $dir/changes.diff ]]; then
    ui_section "文件差异"
    cat "$dir/changes.diff"
  fi
}

# Files Neko is able to manage; used by the manual snapshot.
NEKO_MANAGED_FILES=(
  /etc/sysctl.d/99-zz-neko.conf
  /etc/modules-load.d/neko.conf
  /etc/resolv.conf
  /etc/systemd/resolved.conf.d/99-neko-dns.conf
  /etc/resolvconf/resolv.conf.d/head
  /etc/resolvconf.conf
  /etc/dhcp/dhclient.conf
)

backup_snapshot() {
  local p
  require_root "创建配置快照" || return 1
  neko_lock || return 1
  backup_begin snapshot "手动快照" || return 1
  for p in "${NEKO_MANAGED_FILES[@]}"; do backup_add_file "$p"; done
  backup_commit
  neko_unlock
  ui_ok "已创建配置快照。"
}
