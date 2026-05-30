# Floating tab — 按 visibleSessions 分段染色 (TabGlowOverlay)

**Date:** 2026-05-26
**Status:** Draft — awaiting user review
**Scope:** Single PR / single implementation plan.

## Problem

`TabGlowOverlay` 当前把 floating tab 整块用一种颜色渐变染上,颜色来自
`SessionRegistry.visibleSessions.dominantDisplayState` — 也就是 "最近活跃
session 的 displayState"。问题:

- 多个 background session 并发时,tab 只能反映其中**一个**的状态;另外
  几个 session 的 displayState 被聚合丢失
- needsInput 红色急闪覆盖整个 tab,看不出**是哪一个** session 在等批准
- memory 中 `project_floating-tab-roadmap` 早已写明 "tab 按 visibleSessions
  拆段(每段独立显色),数据层已 per-session 派生 displayState" 是 "形态即
  状态" feat 的待跟进 enhancement

数据层(`LiveSession.displayState` 是 per-session computed var)已经就绪,
缺的是 view 层把每个 session 单独画出来的渲染逻辑。

## Goal

`TabGlowOverlay` 由"整 tab 单色"改成"按 visibleSessions 顺序均分成最多 N 段,
每段独立渲染该 session 的 displayState";段间画一条轻量分割线让分段可读。
tab 几何形态、点击/拖拽/hover 注册器都不变 — 只是 fill 内部分段。

成功标准:

- 多 session 时 tab 能同时反映**所有**段的状态(不再被 dominantDisplayState
  单点决定)
- needsInput 段红色脉冲集中在该段;其他段降饱和让出焦点,不再覆盖整个 tab
- N=1 退化:1 段就是整 tab,不画分割线,行为等同今天
- N=0 退化:dormant,不画 fill 也不画分割线
- 段数 cap 是注入参数(本 spec 走常量 5),未来 Preferences 接入只改 1 行

## Non-goals

明确不做(YAGNI 边界,以免后续扩展):

- ❌ Settings UI / Preferences 字段(`tabSegmentCap` / `tabLength`):只留
  API 注入接口,不实现 Picker
- ❌ 拖动改 tab 尺寸交互
- ❌ 段独立的 hover 反馈、独立 click、独立 context menu(整 tab 仍是单一
  交互单元;`LiveSessionsList` 展开后已经给了每个 session 独立 row)
- ❌ 段顺序的用户重排(数据驱动 sort 顺序稳定:needsInput first, then
  `updatedAt` desc)
- ❌ a11y 段独立 element(段是 decorative;展开后 `LiveSessionsList` 才是
  a11y 主体,collapsed 状态的 a11y label 在外层 `CollapsedSessionBadge`
  已覆盖)
- ❌ 段间过渡渐变(硬边界 + 0.5pt 分割线已拍板,不做色彩 blend)
- ❌ needsInput 段联动其他段闪烁(只该段 pulse,其他段静态降饱和)

## Design

### 涉及文件

全部 6 处,无新增 source 文件夹:

| 文件 | 改动 |
|---|---|
| `ClaudeStats/Views/FloatingStats/TabGlowOverlay.swift` | 改 API(`displayState/needsInput` → `segments: [TabSegment]`),内部多段渲染 |
| `ClaudeStats/Views/FloatingStats/FloatingStatsPanelView.swift` | callsite 改传 `segments`,新增 `segmentCap` 常量 |
| `ClaudeStats/Views/FloatingStats/TabSegment.swift` (新建) | `TabSegment` value type + `TabSegmenter` pure helper(段聚合 + 几何切分) |
| `ClaudeStatsTests/TabSegmenterTests.swift` (新建) | `TabSegmenter.segments / .rects` 单测 |

### 输入 / 数据流

