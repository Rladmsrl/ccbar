# Floating tab — hover preview panel redesign

**Date:** 2026-05-28
**Status:** Draft — awaiting user review
**Scope:** 单 PR / 单 implementation plan。
**Supersedes:** 现行 `FloatingStatsPanelView.expandedContent` 里 sessions-list 显示的整套(`LiveSessionsList` / `LiveSessionRow` / `AgentsSyncStatusView`)。
**Builds on:** Ribbon redesign (`2026-05-28-floating-tab-ribbon-redesign-design.md`) 的段染色 / drag handle / overflow 视觉。Permission bubble override 路径不动。

## Problem

今天 hover floating tab 会展开到 320×360 的 panel,里面是**所有 session 的列表**
(`LiveSessionsList`),每行能 Focus / Stop / Respawn / Remove。用户反馈这套
"没什么用":

- **信息散** — 5 个 session 各占一行,每行能塞的字段就一点点(项目名 + 时间
  + badge + 1-2 按钮),没有任何 session 的"深度"。
- **冗余跟 tab 段染色重合** — 段染色已经告诉你每个 session 的状态颜色;列表里
  又用色点重复了一遍,信息密度反而下降。
- **没有 "看一眼具体在干啥" 的能力** — 想知道 session 3 在 Read 哪个文件 /
  跑哪个 tool,列表回答不了。
- **跳转链路绕** — 想跳到某个 terminal 得先 hover 整条 tab 等展开,再在 5 行
  里找到对应那行,再点 Focus 按钮(还是隐藏的 hover-action)。三步操作。

## Goals

把 panel 重塑为 **"瞄一眼 + 跳过去"**:

1. Hover 哪个 segment,panel 就展开**那一个** session 的深度预览
   (不再是全列表),包含状态 / 当前活动 / 近期 event 时间线
2. panel 里有一个明显的 `Focus →` 按钮,一步直达对应 terminal
3. overflow segment 是唯一保留 list 形态的入口 —— hover 它显示一个迷你
   list(被聚合的 N 个 session,每行带 Focus 按钮),保持对 hidden
   session 的可达性
4. 进出展开态的动画用既有 `expandedContentPhase` 机制,session 间不做
   mid-stream 切换(简单)

## Non-Goals

- **不**支持 mid-stream 切换 session(hover 第 2 段展开后,把鼠标在 tab
  内挪到第 5 段位置不会切。要切必须 mouse out + re-hover)
- **不**做 hero / matched-geometry morph 动画(content 之间走简单 fade)
- **不**在 panel 里保留 Stop / Respawn / Remove(快速操作不是这个面板的
  职责;后续可在右键菜单 / 主窗口实现)
- **不**展示 `model` 和 cumulative `tokens` 字段(v1 sessions 模型上不
  含这两个 — 它们来自 JSONL transcript,需要单独数据路径,v2 再加)
- **不**改 `TabGlowOverlay` 段染色 / drag handle / overflow 视觉(沿用 Ribbon spec)
- **不**改 `PermissionBubbleView`(permission pending 时 override 行为不变)
- **不**改 drag 区域(整条 tab 仍然 draggable via `FloatingDragHandle`)

## Design

### 1. Trigger:per-segment hover → 单 session 展开

在 `TabGlowOverlay` 同层 / 同坐标系下新增一个透明 hit-test 层
`SegmentHoverTracker`:

- 接收当前的 `segments: [TabSegment]` 和 `edge: FloatingPanelEdge`
- 内部用 `TabSegmenter.rects(in: proxy.size, count: segments.count, edge: edge)`
  算出每段 rect(沿用同一函数,保证视觉跟 hit-test 完全对齐)
- 每个 rect 包一个 `Color.clear` 的 `Rectangle()` 加 `.onHover { isOver in ... }`
- hover 进入 segment N → 回调 `onSegmentHover(index: N)`
- hover 退出(所有 segment 都不再 hover)→ `onSegmentHover(index: nil)`

