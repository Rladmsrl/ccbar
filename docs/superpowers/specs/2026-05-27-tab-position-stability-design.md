# Floating tab — 段位置稳定化 + displayState 终止事件优先

**Date:** 2026-05-27
**Status:** Draft — awaiting user review
**Scope:** 单 PR / 单 implementation plan。

## Problem

两个相关 bug 让 floating tab 的 "颜色段" 信息基本失效:

### Bug A —— 绿色完成后会"自己"变橙

`LiveSession.displayState` (LiveSession.swift:138) 是 `lastEvent → 颜色` 的
纯映射。`SessionRegistry.upsertFromHook` (SessionRegistry.swift:84) 收到
任何 hook 都会无条件覆盖 `lastEvent`。两条真实路径会让 `Stop` 后绿色再次
变色:

1. **新一轮 prompt**:`UserPromptSubmit`(蓝)→ `PreToolUse`(橙)。
2. **hook 乱序到达**:`Stop` 已经触发了,但前一阶段的 `SubagentStop` /
   `PostToolUse` 延迟到达。看映射表:
   `SubagentStop / PreToolUse / PostToolUse → .working` → 橙。
   此时 `state` 其实已经被 `Stop` 设成 `.idle`(SessionRegistry.swift:93),
   但 `displayState` 没读 `state` 也没读 `recentEvents`,所以这条信息丢了。

第 1 条是正确语义(确实进入新一轮),不修。第 2 条是 `displayState` 的
设计漏洞,要修。

### Bug B —— 段位置一直在抖,颜色信息无法绑回到具体 session

`SessionRegistry.rebuildSorted` (SessionRegistry.swift:267) 当前规则:

```swift
sessions = sessionsById.values.sorted { lhs, rhs in
    if lhs.needsInput != rhs.needsInput { return lhs.needsInput }
    return lhs.updatedAt > rhs.updatedAt
}
```

任何 hook 事件 / `agents --json` 轮询 / permission 翻转都会 bump
`updatedAt`(SessionRegistry.swift:96 / 158 / 212),最近活动的 session
浮顶 → 段位置每秒都在重排。结果:用户看到"第 2 段变红了"但下一秒
"第 2 段"已经变成另一个 session,颜色编码失去意义。

## Goal

两个改动一并落地:

1. **Bug A**:`displayState` 改成 `state == .idle` 时优先看 `recentEvents`
   里的终止事件(`Stop` / `StopFailure` / `PostCompact` / `SessionEnd`),
   而不是无脑信任 `lastEvent`。
2. **Bug B**:`SessionRegistry` 排序键改成 `startedAt` 升序(BG/FG 分组保留,
   BG 在上),`needsInput` 不再影响位置,只靠原有的红色脉冲 + 粗边框抓眼。
   展开面板里加一列行号,跟段位置一一对应,让用户能从段位置回查到具体
   session 名。

成功标准:

- 完成一轮 (`Stop`) 后,再有任何"曾经表示 working 的事件"到达 (`SubagentStop`,
  `PostToolUse`, ...),段颜色不再退回橙 / 紫,保持绿 (`attention`),
  直到 `SessionEnd` 才退成 dormant 或用户发新 prompt (新一轮的 `working`)
- session 一旦排进某个段(段位置 = 它在当前可见列表中的索引),
  在它活着、且没有更早的 session 加入 / 现有 session 结束的前提下,
  位置不变
- needsInput 段保持原位,仍是红色脉冲
- session 结束 → 其它段顺势 compact,不留空洞
- 展开面板行号跟 tab 段顺序一一匹配,overflow 段对应多行 session
  共享一个"5+"前缀

## Non-goals

明确不做(YAGNI):

- **身份标记**(首字母 / hue 点 / 图标):稳定位置 + 展开面板行号已经够用,
  没数据说位置记忆不够,先不加
