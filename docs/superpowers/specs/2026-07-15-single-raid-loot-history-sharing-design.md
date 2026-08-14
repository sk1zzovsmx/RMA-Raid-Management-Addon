# Single-Raid Loot History Sharing Design

Date: 2026-07-15
Status: Approved design, pending written-spec review

## Problem

The existing Loot History synchronization actions work, but the operational
`Push`, `Require`, and `Sync Now` controls are buried under Escape, Interface,
AddOns, and Loot History. That location is suitable for persistent preferences,
not for actions performed while reviewing raid history.

The replacement must make one selected raid easy to send or recover without
introducing full-database sharing, silent remote writes, or another snapshot
transport.

## Product Contract

Loot History owns one compact `Share` action for the selected raid. A player can:

- offer the selected raid to one current group member; or
- recover the current raid from the authoritative loot source.

A received offer never changes Loot History until the recipient explicitly
accepts it. After acceptance, the existing correlated request, snapshot, and
atomic import flow performs the transfer.

## Scope

- Add `Share` beside the existing Loot History actions.
- Show a compact dialog for the selected raid and current group recipient.
- Add an explicit accept or decline prompt on the recipient.
- Reuse existing single-raid request and snapshot synchronization.
- Move the operational `Push`, `Require`, and `Sync Now` actions out of Config.
- Keep persistent synchronization preferences in Config.
- Keep the existing slash commands for diagnostics and advanced use.

## Non-goals

- Sharing or browsing the complete remote database.
- Adding a remote raid catalog.
- Discovering addon availability for every roster member.
- Adding per-chunk acknowledgements or a second snapshot format.
- Persisting pending offers in SavedVariables.
- Redesigning Loot History, Config, or the synchronization architecture.

## Considered Approaches

### Share action in Loot History with recipient consent (selected)

The sender offers only a raid summary and source raid identifier. The recipient
accepts before requesting the existing snapshot. This places the action where
the selected raid is already visible and preserves the current consent and
import contracts.

### Move the existing Push controls unchanged

Directly relocating `Push` would remain dependent on authorization configured
elsewhere and could appear successful while the receiver rejects it. This is
rejected because the UI would hide an important precondition.

### Automatic sharing on raid selection

Automatic transfer removes explicit recipient consent and creates unnecessary
traffic. It is rejected.

## User Interface

Loot History adds a `Share` button beside `Export` and `Delete`. It opens a
small RMA-styled dialog rather than a new screen.

The dialog shows:

- zone or raid name;
- date and time;
- difficulty or raid size when available;
- loot-record count; and
- a dropdown of current party or raid members, excluding the local player.

The dialog provides two actions:

- `Send selected raid` sends an offer to the chosen group member.
- `Recover current raid` requests the current raid from the known
  authoritative source.

`Send selected raid` is disabled without a selected raid, a recipient, and a
valid group. `Recover current raid` is disabled without a current raid, a
group, or an identifiable authority. Labels and feedback use the existing
localization and chat/UI conventions.

The recipient sees a compact confirmation containing the sender and raid
summary, with `Accept` and `Decline`. Decline and expiry leave all data
unchanged.

## Data Flow: Send Selected Raid

1. Player A selects one raid, opens `Share`, and chooses player B.
2. A validates that the raid still exists and B is a current group member.
3. A whispers a lightweight raid offer containing the source `raidNid` and
   display summary, but no Loot History records.
4. B validates the real addon-message sender, target, group membership,
   envelope, and offer lifetime.
5. B accepts or declines the offer.
6. On acceptance, B calls the existing single-raid request path with A and A's
   source `raidNid`.
7. A answers through the existing correlated snapshot transport.
8. B imports atomically through the existing validation and merge owner and
   refreshes Loot History.

No additional acknowledgement protocol is required. The correlated request
and completed import already express progress and completion.

## Data Flow: Recover Current Raid

`Recover current raid` resolves the current authoritative loot source and uses
the existing current-raid synchronization request. It does not create an offer
because the local player is explicitly initiating recovery. Existing authority,
lineage, snapshot validation, and atomic import rules remain unchanged.

