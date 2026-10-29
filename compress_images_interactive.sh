#!/bin/bash
# macOS 批量图片迭代压缩
# - 运行时输入循环次数和质量参数
# - 每轮都使用上一轮输出作为下一轮输入
# - 最终从原图及各轮结果中挑选最小文件，避免末轮反而变大
# - 原图不修改；输出到新文件夹；文件名和扩展名不变
# - 尽可能复制 EXIF、ICC 等元数据

set -u

for cmd in exiftool; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "缺少必要工具：$cmd"
        echo "请安装：arch -arm64 brew install exiftool imagemagick pngquant oxipng gifsicle"
        exit 1
    fi
done

for cmd in magick pngquant oxipng; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "缺少必要工具：$cmd"
        echo "请安装：arch -arm64 brew install imagemagick pngquant oxipng"
        exit 1
    fi
done

if [ "$#" -lt 1 ] || [ ! -d "$1" ]; then
    echo "用法：先输入命令，末尾留一个空格，再把图片文件夹拖进终端后回车。"
    echo '示例：~/Desktop/compress_images_interactive.sh "/Users/你的用户名/Desktop/商品图片"'
    exit 1
fi

SRC=$(cd "$1" 2>/dev/null && pwd -P) || exit 1

cat <<'INFO'

========== 图片质量与体积参考 ==========
JPG / WebP / HEIC / AVIF：
  90-95  画质优先，通常文件较大
  80-89  画质与体积折中，建议先从 82 开始
  70-79  更小，但细节损失风险增加
  50-69  强压缩，可能出现明显失真
  30-49  极限压缩，不建议用于高画质图片

PNG：使用 pngquant 有损调色板压缩，数值越低通常越小、颜色损失风险越高；
     脚本会按你输入的质量值尝试不同下限，并先使用更保守的范围。
     对已经是调色板 PNG 或高度优化的 PNG，继续压缩可能几乎不会变小。
TIFF：优先采用 ZIP 无损压缩，质量参数通常不影响大小。
GIF：若 gifsicle 已安装，会用质量值换算有损优化强度；动画会尽量保留。
BMP：会按质量值减少颜色数量，可能损失颜色细节。

注意：每轮会用上一轮生成的文件继续压缩，但最终保存各轮中体积最小的有效结果。
质量值不是所有格式通用的视觉标准；实际大小取决于图像内容、格式和元数据。
========================================
INFO

read -r -p "请输入循环次数（1-20，建议 1-3 次）: " PASSES
case "$PASSES" in
    ''|*[!0-9]*) echo "错误：循环次数必须是整数。"; exit 1 ;;
esac
if [ "$PASSES" -lt 1 ] || [ "$PASSES" -gt 20 ]; then
    echo "错误：循环次数范围为 1-20。"
    exit 1
fi

read -r -p "请输入质量参数（30-95；建议先试 82）: " QUALITY
case "$QUALITY" in
    ''|*[!0-9]*) echo "错误：质量参数必须是整数。"; exit 1 ;;
esac
if [ "$QUALITY" -lt 30 ] || [ "$QUALITY" -gt 95 ]; then
    echo "错误：质量参数范围为 30-95。"
    exit 1
fi

DST="$SRC/压缩结果_$(date +%Y%m%d_%H%M%S)"
WORK="$DST/.work"
mkdir -p "$WORK" || { echo "无法创建输出目录。"; exit 1; }

TOTAL=0
MET60=0
SMALLER=0
UNCHANGED=0
FAILED=0
ORIGINAL_TOTAL=0
OUTPUT_TOTAL=0

human_size() {
    awk -v n="$1" 'BEGIN {
        if (n >= 1073741824) printf "%.2f GB", n/1073741824
        else if (n >= 1048576) printf "%.2f MB", n/1048576
        else if (n >= 1024) printf "%.2f KB", n/1024
        else printf "%d B", n
    }'
}

copy_metadata() {
    # 失败时不终止压缩；某些格式/标签不支持跨编码完整复制
    exiftool -TagsFromFile "$1" -all:all -icc_profile \
        -overwrite_original "$2" >/dev/null 2>&1
}

