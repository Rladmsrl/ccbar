# Floating tab 段位置稳定 + displayState 终止事件优先 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修两个 bug:(1) 绿色完成后被晚到的 hook 覆盖回橙;(2) 排序按 `updatedAt` 让段位置一直抖,颜色信息无法绑到具体 session。

**Architecture:** `LiveSession.displayState` 在 `state == .idle` 时优先读 `recentEvents` 里的终止事件,忽略乱序 `lastEvent`。`SessionRegistry.rebuildSorted` 排序键改成 `startedAt` 升序(BG/FG 分组保留),`needsInput` 不再 bump `updatedAt`。展开面板每行加行号列让用户能从段位置回查具体 session。TabSegmenter 代码不动,只是输入顺序变了。

**Tech Stack:** Swift 6, SwiftUI, `@MainActor @Observable`, swift-testing (`Testing` 包)。

**Spec:** `docs/superpowers/specs/2026-05-27-tab-position-stability-design.md`

---

## File Structure

**新增**
- `ClaudeStatsTests/LiveSessionTests.swift` — `displayState` 的单测。今天没有这个文件,要起一个。

**改**
- `ClaudeStats/Models/Session/LiveSession.swift` — `displayState` computed var 改造(只改一处)。
- `ClaudeStats/Services/Session/SessionRegistry.swift` — `rebuildSorted` 排序键改;`markNeedsInput` 删 `updatedAt` 自 bump。
- `ClaudeStats/Views/FloatingStats/FloatingStatsPanelView.swift` — `LiveSessionsList` / `LiveSessionRow` 加行号列。
- `ClaudeStatsTests/SessionRegistryTests.swift` — 新增 startedAt 排序 / needsInput-no-bump 测试;旧 `visibleSessionsBackgroundBeforeForeground` 测试已经是新规则的子集,补加一条带显式 startedAt 区分的。

**不动**
- `ClaudeStats/Views/FloatingStats/TabSegment.swift` (`TabSegmenter`) — 输入顺序变,实现代码不变。
- `ClaudeStats/Views/FloatingStats/TabGlowOverlay.swift` — 色板 / desaturate / pulse 全不动。
- `ClaudeStats/Views/FloatingStats/FloatingProviderStatusView.swift` — 这是 provider 状态行,不是 session 列表,不要碰。
- `ClaudeStatsTests/TabSegmenterTests.swift` — 测试用的就是抽象顺序,跟谁是 startedAt-asc / updatedAt-desc 解耦,沿用。

---

## Task 1: 为 `displayState` 起单测文件并写 RED 测试

`displayState` 今天靠 `lastEvent` 单值映射,要改成"`state == .idle` 时反扫 `recentEvents` 找终止事件"。先用 6 条单测把目标行为写出来,跑一遍确认全 RED。

**Files:**
- Create: `ClaudeStatsTests/LiveSessionTests.swift`

- [ ] **Step 1: 写测试文件,覆盖新 displayState 的全部分支**

