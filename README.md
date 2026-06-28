# Raid Management Addon

Raid Management Addon (RMA) is a raid-leader toolkit for World of Warcraft
Wrath of the Lich King 3.3.5a. It helps a raid leader manage loot rolls,
SoftRes data, loot history, raid attendance, raid warnings, LFM messages, and
basic raid diagnostics from one addon.

RMA is designed for the 3.3.5a client, uses `/rma` as its main command, and
stores only `RMA_*` SavedVariables.

## Compatibility

- Client target: Wrath of the Lich King 3.3.5a
- TOC Interface: `30300`
- Lua runtime: Lua 5.1
- Main slash command: `/rma`
- Addon folder: `Raid Management Addon`
- TOC file: `Raid Management Addon.toc`
- Current version: `0.1.0-alpha.1`

RMA does not require Ace2 or Ace3. Vendored libraries are included under
`Libs/`.

## Installation

1. Copy the `Raid Management Addon` folder into your WoW `Interface\AddOns\`
   directory.
2. Make sure the addon folder contains `Raid Management Addon.toc` directly
   inside it.
3. Enable `Raid Management Addon` from the in-game AddOns list.
4. Log in and run `/rma` to see the available commands.

## Core Features

### Master Loot

The Master Loot window is the main loot-distribution workflow.

- Open the loot workflow with `/rma ml`.
- Select loot from the open loot window or drag an item into the addon.
- Start MS, OS, SoftRes, or Free rolls.
- Run configurable countdowns for roll windows.
- Block late rolls after the countdown when that option is enabled.
- Announce roll starts, countdowns, winners, holds, bank assignments, and
  disenchant assignments.
- Resolve ties with a reroll flow.
- Award loot to selected winners when you are allowed to assign loot.
- Keep loot for later, send it to bank, or mark it for disenchant.
- Handle inventory-trade mode for items already in bags.
- Show trade reminders and optional screenshot reminders before trading.
- Optionally switch to Master Loot when a recognized raid boss is targeted by
  the raid leader.
- Optionally ask to restore Group Loot after boss loot is cleared.
- Optionally announce opened loot automatically when you are Master Looter.

RMA assists the raid leader. It does not bypass Blizzard loot permissions or
protected action rules.

### Roll Tracking

RMA records and displays roll responses during active loot sessions.

- Tracks player rolls from system roll messages.
- Supports MS, OS, SoftRes, and Free roll contexts.
- Marks duplicate, blocked, timed-out, pass, cancelled, and reroll-only states.
- Keeps per-player roll state for the current item.
- Supports tie detection and tie reroll handling.
- Can sort rolls ascending or descending from configuration.

### Loot Counter

The Loot Counter tracks distribution counts for raid members.

- Open with `/rma counter`.
- Tracks MS, OS, and Free counts per player.
- Provides plus/minus controls for manual corrections.
- Can announce grouped counters to raid when you have permission.
- Can reset one player or all counters.
- Can be shown automatically during MS rolls when enabled.

### SoftRes And Loot Reserves

The Reserves window manages imported SoftRes data and reserve visibility during
loot distribution.

- Open the reserve list with `/rma res`.
- Open the import window with `/rma res import`.
- Import SoftRes data as CSV or JSON.
- Supports Multi-reserve and Plus System import modes.
- Handles encoded SoftRes payloads when the required decode/decompress path is
  available.
- Groups reserves by item and shows reserved players.
- Shows item IDs, item names, quantities, Plus values, and possible drop source
  information.
- Checks the current item against imported SoftRes data with `/rma res check`.
- Reports reserve players in raid, outside raid, unmatched reserve names, and
  suggested name matches.
- Allows name aliases between imported SoftRes names and current raid names.
- Can sync SoftRes metadata and runtime reserve data with grouped RMA clients.
- Can clear synced runtime reserve cache.
- Supports optional SoftRes whisper replies:
  - `+sr` replies with a player's current reserves.
  - `+sr [itemLink]` can add a reserve when accepting whispers is enabled.

### Loot History

RMA stores raid logs locally and provides a history view for review and cleanup.

- Open with `/rma history`.
- Creates raid sessions from raid and instance state.
- Records raid zone, size, difficulty, roster snapshots, boss kills, trash
  entries, and loot entries.
- Records loot winners, roll type, roll value, source, and item information.
- Can ignore Group Loot messages or override the raid loot threshold from
  configuration.
- Uses a static loot-source database to resolve item sources where possible.
- Allows editing logged winners, roll types, and roll values.
- Exports loot and raid-attendance data as CSV.
- Scans stored history for empty raids, missing sources, invalid sources,
  orphan data, duplicate candidates, and player-name conflicts.
- Can purge history, rebuild missing loot sources, and clean selected history
  categories.

### Raid Attendance

The Raid Attendance view helps inspect who was present during raid activity.

- Open with `/rma attendance`.
- Shows raid roster snapshots over time.
- Shows boss attendees and raid attendees.
- Shows join and leave information.
- Displays class, specialization, inspected item level, and inspect status when
  available.
- Can force spec inspection with `/rma specinspect force`.

### Logger Sync

RMA can exchange raid-history snapshots with other grouped RMA users.

- `/rma history sync` syncs matching current-raid data.
- `/rma history req <raidId|raidNid> <player>` requests a specific raid snapshot
  from one player.
- `/rma history push <raidId|raidNid> <player>` sends a specific raid snapshot to
  one player.

Sync is compatibility-sensitive and only applies data that matches the expected
RMA protocol, schema, and raid context.

### Raid Warnings

The Raid Warning tool stores reusable warning templates.

- Open with `/rma rw` or `/rma warnings`.
- Fresh installs include stock templates for Pull, Spread, Stack, Stop DPS,
  Bloodlust, and Break.
- Create, edit, delete, preview, and announce saved warnings.
- Announce one warning directly with `/rma rw <ID>`.
- Raid Warning output requires raid leader or assistant permissions. When Raid
  Warning is unavailable, RMA falls back through its chat service.

### LFM Spam

The LFM Spam tool builds and sends recruitment messages with safety limits.

- Open with `/rma lfm`, `/rma pug`, `/rma group`, or `/rma grouper`.
- Configure raid name, composition, needed roles, custom message text, duration,
  and channels.
- Preview the final message before sending.
- Use `/rma lfm start` and `/rma lfm stop` to control the spam cycle.
- Uses message length checks and safety caps for duration and message count.
- Use `/rma ach [achievement link]` to extract an achievement ID for message
  placeholders.

### Minimap Launcher

RMA includes a minimap button for quick access.

- Left-click opens the Master Loot workflow when available.
- Right-click opens the RMA menu.
- The menu can open Master Loot, Reserves, Loot Counter, Loot History, Raid
  Attendance, Raid Warnings, LFM Spam, and configuration.
- The menu can clear raid icons when you have raid icon permission.
- Use `/rma minimap on`, `/rma minimap off`, and `/rma minimap pos <deg>` to
  control visibility and position.

### Configuration

Open configuration with `/rma config`.

The configuration panel includes:

- Master Loot announcement and countdown options.
- Quiet, Standard, Verbose, and Defaults presets.
- Raid Warning template preview and maintenance.
- LFM Spam preview and start/stop shortcuts.
- Loot History sync, maintenance, cleanup, and data-health actions.
- Minimap button visibility.
- Tooltip, screenshot reminder, stack-trade, SoftRes whisper, auto-spam, and
  auto Master Loot options.

Use `/rma config reset` to restore default options.

### Diagnostics And Maintenance

RMA includes local support and validation commands.

- `/rma version` shows addon, interface, raid schema, and sync protocol details,
  then requests grouped RMA client versions.
- `/rma version local` prints only local version data.
- `/rma bug` prints a local diagnostic summary for bug reports.
- `/rma validate raids [verbose]` validates stored raid history schema and
  invariants.
- `/rma perf on|off|threshold <ms>|report|audit|sync|items|reset` controls
  runtime performance logging and reports.
- `/rma debug on|off|level <name|num>` controls local debug output.
- `/rma debug raid` exposes synthetic raid and roll helpers for local testing.
- `/rma debug raidgrid [1-40]` opens the raid-grid debug view.

Debug and performance tools are local diagnostics. They are not required for
normal raid use.

## Command Reference

| Command | Purpose |
| --- | --- |
| `/rma` | Show the main command help. |
| `/rma help [command]` | Show command help or help for one topic. |
| `/rma config` | Open configuration. |
| `/rma config reset` | Restore default options. |
| `/rma ml` | Open or toggle Master Loot. |
| `/rma counter` | Open or toggle Loot Counter. |
| `/rma history` | Show Loot History commands or toggle Loot History. |
| `/rma history sync` | Sync matching current-raid history with grouped RMA users. |
| `/rma history req <raidId|raidNid> <player>` | Request one raid-history snapshot from a player. |
| `/rma history push <raidId|raidNid> <player>` | Push one raid-history snapshot to a player. |
| `/rma attendance` | Open Raid Attendance. |
| `/rma res` | Show reserve commands or toggle the reserve list. |
| `/rma res import` | Open the SoftRes import window. |
| `/rma res check` | Print a SoftRes readiness report for the current item and raid. |
| `/rma res alias <softres-name> <raid-name>` | Map an imported SoftRes name to a raid name. |
| `/rma res unalias <softres-name>` | Remove a SoftRes name alias. |
| `/rma res aliases` | List configured SoftRes aliases. |
| `/rma res sync` | Request SoftRes metadata from grouped RMA clients. |
| `/rma res meta` | Show local SoftRes metadata. |
| `/rma res clearcache` | Clear synced runtime SoftRes cache. |
| `/rma rw` | Open Raid Warnings or show warning commands. |
| `/rma rw <ID>` | Announce a saved warning by ID. |
| `/rma lfm` | Open LFM Spam or show LFM commands. |
| `/rma lfm start` | Start the LFM spam cycle. |
| `/rma lfm stop` | Stop the LFM spam cycle. |
| `/rma ach [achievement link]` | Print the achievement ID for LFM placeholders. |
| `/rma specinspect` | Refresh cached raid specialization icons. |
| `/rma specinspect force` | Refresh all inspectable raid members. |
| `/rma minimap on` | Show the minimap button. |
| `/rma minimap off` | Hide the minimap button. |
| `/rma minimap pos <deg>` | Set minimap button angle. |
| `/rma validate raids [verbose]` | Validate stored raid history. |
| `/rma perf ...` | Control and inspect performance logging. |
| `/rma debug ...` | Control local debug and test helpers. |
| `/rma version [local]` | Print version and compatibility details. |
| `/rma bug` | Print a local support summary. |

Aliases:

- Warnings: `/rma warning`, `/rma warnings`, `/rma warn`, `/rma rw`
- Loot History: `/rma history`
- Attendance: `/rma attendance`, `/rma attendees`, `/rma att`
- Master Loot: `/rma ml`
- Loot Counter: `/rma counter`, `/rma counters`, `/rma counts`
- Reserves: `/rma res`, `/rma reserves`, `/rma reserve`, `/rma sr`,
  `/rma softres`
- LFM Spam: `/rma lfm`, `/rma pug`, `/rma group`, `/rma grouper`
- Minimap: `/rma minimap`, `/rma mm`
- Version: `/rma version`, `/rma ver`, `/rma about`
- Bug report: `/rma bug`, `/rma report`

## Permissions

Some actions depend on the current group role and Blizzard permissions.

- Master Looter: item actions, loot assignment, trade reminders, roll-award
  workflow.
- Raid leader or assistant: Raid Warning output, grouped Loot Counter broadcast,
  LFM group announcements, raid icon cleanup.
- Local only: help, configuration, previews, history review, diagnostics,
  validation, and most maintenance actions.

## SavedVariables

RMA starts clean and uses only `RMA_*` SavedVariables:

- `RMA_Raids`
- `RMA_Players`
- `RMA_Reserves`
- `RMA_Warnings`
- `RMA_Spammer`
- `RMA_Options`

The addon does not read or migrate old non-RMA SavedVariables.

## Notes

- RMA is an alpha baseline and should be smoke-tested in a real 3.3.5a client
  before relying on it in a live raid.
- Sync features require other grouped players to run compatible RMA builds.
- Runtime data is local unless explicitly shared through RMA sync or in-game
  chat/whisper features.
