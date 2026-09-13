#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 macOS 应用图标（课表.icns）—— 针对 macOS 26 Tahoe 的「squircle 牢笼」规则。

背景（实测结论）：
  macOS 26 会检查图标**边缘像素的 alpha**：
    · 全部 ≥ 253  → 用系统自己的圆角形状裁切，图标铺满，正常；
    · 存在 ≤ 252  → 判定「没按新规范设计」，强制套一层灰白圆角底板并把图标缩小嵌进去，
                    也就是用户看到的「白边 / 灰底」。
  所以：① 源图必须**完全不透明**（每像素 alpha=255）；
        ② 源图必须**满幅**，四角不能留白 —— 否则系统裁切后仍会露出白角。

做法：把原始美术图的圆角之外（原本是白色的四个角）用图内自身颜色向外扩散补满，
      再统一 alpha=255，最后切片打包成 .icns。

用法：python3 AppIcon/make-icon.py
"""
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "source-1024.png")      # 原始美术图（1024×1024）
ICONSET = os.path.join(HERE, "课表.iconset")
ICNS = os.path.join(HERE, "课表.icns")

N = 1024
CORNER_RATIO = 189 / 1024      # 原美术图圆角比例（18.5%）
DIFFUSE_ITERS = 340            # 向外扩散迭代次数：4 邻域扩散是曼哈顿距离，
                               # INSET=96 时四角最深处约需 246 轮，留足余量。
# 原图圆角边缘是**柔化**的（贴着形状边界那十几像素是白色描边/羽化），
# 直接拿形状边界当扩散种子会补出一片白角。所以种子统一向内收这么多像素，
# 用内圈的实色去填，补出来的颜色才能和图形自然衔接。
# 96 是量出来的：原图外圈「玻璃高光白边」宽约 90px，必须整圈盖掉。
INSET = 96
# 外圈加深：原图的底是浅蓝白，远看就是「白边」。把外围一圈按半径渐变地
# 加深 + 提饱和，让底色变成明确的蓝色，四周边界再也不会被看成白色。
DEEPEN_START = 0.52        # 归一化半径（切比雪夫）到这个位置开始加深
DEEPEN_FULL = 0.99         # 到这里加深到最大
DEEPEN_SAT = 1.55          # 饱和度倍数
DEEPEN_VAL = 0.74          # 明度倍数


def shift_zero(arr, dy, dx):
    """平移数组，越界处补 0（不用 np.roll，避免从对边环绕污染颜色）。"""
    out = np.zeros_like(arr)
    ys_src = slice(max(0, -dy), N - max(0, dy))
    ys_dst = slice(max(0, dy), N - max(0, -dy))
    xs_src = slice(max(0, -dx), N - max(0, dx))
    xs_dst = slice(max(0, dx), N - max(0, -dx))
    out[ys_dst, xs_dst] = arr[ys_src, xs_src]
    return out


def main():
    if not os.path.exists(SRC):
        sys.exit(f"找不到源图：{SRC}")

    src = Image.open(SRC).convert("RGB")
    if src.size != (N, N):
        src = src.resize((N, N), Image.LANCZOS)
    original = np.asarray(src).copy()

    # ① 扩散种子 = 向内收 INSET 像素后的圆角矩形（避开边缘那圈白色羽化）
    seed_mask = Image.new("L", (N * 4, N * 4), 0)
    ImageDraw.Draw(seed_mask).rounded_rectangle(
        [INSET * 4, INSET * 4, (N - INSET) * 4 - 1, (N - INSET) * 4 - 1],
        radius=(round(N * CORNER_RATIO) - INSET) * 4, fill=255)
    known = np.asarray(seed_mask.resize((N, N), Image.LANCZOS)) > 128

    # ② 扩散源：先把右上角「通知红点」抹掉——否则它的红色会被扩散带进四角，
    #    补出来的角会染上一道红。用它周围的背景色（大半径模糊）顶替。
    soft = np.asarray(Image.fromarray(original).filter(ImageFilter.GaussianBlur(26))).astype(np.float32)
    dot = (original[:, :, 0] > 185) & (original[:, :, 1] < 125) & (original[:, :, 2] < 125)
    src_clean = np.where(dot[..., None], soft, original.astype(np.float32))

    # ③ 把种子颜色逐层向外扩散，铺满内缩之外的全部区域（四角 + 一圈边缘）
    rgb = src_clean.copy()
    cur = known.copy()
    for _ in range(DIFFUSE_ITERS):
        if cur.all():
            break
        acc = np.zeros_like(rgb)
        cnt = np.zeros((N, N), dtype=np.float32)
        for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            acc += shift_zero(rgb, dy, dx) * shift_zero(cur.astype(np.float32), dy, dx)[..., None]
            cnt += shift_zero(cur.astype(np.float32), dy, dx)
        fresh = (~cur) & (cnt > 0)
        rgb[fresh] = acc[fresh] / cnt[fresh][..., None]
        cur |= fresh

    # ④ 补出来的区域用大半径模糊抹平放射状条纹；种子内保持原图（图形实色部分不动）
    filled = Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8))
    blurred = np.asarray(filled.filter(ImageFilter.GaussianBlur(34)))
    base = np.where(known[..., None], original, blurred).astype(np.float32)

    # ⑤ 外圈按半径渐变加深 + 提饱和 —— 让四周边界成为明确的蓝色，不再像白边
    hsv = np.asarray(Image.fromarray(base.astype(np.uint8)).convert("HSV")).astype(np.float32)
    hsv[..., 1] = np.clip(hsv[..., 1] * DEEPEN_SAT, 0, 255)
    hsv[..., 2] = hsv[..., 2] * DEEPEN_VAL
    deep = np.asarray(Image.fromarray(hsv.astype(np.uint8), "HSV").convert("RGB")).astype(np.float32)

    yy, xx = np.mgrid[0:N, 0:N]
    d = np.maximum(np.abs(xx - (N - 1) / 2), np.abs(yy - (N - 1) / 2)) / ((N - 1) / 2)
    t = np.clip((d - DEEPEN_START) / (DEEPEN_FULL - DEEPEN_START), 0, 1)
    t = (t * t * (3 - 2 * t))[..., None]          # smoothstep，边界不生硬
    out_np = base * (1 - t) + deep * t

    out = Image.fromarray(out_np.astype(np.uint8)).convert("RGBA")
    # ④ 关键：全图不透明（Tahoe 的判定只看边缘 alpha，必须处处 255）
    out.putalpha(Image.new("L", (N, N), 255))

    # ⑤ 切片
    os.makedirs(ICONSET, exist_ok=True)
    sizes = [("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32),
             ("icon_32x32@2x.png", 64), ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
             ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
             ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)]
    for name, px in sizes:
        out.resize((px, px), Image.LANCZOS).save(os.path.join(ICONSET, name))

    # ⑥ 打包 icns
    subprocess.run(["iconutil", "-c", "icns", ICONSET, "-o", ICNS], check=True)

    # ⑦ 自检：每个尺寸的边缘 alpha 必须 255，且四角不能是白色
    print("尺寸             边缘α最小  四角颜色               内容宽度")
    ok = True
    for name, px in sizes:
        a = np.asarray(Image.open(os.path.join(ICONSET, name)).convert("RGBA")).astype(int)
        edge = min(a[0, :, 3].min(), a[-1, :, 3].min(), a[:, 0, 3].min(), a[:, -1, 3].min())
        corner = tuple(a[2, 2][:3])
        alpha = a[:, :, 3]
        nz = alpha > 8
        cs = np.where(nz.any(axis=0))[0]
        width = 100 * (cs.max() - cs.min() + 1) / px if len(cs) else 0
        # 角落「灰/白」= 没补上色：彩度极低且偏亮（小尺寸下采样后偏白属正常，故 ≥64 才算）
        flat_light = (max(corner) - min(corner)) < 14 and sum(corner) / 3 > 170
        white_corner = flat_light and px >= 64
        bad = edge < 253 or white_corner
        ok &= not bad
        tag = ""
        if edge < 253:
            tag = "  ← 边缘透明，Tahoe 会套底板"
        elif white_corner:
            tag = "  ← 角落仍是灰/白（没补上色）"
        print(f"{name:>20}  {edge:>6}   {corner}  {width:5.1f}%{tag}")
    print()
    print("✓ 边缘全不透明且无白角，Tahoe 不会再套底板" if ok else "✗ 仍有不合格项，见上方标记")
    print("已生成：", ICNS)


if __name__ == "__main__":
    main()
