# Loot History Sync Diagnostics Design

## Goal

Expose the first failing boundary in Loot History synchronization across two
WotLK clients without changing synchronization behavior. The diagnostic scope
covers automatic Master Loot convergence and the manual Config-panel
`Require Database` and `Push Database` actions.

Current smoke evidence shows that both manual actions report that data was sent,
but the peer Loot History does not change. This proves the Config click handler
and initial outbound queue are reached, while remote admission, raid resolution,
response generation, or import may still stop the flow.

## Constraints

- Reuse the existing global debug option and log-level system.
- Emit diagnostics only while debug logging is enabled.
- Keep `RMALogSync`, protocol version 2, payload formats, SavedVariables, TOC,
  XML, synchronization authority, and import behavior unchanged.
- Do not add a sync-specific toggle, buffer, polling loop, public test API, or
  new module.
- Keep runtime strings ASCII and localized through `addon.Diagnose`.
- Do not log encoded snapshot or delta contents.
- Do not emit one new diagnostic per chunk; the existing chunk diagnostics are
  sufficient when deeper transport inspection is needed.

## Trace Model

Every new line starts with `[SyncTrace]` and carries the fields available at
that boundary. Request-correlated lines include `mode` and `req`. Names,
references, revisions, and rejection reasons use stable key-value fields so
the output from two clients can be compared directly.

The expected successful sequences are:

```text
Automatic: RV_SEND -> RV_ACCEPT -> PULL_SCHEDULE -> RQ_SEND -> RQ_RECV -> RQ_ACCEPT -> SN/DL_SEND -> IMPORT
Require:   CONFIG_REQ -> RQ_SEND -> RQ_RECV -> RQ_ACCEPT -> SN_SEND -> IMPORT
Push:      CONFIG_PUSH -> SN_SEND -> PUSH_ACCEPT -> IMPORT
```

Rejected or terminated paths end with a reason-bearing line instead of
silently returning. Expected reason values include:

```text
disabled
not_in_group
sender_not_member
sender_not_authority
responder_not_authority
channel_not_supported
sender_not_officer
target_mismatch
raid_not_found
signature_mismatch
stale_revision
no_push_consent
incoming_capacity
rate_limited
queue_failed
timeout
```

## Diagnostic Boundaries

### Config dispatch

`Controllers/Config.lua` logs `CONFIG_REQ` or `CONFIG_PUSH` immediately before
delegating to `DBSyncer`. It records the local raid reference and trimmed target
supplied by the panel. It also logs the returned boolean and reason so a
Config-to-syncer failure is distinguishable from a later remote rejection.

### Revision and recovery

`Database/DBSyncer.lua` logs:

- `RV_SEND` with local raid NID, revision, and queue result;
- `RV_RECV` before validation;
- `RV_ACCEPT` or `RV_REJECT` with authority, signature, lineage, stale, or
  disabled reason;
- `PULL_SCHEDULE` and `PULL_FIRE` with master target and local/source raid NID;
- request terminalization with request ID and reason.

### Manual request and push

The existing request/snapshot messages remain, but admission becomes
observable:

- `RQ_RECV` is followed by `RQ_ACCEPT` or `RQ_REJECT` before any snapshot or
  delta construction;
- raid lookup failure records the received raid reference;
- `PUSH_ACCEPT` or `PUSH_REJECT` records whether correlated or configured
  consent was found and, on rejection, the exact reason;
- queue failure records the mode, request ID, target, and transport reason.

### Import result

Snapshot and delta completion log one final result per request:

- `IMPORT_APPLY` with mode, request ID, authority, local raid ID, source raid
  NID, resulting revision, and loot-row count;
- `IMPORT_REJECT` or `REQUEST_END` with the existing terminal reason.

The diagnostics observe existing decisions. They must not introduce new
admission conditions or change which request wins.

## Testing

Automated behavior tests will prove:

- all new traces are silent when debug is disabled;
- successful automatic, Require, and Push fixtures produce a correlated
  boundary sequence;
- representative rejected paths report their actual reason;
- payload text is never included;
- adding diagnostics does not change request counts, timers, imports, or
  authority outcomes.

The complete Python suite and WotLK validators remain required. The decisive
runtime check is one two-client smoke with both clients configured as follows:

```text
/rma debug on
/rma debug level debug
```

Run automatic Master Loot convergence, `Require Database`, and `Push Database`
once each. Compare the two logs by request ID and report the first expected
boundary absent on either client. Only after that evidence is captured should
the behavioral defect be fixed.

## Success Criteria

- A failed smoke identifies one exact boundary and reason instead of only
  showing that the sender queued data.
- A successful flow can be followed end to end across both clients using a
  request ID or the advertised raid revision.
- Debug-disabled runtime behavior and chat output remain unchanged.
- No protocol, persistence, UI layout, or synchronization behavior changes are
  included in the diagnostic commit.
