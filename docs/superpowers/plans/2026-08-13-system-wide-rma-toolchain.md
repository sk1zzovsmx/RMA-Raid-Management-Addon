# System-Wide RMA Toolchain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install a pinned RMA development toolchain under `C:\Tools` for every Windows user and add a repository-owned, fail-fast validation gate.

**Architecture:** A tracked JSON lock is the source of truth for external artifacts, versions, hashes, installation paths, and command roles. A safe PowerShell installer stages and verifies artifacts before machine mutation; a standard-library-only Python validator owns repository static contracts; a separate PowerShell gate composes tool identity, PUC parsing, incremental formatting, whole-addon lint, tests, and Git checks without touching the WoW client.

**Tech Stack:** Windows PowerShell 5.1-compatible scripts, CPython 3.14.7, Python `unittest`, PUC Lua 5.1.5 Win32, LuaJIT 2.1.19907, StyLua 2.3.1, Luacheck 0.23.0, Git, Microsoft Defender, WoW WotLK 3.3.5a Interface 30300.

## Global Constraints

- Install for all Windows users; machine mutation requires an elevated process.
- Central tool root is exactly `C:\Tools`; never redirect an install to a user profile or repository directory.
- `lua` remains the LuaJIT behavior-test command; `lua5.1` and `luac5.1` remain exact PUC Lua 5.1.5 commands.
- Pin CPython 3.14.7 x64 installer SHA-256 `9D9EB2709EF81BF5CD30DB3C2096BDBC4EA10087C22E62F27D356B36F6AE9649`.
- Pin PUC Lua 5.1.5 Win32 archive SHA-256 `C831A26D9C2280ADF594A33690324DE5DE3CF6FB75F26B3753BAE00812BCF162`.
- Pin LuaJIT MSI SHA-256 `D083A5ED83D7597A2FB900769B42BD1A2ECADE3A84258471C3C3F7E12C3A7024` and extracted tree SHA-256 `F32E8406D30658A2CA982B2ABE61622732984117E8B051376AB5DDFE05834585`.
- Pin StyLua 2.3.1 archive SHA-256 `70FC56D7361C20E858BD9C3B3B643E44DC2E2007B670C816BA7FB032956E3BAA` and executable SHA-256 `48F8975687078730B2178116F3EA56F4EB096ADD6A185F9EEB4D1F06089C888B`.
- Pin Luacheck 0.23.0 executable SHA-256 `F1395A3FAC181094A3DF500CF81698D1256638FAB60F6E02994E9B0B1905FCDC`.
- Do not modify addon runtime files, TOC, SavedVariables, wire formats, vendored libraries, WoW client files, or release packages.
- Keep the repository validator Python-standard-library-only and Windows PowerShell scripts compatible with PowerShell 5.1.
- Whole-addon PUC parsing, Luacheck, static validation, and Python tests remain global; StyLua is incremental because 126 unchanged owned files have pre-existing formatting debt.
- Real-client validation is always reported as `BLOCKED_EXTERNAL_SMOKE`, never as an automated pass.
- Each task gets its own commit; stage only the files named by that task.

---

## File Map

- `.gitignore` — exposes repository-owned tooling/configuration while retaining local state and generated artifacts as ignored.
- `.stylua.toml` — canonical Lua 5.1 formatting policy.
- `.styluaignore` — excludes only vendored libraries from formatting.
- `.luacheckrc` — canonical Lua 5.1/WoW global environment and narrow baseline suppressions.
- `tools/toolchain.lock.json` — immutable artifact/source/hash/command contract.
- `tools/validate-rma.py` — standard-library-only TOC/XML load-graph and runtime-policy validator.
- `tools/install-toolchain.ps1` — audit/install entry point for `C:\Tools`, Python, machine `PATH`, manifest, and Defender scan.
- `tools/check-rma.ps1` — fail-fast repository validation orchestrator.
- `tools/README.md` — supported installation, audit, gate, and recovery commands.
- `docs/VALIDATION.md` — authoritative repository validation and manual-smoke boundary.
- `tests/test_toolchain_contract.py` — lock, formatting, lint, and ignore-policy tests.
- `tests/test_rma_static_validator.py` — positive and mutation tests for every static failure family.
- `tests/test_toolchain_installer.py` — installer safety, target, lock, audit, and no-partial-install tests.
- `tests/test_repository_gate.py` — stage resolution, failure propagation, incremental StyLua scope, and truthful smoke tests.
- `docs/validation/2026-08-13-system-wide-toolchain.md` — final machine installation evidence and residual risk.

---

### Task 1: Pin Repository Toolchain And Formatting/Lint Policy

**Files:**
- Modify: `.gitignore`
- Create: `.stylua.toml`
- Modify: `.styluaignore`
- Modify: `.luacheckrc`
- Create: `tools/toolchain.lock.json`
- Create: `tests/test_toolchain_contract.py`

