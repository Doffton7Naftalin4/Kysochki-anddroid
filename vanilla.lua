-- The standard Resupply: taken out of the game unless the option keeps it, and then moved to a code no
-- other stratagem has, so the Shared Resupply keeps the standard code to itself.
local M = {}

M.NAME = "stratagem_resupply"
M.OPTION = "preserve_vanilla_resupply"
M.ARROWS = { "up", "down", "left", "right" }

-- The option, through obsidian.settings (or a stand-in with get). Off when it can't be read.
function M.preserve(settings)
	if type(settings) ~= "table" or type(settings.get) ~= "function" then return false end
	local ok, v = pcall(settings.get, M.OPTION)
	return ok and v == true
end

-- Whether two codes get in each other's way: the game calls a stratagem as soon as the arrows match a
-- whole code, so one code that starts another hides the longer one.
function M.collides(a, b)
	local n = math.min(#a, #b)
	for i = 1, n do
		if a[i] ~= b[i] then return false end
	end
	return true
end

-- Every code in the game's list but the named stratagem's own.
function M.codes(list, except)
	local out = {}
	for _, e in ipairs(type(list) == "table" and list or {}) do
		if type(e) == "table" and e.name ~= except and type(e.combo) == "table" and #e.combo > 0 then out[#out + 1] = e.combo end
	end
	return out
end

local function free(code, taken)
	for _, other in ipairs(taken) do
		if M.collides(code, other) then return false end
	end
	return true
end

-- A code as long as `original` that collides with none of `taken`: of those, the one sharing the longest
-- start with the original, then the fewest arrows changed. The same length, as the code is changed arrow
-- by arrow. nil when every code of that length is in the way.
function M.free_code(taken, original)
	local n = #original
	local best, best_prefix, best_changed
	local code = {}
	local function walk(i)
		if i > n then
			if free(code, taken) then
				local prefix, changed = 0, 0
				for k = 1, n do
					if code[k] ~= original[k] then changed = changed + 1 end
				end
				while prefix < n and code[prefix + 1] == original[prefix + 1] do prefix = prefix + 1 end
				if not best or prefix > best_prefix or (prefix == best_prefix and changed < best_changed) then
					best, best_prefix, best_changed = { unpack(code, 1, n) }, prefix, changed
				end
			end
			return
		end
		for _, arrow in ipairs(M.ARROWS) do
			code[i] = arrow
			walk(i + 1)
		end
	end
	if n == 0 or n > 8 then return nil end
	walk(1)
	return best
end

-- Moves the standard Resupply to a free code through api.stratagems.edit, one arrow at a time, so the
-- API takes it back when the session stops being cleared. Answers the arrows it changed ({ index, ... })
-- or nil and why.
function M.move_code(api, list)
	local entry = api.catalog.stratagem(M.NAME)
	if not entry or type(entry.combo) ~= "table" then return nil, "not_ready" end
	local code = M.free_code(M.codes(list, M.NAME), entry.combo)
	if not code then return nil, "no_free_code" end
	local changed = {}
	for i, arrow in ipairs(code) do
		if entry.combo[i] ~= arrow then
			local ok, why = api.stratagems.edit(M.NAME, "combo." .. i, arrow)
			if not ok then
				M.restore_code(api, changed)
				return nil, why
			end
			changed[#changed + 1] = i
		end
	end
	return changed
end

-- Puts back the arrows move_code changed.
function M.restore_code(api, changed)
	local entry = api.catalog.stratagem(M.NAME)
	if not entry then return end
	for _, i in ipairs(changed or {}) do api.edits.revert_table(entry, "combo." .. i) end
end

return M
