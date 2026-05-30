# Floating Tab Ribbon Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the collapsed floating tab's 80/20 layout (segment stripe + `●N` badge slice) with a 100% segmented ribbon where the overflow segment is visually distinguished by stacked hairlines + a centered `+N` label, plus a thin drag-handle hairline at the trailing end of the bar's long axis.

**Architecture:** Two-file edit. `TabGlowOverlay` loses its `mainAreaFraction` knob and gains: (a) overlay rendering for `isOverflow` segments (hairlines + `+N` text); (b) a single drag-handle hairline in segmented mode. `FloatingStatsPanelView` deletes `CollapsedSessionBadge`, `badgeRegionSize`, `badgeRegionAlignment`, `Metrics.badgeFraction`, drops the `mainAreaFraction` argument, and simplifies `collapsedContent` to a two-branch shape (no-session → centered title; has-session → `Color.clear` placeholder carrying the a11y label).

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, `@Observable`.

**Spec:** `docs/superpowers/specs/2026-05-28-floating-tab-ribbon-redesign-design.md`

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `ClaudeStats/Views/FloatingStats/TabGlowOverlay.swift` | Modify | Strip `mainAreaFraction` + `mainAreaSize`; add overflow-segment overlay rendering; add drag-handle hint in segmented mode |
| `ClaudeStats/Views/FloatingStats/FloatingStatsPanelView.swift` | Modify | Delete `CollapsedSessionBadge`, `badgeRegionSize`, `badgeRegionAlignment`, `Metrics.badgeFraction`; drop `mainAreaFraction` arg; simplify `collapsedContent` to 2-branch with `Color.clear`+a11y |

No new files. No new tests (visual-only — `TabSegmenterTests` already covers the segment aggregation that this work consumes unchanged).

---

## Task 1: Revert the 80/20 infrastructure

**Why first:** The 80/20 layout's two halves (segment area shrink + badge slice render) are tightly coupled — deleting either alone leaves the bar in a broken intermediate state. Land them together so the bar visually becomes "full-height segments, no badge" in one commit. Subsequent tasks then add the overflow visual + drag handle on top of this baseline.

**Files:**
- Modify: `ClaudeStats/Views/FloatingStats/TabGlowOverlay.swift`
- Modify: `ClaudeStats/Views/FloatingStats/FloatingStatsPanelView.swift`

### Step 1: Remove `mainAreaFraction` from `TabGlowOverlay`

In `TabGlowOverlay.swift`:

(a) Delete the stored property (currently lines 31–36, immediately after `let edge: FloatingPanelEdge` and before the `@Environment(\.accessibilityReduceMotion)` line):

```swift
    /// Fraction of the shape's "along-edge" axis (height for left/right,
    /// width for top/bottom) reserved for segment fills + dividers. The
    /// trailing `1 - mainAreaFraction` is left blank so the parent can
    /// host another element there (e.g. a `●N` badge). Default 1.0 — the
    /// fills cover the full shape, preserving today's behaviour.
    var mainAreaFraction: CGFloat = 1.0
```

After deletion, the type's stored members are just `shape` / `segments` / `isExpanded` / `edge` followed directly by `@Environment(\.accessibilityReduceMotion) private var reduceMotion`.

(b) Delete the `mainAreaSize(for:)` helper (currently lines 74–86):

```swift
    /// Shrink the segment-painting area along the "along-edge" axis by
    /// `mainAreaFraction`. The leftover slice (`1 - fraction`) sits at the
    /// trailing end of the bar (bottom for vertical / trailing for
    /// horizontal) — the parent decides what to put there.
    private func mainAreaSize(for total: CGSize) -> CGSize {
        let fraction = max(0, min(1, mainAreaFraction))
        switch edge {
        case .left, .right:
            return CGSize(width: total.width, height: total.height * fraction)
        case .top, .bottom:
            return CGSize(width: total.width * fraction, height: total.height)
        }
    }
```

(c) Simplify `segmentedBody` (currently around line 52) so `TabSegmenter.rects(...)` is called with `proxy.size` directly:

```swift
    private var segmentedBody: some View {
        let hasAnyNeedsInput = segments.contains(where: \.needsInput)
        let specs = segments.map { segment in
            specFor(segment: segment, hasAnyNeedsInput: hasAnyNeedsInput)
        }
        let anyPulses = specs.contains(where: \.pulses)
        return GeometryReader { proxy in
            let rects = TabSegmenter.rects(
                in: proxy.size,
                count: segments.count,
                edge: edge
            )
            TimelineView(.animation(paused: !anyPulses)) { context in
                renderedTab(specs: specs, rects: rects, size: proxy.size, now: context.date)
            }
        }
        .animation(.easeOut(duration: 0.25), value: segments)
        .animation(.easeOut(duration: 0.3), value: isExpanded)
        .allowsHitTesting(false)
    }
```

(`renderedTab` and `segmentFill` keep their existing signatures — they were unchanged when `mainAreaFraction` was introduced and remain unchanged now.)

### Step 2: Drop `mainAreaFraction` arg + `Metrics.badgeFraction`

In `FloatingStatsPanelView.swift`:

(a) The `panelSurface` body calls `TabGlowOverlay` (around line 63). Change the `.overlay(...)` call so it drops the `mainAreaFraction:` argument. The whole call becomes:

```swift
        .overlay(
            TabGlowOverlay(
                shape: shape,
                segments: TabSegmenter.segments(from: sessions, cap: cap),
                isExpanded: state.isExpanded,
                edge: edge
            )
        )
```

(b) In the `private enum Metrics` block at the bottom of `FloatingStatsPanelView` (currently around lines 273–280), delete the `badgeFraction` entry + its doc comment so only `collapsedContentPadding` remains:

```swift
    private enum Metrics {
        static let collapsedContentPadding: CGFloat = 8
    }
```

### Step 3: Delete `CollapsedSessionBadge`, `badgeRegionSize`, `badgeRegionAlignment`

In `FloatingStatsPanelView.swift`:

(a) Delete the entire `CollapsedSessionBadge` struct (currently around lines 283–313, starting with `/// Tiny pill the collapsed tab shows when at least one session is tracked.` and ending with the closing `}` of the struct). Everything from the doc comment through the last `}` goes.

(b) Delete `badgeRegionSize(in:edge:)` (currently around lines 108–117) and `badgeRegionAlignment(for:)` (currently around lines 119–124). Both are private methods of `FloatingStatsPanelView`; delete them and their preceding doc comment.

### Step 4: Simplify `collapsedContent` to two branches

In `FloatingStatsPanelView.swift`, replace the entire body of `collapsedContent(edge:size:)` (currently around lines 77–106) with this version:

```swift
    private func collapsedContent(edge: FloatingPanelEdge, size: CGSize) -> some View {
        let sessions = env.sessionRegistry.visibleSessions
        let title = L10n.string("floating.tab.title", defaultValue: "Claude agents")
        return Group {
            if sessions.isEmpty {
                if edge.isVertical {
                    sideCollapsedTitle(title, edge: edge, size: size)
                } else {
                    horizontalCollapsedTitle(title)
                }
            } else {
                // 折叠条本身(被 TabGlowOverlay 绘制)就是内容。
                // collapsedContent 这一层不再叠任何文字 / badge / hint —— drag
                // handle hint 由 TabGlowOverlay 自己画。Color.clear 占位承载
                // a11y label, 让 VoiceOver 仍能朗读会话总数 + 最高优先级状态。
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

`sessions.dominantBadge` is an `Optional<LiveSession.Badge>`; when `nil` we fall back to the string `"idle"` for the a11y label.

### Step 5: Run tests + smoke verify

Run:
```bash
bash scripts/run-tests.sh
```

Expected: build clean, 335 tests still pass (no test changes in this task; the deleted code had no unit tests, and `TabSegmenterTests` is unaffected because `TabSegmenter.rects` is called identically with the full `proxy.size`).

Then:
```bash
bash scripts/run-debug.sh
```

In the running app, with at least one active Claude session:

1. Floating tab on screen — collapsed bar now shows segment fills covering the **full height** of the bar (no longer reserved trailing 20% for the badge).
2. The `●N` badge is **gone**. The segment stripe is the only visible content in the bar.
3. The expanded SESSIONS list (hover the tab) still works and shows the rowLabel "5+" etc. for overflow rows — that path is untouched.
4. With **no** active sessions, the bar shows the centered "Claude agents" title (across the full bar) just like before. No 80/20 split.

Note: at this commit the overflow segment **still looks identical to other segments** — that's expected and gets fixed in Task 2. This intermediate state is acceptable for a commit because the bar is internally consistent (all segments treated equally) and the spec's other constraints are met.

### Step 6: Commit

```bash
git add ClaudeStats/Views/FloatingStats/TabGlowOverlay.swift \
        ClaudeStats/Views/FloatingStats/FloatingStatsPanelView.swift
