-- WeakestAuras -- GenericTrigger-lite: the runtime trigger system for every
-- non-aura trigger kind. Ported from WeakAuras2's GenericTrigger (ref
-- WA2's GenericTrigger (§4), scaled to this client.
--
-- The payoff of the whole engine: a new trigger *category* is a data table (an
-- "event prototype" in PROTOTYPES) declaring its game/internal events, an `init`
-- preamble, an `args` list, and optional display hooks -- no new system code.
-- One prototype's args drive its test function, its state fields, its condition
-- variables (§10) and its options editor at once.
--
-- Split faithful to upstream (and to Conditions.lua's own reasoning): the
-- *matching* logic (init + per-arg tests + stores) is compiled to one Lua
-- function per trigger via ConstructFunction/loadstring -- prototype fragments
-- are Lua source by design, so an interpreter would loadstring the pieces
-- anyway. The *display* side (duration/name/icon) stays plain Lua closures the
-- system calls after a successful test, exactly as upstream's durationFunc/
-- nameFunc/iconFunc do. loadstring is confirmed on this client (StateMachine's
-- customTriggerLogic, Conditions' deferred custom). /wa gen <id> dumps the
-- generated source, making source-assembly errors readable.
--
-- Watcher sections sit inside a bare `do ... end`. Lua 5.0 allows 200 locals
-- live at once in a function, and this file's chunk is one function; a block
-- returns its slots at `end`, so each self-contained watcher costs the chunk
-- nothing. Closures still capture what they need -- an upvalue survives the
-- block that declared it -- and the sections reach the rest of the file the
-- way they already did, through WA.* and PROTOTYPES. Deleting one of those
-- `do`/`end` pairs re-spends its slots and puts the file back at the ceiling.

if WeakestAuras.disabled then return end

local WA = WeakestAuras

local GenericTrigger = {}

-- events[id][triggernum] = triggerInfo (this display's compiled generic
-- triggers). Present after Add (compile); a ti only enters loaded_events (starts
-- receiving events) once the display is loaded (§11).
local events = {}
-- loaded_events[event][id][triggernum] = triggerInfo -- the dispatch index a
-- game/internal event walks (§4.3). Both game and internal events live here;
-- only game events are RegisterEvent'd on the frame (internal ones arrive via
-- WA.ScanEvents from a watcher).
local loaded_events = {}
-- activeIds[id] = true while this display's tis are in loaded_events (it's
-- loaded). Keeps Load/Unload idempotent.
local activeIds = {}

-- The tis a Delete just retired, kept only until the next Add compares its
-- sourceKey against them (see GenericTrigger.Delete).
local lastCompiled = {}

-- The display being compiled, and per display the spell or item names its
-- compile could not resolve, each with the resolver that failed it. A name
-- resolves to an id baked into the generated source, so an unresolved one
-- leaves that trigger dead until something recompiles it -- which is the entire
-- reason the addon recompiles on spell/item cache traffic (OptionsFrame.lua's
-- debounced sweep). Nothing else about a compile depends on the caches.
local compilingId
local unresolvedIds = {} -- id -> { [name] = resolver }

-- Keyed by the name that failed, so a display waiting on two of them says both.
-- Never printed: an item cache is cold at every login, so the common case is a
-- name that resolves a moment later and the recompile sweep clears it -- a chat
-- line would fire on every login and mean nothing.
local function noteUnresolved(input, resolve)
	if not compilingId then return end
	local names = unresolvedIds[compilingId]
	if not names then
		names = {}
		unresolvedIds[compilingId] = names
	end
	names[input] = resolve
	WA.ReportForAura(compilingId, "unresolved:" .. tostring(input), "warning",
		"[" .. tostring(compilingId) .. "] \"" .. tostring(input)
			.. "\" is not a spell or item this client can name yet, so the trigger using it stays dark.")
end

-- Whether any compiled display is still waiting on a name the client cannot
-- resolve yet.
function WA.HasUnresolvedNames()
	for _ in pairs(unresolvedIds) do return true end
	return false
end

-- Recompiles the displays waiting on a name that resolves now, and nothing
-- else. A name that never resolves -- another class's spell, an item never
-- carried -- is the common case on a multi-class profile, and recompiling every
-- display on each cache event for it was the addon's largest source of garbage.
-- Outside a compile the resolvers note nothing, so the retry is side-effect free.
function WA.RecompileResolvedNames()
	local ready
	for id, names in pairs(unresolvedIds) do
		local data = WeakestAurasDB.displays[id]
		if not data then
			unresolvedIds[id] = nil
		else
			for input, resolve in pairs(names) do
				if resolve(input) then
					ready = ready or {}
					table.insert(ready, data)
					break
				end
			end
		end
	end
	if ready then WA.AddMany(ready) end
	return ready ~= nil
end

-- Internal (WA-generated) event names never handed to Frame:RegisterEvent -- a
-- watcher re-dispatches them through WA.ScanEvents instead (§4.4).
local INTERNAL_EVENTS = {
	SPELL_COOLDOWN_CHANGED = true,
	SPELL_COOLDOWN_READY = true,
	ITEM_COOLDOWN_CHANGED = true,
	ITEM_COOLDOWN_READY = true,
	EQUIPSLOT_COOLDOWN_CHANGED = true,
	EQUIPSLOT_COOLDOWN_READY = true,
	GCD_UPDATE = true,
	GCD_END = true,
	-- Re-emitted by the threat watcher after parsing a TWThreat addon-message
	-- broadcast (there's no threat game event; see the watcher below).
	WA_THREAT_CHANGED = true,
	-- Re-emitted by the swing-timer watcher on a swing reset / rescale / stop.
	WA_SWING_UPDATE = true,
	-- Re-emitted with the cast spell id after the player's own cast completes.
	WA_SPELL_CAST_SUCCEEDED = true,
	-- A shared 1s heartbeat for status prototypes whose value depletes with no
	-- natural game event (weapon-enchant / crowd-control remaining time). Started
	-- lazily by WA.EnsureSlowTick when such a trigger loads (below).
	WA_SLOW_TICK = true,
	-- A shared 0.1s heartbeat for status prototypes that track a fast-moving
	-- value (range to a unit). Started lazily by WA.EnsureFastTick.
	WA_FAST_TICK = true,
	-- Fired after the player's login/loading-screen state has settled. Native
	-- status APIs such as GetMoney can return their usable value only after the
	-- initial PLAYER_ENTERING_WORLD burst.
	WA_DELAYED_PLAYER_ENTERING_WORLD = true,
	-- Re-emitted by the power-tick watcher when a regen tick is inferred or the
	-- timer stops (power type change, full power).
	WA_POWERTICK_UPDATE = true,
	-- Upstream's per-frame custom-trigger pulse, carrying the frame's elapsed
	-- time. Driven by an OnUpdate rather than C_Timer, which cannot schedule
	-- per-frame; per-trigger onUpdateThrottle is what keeps it affordable.
	FRAME_UPDATE = true,
}

-- The unit watcher's occupancy events carry the token in their name
-- (WA_UNIT_CHANGED_target), so they cannot be listed above: the set is whatever
-- tokens loaded auras name, `specific`'s free text included.
local UNIT_CHANGED_PREFIX = "WA_UNIT_CHANGED_"

-- The token an occupancy event names, or nil if this is not one.
local function unitChangeToken(event)
	local _, _, token = string.find(event, "^" .. UNIT_CHANGED_PREFIX .. "(.+)$")
	return token
end

local function isInternalEvent(name)
	if INTERNAL_EVENTS[name] then return true end
	return unitChangeToken(name) and true or false
end

-- ---------------------------------------------------------------------------
-- Code-generation helpers (ConstructFunction, §4.2)
-- ---------------------------------------------------------------------------

-- A config value as a Lua literal for embedding in generated source. %q handles
-- string quoting/escaping (Lua 5.0 has it); numbers/bools go verbatim.
local function fmt(v)
	if type(v) == "number" then return tostring(v)
	elseif type(v) == "boolean" then return v and "true" or "false"
	elseif v == nil then return "nil"
	else return string.format("%q", tostring(v)) end
end

-- Splits a user-typed "EVT_A, EVT_B  EVT_C" event string (custom-trigger config)
-- into a trimmed list. Commas and any whitespace both separate; empty tokens are
-- dropped. Pattern string ops are fine on Lua 5.0 (gsub/find with patterns work;
-- only gmatch is missing).
local function parseEventList(str)
	local out = {}
	if not str or str == "" then return out end
	local s = string.gsub(str, ",", " ")
	local pos = 1
	while true do
		local a, b = string.find(s, "%s+", pos)
		local tok
		if a then tok = string.sub(s, pos, a - 1); pos = b + 1
		else tok = string.sub(s, pos) end
		if tok ~= "" then table.insert(out, tok) end
		if not a then break end
	end
	return out
end

local COMMON_CUSTOM_EVENTS = {
	"PLAYER_ENTERING_WORLD", "PLAYER_TARGET_CHANGED", "PLAYER_REGEN_DISABLED",
	"PLAYER_REGEN_ENABLED", "UNIT_AURA", "UNIT_HEALTH", "UNIT_MANA",
	"UNIT_ENERGY", "UNIT_RAGE", "BAG_UPDATE", "SPELLS_CHANGED",
	"SPELL_UPDATE_COOLDOWN", "ACTIONBAR_UPDATE_COOLDOWN", "READY_CHECK",
	"PARTY_MEMBERS_CHANGED", "RAID_ROSTER_UPDATE", "CHAT_MSG_SAY",
	"CHAT_MSG_PARTY", "CHAT_MSG_RAID", "CHAT_MSG_WHISPER",
	"UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_SUCCEEDED",
	"UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_STOP",
	"COMBAT_LOG_EVENT_UNFILTERED",
}
local customEventSearch = {}

-- One "EVENT:a:b" token's colon-separated parts.
local function splitEventToken(token)
	local parts = {}
	for part in string.gmatch(token, "[^:]+") do table.insert(parts, part) end
	return parts
end

-- A custom trigger's event list in upstream's extended syntax, resolved into the
-- three things this client can act on: the events to register, a per-event set of
-- unit tokens to filter arg1 against, and the trigger numbers to watch.
--
-- "UNIT_AURA:player:target" is a filter rather than a narrower registration: the
-- general event is registered and dispatch drops payloads whose unit is not
-- listed.
-- "TRIGGER:2" names another of the display's triggers and registers no game
-- event at all. "CLEU" is upstream's alias for COMBAT_LOG_EVENT_UNFILTERED, and
-- "CLEU:SPELL_DAMAGE:SPELL_HEAL" filters on the subevent (arg2) the way
-- "UNIT_AURA:player" filters on the unit. A bare CLEU token takes every subevent.
local function parseCustomEventList(str)
	local eventList, unitFilters, watched = {}, nil, nil
	local cleu, subeventFilter, cleuAll = false, nil, false
	local tokens = parseEventList(str)
	for i = 1, #tokens do
		local token = tokens[i]
		local parts = splitEventToken(token)
		local base = parts[1]
		local upper = base and string.upper(base) or ""
		if upper == "CLEU" or upper == "COMBAT_LOG_EVENT_UNFILTERED" then
			if not cleu then
				cleu = true
				table.insert(eventList, "COMBAT_LOG_EVENT_UNFILTERED")
			end
			if #parts == 1 then cleuAll = true end
			for p = 2, #parts do
				subeventFilter = subeventFilter or {}
				subeventFilter[string.upper(parts[p])] = true
			end
		elseif upper == "TRIGGER" then
			for p = 2, #parts do
				local num = tonumber(parts[p])
				if num then
					watched = watched or {}
					watched[num] = true
				end
			end
		elseif #parts > 1 and string.find(upper, "^UNIT_") then
			table.insert(eventList, base)
			unitFilters = unitFilters or {}
			local set = unitFilters[base] or {}
			unitFilters[base] = set
			for p = 2, #parts do
				set[string.lower(parts[p])] = true
			end
		else
			table.insert(eventList, base or token)
		end
	end
	if cleuAll then subeventFilter = nil end
	return eventList, unitFilters, watched, subeventFilter
end

-- The unit filters a built-in prototype gets for free when its UNIT_* events
-- all name the one unit it reads (its `subjectUnit`): upstream's
-- RegisterUnitEvent. Without them every UNIT_HEALTH in a raid runs every Health
-- trigger, and ClassicAPI fires each one once per token -- raidN, partyN,
-- target, nameplateN, markN all at once. Only tokens ClassicAPI does fire
-- events under are filtered; a derived token (targettarget, mouseover) fires
-- none, so its trigger keeps refreshing on any unit's event as before.
local subjectUnitFilters
do
	local FIRING_TOKENS = { player = true, pet = true, target = true, focus = true }
	local function firesUnitEvents(token)
		return FIRING_TOKENS[token] or string.find(token, "^party[1-4]$")
			or string.find(token, "^raid%d+$") or string.find(token, "^nameplate%d+$")
			or string.find(token, "^mark[1-8]$")
	end
	function subjectUnitFilters(eventList, token)
		if type(token) ~= "string" then return nil end
		token = string.lower(token)
		if not firesUnitEvents(token) then return nil end
		local set = { [token] = true }
		local filters
		for i = 1, #eventList do
			local event = eventList[i]
			if string.sub(event, 1, 5) == "UNIT_" then
				filters = filters or {}
				filters[event] = set
			end
		end
		return filters
	end
end

local function isClientEvent(name)
	if isInternalEvent(name) then return true end
	return C_EventUtils.IsEventValid(name) and true or false
end

-- Retail event names any custom trigger may listen under, and the 1.12 events
-- that carry the same news. First-class, not an import fixup: registering one
-- of these names physically registers its client events, and dispatch delivers
-- under the name the trigger listed -- so code branching on
-- `event == "UNIT_POWER_UPDATE"` runs as written whether the aura was imported
-- or typed here, and the events box always means what it says. Without this a
-- retail name pcall-registers into silence and the trigger never re-evaluates.
-- Vanilla splits power by resource and carries no power-type argument, so the
-- four resource events together are what "this unit's power moved" means here.
local EVENT_COMPAT = {
	GROUP_ROSTER_UPDATE = { "PARTY_MEMBERS_CHANGED", "RAID_ROSTER_UPDATE" },
	UNIT_POWER_UPDATE = { "UNIT_MANA", "UNIT_RAGE", "UNIT_ENERGY", "UNIT_FOCUS" },
	UNIT_POWER_FREQUENT = { "UNIT_MANA", "UNIT_RAGE", "UNIT_ENERGY", "UNIT_FOCUS" },
}
-- Client event -> the compat names it feeds, for dispatch's second pass.
local EVENT_COMPAT_SOURCES = {}
for name, sources in pairs(EVENT_COMPAT) do
	for i = 1, #sources do
		EVENT_COMPAT_SOURCES[sources[i]] = EVENT_COMPAT_SOURCES[sources[i]] or {}
		table.insert(EVENT_COMPAT_SOURCES[sources[i]], name)
	end
end

-- Names the editor should flag, in two piles: `invalid` this client neither
-- fires nor redirects, and `redirected` the EVENT_COMPAT names -- which work,
-- and deserve a note saying how rather than a warning saying they don't. A
-- token carrying the extended syntax is judged on its base event, and TRIGGER
-- (no game event) and CLEU (an alias) are exempt rather than reported as
-- unregisterable.
local function invalidEventList(str)
	local invalid, redirected = {}, {}
	local names = parseEventList(str)
	for i = 1, #names do
		local parts = splitEventToken(names[i])
		local base = parts[1] or names[i]
		local upper = string.upper(base)
		if upper == "TRIGGER" or upper == "CLEU" then
			-- not a client event name
		elseif EVENT_COMPAT[base] then
			table.insert(redirected, base)
		elseif not isClientEvent(base) then
			table.insert(invalid, names[i])
		end
	end
	return invalid, redirected
end

local function eventPickerValues(query)
	local values, labels = {}, {}
	local needle = string.upper(query or "")
	local source = needle == "" and COMMON_CUSTOM_EVENTS or (WA.customEventCatalog or {})
	for i = 1, #source do
		local name = source[i]
		if isClientEvent(name)
			and (needle == "" or string.find(name, needle, 1, true)) then
			table.insert(values, name)
			labels[name] = name
			if #values >= 40 then break end
		end
	end
	if #values == 0 then
		table.insert(values, "__NO_EVENT_MATCH__")
		labels.__NO_EVENT_MATCH__ = "No matching events"
	end
	return values, labels
end

local function appendEventName(str, name)
	if name == "__NO_EVENT_MATCH__" then return str or "" end
	local names = parseEventList(str)
	for i = 1, #names do
		if names[i] == name then return str or "" end
	end
	if not str or not string.find(str, "%S") then return name end
	return str .. " " .. name
end

local VALID_OPS = { ["=="] = true, ["~="] = true, ["<"] = true,
	["<="] = true, [">"] = true, [">="] = true }
local function safeOp(op)
	return VALID_OPS[op] and op or "=="
end

-- The comparisons a `string` arg offers, and their editor captions.
local STRING_OPS = { "==", "~=", "find", "notfind" }
local STRING_OP_LABELS = { ["=="] = "Is", ["~="] = "Is Not",
	find = "Contains", notfind = "Doesn't Contain" }

-- The compiled half of a `multiselect` filter (the convention itself lives in
-- WeakestAuras.lua): the comparison it expands into, or nil when it is off.
-- Set keys survive a round trip through a serialiser as strings, so a numeric
-- domain coerces per key rather than trusting the key's type.
--
-- Callable from a prototype's `init` as well as from the arg walk below, so a
-- prototype needing the match as a named local (one an inverse toggle can
-- negate) builds it from the same source the plain filter would.
local function multiSelectSource(trigger, name, var)
	local mode = WA.MultiSelectMode(trigger, name)
	if mode == "multi" then
		local set, terms = trigger[name .. "_multi"], {}
		for value, selected in pairs(set or {}) do
			if selected then
				table.insert(terms, string.format("%s == %s", var, fmt(tonumber(value) or value)))
			end
		end
		if #terms == 0 then return "false" end
		return table.concat(terms, " or ")
	elseif mode == "single" then
		return string.format("%s == %s", var, fmt(trigger[name]))
	end
	return nil
end

-- The compiled half of a `list` filter: the value matches any entry. Where the
-- arg sets `listNegate`, an entry led by "-" excludes its value instead, as
-- upstream's ParseStringCheck does -- so a list of exclusions alone passes
-- anything else, a nil value included. A `listNumeric` arg skips an entry that
-- is not a number. A list with nothing usable matches nothing. The value is the
-- local `listVar` names, the arg's own name by default.
local function listSource(arg, entries)
	if type(entries) ~= "table" then entries = { entries } end
	local var = arg.listVar or arg.name
	local include, exclude = {}, {}
	for i = 1, #entries do
		local _, _, negate, value = string.find(tostring(entries[i]), "^%s*(%-?)%s*(.-)%s*$")
		if negate ~= "" and not arg.listNegate then value = negate .. value; negate = "" end
		if arg.listNumeric then value = tonumber(value) end
		if value ~= nil and value ~= "" then
			if negate ~= "" then
				table.insert(exclude, string.format("%s ~= %s", var, fmt(value)))
			else
				table.insert(include, string.format("%s == %s", var, fmt(value)))
			end
		end
	end
	if #include == 0 and #exclude == 0 then return "false" end
	local parts = {}
	if #include > 0 then table.insert(parts, "(" .. table.concat(include, " or ") .. ")") end
	if #exclude > 0 then table.insert(parts, table.concat(exclude, " and ")) end
	return table.concat(parts, " and ")
end

-- The test source for one arg, or nil if it contributes none. A `test` win:
-- either a format string with a single %s for the user value, or a function
-- (trigger) -> source-string for config-branching tests (e.g. genericShowOn's
-- three show modes each need a different comparison, not one template). A test
-- function returning nil contributes no test. Otherwise a number arg becomes a
-- gated `name <op> value` comparison.
local function constructArgTest(arg, trigger)
	if arg.test then
		if type(arg.test) == "function" then
			local src = arg.test(trigger)
			if not src then return nil end
			return "(" .. src .. ")"
		end
		return "(" .. string.format(arg.test, fmt(trigger[arg.name])) .. ")"
	end
	if arg.type == "number" then
		if not arg.required and not trigger["use_" .. arg.name] then return nil end
		local op = safeOp(trigger[arg.name .. "_operator"] or ">=")
		local test = string.format("(%s %s %s)", arg.name, op, fmt(trigger[arg.name] or 0))
		-- A second bound on the same value turns one comparison into a range
		-- ("between 20 and 50"), which one operator cannot express. Parenthesised
		-- as a unit so it stays one term however the caller joins the tests.
		if arg.multiEntry and trigger["use_" .. arg.name .. "2"] then
			local op2 = safeOp(trigger[arg.name .. "2_operator"] or "<=")
			return string.format("(%s and (%s %s %s))", test, arg.name, op2,
				fmt(trigger[arg.name .. "2"] or 0))
		end
		return test
	elseif arg.type == "select" then
		if not arg.required and not trigger["use_" .. arg.name] then return nil end
		return string.format("(%s == %s)", arg.name, fmt(trigger[arg.name]))
	elseif arg.type == "multiselect" then
		local src = multiSelectSource(trigger, arg.name, arg.name)
		return src and ("(" .. src .. ")") or nil
	elseif arg.type == "list" then
		if not arg.required and not trigger["use_" .. arg.name] then return nil end
		return "(" .. listSource(arg, trigger[arg.name]) .. ")"
	elseif arg.type == "tristate" then
		-- Upstream's three-way flag lives in use_<name> alone: nil ignores the
		-- field, true requires it, false requires its absence. The field itself
		-- is a local the init fills, not a setting.
		local use = trigger["use_" .. arg.name]
		if use == true then return "(" .. arg.name .. ")" end
		if use == false then return "(not " .. arg.name .. ")" end
		return nil
	elseif arg.type == "string" then
		if not arg.required and not trigger["use_" .. arg.name] then return nil end
		local op = trigger[arg.name .. "_operator"] or "=="
		local val = fmt(trigger[arg.name] or "")
		-- find/notfind are plain substring searches (find's 4th argument), not Lua
		-- patterns: spell and unit names carry magic characters the user should not
		-- have to escape. Both sides lowered so matching is case-insensitive, and
		-- the nil guard matters because a stored name is nil until its unit exists.
		if op == "find" then
			return string.format("(%s ~= nil and string.find(string.lower(%s), string.lower(%s), 1, true) ~= nil)",
				arg.name, arg.name, val)
		elseif op == "notfind" then
			return string.format("(%s == nil or string.find(string.lower(%s), string.lower(%s), 1, true) == nil)",
				arg.name, arg.name, val)
		elseif op == "~=" then
			return string.format("(%s ~= %s)", arg.name, val)
		end
		return string.format("(%s == %s)", arg.name, val)
	end
	return nil
end

-- Compiles prototype+trigger into one test function (§4.2). Signature
-- (state, event, arg1..arg12): the status prototypes re-read live game state in
-- `init` and ignore the event args, but the parameters carry the firing event's
-- real payload, so a prototype can test against it instead of re-polling.
-- Dispatch carries nine; only a chat event fills arg10..arg12 (runTriggerCode).
local function constructFunction(proto, trigger, errTag)
	local lines = {}
	table.insert(lines, "return function(state, event, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9, arg10, arg11, arg12)")
	if proto.init then
		table.insert(lines, proto.init(trigger))
	end
	for i = 1, #proto.args do
		local arg = proto.args[i]
		if arg.init then
			table.insert(lines, string.format("local %s = %s", arg.name, arg.init))
		end
	end

	local tests = {}
	for i = 1, #proto.args do
		local arg = proto.args[i]
		-- An arg whose enable() is false is not part of this configuration (the
		-- editor omits its control), so its test is left out too: a use_<name>
		-- left on from an earlier mode would otherwise compile a comparison
		-- against a local the current mode never fills.
		if not (arg.enable and not arg.enable(trigger)) then
			local t = constructArgTest(arg, trigger)
			if t then table.insert(tests, t) end
		end
	end
	local cond = #tests > 0 and table.concat(tests, " and ") or "true"

	for i = 1, #proto.args do
		local arg = proto.args[i]
		if arg.store and arg.storeAlways then
			table.insert(lines, string.format(
				"if state.%s ~= %s then state.%s = %s state.changed = true end",
				arg.name, arg.name, arg.name, arg.name))
		end
	end
	table.insert(lines, "if (" .. cond .. ") then")
	for i = 1, #proto.args do
		local arg = proto.args[i]
		if arg.store and not arg.storeAlways then
			table.insert(lines, string.format(
				"if state.%s ~= %s then state.%s = %s state.changed = true end",
				arg.name, arg.name, arg.name, arg.name))
		end
	end
	table.insert(lines, "return true else return false end")
	table.insert(lines, "end")

	local source = table.concat(lines, "\n")
	-- Engine-generated, so it keeps the real globals: the sandbox belongs to the
	-- code's author, not to the call site. The source is already complete, `return
	-- function(...)` and all, which is why it goes through the builtin door.
	local fn, err = WA.LoadBuiltinFunction(source, errTag)
	return fn, source, err
end

-- Compiles a custom trigger's user text into a function.
-- The text is a whole function expression ("function(event, ...) ... end");
-- WA.LoadFunction owns the wrapper, the sandbox and the error report. Shape
-- mirrors constructFunction's return contract (fn, source, err).
local function constructCustomFunction(trigger, errTag)
	local body = trigger.custom or ""
	-- No source, no function, no complaint -- the same bargain compileCustomField
	-- makes. Picking the Custom category compiles before the editor has painted
	-- anything, and WA.LoadFunction refuses an empty body in the user's chat, so
	-- an untouched trigger would report an error against code it has not been
	-- given yet. It stays inert until there is something to run.
	if not string.find(body, "%S") then return nil, body end
	local fn, err = WA.LoadFunction(body, errTag)
	return fn, body, err
end

local function compileCustomField(source, errTag)
	if not source or not string.find(source, "%S") then return nil end
	return WA.LoadFunction(source, errTag)
end

-- Whether one of a custom trigger's code fields is code the compile below
-- actually reaches. Asked of the trigger table alone, so the import review can
-- put the same question to a payload it has never compiled and get the
-- compiler's own answer. `key` is the field name, except that "untrigger"
-- stands for the untrigger block's `custom` -- which is the trigger's setting to
-- decide, not the block's. `customTexture`, `customStacks` and `customOverlay*`
-- arrive from WeakAuras and are read by nothing here, so they are never live.
--
-- A Trigger State Updater carries its own progress, name, icon and hiding, so
-- its auxiliary fields are not compiled at all rather than compiled and left
-- unread -- two sources for one value is what the editor hides in that mode.
function WA.TriggerCodeIsLive(trigger, key)
	if type(trigger) ~= "table" or trigger.type ~= "custom" then return false end
	local tsu = trigger.custom_type == "stateupdate"
	if key == "custom" then return true end
	if key == "customVariables" then return tsu end
	if tsu then return false end
	if key == "untrigger" then
		return trigger.custom_type == "status"
			or (trigger.custom_type == "event" and trigger.custom_hide == "custom")
	end
	if key == "customDuration" then
		return trigger.custom_type ~= "event" or trigger.custom_hide == "custom"
	end
	return key == "customName" or key == "customIcon"
end

-- A Trigger State Updater's `customVariables` text is a table *expression*, not a
-- function, so it is wrapped into one that returns it. The newlines around the
-- body keep a trailing comment from swallowing the closing `end`.
local function compileTsuVariables(source, errTag)
	if not source or not string.find(source, "%S") then return nil end
	return WA.LoadFunction("function() return \n" .. source .. "\n end", errTag)
end

local function trueFunction() return true end

-- Resolves a "spell" field's stored value -- a numeric spellID, or a name the
-- user typed -- to a numeric spellID, or nil if it doesn't resolve to
-- anything (yet). Numeric input is trusted as-is and never round-tripped
-- through a lookup: the legacy GetSpellInfo(spellID) works for *any* spell
-- ID, known or not (ref ClassicAPI docs §Spell), so a raw ID the player
-- hasn't learned still resolves. A name resolves against the player's own
-- spellbook only, so a name for a spell they don't have (wrong spelling, wrong
-- class, not yet learned) legitimately has no numeric ID to resolve to and this
-- returns nil.
--
-- Two name lookups, in this order. The book-name one has to come first: the
-- engine resolver behind C_Spell (FUN_RESOLVE_SPELL_NAME_TO_BOOK_ID, the same
-- chain CastSpellByName uses) reaches its lookup through the macro parser's
-- rank splitter, which reads a trailing parenthesised suffix as a "(Rank N)"
-- and strips it -- so a spell whose real name ends in parentheses, "Faerie Fire
-- (Feral)", never arrives intact and either misses or lands on the unsuffixed
-- spell of the same stem. C_Spell still has the last word for the "(Rank N)"
-- forms and the pet book, neither of which the player-book index carries.
function WA.ResolveSpellID(input)
	if input == nil or input == "" then return nil end
	local id = tonumber(input)
	if id then return id end
	local bookId = WA.SpellIDByBookName(input)
	if bookId then return bookId end
	local info = C_Spell.GetSpellInfo(input)
	if info and info.spellID then return info.spellID end
	noteUnresolved(input, WA.ResolveSpellID)
	return nil
end

-- Resolves an "item" field's stored value (a numeric itemID, or a name/
-- link the user typed) to a numeric itemID, or nil if it doesn't resolve to
-- anything (yet -- an uncached name needs the client to have seen the item
-- once, same GetItemInfo caveat as any other addon). No plain-Lua item-name-
-- >ID API exists, so a name resolves through GetItemInfo's link return and a
-- string.find capture (this client's Lua 5.0 has no string.match, ref
-- TextReplace.lua).
-- ---------------------------------------------------------------------------
-- The spellbook, indexed by name. The global cooldown is read off a slot because
-- there is no GCD spellID to query, and Debug.lua's /wa cdprobe reads slots to
-- show what each rank of a name reports. Ranks of a name occupy consecutive
-- ascending slots, so the last write wins and the index holds the highest rank
-- (the same rank walk DoiteAuras does before its own GetSpellCooldown calls).
-- ---------------------------------------------------------------------------

do -- scoped; see the local-ceiling note in the file header

local spellSlotByName, spellSlotById, exactSlotById

local function buildSpellSlotIndex()
	spellSlotByName, spellSlotById = {}, {}
	for tab = 1, GetNumSpellTabs() do
		local _, _, offset, numSlots = GetSpellTabInfo(tab)
		if offset and numSlots then
			for i = offset + 1, offset + numSlots do
				local name = GetSpellName(i, BOOKTYPE_SPELL or "spell")
				if name then spellSlotByName[name] = i end
			end
		end
	end
end

function WA.InvalidateSpellSlots()
	spellSlotByName, spellSlotById, exactSlotById = nil, nil, nil
end

-- Slot numbers shift as the book grows, so every cached one stops meaning
-- anything. Registered here rather than on a consumer's frame: the per-spell
-- cooldown watcher depends on this index whether or not anything is watching the
-- global cooldown.
local spellBookFrame = CreateFrame("Frame")
pcall(spellBookFrame.RegisterEvent, spellBookFrame, "SPELLS_CHANGED")
pcall(spellBookFrame.RegisterEvent, spellBookFrame, "LEARNED_SPELL_IN_TAB")
spellBookFrame:SetScript("OnEvent", WA.InvalidateSpellSlots)

function WA.SpellSlotByName(name)
	if not name then return nil end
	if not spellSlotByName then buildSpellSlotIndex() end
	return spellSlotByName[name]
end

-- spellID for a name that appears verbatim in the player's book, or nil. The
-- index holds the highest known rank, which is both the rank a bare name means
-- everywhere else and the one that carries the cooldown.
function WA.SpellIDByBookName(name)
	local slot = WA.SpellSlotByName(name)
	if not slot then return nil end
	local ok, _, _, _, _, _, _, _, _, _, id = pcall(GetSpellInfo, slot, BOOKTYPE_SPELL or "spell")
	if not ok then return nil end
	return id
end

-- Slot for a spellID, via its name -- so a specific rank's ID still lands on the
-- book's highest rank, which is what actually goes on cooldown.
function WA.SpellSlotByID(spellId)
	if not spellId or spellId == 0 then return nil end
	if not spellSlotById then
		if not spellSlotByName then buildSpellSlotIndex() end
		spellSlotById = {}
	end
	local hit = spellSlotById[spellId]
	if hit ~= nil then return hit or nil end
	local name = C_Spell.GetSpellName(spellId)
	local slot = name and spellSlotByName[name]
	spellSlotById[spellId] = slot or false
	return slot
end

-- The slot holding exactly this spellID -- this rank, not the name's highest --
-- or nil when that rank has no button in the player's book.
function WA.ExactSpellSlot(spellId)
	if not spellId or spellId == 0 then return nil end
	if not exactSlotById then exactSlotById = {} end
	local hit = exactSlotById[spellId]
	if hit == nil then
		local slot, book = FindSpellBookSlotByID(spellId)
		hit = (slot and book == (BOOKTYPE_SPELL or "spell")) and slot or false
		exactSlotById[spellId] = hit
	end
	return hit or nil
end

-- (start, duration) off a spellbook slot, or nil. pcall'd: a slot that has gone
-- out of range (the book shrank) raises rather than answering.
function WA.SpellSlotCooldown(slot)
	if not slot then return nil end
	local ok, start, duration = pcall(GetSpellCooldown, slot, BOOKTYPE_SPELL or "spell")
	if not ok or not start or not duration then return nil end
	return start, duration
end

-- Whether the player has actually learned this spell. Two reads because neither
-- alone is enough: IsPlayerSpell answers off the engine's knowledge bitmap,
-- which holds one bit per spellID and so recognises only the *exact* rank
-- learned -- a display pointed at a lower-rank ID (what a WA2 pack that stored
-- one carries) would read as unknown -- while the book walk resolves the ID
-- through its name onto whichever rank is in the book, but sees nothing that
-- has no spellbook button.
function WA.SpellIsKnown(spellId)
	if not spellId or spellId == 0 then return false end
	if IsPlayerSpell(spellId) then return true end
	return WA.SpellSlotByID(spellId) ~= nil
end

end -- spellbook index

-- itemID for a name the user typed, found by walking the player's own
-- containers. Nothing on this client resolves a name: C_Item.GetItemCount and
-- C_Item.GetItemInfo both take an id, an "item:N" string or a link, and say so
-- explicitly -- so an item named rather than linked can only be identified by
-- finding one you hold. A hit is memoized for good (an id never stops belonging
-- to a name); a miss is only rate-limited, since the item may simply not be
-- carried yet and looting one must start working without a reload.

do -- scoped; see the local-ceiling note in the file header

local itemIdByName = {}
local itemNameMissAt = {}
local ITEM_NAME_RESCAN = 0.5

-- Bags the scan walks. GetContainerItemID documents 0 (backpack) and 1..4
-- (equipped bags); the bank indices are tried anyway because the count call
-- reads the bank cold here, and an unsupported index just answers nil.
local SCAN_BAGS = { 0, 1, 2, 3, 4, -1, 5, 6, 7, 8, 9, 10 }

function WA.ItemIDByName(name)
	if not name or name == "" then return nil end
	local lname = string.lower(name)
	if itemIdByName[lname] then return itemIdByName[lname] end
	local last = itemNameMissAt[lname]
	if last and (GetTime() - last) < ITEM_NAME_RESCAN then return nil end

	local function matches(id)
		if not id then return nil end
		local n = C_Item.GetItemNameByID(id)
		if n and string.lower(n) == lname then return id end
		return nil
	end
	local function remember(id)
		itemIdByName[lname] = id
		itemNameMissAt[lname] = nil
		return id
	end

	-- Equipped first: cheapest, and the one place a bag walk cannot look.
	for slot = 1, 19 do
		local hit = matches(GetInventoryItemID("player", slot))
		if hit then return remember(hit) end
	end
	for i = 1, #SCAN_BAGS do
		local bag = SCAN_BAGS[i]
		for slot = 1, GetContainerNumSlots(bag) do
			local hit = matches(C_Container.GetContainerItemID(bag, slot))
			if hit then return remember(hit) end
		end
	end

	itemNameMissAt[lname] = GetTime()
	return nil
end

-- A name that missed can only start resolving once the player is carrying one,
-- and the id a miss baked into a trigger's compiled source is not revisited on
-- its own. GET_ITEM_INFO_RECEIVED (OptionsFrame.lua's recompile hook) covers an
-- item whose *static data* had not arrived; it does not fire for an item already
-- in the client's cache that simply was not in a bag yet, which is what this
-- covers. Shaped after upstream's itemDataLoadFrame: the retry only walks while
-- a name is outstanding, and a name that starts resolving recompiles.
local itemNameRetryFrame = CreateFrame("Frame")
pcall(itemNameRetryFrame.RegisterEvent, itemNameRetryFrame, "BAG_UPDATE")
itemNameRetryFrame:SetScript("OnEvent", function()
	local retry
	for lname in pairs(itemNameMissAt) do
		retry = retry or {}
		table.insert(retry, lname)
	end
	if not retry then return end
	local resolved = false
	for i = 1, #retry do
		-- Clear the rate-limit stamp: a bag change is exactly the event that can
		-- make this walk succeed, so it should not be waited out.
		itemNameMissAt[retry[i]] = nil
		if WA.ItemIDByName(retry[i]) then resolved = true end
	end
	if resolved then WA.RecompileResolvedNames() end
end)

end -- item-name cache

function WA.ResolveItemID(input)
	if input == nil or input == "" then return nil end
	local id = tonumber(input)
	if id then return id end
	-- A shift-clicked link (or any "item:N" string) carries the id outright,
	-- which is the one form needing neither the item cache nor a scan.
	local _, _, linkId = string.find(input, "item:(%d+)")
	if linkId then return tonumber(linkId) end
	local name, link = GetItemInfo(input)
	if link then
		local _, _, capturedId = string.find(link, "item:(%d+)")
		local id2 = capturedId and tonumber(capturedId)
		if id2 then return id2 end
	end
	local byName = WA.ItemIDByName(input)
	if byName == nil then noteUnresolved(input, WA.ResolveItemID) end
	return byName
end

-- Inspect the player's equipment and return the first matching item's details.
-- GetItemInfoInstant is cache-only: an ID can be present while its class data
-- is unavailable, so an uncached item is equipped but cannot match a type.
-- `wantedSubclasses` is a set of subclass ids, or nil for any subclass of the
-- class -- one weapon *type* is rarely what a user means, where "a one-hander"
-- is several of them.
function WA.ItemTypeEquipped(wantedClassID, wantedSubclasses, selectedSlot)
	local firstSeen
	local firstID, firstName, firstIcon, firstClass, firstSubclass
	local firstClassID, firstSubclassID, firstKnown
	local matchingID, matchingName, matchingIcon, matchingClass, matchingSubclass
	local matchingClassID, matchingSubclassID
	local equipped = false
	local startSlot, endSlot = 1, 19
	if selectedSlot and tonumber(selectedSlot) and tonumber(selectedSlot) > 0 then
		startSlot, endSlot = tonumber(selectedSlot), tonumber(selectedSlot)
	end
	for slot = startSlot, endSlot do
		local id = GetInventoryItemID("player", slot)
		if id then
			equipped = true
			local itemID, itemClass, itemSubclass, _, itemIcon, classID, subclassID = C_Item.GetItemInfoInstant(id)
			local known = itemID and classID ~= nil and subclassID ~= nil
			if not firstSeen then firstID = itemID or id end
			if known then
				local itemName, _, _, _, _, _, _, _, _, cachedIcon = C_Item.GetItemInfo(itemID)
				itemIcon = itemIcon or cachedIcon
				if not firstKnown and not firstSeen then
					firstName, firstIcon = itemName, itemIcon
					firstClass, firstSubclass = itemClass, itemSubclass
					firstClassID, firstSubclassID, firstKnown = classID, subclassID, true
				end
				local subclassMatches = wantedSubclasses == nil or wantedSubclasses[subclassID]
				if not matchingID and classID == tonumber(wantedClassID) and subclassMatches then
					matchingID, matchingName, matchingIcon = itemID, itemName, itemIcon
					matchingClass, matchingSubclass = itemClass, itemSubclass
					matchingClassID, matchingSubclassID = classID, subclassID
				end
			elseif not firstSeen then
				firstID = itemID or id
			end
			firstSeen = true
		end
	end
	if matchingID then
		return matchingID, matchingName, matchingIcon, matchingClass, matchingSubclass,
			matchingClassID, matchingSubclassID, equipped, true, true
	end
	return firstID, firstName, firstIcon, firstClass, firstSubclass,
		firstClassID, firstSubclassID, equipped, false, firstKnown and true or false
end

function WA.ItemSetEquipped(setID)
	local targetID = tonumber(setID) or 0
	local total = 18
	local count = 0
	local setName
	local known = false
	local info = C_Item.GetItemSetInfo(targetID)
	if info then
		setName = info.name
		known = true
	end
	if targetID > 0 then
		for slot = 1, 18 do
			local itemID = GetInventoryItemID("player", slot)
			local equippedSetID = itemID and C_Item.GetItemSetIDByID(itemID)
			if equippedSetID == targetID then count = count + 1 end
		end
	end
	return count, total, setName, known
end

function WA.EquipmentSetInfo(setName, partial)
	setName = setName or ""
	local setID = C_EquipmentSet.GetEquipmentSetID(setName)
	if setID then
		local name, icon, _, isEquipped, numItems, numEquipped, _, _, numIgnored =
			C_EquipmentSet.GetEquipmentSetInfo(setID)
		if name then
			numItems = tonumber(numItems) or 0
			numEquipped = tonumber(numEquipped) or 0
			numIgnored = tonumber(numIgnored) or 0
			local active = (partial and numItems > 0 and numEquipped > 0)
				or ((not partial) and isEquipped and true or false)
			return name, icon, numEquipped, numItems, active and true or false, setID, numIgnored
		end
	end

	-- ItemRack is name-keyed and has no numeric set ID. Prefer the
	-- ClassicAPI/pfUI set when both systems contain the same name.
	if ItemRack_GetUserSets then
		local sets = ItemRack_GetUserSets()
		local set = sets and sets[setName]
		if set then
			local total, count = 0, 0
			for slot = 0, 19 do
				local entry = set[slot]
				if entry then
					total = total + 1
					local equippedID = GetInventoryItemID("player", slot)
					if equippedID and tonumber(entry.id) == tonumber(equippedID) then count = count + 1 end
				end
			end
			local active
			if partial then active = total > 0 and count > 0
			elseif ItemRack_IsSetEquipped then active = ItemRack_IsSetEquipped(setName) and true or false
			else active = total > 0 and count == total end
			return setName, set.icon, count, total, active and true or false, nil, 0
		end
	end
	return nil, nil, 0, 0, false
end

-- How many of an item the player holds, plus whether the item was identified at
-- all. Resolved at run time rather than baked into the generated source like
-- other trigger constants: an item can be configured long before one is ever
-- carried, and a typed name only becomes resolvable once one is found.
function WA.ItemCount(input, includeBank)
	local id = WA.ResolveItemID(input)
	if not id then return 0, false end
	return C_Item.GetItemCount(id, includeBank and true or false) or 0, true
end

-- Bool condition/filter for "is `unit` in range of this spell", unit defaulting
-- to "target" for the spell-cooldown caller. SpellHasRange gates self-buffs and
-- other unrestricted spells to always-true rather than gating on a unit the
-- spell was never range-limited against; IsSpellInRange is the engine's own
-- per-spell range check, melee and minimum range included. Real Lua (not
-- generated source) since neither call needs per-trigger config.
function WA.SpellInRange(spellId, unit)
	unit = unit or "target"
	if not C_Spell.SpellHasRange(spellId) then return true end
	if not UnitExists(unit) then return false end
	return C_Spell.IsSpellInRange(spellId, unit) == true
end

-- IsUsableSpell covers cast requirements but not proc state. When a spell is
-- present on a direct action-bar slot, IsUsableAction includes that state (for
-- example, Overpower after a dodge); spells without such a slot keep the
-- spell-level fallback used by the upstream trigger.
function WA.ActionUsability(spellId)
	if GetActionInfo and IsUsableAction then
		for slot = 1, 120 do
			local actionType, actionId = GetActionInfo(slot)
			if actionType == "spell" and actionId == spellId then
				local usable, insufficientResources = IsUsableAction(slot)
				return usable and true or false, insufficientResources and true or false
			end
		end
	end
	local usable, insufficientResources = IsUsableSpell(spellId)
	return usable and true or false, insufficientResources and true or false
end

-- The unit token a trigger actually targets: the dropdown's choice, or the
-- free-text override when the dropdown's "specific" entry is selected (raid17,
-- partyN, or a GUID). Resolved at compile time and baked into the
-- generated source, like every other trigger constant.
function WA.TriggerUnit(trigger, fallback)
	if trigger.unit == "specific" then
		if trigger.specificUnit and trigger.specificUnit ~= "" then
			return trigger.specificUnit
		end
		return fallback or "player"
	end
	return trigger.unit or fallback or "player"
end

-- GetItemInfo's classic 14-tuple; only name (1st) and icon (10th) matter to
-- the item-keyed prototypes below.
-- C_Item.GetItemInfo, not the stock global: the global answers vanilla's short
-- tuple, which has no itemLevel and so puts the texture one slot earlier than
-- the modern 18-value shape documents. Reading position 10 off the global gets
-- nil, which is why an item trigger drew no icon.
local function itemNameIcon(id)
	if not id then return nil, nil end
	local name, _, _, _, _, _, _, _, _, icon = C_Item.GetItemInfo(id)
	return name, icon
end

-- Shared 1s heartbeat: some status prototypes hold a value that depletes with no
-- natural game event (a weapon enchant's remaining time, a crowd-control debuff's
-- countdown-to-expiry). They list "WA_SLOW_TICK" in their events and call this in
-- loadFunc; the ticker starts once and re-dispatches through ScanEvents so those
-- triggers re-read live state ~1x/sec (the region itself animates the countdown;
-- this is only to flip show=false at expiry and re-detect a fresh application).
local slowTicker
function WA.EnsureSlowTick()
	if not slowTicker then
		slowTicker = C_Timer.NewTicker(1, function() WA.ScanEvents("WA_SLOW_TICK") end)
	end
end

-- ---------------------------------------------------------------------------
-- The unit-token watcher (§4.4 WatchUnitChange)
--
-- A single-token trigger reads whatever `target`/`focus`/`mouseover`/... points
-- at right now, and nothing in the game announces "that token moved" in a form
-- a prototype can list: PLAYER_TARGET_CHANGED says the token, not the trigger.
-- So the occupancy half lives here once, for every unit prototype, and reaches
-- them as WA_UNIT_CHANGED_<token> through the ordinary dispatch. A multi-unit
-- family gets its churn from appendMultiUnitEvents instead and never enters
-- this set.
-- ---------------------------------------------------------------------------

do -- scoped; see the local-ceiling note in the file header

-- Tokens whose occupancy the client announces. `player` is here because it
-- never moves at all. Everything else -- the derived-target tokens, and
-- whatever `specific` names -- is polled: UNIT_TARGET exists on no ClassicAPI
-- surface and in no sibling addon, so there is nothing to listen to.
local EVENTED_UNIT_TOKENS = {
	player = true, target = true, focus = true, pet = true, mouseover = true,
}

-- Nameplate churn is a wake as much as the occupancy events are: a `nameplateN`
-- token's creature changes with the plate, and a monitor re-resolving a frame
-- has to hear about a recycled plate.
local UNIT_WATCH_EVENTS = {
	"PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED", "UNIT_PET",
	"UPDATE_MOUSEOVER_UNIT", "PLAYER_ENTERING_WORLD",
	"NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED",
}

-- "This token points at nothing" as a value rather than as an absent key, so
-- tokenGuid's keys stay exactly the watch set and the diff below needs no nil
-- case of its own. No GUID can equal it.
local NO_UNIT = "\0"

local watchedTokens = {}   -- token -> refcount, held while an aura naming it is loaded
local polledTokens = {}    -- the watched tokens with no occupancy event
local tokenGuid = {}       -- token -> last seen GUID, or NO_UNIT
local watchCallbacks = {}
local unitWatchFrame
local diffScratch = {}

local function diffUnitToken(token)
	local guid = UnitGUID(token) or NO_UNIT
	if tokenGuid[token] == guid then return end
	tokenGuid[token] = guid
	-- The GUID, not the event, is what defines a change: a target-to-target
	-- swap, an emptied token and a refilled one all come out here, and an event
	-- that fires spuriously costs nothing.
	WA.ScanEvents(UNIT_CHANGED_PREFIX .. token, token)
end

-- Dispatch can load, unload or delete a display, which rewrites the watch set
-- mid-walk; the tokens are copied out first so `next` is never resumed from a
-- key that has since gone. The scratch table is reused -- a tick that changes
-- nothing must not allocate.
local function diffUnitTokens(set)
	local n = 0
	for token in pairs(set) do n = n + 1; diffScratch[n] = token end
	for i = 1, n do diffUnitToken(diffScratch[i]) end
end

local function runWatchCallbacks()
	for i = 1, #watchCallbacks do
		WA.safecall("unit watch callback", watchCallbacks[i])
	end
end

local function ensureUnitWatchFrame()
	if unitWatchFrame then return end
	unitWatchFrame = CreateFrame("Frame")
	for i = 1, #UNIT_WATCH_EVENTS do
		-- Guarded on the same grounds as ensureEventRegistered's: an event name
		-- this build does not know must not error out the load that asked for it.
		pcall(unitWatchFrame.RegisterEvent, unitWatchFrame, UNIT_WATCH_EVENTS[i])
	end
	unitWatchFrame:SetScript("OnEvent", function()
		diffUnitTokens(watchedTokens)
		runWatchCallbacks()
	end)
end

-- The polled half. The fast tick below is its only caller in game; it is public
-- because a headless run has to drive it directly, a ticker created at load
-- being unpaceable there.
function WA.PollUnitTokens()
	diffUnitTokens(polledTokens)
	runWatchCallbacks()
end

-- Start watching `token`, refcounted. The count is what makes this safe across
-- load transitions: loadFunc-style accumulation would poll every token an aura
-- ever selected for the rest of the session, since nothing unloads it again.
-- LoadDisplays and unregisterEvents own the pairing, off the same event list
-- loaded_events is keyed by.
function WA.WatchUnitToken(token)
	if not token or token == "" then return end
	local count = watchedTokens[token]
	watchedTokens[token] = (count or 0) + 1
	if count then return end
	-- Seeded rather than dispatched: LoadDisplays' own force_events pass is what
	-- gives the new trigger its first read.
	tokenGuid[token] = UnitGUID(token) or NO_UNIT
	ensureUnitWatchFrame()
	if not EVENTED_UNIT_TOKENS[token] then
		polledTokens[token] = true
		WA.EnsureFastTick()
	end
end

function WA.UnwatchUnitToken(token)
	local count = watchedTokens[token]
	if not count then return end
	if count > 1 then watchedTokens[token] = count - 1; return end
	watchedTokens[token] = nil
	polledTokens[token] = nil
	tokenGuid[token] = nil
end

-- What the watcher holds for one token: how many loaded triggers name it, and
-- whether it rides the poll rather than an event.
function WA.UnitTokenWatch(token)
	return watchedTokens[token] or 0, polledTokens[token] and true or false
end

-- Anything that resolves a live token to a frame and must re-resolve when the
-- token moves -- an external glow on a unit frame or a plate. Called on every
-- wake, event or tick, because the caller's token comes from a region's state
-- rather than from the watch set.
function WA.RegisterUnitWatchCallback(fn)
	table.insert(watchCallbacks, fn)
	ensureUnitWatchFrame()
end

end -- unit-token watcher

-- Shared 0.1s heartbeat for status prototypes tracking a fast-moving value
-- (range to a unit), and the carrier for the polled tokens above. Started
-- lazily by WA.EnsureFastTick when such a trigger loads and never cancelled; a
-- range readout wants smoother than the 1s slow tick, and 0.1s is cheap because
-- ScanEvents early-outs on an event no trigger is registered for and the poll
-- walks an empty set until something enrols.
local fastTicker
function WA.EnsureFastTick()
	if not fastTicker then
		fastTicker = C_Timer.NewTicker(0.1, function()
			WA.PollUnitTokens()
			WA.ScanEvents("WA_FAST_TICK")
		end)
	end
end

-- Temporary weapon enchant (oils/stones/poisons) for one hand. C_Item.
-- GetWeaponEnchantInfo returns a flat 12-tuple (main/off/ranged x has/expireMs/
-- charges/enchantID) -- captured whole via a plain multi-assign, never an
-- `and`-chain (which truncates multi-returns to one value on this client's Lua
-- 5.0). expireMs is remaining time in ms; the API gives no *original* duration.
-- The cached expiration is what is *returned*: expireMs is coarse, so
-- GetTime()+remaining wobbles between reads, and publishing the fresh value
-- re-armed the display's timer with a slightly different endpoint on every
-- poll. Within a 1s tolerance the timer holds still; past it the cache snaps
-- to the new value.
local weCache = {}

-- The original duration, learned: the only moment it is readable is an
-- application seen happening, when the remaining IS the full window (less the
-- poll's lag, which rounding to the 30s grid every vanilla enchant duration
-- sits on absorbs -- Quartermaster's curated table is 1800 on all but two
-- rows). Learned per enchantId, monotonic max -- a mid-life first sighting
-- stores its too-low remaining and the first watched application raises it for
-- good -- and persisted in the SavedVariables so a bar after /reload spans the
-- real window with the live remaining inside it, not a full bar of whatever
-- was left.
local function weLearnedDurations()
	if type(WeakestAurasDB) ~= "table" then return nil end
	if type(WeakestAurasDB.weaponEnchantDurations) ~= "table" then
		WeakestAurasDB.weaponEnchantDurations = {}
	end
	return WeakestAurasDB.weaponEnchantDurations
end

function WA.WeaponEnchantInfo(hand)
	local hM, eM, cM, idM, hO, eO, cO, idO, hR, eR, cR, idR = C_Item.GetWeaponEnchantInfo()
	local has, expireMs, enchantId
	if hand == "off" then has, expireMs, enchantId = hO, eO, idO
	elseif hand == "ranged" then has, expireMs, enchantId = hR, eR, idR
	else has, expireMs, enchantId = hM, eM, idM end
	if not has then weCache[hand] = nil; return false, 0, 0, nil end
	local remaining = (expireMs or 0) / 1000
	local expiration = GetTime() + remaining
	local c = weCache[hand]
	-- A new identity re-derives the window too: swapping oils mid-life must not
	-- leave the new enchant wearing the old one's duration.
	if not c or c.enchantId ~= enchantId or expiration > c.expiration + 2 then
		local durations = weLearnedDurations()
		local known = durations and enchantId and durations[enchantId]
		local rounded = math.floor((remaining + 15) / 30) * 30
		if durations and enchantId and rounded > 0 and rounded > (known or 0) then
			durations[enchantId] = rounded
			known = rounded
		end
		local duration = (known and known >= remaining) and known or remaining
		c = { expiration = expiration, duration = duration, enchantId = enchantId }
		weCache[hand] = c
	elseif math.abs(expiration - c.expiration) > 1 then
		c.expiration = expiration
	end
	return true, c.expiration, c.duration, enchantId
end

-- The enchant's own icon: the proc/use/equip spell C_Item.GetEnchantInfo names
-- for it (a poison's proc, an imbue's aura), read once per enchantId; vanilla
-- has no direct enchant->icon read. A spell-less enchant (sharpening stones are
-- flat weapon damage) falls back to the enchanted weapon's texture, read live
-- so a swap moves it.
local weIconCache = {}
local WE_ICON_SLOT = { main = 16, off = 17, ranged = 18 }
function WA.WeaponEnchantIcon(hand, enchantId)
	local icon = enchantId and weIconCache[enchantId]
	if icon == nil and enchantId then
		icon = false
		local info = C_Item.GetEnchantInfo(enchantId)
		if info then
			local spellId = info.spellID
			if not spellId and info.effects then
				for i = 1, #info.effects do
					local e = info.effects[i]
					if e and (e.type == 1 or e.type == 3 or e.type == 7) and e.arg then
						spellId = e.arg
						break
					end
				end
			end
			if spellId then
				icon = C_Spell.GetSpellTexture(spellId) or false
			end
		end
		weIconCache[enchantId] = icon
	end
	if icon then return icon end
	return GetInventoryItemTexture("player", WE_ICON_SLOT[hand] or 16)
end

-- Reputation standing for a named faction. Walks the displayed faction list
-- (headers skipped) since GetFactionInfoByID needs an ID the user doesn't know;
-- niche enough that an O(n) scan on the UPDATE_FACTION event is fine. barMin/
-- barMax/barValue bracket the current standing bar. nil when the faction isn't
-- in the player's list (not yet encountered).
function WA.FactionStanding(name)
	if not name or name == "" then return nil end
	for i = 1, GetNumFactions() do
		local fname, _, standingID, barMin, barMax, barValue, _, _, isHeader = GetFactionInfo(i)
		if not isHeader and fname == name then
			return standingID, barMin, barMax, barValue, fname
		end
	end
	return nil
end

-- The first active loss-of-control effect on the player that matches, or
-- (false, ...). A nil controlType matches any type; a SCHOOL_INTERRUPT match
-- can be narrowed to the schools in schoolMask. C_LossOfControl classifies from
-- the spell's own data and takes CC timing from the server's player aura timer.
-- A school lockout carries no spell, so it reports spellID 0 and the locked
-- schools as `school`.
function WA.PlayerLossOfControl(controlType, schoolMask)
	for i = 1, C_LossOfControl.GetActiveLossOfControlDataCount() do
		local d = C_LossOfControl.GetActiveLossOfControlData(i)
		if d and (not controlType or d.locType == controlType)
			and (not schoolMask or d.locType ~= "SCHOOL_INTERRUPT"
				or bit.band(d.lockoutSchool, schoolMask) ~= 0) then
			local school = d.lockoutSchool ~= 0 and C_Spell.GetSchoolString(d.lockoutSchool) or nil
			local expirationTime = d.timeRemaining and (GetTime() + d.timeRemaining) or 0
			local icon = d.iconTexture ~= "" and d.iconTexture or nil
			return true, d.locType, d.spellID, d.displayText, icon, expirationTime, d.duration or 0, school
		end
	end
	return false, nil, nil, nil, nil, 0, 0, nil
end

do -- scoped; see the local-ceiling note in the file header

-- The character-stat readers the charstats prototype's args call by key. One
-- entry point rather than inline API calls per arg: most of these are
-- multi-return with a discarded first value, which an arg `init` expression
-- cannot express on 5.0, and each reader guards its own API's absence once.
--
-- Four conventions here are not derivable from the call site:
--   * UnitAttackPower / UnitRangedAttackPower return base, posBuff, negBuff with
--     negBuff ALREADY NEGATIVE. Effective is base + pos + neg; subtracting it
--     counts every Curse of Weakness twice, in the wrong direction.
--   * UnitResistance's index is 0-based with 0 = armor, so the six schools are
--     1..6. (SuperCleveRoidMacros passes 3..7 for fire..arcane and is wrong.)
--   * GetSpellBonusDamage's school is 1-based with 1 = physical -- a different
--     base from UnitResistance's, for the same six schools.
--   * UnitArmor returns five values and the effective armor is the second;
--     UnitDefense returns base and modifier, which have to be summed.

local function primaryStat(index)
	local _, effective = UnitStat("player", index)
	return effective or 0
end

local function resistance(school)
	local _, total = UnitResistance("player", school)
	return total or 0
end

local function schoolPower(school)
	return GetSpellBonusDamage(school) or 0
end

local function effectiveAttackPower(fn)
	if not fn then return 0 end
	local base, pos, neg = fn("player")
	return (base or 0) + (pos or 0) + (neg or 0)
end

local function weaponSpeed(offHand)
	local main, off = UnitAttackSpeed("player")
	if offHand then return off or 0 end
	return main or 0
end

local STAT_READERS = {
	strength = function() return primaryStat(1) end,
	agility = function() return primaryStat(2) end,
	stamina = function() return primaryStat(3) end,
	intellect = function() return primaryStat(4) end,
	spirit = function() return primaryStat(5) end,

	attackPower = function() return effectiveAttackPower(UnitAttackPower) end,
	rangedAttackPower = function() return effectiveAttackPower(UnitRangedAttackPower) end,
	mainHandSpeed = function() return weaponSpeed(false) end,
	offHandSpeed = function() return weaponSpeed(true) end,

	-- The paperdoll's "spell damage" is the best school, not their sum, and
	-- physical (school 1) is not part of that comparison.
	spellPower = function()
		local best = 0
		for school = 2, 7 do
			local value = schoolPower(school)
			if value > best then best = value end
		end
		return best
	end,
	spellPowerHoly = function() return schoolPower(2) end,
	spellPowerFire = function() return schoolPower(3) end,
	spellPowerNature = function() return schoolPower(4) end,
	spellPowerFrost = function() return schoolPower(5) end,
	spellPowerShadow = function() return schoolPower(6) end,
	spellPowerArcane = function() return schoolPower(7) end,
	healingPower = function()
		return GetSpellBonusHealing() or 0
	end,
	spellHaste = function()
		return UnitSpellHaste("player") or 0
	end,

	armor = function()
		local _, effective = UnitArmor("player")
		return effective or 0
	end,
	defense = function()
		local base, modifier = UnitDefense("player")
		return (base or 0) + (modifier or 0)
	end,
	dodge = function() return GetDodgeChance() or 0 end,
	parry = function() return GetParryChance() or 0 end,
	block = function() return GetBlockChance() or 0 end,

	resistHoly = function() return resistance(1) end,
	resistFire = function() return resistance(2) end,
	resistNature = function() return resistance(3) end,
	resistFrost = function() return resistance(4) end,
	resistShadow = function() return resistance(5) end,
	resistArcane = function() return resistance(6) end,
}

-- One player stat by key, 0 for anything this client cannot answer. Called from
-- generated trigger code, so an unknown key returns a number rather than
-- erroring the whole compiled test.
function WA.CharacterStat(key)
	local reader = STAT_READERS[key]
	if not reader then return 0 end
	return reader() or 0
end

end

-- ---------------------------------------------------------------------------
-- Prototypes (§4). Each = one table; adding a category never touches the
-- system code above or below.
-- ---------------------------------------------------------------------------

local PROTOTYPES = {}

-- A saved trigger field written under an older name, moved in place. Reached
-- through the trigger type's `migrate` hook, which MergeDefaults runs on every
-- load before seeding defaults -- so it has to stay idempotent and must not
-- overwrite a value already stored under the new name.
local function renameArg(trigger, old, new)
	if trigger[old] == nil then return end
	if trigger[new] == nil then trigger[new] = trigger[old] end
	trigger[old] = nil
end

local COMBAT_EVENT_VALUES = { "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" }
local COMBAT_EVENT_LABELS = {
	PLAYER_REGEN_DISABLED = "Entering Combat",
	PLAYER_REGEN_ENABLED = "Leaving Combat",
}
local CHAT_MESSAGE_VALUES = {
	"CHAT_MSG_SAY", "CHAT_MSG_PARTY", "CHAT_MSG_RAID", "CHAT_MSG_GUILD",
	"CHAT_MSG_OFFICER", "CHAT_MSG_YELL", "CHAT_MSG_WHISPER", "CHAT_MSG_EMOTE",
	"CHAT_MSG_SYSTEM", "CHAT_MSG_MONSTER_SAY",
	"CHAT_MSG_MONSTER_YELL", "CHAT_MSG_MONSTER_WHISPER", "CHAT_MSG_MONSTER_EMOTE",
	"CHAT_MSG_CHANNEL", "CHAT_MSG_LOOT", "CHAT_MSG_RAID_WARNING",
	"CHAT_MSG_BG_SYSTEM_NEUTRAL", "CHAT_MSG_BG_SYSTEM_ALLIANCE", "CHAT_MSG_BG_SYSTEM_HORDE",
}
local CHAT_MESSAGE_LABELS = {}
for i = 1, #CHAT_MESSAGE_VALUES do
	local value = CHAT_MESSAGE_VALUES[i]
	CHAT_MESSAGE_LABELS[value] = string.sub(value, 10)
end
local CHAT_MESSAGE_ALL_EVENTS = {}
for i = 1, #CHAT_MESSAGE_VALUES do table.insert(CHAT_MESSAGE_ALL_EVENTS, CHAT_MESSAGE_VALUES[i]) end
table.insert(CHAT_MESSAGE_ALL_EVENTS, "CHAT_MSG_PARTY_LEADER")
table.insert(CHAT_MESSAGE_ALL_EVENTS, "CHAT_MSG_RAID_LEADER")
table.insert(CHAT_MESSAGE_ALL_EVENTS, "CHAT_MSG_TEXT_EMOTE")

local function chatMessageEvents(trigger)
	if trigger and trigger.use_messageType and trigger.messageType and CHAT_MESSAGE_LABELS[trigger.messageType] then
		local events = { trigger.messageType }
		if trigger.messageType == "CHAT_MSG_PARTY" then table.insert(events, "CHAT_MSG_PARTY_LEADER") end
		if trigger.messageType == "CHAT_MSG_RAID" then table.insert(events, "CHAT_MSG_RAID_LEADER") end
		if trigger.messageType == "CHAT_MSG_EMOTE" then table.insert(events, "CHAT_MSG_TEXT_EMOTE") end
		return events
	end
	return CHAT_MESSAGE_ALL_EVENTS
end

function WA.TalentInfo(wanted, wantedTab, wantedTier, wantedColumn)
	if not wanted or wanted == "" then return false, false, 0, 0, 0, 0, 0, nil, nil end
	local tabs = tonumber(GetNumTalentTabs()) or 0
	for tab = 1, tabs do
		if wantedTab == 0 or wantedTab == tab then
			local count = tonumber(GetNumTalents(tab)) or 0
			for index = 1, count do
				local name, icon, tier, column, rank, maxRank = GetTalentInfo(tab, index)
				if name == wanted
					and (wantedTier == 0 or tier == wantedTier)
					and (wantedColumn == 0 or column == wantedColumn) then
					return true, (tonumber(rank) or 0) > 0, tonumber(rank) or 0,
						tonumber(maxRank) or 0, tab, tonumber(tier) or 0, tonumber(column) or 0, icon
				end
			end
		end
	end
	return false, false, 0, 0, 0, 0, 0, nil, nil
end

function WA.PetBehavior()
	local slots = NUM_PET_ACTION_SLOTS or 10
	for index = 1, slots do
		local name, _, texture, token, active = GetPetActionInfo(index)
		if active and name then
			local behavior
			if name == "PET_MODE_AGGRESSIVE" then behavior = "aggressive"
			elseif name == "PET_MODE_ASSIST" then behavior = "assist"
			elseif name == "PET_MODE_DEFENSIVEASSIST" or name == "PET_MODE_DEFENSIVE" then behavior = "defensive"
			elseif name == "PET_MODE_PASSIVE" then behavior = "passive" end
			if behavior then
				if token and texture then texture = _G[texture] end
				return behavior, texture
			end
		end
	end
	return nil, nil
end

do -- scoped; see the local-ceiling note in the file header

local TALENT_TAB_VALUES = { 0, 1, 2, 3 }
local TALENT_TAB_LABELS = { [0] = "Any Tab", [1] = "Tab 1", [2] = "Tab 2", [3] = "Tab 3" }

local TALENT_RANK_VALUES = { "ignore", "known", "maxed" }
local TALENT_RANK_LABELS = { ignore = "Any Rank", known = "Known (rank > 0)", maxed = "Max Rank" }

PROTOTYPES["talentknown"] = {
	displayName = "Talent Known",
	wa2Event = "Talent Known",
	category = "unit",
	progressType = "static",
	progressValue = "rank",
	progressTotal = "maxRank",
	events = function() return { "CHARACTER_POINTS_CHANGED", "SPELLS_CHANGED", "PLAYER_ENTERING_WORLD" } end,
	force_events = true,
	icon = "Interface\\Icons\\INV_Misc_Book_09",
	iconFunc = function() return "Interface\\Icons\\INV_Misc_Book_09" end,
	nameFunc = function(trigger) return trigger.talentName or "Talent Known" end,
	iconFunc = function(trigger)
		local _, _, _, _, _, _, _, icon = WA.TalentInfo(trigger.talentName,
			(trigger.usePlacement and tonumber(trigger.talentTab)) or 0,
			(trigger.usePlacement and tonumber(trigger.talentTier)) or 0,
			(trigger.usePlacement and tonumber(trigger.talentColumn)) or 0)
		return icon or "Interface\\Icons\\INV_Misc_Book_09"
	end,
	init = function(trigger)
		return "local talentFoundValue, knownValue, rankValue, maxRankValue, talentTabFoundValue, talentTierFoundValue, talentColumnFoundValue, talentIconValue = WeakestAuras.TalentInfo("
			.. fmt(trigger.talentName or "") .. ", " .. tostring(tonumber(trigger.talentTab) or 0) .. ", "
			.. tostring(tonumber(trigger.talentTier) or 0) .. ", " .. tostring(tonumber(trigger.talentColumn) or 0) .. ")"
	end,
	args = {
		{ name = "talentName", type = "talent", display = "Talent Name", required = true },
		{ name = "usePlacement", type = "toggle", display = "Advanced Placement Filters", default = false, reloadOptions = true },
		{ name = "talentTab", type = "select", required = true, display = "Talent Tab",
			valueList = TALENT_TAB_VALUES, valueLabels = TALENT_TAB_LABELS, default = 0,
			enable = function(trigger) return trigger.usePlacement end,
			reloadOptions = true, test = function() return nil end },
		{ name = "talentTier", type = "range", display = "Tier", min = 0, max = 10, step = 1, default = 0,
			enable = function(trigger) return trigger.usePlacement end,
			reloadOptions = true, test = function() return nil end },
		{ name = "talentColumn", type = "range", display = "Column", min = 0, max = 4, step = 1, default = 0,
			enable = function(trigger) return trigger.usePlacement end,
			reloadOptions = true, test = function() return nil end },
		{ name = "rankMode", type = "select", required = true, display = "Rank",
			valueList = TALENT_RANK_VALUES, valueLabels = TALENT_RANK_LABELS, default = "ignore", reloadOptions = true,
			test = function(trigger)
				if trigger.rankMode == "known" then return "(talentFound and known)" end
				if trigger.rankMode == "maxed" then return "(known and rank >= maxRank)" end
				return "talentFound"
			end },
		{ name = "talentFound", type = "hidden", init = "talentFoundValue", store = true, conditionType = "bool", display = "Talent Found" },
		{ name = "known", type = "hidden", init = "knownValue", store = true, conditionType = "bool", display = "Known" },
		{ name = "rank", type = "hidden", init = "rankValue", store = true, conditionType = "number", display = "Rank" },
		{ name = "maxRank", type = "hidden", init = "maxRankValue", store = true, conditionType = "number", display = "Max Rank" },
		{ name = "talentTabFound", type = "hidden", init = "talentTabFoundValue", store = true, conditionType = "number", display = "Tab" },
		{ name = "talentTierFound", type = "hidden", init = "talentTierFoundValue", store = true, conditionType = "number", display = "Tier" },
		{ name = "talentColumnFound", type = "hidden", init = "talentColumnFoundValue", store = true, conditionType = "number", display = "Column" },
		{ name = "icon", type = "hidden", init = "talentIconValue", store = true },
	},
}

end -- talent prototype

do -- scoped; see the local-ceiling note in the file header

local CONDITION_STATUS_LABELS = { ignore = "Ignore", ["true"] = "Yes", ["false"] = "No" }
local CONDITION_STATUS_VALUES = { "ignore", "true", "false" }

local function conditionStatusTest(name)
	return function(trigger)
		local value = trigger[name] or "ignore"
		if value == "ignore" then return nil end
		return value == "true" and name or "not " .. name
	end
end

local function addConditionEvent(events, seen, eventName)
	if not seen[eventName] then
		seen[eventName] = true
		table.insert(events, eventName)
	end
end

local function conditionEvents(trigger)
	local out, seen = {}, {}
	addConditionEvent(out, seen, "PLAYER_ENTERING_WORLD")
	if trigger.incombat ~= "ignore" then
		addConditionEvent(out, seen, "PLAYER_REGEN_ENABLED")
		addConditionEvent(out, seen, "PLAYER_REGEN_DISABLED")
	end
	if trigger.alive ~= "ignore" then
		addConditionEvent(out, seen, "PLAYER_DEAD")
		addConditionEvent(out, seen, "PLAYER_ALIVE")
		addConditionEvent(out, seen, "PLAYER_UNGHOST")
	end
	if trigger.onTaxi ~= "ignore" then
		addConditionEvent(out, seen, "PLAYER_CONTROL_LOST")
		addConditionEvent(out, seen, "PLAYER_CONTROL_GAINED")
	end
	if trigger.resting ~= "ignore" then
		addConditionEvent(out, seen, "PLAYER_UPDATE_RESTING")
	end
	if trigger.mounted ~= "ignore" then
		addConditionEvent(out, seen, "PLAYER_AURAS_CHANGED")
		addConditionEvent(out, seen, "PLAYER_MOUNT_DISPLAY_CHANGED")
	end
	if trigger.hasPet ~= "ignore" then
		addConditionEvent(out, seen, "UNIT_PET")
	end
	if trigger.isMoving ~= "ignore" then
		addConditionEvent(out, seen, "WA_FAST_TICK")
	end
	if trigger.afk ~= "ignore" or trigger.pvpFlagged ~= "ignore" then
		addConditionEvent(out, seen, "PLAYER_FLAGS_CHANGED")
	end
	if trigger.groupType ~= "ignore" then
		addConditionEvent(out, seen, "GROUP_ROSTER_UPDATE")
		addConditionEvent(out, seen, "PARTY_MEMBERS_CHANGED")
		addConditionEvent(out, seen, "RAID_ROSTER_UPDATE")
	end
	if trigger.instanceType ~= "ignore" then
		addConditionEvent(out, seen, "ZONE_CHANGED")
		addConditionEvent(out, seen, "ZONE_CHANGED_INDOORS")
		addConditionEvent(out, seen, "ZONE_CHANGED_NEW_AREA")
	end
	return out
end

local function conditionStatusArg(name, display, init)
	return { name = name, type = "select", required = true, display = display,
		valueList = CONDITION_STATUS_VALUES, valueLabels = CONDITION_STATUS_LABELS,
		default = "ignore", init = init, store = true, conditionType = "bool",
		test = conditionStatusTest(name) }
end

-- No "ignore" entry, and no "any": the mode tier owns being off, and "any group"
-- is the two-entry set { party, raid } rather than a third spelling of it.
local CONDITION_VALUE_LABELS = {
	groupType = { solo = "Solo", party = "Party", raid = "Raid" },
	instanceType = { none = "Outside Instance", dungeon = "Dungeon",
		raid = "Raid", pvp = "Battleground", arena = "Arena" },
}

local function conditionValueTest(name)
	return function(trigger)
		local src = multiSelectSource(trigger, name, name)
		return src and ("(" .. src .. ")") or nil
	end
end


function WA.ConditionGroupType()
	if IsInRaid() then return "raid" end
	if IsInGroup() then return "party" end
	return "solo"
end

function WA.ConditionInstanceType()
	local _, instanceType = GetInstanceInfo()
	if instanceType == "party" then return "dungeon" end
	return instanceType
end

local function conditionValueArg(name, display, values, labels, init)
	return { name = name, type = "multiselect", display = display,
		valueList = values, valueLabels = labels, default = values[1], init = init,
		test = conditionValueTest(name), store = true, conditionType = "string" }
end

PROTOTYPES["conditions"] = {
	displayName = "Conditions",
	wa2Event = "Conditions",
	category = "unit",
	progressType = "none",
	events = conditionEvents,
	force_events = true,
	loadFunc = function(trigger)
		if trigger.isMoving ~= "ignore" then WA.EnsureFastTick() end
	end,
	migrate = function(trigger)
		-- The two shapes these filters were saved in before they took a set:
		-- "ignore" inside the value list meant off, and "any" meant the
		-- party-or-raid pair the set now spells out.
		local function migrateValue(name)
			if trigger[name] == "ignore" then
				trigger[name] = nil
				trigger["use_" .. name] = false
			elseif name == "groupType" and trigger[name] == "any" then
				trigger[name] = nil
				trigger.use_groupType = "multi"
				trigger.groupType_multi = { party = true, raid = true }
			elseif trigger[name] ~= nil and trigger["use_" .. name] == nil then
				trigger["use_" .. name] = "single"
			end
			WA.MultiSelectMigrateGate(trigger, name)
		end
		migrateValue("groupType")
		migrateValue("instanceType")
	end,
	icon = "Interface\\Icons\\Spell_Holy_PowerInfusion",
	iconFunc = function() return "Interface\\Icons\\Spell_Holy_PowerInfusion" end,
	nameFunc = function() return "Conditions" end,
	init = function() return "" end,
	args = {
		conditionStatusArg("alwaystrue", "Always Active", "true"),
		conditionStatusArg("incombat", "In Combat", "UnitAffectingCombat(\"player\") and true or false"),
		conditionStatusArg("alive", "Alive", "(not UnitIsDeadOrGhost(\"player\")) and true or false"),
		conditionStatusArg("onTaxi", "On Taxi", "UnitOnTaxi(\"player\") and true or false"),
		conditionStatusArg("resting", "Resting", "IsResting() and true or false"),
		conditionStatusArg("mounted", "Mounted", "IsMounted() and true or false"),
		conditionStatusArg("hasPet", "Has Pet", "(UnitExists(\"pet\") and not UnitIsDeadOrGhost(\"pet\")) and true or false"),
		conditionStatusArg("isMoving", "Is Moving", "(GetUnitSpeed(\"player\") or 0) > 0"),
		conditionStatusArg("afk", "AFK", "UnitIsAFK(\"player\") and true or false"),
		conditionStatusArg("pvpFlagged", "PvP Flagged", "(UnitIsPVP(\"player\") or (UnitIsPVPFreeForAll(\"player\"))) and true or false"),
		conditionValueArg("groupType", "Group Type", { "solo", "party", "raid" }, CONDITION_VALUE_LABELS.groupType, "WeakestAuras.ConditionGroupType()"),
		conditionValueArg("instanceType", "Instance Type", { "none", "dungeon", "raid", "pvp", "arena" }, CONDITION_VALUE_LABELS.instanceType, "WeakestAuras.ConditionInstanceType()"),
	},
}

end -- conditions prototype

-- GetInstanceInfo's own instanceType strings. No "ignore" entry: the filter's
-- mode tier owns being off, where a sentinel inside the value list would be a
-- second way to say the same thing.
do -- scoped; see the local-ceiling note in the file header

local LOCATION_INSTANCE_VALUES = { "none", "party", "raid", "pvp", "arena" }
local LOCATION_INSTANCE_LABELS = { none = "Outside Instance", party = "Dungeon", raid = "Raid", pvp = "Battleground", arena = "Arena" }

PROTOTYPES["location"] = {
	displayName = "Location",
	wa2Event = "Location",
	category = "unit",
	progressType = "none",
	events = function() return { "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA", "MINIMAP_ZONE_CHANGED", "PLAYER_ENTERING_WORLD" } end,
	force_events = true,
	icon = "Interface\\Icons\\INV_Misc_Map_01",
	iconFunc = function() return "Interface\\Icons\\INV_Misc_Map_01" end,
	nameFunc = function() return "Location" end,
	migrate = function(trigger)
		-- The instance filter was one gated value with an "ignore" sentinel in
		-- its own list before it became a set; the sentinel is now the tier's
		-- off mode, and it is the value that has to move rather than the gate.
		if trigger.instanceTypeFilter == "ignore" then
			trigger.instanceTypeFilter = nil
			trigger.use_instanceTypeFilter = false
		end
		WA.MultiSelectMigrateGate(trigger, "instanceTypeFilter")
	end,
	init = function()
		return "local zoneValue = GetRealZoneText() or GetZoneText() or \"\"\n"
			.. "local subzoneValue = GetSubZoneText() or \"\"\n"
			.. "local instanceNameValue, instanceTypeValue = GetInstanceInfo()"
	end,
	args = {
		{ name = "zone", type = "hidden", display = "Zone", init = "zoneValue", store = true, conditionType = "string" },
		{ name = "subzone", type = "hidden", display = "Subzone", init = "subzoneValue", store = true, conditionType = "string" },
		{ name = "instanceName", type = "hidden", display = "Instance Name", init = "instanceNameValue", store = true, conditionType = "string" },
		{ name = "zoneFilter", type = "text", display = "Zone Filter", default = "", test = function(trigger)
			if not trigger.zoneFilter or trigger.zoneFilter == "" then return nil end
			return "string.lower(zoneValue) == string.lower(" .. fmt(trigger.zoneFilter) .. ")"
		end },
		{ name = "subzoneFilter", type = "text", display = "Subzone Filter", default = "", test = function(trigger)
			if not trigger.subzoneFilter or trigger.subzoneFilter == "" then return nil end
			return "string.lower(subzoneValue) == string.lower(" .. fmt(trigger.subzoneFilter) .. ")"
		end },
		{ name = "instanceNameFilter", type = "text", display = "Instance Name Filter", default = "", test = function(trigger)
			if not trigger.instanceNameFilter or trigger.instanceNameFilter == "" then return nil end
			return "string.lower(instanceNameValue) == string.lower(" .. fmt(trigger.instanceNameFilter) .. ")"
		end },
		{ name = "instanceType", type = "hidden", init = "instanceTypeValue", store = true, conditionType = "string", display = "Instance Type" },
		{ name = "instanceTypeFilter", type = "multiselect", display = "Instance Type",
			valueList = LOCATION_INSTANCE_VALUES, valueLabels = LOCATION_INSTANCE_LABELS,
			default = "none", test = function(trigger)
				local src = multiSelectSource(trigger, "instanceTypeFilter", "instanceTypeValue")
				return src and ("(" .. src .. ")") or nil
			end },
	},
}

end -- location prototype

PROTOTYPES["money"] = {
	displayName = "Money",
	wa2Event = "Money",
	category = "unit",
	progressType = "none",
	events = function() return { "PLAYER_MONEY", "WA_DELAYED_PLAYER_ENTERING_WORLD" } end,
	force_events = true,
	icon = "Interface\\Icons\\INV_Misc_Coin_01",
	iconFunc = function() return "Interface\\Icons\\INV_Misc_Coin_01" end,
	nameFunc = function() return "Money" end,
	init = function()
		return "local money = GetMoney() or 0\n"
			.. "local gold = math.floor(money / 10000)\n"
			.. "local silver = math.fmod(math.floor(money / 100), 100)\n"
			.. "local copper = math.fmod(money, 100)"
	end,
	args = {
		{ name = "money", type = "hidden", required = true, init = "money",
			store = true, conditionType = "number", display = "Money" },
		{ name = "gold", type = "hidden", required = true, init = "gold",
			store = true, conditionType = "number", display = "Gold" },
		{ name = "silver", type = "hidden", required = true, init = "silver",
			store = true, conditionType = "number", display = "Silver" },
		{ name = "copper", type = "hidden", required = true, init = "copper",
			store = true, conditionType = "number", display = "Copper" },
	},
}

do -- scoped; see the local-ceiling note in the file header

local PET_BEHAVIOR_VALUES = { "aggressive", "assist", "defensive", "passive" }
local PET_BEHAVIOR_LABELS = { aggressive = "Aggressive", assist = "Assist", defensive = "Defensive", passive = "Passive" }

PROTOTYPES["petbehavior"] = {
	displayName = "Pet Behavior",
	wa2Event = "Pet Behavior",
	category = "unit",
	progressType = "none",
	events = function() return { "PET_BAR_UPDATE", "UNIT_PET", "WA_DELAYED_PLAYER_ENTERING_WORLD" } end,
	force_events = true,
	icon = "Interface\\Icons\\Ability_Hunter_MendPet",
	iconFunc = function() return "Interface\\Icons\\Ability_Hunter_MendPet" end,
	nameFunc = function() return "Pet" end,
	init = function()
		return "local petBehaviorValue, petIconValue = WeakestAuras.PetBehavior()"
	end,
	args = {
		{ name = "behavior", type = "select", required = true, display = "Pet Behavior",
			valueList = PET_BEHAVIOR_VALUES, valueLabels = PET_BEHAVIOR_LABELS, default = "aggressive",
			test = function(trigger)
				if trigger.inverse then return "petBehaviorValue ~= " .. fmt(trigger.behavior) end
				return "petBehaviorValue == " .. fmt(trigger.behavior)
			end },
		{ name = "inverse", type = "toggle", display = "Inverse" },
		{ name = "petExists", type = "hidden", required = true, init = "UnitExists(\"pet\") and true or false",
			store = true, conditionType = "bool", display = "Has Pet", test = "petExists" },
		{ name = "behaviorValue", type = "hidden", init = "petBehaviorValue",
			store = true, conditionType = "string", display = "Current Behavior" },
		{ name = "icon", type = "hidden", init = "petIconValue", store = true },
	},
}

end -- pet behavior prototype

PROTOTYPES["queuedaction"] = {
	displayName = "Queued Action",
	wa2Event = "Queued Action",
	category = "spell",
	progressType = "none",
	events = function() return { "ACTIONBAR_UPDATE_STATE", "ACTIONBAR_SLOT_CHANGED", "CURRENT_SPELL_CAST_CHANGED", "PLAYER_ENTERING_WORLD" } end,
	force_events = true,
	icon = "Interface\\Icons\\INV_Misc_QuestionMark",
	iconFunc = function(trigger)
		local id = WA.ResolveSpellID(trigger.spellName)
		if id then
			local _, _, icon = GetSpellInfo(id)
			return icon or "Interface\\Icons\\INV_Misc_QuestionMark"
		end
		return "Interface\\Icons\\INV_Misc_QuestionMark"
	end,
	nameFunc = function(trigger) return trigger.spellName or "Queued Action" end,
	init = function(trigger)
		local id = WA.ResolveSpellID(trigger.spellName) or 0
		return "local spellId = " .. fmt(id) .. "\n"
			.. "local queuedValue = C_Spell.IsCurrentSpell(spellId) and true or false"
	end,
	args = {
		{ name = "spellName", type = "spell", display = "Spell", required = true },
		{ name = "queued", type = "hidden", required = true, init = "queuedValue", test = "queued",
			store = true, conditionType = "bool", display = "Queued" },
	},
}

-- Combat status: shown while the player is in combat. No user config.
PROTOTYPES["combat"] = {
	displayName = "In Combat",
	category = "unit",
	progressType = "none",
	events = function() return { "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED", "PLAYER_TARGET_CHANGED" } end,
	force_events = true,
	icon = "Interface\\Icons\\Ability_DualWield",
	iconFunc = function() return "Interface\\Icons\\Ability_DualWield" end,
	nameFunc = function() return "In Combat" end,
	init = function()
		return "local incombat = UnitAffectingCombat(\"player\") and true or false\n"
			.. "local hastarget = UnitExists(\"target\") and true or false\n"
			.. "local attackabletarget = (UnitExists(\"target\") and UnitCanAttack(\"player\", \"target\")) and true or false"
	end,
	args = {
		{ name = "incombat", type = "hidden", required = true, test = "incombat",
			store = true, conditionType = "bool", display = "In Combat" },
		-- Optional filters: require a (attackable) target as well as combat.
		{ name = "hastarget", type = "toggle", display = "Has Target",
			test = function(t) return t.hastarget and "hastarget" or nil end },
		{ name = "attackabletarget", type = "toggle", display = "Attackable Target",
			test = function(t) return t.attackabletarget and "attackabletarget" or nil end },
	},
}

-- A `statesParameter = "unit"` prototype offers WA.multi_unit_tokens beside the
-- single tokens: one clone per member, keyed by GUID rather than by upstream's
-- positional token (§4.3). WA.MultiUnitFamily is called through the table rather
-- than aliased to a local: this chunk sits on Lua 5.0's 200-local ceiling, and a
-- shorthand is not worth a slot.

-- Membership churn for a family, appended to whatever unit events the prototype
-- reads: those say a member changed, these say which members there are.
local function appendMultiUnitEvents(trigger, out)
	local family = WA.MultiUnitFamily(trigger)
	if not family then return out end
	if family == "nameplate" then
		table.insert(out, "NAME_PLATE_UNIT_ADDED")
		table.insert(out, "NAME_PLATE_UNIT_REMOVED")
	else
		table.insert(out, "PARTY_MEMBERS_CHANGED")
		table.insert(out, "RAID_ROSTER_UPDATE")
	end
	table.insert(out, "PLAYER_ENTERING_WORLD")
	return out
end

-- The single token this trigger reads, or nil for a multi-unit family.
local function singleUnitToken(trigger, fallback)
	if WA.MultiUnitFamily(trigger) then return nil end
	return WA.TriggerUnit(trigger, fallback)
end

-- Occupancy for a single token, the pair to appendMultiUnitEvents: those say
-- which members a family has, this says the one token now points somewhere
-- else. A family trigger is already covered, so this leaves it alone and a
-- prototype can call both unconditionally. The fallback must be the same one
-- the prototype's `init` compiles in, or the trigger subscribes to a token it
-- does not read.
local function appendUnitChangeEvents(trigger, out, fallback)
	local token = singleUnitToken(trigger, fallback)
	if token then table.insert(out, UNIT_CHANGED_PREFIX .. token) end
	return out
end

-- Multi-unit init: the runner hands the member's live token in as arg1, so the
-- generated source reads it instead of a compile-time constant.
local function multiUnitInit(trigger, fallback)
	if WA.MultiUnitFamily(trigger) then return "local unit = arg1" end
	return "local unit = " .. fmt(WA.TriggerUnit(trigger, fallback))
end

local function multiUnitName(trigger, fallback)
	local family = WA.MultiUnitFamily(trigger)
	if family then return WA.multi_unit_labels[family] end
	local unit = WA.TriggerUnit(trigger, fallback)
	return UnitName(unit) or unit
end

-- Unit health, static progress (value/total = health/maxhealth).
PROTOTYPES["health"] = {
	displayName = "Health",
	wa2Event = "Health",
	category = "unit",
	progressType = "static",
	progressValue = "health",
	progressTotal = "maxhealth",
	events = function(trigger)
		return appendUnitChangeEvents(trigger,
			appendMultiUnitEvents(trigger, { "UNIT_HEALTH", "UNIT_MAXHEALTH" }), "player")
	end,
	subjectUnit = function(trigger) return singleUnitToken(trigger, "player") end,
	force_events = true,
	statesParameter = "unit",
	icon = "Interface\\Icons\\INV_Potion_54",
	iconFunc = function() return "Interface\\Icons\\INV_Potion_54" end,
	nameFunc = function(trigger) return multiUnitName(trigger, "player") end,
	init = function(trigger) return multiUnitInit(trigger, "player") end,
	args = {
		{ name = "unit", type = "unit", display = "Unit",
			valueList = WA.unit_tokens_multi, valueLabels = WA.unit_labels_multi,
			store = true, conditionType = "string" },
		{ name = "exists", type = "hidden", required = true, test = "UnitExists(unit)" },
		{ name = "health", type = "number", display = "Health", init = "UnitHealth(unit)",
			multiEntry = true, store = true, conditionType = "number" },
		{ name = "maxhealth", type = "hidden", init = "UnitHealthMax(unit)",
			store = true, conditionType = "number", display = "Max Health" },
		{ name = "percenthealth", type = "number", display = "Health (%)",
			init = "(UnitHealthMax(unit) > 0 and (UnitHealth(unit) / UnitHealthMax(unit) * 100) or 0)",
			multiEntry = true, store = true, conditionType = "number" },
		{ name = "healthDeficit", type = "number", display = "Health Deficit",
			init = "(UnitHealthMax(unit) - UnitHealth(unit))",
			store = true, conditionType = "number" },
		{ name = "name", type = "string", init = "UnitName(unit)",
			store = true, conditionType = "string", display = "Name" },
		-- UnitInRange is a ClassicAPI backport (a real 40yd position check); guard
		-- it so a build without it can't error the whole compiled test. Refreshes
		-- on this prototype's health events, not on movement -- a condition var, not
		-- a real-time range gate.
		{ name = "inRange", type = "hidden", init = "(UnitInRange(unit) and true or false)",
			store = true, conditionType = "bool", display = "In Range" },
		{ name = "ignoreDead", type = "toggle", display = "Ignore Dead",
			test = function(t) return t.ignoreDead and "(not UnitIsDead(unit))" or nil end },
		{ name = "ignoreDisconnected", type = "toggle", display = "Ignore Disconnected",
			test = function(t) return t.ignoreDisconnected and "UnitIsConnected(unit)" or nil end },
		{ name = "inRangeFilter", type = "toggle", display = "Only if In Range",
			test = function(t) return t.inRangeFilter and "inRange" or nil end },
	},
}

-- Unit power (mana/rage/energy). Static progress. The Power Type select chooses
-- which resource is read, not which one the unit has to be displaying.
PROTOTYPES["power"] = {
	displayName = "Power",
	wa2Event = "Power",
	category = "unit",
	progressType = "static",
	progressValue = "power",
	progressTotal = "maxpower",
	events = function(trigger)
		return appendUnitChangeEvents(trigger,
			appendMultiUnitEvents(trigger, { "UNIT_MANA", "UNIT_RAGE", "UNIT_ENERGY", "UNIT_FOCUS",
				"UNIT_MAXMANA", "UNIT_MAXRAGE", "UNIT_MAXENERGY", "UNIT_DISPLAYPOWER" }), "player")
	end,
	subjectUnit = function(trigger) return singleUnitToken(trigger, "player") end,
	force_events = true,
	statesParameter = "unit",
	icon = "Interface\\Icons\\Spell_Nature_Lightning",
	iconFunc = function() return "Interface\\Icons\\Spell_Nature_Lightning" end,
	nameFunc = function(trigger) return multiUnitName(trigger, "player") end,
	-- `powertype` is the slot the reads below address: the selected one, or nil
	-- for whatever bar the unit displays. ClassicAPI's UnitPower answers for a
	-- type the unit is not currently showing -- a druid's mana pool in cat form,
	-- which UnitMana cannot reach at all -- so the selection chooses what to read
	-- and narrowing to the displayed bar is requirePowerType's job below.
	init = function(trigger)
		return multiUnitInit(trigger, "player") .. "\nlocal powertype = "
			.. (trigger.use_powertype and fmt(trigger.powertype or 0) or "nil")
	end,
	-- The reads were UnitMana/UnitManaMax, which answer for the displayed bar
	-- alone, so a saved trigger with a type selected was narrowed to the unit
	-- displaying it whether or not the user asked for that. Carrying the
	-- narrowing into the toggle keeps such a trigger doing exactly what it did,
	-- and leaves a checkbox to widen it; a missing key is what marks a trigger
	-- from before the toggle existed, so this must not overwrite a stored one.
	migrate = function(trigger)
		if trigger.use_powertype and trigger.requirePowerType == nil then
			trigger.requirePowerType = true
		end
	end,
	args = {
		{ name = "unit", type = "unit", display = "Unit",
			valueList = WA.unit_tokens_multi, valueLabels = WA.unit_labels_multi,
			store = true, conditionType = "string" },
		{ name = "exists", type = "hidden", required = true, test = "UnitExists(unit)" },
		-- No test of its own: the selection is which slot `init` reads, and
		-- comparing that slot back to the displayed one is the toggle below.
		{ name = "powertype", type = "select", display = "Power Type",
			valueList = { 0, 1, 3, 2 },
			valueLabels = { [0] = "Mana", [1] = "Rage", [2] = "Focus", [3] = "Energy" },
			test = function() return nil end },
		-- Upstream's "Only if Primary", and the narrowing it is upstream: the
		-- reads answer for a type the unit is not displaying, and this restricts
		-- them to the one it is.
		{ name = "requirePowerType", type = "toggle", display = "Only if Primary", default = false,
			enable = function(trigger) return trigger.use_powertype and true or false end,
			test = function(trigger)
				if not (trigger.requirePowerType and trigger.use_powertype) then return nil end
				return "UnitPowerType(unit) == " .. fmt(trigger.powertype)
			end },
		{ name = "power", type = "number", display = "Power", init = "UnitPower(unit, powertype)",
			store = true, conditionType = "number" },
		{ name = "maxpower", type = "hidden", init = "UnitPowerMax(unit, powertype)",
			store = true, conditionType = "number", display = "Max Power" },
		{ name = "percentpower", type = "number", display = "Power (%)",
			init = "(UnitPowerMax(unit, powertype) > 0 and (UnitPower(unit, powertype) / UnitPowerMax(unit, powertype) * 100) or 0)",
			multiEntry = true, store = true, conditionType = "number" },
		{ name = "powerDeficit", type = "number", display = "Power Deficit",
			init = "UnitPowerMissing(unit, powertype)",
			store = true, conditionType = "number" },
		{ name = "name", type = "hidden", init = "UnitName(unit)",
			store = true, conditionType = "string", display = "Name" },
	},
}

-- "Is a real cooldown running", shared by the three cooldown prototypes. The
-- global cooldown is already gone from `duration` by the time this runs -- the
-- watcher's Info excludes it unless the trigger's `showgcd` asked for it -- so
-- this tests nothing but the window it was handed.
do -- scoped; see the local-ceiling note in the file header

local ON_COOLDOWN_EXPR = "(duration ~= nil and duration > 0 and expirationTime > GetTime())"

-- Spell cooldown, timed progress. Fed by the central cooldown watcher (below):
-- its init reads the watcher's cache rather than polling GetSpellCooldown
-- itself, so GCD filtering and ready-time scheduling stay in one place (ref
-- §4.4). `genericShowOn` selects whether it shows while on cooldown (default,
-- the old hardwired behavior), while ready, or always (WA2's showOnCheck).
-- The `remaining` arg is shared by the three cooldown prototypes: a
-- remaining-time threshold only means something while the cooldown is running,
-- so in ready mode `remaining` is 0 and any "<=" test would pass -- the arg is
-- hidden and contributes no test there.
local function cooldownRemainingArg()
	return { name = "remaining", type = "number", display = "Remaining Time", operator = "<=",
		enable = function(trigger) return (trigger.genericShowOn or "showOnCooldown") ~= "showOnReady" end,
		test = function(trigger)
			if not trigger.use_remaining then return nil end
			if (trigger.genericShowOn or "showOnCooldown") == "showOnReady" then return nil end
			return string.format("remaining %s %s",
				safeOp(trigger.remaining_operator or "<="), fmt(trigger.remaining or 0))
		end }
end
PROTOTYPES["spellcooldown"] = {
	displayName = "Cooldown Progress (Spell)",
	wa2Event = "Cooldown Progress (Spell)",
	category = "spell",
	progressType = "timed",
	-- SPELL_UPDATE_USABLE keeps the usable / insufficient-resources stores live
	-- (pcall-guarded registration -- harmless if this build never fires it; the
	-- force_events pass + cooldown events still seed them). PLAYER_TARGET_CHANGED
	-- re-derives spellInRange on a target swap rather than only on the next
	-- cooldown flip; movement in/out of range with the same target refreshes only
	-- on this trigger's own event cadence. SPELLS_CHANGED / LEARNED_SPELL_IN_TAB
	-- re-run the spell-known gate below, so training the spell lights the trigger
	-- without a reload.
	events = function() return { "SPELL_COOLDOWN_CHANGED", "SPELL_COOLDOWN_READY", "SPELL_UPDATE_USABLE",
		"PLAYER_TARGET_CHANGED", "SPELLS_CHANGED", "LEARNED_SPELL_IN_TAB" } end,
	force_events = true,
	-- ClassicAPI's GetSpellInfo/GetSpellCooldown only accept a numeric spellID
	-- (or slot+bookType) -- unlike vanilla's, there's no name-string lookup
	-- form, so every entry point here goes through WA.ResolveSpellID (which
	-- does the name->ID resolution the legacy global can't) and falls back
	-- cleanly if it doesn't resolve to anything (yet). A `remaining` filter asks
	-- the watcher to re-emit while running so the threshold flips near real time.
	loadFunc = function(trigger)
		local id = WA.ResolveSpellID(trigger.spellName)
		if id then WA.WatchSpellCooldown(id, trigger.use_remaining and (trigger.genericShowOn or "showOnCooldown") ~= "showOnReady") end
	end,
	icon = "Interface\\Icons\\Spell_Holy_BorrowedTime",
	iconFunc = function(trigger)
		local id = WA.ResolveSpellID(trigger.spellName)
		if not id then return "Interface\\Icons\\Spell_Holy_BorrowedTime" end
		local _, _, ic = GetSpellInfo(id)
		return ic or "Interface\\Icons\\Spell_Holy_BorrowedTime"
	end,
	nameFunc = function(trigger)
		local id = WA.ResolveSpellID(trigger.spellName)
		if not id then return (trigger.spellName and trigger.spellName ~= "") and trigger.spellName or "?" end
		return GetSpellInfo(id) or trigger.spellName or "?"
	end,
	init = function(trigger)
		return "local spellId = " .. fmt(WA.ResolveSpellID(trigger.spellName) or 0) .. "\n"
			.. "local startTime, duration = WeakestAuras.SpellCdInfo(spellId, " .. (trigger.showgcd and "true" or "false") .. ")\n"
			.. "local expirationTime = (startTime and duration and (startTime + duration)) or 0\n"
			.. "local remaining = (expirationTime > 0 and (expirationTime - GetTime())) or 0\n"
			.. "local onCooldown = " .. ON_COOLDOWN_EXPR .. " and true or false\n"
			.. "local name, _, icon = GetSpellInfo(spellId)\n"
			.. "local spellUsable, insufficientResources = IsUsableSpell(spellId)\n"
			.. "spellUsable, insufficientResources = spellUsable and true or false, insufficientResources and true or false\n"
			.. "local spellInRange = WeakestAuras.SpellInRange(spellId)\n"
			.. "local spellKnown = WeakestAuras.SpellIsKnown(spellId)"
	end,
	args = {
		{ name = "spellName", type = "spell", display = "Spell" },
		{ name = "genericShowOn", type = "select", required = true, display = "Show",
			valueList = { "showOnCooldown", "showOnReady", "showAlways" },
			valueLabels = { showOnCooldown = "On Cooldown", showOnReady = "Ready", showAlways = "Always" },
			default = "showOnCooldown", reloadOptions = true,
			test = function(trigger)
				local onCd = ON_COOLDOWN_EXPR
				local mode = trigger.genericShowOn or "showOnCooldown"
				if mode == "showOnReady" then return "not " .. onCd
				elseif mode == "showAlways" then return "true"
				else return onCd end
			end },
		{ name = "showgcd", type = "toggle", display = "Show Global Cooldown", default = false },
		cooldownRemainingArg(),
		{ name = "duration", type = "hidden", store = true, conditionType = "number", display = "Duration" },
		{ name = "expirationTime", type = "hidden", store = true, conditionType = "timer", display = "Remaining Time" },
		{ name = "onCooldown", type = "hidden", store = true, conditionType = "bool", display = "On Cooldown" },
		{ name = "name", type = "hidden", store = true, conditionType = "string", display = "Spell Name" },
		{ name = "icon", type = "hidden", store = true },
		{ name = "spellUsable", type = "hidden", store = true, conditionType = "bool", display = "Usable" },
		{ name = "insufficientResources", type = "hidden", store = true, conditionType = "bool", display = "Insufficient Resources" },
		{ name = "spellInRange", type = "hidden", store = true, conditionType = "bool", display = "In Range" },
		{ name = "ignoreSpellKnown", type = "toggle", display = "Ignore Unknown Spell", default = false },
		-- A spell the player never learned still has a Spell.dbc row, so the
		-- cooldown read answers for it -- with a zero-length window, which is
		-- indistinguishable from ready. Without this gate a trigger set to show
		-- always is permanently active for every other class's and race's
		-- abilities, and on a multi-trigger display the first_active scan then
		-- hands the icon to whichever of those sits at trigger 1. Mirrors
		-- upstream, where the same gate lives inside GetSpellCooldown (§4.4).
		{ name = "spellKnown", type = "hidden", required = true, store = true, conditionType = "bool",
			display = "Spell Known",
			test = function(trigger)
				if trigger.ignoreSpellKnown then return nil end
				return "spellKnown"
			end },
	},
}

-- Item cooldown, timed progress. Near-clone of spellcooldown, fed by a parallel
-- watcher keyed by itemID instead of spellID. GetItemCooldown returns
-- (start, duration, enable) directly rather than a table -- its pollRaw wrapper
-- (below, in the watcher section) reads them behind an if-guard, not an
-- `and`-chain, since `and`-chaining a multi-return call truncates it to one
-- value on this client's Lua 5.0 (confirmed; the existing
-- spellUsable/insufficientResources init above already avoids the same trap the
-- same way).
PROTOTYPES["itemcooldown"] = {
	displayName = "Cooldown Progress (Item)",
	wa2Event = "Cooldown Progress (Item)",
	category = "item",
	progressType = "timed",
	events = function() return { "ITEM_COOLDOWN_CHANGED", "ITEM_COOLDOWN_READY" } end,
	force_events = true,
	loadFunc = function(trigger)
		local id = WA.ResolveItemID(trigger.itemName)
		if id then WA.WatchItemCooldown(id, trigger.use_remaining and (trigger.genericShowOn or "showOnCooldown") ~= "showOnReady") end
	end,
	icon = "Interface\\Icons\\INV_Misc_Bag_08",
	iconFunc = function(trigger)
		local _, ic = itemNameIcon(WA.ResolveItemID(trigger.itemName))
		return ic or "Interface\\Icons\\INV_Misc_Bag_08"
	end,
	nameFunc = function(trigger)
		local name = itemNameIcon(WA.ResolveItemID(trigger.itemName))
		return name or (trigger.itemName and trigger.itemName ~= "" and trigger.itemName) or "?"
	end,
	init = function(trigger)
		return "local itemId = " .. fmt(WA.ResolveItemID(trigger.itemName) or 0) .. "\n"
			.. "local startTime, duration = WeakestAuras.ItemCdInfo(itemId, " .. (trigger.showgcd and "true" or "false") .. ")\n"
			.. "local expirationTime = (startTime and duration and (startTime + duration)) or 0\n"
			.. "local remaining = (expirationTime > 0 and (expirationTime - GetTime())) or 0\n"
			.. "local onCooldown = " .. ON_COOLDOWN_EXPR .. " and true or false"
	end,
	args = {
		{ name = "itemName", type = "item", display = "Item" },
		{ name = "genericShowOn", type = "select", required = true, display = "Show",
			valueList = { "showOnCooldown", "showOnReady", "showAlways" },
			valueLabels = { showOnCooldown = "On Cooldown", showOnReady = "Ready", showAlways = "Always" },
			default = "showOnCooldown", reloadOptions = true,
			test = function(trigger)
				local onCd = ON_COOLDOWN_EXPR
				local mode = trigger.genericShowOn or "showOnCooldown"
				if mode == "showOnReady" then return "not " .. onCd
				elseif mode == "showAlways" then return "true"
				else return onCd end
			end },
		{ name = "showgcd", type = "toggle", display = "Show Global Cooldown", default = false },
		cooldownRemainingArg(),
		{ name = "duration", type = "hidden", store = true, conditionType = "number", display = "Duration" },
		{ name = "expirationTime", type = "hidden", store = true, conditionType = "timer", display = "Remaining Time" },
		{ name = "onCooldown", type = "hidden", store = true, conditionType = "bool", display = "On Cooldown" },
	},
}

-- Equipment-slot cooldown IDs, resolved once at load. GetInventorySlotInfo is
-- a native 1.12 global (not a ClassicAPI backport) -- safe to call at file
-- scope, same load-time-global pattern as the CLASSIC_API_VERSION gate
-- (WeakestAuras.lua). Covers the on-use slots that commonly carry an item
-- cooldown (trinkets, weapons); not an exhaustive slot list.
local EQUIP_SLOT_DEFS = {
	{ key = "Trinket0Slot", label = "Trinket 1" },
	{ key = "Trinket1Slot", label = "Trinket 2" },
	{ key = "MainHandSlot", label = "Main Hand" },
	{ key = "SecondaryHandSlot", label = "Off Hand" },
	{ key = "NeckSlot", label = "Neck" },
	{ key = "WaistSlot", label = "Waist" },
}
local EQUIP_SLOT_IDS, EQUIP_SLOT_LABELS = {}, {}
for i = 1, #EQUIP_SLOT_DEFS do
	local def = EQUIP_SLOT_DEFS[i]
	local slotId = GetInventorySlotInfo(def.key)
	if slotId then
		table.insert(EQUIP_SLOT_IDS, slotId)
		EQUIP_SLOT_LABELS[slotId] = def.label
	end
end

PROTOTYPES["equipslotcooldown"] = {
	displayName = "Cooldown Progress (Equipment Slot)",
	wa2Event = "Cooldown Progress (Equipment Slot)",
	category = "item",
	progressType = "timed",
	-- PLAYER_ENTERING_WORLD is what makes the stored icon right on a fresh login:
	-- the force_events pass runs at ADDON_LOADED, where the player's inventory is
	-- not populated yet, so every inventory read there answers nil. The other two
	-- follow the slot's occupant changing and its name arriving.
	events = function() return { "EQUIPSLOT_COOLDOWN_CHANGED", "EQUIPSLOT_COOLDOWN_READY",
		"PLAYER_EQUIPMENT_CHANGED", "GET_ITEM_INFO_RECEIVED", "PLAYER_ENTERING_WORLD" } end,
	force_events = true,
	loadFunc = function(trigger)
		if trigger.itemSlot then WA.WatchEquipSlotCooldown(trigger.itemSlot, trigger.use_remaining and (trigger.genericShowOn or "showOnCooldown") ~= "showOnReady") end
	end,
	migrate = function(trigger) renameArg(trigger, "equipSlot", "itemSlot") end,
	icon = "Interface\\Icons\\INV_Misc_Bag_09",
	iconFunc = function(trigger)
		local slot = trigger.itemSlot
		local link = slot and GetInventoryItemLink("player", slot)
		local _, ic = itemNameIcon(link)
		return ic or "Interface\\Icons\\INV_Misc_Bag_09"
	end,
	nameFunc = function(trigger)
		return EQUIP_SLOT_LABELS[trigger.itemSlot] or "?"
	end,
	-- The icon has to be a live store, not the compile-time `iconFunc` constant
	-- every other prototype leans on: what a slot holds is a property of the
	-- player, not of the trigger, so a constant baked at Add time is wrong from
	-- the first trinket swap -- and wrong from the start on a login, where Add
	-- runs before the inventory exists. GetInventoryItemTexture reads the slot
	-- directly and so needs no item cache at all (`name` still does, hence
	-- GET_ITEM_INFO_RECEIVED above).
	init = function(trigger)
		return "local itemSlot = " .. fmt(trigger.itemSlot or 0) .. "\n"
			.. "local startTime, duration, enable = WeakestAuras.EquipSlotCdInfo(itemSlot, " .. (trigger.showgcd and "true" or "false") .. ")\n"
			.. "local expirationTime = (startTime and duration and (startTime + duration)) or 0\n"
			.. "local remaining = (expirationTime > 0 and (expirationTime - GetTime())) or 0\n"
			.. "local onCooldown = " .. ON_COOLDOWN_EXPR .. " and true or false\n"
			.. "local itemId = GetInventoryItemID(\"player\", itemSlot) or nil\n"
			.. "local name = itemId and C_Item.GetItemInfo(itemId) or nil\n"
			.. "local icon = GetInventoryItemTexture(\"player\", itemSlot) or nil"
	end,
	args = {
		{ name = "itemSlot", type = "select", required = true, display = "Slot",
			valueList = EQUIP_SLOT_IDS, valueLabels = EQUIP_SLOT_LABELS,
			default = EQUIP_SLOT_IDS[1] },
		{ name = "genericShowOn", type = "select", required = true, display = "Show",
			valueList = { "showOnCooldown", "showOnReady", "showAlways" },
			valueLabels = { showOnCooldown = "On Cooldown", showOnReady = "Ready", showAlways = "Always" },
			default = "showOnCooldown", reloadOptions = true,
			test = function(trigger)
				local onCd = ON_COOLDOWN_EXPR
				local mode = trigger.genericShowOn or "showOnCooldown"
				if mode == "showOnReady" then return "not " .. onCd
				elseif mode == "showAlways" then return "true"
				else return onCd end
			end },
		{ name = "showgcd", type = "toggle", display = "Show Global Cooldown", default = false },
		-- GetInventoryItemCooldown's third return, upstream's `enable == 1`. The
		-- slot answers it whether or not anything is on cooldown, so this narrows
		-- to a slot holding something the player can actually use.
		{ name = "testForCooldown", type = "toggle", display = "Is Usable", default = false,
			test = function(trigger) return trigger.testForCooldown and "enable" or nil end },
		cooldownRemainingArg(),
		{ name = "duration", type = "hidden", store = true, conditionType = "number", display = "Duration" },
		{ name = "expirationTime", type = "hidden", store = true, conditionType = "timer", display = "Remaining Time" },
		{ name = "onCooldown", type = "hidden", store = true, conditionType = "bool", display = "On Cooldown" },
		{ name = "name", type = "hidden", store = true, conditionType = "string", display = "Item Name" },
		{ name = "itemId", type = "hidden", store = true, conditionType = "number", display = "Item ID" },
		{ name = "icon", type = "hidden", store = true },
	},
}

-- The watcher's own edges only. It already reads the client's cooldown events
-- and emits GCD_UPDATE/GCD_END on the transitions that mean something, so
-- listening to the raw events here as well would re-evaluate on every unrelated
-- actionbar cooldown change and learn nothing.
PROTOTYPES["globalcooldown"] = {
	displayName = "Global Cooldown",
	wa2Event = "Global Cooldown",
	category = "spell",
	progressType = "timed",
	events = function() return { "GCD_UPDATE", "GCD_END", "PLAYER_ENTERING_WORLD" } end,
	force_events = true,
	loadFunc = function() WA.WatchGCD() end,
	icon = "Interface\\Icons\\Spell_Holy_SealOfMight",
	iconFunc = function() return "Interface\\Icons\\Spell_Holy_SealOfMight" end,
	nameFunc = function() return "Global Cooldown" end,
	init = function(trigger)
		return "local startTime, duration = WeakestAuras.GcdInfo()\n"
			.. "local expirationTime = (startTime and duration and (startTime + duration)) or 0\n"
			.. "local remaining = (expirationTime > 0 and (expirationTime - GetTime())) or 0\n"
			.. "local active = duration ~= nil and duration > 0 and expirationTime > GetTime()"
	end,
	args = {
		{ name = "inverse", type = "toggle", display = "Inverse" },
		{ name = "active", type = "hidden", required = true, store = true,
			conditionType = "bool", display = "On Global Cooldown",
			test = function(trigger) return trigger.inverse and "not active" or "active" end },
		{ name = "duration", type = "hidden", store = true, conditionType = "number", display = "Duration" },
		{ name = "expirationTime", type = "hidden", store = true, conditionType = "timer", display = "Remaining Time" },
		{ name = "remaining", type = "hidden", store = true, conditionType = "number", display = "Time Remaining" },
	},
}

-- "Ready" is the absence of a cooldown of the thing's own: an expired window or
-- no window. A window that is only the global cooldown passing over the key is
-- already no window here -- the read excludes it -- which is also what keeps the
-- progress these prototypes publish from counting the GCD they are ready
-- through. There is no `showgcd` opt-out: a GCD is not what "ready" asks about.
local function cooldownReadyInit(infoFunc, keySource, knownSource)
	return "local cooldownKey = " .. keySource .. "\n"
		.. "local startTime, duration = " .. infoFunc .. "(cooldownKey, false)\n"
		.. "local expirationTime = (startTime and duration and (startTime + duration)) or 0\n"
		.. "local ready = (" .. knownSource .. ") and (duration == nil or duration <= 0 or expirationTime <= GetTime())"
end

-- Whether an item is the on-use kind a cooldown can belong to at all. Gear with
-- a passive or on-proc effect has no cooldown to be ready from, so a trigger
-- pointed at one should stay dark rather than claim to be permanently ready.
-- C_Item.GetItemSpell answers nil for an item not yet in the local cache and
-- requests it in the background, which is why the prototypes reading this also
-- listen for GET_ITEM_INFO_RECEIVED -- without that a cold-cached item would
-- read as passive until something else happened to re-evaluate the trigger.
local function itemHasUseSpell(itemId)
	if not itemId or itemId == 0 then return false end
	local spellName, spellId = C_Item.GetItemSpell(itemId)
	return (spellId and spellId > 0) or (spellName and spellName ~= "")
end
WA.ItemHasUseSpell = itemHasUseSpell

local function cooldownReadyArgs(kind, selector)
	local args = {
		{ name = "ready", type = "hidden", required = true, store = true,
			conditionType = "bool", display = "Ready", test = "ready" },
		{ name = "duration", type = "hidden", store = true, conditionType = "number", display = "Duration" },
		{ name = "expirationTime", type = "hidden", store = true, conditionType = "timer", display = "Ready Since" },
		{ name = "name", type = "hidden", store = true, conditionType = "string", display = kind .. " Name" },
		{ name = "icon", type = "hidden", store = true },
	}
	table.insert(args, 1, selector)
	return args
end

PROTOTYPES["spellcooldownready"] = {
	displayName = "Cooldown Ready (Spell)",
	wa2Event = "Cooldown Ready (Spell)",
	category = "spell",
	progressType = "timed",
	events = function() return { "SPELL_COOLDOWN_CHANGED", "SPELL_COOLDOWN_READY", "SPELL_UPDATE_COOLDOWN" } end,
	force_events = true,
	loadFunc = function(trigger)
		local id = WA.ResolveSpellID(trigger.spellName)
		if id then WA.WatchSpellCooldown(id) end
	end,
	icon = "Interface\\Icons\\Spell_Holy_BorrowedTime",
	iconFunc = function(trigger)
		local id = WA.ResolveSpellID(trigger.spellName)
		if not id then return "Interface\\Icons\\Spell_Holy_BorrowedTime" end
		local _, _, icon = GetSpellInfo(id)
		return icon or "Interface\\Icons\\Spell_Holy_BorrowedTime"
	end,
	nameFunc = function(trigger) return trigger.spellName or "Cooldown Ready" end,
	init = function(trigger)
		local id = WA.ResolveSpellID(trigger.spellName) or 0
		return cooldownReadyInit("WeakestAuras.SpellCdInfo", fmt(id),
			"cooldownKey ~= 0 and WeakestAuras.SpellCdKnown(cooldownKey)")
			.. "\nlocal name, _, icon = GetSpellInfo(cooldownKey)"
	end,
	args = cooldownReadyArgs("Spell", { name = "spellName", type = "spell", required = true, display = "Spell" }),
}

PROTOTYPES["itemcooldownready"] = {
	displayName = "Cooldown Ready (Item)",
	wa2Event = "Cooldown Ready (Item)",
	category = "item",
	progressType = "timed",
	events = function() return { "ITEM_COOLDOWN_CHANGED", "ITEM_COOLDOWN_READY", "BAG_UPDATE_COOLDOWN", "GET_ITEM_INFO_RECEIVED" } end,
	force_events = true,
	loadFunc = function(trigger)
		local id = WA.ResolveItemID(trigger.itemName)
		if id then WA.WatchItemCooldown(id) end
	end,
	icon = "Interface\\Icons\\INV_Misc_Bag_08",
	iconFunc = function(trigger)
		local _, icon = itemNameIcon(WA.ResolveItemID(trigger.itemName))
		return icon or "Interface\\Icons\\INV_Misc_Bag_08"
	end,
	nameFunc = function(trigger)
		local name = itemNameIcon(WA.ResolveItemID(trigger.itemName))
		return name or trigger.itemName or "Cooldown Ready"
	end,
	init = function(trigger)
		local id = WA.ResolveItemID(trigger.itemName) or 0
		return cooldownReadyInit("WeakestAuras.ItemCdInfo", fmt(id), "cooldownKey ~= 0 and WeakestAuras.ItemHasUseSpell(cooldownKey)")
			.. "\nlocal name, _, _, _, _, _, _, _, _, icon = C_Item.GetItemInfo(cooldownKey)"
	end,
	args = cooldownReadyArgs("Item", { name = "itemName", type = "item", required = true, display = "Item" }),
}

PROTOTYPES["equipslotcooldownready"] = {
	displayName = "Cooldown Ready (Equipment Slot)",
	wa2Event = "Cooldown Ready (Equipment Slot)",
	category = "item",
	progressType = "timed",
	-- PLAYER_ENTERING_WORLD for the same reason as the progress prototype above:
	-- the force_events pass runs before the player has an inventory to read.
	events = function() return { "EQUIPSLOT_COOLDOWN_CHANGED", "EQUIPSLOT_COOLDOWN_READY", "BAG_UPDATE_COOLDOWN",
		"PLAYER_EQUIPMENT_CHANGED", "GET_ITEM_INFO_RECEIVED", "PLAYER_ENTERING_WORLD" } end,
	force_events = true,
	loadFunc = function(trigger)
		if trigger.itemSlot then WA.WatchEquipSlotCooldown(trigger.itemSlot) end
	end,
	migrate = function(trigger) renameArg(trigger, "equipSlot", "itemSlot") end,
	icon = "Interface\\Icons\\INV_Misc_Bag_09",
	iconFunc = function(trigger)
		local slot = trigger.itemSlot
		local link = slot and GetInventoryItemLink("player", slot)
		local _, icon = itemNameIcon(link)
		return icon or "Interface\\Icons\\INV_Misc_Bag_09"
	end,
	nameFunc = function(trigger) return EQUIP_SLOT_LABELS[trigger.itemSlot] or "Cooldown Ready" end,
	init = function(trigger)
		return "local cooldownKey = " .. fmt(trigger.itemSlot or 0) .. "\n"
			.. "local startTime, duration = WeakestAuras.EquipSlotCdInfo(cooldownKey, false)\n"
			.. "local expirationTime = (startTime and duration and (startTime + duration)) or 0\n"
			.. "local itemSlot = cooldownKey\n"
			.. "local item = GetInventoryItemID(\"player\", cooldownKey)\n"
			.. "local hasUseSpell = WeakestAuras.ItemHasUseSpell(item)\n"
			.. "local ready = (cooldownKey ~= 0 and hasUseSpell) and (duration == nil or duration <= 0 or expirationTime <= GetTime())\n"
			.. "local name = item and C_Item.GetItemInfo(item) or nil\n"
			.. "local icon = GetInventoryItemTexture(\"player\", cooldownKey) or nil"
	end,
	args = cooldownReadyArgs("Equipment", {
		name = "itemSlot", type = "select", required = true, display = "Equipment Slot",
		valueList = EQUIP_SLOT_IDS, valueLabels = EQUIP_SLOT_LABELS, default = EQUIP_SLOT_IDS[1],
	}),
}

end -- cooldown prototypes

PROTOTYPES["actionusable"] = {
	displayName = "Action Usable",
	wa2Event = "Action Usable",
	category = "spell",
	progressType = "none",
	events = function() return { "SPELL_UPDATE_USABLE", "ACTIONBAR_UPDATE_USABLE", "ACTIONBAR_SLOT_CHANGED", "SPELL_COOLDOWN_CHANGED", "PLAYER_TARGET_CHANGED" } end,
	force_events = true,
	loadFunc = function(trigger)
		local id = WA.ResolveSpellID(trigger.spellName)
		if id then WA.WatchSpellCooldown(id) end
	end,
	icon = "Interface\\Icons\\Spell_Holy_BorrowedTime",
	iconFunc = function(trigger)
		local id = WA.ResolveSpellID(trigger.spellName)
		if not id then return "Interface\\Icons\\Spell_Holy_BorrowedTime" end
		local _, _, icon = GetSpellInfo(id)
		return icon or "Interface\\Icons\\Spell_Holy_BorrowedTime"
	end,
	nameFunc = function(trigger) return trigger.spellName or "Action Usable" end,
	init = function(trigger)
		local id = WA.ResolveSpellID(trigger.spellName) or 0
		return "local spellId = " .. fmt(id) .. "\n"
			.. "local usable, insufficientResources = false, false\n"
			.. "usable, insufficientResources = WeakestAuras.ActionUsability(spellId)\n"
			.. "local startTime, duration = WeakestAuras.SpellCdInfo(spellId, false)\n"
			.. "local expirationTime = (startTime and duration and (startTime + duration)) or 0\n"
			.. "local ready = (duration == nil or duration <= 0 or not startTime or startTime == 0 or expirationTime <= GetTime())\n"
			.. "local active = usable and ready\n"
			.. "local spellInRange = WeakestAuras.SpellInRange(spellId)"
	end,
	args = {
		{ name = "spellName", type = "spell", display = "Spell", required = true },
		{ name = "targetRequired", type = "toggle", display = "Require Valid Target", reloadOptions = true },
		{ name = "ignoreSpellCooldown", type = "toggle", display = "Ignore Spell Cooldown", reloadOptions = true },
		{ name = "inverse", type = "toggle", display = "Inverse", reloadOptions = true },
		{ name = "active", type = "hidden", required = true, store = true, conditionType = "bool",
			display = "Usable", test = function(trigger)
				local test = trigger.ignoreSpellCooldown and "usable" or "active"
				if trigger.targetRequired then test = test .. " and spellInRange" end
				if trigger.inverse then return "not (" .. test .. ")" end
				return test
			end },
		{ name = "usable", type = "hidden", store = true, conditionType = "bool", display = "Spell Usable" },
		{ name = "insufficientResources", type = "hidden", store = true, conditionType = "bool", display = "Insufficient Resources" },
		{ name = "spellInRange", type = "hidden", store = true, conditionType = "bool", display = "In Range" },
		{ name = "duration", type = "hidden", store = true, conditionType = "number", display = "Cooldown Duration" },
		{ name = "expirationTime", type = "hidden", store = true, conditionType = "timer", display = "Cooldown End" },
	},
}

-- Cast/channel progress for any unit token. ClassicAPI's UNIT_SPELLCAST_* events
-- say when to re-read; C_Spell.UnitCastingInfo/UnitChannelInfo say what is
-- being cast. Both C_Spell calls return several values positionally; captured through
-- named throwaway locals first and reassigned, rather than destructured
-- directly into the final names, so the two different return shapes
-- (UnitCastingInfo has castID at position 7, UnitChannelInfo doesn't) can't
-- be confused with each other.
PROTOTYPES["cast"] = {
	displayName = "Cast",
	wa2Event = "Cast",
	category = "unit",
	progressType = "timed",
	-- The six all-unit events, plus the player-only pushback pair so the bar
	-- re-reads its end time. FAILED is left out: a started cast that fails also
	-- fires STOP.
	events = function(trigger)
		return appendUnitChangeEvents(trigger,
			appendMultiUnitEvents(trigger, {
				"UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_SUCCEEDED",
				"UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_CHANNEL_START",
				"UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_SPELLCAST_DELAYED",
				"UNIT_SPELLCAST_CHANNEL_UPDATE" }), "player")
	end,
	subjectUnit = function(trigger) return singleUnitToken(trigger, "player") end,
	force_events = true,
	statesParameter = "unit",
	icon = "Interface\\Icons\\Spell_Nature_WispSplode",
	iconFunc = function() return "Interface\\Icons\\Spell_Nature_WispSplode" end,
	nameFunc = function(trigger) return "Cast (" .. (WA.MultiUnitFamily(trigger) or WA.TriggerUnit(trigger, "player")) .. ")" end,
	init = function(trigger)
		return multiUnitInit(trigger, "player") .. "\n"
			.. "local castName, _, castIcon, startMs, endMs, _, _, notInterruptible, castingSpellID = C_Spell.UnitCastingInfo(unit)\n"
			.. "local chanName, chanIcon, chanStartMs, chanEndMs, chanNotInterruptible, chanSpellID\n"
			.. "if not castName then\n"
			.. "\tlocal _n2, _d2, _i2, _s2, _e2, _t2, _ni2, _sid2 = C_Spell.UnitChannelInfo(unit)\n"
			.. "\tchanName, chanIcon, chanStartMs, chanEndMs, chanNotInterruptible, chanSpellID = _n2, _i2, _s2, _e2, _ni2, _sid2\n"
			.. "end\n"
			.. "local casting = castName ~= nil\n"
			.. "local channeling = chanName ~= nil\n"
			.. "local active = casting or channeling\n"
			.. "local name = castName or chanName\n"
			.. "local icon = castIcon or chanIcon\n"
			.. "local spellId = castingSpellID or chanSpellID\n"
			.. "local notInterruptibleFlag = (casting and notInterruptible) or (channeling and chanNotInterruptible) or false\n"
			.. "local interruptible = not notInterruptibleFlag\n"
			.. "local startTime = ((casting and startMs) or (channeling and chanStartMs) or 0) / 1000\n"
			.. "local expirationTime = ((casting and endMs) or (channeling and chanEndMs) or 0) / 1000\n"
			.. "local duration = (expirationTime > 0 and startTime > 0) and (expirationTime - startTime) or 0"
	end,
	args = {
		{ name = "unit", type = "unit", display = "Unit",
			valueList = WA.unit_tokens_multi, valueLabels = WA.unit_labels_multi,
			store = true, conditionType = "string" },
		{ name = "unitName", type = "hidden", init = "UnitName(unit)",
			store = true, conditionType = "string", display = "Unit Name" },
		{ name = "active", type = "hidden", required = true, test = "active" },
		{ name = "casting", type = "hidden", store = true, conditionType = "bool", display = "Casting" },
		{ name = "channeling", type = "hidden", store = true, conditionType = "bool", display = "Channeling" },
		{ name = "name", type = "hidden", store = true, conditionType = "string", display = "Spell Name" },
		{ name = "icon", type = "hidden", store = true },
		{ name = "spellId", type = "hidden", store = true, conditionType = "number", display = "Spell ID" },
		{ name = "duration", type = "hidden", store = true, conditionType = "number", display = "Duration" },
		{ name = "expirationTime", type = "hidden", store = true, conditionType = "timer", display = "Cast End" },
		{ name = "notInterruptibleFlag", type = "hidden", store = true, conditionType = "bool", display = "Not Interruptible" },
		-- The same flag the way upstream's cast trigger spells it. Vanilla casts
		-- carry no protection flag, so this is true for any cast this client can
		-- see -- a condition tinting uninterruptible casts simply never fires.
		{ name = "interruptible", type = "hidden", store = true, conditionType = "bool", display = "Interruptible" },
	},
}

-- A completed cast is an instant, not a state, so this prototype shows for a
-- configured window and takes itself back down (autoHide) rather than waiting
-- for an event that says the cast stopped being true.
--
-- The player's UNIT_SPELLCAST_SUCCEEDED is the signal, through the shared
-- dispatch below. Your casts only, and no unit arg.
PROTOTYPES["castsucceeded"] = {
	displayName = "Spell Cast Succeeded",
	wa2Event = "Spell Cast Succeeded",
	category = "spell",
	autoHide = true,
	events = function() return { "WA_SPELL_CAST_SUCCEEDED" } end,
	loadFunc = function() WA.WatchSpellCast() end,
	icon = "Interface\\Icons\\Spell_Holy_MagicalSentry",
	iconFunc = function(trigger)
		local id = WA.ResolveSpellID(trigger.spellName)
		if not id then return "Interface\\Icons\\Spell_Holy_MagicalSentry" end
		local _, _, ic = GetSpellInfo(id)
		return ic or "Interface\\Icons\\Spell_Holy_MagicalSentry"
	end,
	nameFunc = function(trigger)
		return (trigger.spellName and trigger.spellName ~= "" and trigger.spellName) or "Cast Succeeded"
	end,
	init = function(trigger)
		return "local castSpellId = arg1\n"
			.. "local wantSpellId = " .. fmt(WA.ResolveSpellID(trigger.spellName) or 0) .. "\n"
	end,
	args = {
		{ name = "spellName", type = "spell", display = "Spell" },
		-- An unset or unresolvable spell name resolves to 0, which must match
		-- nothing rather than fire on every cast the player makes.
		{ name = "matched", type = "hidden", required = true,
			test = "wantSpellId ~= 0 and castSpellId == wantSpellId" },
		{ name = "duration", type = "range", display = "Show For (s)",
			min = 0.5, max = 10, step = 0.5, default = 1 },
		{ name = "castSpellId", type = "hidden", store = true,
			conditionType = "number", display = "Spell ID" },
	},
}

PROTOTYPES["readycheck"] = {
	displayName = "Ready Check",
	wa2Event = "Ready Check",
	category = "event",
	eventMode = true,
	autoHide = true,
	events = function() return { "READY_CHECK" } end,
	icon = "Interface\\Icons\\Spell_Holy_DivineIllumination",
	iconFunc = function() return "Interface\\Icons\\Spell_Holy_DivineIllumination" end,
	args = {
		{ name = "duration", type = "range", display = "Show For (s)",
			min = 0.5, max = 10, step = 0.5, default = 1 },
	},
}

PROTOTYPES["combatevents"] = {
	displayName = "Combat Events",
	category = "event",
	eventMode = true,
	autoHide = true,
	events = function() return COMBAT_EVENT_VALUES end,
	icon = "Interface\\Icons\\Ability_Warrior_Charge",
	iconFunc = function() return "Interface\\Icons\\Ability_Warrior_Charge" end,
	args = {
		{ name = "eventtype", type = "select", display = "Type", required = true,
			valueList = COMBAT_EVENT_VALUES, valueLabels = COMBAT_EVENT_LABELS,
			default = "PLAYER_REGEN_DISABLED", store = true, conditionType = "string",
			init = "event",
			test = function(trigger) return "event == " .. fmt(trigger.eventtype or "") end },
		{ name = "duration", type = "range", display = "Show For (s)",
			min = 0.5, max = 10, step = 0.5, default = 1 },
	},
}

PROTOTYPES["chatmessage"] = {
	displayName = "Chat Message",
	wa2Event = "Chat Message",
	category = "event",
	eventMode = true,
	autoHide = true,
	events = chatMessageEvents,
	icon = "Interface\\Icons\\INV_Misc_Note_01",
	iconFunc = function() return "Interface\\Icons\\INV_Misc_Note_01" end,
	init = function(trigger)
		local base = trigger and trigger.messageType
		return "if event == 'CHAT_MSG_PARTY_LEADER' then event = 'CHAT_MSG_PARTY' elseif event == 'CHAT_MSG_RAID_LEADER' then event = 'CHAT_MSG_RAID' elseif event == 'CHAT_MSG_TEXT_EMOTE' then event = 'CHAT_MSG_EMOTE' end"
	end,
	args = {
		{ name = "messageType", type = "select", display = "Message Type", init = "event",
			valueList = CHAT_MESSAGE_VALUES, valueLabels = CHAT_MESSAGE_LABELS,
			default = "CHAT_MSG_SAY" },
		{ name = "message", type = "string", display = "Message", init = "arg1",
			store = true, conditionType = "string" },
		{ name = "sourceName", type = "string", display = "Source Name", init = "arg2",
			store = true, conditionType = "string" },
		{ name = "destName", type = "string", display = "Destination Name", init = "arg5",
			store = true, conditionType = "string" },
		-- ClassicAPI's arg12, "" for monster, system and GM lines; stored as nil there.
		{ name = "sourceGUID", type = "hidden", init = "arg12 ~= '' and arg12 or nil", store = true },
		{ name = "use_cloneId", type = "toggle", display = "Clone per Event", default = false },
		{ name = "duration", type = "range", display = "Show For (s)",
			min = 0.5, max = 10, step = 0.5, default = 1 },
	},
}

-- Combat Log: one subevent of COMBAT_LOG_EVENT_UNFILTERED, filtered on the
-- fields that subevent carries (upstream's "Combat Log" event trigger). The
-- prefix and suffix choose the subevent, and dispatch applies it through the
-- same subevent filter a custom trigger's CLEU:SUBEVENT sets, so the compiled
-- test runs only for matching events. Settings and stored fields keep
-- upstream's names, so an imported Combat Log trigger lands as written.
--
-- The payload is read with CombatLogGetCurrentEventInfo inside the compiled
-- function rather than off arg1..arg9: a combat log event carries up to
-- twenty-four values and the dispatch signature stops at nine. The positions
-- after the eleven shared values depend on the subevent (ClassicAPI docs, the
-- prefix and suffix tables), and the subevent is fixed per trigger, so the
-- layout is resolved at compile time and the init binds each position to its
-- field name. Every field name is declared whether or not this subevent fills
-- it, so a store compiled against any of them reads a defined (nil) value.
do -- scoped; see the local-ceiling note in the file header

-- Prefixes that take a suffix. Any other prefix is a whole subevent on its own
-- (UNIT_DIED, DAMAGE_SHIELD), and a suffix left in the config from an earlier
-- choice is ignored rather than appended.
local CLEU_ACTUAL_PREFIXES = { SWING = true, RANGE = true, SPELL = true,
	SPELL_PERIODIC = true, ENVIRONMENTAL = true }

-- Only what this client's combat log fires: no SPELL_BUILDING, UNIT_DISSIPATES,
-- ENCHANT_*, _ABSORBED, _STOLEN or _AURA_BROKEN*. importCheck below refuses an
-- import naming one of those rather than compiling a trigger that never fires.
local CLEU_PREFIX_VALUES = { "SWING", "RANGE", "SPELL", "SPELL_PERIODIC", "ENVIRONMENTAL",
	"DAMAGE_SHIELD", "DAMAGE_SPLIT", "DAMAGE_SHIELD_MISSED", "PARTY_KILL", "UNIT_DIED", "UNIT_DESTROYED" }
local CLEU_PREFIX_LABELS = { SWING = "Swing", RANGE = "Range", SPELL = "Spell",
	SPELL_PERIODIC = "Periodic Spell", ENVIRONMENTAL = "Environmental",
	DAMAGE_SHIELD = "Damage Shield", DAMAGE_SPLIT = "Damage Split",
	DAMAGE_SHIELD_MISSED = "Damage Shield Missed", PARTY_KILL = "Party Kill",
	UNIT_DIED = "Unit Died", UNIT_DESTROYED = "Unit Destroyed" }
local CLEU_SUFFIX_VALUES = { "_DAMAGE", "_MISSED", "_HEAL", "_ENERGIZE", "_DRAIN", "_LEECH",
	"_INTERRUPT", "_DISPEL", "_DISPEL_FAILED", "_EXTRA_ATTACKS",
	"_AURA_APPLIED", "_AURA_REMOVED", "_AURA_APPLIED_DOSE", "_AURA_REMOVED_DOSE", "_AURA_REFRESH",
	"_CAST_START", "_CAST_SUCCESS", "_CAST_FAILED", "_INSTAKILL",
	"_DURABILITY_DAMAGE", "_DURABILITY_DAMAGE_ALL", "_CREATE", "_SUMMON", "_RESURRECT" }
local CLEU_SUFFIX_LABELS = { _DAMAGE = "Damage", _MISSED = "Missed", _HEAL = "Heal",
	_ENERGIZE = "Energize", _DRAIN = "Drain", _LEECH = "Leech", _INTERRUPT = "Interrupt",
	_DISPEL = "Dispel", _DISPEL_FAILED = "Dispel Failed", _EXTRA_ATTACKS = "Extra Attacks",
	_AURA_APPLIED = "Aura Applied", _AURA_REMOVED = "Aura Removed",
	_AURA_APPLIED_DOSE = "Aura Applied Dose", _AURA_REMOVED_DOSE = "Aura Removed Dose",
	_AURA_REFRESH = "Aura Refresh", _CAST_START = "Cast Start", _CAST_SUCCESS = "Cast Success",
	_CAST_FAILED = "Cast Failed", _INSTAKILL = "Instakill",
	_DURABILITY_DAMAGE = "Durability Damage", _DURABILITY_DAMAGE_ALL = "Durability Damage All",
	_CREATE = "Create", _SUMMON = "Summon", _RESURRECT = "Resurrect" }

-- The subevent a trigger is configured for, or nil while the choice is
-- incomplete -- which leaves the trigger inert, as upstream's is.
local function cleuSubevent(trigger)
	local prefix = trigger.subeventPrefix
	if not prefix or not CLEU_PREFIX_LABELS[prefix] then return nil end
	if not CLEU_ACTUAL_PREFIXES[prefix] then return prefix end
	local suffix = trigger.subeventSuffix
	if not suffix or not CLEU_SUFFIX_LABELS[suffix] then return nil end
	return prefix .. suffix
end

-- The field names behind the payload positions. A prefix that is a whole
-- subevent shares the layout of the suffix it stands for.
local CLEU_SPELL_PREFIX = { "spellId", "spellName", "spellSchool" }
local CLEU_ENVIRONMENTAL_PREFIX = { "environmentalType" }
local CLEU_SUFFIX_FIELDS = {
	_DAMAGE = { "amount", "overkill", "school", "resisted", "blocked", "absorbed",
		"critical", "glancing", "crushing", "isOffHand" },
	_MISSED = { "missType", "isOffHand", "amountMissed" },
	_HEAL = { "amount", "overhealing", "absorbed", "critical" },
	_ENERGIZE = { "amount", "powerType" },
	_DRAIN = { "amount", "powerType", "extraAmount" },
	_LEECH = { "amount", "powerType", "extraAmount" },
	_CAST_FAILED = { "failedType" },
	_INTERRUPT = { "extraSpellId", "extraSpellName", "extraSchool" },
	_DISPEL_FAILED = { "extraSpellId", "extraSpellName", "extraSchool" },
	_DISPEL = { "extraSpellId", "extraSpellName", "extraSchool", "auraType" },
	_EXTRA_ATTACKS = { "number" },
	_AURA_APPLIED = { "auraType" },
	_AURA_REMOVED = { "auraType" },
	_AURA_REFRESH = { "auraType" },
	_AURA_APPLIED_DOSE = { "auraType", "number" },
	_AURA_REMOVED_DOSE = { "auraType", "number" },
}
-- Values the log leaves nil for zero, and the 1-or-nil flags, normalized so a
-- number test and a bool condition read them directly.
local CLEU_ZERO_FIELDS = { resisted = true, blocked = true, absorbed = true }
local CLEU_FLAG_FIELDS = { critical = true, glancing = true, crushing = true, isOffHand = true }

-- Every field name, for the one `local` line that declares them all.
local CLEU_ALL_FIELDS = {}
do
	local seen = {}
	local function collect(fields)
		for i = 1, #fields do
			if not seen[fields[i]] then
				seen[fields[i]] = true
				table.insert(CLEU_ALL_FIELDS, fields[i])
			end
		end
	end
	collect(CLEU_SPELL_PREFIX)
	collect(CLEU_ENVIRONMENTAL_PREFIX)
	for _, fields in pairs(CLEU_SUFFIX_FIELDS) do collect(fields) end
end

-- (prefixFields, suffixKey) for the trigger's subevent.
local function cleuLayout(trigger)
	local prefix = trigger.subeventPrefix
	if prefix == "SPELL" or prefix == "SPELL_PERIODIC" or prefix == "RANGE" then
		return CLEU_SPELL_PREFIX, trigger.subeventSuffix
	elseif prefix == "SWING" then
		return nil, trigger.subeventSuffix
	elseif prefix == "ENVIRONMENTAL" then
		return CLEU_ENVIRONMENTAL_PREFIX, trigger.subeventSuffix
	elseif prefix == "DAMAGE_SHIELD" or prefix == "DAMAGE_SPLIT" then
		return CLEU_SPELL_PREFIX, "_DAMAGE"
	elseif prefix == "DAMAGE_SHIELD_MISSED" then
		return CLEU_SPELL_PREFIX, "_MISSED"
	end
	return nil, nil
end

-- An enable predicate: does the trigger's subevent carry this field.
local function cleuCarries(name)
	return function(trigger)
		local prefixFields, suffixKey = cleuLayout(trigger)
		for i = 1, #(prefixFields or {}) do
			if prefixFields[i] == name then return true end
		end
		local suffixFields = suffixKey and CLEU_SUFFIX_FIELDS[suffixKey] or {}
		for i = 1, #suffixFields do
			if suffixFields[i] == name then return true end
		end
		return false
	end
end

-- Subevents with no source or no target (ClassicAPI docs), whose filters on
-- that side would match nothing.
local CLEU_SOURCELESS = { ENVIRONMENTAL = true, UNIT_DIED = true, UNIT_DESTROYED = true }
local function cleuHasSource(trigger)
	return not CLEU_SOURCELESS[trigger.subeventPrefix or ""]
end
local function cleuHasDest(trigger)
	local _, suffixKey = cleuLayout(trigger)
	return suffixKey ~= "_CAST_START"
end

-- Upstream's CheckCombatLogFlags family, called from the generated test. The
-- COMBATLOG_OBJECT_* bits, by their upstream filter names. `flags` is nil on
-- the options preview and for an event with no unit on that side, which fails
-- every check.
local CLEU_AFFILIATION_MASKS = { Mine = 1, InParty = 2, InGroup = 7, NotInGroup = 8 }
local CLEU_REACTION_MASKS = { Friendly = 16, Neutral = 32, Hostile = 64 }
local CLEU_OBJECT_TYPE_MASKS = { Player = 1024, NPC = 2048, Pet = 4096, Guardian = 8192, Object = 16384 }
local function flagsMatch(masks)
	return function(flags, want)
		local mask = masks[want]
		return type(flags) == "number" and mask ~= nil and bit.band(flags, mask) ~= 0
	end
end
WA.CheckCombatLogFlags = flagsMatch(CLEU_AFFILIATION_MASKS)
WA.CheckCombatLogFlagsReaction = flagsMatch(CLEU_REACTION_MASKS)
WA.CheckCombatLogFlagsObjectType = flagsMatch(CLEU_OBJECT_TYPE_MASKS)

-- Raid marks by upstream's index: 0 none, 1..8 star..skull, 9 any mark.
local CLEU_RAID_MARK_BITS = { 1, 2, 4, 8, 16, 32, 64, 128 }
function WA.CheckRaidFlags(flags, want)
	want = tonumber(want)
	if type(flags) ~= "number" or not want then return false end
	local marks = bit.band(flags, 255)
	if want == 0 then return marks == 0 end
	if want == 9 then return marks ~= 0 end
	local mark = CLEU_RAID_MARK_BITS[want]
	return mark ~= nil and bit.band(flags, mark) ~= 0
end
function WA.RaidFlagToIndex(flags)
	if type(flags) ~= "number" then return 0 end
	for i = 1, 8 do
		if bit.band(flags, CLEU_RAID_MARK_BITS[i]) ~= 0 then return i end
	end
	return 0
end

-- A unit's NPC ID as a string, which is how upstream stores and compares it:
-- nil for a player, an object or no unit at all.
function WA.CreatureIdString(guid)
	local id = guid and C_CreatureInfo.GetCreatureID(guid)
	return id and tostring(id) or nil
end

local CLEU_NPC_TOOLTIP = {
	title = "NPC IDs",
	lines = { "Matches a unit whose NPC ID is any entry here.",
		"Start an entry with - to exclude that NPC instead: a list of only exclusions matches everyone else, players included." },
}

local CLEU_AFFILIATION_VALUES = { "Mine", "InParty", "InGroup", "NotInGroup" }
local CLEU_AFFILIATION_LABELS = { Mine = "Mine", InParty = "In Party", InGroup = "In Group",
	NotInGroup = "Not in Group" }
local CLEU_REACTION_VALUES = { "Hostile", "Neutral", "Friendly" }
local CLEU_REACTION_LABELS = { Hostile = "Hostile", Neutral = "Neutral", Friendly = "Friendly" }
local CLEU_OBJECT_TYPE_VALUES = { "Player", "NPC", "Pet", "Guardian", "Object" }
local CLEU_OBJECT_TYPE_LABELS = { Player = "Player", NPC = "NPC", Pet = "Pet",
	Guardian = "Guardian", Object = "Object" }
local CLEU_RAID_MARK_VALUES = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 }
local CLEU_RAID_MARK_LABELS = { [0] = "None", [1] = "Star", [2] = "Circle", [3] = "Diamond",
	[4] = "Triangle", [5] = "Moon", [6] = "Square", [7] = "Cross", [8] = "Skull", [9] = "Any" }
-- Single-school masks, labelled with the client's localized school names.
-- Shared with the crowd-control prototype's interrupt-school select.
WA.SCHOOL_VALUES = { 1, 2, 4, 8, 16, 32, 64 }
WA.SCHOOL_LABELS = {}
for _, mask in ipairs(WA.SCHOOL_VALUES) do WA.SCHOOL_LABELS[mask] = C_Spell.GetSchoolString(mask) end
local CLEU_MISS_VALUES = { "MISS", "RESIST", "DODGE", "PARRY", "BLOCK", "EVADE", "IMMUNE",
	"DEFLECT", "ABSORB", "REFLECT" }
local CLEU_MISS_LABELS = { MISS = "Miss", RESIST = "Resist", DODGE = "Dodge", PARRY = "Parry",
	BLOCK = "Block", EVADE = "Evade", IMMUNE = "Immune", DEFLECT = "Deflect", ABSORB = "Absorb",
	REFLECT = "Reflect" }
local CLEU_AURA_TYPE_VALUES = { "BUFF", "DEBUFF" }
local CLEU_AURA_TYPE_LABELS = { BUFF = "Buff", DEBUFF = "Debuff" }
-- Upstream's spelling; the init rewrites the log's "DROWNING" to match.
local CLEU_ENVIRONMENT_VALUES = { "Drowning", "Falling", "Fatigue", "Fire", "Lava", "Slime" }
local CLEU_ENVIRONMENT_LABELS = { Drowning = "Drowning", Falling = "Falling", Fatigue = "Fatigue",
	Fire = "Fire", Lava = "Lava", Slime = "Slime" }
local CLEU_POWER_VALUES = { 0, 1, 2, 3 }
local CLEU_POWER_LABELS = { [0] = "Mana", [1] = "Rage", [2] = "Focus", [3] = "Energy" }

-- The source and destination unit dropdowns: the single tokens without
-- `specific`, whose free-text field is one per trigger and could not serve two
-- units at once.
local CLEU_UNIT_TOKENS, CLEU_UNIT_SET = {}, {}
for i = 1, #WA.unit_tokens do
	local token = WA.unit_tokens[i]
	if token ~= "specific" then
		table.insert(CLEU_UNIT_TOKENS, token)
		CLEU_UNIT_SET[token] = true
	end
end

-- Tests for the gated filters whose auto-generated comparison would be wrong:
-- a unit matches by GUID, flags by mask.
local function cleuUnitTest(name, guidVar)
	return function(trigger)
		if not trigger["use_" .. name] then return nil end
		return guidVar .. " ~= nil and " .. guidVar .. " == UnitGUID(" .. fmt(trigger[name] or "player") .. ")"
	end
end
local function cleuFlagTest(name, checker, flagsVar)
	return function(trigger)
		if not trigger["use_" .. name] then return nil end
		return "WeakestAuras." .. checker .. "(" .. flagsVar .. ", " .. fmt(trigger[name]) .. ")"
	end
end
local function cleuSourceUnitOn(trigger) return cleuHasSource(trigger) and trigger.use_sourceUnit end
local function cleuDestUnitOn(trigger) return cleuHasDest(trigger) and trigger.use_destUnit end

PROTOTYPES["combatlog"] = {
	displayName = "Combat Log",
	wa2Event = "Combat Log",
	category = "event",
	eventMode = true,
	autoHide = true,
	-- Spell ID and Spell Name were saved as one value in `spellId` / `spellName`
	-- with an `_operator` beside it, which no other trigger writes -- so the
	-- operator is what tells such a save from a key another type left behind,
	-- which stays untouched for a switch back.
	migrate = function(trigger)
		for _, key in ipairs({ "spellId", "spellName" }) do
			if trigger[key .. "_operator"] ~= nil then
				local value = trigger[key]
				if trigger[key .. "List"] == nil then
					trigger[key .. "List"] = (value ~= nil and value ~= "") and { tostring(value) } or {}
					trigger["use_" .. key .. "List"] = trigger["use_" .. key] and true or false
				end
				trigger[key], trigger["use_" .. key], trigger[key .. "_operator"] = nil, nil, nil
			end
		end
	end,
	events = function() return { "COMBAT_LOG_EVENT_UNFILTERED" } end,
	subevents = function(trigger)
		local subevent = cleuSubevent(trigger)
		if subevent then return { [subevent] = true } end
		return {}
	end,
	icon = "Interface\\Icons\\Ability_Warrior_SavageBlow",
	iconFunc = function() return "Interface\\Icons\\Ability_Warrior_SavageBlow" end,
	nameFunc = function(trigger) return cleuSubevent(trigger) or "Combat Log" end,
	init = function(trigger)
		local prefixFields, suffixKey = cleuLayout(trigger)
		local lines = {
			"local timestamp, subevent, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags,"
				.. " destGUID, destName, destFlags, destRaidFlags,"
				.. " p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12, p13 = CombatLogGetCurrentEventInfo()",
			"local " .. table.concat(CLEU_ALL_FIELDS, ", "),
		}
		local pos = 1
		local function bind(fields)
			for i = 1, #fields do
				local field = fields[i]
				table.insert(lines, field .. " = p" .. pos)
				pos = pos + 1
				if CLEU_ZERO_FIELDS[field] then
					table.insert(lines, field .. " = " .. field .. " or 0")
				elseif CLEU_FLAG_FIELDS[field] then
					table.insert(lines, field .. " = " .. field .. " and true or false")
				end
			end
		end
		if prefixFields then bind(prefixFields) end
		local suffixFields = suffixKey and CLEU_SUFFIX_FIELDS[suffixKey]
		if suffixFields then bind(suffixFields) end
		if prefixFields == CLEU_ENVIRONMENTAL_PREFIX then
			table.insert(lines, "if environmentalType then environmentalType = string.upper(string.sub(environmentalType, 1, 1))"
				.. " .. string.lower(string.sub(environmentalType, 2)) end")
		end
		table.insert(lines, "local icon")
		table.insert(lines, "if spellId and spellId ~= 0 then local _, _, tex = GetSpellInfo(spellId); icon = tex end")
		return table.concat(lines, "\n")
	end,
	-- The prefix and suffix are matched by the subevent filter in dispatch, not
	-- here; their tests contribute nothing.
	args = {
		{ name = "subeventPrefix", type = "select", required = true, display = "Message Prefix",
			valueList = CLEU_PREFIX_VALUES, valueLabels = CLEU_PREFIX_LABELS, default = "SPELL",
			reloadOptions = true, test = function() return nil end },
		{ name = "subeventSuffix", type = "select", required = true, display = "Message Suffix",
			valueList = CLEU_SUFFIX_VALUES, valueLabels = CLEU_SUFFIX_LABELS, default = "_DAMAGE",
			enable = function(trigger) return CLEU_ACTUAL_PREFIXES[trigger.subeventPrefix or ""] == true end,
			reloadOptions = true, test = function() return nil end },

		{ name = "use_sourceUnit", type = "toggle", display = "Source Unit", reloadOptions = true,
			enable = cleuHasSource },
		{ name = "sourceUnit", type = "unit", display = "Source Unit",
			valueList = CLEU_UNIT_TOKENS, valueLabels = WA.unit_labels,
			enable = cleuSourceUnitOn, test = cleuUnitTest("sourceUnit", "sourceGUID") },
		{ name = "sourceName", type = "string", display = "Source Name", enable = cleuHasSource,
			store = true, conditionType = "string" },
		{ name = "sourceNpcId", type = "list", listNegate = true, display = "Source NPC ID",
			listLabel = "Source NPC IDs (any match)", tooltip = CLEU_NPC_TOOLTIP,
			init = "WeakestAuras.CreatureIdString(sourceGUID)", enable = cleuHasSource,
			store = true, conditionType = "string" },
		{ name = "sourceFlags", type = "select", display = "Source Affiliation",
			valueList = CLEU_AFFILIATION_VALUES, valueLabels = CLEU_AFFILIATION_LABELS,
			enable = cleuHasSource, test = cleuFlagTest("sourceFlags", "CheckCombatLogFlags", "sourceFlags") },
		{ name = "sourceFlags2", type = "select", display = "Source Reaction",
			valueList = CLEU_REACTION_VALUES, valueLabels = CLEU_REACTION_LABELS,
			enable = cleuHasSource, test = cleuFlagTest("sourceFlags2", "CheckCombatLogFlagsReaction", "sourceFlags") },
		{ name = "sourceFlags3", type = "select", display = "Source Object Type",
			valueList = CLEU_OBJECT_TYPE_VALUES, valueLabels = CLEU_OBJECT_TYPE_LABELS,
			enable = cleuHasSource, test = cleuFlagTest("sourceFlags3", "CheckCombatLogFlagsObjectType", "sourceFlags") },
		{ name = "sourceRaidFlags", type = "select", display = "Source Raid Mark",
			valueList = CLEU_RAID_MARK_VALUES, valueLabels = CLEU_RAID_MARK_LABELS,
			enable = cleuHasSource, test = cleuFlagTest("sourceRaidFlags", "CheckRaidFlags", "sourceRaidFlags") },
		{ name = "sourceGUID", type = "hidden", store = true, conditionType = "string",
			display = "Source GUID", enable = cleuHasSource },
		{ name = "sourceRaidMarkIndex", type = "hidden", init = "WeakestAuras.RaidFlagToIndex(sourceRaidFlags)",
			store = true, conditionType = "number", display = "Source Raid Mark Index", enable = cleuHasSource },
		{ name = "sourceRaidMark", type = "hidden",
			init = "sourceRaidMarkIndex > 0 and ('{rt' .. sourceRaidMarkIndex .. '}') or ''",
			store = true, conditionType = "string", display = "Source Raid Mark Texture", enable = cleuHasSource },

		{ name = "use_destUnit", type = "toggle", display = "Destination Unit", reloadOptions = true,
			enable = cleuHasDest },
		{ name = "destUnit", type = "unit", display = "Destination Unit",
			valueList = CLEU_UNIT_TOKENS, valueLabels = WA.unit_labels,
			enable = cleuDestUnitOn, test = cleuUnitTest("destUnit", "destGUID") },
		{ name = "destName", type = "string", display = "Destination Name", enable = cleuHasDest,
			store = true, conditionType = "string" },
		{ name = "destNpcId", type = "list", listNegate = true, display = "Destination NPC ID",
			listLabel = "Destination NPC IDs (any match)", tooltip = CLEU_NPC_TOOLTIP,
			init = "WeakestAuras.CreatureIdString(destGUID)", enable = cleuHasDest,
			store = true, conditionType = "string" },
		{ name = "destFlags", type = "select", display = "Destination Affiliation",
			valueList = CLEU_AFFILIATION_VALUES, valueLabels = CLEU_AFFILIATION_LABELS,
			enable = cleuHasDest, test = cleuFlagTest("destFlags", "CheckCombatLogFlags", "destFlags") },
		{ name = "destFlags2", type = "select", display = "Destination Reaction",
			valueList = CLEU_REACTION_VALUES, valueLabels = CLEU_REACTION_LABELS,
			enable = cleuHasDest, test = cleuFlagTest("destFlags2", "CheckCombatLogFlagsReaction", "destFlags") },
		{ name = "destFlags3", type = "select", display = "Destination Object Type",
			valueList = CLEU_OBJECT_TYPE_VALUES, valueLabels = CLEU_OBJECT_TYPE_LABELS,
			enable = cleuHasDest, test = cleuFlagTest("destFlags3", "CheckCombatLogFlagsObjectType", "destFlags") },
		{ name = "destRaidFlags", type = "select", display = "Destination Raid Mark",
			valueList = CLEU_RAID_MARK_VALUES, valueLabels = CLEU_RAID_MARK_LABELS,
			enable = cleuHasDest, test = cleuFlagTest("destRaidFlags", "CheckRaidFlags", "destRaidFlags") },
		{ name = "destGUID", type = "hidden", store = true, conditionType = "string",
			display = "Destination GUID", enable = cleuHasDest },
		{ name = "destRaidMarkIndex", type = "hidden", init = "WeakestAuras.RaidFlagToIndex(destRaidFlags)",
			store = true, conditionType = "number", display = "Destination Raid Mark Index", enable = cleuHasDest },
		{ name = "destRaidMark", type = "hidden",
			init = "destRaidMarkIndex > 0 and ('{rt' .. destRaidMarkIndex .. '}') or ''",
			store = true, conditionType = "string", display = "Destination Raid Mark Texture", enable = cleuHasDest },

		-- The filters are lists under their own keys: `spellName` and `spellId`
		-- hold a single spell on the cooldown triggers, and a trigger keeps its
		-- keys across a type switch, so a list there would reach code reading one.
		{ name = "spellIdList", type = "list", listNumeric = true, listVar = "spellId",
			display = "Spell ID", listLabel = "Spell IDs (any match)", enable = cleuCarries("spellId") },
		{ name = "spellId", type = "hidden", enable = cleuCarries("spellId"),
			store = true, conditionType = "number", display = "Spell ID" },
		{ name = "spellNameList", type = "list", listVar = "spellName",
			display = "Spell Name", listLabel = "Spell Names (any match)", enable = cleuCarries("spellName") },
		{ name = "spellName", type = "hidden", enable = cleuCarries("spellName"),
			store = true, conditionType = "string", display = "Spell Name" },
		{ name = "spellSchool", type = "select", display = "Spell School",
			valueList = WA.SCHOOL_VALUES, valueLabels = WA.SCHOOL_LABELS,
			enable = cleuCarries("spellSchool"), store = true, conditionType = "number" },
		{ name = "environmentalType", type = "select", display = "Environment Type",
			valueList = CLEU_ENVIRONMENT_VALUES, valueLabels = CLEU_ENVIRONMENT_LABELS,
			enable = cleuCarries("environmentalType"), store = true, conditionType = "string" },
		{ name = "missType", type = "select", display = "Miss Type",
			valueList = CLEU_MISS_VALUES, valueLabels = CLEU_MISS_LABELS,
			enable = cleuCarries("missType"), store = true, conditionType = "string" },
		{ name = "extraSpellId", type = "number", display = "Extra Spell ID", operator = "==",
			enable = cleuCarries("extraSpellId"), store = true, conditionType = "number" },
		{ name = "extraSpellName", type = "string", display = "Extra Spell Name",
			enable = cleuCarries("extraSpellName"), store = true, conditionType = "string" },
		{ name = "extraSchool", type = "select", display = "Extra School",
			valueList = WA.SCHOOL_VALUES, valueLabels = WA.SCHOOL_LABELS,
			enable = cleuCarries("extraSchool"), store = true, conditionType = "number" },
		{ name = "auraType", type = "select", display = "Aura Type",
			valueList = CLEU_AURA_TYPE_VALUES, valueLabels = CLEU_AURA_TYPE_LABELS,
			enable = cleuCarries("auraType"), store = true, conditionType = "string" },
		{ name = "amount", type = "number", display = "Amount",
			enable = cleuCarries("amount"), store = true, conditionType = "number" },
		{ name = "overkill", type = "number", display = "Overkill",
			enable = cleuCarries("overkill"), store = true, conditionType = "number" },
		{ name = "overhealing", type = "number", display = "Overhealing",
			enable = cleuCarries("overhealing"), store = true, conditionType = "number" },
		{ name = "school", type = "select", display = "School",
			valueList = WA.SCHOOL_VALUES, valueLabels = WA.SCHOOL_LABELS,
			enable = cleuCarries("school"), store = true, conditionType = "number" },
		{ name = "resisted", type = "number", display = "Resisted",
			enable = cleuCarries("resisted"), store = true, conditionType = "number" },
		{ name = "blocked", type = "number", display = "Blocked",
			enable = cleuCarries("blocked"), store = true, conditionType = "number" },
		{ name = "absorbed", type = "number", display = "Absorbed",
			enable = cleuCarries("absorbed"), store = true, conditionType = "number" },
		{ name = "critical", type = "tristate", display = "Critical",
			enable = cleuCarries("critical"), store = true, conditionType = "bool" },
		{ name = "glancing", type = "tristate", display = "Glancing",
			enable = cleuCarries("glancing"), store = true, conditionType = "bool" },
		{ name = "crushing", type = "tristate", display = "Crushing",
			enable = cleuCarries("crushing"), store = true, conditionType = "bool" },
		{ name = "isOffHand", type = "tristate", display = "Is Off Hand",
			enable = cleuCarries("isOffHand"), store = true, conditionType = "bool" },
		{ name = "number", type = "number", display = "Number",
			enable = cleuCarries("number"), store = true, conditionType = "number" },
		{ name = "powerType", type = "select", display = "Power Type",
			valueList = CLEU_POWER_VALUES, valueLabels = CLEU_POWER_LABELS,
			enable = cleuCarries("powerType"), store = true, conditionType = "number" },
		{ name = "extraAmount", type = "number", display = "Extra Amount",
			enable = cleuCarries("extraAmount"), store = true, conditionType = "number" },

		{ name = "use_cloneId", type = "toggle", display = "Clone per Event", default = false },
		{ name = "duration", type = "range", display = "Show For (s)",
			min = 0.5, max = 10, step = 0.5, default = 1 },
		{ name = "icon", type = "hidden", store = true },
	},
	-- Settings an import can carry that this client cannot honour: a subevent
	-- its log never fires, or a unit token the dropdowns do not offer.
	importCheck = function(trigger)
		local prefix, suffix = trigger.subeventPrefix, trigger.subeventSuffix
		if prefix ~= nil and not CLEU_PREFIX_LABELS[prefix] then
			return "uses subevent prefix " .. tostring(prefix) .. ", which this client never fires"
		end
		if prefix ~= nil and CLEU_ACTUAL_PREFIXES[prefix] and suffix ~= nil and not CLEU_SUFFIX_LABELS[suffix] then
			return "uses subevent " .. prefix .. tostring(suffix) .. ", which this client never fires"
		end
		if trigger.use_sourceUnit and not CLEU_UNIT_SET[trigger.sourceUnit or ""] then
			return "uses source unit " .. tostring(trigger.sourceUnit) .. ", which this trigger does not offer"
		end
		if trigger.use_destUnit and not CLEU_UNIT_SET[trigger.destUnit or ""] then
			return "uses destination unit " .. tostring(trigger.destUnit) .. ", which this trigger does not offer"
		end
		return nil
	end,
}

end -- combatlog

-- Status bool: has the player learned this spell. IsSpellKnown is a native
-- global taking a numeric spellID (3.3.5 semantics).
PROTOTYPES["spellknown"] = {
	displayName = "Spell Known",
	wa2Event = "Spell Known",
	category = "spell",
	progressType = "none",
	events = function() return { "SPELLS_CHANGED", "LEARNED_SPELL_IN_TAB" } end,
	force_events = true,
	icon = "Interface\\Icons\\INV_Misc_Book_09",
	iconFunc = function(trigger)
		local id = WA.ResolveSpellID(trigger.spellName)
		if not id then return "Interface\\Icons\\INV_Misc_Book_09" end
		local _, _, ic = GetSpellInfo(id)
		return ic or "Interface\\Icons\\INV_Misc_Book_09"
	end,
	nameFunc = function(trigger)
		local id = WA.ResolveSpellID(trigger.spellName)
		if not id then return (trigger.spellName and trigger.spellName ~= "") and trigger.spellName or "?" end
		return GetSpellInfo(id) or trigger.spellName or "?"
	end,
	init = function(trigger)
		return "local spellId = " .. fmt(WA.ResolveSpellID(trigger.spellName) or 0) .. "\n"
			.. "local known = IsSpellKnown(spellId) and true or false"
	end,
	args = {
		{ name = "spellName", type = "spell", display = "Spell" },
		{ name = "known", type = "hidden", required = true, test = "known", store = true, conditionType = "bool", display = "Known" },
	},
}

-- The stance bar's occupied slots, and the form sitting in each. Positions, not
-- DBC ids: the bar's order is what a class's spellbook produced, so slot 2 is
-- Defensive Stance on a warrior and Aquatic Form on a druid. Both calls are live
-- here (pfUI reads GetShapeshiftFormInfo's third return and calls
-- GetNumShapeshiftForms; ../pfUI/modules/actionbar.lua:484,1208).
-- The occupied slot, or 0 for no form. Derived from each slot's `active` return
-- rather than from GetShapeshiftForm(), which no addon on this client is known
-- to call.
function WA.ShapeshiftBarIndex()
	for i = 1, GetNumShapeshiftForms() do
		local _, _, active = GetShapeshiftFormInfo(i)
		if active then return i end
	end
	return 0
end

-- The bar's slots and their captions, both from one walk.
function WA.ShapeshiftForms()
	local values, labels = { 0 }, { [0] = "0 - No Form" }
	for i = 1, GetNumShapeshiftForms() do
		table.insert(values, i)
		local _, name = GetShapeshiftFormInfo(i)
		labels[i] = i .. " - " .. (name or "Form " .. i)
	end
	return values, labels
end

-- Status: current shapeshift/stance form, offered on both numberings. `form` is
-- the bar position and is what an upstream import carries; `formId` is the
-- SpellShapeshiftForm.dbc id, which vanilla numbers differently from modern WoW
-- and differently per class -- a raw number rather than a hardcoded per-class
-- select, so this doesn't ship a wrong ID table.
PROTOTYPES["stance"] = {
	displayName = "Stance/Form",
	wa2Event = "Stance/Form/Aura",
	category = "unit",
	progressType = "none",
	-- The plural event fires when the bar's *contents* change (a form learned),
	-- which renumbers every position above it.
	events = function() return { "UPDATE_SHAPESHIFT_FORM", "UPDATE_SHAPESHIFT_FORMS" } end,
	force_events = true,
	icon = "Interface\\Icons\\Ability_Druid_CatForm",
	iconFunc = function() return "Interface\\Icons\\Ability_Druid_CatForm" end,
	nameFunc = function() return "Stance/Form" end,
	init = function(trigger)
		-- The bar-position match is a named local so `inverse` can negate it as
		-- one term. With no form filter set it is `true`, so an inverted trigger
		-- with nothing selected shows never -- upstream's reading of the pair.
		local match = multiSelectSource(trigger, "form", "form") or "true"
		return "local formId = GetShapeshiftFormID() or 0\n"
			.. "local inForm = formId ~= 0\n"
			.. "local form = WeakestAuras.ShapeshiftBarIndex()\n"
			.. "local formMatch = (" .. match .. ")"
	end,
	args = {
		{ name = "form", type = "multiselect", display = "Form",
			valueList = function() return (WA.ShapeshiftForms()) end,
			valueLabels = function() local _, labels = WA.ShapeshiftForms(); return labels end,
			default = 0, store = true, conditionType = "number",
			test = function(trigger) return trigger.inverse and "not formMatch" or "formMatch" end },
		{ name = "inverse", type = "toggle", display = "Inverse Form Match" },
		{ name = "formId", type = "number", display = "Form ID", operator = "==",
			store = true, conditionType = "number" },
		{ name = "inForm", type = "hidden", store = true, conditionType = "bool", display = "In Any Form" },
	},
}

-- Status number: bag+bank item count. C_Item.GetItemCount returns a single
-- value (no multi-return truncation risk from the `and`-chain below).
PROTOTYPES["itemcount"] = {
	displayName = "Item Count",
	wa2Event = "Item Count",
	category = "item",
	progressType = "none",
	events = function() return { "BAG_UPDATE", "BANKFRAME_OPENED", "BANKFRAME_CLOSED" } end,
	force_events = true,
	icon = "Interface\\Icons\\INV_Misc_Bag_10",
	iconFunc = function(trigger)
		local _, ic = itemNameIcon(WA.ResolveItemID(trigger.itemName))
		return ic or "Interface\\Icons\\INV_Misc_Bag_10"
	end,
	nameFunc = function(trigger)
		local name = itemNameIcon(WA.ResolveItemID(trigger.itemName))
		return name or (trigger.itemName and trigger.itemName ~= "" and trigger.itemName) or "?"
	end,
	init = function(trigger)
		return "local count, itemKnown = WeakestAuras.ItemCount("
			.. fmt(trigger.itemName or "") .. ", "
			.. fmt(trigger.includeBank and true or false) .. ")"
	end,
	args = {
		{ name = "itemName", type = "item", display = "Item" },
		-- No gate on the item resolving. A name that matches nothing the player
		-- holds is indistinguishable from holding none of it, and "warn me when
		-- I'm out" is the main reason to want this trigger -- so an unresolved
		-- item counts 0 and shows, rather than compiling a display that can
		-- never appear.
		{ name = "includeBank", type = "toggle", display = "Include Bank" },
		{ name = "count", type = "number", display = "Count", operator = ">=", store = true, conditionType = "number" },
		{ name = "itemKnown", type = "hidden", store = true, conditionType = "bool", display = "Item Identified" },
	},
}

-- Status bool: is this item currently equipped (any slot). C_Item.
-- IsEquippedItem accepts an itemID/link/name directly (same shapes as
-- GetItemInfo), so the raw config string is passed through rather than
-- resolved to an ID first.
PROTOTYPES["itemequipped"] = {
	displayName = "Item Equipped",
	wa2Event = "Item Equipped",
	category = "item",
	progressType = "none",
	events = function() return { "UNIT_INVENTORY_CHANGED", "PLAYER_EQUIPMENT_CHANGED" } end,
	force_events = true,
	icon = "Interface\\Icons\\INV_Chest_Cloth_17",
	iconFunc = function(trigger)
		local _, ic = itemNameIcon(WA.ResolveItemID(trigger.itemName))
		return ic or "Interface\\Icons\\INV_Chest_Cloth_17"
	end,
	nameFunc = function(trigger)
		local name = itemNameIcon(WA.ResolveItemID(trigger.itemName))
		return name or (trigger.itemName and trigger.itemName ~= "" and trigger.itemName) or "?"
	end,
	init = function(trigger)
		return "local itemRef = " .. fmt(trigger.itemName or "") .. "\n"
			.. "local equipped = (itemRef ~= \"\" and C_Item.IsEquippedItem(itemRef)) and true or false"
	end,
	args = {
		{ name = "itemName", type = "item", display = "Item" },
		{ name = "equipped", type = "hidden", required = true, test = "equipped", store = true, conditionType = "bool", display = "Equipped" },
	},
}

-- Declared out here, and only assigned inside the block below, because
-- buildOptions reaches for it when a class change invalidates the subclass
-- selection. Everything else the itemtypeequipped prototype needs stays scoped.
local itemSubclassValues

do -- scoped; see the local-ceiling note in the file header

local ITEM_EQUIP_SLOTS = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 }
local ITEM_EQUIP_SLOT_LABELS = {
	[0] = "Any Slot", [1] = "Head", [2] = "Neck", [3] = "Shoulder", [4] = "Shirt",
	[5] = "Chest", [6] = "Waist", [7] = "Legs", [8] = "Feet", [9] = "Wrist",
	[10] = "Hands", [11] = "Finger 1", [12] = "Finger 2", [13] = "Trinket 1",
	[14] = "Trinket 2", [15] = "Back", [16] = "Main Hand", [17] = "Off Hand",
	[18] = "Ranged", [19] = "Tabard",
}

local ITEM_CLASS_IDS, ITEM_CLASS_LABELS = {}, {}
local ITEM_SUBCLASS_IDS, ITEM_SUBCLASS_LABELS = {}, {}
local fallbackItemClasses = {
	[0] = "Consumable", [1] = "Container", [2] = "Weapon", [3] = "Gem",
	[4] = "Armor", [5] = "Reagent", [6] = "Projectile", [7] = "Trade Goods",
	[8] = "Item Enhancement", [9] = "Recipe", [10] = "Currency",
	[11] = "Quiver", [12] = "Quest", [13] = "Key", [14] = "Permanent",
	[15] = "Miscellaneous",
}
for classID = 0, 15 do
	local label = C_Item.GetItemClassInfo(classID)
	if not label or label == "" then label = fallbackItemClasses[classID] end
	if label then
		table.insert(ITEM_CLASS_IDS, classID)
		ITEM_CLASS_LABELS[classID] = label
		ITEM_SUBCLASS_IDS[classID] = {}
		ITEM_SUBCLASS_LABELS[classID] = {}
		for subclassID = 0, 31 do
			local subclass = C_Item.GetItemSubClassInfo(classID, subclassID)
			if subclass and subclass ~= "" then
				table.insert(ITEM_SUBCLASS_IDS[classID], subclassID)
				ITEM_SUBCLASS_LABELS[classID][subclassID] = subclass
			end
		end
	end
end

function itemSubclassValues(classID)
	local ids = ITEM_SUBCLASS_IDS[tonumber(classID) or -1]
	local labels = ITEM_SUBCLASS_LABELS[tonumber(classID) or -1]
	if ids and #ids > 0 then return ids, labels end
	return { 0 }, { [0] = "Unknown" }
end

PROTOTYPES["itemtypeequipped"] = {
	displayName = "Item Type Equipped",
	wa2Event = "Item Type Equipped",
	category = "item",
	progressType = "none",
	events = function() return { "PLAYER_EQUIPMENT_CHANGED", "UNIT_INVENTORY_CHANGED", "WA_DELAYED_PLAYER_ENTERING_WORLD" } end,
	force_events = true,
	icon = "Interface\\Icons\\INV_Misc_Bag_10",
	iconFunc = function() return "Interface\\Icons\\INV_Misc_Bag_10" end,
	nameFunc = function() return "Item Type Equipped" end,
	migrate = function(trigger)
		if trigger.itemClassID ~= nil then trigger.itemClassID = tonumber(trigger.itemClassID) or trigger.itemClassID end
		if trigger.itemSubclassID ~= nil then trigger.itemSubclassID = tonumber(trigger.itemSubclassID) or trigger.itemSubclassID end
		-- The subclass filter was one always-on value before it became a set. A
		-- saved trigger carrying the value and no mode meant exactly that value,
		-- where a trigger with neither is fresh and takes the defaults.
		if trigger.itemSubclassID ~= nil and trigger.use_itemSubclassID == nil then
			trigger.use_itemSubclassID = "single"
		end
	end,
	init = function(trigger)
		-- The subclass set as source. "nil" means any subclass of the chosen
		-- class; an empty literal means none, which is what a set nothing was
		-- ticked in has to mean for unticking to narrow the match.
		local function subclassSetSource()
			local mode = trigger.use_itemSubclassID
			if mode ~= "single" and mode ~= "multi" then return "nil" end
			local parts = {}
			if mode == "single" then
				local id = tonumber(trigger.itemSubclassID)
				if id then table.insert(parts, "[" .. id .. "] = true") end
			else
				for value, selected in pairs(trigger.itemSubclassID_multi or {}) do
					local id = tonumber(value)
					if selected and id then table.insert(parts, "[" .. id .. "] = true") end
				end
			end
			return "{ " .. table.concat(parts, ", ") .. " }"
		end
		return "local wantedClassID = tonumber(" .. fmt(trigger.itemClassID or "") .. ") or -1\n"
			.. "local wantedSubclasses = " .. subclassSetSource() .. "\n"
			.. "local selectedSlot = " .. fmt(tonumber(trigger.itemSlot) or 0) .. "\n"
			.. "local inverse = " .. fmt(trigger.inverse and true or false) .. "\n"
			.. "local itemIDValue, itemNameValue, itemIconValue, itemClassValue, itemSubclassValue, itemClassIDValue, itemSubclassIDValue, equippedValue, matchingValue, itemKnownValue = WeakestAuras.ItemTypeEquipped(wantedClassID, wantedSubclasses, selectedSlot)"
	end,
	args = {
		{ name = "itemClassID", type = "select", display = "Item Class", required = true,
			valueList = ITEM_CLASS_IDS, valueLabels = ITEM_CLASS_LABELS, default = 2,
			test = function() return nil end, reloadOptions = true },
		{ name = "itemSubclassID", type = "multiselect", display = "Item Subclass",
			valueList = function(trigger) return itemSubclassValues(trigger.itemClassID) end,
			valueLabels = function(trigger) return ITEM_SUBCLASS_LABELS[tonumber(trigger.itemClassID) or -1] end,
			default = 0, test = function() return nil end },
		{ name = "itemSlot", type = "select", required = true, init = "selectedSlot", display = "Equipment Slot",
			valueList = ITEM_EQUIP_SLOTS, valueLabels = ITEM_EQUIP_SLOT_LABELS, default = 0 },
		{ name = "inverse", type = "toggle", display = "Inverse" },
		{ name = "itemID", type = "hidden", init = "itemIDValue", store = true, storeAlways = true, conditionType = "number", display = "Item ID" },
		{ name = "itemName", type = "hidden", init = "itemNameValue", store = true, storeAlways = true, conditionType = "string", display = "Item Name" },
		{ name = "name", type = "hidden", init = "itemNameValue", store = true, storeAlways = true, conditionType = "string", display = "Name" },
		{ name = "icon", type = "hidden", init = "itemIconValue", store = true, storeAlways = true, display = "Icon" },
		{ name = "itemClassName", type = "hidden", init = "itemClassValue", store = true, storeAlways = true, conditionType = "string", display = "Item Class" },
		{ name = "itemSubclassName", type = "hidden", init = "itemSubclassValue", store = true, storeAlways = true, conditionType = "string", display = "Item Subclass" },
		{ name = "foundClassID", type = "hidden", init = "itemClassIDValue", store = true, storeAlways = true, conditionType = "number", display = "Found Item Class ID" },
		{ name = "foundSubclassID", type = "hidden", init = "itemSubclassIDValue", store = true, storeAlways = true, conditionType = "number", display = "Found Item Subclass ID" },
		{ name = "equipped", type = "hidden", init = "equippedValue", store = true, storeAlways = true, conditionType = "bool", display = "Equipped" },
		{ name = "matching", type = "hidden", required = true, init = "matchingValue", store = true, storeAlways = true, conditionType = "bool", display = "Matching Type",
			test = function(trigger) return trigger.inverse and "not matching" or "matching" end },
		{ name = "itemKnown", type = "hidden", init = "itemKnownValue", store = true, storeAlways = true, conditionType = "bool", display = "Item Metadata Available" },
	},
}

end -- item type/class prototype

PROTOTYPES["itemset"] = {
	displayName = "Item Set Equipped",
	wa2Event = "Item Set",
	category = "item",
	progressType = "static",
	progressValue = "count",
	progressTotal = "total",
	events = function() return { "PLAYER_EQUIPMENT_CHANGED", "GET_ITEM_INFO_RECEIVED", "WA_DELAYED_PLAYER_ENTERING_WORLD" } end,
	force_events = true,
	icon = "Interface\\Icons\\INV_Chest_Cloth_17",
	iconFunc = function() return "Interface\\Icons\\INV_Chest_Cloth_17" end,
	migrate = function(trigger) renameArg(trigger, "itemSetID", "itemSetId") end,
	nameFunc = function(trigger)
		local _, _, name = WA.ItemSetEquipped(trigger.itemSetId)
		return name or "Item Set Equipped"
	end,
	init = function(trigger)
		return "local countValue, totalValue, setNameValue, setKnownValue = WeakestAuras.ItemSetEquipped("
			.. fmt(trigger.itemSetId or 0) .. ")"
	end,
	args = {
		{ name = "itemSetId", type = "text", display = "Item Set ID", required = true, default = "0" },
		{ name = "inverse", type = "toggle", display = "Inverse" },
		{ name = "count", type = "hidden", init = "countValue", store = true, conditionType = "number", display = "Equipped Pieces" },
		{ name = "total", type = "hidden", init = "totalValue", store = true, conditionType = "number", display = "Set Pieces" },
		{ name = "setName", type = "hidden", init = "setNameValue", store = true, conditionType = "string", display = "Set Name" },
		{ name = "setKnown", type = "hidden", init = "setKnownValue", store = true, conditionType = "bool", display = "Set Identified" },
		{ name = "active", type = "hidden", required = true, test = function(trigger)
			return trigger.inverse and "count == 0" or "count > 0"
		end, store = true, init = "countValue > 0", conditionType = "bool", display = "Active" },
	},
}

PROTOTYPES["equipmentset"] = {
	displayName = "Equipment Set Equipped",
	wa2Event = "Equipment Set",
	category = "item",
	progressType = "static",
	progressValue = "count",
	progressTotal = "total",
	events = function() return { "PLAYER_EQUIPMENT_CHANGED", "WEAR_EQUIPMENT_SET", "EQUIPMENT_SETS_CHANGED", "EQUIPMENT_SWAP_FINISHED", "WA_DELAYED_PLAYER_ENTERING_WORLD" } end,
	force_events = true,
	migrate = function(trigger) renameArg(trigger, "equipmentSetName", "itemSetName") end,
	icon = "Interface\\Icons\\INV_Misc_Gear_03",
	iconFunc = function(trigger)
		local _, icon = WA.EquipmentSetInfo(trigger.itemSetName, trigger.partial)
		return icon or "Interface\\Icons\\INV_Misc_Gear_03"
	end,
	nameFunc = function(trigger)
		local name = WA.EquipmentSetInfo(trigger.itemSetName, trigger.partial)
		return name or "Equipment Set Equipped"
	end,
	init = function(trigger)
		return "local setNameValue, setIconValue, countValue, totalValue, activeValue, setIDValue, ignoredValue = WeakestAuras.EquipmentSetInfo("
			.. fmt(trigger.itemSetName or "") .. ", " .. fmt(trigger.partial and true or false) .. ")"
	end,
	args = {
		{ name = "itemSetName", type = "text", display = "Equipment Set", required = true },
		{ name = "partial", type = "toggle", display = "Allow Partial Matches" },
		{ name = "inverse", type = "toggle", display = "Inverse" },
		{ name = "name", type = "hidden", init = "setNameValue", store = true, conditionType = "string", display = "Set Name" },
		{ name = "icon", type = "hidden", init = "setIconValue", store = true, display = "Icon" },
		{ name = "count", type = "hidden", init = "countValue", store = true, conditionType = "number", display = "Equipped Pieces" },
		{ name = "total", type = "hidden", init = "totalValue", store = true, conditionType = "number", display = "Set Pieces" },
		{ name = "setID", type = "hidden", init = "setIDValue", store = true, conditionType = "number", display = "Set ID" },
		{ name = "ignored", type = "hidden", init = "ignoredValue", store = true, conditionType = "number", display = "Ignored Slots" },
		{ name = "active", type = "hidden", required = true, init = "activeValue", store = true, conditionType = "bool", display = "Active",
			test = function(trigger) return trigger.inverse and "not active" or "active" end },
	},
}

-- Status: static facts about a unit. UnitClassBase (ClassicAPI backport)
-- returns two values -- captured through pre-declared locals set inside an
-- if-block rather than an `and`-chain, for the same multi-return-truncation
-- reason documented above the itemcooldown prototype.
PROTOTYPES["unitcharacteristics"] = {
	displayName = "Unit Characteristics",
	wa2Event = "Unit Characteristics",
	category = "unit",
	progressType = "none",
	-- UNIT_HEALTH drives the `dead` store; the other facts here cannot change
	-- without a unit-change event firing anyway.
	events = function(trigger)
		return appendUnitChangeEvents(trigger,
			appendMultiUnitEvents(trigger, { "UNIT_LEVEL", "UNIT_HEALTH", "PLAYER_ENTERING_WORLD" }), "target")
	end,
	subjectUnit = function(trigger) return singleUnitToken(trigger, "target") end,
	force_events = true,
	statesParameter = "unit",
	icon = "Interface\\Icons\\INV_Misc_QuestionMark",
	iconFunc = function() return "Interface\\Icons\\INV_Misc_QuestionMark" end,
	nameFunc = function(trigger) return multiUnitName(trigger, "target") end,
	migrate = function(trigger) WA.MultiSelectMigrateGate(trigger, "classification") end,
	init = function(trigger)
		return multiUnitInit(trigger, "target") .. "\n"
			.. "local unitName = UnitName(unit)\n"
			.. "local level = UnitLevel(unit) or 0\n"
			.. "local classFile, classId = UnitClassBase(unit)\n"
			.. "local creatureType = UnitCreatureType(unit) or \"\"\n"
			.. "local classification = UnitClassification(unit) or \"\"\n"
			.. "local isPlayer = UnitIsPlayer(unit) and true or false\n"
			.. "local dead = UnitIsDeadOrGhost(unit) and true or false"
	end,
	args = {
		{ name = "unit", type = "unit", display = "Unit", default = "target",
			valueList = WA.unit_tokens_multi, valueLabels = WA.unit_labels_multi,
			store = true, conditionType = "string" },
		{ name = "exists", type = "hidden", required = true, test = "UnitExists(unit)" },
		{ name = "unitName", type = "string", store = true, conditionType = "string", display = "Name" },
		{ name = "level", type = "number", display = "Level", operator = ">=", store = true, conditionType = "number" },
		{ name = "classFile", type = "hidden", store = true, conditionType = "string", display = "Class" },
		{ name = "creatureType", type = "hidden", store = true, conditionType = "string", display = "Creature Type" },
		{ name = "classification", type = "multiselect", display = "Classification",
			valueList = { "normal", "elite", "rareelite", "rare", "worldboss" },
			valueLabels = { normal = "Normal", elite = "Elite", rareelite = "Rare Elite",
				rare = "Rare", worldboss = "World Boss" },
			default = "elite", store = true, conditionType = "string" },
		{ name = "isPlayer", type = "hidden", store = true, conditionType = "bool", display = "Is Player" },
		{ name = "dead", type = "hidden", store = true, conditionType = "bool", display = "Dead" },
	},
}

-- Custom status and event triggers use upstream's saved field names. Legacy
-- local status records keep their state-first call signature; upstream-shaped
-- functions receive event first.
PROTOTYPES["custom"] = {
	displayName = "Custom",
	category = "custom",
	custom = true,
	progressType = "none",
	events = function(trigger) return parseEventList(trigger and trigger.events) end,
	force_events = true,
	icon = "Interface\\Icons\\INV_Misc_Gear_08",
	iconFunc = function() return "Interface\\Icons\\INV_Misc_Gear_08" end,
	nameFunc = function() return "Custom" end,
	migrate = function(trigger)
		if trigger.customTrigger ~= nil then
			if trigger.custom == nil then
				trigger.custom = trigger.customTrigger
				trigger.weakestAurasLegacyStateArgs = true
			end
			trigger.customTrigger = nil
		end
		if trigger.customEvents ~= nil then
			if trigger.events == nil then trigger.events = trigger.customEvents end
			trigger.customEvents = nil
		end
	end,
	-- No `custom` here: the boilerplate is the editor's opening text, not a
	-- setting, and stamping it at MergeDefaults writes Lua into every aura whose
	-- author only ever glanced at this category. The code field seeds the same
	-- signature the first time it paints.
	defaults = {
		custom_type = "status",
		check = "event",
		events = "",
		custom_hide = "timed",
		duration = 1,
		customDuration = "",
		customName = "",
		customIcon = "",
	},
	args = {},
}

-- Combo points on the current target, static progress (n/5). Always active
-- (like Health/Power) -- the count IS the display; add a condition or filter for
-- "only at 5". GetComboPoints on this client answers for the player's points on
-- the target; passing ("player","target") matches ClassicAPI's 3.3.5 semantics
-- and is harmless if the native form ignores the extra arg.
PROTOTYPES["combopoints"] = {
	displayName = "Combo Points",
	category = "unit",
	progressType = "static",
	progressValue = "comboPoints",
	progressTotal = "maxComboPoints",
	events = function() return { "PLAYER_COMBO_POINTS", "PLAYER_TARGET_CHANGED" } end,
	force_events = true,
	icon = "Interface\\Icons\\Ability_Rogue_Eviscerate",
	iconFunc = function() return "Interface\\Icons\\Ability_Rogue_Eviscerate" end,
	nameFunc = function() return "Combo Points" end,
	init = function()
		return "local comboPoints = GetComboPoints(\"player\", \"target\") or 0\n"
			.. "local maxComboPoints = 5\n"
			.. "local percentComboPoints = comboPoints / maxComboPoints * 100\n"
			.. "local comboPointDeficit = maxComboPoints - comboPoints"
	end,
	args = {
		{ name = "comboPoints", type = "number", display = "Combo Points", operator = ">=",
			store = true, conditionType = "number" },
		{ name = "maxComboPoints", type = "hidden", store = true, conditionType = "number", display = "Max Combo Points" },
		-- Hidden rather than filter rows: the percentage and the deficit of a
		-- 0-5 integer say nothing the count does not, and they exist for the
		-- conditions an imported Power-trigger aura writes against them.
		{ name = "percentComboPoints", type = "hidden", store = true, conditionType = "number",
			display = "Combo Points (%)" },
		{ name = "comboPointDeficit", type = "hidden", store = true, conditionType = "number",
			display = "Combo Point Deficit" },
	},
}

-- Temporary weapon enchant, timed progress. Oils/sharpening stones/shaman
-- imbues/rogue poisons. Fed by WA.WeaponEnchantInfo (which remembers the
-- original duration for a proper depleting bar) + WA_SLOW_TICK for the expiry
-- flip. name comes from the enchant record when resolvable.
PROTOTYPES["weaponenchant"] = {
	displayName = "Weapon Enchant (Temporary)",
	wa2Event = "Weapon Enchant",
	category = "item",
	progressType = "timed",
	events = function() return { "UNIT_INVENTORY_CHANGED", "PLAYER_ENTERING_WORLD", "WA_SLOW_TICK" } end,
	force_events = true,
	loadFunc = function() WA.EnsureSlowTick() end,
	icon = "Interface\\Icons\\INV_Potion_105",
	iconFunc = function() return "Interface\\Icons\\INV_Potion_105" end,
	migrate = function(trigger) renameArg(trigger, "hand", "weapon") end,
	nameFunc = function(trigger)
		local h = trigger.weapon or "main"
		return (h == "off" and "Off Hand Enchant") or (h == "ranged" and "Ranged Enchant") or "Main Hand Enchant"
	end,
	init = function(trigger)
		return "local weapon = " .. fmt(trigger.weapon or "main") .. "\n"
			.. "local has, expirationTime, duration, enchantId = WeakestAuras.WeaponEnchantInfo(weapon)\n"
			.. "local name = \"Weapon Enchant\"\n"
			.. "if enchantId then local ei = C_Item.GetEnchantInfo(enchantId) if ei and ei.name then name = ei.name end end\n"
			.. "local icon = WeakestAuras.WeaponEnchantIcon(weapon, enchantId)\n"
			.. "local remaining = (expirationTime > 0 and (expirationTime - GetTime())) or 0"
	end,
	args = {
		{ name = "weapon", type = "select", required = true, display = "Weapon",
			valueList = { "main", "off", "ranged" },
			valueLabels = { main = "Main Hand", off = "Off Hand", ranged = "Ranged" },
			default = "main" },
		-- Upstream's arg name and values verbatim, so a WA2 import lands it with
		-- no mapping. `showOnMissing` is what the whole rogue poison-reminder
		-- family is built on, and a missing enchant leaves duration and
		-- expirationTime at 0, which the progress guard already tolerates.
		{ name = "showOn", type = "select", required = true, display = "Show",
			valueList = { "showOnActive", "showOnMissing", "showAlways" },
			valueLabels = { showOnActive = "Enchant Found", showOnMissing = "Enchant Missing",
				showAlways = "Always" },
			default = "showOnActive", reloadOptions = true,
			test = function(trigger)
				local mode = trigger.showOn or "showOnActive"
				if mode == "showOnMissing" then return "not has"
				elseif mode == "showAlways" then return "true"
				else return "has" end
			end },
		{ name = "remaining", type = "number", display = "Remaining Time", operator = "<=",
			enable = function(trigger) return (trigger.showOn or "showOnActive") == "showOnActive" end,
			test = function(trigger)
				if not trigger.use_remaining then return nil end
				if (trigger.showOn or "showOnActive") ~= "showOnActive" then return nil end
				return string.format("remaining %s %s",
					safeOp(trigger.remaining_operator or "<="), fmt(trigger.remaining or 0))
			end },
		{ name = "name", type = "hidden", store = true, conditionType = "string", display = "Enchant Name" },
		{ name = "icon", type = "hidden", store = true },
		{ name = "duration", type = "hidden", store = true, conditionType = "number", display = "Duration" },
		{ name = "expirationTime", type = "hidden", store = true, conditionType = "timer", display = "Remaining Time" },
	},
}

-- Reputation with a named faction, static progress within the current standing
-- bar. Niche; the user types the faction name exactly (WA.FactionStanding walks
-- the list for it). standingID 1..8 = Hated..Exalted.
PROTOTYPES["reputation"] = {
	displayName = "Reputation",
	wa2Event = "Faction Reputation",
	category = "unit",
	progressType = "static",
	progressValue = "repValue",
	progressTotal = "repMax",
	events = function() return { "UPDATE_FACTION", "PLAYER_ENTERING_WORLD" } end,
	force_events = true,
	icon = "Interface\\Icons\\INV_BannerPVP_02",
	iconFunc = function() return "Interface\\Icons\\INV_BannerPVP_02" end,
	nameFunc = function(trigger)
		return (trigger.factionName and trigger.factionName ~= "") and trigger.factionName or "Reputation"
	end,
	init = function(trigger)
		return "local standingID, barMin, barMax, barValue, factionName = WeakestAuras.FactionStanding(" .. fmt(trigger.factionName or "") .. ")\n"
			.. "local exists = standingID ~= nil\n"
			.. "local repValue = (barValue and barMin) and (barValue - barMin) or 0\n"
			.. "local repMax = (barMax and barMin) and (barMax - barMin) or 1\n"
			.. "standingID = standingID or 0"
	end,
	args = {
		{ name = "factionName", type = "text", display = "Faction Name" },
		{ name = "exists", type = "hidden", required = true, test = "exists" },
		{ name = "standingID", type = "number", display = "Standing (1-8)", operator = ">=",
			store = true, conditionType = "number" },
		{ name = "repValue", type = "hidden", store = true, conditionType = "number", display = "Bar Value" },
		{ name = "repMax", type = "hidden", store = true, conditionType = "number", display = "Bar Max" },
	},
}

-- Player experience, static progress toward the next level. Guarded for max
-- level (UnitXPMax 0). restedXP is the bonus-rest pool (nil off rested).
PROTOTYPES["experience"] = {
	displayName = "Experience",
	wa2Event = "Experience",
	category = "unit",
	progressType = "static",
	progressValue = "xp",
	progressTotal = "xpMax",
	events = function() return { "PLAYER_XP_UPDATE", "PLAYER_LEVEL_UP", "UPDATE_EXHAUSTION", "PLAYER_ENTERING_WORLD" } end,
	force_events = true,
	icon = "Interface\\Icons\\INV_Misc_Note_01",
	iconFunc = function() return "Interface\\Icons\\INV_Misc_Note_01" end,
	nameFunc = function() return "Experience" end,
	init = function()
		return "local xp = UnitXP(\"player\") or 0\n"
			.. "local xpMax = UnitXPMax(\"player\") or 0\n"
			.. "local restedXP = GetXPExhaustion() or 0\n"
			.. "local xpPercent = (xpMax > 0) and (xp / xpMax * 100) or 0"
	end,
	args = {
		{ name = "xp", type = "number", display = "XP", operator = ">=", store = true, conditionType = "number" },
		{ name = "xpMax", type = "hidden", store = true, conditionType = "number", display = "Max XP" },
		{ name = "xpPercent", type = "number", display = "XP (%)", operator = ">=", store = true, conditionType = "number" },
		{ name = "restedXP", type = "hidden", store = true, conditionType = "number", display = "Rested XP" },
	},
}

-- Character stats (raw values, not ratings -- vanilla has no rating system).
-- Every value comes from WA.CharacterStat, which owns the client's return
-- conventions; the args here only name what to read. Always active -- a status
-- surface for conditions/text, no required gate.
--
-- Only what the client itself holds. Crit, hit, mp5 and weapon skill are not
-- fields on this client and cannot be read at all, so they are absent rather
-- than approximated -- see design/plans/CHARACTER_STATS_PLAN.md.
PROTOTYPES["charstats"] = {
	displayName = "Character Stats",
	wa2Event = "Character Stats",
	category = "unit",
	progressType = "none",
	-- PLAYER_DAMAGE_DONE_MODS is what moves when spell power changes, and
	-- UNIT_INVENTORY_CHANGED is vanilla's equipment-change event.
	events = function()
		return { "UNIT_STATS", "UNIT_ATTACK_POWER", "UNIT_RANGED_ATTACK_POWER", "UNIT_ATTACK",
			"UNIT_ATTACK_SPEED", "UNIT_DAMAGE", "UNIT_DEFENSE", "UNIT_RESISTANCES", "UNIT_AURA",
			"PLAYER_DAMAGE_DONE_MODS", "UNIT_INVENTORY_CHANGED", "PLAYER_ENTERING_WORLD" }
	end,
	subjectUnit = function() return "player" end,
	force_events = true,
	icon = "Interface\\Icons\\INV_Misc_GroupLooking",
	iconFunc = function() return "Interface\\Icons\\INV_Misc_GroupLooking" end,
	nameFunc = function() return "Character Stats" end,
	args = {
		{ type = "header", display = "Primary Stats" },
		{ name = "strength", type = "number", display = "Strength",
			init = [[WeakestAuras.CharacterStat("strength")]],
			multiEntry = true, store = true, conditionType = "number" },
		{ name = "agility", type = "number", display = "Agility",
			init = [[WeakestAuras.CharacterStat("agility")]],
			multiEntry = true, store = true, conditionType = "number" },
		{ name = "stamina", type = "number", display = "Stamina",
			init = [[WeakestAuras.CharacterStat("stamina")]],
			multiEntry = true, store = true, conditionType = "number" },
		{ name = "intellect", type = "number", display = "Intellect",
			init = [[WeakestAuras.CharacterStat("intellect")]],
			multiEntry = true, store = true, conditionType = "number" },
		{ name = "spirit", type = "number", display = "Spirit",
			init = [[WeakestAuras.CharacterStat("spirit")]],
			multiEntry = true, store = true, conditionType = "number" },

		{ type = "header", display = "Attack" },
		{ name = "attackPower", type = "number", display = "Attack Power",
			init = [[WeakestAuras.CharacterStat("attackPower")]],
			multiEntry = true, store = true, conditionType = "number" },
		{ name = "rangedAttackPower", type = "number", display = "Ranged Attack Power",
			init = [[WeakestAuras.CharacterStat("rangedAttackPower")]],
			multiEntry = true, store = true, conditionType = "number" },
		{ name = "mainHandSpeed", type = "number", display = "Main Hand Speed",
			init = [[WeakestAuras.CharacterStat("mainHandSpeed")]],
			multiEntry = true, store = true, conditionType = "number" },
		{ name = "offHandSpeed", type = "number", display = "Off Hand Speed",
			init = [[WeakestAuras.CharacterStat("offHandSpeed")]],
			multiEntry = true, store = true, conditionType = "number" },

		{ type = "header", display = "Spell" },
		{ name = "spellPower", type = "number", display = "Spell Power",
			init = [[WeakestAuras.CharacterStat("spellPower")]],
			multiEntry = true, store = true, conditionType = "number" },
		{ name = "healingPower", type = "number", display = "Healing Power",
			init = [[WeakestAuras.CharacterStat("healingPower")]],
			multiEntry = true, store = true, conditionType = "number" },
		{ name = "spellHaste", type = "number", display = "Spell Haste (%)",
			init = [[WeakestAuras.CharacterStat("spellHaste")]],
			multiEntry = true, store = true, conditionType = "number" },
		-- Per-school spell power is a text placeholder and a condition variable,
		-- not a filter: upstream offers the best school alone, and six more
		-- checkboxes would buy a comparison nobody writes.
		{ name = "spellPowerHoly", type = "hidden", display = "Spell Power (Holy)",
			init = [[WeakestAuras.CharacterStat("spellPowerHoly")]],
			store = true, conditionType = "number" },
		{ name = "spellPowerFire", type = "hidden", display = "Spell Power (Fire)",
			init = [[WeakestAuras.CharacterStat("spellPowerFire")]],
			store = true, conditionType = "number" },
		{ name = "spellPowerNature", type = "hidden", display = "Spell Power (Nature)",
			init = [[WeakestAuras.CharacterStat("spellPowerNature")]],
			store = true, conditionType = "number" },
		{ name = "spellPowerFrost", type = "hidden", display = "Spell Power (Frost)",
			init = [[WeakestAuras.CharacterStat("spellPowerFrost")]],
			store = true, conditionType = "number" },
		{ name = "spellPowerShadow", type = "hidden", display = "Spell Power (Shadow)",
			init = [[WeakestAuras.CharacterStat("spellPowerShadow")]],
			store = true, conditionType = "number" },
		{ name = "spellPowerArcane", type = "hidden", display = "Spell Power (Arcane)",
			init = [[WeakestAuras.CharacterStat("spellPowerArcane")]],
			store = true, conditionType = "number" },

		{ type = "header", display = "Defense" },
		{ name = "armor", type = "number", display = "Armor",
			init = [[WeakestAuras.CharacterStat("armor")]],
			multiEntry = true, store = true, conditionType = "number" },
		{ name = "defense", type = "number", display = "Defense",
			init = [[WeakestAuras.CharacterStat("defense")]],
			multiEntry = true, store = true, conditionType = "number" },
		{ name = "dodge", type = "number", display = "Dodge (%)",
			init = [[WeakestAuras.CharacterStat("dodge")]],
			multiEntry = true, store = true, conditionType = "number" },
		{ name = "parry", type = "number", display = "Parry (%)",
			init = [[WeakestAuras.CharacterStat("parry")]],
			multiEntry = true, store = true, conditionType = "number" },
		{ name = "block", type = "number", display = "Block (%)",
			init = [[WeakestAuras.CharacterStat("block")]],
			multiEntry = true, store = true, conditionType = "number" },

		{ type = "header", display = "Resistance" },
		{ name = "resistHoly", type = "number", display = "Holy Resistance",
			init = [[WeakestAuras.CharacterStat("resistHoly")]],
			multiEntry = true, store = true, conditionType = "number" },
		{ name = "resistFire", type = "number", display = "Fire Resistance",
			init = [[WeakestAuras.CharacterStat("resistFire")]],
			multiEntry = true, store = true, conditionType = "number" },
		{ name = "resistNature", type = "number", display = "Nature Resistance",
			init = [[WeakestAuras.CharacterStat("resistNature")]],
			multiEntry = true, store = true, conditionType = "number" },
		{ name = "resistFrost", type = "number", display = "Frost Resistance",
			init = [[WeakestAuras.CharacterStat("resistFrost")]],
			multiEntry = true, store = true, conditionType = "number" },
		{ name = "resistShadow", type = "number", display = "Shadow Resistance",
			init = [[WeakestAuras.CharacterStat("resistShadow")]],
			multiEntry = true, store = true, conditionType = "number" },
		{ name = "resistArcane", type = "number", display = "Arcane Resistance",
			init = [[WeakestAuras.CharacterStat("resistArcane")]],
			multiEntry = true, store = true, conditionType = "number" },
	},
}

-- Loss of control on the player, timed progress. Upstream's "Crowd Controlled":
-- the first matching C_LossOfControl effect, re-read on LOSS_OF_CONTROL_UPDATE,
-- which ClassicAPI fires when an effect is added, falls off or expires. The type
-- and school options are baked into init's call rather than tested afterwards,
-- since they choose which effect is reported, not whether the one found passes.
PROTOTYPES["crowdcontrol"] = {
	displayName = "Crowd Control",
	wa2Event = "Crowd Controlled",
	category = "unit",
	progressType = "timed",
	events = function() return { "LOSS_OF_CONTROL_UPDATE" } end,
	force_events = true,
	-- The category filter this trigger was saved with before it read
	-- C_LossOfControl. Root, Silence and Disarm are one control type each; CC
	-- (stuns, fears, incapacitates) has no single equivalent and Snare is not a
	-- loss of control at all, so both fall back to any type.
	migrate = function(trigger)
		if trigger.category == nil then return end
		local mapped = ({ Root = "ROOT", Silence = "SILENCE", Disarm = "DISARM" })[trigger.category]
		if mapped and trigger.controlType == nil then
			trigger.controlType = mapped
			trigger.use_controlType = trigger.use_category
		end
		trigger.category, trigger.use_category = nil, nil
	end,
	icon = "Interface\\Icons\\Spell_Nature_Polymorph",
	iconFunc = function() return "Interface\\Icons\\Spell_Nature_Polymorph" end,
	nameFunc = function() return "Crowd Control" end,
	init = function(trigger)
		local controlType = trigger.use_controlType and trigger.controlType or nil
		local schoolMask = controlType == "SCHOOL_INTERRUPT" and trigger.use_interruptSchool
			and tonumber(trigger.interruptSchool) or nil
		return "local active, locType, spellId, name, icon, expirationTime, duration, lockoutSchool = WeakestAuras.PlayerLossOfControl("
			.. fmt(controlType) .. ", " .. fmt(schoolMask) .. ")"
	end,
	args = {
		{ name = "controlType", type = "select", display = "Specific Type",
			valueList = { "STUN", "FEAR", "ROOT", "CONFUSE", "CHARM", "POSSESS", "SILENCE",
				"PACIFY", "PACIFYSILENCE", "DISARM", "SCHOOL_INTERRUPT" },
			valueLabels = { STUN = "Stun", FEAR = "Fear", ROOT = "Root", CONFUSE = "Confuse",
				CHARM = "Charm", POSSESS = "Possess", SILENCE = "Silence", PACIFY = "Pacify",
				PACIFYSILENCE = "Pacify and Silence", DISARM = "Disarm",
				SCHOOL_INTERRUPT = "Interrupt" },
			reloadOptions = true, test = function() return nil end },
		{ name = "interruptSchool", type = "select", display = "Interrupt School",
			valueList = WA.SCHOOL_VALUES, valueLabels = WA.SCHOOL_LABELS,
			default = 4, test = function() return nil end,
			enable = function(trigger) return trigger.use_controlType and trigger.controlType == "SCHOOL_INTERRUPT" end },
		{ name = "inverse", type = "toggle", display = "Inverse" },
		{ name = "active", type = "hidden", required = true, store = true, conditionType = "bool", display = "Under Control",
			test = function(trigger) return trigger.inverse and "not active" or "active" end },
		{ name = "locType", type = "hidden", store = true, conditionType = "string", display = "Control Type" },
		{ name = "spellId", type = "hidden", store = true, conditionType = "number", display = "Spell ID" },
		{ name = "name", type = "hidden", store = true, conditionType = "string", display = "Spell Name" },
		{ name = "icon", type = "hidden", store = true },
		{ name = "lockoutSchool", type = "hidden", store = true, conditionType = "string", display = "Interrupted School" },
		{ name = "expirationTime", type = "hidden", store = true, conditionType = "timer", display = "Remaining Time" },
		{ name = "duration", type = "hidden", store = true, conditionType = "number", display = "Duration" },
	},
}

-- Range to a unit, status. A standalone wrapper over the three range primitives,
-- selected by `rangeMode`:
--   "unit"     -- UnitInRange: a real ~40yd position check (ClassicAPI), the
--                 same primitive the spell-cooldown/health prototypes expose.
--   "interact" -- CheckInteractDistance(unit, index): coarse native bands
--                 (inspect ~28 / trade ~11 / duel ~10 / follow ~28 yd -- index
--                 3 is the melee-ish band UnitInRange's 40yd can't resolve).
--   "spell"    -- WA.SpellInRange: the engine's range check for a named spell.
-- Range changes with movement and there's no movement event, so it leans on
-- WA_FAST_TICK's 0.1s cadence to re-poll (plus a target swap) -- smooth enough
-- for a live distance readout. `distance` is the center-to-center yards from
-- UnitDistanceSquared (ClassicAPI), 0 when the position isn't available.
-- UnitInRange returns (inRange, checkedRange); captured via a direct
-- multi-assign inside the guard, never an `and`-chain (which truncates
-- multi-returns to one value here).
PROTOTYPES["rangecheck"] = {
	displayName = "Range Check",
	wa2Event = "Range Check",
	category = "unit",
	progressType = "none",
	events = function(trigger)
		return appendUnitChangeEvents(trigger,
			{ "WA_FAST_TICK", "PLAYER_ENTERING_WORLD" }, "target")
	end,
	force_events = true,
	loadFunc = function() WA.EnsureFastTick() end,
	icon = "Interface\\Icons\\Ability_Hunter_SniperShot",
	iconFunc = function() return "Interface\\Icons\\Ability_Hunter_SniperShot" end,
	nameFunc = function(trigger)
		local unit = WA.TriggerUnit(trigger, "target")
		return UnitName(unit) or unit
	end,
	init = function(trigger)
		local mode = trigger.rangeMode or "unit"
		local src = "local unit = " .. fmt(WA.TriggerUnit(trigger, "target")) .. "\n"
			.. "local exists = UnitExists(unit) and true or false\n"
			.. "local inRange, checkedRange = false, false\n"
			.. "local distance, checkedDistance = 0, false\n"
		if mode == "interact" then
			src = src .. "if exists and CheckInteractDistance then "
				.. "inRange = CheckInteractDistance(unit, " .. fmt(trigger.interactIndex or 3) .. ") and true or false "
				.. "checkedRange = true end"
		elseif mode == "spell" then
			src = src .. "local spellId = " .. fmt(WA.ResolveSpellID(trigger.spellName) or 0) .. "\n"
				.. "if exists and spellId > 0 then "
				.. "inRange = WeakestAuras.SpellInRange(spellId, unit) "
				.. "checkedRange = true end"
		else
			src = src .. "if exists and UnitInRange then local _r, _c = UnitInRange(unit) "
				.. "inRange = _r and true or false checkedRange = _c and true or false end"
		end
		-- Center-to-center yards, independent of the mode's boolean check, so a
		-- distance readout and a distance filter work in every mode. A real 0
		-- (self, co-located) is indistinguishable from the miss placeholder, so
		-- checkedDistance records whether the position was actually read; the
		-- distance filter gates on it rather than trusting the 0.
		src = src .. "\nif exists and UnitDistanceSquared then "
			.. "local _dsq, _chk = UnitDistanceSquared(unit) "
			.. "if _chk then distance = math.sqrt(_dsq) checkedDistance = true end end"
		return src
	end,
	args = {
		{ name = "unit", type = "unit", display = "Unit", default = "target",
			store = true, conditionType = "string" },
		{ name = "rangeMode", type = "select", required = true, display = "Range Mode",
			valueList = { "unit", "interact", "spell" },
			valueLabels = { unit = "Unit (40yd)", interact = "Interact Band", spell = "Spell Range" },
			default = "unit", reloadOptions = true,
			-- The mode is baked into init's branch, not a runtime local, so it
			-- contributes no test of its own.
			test = function() return nil end },
		{ name = "interactIndex", type = "select", required = true, display = "Interact Band",
			valueList = { 1, 2, 3, 4 },
			valueLabels = { [1] = "Inspect (~28yd)", [2] = "Trade (~11yd)", [3] = "Duel (~10yd)", [4] = "Follow (~28yd)" },
			default = 3,
			-- The band index is baked into the CheckInteractDistance call in init,
			-- not a runtime local, so it contributes no test of its own.
			test = function() return nil end,
			enable = function(trigger) return (trigger.rangeMode or "unit") == "interact" end },
		{ name = "spellName", type = "spell", display = "Spell (for Spell Range)",
			enable = function(trigger) return (trigger.rangeMode or "unit") == "spell" end },
		{ name = "exists", type = "hidden", required = true, test = "exists" },
		-- `distance` is a local from init; the arg only adds the optional filter
		-- and the store, so it declares no init of its own (a `local distance =
		-- distance` would shadow the real one with nil). The filter gates on
		-- checkedDistance so an unknown position (0 placeholder) can't pass a
		-- `<=` test.
		{ name = "distance", type = "number", display = "Distance", operator = "<=",
			store = true, conditionType = "number",
			test = function(trigger)
				if not trigger.use_distance then return nil end
				local op = safeOp(trigger.distance_operator or "<=")
				return string.format("checkedDistance and (distance %s %s)", op, fmt(trigger.distance or 0))
			end },
		{ name = "inRange", type = "hidden", store = true, conditionType = "bool", display = "In Range" },
		{ name = "checkedRange", type = "hidden", store = true, conditionType = "bool", display = "Range Checkable" },
		{ name = "inRangeFilter", type = "toggle", display = "Only if In Range",
			test = function(t) return t.inRangeFilter and "inRange" or nil end },
	},
}

-- Threat, static progress (value/total = pullPct/100, so a bar fills as the mob
-- is about to change hands). No Lua threat API on 1.12: Turtle answers a
-- server-side threat query sent as an addon message, with a table of the top N
-- players on the requester's own target. WA.WatchThreat (below) consumes the
-- reply and sends the query, standing down for anything else on this client
-- that is already asking -- so this needs a party or raid and an elite target,
-- but not TWThreat. `exists` stays false (trigger hidden) until a packet naming
-- the player lands, and goes false again on a target change or when combat ends.
--
-- The two halves of a threat display come off the same rival calculation: not
-- holding the mob, the rival is whoever does and pullGap is the threat left
-- before the player rips it; holding it, the rival is the closest challenger and
-- pullGap is the lead over them. pullPct is the same race as 0..100, threatDiff
-- the plain signed difference. threatpct is the server's own number -- each row's
-- share of its own pull threshold, so it describes whichever row it sits on
-- rather than the player -- so prefer the computed fields.
PROTOTYPES["threat"] = {
	displayName = "Threat",
	wa2Event = "Threat Situation",
	category = "unit",
	progressType = "static",
	progressValue = "pullPct",
	progressTotal = "threatmax",
	events = function() return { "WA_THREAT_CHANGED", "PLAYER_TARGET_CHANGED" } end,
	force_events = true,
	loadFunc = function() WA.WatchThreat() end,
	icon = "Interface\\Icons\\Ability_Threaten",
	iconFunc = function() return "Interface\\Icons\\Ability_Threaten" end,
	nameFunc = function() return "Threat" end,
	init = function() return "local ts = WeakestAuras.ThreatInfo()" end,
	args = {
		{ name = "exists", type = "hidden", required = true, init = "ts.exists", test = "exists" },
		{ name = "pullPct", type = "number", display = "Aggro Race (%)", operator = ">=",
			init = "ts.pullPct or 0", multiEntry = true, store = true, conditionType = "number" },
		{ name = "pullGap", type = "number", display = "Threat Until Swap",
			init = "ts.pullGap or 0", multiEntry = true, store = true, conditionType = "number" },
		{ name = "threatDiff", type = "number", display = "Threat Difference",
			init = "ts.threatDiff or 0", multiEntry = true, store = true, conditionType = "number" },
		{ name = "threat", type = "number", display = "Own Threat",
			init = "ts.threat or 0", store = true, conditionType = "number" },
		{ name = "threatpct", type = "number", display = "Threat (%, server's)", operator = ">=",
			init = "ts.threatpct or 0", store = true, conditionType = "number" },
		{ name = "threatcount", type = "number", display = "Players Listed",
			init = "ts.threatcount or 0", store = true, conditionType = "number" },
		{ name = "aggro", type = "select", display = "Aggro",
			valueList = { "any", "tanking", "notTanking" },
			valueLabels = { any = "Ignore", tanking = "Holding Aggro", notTanking = "Not Holding Aggro" },
			default = "any", test = function(trigger)
				if not trigger.use_aggro or trigger.aggro == "any" then return nil end
				return trigger.aggro == "tanking" and "isTanking" or "(not isTanking)"
			end },
		{ name = "threatmax", type = "hidden", init = "ts.threatmax or 100",
			store = true, conditionType = "number", display = "Threat Max" },
		{ name = "isTanking", type = "hidden", init = "ts.isTanking and true or false",
			store = true, conditionType = "bool", display = "Tanking" },
		{ name = "melee", type = "hidden", init = "ts.melee and true or false",
			store = true, conditionType = "bool", display = "In Melee Range" },
		{ name = "tankName", type = "hidden", init = "ts.tankName",
			store = true, conditionType = "string", display = "Aggro Holder" },
		{ name = "tankThreat", type = "hidden", init = "ts.tankThreat or 0",
			store = true, conditionType = "number", display = "Aggro Holder Threat" },
		{ name = "rivalName", type = "hidden", init = "ts.rivalName",
			store = true, conditionType = "string", display = "Rival" },
		{ name = "rivalThreat", type = "hidden", init = "ts.rivalThreat or 0",
			store = true, conditionType = "number", display = "Rival Threat" },
		-- Stored so a display can anchor itself to the mob's own nameplate: the
		-- NAMEPLATE anchor resolves state.unit, falling back to state.guid.
		{ name = "unit", type = "hidden", init = "ts.unit", store = true,
			conditionType = "string", display = "Unit" },
		{ name = "guid", type = "hidden", init = "ts.guid", store = true,
			conditionType = "string", display = "GUID" },
		{ name = "targetName", type = "hidden", init = "ts.targetName",
			store = true, conditionType = "string", display = "Target Name" },
	},
}

-- Totem in a given element slot, timed progress, off ClassicAPI's GetTotemInfo.
-- PLAYER_TOTEM_UPDATE covers drops, recalls, deaths and expiry; WA_SLOW_TICK
-- only keeps the Remaining Time test current. The totem's name is nil until the
-- client sees the creature, and the update event fires again when it does.
do -- scoped; see the local-ceiling note in the file header

local TOTEM_SLOT_LABELS = { [1] = "Fire", [2] = "Earth", [3] = "Water", [4] = "Air" }
local TOTEM_SLOT_ICONS = {
	[1] = "Interface\\Icons\\Spell_Fire_SearingTotem",
	[2] = "Interface\\Icons\\Spell_Nature_StrengthOfEarthTotem02",
	[3] = "Interface\\Icons\\Spell_Nature_ManaRegenTotem",
	[4] = "Interface\\Icons\\Spell_Nature_InvisibilityTotem",
}
PROTOTYPES["totem"] = {
	displayName = "Totem",
	wa2Event = "Totem",
	category = "spell",
	progressType = "timed",
	events = function() return { "PLAYER_TOTEM_UPDATE", "WA_SLOW_TICK", "PLAYER_ENTERING_WORLD" } end,
	force_events = true,
	loadFunc = function() WA.EnsureSlowTick() end,
	icon = "Interface\\Icons\\Spell_Nature_SearingTotem",
	migrate = function(trigger) renameArg(trigger, "totemSlot", "totemType") end,
	iconFunc = function(trigger) return TOTEM_SLOT_ICONS[trigger.totemType or 1] or "Interface\\Icons\\Spell_Nature_SearingTotem" end,
	nameFunc = function(trigger) return (TOTEM_SLOT_LABELS[trigger.totemType or 1] or "Totem") .. " Totem" end,
	init = function(trigger)
		return "local totemType = " .. fmt(trigger.totemType or 1) .. "\n"
			.. "local _, name, startTime, duration, icon = GetTotemInfo(totemType)\n"
			.. "local active = startTime > 0\n"
			.. "local expirationTime = (startTime > 0 and duration > 0) and (startTime + duration) or 0\n"
			.. "local remaining = (expirationTime > 0 and (expirationTime - GetTime())) or 0"
	end,
	args = {
		{ name = "totemType", type = "select", required = true, display = "Element",
			valueList = { 1, 2, 3, 4 }, valueLabels = TOTEM_SLOT_LABELS, default = 1 },
		{ name = "active", type = "hidden", required = true, test = "active",
			store = true, conditionType = "bool", display = "Active" },
		{ name = "remaining", type = "number", display = "Remaining Time", operator = "<=" },
		{ name = "name", type = "hidden", store = true, conditionType = "string", display = "Totem Name" },
		{ name = "icon", type = "hidden", store = true },
		{ name = "duration", type = "hidden", store = true, conditionType = "number", display = "Duration" },
		{ name = "expirationTime", type = "hidden", store = true, conditionType = "timer", display = "Remaining Time" },
	},
}

end -- totem prototype

-- Swing timer, timed progress per weapon hand. The watcher (below) maintains
-- each hand's swing off ClassicAPI's PLAYER_SWING, plus pfUI's Flurry rescale,
-- the Slam/Hammer-of-Wrath clip warning and the queued on-next-swing ability.
-- Those extras are surfaced as condition variables
-- (blocked/clipWarning/clipDelay/queuedAbility), not a hardcoded bar tint.
PROTOTYPES["swing"] = {
	displayName = "Swing Timer",
	wa2Event = "Swing Timer",
	category = "unit",
	progressType = "timed",
	events = function() return { "WA_SWING_UPDATE", "WA_SLOW_TICK", "PLAYER_ENTERING_WORLD" } end,
	force_events = true,
	loadFunc = function() WA.WatchSwing(); WA.EnsureSlowTick() end,
	icon = "Interface\\Icons\\Ability_Warrior_DecisiveStrike",
	iconFunc = function() return "Interface\\Icons\\Ability_Warrior_DecisiveStrike" end,
	migrate = function(trigger) renameArg(trigger, "swingHand", "hand") end,
	nameFunc = function(trigger)
		local h = trigger.hand or "main"
		return ((h == "off" and "Off Hand") or (h == "ranged" and "Ranged") or "Main Hand") .. " Swing"
	end,
	init = function(trigger)
		return "local hand = " .. fmt(trigger.hand or "main") .. "\n"
			.. "local active, startTime, duration, blocked, clipWarning, clipDelay, queuedAbility = WeakestAuras.SwingInfo(hand)\n"
			.. "active = active and true or false\n"
			.. "startTime = startTime or 0\n"
			.. "duration = duration or 0\n"
			.. "blocked = blocked and true or false\n"
			.. "clipWarning = clipWarning and true or false\n"
			.. "clipDelay = clipDelay or 0\n"
			.. "queuedAbility = queuedAbility or \"none\"\n"
			.. "local expirationTime = (startTime > 0 and duration > 0) and (startTime + duration) or 0\n"
			.. "local remaining = (expirationTime > 0 and (expirationTime - GetTime())) or 0"
	end,
	args = {
		{ name = "hand", type = "select", required = true, display = "Weapon",
			valueList = { "main", "off", "ranged" },
			valueLabels = { main = "Main Hand", off = "Off Hand", ranged = "Ranged" },
			default = "main" },
		{ name = "active", type = "hidden", required = true, test = "active",
			store = true, conditionType = "bool", display = "Swinging" },
		{ name = "remaining", type = "number", display = "Remaining Time", operator = "<=" },
		{ name = "duration", type = "hidden", store = true, conditionType = "number", display = "Swing Speed" },
		{ name = "expirationTime", type = "hidden", store = true, conditionType = "timer", display = "Remaining Time" },
		-- Main-hand-only extras (Slam/HoW clip, ability queue), surfaced as
		-- condition variables the user binds to color/text (no bar-owned tint).
		{ name = "blocked", type = "hidden", store = true, conditionType = "bool", display = "Blocked (casting)" },
		{ name = "clipWarning", type = "hidden", store = true, conditionType = "bool", display = "Clip Warning" },
		{ name = "clipDelay", type = "hidden", store = true, conditionType = "number", display = "Clip Delay" },
		{ name = "queuedAbility", type = "hidden", store = true, conditionType = "string", display = "Queued Ability" },
	},
}

-- Power tick, timed progress, read from WA.WatchPowerTick's inferred cache --
-- no client event fires on the regen tick itself. Inference drifts on a missed
-- or batched power event, and in vanilla spending power does not reset the
-- tick -- both expected, not bugs.
PROTOTYPES["powertick"] = {
	displayName = "Power Tick",
	category = "unit",
	progressType = "timed",
	events = function() return { "WA_POWERTICK_UPDATE", "WA_SLOW_TICK", "PLAYER_ENTERING_WORLD" } end,
	force_events = true,
	loadFunc = function() WA.WatchPowerTick(); WA.EnsureSlowTick() end,
	icon = "Interface\\Icons\\Spell_Nature_Lightning",
	iconFunc = function() return "Interface\\Icons\\Spell_Nature_Lightning" end,
	nameFunc = function() return "Power Tick" end,
	init = function(trigger)
		return "local active, startTime, duration = WeakestAuras.PowerTickInfo()\n"
			.. "active = active and true or false\n"
			.. "startTime = startTime or 0\n"
			.. "duration = duration or 0\n"
			.. "local expirationTime = (startTime > 0 and duration > 0) and (startTime + duration) or 0\n"
			.. "local remaining = (expirationTime > 0 and (expirationTime - GetTime())) or 0"
	end,
	args = {
		{ name = "active", type = "hidden", required = true, test = "active",
			store = true, conditionType = "bool", display = "Ticking" },
		{ name = "remaining", type = "number", display = "Time to Tick", operator = "<=" },
		{ name = "duration", type = "hidden", store = true, conditionType = "number", display = "Tick Interval" },
		{ name = "expirationTime", type = "hidden", store = true, conditionType = "timer", display = "Time to Tick" },
	},
}

-- ---------------------------------------------------------------------------
-- Cooldown watchers (§4.4): one central cache per cooldown *kind* (spell/
-- item/equipment-slot), each polled on its own game-cooldown events + a
-- shared-shape slow ticker, translating the raw API into internal
-- <KIND>_COOLDOWN_CHANGED / _READY events prototypes consume declaratively.
-- Item and equipment-slot cooldowns are a near-clone of the spell-cooldown
-- watcher, so newCooldownWatcher factors the shared cache/ready-timer machinery
-- out once instead of copy-pasting it three times.
-- ---------------------------------------------------------------------------

-- spec: { pollRaw(key) -> start, duration, enabled; changedEvent, readyEvent;
-- extraEvents = { ... } (pcall-registered on the watcher's own frame, e.g.
-- SPELL_UPDATE_COOLDOWN); baseCooldown(key) -> the key's own cooldown in
-- seconds, for the kinds that can answer it }. Returns { Watch(key, wantTick),
-- Info(key) }.
-- `cache` is what the API last said and `announced` is what subscribers were
-- last told. They are separate on purpose: `cache` is refreshed on every read,
-- so no trigger ever evaluates a stale window, and comparing a poll against
-- `cache` would then let a read that happened to land between two polls swallow
-- the change event every *other* aura on that key is owed.

do -- scoped; see the local-ceiling note in the file header

-- A window that is not the key's own cooldown: the global cooldown, and the
-- ranged shot cadence, which this client reports the same way -- firing a wand
-- locks every spell for one ranged swing, and that window's length is the
-- weapon's speed, not 1.5s. Length alone cannot separate those from a real
-- cooldown, since a 1.8s wand and a 1.8s cooldown read identically, so the
-- key's own recovery time decides: a spell whose record carries no recovery has
-- no cooldown of its own, and any window on it belongs to something else.
local SHARED_MAX = 3.0    -- past any wand's swing, and short of every real cooldown in Spell.dbc
local GCD_CEILING = 1.6   -- the 1.5s global cooldown, plus the slack a server's report lands in
local gcdCeiling = GCD_CEILING
local rangedCeiling, rangedStamp = 0, 0

-- `base` is the key's own cooldown in seconds: 0 when it has none, nil when
-- unknown, which is every key that is not a spell. A window is the key's own
-- only if it is that length -- talents shorten a cooldown and nothing lengthens
-- one, so a window longer than the record's is something passing over the key,
-- and a shorter one at these lengths is the global cooldown or a shot.
--
-- Ordered for the hot path: every cooldown trigger runs this on every scan, so
-- a real cooldown -- the common case by far -- exits on the first comparison,
-- and the ranged read is reached only by a window too long to be a global
-- cooldown and short enough to be a shot.
local function isShared(duration, base)
	if duration > SHARED_MAX then return false end
	if duration > gcdCeiling then
		local now = GetTime()
		if now - rangedStamp > 1 then
			rangedStamp = now
			local speed = UnitRangedDamage and UnitRangedDamage("player")
			rangedCeiling = (speed and speed > 0) and (speed + 0.1) or 0
		end
		if duration > rangedCeiling then return false end
	end
	if base == nil or base == 0 then return true end
	return duration < base - 0.05 or duration > base + 0.05
end

-- The global cooldown's measured length, handed over by the watcher that learns
-- it. Never lowers the ceiling below the 1.5s standard: a measurement short
-- enough to do that came off something that was not a global cooldown, and it
-- would take every spell whose own cooldown is shorter than one -- the stances,
-- Shadowform -- down with it.
function WA.SetGcdLength(length)
	gcdCeiling = (length and length + 0.1 > GCD_CEILING) and (length + 0.1) or GCD_CEILING
end

-- The spell's own cooldown in seconds, from its Spell.dbc record: the longer of
-- its own and its category's recovery, since most vanilla cooldowns are the
-- category's (Fire Blast is category 19's 8s). 0 for an unknown spell.
local function spellBaseCooldown(spellId)
	if not (spellId and spellId > 0) then return 0 end
	return (GetSpellBaseCooldown(spellId) or 0) / 1000
end
WA.SpellBaseCooldown = spellBaseCooldown

-- Debug.lua's /wa cdprobe reads the verdict through this; the watchers call the
-- local directly, which is the point of it being one.
function WA.IsSharedCooldown(duration, base)
	return (duration or 0) > 0 and isShared(duration, base)
end

local function newCooldownWatcher(spec)
	local w = { keys = {}, tick = {}, cache = {}, announced = {}, frame = nil, ticker = nil }

	-- Emits nothing, so generated trigger code -- which already runs inside a
	-- scan -- can call it without re-entering dispatch. Mutates the cached
	-- entry in place: every cooldown trigger reads through here on every scan,
	-- and nothing holds the table across calls -- callers take fields off it.
	local function refresh(key)
		local start, duration, enabled = spec.pollRaw(key)
		local c = w.cache[key]
		if not c then
			c = {}
			-- Read once per key: a spell record does not change under a session,
			-- and this keeps the per-scan test down to two comparisons.
			if spec.baseCooldown then c.base = spec.baseCooldown(key) end
			w.cache[key] = c
		end
		c.start = start or 0
		c.duration = duration or 0
		c.enabled = enabled
		return c
	end

	local function pollKey(key)
		local c = refresh(key)
		local a = w.announced[key]
		local changed = not a or a.start ~= c.start or a.duration ~= c.duration
		local running = c.start > 0 and c.duration > 0 and (c.start + c.duration) > GetTime()
		-- Fire on a real change, and additionally every tick while a remaining-time
		-- filter is interested (w.tick), so its threshold flips near real time
		-- rather than only at start/end -- a running cooldown emits no natural event.
		if changed or (w.tick[key] and running) then
			if not a then
				a = {}
				w.announced[key] = a
			end
			a.start = c.start
			a.duration = c.duration
			WA.ScanEvents(spec.changedEvent, key)
		end
		-- Schedule the ready flip for real cooldowns, so the display clears
		-- exactly on time without relying on the ticker's cadence. A shared
		-- window is skipped: it is the global cooldown or a shot cadence passing
		-- over the key, not its own cooldown, and arming a timer for every one of
		-- those would mean a timer per watched key per cast.
		if changed and running and not isShared(c.duration, c.base) then
			local remain = (c.start + c.duration) - GetTime()
			if remain > 0 then
				C_Timer.After(remain + 0.05, function()
					pollKey(key)
					WA.ScanEvents(spec.readyEvent, key)
				end)
			end
		end
		return running
	end

	local pollAll

	-- The poll runs only while something is actually on cooldown. An idle key has
	-- nothing a pass could discover that the client's own cooldown events do not
	-- already deliver, so a watcher whose keys are all ready costs nothing --
	-- which matters because keys are never released (see Watch below). Upstream
	-- suspends its equivalent the same way: cdReadyFrame hides itself, stopping
	-- its OnUpdate, whenever no work is marked pending.
	--
	-- The events on w.frame are what start it again, so this trades the old
	-- always-on pass for a dependency on one of them arriving when a cooldown
	-- begins. They are the canonical ones for each kind and the per-cooldown
	-- expiry timer above still closes the window regardless.
	local function syncTicker(running)
		if running and not w.ticker then
			w.ticker = C_Timer.NewTicker(0.3, function() pollAll() end)
		elseif not running and w.ticker then
			w.ticker:Cancel()
			w.ticker = nil
		end
	end

	pollAll = function()
		local running = false
		for key in pairs(w.keys) do
			if pollKey(key) then running = true end
		end
		syncTicker(running)
	end

	local function ensure()
		if w.frame then return end
		w.frame = CreateFrame("Frame")
		w.frame:SetScript("OnEvent", pollAll)
		-- Guarded: not every 1.12 build fires every one of these, and an unknown
		-- event name would error the whole registration (risk (c), settle per
		-- build with Debug.lua's /wa events pattern).
		for i = 1, #(spec.extraEvents or {}) do
			pcall(w.frame.RegisterEvent, w.frame, spec.extraEvents[i])
		end
	end

	-- Registers a key in the central cooldown cache. wantTick asks the watcher to
	-- re-emit changedEvent every ticker pass while this key is on cooldown (for
	-- remaining-time filters).
	--
	-- Keys are never released, which is deliberate rather than unfinished:
	-- upstream has no unwatch either (its `items[id] = true` is likewise set once
	-- and never cleared, and the refcount on SpellDetails.watched exists to remap
	-- a spell whose override changed, not to free anything on unload). The cost
	-- of a key nothing displays any more is one API read per pass, and only while
	-- some *other* key is running -- syncTicker above is what makes that true.
	local function watch(key, wantTick)
		w.keys[key] = true
		if wantTick then w.tick[key] = true end
		ensure()
		if pollKey(key) then syncTicker(true) end
	end

	-- Generated cooldown-trigger code reads the cache through this. Refreshing
	-- first is what makes it answer for a key nothing has registered yet -- a
	-- force_events pass runs before loadFunc -- and keeps a read that arrives
	-- between two polls current.
	--
	-- The global cooldown and a wand's shot cadence pass over every spell and
	-- item, so a window that is one of those is not a cooldown of this key's own
	-- and is reported as no cooldown at all unless `showgcd` asks for it. That
	-- test belongs here rather than in each prototype's generated code: every
	-- value a trigger derives -- duration, expirationTime, remaining, onCooldown,
	-- ready, usable -- comes off this one read, and filtering per prototype is
	-- how they came to disagree. Excluding is the default so a caller that omits
	-- the flag cannot leak.
	local function info(key, showgcd)
		local c = refresh(key)
		if not showgcd and c.duration > 0 and isShared(c.duration, c.base) then return 0, 0, c.enabled end
		return c.start, c.duration, c.enabled
	end

	return { Watch = watch, Info = info }
end

-- C_Spell.GetSpellCooldown and vanilla's GetSpellCooldown(slot, BOOKTYPE_SPELL)
-- are the same read: ClassicAPI's Script_C_Spell_GetSpellCooldown calls
-- FUN_SPELL_QUERY_COOLDOWN(spellID, bookType=0), which is the helper the slot
-- form reaches after resolving the slot to a spellID (ref ClassicAPI
-- src/spell/Cooldown.cpp). The spellID form is the one to use: the slot form
-- additionally requires the spell to sit in the player's book, so it cannot
-- answer for a talent passive or a profession recipe.
--
-- What this read depends on is the *identity* handed to it -- a spellID with no
-- Spell.dbc row answers nil, and a rank other than the one actually cast has no
-- cooldown of its own. That resolution is WA.ResolveSpellID's job, not this one's.
--
-- The spellID form builds a four-field table per call, though, and this runs for
-- every watched key on each cooldown and usability event and again inside every
-- trigger run. So a spell whose exact rank has a button is read through that
-- slot -- the same query, answered positionally -- and the table form is left
-- for what the book does not hold: a talent passive, a recipe, an unlearned rank.
local spellCdWatch = newCooldownWatcher({
	pollRaw = function(spellId)
		local slot = WA.ExactSpellSlot(spellId)
		if slot then
			local ok, start, duration, enabled = pcall(GetSpellCooldown, slot, BOOKTYPE_SPELL or "spell")
			if ok and start then return start, duration, enabled ~= 0 and enabled ~= false end
		end
		local cdInfo = C_Spell.GetSpellCooldown(spellId)
		if not cdInfo then return nil, nil, nil end
		return cdInfo.startTime, cdInfo.duration, cdInfo.isEnabled
	end,
	baseCooldown = spellBaseCooldown,
	changedEvent = "SPELL_COOLDOWN_CHANGED",
	readyEvent = "SPELL_COOLDOWN_READY",
	extraEvents = { "SPELL_UPDATE_COOLDOWN", "SPELL_UPDATE_USABLE", "ACTIONBAR_UPDATE_COOLDOWN" },
})
function WA.WatchSpellCooldown(spellId, wantTick) spellCdWatch.Watch(spellId, wantTick) end
function WA.SpellCdInfo(spellId, showgcd) return spellCdWatch.Info(spellId, showgcd) end

-- Whether the client has a cooldown record for this spell at all. An id with no
-- Spell.dbc row -- a name that resolved to nothing, a rank that does not exist,
-- a hand-typed number -- reads back as a zero-length cooldown, which is
-- indistinguishable from "ready" unless it is asked about separately. A trigger
-- pointed at a spell the client cannot identify should stay dark rather than
-- claim the spell is permanently off cooldown.
function WA.SpellCdKnown(spellId)
	if not spellId or spellId == 0 then return false end
	if WA.ExactSpellSlot(spellId) then return true end
	return C_Spell.GetSpellCooldown(spellId) ~= nil
end

-- GetItemCooldown returns (start, duration, enable) directly, not a table.
local itemCdWatch = newCooldownWatcher({
	pollRaw = function(itemId)
		local start, duration, enable = GetItemCooldown(itemId)
		return start, duration, enable == 1
	end,
	changedEvent = "ITEM_COOLDOWN_CHANGED",
	readyEvent = "ITEM_COOLDOWN_READY",
	extraEvents = { "BAG_UPDATE_COOLDOWN" },
})
function WA.WatchItemCooldown(itemId, wantTick) itemCdWatch.Watch(itemId, wantTick) end
function WA.ItemCdInfo(itemId, showgcd) return itemCdWatch.Info(itemId, showgcd) end

-- GetInventoryItemCooldown is a native 1.12 global (not a ClassicAPI
-- backport), same (start, duration, enable) shape as GetItemCooldown.
local equipCdWatch = newCooldownWatcher({
	pollRaw = function(slot)
		local start, duration, enable = GetInventoryItemCooldown("player", slot)
		return start, duration, enable == 1
	end,
	changedEvent = "EQUIPSLOT_COOLDOWN_CHANGED",
	readyEvent = "EQUIPSLOT_COOLDOWN_READY",
	extraEvents = { "BAG_UPDATE_COOLDOWN", "PLAYER_EQUIPMENT_CHANGED" },
})
function WA.WatchEquipSlotCooldown(slot, wantTick) equipCdWatch.Watch(slot, wantTick) end
function WA.EquipSlotCdInfo(slot, showgcd) return equipCdWatch.Info(slot, showgcd) end

end -- cooldown watchers

-- Threat watcher: parses the packet Turtle's server-side threat query answers
-- into a cached table describing every player in it, re-emitting
-- WA_THREAT_CHANGED so the threat prototype re-reads it (the incoming addon
-- message is just another event feeding a status update -- fits the existing
-- model with no engine change).
--
-- Packet body: "TWTv4=name:tank:threat:perc:melee;name2:...", five fields to a
-- row and no trailing separator, optionally followed by "#TMTv1=..." when the
-- meter runs in tank mode (ref TWThreat.lua handleThreatPacket). The
-- addon-message prefix is deliberately not checked: the reply is the server's,
-- and it arrives on "TWT " -- with the trailing space -- where TWThreat's own
-- traffic is "TWT", so an exact prefix test drops every packet. TWThreat itself
-- matches the "TWTv4=" marker alone. Plain string.find/sub splitting; this
-- client's Lua 5.0 has no gmatch and the fields are magic-char-free anyway.
--
-- `tank` marks whoever currently holds the mob, which is not the same as top
-- threat: a challenger only takes it at 110% of the holder's threat in melee
-- range and 130% out of it, and each row carries its own melee flag. `perc` is
-- the row's own share of that threshold, so the holder always reads 100 and a
-- challenger reads what pullPct derives below. It is kept as-is and derived
-- from rather than trusted: it is a percentage of *that row's* race, which is
-- the player's only while the player is the one being raced.

do -- scoped; see the local-ceiling note in the file header

local threatCache = { exists = false }
local threatFrame
function WA.WatchThreat()
	if threatFrame then return end

	-- One packet's rows reduced to what the prototype stores. `rival` is whoever
	-- the player is racing for the mob -- the closest challenger when holding it,
	-- the holder otherwise -- and `limit` the threat that flips it, always taken
	-- against the challenger's own melee flag.
	local function digest(rows, count, meRow, tankRow)
		local d = {
			exists = true, threatcount = count,
			threat = meRow.threat, threatpct = meRow.perc, threatmax = 100,
			melee = meRow.melee, isTanking = meRow.tank,
			tankName = tankRow and tankRow.name, tankThreat = tankRow and tankRow.threat or 0,
			unit = "target", guid = UnitGUID("target") or nil,
			targetName = UnitName("target"),
			rivalThreat = 0, threatDiff = 0, pullGap = 0, pullPct = 0,
		}
		local rival, limit
		if meRow.tank then
			for i = 1, count do
				local r = rows[i]
				if r ~= meRow then
					local l = meRow.threat * (r.melee and 1.1 or 1.3)
					if not rival or (l - r.threat) < (limit - rival.threat) then rival, limit = r, l end
				end
			end
		elseif tankRow then
			rival, limit = tankRow, tankRow.threat * (meRow.melee and 1.1 or 1.3)
		end
		if rival then
			-- Rounded at the source: the threshold multiplier makes both a float, and
			-- a raw one reaches a %pullGap text as fifteen digits of noise.
			local challenger = meRow.tank and rival.threat or meRow.threat
			d.rivalName = rival.name
			d.rivalThreat = rival.threat
			d.threatDiff = meRow.threat - rival.threat
			d.pullGap = math.floor(limit - challenger + 0.5)
			d.pullPct = limit > 0 and (math.floor(challenger / limit * 1000 + 0.5) / 10) or 0
		end
		return d
	end

	threatFrame = CreateFrame("Frame")
	-- Guarded like every other event registration here (risk (c)); all three are
	-- native 1.12 events so they should always take.
	pcall(threatFrame.RegisterEvent, threatFrame, "CHAT_MSG_ADDON")
	pcall(threatFrame.RegisterEvent, threatFrame, "PLAYER_TARGET_CHANGED")
	pcall(threatFrame.RegisterEvent, threatFrame, "PLAYER_REGEN_ENABLED")
	pcall(threatFrame.RegisterEvent, threatFrame, "PLAYER_REGEN_DISABLED")
	threatFrame:SetScript("OnEvent", function()
		-- A packet describes the mob the meter last asked about, so a new target,
		-- the start of a fight or the end of one invalidates it wholesale --
		-- otherwise the display keeps counting threat on something that is no
		-- longer being fought.
		if event ~= "CHAT_MSG_ADDON" then
			if threatCache.exists then
				threatCache = { exists = false }
				WA.ScanEvents("WA_THREAT_CHANGED")
			end
			WA.ThreatPollOnEvent(event)
			-- The two moments a threat list is new and nobody has asked about it
			-- yet. Combat start is here because at the pull the target has not
			-- changed, but the list it describes has only just come into being.
			if event == "PLAYER_TARGET_CHANGED" or event == "PLAYER_REGEN_DISABLED" then
				WA.ThreatQueryOnSwitch()
			end
			return
		end
		if not arg2 then return end
		local s, e = string.find(arg2, "TWTv4=", 1, true)
		if not s then return end
		-- Counted before the body is read, and before the player's own row is
		-- required: a packet that left the player out still proves somebody asked.
		WA.ThreatQueryOnReply()
		local body = string.sub(arg2, e + 1)
		local tm = string.find(body, "#", 1, true)
		if tm then body = string.sub(body, 1, tm - 1) end
		local me = UnitName("player")
		local rows, count, meRow, tankRow = {}, 0, nil, nil
		for player in string.gmatch(body, "[^;]+") do
			local name, tank, threat, perc, melee = strsplit(":", player)
			if melee then
				count = count + 1
				rows[count] = { name = name, tank = tank == "1", threat = tonumber(threat) or 0,
					perc = tonumber(perc) or 0, melee = melee == "1" }
				if name == me then meRow = rows[count] end
				if rows[count].tank then tankRow = rows[count] end
			end
		end
		-- The query carries a row limit, so a packet can leave the player out; there
		-- is nothing to report against until one includes them.
		if not meRow then return end
		threatCache = digest(rows, count, meRow, tankRow)
		WA.ScanEvents("WA_THREAT_CHANGED")
	end)
end
function WA.ThreatInfo() return threatCache end

-- The other half of the protocol: the query the reply above answers. The server
-- reads the requester's own selection, so this asks about `target` and nothing
-- else, and it answers whoever asked -- a reply is not broadcast to the channel.
--
-- The gate is most of the work here. One request feeds every consumer on the
-- client through CHAT_MSG_ADDON, so a second sender buys nothing and costs the
-- realm, and a request the server will refuse costs the same as one it answers.
-- Hence the classification test: Turtle's handler declines a `normal` mob
-- outright, which is measured rather than a guess at its `CanHaveThreatList`.
-- `UnitClassification` returns untranslated tokens, so unlike `UnitCreatureType`
-- it is safe to compare against; only `normal` is excluded, because `rare` and
-- `rareelite` have not been shown to fail.

local THREAT_QUERY_PREFIX = "TWT_UDTSv4"
-- What a display can use, not the maximum: the packet costs bytes and the rows
-- past the aggro holder and the player's own are only there to find the closest
-- challenger. A player far enough down a raid's list to fall outside this gets
-- no row and the trigger stays hidden, which is the trade this number sets.
local THREAT_QUERY_LIMIT = 5

local function threatTriggerLoaded()
	local map = loaded_events["WA_THREAT_CHANGED"]
	if not map then return false end
	for _ in pairs(map) do return true end
	return false
end

-- nil when a query is worth making, else the clause that refused it.
function WA.ThreatQueryRefusal()
	if not threatTriggerLoaded() then return "no threat trigger is loaded" end
	if not IsInGroup() then
		return "not in a party or raid"
	end
	if not UnitExists("target") then return "no target" end
	if UnitIsPlayer("target") then return "the target is a player" end
	if UnitIsDead("target") then return "the target is dead" end
	if not UnitCanAttack("player", "target") then return "the target is not attackable" end
	if UnitClassification("target") == "normal" then
		return "the server does not answer for a normal mob"
	end
	-- The player's own combat, not the target's. A mob somebody else is fighting
	-- has a threat list with no row for a player who has not touched it, so there
	-- is nothing for a display to show and, as it happens, nothing the server
	-- answers with. This does not lose the pull: PLAYER_REGEN_DISABLED is the
	-- player entering combat, so the clause is already true when it fires.
	if not UnitAffectingCombat("player") then return "the player is not in combat" end
	return nil
end

-- Who asked. A reply reaches only the client that asked for it, but every addon
-- in that client's process sees it, so a reply this file cannot account for is
-- proof that something else here is querying -- which is the whole of the
-- detection below.
--
-- Accounting is a queue of our own outstanding requests expired by age, not a
-- single "awaiting ours" flag. The flag is simpler and wrong: one request the
-- server never answers would consume the next foreign reply, and then the one
-- after that, for the rest of the session -- the poll would never stand down
-- again. Expiring by age makes that failure decay instead of latch.
--
-- The window is four times the worst round trip measured against the live
-- server (0.08-0.17s) and shorter than the poll, so a request the server drops
-- has aged out before the next one is due.
local THREAT_REPLY_WINDOW = 0.75
local ourRequests = {}
local lastForeignReply = 0

local function expireRequests(now)
	while ourRequests[1] and now - ourRequests[1] > THREAT_REPLY_WINDOW do
		table.remove(ourRequests, 1)
	end
end

local function noteOurRequest(now)
	expireRequests(now)
	table.insert(ourRequests, now)
end

-- One reply, against the requests of ours still young enough to be answered.
function WA.ThreatQueryOnReply()
	local now = GetTime()
	expireRequests(now)
	if ourRequests[1] then table.remove(ourRequests, 1) else lastForeignReply = now end
end

-- false plus the refusing clause, or true plus what went out -- the latter so a
-- caller can report the route as well as the payload, which is the only thing
-- that separates "the message never left" from "nobody answered it".
-- WA.OnThreatQuery, when something has set it, sees every outcome: (info) for a
-- request that left and (nil, reason) for one the gate stopped. Without it the
-- automatic path is unobservable -- a query that was never sent and one the
-- server ignored look identical from outside -- and that is the difference a
-- session watching this protocol most often needs.
function WA.SendThreatQuery(limit)
	local why = WA.ThreatQueryRefusal()
	if why then
		if WA.OnThreatQuery then WA.OnThreatQuery(nil, why) end
		return false, why
	end
	local channel = IsInRaid() and "RAID" or "PARTY"
	local msg = "limit=" .. (limit or THREAT_QUERY_LIMIT)
	WA.SendAddonMessageThrottled(THREAT_QUERY_PREFIX, msg, channel)
	noteOurRequest(GetTime())
	local info = { prefix = THREAT_QUERY_PREFIX, msg = msg, channel = channel }
	if WA.OnThreatQuery then WA.OnThreatQuery(info) end
	return true, info
end

-- Tab-targeting through a pack must cost one request, not one per mob.
local THREAT_SWITCH_THROTTLE = 0.3
-- The request names no unit: the server answers about whatever
-- `GetSelectedCreature()` says the player has selected, so it has to arrive
-- *after* the client's own CMSG_SET_SELECTION for the new target. Sending from
-- inside the PLAYER_TARGET_CHANGED handler races that packet and loses about ten
-- times in eleven, which reads as the server ignoring us. Never send in the
-- event's own frame; this wait is the fix and not a tuning knob.
local THREAT_SWITCH_SETTLE = 0.15
local lastSwitchSend, switchPending = 0, false

-- A target change or a pull, deferred and throttled. Deferred rather than
-- dropped, and that is the point: dropping leaves the one mob the player
-- actually settled on as the one nobody asked about. One timer serves a whole
-- burst, and the gate runs again when it fires, because what armed it may be
-- dead, gone, or a player by then.
function WA.ThreatQueryOnSwitch()
	if switchPending then return end
	local wait = THREAT_SWITCH_THROTTLE - (GetTime() - lastSwitchSend)
	if wait < THREAT_SWITCH_SETTLE then wait = THREAT_SWITCH_SETTLE end
	switchPending = true
	C_Timer.After(wait, function()
		switchPending = false
		-- Only a request that went out arms the throttle; a refusal is not traffic.
		if WA.SendThreatQuery() then lastSwitchSend = GetTime() end
	end)
end

-- The timed query, and the only part of this that stands down. A switch request
-- keeps going out during a hold-off: it costs one message per target change and
-- it is the latency win, where the timer is the sustained traffic.
local THREAT_POLL = 1
-- Twice TWThreat's slowest poll, so one late tick of somebody else's timer does
-- not hand us their fight. Conservative on purpose: what a raid's worth of
-- clients does to the server is not measurable from here.
local THREAT_HOLDOFF = 2.5
local pollTicker

local function pollTick()
	if GetTime() - lastForeignReply < THREAT_HOLDOFF then
		-- Reported, because a poll that has stood down and a poll that never ran
		-- are the same silence from outside and only one of them is right.
		if WA.OnThreatQuery then WA.OnThreatQuery(nil, "something else on this client is asking") end
		return
	end
	WA.SendThreatQuery()
end

-- The poll runs for the length of the player's own fight, which is the only
-- stretch the gate can pass anyway.
--
-- The target-change reset is the load-bearing line. A hold-off is evidence
-- about the mob it was collected on, and carrying it across a switch makes the
-- takeover asymmetric: it goes quiet on time, but starts up a whole hold-off
-- late on every elite->trash switch -- precisely the latency this exists to
-- remove. Nothing has to notice that the other addon came back, either; its
-- first reply re-arms the hold-off on its own.
function WA.ThreatPollOnEvent(event)
	if event == "PLAYER_TARGET_CHANGED" then
		lastForeignReply = 0
	elseif event == "PLAYER_REGEN_DISABLED" then
		if not pollTicker then pollTicker = C_Timer.NewTicker(THREAT_POLL, pollTick) end
	elseif event == "PLAYER_REGEN_ENABLED" then
		if pollTicker then pollTicker:Cancel(); pollTicker = nil end
	end
end

end -- threat watcher

-- Shared dispatch for the player's completed casts: the GCD, swing and Cast
-- Succeeded watchers all consume ClassicAPI's UNIT_SPELLCAST_SUCCEEDED (arg1
-- unit, arg3 spellId), registered once and fanned out to subscribers. The event
-- fans out once per token naming the caster, so only the "player" token counts.
local castSucceededSubs = {}
local castSucceededFrame
local function subscribePlayerCastSucceeded(fn)
	table.insert(castSucceededSubs, fn)
	if castSucceededFrame then return end
	castSucceededFrame = CreateFrame("Frame")
	castSucceededFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
	castSucceededFrame:SetScript("OnEvent", function()
		if arg1 ~= "player" then return end
		local spellId = arg3
		for i = 1, #castSucceededSubs do castSucceededSubs[i](spellId) end
	end)
end

-- ---------------------------------------------------------------------------
-- Global cooldown (§4.4). Upstream's CheckGCD reads a start and duration
-- straight off a dedicated GCD spell -- GetSpellCooldown(29515) on Classic,
-- 61304 elsewhere. Neither ID exists here: they have no 1.12 Spell.dbc row, and
-- this client's GetSpellCooldown takes a spellbook *slot* plus bookType rather
-- than a spellID, so handing it one raises "invalid spell slot" instead of
-- looking anything up.
--
-- What is readable is the same call used the way vanilla means it:
-- GetSpellCooldown(slot, BOOKTYPE_SPELL) answers a true start and duration in
-- GetTime()'s epoch, and a slot whose spell has no cooldown of its own shows
-- the global cooldown and nothing else. So the GCD is read off exactly one such
-- slot, learned from what the player actually casts -- after a completed cast
-- the caster's own slot either reports a GCD-length window (a usable probe,
-- remembered) or a longer one (the spell's own cooldown, keep looking).
--
-- Before a probe is learned the window is latched at the cast instead. Latching
-- rather than re-deriving is the point: a source that only reports a *remaining*
-- time re-reads as a fresh full-length window on every poll, which is a bar that
-- restarts from full several times a second.
-- ---------------------------------------------------------------------------

do -- scoped; see the local-ceiling note in the file header

-- The band a global cooldown can occupy. It is 1.5s, server latency lands the
-- reported window slightly over it, and a rogue's is 1.0s. A window outside the
-- band is something else -- a wand's shot cadence is the one that reaches here
-- -- and latching it would shorten both this watcher's window and the ceiling
-- the cooldown watchers filter against.
local GCD_MIN = 0.9
local GCD_MAX = 1.6
local GCD_DEFAULT = 1.5

local gcd = { start = 0, duration = 0, measured = nil, probeSlot = nil, generation = 0 }

local function gcdEnd()
	if gcd.duration == 0 then return end
	gcd.generation = gcd.generation + 1
	gcd.start, gcd.duration = 0, 0
	WA.ScanEvents("GCD_END")
end

-- Closes the window on its own schedule, so the display clears on time whether
-- or not another cooldown event happens to arrive. The generation stamp makes a
-- timer from a superseded window a no-op instead of ending the current one.
local function gcdSchedule()
	local remain = (gcd.start + gcd.duration) - GetTime()
	if remain <= 0 then return end
	local generation = gcd.generation
	C_Timer.After(remain + 0.05, function()
		if gcd.generation == generation then gcdEnd() end
	end)
end

local function gcdBegin(start, duration)
	-- Same window seen again: keep the latched start and length. Re-deriving them
	-- from a later read is what restarts a running bar.
	if gcd.duration > 0 and math.abs((gcd.start + gcd.duration) - (start + duration)) < 0.1 then return end
	gcd.generation = gcd.generation + 1
	gcd.start, gcd.duration = start, duration
	gcdSchedule()
	WA.ScanEvents("GCD_UPDATE")
end

-- Accepts a window as a measurement of the global cooldown, and publishes the
-- length to the cooldown watchers' filter.
local function gcdMeasure(duration)
	if not duration or duration < GCD_MIN or duration > GCD_MAX then return false end
	gcd.measured = duration
	WA.SetGcdLength(duration)
	return true
end

local function gcdPoll()
	local start, duration = WA.SpellSlotCooldown(gcd.probeSlot)
	if start and gcdMeasure(duration) then
		gcdBegin(start, duration)
	elseif gcd.duration > 0 and (gcd.start + gcd.duration) <= GetTime() then
		gcdEnd()
	end
end

local function gcdOnCast(spellId)
	-- Only spellbook casts: item uses and triggered spells land here too, and
	-- neither starts the GCD. Nor does a ranged auto-attack, though Auto Shot and
	-- Shoot are spellbook spells: each shot locks every spell for the weapon's
	-- speed, which would read as a GCD on every wand shot.
	if C_Spell.IsRangedAutoAttackSpell(spellId) then return end
	local slot = WA.SpellSlotByID(spellId)
	if not slot then return end

	-- Open the window on the cast itself, so the trigger is live before any probe
	-- slot has been learned and stays live for a caster whose own cooldown is
	-- longer than the GCD (its slot can never serve as a probe).
	gcdBegin(GetTime(), gcd.measured or GCD_DEFAULT)

	-- Read a frame later: the cooldown the server applied for this cast has not
	-- landed on the slot at the instant UNIT_SPELLCAST_SUCCEEDED arrives.
	C_Timer.After(0.05, function()
		local start, duration = WA.SpellSlotCooldown(slot)
		if start and gcdMeasure(duration) then
			gcd.probeSlot = slot
			gcdBegin(start, duration)
		end
	end)
end

local gcdFrame
function WA.WatchGCD()
	if gcdFrame then return end
	gcdFrame = CreateFrame("Frame")
	-- Guarded like every other event registration here (risk (c)).
	local events = { "ACTIONBAR_UPDATE_COOLDOWN", "SPELL_UPDATE_COOLDOWN", "SPELLS_CHANGED", "LEARNED_SPELL_IN_TAB" }
	for i = 1, #events do pcall(gcdFrame.RegisterEvent, gcdFrame, events[i]) end
	gcdFrame:SetScript("OnEvent", function()
		if event == "SPELLS_CHANGED" or event == "LEARNED_SPELL_IN_TAB" then
			-- Slot numbers shift as the book grows, so the shared index and the
			-- probe drawn from it both stop meaning anything.
			WA.InvalidateSpellSlots()
			gcd.probeSlot = nil
			return
		end
		gcdPoll()
	end)
	subscribePlayerCastSucceeded(gcdOnCast)
end

-- (start, duration, enabled) of the open window, or (0, 0, true) when none is.
-- Reports an elapsed window as closed but does not close it: generated trigger
-- code calls this from inside a scan, and ending the window there would re-enter
-- dispatch. gcdSchedule's timer is what actually ends it and emits.
function WA.GcdInfo()
	if gcd.duration > 0 and (gcd.start + gcd.duration) <= GetTime() then return 0, 0, true end
	return gcd.start, gcd.duration, true
end

-- The watcher's internals, for Debug.lua's /wa gcd. Which slot it settled on and
-- what length it measured there are the two things the display cannot show and
-- the two the runtime is wrong about when the GCD misbehaves.
function WA.GcdDebug()
	return { probeSlot = gcd.probeSlot, measured = gcd.measured, start = gcd.start,
		duration = gcd.duration, watching = gcdFrame ~= nil }
end

end -- global cooldown

-- Re-emits the shared dispatch as an internal event carrying the spell id, so a
-- trigger reads the cast off the payload instead of re-polling for it.
local spellCastWatching = false
function WA.WatchSpellCast()
	if spellCastWatching then return end
	spellCastWatching = true
	subscribePlayerCastSucceeded(function(spellId)
		WA.ScanEvents("WA_SPELL_CAST_SUCCEEDED", spellId)
	end)
end

-- Swing-timer watcher. ClassicAPI's PLAYER_SWING (arg1 seconds until the next
-- swing, arg2 Enum.PlayerSwingType) owns every timer reset: white hits with
-- extra attacks collapsed, on-next-swing abilities, Auto Shot / Shoot with the
-- wind-up taken off, spells that reset the swing, attack start, weapon swaps
-- and parry haste. What it does not cover stays here, ported from pfUI's
-- modules/swingtimer.lua: the Flurry rescale of an in-flight swing, the
-- Slam/Hammer of Wrath clip warning, and the queued on-next-swing ability. Each
-- hand is stored as {active,start,duration} the region animates, and the extra
-- state is surfaced as condition variables instead of a hardcoded bar tint.

do -- scoped; see the local-ceiling note in the file header

local SWING_PROC_LATENCY = 0.15
-- OctoWoW re-IDs Slam, so swing-delay casts are matched by NAME off
-- UNIT_SPELLCAST_START (rank/id-proof).
local SWING_DELAY_NAMES = { ["Slam"] = true, ["Hammer of Wrath"] = true }
-- Rank-1 canonical names (rank/locale-proof) for on-next-swing classification.
local HS_NAME = C_Spell.GetSpellName(78)
local CLEAVE_NAME = C_Spell.GetSpellName(845)
local MAUL_NAME = C_Spell.GetSpellName(6807)
local SWING_HANDS = { [0] = "main", [1] = "off", [2] = "ranged" }

local swing = {
	main = { active = false, start = 0, duration = 0 },
	off = { active = false, start = 0, duration = 0 },
	ranged = { active = false, start = 0, duration = 0 },
}
local sw = {
	mhSpeed = 0, ohSpeed = 0, raSpeed = 0,
	mhBlocked = false, mhClipWarn = false, mhClipDelay = 0,
	queued = "none", useSQE = false,
	isWarrior = false, hsSlots = {}, cleaveSlots = {},
}
local swingFrame

local function swingUpdateSpeeds()
	local ms, os = UnitAttackSpeed("player")
	if ms and ms > 0 then sw.mhSpeed = ms end
	sw.ohSpeed = (os and os > 0) and os or 0
	local rs = UnitRangedDamage("player")
	sw.raSpeed = (rs and rs > 0) and rs or 0
end

local function classifyOnSwing(spellId)
	if not C_Spell.IsNextMeleeSpell(spellId) then return nil end
	local name = C_Spell.GetSpellName(spellId)
	if name and name == HS_NAME then return "hs"
	elseif name and name == CLEAVE_NAME then return "cleave"
	elseif name and name == MAUL_NAME then return "maul" end
	return nil
end
-- Action-bar slot cache: queue detection fallback for builds without Nampower's
-- SPELL_QUEUE_EVENT. Warriors only (HS/Cleave); rebuilt on bar/equipment change.
local function rebuildQueueSlots()
	sw.hsSlots = {}; sw.cleaveSlots = {}
	if not sw.isWarrior then return end
	for slot = 1, 120 do
		local kind, id = GetActionInfo(slot)
		local name
		if kind == "spell" then name = GetSpellInfo(id)
		elseif kind == "macro" and GetMacroSpell then name = GetMacroSpell(id) end
		if name and name == HS_NAME then table.insert(sw.hsSlots, slot)
		elseif name and name == CLEAVE_NAME then table.insert(sw.cleaveSlots, slot) end
	end
end
local function anyCurrentAction(slots)
	for i = 1, #slots do
		if IsCurrentAction(slots[i]) then return true end
	end
	return false
end
-- The on-next-swing ability currently queued (hs/cleave/maul/none). Nampower's
-- SPELL_QUEUE_EVENT is authoritative once the build fires it (sw.useSQE); else
-- poll the cached action slots live.
function WA.SwingQueued()
	if sw.useSQE then return sw.queued end
	if not sw.isWarrior then return "none" end
	if anyCurrentAction(sw.cleaveSlots) then return "cleave" end
	if anyCurrentAction(sw.hsSlots) then return "hs" end
	return "none"
end

-- A PLAYER_SWING reset. The event gives only the time left, which is shorter
-- than the weapon speed after parry haste or a ranged wind-up, so the bar keeps
-- the full speed and starts in the past rather than restarting from empty.
local function swingReset(hand, remaining)
	swingUpdateSpeeds()
	local speed = (hand == "off" and sw.ohSpeed) or (hand == "ranged" and sw.raSpeed) or sw.mhSpeed
	local duration = (speed > remaining) and speed or remaining
	local s = swing[hand]
	s.start = GetTime() + remaining - duration; s.duration = duration; s.active = true
	if hand == "main" then sw.mhBlocked = false; sw.mhClipWarn = false; sw.mhClipDelay = 0 end
	WA.ScanEvents("WA_SWING_UPDATE")
end
-- Flurry: only a haste GAIN present at swing start (within the proc latency)
-- rescales the in-flight swing; preserve the elapsed fraction by shifting `start`
-- so (now-start)/newDur equals the old elapsed fraction.
local function swingRescale()
	local now = GetTime()
	local oldMh, oldOh = sw.mhSpeed, sw.ohSpeed
	swingUpdateSpeeds()
	local changed = false
	local sm = swing.main
	if sm.active and oldMh > 0 and sw.mhSpeed > 0 and sw.mhSpeed < oldMh
		and (now - sm.start) < SWING_PROC_LATENCY then
		local frac = (now - sm.start) / sm.duration
		if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
		sm.duration = sw.mhSpeed; sm.start = now - frac * sw.mhSpeed; changed = true
	end
	local so = swing.off
	if so.active and oldOh > 0 and sw.ohSpeed > 0 and sw.ohSpeed < oldOh
		and (now - so.start) < SWING_PROC_LATENCY then
		local frac = (now - so.start) / so.duration
		if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
		so.duration = sw.ohSpeed; so.start = now - frac * sw.ohSpeed; changed = true
	end
	if changed then WA.ScanEvents("WA_SWING_UPDATE") end
end
-- A cast that does not reset the swing holds the main-hand auto until it ends;
-- the swing keeps ticking (one that resets it is PLAYER_SWING's). For a
-- named swing-delay cast (Slam / Hammer of Wrath) that will finish AFTER the
-- swing is ready, the auto is clipped by (castDur - remaining) -- surfaced as
-- clipWarning/clipDelay. Any other cast passes 0, which only sets the block.
local function swingBeginDelayCast(castDur)
	if not swing.main.active then return end
	sw.mhBlocked = true
	if castDur > 0 then
		local remaining = (swing.main.start + swing.main.duration) - GetTime()
		local clip = castDur - remaining
		if clip > 0 then sw.mhClipWarn = true; sw.mhClipDelay = clip end
	end
	WA.ScanEvents("WA_SWING_UPDATE")
end
local function swingClearDelayCast()
	if sw.mhBlocked or sw.mhClipWarn then
		sw.mhBlocked = false; sw.mhClipWarn = false; sw.mhClipDelay = 0
		WA.ScanEvents("WA_SWING_UPDATE")
	end
end
-- A landed on-next-swing ability is the queued one going off.
local function swingOnCast(spellId)
	if sw.queued ~= "none" and C_Spell.IsNextMeleeSpell(spellId) then
		sw.queued = "none"
		WA.ScanEvents("WA_SWING_UPDATE")
	end
end
function WA.WatchSwing()
	if swingFrame then return end
	local _, class = UnitClass("player")
	sw.isWarrior = (class == "WARRIOR")
	swingUpdateSpeeds()
	rebuildQueueSlots()
	swingFrame = CreateFrame("Frame")
	local evs = { "PLAYER_SWING", "STOP_AUTOATTACK", "UNIT_ATTACK_SPEED",
		"PLAYER_EQUIPMENT_CHANGED", "PLAYER_ENTERING_WORLD", "ACTIONBAR_SLOT_CHANGED",
		"UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP" }
	for i = 1, #evs do swingFrame:RegisterEvent(evs[i]) end
	-- Nampower's, so guarded: without it the action-slot poll answers instead.
	pcall(swingFrame.RegisterEvent, swingFrame, "SPELL_QUEUE_EVENT")
	swingFrame:SetScript("OnEvent", function()
		if event == "PLAYER_SWING" then
			local hand = SWING_HANDS[arg2]
			if hand then swingReset(hand, arg1) end
		elseif event == "UNIT_ATTACK_SPEED" then
			if arg1 ~= "player" then return end
			swingRescale()
		elseif event == "UNIT_SPELLCAST_START" then
			if arg1 ~= "player" or C_Spell.ResetsMeleeSwing(arg3) then return end
			local castDur = 0
			if SWING_DELAY_NAMES[arg4] then
				local _, _, _, startMs, endMs = C_Spell.UnitCastingInfo("player")
				castDur = ((endMs or 0) - (startMs or 0)) / 1000
			end
			swingBeginDelayCast(castDur)
		elseif event == "UNIT_SPELLCAST_STOP" then
			if arg1 ~= "player" then return end
			swingClearDelayCast()
		elseif event == "SPELL_QUEUE_EVENT" then
			if arg1 == 0 then
				sw.useSQE = true
				local k = classifyOnSwing(arg2 or 0)
				if k then sw.queued = k end
			elseif arg1 == 1 then
				sw.queued = "none"
			end
			WA.ScanEvents("WA_SWING_UPDATE")
		elseif event == "STOP_AUTOATTACK" then
			swing.main.active = false; swing.off.active = false
			WA.ScanEvents("WA_SWING_UPDATE")
		elseif event == "ACTIONBAR_SLOT_CHANGED" then
			rebuildQueueSlots()
		elseif event == "PLAYER_EQUIPMENT_CHANGED" or event == "PLAYER_ENTERING_WORLD" then
			local _, cls = UnitClass("player")
			sw.isWarrior = (cls == "WARRIOR")
			swingUpdateSpeeds()
			if sw.ohSpeed <= 0 then swing.off.active = false end
			rebuildQueueSlots()
		end
	end)
	subscribePlayerCastSucceeded(swingOnCast)
end
-- (active, start, duration, blocked, clipWarning, clipDelay, queuedAbility) or
-- false. blocked/clip/queued are main-hand-only concepts (false/0/"none" else).
function WA.SwingInfo(hand)
	local s = swing[hand] or swing.main
	if not s.active then return false end
	if hand == "main" or hand == nil then
		return true, s.start, s.duration, sw.mhBlocked, sw.mhClipWarn, sw.mhClipDelay, WA.SwingQueued()
	end
	return true, s.start, s.duration, false, false, 0, "none"
end

end -- swing timer

-- Power-tick watcher: no client event fires on the 2s energy / 5s mana regen
-- tick itself, so it's inferred from power-value increases, the same approach
-- pfUI's energytick module uses. Rage and focus have no regen tick.

do -- scoped; see the local-ceiling note in the file header

local POWER_TICK_INTERVAL = { [0] = 5, [3] = 2 }
local pt = {
	active = false, start = 0, duration = 0,
	lastPower = 0, powerType = 0, ignoreNextGain = false,
}
local powerTickFrame

local function powerTickResync()
	pt.powerType = UnitPowerType("player")
	pt.lastPower = UnitMana("player") or 0
	if pt.active then
		pt.active = false
		WA.ScanEvents("WA_POWERTICK_UPDATE")
	end
end
local function powerTickOnPowerEvent()
	local newPower = UnitMana("player") or 0
	local oldPower = pt.lastPower
	pt.lastPower = newPower
	-- In vanilla a spend does not reset the tick, so a decrease is a no-op.
	if newPower < oldPower then return end
	-- A spell gain (e.g. Thistle Tea) also raises power but isn't a tick; the
	-- combat log's energize entry below flags the one that follows so it doesn't
	-- restart the clock. Consumed on any non-decrease, not just a strict
	-- increase, so a gain landing at already-full power doesn't leave the flag
	-- to swallow the next real tick.
	if pt.ignoreNextGain then
		pt.ignoreNextGain = false
		return
	end
	if newPower <= oldPower then return end
	local interval = POWER_TICK_INTERVAL[pt.powerType]
	local max = UnitManaMax("player") or 0
	local full = max > 0 and newPower >= max
	if not interval or full then
		if pt.active then pt.active = false; WA.ScanEvents("WA_POWERTICK_UPDATE") end
		return
	end
	pt.start = GetTime(); pt.duration = interval; pt.active = true
	WA.ScanEvents("WA_POWERTICK_UPDATE")
end
function WA.WatchPowerTick()
	if powerTickFrame then return end
	powerTickResync()
	powerTickFrame = CreateFrame("Frame")
	local evs = { "UNIT_MANA", "UNIT_ENERGY", "UNIT_RAGE", "UNIT_DISPLAYPOWER",
		"PLAYER_ENTERING_WORLD", "COMBAT_LOG_EVENT_UNFILTERED" }
	for i = 1, #evs do powerTickFrame:RegisterEvent(evs[i]) end
	powerTickFrame:SetScript("OnEvent", function()
		if event == "UNIT_DISPLAYPOWER" or event == "PLAYER_ENTERING_WORLD" then
			if arg1 and arg1 ~= "player" then return end
			powerTickResync()
		elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
			-- arg8 destGUID, arg16 powerType. The energize log arrives ahead of
			-- the power update, as the chat line it replaced did.
			if (arg2 == "SPELL_ENERGIZE" or arg2 == "SPELL_PERIODIC_ENERGIZE")
				and arg16 == pt.powerType and arg8 == UnitGUID("player") then
				pt.ignoreNextGain = true
			end
		else
			if arg1 and arg1 ~= "player" then return end
			powerTickOnPowerEvent()
		end
	end)
end
-- (active, start, duration) or false. Rolls the window forward to the current
-- tick boundary if it expired with no power event to advance it (a tick that
-- fired while capped-and-spent, or one the client didn't report).
function WA.PowerTickInfo()
	if not pt.active then return false end
	local now = GetTime()
	if pt.duration > 0 then
		while now >= pt.start + pt.duration do
			pt.start = pt.start + pt.duration
		end
	end
	return true, pt.start, pt.duration
end

end -- power tick

-- ---------------------------------------------------------------------------
-- Event dispatch (§4.3) + the shared game-event frame
-- ---------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local registered = {} -- event -> true, so we RegisterEvent each game event once

local function ensureEventRegistered(event)
	if registered[event] or isInternalEvent(event) then return end
	registered[event] = true
	local compat = EVENT_COMPAT[event]
	if compat then
		for i = 1, #compat do
			pcall(eventFrame.RegisterEvent, eventFrame, compat[i])
		end
		return
	end
	-- Guarded: an invalid event name on this build would otherwise error out the
	-- whole Add (risk (c)).
	pcall(eventFrame.RegisterEvent, eventFrame, event)
end

-- The same registration for a consumer outside this file: a Custom Check
-- condition names its own events, and they have to arrive through the shared
-- frame above rather than through one of the listener's own. A second frame
-- registered for the same name would deliver the event twice -- once to each --
-- so everything that wants a game event asks here and reads it off WA.ScanEvents.
-- An internal WA_* name is accepted and registers nothing, which is correct: it
-- reaches ScanEvents already.
function WA.EnsureGameEventRegistered(event)
	if type(event) ~= "string" or event == "" then return end
	ensureEventRegistered(event)
end

-- The per-frame pulse behind `check = "update"`. Its own frame because an
-- OnUpdate on the shared event frame would run for every display in the addon,
-- and because hiding a frame is how an OnUpdate is switched off -- there is no
-- way to unregister one.
local frameUpdateFrame

-- Runs the OnUpdate iff some loaded trigger listens for it. 1.12 hands the
-- handler its elapsed time as the global arg1.
local function syncFrameUpdate()
	local map = loaded_events["FRAME_UPDATE"]
	local any = false
	if map then
		for _ in pairs(map) do any = true; break end
	end
	if not any then
		if frameUpdateFrame then frameUpdateFrame:Hide() end
		return
	end
	if not frameUpdateFrame then
		frameUpdateFrame = CreateFrame("Frame")
		frameUpdateFrame:SetScript("OnUpdate", function()
			WA.ScanEvents("FRAME_UPDATE", arg1)
		end)
	end
	frameUpdateFrame:Show()
end

-- Whether this trigger accepts one payload of a unit-filtered event. The filter
-- is the local stand-in for upstream's RegisterUnitEvent: the general event is
-- registered, so an unwanted unit has to be dropped here instead of never
-- arriving. Events the trigger declared no filter for always pass.
local function passesUnitFilter(ti, event, unit)
	local filters = ti.unitFilters
	local set = filters and filters[event]
	if not set then return true end
	if unit == nil then return false end
	return set[string.lower(tostring(unit))] and true or false
end

-- The same for "CLEU:SUBEVENT": the combat log's subevent is its arg2.
local function passesSubeventFilter(ti, event, subevent)
	local set = ti.subeventFilter
	if not set or event ~= "COMBAT_LOG_EVENT_UNFILTERED" then return true end
	return subevent ~= nil and set[subevent] and true or false
end

-- A trigger asking for FRAME_UPDATE at every frame is affordable only because it
-- can ask for less. Upstream's onUpdateThrottle, in seconds; 0 means every frame.
local function checkOnUpdateThrottle(ti)
	local throttle = ti.onUpdateThrottle
	if not throttle or throttle <= 0 then return true end
	local now = GetTime()
	if not ti.lastOnUpdate or (now - ti.lastOnUpdate) >= throttle then
		ti.lastOnUpdate = now
		return true
	end
	return false
end

-- watchedTriggers[id][watchedNum][observerNum]: observerNum's "TRIGGER:watchedNum"
-- subscription. Pending/timers hold one coalesced delivery per display.
local watchedTriggers = {}
local watchedPending = {}
local watchedTimers = {}

-- Records one trigger's TRIGGER:n subscriptions, refusing a reciprocal pair.
-- Two triggers watching each other would hand the delivery back and forth
-- forever; upstream drops the second half of the pair, and which half that is
-- falls out of compile order.
local function registerWatchedTriggers(id, observerNum, requested)
	local byWatched = watchedTriggers[id]
	for num in pairs(requested) do
		if num ~= observerNum
			and not (byWatched and byWatched[observerNum] and byWatched[observerNum][num]) then
			byWatched = byWatched or {}
			watchedTriggers[id] = byWatched
			byWatched[num] = byWatched[num] or {}
			byWatched[num][observerNum] = true
		end
	end
end

local function cancelWatchedDelivery(id)
	if watchedTimers[id] then
		watchedTimers[id]:Cancel()
		watchedTimers[id] = nil
	end
	watchedPending[id] = nil
end

-- A fire-and-forget trigger takes itself down on a timer instead of on a later
-- event. C_Timer.NewTimer, not After: After returns nothing on this client, and
-- a re-fire before the deadline must retract the pending hide or the second show
-- gets cut short by the first one's timer.
local function scheduleAutoHide(ti, cloneId)
	cloneId = cloneId or ""
	ti.hideTimers = ti.hideTimers or {}
	local old = ti.hideTimers[cloneId]
	if old then old:Cancel() end
	local timer
	local function hideState()
		if not ti.hideTimers or ti.hideTimers[cloneId] ~= timer then return end
		ti.hideTimers[cloneId] = nil
		local states = WA.GetTriggerStateForTrigger(ti.id, ti.triggernum)
		local s = states and states[cloneId]
		if s and s.show then
			s.show = false; s.changed = true
			WA.UpdatedTriggerState(ti.id)
		end
	end
	timer = C_Timer.NewTimer(ti.duration, hideState)
	ti.hideTimers[cloneId] = timer
end

-- The state is a parameter rather than an upvalue so one function serves every
-- call: a closure per passing event was the commonest garbage in dispatch.
local function setC(state, k, v)
	if state[k] ~= v then state[k] = v; state.changed = true end
end

-- ActivateEvent-lite (§4.3): after a passing test, normalize the state's
-- progress/name/icon. Stores already wrote the raw matched fields; this fills
-- the display-shaped fields regions read. `optionsEvent` marks the options
-- preview's synthetic run, which must not arm the real hide timer -- a preview
-- that took itself down a second after being selected would be unusable.
local function activateEvent(state, ti, cloneId, optionsEvent)
	local proto = ti.proto
	if not state.show then state.show = true; state.changed = true end

	if ti.autoHide then
		-- Its progress is the countdown to its own hide timer, not anything the
		-- prototype stores, and every re-fire restarts both together.
		setC(state, "progressType", "timed")
		setC(state, "duration", ti.duration)
		setC(state, "expirationTime", GetTime() + ti.duration)
		if not optionsEvent then scheduleAutoHide(ti, cloneId) end
	elseif ti.customDurationFunc then
		local ok, v1, v2, isStatic, inverse = WA.RunAuraFunc4(ti.id, ti.id .. ": duration function",
			ti.customDurationFunc, ti.trigger)
		local first = ok and tonumber(v1) or 0
		local second = ok and tonumber(v2) or 0
		setC(state, "inverse", ok and inverse or nil)
		if ok and isStatic then
			setC(state, "progressType", "static")
			setC(state, "value", first)
			setC(state, "total", second)
			setC(state, "duration", nil)
			setC(state, "expirationTime", nil)
		else
			if second <= first then second = first end
			setC(state, "progressType", "timed")
			setC(state, "duration", first)
			setC(state, "expirationTime", second)
			setC(state, "value", nil)
			setC(state, "total", nil)
		end
	else
		-- ti.* overrides let a per-trigger prototype (the custom trigger) pick its
		-- progress shape at Add time; built-in prototypes leave them nil and fall back
		-- to the static proto fields.
		local progressType = ti.progressType or proto.progressType
		local progressValue = ti.progressValue or proto.progressValue
		local progressTotal = ti.progressTotal or proto.progressTotal
		if progressType == "timed" then
			setC(state, "progressType", "timed")
		elseif progressType == "static" then
			setC(state, "progressType", nil)
			setC(state, "value", state[progressValue] or 0)
			setC(state, "total", state[progressTotal] or 0)
		else
			setC(state, "progressType", nil)
		end
	end

	-- ti.name/ti.icon are compile-time constants (nameFunc/iconFunc run once at
	-- Add). A prototype that stores a live `name`/`icon` field (e.g. health/power
	-- reading UnitName each tick) has already written state; only fall back to the
	-- constant when it didn't -- which also keeps a target-unit's display name live
	-- instead of frozen at the target present when the aura was compiled.
	if ti.name ~= nil and state.name == nil then setC(state, "name", ti.name) end
	if ti.icon ~= nil and state.icon == nil then setC(state, "icon", ti.icon) end
	if ti.customNameFunc then
		local ok, value = WA.RunAuraFunc(ti.id, ti.id .. ": name function",
			ti.customNameFunc, ti.trigger)
		if ok then setC(state, "name", value) end
	end
	if ti.customIconFunc then
		local ok, value = WA.RunAuraFunc(ti.id, ti.id .. ": icon function",
			ti.customIconFunc, ti.trigger)
		if ok then setC(state, "icon", value) end
	end
end

-- One member of a multi-unit family: created, refreshed, or dropped in place.
local function runMultiUnitMember(ti, states, event, unit, cloneId)
	local optionsEvent = event == "OPTIONS"
	local state = states[cloneId]
	local existed = state ~= nil
	if not state then state = {} end
	local ok, passed = WA.RunAuraFunc(ti.id, ti.id, ti.triggerFunc, state, event, unit)
	if (ok and passed) or optionsEvent then
		if not existed then
			states[cloneId] = state
			state.changed = true
		end
		activateEvent(state, ti, cloneId, optionsEvent)
		return state.changed and true or false
	elseif existed then
		states[cloneId] = nil
		return true
	end
	return false
end

-- Every current member re-read, and every state whose member is gone dropped.
local function runMultiUnitFullPass(ti, states, event)
	local seen = WA.AcquireScratch()
	local dirty = false
	WA.ForEachMultiUnit(ti.multiUnit, function(unit, cloneId)
		seen[cloneId] = true
		if runMultiUnitMember(ti, states, event, unit, cloneId) then dirty = true end
	end)
	-- Clearing a field mid-traversal is the one table edit `pairs` permits.
	for cloneId in pairs(states) do
		if cloneId ~= "" and not seen[cloneId] then
			states[cloneId] = nil
			dirty = true
		end
	end
	WA.ReleaseScratch(seen)
	return dirty
end

-- Which event means a member left for good. A leaving plate's token still
-- resolves to its unit for the duration of the handler (ClassicAPI computes the
-- token before the slot vacates), so rescanning the family here would re-create
-- the clone that just went away -- its state has to be dropped by GUID instead.
local MULTI_UNIT_REMOVE_EVENT = { nameplate = "NAME_PLATE_UNIT_REMOVED" }

-- Routes one event to the family: a removal drops one state, a unit event
-- re-reads only the member it names, and anything else (roster churn, forced
-- initialization) re-reads the whole family and sweeps what is no longer in it.
local function runMultiUnitTrigger(ti, event, unit)
	local states = WA.GetTriggerStateForTrigger(ti.id, ti.triggernum)
	if not states then return false end
	local family = ti.multiUnit

	if event == MULTI_UNIT_REMOVE_EVENT[family] then
		local cloneId = type(unit) == "string" and WA.UnitCloneId(unit) or nil
		if cloneId and states[cloneId] ~= nil then
			states[cloneId] = nil
			return true
		end
		return false
	end

	if type(unit) == "string" and UnitExists(unit) then
		local cloneId = WA.UnitCloneId(unit)
		local state = cloneId and states[cloneId]
		-- One unit is reachable through several tokens at once (the player in a
		-- raid is also raid7, and maybe target), and ClassicAPI fires the unit
		-- event once per token. The state keeps the token its own family
		-- iterates rather than adopting whichever token woke it.
		if state then return runMultiUnitMember(ti, states, event, state.unit or unit, cloneId) end
		if WA.MultiUnitHasToken(family, unit) then
			return runMultiUnitMember(ti, states, event, unit, cloneId)
		end
		return false
	end

	return runMultiUnitFullPass(ti, states, event)
end

-- A combat log payload runs to 24 values (a damage event's critical flag is the
-- 21st), wider than the nine this dispatch carries. Upstream hands trigger code
-- CombatLogGetCurrentEventInfo() instead, which answers for as long as the
-- event's handler runs -- and every trigger runs inside it. The target is staged
-- in an upvalue for the reason safecall's arguments are: no user code runs
-- between the write and the call that reads it.
--
-- A chat event is wider too: ClassicAPI appends the line ID (arg11) and the
-- sender's GUID (arg12), upstream's layout. GetCurrentChatEvent() hands over all
-- twelve, but only while that event's handler runs, so it is used only when the
-- event in progress is the one being dispatched. A ScanEvents call naming a chat
-- event from anywhere else keeps the payload its caller passed.
--
-- The call is fn(state, event, ...) when `state` is given (a prototype test, a
-- TSU's allstates, a legacy trigger's state), else fn(event, ...).
local runTriggerCode
do
	local cleuTarget
	local function cleuWithState(state, event)
		return cleuTarget(state, event, CombatLogGetCurrentEventInfo())
	end
	local function cleuNoState(event)
		return cleuTarget(event, CombatLogGetCurrentEventInfo())
	end
	local chatTarget
	local function chatWithState(state, event)
		return chatTarget(state, event, select(2, GetCurrentChatEvent()))
	end
	local function chatNoState(event)
		return chatTarget(event, select(2, GetCurrentChatEvent()))
	end
	-- Memoised per name: this runs for every trigger on every dispatch,
	-- FRAME_UPDATE included, and a string.sub per call is garbage.
	local isChatEvent = setmetatable({}, { __index = function(t, name)
		local v = string.sub(name, 1, 9) == "CHAT_MSG_"
		t[name] = v
		return v
	end })
	function runTriggerCode(ti, errTag, fn, state, event, a1, a2, a3, a4, a5, a6, a7, a8, a9)
		if event == "COMBAT_LOG_EVENT_UNFILTERED" or event == "COMBAT_LOG_EVENT" then
			cleuTarget = fn
			if state then return WA.RunAuraFunc(ti.id, errTag, cleuWithState, state, event) end
			return WA.RunAuraFunc(ti.id, errTag, cleuNoState, event)
		end
		if isChatEvent[event] and GetCurrentChatEvent() == event then
			chatTarget = fn
			if state then return WA.RunAuraFunc(ti.id, errTag, chatWithState, state, event) end
			return WA.RunAuraFunc(ti.id, errTag, chatNoState, event)
		end
		if state then
			return WA.RunAuraFunc(ti.id, errTag, fn, state, event, a1, a2, a3, a4, a5, a6, a7, a8, a9)
		end
		return WA.RunAuraFunc(ti.id, errTag, fn, event, a1, a2, a3, a4, a5, a6, a7, a8, a9)
	end
end

-- Runs a Trigger State Updater over its whole allstates table (upstream's `full`
-- statesParameter, §4.3): the custom function owns every clone key and reports
-- either by returning truthy or through the helper methods. Nothing here shapes
-- the states afterwards -- a TSU state supplies its own progress, name and icon,
-- which is the difference between this and activateEvent's normalization.
local function runTsuTrigger(ti, event, a1, a2, a3, a4, a5, a6, a7, a8, a9)
	local states = WA.GetTriggerStateForTrigger(ti.id, ti.triggernum)
	if not states then return false end
	-- Per run, not once at compile: WA.Add builds a fresh allstates table on every
	-- recompile, so the helpers have to be re-attached to whatever table is live.
	WA.EnsureAllStates(states, ti.showNilIsFalse)
	states:SetChanged(false)
	local ok, returned = runTriggerCode(ti, ti.id, ti.triggerFunc, states, event,
		a1, a2, a3, a4, a5, a6, a7, a8, a9)
	local dirty = (ok and (returned or (returned ~= false and states:IsChanged()))) and true or false
	states:SetChanged(false)

	-- Every consumer downstream indexes a clone key expecting a state table. One
	-- non-table poisons the whole trigger rather than one clone, so upstream drops
	-- the table entirely instead of guessing which key the author meant.
	local bad
	for key, state in pairs(states) do
		if type(state) ~= "table" then bad = key; break end
	end
	local allstatesKey = "allstates:" .. ti.triggernum
	if bad then
		WA.ReportForAura(ti.id, allstatesKey, "error", "[" .. ti.id
			.. "] all states table contains a non-table at key: " .. tostring(bad), true)
		local keys = {}
		for key in pairs(states) do table.insert(keys, key) end
		for i = 1, #keys do states[keys[i]] = nil end
		WA.StopStateTimers(ti.id, ti.triggernum)
		return true
	end
	WA.ReportForAura(ti.id, allstatesKey)

	-- Coerced rather than refused, which is upstream's StateShowNil: a state the
	-- author never set `show` on is hidden, and saying so is the only way they find
	-- out why. Never printed -- a trigger can leave it nil on one run and set it on
	-- the next, so a chat line would come and go with the states.
	local showWasNil
	if ti.showNilIsFalse then
		for _, state in pairs(states) do
			if state.show == nil then state.show = false; showWasNil = true end
		end
	end
	WA.ReportForAura(ti.id, "shownil:" .. ti.triggernum, showWasNil and "warning" or nil,
		showWasNil and ("[" .. ti.id .. "] a custom trigger leaves `show` unset on a state, which reads as hidden.") or nil)

	WA.StartStopStateTimers(ti.id, ti.triggernum, states)
	return dirty
end

-- Runs one trigger's compiled function for an event and reconciles its base
-- state or one new event clone.
-- Returns true if the state changed (so the caller batches UpdatedTriggerState).
local function runTriggerFunc(ti, event, a1, a2, a3, a4, a5, a6, a7, a8, a9)
	if ti.tsu then return runTsuTrigger(ti, event, a1, a2, a3, a4, a5, a6, a7, a8, a9) end
	if ti.multiUnit then return runMultiUnitTrigger(ti, event, a1) end
	local states = WA.GetTriggerStateForTrigger(ti.id, ti.triggernum)
	if not states then return false end
	-- The options preview's synthetic event (§14). A test that fails on it says
	-- nothing -- there is no payload to read and no reason for the world to be in
	-- the state being configured -- so the state is activated regardless and the
	-- prototype's own name/icon/progress fill it in. That is what makes a preview
	-- show the trigger's real fields instead of an invented set.
	local optionsEvent = event == "OPTIONS"
	local cloneId = ""
	local state
	if ti.useCloneId then
		state = {}
	else
		state = states[""]
		if not state then state = {}; states[""] = state end
	end

	-- state.changed is false on entry (UpdatedTriggerState clears it after every
	-- batch, step 7), so the flag the compiled stores / activateEvent set is a
	-- true "changed since last apply" signal.
	local ok, passed
	if ti.custom and not ti.legacyStateArgs then
		ok, passed = runTriggerCode(ti, ti.id, ti.triggerFunc, nil, event,
			a1, a2, a3, a4, a5, a6, a7, a8, a9)
	else
		ok, passed = runTriggerCode(ti, ti.id, ti.triggerFunc, state, event,
			a1, a2, a3, a4, a5, a6, a7, a8, a9)
	end
	if (ok and passed) or optionsEvent then
		if ti.useCloneId then
			cloneId = WA.GetUniqueCloneId(states)
			if cloneId == nil then return false end
			states[cloneId] = state
		end
		activateEvent(state, ti, cloneId, optionsEvent)
	elseif ok and ti.untriggerFunc then
		local untriggerOk, shouldHide
		untriggerOk, shouldHide = runTriggerCode(ti, ti.id .. ": untrigger", ti.untriggerFunc,
			ti.legacyStateArgs and state or nil, event, a1, a2, a3, a4, a5, a6, a7, a8, a9)
		if untriggerOk and shouldHide and state.show then
			state.show = false; state.changed = true
		end
	elseif state.show and not ti.autoHide and not ti.eventMode then
		-- Event states end through their declared hide path. A status state follows
		-- its test result directly.
		state.show = false; state.changed = true
	end
	return state.changed and true or false
end

-- Delivers the coalesced TRIGGER:n updates one display accumulated, as
-- ("TRIGGER", watchedTriggernum, thatTrigger'sStates).
local function flushWatchedTriggers(id)
	watchedTimers[id] = nil
	local pending = watchedPending[id]
	watchedPending[id] = nil
	local byWatched = watchedTriggers[id]
	local byTrigger = events[id]
	if not pending or not byWatched or not byTrigger or WA.forced[id] then return end
	local dirty = false
	for watchedNum in pairs(pending) do
		local observers = byWatched[watchedNum]
		local updated = WA.GetTriggerStateForTrigger(id, watchedNum)
		if observers and updated then
			for observerNum in pairs(observers) do
				local ti = byTrigger[observerNum]
				if ti and runTriggerFunc(ti, "TRIGGER", watchedNum, updated) then
					dirty = true
					-- An observer that changed is itself worth watching, so a chain
					-- of TRIGGER:n subscriptions carries one hop per delivery. The
					-- timer for the next hop is scheduled fresh, this one having
					-- already released its slot above.
					WA.NotifyWatchedTriggers(id, observerNum)
				end
			end
		end
	end
	if dirty then WA.UpdatedTriggerState(id) end
end

-- One of a display's triggers produced new states; anything watching it hears so
-- on a zero-delay timer rather than inline. The delay is the recursion guard that
-- matters: a watcher runs after the state pass that woke it has finished, so it
-- cannot re-enter it, and several updates in one pass collapse into one delivery.
-- Called by the state-owned hide timers as well as by dispatch.
function WA.NotifyWatchedTriggers(id, triggernum)
	local byWatched = watchedTriggers[id]
	if not byWatched or not byWatched[triggernum] then return end
	watchedPending[id] = watchedPending[id] or {}
	watchedPending[id][triggernum] = true
	if watchedTimers[id] then return end
	watchedTimers[id] = C_Timer.NewTimer(0, function() flushWatchedTriggers(id) end)
end

-- One registered name's subscribers, delivered under that name. `event` is the
-- name the trigger listed, which is also what passesUnitFilter keys its
-- per-event unit filters by.
-- `dirty` is taken from the scratch pool on the first hit and passed back,
-- because most scans change nothing -- FRAME_UPDATE arrives once a frame.
local function scanRegistered(event, dirty, a1, a2, a3, a4, a5, a6, a7, a8, a9)
	local byId = loaded_events[event]
	if not byId then return dirty end
	for id, byTrigger in pairs(byId) do
		for triggernum, ti in pairs(byTrigger) do
			if not WA.forced[id] and passesUnitFilter(ti, event, a1)
				and passesSubeventFilter(ti, event, a2)
				and (event ~= "FRAME_UPDATE" or checkOnUpdateThrottle(ti)) then
				if runTriggerFunc(ti, event, a1, a2, a3, a4, a5, a6, a7, a8, a9) then
					dirty = dirty or WA.AcquireScratch()
					dirty[id] = true
					WA.NotifyWatchedTriggers(id, triggernum)
				end
			end
		end
	end
	return dirty
end

local function updateDirty(dirty)
	for id in pairs(dirty) do WA.UpdatedTriggerState(id) end
end

-- The producer entry point watchers and the event frame both call (§4.3):
-- walk every trigger registered for `event`, run it, batch one
-- UpdatedTriggerState per affected display. A client event that stands in for
-- retail names (EVENT_COMPAT) also wakes their subscribers, each handed the
-- name it listed rather than the one the client fired.
function WA.ScanEvents(event, a1, a2, a3, a4, a5, a6, a7, a8, a9)
	local dirty = scanRegistered(event, nil, a1, a2, a3, a4, a5, a6, a7, a8, a9)
	local compat = EVENT_COMPAT_SOURCES[event]
	if compat then
		for i = 1, #compat do
			dirty = scanRegistered(compat[i], dirty, a1, a2, a3, a4, a5, a6, a7, a8, a9)
		end
	end
	if dirty then
		WA.RunRelayoutBatch(updateDirty, dirty)
		WA.ReleaseScratch(dirty)
	end
end

-- A handler on this client reads the event payload off the globals arg1..arg9,
-- which exist only for the duration of the handler -- so they are read here and
-- passed explicitly rather than left for ScanEvents to pick up.
eventFrame:SetScript("OnEvent", function()
	if event == "PLAYER_ENTERING_WORLD" then
		C_Timer.After(1, function() WA.ScanEvents("WA_DELAYED_PLAYER_ENTERING_WORLD") end)
	end
	WA.ScanEvents(event, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9)
end)
-- PLAYER_ENTERING_WORLD is the source for the delayed status refresh, so it
-- must be observed even when no active prototype lists the native event.
ensureEventRegistered("PLAYER_ENTERING_WORLD")

-- ---------------------------------------------------------------------------
-- Trigger-system contract (StateMachine.lua calls these)
-- ---------------------------------------------------------------------------

-- Pulls a display's tis out of loaded_events (it stops receiving events) but
-- leaves events[id] intact -- Unload uses this, Delete drops events[id] after.
local function unregisterEvents(id)
	local byTrigger = events[id]
	if not byTrigger then return end
	-- Pending state-owned hides and watched-trigger deliveries, on the same
	-- grounds as the per-trigger hide timers below.
	cancelWatchedDelivery(id)
	WA.StopStateTimers(id)
	for triggernum, ti in pairs(byTrigger) do
		-- A pending hide outlives the events that scheduled it, and would fire
		-- against a display that has since unloaded or been recompiled.
		if ti.hideTimers then
			for _, timer in pairs(ti.hideTimers) do
				if timer then timer:Cancel() end
			end
			ti.hideTimers = nil
		end
		local evs = ti.eventList or {}
		for i = 1, #evs do
			local token = unitChangeToken(evs[i])
			if token then WA.UnwatchUnitToken(token) end
			local map = loaded_events[evs[i]]
			if map and map[id] then map[id][triggernum] = nil end
		end
	end
	-- Drop now-empty per-event maps so ScanEvents doesn't walk dead ids.
	for event, map in pairs(loaded_events) do
		if map[id] then
			local any = false
			for _ in pairs(map[id]) do any = true; break end
			if not any then map[id] = nil end
		end
	end
	syncFrameUpdate()
end

-- Compile only: build each triggernum into a ti stored in events[id]. Neither
-- registers into loaded_events nor force-initializes status triggers -- both
-- wait for LoadDisplays (§11), so an unloaded display costs no events.
function GenericTrigger.Add(data)
	-- Kept across the Delete below so a trigger whose compiled source is
	-- unchanged can be told from one that was edited: the second is a seam for
	-- dropping whatever the old code cached in aura_env, and WA.Add is not --
	-- it fires per drag step.
	local prev = events[data.id] or lastCompiled[data.id]
	GenericTrigger.Delete(data.id)
	local byTrigger = {}
	events[data.id] = byTrigger
	unresolvedIds[data.id] = nil
	WA.ClearWarningPrefix(WA.WarningUidFor(data.id), "unresolved:")
	compilingId = data.id

	for triggernum = 1, #data.triggers do
		local trigger = WA.GetTrigger(data, triggernum)
		local proto = trigger and PROTOTYPES[trigger.type]
		if proto then
			local fn, source, sourceKey, untriggerFunc, customDurationFunc, customNameFunc, customIconFunc
			local tsuVariablesFunc, customEvents, customUnitFilters, customWatched, customSubevents
			local errTag = data.id .. ": trigger " .. triggernum
			local isTsu = proto.custom and trigger.custom_type == "stateupdate"
			if proto.custom then
				fn, source = constructCustomFunction(trigger, errTag)
				local entry = data.triggers[triggernum]
				local untriggerSource = entry.untrigger and entry.untrigger.custom or ""
				-- A TSU never reads the untrigger, so its text must not reach
				-- sourceKey either -- editing code nothing runs is not an edit.
				if isTsu then untriggerSource = "" end
				if WA.TriggerCodeIsLive(trigger, "customVariables") then
					tsuVariablesFunc = compileTsuVariables(trigger.customVariables,
						data.id .. ": custom variables " .. triggernum)
				end
				if WA.TriggerCodeIsLive(trigger, "untrigger") then
					untriggerFunc = compileCustomField(untriggerSource,
						data.id .. ": untrigger " .. triggernum) or trueFunction
				end
				if WA.TriggerCodeIsLive(trigger, "customDuration") then
					customDurationFunc = compileCustomField(trigger.customDuration,
						data.id .. ": duration function " .. triggernum)
				end
				if WA.TriggerCodeIsLive(trigger, "customName") then
					customNameFunc = compileCustomField(trigger.customName,
						data.id .. ": name function " .. triggernum)
				end
				if WA.TriggerCodeIsLive(trigger, "customIcon") then
					customIconFunc = compileCustomField(trigger.customIcon,
						data.id .. ": icon function " .. triggernum)
				end
				if (trigger.custom_type == "status" or isTsu) and trigger.check == "update" then
					customEvents = { "FRAME_UPDATE" }
				else
					customEvents, customUnitFilters, customWatched, customSubevents = parseCustomEventList(trigger.events)
				end
				if customWatched then
					registerWatchedTriggers(data.id, triggernum, customWatched)
				end
				sourceKey = table.concat({ source or "", untriggerSource,
					trigger.customDuration or "", trigger.customName or "", trigger.customIcon or "",
					trigger.customVariables or "" }, "\n")
			else
				fn, source = constructFunction(proto, trigger, errTag)
			end
			sourceKey = sourceKey or source
			local prevTi = prev and prev[triggernum]
			if not prevTi or (prevTi.sourceKey or prevTi.source) ~= sourceKey then
				WA.ClearAuraEnv(data.id)
			end
			if fn then
				local ti = {
					id = data.id, triggernum = triggernum, proto = proto,
					trigger = trigger, triggerFunc = fn, source = source, sourceKey = sourceKey,
					eventMode = (proto.eventMode or (proto.custom and trigger.custom_type == "event")) and true or false,
					useCloneId = (proto.eventMode and trigger.use_cloneId) and true or false,
					multiUnit = proto.statesParameter == "unit" and WA.MultiUnitFamily(trigger) or nil,
					eventList = customEvents or proto.events(trigger),
					name = proto.nameFunc and proto.nameFunc(trigger) or nil,
					icon = proto.iconFunc and proto.iconFunc(trigger) or proto.icon,
					forceEvents = proto.force_events and not (proto.custom and trigger.custom_type == "event"),
				}
				if proto.custom then
					ti.custom = true
					ti.unitFilters = customUnitFilters
					ti.subeventFilter = customSubevents
					ti.onUpdateThrottle = tonumber(trigger.onUpdateThrottle) or 0
					ti.legacyStateArgs = trigger.weakestAurasLegacyStateArgs and true or false
					if isTsu then
						ti.tsu = true
						ti.tsuVariablesFunc = tsuVariablesFunc
						-- Upstream's saved flag for the contract where a state the code
						-- built without setting `show` is hidden rather than left
						-- undecided. An import predating the flag does not carry it and
						-- keeps the older reading; the editor stamps it on an aura that
						-- picks this mode with no `information` of its own.
						ti.showNilIsFalse = (data.information and data.information.showNilIsFalse) and true or false
					else
						ti.untriggerFunc = untriggerFunc
						ti.customDurationFunc = customDurationFunc
						ti.customNameFunc = customNameFunc
						ti.customIconFunc = customIconFunc
						ti.progressType = trigger.customProgressType or "none"
						ti.progressValue = "value"
						ti.progressTotal = "total"
						if trigger.custom_type == "event" and trigger.custom_hide == "timed" then
							ti.autoHide = true
							ti.duration = tonumber(trigger.duration) or 1
						end
					end
				end
				if proto.autoHide then
					ti.autoHide = true
					ti.duration = tonumber(trigger.duration) or 1
				end
				if proto.subjectUnit and not ti.multiUnit then
					ti.unitFilters = subjectUnitFilters(ti.eventList, proto.subjectUnit(trigger))
				end
				-- A prototype listening to the combat log names the subevents it
				-- wants, and dispatch drops the rest before the compiled test runs
				-- -- the same filter a custom trigger's CLEU:SUBEVENT sets.
				if proto.subevents then ti.subeventFilter = proto.subevents(trigger) end
				byTrigger[triggernum] = ti
			end
		end
	end
	compilingId = nil
end

-- Load: register this display's tis into loaded_events (+ RegisterEvent their
-- game events), fire watcher loadFuncs, then force-initialize status triggers
-- (§4.3 force_events) and recombine once. Only touches ids this system
-- compiled (events[id]).
function GenericTrigger.LoadDisplays(ids)
	for k = 1, #ids do
		local id = ids[k]
		local byTrigger = events[id]
		if byTrigger and not activeIds[id] then
			activeIds[id] = true
			local toForce = {}
			for triggernum, ti in pairs(byTrigger) do
				for i = 1, #ti.eventList do
					local ev = ti.eventList[i]
					ensureEventRegistered(ev)
					-- The occupancy watch is refcounted against the same list
					-- loaded_events is keyed by, rather than started from a loadFunc:
					-- unregisterEvents below walks this list too, so the release is
					-- paired by construction instead of by a second lifecycle kept in
					-- step with this one.
					local token = unitChangeToken(ev)
					if token then WA.WatchUnitToken(token) end
					loaded_events[ev] = loaded_events[ev] or {}
					loaded_events[ev][id] = loaded_events[ev][id] or {}
					loaded_events[ev][id][triggernum] = ti
				end
				-- loadFunc (e.g. WatchSpellCooldown) is a "start watching" side
				-- effect, so it belongs to load, not compile -- an unloaded
				-- cooldown aura shouldn't spin up its watcher.
				if ti.proto.loadFunc then ti.proto.loadFunc(ti.trigger) end
				if ti.forceEvents then table.insert(toForce, ti) end
			end
			if #toForce > 0 then
				for i = 1, #toForce do
					local ti = toForce[i]
					if runTriggerFunc(ti, ti.tsu and "STATUS" or "FORCE") then
						WA.NotifyWatchedTriggers(id, ti.triggernum)
					end
				end
				WA.UpdatedTriggerState(id)
			end
		end
	end
	syncFrameUpdate()
end

-- Re-seed an already-loaded display's status triggers (WA2's
-- ScanWithFakeEvent): same force_events pass LoadDisplays runs, for callers that
-- wiped the produced states without a load transition -- the options preview
-- retiring its fake, which otherwise leaves a still-true status trigger reading
-- as inactive until its next real event.
function GenericTrigger.ForceUpdate(ids)
	for k = 1, #ids do
		local id = ids[k]
		local byTrigger = events[id]
		if byTrigger and activeIds[id] then
			local dirty = false
			for triggernum, ti in pairs(byTrigger) do
				if ti.forceEvents then
					if runTriggerFunc(ti, ti.tsu and "STATUS" or "FORCE") then
						dirty = true
						WA.NotifyWatchedTriggers(id, triggernum)
					end
				end
			end
			if dirty then WA.UpdatedTriggerState(id) end
		end
	end
end

-- Unload: pull the display's tis from loaded_events, keeping events[id] so a
-- reload re-registers without recompiling.
function GenericTrigger.UnloadDisplays(ids)
	for k = 1, #ids do
		local id = ids[k]
		if activeIds[id] then
			activeIds[id] = nil
			unregisterEvents(id)
		end
	end
end

function GenericTrigger.Delete(id)
	GenericTrigger.UnloadDisplays({ id })
	-- Handed to the next Add so it can still tell an edited trigger from an
	-- untouched one. WA.Add deletes every system before it re-adds them, so by
	-- the time Add runs, events[id] is already gone and the comparison it makes
	-- would otherwise always report "changed" -- which drops aura_env on every
	-- recompile, including the ones WA.Add fires per drag step.
	if events[id] then lastCompiled[id] = events[id] end
	events[id] = nil
	-- Rebuilt from scratch by the next Add, which is also what makes the
	-- reciprocal-watch refusal depend only on this compile's own order.
	watchedTriggers[id] = nil
	unresolvedIds[id] = nil
	WA.ClearWarningPrefix(WA.WarningUidFor(id), "unresolved:")
	cancelWatchedDelivery(id)
	WA.StopStateTimers(id)
end

function GenericTrigger.Rename(oldId, newId)
	local byTrigger = events[oldId]
	if not byTrigger then return end
	for triggernum, ti in pairs(byTrigger) do
		ti.id = newId
		local evs = ti.eventList or {}
		for i = 1, #evs do
			local map = loaded_events[evs[i]]
			if map and map[oldId] then
				map[newId] = map[oldId]
				map[oldId] = nil
			end
		end
	end
	events[newId] = byTrigger
	events[oldId] = nil
	lastCompiled[oldId] = nil
	if unresolvedIds[oldId] then
		unresolvedIds[newId] = unresolvedIds[oldId]
		unresolvedIds[oldId] = nil
	end
	if activeIds[oldId] then
		activeIds[newId] = true
		activeIds[oldId] = nil
	end
	if watchedTriggers[oldId] then
		watchedTriggers[newId] = watchedTriggers[oldId]
		watchedTriggers[oldId] = nil
	end
	cancelWatchedDelivery(oldId)
	WA.RenameStateTimers(oldId, newId)
end

function GenericTrigger.CreateFallbackState(data, triggernum, state)
	local trigger = WA.GetTrigger(data, triggernum)
	local proto = trigger and PROTOTYPES[trigger.type]
	if proto then
		state.name = proto.nameFunc and proto.nameFunc(trigger) or proto.displayName
		state.icon = proto.iconFunc and proto.iconFunc(trigger) or proto.icon
		if proto.progressType == "timed" then state.progressType = "timed" end
	end
	state.active = false
	return state
end

function GenericTrigger.GetNameAndIcon(data, triggernum)
	local trigger = WA.GetTrigger(data, triggernum)
	local proto = trigger and PROTOTYPES[trigger.type]
	if not proto then return nil, nil end
	local name = proto.nameFunc and proto.nameFunc(trigger) or proto.displayName
	local icon = proto.iconFunc and proto.iconFunc(trigger) or proto.icon
	return name, icon
end

-- How long a preview state's countdown runs before the preview ticker rolls it
-- forward again. WA2's fake-timer window.
local PREVIEW_WINDOW = 7

-- WA2's AddFakeInformation, applied to every state the preview kept. Three
-- things the state as produced cannot carry: a preview must not take itself down
-- on its own deadline; a trigger whose progress is a countdown but which named no
-- deadline needs one or the preview draws an empty bar forever; and a state that
-- reported no name or icon of its own falls back to the prototype's, which is
-- what the aura list row shows for the same trigger.
local function addFakeInformation(data, triggernum, state, ti)
	state.autoHide = false
	local declared = ti and (ti.progressType or (ti.proto and ti.proto.progressType))
	if declared == "timed" and state.expirationTime == nil then
		state.progressType = "timed"
	end
	if state.progressType == "timed" then
		local expirationTime = state.expirationTime
		if not (type(expirationTime) == "number" and expirationTime ~= math.huge
			and expirationTime > GetTime()) then
			state.duration = PREVIEW_WINDOW
			state.expirationTime = GetTime() + PREVIEW_WINDOW
		end
	end
	local name, icon = GenericTrigger.GetNameAndIcon(data, triggernum)
	-- An unconfigured trigger reports "" rather than nil, and "" is truthy in Lua
	-- -- so test for content, not just presence, or the preview shows a blank %n.
	if state.name == nil and name and name ~= "" then state.name = name end
	if state.icon == nil then state.icon = icon end
end

-- The options preview (§14). This system's answer is to run the *real* trigger
-- function under a synthetic "OPTIONS" event and keep whatever states it
-- produced, so a Trigger State Updater previews the clones its own code builds
-- and a prototype previews its own name, icon and progress. Only a run that
-- produced nothing falls back to the synthesised state. Mirrors WA2's
-- GenericTrigger.CreateFakeStates.
--
-- Two deliberate divergences from upstream: it takes `data` rather than an id,
-- as every other contract method here does; and it fabricates no unit token for
-- a multi-unit trigger, because the family's own full pass already re-reads
-- every current member, previewing one clone per member where upstream previews
-- only the family's first token.
function GenericTrigger.CreateFakeStates(data, triggernum)
	local id = data.id
	local states = WA.GetTriggerStateForTrigger(id, triggernum)
	if not states then return end
	-- nil for a trigger that did not compile; the fallback below is then the
	-- whole preview, which is also what it is worth.
	local ti = (events[id] or {})[triggernum]

	if ti then
		-- Trigger code written against a live event payload can throw when run
		-- with none. Upstream's per-aura opt-out is a silent error handler for
		-- exactly this pass; here the handler is not a parameter, so it is a flag
		-- safecall reads. The nested safecall is what guarantees the flag is
		-- cleared even if the run escapes with an error of our own.
		local silence = (data.information and data.information.ignoreOptionsEventErrors) and true or false
		if silence then WA.silenceErrors = true end
		WA.safecall(id .. ": preview trigger " .. triggernum, runTriggerFunc, ti, "OPTIONS")
		WA.silenceErrors = nil
	end

	local shown = 0
	for _, state in pairs(states) do
		if state.show then
			shown = shown + 1
			addFakeInformation(data, triggernum, state, ti)
		end
	end
	if shown == 0 then
		for cloneId in pairs(states) do states[cloneId] = nil end
		local state = {}
		GenericTrigger.CreateFallbackState(data, triggernum, state)
		state.show, state.changed = true, true
		-- Upstream's runtime fallback is always a timed one (duration 0, expiry
		-- infinite) that AddFakeInformation then turns into the rolling window;
		-- ours claims `timed` only when the prototype does, so the preview
		-- supplies the progress upstream's fallback would have carried in.
		state.progressType = state.progressType or "timed"
		states[""] = state
		addFakeInformation(data, triggernum, state, ti)
	end
	-- A TSU's state timers were started from whatever the OPTIONS run left in
	-- `autoHide`, which addFakeInformation has since cleared -- this is what
	-- cancels the deadline that would otherwise hide the preview a second later.
	if ti and ti.tsu then WA.StartStopStateTimers(id, triggernum, states) end
end

-- The variables a Trigger State Updater declares, read out of its compiled
-- customVariables chunk. That chunk is user code, so it runs through the aura
-- environment; a chunk that errors or returns a non-table declares nothing.
-- Public because it is the same answer the editor reports validation against.
function WA.GetTsuVariables(id, triggernum)
	local byTrigger = events[id]
	local ti = byTrigger and byTrigger[triggernum]
	if not ti or not ti.tsuVariablesFunc then return nil end
	local ok, variables = WA.RunAuraFunc(id, id .. ": custom variables " .. triggernum,
		ti.tsuVariablesFunc)
	if not ok then return nil end
	return variables
end

-- Condition variables (§10): every store arg that declared a conditionType.
function GenericTrigger.GetTriggerConditions(data, triggernum)
	local trigger = WA.GetTrigger(data, triggernum)
	local proto = trigger and PROTOTYPES[trigger.type]
	if not proto then return {} end
	-- A TSU declares its own; the prototype has no args to derive them from.
	if proto.custom and trigger.custom_type == "stateupdate" then
		local vars = WA.GetTsuVariables(data.id, triggernum)
		-- A display that is not registered -- an import being translated -- has
		-- no compiled trigger to ask, so the declaration chunk is compiled here
		-- directly, the same evaluation registration would give it.
		if vars == nil and not (events[data.id] and events[data.id][triggernum]) then
			local fn = compileTsuVariables(trigger.customVariables,
				tostring(data.id) .. ": custom variables " .. triggernum)
			if fn then
				local ok, result = WA.RunAuraFunc(data.id,
					tostring(data.id) .. ": custom variables " .. triggernum, fn)
				if ok then vars = result end
			end
		end
		return WA.CleanCustomVariables(vars) or {}
	end
	-- A custom status/event trigger exposes the display-shaped fields its state
	-- machinery actually writes (activateEvent): the progress pair whenever the
	-- state carries one -- a timed event's own window, or whatever the duration
	-- function returns, where the static value/total pair may land instead --
	-- and the name when a name function is set. Mirrors upstream's commonConditions
	-- block for custom triggers; customStacks is read by nothing here and so
	-- deliberately publishes nothing.
	if proto.custom then
		local function live(key, source)
			return WA.TriggerCodeIsLive(trigger, key)
				and type(source) == "string" and string.find(source, "%S") ~= nil
		end
		local out = {}
		local hasDurationFunc = live("customDuration", trigger.customDuration)
		if hasDurationFunc or (trigger.custom_type == "event" and trigger.custom_hide ~= "custom") then
			out.expirationTime = { display = "Remaining Time", type = "timer" }
			out.duration = { display = "Total Duration", type = "number" }
		end
		if hasDurationFunc then
			out.value = { display = "Progress Value", type = "number" }
			out.total = { display = "Progress Total", type = "number" }
		end
		if live("customName", trigger.customName) then
			out.name = { display = "Name", type = "string" }
		end
		return out
	end
	local out = {}
	for i = 1, #proto.args do
		local arg = proto.args[i]
		-- A field the trigger's mode never fills is not offered as a variable.
		if arg.conditionType and not (arg.enable and not arg.enable(trigger)) then
			out[arg.name] = { display = arg.display or arg.name, type = arg.conditionType,
				values = arg.valueLabels }
		end
	end
	return out
end

-- Debug read-only accessor (Debug.lua's /wa gen): the generated source for
-- trigger 1 of this display.
function WA.GetGeneratedSource(id)
	local byTrigger = events[id]
	if not byTrigger then return nil end
	local ti = byTrigger[1]
	for _, t in pairs(byTrigger) do ti = ti or t end
	return ti and ti.source
end

-- Debug read-only accessor (Debug.lua's /wa load): whether this system
-- actually finished registering id into loaded_events, independent of
-- StateMachine's own `loaded[id]` flag -- that flag is set true before
-- applyLoad hands off to each system's LoadDisplays (see StateMachine.lua),
-- so it can say "loaded" even when a system's registration silently never
-- happened. true/false only meaningful for an id this system compiled
-- (events[id] non-nil); nil otherwise.
function WA.IsGenericTriggerActive(id)
	if not events[id] then return nil end
	return activeIds[id] and true or false
end

-- ---------------------------------------------------------------------------
-- Options-side registration: one trigger *type* per prototype, its editor
-- generated from the same args (§4.1). The runtime layer is this one
-- GenericTrigger system, registered for all of them.
-- ---------------------------------------------------------------------------

-- A tristate's three values, as the editor's dropdown spells them. The arg has
-- no default: a nil use_<name> is "ignored", which is also what buildDefaults
-- leaves it as.
local TRISTATE_VALUES = { "ignore", "true", "false" }
local TRISTATE_LABELS = { ignore = "Any", ["true"] = "Yes", ["false"] = "No" }

local function buildDefaults(proto)
	local d = {}
	for i = 1, #proto.args do
		local arg = proto.args[i]
		if arg.type == "unit" then
			d[arg.name] = arg.default or "player"
			d.specificUnit = ""
		elseif arg.type == "range" then
			d[arg.name] = arg.default or 0
		elseif arg.type == "string" then
			if not arg.required then d["use_" .. arg.name] = false end
			d[arg.name .. "_operator"] = arg.operator or "=="
			d[arg.name] = arg.default or ""
		elseif arg.type == "spell" or arg.type == "item" or arg.type == "talent" or arg.type == "text" then
			d[arg.name] = arg.default or ""
		elseif arg.type == "toggle" then
			d[arg.name] = arg.default or false
		elseif arg.type == "select" and arg.required then
			local values = type(arg.valueList) == "function" and arg.valueList(d) or arg.valueList
			d[arg.name] = arg.default or (values and values[1])
		elseif arg.type == "select" and not arg.required then
			d["use_" .. arg.name] = false
			local values = type(arg.valueList) == "function" and arg.valueList(d) or arg.valueList
			d[arg.name] = arg.default or (values and values[1])
		elseif arg.type == "multiselect" then
			-- `false` rather than nil so the key exists in the defaults, which is
			-- what tells the importer this arg takes upstream's multiselect shape.
			d["use_" .. arg.name] = false
			local values = type(arg.valueList) == "function" and arg.valueList(d) or arg.valueList
			d[arg.name] = arg.default or (values and values[1])
			d[arg.name .. "_multi"] = {}
		elseif arg.type == "list" then
			if not arg.required then d["use_" .. arg.name] = false end
			d[arg.name] = {}
		elseif arg.type == "number" and not arg.required then
			d["use_" .. arg.name] = false
			d[arg.name .. "_operator"] = arg.operator or ">="
			d[arg.name] = arg.default or 0
			if arg.multiEntry then
				d["use_" .. arg.name .. "2"] = false
				d[arg.name .. "2_operator"] = arg.operator2 or "<="
				d[arg.name .. "2"] = arg.default2 or 0
			end
		end
	end
	if proto.defaults then
		for k, v in pairs(proto.defaults) do d[k] = v end
	end
	return d
end

local function buildOptions(data, triggernum)
	local t = WA.GetTrigger(data, triggernum or 1)
	local proto = t and PROTOTYPES[t.type]
	if not proto then return WA.TriggerTypeFields(data, t) end

	if proto.custom then
		local fields = WA.TriggerTypeFields(data, t)
		local entry = data.triggers[triggernum or 1]
		entry.untrigger = entry.untrigger or {}
		local function validate(txt, label)
			return WA.Widgets.LuaSyntaxError(WA.WrapFunctionSource(txt), label)
		end
		local optionKey = tostring(data.id or "") .. ":" .. tostring(triggernum or 1)
		local search = customEventSearch[optionKey] or ""
		local eventValues, eventLabels = eventPickerValues(search)
		local isTsu = t.custom_type == "stateupdate"
		local perFrame = isTsu and t.check == "update"
		local more = {
			{ type = "header", name = "Custom Trigger" },
			{ type = "select", name = "Event Type", key = "custom_type",
				values = { "status", "event", "stateupdate" },
				labels = { status = "Status", event = "Event",
					stateupdate = "Trigger State Updater (Advanced)" },
				get = function() return t.custom_type or "status" end,
				set = function(v)
					t.custom_type = v
					if v ~= "status" then t.weakestAurasLegacyStateArgs = nil end
					-- Upstream stamps this on every aura it creates, and a TSU state
					-- that never set `show` reads differently with and without it. An
					-- aura that arrived carrying `information` keeps whatever it said.
					if v == "stateupdate" and data.information == nil then
						data.information = { showNilIsFalse = true }
					end
					WA.Add(data); WA.RefreshOptions()
				end },
		}
		if isTsu then
			table.insert(more, { type = "select", name = "Check On", key = "check",
				values = { "event", "update" },
				labels = { event = "Event(s)", update = "Every Frame" },
				get = function() return t.check or "event" end,
				set = function(v) t.check = v; WA.Add(data); WA.RefreshOptions() end })
		end
		if not perFrame then
			table.insert(more, { type = "multiline", name = "Event(s)", key = "events", height = 72,
				get = function() return t.events or "" end,
				set = function(v) t.events = v; WA.Add(data); WA.RefreshOptions() end })
			table.insert(more, { type = "description", name =
				"Type event names manually above, separated by spaces or commas. "
				.. "Or search below, press Enter, and choose Insert Event." })
			if isTsu then
				table.insert(more, { type = "description", name =
					"UNIT_AURA:player:target fires only for the listed units. TRIGGER:2 "
					.. "runs this trigger when trigger 2 updates. CLEU:SPELL_DAMAGE fires "
					.. "for those combat log subevents only." })
			end
			local invalid, redirected = invalidEventList(t.events)
			if #invalid > 0 then
				table.insert(more, { type = "description", name =
					"|cffff5555Not registered by this client: " .. table.concat(invalid, ", ")
					.. ".|r The names remain saved for addon-generated events." })
			end
			if #redirected > 0 then
				local lines = {}
				for i = 1, #redirected do
					table.insert(lines, redirected[i] .. " ("
						.. table.concat(EVENT_COMPAT[redirected[i]], ", ") .. ")")
				end
				table.insert(more, { type = "description", name =
					"|cffffd100Fires here through this client's own events:|r "
					.. table.concat(lines, "; ")
					.. ". The trigger receives the name listed above." })
			end
			-- A "__" key names a session-local control (this writes a search box's
			-- text, not aura data) -- the marker is what lets a reader of keys tell
			-- the two apart.
			table.insert(more, { type = "input", name = "Find Event", key = "__findEvent", half = true,
				get = function() return customEventSearch[optionKey] or "" end,
				set = function(v) customEventSearch[optionKey] = v or ""; WA.RefreshOptions() end })
			table.insert(more, { type = "menu", name = "Insert Event", half = true,
				values = eventValues, labels = eventLabels,
				onSelect = function(v)
					if v == "__NO_EVENT_MATCH__" then return end
					t.events = appendEventName(t.events, v)
					WA.Add(data); WA.RefreshOptions()
				end })
		end
		if perFrame or (isTsu and t.events and string.find(t.events, "FRAME_UPDATE", 1, true)) then
			table.insert(more, { type = "range", name = "Throttle (s)", key = "onUpdateThrottle",
				min = 0, max = 1, step = 0.01, decimals = 2,
				get = function() return tonumber(t.onUpdateThrottle) or 0 end,
				set = function(v) t.onUpdateThrottle = v; WA.Add(data) end })
		end
		table.insert(more, { type = "code", name = "Custom Trigger", key = "custom", height = 180,
				get = function() return t.custom end,
				set = function(v) t.custom = v; WA.Add(data) end,
				default = (isTsu and "function(allstates, event, ...)\n    return true\nend")
					or (t.weakestAurasLegacyStateArgs
						and "function(state, event, ...)\n    return true\nend")
					or "function(event, ...)\n    return true\nend",
				validate = function(txt) return validate(txt, "custom trigger") end })
		if isTsu then
			table.insert(more, { type = "code", name = "Custom Variables", key = "customVariables", height = 140,
				get = function() return t.customVariables or "" end,
				set = function(v) t.customVariables = v; WA.Add(data); WA.RefreshOptions() end,
				default = "{\n    stacks = \"number\",\n}",
				validate = function(txt)
					return WA.Widgets.LuaSyntaxError(
						WA.WrapFunctionSource("function() return \n" .. (txt or "") .. "\n end"),
						"custom variables")
				end })
			-- The syntax check above only proves the chunk compiles. What the table
			-- *says* is checked by running it, which is too much to do per keystroke,
			-- so the declaration's own problems are reported off the compiled trigger.
			local declared = WA.GetTsuVariables(data.id, triggernum or 1)
			local problem = declared ~= nil and WA.ValidateCustomVariables(declared) or nil
			if problem then
				table.insert(more, { type = "description",
					name = "|cffff5555Custom Variables: " .. problem .. "|r" })
			end
			table.insert(more, { type = "description", name =
				"State fields shown here: show, changed, progressType, value, total, "
				.. "duration, expirationTime, autoHide, paused, remaining, name, icon, "
				.. "stacks, index, inverse." })
			table.insert(more, { type = "description", name =
				"This code also runs once when the aura loads, with event = \"STATUS\" "
				.. "and no payload, so it can seed itself from the current world. Check "
				.. "`event` before building state from an argument the load pass has no "
				.. "value for." })
		end
		if t.weakestAurasLegacyStateArgs then
			table.insert(more, { type = "select", name = "Legacy Progress", key = "customProgressType",
				values = { "none", "timed", "static" },
				labels = { none = "None", timed = "Timed", static = "Static" },
				get = function() return t.customProgressType or "none" end,
				set = function(v) t.customProgressType = v; WA.Add(data) end })
		end
		if t.custom_type == "event" then
			table.insert(more, { type = "select", name = "Hide", key = "custom_hide",
				values = { "timed", "custom" }, labels = { timed = "Timed", custom = "Custom" },
				get = function() return t.custom_hide or "timed" end,
				set = function(v) t.custom_hide = v; WA.Add(data); WA.RefreshOptions() end })
			if t.custom_hide ~= "custom" then
				table.insert(more, { type = "range", name = "Duration (s)", key = "duration",
					min = 0.1, max = 60, step = 0.1,
					get = function() return tonumber(t.duration) or 1 end,
					set = function(v) t.duration = v; WA.Add(data) end })
			end
		end
		-- Everything below is a second source for a value TSU state already carries,
		-- so this mode shows none of it. The saved fields survive untouched, and a
		-- trigger switched back out of TSU gets its editors back with its text.
		if not isTsu then
			if t.custom_type == "status" or t.custom_hide == "custom" then
				table.insert(more, { type = "code", name = "Custom Untrigger", key = "customUntrigger", height = 140,
					get = function() return entry.untrigger.custom end,
					set = function(v) entry.untrigger.custom = v; WA.Add(data) end,
					default = t.weakestAurasLegacyStateArgs
						and "function(state, event, ...)\n    return true\nend"
						or "function(event, ...)\n    return true\nend",
					validate = function(txt) return validate(txt, "custom untrigger") end })
				table.insert(more, { type = "code", name = "Duration Info", key = "customDuration", height = 140,
					get = function() return t.customDuration or "" end,
					set = function(v) t.customDuration = v; WA.Add(data) end,
					validate = function(txt) return validate(txt, "duration info") end })
			end
			table.insert(more, { type = "code", name = "Name Info", key = "customName", height = 120,
				get = function() return t.customName or "" end,
				set = function(v) t.customName = v; WA.Add(data) end,
				validate = function(txt) return validate(txt, "name info") end })
			table.insert(more, { type = "code", name = "Icon Info", key = "customIcon", height = 120,
				get = function() return t.customIcon or "" end,
				set = function(v) t.customIcon = v; WA.Add(data) end,
				validate = function(txt) return validate(txt, "icon info") end })
		end
		for i = 1, #more do table.insert(fields, more[i]) end
		return fields
	end

	local fields = WA.TriggerTypeFields(data, t)

	for i = 1, #proto.args do
		local arg = proto.args[i]
		-- An arg whose enable() is false is inapplicable to the trigger's selected
		-- mode (a spell field while the range mode is "interact"): its control is
		-- omitted rather than rendered as a field nothing reads. Visibility only --
		-- the stored value and the arg's test are untouched, so an arg that goes
		-- back into view keeps what it had.
		if arg.enable and not arg.enable(t) then
			-- inapplicable to this configuration
		elseif arg.hidden or arg.type == "hidden" then
			-- computed/stored only, no UI
		elseif arg.type == "header" then
			table.insert(fields, { type = "header", name = arg.display or "" })
		elseif arg.type == "unit" then
			-- The dropdown's "specific" entry swaps in a free-text token field
			-- beside it; the dropdown's stored token survives being hidden and
			-- comes back when the override is switched off.
			table.insert(fields, {
				type = "select", name = arg.display or "Unit", key = arg.name, half = true,
				values = arg.valueList or WA.unit_tokens,
				labels = arg.valueLabels or WA.unit_labels,
				get = function() return t[arg.name] end,
				set = function(v) t[arg.name] = v; WA.Add(data); WA.RefreshOptions() end,
			})
			if t[arg.name] == "specific" then
				table.insert(fields, {
					type = "input", name = "Unit Token", key = "specificUnit", half = true,
					get = function() return t.specificUnit or "" end,
					set = function(v) t.specificUnit = v; WA.Add(data) end,
				})
			end
		elseif arg.type == "spell" then
			table.insert(fields, {
				type = "spell", name = arg.display or "Spell", key = arg.name,
				get = function() return t[arg.name] or "" end,
				set = function(v) t[arg.name] = v; WA.Add(data) end,
			})
		elseif arg.type == "talent" then
			table.insert(fields, {
				type = "talent", name = arg.display or "Talent", key = arg.name,
				get = function() return t[arg.name] or "" end,
				set = function(v) t[arg.name] = v; WA.Add(data) end,
				resolve = function(v)
					local found, _, _, _, tab, tier, column, icon = WA.TalentInfo(v,
						(t.usePlacement and tonumber(t.talentTab)) or 0,
						(t.usePlacement and tonumber(t.talentTier)) or 0,
						(t.usePlacement and tonumber(t.talentColumn)) or 0)
					return found and icon or nil
				end,
			})
		elseif arg.type == "item" then
			table.insert(fields, {
				type = "item", name = arg.display or "Item", key = arg.name,
				get = function() return t[arg.name] or "" end,
				set = function(v) t[arg.name] = v; WA.Add(data) end,
			})
		elseif arg.type == "text" then
			table.insert(fields, {
				type = "input", name = arg.display or arg.name, key = arg.name,
				get = function() return t[arg.name] or "" end,
				set = function(v) t[arg.name] = v; WA.Add(data) end,
			})
		elseif arg.type == "range" then
			-- A plain bounded number, no operator: the value *is* the setting
			-- rather than one side of a comparison, so it contributes no test.
			table.insert(fields, {
				type = "range", name = arg.display or arg.name, key = arg.name,
				min = arg.min or 0, max = arg.max or 100, step = arg.step or 1,
				decimals = arg.decimals,
				get = function() return t[arg.name] or arg.default or 0 end,
				set = function(v) t[arg.name] = v; WA.Add(data) end,
			})
		elseif arg.type == "string" then
			table.insert(fields, {
				type = "toggle", name = arg.display or arg.name, key = "use_" .. arg.name,
				get = function() return t["use_" .. arg.name] end,
				set = function(v) t["use_" .. arg.name] = v; WA.Add(data); WA.RefreshOptions() end,
			})
			if t["use_" .. arg.name] then
				table.insert(fields, {
					type = "select", name = arg.display or arg.name, key = arg.name .. "_operator", half = true,
					values = STRING_OPS, labels = STRING_OP_LABELS,
					get = function() return t[arg.name .. "_operator"] end,
					set = function(v) t[arg.name .. "_operator"] = v; WA.Add(data) end,
				})
				table.insert(fields, {
					type = "input", name = "Text", key = arg.name, half = true,
					get = function() return t[arg.name] or "" end,
					set = function(v) t[arg.name] = v; WA.Add(data) end,
				})
			end
		elseif arg.type == "toggle" then
			table.insert(fields, {
				type = "toggle", name = arg.display or arg.name, key = arg.name,
				get = function() return t[arg.name] end,
				set = function(v)
					t[arg.name] = v; WA.Add(data)
					if arg.reloadOptions then WA.RefreshOptions() end
				end,
			})
		elseif arg.type == "tristate" then
			-- Three states in one control. A checkbox cannot cycle nil/true/false,
			-- so the dropdown writes the same use_<name> key upstream's does.
			table.insert(fields, {
				type = "select", name = arg.display or arg.name, key = "use_" .. arg.name, half = true,
				values = TRISTATE_VALUES, labels = TRISTATE_LABELS,
				get = function()
					local use = t["use_" .. arg.name]
					if use == nil then return "ignore" end
					return use and "true" or "false"
				end,
				set = function(v)
					if v == "ignore" then t["use_" .. arg.name] = nil
					else t["use_" .. arg.name] = (v == "true") end
					WA.Add(data)
				end,
			})
		elseif arg.type == "select" and arg.required then
			table.insert(fields, {
				type = "select", name = arg.display or arg.name, key = arg.name,
				values = type(arg.valueList) == "function" and arg.valueList(t) or (arg.valueList or arg.values),
				labels = type(arg.valueLabels) == "function" and arg.valueLabels(t) or arg.valueLabels,
				get = function() return t[arg.name] end,
				set = function(v)
					-- Subclass ids are only meaningful inside their class, so a class
					-- change drops whatever the old class's list had selected --
					-- both the single value and the set, since either mode can be
					-- the one on display when the class is changed.
					if arg.name == "itemClassID" and t.type == "itemtypeequipped" then
						local subclassValues = itemSubclassValues(v)
						local valid = {}
						for j = 1, #subclassValues do valid[subclassValues[j]] = true end
						if not valid[t.itemSubclassID] then t.itemSubclassID = subclassValues[1] end
						local set = t.itemSubclassID_multi
						for value in pairs(set or {}) do
							if not valid[value] then set[value] = nil end
						end
					end
					t[arg.name] = v; WA.Add(data)
					if arg.reloadOptions then WA.RefreshOptions() end
				end,
			})
		elseif arg.type == "select" then
			table.insert(fields, {
				type = "toggle", name = "Use " .. (arg.display or arg.name), key = "use_" .. arg.name,
				get = function() return t["use_" .. arg.name] end,
				set = function(v) t["use_" .. arg.name] = v; WA.Add(data); WA.RefreshOptions() end,
			})
			if t["use_" .. arg.name] then
				table.insert(fields, {
					type = "select", name = arg.display or arg.name, key = arg.name,
					values = arg.valueList or arg.values, labels = arg.valueLabels,
					get = function() return t[arg.name] end,
					set = function(v)
						t[arg.name] = v; WA.Add(data)
						if arg.reloadOptions then WA.RefreshOptions() end
					end,
				})
			end
		elseif arg.type == "list" then
			table.insert(fields, {
				type = "toggle", name = arg.display or arg.name, key = "use_" .. arg.name,
				get = function() return t["use_" .. arg.name] end,
				set = function(v) t["use_" .. arg.name] = v; WA.Add(data); WA.RefreshOptions() end,
			})
			if t["use_" .. arg.name] then
				table.insert(fields, {
					type = "namelist", name = arg.listLabel or arg.display or arg.name, key = arg.name,
					tooltip = arg.tooltip,
					get = function()
						if type(t[arg.name]) ~= "table" then t[arg.name] = {} end
						return t[arg.name]
					end,
					onChange = function() WA.Add(data) end,
				})
			end
		elseif arg.type == "multiselect" then
			WA.MultiSelectFields(fields, {
				config = t, name = arg.name, display = arg.display or arg.name,
				default = arg.default,
				values = type(arg.valueList) == "function" and arg.valueList(t)
					or (arg.valueList or arg.values),
				labels = type(arg.valueLabels) == "function" and arg.valueLabels(t)
					or arg.valueLabels,
				onChange = function(repaint)
					WA.Add(data)
					if repaint then WA.RefreshOptions() end
				end,
			})
		elseif arg.type == "number" then
			table.insert(fields, {
				type = "toggle", name = arg.display or arg.name, key = "use_" .. arg.name,
				get = function() return t["use_" .. arg.name] end,
				set = function(v) t["use_" .. arg.name] = v; WA.Add(data); WA.RefreshOptions() end,
			})
			if t["use_" .. arg.name] then
				table.insert(fields, {
					type = "opnumber", name = arg.display or arg.name, key = arg.name,
					getOp = function() return t[arg.name .. "_operator"] end,
					setOp = function(v) t[arg.name .. "_operator"] = v; WA.Add(data) end,
					getVal = function() return t[arg.name] end,
					setVal = function(v) t[arg.name] = v; WA.Add(data) end,
				})
				-- The second bound is offered only once the first is on, since a
				-- range with no lower half is just the upper half on its own.
				if arg.multiEntry then
					table.insert(fields, {
						type = "toggle", name = "And " .. (arg.display or arg.name),
						key = "use_" .. arg.name .. "2",
						get = function() return t["use_" .. arg.name .. "2"] end,
						set = function(v)
							t["use_" .. arg.name .. "2"] = v; WA.Add(data); WA.RefreshOptions()
						end,
					})
					if t["use_" .. arg.name .. "2"] then
						table.insert(fields, {
							type = "opnumber", name = arg.display or arg.name, key = arg.name .. "2",
							getOp = function() return t[arg.name .. "2_operator"] end,
							setOp = function(v) t[arg.name .. "2_operator"] = v; WA.Add(data) end,
							getVal = function() return t[arg.name .. "2"] end,
							setVal = function(v) t[arg.name .. "2"] = v; WA.Add(data) end,
						})
					end
				end
			end
		end
	end
	return fields
end

local function buildSummary(proto)
	return function(data)
		local t = WA.GetTrigger(data, 1)
		if not t then return proto.displayName end
		if t.spellName and t.spellName ~= "" then
			return proto.displayName .. ": " .. t.spellName
		end
		if t.unit then
			return proto.displayName .. " (" .. WA.TriggerUnit(t, "player") .. ")"
		end
		return proto.displayName
	end
end

local systemTypes = {}
for typeName, proto in pairs(PROTOTYPES) do
	-- A prototype gated on a client mod that isn't installed registers no type at
	-- all, so it never reaches the picker rather than appearing there and failing
	-- when chosen. Feature-by-feature degradation, not a second load gate.
	if not proto.enable or proto.enable() then
		WA.RegisterTriggerType(typeName, {
			displayName = proto.displayName,
			category = proto.category,
			defaults = buildDefaults(proto),
			migrate = proto.migrate,
			wa2Event = proto.wa2Event,
			-- Carried so the options side and the WeakAuras2 importer can tell a
			-- prototype that fans a unit family out into clones from one whose
			-- unit dropdown holds single tokens only.
			statesParameter = proto.statesParameter,
			-- The importer reads the arg declarations for the shapes the
			-- defaults cannot describe (a tristate has no default), and asks the
			-- prototype's own importCheck about settings it cannot express.
			args = proto.args,
			importCheck = proto.importCheck,
			summary = buildSummary(proto),
			options = buildOptions,
		})
		table.insert(systemTypes, typeName)
	end
end

WA.RegisterTriggerSystem(systemTypes, GenericTrigger)
