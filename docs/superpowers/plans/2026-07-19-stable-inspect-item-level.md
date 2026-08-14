# Stable Inspect Item Level Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist equipment average item level as a truncated integer so raid digests remain stable across WoW SavedVariables reloads and reentry recovery can reach the reuse popup.

**Architecture:** Keep canonicalization in the existing persisted-inspect owner, `Services/EquipInspect.lua`, immediately before `CommitRaidInspectSnapshot`. The existing `PLAYER_UPDATED`, raid-state digest, snapshot, and replication paths then consume the same integer without schema, protocol, database-store, or digest changes.

**Tech Stack:** WoW 3.3.5a, Interface `30300`, Lua 5.1, Python `unittest`, the existing Lua runtime harness, `luacheck`, StyLua, and the project WotLK validators.

## Global Constraints

- Work only in the isolated `codex/single-raid-history-sharing` worktree.
- Runtime code must remain Lua 5.1-compatible and use only WotLK 3.3.5a APIs.
- Truncate with `math.floor`: `243.11764705882354` becomes `243`; do not round.
- Keep raid schema `6`, sync protocol `3`, and all wire payload structures unchanged.
- Do not weaken digest validation, recovery barriers, or timeout behavior.
- Do not add a migration, compatibility layer, generic numeric canonicalizer, utility module, or database-store fallback.
- Preserve unrelated changes in `.superpowers/sdd/task-4-report.md` and `.planning/`.
- Do not integrate into `codex/loot-bans-optimization` until the complete two-client in-game smoke is positive.

---

## File Structure

- Modify `Raid Management Addon/Services/EquipInspect.lua`: truncate `avgIlvl` in the existing persisted snapshot compaction owner.
- Modify `tests/lua/runtime_harness.lua`: add one end-to-end inspect persistence regression using the real inspect service and real canonical raid digest implementation.
- Modify `tests/test_raid_recording_integrity_behavior.py`: expose the new Lua regression through Python discovery.
- No production file other than `Services/EquipInspect.lua` changes.

### Task 1: Canonicalize Persisted Inspect Item Level

**Files:**
- Modify: `Raid Management Addon/Services/EquipInspect.lua:43-50,199-230`
- Test: `tests/lua/runtime_harness.lua:5310-5401,6149-6163`
- Test: `tests/test_raid_recording_integrity_behavior.py:93-99`

**Interfaces:**
- Consumes: `compactPersistedInspectSnapshot(snapshot)` and the existing `store:CommitRaidInspectSnapshot(raid, playerNid, compact)` call.
- Produces: an unchanged compact inspect table shape whose numeric `avgIlvl` is always `math.floor(tonumber(snapshot.avgIlvl))` before `PLAYER_UPDATED` is committed.
- Produces no new exported function, event, field, schema version, or wire message.

- [ ] **Step 1: Add the failing Lua behavior case**

Add this case near the existing inspect reload persistence case in `tests/lua/runtime_harness.lua`:

```lua
function cases.equip_inspect_persists_truncated_item_level_with_reload_stable_digest(addon)
	installRaidReplicationEventFixture(addon)
	local fixture, inspect = installEquipInspectFixture(addon)
	local raid = fixture.raids[2]
	local slots = { 1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17, 18 }
	for i = 1, #slots do
		local itemId = 2000 + i
		fixture.itemLinks[slots[i]] = itemLink(itemId)
		fixture.itemInfo[itemId] = i == #slots and 245 or 243
	end

	local committedPayload
	local originalCommit = fixture.store.CommitAuthoritativeEvent
	fixture.store.CommitAuthoritativeEvent = function(self, raidUid, eventType, payload)
		if eventType == "PLAYER_UPDATED" then committedPayload = deepCopy(payload) end
		return originalCommit(self, raidUid, eventType, payload)
	end

	assertEqual(true, inspect:ForcePlayer(2, 21), "fractional inspect starts")
	fixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid1")
	local persisted = assert(raid.players[1].inspect)
	assertEqual(243, persisted.avgIlvl, "persisted average must truncate toward zero")
	assertEqual(243, assert(raid.inspect.players[21]).avgIlvl,
		"canonical inspect mirror must use the truncated average")
	assertEqual(243, assert(committedPayload).player.inspect.avgIlvl,
		"PLAYER_UPDATED must carry the truncated average")

	local digestBeforeReload = assert(addon.DB.RaidEvents.DigestState(raid))
	local reloaded = deepCopy(raid)
	reloaded.players[1].inspect.avgIlvl = tonumber(string.format("%.15g", persisted.avgIlvl))
	reloaded.inspect.players[21].avgIlvl = tonumber(string.format("%.15g", persisted.avgIlvl))
	assertEqual(digestBeforeReload, addon.DB.RaidEvents.DigestState(reloaded),
		"SavedVariables numeric reload must preserve the raid digest")
	print("PASS equip_inspect_persists_truncated_item_level_with_reload_stable_digest")
end
```