挂在 `FloatingStatsPanelView.panelSurface` 里,跟 `TabGlowOverlay` 同级
`.overlay(...)`(SegmentHoverTracker 必须在 TabGlowOverlay 之上,因为
TabGlowOverlay `allowsHitTesting(false)`)。

### 2. State 变化

`FloatingStatsPanelState` 新增:

```swift
/// 当前 hover 的 segment index(0-based)。nil = 没在任何 segment 上。
/// 驱动 isExpanded(非 nil ↔ 展开)和 expandedContent 显示的 session。
var hoveredSegmentIndex: Int?
```

`FloatingStatsPanelView` 监听 `hoveredSegmentIndex` 变化:
- nil → non-nil:setExpanded(true)
- non-nil → nil:延 ~250ms grace → setExpanded(false)

(grace 期间如果 hover 又回到某段则取消 collapse,跟今天 `collapseTask` 一样)

**`isExpanded` 保留**:`PermissionStore.pending.count > 0` 时仍然强制
`isExpanded = true`(沿用今天 controller 的 `handlePermissionPendingChange` 逻辑)。
permission override 的优先级 > hover —— hovered 期间来了 permission,内容
切换到 PermissionBubbleView;permission 解决后,如果鼠标还在 segment 上,
回到该 segment 的 preview。

### 3. expandedContent 改造

重写 `FloatingStatsPanelView.expandedContent(cap:)`:

```swift
@ViewBuilder
private func expandedContent(cap: Int) -> some View {
    if let pending = env.permissionStore.pending.first {
        // permission override — 最高优先级
        PermissionBubbleView(...)   // 同今天
    } else if let segmentIndex = state.hoveredSegmentIndex {
        let segments = TabSegmenter.segments(
            from: env.sessionRegistry.visibleSessions,
            cap: cap
        )
        if segmentIndex < segments.count, segments[segmentIndex].isOverflow {
            // overflow segment → mini list
            OverflowSessionList(
                sessions: env.sessionRegistry.visibleSessions.suffix(from: cap - 1)
            )
        } else if segmentIndex < env.sessionRegistry.visibleSessions.count {
            // independent segment → single session preview
            SingleSessionPreview(
                session: env.sessionRegistry.visibleSessions[segmentIndex]
            )
        } else {
            // 鼠标 hover 时段数变了, fallback empty
            Color.clear
        }
    } else {
        // 进入 expanded 但还没决定 hoveredSegmentIndex(罕见过渡态)
        Color.clear
    }
}
```

### 4. `SingleSessionPreview` view(新)

`ClaudeStats/Views/FloatingStats/SingleSessionPreview.swift`,private 不需要,
为了拆文件方便单独成 internal struct。

布局(垂直 VStack,padding 16,frame 适配 panel 320 × 自适应):

```
[● dot]  <displayTitle>                       <kind chip: FG/BG/HL>
              ↑ Status header: 大字 18pt sora semibold

  <subtitle line:  "<state verb> · <last tool/event human-readable>">
              ↑ Activity line: 12pt sora regular, stxMuted

  ──── RECENT ────                            <relative-time of updatedAt>
              ↑ section header: 9pt mono semibold tracking 0.8, stxFainter

  [time] <event 1 human-readable>     ← 11pt mono, list of recentEvents.suffix(3)
  [time] <event 2>
  [time] <event 3>

                                                       [ Focus → ]
              ↑ trailing-right button, 13pt sora medium, stxAccent
```

数据映射:
- `displayTitle` → header 大字
- 状态色点 → `TabFillSpec.spec(for: session.displayState).color`(沿用 Ribbon 调色板)
- kind chip → "FG" / "BG" / "HL"(沿用今天 `kindLabel` 逻辑)
- 状态 verb → `displayState.rawValue` 大写化首字母(`.working` → "Working")
- last tool → `session.recentEvents.last?.event` 走 humanize 映射(spec §4.2)
- relative time → `Format.relativeDate(session.updatedAt)`(沿用现有 helper)
- recent events 列表 → `session.recentEvents.suffix(3)`,每条 `(time, event humanized)`
- Focus button → enabled iff `session.sourcePid != nil && session.kind != .background`
  (跟今天 `canFocus` 同条件);disable 时灰掉 + tooltip "No terminal to focus"
  - onTap: `env.sessionFocus.focus(session:)` 沿用今天 `LiveSessionRow.focusSession()`

