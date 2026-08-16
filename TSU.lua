-- WeakestAuras -- the Trigger State Updater's allstates helper table and the
-- state-owned per-clone auto-hide timers a TSU state carries. Mirrors WA2's
-- TSUHelpers.lua and the startStopTimers half of its WeakAuras.lua (§4.3).
-- Upstream section refs (§N) point at design/architecture/weakauras2-reference.md

if WeakestAuras.disabled then return end

local WA = WeakestAuras

-- ---------------------------------------------------------------------------
-- allstates helpers: states:Update/Replace/Remove/RemoveAll/Get/IsChanged/
-- SetChanged, attached to a trigger's allstates table via metatable.
-- ---------------------------------------------------------------------------

local function fixMissingFields(state)
	if type(state) ~= "table" then return end
	if state.show == nil then
		state.show = true
	end
end

-- Dropped when its allstates table is; a states table that never carries the
-- helper metatable never needs an entry either.
local changedStates = setmetatable({}, { __mode = "k" })

local function remove(states, key)
	local changed = false
	if states[key] then
		states[key] = nil
		states:SetChanged(true)
		changed = true
	end
	return changed
end

local function removeAll(states)
	local changed = false
	for cloneId in pairs(states) do
		states[cloneId] = nil
		changed = true
	end
	if changed then
		states:SetChanged(true)
	end
	return changed
end

local skipKeys = {
	trigger = true,
	triggernum = true,
}

local function recurseReplaceOrUpdate(t1, t2, isRoot, replace)
	local changed = false
	if replace then
		for k in pairs(t1) do
			if t2[k] == nil then
				t1[k] = nil
				changed = true
			end
		end
	end
	for k, v in pairs(t2) do
		if isRoot and skipKeys[k] then
			-- skip
		else
			if type(v) == "table" then
				if type(t1[k]) ~= "table" then
					t1[k] = {}
					changed = true
				end
				if recurseReplaceOrUpdate(t1[k], v, false, replace) then
					changed = true
				end
			else
				if t1[k] ~= v then
					t1[k] = v
					changed = true
				end
			end
		end
	end
	return changed
end

local function replaceOrUpdate(states, key, newState, replace)
	local changed = false
	local state = states[key]
	if state then
		changed = recurseReplaceOrUpdate(state, newState, true, replace)
		if changed then
			state.changed = true
			states:SetChanged(true)
		end
	end
	return changed
end

local function create(states, key, newState)
	states[key] = newState
	states[key].changed = true
	states:SetChanged(true)
	return true
end

local function createOrUpdate(states, key, newState)
	key = key or ""
	if states[key] then
		return replaceOrUpdate(states, key, newState, false)
	else
		return create(states, key, newState)
	end
end

local function createOrReplace(states, key, newState)
	key = key or ""
	if states[key] then
		return replaceOrUpdate(states, key, newState, true)
	else
		return create(states, key, newState)
	end
end

local function get(states, key, field)
	key = key or ""
	local state = states[key]
	if state then
		if field == nil then
			return state
		end
		return state[field]
	end
	return nil
end

local function isChanged(states)
	return changedStates[states] == true
end

local function setChanged(states, changed)
	changedStates[states] = changed
end

local plainMeta = {
	__index = {
		Update = createOrUpdate,
		Replace = createOrReplace,
		Remove = remove,
		RemoveAll = removeAll,
		Get = get,
		IsChanged = isChanged,
		SetChanged = setChanged,
	},
}

-- Upstream wraps Update/Replace with fixMissingFields(states[key]), using the
-- caller's `key` before it has been defaulted -- when key is nil that reads
-- states[nil], never the "" clone the inner call actually touched. Defaulting
-- it the same way here before the lookup is the fix. Takes newState directly
-- rather than forwarding varargs: Update/Replace are always called as
-- states:Update(key, newState), and Lua 5.0 has no `...` expression -- a vararg
-- function reads its extra arguments out of the `arg` table instead.
local function addFixMissingFields(func)
	return function(states, key, newState)
		local changed = func(states, key, newState)
		fixMissingFields(states[key or ""])
		return changed
	end
