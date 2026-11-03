#!/usr/bin/env bash
# ---------------------------------------------------------------
# Xiaomi gauguin (Redmi Note 9 Pro 5G / Mi 10T Lite / Mi 10i)
# postmarketOS(Nura) 自编译脚本 —— 在 Ubuntu 22.04 虚拟机里运行
#
# 用法：
#   bash build.sh doctor  # 预检：环境、网络、两个 fork 仓库是否真的存在（只读，只写日志）
#   bash build.sh setup   # 装依赖、拉代码、改内核包的 source 指向带 DTS 的分支
#   bash build.sh init    # 交互式 pmbootstrap init（会提示你按答案表回答）
#   bash build.sh install # 重算 checksum + 编内核 + 生成镜像（约 1 小时）
#   bash build.sh verify  # 关键：确认 dtb 真的进了内核包和 boot 镜像（上次就死在这）
#   bash build.sh flash   # 刷进手机（手机需已解锁并进 fastboot）
#
# 每个子命令的输出都会同时写进 $WORK/logs/ 下的日志，出问题把日志发出来即可。
# 想关掉日志：NO_TEE=1 bash build.sh doctor
# ---------------------------------------------------------------
set -euo pipefail

WORK="${WORK:-$HOME/gauguin-build}"
APORTS="$WORK/pmaports-gauguin"
APORTS_REPO="https://github.com/UsrBinLuna/pmaports-gauguin"
APORTS_BRANCH="gauguin"
KERNEL_REPO="https://github.com/UsrBinLuna/linux-sm6350"
KERNEL_BRANCH="sm6350-7.2.y"
KERNEL_PKG="linux-postmarketos-qcom-sm6350"
KERNEL_PKG_REL="device/community/linux-postmarketos-qcom-sm6350"
DEVICE="xiaomi-gauguin"
DTB_NAME="sm7225-xiaomi-gauguin"
# 屏幕基本点不亮（驱动不认 CSOT 屏），唯一入口是 USB 网络 + SSH，
# 所以 openssh 和 usbutils 必须烤进镜像 —— 机器离线，事后装不了。
# kbd 提供 setfont 和 /usr/share/consolefonts/（27 寸屏上的 console 字体太小时要用）
EXTRA_PKGS="g++ make vim tmux git openssh usbutils kbd"
# pmbootstrap init 的 "Extra packages" 提示只接受逗号分隔（正则里没有空格）
EXTRA_PKGS_CSV="${EXTRA_PKGS// /,}"
PMB_DATA="$HOME/.local/var/pmbootstrap"
FASTBOOT_VID="2717"          # Xiaomi 的 USB 厂商号，用于 fastboot 免 sudo

WARN=0
FAIL=0

msg()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; WARN=$((WARN + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
die()  { printf '\n\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

pmb() { pmbootstrap --aports="$APORTS" "$@"; }

# 非交互 apt：避免 dpkg 弹紫框把脚本卡死
export DEBIAN_FRONTEND=noninteractive
export PATH="$HOME/.local/bin:$PATH"

CMD="${1:-setup}"
case "$CMD" in
    doctor|setup|init|install|verify|postfix|flash) ;;
    *) echo "用法：bash $0 {doctor|setup|init|install|verify|postfix|flash}"; exit 1 ;;
esac

# 全程留日志（-u 下 LOG 先定义好）
mkdir -p "$WORK/logs" 2>/dev/null || true
LOG="$WORK/logs/$(date +%Y%m%d-%H%M%S)-$CMD.log"
if [ -z "${NO_TEE:-}" ] && [ -d "$WORK/logs" ]; then
    exec > >(tee -a "$LOG") 2>&1
fi

# 统一成 3 位状态码：网络彻底失败时 curl 也会打印 000，这里归一化，别让 "000000" 落到别的分支
http_code() {
    local c
    c=$(curl -sIL -o /dev/null -w '%{http_code}' --max-time 25 "$1" 2>/dev/null || true)
    case "${c:-}" in
        2[0-9][0-9]|3[0-9][0-9]) printf '%s' "$c" ;;
        *) printf '000' ;;
    esac
}

