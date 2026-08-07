-- WeakestAuras -- the shared font block: the curated font list, the addon's one
-- SetFont call site, and the BuildOptions rows that drive them. Mirrors the font
-- half of WA2's Text region (§7).
-- Upstream section refs (§N) point at design/architecture/weakauras2-reference.md
--
-- A consumer keeps its settings as flat keys under a prefix of its own
-- ("text_font", "text_flags", ...) and hands the whole table plus that prefix to
-- Apply; every key is optional, and the defaults below are what a FontString
-- does with no font block at all.

if WeakestAuras.disabled then return end

local WA = WeakestAuras

local textCore = {}
WA.textCore = textCore

-- No LibSharedMedia here, so the picker is a fixed list and what gets *stored*
-- is the path, not the name: there is no registry to resolve a name against
-- later, so renaming an entry would leave every aura holding it with no font.
textCore.FONTS = {
	{ name = "Friz Quadrata", path = "Fonts\\FRIZQT__.TTF" },
	{ name = "Arial Narrow", path = "Fonts\\ARIALN.TTF" },
	{ name = "Morpheus", path = "Fonts\\MORPHEUS.TTF" },
	{ name = "Skurri", path = "Fonts\\SKURRI.TTF" },
	{ name = "Roboto Mono", path = "Interface\\AddOns\\WeakestAuras\\fonts\\RobotoMono.ttf" },
}

-- Stored as "None" rather than "" so the picker has no empty value; Apply maps
-- it back. The two MONOCHROME combos are comma-joined, which is the separator
-- this client's SetFont takes.
textCore.FLAGS = {
	"None", "OUTLINE", "THICKOUTLINE",
	"MONOCHROME", "MONOCHROME,OUTLINE", "MONOCHROME,THICKOUTLINE",
}
textCore.FLAG_LABELS = {
	None = "None",
	OUTLINE = "Outline",
	THICKOUTLINE = "Thick Outline",
	MONOCHROME = "Monochrome",
	["MONOCHROME,OUTLINE"] = "Monochrome Outline",
	["MONOCHROME,THICKOUTLINE"] = "Monochrome Thick Outline",
}

textCore.JUSTIFY_H = { "LEFT", "CENTER", "RIGHT" }
textCore.JUSTIFY_V = { "TOP", "MIDDLE", "BOTTOM" }
local JUSTIFY_LABELS = {
	LEFT = "Left", CENTER = "Center", RIGHT = "Right",
	TOP = "Top", MIDDLE = "Middle", BOTTOM = "Bottom",
}

-- Every key the block reads, with the value it takes when absent. These are what
-- a bare FontString already does, which is why no saved aura needs migrating to
-- pick the block up.
local DEFAULTS = {
	font = "Fonts\\FRIZQT__.TTF",
	size = 12,
	flags = "OUTLINE",
	color = { 1, 1, 1, 1 },
	justifyH = "CENTER",
	justifyV = "MIDDLE",
	spacing = 0,
	shadowColor = { 0, 0, 0, 1 },
	shadowX = 0,
	shadowY = 0,
}
textCore.DEFAULTS = DEFAULTS

local FONT_VALUES, FONT_LABELS = {}, {}
for i = 1, table.getn(textCore.FONTS) do
	local f = textCore.FONTS[i]
	table.insert(FONT_VALUES, f.path)
	FONT_LABELS[f.path] = f.name
end

local function flagString(flags)
	if not flags or flags == "None" then return "" end
	return flags
end

-- SetFont reports falsy and leaves the string *unrendered* when it rejects the
-- path or the flag combination, and GetFont then reads back nil -- so a bad pick
-- is not a wrong-looking region but an invisible one, with nothing on screen to
-- say why. Both readings are taken, since only the second survives a client that
-- returns nothing from SetFont on success.
--
-- The flag string is dropped before the face because it is the likelier half to
-- be refused: MONOCHROME and the two combos are not confirmed on this client.
local function setFont(fs, path, size, flags)
	local ok = fs:SetFont(path, size, flags)
	if ok and fs:GetFont() then return true end
	ok = fs:SetFont(path, size, "")
	if ok and fs:GetFont() then return true end
	ok = fs:SetFont(DEFAULTS.font, size, "")
	if ok and fs:GetFont() then return true end
	fs:SetFontObject(GameFontHighlight)
	return fs:GetFont() ~= nil
