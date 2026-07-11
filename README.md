# NCM 批量转 MP3

一个 macOS / Windows 桌面小工具，用来批量把网易云音乐 `.ncm` 文件转换为可播放的音频文件，并在需要时通过内置 ffmpeg 转成 MP3。

> 本人真的很想在玩GTAV时听自己喜欢的歌，但由于网易云的雷霆格式，网上的转换器又不太好用，干脆自己做一个来。自己动手，丰衣足食！

## 功能

- macOS 原生 SwiftUI 界面
- Windows 版现代白色桌面 UI，提供 NSIS 安装器
- 批量添加 `.ncm` 文件
- 文件夹递归扫描
- 拖拽导入
- 输出目录选择
- 用歌曲信息命名
- 同名文件覆盖开关
- 优先输出 MP3 / 保留原始格式
- 队列状态、进度条、日志
- macOS 版内置 Apple Silicon ffmpeg 8.1，Windows 版内置 x64 ffmpeg，无需用户另装 ffmpeg
- macOS 15.0+ deployment target，面向 macOS 15-27 做兼容；macOS 26+ 在拖拽区和操作区使用系统玻璃效果，旧系统自动降级为兼容材质

## 下载

当前仓库包含已经打包好的 macOS App，新版 Release 也会提供 Windows 安装器：

- `dist/NCM批量转MP3-SwiftUI.app.zip`
- `NCM-Batch-MP3-Setup-1.1.0-x64.exe`

解压后双击 `NCM批量转MP3.app` 即可。

如果 macOS 提示无法打开，可以右键 App 选择“打开”，或在终端执行：

```bash
xattr -cr NCM批量转MP3.app
```

## 原理

实现参考了 `ncmdump` 一类工具的公开实现思路：

1. 校验 NCM 文件头 `CTENFDAM`
2. 解密 core key 和 meta key
3. 构造 key-box
4. 定位封面区后的音频流
5. 对音频流逐字节异或还原
6. 识别真实音频头
7. 如果源音频是 FLAC 且选择优先 MP3，调用内置 ffmpeg 转码

为避免生成打不开的伪 MP3，解密后的音频头如果无法识别，程序会直接报错。

## 从源码构建

### macOS

需要 macOS、Command Line Tools 或 Xcode。

```bash
./scripts/build_app.sh
```

构建产物会输出到：

```text
dist/NCM批量转MP3.app
dist/NCM批量转MP3-SwiftUI.app.zip
```

构建脚本会优先使用已经存在的 `Resources/ffmpeg`。如果不存在，会尝试从 OSXExperts 下载 Apple Silicon ffmpeg 8.1。

### Windows

Windows 版源码在 `windows/`，使用 Electron 和 electron-builder 生成 x64 NSIS 安装器：

```bash
./scripts/build_windows.sh
```

构建产物会输出到：

```text
dist/windows/NCM-Batch-MP3-Setup-1.1.0-x64.exe
```

构建脚本会从 `@ffmpeg-installer/win32-x64` 复制 `ffmpeg.exe` 到安装器资源中。

## 测试

```bash
./scripts/test.sh
```

测试包含：

- SwiftUI App 内置 NCM roundtrip 自测
- 合成 NCM 解密测试
- 合成 FLAC NCM -> 内置 ffmpeg -> MP3 -> 解码验证

## ffmpeg

发布版 App 内置 Apple Silicon 静态 ffmpeg 8.1：

- 来源：https://osxexperts.net/
- 下载后二进制 SHA256：`9a08d61f9328e8164ba560ee7a79958e357307fcfeea6fe626b7d66cdc287028`
- 签进 App 后 SHA256 会变化，详见 `Resources/FFMPEG_NOTICE.txt`

该 ffmpeg 构建启用了 `--enable-gpl`。本项目采用 GPLv3-or-later 发布。

Windows 版内置 `@ffmpeg-installer/win32-x64` 提供的 `ffmpeg.exe`，详见 `windows/resources/FFMPEG_WINDOWS_NOTICE.txt`。

## 免责声明

请只转换你拥有合法权利处理的音频文件。本项目只用于个人备份、学习和研究场景，不鼓励也不帮助侵犯版权。