KREPO_GH="${KERNEL_REPO#https://github.com/}"    # UsrBinLuna/linux-sm6350
AREPO_GH="${APORTS_REPO#https://github.com/}"    # UsrBinLuna/pmaports-gauguin

# ---------------------------------------------------------------
case "$CMD" in

doctor)
    msg "0/7 系统"
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        info "${PRETTY_NAME:-未知发行版} / 内核 $(uname -r) / $(uname -m)"
        case "${ID:-}${VERSION_ID:-}" in
            ubuntu22.04|debian12) ok "发行版合适" ;;
            *) warn "脚本按 Ubuntu 22.04 写的，当前是 ${ID:-?} ${VERSION_ID:-?}，包名/apt 行为可能不同" ;;
        esac
    fi
    [ "$(uname -m)" = "x86_64" ] || info "架构 $(uname -m)（x86_64 最快，其它架构也能跑但编译更慢）"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        v=$(systemd-detect-virt || true)
        info "虚拟化：${v:-none}"
        [ "$v" = "none" ] || warn "在虚拟机里编内核，务必给足内存（见下面内存检查）"
    fi

    msg "1/7 磁盘（编内核 + chroot 至少 20GB）"
    avail=$(df -Pk "$HOME" | awk 'NR==2 {print int($4 / 1024 / 1024)}')
    if [ "${avail:-0}" -ge 20 ]; then ok "$HOME 剩余 ${avail}GB"
    else bad "$HOME 只剩 ${avail}GB，先在 VMware 里扩容虚拟磁盘，再进系统扩分区"; fi

    msg "2/7 内存（8GB 起，4GB 会在编内核时 OOM）"
    mem_gb=$(awk '/MemTotal/ {print int($2 / 1024 / 1024)}' /proc/meminfo)
    if [ "$mem_gb" -ge 7 ]; then ok "${mem_gb}GB"
    else warn "${mem_gb}GB 偏少；编内核时可能被 OOM killer 杀掉，建议先加到 8GB"; fi

    msg "3/7 基本工具"
    for t in git curl python3 tar find timeout; do
        if command -v "$t" >/dev/null 2>&1; then ok "$t"; else bad "缺 $t（setup 会装，但先知道）"; fi
    done
    if command -v sudo >/dev/null 2>&1; then
        if sudo -n true 2>/dev/null; then ok "sudo 免密可用"
        else warn "sudo 需要密码，setup 会提示你输入"; fi
    else bad "没有 sudo，装依赖那步会失败"; fi
    if command -v pmbootstrap >/dev/null 2>&1; then
        info "已装 pmbootstrap：$(pmbootstrap --version 2>&1 | head -1)"
    else
        info "尚未安装 pmbootstrap（setup 会用 pip 装）"
    fi
    if command -v python3 >/dev/null 2>&1; then
        pv=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo "?")
        case "$pv" in
            3.9|3.1[0-9]|3.[2-9][0-9]) ok "python3 $pv" ;;
            *) warn "python3 $pv —— pmbootstrap 要 3.9+" ;;
        esac
    fi
    if command -v fastboot >/dev/null 2>&1; then
        d=$(fastboot devices 2>/dev/null | tr -d '\r' || true)
        if [ -n "$d" ]; then ok "fastboot 已连上：$d"; else info "fastboot 已装，当前没检测到设备（正常，刷机时才需要）"; fi
    else
        info "尚未安装 fastboot（setup 会装）"
    fi

    msg "4/7 网络：GitHub 能不能访问"
    c=$(http_code https://github.com)
    case "$c" in
        2*|3*) ok "github.com 可达（HTTP $c）" ;;
        000)   bad "连不上 github.com：先解决网络/代理，否则后面 clone 必失败" ;;
        *)     warn "github.com 返回 HTTP $c，可能被拦或需要代理" ;;
    esac

    msg "5/7 关键文件是否真的存在（这一步能提前否定整个方案，别急着 clone 200MB）"
    raw_url="https://raw.githubusercontent.com/$KREPO_GH/$KERNEL_BRANCH/arch/arm64/boot/dts/qcom/$DTB_NAME.dts"
    c=$(http_code "$raw_url")
    case "$c" in
        200) ok "内核分支里有 $DTB_NAME.dts" ;;
        404) bad "该分支里没有 $DTB_NAME.dts —— 方案前提不成立，别往下跑。分支名/仓库名要重新确认" ;;
        *)   warn "取 $DTB_NAME.dts 失败（HTTP $c）：$raw_url" ;;
    esac
    c=$(http_code "$KERNEL_REPO/archive/refs/heads/$KERNEL_BRANCH.tar.gz")
    case "$c" in
        200) ok "内核仓库分支 $KERNEL_BRANCH 存在" ;;
        404) bad "内核仓库里没有分支 $KERNEL_BRANCH：$KERNEL_REPO" ;;
        *)   warn "探测内核仓库分支失败（HTTP $c）" ;;
    esac
    c=$(http_code "$APORTS_REPO/archive/refs/heads/$APORTS_BRANCH.tar.gz")
    case "$c" in
        200) ok "pmaports fork 分支 $APORTS_BRANCH 存在" ;;
        404) bad "pmaports fork 没有分支 $APORTS_BRANCH：$APORTS_REPO" ;;
        *)   warn "探测 pmaports fork 失败（HTTP $c）" ;;
    esac

    msg "6/7 仓库里的关键内容"
    for rel in "$KERNEL_PKG_REL/APKBUILD" ; do
        c=$(http_code "https://raw.githubusercontent.com/$AREPO_GH/$APORTS_BRANCH/$rel")
        case "$c" in
            200) ok "pmaports: $rel" ;;
            *)   warn "取不到 pmaports/$rel（HTTP $c），设备包路径可能和脚本假设不同" ;;
        esac
    done
    devinfo_hit=""
    for d in testing community main; do
        c=$(http_code "https://raw.githubusercontent.com/$AREPO_GH/$APORTS_BRANCH/device/$d/device-$DEVICE/deviceinfo")
        if [ "$c" = "200" ]; then devinfo_hit="device/$d/device-$DEVICE"; break; fi
    done
    if [ -n "$devinfo_hit" ]; then ok "设备包位置：$devinfo_hit"
    else warn "没探到 device-$DEVICE/deviceinfo（fork 里设备包路径不明，setup 后会本地再查）"; fi

    msg "7/7 结论"
    info "日志：$LOG"
    if [ "$FAIL" -gt 0 ]; then
        bad "有 $FAIL 项硬性失败，先解决再跑 setup（见上面 ✗ 的行）"
    elif [ "$WARN" -gt 0 ]; then
        ok "没有硬性失败，有 $WARN 项警告 —— 可以跑 bash $0 setup，但先看一眼警告"
    else
        ok "全部通过，可以跑 bash $0 setup"
    fi
    if [ "$FAIL" -gt 0 ]; then
        exit 1
    fi
    exit 0
    ;;

