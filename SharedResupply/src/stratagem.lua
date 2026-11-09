-- The Shared Resupply stratagem's entry for api.stratagems.define, and the Obsidian API version this
-- mod needs.
local M = {}

M.NAME = "shared_resupply"
M.BASE = "stratagem_resupply"
M.TITLE = "Resupply"
M.DESCRIPTION = "Drops four ammunition boxes. The cooldown is shared by the whole squad."
-- The standard Resupply's code. When both are in a player's list, the one the player holds and can call
-- wins (Obsidian API), and with the option on the standard one moves to a free code (src/vanilla.lua).
M.CODE = { "down", "down", "up", "right" }
-- The mod's own icon, in a material this mod puts in the boot bundle (tools/build_icon.py).
M.ICON = "shared_resupply_icon"
M.ICON_MATERIAL = "shared_resupply/icons"

-- api.stratagems.carry, share_cooldown and the code a held stratagem wins came with 1.40.0.
M.API = { 1, 40, 0 }
M.API_TEXT = "1.40.0"

-- Whether an Obsidian API of this version ("1.40.0") has what the mod needs.
function M.api_ok(version)
	local got = {}
	for n in tostring(version or ""):gmatch("%d+") do got[#got + 1] = tonumber(n) end
	if #got == 0 then return false end
	for i, want in ipairs(M.API) do
		local v = got[i] or 0
		if v ~= want then return v > want end
	end
	return true
end

-- The call-in, the same for everyone: between the standard Resupply's Mk1 (15 s) and Mk3 (5 s).
M.CALL_IN = 10

-- Yellow, in no menu: every player carries it, so nobody unlocks it, picks it or buys a level of it, and
-- it has no levels at all.
function M.def()
	return {
		name = M.NAME,
		base = M.BASE,
		title = M.TITLE,
		description = M.DESCRIPTION,
		code = { M.CODE[1], M.CODE[2], M.CODE[3], M.CODE[4] },
		icon = M.ICON,
		icon_material = M.ICON_MATERIAL,
		type = "special",
		unlock = "manual",
		stats = { activation_time = M.CALL_IN },
		upgrades = {},
	}
end

return M