```
SessionRegistry.visibleSessions (@Observable, 已 sorted)
        │
        ▼  cap = 5 (常量;未来从 env.preferences.tabSegmentCap 注入)
FloatingStatsPanelView.panelSurface
        │
        │  TabSegmenter.segments(from: sessions, cap: cap)
        ▼
TabGlowOverlay(segments: [TabSegment], shape:, edge:, isExpanded:)
        │
        │  GeometryReader → TabSegmenter.rects(in:count:edge:) → ForEach
        ▼
N 段 mask-clipped gradient + N-1 条分割线
```

### `TabSegment` 与 `TabSegmenter`

```swift
struct TabSegment: Sendable, Equatable {
    let id: String                          // session.id, 溢出段为 "overflow"
    let displayState: LiveSession.DisplayState
    let needsInput: Bool
    let isOverflow: Bool                    // 仅最后一段在溢出时 true
    let overflowCount: Int                  // 0 == 无溢出
}

enum TabSegmenter {
    /// 把 visibleSessions 折成最多 `cap` 段。N <= cap 时一段对应一个
    /// session。N > cap 时前 cap-1 段对应前 cap-1 个 session,最后一段是
    /// 溢出聚合段(displayState 取溢出区 max(updatedAt) 的 session;
    /// needsInput 取溢出区任一 true)。
    static func segments(
        from sessions: [LiveSession],
        cap: Int
    ) -> [TabSegment]

    /// 给 tab 总 size 和段数, 按 edge 方向均分,返回 N 个 sub-rect。
    /// 垂直 edge (.left/.right) 切高;水平 edge (.top/.bottom) 切宽。
    static func rects(
        in size: CGSize,
        count: Int,
        edge: FloatingPanelEdge
    ) -> [CGRect]
}
```

**Why 前 cap-1 + 最后一段聚合:** N=cap+1 时若选 "前 cap 段独占 + 第 cap+1
段聚合" 会超过 cap 上限。选 "前 cap-1 + 最后一段聚合" 保证段数总数 <= cap。

**例子:** cap=5

- N=3 → 3 段对应 3 session,无溢出
- N=5 → 5 段对应 5 session,无溢出
- N=8 → 前 4 段对应前 4 session;第 5 段聚合后 4 个 session,
  `overflowCount=4`、`isOverflow=true`

### `TabGlowOverlay` 新 API

```swift
struct TabGlowOverlay<S: Shape>: View {
    let shape: S
    let segments: [TabSegment]
    let isExpanded: Bool
    let edge: FloatingPanelEdge
}
```

去掉 `displayState`、`needsInput` 入参 — 这俩信息现在编码在 `segments` 里面。

### 渲染规则

1. **isExpanded == true** → 整 tab 走 `.dormant`,无 fill 无分割线
   (跟当前折叠动效一致)
2. **segments.isEmpty** → 同上,dormant
3. **segments.count == 1** → 1 段占满 tab,不画分割线;视觉等同今天的"
   显示 dominantDisplayState" 行为
4. **segments.count >= 2** → 每段 spec 选择:
   ```swift
   let hasAnyNeedsInput = segments.contains(where: \.needsInput)
   for (segment, rect) in zip(segments, rects) {
       let spec: TabFillSpec
       if segment.needsInput {
           spec = .needsInputSpec(reduceMotion: reduceMotion)
       } else if hasAnyNeedsInput {
           spec = TabFillSpec.spec(for: segment.displayState).desaturated()
       } else {
           spec = TabFillSpec.spec(for: segment.displayState)
       }
       // 渲 spec 到 rect (mask 出 sub-shape 后填渐变)
   }
   // 画 N-1 条分割线
   ```
5. **needsInput 段 pulse:** 只该段 pulse;其他段 `pulses = false`。
   `TimelineView` 仍在 TabGlowOverlay 顶层(整 view 一个时钟),per-segment
   只读 `pulsePhase`,**不开多时钟**