end

local showFixMeta = {
	__index = {
		Update = addFixMissingFields(createOrUpdate),
		Replace = addFixMissingFields(createOrReplace),
		Remove = remove,
		RemoveAll = removeAll,
		Get = get,
		IsChanged = isChanged,
		SetChanged = setChanged,
	},
}

-- Attaches the helper methods to a trigger's live allstates table. The table is
-- recreated by WA.Add on every recompile, so this is idempotent and re-applied
-- on each run rather than once at compile.
--
-- The trap is which metatable `showNilIsFalse` selects, because the two halves
-- of that flag read as opposites and are not. It governs a state the *code*
-- built by hand: one that never set `show` is hidden. So the helper path has to
-- supply the `show` the author would otherwise have to write, or every
-- helper-built state under that flag would vanish -- which is why the fixing
-- metatable is the one the flag turns on, not off.
function WA.EnsureAllStates(states, showNilIsFalse)
	local wantMeta = showNilIsFalse and showFixMeta or plainMeta
	if getmetatable(states) == wantMeta then
		return states
	end
	return setmetatable(states, wantMeta)
end

-- ---------------------------------------------------------------------------
-- Custom-variable expansion and validation, for a TSU trigger's
-- customVariables chunk.
-- ---------------------------------------------------------------------------

local commonConditions = {
	expirationTime = {
		display = "Remaining Duration",
		type = "timer",
		total = "duration",
		inverse = "inverse",
		paused = "paused",
		remaining = "remaining",
	},
	duration = { display = "Total Duration", type = "number" },
	paused = { display = "Is Paused", type = "bool" },
	value = { display = "Progress Value", type = "number", total = "total" },
	total = { display = "Progress Total", type = "number" },
	stacks = { display = "Stacks", type = "number" },
	name = { display = "Name", type = "string" },
}

-- The declared-type subset this addon's conditions/text code can read.
local supportedVariableTypes = {
	bool = true,
	number = true,
	timer = true,
	elapsedTimer = true,
	select = true,
	string = true,
}

-- Upstream's short-hand notations: `stacks = "number"` for a common field takes
-- the full common descriptor, and any `key = "type"` string becomes
-- { display = key, type = type }.
function WA.ExpandCustomVariables(variables)
	for k, v in pairs(commonConditions) do
		if variables[k] and type(variables[k]) ~= "table" then
			variables[k] = v
		end
	end

	for k, v in pairs(variables) do
		if type(v) == "string" then
			variables[k] = {
				display = k,
				type = v,
			}
		end
	end
end

-- The declared variables a TSU trigger's customVariables chunk returns, expanded
-- and cleaned: non-table entries and entries with no usable display name are
-- dropped, as are declared types this addon's conditions/text code cannot read.
function WA.CleanCustomVariables(variables)
	if type(variables) ~= "table" then return nil end
	WA.ExpandCustomVariables(variables)

	local toRemove = {}
	for k, v in pairs(variables) do
		local drop = false
		if type(v) ~= "table" then
			drop = true
		else
			if v.display == nil or type(v.display) ~= "string" then
				if type(k) == "string" then
					v.display = k
				else
					drop = true
				end
			end
			if not drop then
				if not supportedVariableTypes[v.type] then
					drop = true
				elseif v.type == "select" and not v.values then
					drop = true
				end
			end
		end
		if drop then
			table.insert(toRemove, k)
		end
	end
	for i = 1, table.getn(toRemove) do
		variables[toRemove[i]] = nil
	end

	return variables
end

local validProperties = {
	display = "string",
	type = "string",
	test = "function",
	events = "table",
	values = "table",
	total = "string",
	inverse = "string",
	paused = "string",
	remaining = "string",
	modRate = "string",
	useModRate = "boolean",
	formatter = "string",
}

