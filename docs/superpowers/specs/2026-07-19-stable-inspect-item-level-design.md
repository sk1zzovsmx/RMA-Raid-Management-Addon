# Stable Inspect Item Level Design

## Problem

Raid recovery can suspend with `TIMEOUT` after `/reload` even when the local
archive exists. The active raid snapshot is rejected because its stored digest
no longer matches the digest recomputed from SavedVariables.

The demonstrated cause is `avgIlvl`. At runtime the inspect service produced
`243.11764705882354`; WoW persisted it as `243.1176470588235`. After reload the
canonical serializer observed a different floating-point value, changing the
raid digest from `959d733b:1093` to `923a7338:1093`. Recovery correctly refused
to trust or overwrite the inconsistent snapshot and eventually timed out.

## Decision

Persist `avgIlvl` as a non-negative integer, truncating the fractional part
before the inspect snapshot becomes raid state:

```text
243.11764705882354 -> 243
```

This is deliberate truncation, not rounding. The exact fractional average is
not restore-critical, the UI already presents item level as an integer, and an
integer has a stable SavedVariables representation.

## Ownership And Data Flow

`Services/EquipInspect.lua` remains the owner of the persisted inspect shape.
Its existing compaction step will normalize a valid `avgIlvl` with Lua 5.1-safe
integer truncation before calling `CommitRaidInspectSnapshot`.

The resulting flow is unchanged apart from the normalized value:

```text
inspect result -> persisted inspect compaction -> PLAYER_UPDATED event
               -> authoritative raid state -> digest -> replication
```

The database store, event schema, sync protocol, and digest algorithm will not
gain a second normalization rule. All clients receive the already-canonical
integer through the existing event and snapshot paths.

For a numeric item level, the implementation applies `math.floor` once in this
owner. Missing or non-numeric values keep the current compact snapshot behavior.
No generic numeric canonicalizer, additional validation policy, or new utility
module will be introduced.

## Existing Beta Data

There is no migration or digest compatibility layer for the currently corrupt
beta archive. After the fix is verified and deployed, `RMA_Raids` will be reset
with all WoW clients closed. Other `RMA_*` SavedVariables remain untouched.

This reset is acceptable because the user explicitly approved starting the beta
raid database clean. It also prevents an old inconsistent archive from masking
the result of the new smoke test.

## Compatibility

- Raid schema remains `6`.
- Sync protocol remains `3`.
- Wire payload structure is unchanged.
- Legacy receive behavior is unchanged.
- UI layout is unchanged. The displayed item level follows the stored truncated
  integer, so `243.9` is deliberately shown as `243`, not rounded to `244`.
- The recovery barrier and digest validation remain fail-closed.

## Tests

The implementation will be test-driven and will prove:

1. A fractional inspect average is committed as the expected truncated integer.
2. The authoritative `PLAYER_UPDATED` state contains only that integer.
3. The raid digest remains identical after a SavedVariables-style numeric
   serialization and reload round trip.
4. Existing raid replication tests still pass with the canonical value.

After focused tests, run the relevant replication suite and the full automated
suite, followed by Lua 5.1, TOC, XML-handler, `xpcall`, lint, and diff checks.

## Runtime Smoke

After deployment and the authorized `RMA_Raids` reset:

1. A creates the authoritative raid and records loot; B receives it once.
2. Reload A and wait for reentry recovery; the reuse popup appears without
   `TIMEOUT` or digest warnings.
3. Choose **Yes**; the same raid remains current and a new write replicates.
4. On the next reload choose **No**; the previous raid is completed and exactly
   one new raid is created.
5. A offers a completed historical raid; B accepts it and sees it in Loot
   History, while a repeated identical offer creates no duplicate.

The branch must not be integrated into `codex/loot-bans-optimization` until this
smoke is positive.

## Non-Goals

- Changing the digest algorithm globally.
- Migrating or repairing the current beta archive.
- Changing raid schema or sync protocol versions.
- Refactoring database or synchronization ownership beyond this demonstrated
  persistence defect.
