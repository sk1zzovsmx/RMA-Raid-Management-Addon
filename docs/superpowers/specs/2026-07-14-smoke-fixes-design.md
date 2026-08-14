# Smoke Fixes Design

## Goal

Correct the five behaviors found during the WotLK smoke test without reopening the completed rework or adding recovery frameworks:

1. Loot History raid deletion leaves a stale raid row.
2. Accepted inventory trades can remain uncertain after `TRADE_CLOSED` and block the next award.
3. The manual roll-type selector appears during addon-driven trades.
4. The Spammer presents fixed numeric channels instead of current joined channels.
5. Persistent history sync rejects or unsafely merges a late joiner's independently created raid.

## Chosen Approach

Apply narrow patches inside the existing owners. This is preferred over reverting the hardening commits, which would also remove valid safety fixes, and over rebuilding the affected workflows, which would expand scope and risk.

No new runtime file, generic helper layer, SavedVariables migration, global raid identifier, polling loop, or wire-protocol version is introduced.

## Behavior

### Loot History deletion

`Services/Logger/Actions.lua` remains the mutation owner and continues publishing one `LoggerDataChanged` event. The raid-list controller subscribes to that event and marks its cached data dirty. Existing focus selection and current-raid protection remain unchanged.

### Trade settlement and roll-type selector

`TRADE_CLOSED` retains the existing deferred settlement attempt. If inventory evidence is not ready, one subsequent `BAG_UPDATE` is allowed to retry through the same coalesced settlement path. Success clears the in-flight award exactly once; unresolved evidence remains fail-closed and diagnostic rather than being converted into a false award.

The existing `TradeExecution:HasInFlightAward()` state is the sole discriminator between addon-driven and manual trades. Addon-driven trades always hide manual roll-type controls. Manual trades continue scanning HOLD candidates and showing the selector.

### Spammer channel selection

Replace the ten fixed numeric controls with one WotLK `UIDropDownMenuTemplate` multi-select owned by `Controllers/Spammer.lua`.

- Joined custom channels are read from the live `GetChannelList()` ID/name pairs.
- `YELL` is available.
- `GUILD` is enabled only while the player is in a guild.
- A saved but unavailable channel remains visible, checked, and disabled.
- Rendering or opening the menu never mutates `RMA_Spammer`.
- Only an explicit click on an enabled row changes the saved selection.
- The existing runtime still stops safely when delivery fails.

`Modules/Comms.lua` uses the same WotLK pair-shaped channel data when resolving a channel at send time.

### Late-join history synchronization

`raidNid`, `startTime`, row NIDs, and revision counters created independently by two clients are not treated as shared identity.

For an active persistent sync:

1. The sender and receiver must be in the same live group and match zone, raid size, and difficulty.
2. Under master loot, the master looter is the authoritative responder even without raid rank. Without a master looter, only the raid leader is accepted.
3. Without an established runtime lineage, the receiver requests a full snapshot with revision zero.
4. The full snapshot is validated against the sender's envelope ID and atomically replaces synchronized raid metadata and collections while preserving the receiver's local `raidNid`.
5. The receiver records only runtime lineage: authority name, source `raidNid`, and source revision. It is intentionally not persisted; after reload, a safe full bootstrap runs again.
6. A delta is accepted only while authority, source `raidNid`, and revision still match the lineage. Otherwise the next request falls back to a full snapshot.

Manual REQ/PUSH history transfer keeps its current strict ID and consent semantics.

## Data Integrity

- A bootstrap replaces players, attendance, bosses, loot, counters, start time, and end time as one store-owned transaction.
- The receiver's local outer `raidNid` is preserved.
- Bootstrap does not upsert remote rows into unrelated local row NIDs.
- Failed validation or commit restores the exact original raid.
- Trade confirmation still requires positive inventory evidence.
- Saved unavailable Spammer channels are never silently removed.

## Verification

Each behavior receives a focused failing test before implementation. After the five focused tasks, run one simplicity review, the full Python suite, Lua 5.1/TOC/xpcall/XML/luacheck/diff checks, and a single two-client in-game smoke. Local integration into `codex/loot-bans-optimization` remains forbidden until that smoke passes.