```swift
import Foundation
import Testing
@testable import ClaudeStats

@Suite("LiveSession.displayState")
struct LiveSessionDisplayStateTests {

    @Test("Stop 之后晚到的 PostToolUse 不该把绿色翻成橙")
    func stopThenLatePostToolUseStaysAttention() {
        let session = makeSession(
            state: .idle,
            lastEvent: "PostToolUse",
            recentEvents: [
                .init(event: "Stop",        at: Date(timeIntervalSince1970: 1)),
                .init(event: "PostToolUse", at: Date(timeIntervalSince1970: 2)),
            ]
        )
        #expect(session.displayState == .attention)
    }

    @Test("Stop 之后晚到的 SubagentStop 不该把绿色翻成橙")
    func stopThenLateSubagentStopStaysAttention() {
        let session = makeSession(
            state: .idle,
            lastEvent: "SubagentStop",
            recentEvents: [
                .init(event: "Stop",         at: Date(timeIntervalSince1970: 1)),
                .init(event: "SubagentStop", at: Date(timeIntervalSince1970: 2)),
            ]
        )
        #expect(session.displayState == .attention)
    }

    @Test("新一轮 UserPromptSubmit 把 state 翻回 working → 蓝 (thinking)")
    func newPromptGoesThinking() {
        let session = makeSession(
            state: .working,
            lastEvent: "UserPromptSubmit",
            recentEvents: [
                .init(event: "Stop",              at: Date(timeIntervalSince1970: 1)),
                .init(event: "UserPromptSubmit",  at: Date(timeIntervalSince1970: 2)),
            ]
        )
        #expect(session.displayState == .thinking)
    }

    @Test("StopFailure 之后晚到的 PostToolUse 保持 error (红)")
    func stopFailureThenLatePostToolUseStaysError() {
        let session = makeSession(
            state: .idle,
            lastEvent: "PostToolUse",
            recentEvents: [
                .init(event: "StopFailure",  at: Date(timeIntervalSince1970: 1)),
                .init(event: "PostToolUse",  at: Date(timeIntervalSince1970: 2)),
            ]
        )
        #expect(session.displayState == .error)
    }

    @Test("SessionEnd 是最后一个终止事件 → sleeping")
    func sessionEndGivesSleeping() {
        let session = makeSession(
            state: .idle,
            lastEvent: "SessionEnd",
            recentEvents: [
                .init(event: "Stop",       at: Date(timeIntervalSince1970: 1)),
                .init(event: "SessionEnd", at: Date(timeIntervalSince1970: 2)),
            ]
        )
        #expect(session.displayState == .sleeping)
    }

    @Test("state==idle 且 recentEvents 里没终止事件 → idle (dormant)")
    func idleWithNoTerminalEventGivesIdle() {
        let session = makeSession(
            state: .idle,
            lastEvent: "PreToolUse",
            recentEvents: [
                .init(event: "PreToolUse", at: Date(timeIntervalSince1970: 1)),
            ]
        )
        #expect(session.displayState == .idle)
    }

    // MARK: - Helper

    private func makeSession(
        state: LiveSession.State,
        lastEvent: String?,
        recentEvents: [LiveSession.RecentEvent]
    ) -> LiveSession {
        LiveSession(
            id: "s",
            displayTitle: "s",
            cwd: nil,
            kind: .background,
            state: state,
            needsInput: false,
            startedAt: .now,
            updatedAt: .now,
            lastEvent: lastEvent,
            recentEvents: recentEvents
        )
    }
}
```

- [ ] **Step 2: 跑测试确认全 RED**

```bash
bash scripts/run-tests.sh 2>&1 | grep -A1 "LiveSession.displayState"
```

Expected: 6 个 case 全部 FAIL,因为新 `displayState` 还没实现。具体失败信息会是 `.thinking != .attention` 等。

- [ ] **Step 3: 不 commit,接 Task 2 一起 commit**

---

## Task 2: 改 `LiveSession.displayState` 让 RED 转 GREEN

**Files:**
- Modify: `ClaudeStats/Models/Session/LiveSession.swift:138-158`

- [ ] **Step 1: 重写 `displayState` 实现**

把当前 138-158 行的 `displayState` 整体替换成:

```swift
/// Derive the clawd-style internal state from `state` + recent events.
/// `state == .idle` 时优先扫 `recentEvents` 找终止事件(`Stop` /
/// `StopFailure` / `PostCompact` / `SessionEnd`),跳过 `SubagentStop` /
/// `PostToolUse` 这类"working 残音"——它们会在乱序 hook 到达时晚于
/// `Stop` 覆盖 `lastEvent`,但 `state == .idle` 是 `Stop` 已经处理过的
/// 铁证。`state == .working` 时退回 `lastEvent` 单值映射。
/// Unknown / no event → ``DisplayState/idle``.
var displayState: DisplayState {
    if state == .idle {
        for ev in recentEvents.reversed() {
            switch ev.event {
            case "Stop", "PostCompact":
                return .attention
            case "StopFailure", "PostToolUseFailure":
                return .error
            case "SessionEnd":
                return .sleeping
            default:
                continue
            }
        }
        return .idle
    }
    // state == .working
    switch lastEvent {
    case "UserPromptSubmit":
        return .thinking
    case "PreToolUse", "PostToolUse", "SubagentStop":
        return .working
    case "SubagentStart":
        return .juggling
    case "PreCompact":
        return .sweeping
    case "StopFailure", "PostToolUseFailure":
        return .error
    default:
        return .idle
    }
}
```

注意:`StopFailure` / `PostToolUseFailure` 在 `idleEvents` 集合里
(LiveSession.swift:193),所以正常路径走第一段 `if state == .idle`,
但保留 `state == .working` 分支里的 `.error` 映射兜底——以防异步顺序里
`PostToolUseFailure` 还没把 state 翻成 idle 就被读到。

- [ ] **Step 2: 跑测试确认变 GREEN**

```bash
bash scripts/run-tests.sh 2>&1 | grep -E "displayState|✓|✗" | head -20
```

