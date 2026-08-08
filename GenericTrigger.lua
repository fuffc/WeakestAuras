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

-- Internal (WA-generated) event names never handed to Frame:RegisterEvent -- a
-- watcher re-dispatches them through WA.ScanEvents instead (§4.4).
local INTERNAL_EVENTS = {
	SPELL_COOLDOWN_CHANGED = true,
	SPELL_COOLDOWN_READY = true,
	ITEM_COOLDOWN_CHANGED = true,
	ITEM_COOLDOWN_READY = true,
	EQUIPSLOT_COOLDOWN_CHANGED = true,
	EQUIPSLOT_COOLDOWN_READY = true,
	-- Re-emitted by the threat watcher after parsing a TWThreat addon-message
	-- broadcast (there's no threat game event; see the watcher below).
	WA_THREAT_CHANGED = true,
	-- Re-emitted by the totem watcher after a SPELL_GO_SELF totem drop commits.
	WA_TOTEM_UPDATE = true,
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
	-- Re-emitted by the power-tick watcher when a regen tick is inferred or the
	-- timer stops (power type change, full power).
	WA_POWERTICK_UPDATE = true,
}

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

local VALID_OPS = { ["=="] = true, ["~="] = true, ["<"] = true,
	["<="] = true, [">"] = true, [">="] = true }
local function safeOp(op)
	return VALID_OPS[op] and op or "=="
end

-- The comparisons a `string` arg offers, and their editor captions.
local STRING_OPS = { "==", "~=", "find", "notfind" }
local STRING_OP_LABELS = { ["=="] = "Is", ["~="] = "Is Not",
	find = "Contains", notfind = "Doesn't Contain" }

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
-- (state, event, arg1..arg9): the status prototypes re-read live game state in
-- `init` and ignore the event args, but the parameters carry the firing event's
-- real payload, so a prototype can test against it instead of re-polling.
local function constructFunction(proto, trigger, errTag)
	local lines = {}
	table.insert(lines, "return function(state, event, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9)")
	if proto.init then
		table.insert(lines, proto.init(trigger))
	end
	for i = 1, table.getn(proto.args) do
		local arg = proto.args[i]
		if arg.init then
			table.insert(lines, string.format("local %s = %s", arg.name, arg.init))
		end
	end

	local tests = {}
	for i = 1, table.getn(proto.args) do
		local t = constructArgTest(proto.args[i], trigger)
		if t then table.insert(tests, t) end
	end
	local cond = table.getn(tests) > 0 and table.concat(tests, " and ") or "true"

	table.insert(lines, "if (" .. cond .. ") then")
	for i = 1, table.getn(proto.args) do
		local arg = proto.args[i]
		if arg.store then
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

-- Compiles a custom *status* trigger's user text into f(state, event) -> show.
-- The text is a whole function expression ("function(state, event) ... end");
-- WA.LoadFunction owns the wrapper, the sandbox and the error report. Shape
-- mirrors constructFunction's return contract (fn, source, err).
local function constructCustomFunction(trigger, errTag)
	local body = trigger.customTrigger or ""
	local fn, err = WA.LoadFunction(body, errTag)
	return fn, body, err
end

-- Resolves a "spell" field's stored value -- a numeric spellID, or a name the
-- user typed -- to a numeric spellID, or nil if it doesn't resolve to
-- anything (yet). Numeric input is trusted as-is and never round-tripped
-- through a lookup: the legacy GetSpellInfo(spellID) works for *any* spell
-- ID, known or not (ref ClassicAPI docs §Spell), so a raw ID the player
-- hasn't learned still resolves. A name only resolves through C_Spell's name
-- resolver (FUN_RESOLVE_SPELL_NAME_TO_BOOK_ID, the same chain
-- CastSpellByName uses) -- unlike the numeric path, that's bounded to the
-- player's own known spellbook, so a name for a spell they don't have (wrong
-- spelling, wrong class, not yet learned) legitimately has no numeric ID to
-- resolve to and this returns nil.
function WA.ResolveSpellID(input)
	if input == nil or input == "" then return nil end
	local id = tonumber(input)
	if id then return id end
	if C_Spell and C_Spell.GetSpellInfo then
		local info = C_Spell.GetSpellInfo(input)
		if info and info.spellID then return info.spellID end
	end
	return nil
end

-- Resolves an "item" field's stored value (a numeric itemID, or a name/
-- link the user typed) to a numeric itemID, or nil if it doesn't resolve to
-- anything (yet -- an uncached name needs the client to have seen the item
-- once, same GetItemInfo caveat as any other addon). No plain-Lua item-name-
-- >ID API exists, so a name resolves through GetItemInfo's link return and a
-- string.find capture (this client's Lua 5.0 has no string.match, ref
-- TextReplace.lua).
-- itemID for a name the user typed, found by walking the player's own
-- containers. Nothing on this client resolves a name: C_Item.GetItemCount and
-- C_Item.GetItemInfo both take an id, an "item:N" string or a link, and say so
-- explicitly -- so an item named rather than linked can only be identified by
-- finding one you hold. A hit is memoized for good (an id never stops belonging
-- to a name); a miss is only rate-limited, since the item may simply not be
-- carried yet and looting one must start working without a reload.
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
		local n = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
		if n and string.lower(n) == lname then return id end
		return nil
	end
	local function remember(id)
		itemIdByName[lname] = id
		itemNameMissAt[lname] = nil
		return id
	end

	-- Equipped first: cheapest, and the one place a bag walk cannot look.
	if GetInventoryItemID then
		for slot = 1, 19 do
			local hit = matches(GetInventoryItemID("player", slot))
			if hit then return remember(hit) end
		end
	end
	if C_Container and C_Container.GetContainerItemID and GetContainerNumSlots then
		for i = 1, table.getn(SCAN_BAGS) do
			local bag = SCAN_BAGS[i]
			for slot = 1, (GetContainerNumSlots(bag) or 0) do
				local hit = matches(C_Container.GetContainerItemID(bag, slot))
				if hit then return remember(hit) end
			end
		end
	end

	itemNameMissAt[lname] = GetTime()
	return nil
end

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
	return WA.ItemIDByName(input)
end

-- How many of an item the player holds, plus whether the item was identified at
-- all. Resolved at run time rather than baked into the generated source like
-- other trigger constants: an item can be configured long before one is ever
-- carried, and a typed name only becomes resolvable once one is found.
function WA.ItemCount(input, includeBank)
	local id = WA.ResolveItemID(input)
	if not id then return 0, false end
	if not (C_Item and C_Item.GetItemCount) then return 0, true end
	return C_Item.GetItemCount(id, includeBank and true or false) or 0, true
end

-- Bool condition/filter for "is `unit` in range of this spell", unit defaulting
-- to "target" for the spell-cooldown caller. SpellHasRange gates self-buffs and
-- other unrestricted spells to always-true rather than gating on a unit the
-- spell was never range-limited against; UnitInRange is the ClassicAPI 40yd
-- position check. Real Lua (not generated source) since neither call needs
-- per-trigger config.
function WA.SpellInRange(spellId, unit)
	unit = unit or "target"
	local hasRange = C_Spell and C_Spell.SpellHasRange and C_Spell.SpellHasRange(spellId)
	if not hasRange then return true end
	if not UnitExists(unit) then return false end
	if not UnitInRange then return true end -- can't check on this build; don't gate
	return UnitInRange(unit) and true or false
end

-- The unit token a trigger actually targets: the dropdown's choice, or the
-- free-text override when the dropdown's "specific" entry is selected (raid17,
-- partyN, or a SuperWoW GUID). Resolved at compile time and baked into the
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
	if not (C_Item and C_Item.GetItemInfo) then return nil, nil end
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

-- Shared 0.1s heartbeat for status prototypes tracking a fast-moving value
-- (range to a unit). Started lazily by WA.EnsureFastTick when such a trigger
-- loads and never cancelled; a range readout wants smoother than the 1s slow
-- tick, and 0.1s is cheap because ScanEvents early-outs on an event no trigger
-- is registered for.
local fastTicker
function WA.EnsureFastTick()
	if not fastTicker then
		fastTicker = C_Timer.NewTicker(0.1, function() WA.ScanEvents("WA_FAST_TICK") end)
	end
end

-- Temporary weapon enchant (oils/stones/poisons) for one hand. C_Item.
-- GetWeaponEnchantInfo returns a flat 12-tuple (main/off/ranged x has/expireMs/
-- charges/enchantID) -- captured whole via a plain multi-assign, never an
-- `and`-chain (which truncates multi-returns to one value on this client's Lua
-- 5.0). expireMs is remaining time in ms; the API gives no *original* duration,
-- so weCache remembers the remaining seen when the enchant first appeared (reset
-- when it drops or is re-applied -- expiration jumps up) to drive a proper
-- depleting bar rather than a permanently-full one.
local weCache = {}
function WA.WeaponEnchantInfo(hand)
	if not (C_Item and C_Item.GetWeaponEnchantInfo) then return false, 0, 0, nil end
	local hM, eM, cM, idM, hO, eO, cO, idO, hR, eR, cR, idR = C_Item.GetWeaponEnchantInfo()
	local has, expireMs, enchantId
	if hand == "off" then has, expireMs, enchantId = hO, eO, idO
	elseif hand == "ranged" then has, expireMs, enchantId = hR, eR, idR
	else has, expireMs, enchantId = hM, eM, idM end
	if not has then weCache[hand] = nil; return false, 0, 0, nil end
	local remaining = (expireMs or 0) / 1000
	local expiration = GetTime() + remaining
	local c = weCache[hand]
	if not c or expiration > c.expiration + 2 then
		c = { expiration = expiration, duration = remaining }
		weCache[hand] = c
	else
		c.expiration = expiration
	end
	return true, expiration, c.duration, enchantId
end

-- Reputation standing for a named faction. Walks the displayed faction list
-- (headers skipped) since GetFactionInfoByID needs an ID the user doesn't know;
-- niche enough that an O(n) scan on the UPDATE_FACTION event is fine. barMin/
-- barMax/barValue bracket the current standing bar. nil when the faction isn't
-- in the player's list (not yet encountered).
function WA.FactionStanding(name)
	if not name or name == "" or not GetNumFactions then return nil end
	for i = 1, GetNumFactions() do
		local fname, _, standingID, barMin, barMax, barValue, _, _, isHeader = GetFactionInfo(i)
		if not isHeader and fname == name then
			return standingID, barMin, barMax, barValue, fname
		end
	end
	return nil
end