setup)
    msg "1/6 安装依赖（要输 sudo 密码）"
    sudo apt-get update
    sudo apt-get install -y git curl ca-certificates python3 python3-pip python3-venv \
        build-essential tar xz-utils
    sudo apt-get install -y android-tools-adb android-tools-fastboot 2>/dev/null \
        || sudo apt-get install -y adb fastboot 2>/dev/null \
        || warn "adb/fastboot 没装上，刷机那步再手动装"
    ok "依赖就绪"

    msg "2/6 安装 pmbootstrap"
    if ! command -v pmbootstrap >/dev/null 2>&1; then
        python3 -m pip install --user --upgrade pip >/dev/null 2>&1 || true
        if python3 -m pip install --user --upgrade pmbootstrap 2>&1 | tail -5; then
            ok "pip 安装完成"
        else
            warn "pip 装不上，改用 git 源码方式"
            mkdir -p "$HOME/.local/bin"
            [ -d "$WORK/pmbootstrap" ] || \
                git clone --depth=1 https://gitlab.postmarketos.org/postmarketOS/pmbootstrap "$WORK/pmbootstrap"
            [ -x "$WORK/pmbootstrap/pmbootstrap.py" ] || chmod +x "$WORK/pmbootstrap/pmbootstrap.py"
            ln -sf "$WORK/pmbootstrap/pmbootstrap.py" "$HOME/.local/bin/pmbootstrap"
        fi
    fi
    hash -r 2>/dev/null || true
    command -v pmbootstrap >/dev/null 2>&1 || die "pmbootstrap 仍不可用，检查 \$HOME/.local/bin 是否在 PATH"
    ok "pmbootstrap $(pmbootstrap --version 2>&1 | head -1)"

    msg "3/6 克隆 pmaports（作者 fork，含 gauguin 设备包）"
    mkdir -p "$WORK"
    if [ ! -d "$APORTS/.git" ]; then
        git clone -b "$APORTS_BRANCH" "$APORTS_REPO" "$APORTS"
    else
        info "已存在，跳过（想强制更新：rm -rf $APORTS 后重跑）"
    fi
    KPKG="$APORTS/$KERNEL_PKG_REL/APKBUILD"
    [ -f "$KPKG" ] || die "找不到 $KPKG —— 设备包路径和假设不符，先 ls $APORTS/device/*/ 看看"
    ok "内核包：$KERNEL_PKG_REL"

    msg "4/6 克隆带设备树的内核分支"
    KDIR="$WORK/linux-sm6350"
    if [ ! -d "$KDIR/.git" ]; then
        # 只要 dts，浅克隆即可，省一半时间
        git clone -b "$KERNEL_BRANCH" --depth=1 "$KERNEL_REPO" "$KDIR"
    else
        info "已存在，跳过"
    fi
    DTS="$KDIR/arch/arm64/boot/dts/qcom/$DTB_NAME.dts"
    [ -f "$DTS" ] || die "内核分支里找不到 $DTB_NAME.dts，先检查网络和分支名"
    ok "找到设备树：$DTS（$(wc -c < "$DTS") 字节）"
    DTSMK="$KDIR/arch/arm64/boot/dts/qcom/Makefile"
    if grep -q "$DTB_NAME.dtb" "$DTSMK"; then
        ok "Makefile 已注册该 dtb"
    else
        warn "Makefile 里没注册，补一行"
        echo "dtb-\$(CONFIG_ARCH_QCOM) += $DTB_NAME.dtb" >> "$DTSMK"
        ok "已补：dtb-\$(CONFIG_ARCH_QCOM) += $DTB_NAME.dtb"
    fi

    msg "5/6 把内核包的源码指向这个分支"
    [ -f "$KPKG.orig" ] || cp "$KPKG" "$KPKG.orig"
    python3 - "$KPKG" "$KERNEL_BRANCH" "$KERNEL_REPO" <<'PY'