-- Upstream's customVariables validator, for the options editor. Returns nil when
-- the declaration is usable, or a message naming the first problem.
function WA.ValidateCustomVariables(variables)
	if type(variables) ~= "table" then
		return "Not a table"
	end

	WA.ExpandCustomVariables(variables)

	for k, v in pairs(variables) do
		if k == "additionalProgress" then
			-- additionalProgress is exempt from the checks below
		elseif type(v) ~= "table" then
			return string.format("Could not parse '%s'. Expected a table.", tostring(k))
		elseif not supportedVariableTypes[v.type] then
			return string.format(
				"Invalid type for '%s'. Expected 'bool', 'number', 'select', 'string', 'timer' or 'elapsedTimer'.",
				tostring(k))
		elseif v.type == "select" and not v.values then
			return string.format("Type 'select' for '%s' requires a values member", tostring(k))
		else
			for property, propertyValue in pairs(v) do
				if not validProperties[property] then
					return string.format("Unknown property '%s' found in '%s'", tostring(property), tostring(k))
				end
				if type(propertyValue) ~= validProperties[property] then
					return string.format("Invalid type for property '%s' in '%s'. Expected '%s'",
						tostring(property), tostring(k), validProperties[property])
				end
			end
		end
	end

	return nil
end

-- ---------------------------------------------------------------------------
-- State-owned per-clone auto-hide timers. A TSU state owns its own expiry
-- through state.autoHide, unlike an event trigger's single trigger-owned
-- duration.
-- ---------------------------------------------------------------------------

local timers = {}

