# Qoder Meter

给 Qoder Desktop 配一条轻量的会话状态条：查看生成速度、会话耗时、输出 Token 和积分消耗，并可按日 / 周 / 月汇总本机用量，不离开当前窗口。

这是第三方独立伴生应用，不是 Qoder 官方插件，也不修改客户端。macOS 使用 JXA + AppKit，Windows 使用 PowerShell + WPF；两个平台分别维护，功能并不完全相同。

[Windows 使用说明](windows/README.md) · [macOS 使用说明](macos/README.md) · [GitHub Releases](https://github.com/chenleshu/qoder-meter/releases)

## 本次源码更新

- **字段分隔线**：Windows 与 macOS 条形布局使用低对比度细竖线，分隔线纳入宽度计算，并与所依附的字段一起显示或隐藏。
- **稳定条形宽度**：macOS 条形两端按启用字段、字号和可用空间预留容量，运行中的数字、标题、TPS、计时和账户文案只更换槽位内文字，不改变外框或相邻列位置；空间或配置变化时才重算。
- **macOS 统计粒度与无右键操作**：用量统计支持「按日 / 按周 / 按月」，并可切换总览 / 明细；面板底部提供刷新、设置、更多操作与关闭，「更多操作」调用菜单栏左键菜单，不依赖状态条右键。粒度、视图与范围随设置保存。
- **Windows 紧凑条形**：字段按当前内容使用自然宽度，不再为数字预留固定列位；默认关闭状态、工具、请求三项，数字变长时条形只扩展到实际需要。
- **Windows 图文菜单**：右键与托盘菜单按快捷会话、外观布局、账户应用分组，使用系统线性图标、停靠位置示意图、主题色块和账户摘要；字段开关分为速度与时间、用量与账户、会话与活动三组。
- **Windows 账户功能内置**：余额读取、权益领取、领取历史不再依赖外部脚本；正常状态下显示 `余 5,730 · 今 +4,096`，无本机领取记录时显示 `今 +0`。有待领权益、领取中或账户异常时仍优先显示相应状态。
- **Windows 设置与领取记录**：设置按账户与权益、显示位置与外观、状态条字段、会话与启动分成卡片，余额、套餐构成、活动包与今日到账集中在顶部；领取记录按天从新到旧分组，显示当天合计、领取时间、到期时间与适用范围，无记录时提供空状态引导。按钮、复选、下拉框和滚动条统一跟随皮肤。
- **跨平台图文用量统计**：Windows 与 macOS 都改为「总览 / 明细」仪表盘，提供积分 / Token / 请求 / 活跃天摘要卡、最多最近 12 期趋势柱、模型占比和今天 / 近 7 天 / 本月 / 全部规则摘要；明细每页 6 期并显示行内条形。Windows 状态条齿轮左侧新增图表入口，设置卡片提供迷你趋势预览；macOS 不依赖右键，统计面板底部直接提供刷新、设置、更多操作和关闭。数据仍只读本机 Qoder 会话日志，不上传、不调用 AI。
- **macOS 每日 100 Credits 自动领取**：状态条菜单与设置新增 Credits 区块，登录走 Qoder 官方设备授权（浏览器确认，PKCE），令牌以 `0600` 存本机。开启后由独立 LaunchAgent 每小时检查一次，Qoder 未启动也能领取；只匹配 `CLAIM_BENEFIT` + `CREDITS` + `amount=100` 的活动。macOS 仍不查询余额、没有领取历史列表，Windows 的余额展示与 400 条账本没有移植。
- **macOS 用量统计不再整表重扫**：扫描改为按日志文件记账（mtime + size，索引存 `stats-files.json`），只有变化的文件才重新解析；单次调用受时间预算约束，剩下的由计时器分片推进。本机 43 个日志 / 88MB 实测：面板打开从阻塞 3.4 秒降到首次 378ms（仅首次安装无索引时）、日志无新增时 10ms 且一次 jq 都不跑，聚合结果与改造前的整表扫描逐日、逐模型一致。
- **说明与截图整理**：按平台列出能力、安装方式和数据口径；Windows 图片（含新增统计窗口）由当前源码的真实 WPF 控件离线渲染，全部使用示例数据。

这批更新位于 `restructure` 分支，源码版本号统一升到 **2.1.0**（macOS `2.1.0` / build 16，Windows `QM_VERSION=2.1.0`），属于源码更新，不等于已经发布新的安装包。下方安装命令显式拉取该分支。

## 界面预览

### Windows：深色与浅色状态条

![Windows 深色状态条：字段细竖线、会话消耗与账户积分](windows/docs/screenshots/title-graphite.png)

![Windows 浅色状态条：同一布局随主题切换](windows/docs/screenshots/title-paper.png)

窄空间下隐藏次要字段，对应的分隔线同步移除：

![Windows 紧凑状态条](windows/docs/screenshots/toolbar-graphite.png)

Windows 右键与托盘使用同一套图文分组菜单，保留原生键盘导航、子菜单与勾选反馈：

![Windows 图文分组菜单](windows/docs/screenshots/menu-graphite.png)

<table>
  <tr>
    <td width="34%" align="center"><img src="windows/docs/screenshots/sidebar-graphite.png" width="220" alt="Windows 完整统计卡片"><br>完整统计卡片</td>
    <td width="66%" align="center"><img src="windows/docs/screenshots/settings-paper.png" width="330" alt="Windows 设置中的账户摘要与分组卡片"><br>设置：分组卡片与账户摘要</td>
  </tr>
</table>

<table>
  <tr>
    <td align="center"><img src="windows/docs/screenshots/claims-paper.png" width="330" alt="Windows 领取记录按天分组"><br>领取记录：按天分组与当天合计</td>
    <td align="center"><img src="windows/docs/screenshots/claims-paper-empty.png" width="330" alt="Windows 领取记录空状态"><br>空状态：说明记录来源与自动领取</td>
  </tr>
</table>

<table>
  <tr>
    <td align="center"><img src="windows/docs/screenshots/stats-graphite.png" width="330" alt="Windows 用量统计总览"><br>总览：摘要卡与趋势图</td>
    <td align="center"><img src="windows/docs/screenshots/stats-summary-paper.png" width="330" alt="Windows 模型占比与自动摘要"><br>模型占比与自动摘要</td>
  </tr>
  <tr>
    <td align="center"><img src="windows/docs/screenshots/stats-detail-paper.png" width="330" alt="Windows 用量统计明细"><br>明细：逐期条形与分页</td>
    <td align="center"><img src="windows/docs/screenshots/settings-paper.png" width="330" alt="Windows 设置中的统计预览图"><br>设置：统计入口旁迷你预览</td>
  </tr>
</table>

以上是 Windows 真实控件的 2× 离线渲染，不包含真实会话或账户信息。macOS 未变化的卡片与旧版统计面板原生截图见[平台说明](macos/README.md#界面预览)；macOS 新版图文仪表盘、趋势柱、自动摘要和无右键面板操作目前只完成离线逻辑与控件树验证，仍需在 Mac 上生成原生截图，不能把 Windows 图片当作 macOS 实测结果。

## 平台与功能

| 能力 | Windows | macOS |
| --- | --- | --- |
| 当前源码内应用版本号 | 2.1.1 | 2.1.1 |
| 系统 | Windows 11 已开发验证；Windows 10 2004+ 待完整验收 | macOS 13+ |
| 实现 | Windows PowerShell 5.1、WPF、系统 DLL | JXA、AppKit、系统构建工具 |
| 会话指标、细竖线、主题、字号 | 支持 | 支持 |
| 条形宽度 | 按内容自然宽度，默认隐藏状态、工具、请求 | 固定容量，不随内容伸缩 |
| 自动跟随 / 固定会话 | 支持 | 支持 |
| 停靠位置 | 标题栏、会话工具栏、输入框下方、完整卡片 | 标题栏、窗口上方、窗口下方、侧栏卡片 |
| 消费统计 | 支持 7 天、近 30 天、本月、近一年；总览含趋势、模型占比与自动摘要，明细按日 / 周 / 月分页 | 支持 7 天、近 30 天、本月、近一年；同样提供总览 / 明细、趋势、模型占比与自动摘要 |
| Token 单位切换 | 当前采用 k / m 等缩写 | 支持 b / m / k 与 亿 / 万 |
| 账户余额与权益领取 | 支持，需联网 | 领取支持，需联网；**不查询余额** |
| 领取记录 | 本机记录，最多 400 条 | 仅当日状态与最近一次结果，无历史列表 |
| 手动检查更新 | 只接受兼容的 Windows 发布资产 | 检查 macOS 发布版本 |

两个版本号独立推进。不要将某个平台的截图、用量面板或账户能力理解为另一个平台也已经具备。

## 快速开始

### Windows

> Windows 版启动后会读取本机 Qoder 登录态并查询账户。源码默认开启自动领取可领权益；可在设置中关闭自动领取，但关闭后仍会查询余额和活动。活动接口返回空列表时，会用 Qoder 本地缓存中的活动响应补齐，并按天去重避免重复领取。请先阅读[账户行为与数据口径](windows/README.md#账户积分与权益)。

```powershell
git clone --branch restructure https://github.com/chenleshu/qoder-meter.git
cd qoder-meter\windows
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -NoAutoStart -StartNow
```

安装目录为 `%LOCALAPPDATA%\QoderMeter\app`。`-NoAutoStart` 表示保留已有自启动配置、不新增启动守护，不会替已开启自启动的用户关闭它。也可使用 `windows/启动 Qoder 状态条.cmd` 直接运行源码。

### macOS

```bash
git clone --branch restructure https://github.com/chenleshu/qoder-meter.git
cd qoder-meter/macos
./install.sh
```

构建并安装到 `~/Applications/QoderMeter.app`。界面与构建只用 macOS 自带工具，不要求 Node；消费统计面板需要可用的 `jq`。Credits 领取需要 `/usr/bin/python3`（macOS 命令行开发者工具），不使用领取功能时不会碰到它。应用采用本地 ad-hoc 签名，未经过 Apple 公证，首次打开可能需要在系统安全设置中确认。

## 日常使用

- **打开设置**：点击齿轮；Windows 也可左键点击托盘图标，macOS 可从菜单栏进入。
- **选择布局**：条形视图适合常驻查看，卡片适合完整摘要。每个布局独立记忆位置，重置只影响当前布局。
- **调整密度**：开关条形视图字段、选择四档字号。完整卡片仍为固定排版，不受条形字段开关和字号影响。
- **查看详细数据**：悬停状态条，Windows 会弹出与界面同风格的主题卡片，分栏显示会话、模型、六格关键指标、余额构成、领取明细与诊断。
- **查看用量统计**：Windows 可点击状态条齿轮左侧的图表入口，也可从托盘或设置打开；macOS 可点击齿轮左侧统计图标、菜单栏入口或设置中的「用量统计」。两端均支持总览 / 明细、范围、粒度和显示模式，选择独立保存。Windows 优先使用 10 分钟内缓存，点「刷新」才会重扫本机日志；macOS 面板底部另有刷新、设置、更多操作和关闭，无需右键。
- **切换会话**：默认自动跟随打开的会话，也可选择并固定；固定后需恢复自动跟随才能继续自动切换。
- **控制启动**：自启动、随 Qoder 退出均可设置。手动退出会抑制当前 Qoder 进程生命周期内的自动拉起。
- **领取每日 Credits**：macOS 在菜单栏或设置右侧按钮点「登录 Qoder」，浏览器确认后当天起自动领取 100 Credits；Windows 复用本机 Qoder 登录态，源码默认开启自动领取，可在设置关闭。两端的领取状态都不影响本地用量统计的口径。

## 指标怎么读

| 指标 | 含义与边界 |
| --- | --- |
| TPS | 本轮匹配到的输出量 / 模型请求耗时，不是瞬时解码速度或网络测速 |
| 本轮 | 当前轮的经过时间 |
| 总计 | 从会话创建到现在的时间，不等于持续工作时长 |
| Token | 会话输出量；模型缺少精确值时按文本、思考及工具参数估算，估算展示带 `≈` |
| 积分 / 消耗 | 本地账单中记录的会话 Credits，不等于账户余额变化 |
| 用量统计 | 只汇总本机日志中带积分的助手请求，按本机日期分桶；精确用量优先，缺失时估算并标 `≈`，结果不等同官方账单 |
| 延迟 | 最近一次模型请求耗时，不是首 Token 延迟 |
| 余额（Windows） | 套餐、加赠与有效活动包剩余合计；专属活动积分不一定适用于所有模型 |
| 今日领取（Windows） | 本机 Meter 记录的当前权益周期领取积分；UTC+8 每天 10:00 换周期，不是跨设备完整账单 |

当前混合精确 / 估算输出的会话仍优先展示已有精确累计部分，不应据此认定覆盖了全会话的全部输出。请勿将估算 Token 当作官方计费依据。

## 数据与隐私

两端只读 Qoder 的数据库、会话 JSONL 和 segment 日志，不修改客户端、不上传会话内容、无遥测。工具自身会保存设置、日志和必要缓存。

- **macOS**：手动检查更新时访问 GitHub；Credits 领取只在用户于 Meter 内完成设备授权登录后，才访问 `openapi.qoder.sh` 的活动列表与领取接口，未登录时不会发出任何请求。设备令牌与刷新令牌以 `0600` 存在本机 `qoder-credits.json`，不保存账号密码、不写进日志；消费统计缓存保存在本机。
- **Windows**：另会向 `openapi.qoder.sh` 查询余额、活动及提交领取。登录令牌从本机安全存储读取，只在内存中使用并用于官方账号接口认证，不保存账号密码。关闭自动领取不等于关闭账户联网功能。本地用量统计只读会话日志，不需要账户令牌，也不发起网络请求。

## 验证与已知限制

- Windows 的语法检查、界面 / 设置 / 交互回归、统计窗口与模拟账户测试及离线截图命令见[Windows 验证说明](windows/README.md#开发与验证)。测试夹具不会触发真实领取，也不会读取真实日志或账户。
- macOS 的原生构建、四组离线回归（布局 / 统计分组 / 统计面板 / Credits 状态机）与截图说明见[macOS 开发与验证](macos/README.md#开发与验证)。Windows 无法验证 AppKit 的原生字体、窗口行为或签名构建。
- 停靠并非 Qoder 原生插槽。客户端布局、缩放或侧栏宽度变化后可能需要微调；多窗口、混合 DPI 多显示器和中国区客户端仍有待完整验收的场景。
- 本地数据格式与账号接口可能随 Qoder 升级变化；macOS 首次建立扫描索引时会在随后几个刷新周期里分片解析日志（期间面板底部显示「正在补扫 N/M 个文件」，数据随进度增长），Windows 统计刷新及同步账户请求仍可能导致短暂卡顿。本地用量统计只覆盖仍保留的日志，窗口打开后需手动刷新；本地 Credits 与估算 Token 不是官方账单。

## 项目结构

```text
macos/      JXA 主程序、Credits 领取脚本、构建安装脚本、探针与 macOS 截图
windows/    PowerShell / WPF 实现、安装卸载、回归与 Windows 截图
.github/    macOS 构建与 Windows 语法检查工作流
```

本项目与 Qoder 官方无关联。[MIT License](LICENSE)。
