#!/usr/bin/env python3
"""
从高通 downstream 的 dsi-panel-*.dtsi 生成主线 drm_panel 驱动的代码片段。

用法:
    python3 gen_panel_init.py dsi-panel-j17-42-02-0b-dsc-video.dtsi > out.c

输出三段:
    /* MODE */   drm_display_mode 结构体
    /* ON  */    prepare() 里要发的命令
    /* OFF */    unprepare() 里要发的命令

downstream 命令格式(每个 32bit 行):
    type last vc ack wait len_hi len_lo payload...
      type:  0x05=DCS 短写(无参)  0x15=DCS 短写(1 参)  0x39=DCS 长写
      wait:  这条命令之后要等的毫秒数
      len:   负载长度(大端)
"""
import re
import sys


def extract_block(text, prop):
    m = re.search(re.escape(prop) + r"\s*=\s*\[(.*?)\];", text, re.S)
    return m.group(1) if m else None


def parse_cmds(block):
    block = re.sub(r"/\*.*?\*/", "", block, flags=re.S)
    cmds = []
    for line in block.splitlines():
        vals = []
        for tok in line.split():
            tok = tok.strip().rstrip(";")
            if re.fullmatch(r"[0-9A-Fa-f]{2}", tok):
                vals.append(int(tok, 16))
        if len(vals) >= 7:
            cmds.append(vals)
    return cmds


# MIPI DCS 里"无参数"的命令。厂商 dtsi 习惯在长度里多带一个 0x00 填充，
# 直接转成 write_seq 会变成"带参数的写入"，可能被判为非法命令。
NO_PARAM_DCS = {
    0x01,  # soft reset
    0x10,  # enter sleep mode
    0x11,  # exit sleep mode
    0x12,  # partial mode on
    0x13,  # normal mode on
    0x20,  # display invert off
    0x21,  # display invert on
    0x22,  # all pixels off
    0x28,  # display off
    0x29,  # display on
    0x34,  # tearing effect off
    0x35,  # tearing effect on
    0x38,  # idle mode off
    0x39,  # idle mode on
}


def convert(cmds, dsi_ctx="dsi_ctx"):
    out = []
    for v in cmds:
        dtype = v[0]
        wait = v[4]
        length = (v[5] << 8) | v[6]
        payload = v[7:7 + length]
        if not payload:
            continue
        if dtype == 0x05:
            # DCS 短写，无参数（厂商常多写一个 0x00 填充）
            args = "0x%02x" % payload[0]
        elif dtype == 0x15 and payload[0] in NO_PARAM_DCS:
            args = "0x%02x" % payload[0]
        elif dtype == 0x15:
            args = ", ".join("0x%02x" % b for b in payload[:2])
        elif dtype == 0x39:
            args = ", ".join("0x%02x" % b for b in payload)
        else:
            # 其它类型（0x04 读、0x29 之类）保守处理成 raw 写，便于人工复核
            args = ", ".join("0x%02x" % b for b in payload)
            out.append("\t/* 注意: 未知 data type 0x%02x，请人工确认 */" % dtype)
        out.append("\tmipi_dsi_dcs_write_seq_multi(&%s, %s);" % (dsi_ctx, args))
        if wait:
            out.append("\tmipi_dsi_msleep(&%s, %d);" % (dsi_ctx, wait))
    return out


def mode_struct(text, name):
    def num(prop):
        m = re.search(re.escape(prop) + r"\s*=\s*<(\d+)>", text)
        if not m:
            raise SystemExit("缺少属性: " + prop)
        return int(m.group(1))

    w = num("qcom,mdss-dsi-panel-width")
    h = num("qcom,mdss-dsi-panel-height")
    fps = num("qcom,mdss-dsi-panel-framerate")
    hsync = num("qcom,mdss-dsi-h-pulse-width")
    hbp = num("qcom,mdss-dsi-h-back-porch")
    hfp = num("qcom,mdss-dsi-h-front-porch")
    vsync = num("qcom,mdss-dsi-v-pulse-width")
    vbp = num("qcom,mdss-dsi-v-back-porch")
    vfp = num("qcom,mdss-dsi-v-front-porch")
    clock = (w + hfp + hsync + hbp) * (h + vfp + vsync + vbp) * fps // 1000

    lines = []
    lines.append("/* %dx%d @%dHz, htotal=%d, vtotal=%d */" %
                 (w, h, fps, w + hfp + hsync + hbp, h + vfp + vsync + vbp))
    lines.append("static const struct drm_display_mode %s = {" % name)
    lines.append("\t.clock = %d," % clock)
    lines.append("")
    lines.append("\t.hdisplay = %d," % w)
    lines.append("\t.hsync_start = %d," % (w + hfp))
    lines.append("\t.hsync_end = %d," % (w + hfp + hsync))
    lines.append("\t.htotal = %d," % (w + hfp + hsync + hbp))
    lines.append("")
    lines.append("\t.vdisplay = %d," % h)
    lines.append("\t.vsync_start = %d," % (h + vfp))
    lines.append("\t.vsync_end = %d," % (h + vfp + vsync))
    lines.append("\t.vtotal = %d," % (h + vfp + vsync + vbp))
    lines.append("};")
    return lines, (w, h)


def main():
    if len(sys.argv) < 2:
        raise SystemExit("用法: gen_panel_init.py <dsi-panel-*.dtsi> [结构体名]")
    path = sys.argv[1]
    name = sys.argv[2] if len(sys.argv) > 2 else "nt36672c_csot_mode"
    text = open(path, encoding="utf-8", errors="replace").read()

    mode, (w, h) = mode_struct(text, name)
    on_blk = extract_block(text, "qcom,mdss-dsi-on-command")
    off_blk = extract_block(text, "qcom,mdss-dsi-post-off-command")
    if on_blk is None:
        raise SystemExit("找不到 qcom,mdss-dsi-on-command")

    on_cmds = convert(parse_cmds(on_blk))
    off_cmds = convert(parse_cmds(off_blk)) if off_blk else []

    print("/* ===== 由 gen_panel_init.py 从 %s 生成 ===== */" % path.split("/")[-1])
    print("/* ===== MODE ===== */")
    for ln in mode:
        print(ln)
    print("")
    print("/* ===== ON (%d 条命令) ===== */" % len(on_cmds))
    for ln in on_cmds:
        print(ln)
    print("")
    print("/* ===== OFF (%d 条命令) ===== */" % len(off_cmds))
    for ln in off_cmds:
        print(ln)
    print("")
    print("/* 面板显示区域 %dx%d，宽高 mm 见 dtsi 的 physical dimension */" % (w, h))


if __name__ == "__main__":
    main()