**Interfaces:**
- Consumes: artifact/version/hash evidence in Global Constraints.
- Produces: lock schema `1`; `tools/toolchain.lock.json`; canonical formatter/linter configuration consumed by Tasks 3 and 4.

- [ ] **Step 1: Write the failing repository-contract tests**

Create `tests/test_toolchain_contract.py` with these constants and assertions:

```python
from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "tools" / "toolchain.lock.json"

EXPECTED_STYLUA = {
    "syntax": "Lua51",
    "column_width": 120,
    "line_endings": "Unix",
    "indent_type": "Tabs",
    "indent_width": 4,
    "quote_style": "AutoPreferDouble",
    "call_parentheses": "Always",
}

EXPECTED_ARTIFACT_HASHES = {
    "python": "9D9EB2709EF81BF5CD30DB3C2096BDBC4EA10087C22E62F27D356B36F6AE9649",
    "pucLua51": "C831A26D9C2280ADF594A33690324DE5DE3CF6FB75F26B3753BAE00812BCF162",
    "luaJit": "D083A5ED83D7597A2FB900769B42BD1A2ECADE3A84258471C3C3F7E12C3A7024",
    "stylua": "70FC56D7361C20E858BD9C3B3B643E44DC2E2007B670C816BA7FB032956E3BAA",
    "luacheck": "F1395A3FAC181094A3DF500CF81698D1256638FAB60F6E02994E9B0B1905FCDC",
}


class ToolchainContractTests(unittest.TestCase):
    def test_owned_tooling_is_not_ignored(self) -> None:
        for relative in (
            ".stylua.toml", ".styluaignore", ".luacheckrc",
            "tools/toolchain.lock.json", "tools/check-rma.ps1",
            "tools/install-toolchain.ps1", "tools/validate-rma.py",
        ):
            result = subprocess.run(
                ["git", "check-ignore", "--quiet", "--", relative], cwd=ROOT
            )
            self.assertNotEqual(0, result.returncode, relative)

    def test_stylua_policy_is_exact_and_vendor_only(self) -> None:
        self.assertEqual(
            EXPECTED_STYLUA,
            tomllib.loads((ROOT / ".stylua.toml").read_text(encoding="utf-8")),
        )
        exclusions = {
            line.strip().replace("\\", "/")
            for line in (ROOT / ".styluaignore").read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        }
        self.assertEqual({"Raid Management Addon/Libs/**"}, exclusions)

    def test_luacheck_is_closed_lua51_policy(self) -> None:
        text = (ROOT / ".luacheckrc").read_text(encoding="utf-8")
        compact = re.sub(r"\s+", "", text).lower()
        self.assertIn('std="lua51"', compact)
        self.assertNotIn("globals=true", compact)
        self.assertNotRegex(compact, r"ignore=.*\b113\b")
        self.assertIn('"GetLocale"', text)
        self.assertIn('files["Raid Management Addon/Database/DBSyncer.lua"]', text)
        self.assertIn('files["Raid Management Addon/Init.lua"]', text)

    def test_lock_has_exact_artifacts_and_machine_paths(self) -> None:
        lock = json.loads(LOCK.read_text(encoding="utf-8"))
        self.assertEqual(1, lock["schemaVersion"])
        self.assertEqual("C:\\Tools", lock["toolRoot"])
        self.assertEqual(
            ["C:\\Tools", "C:\\Tools\\LuaJIT\\bin", "C:\\Tools\\Lua51\\bin"],
            lock["machinePath"],
        )
        self.assertEqual(
            EXPECTED_ARTIFACT_HASHES,
            {name: spec["artifact"]["sha256"] for name, spec in lock["tools"].items()},
        )
```

- [ ] **Step 2: Run the contract tests to verify RED**

Run:

```powershell
$python = 'C:\Users\Massimo\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
& $python -m unittest tests.test_toolchain_contract -v
```

Expected: FAIL because `.stylua.toml` and `tools/toolchain.lock.json` do not exist and the owned paths remain ignored.

- [ ] **Step 3: Expose only repository-owned tooling in `.gitignore`**

Remove these ignore entries:

```text
docs/
tests/
tools/
.luacheckrc
.stylua.toml
.styluaignore
```

Keep `.codex/`, `.agents/`, `.vscode/`, `.venv/`, `.mcp.json`, `.worktrees/`, `.superpowers/`, `__pycache__/`, `*.py[cod]`, test caches, `dist/`, archives, hashes, logs, and `FrameXML.log`. Add `.venv.backup-*/` so Task 5 can make a recoverable environment replacement without exposing it to Git.

- [ ] **Step 4: Add the exact StyLua policy**

Create `.stylua.toml`:

```toml
syntax = "Lua51"
column_width = 120
line_endings = "Unix"
indent_type = "Tabs"
indent_width = 4
quote_style = "AutoPreferDouble"
call_parentheses = "Always"
```

Replace `.styluaignore` with:

```text
Raid Management Addon/Libs/**
```

- [ ] **Step 5: Make Luacheck deterministic without touching runtime files**

In `.luacheckrc`:

1. change `std = "lua51c"` to `std = "lua51"`;
2. add `"GetLocale"` in sorted order to `read_globals`;
3. append these two narrow baseline suppressions, preserving all existing explicit WoW globals:

```lua
files = {}
files["Raid Management Addon/Database/DBSyncer.lua"] = { ignore = { "542" } }
files["Raid Management Addon/Init.lua"] = { ignore = { "314/PARTY_LOOT_METHOD_CHANGED" } }
```

The first suppression covers the documented empty success branch in `resolveReentryDecision`; the second covers the duplicate literal field assignment without changing runtime bytes. Do not add W113 or a whole-repository warning suppression.

- [ ] **Step 6: Add the exact artifact lock**

Create `tools/toolchain.lock.json` with schema `1` and these records:

```json
{
  "schemaVersion": 1,
  "toolRoot": "C:\\Tools",
  "machinePath": [
    "C:\\Tools",
    "C:\\Tools\\LuaJIT\\bin",
    "C:\\Tools\\Lua51\\bin"
  ],
  "tools": {
    "python": {
      "version": "3.14.7",
      "target": "C:\\Program Files\\Python314",
      "artifact": {
        "url": "https://www.python.org/ftp/python/3.14.7/python-3.14.7-amd64.exe",
        "length": 33258168,
        "sha256": "9D9EB2709EF81BF5CD30DB3C2096BDBC4EA10087C22E62F27D356B36F6AE9649",
        "signature": "Python Software Foundation"
      }
    },
    "pucLua51": {
      "version": "5.1.5",
      "artifact": {
        "url": "https://downloads.sourceforge.net/project/luabinaries/5.1.5/Tools%20Executables/lua-5.1.5_Win32_bin.zip",
        "length": 829421,
        "sha256": "C831A26D9C2280ADF594A33690324DE5DE3CF6FB75F26B3753BAE00812BCF162"
      },
      "installed": {
        "Lua51/bin/lua5.1.exe": "A45F0F8376D3059A8BC79A4D6D07536CC1D9DEC429852CFBC1F899EE96D6CD88",
        "Lua51/bin/luac5.1.exe": "D90802DFB2F849D80FAE6FC9D9F2B5B39EC13B1E120893178BE63B926A2E44BF",
        "Lua51/bin/lua5.1.dll": "FBBE7EE073D0290AC13C98B92A8405EA04DCC6837B4144889885DD70679E933F"
      }
    },
    "luaJit": {
      "version": "2.1.19907",
      "artifact": {
        "url": "https://github.com/DevelopersCommunity/cmake-luajit/releases/download/v2.1.19907/LuaJIT-2.1.19907-win64.msi",
        "length": 4030464,
        "sha256": "D083A5ED83D7597A2FB900769B42BD1A2ECADE3A84258471C3C3F7E12C3A7024"
      },
      "treeFiles": 31,
      "treeSha256": "F32E8406D30658A2CA982B2ABE61622732984117E8B051376AB5DDFE05834585",
      "installed": {
        "LuaJIT/bin/luajit.exe": "90A56F1091137DC7229FB0D10522CAB407E516A23B893CC8BDCD6187328E38AA",
        "LuaJIT/bin/lua51.dll": "CDF4D56E29CF3C437A22A2CE1FF0DC99BA99633E99EA5766AB16439AFEE9280D",
        "LuaJIT/bin/luarocks.exe": "D42ACC48BA3BD7E0EF88A149B839249DB2AED0CECE3A326D1E0470847A78BEB9"
      }
    },
    "stylua": {
      "version": "2.3.1",
      "artifact": {
        "url": "https://github.com/JohnnyMorganz/StyLua/releases/download/v2.3.1/stylua-windows-x86_64.zip",
        "length": 2866539,
        "sha256": "70FC56D7361C20E858BD9C3B3B643E44DC2E2007B670C816BA7FB032956E3BAA"
      },
      "installed": {
        "stylua.exe": "48F8975687078730B2178116F3EA56F4EB096ADD6A185F9EEB4D1F06089C888B"
      }
    },
    "luacheck": {
      "version": "0.23.0",
      "artifact": {
        "url": "https://github.com/mpeterv/luacheck/releases/download/0.23.0/luacheck.exe",
        "length": 693760,
        "sha256": "F1395A3FAC181094A3DF500CF81698D1256638FAB60F6E02994E9B0B1905FCDC"
      },
      "installed": {
        "luacheck.exe": "F1395A3FAC181094A3DF500CF81698D1256638FAB60F6E02994E9B0B1905FCDC"
      }
    }
  }
}
```

- [ ] **Step 7: Run focused policy checks**

Run:

```powershell
$env:Path = 'C:\Tools;C:\Tools\LuaJIT\bin;' + $env:Path
$python = 'C:\Users\Massimo\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
& $python -m unittest tests.test_toolchain_contract -v
& 'C:\Tools\luacheck.exe' 'Raid Management Addon'
git diff --check
```

Expected: contract tests PASS; Luacheck reports `0 warnings / 0 errors`; `git diff --check` exits zero. Do not run StyLua across the whole addon because the known baseline has 126 unchanged formatting findings.

- [ ] **Step 8: Commit Task 1**

```powershell
git add .gitignore .stylua.toml .styluaignore .luacheckrc tools/toolchain.lock.json tests/test_toolchain_contract.py
git commit -m "chore(tooling): pin RMA toolchain policy"
```

---

### Task 2: Add The Closed Repository Static Validator

**Files:**
- Create: `tools/validate-rma.py`
- Create: `tests/test_rma_static_validator.py`

**Interfaces:**
- Consumes: repository root, `Raid Management Addon/Raid Management Addon.toc`, Interface `30300`, current six `RMA_*` SavedVariables, XML `<Script file>`/`<Include file>` edges.
- Produces: CLI `validate-rma.py --root PATH [--format text|json]`; JSON object keys `status`, `tocEntries`, `luaFiles`, `xmlFiles`; stable failure prefix `FAIL <FAMILY>:`.

- [ ] **Step 1: Write positive, load-graph, and mutation tests**

Create `tests/test_rma_static_validator.py`. Use `tempfile.TemporaryDirectory`, copy the repository without `.git`, local state, caches, archives, or logs, and invoke the validator with `sys.executable`.

The positive assertions are:

```python
result = run_validator(ROOT, "--format", "json")
self.assertEqual(0, result.returncode, result.stdout + result.stderr)
payload = json.loads(result.stdout)
self.assertEqual("PASS", payload["status"])
self.assertIn("Raid Management Addon/Init.lua", payload["luaFiles"])
self.assertIn(
    "Raid Management Addon/Libs/LibTalentQuery-1.0/LibTalentQuery-1.0.lua",
    payload["luaFiles"],
)
self.assertEqual(len(payload["luaFiles"]), len(set(payload["luaFiles"])))
```

Add table-driven copied-fixture mutations with exact expected families:

```python
cases = (
    ("TOC_METADATA", "## Interface: 30300", "## Interface: 30400"),
    ("TOC_SAVED_VARIABLES", "RMA_Raids, RMA_Players", "ForeignDB, RMA_Players"),
    ("TOC_MISSING", "EntryPoints\\SlashEvents.lua", "Missing.lua"),
    ("LUA51_SYNTAX", None, "\n::invalid::\n"),
    ("LUA51_API", None, "\nlocal invalid = table.pack(1)\n"),
    ("XPCALL", None, "\nxpcall(print, print, 1)\n"),
    ("WOTLK_API", None, "\nC_Timer.After(1, print)\n"),
    ("XML_HANDLER", None, "\n<Scripts><OnLoad>print()</OnLoad></Scripts>\n"),
    ("IDENTITY", None, "\n_G.ForeignAddonGlobal = {}\n"),
    ("ASCII", None, "\n-- café\n"),
)
```

Add separate witnesses for multiline variadic `xpcall`, `&`, `|`, unary `~`, `<<`, `>>`, `//`, `_ENV`, `table.unpack`, XML absolute paths, `..` path escape, XML include cycles, roots outside RMA, and `--client-path`. Assert each exits nonzero and contains its stable family.

- [ ] **Step 2: Run validator tests to verify RED**

```powershell
$python = 'C:\Users\Massimo\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
& $python -m unittest tests.test_rma_static_validator -v
```

Expected: FAIL because `tools/validate-rma.py` does not exist.

- [ ] **Step 3: Implement TOC metadata and recursive load-graph ownership**

Create `tools/validate-rma.py` with these public internal signatures:

- `fail(family: str, detail: str) -> NoReturn`
- `parse_toc(toc: Path) -> tuple[dict[str, str], list[Path]]`
- `safe_child(root: Path, parent: Path, relative: str) -> Path`
- `resolve_load_graph(addon: Path, entries: list[Path]) -> tuple[list[Path], list[Path]]`
- `strip_lua(source: str) -> str`
- `has_variadic_xpcall(code: str) -> bool`
- `validate(root: Path) -> dict[str, object]`
- `main() -> int`

`safe_child` must reject absolute paths and any resolved path outside the addon root. `resolve_load_graph` must preserve first-load order, deduplicate by normalized absolute path, parse XML with `xml.etree.ElementTree`, follow both `Script` and `Include` `file` attributes relative to the containing XML, reject cycles, and return every reachable Lua/XML path.

Enforce exact current metadata:

```python
EXPECTED_METADATA = {
    "Interface": "30300",
    "Title": "Raid Management Addon",
    "SavedVariables": (
        "RMA_Raids, RMA_Players, RMA_Reserves, "
        "RMA_Warnings, RMA_Spammer, RMA_Options"
    ),
}
```

