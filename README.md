# linux-usb-wifi-rtl8812cu

Linux USB WiFi 驱动适配 —— **主控 Realtek RTL8812CU**（FAST FAC1300U 等 OEM 型号）

> 把「芯片被 Linux 主线支持、但 OEM USB ID 没被收录」的 Realtek WiFi 5 USB 网卡跑起来。
> 本文是一次真实适配的完整复盘（FAST FAC1300U / 主控 RTL8812CU），可复用于同类网卡。

| 项 | 值 |
|---|---|
| 主控 | Realtek **RTL8812CU**（802.11ac，2×2，80 MHz，USB） |
| 存储模式 ID | `0bda:1a2b` |
| 网卡模式 ID | `2357:0137` |
| 适用 | 任何「ID 未被 rtw88 收录、但芯片受支持」的 RTL8812CU/8822CU USB 网卡 |

**TL;DR**：主线 `rtw88_8822cu` 已支持 RTL8812CU，唯独不认 `2357:0137` 这个 OEM ID。
做法是拉 `lwfinger/rtw88` 外部模块 → ID 表加一行 → DKMS 编译 → 屏蔽内核自带同名驱动。
装完插上即用，内核升级自动重建。

---

## 1. 先判断：你这张卡属于哪一类

| 现象 | 含义 | 该做什么 |
|---|---|---|
| `lsusb` 直接看到网卡 ID，`ip link` 就有 `wlanX` | 内核已支持 | 什么都不用做 |
| ID 在主线里查不到，但**同芯片的参考 ID 在** | 只差一个 ID | **本文方案**：补 ID + DKMS |
| 芯片型号主线完全不支持（如早期 RTL8814AU） | 缺整套驱动 | 用厂商/社区完整驱动（`morrownr/8822cu`、`lwfinger/rtw88` 对应分支） |
| 插入后是 `0bda:xxxx` 且被识别成光驱/U 盘 | 「驱动光盘模式」 | 先做模式切换（见 §4.2） |

判断「主线是否支持」的三条命令（只读）：

```bash
lsusb                                            # 拿到 vid:pid
modinfo -F alias rtw_8822cu | grep -i 2357       # 已装模块里有没有
grep -n '0x2357' /usr/src/linux/drivers/net/wireless/realtek/rtw88/rtw8822cu.c
```

本卡实测结论（2026-11-25 核对）：

| 上游 | 是否有 `2357:0137` |
|---|---|
| torvalds/linux v6.8 | ❌（表内 6 条：`0bda:c82c/c812/c82e/d820/d82b`、`13b1:0043`） |
| torvalds/linux master | ❌（仅多一条 `2001:3329`） |
| lwfinger/rtw88 master | ❌（与 torvalds master 的 `rtw8822cu.c` 逐字节一致） |

⇒ **每次重装都必须重新打补丁，不能指望上游哪天收录。**

---

## 2. 为什么必须编译，不能 `new_id` 动态绑

`drivers/net/wireless/realtek/rtw88/usb.c:1293`

```c
rtwdev->chip = (struct rtw_chip_info *)id->driver_info;
```

芯片描述符（`rtw8822c_hw_spec`）是通过 `usb_device_id.driver_info` 传进来的。
而 `echo vid pid > /sys/bus/usb/drivers/rtw_8822cu/new_id` 只能填 vid/pid/class，
**`driver_info` 恒为 0** → `chip` 为空指针 → probe 阶段崩溃。
所以 `new_id` 这条路对 rtw88 封死，只能改 ID 表并重编译。

---

## 3. 这张卡的真实身份（怎么确认的）

| 项 | 值 | 证据 |
|---|---|---|
| 存储模式 ID | `0bda:1a2b` | `USBSTOR\CDROM&VEN_RTK&PROD_DRIVER_STORAGE` |
| 网卡模式 ID | `2357:0137` | SCSI eject 后重新枚举 |
| 芯片 | **RTL8812CU** | 厂商 INF 第 81/82 行：`%RTL8812cu.DeviceDesc% = RTL8812cu.ndi` 同时挂在 `0bda:c812` 与 `2357:0137` 上 |
| 接口类 | `ff/ff/ff` 单接口 | `lsusb -v` |

