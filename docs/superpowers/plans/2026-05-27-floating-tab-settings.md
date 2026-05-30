# Floating Tab Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Floating Edge Tab a real Settings page (Features 卡片 "Configure" 当前跳错到 MenuBar) with one new config —— user-tunable segment cap —— and reshape the collapsed bar into a 80/20 双区 layout so segment colours and `●N` stop fighting for the same pixels.

**Architecture:** Add a `Preferences.floatingTabSegmentCap` (clamped 3...10, default 5) that replaces the hardcoded `segmentCap = 5` constant; wire a new `SettingsSection.floatingTab` through `SettingsSidebarColumn` / `SettingsDetailView` to a new `FloatingTabSettingsView`; teach `TabGlowOverlay` to render its segments inside a sub-region (`mainAreaFraction`) of the shape so `FloatingStatsPanelView` can carve the collapsed bar into 80% segment-stripe + 20% trailing `●N`.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, `@Observable` Preferences, Swift Testing (`@Test`).

**Spec:** `docs/superpowers/specs/2026-05-27-floating-tab-settings-design.md`

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `ClaudeStats/Services/Preferences.swift` | Modify | Add `floatingTabSegmentCap` property + `Keys.floatingTabSegmentCap` + init read |
| `ClaudeStatsTests/PreferencesTests.swift` | Modify | Three new `@Test`s: default, persist, clamp |
| `ClaudeStats/Views/MainWindow/Settings/SettingsSection.swift` | Modify | Add `case floatingTab` + title + symbol |
| `ClaudeStats/Views/MainWindow/Settings/Sections/FloatingTabSettingsView.swift` | Create | The new Settings page (Toggle + Stepper) |
| `ClaudeStats/Views/MainWindow/Settings/SettingsDetailView.swift` | Modify | Route `.floatingTab` → `FloatingTabSettingsView()` |
| `ClaudeStats/Views/MainWindow/Settings/Sections/FeaturesSettingsView.swift` | Modify | `floatingTabCard.onConfigure` switch from `.menuBar` to `.floatingTab` |
| `ClaudeStats/Views/FloatingStats/TabGlowOverlay.swift` | Modify | Accept `mainAreaFraction: CGFloat = 1.0`, paint segments inside that sub-region only |
| `ClaudeStats/Views/FloatingStats/FloatingStatsPanelView.swift` | Modify | Delete `segmentCap` constant; read `env.preferences.floatingTabSegmentCap`; collapsed bar 80/20 layout; thread `cap` into `LiveSessionsList` as a parameter |

---

## Task 1: Preferences gains `floatingTabSegmentCap`

**Why first:** Everything downstream reads this value. Land it with tests before any UI consumes it.

**Files:**
- Modify: `ClaudeStats/Services/Preferences.swift`
- Test: `ClaudeStatsTests/PreferencesTests.swift`

### Step 1: Add three failing tests

Insert these into `PreferencesTests.swift` right after the existing `invalidFloatingEdgeFallsBack` test (after line 39). The `makeDefaults()` helper at the bottom of the file is what other tests already use.

```swift
    @Test("Floating tab segment cap defaults to 5")
    func floatingTabSegmentCapDefault() {
        let defaults = makeDefaults()
        let prefs = Preferences(defaults: defaults)

        #expect(prefs.floatingTabSegmentCap == 5)
    }

    @Test("Floating tab segment cap persists across reloads")
    func floatingTabSegmentCapPersists() {
        let defaults = makeDefaults()
        let prefs = Preferences(defaults: defaults)
        prefs.floatingTabSegmentCap = 7

        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.floatingTabSegmentCap == 7)
    }

    @Test("Floating tab segment cap clamps to 3...10")
    func floatingTabSegmentCapClamps() {
        let defaults = makeDefaults()
        let prefs = Preferences(defaults: defaults)

        prefs.floatingTabSegmentCap = 1
        #expect(prefs.floatingTabSegmentCap == 3)

        prefs.floatingTabSegmentCap = 99
        #expect(prefs.floatingTabSegmentCap == 10)

        // Stored value also reflects the clamp.
        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.floatingTabSegmentCap == 10)
    }
```

### Step 2: Run the tests and confirm they fail

Run:
```bash
bash scripts/run-tests.sh
```

Expected: Build fails — `Value of type 'Preferences' has no member 'floatingTabSegmentCap'`. That's a meaningful "missing symbol" failure (not a behaviour mismatch), so we proceed.

