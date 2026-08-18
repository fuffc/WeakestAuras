-- WeakestAuras -- WeakAuras2 display translation and import compatibility report.

if WeakestAuras.disabled then return end

local WA = WeakestAuras

local REGION_MAP = {
	icon = "icon",
	aurabar = "progressbar",
	texture = "texture",
	progresstexture = "progresstexture",
	text = "text",
	group = "group",
	dynamicgroup = "dynamicgroup",
	model = "fallback",
	stopmotion = "fallback",
}

local GROUP_TYPES = { group = true, dynamicgroup = true }

-- A bar texture travels as a LibSharedMedia *name*, and the sender's media
-- registry is not ours: an unknown name resolves to a missing file and the bar
-- draws nothing at all, which reads as a broken import rather than a missing
-- skin. Every name therefore lands on a bundled texture.
--
-- Names we ship (`WA.Widgets.BarTextures()`) pass through untouched. The aliases
-- below are the common wago names matched to the closest thing we have -- flat
-- fills to Flat, gradient/gloss fills to the bundled grain that looks like them.
-- Anything unlisted falls back to the region default and is reported, so the
-- user knows a skin was substituted rather than wondering why a bar looks plain.
local BAR_TEXTURE_ALIASES = {
	["Solid"] = "Flat",
	["ElvUI Blank"] = "Flat",
	["Details Flat"] = "Flat",
	["Details Hyanda"] = "Flat",
	["Details D'ictum"] = "Flat",
	["Blizzard Raid Bar"] = "Blizzard",
	["Blizzard Raid Bar 2"] = "Blizzard",
	["Melli Dark"] = "MelliDark",
	["Melli Dark Rough"] = "MelliDark",
	["Minimalist"] = "Minimalist",
	["X-Perl"] = "Gloss",
	["X-Perl 3"] = "Gloss",
	["Glaze v2"] = "Glaze2",
	["Perl v2"] = "Perl2",
	["Smooth v2"] = "Smoothv2",
	["LiteStepLite"] = "LiteStep",
	["Bantobar"] = "BantoBar",
	["Skewed"] = "Smooth",
}

local BAR_TEXTURE_DEFAULT = "Blizzard"

local PROTOTYPE_KEYS = {
	"width", "height", "alpha", "anchorFrameType", "anchorFrameFrame",
	"anchorFrameParent", "selfPoint", "anchorPoint", "xOffset", "yOffset",
	"frameStrata", "customText", "customTextUpdate", "customTextUpdateThrottle",
}

local TEXT_KEYS = {
	"font", "outline", "justify", "justifyV", "spacing", "shadowColor",
	"shadowXOffset", "shadowYOffset",
}

local TOP_LEVEL_DROPS = {
	"information", "semver", "skipWagoUpdate", "ignoreWagoUpdate",
	"preferToUpdate", "wagoID", "tocversion",
}

local ANIMATION_CODE_KEYS = {
	"translateFunc", "alphaFunc", "scaleFunc", "rotateFunc", "colorFunc",
}

local ACTION_CODE_KEYS = {
	"custom", "customOnLoad", "customOnUnload", "message_custom",
}

local TRIGGER_CODE_KEYS = {
	{ key = "custom", label = "custom" },
	{ key = "customDuration", label = "duration" },
	{ key = "customName", label = "name" },
	{ key = "customIcon", label = "icon" },
	{ key = "customTexture", label = "texture" },
	{ key = "customStacks", label = "stacks" },
	{ key = "customVariables", label = "variables" },
	{ key = "customOverlay1", label = "overlay1" },
	{ key = "customOverlay2", label = "overlay2" },
	{ key = "customOverlay3", label = "overlay3" },
}

local DISPLAY_CODE_KEYS = {
	{ key = "customText", label = "custom text" },
	{ key = "customSort", label = "custom sort" },
	{ key = "customAnchorPerUnit", label = "custom anchor" },
}

-- Group fields carried beyond the region defaults. controlledChildren is
-- deliberately not among them and never copied: the child list is rebuilt from
-- the payload's own tree, whose ids are all reassigned on install.
local GROUP_KEYS = {
	"customSort", "hybridPosition", "hybridSortMode", "sortHybridTable",
}

local GROW_TYPES = {
	UP = true, DOWN = true, LEFT = true, RIGHT = true,
	HORIZONTAL = true, VERTICAL = true, GRID = true,
}

-- Group fields with no local counterpart at all, each changing how the group
-- behaves rather than how one aura is decorated, so each is reported.
local GROUP_DROP_KEYS = { "animate", "sortOn", "anchorOn", "growOn" }

-- A group's border here is one fixed edge; upstream picks an edge file, a
-- backdrop and three insets. Reported only when the border is actually on --
-- every export carries the block whether or not it is drawn.
local GROUP_BORDER_ART_KEYS = {
	"borderEdge", "borderOffset", "borderInset", "borderSize",
	"borderBackdrop", "backdropColor", "background", "backgroundInset",
}

local ACTION_SPECS = {
	init = {
		{ key = "custom", enabled = "do_custom", body = true },
		{ key = "customOnLoad", enabled = "do_custom_load", body = true },
		{ key = "customOnUnload", enabled = "do_custom_unload", body = true },
	},
	start = {
		{ key = "custom", enabled = "do_custom", body = true },
		{ key = "message_custom", enabled = "do_message", body = false },
	},
	finish = {
		{ key = "custom", enabled = "do_custom", body = true },
		{ key = "message_custom", enabled = "do_message", body = false },
	},
}

local ACTION_DROP_KEYS = {
	"sound_channel", "stop_sound", "stop_sound_fade", "do_sound_fade", "message_channel",
}

-- The glow targets Actions.lua can resolve. Upstream reaches its unit frames
-- through LibGetFrame; ours resolve the same two off the region's stored unit.
local GLOW_FRAME_TYPES = {
	PARENTFRAME = true, FRAMESELECTOR = true, UNITFRAME = true, NAMEPLATE = true,
}

local AURA_TRIGGER_KEYS = {
	"unit", "specificUnit", "debuffType", "useName", "auranames", "matchesShowOn",
	"ownOnly", "useStacks", "stacksOperator", "stacks", "useRem", "remOperator", "rem",
	"useTotal", "totalOperator", "total", "use_debuffClass", "debuffClass",
}

-- Upstream's name-pattern operators, and the closest thing this addon's aura
-- trigger has. Ours is a plain substring test (TriggerAura's `string.find` with
-- plain = true) inverted by "nomatch", so only `find('%s')` translates exactly;
-- the other two are approximations and say so.
local AURA_NAME_PATTERN_OPERATORS = {
	["find('%s')"] = { op = "match" },
	["=="] = { op = "match", note = "exact name match becomes a substring match" },
	["match('%s')"] = { op = "match", note = "Lua pattern match becomes a substring match" },
}

local CUSTOM_TRIGGER_KEYS = {
	"custom_type", "check", "events", "custom", "custom_hide", "duration",
	"customDuration", "customName", "customIcon", "customVariables",
}

local CUSTOM_UNSUPPORTED_KEYS = {
	"customTexture", "customStacks", "customOverlay1", "customOverlay2", "customOverlay3",
}

local AURA_CLONE_KEYS = {
	"combineMode", "combinePerUnit", "showClones", "perUnitMode", "useMatch_count",
	"match_count", "match_countOperator", "useMatchPerUnit_count", "matchPerUnit_count",
	"matchPerUnit_countOperator",
}

local CUSTOM_TYPES = { status = true, event = true, stateupdate = true }

-- Generic-trigger condition variables upstream spells differently, theirs ->
-- ours, per prototype -- so the `name` a dozen prototypes share on both sides is
-- only redirected where it really differs. The trigger fields these belong to
-- are mapped by GENERIC_ARG_NAMES, which is the same divergence seen from the
-- editor's side rather than a second one.
local GENERIC_VARIABLE_NAMES = {
	health = { deficit = "healthDeficit" },
	power = { deficit = "powerDeficit" },
	-- A combo aura's conditions were written against upstream's Power trigger,
	-- so they name its `power` variable rather than ours.
	combopoints = { power = "comboPoints" },
	charstats = { attackpower = "attackPower" },
	experience = { currentXP = "xp", totalXP = "xpMax", percentXP = "xpPercent" },
	rangecheck = { range = "distance" },
	unitcharacteristics = { name = "unitName" },
}

local SUBTEXT_KEYS = {
	"text_text", "text_color", "text_fontSize", "text_font", "text_fontType",
	"text_visible", "text_justify", "text_justifyV", "text_spacing",
	"text_shadowColor", "text_shadowXOffset", "text_shadowYOffset",
	"anchor_point", "anchorXOffset", "anchorYOffset",
}

local SUBTEXT_DROP_KEYS = {
	"rotateText", "text_automaticWidth", "text_fixedWidth", "text_wordWrap",
}

local SUBBORDER_KEYS = {
	"border_visible", "border_color", "border_size", "border_offset", "anchor_mode", "anchor_area",
}

local SUBGLOW_KEYS = {
	"glow", "useGlowColor", "glowColor", "glowType", "glowLines", "glowFrequency",
	"glowLength", "glowThickness", "glowScale", "glowBorder", "glowXOffset",
	"glowYOffset", "anchor_mode", "anchor_area",
}

local SUBTICK_KEYS = {
	"tick_visible", "tick_color", "tick_placement_mode", "automatic_length",
	"tick_thickness", "tick_length", "use_texture", "tick_texture", "tick_blend_mode",
	"tick_desaturate", "tick_rotation", "tick_xOffset", "tick_yOffset", "tick_mirror",
	"tick_placements",
}

local SUBREGION_TYPES = {
	subtext = true, subborder = true, subglow = true, subtick = true,
}

local DROPPED_FORMATS = { Unit = true, GUID = true, GCDTime = true }

local function hasSource(value)
	return type(value) == "string" and string.find(value, "%S") ~= nil
end

local function reportDrop(report, reason, detail)
	table.insert(report.dropped, { reason = reason, detail = detail })
end

