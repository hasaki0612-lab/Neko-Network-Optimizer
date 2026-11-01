# shellcheck shell=bash
# Neko - operating system, hardware and virtualisation detection.

[[ -n ${_NEKO_SYSTEM_LOADED:-} ]] && return 0
_NEKO_SYSTEM_LOADED=1

SYS_OS_ID=unknown SYS_OS_VERSION_ID='' SYS_OS_PRETTY='' SYS_OS_LIKE='' SYS_OS_CODENAME=''
SYS_KERNEL='' SYS_MACHINE='' SYS_ARCH='' SYS_CPU_CORES=0 SYS_CPU_MODEL=''
SYS_MEM_TOTAL_KB=0 SYS_MEM_AVAIL_KB=0 SYS_VIRT=unknown SYS_VIRT_KIND=unknown
SYS_SUPPORT=unsupported SYS_DETECTED=0

sys_detect() {
  sys_detect_os
  sys_detect_kernel
  sys_detect_hw
  sys_detect_virt
  sys_check_support
  SYS_DETECTED=1
}

sys_detect_os() {
  local f k v
  SYS_OS_ID=unknown SYS_OS_VERSION_ID='' SYS_OS_PRETTY='' SYS_OS_LIKE='' SYS_OS_CODENAME=''
  f=$(sysp /etc/os-release)
  [[ -r $f ]] || f=$(sysp /usr/lib/os-release)
  if [[ -r $f ]]; then
    while IFS='=' read -r k v; do
      v=${v%\"} v=${v#\"} v=${v%\'} v=${v#\'}
      case $k in
        ID) SYS_OS_ID=$v ;;
        VERSION_ID) SYS_OS_VERSION_ID=$v ;;
        PRETTY_NAME) SYS_OS_PRETTY=$v ;;
        ID_LIKE) SYS_OS_LIKE=$v ;;
        VERSION_CODENAME) SYS_OS_CODENAME=$v ;;
      esac
    done <"$f"
  fi
  [[ -n $SYS_OS_PRETTY ]] || SYS_OS_PRETTY="未知系统（${SYS_OS_ID}）"
}

sys_detect_kernel() {
  SYS_KERNEL=$(read_first_line /proc/sys/kernel/osrelease) || SYS_KERNEL=$(uname -r 2>/dev/null)
  SYS_MACHINE=$(uname -m 2>/dev/null)
  case $SYS_MACHINE in
    x86_64 | amd64) SYS_ARCH=amd64 ;;
    aarch64 | arm64) SYS_ARCH=arm64 ;;
    armv7* | armhf) SYS_ARCH=armv7 ;;
    *) SYS_ARCH=${SYS_MACHINE:-unknown} ;;
  esac
}

sys_detect_hw() {
  local f k v _
  SYS_CPU_CORES=0 SYS_CPU_MODEL=''
  f=$(sysp /proc/cpuinfo)
  if [[ -r $f ]]; then
    while IFS=: read -r k v; do
      k=$(trim "$k")
      case $k in
        processor) ((SYS_CPU_CORES++)) ;;
        'model name' | 'Model' | 'CPU part')
          [[ -z $SYS_CPU_MODEL ]] && SYS_CPU_MODEL=$(trim "$v")
          ;;
      esac
    done <"$f"
  fi
  ((SYS_CPU_CORES > 0)) || SYS_CPU_CORES=$(nproc 2>/dev/null || echo 0)
  SYS_MEM_TOTAL_KB=0 SYS_MEM_AVAIL_KB=0
  f=$(sysp /proc/meminfo)
  if [[ -r $f ]]; then
    while read -r k v _; do
      case $k in
        MemTotal:) SYS_MEM_TOTAL_KB=$v ;;
        MemAvailable:) SYS_MEM_AVAIL_KB=$v ;;
      esac
    done <"$f"
  fi
}

sys_detect_virt() {
  local v='' f
  if has_cmd systemd-detect-virt; then
    v=$(systemd-detect-virt 2>/dev/null) || true
    # systemd-detect-virt prints "none" and exits 1 on bare metal
  fi
  if [[ -z $v ]]; then
    if [[ -e $(sysp /proc/user_beancounters) || (-d $(sysp /proc/vz) && ! -d $(sysp /proc/bc)) ]]; then
      v=openvz
    elif [[ -r $(sysp /run/systemd/container) ]]; then
      v=$(read_first_line /run/systemd/container)
    elif [[ -e $(sysp /.dockerenv) ]]; then
      v=docker
    elif [[ -r $(sysp /proc/1/environ) ]] && tr '\0' '\n' <"$(sysp /proc/1/environ)" 2>/dev/null | grep -q '^container=lxc'; then
      v=lxc
    elif [[ -d $(sysp /proc/xen) ]]; then
      v=xen
    else
      f=$(cat "$(sysp /sys/class/dmi/id/sys_vendor)" "$(sysp /sys/class/dmi/id/product_name)" 2>/dev/null)
      case $f in
        *QEMU* | *KVM* | *Red\ Hat*) v=kvm ;;
        *VMware*) v=vmware ;;
        *Microsoft*) v=microsoft ;;
        *Xen*) v=xen ;;
        *Amazon\ EC2*) v=amazon ;;
        *Google*) v=google ;;
        *innotek* | *VirtualBox*) v=oracle ;;
        *)
          if grep -qw hypervisor "$(sysp /proc/cpuinfo)" 2>/dev/null; then v=vm-other; else v=none; fi
          ;;
      esac
    fi
  fi
  SYS_VIRT=${v:-none}
  case $SYS_VIRT in
    openvz | lxc | lxc-libvirt | docker | podman | systemd-nspawn | container-other | wsl | rkt | proot | pouch)
      SYS_VIRT_KIND=container
      ;;
    none) SYS_VIRT_KIND=none ;;
    *) SYS_VIRT_KIND=vm ;;
  esac
}

