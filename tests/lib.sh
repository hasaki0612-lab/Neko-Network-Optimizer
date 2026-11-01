# shellcheck shell=bash
# Neko test harness: every test runs against a throw-away fake root filesystem
# (NEKO_SYSROOT) with mocked system commands first in PATH. Nothing here reads
# or modifies the real /proc, /sys or /etc of the machine running the tests.

set -u
export MSYS=winsymlinks:lnk # symlinks that MSYS tools understand on Git for Windows

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FIX="$REPO/tests/fixtures"
# Results are appended to a file so assertions inside subshells still count.
T_RESULTS=${T_RESULTS:-$(mktemp)}

pass() {
  echo "ok $1" >>"$T_RESULTS"
  printf '  \e[32mok\e[0m   %s\n' "$1"
}
fail() {
  echo "FAIL $1" >>"$T_RESULTS"
  printf '  \e[31mFAIL\e[0m %s\n' "$1"
  [[ -n ${2:-} ]] && printf '%s\n' "$2" | head -n 25 | sed 's/^/       /'
}
assert_eq() { if [[ $1 == "$2" ]]; then pass "$3"; else fail "$3" "expected: [$2]"$'\n'"got:      [$1]"; fi; }
assert_contains() { if [[ $1 == *"$2"* ]]; then pass "$3"; else fail "$3" "missing: [$2]"$'\n'"in: $1"; fi; }
assert_not_contains() { if [[ $1 != *"$2"* ]]; then pass "$3"; else fail "$3" "unexpected: [$2]"; fi; }
assert_rc() { if [[ $1 == "$2" ]]; then pass "$3"; else fail "$3" "expected rc $2, got $1"; fi; }
assert_file() { if [[ -e $1 || -L $1 ]]; then pass "$2"; else fail "$2" "missing file $1"; fi; }
assert_no_file() { if [[ ! -e $1 && ! -L $1 ]]; then pass "$2"; else fail "$2" "file should not exist: $1"; fi; }
section() { printf '\n\e[1m%s\e[0m\n' "$1"; }

# ------------------------------------------------------------ environment --
t_setup() {
  T=$(mktemp -d "${TMPDIR:-/tmp}/neko-test.XXXXXX")
  R="$T/root"
  M="$T/mock"
  mkdir -p "$R" "$M/active" "$M/enabled" "$T/bin" "$T/etc" "$T/state" "$T/log" "$T/home"
  : >"$M/calls"
  export NEKO_SYSROOT=$R NEKO_TEST_EUID=0 NEKO_ETC_DIR="$T/etc" NEKO_STATE_DIR="$T/state" NEKO_LOG_DIR="$T/log"
  export NEKO_NO_COLOR=1 NEKO_NO_PAUSE=1 NEKO_NO_CLEAR=1 NEKO_DNS_SETTLE=0 HOME="$T/home" MOCK_DIR=$M
  export NEKO_BIN="$REPO/neko.sh" NEKO_HOME=$REPO
  export PATH="$T/bin:$ORIG_PATH"
  unset MOCK_QDISC EXPORT_SERVER_OVERRIDE NEKO_EXPORT_DIR
  export MOCK_VIRT=kvm
  t_mocks
  t_sysroot_debian
}

t_teardown() {
  [[ -n ${T:-} && -d $T ]] && rm -rf "$T"
  T=''
}

ORIG_PATH=${ORIG_PATH:-$PATH}

mock() { # mock <name> <<'EOF' ... body ... EOF
  {
    echo '#!/usr/bin/env bash'
    cat
  } >"$T/bin/$1"
  chmod +x "$T/bin/$1"
}

t_mocks() {
  # Native Windows jq.exe / openssl.exe print CRLF; Linux builds print LF.
  # These shims make the test platform behave like the target platform.
  local real_jq real_ssl
  real_jq=$(PATH=$ORIG_PATH command -v jq)
  real_ssl=$(PATH=$ORIG_PATH command -v openssl)
  if [[ -n $real_jq ]]; then
    cat >"$T/bin/jq" <<EOF
#!/usr/bin/env bash
set -o pipefail
$(printf '%q' "$real_jq") "\$@" | tr -d '\\r'
EOF
    chmod +x "$T/bin/jq"
  fi
  if [[ -n $real_ssl ]]; then
    cat >"$T/bin/openssl" <<EOF
#!/usr/bin/env bash
set -o pipefail
if [[ \$1 == x509 ]]; then $(printf '%q' "$real_ssl") "\$@" | tr -d '\\r'; else exec $(printf '%q' "$real_ssl") "\$@"; fi
EOF
    chmod +x "$T/bin/openssl"
  fi
  mock systemctl <<'EOF'
case $1 in
  is-active) if [[ -f $MOCK_DIR/active/$2 ]]; then echo active; else echo inactive; exit 3; fi ;;
  is-enabled) if [[ -f $MOCK_DIR/enabled/$2 ]]; then echo enabled; else echo disabled; exit 1; fi ;;
  *) echo "systemctl $*" >>"$MOCK_DIR/calls" ;;
