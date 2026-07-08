import subprocess
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MULTI_AWARD = ROOT / "Raid Management Addon" / "Services" / "Master" / "MultiAward.lua"


def run_lua(script):
    subprocess.run(["lua.cmd", "-e", script], check=True, cwd=ROOT)


class MasterMultiAwardBehaviorTests(unittest.TestCase):
    def test_build_winners_uses_planner_and_clears_selection_when_requested(self):
        script = textwrap.dedent(
            f"""
            local addon = {{ Services = {{}} }}
            local plannerArgs
            local cleared = 0
            local shared = {{
                EnsureServiceNamespace = function(name)
                    addon.Services[name] = addon.Services[name] or {{}}
                    return addon.Services[name]
                end,
                Services = {{
                    Loot = {{
                        GetLootWindowItemCountByKey = function()
                            return 0
                        end,
                    }},
                }},
                L = {{
                    ChatAward = "award %s %s",
                    ChatAwardMutiple = "award %s %s",
                    ErrNoWinnerSelected = "no winner",
                }},
                Diag = {{
                    W = {{
                        ErrMLMultiSelectNotEnough = "need %d have %d",
                        ErrMLMultiAwardInterruptedTimeout = "timeout %s %s %s %s %s",
                    }},
                    D = {{
                        LogMLMultiAwardStarted = "start %s %s %s %s %s",
                    }},
                }},
                ModuleRegistry = nil,
            }}
            addon.Database = {{
                GetFeatureShared = function()
                    return shared
                end,
            }}

            local chunk = assert(loadfile("{str(MULTI_AWARD).replace("\\", "\\\\")}"))
            chunk("Raid Management Addon", addon)

            local controller = addon.Services.Master.MultiAward.CreateController({{
                awardPlanner = {{
                    BuildMultiAwardWinnersPlan = function(args)
                        plannerArgs = args
                        return {{
                            winners = {{
                                {{ name = "Alpha", roll = 98 }},
                                {{ name = "Beta", roll = 77 }},
                            }},
                            clearSelection = true,
                        }}
                    end,
                    BuildMultiAwardState = function()
                        return {{ state = {{}} }}
                    end,
                }},
                inventory = {{
                    BuildMultiAwardSlotCandidates = function()
                        return {{}}, {{}}
                    end,
                }},
                lootState = {{ currentRollType = 1 }},
                rollUi = {{
                    GetSelectedCount = function()
                        return 2
                    end,
                    BuildModel = function()
                        return {{
                            rows = {{
                                {{ name = "Alpha", roll = 98 }},
                                {{ name = "Beta", roll = 77 }},
                            }},
                        }}
                    end,
                    GetSelectedWinnersOrdered = function(_, rows)
                        if not (rows and rows[1] and rows[2]) then
                            error("rows missing")
                        end
                        return {{
                            {{ name = rows[1].name, roll = rows[1].roll }},
                            {{ name = rows[2].name, roll = rows[2].roll }},
                        }}
                    end,
                    ClearAnchor = function()
                        cleared = cleared + 1
                    end,
                }},
                scheduleTimer = function()
                    return {{}}
                end,
                cancelTimer = function()
                end,
                registerAwardedItem = function()
                end,
                awardExecutor = {{
                    Assign = function()
                        return true
                    end,
                }},
                itemCount = {{
                    Set = function()
                    end,
                    Reset = function()
                    end,
                }},
            }})

            local winners, errType = controller:BuildWinners(2)
            if errType ~= nil then
                error("unexpected errType " .. tostring(errType))
            end
            if not (winners and winners[1] and winners[2]) then
                error("expected winners")
            end
            if winners[1].name ~= "Alpha" or winners[2].name ~= "Beta" then
                error("winner order mismatch")
            end
            if not plannerArgs then
                error("planner args missing")
            end
            if plannerArgs.target ~= 2 or plannerArgs.selectedCount ~= 2 then
                error("planner args mismatch")
            end
            if plannerArgs.pickedWinners[1].name ~= "Alpha" or plannerArgs.pickedWinners[2].name ~= "Beta" then
                error("picked winners mismatch")
            end
            if cleared ~= 1 then
                error("expected ClearAnchor once, got " .. tostring(cleared))
            end
            """
        )
        run_lua(script)

    def test_finalize_if_done_announces_and_clears_state(self):
        script = textwrap.dedent(
            f"""
            local addon = {{ Services = {{}} }}
            local announces = {{}}
            local resetCalls = 0
            local shared = {{
                EnsureServiceNamespace = function(name)
                    addon.Services[name] = addon.Services[name] or {{}}
                    return addon.Services[name]
                end,
                Services = {{
                    Loot = {{
                        GetLootWindowItemCountByKey = function()
                            return 0
                        end,
                    }},
                }},
                L = {{
                    ChatAward = "award %s %s",
                    ChatAwardMutiple = "awards %s %s",
                    ErrNoWinnerSelected = "no winner",
                }},
                Diag = {{
                    W = {{
                        ErrMLMultiSelectNotEnough = "need %d have %d",
                        ErrMLMultiAwardInterruptedTimeout = "timeout %s %s %s %s %s",
                    }},
                    D = {{
                        LogMLMultiAwardStarted = "start %s %s %s %s %s",
                    }},
                }},
                ModuleRegistry = nil,
            }}
            addon.Database = {{
                GetFeatureShared = function()
                    return shared
                end,
            }}

            local chunk = assert(loadfile("{str(MULTI_AWARD).replace("\\", "\\\\")}"))
            chunk("Raid Management Addon", addon)

            local lootState = {{
                multiAward = {{
                    active = true,
                    announceOnWin = true,
                    congratsSent = false,
                    total = 2,
                    pos = 3,
                    itemLink = "|cffloot|Hitem:1|h[item]|h|r",
                    winners = {{
                        {{ name = "Alpha" }},
                        {{ name = "Beta" }},
                    }},
                }},
            }}

            local controller = addon.Services.Master.MultiAward.CreateController({{
                awardPlanner = {{
                    BuildMultiAwardWinnersPlan = function()
                        return {{ winners = {{}} }}
                    end,
                    BuildMultiAwardState = function()
                        return {{ state = {{}} }}
                    end,
                }},
                inventory = {{
                    BuildMultiAwardSlotCandidates = function()
                        return {{}}, {{}}
                    end,
                }},
                lootState = lootState,
                rollUi = {{
                    GetSelectedCount = function()
                        return 0
                    end,
                }},
                scheduleTimer = function()
                    return {{}}
                end,
                cancelTimer = function()
                end,
                announce = function(message)
                    announces[#announces + 1] = message
                end,
                registerAwardedItem = function()
                end,
                awardExecutor = {{
                    Assign = function()
                        return true
                    end,
                }},
                itemCount = {{
                    Set = function()
                    end,
                    Reset = function()
                        resetCalls = resetCalls + 1
                    end,
                }},
            }})

            local ok = controller:FinalizeIfDone()
            if ok ~= true then
                error("expected finalize success")
            end
            if lootState.multiAward ~= nil then
                error("expected multiAward cleared")
            end
            if resetCalls ~= 1 then
                error("expected itemCount reset once, got " .. tostring(resetCalls))
            end
            if announces[1] ~= "awards Alpha, Beta |cffloot|Hitem:1|h[item]|h|r" then
                error("unexpected announcement " .. tostring(announces[1]))
            end
        """
        )
        run_lua(script)

    def test_try_multiple_copies_arms_timeout_and_clears_on_timeout(self):
        script = textwrap.dedent(
            f"""
            local addon = {{ Services = {{}} }}
            local timers = {{}}
            local warns = {{}}
            local refreshes = 0
            local resetCalls = 0
            local registers = 0
            local assigned = {{}}
            local shared = {{
                EnsureServiceNamespace = function(name)
                    addon.Services[name] = addon.Services[name] or {{}}
                    return addon.Services[name]
                end,
                Services = {{
                    Loot = {{
                        GetLootWindowItemCountByKey = function(_, itemKey)
                            if itemKey ~= "key:1" then
                                error("unexpected itemKey " .. tostring(itemKey))
                            end
                            return 2
                        end,
                    }},
                }},
                L = {{
                    ChatAward = "award %s %s",
                    ChatAwardMutiple = "awards %s %s",
                    ErrNoWinnerSelected = "no winner",
                }},
                Diag = {{
                    W = {{
                        ErrMLMultiSelectNotEnough = "need %d have %d",
                        ErrMLMultiAwardInterruptedTimeout = "timeout %s %s %s %s %s",
                    }},
                    D = {{
                        LogMLMultiAwardStarted = "start %s %s %s %s %s",
                    }},
                }},
                ModuleRegistry = nil,
            }}
            addon.Database = {{
                GetFeatureShared = function()
                    return shared
                end,
            }}

            local chunk = assert(loadfile("{str(MULTI_AWARD).replace("\\", "\\\\")}"))
            chunk("Raid Management Addon", addon)

            local lootState = {{ currentRollType = 1 }}
            local controller = addon.Services.Master.MultiAward.CreateController({{
                awardPlanner = {{
                    BuildMultiAwardWinnersPlan = function()
                        return {{
                            winners = {{
                                {{ name = "Alpha", roll = 98 }},
                                {{ name = "Beta", roll = 77 }},
                            }},
                        }}
                    end,
                    BuildMultiAwardState = function(args)
                        return {{
                            state = {{
                                active = true,
                                announceOnWin = false,
                                itemLink = args.itemLink,
                                itemKey = "key:1",
                                winners = args.winners,
                                total = #args.winners,
                                pos = 2,
                                rollType = args.rollType,
                                lastCount = args.available,
                            }},
                        }}
                    end,
                }},
                inventory = {{
                    BuildMultiAwardSlotCandidates = function()
                        return {{ 3, 4 }}, {{ [3] = true, [4] = true }}
                    end,
                }},
                lootState = lootState,
                rollUi = {{
                    GetSelectedCount = function()
                        return 0
                    end,
                }},
                scheduleTimer = function(callback, delay)
                    timers[#timers + 1] = {{ callback = callback, delay = delay }}
                    return timers[#timers]
                end,
                cancelTimer = function()
                end,
                warn = function(message)
                    warns[#warns + 1] = message
                end,
                registerAwardedItem = function(count)
                    registers = registers + count
                end,
                refresh = function()
                    refreshes = refreshes + 1
                end,
                awardExecutor = {{
                    Assign = function(_, itemLink, playerName, rollType, rollValue)
                        assigned[#assigned + 1] = {{
                            itemLink = itemLink,
                            playerName = playerName,
                            rollType = rollType,
                            rollValue = rollValue,
                        }}
                        return true
                    end,
                }},
                itemCount = {{
                    Set = function()
                    end,
                    Reset = function()
                        resetCalls = resetCalls + 1
                    end,
                }},
                multiAwardTimeoutSeconds = 7,
            }})

            local ok = controller:TryMultipleCopies("|cffloot|Hitem:1|h[item]|h|r", 2, 2)
            if ok ~= true then
                error("expected TryMultipleCopies success")
            end
            if not (lootState.multiAward and lootState.multiAward.waitingForDecrement) then
                error("expected waitingForDecrement after first award")
            end
            if #assigned ~= 1 or assigned[1].playerName ~= "Alpha" then
                error("expected first award to Alpha")
            end
            if registers ~= 1 then
                error("expected registerAwardedItem once")
            end
            if #timers ~= 1 or timers[1].delay ~= 7 then
                error("expected one timeout timer at 7 seconds")
            end

            timers[1].callback()

            if lootState.multiAward ~= nil then
                error("expected timeout to clear multi-award state")
            end
            if resetCalls ~= 1 then
                error("expected timeout to reset item count")
            end
            if refreshes ~= 2 then
                error("expected refresh after start and after timeout, got " .. tostring(refreshes))
            end
            if warns[1] ~= "timeout 7 |cffloot|Hitem:1|h[item]|h|r 2 2 ?" then
                error("unexpected warn message " .. tostring(warns[1]))
            end
        """
        )
        run_lua(script)

    def test_continue_on_loot_slot_cleared_schedules_next_award_on_decrement(self):
        script = textwrap.dedent(
            f"""
            local addon = {{ Services = {{}} }}
            local timers = {{}}
            local refreshes = 0
            local registers = 0
            local assigned = {{}}
            local counts = {{ ["key:1"] = 1 }}
            local shared = {{
                EnsureServiceNamespace = function(name)
                    addon.Services[name] = addon.Services[name] or {{}}
                    return addon.Services[name]
                end,
                Services = {{
                    Loot = {{
                        GetLootWindowItemCountByKey = function(_, itemKey)
                            return counts[itemKey] or 0
                        end,
                    }},
                }},
                L = {{
                    ChatAward = "award %s %s",
                    ChatAwardMutiple = "awards %s %s",
                    ErrNoWinnerSelected = "no winner",
                }},
                Diag = {{
                    W = {{
                        ErrMLMultiSelectNotEnough = "need %d have %d",
                        ErrMLMultiAwardInterruptedTimeout = "timeout %s %s %s %s %s",
                    }},
                    D = {{
                        LogMLMultiAwardStarted = "start %s %s %s %s %s",
                    }},
                }},
                ModuleRegistry = nil,
            }}
            addon.Database = {{
                GetFeatureShared = function()
                    return shared
                end,
            }}

            local chunk = assert(loadfile("{str(MULTI_AWARD).replace("\\", "\\\\")}"))
            chunk("Raid Management Addon", addon)

            local lootState = {{
                currentRollType = 1,
                multiAward = {{
                    active = true,
                    announceOnWin = false,
                    itemLink = "|cffloot|Hitem:1|h[item]|h|r",
                    itemKey = "key:1",
                    winners = {{
                        {{ name = "Alpha", roll = 98 }},
                        {{ name = "Beta", roll = 77 }},
                    }},
                    total = 2,
                    pos = 2,
                    rollType = 3,
                    lastCount = 2,
                    waitingForDecrement = true,
                }},
            }}

            local controller = addon.Services.Master.MultiAward.CreateController({{
                awardPlanner = {{
                    BuildMultiAwardWinnersPlan = function()
                        return {{ winners = {{}} }}
                    end,
                    BuildMultiAwardState = function()
                        return {{ state = {{}} }}
                    end,
                }},
                inventory = {{
                    BuildMultiAwardSlotCandidates = function(_, itemLink)
                        if itemLink ~= "|cffloot|Hitem:1|h[item]|h|r" then
                            error("unexpected itemLink " .. tostring(itemLink))
                        end
                        return {{ 7 }}, {{ [7] = true }}
                    end,
                }},
                lootState = lootState,
                rollUi = {{
                    GetSelectedCount = function()
                        return 0
                    end,
                }},
                scheduleTimer = function(callback, delay)
                    timers[#timers + 1] = {{ callback = callback, delay = delay }}
                    return timers[#timers]
                end,
                cancelTimer = function()
                end,
                registerAwardedItem = function(count)
                    registers = registers + count
                end,
                refresh = function()
                    refreshes = refreshes + 1
                end,
                awardExecutor = {{
                    Assign = function(_, itemLink, playerName, rollType, rollValue)
                        assigned[#assigned + 1] = {{
                            itemLink = itemLink,
                            playerName = playerName,
                            rollType = rollType,
                            rollValue = rollValue,
                        }}
                        return true
                    end,
                }},
                itemCount = {{
                    Set = function()
                    end,
                    Reset = function()
                    end,
                }},
                multiAwardDelaySeconds = 1,
            }})

            local ok = controller:ContinueOnLootSlotCleared(4)
            if ok ~= true then
                error("expected continuation scheduling")
            end
            if lootState.multiAward.lastClearedSlot ~= 4 then
                error("expected lastClearedSlot update")
            end
            if lootState.multiAward.lastCount ~= 1 then
                error("expected lastCount refresh")
            end
            if #timers ~= 1 or timers[1].delay ~= 1 then
                error("expected one delay timer")
            end

            timers[1].callback()

            if #assigned ~= 1 or assigned[1].playerName ~= "Beta" then
                error("expected Beta follow-up award")
            end
            if registers ~= 1 then
                error("expected registerAwardedItem once")
            end
            if lootState.multiAward ~= nil then
                error("expected sequence to clear after final follow-up")
            end
            if refreshes ~= 2 then
                error("expected refresh before and after follow-up, got " .. tostring(refreshes))
            end
        """
        )
        run_lua(script)


if __name__ == "__main__":
    unittest.main()
