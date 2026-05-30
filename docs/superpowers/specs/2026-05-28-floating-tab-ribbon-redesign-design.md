# Floating tab — collapsed bar Ribbon redesign

**Date:** 2026-05-28
**Status:** Draft — awaiting user review
**Scope:** 单 PR / 单 implementation plan。
**Supersedes:** `2026-05-27-floating-tab-settings-design.md` §Design 4
(badge region 80/20 + `CollapsedSessionBadge`)。前一稿的其他 §
(Settings 入口 + `floatingTabSegmentCap` + `floatingTabCard` 跳转)继续生效。

## Problem

上一稿的 collapsed bar 用 80/20 双区:上 80% 走 `TabGlowOverlay` 分段染色,
末端 20% 放 `CollapsedSessionBadge` 的 `●N`(圆点 + session 总数)。落地
跑起来发现三个问题:

1. **overflow 段看不出是 overflow** —
   `TabGlowOverlay` 当前把 `[TabSegment]` 一段段平均切。`isOverflow == true`
   的段渲染规则跟普通段**完全一致** —— 只是颜色取了被聚合区域 `max(updatedAt)`
   的 displayState。看条的人无法分辨 "5 段独立" 还是 "4 段独立 + 1 段聚合
   了 3 个 session"。`+N` 数字也不知道在哪里能看到。
2. **20% 给一个圆点 + 数字太挤** —
   `CollapsedSessionBadge` 是 `HStack { 7×7 圆点 + monospaceDigit Text(N) }`。
   塞进 36×~22 pt 的末端区,排版不舒服;数字字号被空间反压;且圆点颜色取
   "最高优先级 badge",跟下方紧邻的段染色色相经常同色,糊在一起。
3. **同一信息出现两次** —
   段染色已经把"每个 session 的状态"显示出来了;`●N` 复述的"最高优先级
   颜色 + 总数"是低密度版本,两套语言抢同一块物理空间,反而不清晰。

## Goals

回到"折叠条 = 一条信息密度最高的彩色色带"的定位:

1. 取消 80/20 双区。`TabGlowOverlay` 重新覆盖整条 collapsed bar。
2. 把 overflow 段做出**视觉差异**:在该段填充之上叠一组水平 hairlines
   (像多张纸叠在一起),并在段中央叠一个小号 `+N` monospace 数字标记
   被聚合的 session 数。
3. 顶端加一条 0.5pt 短 hairline 作为 drag handle 视觉提示(仅 segmented
   模式下可见,长度 ≈ bar 短边的 50%,居中,颜色 `Color.white.opacity(0.22)`)。
   该 hint **画在 `TabGlowOverlay` 内部** —— 因为 overlay 是 panelSurface
   最外层的 `.overlay`(画在 `collapsedContent` 之上),hint 若放在
   `collapsedContent` 里会被段填充盖住。
4. 删除 `CollapsedSessionBadge`、`Metrics.badgeFraction`、
   `badgeRegionSize`、`badgeRegionAlignment` 以及 `TabGlowOverlay` 的
   `mainAreaFraction` 参数 —— 这些都是上一稿 80/20 实现专属,无其它消费者。

## Non-Goals

- 不动展开态 `LiveSessionsList` 的任何渲染(rowLabel "5+" 等保持现状)。
- 不动 `TabSegmenter.segments(from:cap:)` 的聚合算法 —— `TabSegment`
  已经带 `isOverflow` 和 `overflowCount`,新设计直接消费,不需要改模型。
- 不动 `Preferences.floatingTabSegmentCap`(3-10,默认 5 的 stepper 保留)。
- 不动 `TabFillSpec` 颜色 / pulse / desaturation 规则 —— overflow 段的
  填充层仍走原有 spec,叠加层是新加的额外视觉。
- 不引入新的 Preferences 项(YAGNI:hairline 颜色、handle 长度、`+N`
  字号等参数化都暂不做,先把视觉钉好)。

## Design

### 1. `TabGlowOverlay`:overflow 段叠加层 + drag handle hint

`TabGlowOverlay.renderedTab(specs:rects:size:now:)` 内当前对每个
segment 调用 `segmentFill(spec:rect:now:)` 画基础填充,然后画 border
+ 段间 dividers。

#### 1a. Overflow 段叠加(每段独立)

每个 segment 渲染后,如果对应的 `TabSegment.isOverflow == true`,
**额外画两层**:

- **A. 水平 hairlines** —— 在该段 `rect` 区域内画 N 条等距 0.5pt 暗线
  (颜色 `Color.black.opacity(0.18)`,数量 `min(overflowCount + 1, 4)`,
  跨整段宽度,垂直方向均分)。视觉上"像多张纸叠在一起"。
- **B. `+N` 字样** —— 在段中央叠一个 `Text("+\(overflowCount)")`,
  字体 `.sora(8, weight: .semibold).monospacedDigit()`(竖边)
  或 `.sora(9, weight: .semibold).monospacedDigit()`(横边),
  颜色 `Color.white.opacity(0.95)`,
  `shadow(color: .black.opacity(0.6), radius: 1, y: 1)` 保证在任何
  段颜色上都可读。

#### 1b. Drag handle hint(整条共一根)

`TabGlowOverlay` segmented 分支额外画一根 hairline 作为可拖拽提示
(dormant 分支不画):

- 竖边 (`left`/`right`):**水平**短线,定位在 bar **长轴顶端**,距顶 4pt,
  长度 = `size.width * 0.5`,水平居中(`x = size.width/2`)。
- 横边 (`top`/`bottom`):**竖向**短线,定位在 bar **长轴的一个末端**
  (`top` dock → bar 右侧 `x = size.width - 4`;`bottom` dock → bar
  左侧 `x = 4`),长度 = `size.height * 0.5`,垂直居中
  (`y = size.height/2`)。`top` 跟 `bottom` 的 X 不对称是有意的(避免
  hint 跟屏幕角靠太近)。
- 厚度 0.5pt,颜色 `Color.white.opacity(0.22)`。

#### 实现

- `TabGlowOverlay` 当前的 `segments: [TabSegment]` 已经包含每段所需的
  完整信息(包括 `isOverflow` 和 `overflowCount`)。
- 在 `renderedTab` 的 `ZStack` 里,segment fills `.clipShape(shape)` 之后,
  再加一个并列 `ForEach(0..<segments.count)`,只对 `isOverflow == true`
  的段画 A + B 两层(整组也 `.clipShape(shape)` 保持圆角剪裁)。
- A 用 `ForEach(0..<lineCount, id:\.self)` 配合 `Rectangle().frame(height:0.5)`
  按 `.position` 摆放;每条线的 y 坐标 = `rect.minY + rect.height * (i+1) / (lineCount+1)`。
- B 用单个 `Text(...)` 加 `.position(x: rect.midX, y: rect.midY)`。
- Drag handle hint 单独画一个 `Rectangle()`,跟 segments 同 `clipShape`。

水平边 (`top`/`bottom`) 时:overflow hairlines 是**竖向**的(沿 height 跨度),
位置沿 width 均匀。与 `dividerLine` 的方向对偶规则一致。

### 2. `FloatingStatsPanelView.collapsedContent`:简化

把当前的 if/else if/else 三分支:
- `if let badge = sessions.dominantBadge` → `CollapsedSessionBadge`(删)
- `else if edge.isVertical` → `sideCollapsedTitle`(留)
- `else` → `horizontalCollapsedTitle`(留)

简化为二分支:

```swift
private func collapsedContent(edge: FloatingPanelEdge, size: CGSize) -> some View {
    let title = L10n.string("floating.tab.title", defaultValue: "Claude agents")
    let sessions = env.sessionRegistry.visibleSessions
    return Group {
        if sessions.isEmpty {
            // 无 session: 居中显示 title 文字, 跟现状一致(竖排或横排)。
            if edge.isVertical {
                sideCollapsedTitle(title, edge: edge, size: size)
            } else {
                horizontalCollapsedTitle(title)
            }
        } else {
            // 有 session: 折叠条本身(被 TabGlowOverlay 绘制)就是内容。
            // collapsedContent 这一层不再叠任何文字 / badge / hint —— drag
            // handle hint 由 TabGlowOverlay 自己画(见 §1)。仅保留 a11y label。
            Color.clear
                .accessibilityLabel(L10n.format(
                    "floating.tab.badge.a11y",
                    defaultValue: "%d Claude sessions, status %@",
                    sessions.count,
                    sessions.dominantBadge?.rawValue ?? "idle"
                ))
        }
    }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Metrics.collapsedContentPadding)
        .overlay(dragHandle)
        .accessibilityHint("Hover to expand. Drag to snap to another screen edge.")
}
```

`sessions.isEmpty == false` 分支显式用 `Color.clear` 占位是因为
`Group { } else { }` 需要一个 view 返回(empty branch 不合法);该
clear view 承载 `.accessibilityLabel` 让 VoiceOver 仍能朗读会话总数 +
最高优先级状态。