copy_fallback() {
    local src="$1" dst="$2"
    cp -p "$src" "$dst"
}

# GIF 有损强度：质量低于 90 时才启用有损优化；质量越低，lossy 数值越高。
if [ "$QUALITY" -lt 90 ]; then
    gif_lossy=$(( (90 - QUALITY) * 2 ))
else
    gif_lossy=0
fi

# BMP 质量映射到颜色数量。
if [ "$QUALITY" -ge 90 ]; then bmp_colors=256
elif [ "$QUALITY" -ge 80 ]; then bmp_colors=192
elif [ "$QUALITY" -ge 70 ]; then bmp_colors=128
elif [ "$QUALITY" -ge 60 ]; then bmp_colors=96
elif [ "$QUALITY" -ge 50 ]; then bmp_colors=64
else bmp_colors=32
fi

png_low1=$((QUALITY - 15)); [ "$png_low1" -lt 0 ] && png_low1=0
png_low2=$((QUALITY - 30)); [ "$png_low2" -lt 0 ] && png_low2=0
printf '\n输入设置：循环 %s 次；通用质量参数 %s\n' "$PASSES" "$QUALITY"
printf 'JPG/WebP/HEIC/AVIF：每轮使用质量 %s（数值越低通常越小、损失越明显）。\n' "$QUALITY"
printf 'PNG：每轮依次尝试 pngquant 质量范围 %s-%s、%s-%s、0-%s；随后做无损优化。\n' \
    "$png_low1" "$QUALITY" "$png_low2" "$QUALITY" "$QUALITY"
if [ "$gif_lossy" -gt 0 ]; then
    printf 'GIF：有损优化强度 %s（越高压缩越强，画面变化风险越高）。\n' "$gif_lossy"
else
    echo 'GIF：仅做无损优化。'
fi
printf 'BMP：颜色数限制为 %s；TIFF：使用 ZIP 无损压缩，质量值不改变 TIFF 画质。\n' "$bmp_colors"
printf '输出目录：%s\n\n' "$DST"