> 踩坑提醒：同型号不同批次的芯片可能被厂家换掉（INF 里也写明「厂家可能未通知更改配置」）。
> **认 ID 和芯片，不认商品名**。FAST 用的是 TP-Link 的 OUI `0x2357`，所以别看到 2357 就以为一定是 TP-Link 设备。

---

## 4. 实际做过的操作（按时间顺序）

时间戳取自服务器文件 mtime，非事后编写。

| # | 操作 | 产物 / 路径 |
|---|---|---|
| 1 | 装依赖 | `git build-essential dkms bc linux-headers-$(uname -r) usb-modeswitch` |
| 2 | 写模式切换配置 | `/etc/usb_modeswitch.d/0bda:1a2b`（`StandardEject=1`） |
| 3 | 写 udev 规则（插入即切） | `/etc/udev/rules.d/40-usb_modeswitch-8812cu.rules` |
| 4 | 克隆外部模块 | `git clone https://github.com/lwfinger/rtw88 /usr/local/src/rtw88` |
| 5 | **在 ID 表加一行** | `/usr/src/rtw88-0.6/rtw8822cu.c:26` |
| 6 | DKMS 编译安装 | `dkms install .` → `/lib/modules/*/updates/dkms/rtw_8822cu.ko.zst` |
| 7 | 屏蔽内核自带 rtw88 | `/etc/modprobe.d/rtw88.conf`（仓库自带，含 `blacklist rtw88_8822cu` 等 35 条） |
| 8 | （可选）按 MAC 固定接口名 | `/etc/udev/rules.d/70-wifi-usb.rules` → `wlan3usb` |

时间线证据：`usb_modeswitch.d` 与 udev 规则 18:19:16，`dkms.conf` 18:22:14，`rtw88.conf` 18:23:20（2026-10-09）。

### 4.1 必须补的那一行

```c
	{ USB_DEVICE_AND_INTERFACE_INFO(0x2357, 0x0137, 0xff, 0xff, 0xff),
	  .driver_info = (kernel_ulong_t)&(rtw8822c_hw_spec) },
```

完整补丁见 `patches/rtw88-add-2357-0137.patch`。

### 4.2 模式切换（这类「驱动光盘」网卡通病）

设备第一次插入是 **CD-ROM 模式**，此时不起网卡作用。三种切法，任选其一：

```bash
# A. usb_modeswitch（本文采用，配合 udev 自动触发）
usb_modeswitch -v 0bda -p 1a2b -KQ

# B. 直接 eject 光驱
eject /dev/sr0

# C. 内核参数禁用 usb-storage 对该 ID 的认领（写入 GRUB，永久）
usb-storage.quirks=0bda:1a2b:i
```

### 4.3 两个容易传错的细节

- **固件来自发行版，不是手工装的**。`/lib/firmware/rtw88/rtw8822c_fw.bin.zst` 属于包
  `linux-firmware-realtek`（mtime 2026-07-14），当时**没有**执行 `make install_fw`
  （否则会额外出现未压缩的 `.bin`）。所以只有发行版缺固件时才需要 `make install_fw`。
- `rtw88.conf` 里的 `options rtw_usb switch_usb_mode=y` 管的是 **USB2→USB3 模式切换**
  （用来规避 2.4 GHz 干扰），**不是**光盘模式切换。两者别混。

---

## 5. 复现

```bash
git clone https://github.com/UnthinkingBrain/linux-usb-wifi-rtl8812cu.git
cd linux-usb-wifi-rtl8812cu
sudo ./install.sh --check      # 先体检，不改系统
sudo ./install.sh              # 安装
sudo ./install.sh --uninstall  # 回滚
```

