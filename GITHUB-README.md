# Xiaomi gauguin (Redmi Note 9 Pro 5G / Mi 10T Lite / Mi 10i) — mainline Linux bring-up notes

Work done in Oct–Nov 2026 on a Chinese retail unit (**2007J17C**, SM7225 "Bitra", CSOT panel).
Everything below was tested on real hardware. Kernel 7.2.0, postmarketOS/Nura edge, systemd, console UI.

If you have the **same phone** and get a black screen after flashing mainline, this repo is for you —
the stock pmaports device package does not support the CSOT panel variant and boot fails in three
separate, non-obvious ways.

> **TL;DR** — mainline works. Screen works. SSH over USB works. Compilers work.
> Touch does **not** work yet (vendor driver is SPI, mainline driver is I2C-only).
> Wi-Fi / BT / audio / camera / modem are not implemented.

## What works (verified)

| Feature | Status |
| --- | --- |
| Boot | ✅ |
| Display | ✅ 1080×2400, full screen, DSC path verified |
| USB networking + SSH | ✅ `ssh user@172.16.42.1` (host: 172.16.42.2/24) |
| Console with readable font | ✅ 28×56 (38×43 chars) |
| g++ / vim / tmux / git | ✅ |
| Internet (via host proxy) | ✅ `http_proxy=http://172.16.42.2:7890` |
| Touch | ❌ see below |
| Wi-Fi / BT / audio / camera / modem | ❌ out of scope here |

## The four fixes

### 1. `fastboot erase dtbo` — required

ABL picks the DTB from the `dtbo` partition (32 MB, 19 Android platform DTBs). The mainline DTB
appended to `boot.img` is ignored, so the kernel receives a vendor 4.19 device tree and resets
right after the logo — which looks exactly like "kernel crashed".

```
fastboot erase dtbo
```

(To restore Android: `fastboot flash dtbo <stock dtbo.img>` from the official fastboot package.)

### 2. Missing kernel cmdline

Newer `boot-deploy` assembles the cmdline from `/usr/lib/kernel-cmdline.d/*.conf` only, so
`deviceinfo_kernel_cmdline` is silently dropped. Without those parameters mainline never comes up
on Qualcomm (clocks/power domains get disabled as "unused").

Fix: ship `/usr/lib/kernel-cmdline.d/50-gauguin.conf` from the device package:

```
arm-smmu.disable_bypass=0
ignore_loglevel
clk_ignore_unused
pd_ignore_unused
regulator_ignore_unused
console=tty0
panic=0
PMOS_NO_OUTPUT_REDIRECT
pmos.nosplash
```

### 3. `/etc/fstab` has a bogus `/boot` entry

`pmbootstrap install` writes `UUID=<boot-fs> /boot ext2 ...`, but with `flash_method=fastboot` the
boot partition holds an Android boot image, not ext2. systemd fails to mount `/boot`, boot stalls
half-way, **SSH never starts — while USB networking (ping 172.16.42.1) already works**, which makes
it very easy to misdiagnose.

Fix: delete that line from the rootfs image before flashing (`build.sh postfix <root.img>` here).

### 4. Kernel package must outrank upstream

`pkgver=7.2.0 pkgrel=0` is the exact same version as the official package → apk may install the
upstream one, which has no `sm7225-xiaomi-gauguin.dtb`, and `mkinitfs` fails with:

```
ERROR: Unable to find qcom/sm7225-xiaomi-gauguin.dtb
```

Fix: `pkgrel=1`. Verify with `zcat <apk> | grep -c sm7225-xiaomi-gauguin` (must be ≥ 1).

## The CSOT panel driver

`panel-csot-nt36672c.c` — a new DRM panel driver for the **CSOT** variant of gauguin
(`j17-42-02-0b`), generated from the vendor dtsi with `tools/gen_csot_driver.py`.

The existing `panel-tianma-nt36672c.c` upstream targets a *different* panel (hfront 73 vs 50,
htotal 1205 vs 1182) and is **not enabled** in `config-postmarketos-qcom-sm6350.aarch64`, so the
stock port can never light up any gauguin screen.