- [ ] **Step 4: Implement Lua/XML/runtime-policy validation**

Scan reachable Lua after stripping comments and strings for Lua 5.2+ syntax/APIs, modern WoW APIs, Ace2, and variadic `xpcall`. Allow vendor `loadstring` but reject `loadstring`, `dofile`, `loadfile`, and `require` in owned Lua. Scan owned XML for `<Scripts>` and `<OnEvent>`-style handlers. Require ASCII for owned runtime Lua/XML outside localization. Reject owned `_G.<name> =` assignments unless the name begins with `RMA`.

Text mode prints:

```text
PASS STATIC: <toc> TOC entries, <lua> Lua, <xml> XML
```

JSON mode writes only one JSON object to stdout so Task 4 can consume the load graph.

- [ ] **Step 5: Run focused validator and mutation tests**

```powershell
$python = 'C:\Users\Massimo\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
& $python -m unittest tests.test_rma_static_validator -v
& $python tools/validate-rma.py --root .
& $python tools/validate-rma.py --root . --format json | ConvertFrom-Json | Select-Object status
git diff --check
```

Expected: all mutation tests PASS; text reports `PASS STATIC`; JSON status is `PASS`; diff check exits zero.

- [ ] **Step 6: Commit Task 2**

```powershell
git add tools/validate-rma.py tests/test_rma_static_validator.py
git commit -m "feat(tooling): add closed RMA static validator"
```

---

### Task 3: Add The Safe Machine-Wide Installer

**Files:**
- Create: `tools/install-toolchain.ps1`
- Create: `tests/test_toolchain_installer.py`

**Interfaces:**
- Consumes: `tools/toolchain.lock.json`, HTTPS artifacts, exact `C:\Tools`, machine environment, Defender.
- Produces: `install-toolchain.ps1 -Mode Audit|Install`; generated `C:\Tools\RMA-TOOLCHAIN-MANIFEST.json`; exit `0` only for a complete audit/install; stable `FAIL <STAGE>:` output.

- [ ] **Step 1: Write installer safety tests**

Create `tests/test_toolchain_installer.py` with this process wrapper, then add the cases below:

```python
def run_installer(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", str(INSTALLER), *arguments,
        ],
        cwd=ROOT,
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
        check=False,
    )
```

Cover:

```python
def test_install_rejects_any_target_other_than_c_tools(self):
    with tempfile.TemporaryDirectory() as temporary:
        result = run_installer("-Mode", "Install", "-ToolRoot", temporary)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("FAIL TARGET", output(result))
        self.assertEqual([], list(Path(temporary).iterdir()))

def test_audit_is_read_only_and_reports_missing_root(self):
    missing = ROOT / "missing-toolchain-fixture"
    result = run_installer("-Mode", "Audit", "-ToolRoot", str(missing))
    self.assertNotEqual(0, result.returncode)
    self.assertIn("FAIL TOOL_ROOT", output(result))
    self.assertFalse(missing.exists())

def test_script_has_no_dynamic_execution_or_client_access(self):
    text = INSTALLER.read_text(encoding="utf-8")
    self.assertNotIn("Invoke-Expression", text)
    self.assertNotIn("World of Warcraft", text)
    self.assertIn('[Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")', text)
    self.assertIn("-DisableRemediation", text)
```

Also test an invalid lock schema, lowercase/non-64-character hashes, duplicate machine `PATH` entries, non-HTTPS URLs, and a mismatched fixture file hash. Every rejection must leave the fixture unchanged.

- [ ] **Step 2: Run installer tests to verify RED**

```powershell
$python = 'C:\Users\Massimo\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
& $python -m unittest tests.test_toolchain_installer -v
```

Expected: FAIL because `tools/install-toolchain.ps1` does not exist.

- [ ] **Step 3: Implement read-only audit and fail-closed preflight**

Start `tools/install-toolchain.ps1` with:

```powershell
[CmdletBinding()]
param(
    [ValidateSet("Audit", "Install")]
    [string]$Mode = "Audit",
    [string]$ToolRoot = "C:\Tools",
    [string]$LockPath = (Join-Path $PSScriptRoot "toolchain.lock.json")
)

$ErrorActionPreference = "Stop"
```

Define and use these functions with the indicated parameter contracts:

- `Fail-Stage([string]$Name, [string]$Detail)` terminates with exit `2` after printing one stable failure line.
- `Read-ToolchainLock([string]$Path)` returns the validated schema-1 JSON object.
- `Assert-Administrator()` rejects non-elevated Install before download.
- `Assert-InstallTarget([string]$Path)` accepts only resolved `C:\Tools`.
- `Test-ExpectedFile([string]$Path, [string]$Sha256)` returns a Boolean without mutation.
- `Get-TreeSha256([string]$Root)` returns the documented sorted tree digest.
- `Invoke-VersionProbe([string]$Command, [string[]]$Arguments, [string]$Pattern)` requires exit zero and matching output.
- `Invoke-ToolchainAudit($Lock, [string]$Root)` returns a complete status object and prints named failures.

