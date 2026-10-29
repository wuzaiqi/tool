# Windows 批量图片压缩工具

本项目提供 Windows 图形界面图片压缩工具，支持选择文件夹、自定义循环次数和质量参数、查看每轮体积变化，并将结果写入新的输出文件夹。

## 文件说明

- `image_compressor.py`：主程序源代码。
- `requirements.txt`：Python 依赖。
- `build_windows.bat`：在 Windows 上自动安装依赖并打包为独立 EXE。
- `run_windows.bat`：在 Windows 上以 Python 方式运行。
- `README.md`：使用说明。

## 重要说明

当前交付的是**Windows 可执行文件构建包**，不是已编译的 `.exe`。EXE 应在 Windows 系统上构建，避免在 macOS/Linux 上生成不兼容的二进制文件。本包内的 `build_windows.bat` 会在 Windows 上完成构建。

## 一、构建 EXE

1. 将 ZIP 解压到 Windows 文件夹，例如 `C:\ImageCompressor`。
2. 安装 Python 3.11 或 3.12（安装时勾选 **Add python.exe to PATH**）。
3. 双击 `build_windows.bat`。
4. 等待构建结束。
5. EXE 位于 `dist\WindowsImageCompressor.exe`。

第一次构建需要联网下载 Python 包。生成后，通常可在未安装 Python 的 Windows 电脑上运行；不同 Windows 版本和安全软件策略可能影响启动。

## 二、运行源代码

双击 `run_windows.bat`，或在项目目录打开命令行执行：

```bat
py -m pip install -r requirements.txt
py image_compressor.py
```

## 三、使用方式

1. 启动程序。
2. 点击“选择文件夹…”选择图片目录。
3. 设置循环次数、质量参数、缩放比例和目标压缩比例。
4. 点击“开始压缩”。
5. 在日志中查看每轮压缩前后大小。
6. 结果保存到源目录内新建的 `压缩结果_年月日时分秒` 文件夹。

## 四、参数建议

- 循环次数：建议先用 `1` 或 `2` 测试。
- 质量参数：`82` 是 JPG/WebP 的起始参考值。
- 缩放比例：`100%` 不主动缩小；低于 `100%` 会缩小图像尺寸。
- 目标减少：`60%` 表示最终体积不超过原图的 `40%`，只是统计目标，不保证每张图片都达到。
- 每轮继续处理上一轮输出；质量参数每轮最多下降 4，缩放比例也会逐轮下降。
- 勾选“保留各轮中体积最小的有效结果”时，最终保存所有轮次中最小的候选文件。

## 五、格式与画质说明

- JPEG：有损压缩；降低质量会缩小文件，但会损失细节。
- WebP：按质量参数压缩，通常适合网页图片。
- PNG：质量低于 90 时使用调色板量化，可能改变颜色；透明图像的边缘可能变化。
- TIFF：优先使用 Deflate 无损压缩；实际缩小幅度取决于图像内容。
- GIF：尝试保留动画并优化；多轮处理可能改变调色板。
- BMP：较低质量参数会转换为调色板图，可能出现色带。
- 多帧/多页 WebP、TIFF 等会尽量保守处理；具体格式的元数据保留能力受 Pillow 编码器限制。

## 六、元数据

程序尽可能保留 EXIF、ICC 色彩配置和 DPI，但不同格式支持程度不同，**不能承诺所有私有标签、GPS、缩略图、专有元数据或动画信息都完全一致**。请先用副本测试重要照片。

## 七、常见问题

### 双击 BAT 后窗口一闪而过
右键 `build_windows.bat` 选择“编辑”，检查是否有错误；也可打开 CMD，进入项目目录后运行 `build_windows.bat`，查看完整错误。

### 提示找不到 Python
安装 Python 3.11/3.12，并勾选 `Add python.exe to PATH`，然后重新打开终端。

### EXE 被安全软件拦截
PyInstaller 打包的未签名程序可能触发安全软件误报。请只从自己构建的项目运行，检查安全软件隔离记录，不要关闭系统安全保护来运行来源不明的 EXE。

### 压缩率未达到 60%
60% 不是所有图像都能保证达到的指标。可以降低质量、降低缩放比例或增加轮数，但会进一步损失画质。PNG、已经高度压缩的 JPEG、纹理复杂图片通常很难在不明显损失质量的情况下缩小 60%。

## 八、重新打包

修改 `image_compressor.py` 后，再运行：

```bat
build_windows.bat
```

会重新生成 `dist\WindowsImageCompressor.exe`。