while IFS= read -r -d '' file; do
    name=$(basename "$file")
    ext="${name##*.}"
    e=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
    output="$DST/$name"

    TOTAL=$((TOTAL + 1))
    original_size=$(stat -f '%z' "$file")
    ORIGINAL_TOTAL=$((ORIGINAL_TOTAL + original_size))
    best="$WORK/best_${TOTAL}.${e}"
    current="$file"

    # 初始候选是原图；只有找到更小文件才更新 best。
    cp -p "$file" "$best" || { FAILED=$((FAILED + 1)); echo "[$TOTAL] $name：无法创建工作副本"; continue; }
    best_size=$original_size

    echo "[$TOTAL] $name（原图 $(human_size "$original_size")）"

    # 动画 GIF 交给 gifsicle 尝试优化。
    # PNG 不调用 magick identify，避开某些 macOS/ImageMagick 环境中的 PNG Abort trap。
    # APNG 常见动画控制块为 acTL；检测到后原样复制，避免破坏动画。
    # 其他非 GIF 格式检查多帧/多页，避免误丢动画帧或 TIFF 页面。
    if [ "$e" = "png" ]; then
        if LC_ALL=C grep -a -q 'acTL' "$file" 2>/dev/null; then
            if copy_fallback "$file" "$output"; then
                UNCHANGED=$((UNCHANGED + 1))
                OUTPUT_TOTAL=$((OUTPUT_TOTAL + original_size))
                echo "  检测到可能的 APNG 动画，为避免破坏动画，原样复制。"
            else
                FAILED=$((FAILED + 1)); echo "  失败：无法复制原图。"
            fi
            echo
            continue
        fi
    elif [ "$e" != "gif" ]; then
        frame_count=$(magick identify "$file" 2>/dev/null | wc -l | tr -d '[:space:]')
        case "$frame_count" in ''|*[!0-9]*) frame_count=1 ;; esac
        if [ "$frame_count" -gt 1 ]; then
            if copy_fallback "$file" "$output"; then
                UNCHANGED=$((UNCHANGED + 1))
                OUTPUT_TOTAL=$((OUTPUT_TOTAL + original_size))
                echo "  检测到多帧/多页，为避免丢帧或丢页，原样复制。"
            else
                FAILED=$((FAILED + 1)); echo "  失败：无法复制原图。"
            fi
            echo
            continue
        fi
    fi

    pass=1
    while [ "$pass" -le "$PASSES" ]; do
        candidate="$WORK/candidate_${TOTAL}_pass${pass}.${e}"
        rm -f "$candidate"
        input_size=$(stat -f '%z' "$current")
        generated=0

        case "$e" in
            jpg|jpeg)
                # quality >= 90 时不强制 4:2:0 色度抽样，避免额外损伤颜色细节。
                if [ "$QUALITY" -lt 90 ]; then
                    magick "$current" -quality "$QUALITY" \
                        -sampling-factor 4:2:0 "$candidate" 2>/dev/null && generated=1
                else
                    magick "$current" -quality "$QUALITY" \
                        "$candidate" 2>/dev/null && generated=1
                fi
                ;;

            webp)
                magick "$current" -quality "$QUALITY" \
                    -define webp:method=6 "$candidate" 2>/dev/null && generated=1
                ;;

            heic|heif|avif)
                # 这些格式依赖 ImageMagick 编译时启用的相应编码器。
                magick "$current" -quality "$QUALITY" \
                    "$candidate" 2>/dev/null && generated=1
                ;;

            png)
                # Q 控制期望质量上限；按从保守到宽松的范围尝试。
                low1=$((QUALITY - 15)); [ "$low1" -lt 0 ] && low1=0
                low2=$((QUALITY - 30)); [ "$low2" -lt 0 ] && low2=0
                png_ok=0

                for qr in "${low1}-${QUALITY}" "${low2}-${QUALITY}" "0-${QUALITY}"; do
                    rm -f "$candidate"
                    if pngquant --quality "$qr" --speed 1 --force \
                        --output "$candidate" -- "$current" >/dev/null 2>&1 \
                        && [ -s "$candidate" ]; then
                        png_ok=1
                        break
                    fi
                done

                if [ "$png_ok" -eq 1 ]; then
                    # pngquant 已完成有损量化；再做一次无损文件结构优化。
                    oxipng -o 3 "$candidate" >/dev/null 2>&1 || true
                    generated=1
                else
                    # 有损量化无法生成时，至少尝试无损优化。
                    if cp -p "$current" "$candidate"; then
                        oxipng -o 4 "$candidate" >/dev/null 2>&1 || true
                        [ -s "$candidate" ] && generated=1
                    fi
                fi
                ;;

            tif|tiff)
                # ZIP 是无损压缩；避免把 TIFF 强制改为有损 JPEG TIFF。
                magick "$current" -compress Zip "$candidate" 2>/dev/null && generated=1
                ;;

            gif)
                if command -v gifsicle >/dev/null 2>&1; then
                    if [ "$gif_lossy" -gt 0 ]; then
                        gifsicle -O3 --lossy="$gif_lossy" \
                            --output "$candidate" "$current" >/dev/null 2>&1 && generated=1
                    else
                        gifsicle -O3 --output "$candidate" \
                            "$current" >/dev/null 2>&1 && generated=1
                    fi
                fi
                ;;

            bmp)
                magick "$current" -colors "$bmp_colors" -type Palette \
                    "$candidate" 2>/dev/null && generated=1
                ;;

            *)
                ;;
        esac

        # 编码失败时沿用本轮输入，不让单张图片中断批处理。
        if [ "$generated" -ne 1 ] || [ ! -s "$candidate" ]; then
            rm -f "$candidate"
            if ! cp -p "$current" "$candidate"; then
                echo "  第 $pass/$PASSES 轮失败，停止此图片。"
                FAILED=$((FAILED + 1))
                break
            fi
            echo "  第 $pass/$PASSES 轮无法重新编码，沿用输入文件。"
        fi

        # 每轮尽量恢复原图元数据；文件大小统计在添加元数据之后进行。
        if ! copy_metadata "$file" "$candidate"; then
            echo "  提醒：此格式的部分元数据可能无法完整复制。"
        fi

        candidate_size=$(stat -f '%z' "$candidate")
        if [ "$input_size" -gt 0 ]; then
            round_saved=$((100 - candidate_size * 100 / input_size))
            cumulative_saved=$((100 - candidate_size * 100 / original_size))
        else
            round_saved=0
            cumulative_saved=0
        fi
        echo "  第 $pass/$PASSES 轮（质量 $QUALITY）：$(human_size "$input_size") -> $(human_size "$candidate_size")；本轮减少 ${round_saved}%，相对原图减少 ${cumulative_saved}%"

        # 记录所有轮次里最小的候选，避免末轮变大后丢掉较小的中间结果。
        if [ "$candidate_size" -lt "$best_size" ]; then
            cp -p "$candidate" "$best"
            best_size=$candidate_size
        fi

        # 下一轮明确使用上一轮输出。
        current="$candidate"
        pass=$((pass + 1))
    done

    if [ ! -s "$best" ]; then
        if copy_fallback "$file" "$output"; then
            UNCHANGED=$((UNCHANGED + 1))
            OUTPUT_TOTAL=$((OUTPUT_TOTAL + original_size))
            echo "  压缩失败，已保留原图副本。"
        else
            FAILED=$((FAILED + 1)); echo "  失败：无法保存输出文件。"
        fi
        echo
        continue
    fi

    if [ "$best_size" -ge "$original_size" ]; then
        if copy_fallback "$file" "$output"; then
            UNCHANGED=$((UNCHANGED + 1))
            OUTPUT_TOTAL=$((OUTPUT_TOTAL + original_size))
            echo "  所有轮次都未能缩小文件，保留原图副本。"
        else
            FAILED=$((FAILED + 1)); echo "  失败：无法保存原图副本。"
        fi
    else
        if cp -p "$best" "$output"; then
            OUTPUT_TOTAL=$((OUTPUT_TOTAL + best_size))
            saved=$((100 - best_size * 100 / original_size))
            SMALLER=$((SMALLER + 1))
            if [ "$best_size" -le $((original_size * 40 / 100)) ]; then
                MET60=$((MET60 + 1))
                echo "  最终采用最小结果：$(human_size "$best_size")，体积减少 ${saved}%（达到减少 60% 的目标）。"
            else
                echo "  最终采用最小结果：$(human_size "$best_size")，体积减少 ${saved}%（未达到减少 60% 的目标）。"
            fi
        else
            FAILED=$((FAILED + 1)); echo "  失败：无法保存结果。"
        fi
    fi
    echo
done < <(
    find "$SRC" -maxdepth 1 -type f \
      \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
         -o -iname '*.webp' -o -iname '*.tif' -o -iname '*.tiff' \
         -o -iname '*.gif' -o -iname '*.bmp' -o -iname '*.heic' \
         -o -iname '*.heif' -o -iname '*.avif' \) -print0
)

rm -rf "$WORK"

printf '\n================ 压缩总结 ================\n'
printf '设置：循环 %s 次，质量参数 %s\n' "$PASSES" "$QUALITY"
printf '图片总数：%s\n' "$TOTAL"
printf '成功缩小：%s\n' "$SMALLER"
printf '减少 60%% 以上：%s\n' "$MET60"
printf '未能缩小/原样保留：%s\n' "$UNCHANGED"
printf '处理失败：%s\n' "$FAILED"
printf '原图总大小：%s\n' "$(human_size "$ORIGINAL_TOTAL")"
printf '输出总大小：%s\n' "$(human_size "$OUTPUT_TOTAL")"
printf '结果目录：%s\n' "$DST"
printf '==========================================\n'
echo "说明：质量参数越低通常压缩越强，但不保证所有图片都能减少 60%；原图从未被修改。"
