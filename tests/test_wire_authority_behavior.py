import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
CAPABILITIES = ADDON / "Services" / "Raid" / "Capabilities.lua"
DISTRIBUTION = ADDON / "Services" / "Loot" / "DistributionSession.lua"
RESERVES_SYNC = ADDON / "Services" / "Reserves" / "Sync.lua"


def run_lua(script):
    with tempfile.NamedTemporaryFile(mode="w", suffix=".lua", encoding="utf-8", delete=False) as handle:
        handle.write(script)
        script_path = Path(handle.name)
    try:
        subprocess.run(["lua.cmd", str(script_path)], check=True, cwd=ROOT)
    finally:
        script_path.unlink(missing_ok=True)


class WireAuthorityBehaviorTests(unittest.TestCase):
    def test_raid_owner_resolves_group_membership_and_loot_authority(self):
        run_lua(textwrap.dedent(f"""
            local lootMethod, partyMaster, raidMaster = "master", nil, 2
            _G.GetLootMethod = function() return lootMethod, partyMaster, raidMaster end
            _G.UnitIsUnit = function(left, right) return left == right end
            local addon = {{
                Database = {{
                    GetUnitRank = function(unit)
                        return unit == "raid3" and 1 or 0
                    end,
                }},
                L = {{}},
                Services = {{ EnsureNamespace = function() end, Raid = {{
                    IsPlayerInRaid = function() return true end,
                    GetUnitID = function(_, name)
                        if name == "Alice" then return "raid2" end
                        if name == "Bob" then return "raid3" end
                        if name == "Charlie" then return "party1" end
                        if name == "Local" then return "player" end
                        return "none"
                    end,
                }}}},
            }}
            assert(loadfile([[{CAPABILITIES.as_posix()}]]))("RMA", addon)
            local raid = addon.Services.Raid
            assert(raid:IsGroupMember("Alice") == true)
            assert(raid:IsGroupMember("Outsider") == false)
            assert(raid:IsLootAuthority("Alice") == true)
            assert(raid:IsLootAuthority("Bob") == false)
            assert(raid:IsReservesAuthority("Alice") == true)
            assert(raid:IsReservesAuthority("Bob") == true)
            assert(raid:IsReservesAuthority("Outsider") == false)
            partyMaster, raidMaster = 1, nil
            assert(raid:IsLootAuthority("Charlie") == true)
            partyMaster = 0
            assert(raid:IsLootAuthority("Local") == true)
        """))

    def test_distribution_rejects_clear_from_non_loot_authority(self):
        run_lua(textwrap.dedent(f"""
            _G.GetTime = function() return 10 end
            local authority = false
            local addon = {{
                Bus = {{ TriggerEvent = function() end }},
                Comms = {{
                    Payload = {{
                        DecodeText = function(value) return value end,
                        EncodeText = function(value) return value or "" end,
                        PackFields = function(sep, ...)
                            local values = {{...}}
                            for i = 1, #values do values[i] = tostring(values[i]) end
                            return table.concat(values, sep)
                        end,
                        SplitFields = function(text, sep, out)
                            for key in pairs(out) do out[key] = nil end
                            for value in string.gmatch(text, "([^" .. sep .. "]+)") do
                                out[#out + 1] = value
                            end
                            return out
                        end,
                    }},
                    QueueAddonMessage = function() return true end,
                    RegisterPrefixIfAvailable = function() end,
                    Sync = function() return true end,
                }},
                Database = {{ GetPlayerName = function() return "Local" end }},
                Diag = {{}},
                Events = {{ Internal = {{ LootDistributionSessionChanged = "changed" }} }},
                Item = {{ GetItemKey = function(value) return value end }},
                Services = {{ Raid = {{
                    CanUseCapability = function() return true end,
                    IsGroupMember = function() return true end,
                    IsLootAuthority = function() return authority end,
                }}}},
                Strings = {{ NormalizeText = function(value)
                    if value == nil or value == "" then return nil end
                    return tostring(value)
                end }},
            }}
            addon.Services.EnsureNamespace = function(name)
                addon.Services[name] = addon.Services[name] or {{}}
            end
            assert(loadfile([[{DISTRIBUTION.as_posix()}]]))("RMA", addon)
            local owner = addon.Services.Loot.DistributionSession
            assert(owner._state.sessionId == nil)
            assert(owner.HandleMessage("RMADist", "CLEAR|2|foreign", "RAID", "Outsider") == true)
            assert(owner._state.sessionId == nil)
            authority = true
            assert(owner.HandleMessage("RMADist", "CLEAR|2|trusted", "RAID", "Alice") == true)
            assert(owner._state.sessionId == "trusted")
            owner._state.ownerKey = "Alice|trusted"
            owner._state.revision = 1
            owner._streams["Alice|trusted"] = {{ committedRevision = 1 }}
            authority = false
            assert(owner.HandleMessage("RMADist", "SESSION_END|2|trusted|2", "RAID", "Alice") == true)
            assert(owner._trustedAuthority == "Alice")
            assert(owner.HandleMessage("RMADist", "SESSION_END|2|trusted|1", "RAID", "Alice") == true)
            assert(owner._state.ownerKey == nil)
            assert(owner._trustedAuthority == nil)
        """))

    def test_reserves_sync_does_not_serve_non_group_sender(self):
        run_lua(textwrap.dedent(f"""
            _G.GetTime = function() return 10 end
            _G.UnitName = function() return "Local" end
            local sent = 0
            local groupMember = false
            local providerAuthority = false
            local addon = {{
                Comms = {{
                    NextRequestId = function() return "1" end,
                    NormalizeSender = function(sender)
                        return string.match(sender or "", "^([^%-]+)")
                    end,
                    Payload = {{
                        PackFields = function(sep, ...) return table.concat({{...}}, sep) end,
                        SplitFields = function(text, sep, out)
                            for key in pairs(out) do out[key] = nil end
                            for value in string.gmatch(text, "([^" .. sep .. "]+)") do
                                out[#out + 1] = value
                            end
                            return out
                        end,
                    }},
                    RegisterPrefixIfAvailable = function() end,
                    SendAddonWhisper = function() sent = sent + 1 return true end,
                    Sync = function() return true end,
                }},
                Database = {{}},
                L = {{
                    MsgReservesSyncDataRequested = "requested",
                    MsgReservesSyncMeta = "%s %s %s %s %s",
                }},
                Services = {{
                    EnsureNamespace = function() end,
                    Raid = {{
                        GetPlayerRoleState = function() return {{ isMasterLooter = true }} end,
                        IsGroupMember = function(_, sender)
                            return groupMember and sender == "Alice"
                        end,
                        IsReservesAuthority = function() return providerAuthority end,
                    }},
                    Reserves = {{
                        _Sync = {{ GetPayload = function()
                            return "payload", {{ checksum = "sum", mode = "multi" }}
                        end }},
                        IsLocalDataAvailable = function() return true end,
                        GetSyncMetadata = function() return {{ checksum = "sum" }} end,
                    }},
                }},
                Strings = {{ NormalizeLower = function(value) return value end }},
                info = function() end,
                warn = function() end,
            }}
            assert(loadfile([[{RESERVES_SYNC.as_posix()}]]))("RMA", addon)
            local sync = addon.Services.Reserves._Sync
            groupMember = true
            assert(sync:HandleMessage("RMAResSync", "META_REQ|1", "WHISPER", "Alice-OtherRealm") == true)
            assert(sent == 0)
            assert(sync:HandleMessage("RMAResSync", "META_REQ|2", "RAID", "Alice") == true)
            assert(sent == 1)
            assert(sync:HandleMessage("RMAResSync", "META_ACK|3|remote|multi|1|1|Alice|C1", "RAID", "Alice") == true)
            assert(sent == 1)
        """))


if __name__ == "__main__":
    unittest.main()