This fixture uses sixteen item levels of `243` and one of `245`, reproducing
`4133 / 17 = 243.11764705882354` without injecting a fractional value directly
into persistence.

- [ ] **Step 2: Register the Python test**

Add this method beside the other inspect reload test in
`tests/test_raid_recording_integrity_behavior.py`:

```python
def test_equip_inspect_persists_truncated_item_level_with_reload_stable_digest(self) -> None:
    result = run_lua_case("equip_inspect_persists_truncated_item_level_with_reload_stable_digest")
    self.assertIn(
        "PASS equip_inspect_persists_truncated_item_level_with_reload_stable_digest",
        result.stdout,
    )
```

- [ ] **Step 3: Run the focused test and verify RED**

Run:

```powershell
python -m unittest tests.test_raid_recording_integrity_behavior.RaidRecordingIntegrityBehaviorTests.test_equip_inspect_persists_truncated_item_level_with_reload_stable_digest -v
```

Expected: FAIL because the committed `avgIlvl` is still the fractional
`243.11764705882354`, so the assertion expecting `243` fails.

- [ ] **Step 4: Implement the minimal normalization at the persistence owner**

In `Raid Management Addon/Services/EquipInspect.lua`, bind `math.floor` with the
other local standard-library references:

```lua
local floor = math.floor
```

Then resolve the persisted average once at the start of
`compactPersistedInspectSnapshot` and use it in the compact table:

```lua
	local avgIlvl = tonumber(snapshot.avgIlvl)
	if avgIlvl then
		avgIlvl = floor(avgIlvl)
	end

	local compact = {
		-- existing fields remain unchanged
		avgIlvl = avgIlvl,
		-- existing fields remain unchanged
	}
```

Do not change `collectItems`, `DBRaidStore.lua`, `DBRaidEvents.lua`, the schema,
or the sync protocol.

- [ ] **Step 5: Run the focused test and verify GREEN**

Run the same command from Step 3.

Expected: `Ran 1 test` and `OK`, with the Lua harness printing
`PASS equip_inspect_persists_truncated_item_level_with_reload_stable_digest`.

- [ ] **Step 6: Run the nearest regression suites**

Run:

```powershell
python -m unittest tests.test_raid_recording_integrity_behavior -v
python -m unittest tests.test_raid_replication_behavior -v
```

Expected: both modules pass. Inspect persistence remains atomic and replicated;
raid digest/recovery behavior has no regression.

- [ ] **Step 7: Run the full static verification once**

Run:

```powershell
python -m unittest discover -s tests -p "test_*.py" -v
py -3 "C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py" "Raid Management Addon\Raid Management Addon.toc"
py -3 "C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py" "Raid Management Addon"
py -3 "C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py" "Raid Management Addon"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon\UI" -g "*.xml"
luacheck "Raid Management Addon" --exclude-files "Raid Management Addon/Libs/**"
stylua --check -- "Raid Management Addon/Services/EquipInspect.lua" "tests/lua/runtime_harness.lua"
git diff --check
```

Expected: tests, TOC, Lua 5.1, `xpcall`, `luacheck`, and diff checks pass; the
XML search returns no matches (exit `1`, which is success for this policy).
Record any existing focused StyLua/EOL baseline honestly and do not bulk-format
unrelated code. `tools/check-rma.ps1` is absent and must not be reported as run.

- [ ] **Step 8: Review scope and commit the atomic fix**

Confirm that the diff contains only the three planned files and that no schema,
protocol, digest, database-store, or wire-format code changed. Then run:

```powershell
git add -- "Raid Management Addon/Services/EquipInspect.lua" "tests/lua/runtime_harness.lua" "tests/test_raid_recording_integrity_behavior.py"
git commit -m "fix(sync-04): stabilize persisted inspect item level"
```

Expected: one atomic runtime/test commit.

---

## Post-Implementation Handoff

After the subagent implementation passes specification review and code-quality
review, the root coordinator must:

1. Re-run the focused test and full verification from fresh command output.
2. Deploy the verified addon from this isolated worktree to the game addon
   directory and verify source/destination hashes.
3. Confirm that every WoW client using the SavedVariables file is closed.
4. Back up the account SavedVariables file, then reset only `RMA_Raids`; preserve
   every other `RMA_*` key.
5. Ask the user to run the five-step two-client smoke from the approved design.

If any WoW process is running, do not edit SavedVariables and do not terminate
the process without explicit user permission. Do not integrate the branch until
the user reports the complete smoke as positive.
