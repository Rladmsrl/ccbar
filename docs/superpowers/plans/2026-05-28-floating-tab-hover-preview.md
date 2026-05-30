# Floating Tab Hover Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the floating tab's "list-of-all-sessions" hover panel with a per-segment "deep preview + Focus jump" experience: hover on segment N → tab expands showing session N's status / activity / recent-event timeline / Focus button; overflow segment → a mini list of aggregated sessions.

**Architecture:** Four additive new views (RecentEvent.humanized extension, SingleSessionPreview, OverflowSessionList, SegmentHoverTracker) + one integration commit that rewrites `FloatingStatsPanelView.expandedContent` as a dispatcher (permission > hovered-single > hovered-overflow), wires `SegmentHoverTracker` as a new overlay above `TabGlowOverlay`, threads `hoveredSegmentIndex` through `FloatingStatsPanelState`, and deletes the obsolete `LiveSessionsList` / `LiveSessionRow` / `AgentsSyncStatusView` and their helpers. The existing `FloatingHoverTracker` and controller-side collapse-task logic continue to drive expand/collapse; the new tracker just adds segment-precise state.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, `@Observable`, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-05-28-floating-tab-hover-preview-design.md`

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `ClaudeStats/Models/Session/LiveSession.swift` | Modify (append) | Add `extension LiveSession.RecentEvent { var humanized: String }` |
| `ClaudeStatsTests/RecentEventHumanizationTests.swift` | Create | Unit tests for the humanization mapping |
| `ClaudeStats/Views/FloatingStats/FloatingStatsPanelState.swift` | Modify | Add `var hoveredSegmentIndex: Int?` |
| `ClaudeStats/Views/FloatingStats/SingleSessionPreview.swift` | Create | Single-session deep preview view (header + activity line + RECENT timeline + Focus button) |
| `ClaudeStats/Views/FloatingStats/OverflowSessionList.swift` | Create | Mini list view for the overflow segment (N rows, each with status + Focus) |
| `ClaudeStats/Views/FloatingStats/SegmentHoverTracker.swift` | Create | Transparent SwiftUI overlay that reports which segment the cursor is over; degrades to a single tracking Rectangle in expanded mode |
| `ClaudeStats/Views/FloatingStats/FloatingStatsPanelView.swift` | Modify | Rewrite `expandedContent(cap:)` as the new dispatcher; mount `SegmentHoverTracker`; thread `onSegmentHoverChange` callback through init; **delete** `LiveSessionsList`, `LiveSessionRow`, `AgentsSyncStatusView`, `expandedHeader`, `animatedExpandedSection`, `expandedSectionAnimation`, `ClaudeAgentsService.AgentAction.helpText` extension |
| `ClaudeStats/Views/FloatingStats/FloatingStatsPanelController.swift` | Modify | Add `handleSegmentHover(_:)` that writes to `state.hoveredSegmentIndex`; clear `hoveredSegmentIndex` when the panel collapses; pass new callback when constructing the SwiftUI root view |

No new dependencies. No new Preferences. No Localizable.xcstrings entries beyond what the new views display in English; existing `floating.tab.session.foreground` / `.background` / `.headless` keys are reused (their callers move from `LiveSessionRow` to the new previews).

---

## Task 1: `LiveSession.RecentEvent.humanized` extension + tests

**Why first:** Pure data mapping, fully unit-testable. Locks the event-name → human-readable string contract that both new views consume.

**Files:**
- Modify: `ClaudeStats/Models/Session/LiveSession.swift`
- Create: `ClaudeStatsTests/RecentEventHumanizationTests.swift`

### Step 1: Write the failing tests

Create `ClaudeStatsTests/RecentEventHumanizationTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeStats

@Suite("LiveSession.RecentEvent.humanized")
struct RecentEventHumanizationTests {

