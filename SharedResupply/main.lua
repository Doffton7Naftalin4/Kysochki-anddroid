-- Shared Resupply client variant: a locally carried Resupply stratagem.
local stratagem = obsidian.module("src/stratagem")
local vanilla = obsidian.module("src/vanilla")
local payload = obsidian.module("src/payload")
local squad = obsidian.module("src/squad")

local api = obsidian.import("obsidian.api")
local api_info = obsidian.info and obsidian.info("obsidian.api")

-- carry came with Obsidian API 1.40.0. With an older one the mod adds nothing.
if not stratagem.api_ok(api_info and api_info.version) then
	obsidian.log("Shared Resupply Client needs Obsidian API " .. stratagem.API_TEXT .. " or later, found " .. tostring(api_info and api_info.version))
	return
end

-- Add the local stratagem before the save's loadout is read.
local function define()
	local made, why = api.stratagems.define(stratagem.def())
	if why == "not_ready" then return false end
	if not made and why ~= "taken" then obsidian.log("Shared Resupply Client not added: " .. tostring(why)) end
	return true
end
if not define() then obsidian.on_frame(define) end

local setup = squad.new(api, {
	preserve = function() return vanilla.preserve(obsidian.settings) end,
	loadout = function() return api.game.global("LoadoutSettings") end,
	log = obsidian.log,
})
setup:frame()
obsidian.on_frame(function() setup:frame() end)
obsidian.on_session(function(on)
	if not on then setup:undo() end
end)

-- Four boxes in the crate on the machine of the player who threw the flare.
obsidian.hook("SupplyCrateComponent", "setup_master", function(original, ...)
	return payload.setup_master(stratagem.NAME, original, ...)
end)

obsidian.log("Shared Resupply Client ready")
