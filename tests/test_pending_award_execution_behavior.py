import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OWNER = ROOT / "Raid Management Addon" / "Services" / "Master" / "PendingAwardExecution.lua"
PENDING_AWARDS = ROOT / "Raid Management Addon" / "Services" / "Loot" / "PendingAwards.lua"


def run_lua(script):
    with tempfile.NamedTemporaryFile(mode="w", suffix=".lua", encoding="utf-8", delete=False) as handle:
        handle.write(script)
        script_path = Path(handle.name)
    try:
        subprocess.run(["lua.cmd", str(script_path)], check=True, cwd=ROOT)
    finally:
        script_path.unlink(missing_ok=True)


class PendingAwardExecutionBehaviorTest(unittest.TestCase):
    def test_owner_orchestrates_confirm_fail_timeout_and_timer_cancellation(self):
        run_lua(textwrap.dedent(f"""
            local addon = {{ Database = {{}} , Services = {{ Master = {{}} }} }}
            function addon.Services.EnsureNamespace(name)
                addon.Services[name] = addon.Services[name] or {{}}
                return addon.Services[name]
            end
            assert(loadfile([[{OWNER.as_posix()}]]))("RMA", addon)
            local factory = assert(addon.Services.Master.PendingAwardExecution)

            local scheduled, cancelled, provisional = {{}}, {{}}, {{}}
            local refreshed, warnings = 0, 0
            local pendingAwards = {{}}
            function pendingAwards.ConfirmProvisional(pending, slot)
                provisional[#provisional + 1] = {{ pending = pending, slot = slot }}
            end
            local owner = factory.Create({{
                confirmProvisional = pendingAwards.ConfirmProvisional,
                timeoutSeconds = 4,
                scheduleTimer = function(callback, delay)
                    local handle = {{ callback = callback, delay = delay }}
                    scheduled[#scheduled + 1] = handle
                    return handle
                end,
                cancelTimer = function(handle) cancelled[#cancelled + 1] = handle end,
                requestRefresh = function() refreshed = refreshed + 1 end,
                warnFailure = function() warnings = warnings + 1 end,
                warnTimeout = function() warnings = warnings + 1 end,
            }})

            local confirmed = 0
            local effect = {{}}
            function effect:Confirm() confirmed = confirmed + 1 return true end
            function effect:Fail(reason) error("unexpected fail: " .. tostring(reason)) end
            local queued = owner:Queue({{ itemLink = "item:1", itemIndex = 3, playerName = "One", effect = effect }})
            assert(queued.effect == effect)
            assert(queued.itemLink == "item:1")
            assert(scheduled[1].delay == 4)
            assert(owner:Confirm(3) == true)
            assert(provisional[1].pending == queued and provisional[1].slot == 3)
            assert(confirmed == 1 and cancelled[1] == scheduled[1])
            assert(owner:HasPending() == false)

            local failedReason
            local failedEffect = {{ Confirm = function() error("unexpected confirm") end }}
            function failedEffect:Fail(reason) failedReason = reason return true end
            owner:Queue({{ itemLink = "item:2", itemIndex = 4, playerName = "Two", effect = failedEffect }})
            assert(owner:Fail("failure") == true)
            assert(failedReason == "failure" and warnings == 1)

            local timeoutReason
            local timeoutEffect = {{ Confirm = function() error("unexpected confirm") end }}
            function timeoutEffect:Fail(reason) timeoutReason = reason return true end
            owner:Queue({{ itemLink = "item:3", itemIndex = 5, playerName = "Three", effect = timeoutEffect }})
            scheduled[3].callback()
            assert(timeoutReason == "timeout")
            assert(refreshed == 1 and warnings == 2)
            assert(owner:HasPending() == false)
        """))

    def test_pending_award_store_purge_removes_only_expired_entries(self):
        run_lua(textwrap.dedent(f"""
            local now = 100
            GetTime = function() return now end
            local state = {{ pendingAwards = {{}}, provisionalAwards = {{}} }}
            local addon = {{
                C = {{ PENDING_AWARD_TTL_SECONDS = 8 }},
                Database = {{}},
                Diag = {{}},
                Item = {{ GetItemStringFromLink = function(link) return link end }},
                Options = {{ IsDebugEnabled = function() return false end }},
                Services = {{}},
                Strings = {{ NormalizeName = function(name) return name end }},
            }}
            function addon.Database.EnsureLootRuntimeState() return nil, state end
            function addon.Services.EnsureNamespace(name)
                addon.Services[name] = addon.Services[name] or {{}}
                return addon.Services[name]
            end
            assert(loadfile([[{PENDING_AWARDS.as_posix()}]]))("RMA", addon)
            local store = assert(addon.Services.Loot.PendingAwards)
            store.Add("item:old", "One", 1, 90)
            now = 110
            store.Add("item:new", "Two", 1, 91)
            store.Purge(5)
            local lists, entries = 0, 0
            for _, list in pairs(state.pendingAwards) do
                lists = lists + 1
                entries = entries + #list
                assert(list[1].itemLink == "item:new")
            end
            assert(lists == 1 and entries == 1)
        """))


if __name__ == "__main__":
    unittest.main()
