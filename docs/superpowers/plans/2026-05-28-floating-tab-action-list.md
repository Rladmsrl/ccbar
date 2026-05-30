# Floating Tab Action List Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the floating tab's default expanded hover preview with a current-session action list that prioritizes open/actionable sessions and hides quiet background workers.

**Architecture:** Add a pure presenter that derives rows, priority, subtitles, collapsed segments, and BG summary from `LiveSession` values. Replace the expanded panel's default content with a SwiftUI list driven by that presenter while keeping permission override behavior. Keep segment hover as an expansion trigger only; expanded content is stable and list-first.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing, existing CCBar floating-tab components.

---

### Task 1: Presenter Model And Tests

**Files:**
- Create: `ClaudeStats/Views/FloatingStats/FloatingSessionActionPresenter.swift`
- Test: `ClaudeStatsTests/FloatingSessionActionPresenterTests.swift`

- [x] **Step 1: Write failing presenter tests**

Create tests for:
- foreground sessions appear as rows;
- quiet BG sessions are hidden and counted in summary;
- actionable BG sessions appear as rows;
- priority order is needs answer, error, warning, done unread, running, idle;
- row subtitle uses `reason · action` shape.

- [x] **Step 2: Run presenter tests and verify RED**

Run:

```bash
xcodebuild -project ClaudeStats.xcodeproj -scheme ClaudeStats -configuration Debug -derivedDataPath /tmp/Codex-stats-build-tests -destination platform=macOS -only-testing:ClaudeStatsTests/FloatingSessionActionPresenterTests test
```

Expected: build fails because `FloatingSessionActionPresenter` does not exist.

- [x] **Step 3: Implement presenter**

Add:
- `FloatingSessionAttention`
- `FloatingSessionActionRowModel`
- `FloatingBackgroundSummaryModel`
- `FloatingSessionActionListModel`
- `FloatingSessionActionPresenter.makeModel(...)`

- [x] **Step 4: Run presenter tests and verify GREEN**

Run the same `xcodebuild -only-testing` command. Expected: tests pass.

### Task 2: Action List View

**Files:**
- Create: `ClaudeStats/Views/FloatingStats/FloatingSessionActionList.swift`
- Modify: `ClaudeStats/Views/FloatingStats/FloatingStatsPanelView.swift`
- Test: extend `ClaudeStatsTests/FloatingSessionActionPresenterTests.swift`

- [x] **Step 1: Write failing tests for collapsed segment input**

Presenter should expose `segmentSessions` that excludes quiet BG sessions and includes actionable BG sessions.

- [x] **Step 2: Run tests and verify RED**

Expected: tests fail because `segmentSessions` is missing or wrong.

- [x] **Step 3: Implement action list view and wire panel**

Replace non-permission expanded content with `FloatingSessionActionList(model:)`.
Use presenter output for `TabGlowOverlay` and `SegmentHoverTracker` segments.
Keep permission bubble as highest-priority override.

- [x] **Step 4: Run focused tests and verify GREEN**

Run presenter tests. Expected: pass.

### Task 3: Hover Trigger Cleanup

**Files:**
- Modify: `ClaudeStats/Views/FloatingStats/FloatingStatsPanelController.swift`
- Modify: `ClaudeStats/Views/FloatingStats/FloatingStatsPanelHoverExpansionPolicy.swift`
- Test: `ClaudeStatsTests/FloatingStatsHoverInteractionTests.swift`

- [x] **Step 1: Write failing hover policy test**

Panel hover should be allowed to expand to the action list even when no segment index is selected.

- [x] **Step 2: Run hover tests and verify RED**

Run focused hover tests. Expected: test fails under current policy.

- [x] **Step 3: Implement hover policy**

Let panel hover expand the stable action-list panel. Keep permission expansion behavior.

- [x] **Step 4: Run hover tests and verify GREEN**

Run focused hover tests. Expected: pass.

### Task 4: Verification And Commit

**Files:**
- All changed files.

- [x] **Step 1: Run full test suite**

```bash
bash scripts/run-tests.sh
```

Expected: all tests pass.

- [x] **Step 2: Run debug build/launch**

```bash
bash scripts/run-debug.sh
```

Expected: build succeeds and app launches from `/tmp/Codex-stats-build`.

- [x] **Step 3: Commit**

```bash
git add ClaudeStats ClaudeStatsTests docs/superpowers/plans/2026-05-28-floating-tab-action-list.md
git commit -m "feat(floating-tab): show current-session action list"
```
