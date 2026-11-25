#!/usr/bin/env bash
# =============================================================================
# linux-usb-wifi-rtl8812cu
#
# 给 lwfinger/rtw88 外部模块补一个 OEM USB ID，让「芯片被主线支持、但 ID 未被收录」
# 的 Realtek WiFi 5 USB 网卡在 Linux 上可用。
#
# 默认目标：FAST（迅捷）FAC1300U —— 主控 RTL8812CU，光盘模式 0bda:1a2b → 网卡模式 2357:0137
#
# 用法：
#   sudo ./install.sh              # 安装
#   sudo ./install.sh --check      # 只体检，不改系统
#   sudo ./install.sh --uninstall  # 卸载（保留源码目录）
#
# 支持：Debian/Ubuntu、Fedora/RHEL、Arch（apt / dnf / pacman 自动识别）
# =============================================================================
set -euo pipefail

# ------------------------------ 可调参数 -------------------------------------
VID="2357"                  # 网卡模式 vendor id
PID="0137"                  # 网卡模式 product id
STORAGE_ID="0bda:1a2b"      # 光盘/存储模式 id（无此形态则留空）
DRIVER_SRC="rtw8822cu.c"    # 该 ID 所属芯片的驱动源文件（RTL8812CU/8822CU 用 rtw8822cu.c）
REPO="https://github.com/lwfinger/rtw88"
SRC_DIR="/usr/local/src/rtw88"
DKMS_NAME="rtw88"
FW_FILE="rtw8822c_fw.bin"   # 需要的固件（.bin 或 .bin.zst 任一同在即可）

# ------------------------------ 输出 ----------------------------------------
if [ -t 1 ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; B=$'\033[1m'; N=$'\033[0m'
else
  R=; G=; Y=; C=; B=; N=
fi
ok()   { printf '%s[ OK ]%s %s\n' "$G" "$N" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$C" "$N" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$Y" "$N" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$R" "$N" "$*" >&2; }
step() { printf '\n%s=== %s ===%s\n' "$B" "$*" "$N"; }
die()  { err "$*"; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "需要 root，请用 sudo 运行"; }

pkg() {  # pkg <cmd> <apt-name> <dnf-name> <pacman-name>
  if command -v apt-get >/dev/null; then echo "$2"
  elif command -v dnf >/dev/null; then echo "$3"
  elif command -v pacman >/dev/null; then echo "$4"
  else echo ""; fi
}

# ------------------------------ 0. 体检 --------------------------------------
check_env() {
  step "环境体检"
  info "内核: $(uname -r)"
  . /etc/os-release 2>/dev/null && info "发行版: ${PRETTY_NAME:-未知}"

  if command -v lsusb >/dev/null; then
    if lsusb | grep -qi "${VID}:${PID}"; then
      ok "设备已在网卡模式 ${VID}:${PID}"
    elif [ -n "$STORAGE_ID" ] && lsusb | grep -qi "$STORAGE_ID"; then
      warn "设备处于存储/光盘模式 $STORAGE_ID —— 需要模式切换"
    else
      warn "未检测到该设备（未插入不影响装驱动）"
    fi
  else
    warn "lsusb 不可用（apt install usbutils）"
  fi

  [ -d "/lib/modules/$(uname -r)/build" ] && ok "内核头文件在位" \
    || warn "缺内核头文件：linux-headers-$(uname -r)"

  if modinfo rtw_8822cu >/dev/null 2>&1; then
    local alias_hit="否"
    modinfo -F alias rtw_8822cu 2>/dev/null | grep -qi "v${VID}p${PID}" && alias_hit="是"
    info "当前 rtw_8822cu 已装，含该 ID: ${alias_hit}"
    info "模块路径: $(modinfo -n rtw_8822cu)"
  else
    info "当前无 rtw_8822cu 模块（首次安装状态）"
  fi

  command -v dkms >/dev/null && info "dkms: $(dkms --version 2>/dev/null | head -1)"
  dkms status 2>/dev/null | grep -i "^${DKMS_NAME}" || true

  if [ -d /sys/firmware/efi ]; then
    local sb; sb=$(od -An -t u1 -j4 -N1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | tr -d ' ')
    [ "${sb:-0}" = "1" ] && warn "Secure Boot 已开启 —— DKMS 会生成 MOK，首次需在 UEFI 里登记（mokutil --import）" \
                         || ok "Secure Boot 未开启"
  else
    info "非 UEFI 引导（无 Secure Boot 顾虑）"
  fi

  if ls /lib/firmware/"${FW_FILE%.bin}"* >/dev/null 2>&1; then
    ok "固件在位: $(ls /lib/firmware/rtw88/ 2>/dev/null | grep -c .) 个文件"
  else
    warn "未找到固件 $FW_FILE（Ubuntu: apt install linux-firmware）"
  fi
}

# ------------------------------ 1. 依赖 --------------------------------------
install_deps() {
  step "1/5 依赖"
  local base; base=$(pkg apt dnf pacman)
  case "$base" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq || warn "apt update 失败，继续"
      apt-get install -y --no-install-recommends git build-essential dkms bc kmod \
        "linux-headers-$(uname -r)" usb-modeswitch usb-modeswitch-data usbutils \
        || warn "部分依赖安装失败，请检查源"
      ;;
    dnf)
      dnf install -y git make gcc dkms bc kmod "kernel-devel-$(uname -r)" usb_modeswitch usbutils \
        || warn "部分依赖安装失败"
      ;;
    pacman)
      pacman -Sy --noconfirm --needed git base-devel dkms bc kmod usb_modeswitch usbutils linux-headers \
        || warn "部分依赖安装失败"
      ;;
    *) warn "未识别的包管理器，请手动安装 git/make/gcc/dkms/kernel headers" ;;
  esac
  for t in git make dkms; do
    command -v "$t" >/dev/null && ok "$t 就绪" || die "$t 缺失"
  done
}