**Event humanization**(简单映射,够用就行):

```swift
"UserPromptSubmit" → "Prompt submitted"
"PreToolUse"       → "Tool: <name>"   // 取 toolName from payload, fallback "Running tool"
"PostToolUse"      → "Tool done"
"PostToolUseFailure"→"Tool failed"
"SubagentStart"    → "Subagent started"
"SubagentStop"     → "Subagent done"
"Stop"             → "Turn finished"
"StopFailure"      → "Turn interrupted"
"Notification"     → "Notification"
"PreCompact"       → "Compacting..."
"PostCompact"      → "Compacted"
"SessionStart"     → "Session started"
"SessionEnd"       → "Session ended"
default            → 原 event 名
```

放在 `RecentEvent` 的 extension 上(`var humanized: String`),避免 view
里写 switch。

### 5. `OverflowSessionList` view(新)

`ClaudeStats/Views/FloatingStats/OverflowSessionList.swift`,internal struct。

布局:

```
<N> sessions · overflow group              ← 11pt mono semibold tracking 0.8
                                              stxFainter

ScrollView {
  ForEach session in sessions:
    [● dot]  <displayTitle>                                  [→]
             <state verb> · <relative-time>
    ────────────────  (SettingRowDivider sibling)
}
```

每行可点 Focus 按钮(`→` 图标 button),跟 SingleSessionPreview 的 Focus
button 同 onTap 逻辑。

数据:
- `sessions` 参数 = `visibleSessions.suffix(from: cap - 1)`(就是聚合在
  overflow 段里那批)
- 行布局参考今天 `LiveSessionRow` 但**简化**:去掉 unread bell / 项目目录
  / id hint / context menu / hover actions —— overflow list 是个紧凑列表,
  详情留给单 session preview 那一支路径(不能从 overflow 进入)

### 6. Hit-test 层 `SegmentHoverTracker`

`ClaudeStats/Views/FloatingStats/SegmentHoverTracker.swift`:

```swift
struct SegmentHoverTracker: View {
    let segments: [TabSegment]
    let edge: FloatingPanelEdge
    /// `true` 时退化为整个 panel 一个 Rectangle, 只追 enter/leave 不切段。
    /// `false`(折叠态)按段铺 N 个 hit-test rect, hover 哪段回调哪个 index。
    let isExpanded: Bool
    var onSegmentHover: (Int?) -> Void

    var body: some View {
        GeometryReader { proxy in
            if isExpanded {
                // 展开态: 单 Rectangle 覆盖整个 panel, 只关心 mouse-leave。
                // 段切换不响应 (mid-stream 切换被排除, 见 Non-Goals)。
                Color.clear
                    .contentShape(Rectangle())
                    .onHover { isOver in
                        if !isOver { onSegmentHover(nil) }
                        // isOver == true 时不回调; hoveredSegmentIndex 已经
                        // 在 collapsed → expanded 转换之前被设好, 保留不动。
                    }
            } else {
                // 折叠态: 按段铺 hit-test, 用户进哪段就报哪段。
                let rects = TabSegmenter.rects(
                    in: proxy.size,
                    count: segments.count,
                    edge: edge
                )
                ZStack {
                    ForEach(0..<segments.count, id: \.self) { i in
                        Color.clear
                            .frame(width: rects[i].size.width,
                                   height: rects[i].size.height)
                            .position(x: rects[i].midX, y: rects[i].midY)
                            .contentShape(Rectangle())
                            .onHover { isOver in
                                onSegmentHover(isOver ? i : nil)
                            }
                    }
                }
            }
        }
    }
}
```

