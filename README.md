<p align="center">
  <img src="docs/assets/claude-stats-icon.png" alt="CCBar app icon" width="128" height="128">
</p>

<h1 align="center">CCBar</h1>

<p align="center">
  <strong>Claude Code,装进你的菜单栏。</strong><br>
  原生 macOS 菜单栏 app:实时会话状态、5h 用量上限、Token / Cost 统计、权限审批气泡。
</p>

<p align="center">
  <a href="https://github.com/Rladmsrl/ccbar/releases/latest"><img src="https://img.shields.io/github/v/release/Rladmsrl/ccbar?label=download&color=2ea44f" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Rladmsrl/ccbar?color=blue" alt="License: AGPL-3.0"></a>
</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#install">Install</a> ·
  <a href="#build-from-source">Build From Source</a> ·
  <a href="#acknowledgements">Acknowledgements</a>
</p>

<p align="center">
  <a href="https://github.com/Rladmsrl/ccbar/releases/latest"><strong>⬇️ 下载最新版</strong></a>
</p>

---

## Features

CCBar 从本地的 `~/.claude/` 读 Claude Code 的会话记录,把它变成你随手一瞥就能看到的信息 —— 一个**只为 Claude Code 重度用户**做的、留得住的桌面工具。

- **菜单栏标签** —— 当前 5h 窗口剩余时间 / 用量百分比,内容、顺序、显隐都能拖着配;可与 Claude Code statusLine 双向桥接
- **实时会话 HUD** —— 谁在跑、停在哪、有没有等待权限审批,胶囊状态徽章一目了然,行内就能 Stop / Respawn / Focus 终端标签页
- **可拖浮窗 (Floating Tab)** —— 把状态钉在屏幕边缘,一条分段色带 = 一排会话;悬停看单会话预览 + 最近事件时间线,点开就是当前会话的操作清单。跨屏不漂回主屏
- **权限审批气泡 (Permission Bubble)** —— Claude Code 等待批准时从浮窗弹出,Allow / Deny / Always 直接同步回 chat,可配全局快捷键、提示音、勿扰
- **Token / Cost 统计** —— 按 (message.id, requestId) 跨 session 去重,避免上游惯有的 cost 翻倍;可切成本口径、是否计入 cache
- **API / 配置切换台 (Switcher)** —— 一键切换 API provider(base URL / key / 模型),管理配置 profile,浏览编辑 AGENTS.md / CLAUDE.md / plans,顺手做 CLI 环境体检
- **Skills 库** —— 本地 + plugin skills 一览,接入 skills.sh
- **Git 仓库活动** —— 本地仓库提交图、语言 / SLOC、代码归属
- **AI 活动时间线** —— 把编辑器活动与 Claude 活动叠在一条时间轴上对比(读本机 Screen Time)
- **Claude 服务状态** —— 盯着 claude.ai / Claude Code 的运行状态,异常时可选系统通知
- **内置自动更新** —— Sparkle 后台静默检查 + 设置里手动检查,EdDSA 签名的 appcast
- **简体中文全量本地化** —— 保留 Skill / Plugin / Subagent 等 Claude 生态术语原文

## Install