# ------------------------------ 2. 模式切换 ----------------------------------
setup_modeswitch() {
  step "2/5 模式切换（存储模式 -> 网卡模式）"
  [ -n "$STORAGE_ID" ] || { info "未配置存储模式 ID，跳过"; return 0; }
  local sVID="${STORAGE_ID%%:*}" sPID="${STORAGE_ID##*:}"

  if grep -rqiE "TargetProduct.*0x${PID}" /usr/share/usb_modeswitch/ /etc/usb_modeswitch.d/ 2>/dev/null; then
    ok "系统数据已覆盖 ${STORAGE_ID} -> ${VID}:${PID}"
  else
    mkdir -p /etc/usb_modeswitch.d
    cat > "/etc/usb_modeswitch.d/${STORAGE_ID}" <<EOF
# Realtek RTL8812CU USB WiFi adapter
# Driver CD-ROM mode -> WLAN mode
TargetVendor=0x${VID}
TargetProduct=0x${PID}
StandardEject=1
EOF
    ok "已写 /etc/usb_modeswitch.d/${STORAGE_ID}"
  fi

  cat > /etc/udev/rules.d/40-usb_modeswitch-8812cu.rules <<EOF
# Realtek RTL8812CU USB WiFi adapter: 插入时若为存储模式，自动切换
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="${sVID}", ATTR{idProduct}=="${sPID}", RUN+="/usr/sbin/usb_modeswitch -v ${sVID} -p ${sPID} -KQ"
EOF
  ok "已写 udev 规则 40-usb_modeswitch-8812cu.rules"

  udevadm control --reload-rules 2>/dev/null || true
  udevadm trigger --subsystem-match=usb --action=change 2>/dev/null || true

  if command -v lsusb >/dev/null && lsusb | grep -qi "$STORAGE_ID"; then
    info "立即切换一次..."
    usb_modeswitch -v "$sVID" -p "$sPID" -KQ 2>&1 | tail -2 || \
      warn "usb_modeswitch 返回非 0；备选：eject /dev/sr0"
    sleep 3
  fi
  lsusb | grep -qi "${VID}:${PID}" && ok "已切到网卡模式 ${VID}:${PID}" \
    || warn "尚未看到 ${VID}:${PID}（可 eject 光驱后重新插拔）"
}

# ------------------------------ 3. 源码 + 补 ID ------------------------------
fetch_and_patch() {
  step "3/5 拉源码并补 USB ID"

  mkdir -p "$(dirname "$SRC_DIR")"
  if [ -d "$SRC_DIR/.git" ]; then
    git -C "$SRC_DIR" pull --ff-only || warn "git pull 失败，沿用现有源码"
  else
    rm -rf "$SRC_DIR"
    git clone --depth 1 "$REPO" "$SRC_DIR" || die "git clone 失败，检查网络"
  fi
  ok "源码: $SRC_DIR"

  local target="$SRC_DIR/$DRIVER_SRC"
  [ -f "$target" ] || die "找不到 $target（若换芯片，请改 DRIVER_SRC）"

  # 幂等插入；插完做完整性自检，防止文件被截断（历史踩坑）
  python3 - "$target" "$VID" "$PID" <<'PYEOF'
import re, sys
path, vid, pid = sys.argv[1], sys.argv[2].lower(), sys.argv[3].lower()
src = open(path, encoding='utf-8').read()
orig_len = len(src)

if f'0x{vid}' in src and f'0x{pid}' in src:
    print(f"[ OK ] {vid}:{pid} 已存在，跳过"); sys.exit(0)

entry = (f"\t{{ USB_DEVICE_AND_INTERFACE_INFO(0x{vid}, 0x{pid}, 0xff, 0xff, 0xff),\n"
         f"\t  .driver_info = (kernel_ulong_t)&(rtw8822c_hw_spec) }}, "
         f"/* OEM RTL8812CU (storage mode 0bda:1a2b) */\n")

m = re.search(r'static const struct usb_device_id \w+\[\]\s*=\s*\{', src)
if not m:
    print("[FAIL] 未定位到 id_table，请手工打补丁"); sys.exit(2)
term = '\n\t{},\n};'
i = src.find(term, m.start())
if i == -1:
    print("[FAIL] 未定位到终止项 {}"); sys.exit(3)

new = src[:i] + '\n' + entry + src[i+1:]      # i+1 保留终止项本体及后文
missing = [k for k in ('MODULE_LICENSE', 'module_usb_driver') if k not in new]
if missing:
    print("[FAIL] 补丁后文件被截断，缺少: " + ", ".join(missing)); sys.exit(4)

open(path, 'w', encoding='utf-8').write(new)
print(f"[ OK ] 已插入 {vid}:{pid}（{orig_len} -> {len(new)} 字节）")
print("[ OK ] 完整性自检通过")
PYEOF

  info "插入结果："
  grep -n -A1 -B1 "0x${VID}" "$target" | sed 's/^/    /' | head -8
}

