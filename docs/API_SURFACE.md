# RMA External API Surface

This document defines which externally reachable RMA contracts are supported.
Reachability through Lua globals does not by itself make an implementation
surface public or stable.

## `_G.RMA`

`Init.lua` publishes the addon table as `_G.RMA` for runtime identity and
diagnostics. The supported root surface is deliberately minimal:

| API | Contract |
|---|---|
| `_G.RMA` | Exists after RMA initialization and refers to the active addon table. |
| `RMA.name` | Read-only identity value for the loaded addon name. |

No callable method under `_G.RMA` is a supported external API. Nested tables
such as `RMA.Database`, `RMA.Services`, `RMA.Controllers`, `RMA.Widgets`,
`RMA.UI`, `RMA.Bus`, and helper modules are package-internal even though Lua
makes them reachable. WoW event methods, diagnostics, performance hooks, frame
lifecycle methods, and controller commands are also internal.

Consumers must not depend on an internal root export remaining present, moving
to a different owner, or preserving its current signature. Removing an
internal export is allowed when repository callers have been migrated.

## Supported External Contracts Outside `_G.RMA`

| Surface | Supported contract | Compatibility rule |
|---|---|---|
| Slash commands | `/rma` and the documented subcommand aliases in the addon README | User-facing command behavior; change deliberately and document aliases. |
| SavedVariables | `RMA_Raids`, `RMA_Players`, `RMA_Reserves`, `RMA_Warnings`, `RMA_Spammer`, `RMA_Options` | Persisted compatibility surface; schema changes require explicit RMA migrations. |
| Addon messages | `RMAVersion`, `RMAResSync`, `RMADist`, `RMALogSync` | Prefix, authorization, version, and payload behavior are compatibility-sensitive. |
| FrameXML globals | Named `RMA*` frames and templates referenced by runtime Lua | Stable while referenced; migrate XML and Lua together. |
| TOC identity | Addon folder, title, Interface `30300`, version, and SavedVariables declarations | Release and client-loading contract. |

Detailed wire ownership remains in `FEATURE_API_MAP.md`. Product ownership and
command/query/notification rules remain in `FEATURE_BOUNDARIES.md`.

## Expansion Rule

New statically visible root assignments or methods on `addon` require an
explicit classification:

1. Prefer the nearest existing namespace owner instead of adding a root export.
2. If the export is internal, add it to the guardrail classification without
   describing it as supported.
3. If it is intended to be public, update this document with its signature,
   semantics, compatibility policy, and callers before implementation.
4. Public status must never be inferred solely from `_G.RMA` reachability.

The guardrail rejects unclassified direct, literal bracket, and `rawset` root
expansion but permits internal exports to disappear, so it does not freeze the
current implementation layout. Runtime-generated methods from libraries or
dynamic keys require review at their concrete binding site because they cannot
be enumerated reliably by a static source scan.