git commit -m "refactor(floating-tab): drop 80/20 layout, restore full-height segment ribbon

- TabGlowOverlay: delete mainAreaFraction param + mainAreaSize() helper;
  segmentedBody calls TabSegmenter.rects with proxy.size directly.
- FloatingStatsPanelView: delete CollapsedSessionBadge, badgeRegionSize,
  badgeRegionAlignment, Metrics.badgeFraction; drop mainAreaFraction arg
  from the TabGlowOverlay overlay; collapsedContent becomes a 2-branch
  shape (empty -> centered title; non-empty -> Color.clear placeholder
  with a11y label, segments shown by TabGlowOverlay underneath).

Overflow segment visual differentiation + drag handle hint land in the
next two commits."
```

---

## Task 2: Overflow segment overlay (hairlines + `+N` label)

**Why:** Spec §1a — make `isOverflow == true` segments visually distinct from independent segments. After Task 1 they all paint identically.

**Files:**
- Modify: `ClaudeStats/Views/FloatingStats/TabGlowOverlay.swift`

### Step 1: Extend `renderedTab` with an overflow-overlay layer

In `TabGlowOverlay.swift`, `renderedTab(specs:rects:size:now:)` (currently around line 100). After the existing segment-fill `ForEach` (which is clipped to the shape) and before the border + dividers, add a new `ForEach` that paints the overflow overlay for any segment whose `TabSegment.isOverflow == true`. The whole edited function:

```swift
    private func renderedTab(specs: [TabFillSpec], rects: [CGRect], size: CGSize, now: Date) -> some View {
        ZStack {
            // N 段填充, mask 到外层 shape 让圆角自然继承
            ForEach(0..<specs.count, id: \.self) { i in
                segmentFill(spec: specs[i], rect: rects[i], now: now)
            }
            .clipShape(shape)

            // Overflow 段叠加层: 水平/竖向 hairlines + 居中 +N 字样, 让聚合
            // 段视觉上跟独立段拉开差距。spec 2026-05-28 §1a。
            ForEach(0..<segments.count, id: \.self) { i in
                if segments[i].isOverflow {
                    overflowOverlay(segment: segments[i], rect: rects[i])
                }
            }
            .clipShape(shape)

            // 边框 — 跟"最显眼"的段一致 (优先 needsInput 段, 否则第 1 段)
            let borderSpec = specs.first(where: \.pulses) ?? specs.first ?? .dormant
            shape
                .stroke(borderSpec.borderColor, lineWidth: borderSpec.borderWidth)

            // 段间分割线, N-1 条; spec §3.7
            ForEach(1..<rects.count, id: \.self) { i in
                dividerLine(at: rects[i].origin, in: size)
            }
        }
    }
```

### Step 2: Add the `overflowOverlay` helper

Still in `TabGlowOverlay.swift`, add this new helper right after `segmentFill(spec:rect:now:)` (which is around line 121–139):

```swift
    /// Visual differentiation for an aggregated overflow segment:
    /// (A) `min(overflowCount + 1, 4)` hairlines spanning the cross axis,
    ///     evenly spaced along the along-edge axis — like multiple sheets
    ///     of paper stacked together; (B) a centered "+N" monospace label
    ///     telling the viewer how many sessions are aggregated here.
    /// spec 2026-05-28 §1a。
    @ViewBuilder
    private func overflowOverlay(segment: TabSegment, rect: CGRect) -> some View {
        let lineCount = min(segment.overflowCount + 1, 4)
        let labelFontSize: CGFloat = edge.isVertical ? 8 : 9
        ZStack {
            // (A) hairlines: 竖边时沿 height 均分(线是水平的); 横边时沿
            // width 均分(线是竖直的)。颜色 Color.black.opacity(0.18)。
            ForEach(0..<lineCount, id: \.self) { i in
                let t = CGFloat(i + 1) / CGFloat(lineCount + 1)
                switch edge {
                case .left, .right:
                    Rectangle()
                        .fill(Color.black.opacity(0.18))
                        .frame(width: rect.size.width, height: 0.5)
                        .position(x: rect.midX, y: rect.minY + rect.height * t)
                case .top, .bottom:
                    Rectangle()
                        .fill(Color.black.opacity(0.18))
                        .frame(width: 0.5, height: rect.size.height)
                        .position(x: rect.minX + rect.width * t, y: rect.midY)
                }
            }
            // (B) +N 字样
            Text("+\(segment.overflowCount)")
                .font(.sora(labelFontSize, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.95))
                .shadow(color: Color.black.opacity(0.6), radius: 1, y: 1)
                .position(x: rect.midX, y: rect.midY)
        }
    }