# ------------------------------ 4. 编译安装 ----------------------------------
build_install() {
  step "4/5 DKMS 编译安装"
  [ -d "/lib/modules/$(uname -r)/build" ] || die "缺内核头文件：apt install linux-headers-$(uname -r)"

  cd "$SRC_DIR"

  local ver
  ver=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' dkms.conf | head -1)
  [ -n "$ver" ] && dkms remove "${DKMS_NAME}/${ver}" --all >/dev/null 2>&1 || true
  rm -rf "/var/lib/dkms/$DKMS_NAME"
  for d in /usr/src/"${DKMS_NAME}"-*; do [ -d "$d" ] && rm -rf "$d"; done

  dkms install "$PWD" || die "dkms install 失败，看 /var/lib/dkms/$DKMS_NAME/*/build/make.log"
  ok "DKMS 安装完成（版本 ${ver:-?}）"

  # 固件：发行版一般自带；缺失才用源码里的
  if ls /lib/firmware/"${FW_FILE%.bin}"* >/dev/null 2>&1; then
    ok "固件已由发行版提供，跳过安装"
  else
    warn "发行版无固件，改用源码内置：make install_fw"
    make install_fw 2>&1 | tail -3 || warn "make install_fw 失败"
  fi

  # 关键：屏蔽内核自带 rtw88，避免两套驱动抢设备
  if [ -f "$SRC_DIR/rtw88.conf" ]; then
    cp -f "$SRC_DIR/rtw88.conf" /etc/modprobe.d/
    ok "已装 /etc/modprobe.d/rtw88.conf（blacklist 内核版 + 参数）"
  fi
  depmod -a
}

# ------------------------------ 5. 加载验证 ----------------------------------
verify() {
  step "5/5 加载与验证"
  modprobe -r rtw_8822cu 2>/dev/null || true
  modprobe rtw_8822cu && ok "rtw_8822cu 已加载" || warn "modprobe 失败（可能未插卡）"

  echo
  info "1) 模块 ID 表："; modinfo -F alias rtw_8822cu 2>/dev/null | grep -i "v${VID}p${PID}" | sed 's/^/    /' || echo "    (未含该 ID)"
  info "2) USB 设备：";  lsusb | grep -iE "${VID}:${PID}|${STORAGE_ID}" | sed 's/^/    /' || echo "    (未检测到)"
  info "3) 网络接口：";  ip -brief link | grep -i wl | sed 's/^/    /' || echo "    (无无线接口)"
  info "4) dmesg：";     dmesg | grep -iE 'rtw88|rtw_8822cu|8822c' | tail -8 | sed 's/^/    /' || echo "    (无)"
  info "5) 固件加载失败？"; dmesg | grep -i 'failed to load firmware' | tail -3 | sed 's/^/    /' || true

  echo
  cat <<'TIP'
下一步（插卡后）：
    ip -brief link                 # 应出现新 wlanX
    sudo iw dev                    # 看 phy
    nmcli dev wifi list            # 扫 SSID
    sudo dmesg -w                  # 边看日志边插拔
TIP
}

# ------------------------------ 卸载 ----------------------------------------
uninstall() {
  step "卸载"
  dkms remove "$DKMS_NAME" --all 2>/dev/null && ok "dkms remove 完成" || warn "无 DKMS 记录"
  for d in /usr/src/"${DKMS_NAME}"-*; do [ -d "$d" ] && rm -rf "$d" && ok "删除 $d"; done
  rm -f /etc/modprobe.d/rtw88.conf
  rm -f /etc/udev/rules.d/40-usb_modeswitch-8812cu.rules
  [ -n "$STORAGE_ID" ] && rm -f "/etc/usb_modeswitch.d/${STORAGE_ID}"
  udevadm control --reload-rules 2>/dev/null || true
  depmod -a
  ok "已卸载（源码 $SRC_DIR 保留）"
}

# ------------------------------ main ----------------------------------------
main() {
  require_root
  case "${1:-}" in
    --check)     check_env; exit 0 ;;
    --uninstall) uninstall; exit 0 ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
  esac
  check_env
  install_deps
  setup_modeswitch
  fetch_and_patch
  build_install
  verify
}

main "$@"