- **手动 pin / 拖拽排序**:同上,等位置稳定下来观察一段时间再说
- **跨重启持久化 segment 位置**:`startedAt` 由 `agents --json` 给的
  daemon 时间(BG)或第一次 hook 时间(FG)决定,app 重启后从同一份数据
  recompute,顺序自然一致;不需要额外存储
- **重写 overflow 段聚合规则**:沿用现有 `TabSegmenter.segments(from:cap:)`
  框架,只改"谁进 overflow"
- **跨段动画 / 段间过渡**:现有 `.animation(.easeOut(duration: 0.25),
  value: segments)` 在新规则下自然会少触发,够用

## Design

### 1. `LiveSession.displayState` 改造

文件:`ClaudeStats/Models/Session/LiveSession.swift:138`。

新逻辑(伪码):

```swift
var displayState: DisplayState {
    if state == .idle {
        // 反向扫 recentEvents, 找最近的"终止事件",
        // 跳过 SubagentStop / PostToolUse 等"working 残音"。
        for ev in recentEvents.reversed() {
            switch ev.event {
            case "Stop", "PostCompact":               return .attention
            case "StopFailure", "PostToolUseFailure": return .error
            case "SessionEnd":                        return .sleeping
            default: continue
            }
        }
        return .idle
    }
    // state == .working: 跟原表一致
    switch lastEvent {
    case "UserPromptSubmit":                          return .thinking
    case "PreToolUse", "PostToolUse", "SubagentStop": return .working
    case "SubagentStart":                             return .juggling
    case "PreCompact":                                return .sweeping
    default:                                          return .idle
    }
}
```

关键不变量:

- `state` 是 `idle`/`working` 二元枚举,已经在 `upsertFromHook`
  (SessionRegistry.swift:91-95) 里用 `workingEvents` / `idleEvents` 集合
  正确维护;`displayState` 现在信任它。
- `recentEvents` 容量 `LiveSession.recentEventLimit = 8`(LiveSession.swift:183),
  足够覆盖一次 Stop 之后乱序到达的几个 hook,不会被"找不到 Stop"漏判。
- 用户发新一轮 prompt → `state` 被 `UserPromptSubmit` 翻成 `.working` →
  走第二段 → 蓝。这是对的,新一轮就不该再绿着。

### 2. `SessionRegistry` 排序键改造

文件:`ClaudeStats/Services/Session/SessionRegistry.swift:267`。

```swift
sessions = sessionsById.values.sorted { lhs, rhs in
    // 1) BG 在 FG 上方 (跟 visibleSessions:240 现有分组规则一致)
    if (lhs.kind == .background) != (rhs.kind == .background) {
        return lhs.kind == .background
    }
    // 2) 同组内: startedAt 升序 = 最早开的在最上
    return lhs.startedAt < rhs.startedAt
}
```

`startedAt` 是 `let`(LiveSession.swift:48),session 出生时定死,
所以排序键在它生命周期内不变。

`markNeedsInput` (SessionRegistry.swift:194-215) 里 `entry.updatedAt = .now`
那一行删掉:在新规则下 `updatedAt` 已经不参与排序,bump 它没意义,
还会让其它读 `updatedAt` 的代码(若有)被误导。

### 3. overflow 段聚合规则微调

文件:`ClaudeStats/Views/FloatingStats/TabSegment.swift` 附近的
`TabSegmenter.segments(from:cap:)`(具体行号实现时定位)。

今天的 segmenter 把 `prefix(cap - 1)` 留作独立段,`suffix(from: cap - 1)`
进 overflow。**输入顺序变了,语义跟着翻**:

| 旧排序 (updatedAt desc)         | 新排序 (startedAt asc)        |
|---|---|
| 独立段 = 最近活动的 cap-1 个    | 独立段 = **最早开的 cap-1 个**(stable) |
| overflow = 最近少活动的         | overflow = **最新开的 N-cap+1 个** |