挂载点(`FloatingStatsPanelView.panelSurface`,在 TabGlowOverlay overlay 之后):

```swift
.overlay(
    SegmentHoverTracker(
        segments: TabSegmenter.segments(from: sessions, cap: cap),
        edge: edge,
        isExpanded: state.isExpanded,
        onSegmentHover: { idx in
            handleSegmentHover(idx)
        }
    )
)
```

`handleSegmentHover(_:)` 在 `FloatingStatsPanelView` 或更上层(controller)
处理:

```swift
private func handleSegmentHover(_ index: Int?) {
    if let index {
        state.hoveredSegmentIndex = index
        // 取消未触发的 collapse task
        controller?.cancelScheduledCollapse()
    } else {
        // 进入 grace 期(~250ms 后真折叠)
        controller?.scheduleCollapse {
            state.hoveredSegmentIndex = nil
        }
    }
}
```

`scheduleCollapse(_:)` 沿用今天 `FloatingStatsPanelController.collapseTask`
机制(已有的 cancel/重设 模式)。

**hover 跟 drag 的关系**:`FloatingDragHandle`(NSView)在 SegmentHoverTracker
**之上**(它今天就是 collapsedContent 的 overlay)。SwiftUI `.onHover` 跟
NSView 的 mouse-down events 不冲突(hover 是 mouseEntered/Exited,drag 是
mouseDown + mouseDragged)。`FloatingDragHandle` 现有的 activationDistance
门槛保证 click ≠ drag,小幅动作不触发 drag。

但这里没有 segment-tap → Focus 的需求(用户选了"panel 里放 Focus 按钮"),
所以 segment 上 click 不需要被响应,fall-through 到 drag 即可。

### 7. 删除的代码

- `LiveSessionsList`(`FloatingStatsPanelView.swift:~287` 起的整个 struct)
- `LiveSessionRow`(LiveSessionsList 的孩子,行内 action 按钮 / context menu / bell 等)
- `AgentsSyncStatusView`(全 sessions 状态条,跟着 list 一起去掉)
- `ClaudeAgentsService.AgentAction` extension 的 `helpText`(`LiveSessionRow` 是唯一消费者)
- `expandedHeader`(整个 SESSIONS list 的标题栏,新设计里没必要)
- `animatedExpandedSection<Content:>` 辅助方法(LiveSessionsList 的 fade-in 调度,新 SingleSessionPreview / OverflowSessionList 用更简单的内置动画)
- `expandedSectionAnimation(for:)`

`expandedContent` 内部所有跟旧 list 相关的引用都跟着拆。

### 8. 动画

**展开 / 折叠** —— 沿用今天 `state.expandedContentPhase` 机制
(`.hidden / .revealing / .visible / .hiding`),没改动。

**Content 内 fade-in** —— 简化:`SingleSessionPreview` 和
`OverflowSessionList` 各自的根 view 加 `.transition(.opacity)` +
`.animation(.easeOut(duration: 0.18))`,不用分 section stagger。

**Session 切换**(mouse out + re-hover 不同段 → expandedContent 显示
不同的 session) —— `.id(segmentIndex)` 让 SwiftUI 把它当成新 view
diff,触发上面的 `.transition(.opacity)`。

**Hover 进入 / 离开 grace** —— 250ms,跟今天 `collapseTask` 的延迟范围
一致(具体值在 controller 里调,spec 不约束精确数字)。

## Testing

主要是 visual / manual。`SegmentHoverTracker` 是纯几何代理,
`TabSegmenter.rects` 已经被覆盖,没新单测可写。

手动验证清单:

1. **基线** — 0 session:hover tab 没任何反应(没 segment 可 hover),
   collapsed 显示居中 title(Ribbon spec §2 行为)。
2. **单 session preview** — cap=5, sessions=3,hover 第 2 段:tab 展开,
   显示 session 2 的 displayTitle / 状态 / recent events / Focus 按钮。
