# -*- coding: utf-8 -*-
"""
Windows Image Compressor
- GUI based on Tkinter
- User-selectable iteration count and quality
- Saves results to a new folder; source files are never modified
- Attempts to preserve EXIF/ICC metadata where supported
"""
from __future__ import annotations

import io
import os
import sys
import threading
import traceback
from pathlib import Path
from datetime import datetime
import tkinter as tk
from tkinter import ttk, filedialog, messagebox

try:
    from PIL import Image, ImageOps, ImageSequence
except ImportError:
    Image = None
    ImageOps = None
    ImageSequence = None

APP_NAME = "Windows 批量图片压缩工具"
SUPPORTED = {".jpg", ".jpeg", ".png", ".webp", ".tif", ".tiff", ".bmp", ".gif"}
OPTIONAL_HEIC = {".heic", ".heif", ".avif"}


def human_size(n: int) -> str:
    if n >= 1024**3:
        return f"{n / 1024**3:.2f} GB"
    if n >= 1024**2:
        return f"{n / 1024**2:.2f} MB"
    if n >= 1024:
        return f"{n / 1024:.2f} KB"
    return f"{n} B"


def get_metadata_kwargs(im: Image.Image) -> dict:
    """Return common metadata supported by Pillow encoders."""
    kwargs = {}
    try:
        exif = im.getexif()
        if exif:
            kwargs["exif"] = exif.tobytes()
    except Exception:
        pass
    icc = im.info.get("icc_profile")
    if icc:
        kwargs["icc_profile"] = icc
    dpi = im.info.get("dpi")
    if dpi:
        kwargs["dpi"] = dpi
    return kwargs


def save_candidate(src: Path, dst: Path, quality: int, resize_percent: int) -> None:
    suffix = src.suffix.lower()
    with Image.open(src) as original:
        # Keep animation/multi-page images intact rather than silently flattening them.
        is_animated = bool(getattr(original, "is_animated", False)) or getattr(original, "n_frames", 1) > 1
        if is_animated:
            if suffix == ".gif":
                frames = [frame.copy().convert("RGBA") for frame in ImageSequence.Iterator(original)]
                durations = [frame.info.get("duration", original.info.get("duration", 100))
                             for frame in ImageSequence.Iterator(original)]
                loop = original.info.get("loop", 0)
                first = frames[0]
                if resize_percent < 100:
                    new_size = (max(1, int(first.width * resize_percent / 100)),
                                max(1, int(first.height * resize_percent / 100)))
                    frames = [f.resize(new_size, Image.Resampling.LANCZOS) for f in frames]
                frames[0].save(
                    dst, format="GIF", save_all=True, append_images=frames[1:],
                    optimize=True, duration=durations, loop=loop, disposal=2
                )
                return
            # Other animated formats: preserve original bytes as the safest fallback.
            shutil.copy2(src, dst)
            return

        im = ImageOps.exif_transpose(original)
        metadata = get_metadata_kwargs(original)
        if resize_percent < 100:
            new_size = (max(1, int(im.width * resize_percent / 100)),
                        max(1, int(im.height * resize_percent / 100)))
            im = im.resize(new_size, Image.Resampling.LANCZOS)

        if suffix in (".jpg", ".jpeg"):
            if im.mode not in ("RGB", "L"):
                # Composite transparency onto white for JPEG.
                if "A" in im.getbands():
                    rgba = im.convert("RGBA")
                    bg = Image.new("RGB", rgba.size, "white")
                    bg.paste(rgba, mask=rgba.getchannel("A"))
                    im = bg
                else:
                    im = im.convert("RGB")
            im.save(dst, format="JPEG", quality=quality, optimize=True,
                    progressive=True, subsampling="4:2:0", **metadata)
        elif suffix == ".webp":
            im.save(dst, format="WEBP", quality=quality, method=6, **metadata)
        elif suffix == ".png":
            # Try lossless first, then indexed-color PNG if needed by caller quality.
            if im.mode not in ("RGB", "RGBA", "L", "LA", "P", "1"):
                im = im.convert("RGBA" if "A" in im.getbands() else "RGB")
            if quality >= 90:
                im.save(dst, format="PNG", optimize=True, compress_level=9, **metadata)
            else:
                # Quantization may change colors; preserve alpha where possible.
                colors = max(16, min(256, int(16 + (quality - 30) * 240 / 65)))
                quant_method = getattr(Image, "Quantize", None)
                if "A" in im.getbands():
                    rgba = im.convert("RGBA")
                    # Pillow's FASTOCTREE supports alpha; use it for transparent PNG.
                    method = quant_method.FASTOCTREE if quant_method else 2
                    q = rgba.quantize(colors=colors, method=method)
                else:
                    q = im.convert("RGB").quantize(colors=colors)
                q.save(dst, format="PNG", optimize=True, compress_level=9, **metadata)
        elif suffix in (".tif", ".tiff"):
            # Deflate is lossless. Keep original pixel data unless resizing is requested.
            im.save(dst, format="TIFF", compression="tiff_adobe_deflate", **metadata)
        elif suffix == ".bmp":
            # BMP is inherently large; indexed color can reduce size but may alter colors.
            if quality < 90:
                colors = max(16, min(256, int(16 + (quality - 30) * 240 / 65)))
                q = im.convert("RGB").quantize(colors=colors)
                q.save(dst, format="BMP")
            else:
                im.save(dst, format="BMP")
        elif suffix == ".gif":
            im.convert("P", palette=Image.Palette.ADAPTIVE, colors=256).save(
                dst, format="GIF", optimize=True
            )
        else:
            shutil.copy2(src, dst)


class CompressorApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(APP_NAME)
        self.geometry("800x620")
        self.minsize(700, 540)
        self.source_var = tk.StringVar()
        self.iter_var = tk.IntVar(value=2)
        self.quality_var = tk.IntVar(value=82)
        self.resize_var = tk.IntVar(value=100)
        self.target_var = tk.IntVar(value=60)
        self.keep_best_var = tk.BooleanVar(value=True)
        self.status_var = tk.StringVar(value="请选择包含图片的文件夹。")
        self.running = False
        self._build_ui()

    def _build_ui(self):
        pad = {"padx": 12, "pady": 6}
        root = ttk.Frame(self, padding=14)
        root.pack(fill="both", expand=True)

        ttk.Label(root, text="Windows 批量图片压缩工具", font=("Microsoft YaHei UI", 16, "bold")).pack(anchor="w")
        ttk.Label(root, text="原图不会修改；结果保存到新的输出文件夹；文件名和扩展名保持不变。",
                  wraplength=750).pack(anchor="w", pady=(2, 12))

        folder = ttk.LabelFrame(root, text="图片文件夹", padding=10)
        folder.pack(fill="x", **pad)
        entry = ttk.Entry(folder, textvariable=self.source_var)
        entry.pack(side="left", fill="x", expand=True, padx=(0, 8))
        ttk.Button(folder, text="选择文件夹…", command=self.choose_folder).pack(side="right")

        settings = ttk.LabelFrame(root, text="压缩设置", padding=10)
        settings.pack(fill="x", **pad)

        row1 = ttk.Frame(settings)
        row1.pack(fill="x", pady=4)
        ttk.Label(row1, text="循环次数：").pack(side="left")
        ttk.Spinbox(row1, from_=1, to=20, width=6, textvariable=self.iter_var).pack(side="left", padx=(0, 18))
        ttk.Label(row1, text="质量参数：").pack(side="left")
        ttk.Spinbox(row1, from_=30, to=95, width=6, textvariable=self.quality_var).pack(side="left", padx=(0, 18))
        ttk.Label(row1, text="每轮缩放比例：").pack(side="left")
        ttk.Spinbox(row1, from_=30, to=100, increment=5, width=6, textvariable=self.resize_var).pack(side="left")
        ttk.Label(row1, text="%").pack(side="left", padx=(2, 0))

        row2 = ttk.Frame(settings)
        row2.pack(fill="x", pady=4)
        ttk.Label(row2, text="目标体积减少：").pack(side="left")
        ttk.Spinbox(row2, from_=0, to=95, increment=5, width=6, textvariable=self.target_var).pack(side="left")
        ttk.Label(row2, text="%（仅统计，不保证每张都达到）").pack(side="left", padx=(4, 0))

        ttk.Checkbutton(settings, text="保留各轮中体积最小的有效结果", variable=self.keep_best_var).pack(anchor="w", pady=(4, 0))

        help_text = (
            "质量参数参考：90–95 画质优先；80–89 均衡；70–79 体积优先；"
            "50–69 强压缩；30–49 极限压缩。PNG/BMP 的低质量模式会减少颜色数量，"
            "可能改变颜色。循环次数越多，可能累积画质损失。"
        )
        ttk.Label(root, text=help_text, wraplength=750, foreground="#555").pack(anchor="w", padx=12, pady=4)

        actions = ttk.Frame(root)
        actions.pack(fill="x", padx=12, pady=8)
        self.start_btn = ttk.Button(actions, text="开始压缩", command=self.start)
        self.start_btn.pack(side="left")
        ttk.Button(actions, text="打开输出目录", command=self.open_output).pack(side="left", padx=8)
        self.output_path = None

        ttk.Label(root, textvariable=self.status_var).pack(anchor="w", padx=12, pady=(4, 2))
        self.log = tk.Text(root, height=15, wrap="word", state="disabled", font=("Consolas", 9))
        self.log.pack(fill="both", expand=True, padx=12, pady=(4, 8))

    def choose_folder(self):
        path = filedialog.askdirectory(title="选择图片文件夹")
        if path:
            self.source_var.set(path)

    def write_log(self, message):
        self.log.configure(state="normal")
        self.log.insert("end", message + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def start(self):
        if self.running:
            return
        source = Path(self.source_var.get().strip().strip('"'))
        if not source.is_dir():
            messagebox.showerror("路径错误", "请先选择一个有效的图片文件夹。")
            return
        try:
            iterations = int(self.iter_var.get())
            quality = int(self.quality_var.get())
            resize_percent = int(self.resize_var.get())
            target = int(self.target_var.get())
        except Exception:
            messagebox.showerror("参数错误", "请检查循环次数、质量和缩放参数。")
            return
        if not 1 <= iterations <= 20 or not 30 <= quality <= 95 or not 30 <= resize_percent <= 100 or not 0 <= target <= 95:
            messagebox.showerror("参数范围", "循环次数 1–20，质量 30–95，缩放 30–100%，目标 0–95%。")
            return

        self.running = True
        self.start_btn.configure(state="disabled")
        self.log.configure(state="normal")
        self.log.delete("1.0", "end")
        self.log.configure(state="disabled")
        threading.Thread(target=self.process, args=(source, iterations, quality, resize_percent, target), daemon=True).start()

    def process(self, source, iterations, quality, resize_percent, target):
        output = source / f"压缩结果_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
        output.mkdir(parents=True, exist_ok=True)
        self.output_path = output
        files = [p for p in source.iterdir() if p.is_file() and p.suffix.lower() in SUPPORTED]
        total = len(files)
        met = 0
        copied = 0
        failed = 0
        original_total = 0
        output_total = 0
        self.after(0, self.write_log, f"源目录：{source}")
        self.after(0, self.write_log, f"输出目录：{output}")
        self.after(0, self.write_log, f"图片数量：{total}；循环次数：{iterations}；质量：{quality}；缩放：{resize_percent}%")
        self.after(0, self.write_log, "-" * 65)

        for idx, src in enumerate(files, 1):
            dst = output / src.name
            original_size = src.stat().st_size
            original_total += original_size
            target_size = int(original_size * (100 - target) / 100)
            self.after(0, self.write_log, f"[{idx}/{total}] {src.name} ({human_size(original_size)})")
            current_bytes = src.read_bytes()
            best_bytes = current_bytes
            best_size = len(best_bytes)
            suffix = src.suffix.lower()
            success = True

            # Iterate by writing each round to memory/temp file, then feed that result into the next round.
            current_path = output / f".tmp_{idx}{suffix}"
            next_path = output / f".tmp_{idx}_next{suffix}"
            try:
                shutil.copy2(src, current_path)
                for turn in range(1, iterations + 1):
                    round_quality = max(30, quality - (turn - 1) * 4)
                    round_resize = max(30, int(resize_percent * (0.95 ** (turn - 1))))
                    try:
                        save_candidate(current_path, next_path, round_quality, round_resize)
                        if not next_path.exists() or next_path.stat().st_size == 0:
                            raise RuntimeError("生成的文件为空")
                        new_size = next_path.stat().st_size
                        self.after(0, self.write_log,
                                   f"  第 {turn}/{iterations} 轮：{human_size(current_path.stat().st_size)} → {human_size(new_size)}；质量 {round_quality}；缩放 {round_resize}%")
                        if new_size < best_size:
                            best_size = new_size
                            best_bytes = next_path.read_bytes()
                        # Continue from this round's output, as requested.
                        shutil.move(str(next_path), str(current_path))
                    except Exception as exc:
                        success = False
                        self.after(0, self.write_log, f"  本轮失败：{exc}")
                        break

                if success:
                    final_bytes = best_bytes if self.keep_best_var.get() else current_path.read_bytes()
                    dst.write_bytes(final_bytes)
                    shutil.copystat(src, dst, follow_symlinks=True)
                    # Metadata copy is best effort: Pillow preserves EXIF/ICC on most still formats.
                    out_size = dst.stat().st_size
                    output_total += out_size
                    reduction = 100 - (out_size * 100 // max(1, original_size))
                    if out_size <= target_size:
                        met += 1
                        self.after(0, self.write_log, f"  达标：减少 {reduction}%")
                    else:
                        self.after(0, self.write_log, f"  未达目标：减少 {reduction}%")
                    if out_size >= original_size:
                        copied += 1
                else:
                    shutil.copy2(src, dst)
                    out_size = dst.stat().st_size
                    output_total += out_size
                    copied += 1
                    self.after(0, self.write_log, "  压缩失败，已复制原图到输出目录")
            except Exception as exc:
                failed += 1
                self.after(0, self.write_log, f"  失败：{exc}")
            finally:
                for temp in (current_path, next_path):
                    try:
                        temp.unlink(missing_ok=True)
                    except Exception:
                        pass

        reduction_total = 0 if original_total == 0 else 100 - output_total * 100 // original_total
        self.after(0, self.write_log, "-" * 65)
        self.after(0, self.write_log, f"完成：{total} 张；达标 {met} 张；原样/未缩小 {copied} 张；失败 {failed} 张")
        self.after(0, self.write_log, f"原图总大小：{human_size(original_total)}；输出总大小：{human_size(output_total)}；整体减少 {reduction_total}%")
        self.after(0, self.write_log, f"结果目录：{output}")
        self.after(0, self.status_var.set, "处理完成。")
        self.after(0, self.finish)

    def finish(self):
        self.running = False
        self.start_btn.configure(state="normal")
        messagebox.showinfo("压缩完成", f"处理完成。\n输出目录：{self.output_path}")

    def open_output(self):
        if self.output_path and self.output_path.exists():
            os.startfile(str(self.output_path))
        else:
            messagebox.showinfo("提示", "压缩完成后才能打开输出目录。")


def main():
    if Image is None:
        root = tk.Tk()
        root.withdraw()
        messagebox.showerror("缺少依赖", "未找到 Pillow。请重新安装或使用打包后的 EXE。")
        return
    app = CompressorApp()
    app.mainloop()


if __name__ == "__main__":
    main()