Panel data taken from the vendor dtsi:

- 1080×2400 @120 Hz, htotal 1182 / vtotal 2465 (same timing for both Tianma and CSOT variants)
- DSC 1.1, slice 540×20, 2 slices, 8 bpc / 8 bpp, block prediction — identical to what the
  existing driver already sets, so only mode + init sequence change
- 85 DCS writes for `on()`, 6 for `off()`

Kconfig: `CONFIG_DRM_PANEL_CSOT_NT36672C` — append `=y` to the kernel config, the DPU
(`dpu_6_4_sm6350.h`) already declares DSC blocks and `dsi_host.c` implements the compression path.

## Touch: why it is not done

gauguin's touch is a **Novatek TDDI controller on SPI** (`[NVT-ts-spi]`, firmware
`novatek_nt36672c_j17_fw02.bin` for the CSOT variant). Mainline's `novatek-nvt-ts` supports
`novatek,nt36672a-ts` but is **I2C-only**, so it cannot bind. The vendor driver
(`drivers/input/touchscreen/nt36672c/nt36xxx.c` in the LineageOS tree) is a 4.19 driver and needs
a real port to 7.2. Estimated 1–2 weeks of work; not attempted.

Useful data for whoever picks this up (from the vendor dtsi):

```dts
novatek@0 {
	compatible = "novatek,NVT-ts-spi";
	novatek,reset-gpio = <&tlmm 21 0x00>;
	novatek,irq-gpio   = <&tlmm 22 0x2001>;
	novatek,swrst-n8-addr = <0x03F0FE>;
	novatek,spi-rd-fast-addr = <0x03F310>;
	/* cfg_0: display-maker 0x36 (Tianma) -> fw01
	 * cfg_1: display-maker 0x42 (CSOT)   -> fw02  <-- this device */
};
```

The vendor kernel sources and firmware `.ihex` files are in the LineageOS kernel repo
(`android_kernel_xiaomi_gauguin`, branch `lineage-24.0`).

## Reproducing

See `BUILD.md` (or `VM-RUNBOOK.md` for the long version). Short form:

```bash
# on Ubuntu 22.04, 8 cores / 8 GB / 40 GB
bash build.sh doctor          # preflight: repos exist, tools, disk
bash build.sh setup           # clone pmaports fork + kernel branch, rewrite APKBUILD
bash build.sh init            # pmbootstrap init (edge / xiaomi / gauguin / console / systemd)
bash build.sh install         # checksum + kernel build + rootfs
bash build.sh postfix         # remove the /boot fstab line, add console font service
# convert root image to sparse, then flash from the host:
img2simg <root.img> root.simg
fastboot erase dtbo
fastboot flash boot     boot.img
fastboot flash userdata root.simg
fastboot reboot
```

`build.sh verify` checks that `sm7225-xiaomi-gauguin.dtb` really made it into the kernel package
and the boot image — run it before flashing; it catches the most common failure.

## Files

| File | What |
| --- | --- |
| `build.sh` | doctor / setup / init / install / verify / postfix / flash |
| `panel-csot-nt36672c.c` | new DRM panel driver (CSOT variant) |
| `tools/gen_panel_init.py` | vendor dtsi → DCS command C code |
| `tools/gen_csot_driver.py` | vendor dtsi + existing driver → complete new driver |
| `tools/telnet_run*.py` | diagnostics over `pmos.debug-shell` (telnet :23) |
| `VM-RUNBOOK.md`, `README.md` | step-by-step notes, Chinese |

## Credits

- `UsrBinLuna/linux-sm6350`, `UsrBinLuna/pmaports-gauguin` — the original mainline port this builds on
- DomHeadroom / Matteo Cuneo — original device package and `panel-tianma-nt36672c.c`
- LineageOS `android_kernel_xiaomi_gauguin` — vendor DTS, panel and touch sources

Panel driver: GPL-2.0-only (derived from kernel sources). Scripts and docs: do whatever you want.