6. **降饱和:** `TabFillSpec.desaturated(by: 0.5)` 把 `saturatedAlpha` /
   `fadedAlpha` 乘 0.5,`borderColor.opacity *= 0.5`,`pulses = false`。原
   spec 不变

### `TabFillSpec.desaturated(by:)` 新加

```swift
extension TabFillSpec {
    /// 把 saturated/faded alpha 与 border opacity 按 factor 降一档,让
    /// needsInput 段成为视觉焦点。原 spec 不变。
    func desaturated(by factor: Double = 0.5) -> TabFillSpec {
        TabFillSpec(
            color: color,
            saturatedAlpha: saturatedAlpha * factor,
            fadedAlpha: fadedAlpha * factor,
            fillVisible: fillVisible,
            borderColor: borderColor.opacity(factor),
            borderWidth: borderWidth,
            pulses: false,
            pulseDuration: pulseDuration
        )
    }
}
```

### 段间分割线

- **粗细:** 0.5 pt(Retina 1 物理像素)
- **颜色:** `Color.stxStroke.opacity(0.6)`(复用现有 token)
- **位置:** 在段边界,1 pt 范围居中
- **方向:** 跟 edge 垂直 — `.left`/`.right` 时分割线水平;`.top`/`.bottom`
  时分割线竖直
- **数量:** N 段画 N-1 条
- **isExpanded 时:** 不画(让位给展开内容)

### 圆角处理

`FloatingTabShape` 保持整体 tab 圆角,内部段用 `Rectangle().path(in: rect)`
作为 sub-segment 几何;依靠外层 `.clipShape(shape)` 把两端段的圆角从外层
继承下来,中间段的两端是直角。

### 段顺序

直接消费 `visibleSessions` 已经排序的顺序:
- needsInput sessions 第 1 段(顶/最左)
- 其余按 `updatedAt` desc

### Forward-compat (Preferences 未来扩展)

本 spec **不动 Preferences**,但要求 API 形状允许后续注入:

1. **cap 注入:** `FloatingStatsPanelView` 内
   ```swift
   private static let segmentCap = 5
   ```
   未来变
   ```swift
   let cap = env.preferences.tabSegmentCap
   ```
   `TabSegmenter.segments(from:cap:)` 已经把 cap 当入参,不依赖 5;
   `TabGlowOverlay` 只看 `segments.count`,完全不知道 cap
2. **tab 几何尺寸:** `FloatingPanelGeometry.size(edge:expanded:)` 是 tab
   大小的单一入口,本 spec 不动它。未来加 `length` 参数:
   ```swift
   static func size(
       edge: FloatingPanelEdge,
       expanded: Bool,
       length: CGFloat? = nil  // ← 未来加
   ) -> CGSize
   ```
   `TabSegmenter.rects(in:count:edge:)` 接 size 参数已经满足 — 无论 size
   多大都能均分
3. **拖动改尺寸的 forward path:** 未来加 resize handle(类比现有
   `FloatingDragHandle`)+ 持久化到 Preferences。本 spec 不实现,但要求
   几何切分不能写死任何段高/段宽 — `TabSegmenter.rects` 接 size 参数
   已满足
4. **段视觉 cap-agnostic:** `TabFillSpec.spec(for:)` 只接 displayState,
   不接 cap / 段数 / segment index。未来 cap 提到 8/10/20 时 `TabFillSpec`
   完全不用动

## Testing

新建 `ClaudeStatsTests/TabSegmenterTests.swift`,15-20 case,沿用 4 个新
test suite 的 `@Suite` / `@Test` / `#expect` 风格。**全是 pure helper
in/out,不需要 SwiftUI runtime。**

### `TabSegmenter.segments(from:cap:)` case

