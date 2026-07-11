from pathlib import Path
import re
import subprocess
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
STRINGS = ADDON / "Modules" / "Strings.lua"
LOOT_SOURCE_CANDIDATES = ADDON / "Modules" / "LootSourceCandidates.lua"
LOOT_SOURCES_DATA = ADDON / "Modules" / "Dataset" / "LootSourcesData.lua"
LOOT_SOURCES = ADDON / "Modules" / "LootSources.lua"
IGNORED_MOBS = ADDON / "Modules" / "Dataset" / "IgnoredMobs.lua"
INIT = ADDON / "Init.lua"
LOGGER_ACTIONS = ADDON / "Services" / "Logger" / "Actions.lua"

ORIGINAL_IGNORED_MOB_IDS = {
    10162, 12557, 15589, 15929, 15930, 16062, 16063, 16064, 16065, 16151,
    16803, 17229, 17535, 17543, 17546, 17547, 17548, 18832, 18834, 18835,
    18836, 20060, 20062, 20063, 20064, 21268, 21269, 21270, 21271, 21272,
    21273, 21274, 21875, 22949, 22950, 22951, 22952, 30449, 30451, 30452,
    30549, 32857, 32867, 32913, 32914, 32915, 32927, 32933, 32934, 33136,
    33329, 33432, 33524, 33651, 33670, 33890, 34014, 34035, 34441, 34444,
    34445, 34447, 34448, 34449, 34450, 34451, 34453, 34454, 34455, 34456,
    34458, 34459, 34460, 34461, 34463, 34465, 34466, 34467, 34468, 34469,
    34470, 34471, 34472, 34473, 34474, 34475, 34496, 34497, 35465, 35610,
    36791, 37868, 37886, 37934, 37950, 37970, 37972, 37973, 37985, 39899,
}

EXPECTED_IGNORED_MOBS_BY_RAID = {
    "Blackwing Lair": (12557, 10162),
    "Temple of Ahn'Qiraj": (15589,),
    "Naxxramas": (16803, 15930, 15929, 30549, 16065, 16064, 16062, 16063),
    "Karazhan": (16151, 17229, 17535, 17546, 17543, 17547, 17548),
    "Gruul's Lair": (18835, 18836, 18834, 18832),
    "Serpentshrine Cavern": (21875,),
    "The Eye": (
        20064, 20060, 20062, 20063, 21270, 21269, 21271, 21268, 21273, 21274, 21272,
    ),
    "Black Temple": (22949, 22950, 22951, 22952),
    "The Obsidian Sanctum": (30451, 30452, 30449),
    "Ulduar": (
        33670, 33329, 33651, 32867, 32927, 32857, 34035, 32933, 32934,
        33524, 33890, 33136, 32915, 32913, 32914, 34014, 33432,
    ),
    "Trial of the Crusader": (
        34461, 34460, 34469, 34467, 34468, 34465, 34471, 34466, 34473,
        34472, 34470, 34463, 34474, 34475, 34458, 34451, 34459, 34448,
        34449, 34445, 34456, 34447, 34441, 34454, 34444, 34455, 34450,
        34453, 35610, 35465, 34497, 34496,
    ),
    "Icecrown Citadel": (
        37972, 37970, 37973, 37950, 37868, 36791, 37934, 37886, 37985,
    ),
    "The Ruby Sanctum": (39899,),
}


def lua_path(path):
    return str(path).replace("\\", "\\\\")


def ignored_mob_mapping_lua():
    raids = []
    for raid_name, npc_ids in EXPECTED_IGNORED_MOBS_BY_RAID.items():
        ids = ", ".join(str(npc_id) for npc_id in npc_ids)
        raids.append(
            f'{{ name = "{raid_name}", key = "{raid_name.lower()}", ids = {{ {ids} }} }}'
        )
    return "{ " + ", ".join(raids) + " }"