### Step 3: Implement the property in `Preferences`

In `ClaudeStats/Services/Preferences.swift`:

(a) Add the property declaration right after the existing `floatingTabDisplayID` block (around line 89). Indentation matches the surrounding properties:

```swift
    /// Max number of session segments the collapsed floating tab shows;
    /// the same value caps how many SESSIONS rows render in the expanded
    /// list. Anything beyond `cap` is grouped into a single trailing
    /// "N+" overflow segment / row. Clamped to 3...10 on write so a
    /// hand-edited UserDefaults value can never persist outside the
    /// supported range.
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

(b) Add the init read right after the existing `floatingTabDisplayID = ...` line (around line 251). The clamp here handles a hand-edited stored value as well as the "absent → 5" default:

```swift
        let storedSegmentCap = (defaults.object(forKey: Keys.floatingTabSegmentCap) as? Int) ?? 5
        floatingTabSegmentCap = max(3, min(10, storedSegmentCap))
```

(c) Add the key inside the `Keys` enum (around line 363, right after `floatingTabDisplayID`):

```swift
        static let floatingTabSegmentCap = "floatingTabSegmentCap"
```

### Step 4: Run tests, confirm they pass

Run:
```bash
bash scripts/run-tests.sh
```

Expected: all three new tests PASS, and the existing `Preferences` / `Floating tab` tests still PASS.

### Step 5: Commit

```bash
git add ClaudeStats/Services/Preferences.swift ClaudeStatsTests/PreferencesTests.swift
git commit -m "feat(preferences): floatingTabSegmentCap (3-10, default 5)"
```

---

## Task 2: `SettingsSection.floatingTab` enum case + sidebar/detail routing

**Why:** Without this, the sidebar can't surface the page and `SettingsDetailView` can't route to it. Page itself stays a stub here — Task 3 fills it in.

**Files:**
- Modify: `ClaudeStats/Views/MainWindow/Settings/SettingsSection.swift`
- Create: `ClaudeStats/Views/MainWindow/Settings/Sections/FloatingTabSettingsView.swift`
- Modify: `ClaudeStats/Views/MainWindow/Settings/SettingsDetailView.swift`

### Step 1: Add the enum case + title + symbol

In `SettingsSection.swift`:

(a) Add `case floatingTab` between `.menuBar` and `.platforms` (line 9):

```swift
    case general
    case features
    case menuBar
    case floatingTab
    case platforms
    case tracking
    case approvals
    case about
```

(b) Add the `.floatingTab` branch in `title`:

```swift
        case .floatingTab: L10n.string("settings.section.floating_tab", defaultValue: "Floating Tab")
```

(c) Add the `.floatingTab` branch in `symbol`:

```swift
        case .floatingTab: "rectangle.on.rectangle"
```

The symbol matches the icon used on the Features card (`FeaturesSettingsView.swift:91`), so the sidebar entry and the card entry visually rhyme.

### Step 2: Create the stub view

Create `ClaudeStats/Views/MainWindow/Settings/Sections/FloatingTabSettingsView.swift`:

```swift
import SwiftUI

/// Settings page for the optional screen-edge floating tab. Owns the
/// on/off toggle (mirror of the Features card) and density controls.
/// Position/edge/screen are intentionally absent — those are direct-drag
/// affordances on the tab itself, see spec §Non-Goals.
struct FloatingTabSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Text("Floating Tab (stub)")
            .font(.sora(13))
            .foregroundStyle(Color.stxMuted)
    }
}

#if DEBUG
#Preview {
    FloatingTabSettingsView()
        .environment(AppEnvironment.preview())
        .padding()
        .frame(width: 720)
        .background(Color.stxBackground)
}
#endif
```

### Step 3: Route `.floatingTab` in `SettingsDetailView`

In `ClaudeStats/Views/MainWindow/Settings/SettingsDetailView.swift`, inside the `switch section` (line 29), add the case between `.menuBar` and `.platforms`:

```swift
        case .menuBar: MenuBarSettingsView()
        case .floatingTab: FloatingTabSettingsView()
        case .platforms: PlatformsSettingsView()