```

`TabSegment` already exposes `isOverflow: Bool` and `overflowCount: Int` (`Views/FloatingStats/TabSegment.swift:13-15`), so no model change is needed.

### Step 3: Build + visually verify

Run:
```bash
bash scripts/run-tests.sh
```

Expected: clean build, 335 tests still pass.

Run:
```bash
bash scripts/run-debug.sh
```

In the running app:

1. With **5 or fewer** active sessions (cap defaults to 5) — no overflow segment is produced by `TabSegmenter.segments(from:cap:)`, so no overlay is drawn. The bar looks like Task 1's output.
2. Settings → Floating Tab → set cap = **3**. Spin up 5 active sessions (or wait until the existing ones do). The collapsed bar shows 3 segments. The 3rd segment (overflow) shows:
   - 3 thin horizontal lines spanning the segment width (`min(2 + 1, 4) = 3`),
   - a centered "+2" text label in white with a black shadow.
3. Set cap = **3**, spin up 10 active sessions. The 3rd segment now shows:
   - 4 thin horizontal lines (`min(7 + 1, 4) = 4`, capped),
   - a centered "+7" text label.
4. Drag the tab to the **top** edge (horizontal layout). The overflow segment's hairlines are now **vertical** (sliced along the width) and the "+N" text is slightly larger (9pt instead of 8pt).
5. needsInput on a session inside the overflow region — the overflow segment's base color shifts to its overflow-region `displayState` (unchanged from before this task), the hairlines + "+N" remain readable on top.

### Step 4: Commit

```bash
git add ClaudeStats/Views/FloatingStats/TabGlowOverlay.swift
git commit -m "feat(floating-tab): overflow segment shows stacked hairlines + +N label

TabGlowOverlay.renderedTab gains a new ForEach pass that paints two
visual layers for every TabSegment whose isOverflow == true: (A) up to
4 thin black hairlines spanning the segment's cross axis, evenly spaced
along the long axis — reads as 'multiple sheets stacked together';
(B) a centered '+N' monospace label (8pt on vertical edges, 9pt on
horizontal) in white with a soft black shadow so it stays legible on
any segment color.

Without these, an aggregated overflow segment was indistinguishable
from an independent segment, defeating the cap mechanism's visual
signal."
```

---

## Task 3: Drag handle hint inside `TabGlowOverlay` segmented branch

**Why:** Spec §1b — give the bar a visible drag affordance now that the only painted content (when sessions exist) is the segment stripe. Today the bar is draggable via the invisible `FloatingDragHandle` NSView, but visually nothing hints at this.

**Files:**
- Modify: `ClaudeStats/Views/FloatingStats/TabGlowOverlay.swift`

### Step 1: Extend `renderedTab` with the drag-handle hairline

In `TabGlowOverlay.swift`, after the segment dividers (the last `ForEach` inside the `ZStack` in `renderedTab`), add a single `dragHandleHint(in: size)` call. The final edited function:

```swift
    private func renderedTab(specs: [TabFillSpec], rects: [CGRect], size: CGSize, now: Date) -> some View {
        ZStack {
            // N 段填充, mask 到外层 shape 让圆角自然继承
            ForEach(0..<specs.count, id: \.self) { i in
                segmentFill(spec: specs[i], rect: rects[i], now: now)
            }
            .clipShape(shape)

            // Overflow 段叠加层: hairlines + +N
            ForEach(0..<segments.count, id: \.self) { i in
                if segments[i].isOverflow {
                    overflowOverlay(segment: segments[i], rect: rects[i])
                }
            }
            .clipShape(shape)

            // 边框 — 跟"最显眼"的段一致 (优先 needsInput 段, 否则第 1 段)
            let borderSpec = specs.first(where: \.pulses) ?? specs.first ?? .dormant
            shape
                .stroke(borderSpec.borderColor, lineWidth: borderSpec.borderWidth)

            // 段间分割线, N-1 条; spec §3.7
            ForEach(1..<rects.count, id: \.self) { i in
                dividerLine(at: rects[i].origin, in: size)
            }

            // 拖拽提示 hairline (segmented 模式专属, 跟段填充在同一层 clip)
            dragHandleHint(in: size)
        }
    }