esac
EOF
  mock ps <<'EOF'
cat "$MOCK_DIR/ps.txt" 2>/dev/null
EOF
  mock ss <<'EOF'
cat "$MOCK_DIR/ss.txt" 2>/dev/null
EOF
  mock ip <<'EOF'
case "$*" in
  *"-4 addr show"*) cat "$MOCK_DIR/ip4.txt" 2>/dev/null ;;
esac
EOF
  mock sysctl <<'EOF'
if [[ $1 == -w ]]; then
  k=${2%%=*} v=${2#*=}
  echo "sysctl -w $2" >>"$MOCK_DIR/calls"
  if grep -qx "$k" "$MOCK_DIR/sysctl_fail" 2>/dev/null; then echo "sysctl: permission denied on key \"$k\"" >&2; exit 1; fi
  f="$NEKO_SYSROOT/proc/sys/${k//.//}"
  [[ -f $f ]] || exit 1
  printf '%s\n' "$v" >"$f"
  echo "$k = $v"
fi
EOF
  mock uname <<'EOF'
case $1 in
  -m) echo "${MOCK_UNAME_M:-x86_64}" ;;
  -r) cat "$NEKO_SYSROOT/proc/sys/kernel/osrelease" ;;
  *) echo Linux ;;
esac
EOF
  mock systemd-detect-virt <<'EOF'
if [[ -n ${MOCK_VIRT:-} ]]; then echo "$MOCK_VIRT"; [[ $MOCK_VIRT == none ]] && exit 1; exit 0; fi
exit 1
EOF
  mock getent <<'EOF'
[[ -f $MOCK_DIR/dns_fail ]] && exit 2
echo "104.16.124.96   STREAM $2"
EOF
  mock modprobe <<'EOF'
echo "modprobe $*" >>"$MOCK_DIR/calls"
if [[ $1 == tcp_bbr ]]; then
  f=$NEKO_SYSROOT/proc/sys/net/ipv4/tcp_available_congestion_control
  grep -qw bbr "$f" || printf '%s bbr\n' "$(cat "$f")" >"$f"
fi
EOF
  mock tc <<'EOF'
case "$*" in
  "qdisc show dev"*) echo "qdisc ${MOCK_QDISC:-fq_codel} 0: root refcnt 2 limit 10240p" ;;
  *) echo "tc $*" >>"$MOCK_DIR/calls" ;;
esac
EOF
  mock nmcli <<'EOF'
echo "nmcli $*" >>"$MOCK_DIR/calls"
case "$*" in
  "-g GENERAL.CONNECTION device show"*) echo "Wired connection 1" ;;
  "-g ipv4.dns connection show"*) echo "8.8.8.8" ;;
  "-g ipv4.ignore-auto-dns connection show"*) echo "no" ;;
  "-g ipv6.dns connection show"*) echo "" ;;
  "-g ipv6.ignore-auto-dns connection show"*) echo "no" ;;
esac
EOF
  mock resolvconf <<'EOF'
echo "resolvconf $*" >>"$MOCK_DIR/calls"
EOF
  mock qrencode <<'EOF'
out=''
while (($#)); do case $1 in -o) out=$2; shift ;; -t|-m|-s) shift ;; --) shift; data=$1 ;; esac; shift; done
if [[ -n $out ]]; then printf 'PNG:%s' "$data" >"$out"; else echo "[QR] $data"; fi
EOF
  mock ethtool <<'EOF'
case $1 in
  -k) printf 'Features for %s:\ngeneric-segmentation-offload: on\ngeneric-receive-offload: on\ntx-udp-segmentation: off [fixed]\n' "$2" ;;
  -i) echo "driver: virtio_net" ;;