- 空 sessions → []
- N=1 → 1 段,`isOverflow == false`,`overflowCount == 0`
- N=cap → cap 段全部非溢出
- N=cap+1 → cap 段,最后一段 `isOverflow == true`、`overflowCount == 2`
- N >> cap → 最后一段 `overflowCount == N - cap + 1`
- 溢出段 `displayState` == 溢出区 max(updatedAt) session 的 displayState
- 溢出段 `needsInput` == 溢出区任一 session needsInput(任一 true 则 true)
- 段顺序保留输入 sessions 顺序
- 溢出段 id == "overflow",非溢出段 id == session.id

### `TabSegmenter.rects(in:count:edge:)` case

- count=0 → []
- count=1 → 1 个 rect == 整 size
- count=N 垂直 edge → 累加 height == 总 height(±0.5 float 误差),宽度
  保持原 width
- count=N 水平 edge → 累加 width == 总 width(±0.5),高度保持原 height
- 相邻 rect 无 gap、无 overlap

### 不测的部分

- TabGlowOverlay 本体 SwiftUI 渲染(SwiftUI snapshot test 不划算,留给手动
  + #Preview)
- 分割线粗细 / 颜色 / 位置(同上)
- 动画曲线 / pulse 相位(同上)
- `TabFillSpec.desaturated` 数值乘法(trivial)

### #Preview 增量

`TabGlowOverlay.swift` 已有 "All states" preview(单段)。新增第 2 个
preview "Segmented":

- 单行 5 个 tab side-by-side,分别 N=1 / 2 / 3 / 5(满)/ 8(溢出)
- 单独子组演示 needsInput 在不同段位置时的降饱和效果

方便 Xcode preview 里目测,不进 CI。

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| 段几何 mask 跟圆角 tab 拼接出锯齿 | 依赖 SwiftUI `.clipShape(shape)` 外层 mask 自然继承圆角;实现时手动在 #Preview 里目测 |
| needsInput 段 pulse 跟其他段 desaturated 动画不同步 | `TimelineView` 在顶层共用一个时钟;非 pulse 段 spec 的 `pulses = false`,自然只有 needsInput 段动 |
| segments empty / dormant 时的早返回路径破坏 #Preview "all states" 用例 | 改 API 后旧 preview 也要适配,统一传 segments 数组 |
| 溢出聚合段被误解为"一个未知 session" | `id == "overflow"` 让 ForEach 稳定;a11y 不暴露段细节,所以无用户体感歧义 |

## 实施顺序提示(给后续 writing-plans)

建议按以下顺序写 TDD,每步独立 PR-able:

1. 新建 `TabSegment.swift` + `TabSegmenter`(只放 stub,函数返回 [])
2. 写 `TabSegmenterTests` 全部 case,跑 RED
3. 实现 `TabSegmenter.segments(from:cap:)`,跑 GREEN
4. 实现 `TabSegmenter.rects(in:count:edge:)`,跑 GREEN
5. 改 `TabGlowOverlay` API + 内部多段渲染 + `TabFillSpec.desaturated`
6. 改 `FloatingStatsPanelView` callsite,常量 `segmentCap = 5`
7. 扩 #Preview "Segmented"
8. 手动测:单 session / 多 session / needsInput 在不同段位置 / 0 session /
   超过 cap 触发溢出 / Reduce Motion / .left .right .top .bottom 四 edge

完整跑 `bash scripts/run-tests.sh` 走完整链路(测试 + build + launch)。

---

## §Amendment 2026-05-26 — Include FG sessions in tab

Manual UI verification (Task 7) surfaced that the original §Goal scope
("only show `kind == .background` in tab") did not match user expectation:
the user runs terminal `claude` (FG) much more often than `claude --bg`,
so the tab was empty most of the time, defeating the feat's purpose.

Amendment scope (all in this PR):

1. `SessionRegistry.visibleSessions` filter drops the `guard session.kind
   == .background` line. FG + BG both appear.

2. `visibleSessions` stable-partitions BG segments before FG segments.
   Within each group the existing sort (needsInput first + updatedAt desc,
   inherited from `sessions`) is preserved.

3. `TabSegment` gains an `isForeground: Bool` field.
   `TabSegmenter.segments` forwards `session.kind == .foreground`. The
   overflow segment takes the kind of the `max(updatedAt)` session in its
   overflow region (same source as overflow `displayState`).

4. `TabGlowOverlay.specFor` adds a 4th branch:
   - `needsInput` → `needsInputSpec` (unchanged)
   - else any other segment `needsInput` → `.desaturated(by: 0.5)` (unchanged cascade)
   - else `isForeground` → `.desaturated(by: 0.7)` (**new**: FG lightly muted)
   - else → normal `.spec(for:)` (unchanged)

5. `CollapsedSessionBadge` `●N` count = `visibleSessions.count` (now
   includes FG); the badge itself does not differentiate FG/BG.

6. `LiveSessionRow` contextMenu is **unchanged** — FG still shows only
   "Focus terminal tab", BG shows Stop / Respawn / Remove. The existing
   `session.kind == .background` checks there continue to work.

Reason FG-desaturate (0.7) is lighter than `needsInput`-induced cascade
(0.5): FG is a constant background distinction, not an interrupt. Cascade
is reserved for "the rest fades so needsInput pops". The two effects do
**not** compose multiplicatively — when `needsInput` is anywhere, all
non-needsInput segments use the 0.5 cascade regardless of kind.

Out of scope (deferred):
- Settings to toggle "include FG" preference
- Visual differentiation other than alpha + sort order
- contextMenu changes for FG sessions

---

## §Amendment 2026-05-26 #2 — Split state hooks from PermissionRequest hook

Manual UI verification (after Amendment #1) revealed `tab` color not changing
even though `visibleSessions` correctly contains FG sessions: `displayState`
depends on hook events (UserPromptSubmit → `.thinking`, etc.), which never
reached CCBar because the user's `~/.claude/settings.json` was already
occupied by a third-party `ensoai-hook.cjs`, and CCBar's `permissionApprovalEnabled`
default of `false` meant CCBar never installed its own hooks.

The original installer took exclusive ownership of `PermissionRequest` (CC
protocol: first hook to return a decision wins), so enabling Permission
approval would have **silently broken** ensoai's notification feature.

Amendment #2:

1. `ClaudePermissionHookInstaller` introduces `InstallOptions: OptionSet`:
   - `.stateHooks` — 14 state events (SessionStart, UserPromptSubmit, etc.).
     Installed via `mergeCommandHook` which appends to existing entries.
     **Safe to coexist** with foreign hooks (ensoai, etc.).
   - `.permissionHook` — `PermissionRequest`. Still takes exclusive ownership.
   - `.all` — both (existing default, preserves backward compat).
2. `install(port:options:)` and `uninstall(options:)` accept the OptionSet.
   Default = `.all` so existing call sites continue to work.
3. `AppEnvironment.start()`:
   - ALWAYS calls `permissionServer.start(port:)` + `installer.install(port:, options: .stateHooks)`.
     State hooks coexist with ensoai → tab color updates work regardless
     of Permission approval feature.
   - Then calls `applyPermissionApprovalSetting()`.
4. `applyPermissionApprovalSetting()`:
   - `enabled` → `installer.install(port:, options: .permissionHook)` only
   - `disabled` → `installer.uninstall(options: .permissionHook)` only
   - Server stays running; state hooks stay installed regardless.
5. `Preferences.permissionApprovalEnabled` semantics narrow: now only
   controls the `PermissionRequest` HTTP hook + in-app bubble UI. State
   hooks are always on.

Reason for "always on" state hooks: tab color updates are pure observation;
they don't intercept CC's decision pipeline, so there's no possible
breakage to coexisting tools. Users get tab functionality regardless of
whether they want CCBar's permission bubble.

Out of scope:
- Settings UI copy update (will be done separately if user requests)
- Migration UI for users with existing PermissionRequest conflicts