```

`SettingsSidebarColumn` iterates `SettingsSection.allCases`, so adding the case to the enum is enough — no separate sidebar change needed.

### Step 4: Build + smoke check

Run:
```bash
bash scripts/run-debug.sh
```

In the running app: open the main window → settings mode → confirm the sidebar shows a new "Floating Tab" row with the `rectangle.on.rectangle` icon between "Menu Bar" and "Platforms". Click it → the detail panel shows "Floating Tab (stub)". Click other sections → they still work.

### Step 5: Commit

```bash
git add ClaudeStats/Views/MainWindow/Settings/SettingsSection.swift \
        ClaudeStats/Views/MainWindow/Settings/Sections/FloatingTabSettingsView.swift \
        ClaudeStats/Views/MainWindow/Settings/SettingsDetailView.swift
git commit -m "feat(settings): add Floating Tab section (stub view)"
```

---

## Task 3: Populate `FloatingTabSettingsView` — General + Density

**Files:**
- Modify: `ClaudeStats/Views/MainWindow/Settings/Sections/FloatingTabSettingsView.swift`

### Step 1: Replace the stub body with two `SettingGroup`s

Replace the entire contents of `FloatingTabSettingsView.swift` with:

```swift
import SwiftUI

/// Settings page for the optional screen-edge floating tab. Owns the
/// on/off toggle (mirror of the Features card) and density controls.
/// Position/edge/screen are intentionally absent — those are direct-drag
/// affordances on the tab itself, see spec §Non-Goals.
struct FloatingTabSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var prefs = env.preferences

        VStack(alignment: .leading, spacing: 28) {
            SettingGroup(title: "General") {
                VStack(spacing: 0) {
                    SettingRow(
                        title: "Show floating edge tab",
                        description: "Drag the tab itself to change edge, position, or screen."
                    ) {
                        Toggle("", isOn: $prefs.floatingTabEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
                .settingCard()
            }

            SettingGroup(title: "Density") {
                VStack(spacing: 0) {
                    SettingRow(
                        title: "Max visible sessions",
                        description: "Caps both the collapsed bar segments and the expanded SESSIONS list. Extra sessions are grouped into the trailing \"N+\" segment."
                    ) {
                        Stepper(
                            value: $prefs.floatingTabSegmentCap,
                            in: 3...10
                        ) {
                            Text("\(prefs.floatingTabSegmentCap)")
                                .font(.sora(13).monospacedDigit())
                                .frame(minWidth: 24, alignment: .trailing)
                        }
                        .labelsHidden()
                    }
                }
                .settingCard()
            }
        }
    }
}

#if DEBUG
#Preview {
    FloatingTabSettingsView()
        .environment(AppEnvironment.preview())
        .padding()
        .frame(width: 720)
        .background(Color.stxBackground)
}
#endif
```

The `SettingGroup` / `SettingRow` / `.settingCard()` modifiers are the same primitives `GeneralSettingsView` uses (see `Views/MainWindow/Settings/Sections/GeneralSettingsView.swift:14-26` for a working pattern of "title group + card + row").

### Step 2: Build + visually verify

Run:
```bash
bash scripts/run-debug.sh
```

In the running app: settings → Floating Tab section. Confirm:
- "General" group with one card containing the toggle row (default ON).
- "Density" group with one card containing the stepper (defaults to 5).
- Tapping the stepper up arrow raises the number, max stops at 10. Down arrow stops at 3.
- Toggling "Show floating edge tab" makes the floating tab on screen appear/disappear in real time.
- Changing the stepper while the floating tab is visible doesn't break anything (visible behaviour change wired in Task 6 — for now the tab still uses the hardcoded 5).

### Step 3: Commit

```bash
git add ClaudeStats/Views/MainWindow/Settings/Sections/FloatingTabSettingsView.swift
git commit -m "feat(settings): floating tab General + Density groups"
```

---

## Task 4: Fix `floatingTabCard` "Configure" button

**Why:** Smallest possible change with the biggest UX payoff — kills the bug we discovered at brainstorm time.

**Files:**
- Modify: `ClaudeStats/Views/MainWindow/Settings/Sections/FeaturesSettingsView.swift`

### Step 1: Switch the routing target

In `FeaturesSettingsView.swift` line 95, replace:

```swift
            onConfigure: { onSelectSection(.menuBar) }
```

with:

```swift
            onConfigure: { onSelectSection(.floatingTab) }