    @Test("Known events map to fixed human-readable strings")
    func knownEventsAreHumanized() {
        let cases: [(String, String)] = [
            ("UserPromptSubmit",   "Prompt submitted"),
            ("PreToolUse",         "Running tool"),
            ("PostToolUse",        "Tool done"),
            ("PostToolUseFailure", "Tool failed"),
            ("SubagentStart",      "Subagent started"),
            ("SubagentStop",       "Subagent done"),
            ("Stop",               "Turn finished"),
            ("StopFailure",        "Turn interrupted"),
            ("Notification",       "Notification"),
            ("PreCompact",         "Compacting…"),
            ("PostCompact",        "Compacted"),
            ("SessionStart",       "Session started"),
            ("SessionEnd",         "Session ended"),
        ]
        for (event, expected) in cases {
            let recent = LiveSession.RecentEvent(event: event, at: .now)
            #expect(recent.humanized == expected,
                    "event=\(event) expected=\(expected) got=\(recent.humanized)")
        }
    }

    @Test("Unknown event names fall through to the raw string")
    func unknownEventsFallThrough() {
        let recent = LiveSession.RecentEvent(event: "SomeFutureHook", at: .now)
        #expect(recent.humanized == "SomeFutureHook")
    }

    @Test("Empty event name falls through to empty string")
    func emptyEventFallsThrough() {
        let recent = LiveSession.RecentEvent(event: "", at: .now)
        #expect(recent.humanized == "")
    }
}
```

### Step 2: Run tests to verify they fail

Run:
```bash
bash scripts/run-tests.sh
```

Expected: build fails — `Value of type 'LiveSession.RecentEvent' has no member 'humanized'`. That's the missing-symbol failure; proceed.

### Step 3: Implement the extension

In `ClaudeStats/Models/Session/LiveSession.swift`, append to the **bottom of the file** (after all existing extensions):

```swift
extension LiveSession.RecentEvent {
    /// Human-readable label for the hook event name. Used by the floating
    /// tab's hover preview to render a session's recent activity timeline
    /// without showing raw CC hook names like "PreToolUse".
    ///
    /// Tool-specific detail (which tool, which file) is intentionally NOT
    /// surfaced — `RecentEvent` only stores the event name + timestamp,
    /// not the payload. If a future change starts capturing the tool name,
    /// the `PreToolUse` branch can be enriched with it.
    var humanized: String {
        switch event {
        case "UserPromptSubmit":   return "Prompt submitted"
        case "PreToolUse":         return "Running tool"
        case "PostToolUse":        return "Tool done"
        case "PostToolUseFailure": return "Tool failed"
        case "SubagentStart":      return "Subagent started"
        case "SubagentStop":       return "Subagent done"
        case "Stop":               return "Turn finished"
        case "StopFailure":        return "Turn interrupted"
        case "Notification":       return "Notification"
        case "PreCompact":         return "Compacting…"
        case "PostCompact":        return "Compacted"
        case "SessionStart":       return "Session started"
        case "SessionEnd":         return "Session ended"
        default:                   return event
        }
    }
}
```

### Step 4: Run tests, confirm pass

Run:
```bash
bash scripts/run-tests.sh
```

Expected: all 3 new tests PASS; existing 335 tests still PASS (total 338).

### Step 5: Commit

```bash
git add ClaudeStats/Models/Session/LiveSession.swift \
        ClaudeStatsTests/RecentEventHumanizationTests.swift
git commit -m "feat(session): RecentEvent.humanized for hover preview timeline"
```

---

## Task 2: `SingleSessionPreview` view (additive)

**Why next:** A pure rendering view. Builds on Task 1's `humanized`. Has no integration; can be eye-balled via `#Preview` without touching the floating tab path.

**Files:**
- Create: `ClaudeStats/Views/FloatingStats/SingleSessionPreview.swift`

### Step 1: Create the file

Create `ClaudeStats/Views/FloatingStats/SingleSessionPreview.swift` with exactly:

```swift
import SwiftUI

/// Deep preview for a single Claude session, rendered inside the floating
/// tab's expanded panel when the user is hovering an independent segment.
///
/// Layout (top-down, see spec 2026-05-28-floating-tab-hover-preview-design §4):
///   header — colored status dot + displayTitle + kind chip (FG/BG/HL)
///   activity line — "Working · <last event humanized>"
///   RECENT divider + 3 most recent events with timestamps
///   Focus button (bottom right)
///
/// The status dot's color comes from `TabFillSpec.spec(for:)` so it matches
/// the tab's segment color exactly (single source of truth for state→color).
struct SingleSessionPreview: View {
    @Environment(AppEnvironment.self) private var env
    let session: LiveSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            activityLine
            recentSection
            Spacer(minLength: 0)
            focusButton
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Circle()
                .fill(TabFillSpec.spec(for: session.displayState).color)
                .frame(width: 9, height: 9)
            Text(session.displayTitle)
                .font(.sora(15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            kindChip
        }
    }

    private var kindChip: some View {
        Text(kindLabel)
            .font(.sora(8, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Color.stxMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private var kindLabel: String {
        switch session.kind {
        case .foreground: return L10n.string("floating.tab.session.foreground", defaultValue: "FG").uppercased()
        case .background: return L10n.string("floating.tab.session.background", defaultValue: "BG").uppercased()
        case .headless:   return L10n.string("floating.tab.session.headless",   defaultValue: "HL").uppercased()
        }
    }

    private var activityLine: some View {
        HStack(spacing: 6) {
            Text(stateVerb)
                .font(.sora(12, weight: .medium))
                .foregroundStyle(.primary)
            if let recent = session.recentEvents.last {
                Text("·")
                    .font(.sora(12))
                    .foregroundStyle(Color.stxMuted)
                Text(recent.humanized)
                    .font(.sora(12))
                    .foregroundStyle(Color.stxMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var stateVerb: String {
        switch session.displayState {
        case .idle:      return "Idle"
        case .thinking:  return "Thinking"
        case .working:   return "Working"
        case .juggling:  return "Juggling"
        case .attention: return "Attention"
        case .sweeping:  return "Compacting"
        case .error:     return "Error"
        case .sleeping:  return "Ended"
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("RECENT")
                    .font(.sora(9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color.stxMuted)
                Spacer(minLength: 6)
                Text(Format.relativeDate(session.updatedAt))
                    .font(.sora(9).monospacedDigit())
                    .foregroundStyle(Color.stxMuted)
            }
            if session.recentEvents.isEmpty {
                Text("No recent activity")
                    .font(.sora(10))
                    .foregroundStyle(Color.stxMuted)
            } else {
                ForEach(Array(session.recentEvents.suffix(3).reversed().enumerated()), id: \.offset) { _, ev in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Format.shortTime(ev.at))
                            .font(.sora(10).monospacedDigit())
                            .foregroundStyle(Color.stxMuted)
                            .frame(width: 44, alignment: .leading)
                        Text(ev.humanized)
                            .font(.sora(11))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
    }

    private var focusButton: some View {
        HStack {
            Spacer()
            Button {
                Task { await focus() }
            } label: {
                HStack(spacing: 4) {
                    Text("Focus")
                        .font(.sora(12, weight: .medium))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(canFocus ? Color.stxAccent : Color.stxMuted)
            .disabled(!canFocus)
            .help(canFocus ? "Focus this session's terminal tab" : "No terminal to focus")
        }
    }

    private var canFocus: Bool {
        session.sourcePid != nil && session.kind != .background
    }

    private func focus() async {
        let result = await env.sessionFocus.focus(session: session)
        if case .failure(let error) = result {
            Log.session.error("focus failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

#if DEBUG
#Preview {
    let now = Date.now
    let session = LiveSession(
        id: "preview-001",
        displayTitle: "claude-stats",
        cwd: "/Users/dev/projects/claude-stats",
        kind: .foreground,
        state: .working,
        needsInput: false,
        sourcePid: 1234,
        startedAt: now.addingTimeInterval(-3600),
        updatedAt: now,
        lastEvent: "PreToolUse",
        recentEvents: [
            .init(event: "Bash", at: now.addingTimeInterval(-180)),
            .init(event: "Edit", at: now.addingTimeInterval(-90)),
            .init(event: "PreToolUse", at: now.addingTimeInterval(-10)),
        ]
    )
    return SingleSessionPreview(session: session)
        .environment(AppEnvironment.preview())
        .frame(width: 320, height: 280)
        .background(Color.stxBackground)
}
#endif
```