Audit must not create directories, download, update `PATH`, install Python, write manifests, or invoke Defender. It validates existing files, hashes, versions, the machine `PATH`, Python 3.14.7, PUC 5.1.5, and the generated manifest. Missing state exits nonzero with a named stage.

- [ ] **Step 4: Implement verified staging and installation**

Add these mutation functions with one responsibility each:

- `Get-VerifiedArtifact($Spec, [string]$Destination)` downloads and verifies length/hash.
- `Expand-VerifiedZip([string]$Archive, [string]$Destination)` extracts only into an empty staged directory.
- `Expand-VerifiedMsi([string]$Archive, [string]$Destination)` runs hidden `msiexec /a` and requires exit zero.
- `Install-Python($Spec, [string]$Installer)` runs the exact silent all-users arguments and verifies 3.14.7.
- `Set-RequiredMachinePath([string[]]$Required)` preserves unrelated entries and inserts each required path once.
- `Write-ToolchainManifest($Lock, [string]$Root, [string]$PathBefore)` records artifacts, installed hashes, versions, signatures, and the original machine path.
- `Invoke-DefenderScan([string]$Root)` performs the no-remediation custom scan and requires its clean result.

Install mode must perform these exact stages:

1. require resolved `C:\Tools` and administrator membership;
2. validate the lock completely;
3. create one GUID directory under `%TEMP%` and record its resolved path;
4. download only missing/mismatched required artifacts with `curl.exe -L --fail --silent --show-error`;
5. verify length and SHA-256 before extraction;
6. verify Python Authenticode status `Valid` and signer subject containing `Python Software Foundation`;
7. stage StyLua ZIP, LuaJIT MSI via `msiexec /a`, PUC ZIP, and Luacheck EXE;
8. verify staged executable hashes, LuaJIT tree hash, and version probes;
9. stop rather than overwrite any unexpected existing target hash;
10. place verified files, including `lua.cmd` and `luajit.cmd` wrappers that quote `C:\Tools\LuaJIT\bin\luajit.exe` and forward `%*`;
11. run the Python installer with `/quiet InstallAllUsers=1 TargetDir="C:\Program Files\Python314" PrependPath=1 Include_launcher=1 InstallLauncherAllUsers=1 Include_test=0` and require exit zero;
12. write machine `PATH` entries once each while preserving unrelated entries;
13. write the generated manifest through a temporary sibling and atomic rename;
14. run `MpCmdRun.exe -Scan -ScanType 3 -File C:\Tools -DisableRemediation` and require “found no threats” plus exit zero;
15. delete only the verified GUID temp directory in `finally`;
16. rerun Audit and print `PASS TOOLCHAIN_INSTALL` only when it exits zero.

Use hidden windows for noninteractive `Start-Process` calls. Never launch a UAC prompt from the script: a non-elevated Install exits before download and prints the exact elevated command.

- [ ] **Step 5: Run installer safety tests and current audit**

```powershell
$python = 'C:\Users\Massimo\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
& $python -m unittest tests.test_toolchain_installer -v
powershell -NoProfile -ExecutionPolicy Bypass -File tools/install-toolchain.ps1 -Mode Audit
git diff --check
```

Expected: installer tests PASS; current audit exits nonzero with named missing stages for PUC/Python/machine `PATH` and makes no changes; diff check exits zero.

- [ ] **Step 6: Commit Task 3**

```powershell
git add tools/install-toolchain.ps1 tests/test_toolchain_installer.py
git commit -m "feat(tooling): add safe machine installer"
```

---

### Task 4: Add The Aggregate Repository Gate

**Files:**
- Create: `tools/check-rma.ps1`
- Create: `tests/test_repository_gate.py`
- Modify: `tools/README.md`
- Modify: `docs/VALIDATION.md`

**Interfaces:**
- Consumes: Task 1 lock/config, Task 2 JSON load graph, Task 3 machine manifest and ordinary machine commands.
- Produces: no-argument `tools/check-rma.ps1`; optional `-RepositoryRoot`, `-ToolchainRoot`, and `-BaseRef`; stable stages `TOOLCHAIN`, `STATIC`, `PUC_LUA51`, `STYLUA`, `LUACHECK`, `UNIT_TESTS`, `DIFF`; final `PASS REPOSITORY_GATE`.

- [ ] **Step 1: Write gate failure-propagation and scope tests**

Create `tests/test_repository_gate.py`. Tests must not require a completed machine installation. Cover:

```python
def test_gate_refuses_client_paths(self):
    result = run_gate("-ClientPath", r"C:\Games\World of Warcraft")
    self.assertNotEqual(0, result.returncode)
    self.assertIn("FAIL CLIENT_PATH", output(result))

def test_gate_reports_missing_toolchain_before_static_checks(self):
    with tempfile.TemporaryDirectory() as temporary:
        result = run_gate("-ToolchainRoot", temporary)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("FAIL TOOLCHAIN", output(result))

def test_stylua_selection_is_incremental_and_vendor_closed(self):
    text = GATE.read_text(encoding="utf-8")
    self.assertIn("Get-ChangedOwnedLua", text)
    self.assertIn("--diff-filter=ACMR", text)
    self.assertIn("Raid Management Addon/Libs/", text)
    self.assertNotIn('& $StyluaExecutable --check "Raid Management Addon"', text)

def test_external_smoke_can_only_be_blocked(self):
    text = GATE.read_text(encoding="utf-8")
    self.assertIn("BLOCKED_EXTERNAL_SMOKE", text)
    self.assertNotRegex(text, r"PASS[^\r\n]*EXTERNAL_SMOKE|EXTERNAL_SMOKE[^\r\n]*PASS")
```

Add cases that pass missing explicit `-PythonExecutable`, `-StyluaExecutable`, `-LuacheckExecutable`, `-LuaExecutable`, `-PucLuaCompiler`, and `-GitExecutable` values and assert the matching stable stage. Add a copied Git fixture where a changed vendor Lua path is excluded but a changed owned Lua path is returned once.

- [ ] **Step 2: Run gate tests to verify RED**

```powershell
$python = 'C:\Users\Massimo\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
& $python -m unittest tests.test_repository_gate -v
```

Expected: FAIL because `tools/check-rma.ps1` does not exist.

- [ ] **Step 3: Implement fail-fast tool and manifest preflight**

Create `tools/check-rma.ps1` with parameters:

```powershell
[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$ToolchainRoot = "C:\Tools",
    [string]$BaseRef,
    [string]$PythonExecutable = "py",
    [string]$LuaExecutable = "lua",
    [string]$PucLuaCompiler = "luac5.1",
    [string]$StyluaExecutable = "stylua",
    [string]$LuacheckExecutable = "luacheck",
    [string]$GitExecutable = "git",
    [string]$ClientPath
)
```

Resolve default repository root after parameter binding. Refuse `ClientPath`. Require the lock and machine manifest to agree on schema, tool root, versions, artifact hashes, and installed hashes. Resolve each command through `Get-Command`, reject aliases/functions/non-executable files, and probe `py -3.14`, LuaJIT, PUC Lua 5.1.5, StyLua 2.3.1, and Luacheck 0.23.0.

- [ ] **Step 4: Implement static, PUC, and incremental StyLua stages**

Invoke Task 2 once with `--format json`, parse the result, and pass every returned Lua path to `luac5.1 -p`, including vendor files.

Define `Get-ChangedOwnedLua` to union normalized paths from:

```text
git diff --name-only --diff-filter=ACMR HEAD --
git diff --cached --name-only --diff-filter=ACMR --
git diff --name-only --diff-filter=ACMR <BaseRef>..HEAD --   # only when BaseRef is supplied
git diff --name-only --diff-filter=ACMR HEAD^..HEAD --       # default committed range
```

Keep only existing `.lua` paths under `Raid Management Addon/` and reject `Raid Management Addon/Libs/`. Sort/deduplicate, then invoke:

```powershell
& $StyluaExecutable --config-path ".stylua.toml" --check --respect-ignores -- @changedOwnedLua
```

When the list is empty, print `PASS STYLUA (0 changed owned Lua files)` without invoking StyLua. Do not format files.

- [ ] **Step 5: Implement whole-addon lint, tests, diff, and truthful final output**

Run in order:

```powershell
& $LuacheckExecutable --config ".luacheckrc" -- "Raid Management Addon"
& $PythonExecutable -3.14 -m unittest discover -s tests -p "test_*.py" -v
& $GitExecutable diff --check
```

Every stage must propagate the real nonzero exit and print `FAIL <STAGE>`. On success print:

```text
BLOCKED_EXTERNAL_SMOKE: repository automation cannot observe a WotLK 3.3.5a client
PASS REPOSITORY_GATE
```

- [ ] **Step 6: Replace obsolete documentation commands**