-- Crowd-control category table (English spell names -> category), adapted from
-- the reference LoseControl addon's Babble-Spell keyed table. On an English
-- client Babble-Spell is identity, so those keys ARE the plain spell names --
-- reproduced here directly since we ship no Babble-Spell. Categories match
-- LoseControl's (stuns/incapacitates/fears all fold into "CC"); a couple of its
-- entries that aren't really control effects (e.g. Mortal Strike, a heal debuff)
-- are dropped so a CC display doesn't false-positive on them.
local CC_CATEGORIES = {
	-- Druid
	["Hibernate"] = "CC", ["Bash"] = "CC", ["Pounce"] = "CC", ["Feral Charge Effect"] = "Root",
	["Entangling Roots"] = "Root",
	-- Hunter
	["Freezing Trap Effect"] = "CC", ["Intimidation"] = "CC", ["Scare Beast"] = "CC",
	["Scatter Shot"] = "CC", ["Wyvern Sting"] = "CC", ["Concussive Shot"] = "Snare",
	["Frost Trap Aura"] = "Root", ["Counterattack"] = "Root", ["Improved Wing Clip"] = "Root",
	["Wing Clip"] = "Snare", ["Entrapment"] = "Root",
	-- Mage
	["Polymorph"] = "CC", ["Polymorph: Turtle"] = "CC", ["Polymorph: Pig"] = "CC",
	["Counterspell - Silenced"] = "Silence", ["Impact"] = "CC", ["Blast Wave"] = "Snare",
	["Frostbite"] = "Root", ["Freeze"] = "Root", ["Frost Nova"] = "Root",
	["Frostbolt"] = "Snare", ["Chilled"] = "Snare", ["Cone of Cold"] = "Snare",
	-- Paladin
	["Hammer of Justice"] = "CC", ["Repentance"] = "CC",
	-- Priest
	["Mind Control"] = "CC", ["Psychic Scream"] = "CC", ["Blackout"] = "CC",
	["Silence"] = "Silence", ["Mind Flay"] = "Snare",
	-- Rogue
	["Blind"] = "CC", ["Cheap Shot"] = "CC", ["Gouge"] = "CC", ["Kidney Shot"] = "CC",
	["Sap"] = "CC", ["Kick - Silenced"] = "Silence", ["Crippling Poison"] = "Snare",
	-- Warlock
	["Death Coil"] = "CC", ["Fear"] = "CC", ["Howl of Terror"] = "CC",
	["Curse of Exhaustion"] = "Snare", ["Seduction"] = "CC", ["Spell Lock"] = "Silence",
	["Aftermath"] = "Snare", ["Cripple"] = "Snare",
	-- Warrior
	["Charge Stun"] = "CC", ["Intercept Stun"] = "CC", ["Intimidating Shout"] = "CC",
	["Concussion Blow"] = "CC", ["Piercing Howl"] = "Snare",
	["Shield Bash - Silenced"] = "Silence", ["Disarm"] = "Disarm",
	-- Other / creature
	["War Stomp"] = "CC", ["Mace Stun Effect"] = "CC", ["Web"] = "Root", ["Net"] = "Root",
	["Knockdown"] = "CC", ["Sleep"] = "CC", ["Dazed"] = "Snare", ["Tidal Charm"] = "CC",
	["Gnomish Mind Control Cap"] = "CC",
}

-- First crowd-control debuff on the player, or (false, ...). Player-unit aura
-- timing is the reliable path on this client (real duration/expiration only for
-- unit == "player"), which is exactly what a "am I CC'd" display
-- needs. Scans HARMFUL and stops at the first nil slot (compacting list).
function WA.ScanPlayerCC()
	if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return false end
	for i = 1, 40 do
		local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HARMFUL")
		if not aura then break end
		local cat = aura.name and CC_CATEGORIES[aura.name]
		if cat then
			return true, cat, aura.name, aura.icon, aura.expirationTime or 0, aura.duration or 0
		end
	end
	return false, nil, nil, nil, 0, 0
end

-- ---------------------------------------------------------------------------
-- Prototypes (§4). Each = one table; adding a category never touches the
-- system code above or below.
-- ---------------------------------------------------------------------------

local PROTOTYPES = {}

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

-- Unit health, static progress (value/total = health/maxhealth).
PROTOTYPES["health"] = {
	displayName = "Health",
	category = "unit",
	progressType = "static",
	progressValue = "health",
	progressTotal = "maxhealth",
	events = function() return { "UNIT_HEALTH", "UNIT_MAXHEALTH" } end,
	force_events = true,
	icon = "Interface\\Icons\\INV_Potion_54",
	iconFunc = function() return "Interface\\Icons\\INV_Potion_54" end,
	nameFunc = function(trigger)
		local unit = WA.TriggerUnit(trigger, "player")
		return UnitName(unit) or unit
	end,
	init = function(trigger) return "local unit = " .. fmt(WA.TriggerUnit(trigger, "player")) end,
	args = {
		{ name = "unit", type = "unit", display = "Unit" },
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
		{ name = "inRange", type = "hidden", init = "((UnitInRange and UnitInRange(unit)) and true or false)",
			store = true, conditionType = "bool", display = "In Range" },
		{ name = "ignoreDead", type = "toggle", display = "Ignore Dead",
			test = function(t) return t.ignoreDead and "(not UnitIsDead(unit))" or nil end },
		{ name = "ignoreDisconnected", type = "toggle", display = "Ignore Disconnected",
			test = function(t) return t.ignoreDisconnected and "UnitIsConnected(unit)" or nil end },
		{ name = "inRangeFilter", type = "toggle", display = "Only if In Range",
			test = function(t) return t.inRangeFilter and "inRange" or nil end },
	},
}

