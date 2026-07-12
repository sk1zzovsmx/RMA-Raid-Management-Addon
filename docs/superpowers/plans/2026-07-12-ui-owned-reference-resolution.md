# UI Owned Reference Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make RMA UI child lookup prefer the control owned by the supplied frame so Interface Options layout cannot mutate unrelated globals with generic names.

**Architecture:** Preserve the public `Frames.GetRef(frameOrName, childName)` API and change only its resolution precedence in `Modules/UI/Frames.lua`. Add a source-level characterization test that locks owned-child precedence, absolute-name support, global fallback, and invalid-input behavior without introducing a Lua test runtime.

**Tech Stack:** World of Warcraft 3.3.5a FrameXML, Lua 5.1, Python 3 `unittest`, PowerShell repository validators.

## Global Constraints

- Target WotLK 3.3.5a, Interface `30300`, and Lua 5.1.
- Keep XML layout-only and do not modify vendored libraries under `Libs/`.
- Preserve all public RMA frame names, SavedVariables, slash commands, addon-message formats, option keys, and localized strings.
- Resolve an existing owner-prefixed child before an unrelated exact global.
- Preserve already-absolute owned names and exact-global fallback when no owned child exists.
- Keep runtime code and comments ASCII.

---

### Task 1: Lock The Resolver Precedence Contract

**Files:**
- Create: `tests/test_ui_frames_contract.py`
- Read: `Raid Management Addon/Modules/UI/Frames.lua:306`

**Interfaces:**
- Consumes: the Lua source definition `function Frames.GetRef(frameOrName, childName)`.
- Produces: `UiFramesReferenceContractTest`, which rejects exact-global-first lookup and protects the compatibility branches.

- [ ] **Step 1: Write the failing resolver contract test**