`Format.relativeDate(_:)` and `Format.shortTime(_:)` are existing helpers used elsewhere in the project; if `shortTime` doesn't exist, the implementer can substitute with `DateFormatter()` configured for `.short` time style — but check first because it likely does.

### Step 2: Build and verify Preview

Run:
```bash
bash scripts/run-tests.sh
```

Expected: build clean, 338 tests still pass (Task 1's 3 + the prior 335).

If `Format.shortTime` doesn't exist, the implementer should add it as a tiny extension or use:
```swift
private static let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
}()
```
and call `Self.timeFormatter.string(from: ev.at)` instead.

(Optional, only if running with a UI present) Open `SingleSessionPreview.swift` in Xcode and toggle the canvas preview to eyeball the layout. If running headless, skip.

### Step 3: Commit

```bash
git add ClaudeStats/Views/FloatingStats/SingleSessionPreview.swift
git commit -m "feat(floating-tab): SingleSessionPreview view (no integration yet)"
```

---

## Task 3: `OverflowSessionList` view (additive)

**Files:**
- Create: `ClaudeStats/Views/FloatingStats/OverflowSessionList.swift`

### Step 1: Create the file

Create `ClaudeStats/Views/FloatingStats/OverflowSessionList.swift` with exactly:

```swift
import SwiftUI

/// Mini list view for the floating tab's overflow segment hover preview.
/// Shows the N sessions aggregated into that segment, each as a compact
/// row with status + Focus button. Used in place of `SingleSessionPreview`
/// when the user hovers the overflow segment instead of an independent one.
///
/// `sessions` is the slice that `TabSegmenter` aggregated into the overflow
/// segment — typically `visibleSessions.suffix(from: cap - 1)`.
struct OverflowSessionList: View {
    @Environment(AppEnvironment.self) private var env
    let sessions: [LiveSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        OverflowSessionRow(session: session)
                        if index < sessions.count - 1 {
                            Rectangle()
                                .fill(Color.stxStroke.opacity(0.4))
                                .frame(height: 1)
                                .padding(.vertical, 4)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(sessions.count) SESSIONS · OVERFLOW")
                .font(.sora(9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Color.stxMuted)
            Spacer(minLength: 6)
        }
    }
}

/// Single row inside `OverflowSessionList`. Mirrors `SingleSessionPreview`'s
/// header row but compressed; intentionally NOT exposed (private to the
/// overflow list).
private struct OverflowSessionRow: View {
    @Environment(AppEnvironment.self) private var env
    let session: LiveSession

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(TabFillSpec.spec(for: session.displayState).color)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayTitle)
                    .font(.sora(11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(stateVerb) · \(Format.relativeDate(session.updatedAt))")
                    .font(.sora(9).monospacedDigit())
                    .foregroundStyle(Color.stxMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if canFocus {
                Button {
                    Task { await focus() }
                } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.stxAccent)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Focus this session's terminal tab")
            }
        }
        .padding(.vertical, 4)
    }

    private var stateVerb: String {
        switch session.displayState {
        case .idle:      return "Idle"
        case .thinking:  return "Thinking"
        case .working:   return "Working"
        case .juggling:  return "Juggling"
        case .attention: return "Attention"
        case .sweeping:  return "Compacting"
        case .error:     return "Error"
        case .sleeping:  return "Ended"
        }
    }

    private var canFocus: Bool {
        session.sourcePid != nil && session.kind != .background
    }

    private func focus() async {
        let result = await env.sessionFocus.focus(session: session)
        if case .failure(let error) = result {
            Log.session.error("focus failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

#if DEBUG
#Preview {
    let now = Date.now
    let sessions: [LiveSession] = [
        LiveSession(id: "ov-1", displayTitle: "another-project",
                    kind: .foreground, state: .working, sourcePid: 1000,
                    startedAt: now, updatedAt: now.addingTimeInterval(-60),
                    lastEvent: "PreToolUse"),
        LiveSession(id: "ov-2", displayTitle: "test-runner",
                    kind: .foreground, state: .idle, sourcePid: 1001,
                    startedAt: now, updatedAt: now.addingTimeInterval(-180),
                    lastEvent: "Stop"),
        LiveSession(id: "ov-3", displayTitle: "bg-worker",
                    kind: .background, state: .working,
                    startedAt: now, updatedAt: now.addingTimeInterval(-30),
                    lastEvent: "PreToolUse"),
    ]
    return OverflowSessionList(sessions: sessions)
        .environment(AppEnvironment.preview())
        .frame(width: 320, height: 280)
        .background(Color.stxBackground)
}
#endif
```

The `stateVerb` and `canFocus` computed properties duplicate `SingleSessionPreview`'s — that's intentional. Two callers, no shared helper extracted (YAGNI; the alternative is adding a `LiveSession` extension exclusively used by these two views, which is more files for negligible savings).

### Step 2: Build

Run:
```bash
bash scripts/run-tests.sh
```

Expected: clean build, 338 tests pass.

### Step 3: Commit

```bash
git add ClaudeStats/Views/FloatingStats/OverflowSessionList.swift
git commit -m "feat(floating-tab): OverflowSessionList view (no integration yet)"
```

---

## Task 4: `SegmentHoverTracker` view (additive)

**Why:** The transparent hit-test layer that converts cursor position over a segment-shaped rect into an `Int?` callback. Independent from the panel view it'll eventually attach to.

**Files:**
- Create: `ClaudeStats/Views/FloatingStats/SegmentHoverTracker.swift`

### Step 1: Create the file

Create `ClaudeStats/Views/FloatingStats/SegmentHoverTracker.swift` with exactly:

```swift
import SwiftUI

/// Transparent SwiftUI overlay that turns mouse position into a segment
/// index. Used by the floating tab to drive `hoveredSegmentIndex` so the
/// expanded panel can show the right session's preview.
///
/// Two modes:
/// - Collapsed (`isExpanded == false`): N segment-shaped `Color.clear`
///   rects, each with `.onHover` reporting that segment's index when
///   entered and `nil` when exited.
/// - Expanded (`isExpanded == true`): a single full-panel rect that only
///   fires `onSegmentHover(nil)` when the cursor leaves the panel entirely.
///   Inner-panel movement does not change `hoveredSegmentIndex` — spec
///   forbids mid-stream session switching.
///
/// See spec 2026-05-28-floating-tab-hover-preview-design §1, §6.
struct SegmentHoverTracker: View {
    let segments: [TabSegment]
    let edge: FloatingPanelEdge
    let isExpanded: Bool
    var onSegmentHover: (Int?) -> Void

    var body: some View {
        GeometryReader { proxy in
            if isExpanded {
                Color.clear
                    .contentShape(Rectangle())
                    .onHover { isOver in
                        if !isOver { onSegmentHover(nil) }
                        // isOver == true 时不回调; hoveredSegmentIndex 在
                        // collapsed → expanded 转换之前已设好, 保留不动。
                    }
            } else {
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
        .allowsHitTesting(true)
    }
}
```

This view has no consumer yet — Task 5 mounts it.

### Step 2: Build

Run:
```bash
bash scripts/run-tests.sh
```

Expected: clean build, 338 tests pass.

### Step 3: Commit

```bash
git add ClaudeStats/Views/FloatingStats/SegmentHoverTracker.swift
git commit -m "feat(floating-tab): SegmentHoverTracker (no consumer yet)"
```

---

## Task 5: Integration — wire state, controller, view; delete old code

**This is the big integration commit.** It rewires the panel's expanded content to dispatch through `hoveredSegmentIndex`, mounts `SegmentHoverTracker`, hooks up the controller-side hover handler, and deletes the now-orphaned `LiveSessionsList` / `LiveSessionRow` / `AgentsSyncStatusView` plus their helpers.

**Files:**
- Modify: `ClaudeStats/Views/FloatingStats/FloatingStatsPanelState.swift`
- Modify: `ClaudeStats/Views/FloatingStats/FloatingStatsPanelController.swift`
- Modify: `ClaudeStats/Views/FloatingStats/FloatingStatsPanelView.swift`

### Step 1: Add `hoveredSegmentIndex` to state

In `FloatingStatsPanelState.swift`, append a new property to the `@Observable` class so the file becomes:

```swift
import CoreGraphics
import Observation

@MainActor
@Observable
final class FloatingStatsPanelState {
    var edge: FloatingPanelEdge = .right
    var isExpanded = false
    var expandedContentPhase: FloatingStatsExpandedContentPhase = .hidden
    var showsCollapsedContent = true
    var isDocked = true
    var edgeReleaseProgress: CGFloat = FloatingPanelDragMotion.dockedEdgeReleaseProgress
    /// When non-nil, the floating tab is expanded showing the deep preview
    /// for `visibleSessions[hoveredSegmentIndex]` (or, if that index points
    /// at an overflow `TabSegment`, the overflow mini list). Set by
    /// `SegmentHoverTracker` via the controller's `handleSegmentHover(_:)`.
    /// Cleared when the panel collapses.
    var hoveredSegmentIndex: Int?
}
```

### Step 2: Controller — `handleSegmentHover` + collapse-time cleanup

In `FloatingStatsPanelController.swift`, add a new method (place it just below `handlePermissionPendingChange` for cohesion with the other state-driven handlers, around line 126):

```swift
    /// Called from the SwiftUI root view when the cursor enters or leaves
    /// a tab segment. Non-nil index drives expand; nil indicates the
    /// cursor left the tab/panel and the existing `collapseTask` grace
    /// window applies (`setHovering(false)` chains into `scheduleCollapse`).
    /// Cleared on actual collapse (see `collapseCurrentPlacement`).
    func handleSegmentHover(_ index: Int?) {
        if let index {
            state.hoveredSegmentIndex = index
            // Treat entering a segment as the panel being hovered, so the
            // controller-side collapse task is cancelled and the panel
            // expands if not already.
            setHovering(true)
        } else {
            // Cursor left all segment rects. Reuse the existing
            // setHovering(false) path so the grace window + permission
            // override + drag suppression rules all apply unchanged.
            setHovering(false)
        }
    }
```

Then locate `collapseCurrentPlacement(animated:)` (it's the method `scheduleCollapse` ends up calling, currently around line 289 in the file's `scheduleCollapse` body — the actual `collapseCurrentPlacement` definition is later in the file; find it via `grep -n "private func collapseCurrentPlacement" ClaudeStats/Views/FloatingStats/FloatingStatsPanelController.swift`). At the **very start** of that method body, add the cleanup line:

```swift
    private func collapseCurrentPlacement(animated: Bool) {
        state.hoveredSegmentIndex = nil    // new: drop the hovered segment when the panel actually goes away
        // ... existing body unchanged ...
    }
```

(The new line must be the first statement so it runs even on early returns later in the method.)

### Step 3: View — add `onSegmentHoverChange` parameter

In `FloatingStatsPanelView.swift`, modify the struct's declared callbacks (around lines 8–10) to add one more:

```swift
struct FloatingStatsPanelView: View {
    @Environment(AppEnvironment.self) private var env

    let state: FloatingStatsPanelState
    var onHoverChanged: (Bool) -> Void
    var onSegmentHoverChange: (Int?) -> Void
    var onDragBegan: (CGPoint) -> Void
    var onDragMoved: (CGPoint) -> Void
    var onDragEnded: (CGPoint) -> Void
```

### Step 4: View — mount `SegmentHoverTracker` in `panelSurface`

In `FloatingStatsPanelView.panelSurface(edge:cap:visibleSize:)`, add a new `.overlay(...)` right after the existing `TabGlowOverlay` overlay. The existing overlay block looks like:

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

Add this **immediately after** that closing `)`:

```swift
        .overlay(
            SegmentHoverTracker(
                segments: TabSegmenter.segments(from: sessions, cap: cap),
                edge: edge,
                isExpanded: state.isExpanded,
                onSegmentHover: { idx in
                    onSegmentHoverChange(idx)
                }
            )
        )
```

The order matters: `SegmentHoverTracker` sits **above** `TabGlowOverlay` in the overlay stack so it actually receives hit-tests (`TabGlowOverlay` is `allowsHitTesting(false)`, so it's transparent to hits regardless).

### Step 5: View — rewrite `expandedContent(cap:)` as the new dispatcher

Find `expandedContent(cap:)` in `FloatingStatsPanelView.swift`. Replace its entire body with:

```swift
    @ViewBuilder
    private func expandedContent(cap: Int) -> some View {
        if let pending = env.permissionStore.pending.first {
            PermissionBubbleView(
                request: pending,
                pendingCount: env.permissionStore.pending.count,
                allowShortcut: PermissionShortcutSpec.parse(env.preferences.permissionShortcutAllow),
                denyShortcut: PermissionShortcutSpec.parse(env.preferences.permissionShortcutDeny),
                alwaysShortcut: PermissionShortcutSpec.parse(env.preferences.permissionShortcutAlways),
                errorMessage: env.permissionStore.lastErrorMessage,
                onAllow: { handlePermissionAllow(pending) },
                onDeny: { handlePermissionDeny(pending) },
                onAlways: { handlePermissionAlways(pending, suggestion: $0) }
            )
        } else if let index = state.hoveredSegmentIndex {
            let sessions = env.sessionRegistry.visibleSessions
            let segments = TabSegmenter.segments(from: sessions, cap: cap)
            if index < segments.count, segments[index].isOverflow {
                OverflowSessionList(
                    sessions: Array(sessions.suffix(from: max(0, cap - 1)))
                )
                .id("overflow-\(index)")
                .transition(.opacity)
            } else if index < sessions.count {
                SingleSessionPreview(session: sessions[index])
                    .id("session-\(sessions[index].id)")
                    .transition(.opacity)
            } else {
                // Edge case: hovered index pointed past the current
                // segments array (e.g. a session ended mid-hover). Render
                // empty rather than crash; the next hover will recover.
                Color.clear
            }
        } else {
            // Expanded without a hovered segment shouldn't normally happen
            // (controller sets hoveredSegmentIndex before/with expand),
            // but render empty to avoid a frame of stale list view.
            Color.clear
        }
    }
```

### Step 6: View — delete the dead code

In `FloatingStatsPanelView.swift`, delete the following symbols (all currently in this file after Task 4 of the Ribbon work landed):

1. The `expandedHeader` computed `var` (the small "Claude agents" + drag icon header). Find it via `grep -n "private var expandedHeader" ClaudeStats/Views/FloatingStats/FloatingStatsPanelView.swift`. Delete the whole declaration through its closing `}`.

2. The `animatedExpandedSection<Content: View>(...)` method and the `expandedSectionAnimation(for:)` method. Both are private helpers that exclusively served the old sessions-list fade-in. Find them via `grep -n "animatedExpandedSection\|expandedSectionAnimation" ClaudeStats/Views/FloatingStats/FloatingStatsPanelView.swift`.

3. The `private struct LiveSessionsList: View { ... }` declaration (the entire struct, including its `body`, `ambiguousTitles`, and `header`).

4. The `private struct LiveSessionRow: View { ... }` declaration (the entire struct, including all its computed properties and helpers).

5. The `private struct AgentsSyncStatusView: View { ... }` declaration (entire struct).

6. The `private extension ClaudeAgentsService.AgentAction { var helpText: String { ... } }` extension at the bottom of the file (its only consumer was `LiveSessionRow`).

After deletion, only the following structures should remain in `FloatingStatsPanelView.swift`:
- `FloatingStatsPanelView` itself (with its body, helpers, the new `expandedContent(cap:)`, etc.)
- `FloatingTabShape` struct (and `CornerRadii`)
- `FloatingPanelEdge` extension at the bottom (`dockedContentAlignment`)
- The `#if DEBUG` previews

Sanity check after deletion: `grep -nE 'LiveSessionsList|LiveSessionRow|AgentsSyncStatusView|expandedHeader|animatedExpandedSection|expandedSectionAnimation|AgentAction.*helpText' ClaudeStats/Views/FloatingStats/FloatingStatsPanelView.swift` should output **nothing**.

### Step 7: Controller — pass the new callback when building the root view

In `FloatingStatsPanelController.swift`, locate the `let rootView = FloatingStatsPanelView(...)` block in `ensurePanel()` (around line 205). The existing call passes 5 callbacks (`onHoverChanged`, `onDragBegan`, `onDragMoved`, `onDragEnded`). Add `onSegmentHoverChange`:

```swift
        let rootView = FloatingStatsPanelView(
            state: state,
            onHoverChanged: { [weak self] hovering in
                self?.setHovering(hovering)
            },
            onSegmentHoverChange: { [weak self] index in
                self?.handleSegmentHover(index)
            },
            onDragBegan: { [weak self] mouseLocation in
                self?.dragBegan(at: mouseLocation)
            },
            onDragMoved: { [weak self] mouseLocation in
                self?.dragMoved(to: mouseLocation)
            },
            onDragEnded: { [weak self] mouseLocation in
                self?.dragEnded(at: mouseLocation)
            }
        )
        .environment(environment)
```

### Step 8: Run tests + smoke verify

Run:
```bash
bash scripts/run-tests.sh
```

Expected: clean build, 338 tests still pass. There are no new automated tests in this task — it's a UI integration. The implementer should also (if a display is available):

```bash
bash scripts/run-debug.sh
```

…and verify the manual checklist in spec §Testing (1–8). If headless, this is deferred to the user.

### Step 9: Commit

```bash
git add ClaudeStats/Views/FloatingStats/FloatingStatsPanelState.swift \
        ClaudeStats/Views/FloatingStats/FloatingStatsPanelController.swift \
        ClaudeStats/Views/FloatingStats/FloatingStatsPanelView.swift
git commit -m "feat(floating-tab): per-segment hover preview replaces sessions list

- FloatingStatsPanelState gains hoveredSegmentIndex driving expandedContent
  dispatch (permission > overflow list > single-session preview).
- SegmentHoverTracker mounted above TabGlowOverlay in panelSurface;
  segment-precise hits in collapsed mode, single tracking rect in
  expanded mode (no mid-stream session switching per spec).
- Controller gains handleSegmentHover(_:) that routes into the existing
  setHovering(_:) collapse-task machinery; collapseCurrentPlacement clears
  state.hoveredSegmentIndex on actual collapse.
- Deleted LiveSessionsList, LiveSessionRow, AgentsSyncStatusView,
  expandedHeader, animatedExpandedSection, expandedSectionAnimation, and
  ClaudeAgentsService.AgentAction.helpText extension (no remaining
  consumers).

Spec: docs/superpowers/specs/2026-05-28-floating-tab-hover-preview-design.md"
```

---

## Spec coverage check

| Spec §Design item | Task |
|---|---|
| §1 Trigger: per-segment hover + SegmentHoverTracker mount | Task 4 (view) + Task 5 step 4 (mount) |
| §2 State `hoveredSegmentIndex` + permission override priority | Task 5 step 1 (state) + Task 5 step 5 (expandedContent permission-first ordering) |
| §3 expandedContent dispatcher | Task 5 step 5 |
| §4 SingleSessionPreview layout (header / activity / RECENT / button) | Task 2 |
| §4 Event humanization mapping | Task 1 |
| §5 OverflowSessionList layout | Task 3 |
| §6 SegmentHoverTracker with isExpanded conditional | Task 4 |
| §7 Deletions (LiveSessionsList et al) | Task 5 step 6 |
| §8 Animation (fade transition on session change via `.id` + `.transition`) | Task 5 step 5 |
| §Testing manual checklist | Task 5 step 8 (verification) |
