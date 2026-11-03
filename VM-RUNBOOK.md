# 下一步待办 · 可执行版

对应 HANDOFF「下一步待办」的四项。**按顺序做，别跳步**：第 0 步不花钱不刷机，
却能提前否掉半个方案；第 7 步是上次失败的复核点，跳过它可能白刷一次。

---

## 第 0 步：手机侧验证（已完成，2026-10-28）

> **0.1 已经查完了**，用用户提供的 bugreport 直接拿到答案，不用再折腾：
>
> - 面板 = **CSOT（华星光电）NT36672C**，1080×2400，DSC video，TDDI
> - 证据：`DisplayDxe: MDPPLATFORM_PANEL_J17_CSOT_NT36672C_LCD_DSC_VIDEO`、
>   `Successfully bind display panel 'qcom,mdss_dsi_j17_42_02_0b_dsc_video'`（42=华星）、
>   `fw_name: novatek_nt36672c_j17_fw01.bin`、`panel is tddi`
> - 结论：**面板是原厂 CSOT 版，没有证据支持"换过屏"**
> - 但 fork 的驱动不认这块屏（只认 `tianma,fhd-video`，1080×2246），所以黑屏仍是大概率
>
> 找这些信息要在 `dumpstate_board.txt` 里搜 `DisplayDxe`，不是在 bugreport 正文里搜
> `lcm`/`nt36672` —— MIUI 的日志里压根不出现 LCM 这个词，所以之前怎么搜都搜不到。

### 0.2 OTG：这一项已经不用做了

DTS 里固定写着：

```dts
&usb_1_dwc3 {
    dr_mode = "peripheral";
};
```

设备模式，不是 host。所以这次**一定**接不了键盘，USB 口的唯一用途是跑 USB 网络
给 SSH 用。查 OTG 通不通没有意义 —— 要接键盘得改 DTS 加 host 模式，那是第二阶段。

### 0.3 解锁状态：现在就查，这一条可能卡住整个计划

bugreport 里显示：

```
ro.boot.flash.locked    = 1
ro.boot.verifiedbootstate = green
```

`flash.locked=1` + `green` = **抓报告时手机是锁定状态**。这跟"已经解锁"的说法是矛盾的。
最可能的解释：屏幕维修时维修店刷过机，或者某次 OTA 把解锁状态弄回去了。

**先确认**（手机关机 → 音量下+电源进 fastboot）：

```bash
fastboot oem device-info
```

看 `Device unlocked:` 那一行：

- `true` → 可以刷，继续第 1 步
- `false` → **必须重新解锁**（`fastboot flashing unlock`，会清空数据）。
  小米重新解锁通常还要再走一次 168 小时等待期，先去小米解锁工具里看绑定状态。
  这种情况下别急着编译，先解决解锁

顺带记录：电量充到 50% 以上（刷机掉电 = 变砖风险）；型号是 Redmi Note 9 Pro 5G（M2007J17C）。

---

## 第 1 步：虚拟机准备

```bash
# 在 Ubuntu 22.04 虚拟机里
nproc                          # 期望 ≥4
free -h                        # 期望 ≥7Gi 可用
df -h "$HOME"                  # 期望 ≥20G 可用
curl -sI https://github.com | head -1     # 期望 HTTP/1.1 200 或 301
```

不够就改 VMware 虚拟机设置：CPU 4 核、内存 8GB、磁盘 40GB。

磁盘扩过之后 Ubuntu 里要扩分区（按 Ubuntu 22.04 默认装法，/ 在 `/dev/sda3`）：

```bash
lsblk                                       # 先看清楚分区名，别照抄
sudo growpart /dev/sda 3
sudo resize2fs /dev/sda3
df -h /
```

**如果之前用旧脚本跑过**，清干净再来（旧 clone 里可能已经是被改坏的 APKBUILD）：

```bash
rm -rf ~/gauguin-build ~/.local/var/pmbootstrap
```

---

## 第 2 步：把 build.sh 送进虚拟机

文件在 Windows 这边：`D:\UserFiles\Documents\deepseek-harness\default-workspace\pmos-gauguin\build.sh`

三种办法，任选：