```python
from __future__ import annotations

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
FRAMES_LUA = ROOT / "Raid Management Addon" / "Modules" / "UI" / "Frames.lua"


def get_ref_body() -> str:
    source = FRAMES_LUA.read_text(encoding="utf-8")
    match = re.search(
        r"function Frames\.GetRef\(frameOrName, childName\)([\s\S]*?)\nend",
        source,
    )
    if match is None:
        raise AssertionError("Frames.GetRef definition is missing")
    return match.group(1)


class UiFramesReferenceContractTest(unittest.TestCase):
    def test_owned_child_precedes_exact_global_fallback(self) -> None:
        body = get_ref_body()
        owned_lookup = "local owned = _G[frameName .. childName]"
        exact_fallback = "return _G[childName]"
        self.assertIn(owned_lookup, body)
        self.assertIn("if owned then", body)
        self.assertLess(body.index(owned_lookup), body.rindex(exact_fallback))

    def test_absolute_owned_name_remains_supported(self) -> None:
        body = get_ref_body()
        self.assertIn("if strsub(childName, 1, #frameName) == frameName then", body)
        self.assertIn("return _G[childName]", body)

    def test_invalid_inputs_remain_guarded(self) -> None:
        body = get_ref_body()
        self.assertIn('if type(frameName) ~= "string" or frameName == "" then', body)
        self.assertIn('if type(childName) ~= "string" or childName == "" then', body)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the focused test and verify the old order fails**

Run:

```powershell
py -3 -m unittest tests.test_ui_frames_contract -v
```

Expected: FAIL because `Frames.GetRef` does not yet define `local owned = _G[frameName .. childName]` and still checks the exact global first.

- [ ] **Step 3: Preserve the failing-test evidence without committing red state**

Record the focused command and its expected owned-lookup assertion failure in
the execution notes, then continue directly to Task 2. Do not commit while the
new test is failing.

---

### Task 2: Prefer The Child Owned By The Supplied Frame

**Files:**
- Modify: `Raid Management Addon/Modules/UI/Frames.lua:306-323`
- Test: `tests/test_ui_frames_contract.py`

**Interfaces:**
- Consumes: `resolveFrameName(frameOrName)` and `_G`.
- Produces: unchanged `Frames.GetRef(frameOrName, childName)` signature with owner-first resolution and exact-global fallback.

- [ ] **Step 1: Implement the minimal precedence change**

Replace the final lookup portion of `Frames.GetRef` with:

```lua
	if strsub(childName, 1, #frameName) == frameName then
		return _G[childName]
	end

	local owned = _G[frameName .. childName]
	if owned then
		return owned
	end

	return _G[childName]
```

Do not change the two existing invalid-input guards or the function signature.

- [ ] **Step 2: Run the focused test and verify it passes**

Run:

```powershell
py -3 -m unittest tests.test_ui_frames_contract -v
```

Expected: 3 tests pass.

- [ ] **Step 3: Run the Config and full Python suites**

Run:

```powershell
py -3 -m unittest tests.test_config_xml_contract -v
py -3 -m unittest discover -s tests -v
```

Expected: Config contract passes and the full suite reports no failures.

- [ ] **Step 4: Review every shared resolver caller for semantic fit**

Run:

```powershell
rg -n "Frames\.GetRef\(" "Raid Management Addon" -g "*.lua" -g "!Libs/**"
```

Expected: callers pass an owner frame or frame name plus either a short owned suffix or an already-absolute owned name. Record any exception before proceeding; do not add caller-specific workarounds.

- [ ] **Step 5: Commit the resolver test and fix atomically**

```powershell
git add -- tests/test_ui_frames_contract.py "Raid Management Addon/Modules/UI/Frames.lua"
git commit -m "fix(ui): Prefer frame-owned references"
```

Expected: one green commit containing the regression contract and minimal
precedence change.

---

### Task 3: Validate WotLK Runtime And Package Contracts

**Files:**
- Verify: `Raid Management Addon/Modules/UI/Frames.lua`
- Verify: `Raid Management Addon/UI/Config.xml`
- Verify: `Raid Management Addon/Raid Management Addon.toc`

**Interfaces:**
- Consumes: the completed resolver behavior and repository validation scripts.
- Produces: validation evidence and an explicit in-game smoke-test checklist; no new runtime API.

- [ ] **Step 1: Run repository and WotLK validators**

Run:

```powershell
py -3 "..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py" "Raid Management Addon/Raid Management Addon.toc"
py -3 "..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py" "Raid Management Addon"
py -3 "..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py" "Raid Management Addon"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon/UI" -g "*.xml"
rg -n "C_Timer|C_AddOns|Settings\.|MenuUtil|SetAtlas|SetColorTexture|table\.pack|table\.unpack|goto|_ENV" "Raid Management Addon" -g "*.lua" -g "!Libs/**"
git diff --check
```

Expected: TOC, Lua 5.1, and `xpcall` validators pass; XML handler and unsupported-API searches return no newly introduced matches; `git diff --check` is clean.

- [ ] **Step 2: Run the repository aggregate check when available**

Run:

```powershell
if (Test-Path "tools/check-rma.ps1") { & "tools/check-rma.ps1" }
```

Expected: the script exits successfully. If unavailable or blocked by a missing optional executable, record the exact skipped gate and run its available constituent checks individually.

- [ ] **Step 3: Produce the runtime smoke checklist for the user**

Request verification of these exact flows in the 3.3.5a client:

```text
Interface > AddOns > RMA root, Master Loot, Loot History, LFM Spam,
Raid Warning, and Help:
- titles remain at the top;
- text wraps before the right boundary;
- controls remain inside the visible panel;
- scroll bars reach all content.

Also open /rma config, Warnings, Spammer, Loot Counter, and Reserves,
then run /reload and repeat Interface > AddOns > RMA navigation.
```

Expected: no Lua errors, misplaced generic controls, missing buttons, or truncated unreachable content.

- [ ] **Step 4: Review final branch coherence**

Run:

```powershell
git status --short --branch
git log --oneline --decorate -4
git diff main...HEAD --check
git diff main...HEAD --stat
```

Expected: only the approved design, plan, focused test, and resolver implementation are present; the worktree is clean and the root workspace README changes are absent.