```

### Step 2: Add the `dragHandleHint` helper

Add this private helper right after `dividerLine(at:in:)` (currently around line 142–155):

```swift
    /// A single thin hairline near the "trailing" end of the bar's long
    /// axis — top for vertical edges, far-from-screen end for horizontal
    /// edges — signaling that the bar is draggable. Painted inside the
    /// segmented branch only, on top of the segment fills.
    /// spec 2026-05-28 §1b。
    @ViewBuilder
    private func dragHandleHint(in size: CGSize) -> some View {
        let insetFromEdge: CGFloat = 4
        switch edge {
        case .left, .right:
            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(width: size.width * 0.5, height: 0.5)
                .position(x: size.width / 2, y: insetFromEdge)
        case .top:
            // top dock: bar 顶贴屏幕顶 -> "trailing end" 是 bar 底
            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(width: 0.5, height: size.height * 0.5)
                .position(x: size.width - insetFromEdge, y: size.height / 2)
        case .bottom:
            // bottom dock: bar 底贴屏幕底 -> "trailing end" 是 bar 顶
            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(width: 0.5, height: size.height * 0.5)
                .position(x: insetFromEdge, y: size.height / 2)
        }
    }
```

### Step 3: Build + visually verify

Run:
```bash
bash scripts/run-tests.sh
```

Expected: clean build, 335 tests still pass.

Run:
```bash
bash scripts/run-debug.sh
```

In the running app, with at least one active Claude session:

1. **Right edge** (default) — a thin white horizontal hairline appears near the **top** of the bar, ≈ half the bar's width, centered. Visible against the segment fill below.
2. **Left edge** (drag the tab there) — same hint, still at the **top**.
3. **Top edge** (drag there) — a thin vertical hairline appears at the bar's **right-most** position (the end farthest from the screen edge), ≈ half the bar's height, centered.
4. **Bottom edge** (drag there) — vertical hairline at the bar's **left-most** position.
5. **No sessions** — the bar's dormant branch fires (just a stroked border); the drag handle hint is NOT drawn (it's only in `segmentedBody → renderedTab`). Title still centered as before.

### Step 4: Commit

```bash
git add ClaudeStats/Views/FloatingStats/TabGlowOverlay.swift
git commit -m "feat(floating-tab): drag handle hint inside segmented overlay

A single 0.5pt white hairline at the 'trailing end' of the bar's long
axis (top for left/right docks, far-from-screen end for top/bottom
docks) signals that the bar is draggable. Painted inside the segmented
branch only, on top of segment fills; dormant mode (no sessions) keeps
the bare-stroked-border look so the centered title stays unobstructed."
```

---

## Spec coverage check

| Spec §Design item | Task |
|---|---|
| §1a Overflow segment hairlines + `+N` overlay | Task 2 |
| §1b Drag handle hairline in segmented mode | Task 3 |
| §2 `collapsedContent` simplified to 2 branches with `Color.clear`+a11y | Task 1 step 4 |
| §3 Delete `CollapsedSessionBadge` | Task 1 step 3 |
| §3 Delete `badgeRegionSize` / `badgeRegionAlignment` | Task 1 step 3 |
| §3 Delete `Metrics.badgeFraction` | Task 1 step 2 |
| §3 Delete `TabGlowOverlay.mainAreaFraction` + `mainAreaSize` | Task 1 step 1 |
| §3 Drop `mainAreaFraction` arg in `panelSurface` | Task 1 step 2 |
| §4 A11y label moved onto `Color.clear` placeholder | Task 1 step 4 |