- VMware 共享文件夹（装了 vmware-tools 才挂得上，一般在 `/mnt/hgfs/<共享名>/`）
- 直接拖拽 / 复制粘贴文件进虚拟机桌面
- 虚拟机里没有中文输入法也不怕，最土但最可靠：把文件内容复制到剪贴板，
  在虚拟机里执行 `cat > build.sh <<'PASTE'`，粘贴，然后单独一行 `PASTE` 回车

不管哪种方式，**必须转一次换行符**（Windows 是 CRLF）：

```bash
cd ~
sed -i 's/\r$//' build.sh        # 不转的话 bash 报 $'\r': command not found
bash -n build.sh && echo "语法 OK"
chmod +x build.sh
```

---

## 第 3 步：预检（不装东西、不改系统，30 秒）

```bash
bash build.sh doctor
```

它会检查：系统/内存/磁盘/工具/sudo、GitHub 是否可达、
**两个 fork 仓库和那棵 gauge DTS 是否真的存在**、设备包路径、手机是否连着。

最后一次是重点：`✗` 说明整个方案的前提不成立（比如分支名改了、仓库没了），
这种时候别往下走，把输出发我。`!` 是警告，可以继续但要留意。

预期结尾：

```
==> 7/7 结论
  ✓ 全部通过，可以跑 bash build.sh setup
```

---

## 第 4 步：拉代码 + 改内核包

```bash
bash build.sh setup
```

依次做：装依赖（要 sudo 密码）→ pip 装 pmbootstrap → clone pmaports fork →
clone 内核分支（只取 DTS，浅克隆）→ 检查并补 `Makefile` 的 dtb 登记 →
**改写内核 APKBUILD 的 `source` 指向带 DTS 的分支** → 打印改动 diff →
写 fastboot udev 规则。

关键看这几行：

```
  ✓ 找到设备树：.../sm7225-xiaomi-gauguin.dts（xxxxx 字节）
  ✓ Makefile 已注册该 dtb
    [ok] APKBUILD rewritten: linux-sm6350@sm6350-7.2.y -> top dir linux-sm6350-$_branch
  ✓ 改写结果自检通过
```

自检不过会当场 `die`，不会让你白等一小时编译。
`diff -u` 那段保存好，出问题就是靠它定位。

> 这一步故意**不**算 checksum：pmbootstrap 没 `init` 之前不认 `--aports`，
> checksum 会失败。算 checksum 挪到 `install` 第一步做了。

---

## 第 5 步：pmbootstrap init（交互式）

```bash
bash build.sh init
```

按屏幕答案表回答，其中**最容易踩的一条**：

```
额外软件包 Extra pkgs : g++,make,vim,tmux,git,openssh,usbutils   ← 必须逗号分隔
```

**为什么必须现在填**：刷完的机器没有 Wi-Fi、没有基带、没有蓝牙 —— 它根本不能联网。
`apk add g++` 在手机上是**不可能**成功的。编译器只能现在就烤进镜像。
漏了这步，`install` 之后必须整包重做（又 20 分钟）。

其余答案：渠道 `edge`、厂商 `xiaomi`、设备 `xiaomi-gauguin`、UI `console`、
内核直接回车、时区 `Asia/Shanghai`。

---

## 第 6 步：编内核 + 出镜像

```bash
bash build.sh install
```

顺序：`pmbootstrap checksum`（下载 200MB 源码）→ 编内核（4 核 40-60 分钟）→
`pmbootstrap install --split`（再 10-20 分钟；额外包在 init 时已写进配置，**不要**再传 `--add`，
pmbootstrap 3 的 `--add` 只认逗号分隔，空格列表会被当成一个包名）。

中途别关终端。所有输出同时存到 `~/gauguin-build/logs/`。

---

## 第 7 步：验证 dtb 真进了镜像（别跳）

```bash
bash build.sh verify
```

它干的事：从 `deviceinfo` 读出 `deviceinfo_dtb` 的值，然后
**在编出来的内核 apk 和 boot 镜像里搜这个名字**。

这就是上次 `mkinitfs` 报错的那个点的机器化复核。期望：

```
==> 1/2 内核包里有没有 sm7225-xiaomi-gauguin
  ✓ linux-postmarketos-qcom-sm6350-7.2.0-r0.apk 含 sm7225-xiaomi-gauguin
==> 2/2 boot 镜像 / initramfs 里有没有 sm7225-xiaomi-gauguin
  ✓ xiaomi-gauguin-boot.img 含 sm7225-xiaomi-gauguin
  ✓ dtb 已进镜像，可以刷：bash build.sh flash
```

