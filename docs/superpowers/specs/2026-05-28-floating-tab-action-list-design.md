# Floating tab — current-session action list redesign

**Date:** 2026-05-28
**Status:** Draft — product direction approved, awaiting user review
**Scope:** Replace the hover-preview panel's primary content model. This spec
builds on the hover-preview refactor but changes the product intent from
"hover a segment to inspect one session" to "scan current open sessions and
jump to the one that needs attention".

## Problem

The current hover-preview refactor makes each tab segment open a deep preview
for one session. That is useful when the user already knows which session they
want to inspect, but it does not answer the main question the floating tab
should answer in daily use:

> What open sessions do I have right now, which ones need me, which ones are
> done or unhealthy, and how do I jump back quickly?

Showing background agent workers as first-class rows also creates noise. A
background job that is simply running is not usually something the user can or
needs to act on. When many BG rows are visible, the panel starts feeling like an
agent fleet table instead of a lightweight current-session control surface.

## Product Direction

The expanded floating tab should be a **current-session action list**.

It should prioritize sessions the user can actually return to, especially
foreground/open terminal sessions. It should make actionable states obvious:
needs answer, permission request, error/interrupted, warning, completed and
unread, running, idle. Every main row should support a direct jump/focus action.

Background sessions should not appear in the main list just because they exist.
They should surface only when they become actionable: needs input, permission,
warning, error/interrupted, or completed/unread. Otherwise BG is represented by a
small summary line such as "4 background running".

## Goals

1. Make the expanded panel answer "what needs my attention now?"
2. Keep the first screen scannable, not a log viewer.
3. Preserve one-step focus/jump for open sessions.
4. Hide non-actionable BG work by default while still surfacing BG problems.
5. Keep the collapsed tab's segment signal useful without forcing the expanded
   panel into one-session-at-a-time detail.

## Non-Goals

- Do not build a full background-agent management UI in this panel.
- Do not show all BG sessions as ordinary rows while they are merely running.
- Do not add model/token/cost fields here.
- Do not turn each row into a multi-event timeline by default.
- Do not remove permission bubble override behavior.
- Do not solve durable notification history beyond current unread/done state.

## Information Architecture

### Expanded Panel

The expanded panel's first screen is a list, not a single-session preview.

Header:
- Title: "Current sessions" or "Needs attention" depending on whether any
  actionable row exists.
- Count: number of open/current rows, plus a compact BG summary when relevant.

Rows:
- Status dot, using the same state palette as the collapsed tab.
- Display title, usually project/session title.
- Status reason plus current/last action on one subtitle line.
- Jump/focus button on the trailing edge when focus is available.

Footer/summary:
- If non-actionable BG sessions exist, show a quiet summary line:
  "4 background running" or "4 background hidden until actionable".
- If no open/current sessions exist and only quiet BG exists, show a dormant
  empty state rather than a detailed BG list.

### Row Content

Use the "reason + current action" format:

```text
claude-stats
Needs answer · permission request                         Focus

codex-app
Warning · tests flaky                                     Focus

release-notes
Done · review output                                      Focus

docs-refresh
Running · editing file                                    Focus
```

The first phrase answers why the row matters. The second phrase gives context.
Examples:
- `Needs answer · permission request`
- `Error · command failed`
- `Warning · tests flaky`
- `Done · review output`
- `Running · editing file`
- `Idle · last active 3m ago`

Recent events remain useful as data, but the default row should not display a
timeline. The user should not need to read logs inside a hover panel.

## Session Inclusion Rules

### Main Rows

Include:
- Foreground/open sessions.
- Headless sessions only if they have a meaningful focus/jump target or are
  actionable.
- Background sessions only if actionable.

Exclude:
- Background sessions that are merely running, thinking, idle, or otherwise not
  asking for user attention.
- Placeholder/unnamed BG rows unless they are actionable.

### Background Summary

When excluded BG sessions exist, show a compact summary outside the main list.
The summary is informational only; it should not compete visually with rows that
need attention.

Possible copy:
- `4 background running`
- `4 background hidden until actionable`
- `2 background running · 1 completed`

If a BG session becomes actionable, it leaves the summary and becomes a main
row until the user acknowledges it or it is no longer actionable.