-- ---------------------------------------------------------------------------
-- Media paths
--
-- An export carries absolute paths into the *sender's* WeakAuras install
-- (`Interface\Addons\WeakAuras\PowerAurasMedia\Auras\Aura22`), and this client
-- has never had that addon, so the file is not there and the region paints the
-- engine's missing-texture block. The same art and sounds are bundled here, so
-- the path is rewritten onto our copy.
--
-- Three properties of the incoming string are load-bearing, all of them observed
-- in the wago corpus:
--
-- * **Case varies.** Upstream writes both `Addons` and `AddOns`, so every
--   comparison happens on a lowercased copy.
-- * **The extension is optional.** `...\Square_FullWhite` and
--   `...\Ring_10px.tga` are both real exported values for the same kind of
--   field, so a lookup that misses tries again without the extension.
-- * **Either separator can appear.** Normalised to `\` before matching.
--
-- The destination is looked up in the catalogues the pickers are built from
-- rather than computed from the source name. Rewriting onto a file we do not
-- ship would replace a dead path the report can name with one that looks live
-- and still draws nothing.
-- ---------------------------------------------------------------------------

local MEDIA_ROOTS = {
	{ prefix = "interface\\addons\\weakauras\\media\\textures\\", kind = "texture" },
	{ prefix = "interface\\addons\\weakauras\\poweraurasmedia\\auras\\", kind = "texture" },
	{ prefix = "interface\\addons\\weakauras\\media\\sounds\\", kind = "sound" },
	{ prefix = "interface\\addons\\weakauras\\poweraurasmedia\\sounds\\", kind = "sound" },
	{ prefix = "interface\\addons\\weakauras\\media\\fonts\\", kind = "font" },
}

-- The bundled statusbars dropped upstream's Statusbar_ prefix to match the bare
-- names this addon's bar picker stores, so they are the one set whose incoming
-- name does not find itself in WA.textureTypes.
local BAR_TEXTURE_RENAMES = {
	Statusbar_Clean = "Clean", Statusbar_Stripes = "Stripes",
	Statusbar_Stripes_Thick = "ThickStripes", Statusbar_Stripes_Thin = "ThinStripes",
}

local mediaIndex

-- Files a texture path may omit the extension of, so both spellings resolve.
local function addMedia(index, path)
	local _, _, file = string.find(path, "([^\\]+)$")
	if not file then return end
	local lower = string.lower(file)
	index[lower] = path
	local _, _, stem = string.find(lower, "^(.+)%.[^.]*$")
	if stem and index[stem] == nil then index[stem] = path end
end

local function buildMediaIndex()
	local index = { texture = {}, sound = {}, font = {} }
	for category, list in pairs(WA.textureTypes or {}) do
		for i = 1, table.getn(list) do
			addMedia(index.texture, WA.Widgets.TexturePath(category, list[i]))
		end
	end
	for name, bar in pairs(BAR_TEXTURE_RENAMES) do
		addMedia(index.texture, WA.Widgets.BarTexturePath(bar))
		-- BarTexturePath returns an extensionless path, so addMedia's own stem
		-- pass never fires and the upstream spelling has to be keyed by hand.
		index.texture[string.lower(name)] = WA.Widgets.BarTexturePath(bar)
	end
	for path in pairs(WA.bundled_sound_types or {}) do addMedia(index.sound, path) end
	local fonts = WA.textCore and WA.textCore.FONTS or {}
	for i = 1, table.getn(fonts) do addMedia(index.font, fonts[i].path) end
	return index
end

-- The bundled path for a WeakAuras2 media path, or nil for anything else --
-- a path into a third-party addon, or into a WeakAuras folder whose file this
-- addon does not carry. Both stay as they are and are reported.
local function rewriteMedia(value)
	if type(value) ~= "string" or value == "" then return nil end
	local normalized = string.gsub(value, "/", "\\")
	local lower = string.lower(normalized)
	for i = 1, table.getn(MEDIA_ROOTS) do
		local root = MEDIA_ROOTS[i]
		if string.sub(lower, 1, string.len(root.prefix)) == root.prefix then
			mediaIndex = mediaIndex or buildMediaIndex()
			local file = string.sub(lower, string.len(root.prefix) + 1)
			local index = mediaIndex[root.kind]
			local hit = index[file]
			if not hit then
				local _, _, stem = string.find(file, "^(.+)%.[^.]*$")
				hit = stem and index[stem]
			end
			return hit
		end
	end
	return nil
end

-- Fields whose value is a media path, wherever they sit. Walked recursively over
-- the finished display rather than rewritten at each translation site, so an
-- action, a condition's change value, a sub-region and a user-config default are
-- all covered by one pass and none can be forgotten when a new one is added.
--
-- `sound` also names a *condition property*, but that is a `property` key rather
-- than a `sound` one, and the paths it points at live in the change's `value`
-- table -- which this walk reaches anyway.
local MEDIA_KEYS = {
	displayIcon = "texture", groupIcon = "texture", texture = "texture",
	foregroundTexture = "texture", backgroundTexture = "texture",
	sparkTexture = "texture", tick_texture = "texture",
	sound = "sound", sound_path = "sound",
	text_font = "font", font = "font",
}

local function remapMedia(node, report, label, seen)
	if type(node) ~= "table" then return end
	seen = seen or {}
	if seen[node] then return end
	seen[node] = true
	for key, value in pairs(node) do
		if type(value) == "table" then
			remapMedia(value, report, label, seen)
		elseif MEDIA_KEYS[key] then
			local rewritten = rewriteMedia(value)
			if rewritten and rewritten ~= value then
				node[key] = rewritten
				reportDrop(report, "WeakAuras media path rewritten",
					label .. " " .. key .. ": " .. value .. " -> " .. rewritten)
			end
		end
	end
end

local function take(dst, src, keys)
	if type(src) ~= "table" then return end
	for i = 1, table.getn(keys) do
		local key = keys[i]
		if src[key] ~= nil then dst[key] = WA.DeepCopy(src[key]) end
	end
end

local function copyBlock(dst, src, key)
	if src[key] ~= nil then dst[key] = WA.DeepCopy(src[key]) end
end

-- The unit tokens a trigger may name here: the single ones the Unit dropdown
-- offers, plus its `specific` escape hatch. Upstream's group/party/raid/nameplate
-- families are refused rather than collapsed onto one unit -- only three
-- prototypes fan a family out, and importing a raid-wide aura as a single-unit
-- one is the failure that looks right and behaves wrong.
local function isSupportedUnit(unit)
	if unit == nil then return true end
	for i = 1, table.getn(WA.unit_tokens or {}) do
		if WA.unit_tokens[i] == unit then return true end
	end
	return false
end

local function lua50SourceError(source)
	if string.find(source, "#%s*[%a_]") then return "length operator" end
	if string.find(source, "%.%.%.") then return "vararg syntax" end
	return nil
end

local function validateTriggerCode(source, detail, report, tableExpression)
	if not hasSource(source) then return true end
	local valid = not lua50SourceError(source)
	if valid and type(WA.LoadFunction) == "function" then
		local candidate = source
		if tableExpression then
			candidate = "function() return \n" .. source .. "\n end"
		end
		valid = WA.LoadFunction(candidate, nil) ~= nil
	end
	if not valid then
		reportDrop(report, "custom code", detail)
		return false
	end
	return true
end

local function validateConditionCode(source, detail, report, body)
	if not hasSource(source) then return false end
	local valid = not lua50SourceError(source)
	if valid and type(WA.LoadFunction) == "function" then
		valid = WA.LoadFunction(source, nil, body) ~= nil
	end
	if not valid then
		reportDrop(report, "custom code", detail)
		return false
	end
	return true
end

local function conditionLabel(data, index)
	return tostring(data.id or "?") .. " condition " .. index
end

local function conditionTemplate(templates, trigger, variable)
	if trigger == -1 then return WA.globalConditions and WA.globalConditions[variable] end
	if type(trigger) ~= "number" or trigger < 1 then return nil end
	return templates[trigger] and templates[trigger][variable]
end

local function translateConditionCheck(source, templates, report, label, types)
	if type(source) ~= "table" then return nil, "missing check" end
	local trigger = source.trigger
	if trigger == -2 then
		if source.variable ~= "AND" and source.variable ~= "OR" then
			return nil, "unknown combinator " .. tostring(source.variable)
		end
		if type(source.checks) ~= "table" then return nil, "combinator has no checks" end
		local checks = {}
		for i = 1, table.getn(source.checks) do
			local child, detail = translateConditionCheck(source.checks[i], templates, report,
				label .. " check " .. i, types)
			if child then
				table.insert(checks, child)
			else
				reportDrop(report, "condition check", label .. " check " .. i .. ": " .. tostring(detail))
			end
		end
		if table.getn(checks) == 0 then return nil, "all combinator checks are invalid" end
		return { trigger = -2, variable = source.variable, checks = checks }
	end
	local variable = source.variable
	local renames = types and types[trigger] and GENERIC_VARIABLE_NAMES[types[trigger]]
	if renames and renames[variable] then variable = renames[variable] end
	local template = conditionTemplate(templates, trigger, variable)
	if not template then
		return nil, "unknown variable " .. tostring(source.variable) .. " for trigger " .. tostring(trigger)
	end
	local check = { trigger = WA.DeepCopy(trigger), variable = WA.DeepCopy(variable) }
	if source.op ~= nil then check.op = WA.DeepCopy(source.op) end
	if source.value ~= nil then check.value = WA.DeepCopy(source.value) end
	return check
end

local function conditionCodeValue(value)
	if type(value) == "table" and type(value.custom) == "string" then return value.custom end
	if type(value) == "string" then return value end
	return nil
end

local function translateConditionChanges(source, properties, report, label)
	if type(source) ~= "table" then return nil, "missing changes" end
	local changes = {}
	for i = 1, table.getn(source) do
		local change = source[i]
		if type(change) ~= "table" or properties[change.property] == nil then
			return nil, "unknown property " .. tostring(type(change) == "table" and change.property or nil)
		end
		local property = change.property
		local value = WA.DeepCopy(change.value)
		-- A property row the author added and never filled in. Upstream's code
		-- generator skips it; ours would hand the nil straight to the property
		-- setter, and a setter doing arithmetic on it takes the aura down.
		if change.value == nil then
			reportDrop(report, "condition change", label .. " " .. tostring(property) .. ": no value set")
		elseif property == "customcode" then
			local code = conditionCodeValue(value)
			if code and validateConditionCode(code, label .. " " .. property, report, true) then
				table.insert(changes, { property = WA.DeepCopy(property), value = value })
			elseif not code then
				reportDrop(report, "custom code", label .. " " .. property)
			end
		else
			table.insert(changes, { property = WA.DeepCopy(property), value = value })
		end
	end
	return changes
end

local function translateConditions(source, data, report)
	if type(source) ~= "table" then
		reportDrop(report, "condition", conditionLabel(data, 1) .. ": invalid conditions")
		return {}
	end
	data.triggers = data.triggers or {}
	local templates = WA.GetConditionTemplates(data)
	local properties = WA.GetProperties(data)
	local types = {}
	for i = 1, table.getn(data.triggers) do
		local entry = data.triggers[i]
		types[i] = entry and entry.trigger and entry.trigger.type
	end
	local conditions = {}
	for i = 1, table.getn(source) do
		local label = conditionLabel(data, i)
		local item = source[i]
		local check, checkDetail = translateConditionCheck(item and item.check, templates, report, label, types)
		local changes, changeDetail
		if check then changes, changeDetail = translateConditionChanges(item and item.changes, properties, report, label) end
		if check and changes then
			table.insert(conditions, { check = check, changes = changes })
		else
			reportDrop(report, "condition", label .. ": " .. tostring(checkDetail or changeDetail))
		end
	end
	return conditions
end

local function loadLabel(data, field)
	return tostring(data.id or "?") .. ": " .. field
end

local function loadValuePresent(value)
	if value == nil or value == false then return false end
	if type(value) == "string" then return value ~= "" end
	if type(value) == "table" then
		for _, child in pairs(value) do
			if loadValuePresent(child) then return true end
		end
		return false
	end
	return true
end

local function selectedLoadValues(block)
	local values = {}
	if type(block) ~= "table" or type(block.multi) ~= "table" then return values end
	for key, selected in pairs(block.multi) do
		if selected then table.insert(values, key) end
	end
	return values
end

local function translateLoadMultiselect(source, destination, field, report, data)
	local use = source["use_" .. field]
	local block = source[field]
	if use == nil or not loadValuePresent(block) then return end
	local selected = selectedLoadValues(block)
	if use == true then
		if type(block) == "table" and block.single ~= nil then
			destination["use_" .. field] = field == "class" and "single" or true
			destination[field] = WA.DeepCopy(block.single)
			return
		end
		if table.getn(selected) == 1 then
			destination["use_" .. field] = field == "class" and "single" or true
			destination[field] = WA.DeepCopy(selected[1])
			return
		end
	else
		if table.getn(selected) == 1 and field ~= "class" then
			destination["use_" .. field] = true
			destination[field] = WA.DeepCopy(selected[1])
			return
		end
		if field == "class" and table.getn(selected) > 0 then
			destination.use_class = "multi"
			destination.classes = {}
			for i = 1, table.getn(selected) do destination.classes[selected[i]] = true end
			return
		end
	end
	reportDrop(report, "load constraint", loadLabel(data, field) .. " has an unsupported multi-select")
end

local function translateLoad(source, data, report)
	if type(source) ~= "table" then return {} end
	local destination = {}
	if source.never or source.use_never then destination.never = true end
	for _, field in ipairs({ "class", "race", "faction", "ingroup" }) do
		translateLoadMultiselect(source, destination, field, report, data)
	end
	local tristates = {
		combat = { trueValue = "incombat", falseValue = "outofcombat" },
		alive = { trueValue = "alive", falseValue = "dead" },
		mounted = { trueValue = "mounted", falseValue = "notmounted" },
		vehicle = { trueValue = "ontaxi", falseValue = "nottaxi" },
	}
	for field, values in pairs(tristates) do
		if source["use_" .. field] and source[field] ~= nil then
			destination["use_" .. field] = true
			destination[field] = source[field] and values.trueValue or values.falseValue
		end
	end
	local simple = { "level", "zone", "stance", "player", "realm", "guild" }
	for i = 1, table.getn(simple) do
		local field = simple[i]
		if source["use_" .. field] and source[field] ~= nil then
			destination["use_" .. field] = true
			destination[field] = WA.DeepCopy(source[field])
			if source[field .. "_operator"] ~= nil then
				destination[field .. "_operator"] = WA.DeepCopy(source[field .. "_operator"])
			end
		end
	end
	if source.use_groupSize and source.groupSize ~= nil then
		destination.use_size = true
		destination.size = WA.DeepCopy(source.groupSize)
		destination.size_operator = WA.DeepCopy(source.groupSize_operator or source.groupSizeOperator or ">=")
	end
	for _, field in ipairs({ "spellknown", "not_spellknown", "itemequiped", "not_itemequiped" }) do
		if source["use_" .. field] and loadValuePresent(source[field]) then
			destination["use_" .. field] = true
			destination[field] = WA.DeepCopy(source[field])
		end
	end
	local consumed = {
		never = true, use_never = true, class = true, race = true, faction = true, ingroup = true,
		combat = true, alive = true, mounted = true, vehicle = true, level = true, zone = true,
		stance = true, player = true, realm = true, guild = true, groupSize = true,
		groupSize_operator = true, groupSizeOperator = true, spellknown = true, not_spellknown = true,
		itemequiped = true, not_itemequiped = true,
	}
	consumed.use_zoneIds = true
	for _, field in ipairs(simple) do consumed[field .. "_operator"] = true end
	for _, field in ipairs({ "combat", "alive", "mounted", "vehicle", "class", "race", "faction", "ingroup", "level", "zone", "stance", "player", "realm", "guild", "groupSize", "spellknown", "not_spellknown", "itemequiped", "not_itemequiped" }) do
		consumed["use_" .. field] = true
	end
	consumed.use_groupSize = true
	for key, value in pairs(source) do
		if not consumed[key] and type(key) == "string" and string.sub(key, 1, 4) == "use_"
			and value and loadValuePresent(source[string.sub(key, 5)]) then
			reportDrop(report, "load constraint", loadLabel(data, string.sub(key, 5)))
		end
	end
	if source.use_zoneIds and loadValuePresent(source.zoneIds) then
		reportDrop(report, "load constraint", loadLabel(data, "zoneIds"))
	end
	return destination
end

local function reportStateCompatibility(trigger, triggernum, report)
	local events = trigger.events
	if type(events) == "string"
		and (string.find(events, "CLEU:", 1, true)
			or string.find(events, "COMBAT_LOG_EVENT_UNFILTERED:", 1, true)) then
		reportDrop(report, "unsupported custom event syntax", "trigger " .. triggernum .. ": CLEU")
	end
	if trigger.custom_type ~= "stateupdate" then return end
	local code = tostring(trigger.custom or "") .. "\n" .. tostring(trigger.customVariables or "")
	if string.find(code, "additionalProgress", 1, true) then
		reportDrop(report, "unsupported custom state", "trigger " .. triggernum .. ": additionalProgress")
	end
	if string.find(code, "tooltip", 1, true) then
		reportDrop(report, "unsupported custom state", "trigger " .. triggernum .. ": state.tooltip")
	end
	if string.find(code, "modRate", 1, true) or string.find(code, "useModRate", 1, true) then
		reportDrop(report, "unsupported custom state", "trigger " .. triggernum .. ": modRate")
	end
end

-- Upstream keeps names and spell ids in two lists; ours keeps one, whose entries
-- are read as an id when they parse as a number (TriggerAura's buildEntries). So
-- the spell ids append to the name list rather than needing a second field.
local function translateAuraSpellIds(trigger, source)
	local ids = source.auraspellids
	if type(ids) ~= "table" or table.getn(ids) == 0 then return end
	trigger.auranames = trigger.auranames or {}
	for i = 1, table.getn(ids) do
		local id = tonumber(ids[i])
		if id then table.insert(trigger.auranames, tostring(id)) end
	end
	if table.getn(trigger.auranames) > 0 then trigger.useName = true end
end

-- namePattern_name/_operator upstream, namePattern/namePatternOperator here.
-- Carrying useNamePattern without the pattern is the worst of the three
-- outcomes: the runtime skips an empty pattern, so the aura silently stops
-- filtering by name at all.
local function translateAuraNamePattern(trigger, source, triggernum, report)
	if not source.useNamePattern then return end
	local pattern = source.namePattern_name
	if type(pattern) ~= "string" or pattern == "" then
		reportDrop(report, "aura name pattern", "trigger " .. triggernum .. ": no pattern text")
		return
	end
	local mapped = AURA_NAME_PATTERN_OPERATORS[source.namePattern_operator or "find('%s')"]
	if not mapped then
		reportDrop(report, "aura name pattern",
			"trigger " .. triggernum .. ": unsupported operator " .. tostring(source.namePattern_operator))
		return
	end
	trigger.useNamePattern = true
	trigger.namePattern = WA.DeepCopy(pattern)
	trigger.namePatternOperator = mapped.op
	if mapped.note then
		reportDrop(report, "aura name pattern", "trigger " .. triggernum .. ": " .. mapped.note)
	end
end

local function translateAuraTrigger(source, triggernum, report)
	if not isSupportedUnit(source.unit) then
		report.refused = "trigger " .. triggernum .. " uses unsupported unit " .. tostring(source.unit)
		return nil
	end
	for i = 1, table.getn(AURA_CLONE_KEYS) do
		local key = AURA_CLONE_KEYS[i]
		if source[key] ~= nil and (key == "combineMode" or source[key]) then
			report.refused = "trigger " .. triggernum .. " uses clone-dependent aura setting " .. key
			return nil
		end
	end
	local trigger = {}
	take(trigger, source, AURA_TRIGGER_KEYS)
	trigger.type = "aura"
	translateAuraSpellIds(trigger, source)
	translateAuraNamePattern(trigger, source, triggernum, report)
	-- A trigger with the name filters off and nothing to match on never shows
	-- (TriggerAura's buildTriggerInfo skips it), which looks like an aura that
	-- imported fine and is simply broken. Naming it is the whole difference.
	if not trigger.useName and not trigger.useNamePattern then
		reportDrop(report, "aura trigger matches nothing",
			"trigger " .. triggernum .. ": no name or spell id survived translation")
	end
	return trigger
end

local function translateCustomTrigger(source, entry, triggernum, report)
	if source.custom_type ~= nil and not CUSTOM_TYPES[source.custom_type] then
		report.refused = "trigger " .. triggernum .. " uses unsupported custom type " .. tostring(source.custom_type)
		return nil
	end
	local trigger = {}
	take(trigger, source, CUSTOM_TRIGGER_KEYS)
	trigger.type = "custom"
	for i = 1, table.getn(CUSTOM_UNSUPPORTED_KEYS) do
		local key = CUSTOM_UNSUPPORTED_KEYS[i]
		if source[key] ~= nil then
			reportDrop(report, "unsupported custom field", "trigger " .. triggernum .. ": " .. key)
		end
	end

	local codeFields = {
		{ key = "custom", detail = "custom", tableExpression = false },
		{ key = "customDuration", detail = "duration", tableExpression = false },
		{ key = "customName", detail = "name", tableExpression = false },
		{ key = "customIcon", detail = "icon", tableExpression = false },
		{ key = "customVariables", detail = "variables", tableExpression = true },
	}
	for i = 1, table.getn(codeFields) do
		local field = codeFields[i]
		if trigger[field.key] ~= nil and not validateTriggerCode(trigger[field.key],
			"trigger " .. triggernum .. " " .. field.detail, report, field.tableExpression) then
			trigger[field.key] = nil
		end
	end
	local untrigger = entry and entry.untrigger
	if type(untrigger) == "table" and untrigger.custom ~= nil then
		if validateTriggerCode(untrigger.custom, "trigger " .. triggernum .. " uncustom", report, false) then
			untrigger = { custom = WA.DeepCopy(untrigger.custom) }
		else
			untrigger = {}
		end
	else
		untrigger = {}
	end
	reportStateCompatibility(source, triggernum, report)
	return trigger, untrigger
end

-- The local prototype behind an upstream `trigger.event` key, answered from the
-- prototypes' own `wa2Event` declarations rather than from a list written out
-- here: a prototype that declares one becomes importable with no edit, and one
-- that declares none (`combatevents`, whose name collides with upstream's Combat
-- Log without sharing its source) stays refused.
-- Walked per lookup rather than cached: the trigger types register after this
-- file's chunk runs, and a cache built on the first import would not see a type
-- registered after it -- which is the property this derivation exists for.
local function genericPrototypeFor(event)
	if type(event) ~= "string" then return nil end
	for key, spec in pairs(WA.triggerTypes or {}) do
		if spec.wa2Event == event then return key end
	end
	return nil
end

-- Upstream arg names the local prototype spells differently, ours -> theirs.
-- Every one of these is a stored condition variable here, so aligning the name
-- would have to walk each saved condition and each text placeholder that names
-- it; the mapping costs a line and loses nothing, since GENERIC_VARIABLE_NAMES
-- renames an imported condition's variable through the same knowledge.
local GENERIC_ARG_NAMES = {
	health = { healthDeficit = "deficit" },
	power = { powerDeficit = "deficit" },
	charstats = { attackPower = "attackpower" },
	experience = { xp = "currentXP", xpPercent = "percentXP" },
	rangecheck = { distance = "range" },
	unitcharacteristics = { unitName = "namerealm" },
	-- A combo trigger arrives as a Power trigger (see COMBO_POINT_POWER_TYPE),
	-- so its threshold is upstream's `power` and its operator `power_operator`.
	combopoints = { comboPoints = "power" },
}

-- WeakAuras2 has no combo-point trigger. On every client it builds against,
-- combo points *are* a power type -- `Enum.PowerType.ComboPoints` is 4 -- so a
-- combo aura exports as a Power trigger with `powertype = 4`, which is what the
-- whole ComboFill / ring-accent family on wago is made of.
--
-- Index 4 on this client is `Happiness`, vanilla pet happiness (ClassicAPI's
-- Enum.PowerType is 1.12's, not modern's), and combo points are not a power type
-- here at all -- `GetComboPoints` is the only source. Translating the number
-- literally yields a trigger testing `UnitPowerType(unit) == 4`, which can never
-- be true for a player, so every such display imports silently invisible.
--
-- Upstream's own non-retail branch special-cases the same number to
-- `GetComboPoints(unit, unit .. '-target')`, which is exactly what
-- PROTOTYPES["combopoints"] does, so the trigger is re-pointed at that
-- prototype. It stays a redirect rather than a second `wa2Event = "Power"`
-- declaration because genericPrototypeFor returns the first match out of a
-- `pairs` walk -- two prototypes claiming one event would resolve at random.
local COMBO_POINT_POWER_TYPE = 4

-- Power types this client has a bar for. Upstream offers every expansion's,
-- and one we have no equivalent of decides what the trigger matches, so it is
-- refused rather than imported as some other resource.
local SUPPORTED_POWER_TYPES = { [0] = true, [1] = true, [2] = true, [3] = true }

-- A select arrives either bare or in upstream's { single = } / { multi = }
-- wrapper; powertype has to be read before the walker unwraps it.
local function selectNumber(value)
	if type(value) == "table" then
		if value.single ~= nil then return tonumber(value.single) end
		for key, selected in pairs(value.multi or {}) do
			if selected then return tonumber(key) end
		end
		return nil
	end
	return tonumber(value)
end

-- Upstream trigger settings with no local counterpart. `refuse` names one that
-- decides or inverts what the trigger matches, where importing without it would
-- claim the aura does something it does not; `drop` names one that only widens
-- the match, which is reported the way a dropped load constraint is. A function
-- decides from the value, for a setting whose default is harmless.
local GENERIC_UNSUPPORTED = {
	cast = { spell = "refuse", spellNames = "refuse", spellId = "refuse",
		castType = "drop", interruptible = "drop", sourceUnit = "drop", destUnit = "drop" },
	castsucceeded = { spellNames = "refuse", spellId = "refuse" },
	crowdcontrol = { controlType = "drop", interruptSchool = "drop", spellName = "drop" },
	equipslotcooldown = { testForCooldown = "drop" },
	itemequipped = { itemSlot = "drop" },
	itemset = { equipped = "drop" },
	itemtypeequipped = { itemTypeName = "refuse" },
	location = { zoneIds = "drop", instanceId = "drop", instanceSize = "drop",
		instanceDifficulty = "drop" },
	power = { requirePowerType = "drop", showCost = "drop",
		powertype = function(value)
			local index = selectNumber(value)
			if index == nil or SUPPORTED_POWER_TYPES[index] then return nil end
			-- 4 never reaches here: it is redirected to combopoints first.
			return "refuse"
		end },
	-- The combo route inherits upstream's Power settings, and the resource-shaped
	-- ones have no counterpart on a count out of five.
	combopoints = { requirePowerType = "drop", showCost = "drop",
		percentpower = "drop", deficit = "drop" },
	reputation = { factionID = "refuse", watched = "refuse" },
	-- Upstream stores the shapeshift *bar position*; this client's trigger
	-- matches the form's DBC id (GetShapeshiftFormID), and the two numberings
	-- have nothing to do with each other. Nothing here can translate one into
	-- the other -- the bar's order is class- and spellbook-dependent -- so the
	-- filter is refused rather than imported as a different form.
	stance = { form = "refuse" },
	talentknown = { talent = "refuse", spec = "refuse" },
	totem = { totemName = "refuse", totemNamePattern = "refuse", clones = "refuse" },
	unitcharacteristics = { class = "drop", hostility = "drop", character = "drop",
		unitisunit = "drop", npcId = "drop", dead = "drop" },
	-- showOn travels on every Weapon Enchant export, its own default included;
	-- only the two modes that invert what the trigger shows are refused.
	weaponenchant = { enchant = "refuse", stacks = "drop",
		showOn = function(value)
			return (value ~= nil and value ~= "showOnActive") and "refuse" or nil
		end },
}

local GENERIC_CODE_DROPS = { "customDuration", "customName", "customIcon" }

-- Upstream's number filters travel as strings, and its comparison filters as
-- one-entry arrays once the user has ever opened the second bound.
local GENERIC_OPERATORS = {
	["=="] = "==", ["~="] = "~=", ["<"] = "<", ["<="] = "<=", [">"] = ">", [">="] = ">=",
	["find('%s')"] = "find",
}

-- Whether upstream's trigger actually applies a setting. `use_<key>` false is a
-- multiselect's "several values" mode rather than "off", so a value still present
-- under it counts as applied.
local function upstreamSetting(source, key)
	local use = source["use_" .. key]
	if use == false then
		return type(source[key]) == "table" and loadValuePresent(source[key])
	end
	if use ~= nil then return true end
	return loadValuePresent(source[key])
end

-- The keys a prototype's editor writes, from the defaults its own args build.
-- `use_<name>`, `<name>_operator` and the `<name>2` pair qualify a base key
-- rather than being keys in their own right, and are taken with it.
local function genericBaseKeys(defaults)
	local bases = {}
	for key in pairs(defaults) do
		local companion = string.sub(key, 1, 4) == "use_"
			or string.find(key, "_operator$") ~= nil
		if not companion then
			local _, _, stem = string.find(key, "^(.+)2$")
			companion = stem ~= nil and defaults[stem] ~= nil
		end
		if not companion then table.insert(bases, key) end
	end
	return bases
end

-- One value out of upstream's multiselect shape, or nil when it names several:
-- a select here holds one value and cannot express the set.
local function singleSelectValue(value, use)
	if use ~= false and value.single ~= nil then return value.single end
	local found
	for key, selected in pairs(value.multi or {}) do
		if selected then
			if found ~= nil then return nil end
			found = key
		end
	end
	if found == nil then return value.single end
	return found
end

local function translateGenericTrigger(source, triggernum, report)
	local protoKey = genericPrototypeFor(source.event)
	if not protoKey then
		report.refused = "trigger " .. triggernum .. " event " .. tostring(source.event) .. " is not supported"
		return nil
	end
	local label = "trigger " .. triggernum .. " " .. tostring(source.event)

	-- Power type 4 is combo points upstream and pet happiness here, so the
	-- trigger is re-pointed before anything reads the prototype it named.
	if protoKey == "power" and upstreamSetting(source, "powertype")
		and selectNumber(source.powertype) == COMBO_POINT_POWER_TYPE then
		-- GetComboPoints answers for the player's points on the player's target
		-- and nothing else, so a combo trigger watching another unit cannot be
		-- honoured -- and importing it as the player's would claim the aura
		-- watches something it does not.
		if source.unit ~= nil and source.unit ~= "player" then
			report.refused = label .. " reads combo points on " .. tostring(source.unit)
				.. ", which this client can only answer for the player"
			return nil
		end
		protoKey = "combopoints"
		reportDrop(report, "combo points imported as their own trigger",
			label .. ": power type 4 is combo points upstream and pet happiness here")
	end

	local defaults = (WA.triggerTypes[protoKey] or {}).defaults or {}

	-- An inverted match is never a widening: a prototype without its own inverse
	-- would show exactly when the author meant it to hide.
	if defaults.inverse == nil and source.use_inverse then
		report.refused = label .. " is inverted, which this trigger cannot express"
		return nil
	end
	-- Upstream offers these on every trigger; here they are compiled only for a
	-- custom one, so on a prototype they would be code nothing ever runs.
	for i = 1, table.getn(GENERIC_CODE_DROPS) do
		if hasSource(source[GENERIC_CODE_DROPS[i]]) then
			reportDrop(report, "unsupported trigger code", label .. ": " .. GENERIC_CODE_DROPS[i])
		end
	end
	local unsupported = GENERIC_UNSUPPORTED[protoKey] or {}
	for key, verdict in pairs(unsupported) do
		if upstreamSetting(source, key) then
			if type(verdict) == "function" then verdict = verdict(source[key]) end
			if verdict == "refuse" then
				report.refused = label .. " uses " .. key .. ", which has no counterpart here"
				return nil
			elseif verdict == "drop" then
				reportDrop(report, "unsupported trigger filter", label .. ": " .. key)
			end
		end
	end

	local names = GENERIC_ARG_NAMES[protoKey] or {}
	local trigger = { type = protoKey }
	local bases = genericBaseKeys(defaults)
	for i = 1, table.getn(bases) do
		local base = bases[i]
		local srcKey = names[base] or base
		local wantNumber = type(defaults[base]) == "number"
		local value, second = source[srcKey], nil
		local operator, operator2 = source[srcKey .. "_operator"], nil
		if type(value) == "table" and (value.single ~= nil or value.multi ~= nil) then
			value = singleSelectValue(value, source["use_" .. srcKey])
			if value == nil then
				reportDrop(report, "unsupported trigger filter",
					label .. ": " .. base .. " selects a set this trigger cannot express")
			end
		elseif type(value) == "table" then
			value, second = value[1], value[2]
		end
		if type(operator) == "table" then operator, operator2 = operator[1], operator[2] end
		if wantNumber then
			value, second = tonumber(value), tonumber(second)
		end

		if defaults["use_" .. base] ~= nil then
			local use = source["use_" .. srcKey]
			if use ~= nil then trigger["use_" .. base] = use and true or false end
			if value ~= nil then trigger[base] = WA.DeepCopy(value) end
			if operator ~= nil then
				local mapped = GENERIC_OPERATORS[operator]
				if mapped then
					trigger[base .. "_operator"] = mapped
				else
					trigger["use_" .. base] = false
					reportDrop(report, "unsupported trigger filter",
						label .. ": " .. base .. " " .. tostring(operator))
				end
			end
			if second ~= nil then
				if defaults[base .. "2"] ~= nil then
					trigger["use_" .. base .. "2"] = true
					trigger[base .. "2"] = WA.DeepCopy(second)
					if GENERIC_OPERATORS[operator2] then
						trigger[base .. "2_operator"] = GENERIC_OPERATORS[operator2]
					end
				else
					reportDrop(report, "unsupported trigger filter", label .. ": second " .. base .. " bound")
				end
			end
		elseif type(defaults[base]) == "boolean" then
			-- A plain flag: upstream keeps it under `use_<name>` and leaves the
			-- name itself for whatever the flag qualifies, where a toggle here is
			-- the bare key and nothing else.
			local flag = source["use_" .. srcKey]
			if flag == nil then flag = value end
			if flag ~= nil then trigger[base] = flag and true or false end
		elseif value ~= nil then
			trigger[base] = WA.DeepCopy(value)
		end
	end

	if defaults.unit ~= nil and not isSupportedUnit(trigger.unit) then
		report.refused = label .. " uses unsupported unit " .. tostring(trigger.unit)
		return nil
	end
	return trigger
end

local function translateTriggerEntry(entry, triggernum, report)
	if type(entry) ~= "table" or type(entry.trigger) ~= "table" then
		report.refused = "trigger " .. triggernum .. " has no trigger data"
		return nil
	end
	local source = entry.trigger
	local trigger, untrigger
	if source.type == "aura2" then
		trigger = translateAuraTrigger(source, triggernum, report)
	elseif source.type == "custom" then
		trigger, untrigger = translateCustomTrigger(source, entry, triggernum, report)
	elseif source.type == "aura" then
		report.refused = "trigger " .. triggernum .. " is a legacy aura trigger (type aura)"
		return nil
	else
		trigger = translateGenericTrigger(source, triggernum, report)
	end
	if not trigger then return nil end
	if not untrigger then
		untrigger = {}
		if type(entry.untrigger) == "table" and entry.untrigger.custom ~= nil then
			if validateTriggerCode(entry.untrigger.custom, "trigger " .. triggernum .. " uncustom", report, false) then
				untrigger.custom = WA.DeepCopy(entry.untrigger.custom)
			end
		end
	end
	return { trigger = trigger, untrigger = untrigger }
end

local function translateTriggers(source, report)
	if source.triggers == nil then return nil end
	if type(source.triggers) ~= "table" then
		report.refused = "display has invalid trigger data"
		return nil
	end
	local sourceTriggers = source.triggers
	local triggers = {}
	for i = 1, table.getn(sourceTriggers) do
		local entry = translateTriggerEntry(sourceTriggers[i], i, report)
		if not entry then return nil end
		triggers[i] = entry
	end
	if sourceTriggers.disjunctive == "all" or sourceTriggers.disjunctive == "any"
		or sourceTriggers.disjunctive == "custom" then
		triggers.disjunctive = sourceTriggers.disjunctive
	elseif sourceTriggers.disjunctive ~= nil then
		reportDrop(report, "unsupported trigger combination", tostring(sourceTriggers.disjunctive))
	end
	if sourceTriggers.activeTriggerMode ~= nil then
		triggers.activeTriggerMode = WA.DeepCopy(sourceTriggers.activeTriggerMode)
	end
	if sourceTriggers.customTriggerLogic ~= nil then
		if validateTriggerCode(sourceTriggers.customTriggerLogic, "trigger logic", report, false) then
			triggers.customTriggerLogic = WA.DeepCopy(sourceTriggers.customTriggerLogic)
		else
			triggers.customTriggerLogic = nil
		end
	end
	return triggers
end

local function subDetail(kind, index, detail)
	return kind .. " " .. index .. ": " .. detail
end

local function knownTextSymbol(data, symbol)
	local bare = symbol
	local _, _, scoped = string.find(symbol, "^%d+%.(.+)$")
	if scoped then bare = scoped end
	if WA.dynamic_texts and WA.dynamic_texts[bare] then return true end
	if string.find(bare, "^c%d*$") then return true end
	if type(WA.TextSymbols) == "function" then
		local names = WA.TextSymbols(data)
		for i = 1, table.getn(names or {}) do
			if names[i] == bare then return true end
		end
	end
	return false
end

local function scanTextPlaceholders(text, callback)
	if type(text) ~= "string" then return end
	local seen = {}
	local function visit(symbol)
		if symbol ~= "" and not seen[symbol] then
			seen[symbol] = true
			callback(symbol)
		end
	end
	local pos = 1
	while true do
		local start, finish, symbol = string.find(text, "%%([%w_%.]+)", pos)
		if not start then break end
		if start == 1 or string.sub(text, start - 1, start - 1) ~= "%" then
			visit(symbol)
		end
		pos = finish + 1
	end
	pos = 1
	while true do
		local start, finish, symbol = string.find(text, "%%{([^}]*)}", pos)
		if not start then break end
		visit(symbol)
		pos = finish + 1
	end
end

local function reportTextPlaceholders(text, data, index, report)
	scanTextPlaceholders(text, function(symbol)
		local _, _, bare = string.find(symbol, "^%d+%.(.+)$")
		bare = bare or symbol
		if bare == "i" then
			reportDrop(report, "known-blank text placeholder", subDetail("subtext", index, "%i"))
		elseif not knownTextSymbol(data, symbol) then
			reportDrop(report, "unsupported text placeholder", subDetail("subtext", index, "%" .. symbol))
		end
	end)
end

local function translateTextFormats(source, destination, data, index, report)
	scanTextPlaceholders(source.text_text, function(symbol)
		local prefix = "text_text_format_" .. symbol .. "_"
		local prefixLength = string.len(prefix)
		local hasSettings = false
		for key in pairs(source) do
			if type(key) == "string" and string.sub(key, 1, prefixLength) == prefix then
				hasSettings = true
			end
		end
		if hasSettings then
			local format = source[prefix .. "format"]
			if not format or DROPPED_FORMATS[format]
				or not (WA.format_types and WA.format_types[format]) then
				reportDrop(report, "unsupported text format",
					subDetail("subtext", index, "%" .. symbol .. " (" .. tostring(format) .. ")"))
			else
				for key, value in pairs(source) do
					if type(key) == "string" and string.sub(key, 1, prefixLength) == prefix then
						destination[key] = WA.DeepCopy(value)
					end
				end
			end
		end
	end)
end

local function translateFont(font)
	local default = WA.textCore and WA.textCore.DEFAULTS and WA.textCore.DEFAULTS.font
	default = default or "Fonts\\FRIZQT__.TTF"
	if type(font) ~= "string" then return nil, default end
	if font == "Friz Quadrata TT" then return default, default end
	-- A font travels as a LibSharedMedia name, but an author who typed a path
	-- into the box exports the path, and upstream's own faces are bundled here
	-- under a different folder.
	font = rewriteMedia(font) or font
	local fonts = WA.textCore and WA.textCore.FONTS or {}
	for i = 1, table.getn(fonts) do
		if fonts[i].path == font then return font, default end
		if fonts[i].name == font then return fonts[i].path, default end
	end
	return nil, default
end

local function subAnchorSupported(data, key)
	local values = WA.regionPrototype.GetSubRegionAnchors(data, "point")
	for i = 1, table.getn(values) do
		if values[i] == key then return true end
	end
	return false
end

-- Upstream keeps the anchored part and the point in a single value
-- ("OUTER_TOPLEFT", "ICON_LEFT", "SPARK"); ours splits them across anchor_target
-- and anchor_point, the latter being one of the nine SetPoint accepts. Whether a
-- part exists is asked of the destination region type, since a bar's ICON_* has
-- no icon to sit on once the display is an icon.
local function translateSubtextAnchor(destination, source, data, index, report)
	local anchor = destination.anchor_point
	if anchor == nil then anchor = source.text_anchorPoint end
	if type(anchor) ~= "string" or anchor == "AUTO" then
		if anchor ~= nil then
			reportDrop(report, "anchor substitution",
				subDetail("subtext", index, tostring(anchor) .. " -> CENTER"))
		end
		anchor = "CENTER"
	end

	local point = WA.regionPrototype.ResolveAnchorPoint(anchor, "CENTER")
	local target = anchor
	if not subAnchorSupported(data, target) then
		target = subAnchorSupported(data, point) and point or "region"
		if anchor ~= point then
			reportDrop(report, "anchor substitution",
				subDetail("subtext", index, anchor .. " -> " .. target))
		end
	end

	destination.anchor_target = target
	destination.anchor_point = point
	-- Upstream's own default is AUTO, resolved at paint time from the anchor;
	-- ours stores a real point, so an AUTO (or absent) self point is resolved here.
	if WA.regionPrototype.IsAnchorPoint(source.text_selfPoint) then
		destination.self_point = source.text_selfPoint
	else
		destination.self_point = WA.regionPrototype.AutoSelfPoint(anchor, point, data.regionType)
	end
end

local function translateSubtext(source, index, data, report)
	local destination = {}
	take(destination, source, SUBTEXT_KEYS)
	destination.type = "subtext"
	if destination.anchorXOffset == nil and source.text_anchorXOffset ~= nil then
		destination.anchorXOffset = WA.DeepCopy(source.text_anchorXOffset)
	end
	if destination.anchorYOffset == nil and source.text_anchorYOffset ~= nil then
		destination.anchorYOffset = WA.DeepCopy(source.text_anchorYOffset)
	end
	translateSubtextAnchor(destination, source, data, index, report)
	if source.text_font ~= nil then
		local font, default = translateFont(source.text_font)
		if font then
			destination.text_font = font
		else
			destination.text_font = default
			reportDrop(report, "unsupported font", subDetail("subtext", index, tostring(source.text_font)))
		end
	end
	for i = 1, table.getn(SUBTEXT_DROP_KEYS) do
		local key = SUBTEXT_DROP_KEYS[i]
		if source[key] ~= nil then
			reportDrop(report, "unsupported subtext field", subDetail("subtext", index, key))
		end
	end
	translateTextFormats(source, destination, data, index, report)
	reportTextPlaceholders(source.text_text, data, index, report)
	return destination
end

local function translateSubborder(source, index, report)
	local destination = {}
	take(destination, source, SUBBORDER_KEYS)
	destination.type = "subborder"
	if destination.anchor_area == nil and source.border_anchor ~= nil then
		destination.anchor_area = WA.DeepCopy(source.border_anchor)
	end
	if source.border_edge ~= nil then
		reportDrop(report, "unsupported border art", subDetail("subborder", index, "border_edge"))
	end
	return destination
end

local function translateSubglow(source, index, report)
	local destination = {}
	take(destination, source, SUBGLOW_KEYS)
	destination.type = "subglow"
	if source.glowDuration ~= nil then
		reportDrop(report, "unsupported glow field", subDetail("subglow", index, "glowDuration"))
	end
	if destination.glowType == "Proc" then
		destination.glowType = "Pixel"
		reportDrop(report, "glow type substitution", subDetail("subglow", index, "Proc -> Pixel"))
	elseif destination.glowType ~= nil
		and (not WA.glow_types or not WA.glow_types[destination.glowType]) then
		local original = destination.glowType
		destination.glowType = "Pixel"
		reportDrop(report, "glow type substitution",
			subDetail("subglow", index, tostring(original) .. " -> Pixel"))
	end
	return destination
end

local function translateSubtick(source, index, report)
	local destination = {}
	take(destination, source, SUBTICK_KEYS)
	destination.type = "subtick"
	if destination.tick_placements == nil and source.tick_placement ~= nil then
		destination.tick_placements = { WA.DeepCopy(source.tick_placement) }
	end
	if source.progressSources ~= nil then
		if type(source.progressSources) ~= "table" then
			reportDrop(report, "unsupported progress source", subDetail("subtick", index, "progressSources"))
		else
			local first = source.progressSources[1]
			if type(first) == "table" then
				if first[1] ~= nil then destination.tick_progressSource = WA.DeepCopy(first[1]) end
				if first[2] ~= nil and first[2] ~= "" then
					reportDrop(report, "per-property progress source",
						subDetail("subtick", index, tostring(first[2])))
				end
			elseif first ~= nil then
				reportDrop(report, "unsupported progress source", subDetail("subtick", index, "progressSources"))
			end
			if table.getn(source.progressSources) > 1 then
				reportDrop(report, "multiple progress sources", subDetail("subtick", index, "progressSources"))
			end
		end
	end
	return destination
end

local function translateSubRegion(source, index, parentType, data, report)
	if type(source) ~= "table" then
		reportDrop(report, "unsupported sub-region", subDetail("sub-region", index, "invalid data"))
		return nil
	end
	local kind = source.type
	if not SUBREGION_TYPES[kind] then
		reportDrop(report, "unsupported sub-region", subDetail("sub-region", index, tostring(kind)))
		return nil
	end
	local spec = WA.subRegionTypes and WA.subRegionTypes[kind]
	if spec and spec.supports and not spec.supports(parentType) then
		reportDrop(report, "unsupported sub-region", subDetail("sub-region", index, kind .. " on " .. parentType))
		return nil
	end
	if kind == "subtext" then return translateSubtext(source, index, data, report) end
	if kind == "subborder" then return translateSubborder(source, index, report) end
	if kind == "subglow" then return translateSubglow(source, index, report) end
	return translateSubtick(source, index, report)
end

local function translateSubRegions(source, data, report)
	if source.subRegions == nil then return nil end
	if type(source.subRegions) ~= "table" then
		reportDrop(report, "unsupported sub-regions", "invalid data")
		return {}
	end
	local destination = {}
	for i = 1, table.getn(source.subRegions) do
		local sub = translateSubRegion(source.subRegions[i], i, data.regionType, data, report)
		if sub then table.insert(destination, sub) end
	end
	return destination
end

local function keysFor(localType)
	local keys, seen = {}, {}
	-- Seeded taken, so the loop below cannot pick it up out of a group's
	-- defaults: it names children by id, and every id in an import is reassigned.
	seen.controlledChildren = true
	local function add(key)
		if not seen[key] then
			seen[key] = true
			table.insert(keys, key)
		end
	end
	local spec = WA.regionTypes[localType]
	for key in pairs(spec and spec.defaults or {}) do add(key) end
	if spec and spec.isGroup then
		for i = 1, table.getn(GROUP_KEYS) do add(GROUP_KEYS[i]) end
		return keys
	end
	for i = 1, table.getn(PROTOTYPE_KEYS) do add(PROTOTYPE_KEYS[i]) end
	if localType == "text" then
		for i = 1, table.getn(TEXT_KEYS) do add(TEXT_KEYS[i]) end
	end
	return keys
end

local function addCode(report, name, source, active)
	if not hasSource(source) then return end
	table.insert(report.code, { name = name, source = source, active = active and true or false })
end

function WA.CollectImportCode(data, report, prefix)
	if type(data) ~= "table" then return end
	report = report or { code = {} }
	report.code = report.code or {}
	prefix = prefix or (tostring(data.id or "?") .. " - ")

	for i = 1, table.getn(DISPLAY_CODE_KEYS) do
		local item = DISPLAY_CODE_KEYS[i]
		local active
		if item.key == "customSort" then
			active = data.sort == "custom"
		elseif item.key == "customAnchorPerUnit" then
			active = data.useAnchorPerUnit and true or false
		else
			active = true
		end
		addCode(report, prefix .. item.label, data[item.key], active)
	end

	local triggers = data.triggers
	for n = 1, table.getn(triggers or {}) do
		local entry = triggers[n]
		for _, slot in ipairs({ "trigger", "untrigger" }) do
			local block = entry and entry[slot]
			for i = 1, table.getn(TRIGGER_CODE_KEYS) do
				local item = TRIGGER_CODE_KEYS[i]
				local label, liveKey = item.label, item.key
				-- The untrigger block holds one field the compiler reads, under the
				-- name the predicate knows it by; anything else stored there is
				-- carried and never run.
				if slot == "untrigger" then
					label = "un" .. label
					liveKey = item.key == "custom" and "untrigger" or nil
				end
				addCode(report, prefix .. "trigger " .. n .. " " .. label,
					block and block[item.key],
					liveKey and WA.TriggerCodeIsLive(entry and entry.trigger, liveKey))
			end
		end
	end
	addCode(report, prefix .. "trigger logic", triggers and triggers.customTriggerLogic,
		triggers and triggers.disjunctive == "custom")

	local conditions = data.conditions
	for n = 1, table.getn(conditions or {}) do
		local changes = conditions[n] and conditions[n].changes or {}
		for i = 1, table.getn(changes) do
			local change = changes[i]
			local property = change and change.property
			local source
			if property == "customcode" or property == "chat"
				or property == "sound" or property == "glowexternal" then
				source = conditionCodeValue(change.value)
			end
			if source then
				addCode(report, prefix .. "condition " .. n .. " " .. tostring(change.property), source, true)
			end
		end
	end

	local animation = data.animation
	for _, phase in ipairs({ "start", "main", "finish" }) do
		local block = animation and animation[phase]
		for i = 1, table.getn(ANIMATION_CODE_KEYS) do
			local key = ANIMATION_CODE_KEYS[i]
			local slot = string.sub(key, 1, string.len(key) - 4)
			addCode(report, prefix .. "animation " .. phase .. " " .. key,
				block and block[key], WA.AnimationCodeIsLive(block, slot))
		end
	end

	local actions = data.actions
	for _, phase in ipairs({ "init", "start", "finish" }) do
		local block = actions and actions[phase]
		for i = 1, table.getn(ACTION_CODE_KEYS) do
			local key = ACTION_CODE_KEYS[i]
			local enabled = "do_custom"
			if key == "customOnLoad" then enabled = "do_custom_load"
			elseif key == "customOnUnload" then enabled = "do_custom_unload"
			elseif key == "message_custom" then enabled = "do_message" end
			addCode(report, prefix .. "action " .. phase .. " " .. key,
				block and block[key], block and block[enabled])
		end
	end
end

local function animationPresetTypes(phase)
	if phase == "start" then return WA.anim_start_preset_types end
	if phase == "finish" then return WA.anim_finish_preset_types end
	return WA.anim_main_preset_types
end

local function animationCapabilities(localType)
	return {
		scale = localType ~= "group" and localType ~= "dynamicgroup",
		color = localType ~= "group" and localType ~= "dynamicgroup",
		rotate = localType == "texture" or localType == "progresstexture",
	}
end

local function validateAnimation(data, sourceType, report)
	local animation = data.animation
	if type(animation) ~= "table" then return end
	local caps = animationCapabilities(sourceType)
	for _, phase in ipairs({ "start", "main", "finish" }) do
		local block = animation[phase]
		if type(block) == "table" then
			if block.type == "preset" and not animationPresetTypes(phase)[block.preset] then
				reportDrop(report, "unsupported animation preset", phase .. ": " .. tostring(block.preset))
				block.type, block.preset = "none", nil
			end
			if block.use_scale and not caps.scale then
				reportDrop(report, "unsupported animation", phase .. ": use_scale")
				block.use_scale = false
			end
			if block.use_rotate and not caps.rotate then
				reportDrop(report, "unsupported animation", phase .. ": use_rotate")
				block.use_rotate = false
			end
			if block.use_color and not caps.color then
				reportDrop(report, "unsupported animation", phase .. ": use_color")
				block.use_color = false
			end
			for i = 1, table.getn(ANIMATION_CODE_KEYS) do
				local key = ANIMATION_CODE_KEYS[i]
				local source = block[key]
				if hasSource(source) and type(WA.LoadFunction) == "function"
					and not WA.LoadFunction(source, nil) then
					block[key] = nil
					reportDrop(report, "custom code", "animation " .. phase .. " " .. key)
				end
			end
		end
	end
end

local function validateActionCode(data, report)
	local actions = data.actions
	if type(actions) ~= "table" then return end
	for _, phase in ipairs({ "init", "start", "finish" }) do
		local block = actions[phase]
		local specs = ACTION_SPECS[phase]
		if type(block) == "table" then
			for i = 1, table.getn(specs or {}) do
				local spec = specs[i]
				local source = block[spec.key]
				if hasSource(source) and type(WA.LoadFunction) == "function"
					and not WA.LoadFunction(source, nil, spec.body) then
					block[spec.key] = nil
					reportDrop(report, "custom code", "action " .. phase .. " " .. spec.key)
				end
			end
		end
	end
end

-- Upstream writes an aura reference as "WeakAuras:<id>"; ours is the same shape
-- under our own name. The id inside is the *exporter's*, and every id in an
-- import is reassigned -- remapChildIdKeys (ImportExport.lua) rewrites it once
-- the whole pack is installed and the old-to-new map is complete.
local WA2_ANCHOR_PREFIX = "WeakAuras:"

local function translateAnchorReference(value)
	if type(value) ~= "string" or value == "" then return nil end
	local _, _, id = string.find(value, "^WeakAuras:(.+)$")
	if id then return WA.ANCHOR_AURA_PREFIX .. id end
	return value
end

-- Upstream's Proc glow carries two keys nothing else reads. Dropping the art
-- (below) without them would leave an aura whose saved glow still claims a start
-- animation the replacement art has no concept of.
local GLOW_PROC_KEYS = { "glow_startAnim", "glow_duration" }

-- One glow descriptor, wherever it came from: an action block's keys sit on the
-- block, a condition change's on its `value`, and the shape is upstream's own
-- either way. A frame we cannot resolve is dropped outright, because a glow
-- aimed at nothing is a control the user will keep adjusting to no effect; an
-- art we do not draw falls back rather than dropping, since a glow of the wrong
-- shape still tells them what it was meant to tell them.
local function sanitizeGlow(block, report, label)
	if type(block) ~= "table" then return end
	if block.glow_type and not (WA.glow_types and WA.glow_types[block.glow_type]) then
		reportDrop(report, "unsupported glow art", label .. ": " .. tostring(block.glow_type))
		block.glow_type = nil
	end
	if block.glow_frame_type and not GLOW_FRAME_TYPES[block.glow_frame_type] then
		reportDrop(report, "unsupported glow frame", label .. ": " .. tostring(block.glow_frame_type))
		block.glow_frame_type, block.glow_frame = nil, nil
	end
	-- A frame selector names a global frame or another display, and upstream
	-- writes both into the one field. The aura reference carries the exporter's
	-- id, which remapChildIdKeys rewrites once the pack is installed.
	if block.glow_frame_type == "FRAMESELECTOR" then
		block.glow_frame = translateAnchorReference(block.glow_frame)
		if not block.glow_frame then
			reportDrop(report, "unsupported glow frame", label .. ": no frame named")
			block.glow_frame_type = nil
		end
	end
	for i = 1, table.getn(GLOW_PROC_KEYS) do
		local key = GLOW_PROC_KEYS[i]
		if block[key] ~= nil then
			reportDrop(report, "unsupported glow art", label .. ": " .. key)
			block[key] = nil
		end
	end
end

local function sanitizeActions(data, report)
	local actions = data.actions
	if type(actions) ~= "table" then return end
	for _, phase in ipairs({ "init", "start", "finish" }) do
		local block = actions[phase]
		if type(block) == "table" then
			for i = 1, table.getn(ACTION_DROP_KEYS) do
				local key = ACTION_DROP_KEYS[i]
				if block[key] ~= nil then
					reportDrop(report, "unsupported action", phase .. ": " .. key)
					block[key] = nil
				end
			end
			if block.message_type == "INSTANCE_CHAT" then
				reportDrop(report, "unsupported action", phase .. ": INSTANCE_CHAT")
				block.message_type, block.do_message = nil, nil
			end
			sanitizeGlow(block, report, phase)
			-- A glow whose frame is gone would light this aura's own region
			-- instead of the one the author picked, which is worse than silence.
			if block.do_glow and not block.glow_frame_type then
				reportDrop(report, "unsupported action", phase .. ": glow")
				block.do_glow = nil
			end
		end
	end
end

-- The condition half of the same descriptor. `translateConditionChanges` copies
-- a change's value wholesale -- correct for every other property, but a glow
-- carries frame and art names that have to survive the same check the action
-- block's do.
local function sanitizeConditionGlows(data, report)
	local conditions = data.conditions
	for n = 1, table.getn(conditions or {}) do
		local changes = conditions[n] and conditions[n].changes or {}
		for i = 1, table.getn(changes) do
			local change = changes[i]
			if change and change.property == "glowexternal" and type(change.value) == "table" then
				sanitizeGlow(change.value, report, conditionLabel(data, n) .. " glow")
			end
		end
	end
end

local function reportMediaOptions(options, report, seen)
	if type(options) ~= "table" then return end
	seen = seen or {}
	if seen[options] then return end
	seen[options] = true
	if options.type == "media" then
		reportDrop(report, "media option", options.name or options.key or "unnamed")
	end
	for _, value in pairs(options) do
		if type(value) == "table" then reportMediaOptions(value, report, seen) end
	end
end

local function reportTopLevelDrops(source, report)
	for i = 1, table.getn(TOP_LEVEL_DROPS) do
		local key = TOP_LEVEL_DROPS[i]
		if source[key] ~= nil then reportDrop(report, "metadata", key) end
	end
end

-- Texture-valued fields whose value can be a fileID or an atlas name, neither of
-- which resolves on this client. The value is kept -- it is still what the author
-- chose, and the options tab shows it -- and every paint falls back to a
-- placeholder rather than the engine's missing-texture block. Reported so the
-- substitution is not a silent one.
local TEXTURE_FIELDS = {
	{ key = "groupIcon", label = "group icon" },
	{ key = "displayIcon", label = "manual icon" },
	{ key = "sparkTexture", label = "spark texture" },
	{ key = "texture", label = "texture", only = "texture" },
	{ key = "foregroundTexture", label = "foreground texture" },
	{ key = "backgroundTexture", label = "background texture" },
}

-- A path into some *other* addon's folder, after the WeakAuras rewrite has had
-- its turn. Nothing offline can tell whether the sender's addon is installed
-- here, so the value is left alone -- but silence would be wrong too, since this
-- is the second most common reason an imported display draws nothing.
local function foreignAddonPath(value)
	if type(value) ~= "string" then return false end
	local lower = string.lower(string.gsub(value, "/", "\\"))
	if not string.find(lower, "^interface\\addons\\") then return false end
	return string.find(lower, "^interface\\addons\\weakestauras\\") == nil
end

local function reportUndrawableTextures(source, data, report)
	for i = 1, table.getn(TEXTURE_FIELDS) do
		local field = TEXTURE_FIELDS[i]
		local value = source[field.key]
		if value ~= nil and value ~= ""
			and (not field.only or source.regionType == field.only) then
			if not WA.DrawableTexture(value) then
				reportDrop(report, "texture this client cannot load",
					tostring(source.id or "?") .. " " .. field.label .. ": " .. tostring(value))
			elseif foreignAddonPath(data[field.key]) then
				reportDrop(report, "texture from an addon that may not be installed",
					tostring(source.id or "?") .. " " .. field.label .. ": " .. tostring(data[field.key]))
			end
		end
	end
end

-- Lands an incoming bar texture on one this addon actually ships. textureSource
-- is forced to LSM because it is ours, not upstream's: a bar arriving with a
-- stale Picker source would look at an empty textureInput and draw nothing.
local function translateBarTexture(data, source, report)
	data.textureSource = "LSM"
	data.textureInput = nil
	local name = source.texture
	if name == nil then return end
	local shipped = WA.Widgets.BarTextures()
	for i = 1, table.getn(shipped) do
		if shipped[i] == name then return end
	end
	local alias = BAR_TEXTURE_ALIASES[name]
	data.texture = alias or BAR_TEXTURE_DEFAULT
	reportDrop(report, "bar texture substituted",
		tostring(source.id or "?") .. ": " .. tostring(name) .. " -> " .. data.texture)
end

-- ---------------------------------------------------------------------------
-- Anchoring
--
-- Upstream's anchor frame types and ours are the same vocabulary bar one, so an
-- anchor is carried rather than flattened onto the screen.
--
-- Flattening is not the cosmetic loss it looks like. A display anchored to
-- another frame usually carries xOffset and yOffset of 0 and takes its whole
-- position from the anchor, so forcing SCREEN does not merely shift it -- it
-- collapses every display in the set onto one point. The corpus's ComboFill1-5
-- are exactly that: five textures at (0,0), each anchored to a different combo
-- point behind it, which imported as five textures stacked in one place.
--
-- PRD is retail's Personal Resource Display, which this client has no equivalent
-- of; CUSTOM resolves its frame by running the author's Lua, which would have to
-- travel through the code-disclosure path before it could be honoured. Both fall
-- back to the screen and say so.
-- ---------------------------------------------------------------------------

local ANCHOR_FRAME_TYPES = {
	SCREEN = true, UIPARENT = true, SELECTFRAME = true,
	MOUSE = true, NAMEPLATE = true, UNITFRAME = true,
}

local function translateAnchor(data, source, report)
	local frameType = source.anchorFrameType
	local label = tostring(source.id or "?")
	if frameType == nil or not ANCHOR_FRAME_TYPES[frameType] then
		if frameType ~= nil and frameType ~= "SCREEN" then
			reportDrop(report, "anchored to a frame this client has no equivalent of",
				label .. ": " .. tostring(frameType) .. " -> screen")
		end
		data.anchorFrameType = "SCREEN"
		data.anchorFrameFrame, data.anchorFrameParent = nil, nil
		return
	end
	data.anchorFrameType = frameType
	if frameType ~= "SELECTFRAME" then
		data.anchorFrameFrame = nil
		return
	end
	local reference = translateAnchorReference(source.anchorFrameFrame)
	if not reference then
		reportDrop(report, "anchored to a frame that was not named",
			label .. ": imported anchored to screen")
		data.anchorFrameType = "SCREEN"
		data.anchorFrameFrame, data.anchorFrameParent = nil, nil
		return
	end
	data.anchorFrameFrame = reference
	-- A reference to another aura is resolved by id and travels with the pack. A
	-- global frame name is the sender's UI, not ours, and nothing offline can say
	-- whether it exists here -- kept, since the alternative is silently moving
	-- the display, and reported so the miss is not a mystery.
	if string.sub(source.anchorFrameFrame, 1, string.len(WA2_ANCHOR_PREFIX)) ~= WA2_ANCHOR_PREFIX then
		reportDrop(report, "anchored to a frame from the sender's UI",
			label .. ": " .. tostring(source.anchorFrameFrame))
	end
end

local function translateGroup(data, source, report)
	local label = tostring(source.id or "?")
	-- A group's stored selfPoint means something upstream that it cannot mean
	-- here, and honouring it displaces the whole pack.
	--
	-- Upstream's group frame is 2x2 and never resized (Group.lua's create), so
	-- which of its corners is pinned moves it by a pixel -- the static group even
	-- overwrites selfPoint on every modify, to BOTTOMLEFT or CENTER, which is why
	-- an export can carry a point nothing ever reads back. A dynamic group's
	-- selfPoint is a third thing again: the corner its children grow from, which
	-- is `align` here. Our group frame is sized to its children's bounding box, so
	-- pinning it by a corner instead of its centre shifts every child by half that
	-- box -- hundreds of pixels for a real pack.
	--
	-- A grid is the one case where nothing is lost: upstream's options write
	-- selfPoint from gridType (its gridSelfPoints table) whenever either is
	-- touched, so the corner it names is one gridType already carries.
	if data.selfPoint ~= nil and data.selfPoint ~= "CENTER" and data.grow ~= "GRID" then
		reportDrop(report, "group anchor point", label .. ": " .. tostring(data.selfPoint)
			.. " -> CENTER")
	end
	data.selfPoint = "CENTER"
	-- A group's alpha cascades onto its children upstream; here the container
	-- frame has no alpha of its own, so a translucent pack would import opaque.
	if source.alpha ~= nil and source.alpha ~= 1 then
		reportDrop(report, "group alpha", label .. ": " .. tostring(source.alpha))
	end
	-- CIRCLE/COUNTERCIRCLE and CUSTOM name no axis to keep, so they fall back to
	-- the region default rather than to a direction. GRID is not among them: its
	-- geometry fields are ours by the same names, so `take` carries them.
	if data.grow ~= nil and not GROW_TYPES[data.grow] then
		reportDrop(report, "unsupported grow direction", label .. ": " .. tostring(data.grow))
		data.grow = nil
	end
	-- customGrow is refused rather than carried, so it is not this author's Lua
	-- that runs: upstream's grow function writes control-point coordinates, and
	-- there are no control points here to write.
	if hasSource(source.customGrow) then
		reportDrop(report, "custom grow", label)
	end
	for i = 1, table.getn(GROUP_DROP_KEYS) do
		local key = GROUP_DROP_KEYS[i]
		if source[key] then reportDrop(report, "unsupported group field", label .. ": " .. key) end
	end
	if source.border then
		for i = 1, table.getn(GROUP_BORDER_ART_KEYS) do
			if source[GROUP_BORDER_ART_KEYS[i]] ~= nil then
				reportDrop(report, "group border art", label)
				break
			end
		end
	end
end

local function translateDisplay(source, report)
	local sourceType = source.regionType
	local localType = REGION_MAP[sourceType]
	if not localType then
		report.refused = "unsupported region type " .. tostring(sourceType)
		return nil
	end

	local data = {}
	if source.id ~= nil then data.id = WA.DeepCopy(source.id) end
	if source.uid ~= nil then data.uid = WA.DeepCopy(source.uid) end
	-- Author metadata, outside keysFor's per-type whitelist because every type
	-- carries it: the Info tab shows and edits both.
	if type(source.desc) == "string" then data.desc = source.desc end
	if type(source.url) == "string" then data.url = source.url end
	take(data, source, keysFor(localType))
	data.regionType = sourceType == "aurabar" and "progressbar" or sourceType
	if sourceType == "model" or sourceType == "stopmotion" then
		reportDrop(report, "unsupported region type", sourceType)
	elseif sourceType == "progresstexture"
		and (source.orientation == "CLOCKWISE" or source.orientation == "ANTICLOCKWISE") then
		reportDrop(report, "unsupported progress texture orientation", source.orientation)
	end

	translateAnchor(data, source, report)

	if GROUP_TYPES[sourceType] then
		translateGroup(data, source, report)
	else
		if sourceType == "aurabar" then translateBarTexture(data, source, report) end
		local progress = source.progressSource
		if type(progress) == "table" then
			data.progressSource = WA.DeepCopy(progress[1])
			if progress[1] == 0 then
				if progress[3] ~= nil then data.progressSourceManualValue = WA.DeepCopy(progress[3]) end
				if progress[4] ~= nil then data.progressSourceManualTotal = WA.DeepCopy(progress[4]) end
			end
			if progress[2] ~= nil and progress[2] ~= "" then
				reportDrop(report, "per-property progress source", tostring(progress[2]))
			end
		end
		local triggers = translateTriggers(source, report)
		if report.refused then return nil end
		if triggers then data.triggers = triggers end
	end
	local subRegions = translateSubRegions(source, data, report)
	if subRegions then data.subRegions = subRegions end
	if source.conditions ~= nil then
		data.conditions = translateConditions(source.conditions, data, report)
	end
	if source.load ~= nil then
		data.load = translateLoad(source.load, data, report)
	end

	copyBlock(data, source, "animation")
	copyBlock(data, source, "actions")
	copyBlock(data, source, "authorOptions")
	copyBlock(data, source, "config")
	if source.authorMode ~= nil then data.authorMode = WA.DeepCopy(source.authorMode) end
	validateAnimation(data, localType, report)
	sanitizeActions(data, report)
	sanitizeConditionGlows(data, report)
	validateActionCode(data, report)
	reportMediaOptions(data.authorOptions, report)
	WA.ValidateUserConfig(data)
	remapMedia(data, report, tostring(source.id or "?"))
	reportUndrawableTextures(source, data, report)
	reportTopLevelDrops(source, report)

	local codeSource = WA.DeepCopy(source)
	codeSource.animation = data.animation
	codeSource.actions = data.actions
	codeSource.customText = data.customText
	codeSource.conditions = data.conditions
	codeSource.customSort = data.customSort
	codeSource.customAnchorPerUnit = data.customAnchorPerUnit
	WA.CollectImportCode(codeSource, report, tostring(source.id or "?") .. " - ")

	-- Current-schema by construction -- fresh tables, current field names,
	-- upstream's own draw order -- so the importer's migrations must not touch
	-- it. The source's internalVersion counts upstream Modernize passes, not
	-- our schema, and is never carried.
	data.internalVersion = WA.SCHEMA_VERSION
	return data
end

-- A dynamic group arranges its children itself and cannot own a nested group --
-- the one placement WA.CanPlaceAura refuses outright. Silently flattening the
-- pack would put a sub-group's children where their author never arranged them,
-- so the whole import stops instead.
local function placementRefusal(parentSource, childSource)
	if parentSource.regionType ~= "dynamicgroup" then return nil end
	if not GROUP_TYPES[childSource.regionType] then return nil end
	return "\"" .. tostring(childSource.id) .. "\" is a group inside a dynamic group, which cannot be placed here"
end

-- The displays under the root, parents before their own children and siblings in
-- the author's order. The installer walks the same list and depends on that
-- ordering to have a parent's assigned id in hand by the time it reaches a child.
--
-- payload.c is a flat list in both transmission versions and means two different
-- things. v1421 strips parent and controlledChildren and sends the root's direct
-- children; v2000 keeps both and sends every descendant, so there the tree exists
-- only in those fields. The version decides which, never the presence of a parent
-- field -- a v2000 pack read as v1421 loses every sub-group's nesting, and the
-- reverse finds no tree at all.
local function buildTree(payload, report)
	local rootSource = payload.d
	local children = payload.c
	if children == nil then return {} end
	if type(children) ~= "table" then
		report.refused = "payload has invalid child displays"
		return nil
	end
	local count = table.getn(children)
	if count > 0 and not GROUP_TYPES[rootSource.regionType] then
		report.refused = "child displays require a group root"
		return nil
	end
	-- Every id below is a table key, and a nil one raises rather than refusing.
	if count > 0 and type(rootSource.id) ~= "string" then
		report.refused = "the group display has no id"
		return nil
	end
	for i = 1, count do
		if type(children[i]) ~= "table" or type(children[i].id) ~= "string" then
			report.refused = "child display " .. i .. " has no id"
			return nil
		end
	end

	local nodes = {}
	if payload.v ~= 2000 then
		for i = 1, count do
			local refusal = placementRefusal(rootSource, children[i])
			if refusal then
				report.refused = refusal
				return nil
			end
			table.insert(nodes, { source = children[i], parent = rootSource.id })
		end
		return nodes
	end

	local byId = { [rootSource.id] = rootSource }
	for i = 1, count do
		local child = children[i]
		if byId[child.id] then
			report.refused = "two displays share the id \"" .. child.id .. "\""
			return nil
		end
		byId[child.id] = child
	end

	-- Following controlledChildren rather than each child's parent is what keeps
	-- siblings in the author's order; `seen` is also the cycle guard, since a
	-- payload can name a group as its own ancestor.
	local seen = {}
	local function walk(parentSource)
		local list = parentSource.controlledChildren
		if type(list) ~= "table" then return end
		for i = 1, table.getn(list) do
			if report.refused then return end
			local child = byId[list[i]]
			if child and child ~= rootSource and not seen[child] then
				seen[child] = true
				local refusal = placementRefusal(parentSource, child)
				if refusal then
					report.refused = refusal
					return
				end
				table.insert(nodes, { source = child, parent = parentSource.id })
				walk(child)
			end
		end
	end
	walk(rootSource)
	if report.refused then return nil end

	for i = 1, count do
		if not seen[children[i]] then
			reportDrop(report, "aura not imported",
				tostring(children[i].id) .. ": no group in this import claims it")
		end
	end
	return nodes
end

-- A group whose children all refused installs as an empty box: it holds
-- nothing, draws nothing, and the user has to hunt it down and delete it. It
-- leaves with them, and so does any group left empty by its leaving. A group its
-- author shipped empty stays -- that one is deliberate, so only a group that
-- *lost* children is pruned.
local function pruneEmptyGroups(children, nodes, report)
	local authored = {}
	for i = 1, table.getn(nodes) do authored[nodes[i].parent] = true end
	local pruning = true
	while pruning do
		pruning = false
		local hasChild = {}
		for i = 1, table.getn(children) do hasChild[children[i].parent] = true end
		for i = table.getn(children), 1, -1 do
			local child = children[i]
			if GROUP_TYPES[child.regionType] and authored[child.id] and not hasChild[child.id] then
				table.remove(children, i)
				reportDrop(report, "aura not imported",
					tostring(child.id) .. ": an empty group, none of its auras could be imported")
				pruning = true
			end
		end
	end
end

function WA.WA2Translate(payload)
	local report = { created = {}, dropped = {}, code = {}, refused = nil }
	if type(payload) ~= "table" then
		report.refused = "payload is not a table"
		return nil, report
	end
	if type(payload.d) ~= "table" then
		report.refused = "payload has no display"
		return nil, report
	end
	-- The root is translated before the tree is walked, so that a root refusing on
	-- its own terms says so rather than being reported as a malformed group.
	local ok, root = pcall(translateDisplay, payload.d, report)
	if not ok then
		report.refused = "translation failed: " .. tostring(root)
		return nil, report
	end
	if not root then return nil, report end
	local nodes = buildTree(payload, report)
	if not nodes then return nil, report end

	-- A child that refuses is dropped by name rather than refusing the pack: the
	-- rest of it behaves exactly as its author arranged, and a named absence is
	-- a visible failure where refusing thirty auras over one leaves the user
	-- nothing they can act on. Only the root refusing refuses the import, and a
	-- child's own report is merged only once it survives, so a dropped display
	-- never contributes code to the disclosure list.
	local children, dropped = {}, {}
	local nodeCount = table.getn(nodes)
	for i = 1, nodeCount do
		local node = nodes[i]
		local label = tostring(node.source.id or "?")
		if dropped[node.parent] then
			dropped[label] = true
			reportDrop(report, "aura not imported", label .. ": its group was not imported")
		else
			local childReport = { created = {}, dropped = {}, code = {}, refused = nil }
			local childOk, child = pcall(translateDisplay, node.source, childReport)
			if childOk and child then
				child.parent = node.parent
				table.insert(children, child)
				for n = 1, table.getn(childReport.dropped) do
					table.insert(report.dropped, childReport.dropped[n])
				end
				for n = 1, table.getn(childReport.code) do
					table.insert(report.code, childReport.code[n])
				end
			else
				dropped[label] = true
				reportDrop(report, "aura not imported",
					label .. ": " .. tostring(childOk and childReport.refused or child))
			end
		end
	end
	pruneEmptyGroups(children, nodes, report)
	if nodeCount > 0 and table.getn(children) == 0 then
		report.refused = "none of this group's " .. nodeCount .. " auras could be imported"
		return nil, report
	end
	return { root = root, children = children }, report
end

-- How many details one reason spells out before it just counts. A pack of
-- eighty children reports the same drop eighty times, and a summary nobody can
-- read to the end is a review step in name only.
local DETAIL_LIMIT = 6

function WA.ImportSummary(pending, report)
	local root = pending and pending.root or {}
	local childCount = table.getn(pending and pending.children or {})
	local header = "Importing \"" .. tostring(root.id or "Imported") .. "\"  ("
		.. tostring(root.regionType or "unknown") .. ")"
	if childCount == 1 then
		header = header .. " and 1 aura inside it"
	elseif childCount > 1 then
		header = header .. " and " .. childCount .. " auras inside it"
	end
	local lines = { header }
	if table.getn(report and report.code or {}) > 0 then
		table.insert(lines, "")
		table.insert(lines, "Runs this author's Lua:")
		for i = 1, table.getn(report.code) do
			local item = report.code[i]
			local state = item.active and "active" or "inactive"
			table.insert(lines, "  " .. tostring(item.name) .. "  (" .. state .. ")")
			local source = string.gsub(item.source or "", "\n", "\n    ")
			table.insert(lines, "    " .. source)
		end
	end
	if table.getn(report and report.dropped or {}) > 0 then
		local groups, byReason = {}, {}
		for i = 1, table.getn(report.dropped) do
			local item = report.dropped[i]
			local group = byReason[item.reason]
			if not group then
				group = { reason = item.reason, count = 0, details = {} }
				byReason[item.reason] = group
				table.insert(groups, group)
			end
			group.count = group.count + 1
			table.insert(group.details, item.detail)
		end
		table.insert(lines, "")
		table.insert(lines, "Not imported:")
		for i = 1, table.getn(groups) do
			local group = groups[i]
			local shown = group.details
			local hidden = group.count - DETAIL_LIMIT
			if hidden > 0 then
				shown = {}
				for n = 1, DETAIL_LIMIT do shown[n] = group.details[n] end
			end
			local line = "  " .. tostring(group.reason) .. " (" .. group.count .. ")  "
				.. table.concat(shown, ", ")
			if hidden > 0 then line = line .. ", and " .. hidden .. " more" end
			table.insert(lines, line)
		end
	end
	if report and report.sourceVersion then
		table.insert(lines, "")
		table.insert(lines, "Exported from " .. (report.sourceAddon or "WeakestAuras")
			.. " " .. tostring(report.sourceVersion))
		local mods = report.sourceMods
		if type(mods) == "table" then
			local parts = {}
			if mods.classicapi then table.insert(parts, "ClassicAPI " .. tostring(mods.classicapi)) end
			if mods.superwow then table.insert(parts, "SuperWoW " .. tostring(mods.superwow)) end
			if mods.nampower then table.insert(parts, "Nampower " .. tostring(mods.nampower)) end
			if table.getn(parts) > 0 then
				table.insert(lines, "  built with " .. table.concat(parts, ", "))
			end
		end
		if report.sourceAddon == "WeakestAuras"
			and WA.VersionNewer(report.sourceVersion, WA.version) then
			table.insert(lines, "  That WeakestAuras is newer than this one -- settings it added may not survive.")
		end
	end
	return table.concat(lines, "\n")
end