搜不到就**别刷**，按它给的三步排查，把日志发我。

---

## 第 7.5 步：无头首刷的三条硬约束（黑屏已是定局，这步是保命）

屏幕基本不会亮（驱动不认这块 CSOT 屏），所以你只有 USB 网络这一个入口。
下面三条不满足，刷完可能连"它到底起没起来"都判断不了：

**1. 镜像里必须有 SSH**

`build.sh` 的额外包已改成 `g++ make vim tmux git openssh usbutils`。如果你自己手改过，
确认 `openssh` 在里面 —— 没有它，就算网卡通了你也没有入口登进去。
`usbutils` 是为了进去后能看 `lsusb` 和插拔状态。

**2. 没网卡时的抢救通道：`pmos.debug-shell`**

如果刷完网卡没出现，说明卡在 initramfs 或更早。这时把这一行加进 deviceinfo 再重刷：

```bash
cd ~/gauguin-build/pmaports-gauguin
edit device/*/device-xiaomi-gauguin/deviceinfo   # 在 deviceinfo_kernel_cmdline 末尾加 pmos.debug-shell
bash ~/build.sh install   # 重新生成镜像（不用重编内核）
```

刷完就能 `telnet 172.16.42.1 23` 进 initramfs 的调试 shell，看它卡在哪。
**别一直留着这个参数** —— 它可能会停在 initramfs 不继续启动，用完要删掉。

**3. 永远插着线，别指望断电重启**

DTS 里没有电池/充电节点，等于没有电源管理：拔线就是立刻掉电，重启也只能靠重新插线按电源键。
当编译机用本来就得插着，但别把它放在床上/包里跑任务。

---

## 第 8 步：刷机

手机：关机 → 按住**音量下 + 电源** → 出现 FASTBOOT 橙色字再松手 → 插线。

```bash
fastboot devices          # 得能看到一串序列号
bash build.sh flash
```

**关于 boot.img 大小**（2026-10-28 查源码确认）：`install --split` 会生成两个 boot 相关文件——

- `chroot_native/home/pmos/rootfs/xiaomi-gauguin-boot.img`：按 `boot_size`（512MB）填充的分区镜像
- `chroot_rootfs_xiaomi-gauguin/boot/boot.img`：≈26MB，真正的 Android boot 镜像

我们的 `deviceinfo_flash_method="fastboot"`，pmbootstrap 的 `fastboot` flasher 刷的是后者
（`$BOOT/boot.img`）；前者只属于 `fastboot-bootpart` 那种 flash method。所以 512MB 那个不用管，
也不必为了它去调 `boot_size`（3.x 还强制要求 ≥512）。判据：fastboot 打印 `Sending 'boot' (26xxx KB)`。

`flash_rootfs` 会清空 userdata（手机里的数据没了，刷之前自己备份）。

刷完长按电源开机，第一次 1-3 分钟。

---

## 第 9 步：进系统（黑屏也要试）

手机插着的 USB 线另一端接 Ubuntu。Ubuntu 上：

```bash
ip a                      # 找新冒出来的 enp0s20u1 / usb0 之类
sudo ip addr add 172.16.42.2/24 dev <那个接口>
ping -c1 172.16.42.1
ssh <init 时填的用户名>@172.16.42.1
```

进去之后确认编译器在了：

```bash
g++ --version
echo 'int main(){return 0;}' > a.cpp && g++ a.cpp -o a && ./a && echo OK
```

如果 NetworkManager 抢走了这个接口导致没网，就把它设成手动：

```bash
nmcli con mod <连接名> ipv4.method manual ipv4.addresses 172.16.42.2/24
nmcli con up <连接名>
```

---

## 排错对照表