esac
EOF
}

w() { # w <path relative to sysroot> <content>
  mkdir -p "$(dirname "$R/$1")"
  printf '%s\n' "$2" >"$R/$1"
}

t_sysroot_debian() {
  w etc/os-release 'PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
NAME="Debian GNU/Linux"
VERSION_ID="13"
VERSION_CODENAME=trixie
ID=debian'
  w proc/sys/kernel/osrelease '6.12.48+deb13-amd64'
  w proc/cpuinfo 'processor	: 0
model name	: QEMU Virtual CPU version 2.5+
flags		: fpu hypervisor
processor	: 1
model name	: QEMU Virtual CPU version 2.5+'
  w proc/meminfo 'MemTotal:        2014532 kB
MemFree:          912345 kB
MemAvailable:    1523400 kB'
  local s=proc/sys/net
  w $s/ipv4/tcp_congestion_control cubic
  w $s/ipv4/tcp_available_congestion_control 'reno cubic'
  w $s/core/default_qdisc fq_codel
  w $s/core/rmem_max 212992
  w $s/core/wmem_max 212992
  w $s/core/rmem_default 212992
  w $s/core/wmem_default 212992
  w $s/ipv4/tcp_rmem $'4096\t131072\t6291456'
  w $s/ipv4/tcp_wmem $'4096\t16384\t4194304'
  w $s/ipv4/udp_mem $'46350\t61803\t92700'
  w $s/ipv4/udp_rmem_min 4096
  w $s/ipv4/udp_wmem_min 4096
  w $s/ipv4/tcp_fastopen 1
  w $s/ipv4/tcp_ecn 2
  w $s/ipv4/tcp_mtu_probing 0
  w $s/ipv4/tcp_keepalive_time 7200
  w $s/ipv4/tcp_keepalive_intvl 75
  w $s/ipv4/tcp_keepalive_probes 9
  w $s/ipv4/tcp_slow_start_after_idle 1
  w proc/net/route 'Iface	Destination	Gateway 	Flags	RefCnt	Use	Metric	Mask		MTU	Window	IRTT
eth0	00000000	0102A8C0	0003	0	0	100	00000000	0	0	0
eth0	0002A8C0	00000000	0001	0	0	100	00FFFFFF	0	0	0'
  w proc/net/ipv6_route '00000000000000000000000000000000 00 00000000000000000000000000000000 00 fe800000000000000000000000000001 00000400 00000001 00000000 00000003     eth0'
  w proc/net/if_inet6 '20010db8000000000000000000000010 02 40 00 80     eth0
fe800000000000000000000000000010 02 40 20 80     eth0
00000000000000000000000000000001 01 80 10 80       lo'
  w proc/net/snmp 'Ip: Forwarding DefaultTTL
Ip: 2 64
Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts InCsumErrors
Tcp: 1 200 120000 -1 100 200 0 0 5 500000 400000 1200 0 10 0
Udp: InDatagrams NoPorts InErrors OutDatagrams RcvbufErrors SndbufErrors InCsumErrors IgnoredMulti MemErrors
Udp: 90000 12 0 88000 0 0 0 0 0'
  w proc/net/snmp6 'Udp6InDatagrams                 1200
Udp6NoPorts                     0
Udp6InErrors                    0
Udp6OutDatagrams                1100
Udp6RcvbufErrors                0
Udp6SndbufErrors                0'
  w proc/net/dev 'Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo:    1000      10    0    0    0     0          0         0     1000      10    0    0    0     0       0          0
  eth0: 123456789 100000    0    3    0     0          0         0 98765432   90000    0    0    0     0       0          0'
  w sys/class/net/eth0/mtu 1500
  mkdir -p "$R/sys/class/net/eth0/queues/tx-0" "$R/sys/class/net/eth0/device" "$R/sys/bus/virtio/drivers/virtio_net"
  ln -s "$R/sys/bus/virtio/drivers/virtio_net" "$R/sys/class/net/eth0/device/driver"
  mkdir -p "$R/sys/class/net/lo"
  w sys/class/net/lo/mtu 65536
  w lib/modules/6.12.48+deb13-amd64/kernel/net/ipv4/tcp_bbr.ko.xz x
  w lib/modules/6.12.48+deb13-amd64/kernel/net/sched/sch_fq.ko.xz x
  mkdir -p "$R/run/systemd/system" "$R/etc/systemd/system" "$R/etc/sysctl.d"
  # DNS: systemd-resolved stub
  w run/systemd/resolve/stub-resolv.conf 'nameserver 127.0.0.53
options edns0 trust-ad
search .'
  w run/systemd/resolve/resolv.conf 'nameserver 1.1.1.1'
  ln -s ../run/systemd/resolve/stub-resolv.conf "$R/etc/resolv.conf"
  w etc/systemd/resolved.conf '[Resolve]
#DNS=
#DNSOverTLS=no'
  touch "$M/active/systemd-resolved" "$M/active/systemd-networkd"
  printf '2: eth0    inet 203.0.113.10/24 brd 203.0.113.255 scope global eth0\n' >"$M/ip4.txt"
  : >"$M/ps.txt"
  : >"$M/ss.txt"
}

