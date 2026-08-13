# NCM 批量转 MP3

一个 macOS / Windows 桌面小工具，用来批量把网易云音乐 `.ncm` 文件转换为可播放的音频文件，并在需要时通过内置 ffmpeg 转成 MP3。

> 本人真的很想在玩GTAV时听自己喜欢的歌，但由于网易云的雷霆格式，网上的转换器又不太好用，干脆自己做一个来。自己动手，丰衣足食！

## 功能

- macOS 原生 SwiftUI 界面，支持跟随系统的浅色 / 深色外观和手动切换
- Windows 原生 C# / WPF 桌面应用，不包含 Electron 或浏览器内核；Windows 11 使用系统 Mica 云母背景，旧系统自动回退
- macOS / Windows 默认跟随系统深浅色，均可通过右上角太阳 / 月亮按钮在本次运行中手动切换
- 批量添加 `.ncm` 文件
- 文件夹递归扫描
- 拖拽导入
- 输出目录选择
- 用歌曲信息命名
- 同名文件覆盖开关
- 优先输出 MP3 / 保留原始格式
- MP3 自动写入 NCM 内嵌封面、标题、歌手和专辑标签
- 队列状态、进度条、日志
- macOS / Windows 均提供队列前的原生“开始使用教程”
- 启动时自动检测 GitHub Release 新版本，也可手动检查并跳转下载
- macOS 版内置 Apple Silicon ffmpeg 8.1，Windows 版内置 x64 ffmpeg，无需用户另装 ffmpeg
- macOS 15.0+ deployment target，面向 macOS 15-27 做兼容；macOS 26+ 在拖拽区和操作区使用系统玻璃效果，旧系统自动降级为兼容材质

## 下载

Release 会提供 macOS 常见拖拽安装 DMG 和 Windows 安装器：

- `NCM批量转MP3-1.2.1-macOS-arm64.dmg`
- `NCM-Batch-MP3-Setup-1.2.1-x64.exe`

所有构建产物（含 SwiftUI 版 zip）会作为附件挂在 GitHub Release 上，仓库不跟踪二进制产物。

macOS 打开 DMG 后，把 `NCM批量转MP3.app` 拖到 `Applications` 即可。

如果 macOS 提示无法打开，可以右键 App 选择“打开”，或在终端执行：

```bash
xattr -cr NCM批量转MP3.app
```

## 原理

实现参考了 `ncmdump` 一类工具的公开实现思路：

1. 校验 NCM 文件头 `CTENFDAM`
2. 解密 core key 和 meta key
3. 构造 key-box
4. 读取 NCM 内嵌封面并定位后续音频流
5. 对音频流逐字节异或还原
6. 识别真实音频头
7. 如果源音频不是 MP3 且选择优先 MP3，调用内置 ffmpeg 转码
8. 将封面、标题、歌手和专辑写入 MP3 的 ID3 标签

为避免生成打不开的伪 MP3，解密后的音频头如果无法识别，程序会直接报错。

## 项目结构

```text
apps/
├── macos/          # macOS SwiftUI 应用（源码、Info.plist、图标脚本、ffmpeg 资源）
└── windows/        # Windows 原生 WPF 应用（App / Core / Tests 三项目、安装器）
scripts/            # 跨平台构建与测试编排脚本
tests/macos/        # macOS 端测试（合成 NCM roundtrip、ffmpeg 集成、封面写入）
.github/workflows/  # Windows 原生版 CI
dist/               # 构建产物（DMG、安装器、SwiftUI 应用 zip）
```

## 从源码构建

### macOS

需要 macOS、Command Line Tools 或 Xcode。

```bash
./scripts/build_app.sh
./scripts/build_dmg.sh
```

构建产物会输出到：

```text
dist/NCM批量转MP3.app
dist/NCM批量转MP3-SwiftUI.app.zip
dist/NCM批量转MP3-1.2.1-macOS-arm64.dmg
```

构建脚本会优先使用已经存在的 `apps/macos/assets/ffmpeg`。如果不存在，会尝试从 OSXExperts 下载 Apple Silicon ffmpeg 8.1。

### Windows

Windows 版源码在 `apps/windows/`，界面和转换核心均使用 C#，由 WPF 生成原生 x64 桌面程序，再用 NSIS 打包。发布配置为 self-contained，用户无需另装 .NET 或 ffmpeg。

需要 .NET 8 SDK 和 NSIS：

```bash
./scripts/build_windows.sh
```

构建产物会输出到：

```text
dist/windows/NCM-Batch-MP3-Setup-1.2.1-x64.exe
```

构建脚本会运行 C# 合成 NCM 往返测试、发布 `win-x64` WPF 应用，并将 `@ffmpeg-installer/win32-x64` 提供的 `ffmpeg.exe` 打入安装器。

## 测试

```bash
./scripts/test.sh
```

测试包含：

- SwiftUI App 内置 NCM roundtrip 自测
- Windows 原生 C# 核心的合成 NCM roundtrip 自测
- 合成 NCM 解密测试
- 合成 FLAC NCM -> 内置 ffmpeg -> MP3 -> 解码验证

## ffmpeg

发布版 App 内置 Apple Silicon 静态 ffmpeg 8.1：

- 来源：https://osxexperts.net/
- 下载后二进制 SHA256：`9a08d61f9328e8164ba560ee7a79958e357307fcfeea6fe626b7d66cdc287028`
- 签进 App 后 SHA256 会变化，详见 `apps/macos/assets/FFMPEG_NOTICE.txt`

该 ffmpeg 构建启用了 `--enable-gpl`。本项目采用 GPLv3-or-later 发布。

Windows 原生版内置 `@ffmpeg-installer/win32-x64` 提供的 `ffmpeg.exe`，详见 `apps/windows/resources/FFMPEG_WINDOWS_NOTICE.txt`。

## 免责声明

请只转换你拥有合法权利处理的音频文件。本项目只用于个人备份、学习和研究场景，不鼓励也不帮助侵犯版权。