| 症状 | 原因 | 动作 |
| --- | --- | --- |
| `bash: $'\r': command not found` | Windows 换行 | `sed -i 's/\r$//' build.sh` |
| `doctor` 里 DTS 那条 `✗ 404` | 分支名/仓库名变了 | 停，别 setup，把输出发我 |
| `pip install pmbootstrap` 报 `externally-managed-environment` | Python 太新（23.04+） | 脚本会退回 git 源码方式；若也失败，`python3 -m venv ~/pmb && ~/pmb/bin/pip install pmbootstrap` |
| `pmbootstrap: command not found` | `~/.local/bin` 不在 PATH | `echo 'export PATH=$HOME/.local/bin:$PATH' >> ~/.bashrc && exec bash` |
| `checksum` 报 `Config file not found` | 还没 init | `bash build.sh init` 后重跑 install |
| 编内核被 `Killed` | 内存不够（OOM） | 虚拟机内存加到 8GB；或把 init 里的 `--jobs` 调成 2 |
| `builddir ... does not exist` | APKBUILD 的 builddir 没改对 | 看 setup 打印的 diff；`grep builddir=` 对比解压目录名 |
| `mkinitfs` 还是找不到 dtb | dtb 没进包 | 跑 `bash build.sh verify`，按它给的排查顺序 |
| `fastboot devices` 空的 | 线/口/权限/模式 | 换线换口、`sudo fastboot devices` 对比、确认在 FASTBOOT 界面 |
| 黑屏但有背光 | 面板驱动没绑上（型号不对或 DTS 的偏压/时序问题） | **先别急着重刷**：看电脑上有没有新网卡。有 → SSH 进去 `dmesg \| grep -iE 'panel\|nt36672'`，内核会告诉你它认没认得这块屏 |
| 黑屏且电脑上没新网卡 | 内核没起来 | 真失败。重刷官方 `boot.img` 或整包 |
| 屏亮但一直转圈/没输出 | 起不来 | 接 USB 看有没有网卡；没网卡就接串口（见下） |

### 关于"黑屏"

**黑屏 ≠ 白忙。** 你的目标是写 ACM 题，输出在笔记本屏幕上，手机只是个编译/运行环境。
所以判据只有一条：

```
刷完 30 秒内，Ubuntu 上 ip a 有没有新网卡，ping 172.16.42.1 通不通
```

- **通** → 系统起来了。`ssh` 进去，`dmesg | grep -iE 'panel|nt36672'` 看面板真相，
  g++ 能编能跑就能用。屏幕不亮只影响"手机自己显示"，不影响"拿它编译"
- **不通** → 内核没起来，这才是真失败

DTS 里还有个 `simple-framebuffer@a0000000`（1080×2400）加上 cmdline `console=tty0`，
理论上面板驱动绑不上时，内核 console 还有机会通过 bootloader 留下的 framebuffer
显示出来。**不敢保证**（取决于 bootloader 是否交出了 framebuffer、时序是否对），
但如果你看到开机图案之后停在那里，值得等 10 秒钟看有没有文字冒出来。

**抓日志的办法**（没有串口时最有用）：刷完立刻在 Ubuntu 上

```bash
sudo apt install picocom
picocom -b 115200 /dev/ttyUSB0        # 需要 USB 串口小板接主板测试点，没有就跳过
```

没有串口板就只能靠"屏幕有没有反应 + USB 网卡有没有出现"两个信号。
这两个都没有，基本是内核根本没起来，把 `~/gauguin-build/logs/` 里最新的日志发我。

---

## 跑完要回传给我的东西

1. 第 0.1 步查到的结果（是/不是 nt36672c，或者"查不到"）
2. `bash build.sh doctor` 的完整输出
3. `pmbootstrap --version` 的输出（这个决定我后面给命令时用什么参数）
4. 卡住那一步的 `~/gauguin-build/logs/*.log`
5. 屏幕现象：黑屏 / 有背光黑屏 / 亮屏无输出 / 进系统；以及**电脑上有没有出现网卡**
6. 如果进去了：`dmesg | grep -iE 'panel|nt36672'` 的输出

## 暂时不要碰的（第二阶段）

- 触摸只覆盖半屏 → 需要在 DTS 里改 touchscreen 的坐标范围
- USB 改 host 模式接键盘 → 改 `dr_mode` + typec 方向检测
- Wi-Fi/蓝牙（WCN3991）、音频、相机、基带 → 都需要各自的固件和 DTS 节点
- 面板不匹配 → 先看第 9 步的 `dmesg` 结果再决定要不要写新面板节点
