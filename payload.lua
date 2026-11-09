-- Four ammunition boxes in the Shared Resupply's crate. The game's ammunition crate
-- (gameobjects/supplycrate_ammunition) lists two boxes in supply_crate_info.content, and
-- SupplyCrateComponent.setup_master spawns them, on the machine of whoever threw the flare only: the
-- hellpod and the crate belong to that machine, and every other machine gets the boxes as the game's own
-- replicated pickups. For a crate of this stratagem the list holds four while the game reads it, then goes
-- back. Should the game read another copy of the list, the two missing boxes are spawned after.
local M = {}

M.BOX = "gameobjects/pickup_ammunitionbox_01"
M.COUNT = 4
-- Two by two, on the spacing of the game's own two (0.5 m, 0.25 m up).
M.GRID = {
	{ 0.25, 0.25, 0.25 }, { 0.25, -0.25, 0.25 },
	{ -0.25, 0.25, 0.25 }, { -0.25, -0.25, 0.25 },
}
-- Beside the game's two, when only those were spawned.
M.EXTRA = { { 0.5, 0, 0.25 }, { -0.5, 0, 0.25 } }

-- The game, swapped in the tests.
M.engine = {
	settings = function(unit, upgrade)
		local s = rawget(_G, "LoadoutSettings")
		return s and s.get_upgraded_settings(unit, upgrade)
	end,
	at = function(unit, offset)
		return rawget(_G, "Unit").world_position(unit, 0) + rawget(_G, "Vector3")(offset[1], offset[2], offset[3])
	end,
	turn = function(angle)
		return rawget(_G, "Quaternion").axis_angle(rawget(_G, "Vector3").up(), angle)
	end,
}

-- Whether a crate's setup info comes from this stratagem: the hellpod hands on the stratagem's entry.
function M.ours(init, name)
	return type(init) == "table" and type(init.stratagem_info) == "table" and init.stratagem_info.name == name
end

-- The four boxes, in the game's form, from the game's list (for the unit path).
function M.content(old)
	local path = type(old) == "table" and type(old[1]) == "table" and old[1].unit_path or M.BOX
	local out = {}
	for i, offset in ipairs(M.GRID) do
		out[i] = { unit_path = path, spawn_offset = { offset[1], offset[2], offset[3] }, spawn_rotation = 0 }
	end
	return out
end

local function crate_info(unit, init)
	local ok, settings = pcall(M.engine.settings, unit, init.upgrade_value)
	local info = ok and type(settings) == "table" and settings.supply_crate_info
	return type(info) == "table" and type(info.content) == "table" and info or nil
end

-- The boxes the game didn't spawn, beside the ones it did.
local function top_up(self, unit, ctx, init, path)
	local state = type(ctx) == "table" and ctx.state
	if type(state) ~= "table" or state.was_migrated or type(state.content_units) ~= "table" then return end
	local units = state.content_units
	local extra = 1
	while #units < M.COUNT and M.EXTRA[extra] do
		init.use_rotation, init.hide_time = true, state.open_timer
		units[#units + 1] = self.entity_spawner:spawn_entity(path, M.engine.at(unit, M.EXTRA[extra]), M.engine.turn(0), nil, init)
		extra = extra + 1
	end
end

-- SupplyCrateComponent.setup_master(self, unit, ctx, init) for every crate; name: this stratagem's.
function M.setup_master(name, original, self, unit, ctx, init, ...)
	if not M.ours(init, name) then return original(self, unit, ctx, init, ...) end
	local info = crate_info(unit, init)
	local old = info and info.content
	if info then info.content = M.content(old) end
	local ok, err = pcall(original, self, unit, ctx, init, ...)
	if info then info.content = old end
	if not ok then error(err, 0) end
	local path = type(old) == "table" and type(old[1]) == "table" and old[1].unit_path or M.BOX
	top_up(self, unit, ctx, init, path)
end

return M