end

local function val(data, prefix, key)
	local v = data[prefix .. key]
	if v == nil then return DEFAULTS[key] end
	return v
end

-- Applies the whole block to `fs`, reading `data[prefix .. key]` for each key.
-- Returns whether a font actually loaded, which is what gates SetText below.
--
-- `size` overrides the stored one without writing it back: a condition changing
-- font size has to re-enter SetFont -- and therefore the read-back above -- not
-- merely call SetTextHeight, but the size it picked is not the user's setting.
function textCore.Apply(fs, data, prefix, size)
	local ok = setFont(fs, val(data, prefix, "font"), size or val(data, prefix, "size"),
		flagString(val(data, prefix, "flags")))

	local c = val(data, prefix, "color")
	fs:SetTextColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1)

	fs:SetJustifyH(val(data, prefix, "justifyH"))
	fs:SetJustifyV(val(data, prefix, "justifyV"))
	fs:SetSpacing(val(data, prefix, "spacing"))

	local s = val(data, prefix, "shadowColor")
	fs:SetShadowColor(s[1] or 0, s[2] or 0, s[3] or 0, s[4] or 1)
	fs:SetShadowOffset(val(data, prefix, "shadowX"), val(data, prefix, "shadowY"))

	return ok
end

-- The other half of the read-back: a FontString whose font failed to load draws
-- nothing at all, so replacing its string blanks the region outright where
-- leaving the previous one at least keeps something on screen.
function textCore.SetText(fs, str)
	if not fs:GetFont() then return false end
	fs:SetText(str)
	return true
end

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------

local function summary(get)
	local font = get("font") or DEFAULTS.font
	local flags = get("flags") or DEFAULTS.flags
	return (FONT_LABELS[font] or font) .. ", "
		.. (textCore.FLAG_LABELS[flags] or flags)
end

-- The block's BuildOptions rows, behind a fold keyed on `foldKey` within `data`.
-- `get(key)`/`set(key, v)` address the bare key names above; the consumer owns
-- the prefix and the WA.Add call.
--
-- Size and colour are deliberately not here. They belong wherever the consumer
-- already puts them: they are the two rows anyone actually edits, and burying
-- them under a fold to keep the other eight company is a worse tab.
function textCore.OptionFields(data, foldKey, get, set)
	local S = WA.OptionsState
	local collapsed = S.isCollapsed(data, foldKey, true)
	local fields = { {
		type = "disclosure", name = "Font Options",
		summary = summary(get),
		collapsed = collapsed,
		onToggle = function()
			S.setCollapsed(data, foldKey, not collapsed)
			WA.RefreshOptions()
		end,
	} }
	if collapsed then return fields end

	local function row(f) table.insert(fields, f) end
	local function pick(key, name, values, labels, half)
		row({
			type = "select", name = name, key = key, values = values, labels = labels, half = half,
			get = function() return get(key) or DEFAULTS[key] end,
			set = function(v) set(key, v) end,
		})
	end
	local function slide(key, name, min, max, half)
		row({
			type = "range", name = name, key = key, min = min, max = max, step = 1, half = half,
			get = function()
				local v = get(key)
				if v == nil then return DEFAULTS[key] end
				return v
			end,
			set = function(v) set(key, v) end,
		})
	end

	pick("font", "Font", FONT_VALUES, FONT_LABELS)
	pick("flags", "Outline", textCore.FLAGS, textCore.FLAG_LABELS)
	pick("justifyH", "Justify", textCore.JUSTIFY_H, JUSTIFY_LABELS, true)
	pick("justifyV", "Vertical Justify", textCore.JUSTIFY_V, JUSTIFY_LABELS, true)
	slide("spacing", "Line Spacing", 0, 20)
	row({
		type = "color", name = "Shadow Color", key = "shadowColor",
		get = function() return get("shadowColor") or DEFAULTS.shadowColor end,
		set = function(v) set("shadowColor", v) end,
	})
	slide("shadowX", "Shadow X", -10, 10, true)
	slide("shadowY", "Shadow Y", -10, 10, true)

	return fields
end