## Wire Contract

Add one backward-compatible message kind on the existing Loot History sync
prefix for the offer. Its bounded payload contains only:

- protocol version;
- offer identifier;
- source `raidNid`;
- intended recipient; and
- a short raid display summary.

The offer is not persistence data and cannot invoke an import. Unknown message
kinds remain ignored, so older clients continue operating without errors. The
snapshot and delta formats do not change.

## Runtime State And Validation

- Offers expire after 30 seconds.
- At most one pending offer per sender is kept in runtime memory.
- A newer valid offer from the same sender replaces the older prompt.
- Duplicate, expired, malformed, self-addressed, or wrong-target offers are
  ignored.
- Both parties must still be group members when an offer is sent or accepted.
- The source raid must still exist when A receives the accepted request.
- Accepting a valid offer starts exactly one request.
- Pending offers are discarded naturally on reload and never enter
  SavedVariables.

These rules are implemented in the existing Loot History UI/controller and
database synchronization owners. No new generic module or compatibility layer
is introduced.

## Config And Slash Commands

Remove the operational `Push`, `Require`, and `Sync Now` rows from the Config
panel. Do not silently clear any already saved preference values. Persistent
synchronization settings remain in Config.

Keep the existing commands:

- `/rma history req <raidNid> <player>`
- `/rma history push <raidNid> <player>`
- `/rma history sync`

They remain useful for diagnosis and advanced/manual recovery; the normal UX
does not require them.

## Failure Handling

- An unavailable or departed recipient produces local feedback and no offer.
- Decline or timeout changes no Loot History data.
- A missing source raid causes the later request to fail through the existing
  diagnosed request path.
- Invalid senders or recipients cannot open an actionable prompt.
- A partial, invalid, or timed-out snapshot never mutates Loot History.
- Duplicate accepted requests remain idempotent under existing import rules.
- Older clients silently ignore the offer and can still use slash commands and
  persistent synchronization.

## Compatibility And Persistence

- No SavedVariables schema change is required.
- No existing saved preference is deleted or rewritten by this UI change.
- The existing addon-message prefix remains unchanged.
- The offer is additive and ignored by older clients.
- Existing request, snapshot, merge, lineage, and deduplication contracts remain
  authoritative.

## Automated Verification

Tests must cover:

- `Share` availability for a selected raid;
- correct raid summary and group-recipient list;
- exclusion of the local player;
- enabled and disabled action states;
- offer envelope send, receive, and validation;
- acceptance starts exactly one existing request;
- decline and 30-second expiry start no request and import no data;
- duplicate and malformed offers are ignored;
- group departure before send or acceptance is handled safely;
- no Loot History data is sent before acceptance;
- atomic import and no duplicate loot records after acceptance;
- `Recover current raid` uses the existing authoritative sync path;
- operational controls are absent from Config while persistent preferences
  remain;
- existing slash commands remain registered; and
- older or unknown message kinds remain harmless.

Run the full Python suite, `tools/check-rma.ps1`, Lua 5.1 validation, `xpcall`
scan, XML handler scan, lint, TOC validation, and `git diff --check`.

## In-Game Smoke Test

With two compatible clients in the same group:

1. A selects one historical raid and offers it to B.
2. B declines; neither history changes.
3. A offers the same raid again and B accepts.
4. B receives that raid without duplicate loot records.
5. B uses `Recover current raid` and receives the current authoritative raid.
6. Both clients reload; no pending offer survives and existing preferences do.
7. The Config panel contains persistent sync preferences but no operational
   sharing actions.

## Acceptance Criteria

- Sharing a selected raid is accessible directly from Loot History.
- The recipient explicitly consents before any history transfer begins.
- Only the selected raid is requested and imported.
- No history data is transmitted in the offer.
- Acceptance reuses the tested request and snapshot path.
- Decline, expiry, invalid input, or partial transfer cannot mutate history.
- Config contains preferences rather than operational sharing actions.
- Existing slash commands and persistent synchronization remain functional.
- No SavedVariables migration, full-database protocol, or new generic module is
  introduced.
- Integration remains suspended until the two-client smoke test passes.
