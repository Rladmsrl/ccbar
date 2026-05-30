# Floating tab — Settings 入口与段数 cap 可配置化

**Date:** 2026-05-27
**Status:** Draft — awaiting user review
**Scope:** 单 PR / 单 implementation plan。

## Problem

Floating Edge Tab 在 Features 页有一张 `floatingTabCard`
(`ClaudeStats/Views/MainWindow/Settings/Sections/FeaturesSettingsView.swift:87`),
卡片右上的"配置"按钮会调 `onConfigure: { onSelectSection(.menuBar) }`,**跳到
菜单栏图标排序页**——但菜单栏页跟悬浮标签完全无关,这是个直接的 UX bug。

同时,折叠条 `TabGlowOverlay` 当前用的段数上限是写死在
`FloatingStatsPanelView.swift:249` 的 `segmentCap = 5`,跑 7、8 个 session 的
power user 永远只能看到前 4 段独立 + 1 段 overflow,信息密度对不上"运行盘"
定位。

折叠条同时存在**两套状态指示组件**互相打架:`CollapsedSessionBadge`
(`FloatingStatsPanelView.swift:256`) 显示 `●N`(单色 + 总数),而它**下层**
的 `TabGlowOverlay`(`TabGlowOverlay.swift:26`)已经按 session 分段染色 ——
两个组件在抢"传达状态"这件事,且 `●N` 信息更稀。

## Goals

1. 修复"点配置"跳错页:新增专属 `SettingsSection.floatingTab`,
   `floatingTabCard.onConfigure` 跳过去。
2. 把"同时显示段数 cap"提成用户可调(3-10,默认 5),折叠条段数和展开
   SESSIONS 列表行数共用此值。
3. 折叠条布局改为**双区**:沿边主体走分段染色,**末端 20%** 让给 `●N` 独立
   显示,两组信息不再争夺空间。

## Non-Goals

下列功能维度刻意**不**在本次范围内引入配置项:

- `floatingTabEdge` / `floatingTabAnchor` / `floatingTabDisplayID` —— 维持
  "拖拽即调"的体验,不暴露 Settings 控件。
- 无 session 时的折叠态外观 —— 保持 `Claude agents` 文字 + 竖排旋转。
- session 排序策略 —— 维持"位置稳定"(BG→FG,组内按 `startedAt` 升序;见
  `SessionRegistry.swift:274`)。展开列表里 needsInput 不上浮。
- 行密度 / 副信息列 —— 保持 `displayTitle` + `项目·[id]·时间` 现状。
- hover 展开延迟 / 折叠延迟 / 拖拽灵敏度 / 点击钉住。
- session 完成声音、横幅、发光等通知反馈。
- 段脉动动画总开关(继续完全交给系统 Reduce Motion)。

这些维度未来可作为独立 spec 引入,本次留白。

## Design

### 1. 新增 `SettingsSection.floatingTab`

`SettingsSection` 枚举(目前包含 `.menuBar` / `.tracking` / `.approvals` 等)
新增 `case floatingTab`。Settings 侧栏增加一项,标题
"Floating Edge Tab",图标 `rectangle.on.rectangle`(跟 Features 卡片图标
一致)。

`FloatingTabSettingsView.swift` 新建于
`ClaudeStats/Views/MainWindow/Settings/Sections/`,内容:

- **第一行 SettingGroup "General"**:
  - Toggle "Show floating edge tab" —— 绑 `prefs.floatingTabEnabled`,镜像
    Features 卡片的开关。
  - 一行只读副本:`Drag the tab to change edge, position, or screen.`
    (告诉用户为什么这里没有边/位置/屏幕的下拉)
- **第二行 SettingGroup "Density"**:
  - Stepper "Max visible sessions": 范围 3...10,默认 5。
    绑 `prefs.floatingTabSegmentCap`(新增,见 §2)。
    副本:`Extra sessions are grouped into the trailing "N+" segment.`

### 2. Preferences 新增 `floatingTabSegmentCap: Int`

`ClaudeStats/Services/Preferences.swift` 增加:

```swift
var floatingTabSegmentCap: Int {
    didSet {
        let clamped = max(3, min(10, floatingTabSegmentCap))
        if clamped != floatingTabSegmentCap {
            floatingTabSegmentCap = clamped       // re-fires didSet, persists below
            return
        }
        defaults.set(floatingTabSegmentCap, forKey: Keys.floatingTabSegmentCap)
    }
}
```

`init` 时从 UserDefaults 读,缺省 5。
`Keys.floatingTabSegmentCap = "floatingTabSegmentCap"`。

### 3. `segmentCap` 取数从常量改为读 Preferences

`FloatingStatsPanelView.swift:249` 的
`fileprivate static let segmentCap = 5` **删掉**。

所有使用点改为读 `env.preferences.floatingTabSegmentCap`:

- `panelSurface` 里 `TabSegmenter.segments(from: sessions, cap: ...)`
  (`FloatingStatsPanelView.swift:61`)
- `LiveSessionsList.body` 里 `let cap = ...` 处
  (`FloatingStatsPanelView.swift:301`)
