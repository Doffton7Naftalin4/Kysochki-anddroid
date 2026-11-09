-- Shared Resupply: a squad-wide Resupply stratagem on a shared cooldown.
local stratagem = obsidian.module("src/stratagem")
local vanilla = obsidian.module("src/vanilla")
local payload = obsidian.module("src/payload")
local squad = obsidian.module("src/squad")

local api = obsidian.import("obsidian.api")
local api_info = obsidian.info and obsidian.info("obsidian.api")

-- carry and share_cooldown came with Obsidian API 1.40.0. With an older one the mod adds nothing, so the
-- game stays as it is.
if not stratagem.api_ok(api_info and api_info.version) then
	obsidian.log("Shared Resupply needs Obsidian API " .. stratagem.API_TEXT .. " or later, found " .. tostring(api_info and api_info.version))
	return
end

-- In the main chunk, before the save's loadout is read: the API keeps the def until the game has the
-- stratagem list. not_ready came from APIs before that; the frame calls try again until true stops them.
local function define()
	local made, why = api.stratagems.define(stratagem.def())
	if why == "not_ready" then return false end
	if not made and why ~= "taken" then obsidian.log("Shared Resupply not added: " .. tostring(why)) end
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
-- Frames stop while the mod is off (a lobby that isn't cleared, or a player without the mod), so the
-- changes come off now and go back on the first frame after.
obsidian.on_session(function(on)
	if not on then setup:undo() end
end)

-- Four boxes in the crate, on the thrower's machine, where the game spawns the crate's boxes.
obsidian.hook("SupplyCrateComponent", "setup_master", function(original, ...)
	return payload.setup_master(stratagem.NAME, original, ...)
end)

obsidian.log("Shared Resupply ready")
