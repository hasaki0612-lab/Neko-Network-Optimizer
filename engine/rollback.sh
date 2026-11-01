# shellcheck shell=bash
# Neko - backup & rollback menu (front end of core/backup.sh).

[[ -n ${_NEKO_ROLLBACK_LOADED:-} ]] && return 0
_NEKO_ROLLBACK_LOADED=1

rb_pick_id() { # rb_pick_id <prompt> -> REPLY_INPUT = id
  ui_prompt "$1（输入编号前 5 位或完整编号，留空取消）" || return 1
  local want=$REPLY_INPUT id
  [[ -n $want ]] || return 1
  [[ $want =~ ^[0-9]+$ ]] && printf -v want '%05d' "$((10#$want))"
  while IFS= read -r id; do
    if [[ $id == "$want" || $id == "$want"-* ]]; then
      REPLY_INPUT=$id
      return 0
    fi
  done < <(backup_ids)
  ui_err "未找到变更：${REPLY_INPUT}"
  return 1
}

rollback_menu() {
  if ! is_root; then
    ui_header "配置备份与回滚"
    require_root "查看和恢复备份"
    return 0
  fi
  backup_init || return 1
  while true; do
    ui_header "配置备份与回滚"
    ui_kv "备份目录" "$(backup_root)"
    ui_kv "变更记录" "$(grep -c . "$(backup_history_file)" 2>/dev/null || echo 0) 条"
    echo
    ui_item 1 "查看变更历史"
    ui_item 2 "查看变更详情（修改前后差异）"
    ui_item 3 "撤销最近一次变更"
    ui_item 4 "恢复到指定变更之前"
    ui_item 5 "完整回滚（撤销 Neko 的全部修改）"
    ui_item 6 "创建配置快照"
    ui_back_item
    ui_read_choice 6 || return 0
    case $REPLY_CHOICE in
      0) return 0 ;;
      1) backup_history_print ;;
      2)
        backup_history_print && rb_pick_id "查看哪个变更" && backup_show "$REPLY_INPUT"
        ;;
      3)
        local last
        last=$(awk -F'\t' '$3 == "committed" && $4 != "snapshot" { id = $1 } END { print id }' "$(backup_history_file)")
        if [[ -z $last ]]; then
          ui_info "没有可撤销的变更。"
        else
          backup_show "$last" | head -n 20
          backup_restore_to "$last" interactive
        fi
        ;;
      4)
        backup_history_print && rb_pick_id "恢复到哪个变更之前" && backup_restore_to "$REPLY_INPUT" interactive
        ;;
      5)
        local first
        first=$(backup_ids | head -n 1)
        if [[ -z $first ]]; then
          ui_info "Neko 尚未修改过任何配置。"
        else
          ui_warn "完整回滚会把 Neko 管理的所有文件与运行时参数恢复到 Neko 第一次修改之前的状态。"
          backup_restore_to "$first" interactive
        fi
        ;;
      6) backup_snapshot ;;
    esac
    ui_pause
  done
}
