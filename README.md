# Qoder Meter for Windows

Qoder 会话伴生状态条，基于 macOS [qoder-meter](https://github.com/chenleshu/qoder-meter) 移植。使用 Windows PowerShell 5.1、WPF 与系统 DLL，无需 Node/Python 运行时；不修改 Qoder 客户端。

## 安装与打开

开发验证环境：Windows 11、Qoder Desktop 0.4.11。Windows 10 2004+ 需要可用的 winsqlite3/JSON1，尚未单独实机验证。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -NoAutoStart -StartNow
```

安装位置：`%LOCALAPPDATA%\QoderMeter\app`。设置与日志：`%APPDATA%\QoderMeter`。默认推荐不启用自启动；需要时在设置里勾选「随 Qoder 自动启动」。使用根目录「启动 Qoder 状态条.cmd」也可直接运行源码。

## 界面与交互

- **三个 Windows 内部停靠位置**：标题栏中部、会话工具栏中部、输入框下方。旧版默认侧栏卡片迁移到标题栏，避免遮住会话列表；完整统计卡片仍可选。
- 点击齿轮或左键托盘打开设置；右键状态条或托盘打开菜单。设置立即生效并保存。
- 状态条可横向微调；卡片顶部可自由拖动。每个位置独立记忆偏移，「重置当前位置」只重置当前视图。
- 五套皮肤和自动外观、四档字号、逐项指标开关。卡片固定宽度 246 DIP，完整统计与每日 Credits 分层显示，不受字段开关影响。
- 状态条按实际内容自动收窄，空闲时不保留大段留白；窄空间优先保留 TPS、Token、状态和领取提示，次要指标自动精简；悬停查看完整数据。Token 为会话累计输出，数字缩写时可在悬浮提示中查看精确或估算值。空间严重不足时收起为细线，移入展开、移出 1.5 秒收起。
- 自动跟随当前打开会话，也能从最近会话菜单选择并固定。支持立即刷新、显示/隐藏、重置位置。
- Qoder 非前台或最小化时隐藏。关闭 Qoder 时可随之退出；可选启动守护在下一次打开 Qoder 时重新拉起。主动退出仅抑制当前 Qoder 进程生命周期的自动拉起。
- 更新检查仅由手动按钮触发，只将带明确 Windows 资产的 GitHub Release 作为升级；不会把 macOS `.app` 压缩包当 Windows 更新，也不会自动下载执行。

## 每日 Credits

复用本机已有 `%LOCALAPPDATA%\QoderDailyCredits\QoderDailyCredits.ps1` 与「Qoder 每天领取 100 Credits」计划任务。Meter 不保存登录凭证，不调用私有领取 API。领取动作由现有脚本操作 Qoder 界面，可能短暂打开权益中心并通过客户端联网。

周期为 UTC+8 每天 10:00 至次日 09:59。10:05/10:30 留给计划任务；10:35 后仍未领、且会话空闲时，Meter 补领。凌晨属于上一周期，可以补领。尝试上限每周期 3 次、间隔 30 分钟；计数和退避在启动领取进程前落盘，重启不会丢失。

未领取时最多每 30 秒读一次本地状态；一旦确认为 `claimed` 或 `already_claimed`，本进程在本周期不再检查状态文件，也禁用手动领取。领取程序退出码为 0 不等于领取成功，必须有本地成功记录。

注意：现有独立领取脚本没有互斥锁。Meter 会检查相同脚本是否已运行并避免重复启动，但与不协作的外部计划任务同时启动仍存在极短竞态。本次未改动独立脚本和计划任务。

## 数据与口径

| 只读来源 | 用途 |
| --- | --- |
| `%APPDATA%\com.qoder.app.stable\main.sqlite` | 会话、标题、模型、创建时间、轮次与外观设置 |
| Qoder 的 `Local Storage\leveldb` | 当前打开的会话路由 |
| `%USERPROFILE%\.qoder\projects\…\<session>.jsonl` | Credits、请求、工具、输出估算 |
| `%USERPROFILE%\.qoder\logs\sessions\…\segments\*.jsonl` | 本轮及模型请求起止时间 |
| `%LOCALAPPDATA%\QoderDailyCredits\state.json` | 领取结果，由现有领取脚本维护 |

assistant 内容按相邻 12ms 分组，以 `CJK/1.35 + 其他字符/3.8` 估算输出；请求按 request_id 去重，TPS 按匹配输出/模型耗时计算。返回精确输出 token 时使用精确值，否则标 `≈`。工具调用只统计当前会话 JSONL，不以来源范围不可靠的上下文快照兜底。会话内容不上传；只有主动检查更新和已有领取动作需要网络。

## 验证

以下新版回归使用临时目录、模拟时钟或只读数据，不操作真实领取：

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File probe\ui-regression.ps1 -Full
powershell -NoProfile -STA -ExecutionPolicy Bypass -File probe\interaction-regression.ps1
powershell -NoProfile -STA -ExecutionPolicy Bypass -File probe\settings-regression.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File probe\credit-regression.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File probe\data-regression.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File probe\lifecycle-test.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools\parse-check.ps1
```

`credit-e2e.ps1`、`try-layout.ps1` 等旧探针包含旧的进程匹配逻辑，不用于新版验收；不要在有其他 PowerShell 应用运行时使用这些旧探针。使用新版停止入口，它核验实例记录中的 PID、启动时间和完整脚本路径。

## 已知边界

停靠预留区根据 Qoder 0.4.11 默认菜单、侧栏及上下文指示区域适配，并非客户端原生插槽。大幅调整 Qoder 侧栏宽度、界面缩放或未来版本布局后，可能需要切换到标题栏位置或手动微调。很长的会话标题可能占用工具栏中部，优先选择标题栏停靠。几何计算支持所在显示器、负坐标和 DPI；多屏混合缩放仍需要相应硬件实机验收。

自动外观优先读取实测存在的 `applicationIcon.resolvedAppearance`，它是应用图标的外观值，不能保证等于编辑区主题；缺失时回退 Windows 外观，也可手动选择皮肤。

巨大会话首次读取可能短暂停顿；后续增量读取。实时布局约 300ms 更新，数据约 1.8 秒刷新。更新检查不会安装升级包。中国区客户端路径与数据兼容性未全面验证。

## 文件组织

`src/meter.ps1` 组织刷新与命令；`lib-ui` 构建视图；`lib-settings` 设置窗；`lib-config-layout` 配置和纯几何；`lib-data` 数据口径；`lib-credits` 领取策略；`lib-lifecycle`/`watch`/`stop` 维护独立实例；`lib-interop` 封装系统 DLL。

License: MIT（沿用原项目）。