这是稳定性的内在 trade-off:既然"位置 = 身份,不能动",那么 cap 撑爆时,
能塞进 overflow 的只能是 **新来的** session,不能赶走老的。否则老 session
的 slot 又会随新人到来而漂移,失稳。

代价:N > 5(cap)时,刚开的 session 看不到色段,得 hover/展开看。这是
明知的取舍——稳定性比"我刚开的那个能看到"优先。N ≤ 5 是常态,这条
路径很少触发。

`TabSegmenter.segments(from:cap:)` 的实现代码**完全不动**,只是输入顺序
变了。overflow 段 `kind` 沿用 overflowRegion 里 `max(updatedAt)` 的
session,在新顺序下含义变成"新开的这几个里最近还在动的那个的 kind",
也合理,保留。

### 4. 展开面板行号

文件:`ClaudeStats/Views/FloatingStats/FloatingStatsPanelView.swift`
中的 `LiveSessionsList` 和 `LiveSessionRow`(`FloatingProviderStatusView`
是 provider 状态行,跟 session 列表无关,不动)。

每行最左加一列窄的行号("1" / "2" / "3" / "4" / "5+")。"5+" 行号
专属 overflow 段对应的多个 session:它们各占一行,**每行的行号列都显示
"5+"**(而不是只在第一行显示),这样视觉上能一眼区分出 "5+ 区域" 与
"1-4 主区域",代价是同一字符串重复出现,但好于让用户去对齐多行分组。

视觉:

```
┌───────────────────────────────────┐
│ 1  ●  bg-chat-agent      working  │
│ 2  ●  bg-docs-fetcher    juggling │
│ 3  ○  PycharmProjects    attention│
│ 4  ○  ccbar-fix          working  │
│ 5+ ●  bg-archive-runner  idle     │
│ 5+ ●  bg-bench           idle     │
└───────────────────────────────────┘
```

字号小 (10-11pt)、`.secondary` 灰度。目的是让用户建立段位置 ↔ 行号 ↔
session 的对应,不喧宾夺主。

行号渲染源数据 = `SessionRegistry.visibleSessions` 的索引;cap 之后的
全部归到 "5+"。这个 cap 跟 TabSegmenter 用的常量 5 保持一致(共享同一个
常量,避免漂移)。

### 5. 测试

新加单测:

`LiveSessionTests`:
- Stop 之后 lastEvent 被覆盖成 PostToolUse → displayState 仍是 `.attention`
- Stop 之后 lastEvent 被覆盖成 SubagentStop → `.attention`
- Stop 之后 lastEvent = UserPromptSubmit + state = working → `.thinking`
- StopFailure 之后再覆盖 PostToolUse → `.error`
- SessionEnd 是最后一个终止事件 → `.sleeping`
- recentEvents 为空 / 没有终止事件 → `.idle`

`SessionRegistryTests`:
- 3 个 BG 按 startedAt asc 排,即使 updatedAt 顺序相反
- BG 和 FG 混合 → BG 全部排前面,组内仍是 startedAt asc
- needsInput 翻成 true 后位置不变
- session 结束 → 其它 session 顺序保持(没空洞)

`TabSegmenterTests` (若已存在):
- N=6 cap=5 时 overflow 段聚合的是 startedAt 最大的 2 个
  (验证 cap 截断在新顺序下语义对)

UI 验证(手动 checklist,实施 PR 里跑):
- 多开 3-4 个 BG session,看 collapsed tab 段位置在 hook 涌入时是否稳定
- 完成一轮再 hover/展开,确认段对应的行号正确
- 触发一个 PermissionRequest,确认对应段红脉冲且 **不移动**

## Open questions

无。

## Implementation order

1. `displayState` 修(独立、零风险,先单测)
2. `SessionRegistry` 排序键改 + `markNeedsInput` 不 bump `updatedAt`
3. `FloatingProviderStatusView` 加行号列
4. 手动 UI 验证 + commit
