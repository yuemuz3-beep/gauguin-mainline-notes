#!/usr/bin/env python3
"""
用厂商 dtsi 的时序 + 初始化序列，从现成的 panel-tianma-nt36672c.c 生成 CSOT 版驱动。

思路：不改框架代码（DSC/PPS/reset/probe 全部照抄），只替换
  1) 名字 tianma -> csot
  2) on() 函数体      <- 厂商 qcom,mdss-dsi-on-command
  3) off() 函数体     <- 厂商 qcom,mdss-dsi-post-off-command
  4) drm_display_mode <- 厂商 timing 参数
  5) compatible 字符串

用法:
    python3 gen_csot_driver.py panel-tianma-nt36672c.c dsi-panel-j17-42-02-0b-dsc-video.dtsi out.c
"""
import re
import sys


def extract(text, prop):
    m = re.search(re.escape(prop) + r"\s*=\s*\[(.*?)\];", text, re.S)
    return m.group(1) if m else None


NO_PARAM = {0x01, 0x10, 0x11, 0x12, 0x13, 0x20, 0x21, 0x22,
            0x28, 0x29, 0x34, 0x35, 0x38, 0x39}


def gen_cmds(block, indent="\t", ctx="dsi_ctx"):
    block = re.sub(r"/\*.*?\*/", "", block, flags=re.S)
    out = []
    for line in block.splitlines():
        v = [int(t, 16) for t in line.split()
             if re.fullmatch(r"[0-9A-Fa-f]{2}", t.rstrip(";"))]
        if len(v) < 7:
            continue
        dtype, wait = v[0], v[4]
        length = (v[5] << 8) | v[6]
        payload = v[7:7 + length]
        if not payload:
            continue
        if dtype == 0x05:
            # DCS 短写，无参数
            args = "0x%02x" % payload[0]
        elif dtype == 0x15 and len(payload) == 2 and payload[1] == 0x00 and payload[0] in NO_PARAM:
            # 厂商用 "02 <cmd> 00" 表示无参命令（0x11 退休眠、0x29 开显示等）。
            # 注意：只有第二个字节是 0x00 时才能这么判——否则那是厂商页里的
            # 寄存器写入（比如 FF 23 页下的 "02 11 01" 是寄存器 0x11=0x01）。
            args = "0x%02x" % payload[0]
        elif dtype == 0x15:
            args = ", ".join("0x%02x" % b for b in payload[:2])
        else:
            args = ", ".join("0x%02x" % b for b in payload)
        out.append("%smipi_dsi_dcs_write_seq_multi(&%s, %s);" % (indent, ctx, args))
        if wait:
            out.append("%smipi_dsi_msleep(&%s, %d);" % (indent, ctx, wait))
    return "\n".join(out)


def gen_mode(text, name):
    def n(prop):
        m = re.search(re.escape(prop) + r"\s*=\s*<(\d+)>", text)
        if not m:
            raise SystemExit("dtsi 缺少属性: " + prop)
        return int(m.group(1))

    w, h, fps = n("qcom,mdss-dsi-panel-width"), n("qcom,mdss-dsi-panel-height"), n("qcom,mdss-dsi-panel-framerate")
    hs, hb, hf = n("qcom,mdss-dsi-h-pulse-width"), n("qcom,mdss-dsi-h-back-porch"), n("qcom,mdss-dsi-h-front-porch")
    vs, vb, vf = n("qcom,mdss-dsi-v-pulse-width"), n("qcom,mdss-dsi-v-back-porch"), n("qcom,mdss-dsi-v-front-porch")
    ht, vt = w + hf + hs + hb, h + vf + vs + vb
    return "\n".join([
        "\t.clock = %d," % (ht * vt * fps // 1000),
        "",
        "\t.hdisplay = %d," % w,
        "\t.hsync_start = %d," % (w + hf),
        "\t.hsync_end = %d," % (w + hf + hs),
        "\t.htotal = %d," % ht,
        "",
        "\t.vdisplay = %d," % h,
        "\t.vsync_start = %d," % (h + vf),
        "\t.vsync_end = %d," % (h + vf + vs),
        "\t.vtotal = %d," % vt,
    ])


def main():
    if len(sys.argv) < 4:
        raise SystemExit("用法: gen_csot_driver.py <模板.c> <厂商.dtsi> <输出.c>")
    tpl_path, dtsi_path, out_path = sys.argv[1:4]

    tpl = open(tpl_path, encoding="utf-8").read()
    dtsi = open(dtsi_path, encoding="utf-8", errors="replace").read()

    on_blk = extract(dtsi, "qcom,mdss-dsi-on-command")
    off_blk = extract(dtsi, "qcom,mdss-dsi-post-off-command")
    if not on_blk:
        raise SystemExit("dtsi 里找不到 qcom,mdss-dsi-on-command")

    src = tpl.replace("nt36672c_tianma", "nt36672c_csot")
    src = src.replace("panel-tianma-nt36672c", "panel-csot-nt36672c")
    src = src.replace("panel-nt36672c-tianma", "panel-nt36672c-csot")
    src = src.replace('"tianma,nt36672c"', '"csot,nt36672c"')
    src = src.replace("nt36672c tianma fhd video mode dsi panel",
                      "nt36672c csot (j17-42-02-0b) fhd video mode dsi panel")
    src = src.replace("// Copyright (c) 2025 FIXME",
                      "// Ported to the CSOT variant (j17-42-02-0b) for Xiaomi gauguin")

    pat_on = re.compile(r"(static int nt36672c_csot_on\(struct nt36672c_csot \*ctx\)\n\{\n"
                        r"\tstruct mipi_dsi_multi_context dsi_ctx = \{ \.dsi = ctx->dsi \};\n\n)"
                        r"(.*?)"
                        r"(\n\s*return dsi_ctx\.accum_err;\n\}\n)", re.S)
    if not pat_on.search(src):
        raise SystemExit("没能定位 on() 函数体，模板结构变了")
    src = pat_on.sub(lambda m: m.group(1) + gen_cmds(on_blk) + m.group(3), src, count=1)

    pat_mode = re.compile(r"(static const struct drm_display_mode nt36672c_csot_mode = \{\n)"
                          r"(.*?)"
                          r"(\n\};\n)", re.S)
    if not pat_mode.search(src):
        raise SystemExit("没能定位 mode 结构体")
    src = pat_mode.sub(lambda m: m.group(1) + gen_mode(dtsi, "nt36672c_csot") + m.group(3), src, count=1)

    if off_blk:
        pat_off = re.compile(r"(static int nt36672c_csot_off\(struct nt36672c_csot \*ctx\)\n\{\n"
                             r"\tstruct mipi_dsi_multi_context dsi_ctx = \{ \.dsi = ctx->dsi \};\n\n)"
                             r"(.*?)"
                             r"(\n\s*return dsi_ctx\.accum_err;\n\}\n)", re.S)
        if not pat_off.search(src):
            raise SystemExit("没能定位 off() 函数体")
        src = pat_off.sub(lambda m: m.group(1) + gen_cmds(off_blk) + m.group(3), src, count=1)

    open(out_path, "w", encoding="utf-8").write(src)
    print("已生成:", out_path)
    print("on 命令数:", gen_cmds(on_blk).count("write_seq_multi"))
    if off_blk:
        print("off 命令数:", gen_cmds(off_blk).count("write_seq_multi"))


if __name__ == "__main__":
    main()
