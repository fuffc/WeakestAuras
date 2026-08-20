-- WeakestAuras -- trigger *types*: the options-side registry (defaults + a
-- config tab + a summary line per trigger.type), via
-- WeakestAuras.RegisterTriggerType; see Data.lua. The runtime layer that turns
-- this config into states lives in a trigger *system* (TriggerAura.lua),
-- registered via WA.RegisterTriggerSystem -- same options/runtime split as
-- upstream's triggerTypesOptions vs triggerSystems.
-- Upstream section refs (§N) point at design/architecture/weakauras2-reference.md
--
-- Field names track upstream's BuffTrigger2 (§5) so future features and
-- (eventually) imported WA2 strings
-- line up: unit, debuffType, useName + auranames, matchesShowOn. `auranames` is
-- an any-of-these list (LibWidgets add/remove/reorder editor); simplified from
-- upstream's split auranames/auraspellids arrays -- a numeric entry here is
-- matched by spellId, a text entry by name, no separate useExactSpellId flag.

if WeakestAuras.disabled then return end

local WA = WeakestAuras

local DEBUFF_TYPE_LABELS = { HELPFUL = "Buff", HARMFUL = "Debuff", BOTH = "Both" }
local SHOW_ON_LABELS = {
	showOnActive = "Aura(s) Active",
	showOnMissing = "Aura(s) Missing",
	showAlways = "Always",
}
local NAME_PATTERN_LABELS = { match = "Contains", nomatch = "Doesn't Contain" }
-- The dispel classes AuraData.dispelName can carry (from SpellDispelType.dbc).
-- Already display-ready, so no label table.
local DISPEL_TYPES = { "Magic", "Curse", "Disease", "Poison" }

-- Trigger types grouped for the picker, in menu order. Two dozen types in one
-- flat list is not browsable, so the editor asks for a category first and then
-- the type within it (§4.1). The category is *derived* from the selected type
-- and never stored: a type determines its own category, so keeping both in saved
-- data would be two fields where one decides the other. `default` is the type a
-- category switch lands on.
local CATEGORIES = {
	{ key = "aura",   name = "Aura",          default = "aura" },
	{ key = "spell",  name = "Spell",         default = "spellcooldown" },
	{ key = "item",   name = "Item",          default = "itemcooldown" },
	{ key = "unit",   name = "Player & Unit", default = "health" },
	{ key = "event",  name = "Events",        default = "readycheck" },
	{ key = "custom", name = "Custom",        default = "custom" },
}

local function categoryOf(typeName)
	local spec = typeName and WA.triggerTypes[typeName]
	return (spec and spec.category) or "unit"
end

-- Registered trigger types in one category ("aura" plus every GenericTrigger
-- prototype -- read live at options-build time, so a prototype registered in a
-- later file still shows up).
local function triggerTypeList(category)
	local list, labels = {}, {}
	for name, spec in pairs(WA.triggerTypes) do
		if not category or (spec.category or "unit") == category then
			table.insert(list, name)
			labels[name] = spec.displayName or name
		end
	end
	-- Ordered by the label the user reads rather than the internal key, which
	-- would file "In Combat" under `combat` and scatter the cooldown types.
	table.sort(list, function(a, b) return (labels[a] or a) < (labels[b] or b) end)
	return list, labels
end

-- The shared Category + Type controls, reused by every trigger type's options
-- generator (aura here, each generic prototype in GenericTrigger.lua) so the
-- user can switch a trigger between kinds from any of them. Returns an array:
-- the Type dropdown is left out when its category holds a single type, which
-- would otherwise be a control with nothing to choose. Switching either seeds
-- the new type's defaults (MergeDefaults is non-destructive) before rebuilding,
-- so the freshly-selected type's config fields exist for its editor.
function WA.TriggerTypeFields(data, t)
	local function switchTo(v)
		t.type = v
		WA.MergeDefaults(data)
		WA.Add(data)
		WA.RefreshOptions()
	end

	local catKeys, catLabels = {}, {}
	for i = 1, table.getn(CATEGORIES) do
		catKeys[i] = CATEGORIES[i].key
		catLabels[CATEGORIES[i].key] = CATEGORIES[i].name
	end

	local fields = { {
		type = "select", name = "Category", key = "category",
		values = catKeys, labels = catLabels,
		get = function() return categoryOf(t.type) end,
		set = function(v)
			for i = 1, table.getn(CATEGORIES) do
				if CATEGORIES[i].key == v then switchTo(CATEGORIES[i].default); return end
			end
		end,
	} }

	local types, typeLabels = triggerTypeList(categoryOf(t.type))
	if table.getn(types) > 1 then
		table.insert(fields, {
			type = "select", name = "Type", key = "type",
			values = types, labels = typeLabels,
			get = function() return t.type end,
			set = switchTo,
		})
	end
	return fields
