local suiteFiles = {
	"tests/lua/harness/00_support.lua",
	"tests/lua/harness/10_loot_distribution.lua",
	"tests/lua/harness/20_raid_database.lua",
	"tests/lua/harness/30_raid_runtime.lua",
	"tests/lua/harness/40_inspect_foundations.lua",
	"tests/lua/harness/50_reserves_messaging.lua",
	"tests/lua/harness/60_loot_ui.lua",
	"tests/lua/harness/70_raid_sync.lua",
	"tests/lua/harness/90_dispatch.lua",
}

local sources = {}
for i = 1, #suiteFiles do
	local path = suiteFiles[i]
	local file, openError = io.open(path, "rb")
	if not file then
		error("cannot load Lua behavior suite " .. path .. ": " .. tostring(openError), 0)
	end
	sources[i] = file:read("*a")
	file:close()
end

local chunk, loadError = loadstring(table.concat(sources, "\n"), "@tests/lua/runtime_harness.lua")
if not chunk then
	error(loadError, 0)
end

return chunk()