import re, sys, pathlib

path, branch, repo = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
s = p.read_text()

m = re.search(r'source="(.*?)"', s, re.S)
if not m:
    sys.exit("APKBUILD 里没有 source=\"...\" 段（abuild 结构变了），把文件发出来再改")

# 保留原来的本地文件条目（$_config、patch 之类），只把远程 URL 换掉
locals_ = [ln.strip() for ln in m.group(1).splitlines()
           if ln.strip() and not re.match(r'^(https?|ftp)://', ln.strip())]
base = repo.rstrip('/').rsplit('/', 1)[-1]          # linux-sm6350
new_url = "%s/archive/refs/heads/$_branch.tar.gz" % repo
body = "\n\t" + new_url + "".join("\n\t" + l for l in locals_) + "\n"
s = s[:m.start()] + 'source="' + body + '"' + s[m.end():]

if '_branch=' not in s:
    line = '_branch="%s"\n' % branch
    mt = re.search(r'^_tag=.*\n', s, re.M)
    s = (s[:mt.end()] + line + s[mt.end():]) if mt else (line + s)

# GitHub 归档解压出来的顶层目录是 <repo>-<branch>
extracted = "%s-$_branch" % base
s, n = re.subn(r'^builddir=.*$', 'builddir="$srcdir/%s"' % extracted, s, count=1, flags=re.M)
if n != 1:
    s = s.rstrip('\n') + '\nbuilddir="$srcdir/%s"\n' % extracted