从 [Releases](https://github.com/Rladmsrl/ccbar/releases/latest) 下载最新包。第一次打开如果被 Gatekeeper 拦住,右键 ▸ **打开**。

## Privacy & Data

CCBar 是 **local-first**:核心统计来自 `~/.claude/projects/` 的本地会话日志,不上传任何使用数据。

可选权限,用到才申请:
- **Full Disk Access** —— 读取 `~/.claude/` 完整目录(Sonoma+ 上某些路径需要)
- **自动化 / Apple Events** —— 点 Focus 时用 AppleScript 把对应终端标签页切到前台
- **辅助功能 / 输入监听** —— 仅当你开启「全局快捷键」让 Allow / Deny 在任意 app 前台都生效时才需要
- **Network access** —— 三种情况会联网:看 Claude 服务状态(拉官方 status 页)、在 Skills 页同步 skills.sh、检查应用更新(Sparkle appcast)

**API key 存储**:在 Switcher 里切换 provider 时,API key **默认存进 macOS 钥匙串**。只有当你显式选「JSON」存储模式时,key 才会以**明文**写进 `~/.claude/settings.json`(Claude Code 原生读取的位置)和 CCBar 的 `providers.json`(文件权限已锁到仅本人可读)。

CCBar 内置 [Sparkle](https://sparkle-project.org) 自动更新,默认开启后台静默检查,也能在 **设置 ▸ 关于 ▸ Check for Updates…** 手动检查。每次推一个 `v*.*.*` tag,发版工作流就构建并打包,发一个带 DMG/zip 的 GitHub Release,再 EdDSA 签名、把更新后的 `appcast.xml` 推到本仓库 `gh-pages`(GitHub Pages serve 在 `SUFeedURL`),已安装的 app 据此自动更新。

## Build From Source

```bash
git clone https://github.com/Rladmsrl/ccbar.git
cd ccbar
brew install xcodegen
bash scripts/run-debug.sh   # 生成 + Debug 构建 + 启动菜单栏 app
bash scripts/run-tests.sh   # 跑单元测试
```

`ClaudeStats.xcodeproj` 由 [`project.yml`](project.yml) + [XcodeGen](https://github.com/yonaskolb/XcodeGen) 生成,不入库。改动 `project.yml` 后跑 `bash scripts/generate.sh` 重新生成。详细的开发约定见 [`CLAUDE.md`](CLAUDE.md)。

### Requirements

- macOS 14+
- Xcode 26+,Swift 6 strict concurrency mode
- XcodeGen

### Project Layout

```
ClaudeStats/
  App/          @main 入口、AppEnvironment、Info.plist、entitlements
  Models/       Sendable value types
  Providers/    Provider 协议 + Claude Code 实现(目前唯一 provider)
  Services/     扫描器、解析器、SessionRegistry、统计聚合
  ViewModels/   @MainActor @Observable 视图模型
  Views/
    FloatingStats/   可拖浮窗、Permission Bubble、状态色覆盖层
    Sessions/        实时会话列表 / 详情
    Usage/           Token / Cost / 5h 用量上限
    Activity/        AI 活动时间线
    Git/             仓库活动
    MainWindow/      主窗口
    Install/         statusLine bridge 安装向导
  Pricing/         模型价目数据(JSON)
  Localization/    Localizable.xcstrings(中英双语)
  Resources/       App resources
  Utilities/       Logger、formatter、共享 helpers
ClaudeStatsTests/  解析、扫描、设置、集成测试
docs/assets/       README 图
scripts/           generate.sh / run-debug.sh / run-tests.sh
```

## Contributing

欢迎 issue 和 PR。提 PR 前请跑 `bash scripts/run-tests.sh`;涉及 app 行为改动的再跑 `bash scripts/run-debug.sh`。保持 Swift 6 strict concurrency 零警告。

## Acknowledgements

CCBar 站在两个开源项目的肩膀上:[**1pitaph/claude-stats**](https://github.com/1pitaph/claude-stats)（UI 样式、统计视图骨架与整体视觉体系 —— CCBar 是它的下游 fork,继承 AGPL-3.0）与 [**rullerzhou-afk/clawd-on-desk**](https://github.com/rullerzhou-afk/clawd-on-desk)（「agent 状态实时映射到桌面」+「权限审批气泡」的核心思路）。

## License

[GNU Affero General Public License v3.0](LICENSE) —— 继承自上游 `1pitaph/claude-stats`。

任何衍生作品必须保持开源且采用 AGPL-3.0。如果你 fork 了 CCBar 并提供网络服务,你也需要把修改过的源码对你的用户开放。