sys_virt_label() {
  case $SYS_VIRT in
    kvm) echo KVM ;;
    qemu) echo QEMU ;;
    lxc | lxc-libvirt) echo LXC ;;
    openvz) echo OpenVZ ;;
    docker) echo Docker ;;
    podman) echo Podman ;;
    xen) echo Xen ;;
    vmware) echo VMware ;;
    microsoft) echo Hyper-V ;;
    amazon) echo 'AWS (Nitro/KVM)' ;;
    google) echo 'Google Cloud (KVM)' ;;
    oracle) echo VirtualBox ;;
    systemd-nspawn) echo systemd-nspawn ;;
    wsl) echo WSL ;;
    none) echo '物理机 / 未检测到虚拟化' ;;
    vm-other) echo '其他虚拟机' ;;
    *) echo "$SYS_VIRT" ;;
  esac
}

sys_is_container() { [[ $SYS_VIRT_KIND == container ]]; }

sys_check_support() {
  SYS_SUPPORT=unsupported
  case $SYS_OS_ID in
    debian)
      case $SYS_OS_VERSION_ID in 12 | 13) SYS_SUPPORT=supported ;; *) SYS_SUPPORT=untested ;; esac
      ;;
    ubuntu)
      case $SYS_OS_VERSION_ID in 22.04 | 24.04) SYS_SUPPORT=supported ;; *) SYS_SUPPORT=untested ;; esac
      ;;
    *)
      [[ " $SYS_OS_LIKE " == *' debian '* || " $SYS_OS_LIKE " == *' ubuntu '* ]] && SYS_SUPPORT=untested
      ;;
  esac
  [[ $SYS_ARCH == amd64 || $SYS_ARCH == arm64 ]] || { [[ $SYS_SUPPORT == supported ]] && SYS_SUPPORT=untested; }
}

sys_support_label() {
  case $SYS_SUPPORT in
    supported) ui_status good '受支持' ;;
    untested) ui_status warn '未经测试（修改操作需额外确认）' ;;
    *) ui_status bad '不受支持（仅允许只读检测）' ;;
  esac
}

# Gate for every modifying operation.
sys_allow_modify() {
  ((SYS_DETECTED)) || sys_detect
  case $SYS_SUPPORT in
    supported) return 0 ;;
    untested)
      ui_warn "当前系统（${SYS_OS_PRETTY}）未经测试，修改操作可能与系统默认方式不兼容。"
      ui_confirm "仍要继续吗？" n
      ;;
    *)
      ui_err "当前系统（${SYS_OS_PRETTY}）不在支持范围内，Neko 仅提供只读检测。"
      ui_note "首批支持：Debian 12/13、Ubuntu 22.04/24.04（x86_64 / ARM64）。"
      return 1
      ;;
  esac
}

sys_mem_mib() { printf '%d' $((SYS_MEM_TOTAL_KB / 1024)); }

sys_report() {
  ((SYS_DETECTED)) || sys_detect
  ui_section "操作系统"
  ui_kv "系统" "$SYS_OS_PRETTY"
  ui_kv "支持状态" "$(sys_support_label)"
  ui_kv "内核" "$SYS_KERNEL"
  ui_kv "架构" "${SYS_ARCH}（${SYS_MACHINE}）"
  ui_kv "虚拟化" "$(sys_virt_label)"
  ui_kv "Bash" "${BASH_VERSION}"
  ui_section "硬件资源"
  ui_kv "CPU" "${SYS_CPU_MODEL:-未知} × ${SYS_CPU_CORES} 核"
  ui_kv "内存总量" "$(human_bytes $((SYS_MEM_TOTAL_KB * 1024)))"
  ui_kv "可用内存" "$(human_bytes $((SYS_MEM_AVAIL_KB * 1024)))"
  if sys_is_container; then
    ui_warn "检测到容器环境（$(sys_virt_label)）：拥塞控制模块、默认 Qdisc 等内核全局参数通常由宿主机控制。"
  fi
}