p.write_text(s)
print("    [ok] APKBUILD rewritten: %s@%s -> top dir %s" % (base, branch, extracted))
PY

    # 自校验：改写没生效就当场停，别等到编完 1 小时才报错
    grep -qF "$KERNEL_REPO/archive/refs/heads/\$_branch.tar.gz" "$KPKG" \
        || die "APKBUILD 的 source 段没改成预期内容，见 $KPKG"
    KBASE="${KERNEL_REPO%/}"
    KBASE="${KBASE##*/}"
    EXPECT_BUILDDIR='builddir="$srcdir/'"$KBASE"'-$_branch"'
    grep -qF "$EXPECT_BUILDDIR" "$KPKG" \
        || die "APKBUILD 的 builddir 没改对（应为 $EXPECT_BUILDDIR，解压目录名会对不上），见 $KPKG"
    if grep -qF '$_config' "$KPKG"; then ok "保留了 \$_config 条目"; fi
    ok "改写结果自检通过"

    msg "5.5/6 改写前后差异（保存下来，出问题先看这里）"
    diff -u "$KPKG.orig" "$KPKG" | sed -n '1,80p' || true

    msg "6/6 让 fastboot 免 sudo（Xiaomi USB 厂商号 $FASTBOOT_VID）"
    printf 'SUBSYSTEM=="usb", ATTR{idVendor}=="%s", MODE="0666", GROUP="plugdev"\n' "$FASTBOOT_VID" \
        | sudo tee /etc/udev/rules.d/51-android-gauguin.rules >/dev/null
    sudo udevadm control --reload-rules 2>/dev/null || true
    sudo udevadm trigger 2>/dev/null || true
    sudo groupadd -f plugdev 2>/dev/null || true
    sudo usermod -aG plugdev "$USER" 2>/dev/null || true
    ok "udev 规则已写入（重新登录后才彻底生效；临时可用 sudo）"

    cat <<EOF

下一步（两步，别跳）：

  bash $0 init       # 交互式初始化，按屏幕答案表回答
  bash $0 install    # 会自动先重算 checksum，再编内核、生成镜像

为什么不在 setup 里算 checksum：pmbootstrap 没 init 之前多半不认
--aports 配置，checksum 会失败。所以放到 init 之后、install 里做。

EOF
    ;;

init)
    msg "pmbootstrap init（交互式）"
    if [ ! -d "$APORTS/.git" ]; then die "还没跑 setup：先 bash $0 setup"; fi
    if ! command -v pmbootstrap >/dev/null 2>&1; then die "pmbootstrap 不可用，先 bash $0 setup"; fi
    cat <<EOF