## Sorting

Sort rows by attention priority:

1. Needs answer / permission
2. Error / interrupted
3. Warning
4. Done and unread
5. Running
6. Idle

Within the same priority, keep ordering stable enough that rows do not jump
around constantly. Prefer existing session ordering or `startedAt` where it
preserves spatial memory; use `updatedAt` only where recency is clearly part of
the priority, such as multiple completed/unread rows.

## Collapsed Tab Behavior

The collapsed tab should continue to show a compact visual signal. Since the
expanded panel is becoming an action list, the collapsed segment model should be
interpreted as "visible/actionable current sessions", not "all agents".

Preferred behavior:
- Foreground/open sessions get normal segments.
- Actionable BG sessions get segments.
- Non-actionable BG sessions do not get individual segments.
- A quiet BG count can be represented only as text/tooltip/summary, not as a
  full visual segment that suggests an actionable row.

The strongest state in the visible/actionable set should dominate peripheral
attention. For example, a permission request should be more visually prominent
than a merely running session.

## Interaction

Hover collapsed tab:
- Expand to the action-list panel.
- Do not require hovering a specific segment to get useful content.

Click row / trailing jump:
- Focus the matching terminal/session when focus is available.
- For rows without focus target, use the row's primary available action:
  acknowledge, open details, or no-op with disabled state depending on the
  underlying capability.

Permission pending:
- Permission bubble still overrides the panel content.
- After resolution, return to the action list if the mouse remains over the
  floating panel.

Acknowledgement:
- Done/unread rows should stop being attention-priority once the user focuses,
  clicks, or otherwise acknowledges them.
- Exact acknowledgement mechanics can reuse existing `markRead` behavior.

## Data Model Notes

The existing `LiveSession` model already contains most fields needed:
- `displayTitle`
- `kind`
- `displayState`
- `needsInput`
- `sourcePid`
- `updatedAt`
- `lastEvent`
- `recentEvents`
- `managementId`

The redesign needs one derived concept:

```swift
enum FloatingSessionAttention {
    case needsAnswer
    case error
    case warning
    case doneUnread
    case running
    case idle
}
```

This does not need to be persisted. It should be computed from existing
session state, permission state, unread-done state, and recent event summary.

## Component Direction

Replace the expanded panel's primary content with a new list component:

- `FloatingSessionActionList`
- `FloatingSessionActionRow`
- `FloatingBackgroundSummary`
- A small presenter/helper that derives inclusion, priority, subtitle, and
  focus availability from `LiveSession` plus environment stores.

`SingleSessionPreview` and `OverflowSessionList` can either be removed or kept
temporarily if the implementation wants to preserve them behind a secondary
detail path. They should no longer be the default expanded panel experience.

## Error and Empty States

No open/current sessions:
- Collapsed tab shows dormant title.
- Expanded panel can show "No open sessions" only if the user explicitly opens
  it; avoid showing a large empty panel on accidental hover.

Only quiet BG running:
- Main list is empty.
- Show a compact background summary rather than full BG rows.

Focus unavailable:
- Keep row visible if it is actionable.
- Disable the focus button and use a tooltip explaining why it cannot focus.

## Testing

Unit tests should cover:
- Inclusion rules for foreground, headless, actionable BG, and quiet BG.
- Attention priority sorting.
- Subtitle derivation for needs answer, warning, done, running, and idle.
- BG summary counts.
- Done/unread acknowledgement behavior if touched.

Manual verification should cover:
- Multiple open sessions with mixed states.
- Quiet BG workers do not appear as rows.
- Actionable BG workers do appear as rows.
- Permission bubble still overrides and remains clickable.
- Focus works from action rows.
- Collapsed tab no longer over-counts quiet BG as actionable visible segments.

## Implementation Decision

The existing hover-preview refactor uses per-segment hover to choose a single
session. This spec intentionally changes that interaction.

For the first implementation, keep segment hover only for collapsed visual
affordance and always open the same action-list panel. This minimizes motion,
preserves the collapsed segment signal, and makes the expanded content stable
and list-first.

Do not keep single-session preview as the default expanded experience. If it is
kept in code temporarily, it must be secondary and unreachable from the normal
hover path until a later design explicitly reintroduces it.