### 3. 删除已经成为弃儿的代码

- `CollapsedSessionBadge`(`FloatingStatsPanelView.swift:256`):删整个 `struct`
  (跟它的 `var color: Color`)。
- `FloatingStatsPanelView.badgeRegionSize(in:edge:)` 和
  `badgeRegionAlignment(for:)`:删两个 private method。
- `FloatingStatsPanelView.collapsedDragHint(edge:size:)`:**不**新增
  (drag handle hint 由 `TabGlowOverlay` 承载,见 §1b)。
- `Metrics.badgeFraction`:删常量,`Metrics` enum 只剩 `collapsedContentPadding`。
- `TabGlowOverlay.mainAreaFraction`:删 var + `mainAreaSize(for:)` helper +
  `segmentedBody` 里对它的引用,`TabSegmenter.rects(in: proxy.size, ...)`
  直接用 `proxy.size`。
- `panelSurface` 的 `TabGlowOverlay(...)` 调用:删 `mainAreaFraction:` 实参。

### 4. accessibility

之前 `CollapsedSessionBadge.accessibilityLabel` 报 "%d Claude sessions,
status %@" —— 拆除 badge 后该 label 由 §2 里 `collapsedContent` 的
`Color.clear` 占位 view 承载,L10n key `floating.tab.badge.a11y` 沿用。

## Testing

主要是 visual / manual。`TabGlowOverlay` 的 overflow 叠加层属于
渲染细节,没有单元测试可写(`TabSegmenter` 的聚合算法已经在
`TabSegmenterSegmentsTests` 全覆盖)。

手动验证清单:

1. **0 session** — collapsed bar 显示居中 "Claude agents" 文字(竖排
   或横排,跟现状一致)。无段染色、无 drag handle hint。
2. **1-cap session,无溢出** — N 段均分,无 hairlines、无 `+N`。
   顶端有短 hairline drag handle。
3. **N > cap,触发 overflow** — 末段是 overflow 段:有水平 hairlines(
   叠层视觉)+ 居中 `+3`(或对应数字)。
4. **cap=3, sessions=4** — 2 段独立 + 1 段 overflow,overflow 显示 `+2`。
5. **cap=3, sessions=10** — 2 段独立 + 1 段 overflow,overflow 显示 `+8`,
   hairlines 数量饱和(4 条上限)。
6. **needsInput 段在 overflow 之外** — 该段独立、red pulse,overflow 段
   被 desaturate(沿用现有规则)但 hairlines + `+N` 仍可见。
7. **横边(top/bottom)** — hairlines 竖向、`+N` 字号略大(9pt),drag
   handle hint 在 bar 左侧 / 右侧居中(横向条的 "顶端"对应短竖线在
   bar 最远离屏幕边的那一头)。
8. **VoiceOver** — focus 到 collapsed bar,朗读 "%d Claude sessions,
   status %@"(跟拆 `CollapsedSessionBadge` 前一致)。

## Files touched

| File | Change |
|---|---|
| `Views/FloatingStats/TabGlowOverlay.swift` | overflow 段叠加 hairlines + `+N`;删 `mainAreaFraction` 参数和 `mainAreaSize(for:)` |
| `Views/FloatingStats/FloatingStatsPanelView.swift` | `collapsedContent` 简化(删 badge 分支);新增 `collapsedDragHint(edge:size:)`;删 `CollapsedSessionBadge` struct、`badgeRegionSize`、`badgeRegionAlignment`、`Metrics.badgeFraction`;`panelSurface` 调用 `TabGlowOverlay` 不再传 `mainAreaFraction`;新增 a11y label on collapsedContent's hasSessions branch |

## Out of scope

- 不改 `TabSegmenter`(模型已经够用)。
- 不改 `Preferences`(`floatingTabSegmentCap` 沿用)。
- 不改 Settings 页面(2026-05-27 spec 的 Settings section + Stepper 保留)。
- 不改展开态(`LiveSessionsList` 的 rowLabel "5+" 等保持不变 ——
  expanded list 跟 collapsed bar 的视觉语言可以不同;expanded 已经有
  独立 rowLabel 列,不需要 "+N" 这种紧凑表达)。
- 不引入"hover 才显示 +N" 之类的渐进披露 —— 折叠态信息密度本身就要
  立刻可读。
- 不引入 `Preferences` 上的视觉调参开关。
