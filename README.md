# Raid Management Addon

Raid Management Addon (RMA) is an operational toolkit for World of Warcraft:
Wrath of the Lich King 3.3.5a. It combines Master Loot, roll tracking, SoftRes,
raid recording, attendance, warnings, LFM messages, and support tools in one
addon. RMA assists raid staff; it never bypasses Blizzard loot permissions,
protected actions, or chat restrictions.

## Compatibility and installation

- Client: Wrath of the Lich King 3.3.5a (build 12340)
- TOC interface: `30300`
- Runtime: Lua 5.1
- Addon folder: `Raid Management Addon`
- Main command: `/rma`
- Version: `0.1.1`

RMA does not require Ace2 or Ace3. Copy the `Raid Management Addon` folder
into `World of Warcraft\Interface\AddOns\`; it must contain `Raid Management
Addon.toc` directly. Enable the addon, log in, and enter `/rma` for command
help.

Version 0.1.1 is a pre-release build. Test it in a real 3.3.5a raid before
relying on it for a live run. Grouped sync and sharing require compatible RMA
builds; data stays local unless RMA deliberately sends it through addon
messages, raid chat, or whispers.

## Master Loot

Open Master Loot with `/rma ml`. It reads the open loot window and also supports
an inventory-trade workflow for items already in bags. Choose an eligible item,
start an MS, OS, SoftRes, or Free roll, collect system roll messages, resolve
ties, then award the selected winner or winners. One award sequence can handle
multiple copies; an item can also be held, banked, or marked for disenchant.

The roll screen can announce starts, countdowns, winners, holds, bank, and DE
outcomes. It may block late rolls after the configured countdown and show
class/spec, reserve, and Loot Counter context when those data are available.
Manual trade classification records MS, OS, SoftRes, or Free after the normal
Blizzard trade interaction; it never automates or forces a trade.

Loot assignment and loot-method changes require Blizzard group permissions. In
a raid where RMA can only observe passive loot, the window can show observed
information but cannot make an authorized award. Options can request Master
Loot after targeting a recognized boss, ask to restore Group Loot after clearing
boss loot, announce opened loot, and add a SoftRes summary. These convenience
requests remain subject to current group state and permissions.

Commands and aliases: `/rma ml`.

## Rolls and Loot Counter

Roll tracking is tied to an active loot session. It records system roll results,
marks duplicate, blocked, timed-out, pass, cancelled, and reroll-only states,
and supports tie rerolls. Roll ordering can be ascending or descending. A
countdown is optional; without it RMA has no automatic intake close time.

Open Loot Counter with `/rma counter`, `/rma counters`, or `/rma counts`. It
displays MS, OS, and Free counts for the current raid and offers manual
plus/minus correction and resets in its UI. It can open automatically for MS
rolls. Counter broadcasts and related raid output still need the current chat or
raid capability; viewing and local adjustment remain local.

## SoftRes and reserves

Open reserves with `/rma res`, `/rma reserves`, `/rma reserve`, `/rma sr`, or
`/rma softres`. Open the importer with `/rma res import`. It accepts CSV and
JSON reserve data, including Multi-reserve and Plus System modes, and validates
and normalizes data before applying it. Item details can remain incomplete until
the client has item information.

RMA groups reserves by item and can display quantities, Plus values, known drop
sources, tooltip hints, and Master Loot context. `/rma res check` reports
current-item coverage, current-raid presence, unmapped names, and suggested
matches. Name reconciliation is explicit: use `/rma res alias <softres-name>
<raid-name>`, `/rma res unalias <softres-name>`, or `/rma res aliases` instead
of assuming different spellings identify the same player.

`/rma res sync` requests reserve metadata from grouped compatible clients;
`/rma res meta` prints local metadata, and `/rma res clearcache` removes only
the synced runtime cache. These do not replace the saved local import. Optional
whisper handling can reply to `+sr`; accepting `+sr [itemLink]` as a reserve
addition needs the corresponding option and appropriate raid or loot authority.
Whisper and sync traffic are best-effort and depend on the group, remote support,
and normal WoW messaging limits.

## Raid recording, Loot History, attendance, and inspection

RMA creates and updates raid records from live raid and instance context. It
records roster changes, boss and trash entries, loot, winners, roll type/value,
and available source information. Master Loot awards, inventory trades, and
passive Group Loot observations can feed a record; duplicate and ambiguous
passive messages are guarded by the recording workflow. Source lookup is
limited to RMA's static data, so unknown or incomplete sources can remain.

Open Loot History with `/rma logger`. The window supports reviewing and editing
loot, CSV export, data scans, cleanup, source rebuilding, and selected completed
raid sharing. `/rma logger share` opens the share dialog. Sharing is opt-in: a
recipient must accept, both players need the relevant group context, and only
compatible protocol/schema data is applied. Current-raid synchronization can
perform its own protocol-driven recovery with compatible peers; it is not a
selected-history recovery action or a Loot History command. There is no
`/rma history` command.

Open Raid Attendance with `/rma attendance`, `/rma attendees`, or `/rma att`.
It projects recorded roster and boss-attendee information, including join/leave
data. Refresh specialization data with `/rma specinspect` or force a new sweep
with `/rma specinspect force`; inspect results are asynchronous and can be
cached, skipped, unavailable, or delayed by normal inspect constraints.
Equipment inspection uses the same throttled, failure-safe model.
The specialization-inspection alias is `/rma inspectspec`.

## Warnings and LFM

Open Raid Warnings with `/rma warning`, `/rma warnings`, `/rma warn`, or
`/rma rw`. The window stores reusable templates and can create, edit, preview,
delete, and announce them. `/rma rw <ID>` requests the saved warning with that
numeric ID. Raid Warning output needs the relevant raid capability; when it
cannot use that channel, the chat service can use its defined fallback and RMA
reports the result rather than silently claiming a raid warning was sent.

Open LFM Spam with `/rma pug`, `/rma lfm`, `/rma group`, or `/rma grouper`.
Build a draft from raid name, needed roles, text, duration, channels, and
achievement placeholders, then preview it. The LFM roots all use the same
handler: an empty command, `/rma lfm toggle`, or `/rma lfm show` toggles the
window; `/rma lfm start` starts the cycle and `/rma lfm stop` stops it. The
runtime validates output length and applies duration, attempt, and message
limits; it pauses or stops if scheduling or chat transport cannot continue.
Extract a linked achievement ID with `/rma ach`, `/rma achi`, `/rma achiev`, or
`/rma achievement`. RMA uses normal chat channels and cannot guarantee delivery.

## Minimap and Quick Bar

Configure the minimap button with `/rma minimap` or `/rma mm`: `/rma minimap
on`, `/rma minimap off`, and `/rma minimap pos <deg>` show, hide, or place it.
`/rma minimap pos` without an angle reports the current saved position.
Left-click opens RMA's menu; right-click opens configuration. The menu offers
Master Loot, reserves, Loot Counter, Loot History, attendance, warnings, LFM,
raid-icon cleanup when permitted, and a Quick Bar toggle. Hold Shift to drag on
the minimap ring or Alt to free-drag it.

Quick Bar is a movable optional action strip. Use `/rma quickbar show` or
`/rma quickbar hide`. Its ML and GL buttons ask for confirmation before
requesting that loot method and highlight the active one; HIS opens Loot
History, SR opens reserves, and RW opens warnings. Each button can be hidden,
and the strip can be horizontal or vertical in configuration. Loot-method
actions remain constrained by Blizzard permissions and do nothing when already
active.

## Configuration

Open configuration with `/rma config`, `/rma conf`, `/rma options`, or
`/rma opt`; `/rma config reset` restores registered defaults. The panel owns
Master Loot presets and roll behavior, announcements, tooltip/trade reminders,
reserve whispers, counter display, minimap and Quick Bar settings, warning
maintenance, LFM controls, Loot History maintenance, and help.

Options change RMA behavior, not WoW authority. Enabling an automatic
loot-method prompt cannot grant loot access, enabling sync cannot make an
incompatible peer compatible, and enabling inspect refresh cannot bypass client
inspect restrictions.

## Diagnostics, validation, debug, and performance

`/rma help` shows command help. `/rma version`, `/rma ver`, or `/rma about`
prints version, interface, raid-schema, and sync-protocol information and asks
compatible grouped clients to answer; append `local` to keep it local. `/rma
bug` or `/rma report` prints a local support summary. The command forms are
`/rma bug` and `/rma report`.

`/rma validate raids [verbose]` validates stored raid records and reports its
bounded details. Use `/rma validate raids verbose` or `/rma validate raids all`
to include informational detail. It checks saved data only; it cannot prove an
unobserved event was recorded.

Performance controls are `/rma perf` or `/rma performance`. With no subcommand
they report status; `/rma perf on` and `/rma perf off` enable or disable local
collection. Set the threshold with `/rma perf threshold <ms>`, `/rma perf th <ms>`, or `/rma perf ms <ms>`. `/rma perf report`, `/rma perf stats`, and
`/rma perf top` print the same timing report; `/rma perf audit` and `/rma perf summary` print the aggregate audit; `/rma perf items`, `/rma perf item`, and
`/rma perf tooltip` print item-information metrics; `/rma perf reset` and
`/rma perf clear` reset those metrics; and `/rma perf status` prints status.
They collect local runtime and item-information metrics, not a server profile.

Debug controls are `/rma debug`, `/rma dbg`, or `/rma debugger`: `toggle`,
`on`, `off`, `levels`, and `level <name|num>`. Registered development helpers
include `/rma debug timers [reset]`, `/rma debug raidgrid [1-40]`, and these
synthetic raid forms: `/rma debug raid seed` or `/rma debug raid add` seeds the
profiles; `/rma debug raid clear` or `/rma debug raid reset` removes them;
`/rma debug raid rolls [tie]` or `/rma debug raid all [tie]` submits the batch;
and `/rma debug raid roll <1-4|name> [1-100]` submits one roll. They are local
testing tools. Synthetic raid helpers need a current raid record, use only
synthetic profiles, and refuse invalid operations; do not treat them as a
live-raid smoke test.

## SavedVariables and boundaries

RMA starts clean and stores only these account SavedVariables:

- `RMA_Raids`
- `RMA_Players`
- `RMA_Reserves`
- `RMA_Warnings`
- `RMA_Spammer`
- `RMA_Options`

It does not read, write, or migrate non-RMA SavedVariables. Addon-message
prefixes use `RMA`; sync wire formats are compatibility-sensitive and are not a
general import path. Use `/rma` in-game for the runtime command reference,
because it reflects the registered commands in the loaded addon.