Expected: 6 个 displayState case 全部 PASS。其它已有测试不应回归。

- [ ] **Step 3: Commit**

```bash
git add ClaudeStats/Models/Session/LiveSession.swift ClaudeStatsTests/LiveSessionTests.swift
git commit -m "fix(live-session): displayState 在 idle 时读 recentEvents 找终止事件

修两类"绿变橙"路径:
1) Stop 之后晚到的 PostToolUse / SubagentStop 覆盖 lastEvent,
   原 displayState 只看 lastEvent → 翻成 working 橙
2) 现在 state == .idle 时反扫 recentEvents,跳过 working 残音,
   优先返回 Stop/PostCompact (attention) / StopFailure (error) /
   SessionEnd (sleeping)。

新一轮 UserPromptSubmit 把 state 翻回 working → 走第二段映射 → 蓝,
不受新逻辑影响。"
```

---

## Task 3: 加 `SessionRegistry` 新排序的 RED 测试

`rebuildSorted` 当前是 `needsInput 优先 + updatedAt desc`,要改成 `BG/FG 分组 + startedAt asc`。先写测试。

**Files:**
- Modify: `ClaudeStatsTests/SessionRegistryTests.swift` (在文件末尾、`visibleSessionsHidesUnnamedBackground` 之后追加新测试,保持现有结构)

- [ ] **Step 1: 在 `SessionRegistryTests.swift` 末尾(`}` 闭合大括号之前)追加测试**

文件当前最后一行是 line 237 的 `}`,在它之前插入:

```swift

    // MARK: - 段位置稳定 (spec 2026-05-27)

    @Test("同组内按 startedAt 升序排,即使 updatedAt 顺序相反")
    func backgroundSortedByStartedAtAsc() {
        let registry = SessionRegistry()
        // bg-a 先开 (startedAt 早), bg-b 后开 (startedAt 晚)
        let early = Date(timeIntervalSince1970: 1_000)
        let late  = Date(timeIntervalSince1970: 2_000)
        registry.upsertFromAgentsList([
            ClaudeAgent(pid: 1, sessionId: "bg-a", cwd: "/", kind: .background, status: .idle, name: "a", startedAt: early),
            ClaudeAgent(pid: 2, sessionId: "bg-b", cwd: "/", kind: .background, status: .idle, name: "b", startedAt: late),
        ])
        // 让 bg-b 后续被 hook 摸了, updatedAt 变成现在
        registry.upsertFromHook(event: "PreToolUse", payload: ["session_id": "bg-b"])
        // 但顺序仍应是 [bg-a, bg-b], 因为按 startedAt 排
        #expect(registry.sessions.map(\.id) == ["bg-a", "bg-b"])
    }

    @Test("needsInput 不再让 session 浮顶,位置保持 startedAt asc")
    func needsInputDoesNotReorder() {
        let registry = SessionRegistry()
        let early = Date(timeIntervalSince1970: 1_000)
        let late  = Date(timeIntervalSince1970: 2_000)
        registry.upsertFromAgentsList([
            ClaudeAgent(pid: 1, sessionId: "bg-a", cwd: "/", kind: .background, status: .idle, name: "a", startedAt: early),
            ClaudeAgent(pid: 2, sessionId: "bg-b", cwd: "/", kind: .background, status: .idle, name: "b", startedAt: late),
        ])
        // 把 bg-b (晚开) 标 needsInput,旧规则会让它浮顶,新规则不该
        registry.markNeedsInput("bg-b", true)
        #expect(registry.sessions.map(\.id) == ["bg-a", "bg-b"])
    }

    @Test("markNeedsInput 不再 bump updatedAt")
    func needsInputDoesNotBumpUpdatedAt() {
        let registry = SessionRegistry()
        let early = Date(timeIntervalSince1970: 1_000)
        registry.upsertFromAgentsList([
            ClaudeAgent(pid: 1, sessionId: "bg-a", cwd: "/", kind: .background, status: .idle, name: "a", startedAt: early)
        ])
        let beforeUpdate = registry.sessions.first?.updatedAt
        registry.markNeedsInput("bg-a", true)
        let afterUpdate = registry.sessions.first?.updatedAt
        #expect(beforeUpdate == afterUpdate)
    }

    @Test("session 结束后剩余 session 顺序保持稳定 (compact)")
    func sessionEndKeepsOthersStable() {
        let registry = SessionRegistry()
        let t1 = Date(timeIntervalSince1970: 1_000)
        let t2 = Date(timeIntervalSince1970: 2_000)
        let t3 = Date(timeIntervalSince1970: 3_000)
        // 三个 FG: a, b, c (startedAt 递增)
        registry.upsertFromHook(event: "SessionStart", payload: ["session_id": "a", "cwd": "/p/a"])
        registry.upsertFromHook(event: "SessionStart", payload: ["session_id": "b", "cwd": "/p/b"])
        registry.upsertFromHook(event: "SessionStart", payload: ["session_id": "c", "cwd": "/p/c"])
        // 因为 upsertFromHook 用 .now, 这里让 startedAt 不可控 -- 用 agents 重新固定
        _ = (t1, t2, t3)  // 这条测试退化成"a,b,c 顺序保持",hook 顺序入即可
        #expect(registry.sessions.map(\.id) == ["a", "b", "c"])
        // 结束 b
        registry.upsertFromHook(event: "SessionEnd", payload: ["session_id": "b"])
        // 剩下 a, c, 顺序保留 (a 在 c 前, 因为 a 更早 startedAt)
        #expect(registry.sessions.map(\.id) == ["a", "c"])
    }

    @Test("BG 仍排在 FG 前面,组内按 startedAt asc")
    func backgroundBeforeForegroundWithStartedAt() {
        let registry = SessionRegistry()
        // 制造场景: FG 比 BG 先开 (startedAt 更早), 但 BG 仍应排前面
        registry.upsertFromHook(event: "SessionStart", payload: ["session_id": "fg-old", "cwd": "/p/fg"])
        registry.upsertFromAgentsList([
            ClaudeAgent(
                pid: 1, sessionId: "bg-new", cwd: "/",
                kind: .background, status: .idle, name: "bg-new",
                startedAt: Date()  // 现在,比 fg-old 晚
            )
        ])
        #expect(registry.sessions.map(\.id) == ["bg-new", "fg-old"])
    }
```

