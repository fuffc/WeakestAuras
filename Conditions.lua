-- WeakestAuras -- conditions: trigger-state-driven display overrides ("if
-- trigger state says X, change display property Y"). Mirrors WA2's Conditions
-- (§10), with one deliberate divergence:
-- upstream compiles the whole list to one loadstring'd function per aura; we
-- *interpret* the same descriptor data. At tens of auras the interpreter is
-- plenty fast, and with no offline Lua a generated-code bug would be an in-game
-- string-assembly hunt -- an interpreter's stack traces point at real lines.
-- The descriptor format and the three-phase algorithm are upstream's exactly,
-- so a compiler can replace the interpreter later without touching saved data.
-- Upstream section refs (§N) point at design/architecture/weakauras2-reference.md
--
-- The data (per condition): { check = { trigger, variable, op, value, checks },
-- changes = { { property, value }, ... } }. trigger -1 = a global condition,
-- -2 = an AND/OR combinator over check.checks. Everything meets the rest of the
-- engine at region.states (what to read) and the region/subregion property
-- setters (what to write) -- the same setters config-apply already calls.

if WeakestAuras.disabled then return end

local WA = WeakestAuras

-- compiled[uid] = { data, properties (WA.GetProperties map), templates
-- ([triggernum] = condition-variable map) }. Rebuilt on every WA.Add via
-- WA.LoadConditions; keyed by uid (stable across rename) so a rename needs no
-- fixup here.
local compiled = {}
-- activated[uid][cloneId][i] = was condition i active on the previous run --
-- drives deactivation restore (a condition that turned off restores its
-- properties' saved base values) and, later, edge-triggered actions.
local activated = {}
-- scheduled[uid.."\0"..cloneId] = the one pending exact-recheck C_Timer for a
-- timer/elapsedTimer check crossing its threshold (§10 ScheduleConditionCheck).
local scheduled = {}

-- ---------------------------------------------------------------------------
-- Global conditions (trigger == -1): a shared pseudo-state re-checked on the
-- events below. All three APIs exist on 1.12.
-- ---------------------------------------------------------------------------

WA.globalConditions = {
	incombat = { display = "In Combat", type = "bool",
		get = function() return UnitAffectingCombat("player") and true or false end },
	hastarget = { display = "Has Target", type = "bool",
		get = function() return UnitExists("target") and true or false end },
	attackabletarget = { display = "Target Attackable", type = "bool",
		get = function() return (UnitExists("target") and UnitCanAttack("player", "target")) and true or false end },
}
local GLOBAL_EVENTS = { "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED", "PLAYER_TARGET_CHANGED" }

-- ---------------------------------------------------------------------------
-- Vocabulary: changeable properties + checkable variables
-- ---------------------------------------------------------------------------

-- The overridable properties for a display: the region type's own registry
-- (already carrying the AddProperties universals) plus each subtext's, keyed
-- sub.<n>.<key>. Normalized into one flat shape so the apply/base code and the
-- editor both read the same entries (§10 Private.GetProperties).
function WA.GetProperties(data)
	local out = {}
	local rt = WA.regionTypes[data.regionType]
	if rt and rt.properties then
		for key, spec in pairs(rt.properties) do
			out[key] = { display = spec.display or key, setter = spec.setter, action = spec.action, type = spec.type,
				min = spec.min, max = spec.max, softMax = spec.softMax, step = spec.step, values = spec.values,
				base = spec.base, baseIndex = spec.baseIndex, dataKey = spec.dataKey or key }
		end
	end
	local subs = data.subRegions or {}
	local perType = {}
	for i = 1, table.getn(subs) do
		local sspec = WA.subRegionTypes[subs[i].type]
		perType[subs[i].type] = (perType[subs[i].type] or 0) + 1
		if sspec and sspec.properties then
			-- Same label the Display Effects list gives the block this targets, so
			-- the two pages name one element the same way -- which means counting
			-- per type here too, not by list position. The position is still what
			-- the key `sub.<i>.<key>` addresses it by.
			local label = (sspec.displayName or subs[i].type) .. " " .. perType[subs[i].type] .. " "
			for key, pspec in pairs(sspec.properties) do
				out["sub." .. i .. "." .. key] = { display = label .. (pspec.display or key),
					setter = pspec.setter, action = pspec.action, type = pspec.type, min = pspec.min, max = pspec.max,
					softMax = pspec.softMax, step = pspec.step, values = pspec.values, base = pspec.base, baseIndex = pspec.baseIndex,
					isSub = true, subIndex = i, subKey = pspec.dataKey or key }
			end
		end
	end
	return out
end

-- The checkable variable templates per trigger (§10): each trigger system's
-- GetTriggerConditions. [triggernum] = { variable = { display, type, values } }.
function WA.GetConditionTemplates(data)
	local out = {}
	-- A group carries no triggers at all (MergeDefaults clears them), and its
	-- options window still reaches here for the conditions tab.
	for triggernum = 1, table.getn(data.triggers or {}) do
		local system = WA.GetTriggerSystem(data, triggernum)
		if system and system.GetTriggerConditions then
			out[triggernum] = system.GetTriggerConditions(data, triggernum) or {}
		else
			out[triggernum] = {}
		end
	end
	return out
end

-- ---------------------------------------------------------------------------
-- Property read/write (the same setters config-apply uses, §6/§10)
-- ---------------------------------------------------------------------------

-- The saved base value a deactivated condition restores -- the config is the
-- source of truth, never a snapshot of live widget state (§10 GetBaseProperty).
local function getBase(data, entry)
	if entry.isSub then
		local sub = data.subRegions and data.subRegions[entry.subIndex]
		local value = sub and sub[entry.subKey]
		if entry.baseIndex and type(value) == "table" then return value[entry.baseIndex] end
		return value
	end
	if entry.base ~= nil then return entry.base end
	local value = data[entry.dataKey]
	if entry.baseIndex and type(value) == "table" then return value[entry.baseIndex] end
	return value
end

local function applyProperty(region, entry, value)
	local target = region
	if entry.isSub then
		target = region.subRegions and region.subRegions[entry.subIndex]
	end
	if not target or not entry.setter or not target[entry.setter] then return end
	-- A number setter does arithmetic on what it is handed, so a nil takes the
	-- aura down. Two things produce one: a change the author never filled in, and
	-- a deactivating condition restoring a property that has no base to restore
	-- to. Leaving the property where it stands beats erroring in a paint.
	if value == nil and entry.type == "number" then return end
	if entry.type == "color" then
		local c = value or { 1, 1, 1, 1 }
		target[entry.setter](target, c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1)
	else
		target[entry.setter](target, value)
	end
end

-- ---------------------------------------------------------------------------
-- Evaluation
-- ---------------------------------------------------------------------------

local function numCmp(op, a, b)
	if a == nil or b == nil then return false end
	if op == "==" then return a == b
	elseif op == "~=" then return a ~= b
	elseif op == ">" then return a > b
	elseif op == ">=" then return a >= b
	elseif op == "<" then return a < b
	elseif op == "<=" then return a <= b end
	return false
end

local function compareValue(vtype, op, actual, value)
	op = op or "=="
	if vtype == "number" then
		return numCmp(op, tonumber(actual), tonumber(value))
	elseif vtype == "bool" then
		local a = actual and true or false
		local b = (value == true or value == "true" or value == 1 or value == "1")
		if op == "~=" then return a ~= b end
		return a == b
	else -- string / select
		if op == "~=" then return tostring(actual) ~= tostring(value) end
		return tostring(actual) == tostring(value)
	end
end

-- Returns (active, nextFlip): active is this check's boolean now; nextFlip is
-- the soonest future time a timer/elapsedTimer sub-result would change (or nil),
-- so the caller can schedule an exact recheck instead of polling.
local function evalCheck(check, states, entry, now)
	local trig = check.trigger
	if trig == -2 then
		-- AND/OR combinator over nested checks.
		local subs = check.checks or {}
		local isOr = check.variable == "OR"
		local res = not isOr -- AND starts true, OR starts false
		local nextFlip
		for i = 1, table.getn(subs) do
			local r, f = evalCheck(subs[i], states, entry, now)
			if isOr then if r then res = true end
			else if not r then res = false end end
			if f and (not nextFlip or f < nextFlip) then nextFlip = f end
		end
		return res, nextFlip
	elseif trig == -1 then
		local g = WA.globalConditions[check.variable]
		if not g then return false end
		return compareValue("bool", check.op, g.get(), check.value)
	else
		local state = states[trig]
		if not state then return false end
		local tmpl = entry.templates[trig] and entry.templates[trig][check.variable]
		if not tmpl then return false end
		local vtype = tmpl.type
		if vtype == "timer" then
			-- state[variable] holds an absolute expiration; compare *remaining*.
			-- A fallback/missing state carries 0 here -- treat as "no timer" so a
			-- "remaining < N" check doesn't read the huge negative remaining as true.
			local expiry = state[check.variable]
			if not expiry or expiry <= 0 then return false end
			local target = tonumber(check.value) or 0
			local cur = numCmp(check.op, expiry - now, target)
			local flip = expiry - target -- remaining == target at this instant
			return cur, (flip > now and flip or nil)
		elseif vtype == "elapsedTimer" then
			-- state[variable] holds an absolute past timestamp; compare *elapsed*.
			local base = state[check.variable]
			if not base or base <= 0 then return false end
			local target = tonumber(check.value) or 0
			local cur = numCmp(check.op, now - base, target)
			local flip = base + target -- elapsed == target at this instant
			return cur, (flip > now and flip or nil)
		else
			return compareValue(vtype, check.op, state[check.variable], check.value)
		end
	end
end

-- ---------------------------------------------------------------------------
-- The run + recheck scheduling
-- ---------------------------------------------------------------------------

local function getActivated(uid, cloneId)
	activated[uid] = activated[uid] or {}
	activated[uid][cloneId] = activated[uid][cloneId] or {}
	return activated[uid][cloneId]
end

local runFor -- forward decl: scheduleRecheck's timer closure re-enters it.

local function scheduleRecheck(region, uid, cloneId, nextFlip, now)
	local key = uid .. "\0" .. cloneId
	local existing = scheduled[key]
	if existing then existing:Cancel(); scheduled[key] = nil end
	if nextFlip and region.toShow then
		-- Small epsilon so the boundary has actually passed when we re-evaluate
		-- (a strict "<" wouldn't flip at exactly the threshold instant).
		local delay = (nextFlip - now) + 0.05
		if delay < 0.05 then delay = 0.05 end
		scheduled[key] = C_Timer.NewTimer(delay, function()
			scheduled[key] = nil
			if region.toShow then runFor(region, uid, false) end
		end)
	end
end

runFor = function(region, uid, hideRegion)
	local entry = compiled[uid]
	if not entry then return end
	local data = entry.data
	local conditions = data.conditions or {}
	local nConds = table.getn(conditions)
	local cloneId = region.cloneId or ""
	local now = GetTime()

	if nConds == 0 then
		scheduleRecheck(region, uid, cloneId, nil, now)
		return
	end

	local states = region.states or {}
	local prev = getActivated(uid, cloneId)

	-- Phase 1: evaluate every condition, collecting the earliest timer flip.
	local newActive = {}
	local nextFlip
	for i = 1, nConds do
		local active, flip
		if hideRegion then
			active = false
		else
			active, flip = evalCheck(conditions[i].check, states, entry, now)
		end
		newActive[i] = active and true or false
		if flip and (not nextFlip or flip < nextFlip) then nextFlip = flip end
	end

	-- Phase 2 (deactivation): conditions active before but not now write their
	-- properties' base values. Phase 3 (activation): active conditions write
	-- their change values, later conditions overwriting earlier -- so a
	-- contested property goes to the last matching condition, and a property no
	-- active condition touches is restored. propertyChanges holds one entry per
	-- touched property; applied once each afterwards (no mid-run flicker, §10).
	local propertyChanges = {}
	for i = 1, nConds do
		if prev[i] and not newActive[i] then
			local changes = conditions[i].changes or {}
			for c = 1, table.getn(changes) do
				local prop = changes[c].property
				local pentry = prop and entry.properties[prop]
				if pentry and not pentry.action then
					propertyChanges[prop] = { entry = pentry, value = getBase(data, pentry) }
				elseif pentry and pentry.action == "SoundPlay"
					and type(changes[c].value) == "table"
					and changes[c].value.sound_type == "Loop" then
					local target = region
					if pentry.isSub then target = region.subRegions and region.subRegions[pentry.subIndex] end
					if target and target.SoundRepeatStop then target:SoundRepeatStop() end
				end
			end
		end
	end
	for i = 1, nConds do
		if newActive[i] then
			local changes = conditions[i].changes or {}
			for c = 1, table.getn(changes) do
				local prop = changes[c].property
				local pentry = prop and entry.properties[prop]
				if pentry and pentry.action then
					if not prev[i] then
						local target = region
						if pentry.isSub then target = region.subRegions and region.subRegions[pentry.subIndex] end
						if target and target[pentry.action] then
							local value = changes[c].value
							if pentry.type == "customcode" and type(value) == "string" then
								value = WA.LoadFunction(value, uid .. ": condition custom code", true)
							end
							if pentry.type == "sound" then
								target[pentry.action](target, value)
							elseif pentry.type == "chat" then
								target[pentry.action](target, value)
							else
								target[pentry.action](target, value)
							end
						end
					end
				elseif pentry then
					propertyChanges[prop] = { entry = pentry, value = changes[c].value }
				end
			end
		end
	end
	for _, pc in pairs(propertyChanges) do
		applyProperty(region, pc.entry, pc.value)
	end

	for i = 1, nConds do prev[i] = newActive[i] end
	scheduleRecheck(region, uid, cloneId, hideRegion and nil or nextFlip, now)
end

-- ---------------------------------------------------------------------------
-- Hooks the state machine calls (overriding Data.lua's no-op stubs). The
-- StateMachine looks these WA.* names up at call time, so overriding here --
-- loaded after StateMachine, before AddAllDisplays -- is enough.
-- ---------------------------------------------------------------------------

WA.RunConditions = function(region, uid, hideRegion)
	if not uid then return end
	WA.safecall(uid, runFor, region, uid, hideRegion)
end

function WA.ReleaseConditionsForClone(uid, cloneId)
	if not uid then return end
	local byClone = activated[uid]
	if byClone then byClone[cloneId] = nil end
	local key = uid .. "\0" .. cloneId
	local timer = scheduled[key]
	if timer then timer:Cancel(); scheduled[key] = nil end
end

function WA.LoadConditions(data)
	if WA.IsGroup(data) then return end
	local uid = data.uid
	compiled[uid] = {
		data = data,
		properties = WA.GetProperties(data),
		templates = WA.GetConditionTemplates(data),
	}
	-- Forget prior activation so a recompiled aura re-evaluates from scratch
	-- (its regions get re-applied by the WA.Add that called us).
	activated[uid] = nil
end

function WA.UnloadConditions(data)
	local uid = data.uid
	compiled[uid] = nil
	activated[uid] = nil
	for key, timer in pairs(scheduled) do
		local sep = string.find(key, "\0", 1, true)
		if sep and string.sub(key, 1, sep - 1) == uid then
			timer:Cancel()
			scheduled[key] = nil
		end
	end
end

-- Read-only debug view (Debug.lua's /wa conditions): per-clone activation flags
-- and whether an exact recheck is pending.
function WA.GetConditionDebug(uid)
	local pending = {}
	for key in pairs(scheduled) do
		local sep = string.find(key, "\0", 1, true)
		if sep and string.sub(key, 1, sep - 1) == uid then
			table.insert(pending, string.sub(key, sep + 1))
		end
	end
	return compiled[uid], activated[uid], pending
end

-- ---------------------------------------------------------------------------
-- Global-condition events: re-run every shown region's conditions on a combat/
-- target change. Cheap at this scale, so it runs unconditionally rather than
-- tracking which auras actually use a global condition (§10 dynamic events).
-- ---------------------------------------------------------------------------

local globalFrame = CreateFrame("Frame")
for i = 1, table.getn(GLOBAL_EVENTS) do globalFrame:RegisterEvent(GLOBAL_EVENTS[i]) end
globalFrame:SetScript("OnEvent", function()
	if not WA.ForEachRegion then return end
	WA.ForEachRegion(function(region, id)
		if region.toShow then
			local data = WeakestAurasDB.displays[id]
			if data and data.uid then WA.RunConditions(region, data.uid, false) end
		end
	end)
end)
