-- The client variant's entry for api.stratagems.define and minimum Obsidian API version.
local M = {}

M.NAME = "shared_resupply"
M.BASE = "stratagem_resupply"
M.TITLE = "Resupply"
M.DESCRIPTION = "Drops four ammunition boxes. Cooldown is individual to this player."
M.CODE = { "down", "down", "up", "right" }
M.ICON = "shared_resupply_icon"
M.ICON_MATERIAL = "shared_resupply/icons"

-- api.stratagems.carry came with Obsidian API 1.40.0.
M.API = { 1, 40, 0 }
M.API_TEXT = "1.40.0"

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

M.CALL_IN = 10

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
