-- WeakestAuras -- the shared font block: the curated font list, the addon's one
-- SetFont call site, and the BuildOptions rows that drive them. Mirrors the font
-- half of WA2's Text region (§7).
-- Upstream section refs (§N) point at design/architecture/weakauras2-reference.md
--
-- A consumer keeps its settings as flat keys under its own schema and hands the
-- table plus a prefix and alias map to Apply; every key is optional, and the
-- defaults below are what a FontString does with no font block at all.

if WeakestAuras.disabled then return end

local WA = WeakestAuras

local textCore = {}
WA.textCore = textCore

-- No LibSharedMedia here, so the picker is a fixed list and what gets *stored*
-- is the path, not the name: there is no registry to resolve a name against
-- later, so renaming an entry would leave every aura holding it with no font.
--
-- The bundled faces carry WA2's LibSharedMedia names verbatim, because that is
-- what a WeakAuras export stores in text_font and WA2Import resolves an incoming
-- name against this list -- renaming one here silently strips the font off every
-- aura imported afterwards.
textCore.FONTS = {
	{ name = "Friz Quadrata", path = "Fonts\\FRIZQT__.TTF" },
	{ name = "Arial Narrow", path = "Fonts\\ARIALN.TTF" },
	{ name = "Morpheus", path = "Fonts\\MORPHEUS.TTF" },
	{ name = "Skurri", path = "Fonts\\SKURRI.TTF" },
	{ name = "Roboto Mono", path = "Interface\\AddOns\\WeakestAuras\\fonts\\RobotoMono.ttf" },
	{ name = "Fira Mono Medium", path = "Interface\\AddOns\\WeakestAuras\\fonts\\FiraMono-Medium.ttf" },
	{ name = "Fira Sans Black", path = "Interface\\AddOns\\WeakestAuras\\fonts\\FiraSans-Heavy.ttf" },
	{ name = "Fira Sans Medium", path = "Interface\\AddOns\\WeakestAuras\\fonts\\FiraSans-Medium.ttf" },
	{ name = "Fira Sans Condensed Black", path = "Interface\\AddOns\\WeakestAuras\\fonts\\FiraSansCondensed-Heavy.ttf" },
	{ name = "Fira Sans Condensed Medium", path = "Interface\\AddOns\\WeakestAuras\\fonts\\FiraSansCondensed-Medium.ttf" },
	{ name = "PT Sans Narrow Regular", path = "Interface\\AddOns\\WeakestAuras\\fonts\\PTSansNarrow-Regular.ttf" },
	{ name = "PT Sans Narrow Bold", path = "Interface\\AddOns\\WeakestAuras\\fonts\\PTSansNarrow-Bold.ttf" },
	{ name = "Oswald", path = "Interface\\AddOns\\WeakestAuras\\fonts\\Oswald-Regular.ttf" },
	{ name = "Celestia Medium Redux", path = "Interface\\AddOns\\WeakestAuras\\fonts\\CelestiaMediumRedux1.55.ttf" },
	{ name = "DejaVu Sans", path = "Interface\\AddOns\\WeakestAuras\\fonts\\DejaVuLGCSans.ttf" },
	{ name = "DejaVu Serif", path = "Interface\\AddOns\\WeakestAuras\\fonts\\DejaVuLGCSerif.ttf" },
	{ name = "Gentium Plus", path = "Interface\\AddOns\\WeakestAuras\\fonts\\GentiumPlus-Regular.ttf" },
	{ name = "Hack", path = "Interface\\AddOns\\WeakestAuras\\fonts\\Hack-Regular.ttf" },
	{ name = "Liberation Mono", path = "Interface\\AddOns\\WeakestAuras\\fonts\\LiberationMono-Regular.ttf" },
	{ name = "Liberation Sans", path = "Interface\\AddOns\\WeakestAuras\\fonts\\LiberationSans-Regular.ttf" },
	{ name = "Liberation Serif", path = "Interface\\AddOns\\WeakestAuras\\fonts\\LiberationSerif-Regular.ttf" },
	{ name = "swf!t", path = "Interface\\AddOns\\WeakestAuras\\fonts\\SWF!T___.TTF" },
	{ name = "Yellowjacket", path = "Interface\\AddOns\\WeakestAuras\\fonts\\yellow.ttf" },
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

textCore.REGION_KEYS = {
	font = "font", size = "fontSize", flags = "outline", color = "color",
	justifyH = "justify", justifyV = "justifyV", spacing = "spacing",
	shadowColor = "shadowColor", shadowX = "shadowXOffset", shadowY = "shadowYOffset",
}
textCore.SUBTEXT_KEYS = {
	font = "font", size = "fontSize", flags = "fontType", color = "color",
	justifyH = "justify", justifyV = "justifyV", spacing = "spacing",
	shadowColor = "shadowColor", shadowX = "shadowXOffset", shadowY = "shadowYOffset",
}

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
local function setFontFace(fs, path, size, flags)
	local ok = fs:SetFont(path, size, flags)
	if ok and fs:GetFont() then return true end
	ok = fs:SetFont(path, size, "")
	if ok and fs:GetFont() then return true end
	ok = fs:SetFont(DEFAULTS.font, size, "")
	if ok and fs:GetFont() then return true end
	fs:SetFontObject(GameFontHighlight)
	return fs:GetFont() ~= nil
end

-- Where this client stops honouring SetFont's size. Nothing announces it: past
-- the ceiling SetFont returns normally, GetFont reads back the size that was
-- asked for, and the glyphs are rasterised at the ceiling regardless -- so a
-- 40pt aura draws the same height as a 20pt one.
--
-- It has to be MEASURED, and by width, because a clamped size lays out exactly
-- like the ceiling's: the sweep looks for where the string stops widening. A
-- sweep that widens the whole way (or that measures nothing at all, which is
-- what the headless harness does) latches `false` and turns the scaling below
-- off entirely, so a client without a ceiling pays nothing for this.
--
-- One measurement serves every face: the ceiling belongs to the rasteriser, not
-- to the file.
local sizeCeiling
local CEILING_SWEEP_TOP = 80
local function fontSizeCeiling()
	if sizeCeiling ~= nil then return sizeCeiling end
	sizeCeiling = false
	local host = CreateFrame("Frame", nil, UIParent)
	host:Hide()
	local probe = host:CreateFontString(nil, "BACKGROUND")
	local grew, last = nil, nil
	for size = 8, CEILING_SWEEP_TOP do
		probe:SetFont(DEFAULTS.font, size, "")
		probe:SetText("HHHHHH")
		local w = probe:GetStringWidth() or 0
		if w <= 0 then return sizeCeiling end
		if last and w > last + 0.5 then grew = size end
		last = w
	end
	if grew and grew < CEILING_SWEEP_TOP then sizeCeiling = grew end
	return sizeCeiling
end

-- The measurement itself, for /wa textprobe to report.
textCore.SizeCeiling = fontSizeCeiling

-- SetTextHeight scales what SetFont rasterised, and is the only way to draw
-- above the ceiling -- softer edges up there, which is the whole price. Two
-- things about it are load-bearing, and the fix does not work without either:
--
-- The two sizes must DIFFER. SetTextHeight does nothing when it would not change
-- the size SetFont was given, and above the ceiling that size is the one the
-- user asked for -- SetFont was told 40 and reports 40, it merely drew 20. So
-- the face is deliberately rasterised at the ceiling and scaled from there;
-- asking for 40 twice changes nothing. MikScrollingBattleText reaches the same
-- shape from the other side, rasterising one point below whatever it wants.
--
-- And it is re-asserted after the string, which is why the size is kept on the
-- FontString for SetText below. This pair applied at SetFont time alone drew at
-- the ceiling on screen even though it measures correctly on a bare FontString,
-- so something between the two puts the height back -- the colour/justify/
-- spacing/shadow calls in Apply, or the SetParent round trip Auto-mode measuring
-- makes. Which one is unidentified; the re-assert costs one call per string and
-- only on a string that is actually scaled.
local function setFont(fs, path, size, flags)
	local ceiling = fontSizeCeiling()
	local raster = size
	if ceiling and size > ceiling then raster = ceiling end
	if not setFontFace(fs, path, raster, flags) then return false end
	if raster ~= size then
		fs.waTextHeight = size
		fs:SetTextHeight(size)
	else
		fs.waTextHeight = nil
	end
	return true
end

local function keyName(aliases, key)
	return aliases and aliases[key] or key
end

local function val(data, prefix, key, aliases)
	local v = data[prefix .. keyName(aliases, key)]
	if v == nil then return DEFAULTS[key] end
	return v
end

-- Applies the whole block to `fs`, reading `data[prefix .. key]` for each key.
-- Returns whether a font actually loaded, which is what gates SetText below.
--
-- `size` overrides the stored one without writing it back: a condition changing
-- font size has to re-enter SetFont -- and therefore the read-back above -- not
-- merely call SetTextHeight, but the size it picked is not the user's setting.
function textCore.Apply(fs, data, prefix, size, aliases)
	local ok = setFont(fs, val(data, prefix, "font", aliases), size or val(data, prefix, "size", aliases),
		flagString(val(data, prefix, "flags", aliases)))

	local c = val(data, prefix, "color", aliases)
	fs:SetTextColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1)

	fs:SetJustifyH(val(data, prefix, "justifyH", aliases))
	fs:SetJustifyV(val(data, prefix, "justifyV", aliases))
	fs:SetSpacing(val(data, prefix, "spacing", aliases))

	local s = val(data, prefix, "shadowColor", aliases)
	fs:SetShadowColor(s[1] or 0, s[2] or 0, s[3] or 0, s[4] or 1)
	fs:SetShadowOffset(val(data, prefix, "shadowX", aliases), val(data, prefix, "shadowY", aliases))

	return ok
