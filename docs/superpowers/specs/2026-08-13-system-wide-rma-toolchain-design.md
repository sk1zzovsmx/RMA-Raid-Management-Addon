# System-Wide RMA Toolchain Design

## Objective

Provide one predictable Windows development toolchain for every user of this
computer and connect it to a repository-owned validation gate for Raid
Management Addon. The result must distinguish LuaJIT behavioral testing from
the exact PUC Lua 5.1.5 parser used to qualify code for the WotLK 3.3.5a
client.

The intended improvements are reproducibility, runtime-safety evidence, and
maintainability. This batch changes development tooling and validation policy;
it does not change addon behavior, SavedVariables, addon-message formats, TOC
load order, vendored libraries, or game-client files.

## Current Evidence

`C:\Tools` currently contains working StyLua 2.3.1, Luacheck 0.23.0,
LuaJIT 2.1, LuaRocks 3.11.1, and `lua.cmd`/`luajit.cmd` launchers. A real RMA
Lua harness case passes through `lua.cmd`, and Microsoft Defender reports no
threats in the directory.

The installation is incomplete at the repository boundary:

- `C:\Tools` is absent from both the user and machine `PATH`;
- PUC `lua5.1.exe` and `luac5.1.exe` are absent;
- the Windows Python launcher is absent, the WindowsApps `python` alias is not
  an operational interpreter, and the ignored `.venv` points to another
  user's removed Python installation;
- `.stylua.toml` is absent;
- `.styluaignore`, `.luacheckrc`, `tools/`, and their contents are ignored and
  therefore do not establish a shared repository contract;
- the current reset baseline deliberately omits `tools/check-rma.ps1`.

The existing executables are unsigned. That fact is recorded rather than
hidden; third-party binaries will be accepted through official-source
provenance, pinned hashes, and malware scanning, not by fabricating an RMA code
signature.

## Chosen Approach

Use `C:\Tools` as the central machine-wide tool root and track the configuration,
installer, manifest, static validator, and aggregate gate in the repository.
Do not rely on package-manager auto-updates, Codex-bundled paths, ignored agent
skills, a particular user's profile, or temporary download directories.

The repository will not vendor the third-party executables. It will instead
own the expected versions, download locations, hashes, installation layout,
and verification behavior.

## Machine-Wide Layout

The accepted layout is:

```text
C:\Tools\
|-- lua.cmd                     -> LuaJIT behavioral-test launcher
|-- luajit.cmd                  -> LuaJIT launcher
|-- luacheck.exe
|-- stylua.exe
|-- LuaJIT\
|   `-- bin\
|       |-- luajit.exe
|       |-- lua51.dll
|       `-- luarocks.exe
|-- Lua51\
|   `-- bin\
|       |-- lua5.1.exe          -> exact PUC Lua 5.1.5 runtime
|       `-- luac5.1.exe         -> exact PUC Lua 5.1.5 parser/compiler
`-- RMA-TOOLCHAIN-MANIFEST.json
```

`lua` continues to mean LuaJIT for the existing Python-to-Lua behavior harness.
`lua5.1` and `luac5.1` are separate commands used for exact client-language
qualification. The design forbids silently redirecting all three names to one
runtime because that would erase the distinction between fast tests and the
release parser.

The machine `PATH` contains, once each and in deterministic order:

1. `C:\Tools`
2. `C:\Tools\LuaJIT\bin`
3. `C:\Tools\Lua51\bin`

Python is pinned to CPython 3.14.7 and installed from the official python.org
Windows x64 installer with all-users scope, the `py` launcher, and machine
`PATH` integration. The accepted installer SHA-256 is
`9D9EB2709EF81BF5CD30DB3C2096BDBC4EA10087C22E62F27D356B36F6AE9649`, as
published on the Python 3.14.7 release page. The repository suite must pass on
this exact runtime before it is accepted; the existing tests require only
Python 3.12 or later.

## Installation And Provenance

`tools/install-toolchain.ps1` is the single idempotent installer. It requires
an elevated process because it writes machine configuration. Before mutation
it validates administrative rights, resolves every target to `C:\Tools`, and
captures the existing machine `PATH` for rollback evidence.

The installer will:

1. inspect existing files and preserve them when their hashes match the lock;
2. stop before overwriting any unexpected binary;
3. download into a GUID-named temporary directory;
4. accept only HTTPS official release sources and exact expected hashes;
5. extract into a staging directory, execute version probes there, and only
   then place files in `C:\Tools`;
6. install Python for all users with the launcher and machine `PATH` enabled;
7. normalize the three toolchain `PATH` entries without duplicating unrelated
   entries;
8. write `RMA-TOOLCHAIN-MANIFEST.json` with versions, source URLs, hashes,
   signature status, installation time, and executable paths;
9. remove only its own verified temporary directory;
10. run a Defender custom scan with remediation disabled and report the exact
    result.

PUC Lua is pinned to 5.1.5. The implementation must independently confirm the
official LuaBinaries archive, expected archive length and SHA-256, paired
`lua5.1.exe`/`luac5.1.exe`, `Lua 5.1.5` version output, and final executable
hashes before acceptance. No LuaJIT parser result may substitute for this
stage.

If the current process is not elevated, the installer makes no machine change
and prints one exact elevated command for the user to run. It does not attempt
partial per-user installation.

## Repository Integration

The repository tracks these files:

- `.stylua.toml`: syntax `Lua51`, 120 columns, Unix line endings, tabs of width
  four, double-quote preference, and stable call-parentheses policy;
- `.styluaignore`: all vendored libraries and only specifically justified
  generated or unloaded trees;
- `.luacheckrc`: Lua 5.1 standard plus explicit source-proven WoW/FrameXML
  globals; no blanket global acceptance and no blanket undefined-global
  suppression;
- `tools/toolchain.lock.json`: exact expected external tool versions, sources,
  hashes, commands, and roles;
- `tools/install-toolchain.ps1`: machine-wide idempotent installer;
- `tools/validate-rma.py`: repository-owned, Python-standard-library-only
  static contract validator;
- `tools/check-rma.ps1`: no-argument, fail-fast aggregate gate;
- `tools/README.md`: installation, validation, recovery, and external-smoke
  boundaries.

`.gitignore` stops ignoring these repository-owned contracts while continuing
to ignore `.venv`, caches, generated reports, archives, Codex state, and other
local-only data. No binary under `C:\Tools` or generated machine manifest is
added to Git.

The historical validated repository gate under the archived rewrite worktree
is evidence and a starting point, not a file to restore blindly. Its static
rules, TOC ownership assumptions, vendor layout, and SavedVariables contract
must be adapted to the active branch before use.

## Aggregate Gate

`tools/check-rma.ps1` resolves tools from the ordinary `PATH` and fails with a
stable named stage when Python, LuaJIT, PUC Lua 5.1.5, StyLua, Luacheck, Git, or
the required repository files are unavailable. It must not fall back to a
Codex-only Python runtime or an ignored `.agents` directory.

The no-argument gate runs, in fail-fast order:

1. tool version and lock/manifest agreement;
2. repository static validation, including TOC metadata and references, Lua
   5.1 forbidden syntax/APIs, variadic `xpcall`, XML script handlers, project
   identity, and non-vendor ASCII policy;
3. `luac5.1 -p` over every TOC-owned Lua file, including vendor files without
   modifying them;
4. LuaJIT parse/load checks and the Lua behavior harness through the Python
   tests;
5. `stylua --check` with the tracked configuration over owned non-vendor Lua
   changed in the current index, worktree, or explicit commit range; the gate
   reports the unchanged formatting baseline without rewriting it;
6. `luacheck` with the tracked Lua 5.1/WoW environment;
7. full Python `unittest` discovery;
8. `git diff --check`, excluding only immutable vendor bytes when their
   upstream formatting requires it.

The gate reports real client validation as `BLOCKED_EXTERNAL_SMOKE`; static
automation never claims that login, reload, combat/taint behavior,
SavedVariables persistence, or multi-client synchronization passed.

Existing Luacheck findings are reviewed individually. Source-proven WoW globals
belong in the environment configuration. Intentional constructs may receive a
narrow file/code suppression with a written reason. The tooling batch must not
change runtime behavior merely to make lint output green, and unresolved real
findings keep the gate red.

## Failure Safety And Recovery

No installer stage deletes or overwrites an existing executable before its
replacement has passed source, hash, extraction, and version checks. Unknown
existing binaries cause a stop with their paths and hashes. Machine `PATH`
updates preserve unrelated entries and are written only after the staged tools
pass their probes.

If Python installation or a `PATH` update fails, the installer reports which
stages completed and prints the recorded original `PATH`; it does not claim a
complete installation. Re-running the same installer is the supported recovery
path because accepted stages are hash-idempotent.

The broken ignored `.venv` is replaced only after the system Python and `py`
launcher pass. Its resolved absolute target is checked to remain inside the
repository before replacement. The recreated environment is local and remains
ignored by Git.

## Acceptance Criteria

From a newly launched non-elevated shell for any Windows user:

- `lua -v`, `luajit -v`, `lua5.1 -v`, `luac5.1 -v`, `stylua --version`,
  `luacheck --version`, `python --version`, and `py -3 --version` resolve;
- `lua` identifies LuaJIT while `lua5.1` identifies exactly Lua 5.1.5;
- downloaded artifact hashes agree with the repository lock, while installed
  binary hashes and versions agree with the generated machine manifest;
- Defender reports no threat for `C:\Tools`;
- a representative RMA Lua harness case passes through `lua`;
- every TOC-owned Lua file parses through `luac5.1 -p`;
- the repository-owned static validator passes;
- changed owned Lua passes StyLua and whole-addon non-vendor Lua passes
  Luacheck using the tracked configurations;
- the full Python suite passes;
- `tools/check-rma.ps1` exits zero and prints `PASS REPOSITORY_GATE`;
- `git diff --check` passes;
- no addon runtime, vendored library, SavedVariable, game installation, or
  release package changed as a side effect.

In-game smoke validation remains a separate manual requirement whenever future
runtime work makes it applicable.
