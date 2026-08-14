# Loot History Sync Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add debug-gated, request-correlated diagnostics that identify the first failing boundary in automatic Loot History synchronization and the Config-panel Require and Push flows without changing their behavior.

**Architecture:** Keep all wire decisions in `Database/DBSyncer.lua` and use one private trace formatter there. `Controllers/Config.lua` logs only its dispatch/result boundary. All templates stay in `Localization/DiagnoseLog.en.lua`; tests extend the existing real DBSyncer fixture and assert that diagnostics observe, but never alter, request and import outcomes.

**Tech Stack:** WoW 3.3.5a, Interface `30300`, Lua 5.1, existing RMA logging/options/diagnostics, Python `unittest`, Lua runtime harness, `luacheck`, and repository WotLK validators.

## Global Constraints

- Work only on `codex/rework-simplification`; do not integrate before the two-client smoke passes.
- Reuse `/rma debug on` and `/rma debug level debug`; add no debug option or SavedVariables field.
- Preserve `RMALogSync`, protocol version 2, payload formats, request authority, import behavior, TOC, and XML.
- Keep new runtime text ASCII and route it through `addon.Diagnose`.
- Never log encoded snapshot/delta contents and add no new per-chunk trace.
- Add no module, public test API, polling loop, buffer, compatibility wrapper, or behavioral fix.
- Every task starts with a focused failing test, makes the smallest passing change, runs focused validation, receives an independent review, and creates one atomic commit.

---

### Task 1: Trace automatic revision and recovery boundaries

**Files:**

- Modify: `Raid Management Addon/Localization/DiagnoseLog.en.lua:249-268`
- Modify: `Raid Management Addon/Database/DBSyncer.lua:150-170, 471-510, 709-760, 864-945, 1780-1900`
- Modify: `tests/lua/runtime_harness.lua:7182-7465, 7631-7786`
- Modify: `tests/test_sync_communications_behavior.py`

**Interfaces:**

- Consumes: `Options.IsDebugEnabled()`, `addon:debug(message)`, and existing sync state.
- Produces: private `traceSync(eventName, details)` and the diagnostic template `Diag.D.LogSyncTrace`; neither is exported.

- [ ] **Step 1: Add debug capture to the real DBSyncer fixture**

Extend the fixture state and existing stubs:

```lua
debugEnabled = false,
debugMessages = {},
```

```lua
addon.Options = {
    RegisterNamespace = function(_, defaults)
        fixture.options = defaults or {}
        return { Get = function(_, key) return fixture.options[key] end }
    end,
    IsDebugEnabled = function() return fixture.debugEnabled end,
}

addon.debug = function(_, message)
    fixture.debugMessages[#fixture.debugMessages + 1] = tostring(message)
end

function fixture:HasDebug(fragment)
    for i = 1, #self.debugMessages do
        if string.find(self.debugMessages[i], fragment, 1, true) then return true end
    end
    return false
end
```

- [ ] **Step 2: Write failing automatic trace cases**

Add `sync_diagnostics_are_debug_gated` and `sync_diagnostics_trace_revision_pull`:

```lua
function cases.sync_diagnostics_are_debug_gated(addon)
    local fixture = installRealDbSyncerFixture(addon)
    fixture.lootMethod = "master"
    fixture.localMasterLooter = true
    fixture.localRevision = 1
    fixture:TriggerRaidLootUpdate(41, { lootNid = 1 })
    assertEqual(0, #fixture.debugMessages, "disabled debug emitted sync diagnostics")
    print("PASS sync_diagnostics_are_debug_gated")
end

function cases.sync_diagnostics_trace_revision_pull(addon)
    local fixture, syncer = installRealDbSyncerFixture(addon)
    fixture.debugEnabled = true
    fixture.lootMethod = "master"
    fixture.lootAuthority = "Master-Test Realm"
    fixture.roster = {
        { name = "Master-Test Realm", rank = 0 },
        { name = "Tester-Test Realm", rank = 0 },
    }
    syncer:OnAddonMessage(
        "RMALogSync",
        table.concat({ "RV", 2, 88, "Naxxramas", 25, 1, 3 }, "\t"),
        "RAID",
        "Master-Test Realm"
    )
    assertTrue(fixture:HasDebug("event=RV_RECV"), "missing revision receive trace")
    assertTrue(fixture:HasDebug("event=RV_ACCEPT"), "missing revision acceptance trace")
    assertTrue(fixture:HasDebug("event=PULL_SCHEDULE"), "missing pull schedule trace")
    assertTrue(fixture:FireTimer(syncer._noticePullHandle), "notice pull did not fire")
    assertTrue(fixture:HasDebug("event=PULL_FIRE"), "missing pull fire trace")
    assertTrue(fixture:HasDebug("event=RQ_SEND"), "missing targeted request trace")
    assertTrue(fixture:HasDebug("req=generated-1"), "request trace lacks correlation ID")
    print("PASS sync_diagnostics_trace_revision_pull")
end
```

Add Python wrappers using `run_lua_case(...)`.

- [ ] **Step 3: Run the focused cases and confirm RED**

Run:

```powershell
py -3 -m unittest tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_sync_diagnostics_are_debug_gated tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_sync_diagnostics_trace_revision_pull -v
```

Expected: the gated case passes, while the trace case fails because `[SyncTrace]` events do not exist.

- [ ] **Step 4: Add the single private trace formatter**

Add the localized template:

```lua
Diag.D.LogSyncTrace = "[SyncTrace] event=%s %s"
```

Immediately after the existing debug-option helper in `DBSyncer.lua`, add:

```lua
local function traceSync(eventName, details)
    if not isDebugEnabled() then return end
    addon:debug((Diag.D.LogSyncTrace):format(tostring(eventName), tostring(details or "")))
end
```

Do not export this function or retain trace state.

- [ ] **Step 5: Instrument automatic boundaries without changing decisions**

Add calls adjacent to existing branches:

```lua
traceSync("RV_SEND", format(
    "raidNid=%s revision=%s queued=%s",
    tostring(raidNid), tostring(revision), tostring(queued == true)
))
```

```lua
traceSync("RV_RECV", format(
    "from=%s sourceRaidNid=%s revision=%s",
    tostring(sender), tostring(sourceRaidNid), tostring(revision)
))
```

Each current early return in `handleRevisionNotice` gets exactly one
`RV_REJECT` before returning, using `disabled`, `sender_not_authority`,
`signature_mismatch`, `stale_revision`, or `pending_other_lineage`. The success
path emits `RV_ACCEPT` and `PULL_SCHEDULE`. The timer callback emits
`PULL_FIRE` before calling `requestLoggerSync`.

After a successful `sendRequest`, emit:

```lua
traceSync("RQ_SEND", format(
    "mode=%s req=%s target=%s raidRef=%s sourceRaidNid=%s revision=%s",
    tostring(MODE_SYNC), tostring(requestId), tostring(target or "GROUP"),
    tostring(currentRaid.raidNid), tostring(requestedSourceRaidNid or lineageSourceRaidNid or 0),
    tostring(signature.sinceRevision or 0)
))
```

In `terminalizeRequest`, emit one `REQUEST_END` after cleanup with `mode`,
`req`, and `reason`. Do not add logs to individual chunk loops.

- [ ] **Step 6: Run focused GREEN and regression checks**

```powershell
py -3 -m unittest tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_sync_diagnostics_are_debug_gated tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_sync_diagnostics_trace_revision_pull tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_revision_notice_rejects_stale_mismatch_and_non_master tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_targeted_timeout_retries_once -v
luacheck "Raid Management Addon/Database/DBSyncer.lua" "Raid Management Addon/Localization/DiagnoseLog.en.lua"
git diff --check
```

Expected: all cases pass; request counts, timers, retries, and imports remain unchanged.

- [ ] **Step 7: Commit Task 1**