end

WA.RegisterTriggerType("aura", {
	displayName = "Aura",
	category = "aura",
	defaults = {
		unit = "player",
		specificUnit = "",
		debuffType = "HELPFUL",
		useName = true,
		auranames = {},
		auraignorenames = {},
		matchesShowOn = "showOnActive",
		unitExists = false,
		ownOnly = false,
		castByPlayer = false,
		use_debuffClass = false,
		debuffClass = "Magic",
		useStacks = false,
		stacksOperator = ">=",
		stacks = 1,
		useRem = false,
		remOperator = "<=",
		rem = 0,
		useTotal = false,
		totalOperator = ">=",
		total = 0,
		useCasterName = false,
		casterName = "",
		useNamePattern = false,
		namePattern = "",
		namePatternOperator = "match",
	},
	-- In-place migration of an older saved aura trigger to the field names above.
	-- Idempotent (MergeDefaults runs it on every touch).
	migrate = function(t)
		if t.auraType ~= nil then
			if t.debuffType == nil then t.debuffType = t.auraType end
			t.auraType = nil
		end
		if t.spellName ~= nil then
			if t.spellName ~= "" then
				t.auranames = t.auranames or {}
				if not t.auranames[1] then t.auranames[1] = t.spellName end
				t.useName = true
			end
			t.spellName = nil
		end
	end,
	summary = function(data)
		local t = WA.GetTrigger(data, 1)
		if not t then return "" end
		local kind = t.debuffType == "HARMFUL" and "Debuff" or (t.debuffType == "BOTH" and "Aura" or "Buff")
		local n = t.auranames and table.getn(t.auranames) or 0
		local spell = (n > 0 and t.auranames[1] ~= "") and t.auranames[1] or "?"
		if n > 1 then spell = spell .. " (+" .. (n - 1) .. ")" end
		return kind .. ": " .. spell .. " (" .. WA.TriggerUnit(t, "player") .. ")"
	end,
	options = function(data, triggernum)
		local t = WA.GetTrigger(data, triggernum or 1)
		local fields = WA.TriggerTypeFields(data, t)
		-- The dropdown's "specific" entry swaps in a free-text token field
		-- beside it; the dropdown's stored token survives being hidden and
		-- comes back when the override is switched off.
		table.insert(fields, {
			type = "select", name = "Unit", key = "unit", half = true,
			values = WA.unit_tokens_multi, labels = WA.unit_labels_multi,
			get = function() return t.unit end,
			set = function(v) t.unit = v; WA.Add(data); WA.RefreshOptions() end,
		})
		if t.unit == "specific" then
			table.insert(fields, {
				type = "input", name = "Unit Token", key = "specificUnit", half = true,
				get = function() return t.specificUnit or "" end,
				set = function(v) t.specificUnit = v; WA.Add(data) end,
			})
		end
		local more = {
			{
				type = "select", name = "Aura Type", key = "debuffType", half = true,
				values = { "HELPFUL", "HARMFUL", "BOTH" },
				labels = DEBUFF_TYPE_LABELS,
				get = function() return t.debuffType end,
				set = function(v) t.debuffType = v; WA.Add(data) end,
			},

			{ type = "header", name = "Spell Selection" },
			{
				-- Any-of-these-match list: a numeric entry matches by spellId
				-- (AuraData.spellId, more precise than name -- handles same-name
				-- rank collisions), a text entry by aura.name. No separate
				-- ID-vs-name toggle is needed since WA.ResolveSpellID's
				-- numeric-trusts-as-ID rule already disambiguates the two per
				-- entry.
				type = "namelist", name = "Aura Names / IDs (any match)", key = "auranames",
				get = function() return t.auranames end,
				-- RefreshList too: the list row's icon and summary line are both
				-- derived from these entries (see resolveRowIcon).
				onChange = function() WA.Add(data); WA.RefreshList(); WA.RefreshOptions() end,
			},
			{
				-- Rejected even when the match list also names them, so a broad
				-- name pattern can be narrowed by exception. No RefreshList: the
				-- row icon and summary come from the match list only.
				type = "namelist", name = "Ignore Names / IDs", key = "auraignorenames",
				get = function() return t.auraignorenames end,
				onChange = function() WA.Add(data) end,
			},

			{ type = "header", name = "Active Aura Filters" },
			{
				type = "toggle", name = "Own Only", key = "ownOnly",
				get = function() return t.ownOnly end,
				set = function(v) t.ownOnly = v; WA.Add(data) end,
			},
			{
				type = "toggle", name = "Cast By Player", key = "castByPlayer",
				get = function() return t.castByPlayer end,
				set = function(v) t.castByPlayer = v; WA.Add(data) end,
			},
		}
		for i = 1, table.getn(more) do table.insert(fields, more[i]) end
		table.insert(fields, {
			type = "toggle", name = "Dispel Type", key = "use_debuffClass",
			get = function() return t.use_debuffClass end,
			set = function(v) t.use_debuffClass = v; WA.Add(data); WA.RefreshOptions() end,
		})
		if t.use_debuffClass then
			table.insert(fields, {
				type = "select", name = "Dispel Type", key = "debuffClass",
				values = DISPEL_TYPES,
				get = function() return t.debuffClass end,
				set = function(v) t.debuffClass = v; WA.Add(data) end,
			})
		end
		table.insert(fields, {
			type = "toggle", name = "Stacks", key = "useStacks",
			get = function() return t.useStacks end,
			set = function(v) t.useStacks = v; WA.Add(data); WA.RefreshOptions() end,
		})
		if t.useStacks then
			table.insert(fields, {
				type = "opnumber", name = "Stacks", key = "stacks",
				getOp = function() return t.stacksOperator end,
				setOp = function(v) t.stacksOperator = v; WA.Add(data) end,
				getVal = function() return t.stacks end,
				setVal = function(v) t.stacks = v; WA.Add(data) end,
			})
		end
		table.insert(fields, {
			type = "toggle", name = "Remaining Time", key = "useRem",
			get = function() return t.useRem end,
			set = function(v) t.useRem = v; WA.Add(data); WA.RefreshOptions() end,
		})
		if t.useRem then
			table.insert(fields, {
				type = "opnumber", name = "Remaining Time (s)", key = "rem",
				getOp = function() return t.remOperator end,
				setOp = function(v) t.remOperator = v; WA.Add(data) end,
				getVal = function() return t.rem end,
				setVal = function(v) t.rem = v; WA.Add(data) end,
			})
		end
		table.insert(fields, {
			type = "toggle", name = "Total Duration", key = "useTotal",
			get = function() return t.useTotal end,
			set = function(v) t.useTotal = v; WA.Add(data); WA.RefreshOptions() end,
		})
		if t.useTotal then
			table.insert(fields, {
				type = "opnumber", name = "Total Duration (s)", key = "total",
				getOp = function() return t.totalOperator end,
				setOp = function(v) t.totalOperator = v; WA.Add(data) end,
				getVal = function() return t.total end,
				setVal = function(v) t.total = v; WA.Add(data) end,
			})
		end
		table.insert(fields, {
			type = "toggle", name = "Caster Name", key = "useCasterName",
			get = function() return t.useCasterName end,
			set = function(v) t.useCasterName = v; WA.Add(data); WA.RefreshOptions() end,
		})
		if t.useCasterName then
			table.insert(fields, {
				type = "input", name = "Caster Name", key = "casterName",
				get = function() return t.casterName end,
				set = function(v) t.casterName = v; WA.Add(data) end,
			})
		end
		table.insert(fields, {
			type = "toggle", name = "Name Pattern", key = "useNamePattern",
			get = function() return t.useNamePattern end,
			set = function(v) t.useNamePattern = v; WA.Add(data); WA.RefreshOptions() end,
		})
		if t.useNamePattern then
			table.insert(fields, {
				type = "select", name = "Name Pattern", key = "namePatternOperator", half = true,
				values = { "match", "nomatch" },
				labels = NAME_PATTERN_LABELS,
				get = function() return t.namePatternOperator end,
				set = function(v) t.namePatternOperator = v; WA.Add(data) end,
			})
			table.insert(fields, {
				type = "input", name = "Text", key = "namePattern", half = true,
				get = function() return t.namePattern end,
				set = function(v) t.namePattern = v; WA.Add(data) end,
			})
		end

		table.insert(fields, { type = "header", name = "Show On" })
		table.insert(fields, {
			type = "select", name = "Show On", key = "matchesShowOn",
			values = { "showOnActive", "showOnMissing", "showAlways" },
			labels = SHOW_ON_LABELS,
			get = function() return t.matchesShowOn end,
			set = function(v) t.matchesShowOn = v; WA.Add(data) end,
		})
		table.insert(fields, {
			type = "toggle", name = "Show If Unit Is Not Available", key = "unitExists",
			get = function() return t.unitExists end,
			set = function(v) t.unitExists = v; WA.Add(data) end,
		})
		return fields
	end,
})