3. **mouse out + re-hover 切 session** — 在 2 上展开后,mouse 移出 tab,
   再 hover 第 3 段:panel 内容切到 session 3(fade transition)。
4. **mid-stream 不切** — hover 第 2 段展开后,mouse 在 tab 内挪到第 3 段
   位置(段已 hidden,只有 hit-test 层):panel 不变(因为 hit-test 层覆
   盖整个 panel 区域,onHover 只在边界进入/离开时 fire,内部移动是连续
   hover 同一个 Rectangle)。
   - **检验细节**:如果 hit-test 层在 panel 展开后还按 segment rect 切
     分,鼠标从 segment 2 rect 移到 segment 3 rect 时会 fire 切换。
     **修正**:展开后(`isExpanded == true`),`SegmentHoverTracker`
     退化为单个全 panel 的 Rectangle,只追踪 enter/leave,不再分段切换。
     这才是"鼠标离开再 re-hover"的真实行为。
5. **overflow segment hover** — cap=3, sessions=5,hover 第 3 段:tab 展开,
   显示 OverflowSessionList 里 3 个 session(各带 Focus 按钮)。
6. **permission override** — 任意时刻 hover + permission 来:panel 切到
   PermissionBubbleView;permission 解决,鼠标仍在 segment 上:切回该
   segment 的 preview。
7. **Focus 按钮** — 单 session preview 里点 Focus(session 有 sourcePid):
   跳转到对应 terminal app(沿用 SessionFocusService);如果 sourcePid
   为 nil 或 kind 是 background,按钮 disable(灰 + tooltip)。
8. **拖动** — 整条 tab 仍可拖,hover 不干扰 drag activation。

## Files touched

| File | Action |
|---|---|
| `Views/FloatingStats/FloatingStatsPanelState.swift` | 加 `hoveredSegmentIndex: Int?` |
| `Views/FloatingStats/FloatingStatsPanelView.swift` | 重写 `expandedContent(cap:)`;新增 `SegmentHoverTracker` overlay 挂载 + `handleSegmentHover(_:)`;删除 `LiveSessionsList` / `LiveSessionRow` / `AgentsSyncStatusView` / `expandedHeader` / `animatedExpandedSection` / `expandedSectionAnimation` / `ClaudeAgentsService.AgentAction.helpText` extension |
| `Views/FloatingStats/SegmentHoverTracker.swift` | 新建 — 透明 hit-test 层 |
| `Views/FloatingStats/SingleSessionPreview.swift` | 新建 — 单 session 深度预览 |
| `Views/FloatingStats/OverflowSessionList.swift` | 新建 — overflow 段的迷你 list |
| `Views/FloatingStats/FloatingStatsPanelController.swift` | 新增 `scheduleCollapse(_:)` 公开方法 + `cancelScheduledCollapse()`(把今天 `collapseTask` 的细节 expose 给 view);hover trigger 不再依赖 `FloatingHoverTracker`(整条 tab 的 hover 跟踪),改成 view 层 SegmentHoverTracker 驱动。`FloatingHoverTracker` 是否删除?**保留**给 collapsed 模式的 mouseEntered 跟踪(影响 cursor-over-collapsed 时的视觉细节)。但 expanded 阶段的 collapse 决定由 SegmentHoverTracker 驱动 |
| `Models/Session/RecentEvent.swift`(或 LiveSession extension) | 新增 `var humanized: String` 给 `RecentEvent`(humanization 映射表) |

## Out of scope(显式)

- model / cumulative token 字段(等 v2 数据源)
- mid-stream segment 切换(scrub)
- hero / matched-geometry morph 动画
- panel 内 Stop / Respawn / Remove 按钮(快速操作不在此面板)
- 改 PermissionBubbleView(沿用)
- 改 TabGlowOverlay 段染色 / overflow 视觉(沿用 Ribbon spec)
- 改 drag affordance / FloatingDragHandle 行为