按下面的答案回答（没列出来的问题，用方括号里的默认值直接回车）：

  渠道 Channel          : edge          ← 内核包取的就是 7.2 分支，选 edge
  厂商 Vendor           : xiaomi
  设备 Device           : $DEVICE
  界面 UI               : console       ← 别选 Phosh/GNOME，省内存也少踩驱动坑
  内核 Kernel           : $KERNEL_PKG  （只有一个就直接回车）
  用户名 / 主机名       : 随便起，例如 user / gauguin
  额外软件包 Extra pkgs : $EXTRA_PKGS_CSV
                          ↑ 必须逗号分隔，空格会被拒绝
                          ↑ 关键：刷完手机没有 Wi-Fi/基带/蓝牙，联网装东西是不可能的，
                            编译器必须现在就烤进镜像。漏了这步，装完只能重新 install。
  时区 / 键盘           : Asia/Shanghai，us
  并行编译任务 --jobs   : CPU 核数（4 核填 4，别超过内存能扛的量）

EOF
    read -r -p "按回车继续（Ctrl+C 放弃）..." _
    pmb init
    ok "init 完成，配置文件在 $HOME/.config/pmbootstrap.cfg"
    cat <<EOF

接着跑：
    bash $0 install

想事后改配置：pmbootstrap --aports="$APORTS" config
想改额外软件包：pmbootstrap --aports="$APORTS" config extra_packages "$EXTRA_PKGS_CSV"

EOF
    ;;

install)
    if ! ls "$HOME"/.config/pmbootstrap* >/dev/null 2>&1; then
        die "还没初始化：先 bash $0 init（否则不知道给哪台设备编）"
    fi
    if [ ! -f "$APORTS/$KERNEL_PKG_REL/APKBUILD" ]; then
        die "找不到内核包 APKBUILD，先 bash $0 setup"
    fi

    msg "1/4 重算校验和（源码已换成分支 tarball，旧 sha512sums 必然不对）"
    pmb checksum "$KERNEL_PKG"

    msg "2/4 编译内核（首次 40-60 分钟；4 核机器更久，日志在 $LOG）"
    pmb build --arch aarch64 "$KERNEL_PKG"
    ok "内核编译完成"

    msg "3/4 生成镜像（打包 rootfs，再等 10-20 分钟）"
    # 额外软件包在 init 时已写进配置（extra_packages），这里不要再传 --add：
    # pmbootstrap 3 的 --add 只认逗号分隔，空格列表会被当成一个包名，
    # 报 "Could not find it in pmaports or any APKINDEX!"。
    if ! grep -q 'openssh' "$HOME/.config/pmbootstrap.cfg" 2>/dev/null; then
        warn "配置里没看到 openssh —— 镜像可能没有 SSH 入口，检查 init 时的 extra_packages"
    fi
    if ! pmb install --split; then
        warn "--split 不被当前 pmbootstrap 支持，改用默认方式重试"
        pmb install
    fi
    ok "镜像生成完成"

    msg "4/4 产物位置"
    ls -lh "$PMB_DATA"/data/*.img 2>/dev/null || true
    ls -1 "$PMB_DATA"/packages/*/*/"$KERNEL_PKG"-*.apk 2>/dev/null | tail -3 || true
    cat <<EOF

先别刷机，跑一遍这个（10 秒，省一次白刷）：
    bash $0 verify

EOF
    ;;