```

### Step 2: Smoke verify

Run:
```bash
bash scripts/run-debug.sh
```

In the running app: settings → Features → on the "Floating Edge Tab" card click the "Configure" button → the detail panel switches to the Floating Tab section (not Menu Bar). Confirm the sidebar selection also moves to the new row.

### Step 3: Commit

```bash
git add ClaudeStats/Views/MainWindow/Settings/Sections/FeaturesSettingsView.swift
git commit -m "fix(settings): floatingTabCard Configure jumps to .floatingTab, not .menuBar"
```

---

## Task 5: `TabGlowOverlay` accepts `mainAreaFraction`

**Why:** Decouples the overlay's "paint segments here" from "the whole shape." Task 6 will set this to 0.8 in collapsed-mode so segment fills don't cover the 20% reserved for `●N`. Default 1.0 keeps every existing caller unchanged.

**Files:**
- Modify: `ClaudeStats/Views/FloatingStats/TabGlowOverlay.swift`

### Step 1: Add the property + propagate it through `segmentedBody`

In `TabGlowOverlay.swift`:

(a) Add the property with a default after `let edge: FloatingPanelEdge` (line 30):

```swift
struct TabGlowOverlay<S: Shape>: View {
    let shape: S
    let segments: [TabSegment]
    let isExpanded: Bool
    let edge: FloatingPanelEdge
    /// Fraction of the shape's "along-edge" axis (height for left/right,
    /// width for top/bottom) reserved for segment fills + dividers. The
    /// trailing `1 - mainAreaFraction` is left blank so the parent can
    /// host another element there (e.g. a `●N` badge). Default 1.0 — the
    /// fills cover the full shape, preserving today's behaviour.
    var mainAreaFraction: CGFloat = 1.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
```

(b) Change `segmentedBody` (around line 46) to compute `rects` against the sub-region instead of the full shape. The main area is anchored at the bar's natural origin (top of vertical edges, leading of horizontal edges), so the badge that lives in the trailing slice will sit at the bottom/trailing — see Task 6 step 5. The whole edited body:

```swift
    private var segmentedBody: some View {
        let hasAnyNeedsInput = segments.contains(where: \.needsInput)
        let specs = segments.map { segment in
            specFor(segment: segment, hasAnyNeedsInput: hasAnyNeedsInput)
        }
        let anyPulses = specs.contains(where: \.pulses)
        return GeometryReader { proxy in
            let mainSize = mainAreaSize(for: proxy.size)
            let rects = TabSegmenter.rects(
                in: mainSize,
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

`renderedTab` and `segmentFill` keep their existing signatures — `TabSegmenter.rects(in: mainSize, ...)` already returns rects starting at the natural origin of the shrunken region, and `.position(x: rect.midX, y: rect.midY)` paints them in absolute GeometryReader coordinates which happen to be the top/leading anchored sub-region. No offset threading needed.

### Step 2: Run tests + smoke verify default behaviour

Run:
```bash
bash scripts/run-tests.sh
```

Expected: `TabSegmenterTests` and `PreferencesTests` all PASS. `TabSegmenter.rects` itself is unchanged — `TabGlowOverlay` just calls it with a smaller `size`.

Then run the app:
```bash
bash scripts/run-debug.sh
```

In the running app: floating tab on screen, multiple sessions. Confirm the segment stripe + `●N` looks **identical to before** — `mainAreaFraction` defaults to 1.0, so nothing visible should change yet. Hover-expand still works.

### Step 3: Commit

```bash
git add ClaudeStats/Views/FloatingStats/TabGlowOverlay.swift
git commit -m "refactor(floating-tab): TabGlowOverlay accepts mainAreaFraction (default 1.0)"
```

---

## Task 6: Wire `floatingTabSegmentCap` into the tab + collapsed 80/20 layout

**Why:** This is the visible payoff — the segment cap finally responds to Settings, and the collapsed bar adopts the 80/20 split decided in spec §Design 4. Big change, but everything below it landed in earlier tasks, so this task is mostly bookkeeping inside `FloatingStatsPanelView`.

**Files:**
- Modify: `ClaudeStats/Views/FloatingStats/FloatingStatsPanelView.swift`

### Step 1: Delete the hardcoded cap constant

In `FloatingStatsPanelView.swift` remove lines 245-249 (the comment block + `static let segmentCap = 5` declaration). Cap is now read from `env.preferences.floatingTabSegmentCap` at the use sites.

### Step 2: Make `LiveSessionsList` take `cap` as a parameter

`LiveSessionsList` is a `private struct` inside this file. It currently references `FloatingStatsPanelView.segmentCap` (line 301 and 343). Convert it to receive the cap as a parameter.

(a) Add a `let cap: Int` stored property to `LiveSessionsList` (around line 289, between `unreadDoneSessions` and `body`):

```swift
private struct LiveSessionsList: View {
    let sessions: [LiveSession]
    let unreadDoneSessions: Set<String>
    let cap: Int

    var body: some View {
```

(b) Replace the `let cap = FloatingStatsPanelView.segmentCap` in `body` (line 301) with `_ = cap   // already a property` — i.e. delete the line and use the property directly. The block that currently reads:

```swift
                let ambiguous = ambiguousTitles
                let cap = FloatingStatsPanelView.segmentCap
                if sessions.count > cap {
```

becomes:

```swift
                let ambiguous = ambiguousTitles
                if sessions.count > cap {
```

(c) Update `ambiguousTitles` (around line 343) to use the property instead of the constant:

```swift
    private var ambiguousTitles: Set<String> {
        let independent = sessions.count > cap
            ? Array(sessions.prefix(cap - 1))
            : sessions
        var counts: [String: Int] = [:]
        for session in independent {
            counts[session.displayTitle, default: 0] += 1
        }
        return Set(counts.filter { $0.value > 1 }.keys)
    }
```

### Step 3: Pass the cap from `expandedContent` to `LiveSessionsList`

In `FloatingStatsPanelView.expandedContent` (around line 156) the current call is:

```swift
                        LiveSessionsList(
                            sessions: env.sessionRegistry.visibleSessions,
                            unreadDoneSessions: env.sessionRegistry.unreadDoneSessions
                        )
```

Change it to thread `cap` in:

```swift
                        LiveSessionsList(
                            sessions: env.sessionRegistry.visibleSessions,
                            unreadDoneSessions: env.sessionRegistry.unreadDoneSessions,
                            cap: env.preferences.floatingTabSegmentCap
                        )
```

### Step 4: Read the cap in `panelSurface` and pass to `TabSegmenter` + `TabGlowOverlay` with `mainAreaFraction = 0.8`

In `panelSurface` (around line 36), change the local that builds `sessions` to also build `cap`:

```swift
        let collapsedSize = FloatingPanelGeometry.size(edge: edge, expanded: false)
        let sessions = env.sessionRegistry.visibleSessions
        let cap = env.preferences.floatingTabSegmentCap
```

And update the `TabGlowOverlay` overlay (around line 58) to use the read cap and the new fraction. Also remove the existing static call to `Self.segmentCap`:

```swift
        .overlay(
            TabGlowOverlay(
                shape: shape,
                segments: TabSegmenter.segments(from: sessions, cap: cap),
                isExpanded: state.isExpanded,
                edge: edge,
                mainAreaFraction: 0.8
            )
        )
```

### Step 5: Reshape `collapsedContent` so `●N` lives in the trailing 20%

`collapsedContent` currently lays the badge (or fallback title) centred inside the whole collapsed area. The 80/20 split applies **only when a session badge would be shown** (i.e. `sessions.dominantBadge != nil`); the empty / no-session branch keeps the title centred across the full bar.

Replace the existing `collapsedContent(edge:size:)` (around line 71) body with this version:

```swift
    private func collapsedContent(edge: FloatingPanelEdge, size: CGSize) -> some View {
        let sessions = env.sessionRegistry.visibleSessions
        let title = L10n.string("floating.tab.title", defaultValue: "Claude agents")
        return Group {
            if let badge = sessions.dominantBadge {
                // Pin the badge to the 20% trailing region nearest the screen
                // edge. The segment stripe (drawn by TabGlowOverlay with
                // mainAreaFraction=0.8) lives in the other 80%, so the two
                // information layers stop fighting for the same pixels.
                CollapsedSessionBadge(count: sessions.count, badge: badge)
                    .accessibilityLabel(L10n.format(
                        "floating.tab.badge.a11y",
                        defaultValue: "%d Claude sessions, status %@",
                        sessions.count,
                        badge.rawValue
                    ))
                    .frame(
                        width: badgeRegionSize(in: size, edge: edge).width,
                        height: badgeRegionSize(in: size, edge: edge).height,
                        alignment: .center
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: badgeRegionAlignment(for: edge))
            } else if edge.isVertical {
                sideCollapsedTitle(title, edge: edge, size: size)
            } else {
                horizontalCollapsedTitle(title)
            }
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Metrics.collapsedContentPadding)
            .overlay(dragHandle)
            .accessibilityHint("Hover to expand. Drag to snap to another screen edge.")
    }

    /// 20% slice at the screen-edge end of the collapsed bar — where the
    /// badge sits when there are sessions to summarize.
    private func badgeRegionSize(in total: CGSize, edge: FloatingPanelEdge) -> CGSize {
        switch edge {
        case .left, .right:
            return CGSize(width: total.width, height: total.height * 0.2)
        case .top, .bottom:
            return CGSize(width: total.width * 0.2, height: total.height)
        }
    }

    private func badgeRegionAlignment(for edge: FloatingPanelEdge) -> Alignment {
        switch edge {
        case .left, .right:   return .bottom    // vertical bar: badge at the bottom
        case .top, .bottom:   return .trailing  // horizontal bar: badge on the right
        }
    }
```

`TabGlowOverlay` paints its segments into the leading/top 80% of the same bar via `mainAreaFraction = 0.8` (Task 5 `mainAreaSize` anchors that region at the natural origin), so the 20% trailing slice — where the badge sits — is always free of segment fill.

### Step 6: Build + visually verify the full path

Run:
```bash
bash scripts/run-debug.sh
```

Verification checklist in the running app:
1. Open Settings → Floating Tab → set cap = **3**. Spin up 5 sessions. Collapsed bar shows **3 segments** (the 3rd is the overflow segment, slightly larger displayState colour aggregated). Expanded SESSIONS list shows 5 rows: first 2 with rowLabels "1"/"2", remaining 3 with rowLabel "3+".
2. Set cap = **10**. With 7 sessions, all 7 are independent segments; expanded list has 7 rows labelled 1...7.
3. With ≥1 session and any cap, the collapsed bar's **trailing 20%** shows `●N` (badge dot + count), and the segment stripe occupies the **other 80%**. They don't overlap.
4. Kill all sessions (or wait until they finish and clear). The collapsed bar shows the centred "Claude agents" title (vertical or horizontal depending on edge) across the **full bar** — no 80/20 split when there's no badge.
5. Drag the tab to each of the 4 edges; the 80/20 split always places `●N` at the **trailing end of the bar's long axis** — bottom for `.left`/`.right`, right for `.top`/`.bottom` — with the segment stripe filling the other 80%. The two layers never overlap regardless of which edge.
6. Hover-expand still works and shows the SESSIONS list with the right row count.

### Step 7: Run tests one more time

Run:
```bash
bash scripts/run-tests.sh
```

Expected: full test suite PASSES.

### Step 8: Commit

```bash
git add ClaudeStats/Views/FloatingStats/FloatingStatsPanelView.swift
git commit -m "feat(floating-tab): segmentCap reads Preferences, collapsed bar 80/20 layout

- Delete the hardcoded segmentCap = 5; both TabSegmenter (collapsed) and
  LiveSessionsList (expanded) now read env.preferences.floatingTabSegmentCap.
- LiveSessionsList takes 'cap' as a parameter so it stays free of
  environment access (single direction of dependency).
- Collapsed bar: when at least one session is visible, ●N is pinned to
  the 20% slice at the screen-edge end; TabGlowOverlay paints into the
  other 80% via mainAreaFraction. Empty / no-session state keeps the
  centred title across the full bar."
```

---

## Spec coverage check

| Spec §Design item | Task |
|---|---|
| §1 New `SettingsSection.floatingTab` + sidebar surfacing | Task 2 |
| §1 `FloatingTabSettingsView.swift` General/Density groups | Tasks 2 + 3 |
| §2 `Preferences.floatingTabSegmentCap` (3-10, default 5) | Task 1 |
| §3 Replace constant `segmentCap` with prefs read at all call sites | Task 6 (steps 1-4) |
| §3 `LiveSessionsList` takes `cap` as a parameter, no env coupling | Task 6 (steps 2-3) |
| §4 Collapsed bar 80/20 split with `●N` in the trailing 20% | Tasks 5 + 6 |
| §4 No-session branch keeps centred title | Task 6 (step 5) |
| §4 `TabGlowOverlay` `mainAreaFraction` param | Task 5 |
| §5 `floatingTabCard.onConfigure` → `.floatingTab` | Task 4 |
| §Testing PreferencesTests new cases | Task 1 |
| §Testing manual smoke list | Task 6 (step 6) |