# Install a fake sing-box (binary + unit + config) into the sysroot.
t_install_singbox() { # t_install_singbox [running]
  mkdir -p "$R/usr/bin" "$R/etc/sing-box"
  cat >"$R/usr/bin/sing-box" <<'EOF'
#!/usr/bin/env bash
case $1 in
  version) echo "sing-box version 1.12.4"; echo; echo "Environment: go1.24.4 linux/amd64" ;;
  check) echo "sing-box $*" >>"$MOCK_DIR/calls"; exit "${MOCK_SB_CHECK_RC:-0}" ;;
esac
EOF
  chmod +x "$R/usr/bin/sing-box"
  printf '[Unit]\nDescription=sing-box\n[Service]\nExecStart=/usr/bin/sing-box -D /var/lib/sing-box -c /etc/sing-box/config.json run\n' >"$R/etc/systemd/system/sing-box.service"
  cp "$FIX/singbox-config.json" "$R/etc/sing-box/config.json"
  cp "$FIX/certs/leaf.pem" "$R/etc/sing-box/leaf.pem"
  cp "$FIX/certs/self.pem" "$R/etc/sing-box/self.pem"
  if [[ ${1:-} == running ]]; then
    echo "1234 /usr/bin/sing-box -D /var/lib/sing-box -c /etc/sing-box/config.json run" >>"$M/ps.txt"
    touch "$M/active/sing-box" "$M/enabled/sing-box"
    printf 'tcp LISTEN 0 4096 *:443 *:* users:(("sing-box",pid=1234,fd=7))\nudp UNCONN 0 0 *:8443 *:* users:(("sing-box",pid=1234,fd=9))\n' >>"$M/ss.txt"
  fi
}

t_install_xray() {
  mkdir -p "$R/usr/local/bin" "$R/usr/local/etc/xray" "$R/etc/xray"
  cat >"$R/usr/local/bin/xray" <<'EOF'
#!/usr/bin/env bash
case $1 in
  version) echo "Xray 25.10.15 (Xray, Penetrates Everything.) 3b5b1a9 (go1.25.1 linux/amd64)" ;;
  run) echo "xray $*" >>"$MOCK_DIR/calls" ;;
esac
EOF
  chmod +x "$R/usr/local/bin/xray"
  printf '[Service]\nExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json\n' >"$R/etc/systemd/system/xray.service"
  cp "$FIX/xray-config.json" "$R/usr/local/etc/xray/config.json"
  cp "$FIX/certs/leaf.pem" "$R/etc/xray/leaf.pem"
}

# Run the real neko.sh with scripted input.
neko_run() { # neko_run <input> [args...]
  local input=$1
  shift
  printf '%b' "$input" | bash "$REPO/neko.sh" "$@" 2>&1
}

# Source Neko into the current (sub)shell for unit tests.
neko_source() {
  # shellcheck source=/dev/null
  source "$REPO/neko.sh"
  neko_load
  trap 'export_cleanup' EXIT # main() normally installs this
  ui_init
  log_init
  config_load
  sys_detect
}

t_summary() { # prints totals; returns non-zero when any check failed
  local run fail
  run=$(grep -c . "$T_RESULTS")
  fail=$(grep -c '^FAIL' "$T_RESULTS")
  echo
  if ((fail)); then
    printf '\e[31m%d/%d checks failed\e[0m\n' "$fail" "$run"
    grep '^FAIL' "$T_RESULTS" | sed 's/^FAIL /  - /'
    return 1
  fi
  printf '\e[32mall %d checks passed\e[0m\n' "$run"
}