```powershell
git add -- "Raid Management Addon/Database/DBSyncer.lua" "Raid Management Addon/Localization/DiagnoseLog.en.lua" "tests/lua/runtime_harness.lua" "tests/test_sync_communications_behavior.py"
git commit -m "feat(sync): trace automatic convergence boundaries"
```

---

### Task 2: Trace Config Require and Push admission

**Files:**

- Modify: `Raid Management Addon/Controllers/Config.lua:6-12, 1116-1142`
- Modify: `Raid Management Addon/Localization/DiagnoseLog.en.lua:249-270`
- Modify: `Raid Management Addon/Database/DBSyncer.lua:395-469, 947-1027, 1061-1100, 1700-1778`
- Modify: `tests/test_config_xml_contract.py`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_sync_communications_behavior.py`

**Interfaces:**

- Consumes: private `traceSync(eventName, details)` from Task 1.
- Produces: reason-bearing `CONFIG_REQ`, `CONFIG_PUSH`, `RQ_ACCEPT`, `RQ_REJECT`, `PUSH_ACCEPT`, and `PUSH_REJECT` diagnostics. Existing return values remain unchanged.

- [ ] **Step 1: Add failing Config dispatch contract coverage**

Add a focused source contract to `tests/test_config_xml_contract.py` which
loads `Controllers/Config.lua` and asserts that the action owner emits both
dispatch and result phases through `Diag.D.LogSyncConfigAction`:

```python
def test_logger_sync_panel_actions_emit_debug_gated_results(self) -> None:
    source = CONTROLLER_LUA.read_text(encoding="utf-8")
    self.assertIn("Diag.D.LogSyncConfigAction", source)
    self.assertIn('traceConfigSyncAction("CONFIG_REQ", "dispatch"', source)
    self.assertIn('traceConfigSyncAction("CONFIG_PUSH", "dispatch"', source)
    self.assertIn('traceConfigSyncAction(eventName, "result"', source)
```

- [ ] **Step 2: Add failing Require and Push admission cases**

Add one Lua case that enables debug, calls `RequestLoggerReq`, feeds the
matching `RQ` to a responder-shaped fixture, and then feeds representative
`PUSH` snapshot envelopes with and without consent. Assert:

```lua
assertTrue(fixture:HasDebug("event=RQ_SEND mode=REQ"), "Require send trace missing")
assertTrue(fixture:HasDebug("event=RQ_ACCEPT mode=REQ"), "Require acceptance trace missing")
assertTrue(fixture:HasDebug("event=RQ_REJECT"), "Require rejection trace missing")
assertTrue(fixture:HasDebug("reason=raid_not_found"), "Require lookup reason missing")
assertTrue(fixture:HasDebug("event=PUSH_REJECT"), "Push rejection trace missing")
assertTrue(fixture:HasDebug("reason=no_push_consent"), "Push consent reason missing")
```

Capture send/import counts before each diagnostic assertion and prove they are
unchanged by logging.

- [ ] **Step 3: Run the focused tests and confirm RED**

```powershell
py -3 -m unittest tests.test_config_xml_contract.ConfigLayoutOwnershipTest.test_logger_sync_panel_actions_emit_debug_gated_results tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_sync_diagnostics_trace_manual_admission -v
```

Expected: both fail because Config result traces and reason-bearing manual
admission traces are absent.

- [ ] **Step 4: Instrument Config dispatch and returned outcome**

Add:

```lua
local Diag = addon.Diag

local function traceConfigSyncAction(eventName, phase, raidRef, target, result, reason)
    if not (Options.IsDebugEnabled() and addon.debug) then return end
    addon:debug((Diag.D.LogSyncConfigAction):format(
        tostring(eventName), tostring(phase), tostring(raidRef or 0),
        tostring(target or ""), tostring(result), tostring(reason or "none")
    ))
end
```

With this template:

```lua
Diag.D.LogSyncConfigAction =
    "[SyncTrace] event=%s phase=%s raidRef=%s target=%s result=%s reason=%s"