Update `tools/README.md` with exact Audit, elevated Install, and repository gate commands. Update `docs/VALIDATION.md` so the authoritative static command is:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/check-rma.ps1
```

Document that StyLua is incremental because the accepted unchanged baseline is not bulk-formatted, while PUC, static policy, Luacheck, and tests are global. Remove claims that `tools/check-rma.ps1` is absent or that `.agents` validators are authoritative.

- [ ] **Step 7: Run focused gate tests and expected pre-install failure**

```powershell
$python = 'C:\Users\Massimo\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
& $python -m unittest tests.test_repository_gate -v
powershell -NoProfile -ExecutionPolicy Bypass -File tools/check-rma.ps1
git diff --check
```

Expected: gate unit tests PASS; the real no-argument gate exits nonzero at `TOOLCHAIN` because Task 5 has not installed PUC/Python/machine `PATH`; diff check exits zero. A pre-install gate failure is evidence of fail-closed behavior, not a pass.

- [ ] **Step 8: Commit Task 4**

```powershell
git add tools/check-rma.ps1 tests/test_repository_gate.py tools/README.md docs/VALIDATION.md
git commit -m "feat(tooling): add aggregate repository gate"
```

---

### Task 5: Install, Qualify, And Record The Machine-Wide Toolchain

**Files:**
- Create: `docs/validation/2026-08-13-system-wide-toolchain.md`
- Local only: replace ignored `.venv` after a verified recoverable backup.
- Machine only: `C:\Tools`, `C:\Program Files\Python314`, machine `PATH`, generated manifest.

**Interfaces:**
- Consumes: Tasks 1-4 and an elevated Windows PowerShell process.
- Produces: complete machine audit, recreated `.venv`, green repository gate, durable evidence document.

- [ ] **Step 1: Capture the pre-install audit and elevation state**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/install-toolchain.ps1 -Mode Audit
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
```

Expected before installation: Audit exits nonzero with named missing PUC/Python/`PATH` stages. If the elevation check is false, stop automated execution and give the user exactly:

```powershell
Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File "D:\ADDON\RMA-Raid Management Addon\tools\install-toolchain.ps1" -Mode Install'
```

Do not claim machine completion until that elevated command exits zero.

- [ ] **Step 2: Run the elevated idempotent installation**

From elevated Windows PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\ADDON\RMA-Raid Management Addon\tools\install-toolchain.ps1" -Mode Install
```

Expected: `PASS TOOLCHAIN_INSTALL`, valid Defender result, generated `C:\Tools\RMA-TOOLCHAIN-MANIFEST.json`, and no unexpected overwrite.

- [ ] **Step 3: Verify command resolution from a fresh process environment**

Open a new non-elevated PowerShell and run:

```powershell
Get-Command lua,luajit,lua5.1,luac5.1,stylua,luacheck,python,py
lua -v
luajit -v
lua5.1 -v
luac5.1 -v
stylua --version
luacheck --version
python --version
py -3.14 --version
powershell -NoProfile -ExecutionPolicy Bypass -File tools/install-toolchain.ps1 -Mode Audit
```

Expected: all commands resolve for the non-elevated user; versions match the lock; Audit exits zero.

- [ ] **Step 4: Replace the broken ignored virtual environment safely**

Resolve the repository and `.venv`; require the latter to equal `Join-Path $repository '.venv'`. Move it to `.venv.backup-<UTC timestamp>` rather than deleting it. Then run:

```powershell
py -3.14 -m venv .venv
& .\.venv\Scripts\python.exe --version
& .\.venv\Scripts\python.exe -m unittest discover -s tests -p "test_*.py" -v
```

Expected: Python 3.14.7 and all tests PASS. Retain the ignored backup until the full gate passes; only then report it as removable.

- [ ] **Step 5: Run the complete repository gate and independent checks**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/check-rma.ps1
py -3.14 tools/validate-rma.py --root .
Get-ChildItem -LiteralPath 'Raid Management Addon' -Recurse -Filter '*.lua' -File | ForEach-Object {
    luac5.1 -p $_.FullName
    if ($LASTEXITCODE -ne 0) { throw "PUC parse failed: $($_.FullName)" }
}
git diff --check
git status --short --branch
```

Expected: gate exits zero and prints `PASS REPOSITORY_GATE`; validator passes; all Lua parses; diff check passes. Report runtime smoke as not run/manual pending.

- [ ] **Step 6: Write machine qualification evidence**

Create `docs/validation/2026-08-13-system-wide-toolchain.md` recording:

- exact command paths and versions;
- artifact and installed hashes from both manifests;
- Python Authenticode result;
- machine `PATH` entries and duplicate count;
- Defender command/result;
- `.venv` recreation result;
- focused test counts and full suite count;
- PUC parsed file count;
- StyLua changed-file count;
- Luacheck warnings/errors;
- aggregate gate output and exit code;
- `git diff --check` and status;
- `BLOCKED_EXTERNAL_SMOKE` and remaining manual WotLK smoke boundary.

Do not include secrets, full user environment dumps, or unrelated machine paths.

- [ ] **Step 7: Commit Task 5 evidence**

```powershell
git add docs/validation/2026-08-13-system-wide-toolchain.md
git commit -m "docs(tooling): record machine-wide qualification"
```

- [ ] **Step 8: Final coherence check**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/check-rma.ps1
git diff HEAD~5..HEAD --check
git status --short --branch
```

Expected: repository gate passes; five task commits are coherent; only pre-existing unrelated untracked paths such as `.archived-worktrees/` remain; no addon runtime or vendor file appears in the five-commit diff.