- [ ] **Step 2: 跑测试确认新加的 5 个 case 全 RED**

```bash
bash scripts/run-tests.sh 2>&1 | grep -E "startedAt|needsInput|compact" | head -20
```

Expected:
- `backgroundSortedByStartedAtAsc` FAIL — 旧规则 bg-b 更新过会浮顶
- `needsInputDoesNotReorder` FAIL — needsInput 旧规则会优先
- `needsInputDoesNotBumpUpdatedAt` FAIL — markNeedsInput 当前会 bump
- `sessionEndKeepsOthersStable` — 这条可能会因为 `upsertFromHook` 用 `.now` 顺序入,startedAt 自然递增,结果可能 PASS。如果 PASS 就算 bonus,不算 RED 失败
- `backgroundBeforeForegroundWithStartedAt` — 旧规则下也会过(visibleSessions 现有分组),不过应在 `sessions` 属性上也成立

- [ ] **Step 3: 不 commit,接 Task 4**

---

## Task 4: 改 `SessionRegistry` 排序 + 删 needsInput bump

**Files:**
- Modify: `ClaudeStats/Services/Session/SessionRegistry.swift:211-214` (`markNeedsInput`)
- Modify: `ClaudeStats/Services/Session/SessionRegistry.swift:267-270` (`rebuildSorted`)

- [ ] **Step 1: 改 `rebuildSorted` 排序**

把 line 267-270 的:

```swift
        sessions = sessionsById.values.sorted { lhs, rhs in
            if lhs.needsInput != rhs.needsInput { return lhs.needsInput }
            return lhs.updatedAt > rhs.updatedAt
        }
```

替换成:

```swift
        // 段位置稳定化 (spec 2026-05-27):
        // - BG 在 FG 上方 (跟 visibleSessions 的分组规则一致)
        // - 组内按 startedAt 升序: 最早开的在最上, 整个 session 生命周期内
        //   不变 (startedAt 是 let)。needsInput / 状态变化 / hook 涌入
        //   都不影响位置, 只影响该段的颜色。
        sessions = sessionsById.values.sorted { lhs, rhs in
            if (lhs.kind == .background) != (rhs.kind == .background) {
                return lhs.kind == .background
            }
            return lhs.startedAt < rhs.startedAt
        }
```

- [ ] **Step 2: 删 `markNeedsInput` 里的 `updatedAt` bump**

`markNeedsInput` 当前 (line 211-214):

```swift
        if entry.needsInput == needsInput { return }
        entry.needsInput = needsInput
        entry.updatedAt = .now
        sessionsById[sessionId] = entry
```

改成:

```swift
        if entry.needsInput == needsInput { return }
        entry.needsInput = needsInput
        // 排序键已改为 startedAt, 不再需要 bump updatedAt 让 session 浮顶。
        // bump updatedAt 还会污染 overflow 段的 kind 推断 (取 max(updatedAt))。
        sessionsById[sessionId] = entry
```

- [ ] **Step 3: 跑测试确认新加的 5 个 case 全 GREEN,旧测试不回归**

```bash
bash scripts/run-tests.sh 2>&1 | tail -30
```

Expected: 全部 PASS。特别留意已有的 `visibleSessionsBackgroundBeforeForeground` (line 211) 不该回归——它的断言"BG 在 FG 前面"在新规则下依然成立。

- [ ] **Step 4: Commit**

```bash
git add ClaudeStats/Services/Session/SessionRegistry.swift ClaudeStatsTests/SessionRegistryTests.swift
git commit -m "feat(session-registry): 排序改 startedAt asc, 段位置不再因 hook 抖动

排序键从 (needsInput 优先, updatedAt desc) 改成 (BG/FG 分组, startedAt asc):
- startedAt 是 let, session 生命周期内不变 → slot 不漂移
- needsInput / 状态变化 / hook 涌入 → 段颜色变, 位置不变
- BG 仍排在 FG 上方, 跟 visibleSessions 分组规则一致

markNeedsInput 也不再 bump updatedAt: 排序键已经不看它了, bump 还会
污染 TabSegmenter 推断 overflow 段 kind 的 max(updatedAt) 选取。

Trade-off: N > cap (5) 时, 新开的 session 进 overflow 段, 看不到独立色块。
N≤5 是常态。spec docs/superpowers/specs/2026-05-27-tab-position-stability-design.md §3"
```

---

## Task 5: `LiveSessionsList` / `LiveSessionRow` 加行号列

让展开面板每行最左有"1" / "2" / ... / "5+",跟 collapsed tab 段位置一一对应。

**Files:**
- Modify: `ClaudeStats/Views/FloatingStats/FloatingStatsPanelView.swift:279-348` (`LiveSessionsList`) and `350-...` (`LiveSessionRow`)

- [ ] **Step 1: 给 `LiveSessionRow` 加 `rowLabel` 参数**

找到 `LiveSessionRow` (line 350) 的字段块 (line 352-362):

```swift
    let session: LiveSession
    /// When `true`, append a short session-id suffix to the subtitle so the
    /// user can tell apart multiple sessions whose `displayTitle` collides
    /// (e.g. two sessions in the same project folder).
    var showsIdHint: Bool = false
    /// True when this session has a `*→done` transition we haven't shown
    /// to the user yet. Drives the bell icon.
    var isUnreadDone: Bool = false
```

在 `session` 之后(`showsIdHint` 之前)插入:

```swift
    /// "1" / "2" / "5+" 等,展示在行最左,跟 collapsed tab 段位置对齐。
    /// `nil` 时不显示行号列。
    var rowLabel: String?
```

- [ ] **Step 2: 在 `body` 的 HStack 最前面渲染行号**

找到 `LiveSessionRow.body` (line 364) 的 HStack:

```swift
    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(badgeColor)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
```

在 `Circle()` 之前插入:

```swift
            if let rowLabel {
                Text(rowLabel)
                    .font(.sora(9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.stxMuted)
                    .frame(width: 18, alignment: .leading)
                    .accessibilityHidden(true)
            }
```

- [ ] **Step 3: 在 `LiveSessionsList` 里给每行算出 `rowLabel`**

找到 `LiveSessionsList.body` 里的 `ForEach`(line 294-300):

```swift
                ForEach(Array(sessions.prefix(Self.maxVisibleRows)), id: \.id) { session in
                    LiveSessionRow(
                        session: session,
                        showsIdHint: ambiguous.contains(session.displayTitle),
                        isUnreadDone: unreadDoneSessions.contains(session.id)
                    )
                }
                if sessions.count > Self.maxVisibleRows {
                    Text(L10n.format(
                        "floating.tab.sessions.overflow",
                        defaultValue: "+%d more",
                        sessions.count - Self.maxVisibleRows
                    ))
                        .font(.sora(9))
                        .foregroundStyle(Color.stxMuted)
                }
```

替换成:

```swift
                ForEach(Array(sessions.prefix(Self.maxVisibleRows).enumerated()), id: \.element.id) { index, session in
                    LiveSessionRow(
                        session: session,
                        rowLabel: "\(index + 1)",
                        showsIdHint: ambiguous.contains(session.displayTitle),
                        isUnreadDone: unreadDoneSessions.contains(session.id)
                    )
                }
                // overflow: cap-1 之后的 session 全用 "5+" 行号
                // (跟 TabSegmenter 的 overflow 段一一对应),沿用"+%d more"
                // 摘要行不动,但每条 overflow 行也展开成 LiveSessionRow,
                // 否则用户没办法在面板里看到具体哪几个 session 进了 overflow。
                if sessions.count > Self.maxVisibleRows {
                    let overflowLabel = "\(Self.maxVisibleRows)+"
                    ForEach(Array(sessions.dropFirst(Self.maxVisibleRows)), id: \.id) { session in
                        LiveSessionRow(
                            session: session,
                            rowLabel: overflowLabel,
                            showsIdHint: ambiguous.contains(session.displayTitle),
                            isUnreadDone: unreadDoneSessions.contains(session.id)
                        )
                    }
                }
```

注:

- 这里去掉了"+%d more"摘要文字,因为现在 overflow 段对应的 session 直接展开成多行,每行都有"5+"前缀,信息更明确。
- `ambiguous` 计算 (line 317-323) 当前只看 `prefix(maxVisibleRows)`;overflow 行也展开后,理论上 ambiguous 检测要看全体。但这是次要的,**不要在本 PR 里改 `ambiguous` 的范围**——会引入额外的差异,跟稳定化主线无关。保留现在的行为,即只对前 5 行做歧义检测;overflow 行就算同名也不显示 id 提示。如果实际触发,后续 PR 再扩。

但 `ambiguous` 现在依赖 `prefix(maxVisibleRows)`,改后 overflow 行也会调用 `ambiguous.contains(...)`——对 overflow session 这个集合可能误判(集合里没它的 title 时 = false,没事)。不需要改 `ambiguousTitles` 的实现。

- [ ] **Step 4: 跑构建确认编译过**

```bash
bash scripts/run-debug.sh 2>&1 | tail -20
```

Expected: 编译成功,app 启动。如果有 SwiftUI 类型推断的报错(`ForEach` enumerated 容易踩),可能要写成 `ForEach(0..<sessions.prefix(...).count, id: \.self)` 配合 `let session = sessions[index]`。优先用 `enumerated()` + `id: \.element.id` 的形式。

- [ ] **Step 5: 手动 UI 验证**

打开 app 后:

1. 开 1 个 session,展开面板,确认行号列显示 "1"
2. 开 2-3 个 session,展开面板,确认行号 1/2/3 与 collapsed tab 上的段位置一一对应(顶段 = 行 1)
3. 触发一个 PermissionRequest,确认对应 session 行**位置不变**,只是颜色变红、有红脉冲(已有行为)
4. 等一轮 turn 完成,确认对应段保持绿色(Stop 之后)——这一步同时验证 Task 2 的 displayState 修复
5. 让该 session 再发 prompt,确认变蓝(thinking)——验证新一轮的颜色对

如果你能开到 6 个 session(尝试 `claude --bg` 多开),验证 collapsed tab 上是 "前 4 个独立段 + 1 overflow 段","展开面板显示 5 个 '1'-'4' 行 + 2 个 '5+' 行"。

- [ ] **Step 6: Commit**

```bash
git add ClaudeStats/Views/FloatingStats/FloatingStatsPanelView.swift
git commit -m "feat(floating-tab): 展开面板加行号列, 与 collapsed tab 段位置对齐

每行最左加 '1' / '2' / ... / '5+' 行号. overflow 段对应的多条 session
不再折叠成 '+N more' 摘要, 而是展开成多行, 每行行号都是 '5+', 让用户
能从颜色段位置回查到具体哪个 session.

spec docs/superpowers/specs/2026-05-27-tab-position-stability-design.md §4."
```

---

## Task 6: 整体回归检查 + 收尾

- [ ] **Step 1: 跑全部测试**

```bash
bash scripts/run-tests.sh
```

Expected: 全部 PASS。如果有不相关的失败(snapshot drift 等),记录但不强行修——本 PR 范围只覆盖上面的改动。

- [ ] **Step 2: 跑 debug build,做一遍手动 UI 验证 checklist**

```bash
bash scripts/run-debug.sh
```

跟 Task 5 Step 5 的 checklist 一致再过一遍。

- [ ] **Step 3: 如果一切 OK,本 PR 收尾**

到这一步本 plan 完成。下一步交给 finishing-a-development-branch skill 决定 merge / PR / 其它。