-- Unit power (mana/rage/energy -- UnitMana returns the active bar). Static
-- progress. UnitPowerType select filters which resource must be active.
PROTOTYPES["power"] = {
	displayName = "Power",
	category = "unit",
	progressType = "static",
	progressValue = "power",
	progressTotal = "maxpower",
	events = function() return { "UNIT_MANA", "UNIT_RAGE", "UNIT_ENERGY", "UNIT_FOCUS", "UNIT_MAXMANA", "UNIT_MAXRAGE", "UNIT_MAXENERGY", "UNIT_DISPLAYPOWER" } end,
	force_events = true,
	icon = "Interface\\Icons\\Spell_Nature_Lightning",
	iconFunc = function() return "Interface\\Icons\\Spell_Nature_Lightning" end,
	nameFunc = function(trigger)
		local unit = WA.TriggerUnit(trigger, "player")
		return UnitName(unit) or unit
	end,
	init = function(trigger) return "local unit = " .. fmt(WA.TriggerUnit(trigger, "player")) end,
	args = {
		{ name = "unit", type = "unit", display = "Unit" },
		{ name = "exists", type = "hidden", required = true, test = "UnitExists(unit)" },
		{ name = "powertype", type = "select", display = "Power Type",
			init = "UnitPowerType(unit)",
			valueList = { 0, 1, 3, 2 },
			valueLabels = { [0] = "Mana", [1] = "Rage", [2] = "Focus", [3] = "Energy" } },
		{ name = "power", type = "number", display = "Power", init = "UnitMana(unit)",
			store = true, conditionType = "number" },
		{ name = "maxpower", type = "hidden", init = "UnitManaMax(unit)",
			store = true, conditionType = "number", display = "Max Power" },
		{ name = "percentpower", type = "number", display = "Power (%)",
			init = "(UnitManaMax(unit) > 0 and (UnitMana(unit) / UnitManaMax(unit) * 100) or 0)",
			multiEntry = true, store = true, conditionType = "number" },
		{ name = "powerDeficit", type = "number", display = "Power Deficit",
			init = "(UnitManaMax(unit) - UnitMana(unit))",
			store = true, conditionType = "number" },
		{ name = "name", type = "hidden", init = "UnitName(unit)",
			store = true, conditionType = "string", display = "Name" },
	},
}

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
	category = "spell",
	progressType = "timed",
	-- SPELL_UPDATE_USABLE keeps the usable / insufficient-resources stores live
	-- (pcall-guarded registration -- harmless if this build never fires it; the
	-- force_events pass + cooldown events still seed them). PLAYER_TARGET_CHANGED
	-- re-derives spellInRange on a target swap rather than only on the next
	-- cooldown flip; movement in/out of range with the same target refreshes only
	-- on this trigger's own event cadence.
	events = function() return { "SPELL_COOLDOWN_CHANGED", "SPELL_COOLDOWN_READY", "SPELL_UPDATE_USABLE", "PLAYER_TARGET_CHANGED" } end,
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
		local floor = trigger.showgcd and "0" or "1.5"
		return "local spellId = " .. fmt(WA.ResolveSpellID(trigger.spellName) or 0) .. "\n"
			.. "local startTime, duration = WeakestAuras.SpellCdInfo(spellId)\n"
			.. "local expirationTime = (startTime and duration and (startTime + duration)) or 0\n"
			.. "local remaining = (expirationTime > 0 and (expirationTime - GetTime())) or 0\n"
			.. "local onCooldown = (duration ~= nil and duration > " .. floor .. " and expirationTime > GetTime()) and true or false\n"
			.. "local name, _, icon = GetSpellInfo(spellId)\n"
			.. "local spellUsable, insufficientResources = false, false\n"
			.. "if IsUsableSpell then local _u, _m = IsUsableSpell(spellId) spellUsable = _u and true or false insufficientResources = _m and true or false end\n"
			.. "local spellInRange = WeakestAuras.SpellInRange(spellId)"
	end,
	args = {
		{ name = "spellName", type = "spell", display = "Spell" },
		-- Show mode. `duration > floor` filters the GCD (floor 1.5) unless
		-- showgcd keeps GCD-length cooldowns (floor 0). 1.5 is a stand-in for a
		-- real GCD reference.
		{ name = "genericShowOn", type = "select", required = true, display = "Show",
			valueList = { "showOnCooldown", "showOnReady", "showAlways" },
			valueLabels = { showOnCooldown = "On Cooldown", showOnReady = "Ready", showAlways = "Always" },
			default = "showOnCooldown", reloadOptions = true,
			test = function(trigger)
				local floor = trigger.showgcd and "0" or "1.5"
				local onCd = "(duration ~= nil and duration > " .. floor .. " and expirationTime > GetTime())"
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
			.. "local startTime, duration = WeakestAuras.ItemCdInfo(itemId)\n"
			.. "local expirationTime = (startTime and duration and (startTime + duration)) or 0\n"
			.. "local remaining = (expirationTime > 0 and (expirationTime - GetTime())) or 0\n"
			.. "local onCooldown = (duration ~= nil and duration > 1.5 and expirationTime > GetTime()) and true or false"
	end,
	args = {
		{ name = "itemName", type = "item", display = "Item" },
		{ name = "genericShowOn", type = "select", required = true, display = "Show",
			valueList = { "showOnCooldown", "showOnReady", "showAlways" },
			valueLabels = { showOnCooldown = "On Cooldown", showOnReady = "Ready", showAlways = "Always" },
			default = "showOnCooldown", reloadOptions = true,
			test = function(trigger)
				local onCd = "(duration ~= nil and duration > 1.5 and expirationTime > GetTime())"
				local mode = trigger.genericShowOn or "showOnCooldown"
				if mode == "showOnReady" then return "not " .. onCd
				elseif mode == "showAlways" then return "true"
				else return onCd end
			end },
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
for i = 1, table.getn(EQUIP_SLOT_DEFS) do
	local def = EQUIP_SLOT_DEFS[i]
	local slotId = GetInventorySlotInfo and GetInventorySlotInfo(def.key)
	if slotId then
		table.insert(EQUIP_SLOT_IDS, slotId)
		EQUIP_SLOT_LABELS[slotId] = def.label
	end
end

PROTOTYPES["equipslotcooldown"] = {
	displayName = "Cooldown Progress (Equipment Slot)",
	category = "item",
	progressType = "timed",
	events = function() return { "EQUIPSLOT_COOLDOWN_CHANGED", "EQUIPSLOT_COOLDOWN_READY" } end,
	force_events = true,
	loadFunc = function(trigger)
		if trigger.equipSlot then WA.WatchEquipSlotCooldown(trigger.equipSlot, trigger.use_remaining and (trigger.genericShowOn or "showOnCooldown") ~= "showOnReady") end
	end,
	icon = "Interface\\Icons\\INV_Misc_Bag_09",
	iconFunc = function(trigger)
		local slot = trigger.equipSlot
		local link = slot and GetInventoryItemLink and GetInventoryItemLink("player", slot)
		local _, ic = itemNameIcon(link)
		return ic or "Interface\\Icons\\INV_Misc_Bag_09"
	end,
	nameFunc = function(trigger)
		return EQUIP_SLOT_LABELS[trigger.equipSlot] or "?"
	end,
	init = function(trigger)
		return "local equipSlot = " .. fmt(trigger.equipSlot or 0) .. "\n"
			.. "local startTime, duration = WeakestAuras.EquipSlotCdInfo(equipSlot)\n"
			.. "local expirationTime = (startTime and duration and (startTime + duration)) or 0\n"
			.. "local remaining = (expirationTime > 0 and (expirationTime - GetTime())) or 0\n"
			.. "local onCooldown = (duration ~= nil and duration > 1.5 and expirationTime > GetTime()) and true or false"
	end,
	args = {
		{ name = "equipSlot", type = "select", required = true, display = "Slot",
			valueList = EQUIP_SLOT_IDS, valueLabels = EQUIP_SLOT_LABELS,
			default = EQUIP_SLOT_IDS[1] },
		{ name = "genericShowOn", type = "select", required = true, display = "Show",
			valueList = { "showOnCooldown", "showOnReady", "showAlways" },
			valueLabels = { showOnCooldown = "On Cooldown", showOnReady = "Ready", showAlways = "Always" },
			default = "showOnCooldown", reloadOptions = true,
			test = function(trigger)
				local onCd = "(duration ~= nil and duration > 1.5 and expirationTime > GetTime())"
				local mode = trigger.genericShowOn or "showOnCooldown"
				if mode == "showOnReady" then return "not " .. onCd
				elseif mode == "showAlways" then return "true"
				else return onCd end
			end },
		cooldownRemainingArg(),
		{ name = "duration", type = "hidden", store = true, conditionType = "number", display = "Duration" },
		{ name = "expirationTime", type = "hidden", store = true, conditionType = "timer", display = "Remaining Time" },
		{ name = "onCooldown", type = "hidden", store = true, conditionType = "bool", display = "On Cooldown" },
	},
}

-- Cast/channel progress (player/target), polled -- ClassicAPI's C_Spell.
-- Unit/ChannelInfo only cover a unit's own cast reliably by polling; this client
-- has no combat log to track an arbitrary caster from. SuperWoW's UNIT_CASTEVENT
-- would extend this to any GUID with real payload -- a separate extension point.
-- Both C_Spell calls return several values positionally; captured through
-- named throwaway locals first and reassigned, rather than destructured
-- directly into the final names, so the two different return shapes
-- (UnitCastingInfo has castID at position 7, UnitChannelInfo doesn't) can't
-- be confused with each other.
PROTOTYPES["cast"] = {
	displayName = "Cast",
	category = "unit",
	progressType = "timed",
	events = function() return { "SPELLCAST_START", "SPELLCAST_STOP", "SPELLCAST_CHANNEL_START", "SPELLCAST_CHANNEL_STOP", "SPELLCAST_FAILED", "SPELLCAST_INTERRUPTED", "PLAYER_TARGET_CHANGED" } end,
	force_events = true,
	icon = "Interface\\Icons\\Spell_Nature_WispSplode",
	iconFunc = function() return "Interface\\Icons\\Spell_Nature_WispSplode" end,
	nameFunc = function(trigger) return "Cast (" .. WA.TriggerUnit(trigger, "player") .. ")" end,
	init = function(trigger)
		return "local unit = " .. fmt(WA.TriggerUnit(trigger, "player")) .. "\n"
			.. "local castName, castIcon, startMs, endMs, notInterruptible, castingSpellID\n"
			.. "if C_Spell and C_Spell.UnitCastingInfo then\n"
			.. "\tlocal _n, _d, _i, _s, _e, _t, _c, _ni, _sid = C_Spell.UnitCastingInfo(unit)\n"
			.. "\tcastName, castIcon, startMs, endMs, notInterruptible, castingSpellID = _n, _i, _s, _e, _ni, _sid\n"
			.. "end\n"
			.. "local chanName, chanIcon, chanStartMs, chanEndMs, chanNotInterruptible, chanSpellID\n"
			.. "if not castName and C_Spell and C_Spell.UnitChannelInfo then\n"
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
			.. "local startTime = ((casting and startMs) or (channeling and chanStartMs) or 0) / 1000\n"
			.. "local expirationTime = ((casting and endMs) or (channeling and chanEndMs) or 0) / 1000\n"
			.. "local duration = (expirationTime > 0 and startTime > 0) and (expirationTime - startTime) or 0"
	end,
	args = {
		{ name = "unit", type = "unit", display = "Unit" },
		{ name = "active", type = "hidden", required = true, test = "active" },
		{ name = "casting", type = "hidden", store = true, conditionType = "bool", display = "Casting" },
		{ name = "channeling", type = "hidden", store = true, conditionType = "bool", display = "Channeling" },
		{ name = "name", type = "hidden", store = true, conditionType = "string", display = "Spell Name" },
		{ name = "icon", type = "hidden", store = true },
		{ name = "spellId", type = "hidden", store = true, conditionType = "number", display = "Spell ID" },
		{ name = "duration", type = "hidden", store = true, conditionType = "number", display = "Duration" },
		{ name = "expirationTime", type = "hidden", store = true, conditionType = "timer", display = "Cast End" },
		{ name = "notInterruptibleFlag", type = "hidden", store = true, conditionType = "bool", display = "Not Interruptible" },
	},
}

-- A completed cast is an instant, not a state, so this prototype shows for a
-- configured window and takes itself back down (autoHide) rather than waiting
-- for an event that says the cast stopped being true.
--
-- Nampower's SPELL_GO_SELF is the signal, through the shared dispatch above.
-- SuperWoW's UNIT_CASTEVENT also reports completed casts and covers *every*
-- unit, but it fires a CAST for spells the player never chose -- procs and
-- companion ids land alongside the real one -- whereas SPELL_GO_SELF is exactly
-- the player's own cast. Hence: your casts only, and no unit arg.
PROTOTYPES["castsucceeded"] = {
	displayName = "Spell Cast Succeeded",
	category = "spell",
	autoHide = true,
	enable = function() return WA.hasNampower end,
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

-- Status bool: has the player learned this spell. IsSpellKnown is a native
-- global taking a numeric spellID (3.3.5 semantics).
PROTOTYPES["spellknown"] = {
	displayName = "Spell Known",
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
			.. "local known = (IsSpellKnown and IsSpellKnown(spellId)) and true or false"
	end,
	args = {
		{ name = "spellName", type = "spell", display = "Spell" },
		{ name = "known", type = "hidden", required = true, test = "known", store = true, conditionType = "bool", display = "Known" },
	},
}

-- Status: current shapeshift/stance form. Vanilla SpellShapeshiftForm.dbc IDs
-- don't match modern WoW's numbering and vary per class -- exposed as a raw
-- number (0 = no form) rather than a hardcoded per-class select, so this
-- doesn't ship a wrong ID table; a user determines their own class's IDs
-- in-game and filters on them directly.
PROTOTYPES["stance"] = {
	displayName = "Stance/Form",
	category = "unit",
	progressType = "none",
	events = function() return { "UPDATE_SHAPESHIFT_FORM" } end,
	force_events = true,
	icon = "Interface\\Icons\\Ability_Druid_CatForm",
	iconFunc = function() return "Interface\\Icons\\Ability_Druid_CatForm" end,
	nameFunc = function() return "Stance/Form" end,
	init = function()
		return "local formId = (GetShapeshiftFormID and GetShapeshiftFormID()) or 0\n"
			.. "local inForm = formId ~= 0"
	end,
	args = {
		{ name = "formId", type = "number", display = "Form ID", operator = "==",
			store = true, conditionType = "number" },
		{ name = "inForm", type = "hidden", store = true, conditionType = "bool", display = "In Any Form" },
	},
}

-- Status number: bag+bank item count. C_Item.GetItemCount returns a single
-- value (no multi-return truncation risk from the `and`-chain below).
PROTOTYPES["itemcount"] = {
	displayName = "Item Count",
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
			.. "local equipped = (C_Item and C_Item.IsEquippedItem and itemRef ~= \"\" and C_Item.IsEquippedItem(itemRef)) and true or false"
	end,
	args = {
		{ name = "itemName", type = "item", display = "Item" },
		{ name = "equipped", type = "hidden", required = true, test = "equipped", store = true, conditionType = "bool", display = "Equipped" },
	},
}

-- Status: static facts about a unit. UnitClassBase (ClassicAPI backport)
-- returns two values -- captured through pre-declared locals set inside an
-- if-block rather than an `and`-chain, for the same multi-return-truncation
-- reason documented above the itemcooldown prototype.
PROTOTYPES["unitcharacteristics"] = {
	displayName = "Unit Characteristics",
	category = "unit",
	progressType = "none",
	events = function() return { "UNIT_LEVEL", "PLAYER_TARGET_CHANGED", "PLAYER_ENTERING_WORLD" } end,
	force_events = true,
	icon = "Interface\\Icons\\INV_Misc_QuestionMark",
	iconFunc = function() return "Interface\\Icons\\INV_Misc_QuestionMark" end,
	nameFunc = function(trigger)
		local unit = WA.TriggerUnit(trigger, "target")
		return UnitName(unit) or unit
	end,
	init = function(trigger)
		return "local unit = " .. fmt(WA.TriggerUnit(trigger, "target")) .. "\n"
			.. "local unitName = UnitName(unit)\n"
			.. "local level = UnitLevel(unit) or 0\n"
			.. "local classFile, classId\n"
			.. "if UnitClassBase then classFile, classId = UnitClassBase(unit) end\n"
			.. "local creatureType = UnitCreatureType(unit) or \"\"\n"
			.. "local classification = UnitClassification(unit) or \"\"\n"
			.. "local isPlayer = UnitIsPlayer(unit) and true or false"
	end,
	args = {
		{ name = "unit", type = "unit", display = "Unit", default = "target" },
		{ name = "exists", type = "hidden", required = true, test = "UnitExists(unit)" },
		{ name = "unitName", type = "string", store = true, conditionType = "string", display = "Name" },
		{ name = "level", type = "number", display = "Level", operator = ">=", store = true, conditionType = "number" },
		{ name = "classFile", type = "hidden", store = true, conditionType = "string", display = "Class" },
		{ name = "creatureType", type = "hidden", store = true, conditionType = "string", display = "Creature Type" },
		{ name = "classification", type = "select", display = "Classification",
			valueList = { "normal", "elite", "rareelite", "rare", "worldboss" },
			store = true, conditionType = "string" },
		{ name = "isPlayer", type = "hidden", store = true, conditionType = "bool", display = "Is Player" },
	},
}

-- Custom status trigger. Unlike every prototype above, its test function, events
-- and progress come from user text, not an `args` list -- GenericTrigger.Add
-- compiles trigger.customTrigger via constructCustomFunction (not
-- constructFunction) and reads its events from trigger.customEvents whenever
-- proto.custom is set. Only WA2's `status` custom mode is supported: the user's
-- f(state, event) is re-run on each listed event, show follows the returned bool,
-- and the function writes its own name/icon/progress/condition fields onto the
-- persistent `state` table (setting state.changed = true when it mutates them, so
-- the change propagates -- same contract WA2 custom triggers carry). A custom
-- trigger declares no condition variables, so GetTriggerConditions returns an
-- empty table for it.
PROTOTYPES["custom"] = {
	displayName = "Custom",
	category = "custom",
	custom = true,
	-- Fallback only; Add sets ti.progressType per-trigger from customProgressType
	-- and activateEvent reads that (not this) for a custom ti.
	progressType = "none",
	events = function(trigger) return parseEventList(trigger and trigger.customEvents) end,
	force_events = true,
	icon = "Interface\\Icons\\INV_Misc_Gear_08",
	iconFunc = function() return "Interface\\Icons\\INV_Misc_Gear_08" end,
	nameFunc = function() return "Custom" end,
	defaults = {
		customTrigger = "function(state, event)\n    return true\nend",
		customEvents = "",
		customProgressType = "none",
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
		return "local comboPoints = (GetComboPoints and GetComboPoints(\"player\", \"target\")) or 0\n"
			.. "local maxComboPoints = 5"
	end,
	args = {
		{ name = "comboPoints", type = "number", display = "Combo Points", operator = ">=",
			store = true, conditionType = "number" },
		{ name = "maxComboPoints", type = "hidden", store = true, conditionType = "number", display = "Max Combo Points" },
	},
}

-- Temporary weapon enchant, timed progress. Oils/sharpening stones/shaman
-- imbues/rogue poisons. Fed by WA.WeaponEnchantInfo (which remembers the
-- original duration for a proper depleting bar) + WA_SLOW_TICK for the expiry
-- flip. name comes from the enchant record when resolvable.
PROTOTYPES["weaponenchant"] = {
	displayName = "Weapon Enchant (Temporary)",
	category = "item",
	progressType = "timed",
	events = function() return { "UNIT_INVENTORY_CHANGED", "PLAYER_ENTERING_WORLD", "WA_SLOW_TICK" } end,
	force_events = true,
	loadFunc = function() WA.EnsureSlowTick() end,
	icon = "Interface\\Icons\\INV_Potion_105",
	iconFunc = function() return "Interface\\Icons\\INV_Potion_105" end,
	nameFunc = function(trigger)
		local h = trigger.hand or "main"
		return (h == "off" and "Off Hand Enchant") or (h == "ranged" and "Ranged Enchant") or "Main Hand Enchant"
	end,
	init = function(trigger)
		return "local has, expirationTime, duration, enchantId = WeakestAuras.WeaponEnchantInfo(" .. fmt(trigger.hand or "main") .. ")\n"
			.. "local name = \"Weapon Enchant\"\n"
			.. "if enchantId and C_Item and C_Item.GetEnchantInfo then local ei = C_Item.GetEnchantInfo(enchantId) if ei and ei.name then name = ei.name end end\n"
			.. "local remaining = (expirationTime > 0 and (expirationTime - GetTime())) or 0"
	end,
	args = {
		{ name = "hand", type = "select", required = true, display = "Weapon",
			valueList = { "main", "off", "ranged" },
			valueLabels = { main = "Main Hand", off = "Off Hand", ranged = "Ranged" },
			default = "main" },
		{ name = "has", type = "hidden", required = true, test = "has" },
		{ name = "remaining", type = "number", display = "Remaining Time", operator = "<=" },
		{ name = "name", type = "hidden", store = true, conditionType = "string", display = "Enchant Name" },
		{ name = "duration", type = "hidden", store = true, conditionType = "number", display = "Duration" },
		{ name = "expirationTime", type = "hidden", store = true, conditionType = "timer", display = "Remaining Time" },
	},
}

-- Reputation with a named faction, static progress within the current standing
-- bar. Niche; the user types the faction name exactly (WA.FactionStanding walks
-- the list for it). standingID 1..8 = Hated..Exalted.
PROTOTYPES["reputation"] = {
	displayName = "Reputation",
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
		return "local xp = (UnitXP and UnitXP(\"player\")) or 0\n"
			.. "local xpMax = (UnitXPMax and UnitXPMax(\"player\")) or 0\n"
			.. "local restedXP = (GetXPExhaustion and GetXPExhaustion()) or 0\n"
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
-- UnitStat's effective value is its 2nd return (base is 1st); captured via a
-- plain multi-assign, not an `and`-chain. Always active -- a status surface for
-- conditions/text, no required gate.
PROTOTYPES["charstats"] = {
	displayName = "Character Stats",
	category = "unit",
	progressType = "none",
	events = function() return { "UNIT_STATS", "UNIT_ATTACK_POWER", "UNIT_AURA", "PLAYER_ENTERING_WORLD" } end,
	force_events = true,
	icon = "Interface\\Icons\\INV_Misc_GroupLooking",
	iconFunc = function() return "Interface\\Icons\\INV_Misc_GroupLooking" end,
	nameFunc = function() return "Character Stats" end,
	init = function()
		return "local function _stat(i) local b, e = UnitStat(\"player\", i) return e or b or 0 end\n"
			.. "local strength = UnitStat and _stat(1) or 0\n"
			.. "local agility = UnitStat and _stat(2) or 0\n"
			.. "local stamina = UnitStat and _stat(3) or 0\n"
			.. "local intellect = UnitStat and _stat(4) or 0\n"
			.. "local spirit = UnitStat and _stat(5) or 0\n"
			.. "local attackPower = 0\n"
			.. "if UnitAttackPower then local ab, ap, an = UnitAttackPower(\"player\") attackPower = (ab or 0) + (ap or 0) - (an or 0) end"
	end,
	args = {
		{ name = "strength", type = "number", display = "Strength", operator = ">=", store = true, conditionType = "number" },
		{ name = "agility", type = "number", display = "Agility", operator = ">=", store = true, conditionType = "number" },
		{ name = "stamina", type = "number", display = "Stamina", operator = ">=", store = true, conditionType = "number" },
		{ name = "intellect", type = "number", display = "Intellect", operator = ">=", store = true, conditionType = "number" },
		{ name = "spirit", type = "number", display = "Spirit", operator = ">=", store = true, conditionType = "number" },
		{ name = "attackPower", type = "number", display = "Attack Power", operator = ">=", store = true, conditionType = "number" },
	},
}

-- Crowd control on the player, timed progress. Debuff scan (WA.ScanPlayerCC)
-- against the bundled category table -- ClassicAPI-only, no combat log or
-- Nampower needed, and player-unit aura timing is the reliable case. Optional
-- category filter; name/icon/expiration drive the display. WA_SLOW_TICK flips it
-- off at expiry; UNIT_AURA catches a new/removed debuff immediately.
PROTOTYPES["crowdcontrol"] = {
	displayName = "Crowd Control",
	category = "unit",
	progressType = "timed",
	events = function() return { "UNIT_AURA", "PLAYER_AURAS_CHANGED", "WA_SLOW_TICK" } end,
	force_events = true,
	loadFunc = function() WA.EnsureSlowTick() end,
	icon = "Interface\\Icons\\Spell_Nature_Polymorph",
	iconFunc = function() return "Interface\\Icons\\Spell_Nature_Polymorph" end,
	nameFunc = function() return "Crowd Control" end,
	init = function()
		return "local active, category, name, icon, expirationTime, duration = WeakestAuras.ScanPlayerCC()"
	end,
	args = {
		{ name = "active", type = "hidden", required = true, test = "active",
			store = true, conditionType = "bool", display = "Under Control" },
		{ name = "category", type = "select", display = "Category",
			valueList = { "CC", "Silence", "Disarm", "Root", "Snare" },
			test = function(t) return t.use_category and ("(category == " .. fmt(t.category) .. ")") or nil end },
		{ name = "name", type = "hidden", store = true, conditionType = "string", display = "Spell Name" },
		{ name = "icon", type = "hidden", store = true },
		{ name = "expirationTime", type = "hidden", store = true, conditionType = "timer", display = "Remaining Time" },
		{ name = "duration", type = "hidden", store = true, conditionType = "number", display = "Duration" },
	},
}

-- Range to a unit, status. A standalone wrapper over the three range primitives,
-- selected by `rangeMode`:
--   "unit"     -- UnitInRange: a real ~40yd position check (ClassicAPI), the
--                 same primitive the spell-cooldown/health prototypes expose.
--   "interact" -- CheckInteractDistance(unit, index): coarse native bands, the
--                 ONLY way to detect short/melee range here (inspect ~28 /
--                 trade ~11 / duel ~10 / follow ~28 yd -- index 3 is the
--                 melee-ish band UnitInRange's 40yd can't resolve).
--   "spell"    -- WA.SpellInRange: SpellHasRange-gated UnitInRange for a named
--                 spell (exact per-spell range would need SuperWoW SpellInfo +
--                 UnitPosition -- an opt-in refinement, not wired here).
-- Range changes with movement and there's no movement event, so it leans on
-- WA_FAST_TICK's 0.1s cadence to re-poll (plus a target swap) -- smooth enough
-- for a live distance readout. `distance` is the center-to-center yards from
-- UnitDistanceSquared (ClassicAPI), 0 when the position isn't available.
-- UnitInRange returns (inRange, checkedRange); captured via a direct
-- multi-assign inside the guard, never an `and`-chain (which truncates
-- multi-returns to one value here).
PROTOTYPES["rangecheck"] = {
	displayName = "Range Check",
	category = "unit",
	progressType = "none",
	events = function() return { "PLAYER_TARGET_CHANGED", "WA_FAST_TICK", "PLAYER_ENTERING_WORLD" } end,
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
		{ name = "unit", type = "unit", display = "Unit", default = "target" },
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

-- Threat, static progress. No Lua threat API on 1.12; TWThreat drives Turtle's
-- server-side threat query and broadcasts it. We consume its CHAT_MSG_ADDON
-- packets via WA.WatchThreat (below) and never send, so there's no protocol
-- risk -- it just needs someone in the group running TWThreat and an elite/boss
-- target for packets to arrive. `exists` stays false (trigger hidden) until the
-- first packet naming the player lands. threatpct is 0..100 (the player's threat
-- as a percentage of the tank's / aggro threshold).
PROTOTYPES["threat"] = {
	displayName = "Threat (TWThreat)",
	category = "unit",
	progressType = "static",
	progressValue = "threatpct",
	progressTotal = "threatmax",
	events = function() return { "WA_THREAT_CHANGED", "PLAYER_TARGET_CHANGED" } end,
	force_events = true,
	loadFunc = function() WA.WatchThreat() end,
	icon = "Interface\\Icons\\Ability_Threaten",
	iconFunc = function() return "Interface\\Icons\\Ability_Threaten" end,
	nameFunc = function() return "Threat" end,
	init = function()
		return "local threatpct, isTanking, exists = WeakestAuras.ThreatInfo()\n"
			.. "local threatmax = 100"
	end,
	args = {
		{ name = "exists", type = "hidden", required = true, test = "exists" },
		{ name = "threatpct", type = "number", display = "Threat (%)", operator = ">=",
			store = true, conditionType = "number" },
		{ name = "threatmax", type = "hidden", store = true, conditionType = "number", display = "Threat Max" },
		{ name = "isTanking", type = "hidden", store = true, conditionType = "bool", display = "Tanking" },
	},
}

-- Totem in a given element slot, timed progress. No GetTotemInfo on 1.12; the
-- totem watcher (below) emulates it from a bundled spellID->duration DB + a
-- Nampower SPELL_GO_SELF drop signal. Per-slot default icon/name are
-- compile-time constants; the live totem's name/icon come from the watcher's
-- stores and win via activateEvent. Early-destroyed totems (killed, or the slot
-- overwritten) aren't detected mid-life beyond WA_SLOW_TICK expiry +
-- PLAYER_DEAD clear -- same limitation as the pfUI/CallOfElements refs.
local TOTEM_SLOT_LABELS = { [1] = "Fire", [2] = "Earth", [3] = "Water", [4] = "Air" }
local TOTEM_SLOT_ICONS = {
	[1] = "Interface\\Icons\\Spell_Fire_SearingTotem",
	[2] = "Interface\\Icons\\Spell_Nature_StrengthOfEarthTotem02",
	[3] = "Interface\\Icons\\Spell_Nature_ManaRegenTotem",
	[4] = "Interface\\Icons\\Spell_Nature_InvisibilityTotem",
}
PROTOTYPES["totem"] = {
	displayName = "Totem",
	category = "spell",
	progressType = "timed",
	events = function() return { "WA_TOTEM_UPDATE", "WA_SLOW_TICK", "PLAYER_ENTERING_WORLD" } end,
	force_events = true,
	loadFunc = function() WA.WatchTotems(); WA.EnsureSlowTick() end,
	icon = "Interface\\Icons\\Spell_Nature_SearingTotem",
	iconFunc = function(trigger) return TOTEM_SLOT_ICONS[trigger.totemSlot or 1] or "Interface\\Icons\\Spell_Nature_SearingTotem" end,
	nameFunc = function(trigger) return (TOTEM_SLOT_LABELS[trigger.totemSlot or 1] or "Totem") .. " Totem" end,
	init = function(trigger)
		return "local slot = " .. fmt(trigger.totemSlot or 1) .. "\n"
			.. "local active, name, icon, startTime, duration = WeakestAuras.TotemInfo(slot)\n"
			.. "active = active and true or false\n"
			.. "startTime = startTime or 0\n"
			.. "duration = duration or 0\n"
			.. "local expirationTime = (startTime > 0 and duration > 0) and (startTime + duration) or 0\n"
			.. "local remaining = (expirationTime > 0 and (expirationTime - GetTime())) or 0"
	end,
	args = {
		{ name = "totemSlot", type = "select", required = true, display = "Element",
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

-- Swing timer, timed progress per weapon hand. Full port of pfUI's
-- modules/swingtimer.lua: the watcher (below) maintains each hand's swing
-- start/duration off Nampower's AUTO_ATTACK_SELF reset + UnitAttackSpeed, the
-- Flurry proc-latency rescale, and the advanced grafts -- on-next-swing consume
-- (Heroic Strike/Cleave/Maul), the Slam/Hammer-of-Wrath clip warning,
-- ability-queue coloring, ranged bar, and parry haste. Those extras are
-- surfaced as condition variables (blocked/clipWarning/clipDelay/queuedAbility),
-- not a hardcoded bar tint -- the WA-idiomatic translation of pfUI's inline
-- rendering (see the watcher comment).
PROTOTYPES["swing"] = {
	displayName = "Swing Timer",
	category = "unit",
	progressType = "timed",
	events = function() return { "WA_SWING_UPDATE", "WA_SLOW_TICK", "PLAYER_ENTERING_WORLD" } end,
	force_events = true,
	loadFunc = function() WA.WatchSwing(); WA.EnsureSlowTick() end,
	icon = "Interface\\Icons\\Ability_Warrior_DecisiveStrike",
	iconFunc = function() return "Interface\\Icons\\Ability_Warrior_DecisiveStrike" end,
	nameFunc = function(trigger)
		local h = trigger.swingHand or "main"
		return ((h == "off" and "Off Hand") or (h == "ranged" and "Ranged") or "Main Hand") .. " Swing"
	end,
	init = function(trigger)
		return "local hand = " .. fmt(trigger.swingHand or "main") .. "\n"
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
		{ name = "swingHand", type = "select", required = true, display = "Weapon",
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
-- SPELL_UPDATE_COOLDOWN) }. Returns { Watch(key, wantTick), Info(key) }.
local function newCooldownWatcher(spec)
	local w = { keys = {}, tick = {}, cache = {}, frame = nil, ticker = nil }

	local function pollKey(key)
		local start, duration, enabled = spec.pollRaw(key)
		start = start or 0; duration = duration or 0
		local c = w.cache[key]
		local changed = not c or c.start ~= start or c.duration ~= duration
		if changed then
			w.cache[key] = { start = start, duration = duration, enabled = enabled }
		end
		local running = start > 0 and duration > 0 and (start + duration) > GetTime()
		-- Fire on a real change, and additionally every tick while a remaining-time
		-- filter is interested (w.tick), so its threshold flips near real time
		-- rather than only at start/end -- a running cooldown emits no natural event.
		if changed or (w.tick[key] and running) then
			WA.ScanEvents(spec.changedEvent, key)
		end
		-- Schedule the ready flip for real (non-GCD) cooldowns, so the display
		-- clears exactly on time without relying on the slow ticker's cadence.
		if changed and start > 0 and duration > 1.5 then
			local remain = (start + duration) - GetTime()
			if remain > 0 then
				C_Timer.After(remain + 0.05, function()
					pollKey(key)
					WA.ScanEvents(spec.readyEvent, key)
				end)
			end
		end
	end

	local function pollAll()
		for key in pairs(w.keys) do pollKey(key) end
	end

	local function ensure()
		if not w.frame then
			w.frame = CreateFrame("Frame")
			w.frame:SetScript("OnEvent", pollAll)
			-- Guarded: not every 1.12 build fires every one of these, and an unknown
			-- event name would error the whole registration (risk (c), settle per
			-- build with Debug.lua's /wa events pattern).
			for i = 1, table.getn(spec.extraEvents or {}) do
				pcall(w.frame.RegisterEvent, w.frame, spec.extraEvents[i])
			end
		end
		if not w.ticker then
			w.ticker = C_Timer.NewTicker(0.3, pollAll)
		end
	end

	-- Registers a key in the central cooldown cache. wantTick asks the watcher
	-- to re-emit changedEvent every ticker pass while this key is on cooldown
	-- (for remaining-time filters). No unwatch path yet (a few idle keys in the
	-- poll set is cheap); refcounted teardown belongs with LoadDisplays/
	-- UnloadDisplays.
	local function watch(key, wantTick)
		w.keys[key] = true
		if wantTick then w.tick[key] = true end
		ensure()
		pollKey(key)
	end

	-- Generated cooldown-trigger code reads the cache through this.
	local function info(key)
		local c = w.cache[key]
		if not c then return nil, nil, nil end
		return c.start, c.duration, c.enabled
	end

	return { Watch = watch, Info = info }
end

local spellCdWatch = newCooldownWatcher({
	pollRaw = function(spellId)
		local cdInfo = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(spellId)
		return cdInfo and cdInfo.startTime, cdInfo and cdInfo.duration, cdInfo and cdInfo.isEnabled
	end,
	changedEvent = "SPELL_COOLDOWN_CHANGED",
	readyEvent = "SPELL_COOLDOWN_READY",
	extraEvents = { "SPELL_UPDATE_COOLDOWN", "ACTIONBAR_UPDATE_COOLDOWN" },
})
function WA.WatchSpellCooldown(spellId, wantTick) spellCdWatch.Watch(spellId, wantTick) end
function WA.SpellCdInfo(spellId) return spellCdWatch.Info(spellId) end

-- GetItemCooldown returns (start, duration, enable) directly, not a table --
-- read behind an if-guard (not an `and`-chain) so all three values actually
-- propagate; `and`-chaining a multi-return call truncates it to one value on
-- this client's Lua 5.0.
local itemCdWatch = newCooldownWatcher({
	pollRaw = function(itemId)
		if not GetItemCooldown then return 0, 0, false end
		local start, duration, enable = GetItemCooldown(itemId)
		return start, duration, enable == 1
	end,
	changedEvent = "ITEM_COOLDOWN_CHANGED",
	readyEvent = "ITEM_COOLDOWN_READY",
	extraEvents = { "BAG_UPDATE_COOLDOWN" },
})
function WA.WatchItemCooldown(itemId, wantTick) itemCdWatch.Watch(itemId, wantTick) end
function WA.ItemCdInfo(itemId) return itemCdWatch.Info(itemId) end

-- GetInventoryItemCooldown is a native 1.12 global (not a ClassicAPI
-- backport), same (start, duration, enable) shape as GetItemCooldown.
local equipCdWatch = newCooldownWatcher({
	pollRaw = function(slot)
		if not GetInventoryItemCooldown then return 0, 0, false end
		local start, duration, enable = GetInventoryItemCooldown("player", slot)
		return start, duration, enable == 1
	end,
	changedEvent = "EQUIPSLOT_COOLDOWN_CHANGED",
	readyEvent = "EQUIPSLOT_COOLDOWN_READY",
	extraEvents = { "BAG_UPDATE_COOLDOWN", "PLAYER_EQUIPMENT_CHANGED" },
})
function WA.WatchEquipSlotCooldown(slot, wantTick) equipCdWatch.Watch(slot, wantTick) end
function WA.EquipSlotCdInfo(slot) return equipCdWatch.Info(slot) end

-- Threat watcher: parses TWThreat's CHAT_MSG_ADDON broadcasts into a cached
	-- threat percentage for the player, re-emitting WA_THREAT_CHANGED so the threat
-- prototype re-reads it (the incoming addon message is just another event
-- feeding a status update -- fits the existing model with no engine change).
-- Packet body: "...TWTv4=name:tank:threat:perc:melee:extra;name2:...;" (ref
-- TWThreat.lua handleThreatPacket). Plain string.find/sub splitting -- this
-- client's Lua 5.0 has no gmatch, and the fields are magic-char-free anyway.
local threatCache = { pct = 0, isTanking = false, exists = false }
local threatFrame
local function splitStr(s, sep)
	local out, pos = {}, 1
	while true do
		local a, b = string.find(s, sep, pos, true)
		if not a then table.insert(out, string.sub(s, pos)); break end
		table.insert(out, string.sub(s, pos, a - 1))
		pos = b + 1
	end
	return out
end
function WA.WatchThreat()
	if threatFrame then return end
	threatFrame = CreateFrame("Frame")
	-- Guarded like every other event registration here (risk (c)); CHAT_MSG_ADDON
	-- is a native 1.12 event so it should always take.
	pcall(threatFrame.RegisterEvent, threatFrame, "CHAT_MSG_ADDON")
	threatFrame:SetScript("OnEvent", function()
		if arg1 ~= "TWT" or not arg2 then return end
		local s, e = string.find(arg2, "TWTv4=", 1, true)
		if not s then return end
		local players = splitStr(string.sub(arg2, e + 1), ";")
		local me = UnitName("player")
		local found = false
		for i = 1, table.getn(players) do
			local f = splitStr(players[i], ":")
			if f[1] == me and f[4] then
				threatCache.pct = tonumber(f[4]) or 0
				threatCache.isTanking = f[2] == "1"
				threatCache.exists = true
				found = true
			end
		end
		if found then WA.ScanEvents("WA_THREAT_CHANGED") end
	end)
end
function WA.ThreatInfo() return threatCache.pct, threatCache.isTanking, threatCache.exists end

-- Shared SPELL_GO_SELF dispatch: the totem and swing watchers both consume this
-- Nampower event (arg1 itemId, 0 for a real spell cast; arg2 spellId -- ref
-- DoiteAuras DoiteConditions.lua ~2270). Registered once and fanned out to
-- subscribers so the two watchers don't each stand up their own frame, and the
-- gating CVar is flipped once: Nampower hides SPELL_GO events behind
-- NP_EnableSpellGoEvents (default 0), enabled here the same guarded way
-- DoiteAuras does -- without it arg2/spellId never arrives.
local spellGoSelfSubs = {}
local spellGoSelfFrame
local function subscribeSpellGoSelf(fn)
	table.insert(spellGoSelfSubs, fn)
	if spellGoSelfFrame then return end
	if GetCVar and SetCVar then
		local ok, v = pcall(GetCVar, "NP_EnableSpellGoEvents")
		if ok and v and tostring(v) == "0" then pcall(SetCVar, "NP_EnableSpellGoEvents", "1") end
	end
	spellGoSelfFrame = CreateFrame("Frame")
	pcall(spellGoSelfFrame.RegisterEvent, spellGoSelfFrame, "SPELL_GO_SELF")
	spellGoSelfFrame:SetScript("OnEvent", function()
		if arg1 and arg1 ~= 0 then return end -- item-triggered, not a real spell cast
		local spellId = arg2
		if not spellId then return end
		for i = 1, table.getn(spellGoSelfSubs) do spellGoSelfSubs[i](spellId) end
	end)
end

-- Re-emits the shared dispatch as an internal event carrying the spell id, so a
-- trigger reads the cast off the payload instead of re-polling for it. Player
-- only: SPELL_GO_SELF does not fire for anyone else's casts.
local spellCastWatching = false
function WA.WatchSpellCast()
	if spellCastWatching then return end
	spellCastWatching = true
	subscribeSpellGoSelf(function(spellId)
		WA.ScanEvents("WA_SPELL_CAST_SUCCEEDED", spellId)
	end)
end

-- Single-bit flag test (masks used here are all powers of two), so nothing
-- depends on a `bit` library being present -- AUTO_ATTACK_SELF hitInfo bits and
-- the Spell.dbc attribute/flag bits (via GetSpellRecField) both go through this.
local function hasFlag(v, f) return math.mod(math.floor(v / f), 2) == 1 end

-- Totem watcher: emulates a GetTotemInfo(slot) the way pfUI's libtotem /
-- CallOfElements do on this client -- there's no native one on 1.12. A totem
-- drop is a shared-dispatch SPELL_GO_SELF matched against a bundled spellID->
-- {slot,duration} DB (ported from pfUI libtotem; CallOfElements builds the same
-- data at runtime by name-scan, so the static table is the cleaner source),
-- committing {name,icon,start,duration} into the element slot. Totemic Recall/
-- Call clears every slot (name-matched, enUS -- we ship no ID for it and Turtle
-- may re-ID it). No early-death detection beyond expiry + PLAYER_DEAD (no event
-- fires when a totem is killed) -- matches the references' own limitation.
local TOTEM_SPELLS = {
	-- FIRE (slot 1)
	[1535] = { 1, 5 }, [8498] = { 1, 5 }, [8499] = { 1, 5 }, [11314] = { 1, 5 }, [11315] = { 1, 5 },
	[8227] = { 1, 120 }, [8249] = { 1, 120 }, [10526] = { 1, 120 }, [16387] = { 1, 120 },
	[8184] = { 1, 120 }, [10478] = { 1, 120 }, [10479] = { 1, 120 },
	[8190] = { 1, 20 }, [10585] = { 1, 20 }, [10586] = { 1, 20 }, [10587] = { 1, 20 },
	[3599] = { 1, 30 }, [6363] = { 1, 35 }, [6364] = { 1, 40 }, [6365] = { 1, 45 }, [10437] = { 1, 50 }, [10438] = { 1, 55 },
	-- EARTH (slot 2)
	[2484] = { 2, 45 }, [5730] = { 2, 15 }, [6390] = { 2, 15 }, [6391] = { 2, 15 }, [6392] = { 2, 15 },
	[10427] = { 2, 15 }, [10428] = { 2, 15 },
	[8071] = { 2, 120 }, [8154] = { 2, 120 }, [8155] = { 2, 120 }, [10406] = { 2, 120 }, [10407] = { 2, 120 }, [10408] = { 2, 120 },
	[8075] = { 2, 120 }, [8160] = { 2, 120 }, [8161] = { 2, 120 }, [10442] = { 2, 120 }, [25361] = { 2, 120 },
	[8143] = { 2, 120 },
	-- WATER (slot 3)
	[8170] = { 3, 120 }, [8185] = { 3, 120 }, [10537] = { 3, 120 }, [10538] = { 3, 120 },
	[5394] = { 3, 60 }, [6375] = { 3, 60 }, [6377] = { 3, 60 }, [10462] = { 3, 60 }, [10463] = { 3, 60 },
	[5675] = { 3, 60 }, [10495] = { 3, 60 }, [10496] = { 3, 60 }, [10497] = { 3, 60 },
	[16190] = { 3, 12 }, [8166] = { 3, 120 },
	-- AIR (slot 4)
	[8835] = { 4, 120 }, [10627] = { 4, 120 }, [8177] = { 4, 45 },
	[10595] = { 4, 120 }, [10600] = { 4, 120 }, [10601] = { 4, 120 }, [25359] = { 4, 120 },
	[8512] = { 4, 120 }, [10613] = { 4, 120 }, [10614] = { 4, 120 },
	[15107] = { 4, 120 }, [15421] = { 4, 120 }, [15422] = { 4, 120 },
}
local TOTEM_RECALL_NAMES = { ["Totemic Recall"] = true, ["Totemic Call"] = true }
local totemActive = {} -- slot -> { name, icon, start, duration }
local totemMiscFrame
local function totemClearAll()
	local any = false
	for slot in pairs(totemActive) do totemActive[slot] = nil; any = true end
	if any then WA.ScanEvents("WA_TOTEM_UPDATE") end
end
function WA.WatchTotems()
	if totemMiscFrame then return end
	totemMiscFrame = CreateFrame("Frame")
	pcall(totemMiscFrame.RegisterEvent, totemMiscFrame, "PLAYER_DEAD")
	totemMiscFrame:SetScript("OnEvent", totemClearAll)
	subscribeSpellGoSelf(function(spellId)
		local data = TOTEM_SPELLS[spellId]
		if data then
			local name, _, icon = GetSpellInfo(spellId)
			totemActive[data[1]] = { name = name, icon = icon, start = GetTime(), duration = data[2] }
			WA.ScanEvents("WA_TOTEM_UPDATE")
			return
		end
		local nm = GetSpellInfo(spellId)
		if nm and TOTEM_RECALL_NAMES[nm] then totemClearAll() end
	end)
end
-- (active, name, icon, start, duration) or nil once expired (self-cleaning, the
-- same shape pfUI's GetTotemInfo returns).
function WA.TotemInfo(slot)
	local t = totemActive[slot]
	if not t then return false end
	if (t.start + t.duration) - GetTime() < 0 then
		totemActive[slot] = nil
		return false
	end
	return true, t.name, t.icon, t.start, t.duration
end

-- Swing-timer watcher: a faithful port of pfUI modules/swingtimer.lua's state
-- machine, translated from its bar+OnUpdate rendering to WeakestAuras' data
-- model --
-- each hand is stored as {active,start,duration} the region animates, and the
-- extra swing state (blocked / clip / queued ability) is surfaced as condition
-- variables instead of a hardcoded bar tint. State is consolidated into one
-- table to stay clear of Lua 5.0's 32-upvalue-per-closure limit (pfUI's S does
-- the same). All the Spell.dbc reads go through GetSpellRecField, a Nampower
-- accessor (used by pfUI + DoiteAuras, not a ClassicAPI backport) -- every call
-- is guarded so a build lacking it simply degrades to AUTO_ATTACK_SELF-only
-- resets (the shipped core behaviour).
local HITINFO_LEFTSWING, HITINFO_NOACTION = 4, 65536
local ATTR_ON_NEXT_SWING = 4      -- 0x04    replaces the next auto-attack swing
local FLAG_AUTOATTACK = 8         -- 0x08    interruptFlags: cast resets the swing
local ATTR_KEEP_SWINGS = 131072   -- 0x20000 attributesEx2: cast does NOT reset it
local SWING_PROC_LATENCY = 0.15
local WAND_SHOOT_SPELLID, THROW_SPELLID = 5019, 2764
-- OctoWoW re-IDs Slam and SPELL_START_SELF is silent for it, so swing-delay casts
-- are matched by NAME off SPELLCAST_START (rank/id-proof).
local SWING_DELAY_NAMES = { ["Slam"] = true, ["Hammer of Wrath"] = true }
-- Rank-1 canonical names (rank/locale-proof) for on-next-swing classification.
local HS_NAME = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(78)
local CLEAVE_NAME = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(845)
local MAUL_NAME = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(6807)

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
	playerGuid = nil, onSwingCache = {},
}
local swingFrame

local function swingUpdateSpeeds()
	if UnitAttackSpeed then
		local ms, os = UnitAttackSpeed("player")
		if ms and ms > 0 then sw.mhSpeed = ms end
		sw.ohSpeed = (os and os > 0) and os or 0
	end
	if UnitRangedDamage then
		local rs = UnitRangedDamage("player")
		sw.raSpeed = (rs and rs > 0) and rs or 0
	end
end

-- Spell.dbc "replaces the next swing" bit (SPELL_ATTR_ON_NEXT_SWING), cached.
local function isOnSwingSpell(spellId)
	local c = sw.onSwingCache[spellId]
	if c ~= nil then return c end
	local attr = (GetSpellRecField and GetSpellRecField(spellId, "attributes")) or 0
	local r = hasFlag(attr, ATTR_ON_NEXT_SWING)
	sw.onSwingCache[spellId] = r
	return r
end
local function classifyOnSwing(spellId)
	if not isOnSwingSpell(spellId) then return nil end
	local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellId)
	if name and name == HS_NAME then return "hs"
	elseif name and name == CLEAVE_NAME then return "cleave"
	elseif name and name == MAUL_NAME then return "maul" end
	return nil
end
-- Action-bar slot cache: queue detection fallback for builds without Nampower's
-- SPELL_QUEUE_EVENT. Warriors only (HS/Cleave); rebuilt on bar/equipment change.
local function rebuildQueueSlots()
	sw.hsSlots = {}; sw.cleaveSlots = {}
	if not (sw.isWarrior and GetActionInfo) then return end
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
	if not IsCurrentAction then return false end
	for i = 1, table.getn(slots) do
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

local function swingReset(hand)
	swingUpdateSpeeds()
	local speed = (hand == "off" and sw.ohSpeed) or (hand == "ranged" and sw.raSpeed) or sw.mhSpeed
	if not speed or speed <= 0 then return end
	local s = swing[hand]
	s.start = GetTime(); s.duration = speed; s.active = true
	if hand == "main" then sw.mhBlocked = false; sw.mhClipWarn = false; sw.mhClipDelay = 0 end
	WA.ScanEvents("WA_SWING_UPDATE")
end
-- Ranged auto-attack: Auto Shot / Throw replace the melee swing clock; wand Shoot
-- leaves it running (casters weave), so replaceMH is false only there.
local function swingResetRanged(replaceMH)
	swingUpdateSpeeds()
	if sw.raSpeed <= 0 then return end
	if replaceMH then swing.main.active = false end
	local r = swing.ranged
	r.start = GetTime(); r.duration = sw.raSpeed; r.active = true
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
-- Parry haste: the player parried (AUTO_ATTACK_OTHER victimState 3, victim = the
-- player) -> the nearest-to-firing melee swing is hastened 40% of weapon speed,
-- floored at 20% remaining (SP_SwingTimer's rule). Move `start` earlier, clamped.
local function swingParryHaste()
	local now = GetTime()
	local function apply(s, speed)
		if not s.active or not speed or speed <= 0 then return false end
		local remaining = (s.start + s.duration) - now
		local minimum = speed * 0.20
		if remaining <= minimum then return false end
		local reduced = remaining - speed * 0.40
		if reduced < minimum then reduced = minimum end
		s.start = now - (s.duration - reduced)
		return true
	end
	local m, o = swing.main, swing.off
	local mFrac = (m.active and m.duration > 0) and (((m.start + m.duration) - now) / m.duration) or 2
	local oFrac = (o.active and o.duration > 0) and (((o.start + o.duration) - now) / o.duration) or 2
	local changed
	if oFrac < mFrac then changed = apply(o, sw.ohSpeed) else changed = apply(m, sw.mhSpeed) end
	if changed then WA.ScanEvents("WA_SWING_UPDATE") end
end
-- Swing-delay cast (Slam / Hammer of Wrath): the swing keeps ticking but the auto
-- can't fire until the cast ends. If the cast will finish AFTER the swing is
-- ready, the auto is clipped by (castDur - remaining) -- surfaced as clipWarning/
-- clipDelay. Called with a duration from SPELLCAST_START and with 0 from the
-- attribute-driven SPELL_START_SELF fallback, so a 0 only sets the block.
local function swingBeginDelayCast(castDur)
	if not swing.main.active then return end
	sw.mhBlocked = true
	if castDur and castDur > 0 then
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
-- Shared-dispatch SPELL_GO_SELF: a cast landed. Ranged auto-attacks reset the
-- ranged clock; on-next-swing abilities (HS/Cleave/Maul/Raptor/etc.) consume the
-- MH swing; otherwise mirror the server melee-reset rule (interruptFlags has
-- AUTOATTACK and attributesEx2 lacks KEEP_SWINGS). A blocked swing-delay cast
-- that doesn't reset just releases the hold.
local function swingOnSpellGo(spellId)
	if C_Spell and C_Spell.IsRangedAutoAttackSpell and C_Spell.IsRangedAutoAttackSpell(spellId) then
		swingResetRanged(spellId ~= WAND_SHOOT_SPELLID)
		return
	elseif spellId == THROW_SPELLID then
		swingResetRanged(true)
		return
	elseif isOnSwingSpell(spellId) then
		sw.queued = "none"
		swingReset("main")
		return
	end
	local iflags = (GetSpellRecField and GetSpellRecField(spellId, "interruptFlags")) or 0
	local ex2 = (GetSpellRecField and GetSpellRecField(spellId, "attributesEx2")) or 0
	if hasFlag(iflags, FLAG_AUTOATTACK) and not hasFlag(ex2, ATTR_KEEP_SWINGS) then
		if swing.main.active then swingReset("main") end
		if swing.off.active then swingReset("off") end
	elseif sw.mhBlocked then
		swingClearDelayCast()
	end
end
function WA.WatchSwing()
	if swingFrame then return end
	local _, class = UnitClass("player")
	sw.isWarrior = (class == "WARRIOR")
	if UnitExists then local _, g = UnitExists("player"); sw.playerGuid = g end
	swingUpdateSpeeds()
	rebuildQueueSlots()
	swingFrame = CreateFrame("Frame")
	local evs = { "AUTO_ATTACK_SELF", "AUTO_ATTACK_OTHER", "START_AUTOATTACK",
		"STOP_AUTOATTACK", "UNIT_ATTACK_SPEED", "PLAYER_EQUIPMENT_CHANGED",
		"PLAYER_ENTERING_WORLD", "ACTIONBAR_SLOT_CHANGED", "SPELLCAST_START",
		"SPELL_START_SELF", "SPELLCAST_FAILED", "SPELLCAST_INTERRUPTED",
		"SPELL_QUEUE_EVENT" }
	for i = 1, table.getn(evs) do pcall(swingFrame.RegisterEvent, swingFrame, evs[i]) end
	swingFrame:SetScript("OnEvent", function()
		if event == "AUTO_ATTACK_SELF" then
			local hitInfo = arg4 or 0
			local hand = hasFlag(hitInfo, HITINFO_LEFTSWING) and "off" or "main"
			local s = swing[hand]
			-- Server didn't advance the clock (dodge/parry/miss): leave a running
			-- timer alone, but still start one that isn't active yet.
			if hasFlag(hitInfo, HITINFO_NOACTION) and s.active then return end
			-- Extra attack: >20% of the swing still remaining => the server did not
			-- reset the clock, so this hit is an extra attack -- don't restart.
			if s.active and s.duration > 0 then
				local remaining = (s.start + s.duration) - GetTime()
				if remaining > 0 and (remaining / s.duration) > 0.20 then return end
			end
			swingReset(hand)
		elseif event == "AUTO_ATTACK_OTHER" then
			if arg5 == 3 and (not sw.playerGuid or arg2 == sw.playerGuid) then swingParryHaste() end
		elseif event == "UNIT_ATTACK_SPEED" then
			if arg1 and arg1 ~= "player" then return end
			swingRescale()
		elseif event == "SPELLCAST_START" then
			if arg1 and SWING_DELAY_NAMES[arg1] then swingBeginDelayCast((arg2 or 0) / 1000) end
		elseif event == "SPELL_START_SELF" then
			if arg1 and arg1 > 0 and swing.main.active then
				local iflags = (GetSpellRecField and GetSpellRecField(arg1, "interruptFlags")) or 0
				if not hasFlag(iflags, FLAG_AUTOATTACK) then swingBeginDelayCast(0) end
			end
		elseif event == "SPELLCAST_FAILED" or event == "SPELLCAST_INTERRUPTED" then
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
	subscribeSpellGoSelf(swingOnSpellGo)
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

-- Power-tick watcher: no client event fires on the 2s energy / 5s mana regen
-- tick itself, so it's inferred from power-value increases, the same approach
-- pfUI's energytick module uses. Rage and focus have no regen tick.
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
	-- A buff/proc gain (e.g. Thistle Tea) also raises power but isn't a tick;
	-- the combat-log filter below flags the one that follows so it doesn't
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
		"PLAYER_ENTERING_WORLD", "CHAT_MSG_SPELL_SELF_BUFF",
		"CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS" }
	for i = 1, table.getn(evs) do pcall(powerTickFrame.RegisterEvent, powerTickFrame, evs[i]) end
	powerTickFrame:SetScript("OnEvent", function()
		if event == "UNIT_DISPLAYPOWER" or event == "PLAYER_ENTERING_WORLD" then
			if arg1 and arg1 ~= "player" then return end
			powerTickResync()
		elseif event == "CHAT_MSG_SPELL_SELF_BUFF" or event == "CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS" then
			if arg1 and string.find(arg1, "You gain") and string.find(arg1, "Energy from") then
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

-- ---------------------------------------------------------------------------
-- Event dispatch (§4.3) + the shared game-event frame
-- ---------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local registered = {} -- event -> true, so we RegisterEvent each game event once

local function ensureEventRegistered(event)
	if registered[event] or INTERNAL_EVENTS[event] then return end
	registered[event] = true
	-- Guarded: an invalid event name on this build would otherwise error out the
	-- whole Add (risk (c)).
	pcall(eventFrame.RegisterEvent, eventFrame, event)
end

-- A fire-and-forget trigger takes itself down on a timer instead of on a later
-- event. C_Timer.NewTimer, not After: After returns nothing on this client, and
-- a re-fire before the deadline must retract the pending hide or the second show
-- gets cut short by the first one's timer.
local function scheduleAutoHide(ti)
	if ti.hideTimer then ti.hideTimer:Cancel() end
	ti.hideTimer = C_Timer.NewTimer(ti.duration, function()
		ti.hideTimer = nil
		local states = WA.GetTriggerStateForTrigger(ti.id, ti.triggernum)
		local s = states and states[""]
		if s and s.show then
			s.show = false; s.changed = true
			WA.UpdatedTriggerState(ti.id)
		end
	end)
end

-- ActivateEvent-lite (§4.3): after a passing test, normalize the state's
-- progress/name/icon. Stores already wrote the raw matched fields; this fills
-- the display-shaped fields regions read.
local function activateEvent(state, ti)
	local proto = ti.proto
	if not state.show then state.show = true; state.changed = true end

	local function setC(k, v)
		if state[k] ~= v then state[k] = v; state.changed = true end
	end

	if ti.autoHide then
		-- Its progress is the countdown to its own hide timer, not anything the
		-- prototype stores, and every re-fire restarts both together.
		setC("progressType", "timed")
		setC("duration", ti.duration)
		setC("expirationTime", GetTime() + ti.duration)
		scheduleAutoHide(ti)
	else
		-- ti.* overrides let a per-trigger prototype (the custom trigger) pick its
		-- progress shape at Add time; built-in prototypes leave them nil and fall back
		-- to the static proto fields.
		local progressType = ti.progressType or proto.progressType
		local progressValue = ti.progressValue or proto.progressValue
		local progressTotal = ti.progressTotal or proto.progressTotal
		if progressType == "timed" then
			setC("progressType", "timed")
		elseif progressType == "static" then
			setC("progressType", nil)
			setC("value", state[progressValue] or 0)
			setC("total", state[progressTotal] or 0)
		else
			setC("progressType", nil)
		end
	end

	-- ti.name/ti.icon are compile-time constants (nameFunc/iconFunc run once at
	-- Add). A prototype that stores a live `name`/`icon` field (e.g. health/power
	-- reading UnitName each tick) has already written state; only fall back to the
	-- constant when it didn't -- which also keeps a target-unit's display name live
	-- instead of frozen at the target present when the aura was compiled.
	if ti.name ~= nil and state.name == nil then setC("name", ti.name) end
	if ti.icon ~= nil and state.icon == nil then setC("icon", ti.icon) end
end

-- Runs one trigger's compiled function for an event and reconciles its "" state.
-- Returns true if the state changed (so the caller batches UpdatedTriggerState).
local function runTriggerFunc(ti, event, a1, a2, a3, a4, a5, a6, a7, a8, a9)
	local states = WA.GetTriggerStateForTrigger(ti.id, ti.triggernum)
	if not states then return false end
	local state = states[""]
	if not state then state = {}; states[""] = state end

	-- state.changed is false on entry (UpdatedTriggerState clears it after every
	-- batch, step 7), so the flag the compiled stores / activateEvent set is a
	-- true "changed since last apply" signal.
	local ok, passed = WA.RunAuraFunc(ti.id, ti.id, ti.triggerFunc, state, event,
		a1, a2, a3, a4, a5, a6, a7, a8, a9)
	if ok and passed then
		activateEvent(state, ti)
	elseif state.show and not ti.autoHide then
		-- An autoHide trigger owns its own hiding: a later event whose test fails
		-- must not pull it down before its timer says so.
		state.show = false; state.changed = true
	end
	return state.changed and true or false
end

-- The producer entry point watchers and the event frame both call (§4.3):
-- walk every trigger registered for `event`, run it, batch one
-- UpdatedTriggerState per affected display.
function WA.ScanEvents(event, a1, a2, a3, a4, a5, a6, a7, a8, a9)
	local byId = loaded_events[event]
	if not byId then return end
	local dirty = {}
	for id, byTrigger in pairs(byId) do
		for triggernum, ti in pairs(byTrigger) do
			if not WA.forced[id] then
				if runTriggerFunc(ti, event, a1, a2, a3, a4, a5, a6, a7, a8, a9) then
					dirty[id] = true
				end
			end
		end
	end
	for id in pairs(dirty) do WA.UpdatedTriggerState(id) end
end

-- A handler on this client reads the event payload off the globals arg1..arg9,
-- which exist only for the duration of the handler -- so they are read here and
-- passed explicitly rather than left for ScanEvents to pick up.
eventFrame:SetScript("OnEvent", function()
	WA.ScanEvents(event, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9)
end)

-- ---------------------------------------------------------------------------
-- Trigger-system contract (StateMachine.lua calls these)
-- ---------------------------------------------------------------------------

-- Pulls a display's tis out of loaded_events (it stops receiving events) but
-- leaves events[id] intact -- Unload uses this, Delete drops events[id] after.
local function unregisterEvents(id)
	local byTrigger = events[id]
	if not byTrigger then return end
	for triggernum, ti in pairs(byTrigger) do
		-- A pending hide outlives the events that scheduled it, and would fire
		-- against a display that has since unloaded or been recompiled.
		if ti.hideTimer then ti.hideTimer:Cancel(); ti.hideTimer = nil end
		local evs = ti.eventList or {}
		for i = 1, table.getn(evs) do
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
end

-- Compile only: build each triggernum into a ti stored in events[id]. Neither
-- registers into loaded_events nor force-initializes status triggers -- both
-- wait for LoadDisplays (§11), so an unloaded display costs no events.
function GenericTrigger.Add(data)
	-- Kept across the Delete below so a trigger whose compiled source is
	-- unchanged can be told from one that was edited: the second is a seam for
	-- dropping whatever the old code cached in aura_env, and WA.Add is not --
	-- it fires per drag step.
	local prev = events[data.id]
	GenericTrigger.Delete(data.id)
	local byTrigger = {}
	events[data.id] = byTrigger

	for triggernum = 1, table.getn(data.triggers) do
		local trigger = WA.GetTrigger(data, triggernum)
		local proto = trigger and PROTOTYPES[trigger.type]
		if proto then
			local fn, source
			local errTag = data.id .. ": trigger " .. triggernum
			if proto.custom then
				fn, source = constructCustomFunction(trigger, errTag)
			else
				fn, source = constructFunction(proto, trigger, errTag)
			end
			local prevTi = prev and prev[triggernum]
			if not prevTi or prevTi.source ~= source then WA.ClearAuraEnv(data.id) end
			if fn then
				local ti = {
					id = data.id, triggernum = triggernum, proto = proto,
					trigger = trigger, triggerFunc = fn, source = source,
					eventList = proto.events(trigger),
					name = proto.nameFunc and proto.nameFunc(trigger) or nil,
					icon = proto.iconFunc and proto.iconFunc(trigger) or proto.icon,
				}
				-- Custom triggers pick their progress shape from config; the user
				-- writes state.value/state.total (static) or state.duration/
				-- expirationTime (timed) directly, so the progress keys point at
				-- those generic names rather than a prototype-declared store arg.
				if proto.custom then
					ti.progressType = trigger.customProgressType or "none"
					ti.progressValue = "value"
					ti.progressTotal = "total"
				end
				if proto.autoHide then
					ti.autoHide = true
					ti.duration = tonumber(trigger.duration) or 1
				end
				byTrigger[triggernum] = ti
			end
		end
	end
end

-- Load: register this display's tis into loaded_events (+ RegisterEvent their
-- game events), fire watcher loadFuncs, then force-initialize status triggers
-- (§4.3 force_events) and recombine once. Only touches ids this system
-- compiled (events[id]).
function GenericTrigger.LoadDisplays(ids)
	for k = 1, table.getn(ids) do
		local id = ids[k]
		local byTrigger = events[id]
		if byTrigger and not activeIds[id] then
			activeIds[id] = true
			local toForce = {}
			for triggernum, ti in pairs(byTrigger) do
				for i = 1, table.getn(ti.eventList) do
					local ev = ti.eventList[i]
					ensureEventRegistered(ev)
					loaded_events[ev] = loaded_events[ev] or {}
					loaded_events[ev][id] = loaded_events[ev][id] or {}
					loaded_events[ev][id][triggernum] = ti
				end
				-- loadFunc (e.g. WatchSpellCooldown) is a "start watching" side
				-- effect, so it belongs to load, not compile -- an unloaded
				-- cooldown aura shouldn't spin up its watcher.
				if ti.proto.loadFunc then ti.proto.loadFunc(ti.trigger) end
				if ti.proto.force_events then table.insert(toForce, ti) end
			end
			if table.getn(toForce) > 0 then
				for i = 1, table.getn(toForce) do
					runTriggerFunc(toForce[i], "FORCE")
				end
				WA.UpdatedTriggerState(id)
			end
		end
	end
end

-- Re-seed an already-loaded display's status triggers (WA2's
-- ScanWithFakeEvent): same force_events pass LoadDisplays runs, for callers that
-- wiped the produced states without a load transition -- the options preview
-- retiring its fake, which otherwise leaves a still-true status trigger reading
-- as inactive until its next real event.
function GenericTrigger.ForceUpdate(ids)
	for k = 1, table.getn(ids) do
		local id = ids[k]
		local byTrigger = events[id]
		if byTrigger and activeIds[id] then
			local dirty = false
			for triggernum, ti in pairs(byTrigger) do
				if ti.proto.force_events then
					if runTriggerFunc(ti, "FORCE") then dirty = true end
				end
			end
			if dirty then WA.UpdatedTriggerState(id) end
		end
	end
end

-- Unload: pull the display's tis from loaded_events, keeping events[id] so a
-- reload re-registers without recompiling.
function GenericTrigger.UnloadDisplays(ids)
	for k = 1, table.getn(ids) do
		local id = ids[k]
		if activeIds[id] then
			activeIds[id] = nil
			unregisterEvents(id)
		end
	end
end

function GenericTrigger.Delete(id)
	GenericTrigger.UnloadDisplays({ id })
	events[id] = nil
end

function GenericTrigger.Rename(oldId, newId)
	local byTrigger = events[oldId]
	if not byTrigger then return end
	for triggernum, ti in pairs(byTrigger) do
		ti.id = newId
		local evs = ti.eventList or {}
		for i = 1, table.getn(evs) do
			local map = loaded_events[evs[i]]
			if map and map[oldId] then
				map[newId] = map[oldId]
				map[oldId] = nil
			end
		end
	end
	events[newId] = byTrigger
	events[oldId] = nil
	if activeIds[oldId] then
		activeIds[newId] = true
		activeIds[oldId] = nil
	end
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

-- Condition variables (§10): every store arg that declared a conditionType.
function GenericTrigger.GetTriggerConditions(data, triggernum)
	local trigger = WA.GetTrigger(data, triggernum)
	local proto = trigger and PROTOTYPES[trigger.type]
	if not proto then return {} end
	local out = {}
	for i = 1, table.getn(proto.args) do
		local arg = proto.args[i]
		if arg.conditionType then
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

local function buildDefaults(proto)
	local d = {}
	for i = 1, table.getn(proto.args) do
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
		elseif arg.type == "spell" or arg.type == "item" or arg.type == "text" then
			d[arg.name] = arg.default or ""
		elseif arg.type == "toggle" then
			d[arg.name] = arg.default or false
		elseif arg.type == "select" and arg.required then
			d[arg.name] = arg.default or (arg.valueList and arg.valueList[1])
		elseif arg.type == "select" and not arg.required then
			d["use_" .. arg.name] = false
			d[arg.name] = arg.default or (arg.valueList and arg.valueList[1])
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

	-- Custom trigger has no args -- its editor is the code/events/progress fields,
	-- not the generated per-arg controls. Committing recompiles via WA.Add (which
	-- surfaces any compile error to chat; /wa gen dumps the stored source).
	if proto.custom then
		local fields = WA.TriggerTypeFields(data, t)
		local more = {
			{ type = "header", name = "Custom Status Trigger" },
			{ type = "select", name = "Progress", key = "customProgressType",
				values = { "none", "timed", "static" },
				labels = { none = "None", timed = "Timed", static = "Static" },
				get = function() return t.customProgressType or "none" end,
				set = function(v) t.customProgressType = v; WA.Add(data) end },
			{ type = "input", name = "Events (comma-separated)", key = "customEvents",
				get = function() return t.customEvents or "" end,
				set = function(v) t.customEvents = v; WA.Add(data) end },
			{ type = "code", name = "Custom Trigger Function", key = "customTrigger", height = 180,
				-- Raw, not `or ""`: nil means never configured (open at the
				-- default below), "" means cleared and left cleared. MergeDefaults
				-- seeds this one, so nil only shows up on a hand-built trigger.
				get = function() return t.customTrigger end,
				set = function(v) t.customTrigger = v; WA.Add(data) end,
				-- Reset seeds the signature back, so an emptied box is recoverable
				-- without the user having to remember the shape. Taken from the
				-- prototype's own defaults rather than spelled out again here.
				default = proto.defaults and proto.defaults.customTrigger,
				-- Asked of the compiler for its wrapper rather than spelling one
				-- here: two spellings drift, and the symptom is an error line
				-- number silently off by one.
				validate = function(txt)
					return WA.Widgets.LuaSyntaxError(WA.WrapFunctionSource(txt), "custom trigger")
				end },
		}
		for i = 1, table.getn(more) do table.insert(fields, more[i]) end
		return fields
	end

	local fields = WA.TriggerTypeFields(data, t)

	for i = 1, table.getn(proto.args) do
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
				values = WA.unit_tokens, labels = WA.unit_labels,
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
		elseif arg.type == "select" and arg.required then
			table.insert(fields, {
				type = "select", name = arg.display or arg.name, key = arg.name,
				values = arg.valueList or arg.values, labels = arg.valueLabels,
				get = function() return t[arg.name] end,
				set = function(v)
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
			summary = buildSummary(proto),
			options = buildOptions,
		})
		table.insert(systemTypes, typeName)
	end
end

WA.RegisterTriggerSystem(systemTypes, GenericTrigger)