脚本做了这些事：依赖安装（apt/dnf/pacman 自适应）→ 模式切换配置 → 克隆源码 →
**幂等**插入 ID（含完整性自检，防止历史上出现过的文件截断）→ `dkms install` →
装 `rtw88.conf` → 加载验证。

换别的网卡只改文件头三个变量：

```bash
VID="2357"; PID="0137"; STORAGE_ID="0bda:1a2b"; DRIVER_SRC="rtw8822cu.c"
```

---

## 6. 装完怎么验证

```bash
modinfo -F alias rtw_8822cu | grep -i 2357   # 应有 usb:v2357p0137d*...icFFiscFFipFF
lsusb | grep -i 2357                          # 已切到网卡模式
ip -brief link | grep wl                      # 出现 wlanX
dmesg | grep -iE 'rtw88|8822c' | tail          # 无 firmware 报错
nmcli dev wifi list                           # 能看到 SSID
```

本机实测（2026-11-19 21:46，插卡后约 40 秒）：

```
kernel: rtw_8822cu 1-1:1.0 wlan3usb: renamed from wlan0
wpa_supplicant: wlan3usb: SME: Trying to authenticate with 80:cf:aa:bb:cc:dd (SSID='TestLab-5G' freq=5180 MHz)
kernel: wlan3usb: authenticated / associated
```

---

## 7. 排错表

| 症状 | 原因 | 处理 |
|---|---|---|
| 插上仍是 `0bda:1a2b`，没有 wlan | udev 未触发 / usb_modeswitch 未装 | 手动 `usb_modeswitch -KQ`；确认 `usb-modeswitch` 已装 |
| 有 `2357:0137` 但没有 wlanX | 模块没加载 / ID 没打上 | `modprobe rtw_8822cu`；`modinfo -F alias` 复核查 ID |
| `dmesg: failed to load firmware` | 固件缺失 | `apt install linux-firmware`，或源码里 `make install_fw` |
| `modprobe: Key was rejected by service` | Secure Boot 拒签 | `mokutil --import` 登记 DKMS 生成的 MOK，或关掉 Secure Boot |
| 内核升级后失效 | DKMS 未跟上 / 被卸载 | `dkms status`、`dkms autoinstall` |
| 两套驱动抢设备 | 内核版 rtw88 未屏蔽 | 确认 `/etc/modprobe.d/rtw88.conf` 在位 |
| 2.4 GHz 干扰严重 | USB3 模式射频干扰 | `options rtw_usb switch_usb_mode=n` |
| 接口名每次变化 | 未做名称固定 | 按 MAC 写 `70-wifi-usb.rules` |

---

## 8. 边界

- 本方案**只解决「缺 ID」**。芯片若不被 rtw88 支持，补 ID 无用，需换完整驱动。
- 补丁针对 `rtw8822cu.c`；换芯片要改 `DRIVER_SRC`，且 `.driver_info` 指向的 `hw_spec` 也要跟着换。
- 外部模块与内核自带模块**不能共存**，`rtw88.conf` 的 blacklist 是必需项，不是可选项。
- 重装系统 / 删 `/usr/src/rtw88-*` / 卸 `dkms` 之后失效，需重跑 `install.sh`。

---

## 9. 环境（本次实测）

| 项 | 值 |
|---|---|
| 系统 | Ubuntu 24.04.5 LTS |
| 内核 | 6.8.0-149-generic（安装时 6.8.0-146，已跨两次升级验证 DKMS 自动重建） |
| dkms | 3.0.11-1ubuntu13 |
| usb-modeswitch | 2.6.1-3ubuntu3 |
| 模块版本 | `rtw88/0.6`（lwfinger/rtw88 外部模块） |
| Secure Boot | 未启用（无需 MOK 登记） |

## License

脚本与文档：MIT。补丁按内核惯例 `GPL-2.0 OR BSD-3-Clause`（与 rtw88 一致）。