-- Set while a diagnostic is watching (Debug.lua's /wa tsutrace), nil otherwise
-- so the timer path costs nothing when nobody is. Called as
-- (what, id, triggernum, cloneId, seconds) for "arm", "fire" and "cancel".
WA.OnStateTimer = nil

local function report(what, record, cloneId, seconds)
	if WA.OnStateTimer then
		WA.OnStateTimer(what, record.id, record.triggernum, cloneId, seconds)
	end
end

-- Read-only walk of a display's live hide timers, for the same diagnostic. A
-- record's armedAt/armedDelay say what deadline it was actually given, which is
-- the only way to tell a timer that fired early from a state something else
-- removed.
function WA.ForEachStateTimer(id, fn)
	local displayTimers = timers[id]
	if not displayTimers then return end
	for triggernum, triggerTimers in pairs(displayTimers) do
		for cloneId, record in pairs(triggerTimers) do fn(triggernum, cloneId, record) end
	end
end

local function cancelTimerRecord(record, cloneId)
	if record.handle then
		report("cancel", record, cloneId, record.armedDelay)
		record.handle:Cancel()
	end
	record.handle = nil
	record.expirationTime = nil
	record.state = nil
end

-- Reconciles one trigger's per-clone hide timers against its states.
function WA.StartStopStateTimers(id, triggernum, states)
	timers[id] = timers[id] or {}
	timers[id][triggernum] = timers[id][triggernum] or {}
	local triggerTimers = timers[id][triggernum]

	for cloneId, state in pairs(states) do
		-- Lua 5.0 closes a `for` body's own locals per iteration but NOT the loop
		-- variables, which stay one shared upvalue until the loop ends. A timer
		-- closing over `cloneId` directly would therefore see whichever key the
		-- loop finished on, and every clone's deadline would delete that one
		-- clone. The copy is what gives each closure its own key. 5.1 does not
		-- behave this way, so the headless harness cannot catch a regression here.
		local key = cloneId
		local expirationTime = nil
		if state.autoHide then
			if type(state.autoHide) == "boolean" then
				if state.paused then
					expirationTime = nil
				else
					if state.expirationTime == nil and type(state.duration) == "number" then
						-- A boolean autoHide names no deadline, so one is derived from
						-- the duration and written back: TSU code reads state.expirationTime
						-- afterwards, and leaving it nil would make the hide unobservable
						-- to the aura that scheduled it.
						state.expirationTime = GetTime() + state.duration
					end
					expirationTime = state.expirationTime
				end
			elseif type(state.autoHide) == "number" then
				expirationTime = state.autoHide
			end
		end
		-- state.expirationTime is whatever the aura's code put there, so the
		-- boolean path can arrive here holding a non-number. No deadline, no timer.
		if type(expirationTime) ~= "number" then expirationTime = nil end

		local record = triggerTimers[key]
		if expirationTime == nil then
			if record then
				cancelTimerRecord(record, key)
			end
		else
			if not record then
				record = {}
				triggerTimers[key] = record
			end
			-- The display id is read back off the record rather than captured, so a
			-- rename can re-key a deadline that is already pending: a closure holding
			-- the old id would remove the state and then repaint nothing.
			record.id = id
			record.triggernum = triggernum
			if record.expirationTime ~= expirationTime or record.state ~= state then
				if record.handle then
					record.handle:Cancel()
				end
				local delay = expirationTime - GetTime()
				if delay < 0 then delay = 0 end
				record.armedAt = GetTime()
				record.armedDelay = delay
				report("arm", record, key, delay)
				record.handle = C_Timer.NewTimer(delay, function()
					report("fire", record, key, GetTime() - (record.armedAt or GetTime()))
					record.handle = nil
					record.expirationTime = nil
					record.state = nil
					if states[key] then
						states[key] = nil
						if WA.NotifyWatchedTriggers then
							WA.NotifyWatchedTriggers(record.id, record.triggernum)
						end
						WA.UpdatedTriggerState(record.id)
					end
				end)
				record.expirationTime = expirationTime
				record.state = state
			end
		end
	end

	local toRemove = {}
	for cloneId in pairs(triggerTimers) do
		if not states[cloneId] then
			table.insert(toRemove, cloneId)
		end
	end
	for i = 1, table.getn(toRemove) do
		local cloneId = toRemove[i]
		cancelTimerRecord(triggerTimers[cloneId], cloneId)
		triggerTimers[cloneId] = nil
	end
end

-- Cancels one clone's pending hide across every trigger of a display. The clone
-- lifecycle calls this when it releases a region frame.
function WA.StopStateTimersForClone(id, cloneId)
	local displayTimers = timers[id]
	if not displayTimers then return end
	for triggernum, triggerTimers in pairs(displayTimers) do
		local record = triggerTimers[cloneId]
		if record then
			cancelTimerRecord(record, cloneId)
			triggerTimers[cloneId] = nil
		end
	end
end

-- Re-keys a display's pending hides. A rename does not recompile, so cancelling
-- them instead would leave a state that already has its deadline with nothing
-- left to fire it.
function WA.RenameStateTimers(oldId, newId)
	local displayTimers = timers[oldId]
	if not displayTimers then return end
	timers[newId] = displayTimers
	timers[oldId] = nil
	for _, triggerTimers in pairs(displayTimers) do
		for _, record in pairs(triggerTimers) do record.id = newId end
	end
end

-- Cancels a display's pending hides -- all of them, or one trigger's. Unload,
-- recompilation and deletion all drop timer ownership through this.
function WA.StopStateTimers(id, triggernum)
	local displayTimers = timers[id]
	if not displayTimers then return end

	if triggernum then
		local triggerTimers = displayTimers[triggernum]
		if triggerTimers then
			for cloneId, record in pairs(triggerTimers) do
				cancelTimerRecord(record, cloneId)
			end
			displayTimers[triggernum] = nil
		end
	else
		for _, triggerTimers in pairs(displayTimers) do
			for cloneId, record in pairs(triggerTimers) do
				cancelTimerRecord(record, cloneId)
			end
		end
		timers[id] = nil
	end
end