```

Refactor only `RequestLoggerSyncPanelAction` so Require and Push store their
existing return values, log them, and return the same pair:

```lua
if actionName == "require" and syncer.RequestLoggerReq then
    local target = GetOptionByKey("syncRequirePlayer")
    traceConfigSyncAction("CONFIG_REQ", "dispatch", currentRaid, target, "pending", "none")
    local result, reason = syncer:RequestLoggerReq(currentRaid, target)
    traceConfigSyncAction("CONFIG_REQ", "result", currentRaid, target, result, reason)
    return result, reason
elseif actionName == "push" and syncer.BroadcastLoggerPush then
    local target = GetOptionByKey("syncPushPlayer")
    traceConfigSyncAction("CONFIG_PUSH", "dispatch", currentRaid, target, "pending", "none")
    local result, reason = syncer:BroadcastLoggerPush(currentRaid, target)
    traceConfigSyncAction("CONFIG_PUSH", "result", currentRaid, target, result, reason)
    return result, reason
elseif actionName == "sync" and syncer.RequestLoggerSync then
    return syncer:RequestLoggerSync()
end
```

Keep the Sync Now branch and unsupported-action warning behavior unchanged.

- [ ] **Step 5: Add reason-bearing manual admission traces**

For `handleIncomingRequest`, preserve the current boolean gates but emit
`RQ_REJECT` immediately before each existing return. Use distinct reasons for
`not_in_group`, `sender_not_member`, `sender_not_authority`, `rate_limited`,
`raid_not_found`, and `signature_mismatch`. Emit `RQ_ACCEPT` only after the
raid is resolved and before delta/snapshot construction.

Change private consent helpers to return an additional reason without changing
their first three return values. `acquirePushConsent` returns `nil, reason` on
the existing rejection branches and the snapshot admission caller logs:

```lua
traceSync("PUSH_REJECT", format(
    "mode=%s req=%s from=%s raidNid=%s reason=%s",
    tostring(MODE_PUSH), tostring(requestId), tostring(sender),
    tostring(raidNid), tostring(reason or "no_push_consent")
))
```

On success it emits `PUSH_ACCEPT` with `consent=correlated` or
`consent=configured`. The helpers must not grant consent in any new case.

After successful manual request or push queueing, emit `RQ_SEND mode=REQ` or
`SN_SEND mode=PUSH`; on failure emit the same boundary with `queued=false` and
the transport reason.

- [ ] **Step 6: Run focused GREEN and authority regressions**

```powershell
py -3 -m unittest tests.test_config_xml_contract.ConfigLayoutOwnershipTest.test_logger_sync_panel_actions_emit_debug_gated_results tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_sync_diagnostics_trace_manual_admission tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_real_db_syncer_requires_push_consent tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_real_db_syncer_consumes_push_consent_once tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_sync_authorization_fails_closed -v
luacheck "Raid Management Addon/Controllers/Config.lua" "Raid Management Addon/Database/DBSyncer.lua" "Raid Management Addon/Localization/DiagnoseLog.en.lua"
git diff --check
```

Expected: all pass and the pre-existing consent/authority assertions remain
unchanged.

- [ ] **Step 7: Commit Task 2**

```powershell
git add -- "Raid Management Addon/Controllers/Config.lua" "Raid Management Addon/Database/DBSyncer.lua" "Raid Management Addon/Localization/DiagnoseLog.en.lua" "tests/test_config_xml_contract.py" "tests/lua/runtime_harness.lua" "tests/test_sync_communications_behavior.py"
git commit -m "feat(sync): trace manual history transfer admission"
```

---

### Task 3: Trace import outcomes and prepare the evidence smoke

**Files:**

- Modify: `Raid Management Addon/Database/DBSyncer.lua:709-799, 1109-1297, 1401-1685`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_sync_communications_behavior.py`
- Modify: `docs/SYNC_COMMUNICATIONS_HARDENING_REPORT.md`

**Interfaces:**

- Consumes: `traceSync(eventName, details)` and reason-bearing admission from Tasks 1-2.
- Produces: one `IMPORT_APPLY`, `IMPORT_REJECT`, or `REQUEST_END` outcome per correlated request and documented two-client evidence steps.

