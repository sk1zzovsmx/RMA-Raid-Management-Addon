# Shared R5 Wire Codec Smoke Record

Verification date: 2026-07-20

## Environment

- Target runtime: WotLK 3.3.5a build 12340, Interface 30300, Lua 5.1.5.
- Required setup: two clients running the same R5 addon build in one group or raid.
- Available setup: no WotLK client session was available in this worktree.

## Required Two-Client Smoke

| Scenario | Status | Observation |
|---|---|---|
| Both clients log in with no Lua errors | NOT RUN | No client session was available. |
| Both clients `/reload` successfully | NOT RUN | No client session was available. |
| `/rma` opens on both clients | NOT RUN | No client session was available. |
| Version request and R5 response exchange | NOT RUN | No client session was available. |
| Live loot replication converges | NOT RUN | No client session was available. |
| Range recovery or snapshot recovery converges | NOT RUN | No client session was available. |
| Reserve sharing converges | NOT RUN | No client session was available. |
| Active loot-distribution flow converges | NOT RUN | No client session was available. |
| RMADist state flow remains ordered on `NORMAL`; only `HELLO`/`SNAP_REQ` use `ALERT` | NOT RUN | No client session was available. |
| Independently correlated BULK recovery and ALERT control flows complete | NOT RUN | No client session was available. |
| `RMA_*` SavedVariables persist after reload | NOT RUN | No client session was available. |

## Residual Risk

All in-game checks are NOT RUN. Static validation cannot prove live client
transport behavior, ChatThrottleLib priority scheduling, group authorization,
cross-client R5 compatibility, combat interaction, or SavedVariables behavior
after a real reload. In particular, static tests prove the RMADist priority
classification but not live queue timing. Run every row above on two WotLK
3.3.5a clients before relying on this change in a raid.