verify)
    [ -d "$PMB_DATA" ] || die "找不到 $PMB_DATA，install 还没跑过"
    DEVINFO=$(ls "$APORTS"/device/*/device-"$DEVICE"/deviceinfo 2>/dev/null | head -1 || true)
    NEEDLE="$DTB_NAME"
    if [ -n "${DEVINFO:-}" ]; then
        d=$(grep -o 'deviceinfo_dtb="[^"]*"' "$DEVINFO" | head -1 | cut -d'"' -f2 || true)
        if [ -n "${d:-}" ]; then NEEDLE="${d##*/}"; info "deviceinfo_dtb = $d"; fi
    else
        warn "没找到 device-$DEVICE/deviceinfo，用默认名字 $NEEDLE 检查"
    fi

    msg "1/2 内核包里有没有 $NEEDLE（.apk 是 gzip 压缩的，必须先解压再搜）"
    hit=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$f" in
            *.apk) n=$(gzip -dc "$f" 2>/dev/null | grep -ac -- "$NEEDLE" || true) ;;
            *)     n=$(grep -ac -- "$NEEDLE" "$f" 2>/dev/null || true) ;;
        esac
        if [ "${n:-0}" -gt 0 ]; then
            ok "$(basename "$f") 含 $NEEDLE"
            hit=$((hit + 1))
        else
            bad "$(basename "$f") 里没有 $NEEDLE —— 内核包没把 dtb 装进去"
        fi
    done < <(find "$PMB_DATA/packages" -name "$KERNEL_PKG-*.apk" 2>/dev/null | sort | tail -3)
    [ "$hit" -gt 0 ] || warn "没找到 ${KERNEL_PKG} 的 apk（pmbootstrap 的产物目录可能不同，不致命）"

    msg "2/2 boot 镜像 / initramfs 里有没有 $NEEDLE（上次失败就在这里）"
    img_seen=0
    img_hit=0
    check_img() {
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            img_seen=$((img_seen + 1))
            if grep -qa -- "$NEEDLE" "$f"; then
                ok "$(basename "$f") 含 $NEEDLE"
                img_hit=$((img_hit + 1))
            else
                info "$(basename "$f") 不含（$(du -h "$f" 2>/dev/null | cut -f1)）"
            fi
        done <<< "${1:-}"
    }

    roots=()
    for d in "$PMB_DATA/data" "$PMB_DATA/images" "$PMB_DATA/chroot_native/home/pmos/rootfs"; do
        if [ -d "$d" ]; then roots+=("$d"); fi
    done
    found=""
    if [ "${#roots[@]}" -gt 0 ]; then
        found=$(find "${roots[@]}" -maxdepth 3 \( -name '*.img' -o -name 'initramfs*' \) 2>/dev/null | head -40 || true)
    fi
    if [ -z "$found" ]; then
        # pmbootstrap 版本不同，产物可能落在别处：整棵树再找一遍
        found=$(find "$PMB_DATA" -maxdepth 6 \( -name '*.img' -o -name 'initramfs*' \) 2>/dev/null | head -20 || true)
    fi
    check_img "$found"

    if [ "$img_seen" -eq 0 ]; then
        warn "没找到任何 .img / initramfs 文件（pmbootstrap 版本不同，产物路径可能变了）"
        info "手动确认一下：find $PMB_DATA -name '*.img' | head"
        if [ "$hit" -gt 0 ]; then
            ok "内核包里已经含 $NEEDLE，通常就可以刷了：bash $0 flash"
            exit 0
        fi
        die "内核包里也没有 $NEEDLE —— 这个组合说明 dtb 没编进去，别刷"
    fi

    if [ "$img_hit" -eq 0 ]; then
        bad "找到 $img_seen 个镜像文件，但没有一个包含 $NEEDLE"
        cat <<EOF

  mkinitfs 的原始报错会在这里复现。按顺序查：
    1. grep -n 'source=' "$APORTS/$KERNEL_PKG_REL/APKBUILD"   # 确认指向 heads/\$_branch
    2. pmbootstrap --aports="$APORTS" checksum $KERNEL_PKG     # 确认 sums 已刷新
    3. 上面第 1 步若已通过，说明 dtb 编译出来了但没装进包 → 把 $LOG 发我
EOF
        exit 1
    fi
    ok "dtb 已进镜像，可以刷：bash $0 flash"
    ;;

