# Qoder Meter

Qoder 会话伴生状态条：实时显示当前会话的 TPS、本轮与总计时长、输出 Token、积分、请求数、工具调用和延迟，并跟随当前打开的会话切换。

macOS 与 Windows 各有一套独立实现，数据源、指标口径和交互设计保持一致，但分别使用各平台原生技术编写，互不依赖外部运行时。

<p align="center">
  <img src="macos/docs/screenshots/title-bar@2x.png" width="760" alt="标题栏状态条">
</p>

## 平台支持

| 平台 | 当前版本 | 技术栈 | 说明 |
| --- | --- | --- | --- |
| macOS 13+ | **1.5.2** | JXA + AppKit，`osacompile` 构建 | [macos/README.md](macos/README.md) |
| Windows 10 2004+ / 11 | **1.4.0-win.2** | PowerShell 5.1 + WPF + 系统 DLL | [windows/README.md](windows/README.md) |

两个平台的版本号独立推进。macOS 主线包含较新的用量统计面板、Token 单位切换等功能；Windows 移植版会逐步跟进。

## 目录结构

```text
.
├── macos/
│   ├── src/main.js              # JXA 主程序：取数、UI、设置、守护
│   ├── build.sh                 # 构建 QoderMeter.app
│   ├── install.sh               # 构建并安装到 ~/Applications
│   ├── uninstall.sh
│   ├── 启动/停止 Qoder 状态条.command
│   └── docs/screenshots/
├── windows/
│   ├── src/meter.ps1            # 入口：刷新循环、命令路由
│   ├── src/lib-data.ps1         # 数据口径：sqlite / JSONL / segment
│   ├── src/lib-ui.ps1           # WPF 视图
│   ├── src/lib-settings.ps1     # 设置窗口
│   ├── src/lib-config-layout.ps1# 配置与停靠几何
│   ├── src/lib-credits.ps1      # 每日 Credits 策略
│   ├── src/lib-lifecycle.ps1    # 实例/自启动/更新检查
│   ├── src/lib-interop.ps1      # user32 / dwmapi / winsqlite3
│   ├── install.ps1, uninstall.ps1
│   ├── probe/                   # 回归探针
│   └── tools/                   # parse-check、BOM 工具
├── .github/workflows/build.yml  # macOS 构建 + Windows 语法检查
└── LICENSE
```

## 快速开始

### macOS

```bash
git clone https://github.com/chenleshu/qoder-meter.git
cd qoder-meter/macos
./install.sh          # 构建并安装到 ~/Applications 后启动
# 或者只构建：./build.sh && open QoderMeter.app
```

### Windows

```powershell
git clone https://github.com/chenleshu/qoder-meter.git
cd qoder-meter\windows
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -NoAutoStart -StartNow
```

安装到 `%LOCALAPPDATA%\QoderMeter\app`，设置与日志在 `%APPDATA%\QoderMeter`。不启用自启动时，用本目录的「启动 Qoder 状态条.cmd」手动打开。

## 开发与调试

### Windows

直接从源码运行（无需安装，改完重启进程即可）：

```powershell
cd windows
powershell -NoProfile -STA -ExecutionPolicy Bypass -File src\meter.ps1
```

可选参数：`-Layout title|toolbar|bottom|sidebar`、`-Pin <session-id>`、`-AlwaysOn`、`-NoTray`。

- 实例是单例的：调试前先 `powershell -File src\stop.ps1` 停掉已安装或先前启动的实例。
- 日志：`%APPDATA%\QoderMeter\meter.log`；设置：`%APPDATA%\QoderMeter\settings.json`。
- 语法自检：`powershell -File tools\parse-check.ps1`。
- UI / 交互 / 数据回归（在 `windows` 目录执行）：

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File probe\ui-regression.ps1 -Full
powershell -NoProfile -STA -ExecutionPolicy Bypass -File probe\interaction-regression.ps1
powershell -NoProfile -STA -ExecutionPolicy Bypass -File probe\settings-regression.ps1
powershell -NoProfile -STA -ExecutionPolicy Bypass -File probe\data-regression.ps1
powershell -NoProfile -STA -ExecutionPolicy Bypass -File probe\lifecycle-test.ps1
```

`data-regression` 会用 Node 做 JSON.stringify 对照，本机没有 node 时相关用例会跳过失败；其余用例不依赖 Node。

脚本必须是 **UTF-8 with BOM**，否则 PowerShell 5.1 会按 ANSI 解析，中文字面量出错。改完脚本后执行 `bash tools/bom.sh` 补齐 BOM。

### macOS

```bash
cd macos
./build.sh
open QoderMeter.app
```

- 日志：`~/Library/Logs/QoderMeter.log`；设置：`~/Library/Application Support/QoderMeter`。
- 用量统计面板依赖系统 `jq`，缺失时状态条仍可用、统计面板为空。
- 构建依赖 macOS 自带的 `osacompile`、`PlistBuddy`、`codesign`，无法在 Windows 上构建。

## 版本与发布

- macOS：tag `vX.Y.Z`，产物 `QoderMeter-X.Y.Z.zip`。
- Windows：tag `vX.Y.Z-win.N`，产物 `QoderMeter-X.Y.Z-win.N-windows-x64.zip`。
- 版本号位置：`macos/build.sh` 的 `CFBundleShortVersionString`；`windows/src/meter.ps1` 的 `QM_VERSION`。
- Windows 版「检查更新」只认带明确 Windows 资产的 Release，不会把 macOS `.app` 包当作更新。

## 数据与隐私

两个平台都只读 Qoder 本地数据（`main.sqlite`、`~/.qoder/projects`、会话 segment 日志），不修改客户端、无遥测、不上传会话内容。联网仅发生在手动检查更新，以及（Windows）配合本机已有的 Credits 领取脚本时。

## 已知限制

- Windows 停靠位置按 Qoder 0.4.11 默认布局调参，改侧栏宽度、界面缩放或客户端升级后可能需要切到标题栏位置或手动微调。
- 混合 DPI 多显示器、非 ASCII 用户目录（Windows sqlite 路径编组）尚未完整验证。
- 两个平台的数据解析都依赖 Qoder 的本地数据结构，客户端升级后可能需要同步调整。

## License

[MIT](LICENSE)
