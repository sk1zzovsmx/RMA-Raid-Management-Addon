# Spammer And Warnings Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make LFM spam and raid warnings bounded, reload-safe, failure-aware, and consistent from slash/config/UI entry points.

**Architecture:** `Services/Spammer/Draft.lua` owns canonical `RMA_Spammer` data, a cohesive runtime owner manages the LFM lifecycle, and Chat/Comms only validate and transport messages. `Services/Warnings/Store.lua` owns normalized warning records; controllers render state and propagate terminal results without mutating persistence directly.

**Tech Stack:** WoW 3.3.5a, Interface 30300, Lua 5.1, Python unittest and Lua runtime harness.

## Global Constraints

- Preserve `RMA_Spammer`, `RMA_Warnings`, slash/config/frame contracts and WotLK chat APIs.
- Persist stable channel identities, never volatile session channel IDs.
- Count and cap actual send attempts, throttle multi-channel sends, and never show success when transport fails.
- Runtime smoke remains deferred until the full refactoring program is complete.

---

### Task 1: Normalize Spammer And Warning SavedVariables

**Files:**
- Modify: `Raid Management Addon/Services/Spammer/Draft.lua`
- Modify: `Raid Management Addon/Services/Warnings/Store.lua`
- Modify: relevant controllers only to consume canonical results.
- Modify: `tests/lua/runtime_harness.lua`
- Create: `tests/test_spammer_warnings_behavior.py`

- [ ] Add reload-shaped tests for malformed/sparse/map-backed records, invalid types, oversized text, negative counts/duration, duplicate/volatile channels, and independent defaults.
- [ ] Normalize spammer fields through a whitelist and persist channel names/identities rather than numeric IDs; clamp or reject invalid operational values with stable reasons.
- [ ] Normalize warnings into dense `{name, content}` records with service-owned byte limits and preserve valid existing entries.
- [ ] Run full gates and commit `fix(chat): Normalize spammer and warning data`.

### Task 2: Make LFM Runtime Bounded And Headless-Safe

**Files:**
- Create only if cohesive: `Raid Management Addon/Services/Spammer/Runtime.lua`
- Modify: `Raid Management Addon/Services/Chat.lua`
- Modify: `Raid Management Addon/Controllers/Spammer.lua`
- Modify: slash/config entry points and TOC as required.
- Modify: tests.

- [ ] Test fresh-load saved draft started from slash/config without opening the frame; output must match canonical draft, not literal `LFM`.
- [ ] Test multiple channels, actual send-attempt cap, minimum interval, start/stop/restart, scheduler nil/throw, stale callbacks, combat/group/channel transitions, and callback once.
- [ ] Move lifecycle out of generic Chat only if the new owner owns draft snapshot, timer, throttled send queue, cap, terminal status, and cancellation.
- [ ] Build start atomically: no ticking/UI lock unless timer creation succeeds; count each destination attempt and stop before the global cap.
- [ ] Run full gates and commit `fix(spammer): Bound LFM delivery lifecycle`.

### Task 3: Validate Chat Transport And Stable Channels

**Files:**
- Modify: `Raid Management Addon/Modules/Comms.lua`
- Modify: `Raid Management Addon/Services/Chat.lua`
- Modify: `Raid Management Addon/Services/Spammer/Draft.lua`
- Modify: `Raid Management Addon/Controllers/Spammer.lua`
- Modify: localization and tests.

- [ ] Resolve persisted channel names to live IDs at send time; reject missing/ambiguous channels and never send to a stale numeric ID after reload/rejoin.
- [ ] Make `SendChat` return boolean/reason, contain WoW API errors, and validate group/guild/channel/rank availability immediately before the effect.
- [ ] Aggregate per-destination outcomes; stop/report terminal failure without false success while preserving successful attempt accounting.
- [ ] Run full gates and commit `fix(chat): Propagate delivery outcomes`.

### Task 4: Harden Warning Storage And Announcement Results

**Files:**
- Modify: `Raid Management Addon/Services/Warnings/Store.lua`
- Modify: `Raid Management Addon/Services/Chat.lua`
- Modify: `Raid Management Addon/Controllers/Warnings.lua`
- Modify: localization and tests.

- [ ] Test corrupted/holey SavedVariables, API/slash oversized text, duplicate names, transport failure, outside-group fallback, permission/rank changes, and controller feedback.
- [ ] Keep warning mutations atomic and service-validated; `Announce` returns `{sent, channel, fallback, reason}` or an equivalent stable result.
- [ ] Controllers/slash report the real terminal outcome; local fallback is explicit and is not represented as a successful raid send.
- [ ] Run full gates and commit `fix(warnings): Report announcement outcomes`.

### Task 5: Synchronize Draft Invalidation And Report Coherence

**Files:**
- Modify: `Raid Management Addon/Services/Spammer/Draft.lua`
- Modify: `Raid Management Addon/Controllers/Spammer.lua`
- Modify: `Raid Management Addon/Controllers/Config.lua`
- Modify: tests.
- Create: `docs/SPAMMER_WARNINGS_HARDENING_REPORT.md`
- Modify: `docs/FEATURE_API_MAP.md`, `docs/ARCHITECTURE.md`, `docs/VALIDATION.md` only for final contracts.

- [ ] Add a completed-state draft-change event or one owner action so Config clear invalidates loaded UI predictably; define whether active runtime keeps its immutable snapshot or stops.
- [ ] Test clear before/after frame creation, while active, during pending callbacks, and subsequent headless start.
- [ ] Run complete unittest, TOC, Lua 5.1, xpcall, XML, whole-addon luacheck and `git diff --check` gates.
- [ ] Record behavior deltas, SavedVariables/channel migration, TOC/registry coherence, exact limits, validation evidence and `runtime smoke: deferred by user until the full refactoring program is complete`.
- [ ] Commit `docs(chat): Record spammer and warning hardening`.