postfix)
    # 坑：pmbootstrap install 会给 rootfs 写一条 /boot ext2 挂载项，但我们用 fastboot
    # 刷的是 Android boot 镜像，boot 分区上没有 ext2 → 开机 systemd 挂载失败 → 卡住，
    # 而且此时 USB 网络的 ping 是通的，非常容易误判成"系统起来了"。
    # 这一步把 root 镜像里的那条删掉。用法：bash build.sh postfix [root.img]
    msg "修补 rootfs 的 /boot 挂载项"
    IMG="${2:-}"
    if [ -z "$IMG" ]; then
        for c in "$WORK/images/pmos-root.img" "$WORK/images/csot-root.img" \
                 /tmp/postmarketOS-export/*-root.img; do
            if [ -f "$c" ]; then IMG="$c"; break; fi
        done
    fi
    [ -n "$IMG" ] && [ -f "$IMG" ] || die "找不到 root 镜像，用法：bash $0 postfix /path/to/root.img"
    info "目标镜像：$IMG"

    MNT=/mnt/pmos-postfix
    sudo mkdir -p "$MNT"
    sudo mount -o loop,rw "$IMG" "$MNT" || die "挂载失败（镜像可能已被占用）"
    if grep -qE '^[^#]*[[:space:]]/boot[[:space:]]' "$MNT/etc/fstab"; then
        sudo sed -i '\|^[^#]*[[:space:]]/boot[[:space:]]|d' "$MNT/etc/fstab"
        ok "已删除 /boot 挂载项"
    else
        info "没有 /boot 项，无需修改"
    fi
    info "现在的内容："
    grep -v '^#' "$MNT/etc/fstab" | sed 's/^/    /'

    msg "顺带写入 console 字体服务（28×56，重刷后不用再手配）"
    sudo tee "$MNT/etc/systemd/system/console-font.service" >/dev/null <<'EOFSVC'
[Unit]
Description=Set 28x56 console font
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/setfont /usr/share/consolefonts/ter-u28b.psf.gz
ExecStart=/usr/sbin/setfont -d
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOFSVC
    sudo mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
    sudo ln -sf ../console-font.service \
        "$MNT/etc/systemd/system/multi-user.target.wants/console-font.service"
    if [ -f "$MNT/usr/share/consolefonts/ter-u28b.psf.gz" ]; then
        ok "字体文件存在，服务已启用"
    else
        warn "镜像里没有 ter-u28b 字体（kbd 没装进镜像），服务会静默失败，无副作用"
    fi

    sudo sync
    sudo umount "$MNT" || die "卸载失败，先手动 sudo umount $MNT"
    ok "写回完成：$IMG"
    ;;

flash)
    command -v fastboot >/dev/null 2>&1 || die "没装 fastboot（sudo apt install android-tools-fastboot）"
    devs=$(fastboot devices 2>/dev/null | tr -d '\r' || true)
    if [ -z "$devs" ]; then
        cat <<EOF
没检测到设备。检查清单：
  · 手机关机后按住 音量下 + 电源，出现 FASTBOOT 橙色字再松手
  · 换根线 / 换 USB 口（别走 USB Hub）
  · lsusb 里应该有 2717:xxxx（没有 = 线或口的锅）
  · 权限：sudo fastboot devices 试一次；能出设备就说明是 udev 没生效，重登录一次
EOF
        die "fastboot 没找到设备"
    fi
    ok "已连接：$devs"

    msg "1/2 刷内核（boot 分区）"
    pmb flasher flash_kernel

    msg "2/2 刷根文件系统（userdata 分区，会清空手机数据）"
    pmb flasher flash_rootfs

    cat <<EOF

刷完长按电源开机。第一次开机 1-3 分钟，屏幕应该会亮（面板是 NT36672C 的前提下）。

接不上的时候：
  · 黑屏但有背光  → 面板驱动不匹配（多半是换过屏），改 DTS 或换屏
  · 屏亮但没输出  → 手机插 USB，Ubuntu 上 ip a 找新网卡，主机配 172.16.42.2/24
                    然后 ssh <username>@172.16.42.1

回滚（用官方线刷包里的 boot.img，只回内核）：
    fastboot flash boot boot.img
彻底回滚用 MiFlash 刷官方 tgz 整包。别碰 persist 分区（Wi-Fi 校准数据在里面）。

EOF
    ;;
esac