end

-- The other half of the read-back: a FontString whose font failed to load draws
-- nothing at all, so replacing its string blanks the region outright where
-- leaving the previous one at least keeps something on screen.
function textCore.SetText(fs, str)
	if not fs:GetFont() then return false end
	fs:SetText(str)
	-- Only a string scaled past the size ceiling carries one, and only that string
	-- pays for the second call.
	if fs.waTextHeight then fs:SetTextHeight(fs.waTextHeight) end
	return true
end

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------

local function summary(get, aliases)
	local font = get(keyName(aliases, "font")) or DEFAULTS.font
	local flags = get(keyName(aliases, "flags")) or DEFAULTS.flags
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
function textCore.OptionFields(data, foldKey, get, set, aliases)
	local S = WA.OptionsState
	local collapsed = S.isCollapsed(data, foldKey, true)
	local fields = { {
		type = "disclosure", name = "Font Options",
		summary = summary(get, aliases),
		collapsed = collapsed,
		onToggle = function()
			S.setCollapsed(data, foldKey, not collapsed)
			WA.RefreshOptions()
		end,
	} }
	if collapsed then return fields end

	local function row(f) table.insert(fields, f) end
	local function pick(key, name, values, labels, half)
		local storedKey = keyName(aliases, key)
		row({
			type = "select", name = name, key = storedKey, values = values, labels = labels, half = half,
			get = function() return get(storedKey) or DEFAULTS[key] end,
			set = function(v) set(storedKey, v) end,
		})
	end
	local function slide(key, name, min, max, half)
		local storedKey = keyName(aliases, key)
		row({
			type = "range", name = name, key = storedKey, min = min, max = max, step = 1, half = half,
			get = function()
				local v = get(storedKey)
				if v == nil then return DEFAULTS[key] end
				return v
			end,
			set = function(v) set(storedKey, v) end,
		})
	end

	pick("font", "Font", FONT_VALUES, FONT_LABELS)
	pick("flags", "Outline", textCore.FLAGS, textCore.FLAG_LABELS)
	pick("justifyH", "Justify", textCore.JUSTIFY_H, JUSTIFY_LABELS, true)
	pick("justifyV", "Vertical Justify", textCore.JUSTIFY_V, JUSTIFY_LABELS, true)
	slide("spacing", "Line Spacing", 0, 20)
	local shadowColorKey = keyName(aliases, "shadowColor")
	row({
		type = "color", name = "Shadow Color", key = shadowColorKey,
		get = function() return get(shadowColorKey) or DEFAULTS.shadowColor end,
		set = function(v) set(shadowColorKey, v) end,
	})
	slide("shadowX", "Shadow X", -10, 10, true)
	slide("shadowY", "Shadow Y", -10, 10, true)

	return fields
end