- `LiveSessionsList.ambiguousTitles` 里 `let cap = ...` 处
  (`FloatingStatsPanelView.swift:343`)

`LiveSessionsList` 当前是 `private struct`,且没有
`@Environment(AppEnvironment.self)`。改造方式:**在外层
`expandedContent`** 把 cap 算好后作为 `let cap: Int` 参数传给
`LiveSessionsList`,`LiveSessionsList` 不持有 environment 引用 ——
保持视图组件单向依赖。

### 4. 折叠条改为 80/20 双区布局

当前 `collapsedContent` (`FloatingStatsPanelView.swift:71`) 把
`CollapsedSessionBadge` 或文字标题铺满整个折叠条,`TabGlowOverlay` 在
**整个 shape** 上做分段填充。

改造:折叠态把 collapsed 区域沿"沿边方向"切两段:

- **主区(80%)**:`TabGlowOverlay` 在这一区做分段染色。
- **末端区(20%)**:`CollapsedSessionBadge`(`●N`)显示在此处。
  - 竖边(left/right):末端 = 下端 20% 高度
  - 横边(top/bottom):末端 = 末端 20% 宽度
  - 末端区**不参与分段染色**,只画 `●N`。整条折叠条的
    `.regularMaterial` 背景 + `FloatingTabShape` 圆角剪裁
    (`FloatingStatsPanelView.swift:54`)保持不变 —— 末端区与主区共用同一
    层材质,视觉上仍是连续的一根条;分段填充只发生在主区那 80% 里。

实现上:

- `TabGlowOverlay` 改造接受一个 `mainAreaFraction: CGFloat`(默认 1.0,
  保持向后兼容);把 `TabSegmenter.rects(in:count:edge:)` 的 `size` 参数
  替换成"主区 size + offset"。
- `FloatingStatsPanelView.panelSurface` 折叠态时:
  - 传 `mainAreaFraction = 0.8` 给 `TabGlowOverlay`
  - `CollapsedSessionBadge` 用 `alignment` + `padding` 钉到 `edge` 的末端
    20% 区,无 session 时改为铺满显示文字(保持现状的旋转/字体逻辑)。

无 session 时 = `segments.isEmpty`(由 `TabSegmenter.segments(from:cap:)`
决定),依旧走 `TabGlowOverlay` 的 dormant 分支
(`TabGlowOverlay.swift:36`),整个 shape 只画 border,不分段;文字仍铺满
整个 collapsed 区 —— 跟现状一致。

### 5. `floatingTabCard.onConfigure` 跳转修正

`FeaturesSettingsView.swift:95`:
```swift
onConfigure: { onSelectSection(.menuBar) }
```
改为:
```swift
onConfigure: { onSelectSection(.floatingTab) }
```

## Testing

- **PreferencesTests** 新增 `floatingTabSegmentCapDefaultsTo5` /
  `floatingTabSegmentCapPersists` / `floatingTabSegmentCapClampsToRange`
  (跟现有 `floatingTabDefaults` / `floatingTabPersists` 同位置:
  `ClaudeStatsTests/PreferencesTests.swift:8`)
- **手动验证**:
  1. 打开 Features → 点 floatingTabCard "Configure" → 应进入新建的
     Floating Edge Tab 设置页(不是 MenuBar)。
  2. 把 cap 调成 3,跑 5 个 session,确认折叠条只有 3 段(其中 1 段是 `3+`
     overflow),展开列表 5 行(前 2 行独立 + 3 行 overflow,统一 rowLabel
     `3+`)—— 跟 `TabSegmenter` 折叠规则对齐。
  3. 折叠条末端 20% 显示 `●5`,主区 80% 是 3 段染色,两者不重叠。
  4. 把 cap 调成 10,跑 8 个 session,确认 8 段独立 + 末端 `●8`。
  5. 无 session 时折叠条整条显示 "Claude agents" 文字(末端区不再独立)。

## Files touched

| File | Change |
|---|---|
| `Services/Preferences.swift` | 新增 `floatingTabSegmentCap` + Keys |
| `Views/MainWindow/Settings/SettingsSection.swift` (或 enum 所在文件) | 新增 `.floatingTab` case |
| `Views/MainWindow/Settings/Sections/FloatingTabSettingsView.swift` | 新建 |
| `Views/MainWindow/Settings/SettingsView.swift` | 侧栏路由新增 |
| `Views/MainWindow/Settings/Sections/FeaturesSettingsView.swift` | `onConfigure` 改 |
| `Views/FloatingStats/FloatingStatsPanelView.swift` | 删 `segmentCap` 常量,取数改读 prefs;折叠条双区布局 |
| `Views/FloatingStats/TabGlowOverlay.swift` | 接受 `mainAreaFraction` |
| `ClaudeStatsTests/PreferencesTests.swift` | 加三条 test |

## Out of scope (explicitly)

详见 §Non-Goals。简言之 —— 触发/拖拽手感(桶 2/6)、通知反馈(桶 5)、
位置/形态(桶 1)、与 Claude 通信扩展(桶 7)均不在本次。
