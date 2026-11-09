-- What the mod asks of Obsidian API while it runs: every player carries the Shared Resupply, the whole
-- squad waits out one cooldown for it, and the standard Resupply is hidden, or with the option on, moved
-- to a free code. Applied once the game has the stratagem list, taken back when the mod stops (a lobby
-- that isn't cleared, or a player without the mod), and applied again when the option changes.
local stratagem = obsidian.module("src/stratagem")
local vanilla = obsidian.module("src/vanilla")

local M = {}

-- deps: preserve() answers the option, loadout() the game's LoadoutSettings, log(text).
function M.new(api, deps)
	local c = { api = api, deps = deps, applied = nil, logged = {} }

	local function log_once(key, text)
		if c.logged[key] then return end
		c.logged[key] = true
		if deps.log then deps.log(text) end
	end

	-- true once everything is in place; false to try again on a later frame.
	function c:apply(preserve)
		local s = api.stratagems
		local ok, why = s.carry(stratagem.NAME)
		if not ok then
			if why ~= "not_available" and why ~= "not_cleared" then log_once("carry", "Shared Resupply not carried: " .. tostring(why)) end
			return false
		end
		ok, why = s.share_cooldown(stratagem.NAME)
		if not ok then return false end
		local done = { preserve = preserve }
		if preserve then
			local loadout = deps.loadout and deps.loadout()
			local changed
			changed, why = vanilla.move_code(api, loadout and loadout.stratagems)
			if changed then
				done.code = changed
			elseif why == "not_ready" then
				return false
			else
				-- The held stratagem still wins the code; only when both are ready does the standard one.
				log_once("code", "Standard Resupply keeps the shared code: " .. tostring(why))
			end
		else
			ok, why = s.hide(vanilla.NAME)
			if not ok then
				if why ~= "not_available" and why ~= "not_cleared" then log_once("hide", "Standard Resupply not hidden: " .. tostring(why)) end
				return false
			end
			done.hidden = true
		end
		c.applied = done
		return true
	end

	function c:undo()
		local done = c.applied
		c.applied = nil
		local s = api.stratagems
		s.uncarry(stratagem.NAME)
		s.unshare_cooldown(stratagem.NAME)
		if done and done.hidden then s.unhide(vanilla.NAME) end
		if done and done.code then vanilla.restore_code(api, done.code) end
	end

	-- Each frame the mod runs: in place, and in step with the option.
	function c:frame()
		local preserve = deps.preserve() == true
		if c.applied and c.applied.preserve ~= preserve then c:undo() end
		if not c.applied then c:apply(preserve) end
		return false
	end

	return c
end

return M