class LazyInstanceDatasetsTest(unittest.TestCase):
    def test_active_index_shape_is_bounded_to_one_raid(self):
        script = textwrap.dedent(
            f"""
            _G.GetAchievementLink = function() return nil end

            local function loadData(raw)
                local addon = {{ Colors = {{}} }}
                assert(loadfile("{lua_path(STRINGS)}"))("Raid Management Addon", addon)
                assert(loadfile("{lua_path(LOOT_SOURCE_CANDIDATES)}"))("Raid Management Addon", addon)
                addon.LootSourcesData = {{ Raw = raw }}
                assert(loadfile("{lua_path(LOOT_SOURCES_DATA)}"))("Raid Management Addon", addon)
                return addon.LootSourcesData
            end

            local naxxSources = {{
                {{ name = "Anub'Rekhan", npcId = 15956, items = {{
                    {{ 39139, {{ normal10 = true }} }},
                    {{ 39140, {{ normal10 = true, normal25 = true }} }},
                }} }},
            }}
            local ulduarSources = {{
                {{ name = "Flame Leviathan", npcId = 33113, items = {{
                    {{ 45282, {{ normal10 = true }} }},
                    {{ 45283, {{ normal10 = true, normal25 = true }} }},
                }} }},
            }}

            local activeData = loadData({{
                {{ name = "Naxxramas", sources = naxxSources }},
                {{ name = "Ulduar", sources = ulduarSources }},
            }})
            local globalFixture = loadData({{
                {{ name = "Global Fixture", sources = {{
                    naxxSources[1],
                    ulduarSources[1],
                }} }},
            }})

            local function countGeneratedShape(...)
                local seen = {{}}
                local candidates = 0
                local references = 0

                local function visit(value)
                    if type(value) ~= "table" then return end
                    references = references + 1
                    if seen[value] then return end
                    seen[value] = true
                    for key, child in pairs(value) do
                        candidates = candidates + 1
                        visit(key)
                        visit(child)
                    end
                end

                for i = 1, select("#", ...) do
                    visit(select(i, ...))
                end
                return candidates, references
            end

            local beforeKb = collectgarbage("count")
            local inactiveCandidates, inactiveReferences = countGeneratedShape(
                activeData.ByItemId,
                activeData.ByInstance
            )
            assert(inactiveCandidates == 0 and inactiveReferences == 0)

            assert(activeData.ActivateInstance("Naxxramas") == true)
            local activeKb = collectgarbage("count")
            local naxxCandidates, naxxReferences = countGeneratedShape(
                activeData.ByItemId,
                activeData.ByInstance
            )
            assert(naxxCandidates > 0 and naxxReferences > 0)

            assert(globalFixture.ActivateInstance("Global Fixture") == true)
            local globalCandidates, globalReferences = countGeneratedShape(
                globalFixture.ByItemId,
                globalFixture.ByInstance
            )
            assert(naxxCandidates < globalCandidates)
            assert(naxxReferences < globalReferences)

            assert(activeData.DeactivateInstance() == true)
            assert(activeData.ByItemId == nil and activeData.ByInstance == nil)
            local deactivatedKb = collectgarbage("count")
            collectgarbage("collect")
            local collectedKb = collectgarbage("count")

            print(string.format(
                "memory-shape kb before=%.3f active=%.3f deactivated=%.3f collected=%.3f " ..
                    "naxx_candidates=%d naxx_references=%d global_candidates=%d global_references=%d",
                beforeKb,
                activeKb,
                deactivatedKb,
                collectedKb,
                naxxCandidates,
                naxxReferences,
                globalCandidates,
                globalReferences
            ))
            """
        )
        subprocess.run(
            ["lua.cmd", "-e", " ".join(line.strip() for line in script.splitlines())],
            check=True,
            cwd=ROOT,
        )

    def test_logger_source_rebuild_bounds_historical_dataset_lifecycle(self):
        script = textwrap.dedent(
            f"""
            local scheduled = {{}}
            local cancelledTimers = 0
            local raids = {{}}
            local activeKey = "karazhan"
            local activations = {{}}
            local resolverKeys = {{}}
            local failResolution = false
            local failActivation = false

            local data = {{}}
            function data.GetActiveInstanceKey() return activeKey end
            function data.ActivateInstance(instanceName)
                if failActivation and instanceName == "Naxxramas" then error("injected activation failure") end
                local keys = {{
                    Naxxramas = "naxxramas", Ulduar = "ulduar", Karazhan = "karazhan",
                    naxxramas = "naxxramas", ulduar = "ulduar", karazhan = "karazhan",
                }}
                activeKey = keys[instanceName]
                table.insert(activations, activeKey or "unsupported")
                if activeKey then return true end
                return false, "unsupported-instance"
            end
            function data.DeactivateInstance()
                activeKey = nil
                table.insert(activations, "deactivated")
                return true
            end

            local raidStore = {{}}
            function raidStore:GetAllRaids() return raids end
            function raidStore:MarkLootSyncRevision() end
            function raidStore:TouchRaidSyncRevision() end

            local queries = {{}}
            function queries:FindBossByNid() return nil end
            function queries:FindBossByName() return nil end
            function queries:FindBossBySourceNpcId() return nil end
            function queries:FindBossBySourceKey() return nil end

            local actions = {{}}
            local addon = {{
                L = {{}}, Diag = {{}}, Strings = {{
                    TrimText = function(value) return value or "" end,
                    NormalizeName = function(value) return value end,
                }},
                Base64 = {{ Encode = function(value) return value end }},
                LootSourceCandidates = {{}}, LootSourcesData = data,
                LootSources = {{
                    FindSource = function()
                        table.insert(resolverKeys, activeKey or "inactive")
                        if failResolution then error("injected resolution failure") end
                        assert(activeKey == "naxxramas" or activeKey == "ulduar", "resolver observed stale dataset " .. tostring(activeKey))
                        return {{ reason = "missing" }}
                    end,
                }},
                Database = {{
                    EnsureServiceNamespace = function() end,
                    GetRaidStore = function() return raidStore end,
                    GetRaidQueries = function() return queries end,
                    EnsureRaidSchema = function() end,
                }},
                Services = {{ Logger = {{ Actions = actions, Store = {{ _InvalidateIndexes = function() end }}, Helpers = {{}} }} }},
                Timer = {{
                    BindMixin = function(target)
                        function target:ScheduleTimer(callback)
                            local handle = {{ callback = callback, cancelled = false }}
                            table.insert(scheduled, handle)
                            return handle
                        end
                        function target:CancelTimer(handle)
                            handle.cancelled = true
                            cancelledTimers = cancelledTimers + 1
                        end
                    end,
                }},
                Time = {{ GetCurrentTime = function() return 1 end }},
                Bus = {{ TriggerEvent = function() end }},
                Events = {{ Internal = {{ LoggerLootChanged = "loot", LoggerDataChanged = "data" }} }},
            }}
            assert(loadfile("{lua_path(LOGGER_ACTIONS)}"))("Raid Management Addon", addon)

            local function drainTimers()
                while #scheduled > 0 do
                    local handle = table.remove(scheduled, 1)
                    if not handle.cancelled then handle.callback() end
                end
            end
            local function runNextTimer()
                while #scheduled > 0 do
                    local handle = table.remove(scheduled, 1)
                    if not handle.cancelled then
                        handle.callback()
                        return
                    end
                end
                error("no runnable timer")
            end

            raids = {{
                {{ zone = "Naxxramas", loot = {{ {{ itemId = 39139 }} }} }},
                {{ zone = "Unsupported Raid", loot = {{ {{ itemId = 99999 }} }} }},
            }}
            local syncResult = actions:RebuildLootSources()
            assert(syncResult.raids == 2 and syncResult.scanned == 2 and syncResult.unresolved == 2, "sync counts")
            assert(activeKey == "karazhan", "synchronous rebuild did not restore live dataset")

            raids = {{ {{ zone = "Naxxramas", loot = {{ {{ itemId = 39139 }} }} }} }}
            local completed = false
            actions:StartLootSourceRebuild(function(_, done) completed = done end, {{ chunkSize = 1, delaySeconds = 0 }})
            runNextTimer()
            assert(activeKey == "karazhan", "historical index leaked between chunks")
            data.ActivateInstance("Ulduar")
            drainTimers()
            assert(completed == true and activeKey == "ulduar", "completed rebuild overwrote the zone transition")
            data.ActivateInstance("Karazhan")

            local cancelled = actions:StartLootSourceRebuild(nil, {{ chunkSize = 1, delaySeconds = 0 }})
            runNextTimer()
            assert(activeKey == "karazhan", "chunked rebuild leaked its historical dataset")
            assert(cancelled:Cancel() == true, "first cancellation")
            assert(activeKey == "karazhan", "cancelled rebuild did not restore live dataset")
            assert(cancelled:Cancel() == false, "cancellation must be idempotent")

            local replaced = actions:StartLootSourceRebuild(nil, {{ chunkSize = 1, delaySeconds = 0 }})
            runNextTimer()
            assert(activeKey == "karazhan", "replacement precondition")
            local replacement = actions:StartLootSourceRebuild(nil, {{ chunkSize = 1, delaySeconds = 0 }})
            assert(replaced:IsCancelled() == true and activeKey == "karazhan", "replacement did not restore prior live dataset")
            assert(replacement:Cancel() == true and activeKey == "karazhan", "replacement cancellation")
            assert(cancelledTimers >= 2, "replacement did not cancel scheduled timers")

            activations = {{}}
            resolverKeys = {{}}
            raids = {{
                {{ zone = "Naxxramas", loot = {{ {{ itemId = 39139 }} }} }},
                {{ zone = "Ulduar", loot = {{ {{ itemId = 45282 }} }} }},
            }}
            actions:StartLootSourceRebuild(nil, {{ chunkSize = 1, delaySeconds = 0 }})
            drainTimers()
            assert(table.concat(resolverKeys, ",") == "naxxramas,ulduar", "historical resolver order mismatch")
            assert(activeKey == "karazhan", "two-raid rebuild did not preserve live context")
            assert(table.concat(activations, ","):find("naxxramas", 1, true), "Naxxramas was not leased")
            assert(table.concat(activations, ","):find("ulduar", 1, true), "Ulduar was not leased")

            activations = {{}}
            resolverKeys = {{}}
            local unsupportedResult
            raids = {{ {{ zone = "Unsupported Raid", loot = {{ {{ itemId = 99999 }} }} }} }}
            actions:StartLootSourceRebuild(function(result) unsupportedResult = result end, {{ chunkSize = 1, delaySeconds = 0 }})
            drainTimers()
            assert(#resolverKeys == 0, "unsupported chunked raid reused a stale resolver dataset")
            assert(unsupportedResult.scanned == 1 and unsupportedResult.unresolved == 1, "unsupported counts")
            assert(activeKey == "karazhan", "unsupported chunked raid did not restore live dataset")

            raids = {{ {{ zone = "Naxxramas", loot = {{ {{ itemId = 39139 }} }} }} }}
            failResolution = true
            local failed = actions:StartLootSourceRebuild(nil, {{ chunkSize = 1, delaySeconds = 0 }})
            local ok, err = pcall(runNextTimer)
            assert(ok == false and string.find(tostring(err), "injected resolution failure", 1, true), tostring(err))
            assert(activeKey == "karazhan", "failed chunk did not restore live dataset")
            assert(failed:IsCancelled() == true, "failed chunk retained active rebuild ownership")
            assert(failed:Cancel() == false, "failed chunk cancellation was not stable")

            failResolution = false
            local callbackFailed = actions:StartLootSourceRebuild(function()
                error("injected completion failure")
            end, {{ chunkSize = 2, delaySeconds = 0 }})
            local callbackOk, callbackErr = pcall(drainTimers)
            assert(callbackOk == false and string.find(tostring(callbackErr), "injected completion failure", 1, true), tostring(callbackErr))
            assert(activeKey == "karazhan", "completion callback failure did not preserve live dataset")
            assert(callbackFailed:IsCancelled() == true and callbackFailed:Cancel() == false, "callback failure cleanup")

            failActivation = true
            local syncOk, syncErr = pcall(function() actions:RebuildLootSources() end)
            assert(syncOk == false and string.find(tostring(syncErr), "injected activation failure", 1, true), tostring(syncErr))
            assert(activeKey == "karazhan", "synchronous activation failure did not restore live dataset")
            """
        )
        subprocess.run(
            ["lua.cmd", "-e", " ".join(line.strip() for line in script.splitlines())],
            check=True,
            cwd=ROOT,
        )

    def test_loot_source_activation_skips_malformed_rows_transactionally(self):
        script = textwrap.dedent(
            f"""
            local addon = {{ LootSourceCandidates = {{
                GetModeSignature = function() return "" end,
            }} }}
            addon.LootSourcesData = {{ Raw = {{
                "not-a-raid",
                {{ name = "Naxxramas", sources = {{
                    "not-a-source",
                    {{ name = "Valid Boss", npcId = 15956, items = {{
                        "not-an-item",
                        {{ 39139, "not-modes" }},
                        {{ 39140, {{ normal10 = true, malformed = true, [7] = true }} }},
                    }} }},
                    {{ name = "Bad Items", npcId = 1, items = "not-items" }},
                }} }},
            }} }}
            assert(loadfile("{lua_path(LOOT_SOURCES_DATA)}"))("Raid Management Addon", addon)
            local data = addon.LootSourcesData
            assert(type(data._HasGeneratedRootsForTests) == "function")
            assert(data.ActivateInstance("Naxxramas") == true)
            assert(data.ByItemId[39139] ~= nil and data.ByItemId[39140] ~= nil)
            assert(data.ByInstance.naxxramas.normal[10][39140] ~= nil)

            local publishedItems, publishedInstances = data.ByItemId, data.ByInstance
            data.DeactivateInstance()
            local failureGeneration = data.GetGeneration()
            local originalSignature = addon.LootSourceCandidates.GetModeSignature
            addon.LootSourceCandidates.GetModeSignature = function() error("unexpected build failure") end
            local ok = pcall(function() data.ActivateInstance("Naxxramas") end)
            assert(ok == false)
            assert(data.GetActiveInstanceKey() == nil)
            assert(data.GetGeneration() == failureGeneration, "failed inactive build changed generation")
            assert(data.ByItemId == nil and data.ByInstance == nil, "partial generated roots leaked")
            assert(data._HasGeneratedRootsForTests() == false, "private partial generated roots leaked")
            assert(publishedItems ~= data.ByItemId and publishedInstances ~= data.ByInstance)
            addon.LootSourceCandidates.GetModeSignature = originalSignature
            assert(data.ActivateInstance("Naxxramas") == true)
            assert(data._HasGeneratedRootsForTests() == true)
            assert(#data.ByItemId[39139] == 1 and #data.ByItemId[39140] == 1, "retry retained partial candidates")
            """
        )
        subprocess.run(
            ["lua.cmd", "-e", " ".join(line.strip() for line in script.splitlines())],
            check=True,
            cwd=ROOT,
        )

    def test_init_owns_active_dataset_zone_lifecycle(self):
        source = INIT.read_text(encoding="utf-8")
        dataset_sources = (
            LOOT_SOURCES_DATA.read_text(encoding="utf-8"),
            IGNORED_MOBS.read_text(encoding="utf-8"),
        )

        self.assertIn('ZONE_CHANGED_NEW_AREA = "ZONE_CHANGED_NEW_AREA"', source)
        self.assertEqual(
            1,
            len(re.findall(r"local function refreshActiveInstanceDatasets\s*\(", source)),
        )

        coordinator = re.search(
            r"local function refreshActiveInstanceDatasets\s*\(\)(.*?)\n\s*end\n",
            source,
            re.DOTALL,
        )
        self.assertIsNotNone(coordinator)
        body = coordinator.group(1)
        self.assertEqual(1, body.count("GetInstanceInfo()"))
        self.assertIn('instanceType == "raid" and L.RaidZones[instanceName] ~= nil', body)
        self.assertIn("addon.LootSourcesData", body)
        self.assertIn("addon.IgnoredMobs", body)
        self.assertEqual(2, body.count("ActivateInstance(instanceName)"))
        self.assertEqual(2, body.count("DeactivateInstance()"))

        self.assertRegex(
            source,
            r"function addon:ZONE_CHANGED_NEW_AREA\(\)\s+handleRaidInstanceInfoChanged\(\)\s+end",
        )
        self.assertIn(
            "local instanceName, instanceType, instanceDiff = handleRaidInstanceInfoChanged(true)",
            source,
        )
        for event_name in (
            "PLAYER_ENTERING_WORLD",
            "PLAYER_DIFFICULTY_CHANGED",
            "UPDATE_INSTANCE_INFO",
        ):
            self.assertRegex(
                source,
                rf"function addon:{event_name}\([^)]*\)[\s\S]*?handleRaidInstanceInfoChanged\(\)",
            )

        for dataset_source in dataset_sources:
            self.assertNotIn("RegisterEvent", dataset_source)

    def test_production_ignored_mob_partition_and_lifecycle(self):
        self.assertEqual(
            ORIGINAL_IGNORED_MOB_IDS,
            {npc_id for npc_ids in EXPECTED_IGNORED_MOBS_BY_RAID.values() for npc_id in npc_ids},
        )
        script = textwrap.dedent(
            f"""
            local addon = {{ L = {{ StrTrashMobName = "Localized Trash" }} }}
            assert(loadfile("{lua_path(IGNORED_MOBS)}"))("Raid Management Addon", addon)
            local ignored = addon.IgnoredMobs
            local expected = {ignored_mob_mapping_lua()}

            local trashName = ignored.GetTrashMobName()
            assert(trashName == "Localized Trash")
            assert(ignored.IsTrashMobName(trashName) == true)
            assert(ignored.IsTrashMobName("not-trash") == false)

            local initialGeneration = ignored.GetGeneration()
            local invalidCases = {{ {{}}, {{ value = "" }}, {{ value = "   " }}, {{ value = "Unsupported Raid" }} }}
            for _, invalidCase in ipairs(invalidCases) do
                local activated, reason = ignored.ActivateInstance(invalidCase.value)
                assert(activated == false and reason == "unsupported-instance")
                assert(ignored.GetActiveInstanceKey() == nil)
                assert(ignored.Ids == nil)
                assert(ignored.GetGeneration() == initialGeneration)
            end

            for raidIndex, raid in ipairs(expected) do
                assert(ignored.ActivateInstance("  " .. string.upper(raid.name) .. "  ") == true)
                assert(ignored.GetActiveInstanceKey() == raid.key)
                for otherIndex, otherRaid in ipairs(expected) do
                    for _, npcId in ipairs(otherRaid.ids) do
                        assert(
                            ignored.Contains(npcId) == (raidIndex == otherIndex),
                            raid.name .. " partition mismatch for NPC " .. npcId
                        )
                    end
                end
            end

            assert(ignored.ActivateInstance("Naxxramas") == true)
            local sameIds = ignored.Ids
            local sameGeneration = ignored.GetGeneration()
            assert(ignored.ActivateInstance("  NAXXRAMAS  ") == true)
            assert(ignored.Ids == sameIds)
            assert(ignored.GetGeneration() == sameGeneration)

            assert(ignored.ActivateInstance("Ulduar") == true)
            assert(ignored.Ids ~= sameIds)
            assert(ignored.Contains(33329) == true and ignored.Contains(15929) == false)
            assert(ignored.GetGeneration() == sameGeneration + 1)
            assert(ignored.GetTrashMobName() == trashName and ignored.IsTrashMobName(trashName) == true)

            for _, invalidCase in ipairs(invalidCases) do
                assert(ignored.ActivateInstance("Ulduar") == true)
                local activeGeneration = ignored.GetGeneration()
                local activated, reason = ignored.ActivateInstance(invalidCase.value)
                assert(activated == false and reason == "unsupported-instance")
                assert(ignored.GetActiveInstanceKey() == nil and ignored.Ids == nil)
                assert(ignored.GetGeneration() == activeGeneration + 1)
            end

            assert(ignored.ActivateInstance("Karazhan") == true)
            assert(ignored.GetTrashMobName() == trashName and ignored.IsTrashMobName(trashName) == true)
            assert(ignored.DeactivateInstance() == true)
            assert(ignored.Ids == nil)
            assert(ignored.GetTrashMobName() == trashName and ignored.IsTrashMobName(trashName) == true)
            """
        )
        subprocess.run(
            ["lua.cmd", "-e", " ".join(line.strip() for line in script.splitlines())],
            check=True,
            cwd=ROOT,
        )

    def test_ignored_mob_partition_preserves_every_original_id(self):
        source = IGNORED_MOBS.read_text(encoding="utf-8")
        current_ids = {
            int(value)
            for value in re.findall(r"\[?(\d+)\]?\s*(?:=\s*true\s*,|,)\s*--", source)
        }
        self.assertEqual(ORIGINAL_IGNORED_MOB_IDS, current_ids)

    def test_instance_datasets_follow_the_active_raid_lifecycle(self):
        script = textwrap.dedent(
            f"""
            _G.GetAchievementLink = function() return nil end
            local addon = {{ Colors = {{}} }}

            assert(loadfile("{lua_path(STRINGS)}"))("Raid Management Addon", addon)
            assert(loadfile("{lua_path(LOOT_SOURCE_CANDIDATES)}"))("Raid Management Addon", addon)

            addon.LootSourcesData = {{ Raw = {{
                {{ name = "Naxxramas", sources = {{
                    {{ name = "Anub'Rekhan", npcId = 15956, items = {{ {{ 39139, {{ normal10 = true }} }} }} }},
                }} }},
                {{ name = "Ulduar", sources = {{
                    {{ name = "Flame Leviathan", npcId = 33113, items = {{ {{ 45282, {{ normal10 = true }} }} }} }},
                }} }},
            }} }}

            assert(loadfile("{lua_path(LOOT_SOURCES_DATA)}"))("Raid Management Addon", addon)
            assert(loadfile("{lua_path(LOOT_SOURCES)}"))("Raid Management Addon", addon)
            assert(loadfile("{lua_path(IGNORED_MOBS)}"))("Raid Management Addon", addon)

            local data = addon.LootSourcesData
            local ignored = addon.IgnoredMobs
            assert(type(data.ActivateInstance) == "function", "LootSourcesData.ActivateInstance is missing")
            assert(type(data.DeactivateInstance) == "function", "LootSourcesData.DeactivateInstance is missing")
            assert(type(data.GetActiveInstanceKey) == "function", "LootSourcesData.GetActiveInstanceKey is missing")
            assert(type(data.GetGeneration) == "function", "LootSourcesData.GetGeneration is missing")
            assert(type(ignored.ActivateInstance) == "function", "IgnoredMobs.ActivateInstance is missing")
            assert(type(ignored.DeactivateInstance) == "function", "IgnoredMobs.DeactivateInstance is missing")
            assert(type(ignored.GetActiveInstanceKey) == "function", "IgnoredMobs.GetActiveInstanceKey is missing")
            assert(type(ignored.GetGeneration) == "function", "IgnoredMobs.GetGeneration is missing")
            assert(type(ignored._SetRawForTests) == "function", "IgnoredMobs._SetRawForTests is missing")

            assert(data.GetActiveInstanceKey() == nil, "loot sources must start inactive")
            assert(data.ByItemId == nil, "loot sources must not allocate item entries at startup")
            assert(data.ByInstance == nil, "loot sources must not allocate instance entries at startup")

            local initialGeneration = data.GetGeneration()
            for _, invalidCase in ipairs({{ {{}}, {{ value = "" }}, {{ value = "   " }} }}) do
                local activated, reason = data.ActivateInstance(invalidCase.value)
                assert(activated == false and reason == "unsupported-instance")
                assert(data.GetActiveInstanceKey() == nil)
                assert(data.ByItemId == nil and data.ByInstance == nil)
                assert(data.GetGeneration() == initialGeneration)
            end
            assert(data.ActivateInstance("Naxxramas") == true)
            assert(data.GetActiveInstanceKey() == "naxxramas")
            assert(data.ByItemId[39139] ~= nil, "Naxxramas item was not activated")
            assert(data.ByItemId[45282] == nil, "Ulduar item leaked into Naxxramas")
            local naxxGeneration = data.GetGeneration()
            assert(naxxGeneration == initialGeneration + 1, "activation must increment generation")
            assert(data.ActivateInstance("Naxxramas") == true)
            assert(data.GetGeneration() == naxxGeneration, "repeat activation must preserve generation")

            local naxxByItemId = data.ByItemId
            local naxxByInstance = data.ByInstance
            assert(data.DeactivateInstance() == true)
            assert(data.GetGeneration() == naxxGeneration + 1, "deactivation must increment generation")
            assert(data.GetActiveInstanceKey() == nil)
            assert(data.ByItemId ~= naxxByItemId, "deactivation must remove the active ByItemId reference")
            assert(data.ByInstance ~= naxxByInstance, "deactivation must remove the active ByInstance reference")
            assert(data.ByItemId == nil)
            assert(data.ByInstance == nil)

            assert(data.ActivateInstance("Naxxramas") == true)
            local invalidActiveGeneration = data.GetGeneration()
            for _, invalidCase in ipairs({{ {{}}, {{ value = "" }}, {{ value = "   " }} }}) do
                local activated, reason = data.ActivateInstance(invalidCase.value)
                assert(activated == false and reason == "unsupported-instance")
                assert(data.GetActiveInstanceKey() == nil)
                assert(data.ByItemId == nil and data.ByInstance == nil)
                assert(data.GetGeneration() == invalidActiveGeneration + 1)
                invalidActiveGeneration = data.GetGeneration()
                assert(data.ActivateInstance("Naxxramas") == true)
                invalidActiveGeneration = data.GetGeneration()
            end
            assert(data.DeactivateInstance() == true)

            local unsupportedGeneration = data.GetGeneration()
            local activated, reason = data.ActivateInstance("Icecrown Citadel")
            assert(activated == false and reason == "unsupported-instance")
            assert(data.GetActiveInstanceKey() == nil)
            assert(data.GetGeneration() == unsupportedGeneration)

            assert(ignored.ActivateInstance("The Eye") == true)
            assert(ignored.Contains(20064) == true and ignored.Contains(21875) == false)
            assert(ignored.DeactivateInstance() == true)

            ignored._SetRawForTests({{ naxxramas = {{ 15929 }}, ulduar = {{ 33329 }} }})
            assert(ignored.GetActiveInstanceKey() == nil)
            assert(ignored.Ids == nil)
            assert(ignored.Contains(15929) == false and ignored.Contains(33329) == false)
            local ignoredGeneration = ignored.GetGeneration()
            assert(ignored.ActivateInstance("Naxxramas") == true)
            assert(ignored.GetActiveInstanceKey() == "naxxramas")
            assert(ignored.GetGeneration() == ignoredGeneration + 1)
            assert(ignored.Contains(15929) == true and ignored.Contains(33329) == false)
            local ignoredNaxxGeneration = ignored.GetGeneration()
            assert(ignored.ActivateInstance("Naxxramas") == true)
            assert(ignored.GetGeneration() == ignoredNaxxGeneration)
            assert(ignored.ActivateInstance("Ulduar") == true)
            assert(ignored.GetActiveInstanceKey() == "ulduar")
            assert(ignored.GetGeneration() == ignoredNaxxGeneration + 1)
            assert(ignored.Contains(15929) == false and ignored.Contains(33329) == true)
            assert(ignored.DeactivateInstance() == true)
            assert(ignored.GetActiveInstanceKey() == nil)
            assert(ignored.GetGeneration() == ignoredNaxxGeneration + 2)
            assert(ignored.Ids == nil, "ignored-mob deactivation must release Ids")

            assert(data.ActivateInstance("Naxxramas") == true)
            local resolved = addon.LootSources.FindSource(
                39139,
                {{ raid = "Naxxramas", raidSize = 10, difficulty = 3 }}
            )
            assert(resolved.npcId == 15956)
            assert(data.DeactivateInstance() == true)
            local missing = addon.LootSources.FindSource(
                39139,
                {{ raid = "Naxxramas", raidSize = 10, difficulty = 3 }}
            )
            assert(missing.reason == "missing", "deactivation must invalidate cached resolver results")
            assert(data.ActivateInstance("Ulduar") == true)
            local stale = addon.LootSources.FindSource(
                39139,
                {{ raid = "Naxxramas", raidSize = 10, difficulty = 3 }}
            )
            assert(stale.reason == "missing", "new activation must not return a cached Naxxramas result")
            """
        )
        subprocess.run(
            ["lua.cmd", "-e", " ".join(line.strip() for line in script.splitlines())],
            check=True,
            cwd=ROOT,
        )


if __name__ == "__main__":
    unittest.main()