- [ ] **Step 1: Add failing import outcome coverage**

Extend the existing correlated snapshot round-trip and atomic failure cases so
debug-enabled fixtures assert:

```lua
assertTrue(fixture:HasDebug("event=IMPORT_APPLY mode=SYNC"), "sync import trace missing")
assertTrue(fixture:HasDebug("req=generated-1"), "import trace lacks request ID")
assertTrue(fixture:HasDebug("loot=3"), "import trace lacks resulting loot count")
assertTrue(fixture:HasDebug("event=IMPORT_REJECT"), "failed import trace missing")
assertTrue(fixture:HasDebug("reason=merge_failed"), "failed import reason missing")
```

Add a payload confidentiality assertion using a unique fixture payload marker:

```lua
for i = 1, #fixture.debugMessages do
    assertTrue(
        not string.find(fixture.debugMessages[i], "SECRET_PAYLOAD_MARKER", 1, true),
        "sync diagnostics exposed payload contents"
    )
end
```

- [ ] **Step 2: Run focused cases and confirm RED**

```powershell
py -3 -m unittest tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_notice_snapshot_round_trip_preserves_history_fields tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_sync_history_import_is_atomic_across_build_and_commit_failures -v
```

Expected: existing behavioral assertions pass, new import trace assertions fail.

- [ ] **Step 3: Instrument one terminal result per request**

After successful snapshot or delta import, emit:

```lua
traceSync("IMPORT_APPLY", format(
    "mode=%s req=%s from=%s localRaid=%s sourceRaidNid=%s revision=%s loot=%s",
    tostring(mode), tostring(requestId), tostring(sender), tostring(currentId or raidId or 0),
    tostring(sourceRaidNid or 0), tostring(resultRevision or 0), tostring(#(raid.loot or {}))
))
```

Immediately before the existing failed-import terminal/reject call, emit
`IMPORT_REJECT` with the same identity fields and the existing reason. Do not
log the encoded payload, parsed row contents, item links, or player history.

Keep `REQUEST_END` in `terminalizeRequest` as the only general terminal trace;
do not duplicate it in every failure branch.

- [ ] **Step 4: Update the hardening report with the exact smoke procedure**

Add a short diagnostics section documenting:

```text
/rma debug on
/rma debug level debug
```

Run automatic sync, Require, and Push once each on clients A and B. Compare
`[SyncTrace]` lines by `req` or `revision`; record the first missing expected
event. State explicitly that the diagnostic batch changes no protocol or sync
behavior and that a separate fix requires the captured evidence.

- [ ] **Step 5: Run complete offline validation**

```powershell
py -3 -m unittest discover -s tests -p "test_*.py" -v
py -3 "..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py" "Raid Management Addon/Raid Management Addon.toc"
py -3 "..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py" "Raid Management Addon"
py -3 "..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py" "Raid Management Addon"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon/UI" -g "*.xml"
luacheck "Raid Management Addon" --exclude-files "Raid Management Addon/Libs/**"
git diff --check
git status --short --branch
```

Expected: Python suite, TOC, Lua 5.1, xpcall, luacheck, and diff checks pass;
the XML search returns no matches. Report the existing focused StyLua EOL debt
honestly and do not bulk-format unrelated runtime files.

- [ ] **Step 6: Commit Task 3**

```powershell
git add -- "Raid Management Addon/Database/DBSyncer.lua" "tests/lua/runtime_harness.lua" "tests/test_sync_communications_behavior.py" "docs/SYNC_COMMUNICATIONS_HARDENING_REPORT.md"
git commit -m "feat(sync): trace history import outcomes"
```

- [ ] **Step 7: Stop before behavioral fixes or integration**

Keep `codex/rework-simplification` and its worktree intact. Do not change raid
reference semantics, officer consent, authority, retry behavior, or imports
until the user supplies the two-client trace. Do not integrate before that
diagnostic smoke is reviewed.
