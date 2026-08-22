-- WeakestAuras -- shared widget factories and the declarative options-table
-- renderer. Widget look/feel (flat dark backdrop buttons, tooltip-style edit
-- boxes) follows the sibling Quartermaster config.
--
-- WA.Widgets.BuildOptions(page, fields) paints a whole tab's controls from a
-- plain array of field descriptors instead of hand-building a frame per field:
--   { type = "header"|"disclosure"|"toggle"|"input"|"multiline"|"range"|"select"
--            |"color"|"spell"|"item"|"icon"|"namelist"|"opnumber"|"button"|"menu"|"space"|"anchorgrid",
--     name = "...",
--     key = "...",         -- stable field id, see below; omitted for header/button
--     get = function() end, set = function(value) end,   -- color: get/set a {r,g,b,a}
--     half = true,         -- pack two-per-row (any non-header type); default full row
--     min, max, step, softMax,   -- range only
--     values, labels,      -- select only: ordered values + optional value->label
--     swatches,            -- select only: value -> texture path; each entry (and
--                          -- the button face) previews it as a filled bar
--     getOp, setOp, getVal, setVal,   -- opnumber only: operator select + number
--     onClick, width }     -- button only: name is its label, width its pixel size
-- A `header` additionally takes `collapsed` (a bool -- present at all makes the
-- section collapsible: draws an up/down arrow, and the title line itself
-- toggles) with `onToggle`, `onDelete` (a two-click-confirm delete button), and
-- `actions` (icon buttons painted left-to-right on the right).
-- A `select` can also carry `actions`, which are painted beside its dropdown.
-- Collapsing is the *generator's* job: BuildOptions only paints the affordance,
-- so a collapsed section simply omits its body fields from the array it returns.
-- A `disclosure` folds the same way but is a control rather than a divider: a
-- gear leading a clickable one-line label, for settings that get set once and
-- then only get in the way. It takes the same `collapsed`/`onToggle`, plus
-- `summary` -- appended to `name` in grey, so the folded state still says what
-- the hidden rows hold.
-- A `range` is a spin box (LibWidgets.NewSpinBox), not a bare slider: `min`/
-- `max`/`step` drive the track, and the value is typeable inside it. A `softMax`
-- caps the track without capping the field: dragging and stepping stop there,
-- typing carries on up to `max` if there is one and without limit if there is
-- not (WeakAuras2's own softMax, which its spin box treats the same way).
-- `code` is a `multiline` for user-authored Lua: syntax-coloured per keystroke
-- unless WeakestAurasDB.codeEditorLive is turned off (/wa codelive), in which
-- case colouring waits for blur. With
-- `height`, `validate(text) -> errOrNil` (a red line under the box, re-run on
-- every keystroke -- W.LuaSyntaxError is what both call sites pass) and
-- `default` (string or function; adds a two-click-confirm Reset button that
-- seeds the box back to it, and is what a never-configured field opens at --
-- committed, not just shown, which is why a `code` field's `get` returns the
-- raw stored value rather than `... or ""`: nil means never set, "" means the
-- user cleared it and must stay cleared). The error line and Reset belong to
-- the widget (LibWidgets.NewCodeEditBox), not to this renderer.
-- `spell` renders a spell-name/ID box with a live icon preview (numeric -> its
-- spell icon); `item` is the same idea keyed by WA.ResolveItemID/GetItemInfo
-- instead. `icon` is the same box but stores a resolved texture path (a
-- spellID resolves to its icon; a raw path is kept as-is) -- the manual-icon
-- picker's stopgap input until a browsing widget lands. `opnumber` is an
-- operator dropdown + number box on one line, for
-- "stacks >= N" style filters. `menu` is a drop button whose face stays fixed
-- at `name` (it labels an action, e.g. "+ Add Display Effect") and whose entries
-- are `values`/`labels`, calling `onSelect(value)` -- one control in place of a
-- row of near-identical add buttons. `namelist` is an add/remove/reorder list of
-- plain strings (LibWidgets.NewListEditor) -- `get` returns the live backing
-- array (mutated in place), `onChange` fires after any add/remove/reorder.
-- `half` lays a field in a two-column grid: the
-- first half goes left, the next right; a full-width field or header closes the
-- row. Columns size to the page's current width.
-- Region/trigger type option generators (Regions.lua, Triggers.lua) return one
-- of these arrays per aura; OptionsFrame.lua just hands it to BuildOptions.
--
-- Repaints reuse the widgets already on the page rather than minting new ones
-- (frames can't be destroyed on this client, so the old approach leaked a page
-- of controls per tab switch) -- see the widget pool below.
--
-- `key` is redundant with get/set (BuildOptions never reads it) but is the
-- field's stable identity: get/set are closures bound to one specific `data`
-- table, so nothing outside them can tell which property a field maps to, and
-- editing a field across N selected auras at once needs that identity to match
-- "the same field" between one aura's descriptor array and another's. Every
-- settable field carries one -- tools/optionsim's key gate enforces it. The
-- conventions:
--   - the key names the property the set writes (data.<key> for region fields,
--     data.triggers[n].trigger.<key> for trigger fields); a nested path is
--     dotted ("information.ignoreOptionsEventErrors")
--   - a field writing several properties as a unit gets one coined name
--     ("message_color" for action.r/g/b)
--   - a "__" prefix names a session-local control (a search box) whose set
--     never touches aura data
--   - foldable/deletable section headers carry the section's own key
--     ("trigger:<n>", "sub:<n>:<type>", "region:<name>"), which is what
--     qualifies a field key that repeats across sections
--   - `scope = "tab"` marks a field whose identity is tab-wide rather than
--     section-local: the trailing structural add buttons, which sit after the
--     last section and would otherwise take that section's qualification and
--     stop matching between auras with different section counts
--   - `soloOnly` marks a field that never joins a merged (multi-selection)
--     array: an identity (Rename), an op whose fan-out is wrong (Delete's
--     two-click confirm), per-aura prose (warnings, provenance)
--   - `tristate` is stamped by the merge onto merged toggles alone: their nil
--     read is real disagreement and draws the indeterminate dash, where an
--     ordinary toggle's nil just means false
--   - `tooltip` ({ title, lines }) hangs a hover zone over the field's
--     caption -- the merge attaches one to a disagreeing field listing each
--     member's own value.

if WeakestAuras.disabled then return end

local WA = WeakestAuras
WA.Widgets = {}
local W = WA.Widgets
local OPTIONS_INDENT_W = 14

-- Absolute path to the vendored LibWidgets textures. The library can't discover
-- its own path (no debug library here), so callers pass it in. Handed to widgets
-- that need their own art, e.g. the drop button's menu-affordance arrow.
W.LIBWIDGETS_TEXTURES = "Interface\\AddOns\\WeakestAuras\\libs\\LibWidgets\\textures\\"
W.DUPLICATE_TEXTURE = "Interface\\AddOns\\WeakestAuras\\textures\\duplicate.tga"

function W.DeleteAction(onClick)
	return { icon = LibWidgets.ICON_DELETE, tooltip = "Delete", onClick = onClick }
end

-- Duplicate/up/down/delete for a positional list, as a header `actions` array.
-- `mutators` replaces any of the four with a handler taking (list, index); the
-- ones it omits get the plain list mutation, and `onChanged` runs after either.
--
-- A list whose *index* is addressed from outside the list must override every
-- key it can reach: the plain mutations renumber nothing, so anything holding an
-- index (data.subRegions' `sub.<n>.<key>` condition properties) silently
-- retargets at whatever moves into the slot. The bounds checks stay here so a
-- mutator never has to repeat them.
--
-- `mutators.delete = false` drops the delete action entirely, for a header that
-- already carries its own `onDelete`: that one is the arming two-click button,
-- which a plain action icon is not. `mutators.duplicate = false` drops that one
-- the same way, for a row a second copy of would be meaningless (the enforced
-- sub-region standing for the region's own art).
function W.ListActions(list, index, onChanged, mutators)
	mutators = mutators or {}
	local actions = {}
	if mutators.duplicate ~= false then
		table.insert(actions, { icon = W.DUPLICATE_TEXTURE, tooltip = "Duplicate", onClick = function()
			if mutators.duplicate then
				mutators.duplicate(list, index)
			else
				table.insert(list, index + 1, WA.DeepCopy(list[index]))
			end
			onChanged()
		end })
	end
	table.insert(actions, { icon = W.LIBWIDGETS_TEXTURES .. "up", tooltip = "Move Up", onClick = function()
		if index > 1 then
			if mutators.moveUp then
				mutators.moveUp(list, index)
			else
				list[index - 1], list[index] = list[index], list[index - 1]
			end
			onChanged()
		end
	end })
	table.insert(actions, { icon = W.LIBWIDGETS_TEXTURES .. "down", tooltip = "Move Down", onClick = function()
		if index < table.getn(list) then
			if mutators.moveDown then
				mutators.moveDown(list, index)
			else
				list[index + 1], list[index] = list[index], list[index + 1]
			end
			onChanged()
		end
	end })
	if mutators.delete ~= false then
		table.insert(actions, W.DeleteAction(function()
			if mutators.delete then
				mutators.delete(list, index)
			else
				table.remove(list, index)
			end
			onChanged()
		end))
	end
	return actions
end

-- Status bar art. The names are LibWidgets' (so every consumer offers the same
-- set); the files are this addon's, for the same no-self-path reason as above.
W.BAR_TEXTURE_DIR = "Interface\\AddOns\\WeakestAuras\\textures\\bars\\"

-- Three-state eye for the aura list's forced-visibility toggle: full / partial /
-- empty. These are the frames WA2 reads out of Interface\LFGFrame, which this
-- client does not ship -- AshenBannerLFG had to vendor its own copies for its
-- minimap eye, which is why ours are vendored too rather than pathed at the
-- stock location. Referencing that addon's copies directly would blank the
-- indicator if it were ever uninstalled, and blank is indistinguishable from
-- the empty state.
W.EYE_TEXTURES = "Interface\\AddOns\\WeakestAuras\\textures\\eye\\"

-- The code editor's fixed-width face. Same no-self-path reason as above: the
-- library can't discover its own path, so the consumer supplies it. Vendored
-- under fonts\ (not a .toc entry -- see pack.ps1's $fontsDir block).
W.CODE_FONT = "Interface\\AddOns\\WeakestAuras\\fonts\\RobotoMono.ttf"
-- RobotoMono runs large for its nominal size, so the code boxes sit well below
-- the UI's usual body size. Only the default: WeakestAurasDB.codeEditorFontSize
-- overrides it (/wa codefont <6-16>), and the widget takes it per paint.
W.CODE_FONT_SIZE = 9
-- The client's own guild-MOTD horn, 16x16 and amber, which is also what a drop
-- button's row preview draws with nothing passed -- taken from the library rather
-- than respelled so the two cannot drift apart. Shared with the `sound` warning
-- severity, so the mark that means "play this" in the picker means "this aura
-- plays one" on the aura list's row.
--
-- Spelled out as a fallback because an older LibWidgets copy can win the version
-- race and publish no such field (see LIBWIDGETS_DEV).
W.SOUND_PREVIEW_TEXTURE = LibWidgets.PREVIEW_TEXTURE
	or "Interface\\Buttons\\UI-GuildButton-MOTD-Up"

-- Falls back to the client's own bar art rather than erroring, so an older
-- LibWidgets copy winning the version race degrades a bar's *look* instead of
-- taking down the whole options paint (LibWidgetsProblem reports the real cause).
function W.BarTexturePath(name)
	if not LibWidgets.BarTexturePath then return "Interface\\TargetingFrame\\UI-StatusBar" end
	return LibWidgets.BarTexturePath(W.BAR_TEXTURE_DIR, name)
end

-- Bar textures this addon ships on top of LibWidgets' shared set. They stay
-- here rather than in LibWidgets.BAR_TEXTURES because that list is shared by
-- every addon vendoring the library, and only this one ships these files -- a
-- name added there would offer the other consumers a texture that resolves to
-- nothing.
local EXTRA_BAR_TEXTURES = {
	"Clean", "Stripes", "ThinStripes", "ThickStripes",
	"Armory", "Charcoal", "Cilo", "Comet", "Dabs", "DarkBottom",
	"Diagonal", "Frost", "Glass", "Glaze", "Glaze2", "Grid", "Hatched",
	"LiteStep", "Melli", "MelliDark", "Perl2", "Pill", "Smoothv2",
	"Steel", "Striped", "Tube", "Water", "Wglass", "Wisps", "Xeon",
}

-- LibWidgets' set plus ours, built once. Every consumer of the bar list reads
-- this rather than LibWidgets.BAR_TEXTURES directly, or the two drift.
function W.BarTextures()
	if not W.barTextures then
		W.barTextures = {}
		local shared = LibWidgets.BAR_TEXTURES or {}
		for i = 1, table.getn(shared) do
			table.insert(W.barTextures, shared[i])
		end
		for i = 1, table.getn(EXTRA_BAR_TEXTURES) do
			table.insert(W.barTextures, EXTRA_BAR_TEXTURES[i])
		end
	end
	return W.barTextures
end

-- value -> path map for a `select` field's `swatches`, built once.
function W.BarTextureSwatches()
	if not W.barSwatches then
		W.barSwatches = {}
		local list = W.BarTextures()
		for i = 1, table.getn(list) do
			W.barSwatches[list[i]] = W.BarTexturePath(list[i])
		end
	end
	return W.barSwatches
end

-- The LibWidgets surface this file is written against. Every addon vendoring
-- the library shares one global instance and the highest MINOR wins, so another
-- addon's older copy can be the one actually running here -- in which case the
-- first symptom is a nil call in the middle of a repaint, naming a function
-- rather than the version problem behind it. Check it once at load and record
-- what's missing; the options window reports it on open and `/wa libs` dumps
-- it (chat output at file-load time is unreliable on this client, so nothing is
-- printed from here). libs\LibWidgetsDev.lua is the escape hatch.
W.LIBWIDGETS_REQUIRED = {
	"NewButton", "NewIconButton", "NewCheckBox", "NewColorSwatch", "NewTextBox",
	"NewMultiLineEditBox", "NewScrollFrame", "NewScrollBar", "NewSpinBox", "NewDropButton",
	"NewListEditor", "NewIconPicker", "GetIconDatabase", "CloseAllMenus", "ClearFocus",
	"FormatNumber", "BarTexturePath",
	"LuaColorize", "LuaEncode", "LuaDecode", "LuaStripColors",
	"LuaPadWithLinebreaks", "LuaNextToken", "NewCodeEditBox", "NewAnchorGrid",
}
W.libWidgetsMissing = {}
for i = 1, table.getn(W.LIBWIDGETS_REQUIRED) do
	local name = W.LIBWIDGETS_REQUIRED[i]
	if not LibWidgets[name] then table.insert(W.libWidgetsMissing, name) end
end

-- One line describing which LibWidgets copy is live, or nil when it's fine.
function W.LibWidgetsProblem()
	if table.getn(W.libWidgetsMissing) == 0 then return nil end
	return "LibWidgets in use is MINOR " .. tostring(LibWidgets.MINOR or "?")
		.. " and is missing " .. table.concat(W.libWidgetsMissing, ", ")
		.. " -- another addon's older copy won the LibStub version race."
end

W.PANEL_BACKDROP = {
	bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
	edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
	tile = true, tileSize = 32, edgeSize = 16,
	insets = { left = 5, right = 5, top = 5, bottom = 5 },
}
W.EDITBOX_BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 9,
	insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- ---------------------------------------------------------------------------
-- Base controls
--
-- Thin adapters over LibWidgets.New* (libs\LibWidgets) for the panel's own
-- chrome -- the controls that are built once and live for the session (search
-- box, tab strip, the buttons around the aura list). Everything inside the
-- options page itself goes through the pooled builders further down instead.
-- New *generic* controls belong in LibWidgets, not here.
-- ---------------------------------------------------------------------------

-- A live-filter edit box: fires onChange(text) on every keystroke and shows a
-- greyed "Search" hint while empty. Escape clears the text (not just focus),
-- which the shared NewTextBox leaves to the caller.
function W.searchbox(parent, width, onChange)
	local e = LibWidgets.NewTextBox(parent, { width = width, height = 20, hint = "Search", onChange = onChange })
	e:SetScript("OnEscapePressed", function() this:SetText(""); this:ClearFocus() end)
	return e
end

function W.sectionHeader(parent, text)
	local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	fs:SetJustifyH("LEFT")
	fs:SetText(text)
	fs:SetTextColor(1, 0.82, 0)
	return fs
end

function W.fieldLabel(parent, text)
	local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	fs:SetJustifyH("LEFT")
	fs:SetText(text)
	return fs
end

function W.button(parent, text, onClick)
	return LibWidgets.NewButton(parent, { text = text, onClick = onClick })
end

-- Icon-only toolbar button. Mirrors WA2's WeakAurasToolbarButton, minus the
-- text label: its toolbar sits over a left column that grows with the window
-- (~290px at that addon's default size), ours over one fixed at 200, which has
-- room for icons and tooltips only.
--
-- setToggled marks the buttons standing for a persistent mode rather than a
-- one-shot action, matching the strong-highlight state upstream gives Lock
-- Positions and Magnetically Align.
-- `label`, when given, puts the caption beside the icon and widens the button to
-- fit it; without one the button stays the 22px square the icon fills. The
-- tooltip is kept either way -- it carries the second explanatory line a caption
-- has no room for.
function W.toolbarButton(parent, icon, tooltip, onClick, label)
	local b = CreateFrame("Button", nil, parent)
	b:SetWidth(22); b:SetHeight(22)

	local on = b:CreateTexture(nil, "BACKGROUND")
	on:SetAllPoints(b)
	on:SetTexture(0.9, 0.8, 0.2, 0.25)
	on:Hide()

	-- 16px hard-sized and pinned left rather than inset from both corners: the
	-- two agree exactly on an unlabelled 22px button, and only this form survives
	-- the button growing to fit a caption.
	local tex = b:CreateTexture(nil, "ARTWORK")
	tex:SetWidth(16); tex:SetHeight(16)
	tex:SetPoint("LEFT", b, "LEFT", 3, 0)
	tex:SetTexture(icon)
	b.icon = tex

	if label then
		local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		fs:SetPoint("LEFT", tex, "RIGHT", 4, 0)
		fs:SetJustifyH("LEFT")
		fs:SetText(label)
		b.label = fs
		b:SetWidth(3 + 16 + 4 + (fs:GetStringWidth() or 0) + 6)
	end

	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints(b)
	hl:SetTexture(1, 1, 1, 0.15)

	function b.setToggled(v)
		b.toggled = v and true or false
		if b.toggled then on:Show() else on:Hide() end
	end

	b:SetScript("OnEnter", function()
		GameTooltip:SetOwner(this, "ANCHOR_NONE")
		GameTooltip:SetPoint("BOTTOMLEFT", this, "TOPLEFT", 0, 4)
		GameTooltip:SetText(this.tipTitle or "", 1, 1, 1)
		if this.tipDesc then GameTooltip:AddLine(this.tipDesc, 0.8, 0.8, 0.8, true) end
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	b.tipTitle = tooltip
	if onClick then b:SetScript("OnClick", onClick) end
	return b
end

local QUESTION_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- The `disclosure` field's glyph. A stock item icon rather than vendored art:
-- 1.12 ships no gear in Interface\Buttons, and this one (Charged Gear, from
-- Gnomeregan) is a single cog that stays legible shrunk to a 9px button face.
local GEAR_ICON = "Interface\\Icons\\INV_Misc_Gear_01"

-- One shared icon-browser dialog behind every `icon` field's Browse button.
-- Built on first use, not at load: LibWidgets.GetIconDatabase's first call walks
-- the client's whole icon set, which is not worth paying for unless the user
-- actually opens the picker. The pick is routed through a stored callback rather
-- than rebuilding the dialog per field.
function W.OpenIconPicker(current, onPick)
	if not LibWidgets.NewIconPicker then
		DEFAULT_CHAT_FRAME:AddMessage("|cffff4040WeakestAuras:|r "
			.. (W.LibWidgetsProblem() or "the loaded LibWidgets has no NewIconPicker."))
		return
	end
	if not W.iconPicker then
		W.iconPicker = LibWidgets.NewIconPicker(UIParent, {
			nameFrame = "WeakestAurasIconPicker",
			title = "Select Icon",
			onAccept = function(path)
				if W.onIconPicked then W.onIconPicked(path) end
			end,
		})
	end
	W.onIconPicked = onPick
	W.iconPicker.Open(current)
end

local TEXTURE_PATH_PREFIX = "Interface\\AddOns\\WeakestAuras\\textures\\"
local TEXTURE_CATEGORIES = {
	Shapes = {
		"arrows_target.tga", "Circle_AlphaGradient_In.tga", "Circle_AlphaGradient_Out.tga", "circle_border5.tga",
		"Circle_Smooth.tga", "Circle_Smooth2.tga", "Circle_Smooth_Border.tga", "Circle_Squirrel.tga", "Circle_Squirrel_Border.tga",
		"Circle_White.tga", "Circle_White_Border.tga", "Ring_10px.tga", "Ring_20px.tga", "Ring_30px.tga", "Ring_40px.tga",
		"ring_glow3.tga", "Square_AlphaGradient.tga", "square_border_10px.tga", "square_border_1px.tga", "square_border_5px.tga",
		"Square_FullWhite.tga", "square_mini.tga", "Square_Smooth.tga", "Square_Smooth_Border.tga", "Square_Squirrel.tga",
		"Square_Squirrel_Border.tga", "Square_White.tga", "Square_White_Border.tga", "target_indicator.tga",
		"target_indicator_glow.tga", "Trapezoid.tga", "triangle-border.tga", "triangle.tga", "Triangle45.tga",
	},
	Alerts = {
		"ArcaneMissiles.blp", "ArcaneMissiles1.blp", "ArcaneMissiles2.blp", "ArcaneMissiles3.blp", "ArcaneSoul.blp",
		"ArtOfWar.blp", "BacklashGreen.blp", "Backslash.blp", "BanditsGuile.blp", "Berserk.blp",
		"BloodBoil.blp", "BloodSurge.blp", "BrainFreeze.blp", "DarkTiger.blp", "DarkTransformation.blp", "Daybreak.blp",
		"DemonicCore.blp", "DemonicCoreVertical.blp", "Denounce.blp", "EchoOfTheElements.blp", "EclipseMoon.blp", "EclipseSun.blp",
		"EssenceBurst.blp", "FocusFire.blp", "FrozenFingers.blp", "Fulmination.blp", "FuryOfStormrage.blp", "GenericArc1.blp",
		"GenericArc2.blp", "GenericArc3.blp", "GenericArc4.blp", "GenericArc5.blp", "GenericArc6.blp", "GenericTop1.blp",
		"GenericTop2.blp", "GrandCrusader.blp", "HandOfLight.blp", "HighTide.blp", "HotStreak.blp", "Hyperthermia.blp",
		"ImpEmpowerment.blp", "ImpEmpowermentGreen.blp", "Impact.blp", "KillingMachine.blp", "LockAndLoad.blp", "MaelstromWeapon.blp",
		"MaelstromWeapon1.blp", "MaelstromWeapon2.blp", "MaelstromWeapon3.blp", "MaelstromWeapon4.blp", "MasterMarksman.blp",
		"MoltenCore.blp", "MonkBlackoutKick.blp", "MonkOx.blp", "MonkOx2.blp", "MonkOx3.blp", "MonkSerpent.blp",
		"MonkTiger.blp", "MonkTigerPalm.blp", "NatureSGrace.blp", "Necropolis.blp", "Nightfall.blp", "PredatorySwiftness.blp",
		"OmenOfClarityFeral.blp", "PredatorySwiftnessGreen.blp", "RagingBlow.blp", "Rime.blp", "Serendipity.blp", "ShadowOfDeath.blp",
		"ShadowWordInsanity.blp", "ShootingStars.blp",
		"SliceAndDice.blp", "Snapfire.blp", "SuddenDeath.blp", "SuddenDoom.blp", "SurgeOfDarkness.blp", "SurgeOfLight.blp",
		"SpellActivationOverlay0.blp", "SwordAndBoard.blp", "ThrillOfTheHunt1.blp", "ThrillOfTheHunt2.blp", "ThrillOfTheHunt3.blp", "ToothAndClaw.blp",
		"Ultimatum.blp", "WhiteTiger.blp",
	},
	-- Power Auras art, split the four ways upstream splits it. Every name here
	-- also has to be reachable from WA2Import's rewrite of an incoming
	-- PowerAurasMedia\Auras path, which looks the basename up in this table --
	-- so a file dropped from here stops resolving on import as well as in the
	-- picker. Aura146-246 exist upstream of WeakAuras2 but not in it, and are
	-- not bundled: see textures/README.md.
	PowerAurasHeadsUp = {
		"Aura1.tga", "Aura2.tga", "Aura3.tga", "Aura4.tga", "Aura5.tga", "Aura6.tga", "Aura7.tga",
		"Aura11.tga", "Aura16.tga", "Aura17.tga", "Aura18.tga", "Aura23.tga", "Aura24.tga", "Aura28.tga",
		"Aura33.tga",
	},
	PowerAurasIcons = {
		"Aura8.tga", "Aura9.tga", "Aura10.tga", "Aura12.tga", "Aura13.tga", "Aura14.tga", "Aura15.tga",
		"Aura19.tga", "Aura21.tga", "Aura22.tga", "Aura25.tga", "Aura26.tga", "Aura27.tga", "Aura29.tga",
		"Aura30.tga", "Aura31.tga", "Aura32.tga", "Aura34.tga", "Aura35.tga", "Aura36.tga", "Aura45.tga",
		"Aura48.tga", "Aura49.tga", "Aura50.tga", "Aura51.tga", "Aura52.tga", "Aura53.tga", "Aura54.tga",
		"Aura68.tga", "Aura69.tga", "Aura70.tga", "Aura71.tga", "Aura72.tga", "Aura73.tga", "Aura74.tga",
		"Aura75.tga", "Aura76.tga", "Aura77.tga", "Aura78.tga", "Aura79.tga", "Aura84.tga", "Aura85.tga",
		"Aura86.tga", "Aura87.tga", "Aura88.tga", "Aura95.tga", "Aura96.tga", "Aura97.tga", "Aura98.tga",
		"Aura99.tga", "Aura100.tga", "Aura101.tga", "Aura102.tga", "Aura103.tga", "Aura110.tga",
		"Aura111.tga", "Aura112.tga", "Aura113.tga", "Aura114.tga", "Aura115.tga", "Aura116.tga",
		"Aura117.tga", "Aura118.tga", "Aura119.tga", "Aura120.tga", "Aura130.tga", "Aura131.tga",
		"Aura132.tga", "Aura138.tga", "Aura139.tga", "Aura140.tga", "Aura141.tga", "Aura142.tga",
		"Aura143.tga",
	},
	PowerAurasSeparated = {
		"Aura46.tga", "Aura47.tga", "Aura55.tga", "Aura56.tga", "Aura57.tga", "Aura58.tga", "Aura59.tga",
		"Aura60.tga", "Aura61.tga", "Aura62.tga", "Aura63.tga", "Aura64.tga", "Aura65.tga", "Aura66.tga",
		"Aura67.tga", "Aura80.tga", "Aura81.tga", "Aura82.tga", "Aura83.tga", "Aura89.tga", "Aura90.tga",
		"Aura91.tga", "Aura92.tga", "Aura93.tga", "Aura94.tga", "Aura104.tga", "Aura105.tga", "Aura106.tga",
		"Aura107.tga", "Aura108.tga", "Aura109.tga", "Aura121.tga", "Aura122.tga", "Aura123.tga",
		"Aura124.tga", "Aura125.tga", "Aura126.tga", "Aura127.tga", "Aura128.tga", "Aura129.tga",
		"Aura133.tga", "Aura134.tga", "Aura135.tga", "Aura136.tga", "Aura137.tga", "Aura144.tga",
		"Aura145.tga",
	},
	PowerAurasWords = {
		"Aura20.tga", "Aura37.tga", "Aura38.tga", "Aura39.tga", "Aura40.tga", "Aura41.tga", "Aura42.tga",
		"Aura43.tga", "Aura44.tga",
	},
}
WA.textureTypes = TEXTURE_CATEGORIES

-- All four Power Auras categories draw from one folder, so the category name
-- cannot be lowercased into the path the way Shapes and Alerts are.
local TEXTURE_CATEGORY_DIRS = {
	PowerAurasHeadsUp = "powerauras", PowerAurasIcons = "powerauras",
	PowerAurasSeparated = "powerauras", PowerAurasWords = "powerauras",
}
local TEXTURE_CATEGORY_VALUES = {
	"Alerts", "Shapes",
	"PowerAurasHeadsUp", "PowerAurasIcons", "PowerAurasSeparated", "PowerAurasWords",
}
local TEXTURE_CATEGORY_LABELS = {
	Alerts = "Blizzard Alerts", Shapes = "Shapes",
	PowerAurasHeadsUp = "Power Auras: Heads-Up", PowerAurasIcons = "Power Auras: Icons",
	PowerAurasSeparated = "Power Auras: Separated", PowerAurasWords = "Power Auras: Words",
}

-- Full path to one bundled texture. Public because WA2Import builds its rewrite
-- index off WA.textureTypes and has to form the same paths the picker stores.
function W.TexturePath(category, name)
	local dir = TEXTURE_CATEGORY_DIRS[category] or string.lower(category)
	return TEXTURE_PATH_PREFIX .. dir .. "\\" .. name
end
local texturePath = W.TexturePath

-- lowercased file name -> the category holding it, for the categories whose
-- folder does not name them. Built on first use, since the four Power Auras
-- lists share one folder and the path alone cannot say which tab to open on.
local powerAurasCategory
local function powerAurasCategoryFor(name)
	if not powerAurasCategory then
		powerAurasCategory = {}
		for i = 1, table.getn(TEXTURE_CATEGORY_VALUES) do
			local category = TEXTURE_CATEGORY_VALUES[i]
			if TEXTURE_CATEGORY_DIRS[category] == "powerauras" then
				local list = TEXTURE_CATEGORIES[category]
				for j = 1, table.getn(list) do
					powerAurasCategory[string.lower(list[j])] = category
				end
			end
		end
	end
	return powerAurasCategory[string.lower(name or "")]
end

function W.OpenTexturePicker(current, onPick)
	if not LibWidgets.NewIconPicker then
		DEFAULT_CHAT_FRAME:AddMessage("|cffff4040WeakestAuras:|r "
			.. (W.LibWidgetsProblem() or "the loaded LibWidgets has no texture picker support."))
		return
	end
	if not W.texturePicker then
		W.texturePicker = LibWidgets.NewIconPicker(UIParent, {
			nameFrame = "WeakestAurasTexturePicker",
			title = "Select Texture",
			categories = TEXTURE_CATEGORIES,
			categoryValues = TEXTURE_CATEGORY_VALUES,
			categoryLabels = TEXTURE_CATEGORY_LABELS,
			defaultCategory = "Shapes",
			pathFor = function(name, category) return texturePath(category or "Shapes", name) end,
			normalize = function(value)
				local _, _, name = string.find(string.lower(value or ""), "textures\\[^\\]+\\([^\\]+)$")
				return name or value
			end,
			categoryFor = function(value)
				local lower = string.lower(value or "")
				if string.find(lower, "textures\\alerts\\", 1, true) then return "Alerts" end
				if string.find(lower, "textures\\powerauras\\", 1, true) then
					local _, _, name = string.find(lower, "([^\\]+)$")
					return powerAurasCategoryFor(name) or "PowerAurasIcons"
				end
				return "Shapes"
			end,
			labelFor = function(name) return name end,
			onAccept = function(path)
				if W.onTexturePicked then W.onTexturePicked(path) end
			end,
		})
	end
	W.onTexturePicked = onPick
	W.texturePicker.Open(current)
end

function W.CloseTexturePicker()
	if W.texturePicker then W.texturePicker.Close() end
end

function W.CloseIconPicker()
	if W.iconPicker then W.iconPicker.Close() end
end

-- ---------------------------------------------------------------------------
-- Model browser
--
-- The icon and texture pickers browse art a grid cell can paint; a model
-- cannot be painted into a tile, so this is a name list beside one live
-- PlayerModel preview. Fed from WA2ModelIDs.lua's packed string -- the models
-- this client provably contains -- indexed per top directory on first open, so
-- a session that never browses pays nothing.
-- ---------------------------------------------------------------------------

local MODEL_CATEGORY_VALUES = { "creature", "spells", "character", "item", "world", "interface", "particles" }
local MODEL_CATEGORY_LABELS = {
	creature = "Creatures", spells = "Spells", character = "Characters",
	item = "Items", world = "World", interface = "Interface", particles = "Particles",
}

local modelIndex
local function modelListFor(category)
	if not modelIndex then
		modelIndex = {}
		for i = 1, table.getn(MODEL_CATEGORY_VALUES) do
			modelIndex[MODEL_CATEGORY_VALUES[i]] = {}
		end
		for path in string.gfind(WA.wa2ModelIDs or "", "%d+,([^;]+)") do
			local _, _, top, rest = string.find(path, "^([^/]+)/(.+)$")
			local list = top and modelIndex[top]
			if list then table.insert(list, rest) end
		end
		for i = 1, table.getn(MODEL_CATEGORY_VALUES) do
			table.sort(modelIndex[MODEL_CATEGORY_VALUES[i]])
		end
	end
	return modelIndex[category] or {}
end

-- The stored form: backslashes and the .mdx spelling SetModel provably takes.
local function modelPickPath(category, rest)
	return string.gsub(category .. "/" .. rest, "/", "\\") .. ".mdx"
end

-- The stored form back to (category, rest), for opening the dialog on the
-- model already in use. nil for a path outside the indexed trees.
local function modelPickParse(value)
	if type(value) ~= "string" or value == "" then return nil end
	local low = string.lower(string.gsub(value, "\\", "/"))
	low = string.gsub(low, "%.md[xl]$", "")
	low = string.gsub(low, "%.m2$", "")
	local _, _, top, rest = string.find(low, "^([^/]+)/(.+)$")
	if top and MODEL_CATEGORY_LABELS[top] then return top, rest end
	return nil
end

local MODEL_ROWS = 14
local MODEL_ROW_H = 16

local function buildModelPicker()
	local scrollName = "WeakestAurasModelPickerScroll"
	local pad = 10
	local listW, previewW = 290, 200
	local listH = MODEL_ROWS * MODEL_ROW_H + 8

	local frame = CreateFrame("Frame", "WeakestAurasModelPickerDialog", UIParent)
	frame:SetWidth(listW + previewW + pad * 3)
	frame:SetHeight(listH + 124)
	frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	frame:SetBackdrop(W.EDITBOX_BACKDROP)
	frame:SetBackdropColor(0, 0, 0, 0.92)
	frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.9)
	frame:SetFrameStrata("FULLSCREEN_DIALOG")
	frame:SetToplevel(true)
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function() this:StartMoving() end)
	frame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
	frame:SetScript("OnMouseDown", function() LibWidgets.CloseAllMenus() end)
	frame:SetScript("OnHide", function() LibWidgets.CloseAllMenus() end)
	frame:Hide()

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", pad, -pad)
	title:SetText("Select Model")

	local count = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	count:SetPoint("TOPRIGHT", -pad, -pad - 2)
	count:SetJustifyH("RIGHT")

	local selectedCategory, selectedRest = "spells", nil
	local filtered = {}
	local refresh, applyFilter

	local search = LibWidgets.NewTextBox(frame, {
		width = 150, height = 20, hint = "Search",
		onChange = function(text) applyFilter(text) end,
	})
	search:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -pad, -pad - 22)
	search:SetScript("OnEscapePressed", function() this:SetText(""); this:ClearFocus() end)

	local categoryButton = LibWidgets.NewDropButton(frame, {
		values = MODEL_CATEGORY_VALUES,
		labels = MODEL_CATEGORY_LABELS,
		width = 130, height = 20,
		menuParent = frame,
		get = function() return selectedCategory end,
		onSelect = function(value)
			selectedCategory = value
			selectedRest = nil
			applyFilter(search:GetText() or "")
		end,
	})
	categoryButton:SetPoint("TOPLEFT", frame, "TOPLEFT", pad, -pad - 22)

	local list = CreateFrame("Frame", nil, frame)
	list:SetPoint("TOPLEFT", pad, -pad - 48)
	list:SetWidth(listW)
	list:SetHeight(listH)
	list:SetBackdrop(W.EDITBOX_BACKDROP)
	list:SetBackdropColor(0, 0, 0, 0.5)
	list:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)

	local scroll = CreateFrame("ScrollFrame", scrollName, list, "FauxScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", list, "TOPLEFT", 4, -4)
	scroll:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", -22, 4)

	-- The live preview. Configuration rides wa* fields plus an OnShow
	-- re-apply, because a hidden model drops its geometry.
	local previewBox = CreateFrame("Frame", nil, frame)
	previewBox:SetPoint("TOPLEFT", list, "TOPRIGHT", pad, 0)
	previewBox:SetWidth(previewW)
	previewBox:SetHeight(listH)
	previewBox:SetBackdrop(W.EDITBOX_BACKDROP)
	previewBox:SetBackdropColor(0, 0, 0, 0.5)
	previewBox:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
	local previewApply = function(model)
		if model.waPath then
			-- A known creature entry textures the preview; the raw path is
			-- the white fallback (skins live in CreatureDisplayInfo, which
			-- SetModel never consults).
			local entry = WA.ResolveCreatureEntry(model.waPath)
			if entry and model.SetCreature then
				pcall(model.SetCreature, model, entry)
			else
				pcall(model.SetModel, model, model.waPath)
			end
			pcall(model.SetPosition, model, 0, 0, 0)
			pcall(model.SetFacing, model, 0)
		else
			pcall(model.ClearModel, model)
		end
	end
	local preview
	local ok, built = pcall(CreateFrame, "PlayerModel", nil, previewBox)
	if ok and built then
		preview = built
		preview:SetPoint("TOPLEFT", previewBox, "TOPLEFT", 4, -4)
		preview:SetPoint("BOTTOMRIGHT", previewBox, "BOTTOMRIGHT", -4, 4)
		preview:SetScript("OnShow", function() previewApply(this) end)
		-- The model renders where the frame sat at apply time and does not
		-- follow a later move (Regions.lua's modelOnUpdate documents the
		-- quirk), so re-apply when the dialog stops moving.
		preview:SetScript("OnUpdate", function()
			local left, top = this:GetLeft(), this:GetTop()
			if left ~= this.waLeft or top ~= this.waTop then
				this.waLeft, this.waTop = left, top
				this.waMoved = left and true or nil
			elseif this.waMoved then
				this.waMoved = nil
				previewApply(this)
			end
		end)
	end
	local previewLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	previewLabel:SetPoint("TOPLEFT", previewBox, "BOTTOMLEFT", 2, -4)
	previewLabel:SetPoint("TOPRIGHT", previewBox, "BOTTOMRIGHT", -2, -4)
	previewLabel:SetJustifyH("LEFT")

	local function setPreview(rest)
		if preview then
			preview.waPath = rest and modelPickPath(selectedCategory, rest) or nil
			previewApply(preview)
		end
		previewLabel:SetText(rest or "")
	end

	local rows = {}
	local function rowAt(i)
		local r = rows[i]
		if r then return r end
		r = CreateFrame("Button", nil, list)
		r:SetWidth(listW - 30)
		r:SetHeight(MODEL_ROW_H)
		r:SetPoint("TOPLEFT", list, "TOPLEFT", 6, -4 - (i - 1) * MODEL_ROW_H)
		local hl = r:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints(r)
		hl:SetTexture(1, 0.82, 0, 0.2)
		local fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetPoint("LEFT", 2, 0)
		fs:SetPoint("RIGHT", -2, 0)
		fs:SetJustifyH("LEFT")
		r.text = fs
		r:SetScript("OnClick", function()
			LibWidgets.CloseAllMenus()
			if not this.rest then return end
			selectedRest = this.rest
			setPreview(selectedRest)
			refresh()
		end)
		rows[i] = r
		return r
	end

	refresh = function()
		local n = table.getn(filtered)
		FauxScrollFrame_Update(scroll, n, MODEL_ROWS, MODEL_ROW_H)
		local offset = FauxScrollFrame_GetOffset(scroll)
		for i = 1, MODEL_ROWS do
			local r = rowAt(i)
			local rest = filtered[offset + i]
			if rest then
				r.rest = rest
				r.text:SetText(rest)
				if rest == selectedRest then
					r.text:SetTextColor(1, 0.82, 0)
				else
					r.text:SetTextColor(1, 1, 1)
				end
				r:Show()
			else
				r.rest = nil
				r:Hide()
			end
		end
		count:SetText(n .. (n == 1 and " model" or " models"))
	end

	applyFilter = function(text)
		local all = modelListFor(selectedCategory)
		filtered = {}
		if not text or text == "" then
			for i = 1, table.getn(all) do filtered[i] = all[i] end
		else
			local needle = string.lower(text)
			for i = 1, table.getn(all) do
				if string.find(all[i], needle, 1, true) then table.insert(filtered, all[i]) end
			end
		end
		local bar = getglobal(scrollName .. "ScrollBar")
		if bar then bar:SetValue(0) end
		setPreview(selectedRest)
		refresh()
	end

	scroll:SetScript("OnVerticalScroll", function()
		FauxScrollFrame_OnVerticalScroll(MODEL_ROW_H, refresh)
	end)
	local function wheel()
		local bar = getglobal(scrollName .. "ScrollBar")
		if bar then bar:SetValue(bar:GetValue() - arg1 * MODEL_ROW_H * 3) end
	end
	scroll:EnableMouseWheel(true); scroll:SetScript("OnMouseWheel", wheel)
	list:EnableMouseWheel(true); list:SetScript("OnMouseWheel", wheel)

	local function scrollToSelected()
		if not selectedRest then return end
		for i = 1, table.getn(filtered) do
			if filtered[i] == selectedRest then
				local bar = getglobal(scrollName .. "ScrollBar")
				if bar then
					local target = (i - 1 - math.floor(MODEL_ROWS / 2)) * MODEL_ROW_H
					local lo, hi = bar:GetMinMaxValues()
					if target < lo then target = lo elseif target > hi then target = hi end
					bar:SetValue(target)
				end
				return
			end
		end
	end

	local cancel = LibWidgets.NewButton(frame, {
		text = "Cancel", width = 90,
		onClick = function() frame.Close() end,
	})
	cancel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -pad, pad)

	local accept = LibWidgets.NewButton(frame, {
		text = "Okay", width = 90,
		onClick = function()
			local category, rest = selectedCategory, selectedRest
			frame.Close()
			if rest and W.onModelPicked then W.onModelPicked(modelPickPath(category, rest)) end
		end,
	})
	accept:SetPoint("RIGHT", cancel, "LEFT", -6, 0)

	function frame.Open(current)
		local category, rest = modelPickParse(current)
		if category then
			selectedCategory, selectedRest = category, rest
		else
			selectedRest = nil
		end
		search:SetText("")
		applyFilter("")
		scrollToSelected()
		setPreview(selectedRest)
		refresh()
		frame:Show()
	end

	function frame.Close()
		LibWidgets.CloseAllMenus()
		search:ClearFocus()
		frame:Hide()
	end

	if UISpecialFrames then table.insert(UISpecialFrames, "WeakestAurasModelPickerDialog") end

	frame.search = search
	frame.categoryButton = categoryButton
	frame.accept = accept
	frame.rows = rows
	frame.preview = preview

	return frame
end

-- One shared dialog behind the model region's Browse button, same shape as
-- the icon picker's: built on first use, pick routed through a stored
-- callback rather than rebuilding per field.
function W.OpenModelPicker(current, onPick)
	if not (LibWidgets.NewTextBox and LibWidgets.NewDropButton and LibWidgets.NewButton) then
		DEFAULT_CHAT_FRAME:AddMessage("|cffff4040WeakestAuras:|r "
			.. (W.LibWidgetsProblem() or "the loaded LibWidgets is missing the controls the model browser needs."))
		return
	end
	if not W.modelPicker then W.modelPicker = buildModelPicker() end
	W.onModelPicked = onPick
	W.modelPicker.Open(current)
end

function W.CloseModelPicker()
	if W.modelPicker then W.modelPicker.Close() end
end
-- Comparison operators offered by opnumber fields; the same set the runtime
-- cmp() in TriggerAura understands.
W.OPERATORS = { "==", "~=", "<", "<=", ">", ">=" }

-- Compiles `source` and returns "line N: message", or nil when it parses --
-- the `validate` hook a user-authored-Lua field hands to BuildOptions.
--
-- `chunkName` is what Lua puts inside the error's `[string "..."]:LINE:`
-- prefix, so keeping it short and caller-supplied makes stripping that prefix a
-- plain (non-pattern) find instead of a pattern that would have to survive
-- whatever the user typed. Callers that wrap the body ("return " .. body) must
-- use a prefix containing **no newline**, or every reported line is off by one.
function W.LuaSyntaxError(source, chunkName)
	local chunk, err = loadstring(source or "", chunkName or "code")
	if chunk then return nil end
	if not err then return "syntax error" end
	-- Lua 5.0 error strings are `[string "name"]:LINE: message`. Take the last
	-- "]:" so a chunk name containing one can't cut the prefix short.
	local last, from = nil, 1
	while true do
		local s, e = string.find(err, "]:", from, true)
		if not s then break end
		last = e
		from = s + 1
	end
	if not last then return err end
	local rest = string.sub(err, last + 1)
	if string.find(rest, "^%d+") then return "line " .. rest end
	return rest
end

local EMPTY = {}

-- ---------------------------------------------------------------------------
-- Widget pool
--
-- Frames can't be destroyed on this client, so a repaint that minted a fresh
-- widget per field and merely hid the previous set leaked a full page of
-- controls on every tab/aura switch -- and not cheaply: a single dropdown
-- brings a popup frame, a scroll frame and one button per menu entry with it,
-- and the slider and list editor each burn a unique *global* frame name per
-- instance (their Blizzard templates address child frames by name).
--
-- Widgets are therefore acquired from a per-kind free list kept on the page and
-- rebound to whatever field is being painted. Each pooled widget is built once
-- around a `bind` table this file owns, and every callback handed to LibWidgets
-- is an indirection that reads the current binding out of it -- so rebinding is
-- just overwriting `bind` fields, with no library-side support needed.
--
-- `kind` folds in any parameter a widget can only take at construction (a
-- dropdown's width, a list editor's visible row count), so an instance is only
-- ever reused where those still hold.
-- ---------------------------------------------------------------------------

local function acquire(page, kind, create)
	local pool = page.widgetPools[kind]
	if not pool then pool = {}; page.widgetPools[kind] = pool end
	local n = (page.widgetUsed[kind] or 0) + 1
	page.widgetUsed[kind] = n
	local w = pool[n]
	if not w then
		w = create()
		pool[n] = w
	end
	w:ClearAllPoints()
	w:Show()
	return w
end

local function poolLabel(page, text)
	local fs = acquire(page, "label", function() return W.fieldLabel(page, "") end)
	fs:SetText(text or "")
	return fs
end

-- A wrapping explanatory line under a field. Pooled apart from `label` because
-- it carries a wrap width, which a plain label reused from the same pool would
-- inherit and then wrap inside its own row.
local function poolDescription(page, text, width)
	local fs = acquire(page, "desc", function()
		local f = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		f:SetJustifyH("LEFT")
		f:SetTextColor(0.6, 0.6, 0.6)
		return f
	end)
	fs:SetWidth(width)
	fs:SetText(text or "")
	return fs
end

local function poolHeaderLabel(page, text)
	local fs = acquire(page, "headerlabel", function() return W.sectionHeader(page, "") end)
	fs:SetText(text or "")
	return fs
end

local function poolRule(page)
	return acquire(page, "rule", function()
		local t = page:CreateTexture(nil, "ARTWORK")
		t:SetHeight(1)
		t:SetTexture(0.9, 0.75, 0.2, 0.45)
		return t
	end)
end

-- The 18px spell/item/icon preview swatch beside a text field.
local function poolPreviewIcon(page)
	return acquire(page, "previewicon", function()
		local t = page:CreateTexture(nil, "OVERLAY")
		t:SetWidth(18); t:SetHeight(18)
		t:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		return t
	end)
end

local function poolCheck(page, text, onClick, get, tristate)
	local cb = acquire(page, "check", function()
		local bind = {}
		local w = LibWidgets.NewCheckBox(page, {
			onClick = function(v) if bind.onClick then bind.onClick(v) end end,
		})
		w.bind = bind
		return w
	end)
	cb.bind.onClick = onClick
	cb.label:SetText(text or "")
	-- Only a field that declares `tristate` (a mass-edit merged toggle) shows
	-- the indeterminate dash on nil -- an ordinary field's get returning nil
	-- just means false, and a dash there would read as disagreement where
	-- there is none.
	local v = get and get()
	if not tristate then v = v and true or false end
	cb.setChecked(v)
	return cb
end

-- Shift-clicking an item drops its link into whichever field is focused and has
-- asked for links (the item fields). `HandleModifiedItemClick` is the real entry
-- point on this client -- it forwards to `ChatEdit_InsertLink` only while the
-- *chat* edit box is visible, so wrapping `ChatEdit_InsertLink` alone never sees
-- a link bound for one of ours. Both are wrapped: the second still carries a
-- link clicked in chat, which arrives there directly. Quartermaster's config
-- intercepts the same pair for the same reason.
local linkSink

-- The itemID is stored rather than the link or the name: an id always resolves,
-- where a name has to be found in the player's bags first. The readable name
-- comes back through the trigger's own nameFunc, so nothing is lost on screen.
local function routeLink(text)
	if not text or not linkSink or not linkSink:IsVisible() then return false end
	local _, _, id = string.find(text, "item:(%d+)")
	if not id then return false end
	linkSink:SetText(id)
	linkSink:SetFocus()
	if linkSink.bind and linkSink.bind.onCommit then linkSink.bind.onCommit(id) end
	return true
end

local origModifiedClick = HandleModifiedItemClick
function HandleModifiedItemClick(link)
	if link and IsModifiedClick("CHATLINK") and routeLink(link) then return true end
	if origModifiedClick then return origModifiedClick(link) end
end

local origInsertLink = ChatEdit_InsertLink
function ChatEdit_InsertLink(text)
	if routeLink(text) then return true end
	if origInsertLink then return origInsertLink(text) end
	return false
end

local function poolEditBox(page, width, onCommit)
	local e = acquire(page, "editbox", function()
		local bind = {}
		local w = LibWidgets.NewTextBox(page, {
			height = 20,
			onCommit = function(t) if bind.onCommit then bind.onCommit(t) end end,
		})
		w.bind = bind
		-- Chained, not replaced: the library's own handler closes open menus.
		local origFocus = w:GetScript("OnEditFocusGained")
		w:SetScript("OnEditFocusGained", function()
			if origFocus then origFocus() end
			linkSink = this.acceptsLinks and this or nil
		end)
		w:SetScript("OnEditFocusLost", function()
			if linkSink == this then linkSink = nil end
		end)
		return w
	end)
	e.bind.onCommit = onCommit
	-- One pool serves every field, so a box that last served an item field must
	-- not keep accepting links on behalf of the next one.
	e.acceptsLinks = false
	e:SetWidth(width)
	-- A reused box may still hold focus from the edit that triggered this
	-- repaint; its text is about to be replaced under the cursor either way.
	e:ClearFocus()
	return e
end

local function poolButton(page, text, width, onClick)
	local b = acquire(page, "button", function() return LibWidgets.NewButton(page, {}) end)
	b.setText(text)
	b:SetWidth(width or 80)
	-- NewButton's own OnMouseDown already closes any open menu, so rebinding
	-- only OnClick here loses nothing.
	b:SetScript("OnClick", onClick or function() end)
	return b
end

-- The small texture-faced buttons on a collapsible header (arrow, actions, delete) and on
-- a disclosure line (gear). The tint is reset on every acquisition, since one
-- pool serves all of them and a dimmed disclosure gear would otherwise carry
-- over onto whatever header arrow lands on that instance next.
local function poolIconButton(page, icon, onClick, tooltip)
	local b = acquire(page, "iconbutton", function()
		local w = LibWidgets.NewIconButton(page, { width = 16, height = 16, iconSize = 9 })
		w.baseOnEnter = w:GetScript("OnEnter")
		w.baseOnLeave = w:GetScript("OnLeave")
		return w
	end)
	b.icon:SetTexture(icon)
	b.icon:SetVertexColor(1, 1, 1)
	b:SetScript("OnClick", function() LibWidgets.CloseAllMenus(); if onClick then onClick() end end)
	b:SetScript("OnEnter", function()
		if b.baseOnEnter then b.baseOnEnter() end
		if tooltip and tooltip ~= "" then
			GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
			GameTooltip:AddLine(tooltip)
			GameTooltip:Show()
		end
	end)
	b:SetScript("OnLeave", function()
		if b.baseOnLeave then b.baseOnLeave() end
		GameTooltip:Hide()
	end)
	return b
end

-- A section header's delete button, armed by a first click and committed by a
-- second within 3s -- the same two-click confirm the aura list's own Delete
-- uses, since deleting a trigger/effect/condition is just as unrecoverable. A
-- 16px icon button has no label to morph into "Confirm?" and a tinted 9px glyph
-- is too small to read as a state change, so an armed button goes solid red --
-- backdrop, border and glyph together -- which is legible at a glance and can't
-- be mistaken for the hover highlight.
local function poolDeleteButton(page, onDelete)
	local b = acquire(page, "delbutton", function()
		local bind = {}
		local w = LibWidgets.NewIconButton(page, { width = 16, height = 16, iconSize = 9 })
		w.icon:SetTexture(LibWidgets.ICON_DELETE)
		w.bind = bind
		w.arm = function()
			w.armed = true
			w:SetBackdropColor(0.65, 0.06, 0.06, 1)
			w:SetBackdropBorderColor(1, 0.3, 0.3, 1)
			w.icon:SetVertexColor(1, 0.9, 0.9)
		end
		w.disarm = function()
			w.armed = nil
			w:SetBackdropColor(0, 0, 0, 0.7)
			w:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
			w.icon:SetVertexColor(1, 1, 1)
		end
		w:SetScript("OnClick", function()
			LibWidgets.CloseAllMenus()
			if w.armed then
				w.disarm()
				if bind.onDelete then bind.onDelete() end
			else
				w.arm()
				C_Timer.After(3, function() if w.armed then w.disarm() end end)
			end
		end)
		-- Hover must not repaint an armed button back to the neutral border, or
		-- moving the mouse would silently undo the only cue that it's primed.
		w:SetScript("OnEnter", function()
			if not w.armed then this:SetBackdropBorderColor(0.9, 0.8, 0.2, 1) end
			GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
			GameTooltip:AddLine(w.armed and "Click again to confirm" or "Delete")
			GameTooltip:Show()
		end)
		w:SetScript("OnLeave", function()
			if not w.armed then this:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8) end
			GameTooltip:Hide()
		end)
		return w
	end)
	b.bind.onDelete = onDelete
	-- Disarm on reuse: a pooled button armed for the section it served in the
	-- last paint must never commit that click against whatever section it lands
	-- on in this one.
	b.disarm()
	return b
end

local function poolActionButton(page, action)
	if action.confirm then return poolDeleteButton(page, action.onClick) end
	return poolIconButton(page, action.icon, action.onClick, action.tooltip)
end

-- A bare click target laid over a collapsible header's title line. It doubles
-- as the header's tooltip zone (`f.tooltip`, the mass-edit member listing) --
-- a separate zone over the title would sit on this button and steal its
-- toggle clicks. Assigned every acquire, so a pooled area reused by a
-- tooltip-less header goes quiet again.
local function poolHitArea(page, onClick, tooltip)
	local b = acquire(page, "hitarea", function()
		local z = CreateFrame("Button", nil, page)
		z:SetScript("OnEnter", function()
			if not this.tipTitle then return end
			GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
			GameTooltip:SetText(this.tipTitle, 1, 1, 1)
			local lines = this.tipLines or EMPTY
			for i = 1, table.getn(lines) do
				GameTooltip:AddLine(lines[i], 0.9, 0.9, 0.9, true)
			end
			GameTooltip:Show()
		end)
		z:SetScript("OnLeave", function() GameTooltip:Hide() end)
		return z
	end)
	b:SetHeight(16)
	b:SetScript("OnClick", onClick)
	b.tipTitle = tooltip and tooltip.title or nil
	b.tipLines = tooltip and tooltip.lines or nil
	return b
end

-- `swatches` (value -> texture path) turns this into a previewing picker; a
-- swatch button can't be un-swatched after construction, so it pools separately.
local function poolDropdown(page, width, values, labels, onSelect, get, swatches, previews, onPreview)
	local kind = (swatches and "dropsw" or previews and "droppreview" or "drop") .. width
	local d = acquire(page, kind, function()
		local bind = {}
		-- NewDropButton captures `labels` once; a proxy that forwards misses to
		-- the live binding is what lets one pooled button serve every field.
		-- `values` needs no such trick -- passed as a function it already means
		-- "rebuild the menu from this on every open".
		local labelProxy = setmetatable({}, { __index = function(t, k)
			if k == nil then return nil end
			return bind.labels and bind.labels[k]
		end })
		local swatchProxy = swatches and setmetatable({}, { __index = function(t, k)
			if k == nil then return nil end
			return bind.swatches and bind.swatches[k]
		end })
		local previewProxy = previews and setmetatable({}, { __index = function(t, k)
			if k == nil then return nil end
			return bind.previews and bind.previews[k]
		end })
		local w = LibWidgets.NewDropButton(page, {
			width = width,
			values = function() return bind.values or EMPTY end,
			labels = labelProxy,
			swatches = swatchProxy,
			previews = previewProxy,
			previewTexture = W.SOUND_PREVIEW_TEXTURE,
			onPreview = function(v) if bind.onPreview then bind.onPreview(v) end end,
			onSelect = function(v) if bind.onSelect then bind.onSelect(v) end end,
			get = function() return bind.get and bind.get() end,
			textureDir = W.LIBWIDGETS_TEXTURES,
			-- The library's default of 8 rows scrolls the longest lists here (the
			-- trigger-type picker, a condition's property list) far more than they
			-- need. Read once at construction, so it applies to every field this
			-- pooled button is later rebound to.
			maxVisibleItems = 14,
		})
		w.bind = bind
		return w
	end)
	d.bind.values = values
	d.bind.labels = labels
	d.bind.swatches = swatches
	d.bind.previews = previews
	d.bind.onPreview = onPreview
	d.bind.onSelect = onSelect
	d.bind.get = get
	d.setValue(get and get())
	return d
end

local function poolAnchorGrid(page, f, width)
	local grid = acquire(page, "anchorgrid", function()
		local bind = {}
		local w = LibWidgets.NewAnchorGrid(page, {
			values = f.values,
			get = function() return bind.get and bind.get() end,
			onSelect = function(v) if bind.set then bind.set(v) end end,
		})
		w.bind = bind
		return w
	end)
	grid.bind.get = f.get
	grid.bind.set = f.set
	grid.setBindings(f.values, function() return grid.bind.get and grid.bind.get() end,
		function(v) if grid.bind.set then grid.bind.set(v) end end)
	grid.setSize(f.width or 100, f.height or 50)
	grid.setValue(f.get())
	return grid
end

-- A drop button whose face never changes: it names an action and its entries
-- are the choices. NewDropButton repaints the face from the picked value only
-- when given a `get`, so omitting one leaves the face entirely to setValue --
-- which this calls with the caption on every paint.
local function poolMenuButton(page, width, caption, values, labels, onSelect)
	local d = acquire(page, "menu" .. width, function()
		local bind = {}
		local labelProxy = setmetatable({}, { __index = function(t, k)
			if k == nil then return nil end
			return bind.labels and bind.labels[k]
		end })
		local w = LibWidgets.NewDropButton(page, {
			width = width,
			values = function() return bind.values or EMPTY end,
			labels = labelProxy,
			onSelect = function(v) if bind.onSelect then bind.onSelect(v) end end,
			textureDir = W.LIBWIDGETS_TEXTURES,
		})
		w.bind = bind
		return w
	end)
	d.bind.values = values
	d.bind.labels = labels
	d.bind.onSelect = onSelect
	-- No label maps the caption, so setValue falls through to the caption itself.
	d.setValue(caption)
	return d
end

local function poolColor(page, get, set)
	local sw = acquire(page, "color", function()
		local bind = {}
		local w = LibWidgets.NewColorSwatch(page, {
			get = function() return bind.get and bind.get() end,
			set = function(v) if bind.set then bind.set(v) end end,
		})
		w.bind = bind
		return w
	end)
	sw.bind.get = get
	sw.bind.set = set
	sw.repaint()
	return sw
end

-- A syntax-coloured Lua editor. The error line and the Reset button are the
-- widget's own (see LibWidgets.NewCodeEditBox), so nothing here pools them
-- separately -- which is also what keeps them from being stranded by a repaint.
-- Height is a construction-time parameter, so it folds into the pool key.
local function poolCode(page, f, width, height)
	local box = acquire(page, "code" .. height, function()
		local bind = {}
		local w = LibWidgets.NewCodeEditBox(page, {
			width = width, height = height,
			font = { path = W.CODE_FONT, size = W.CODE_FONT_SIZE },
			onChange = function(t) if bind.onChange then bind.onChange(t) end end,
			onCommit = function(t) if bind.onCommit then bind.onCommit(t) end end,
			validate = function(t) return bind.validate and bind.validate(t) end,
		})
		w.bind = bind
		return w
	end)
	-- Unbound across the seed: setText re-validates and would otherwise run the
	-- previous field's validator against this field's text.
	box.bind.onChange, box.bind.onCommit, box.bind.validate = nil, nil, nil
	box.setSize(width, height)
	-- Read per paint rather than at construction, so /wa codelive takes effect on
	-- the next repaint instead of needing a reload. `false` is a real stored
	-- value, so this can't collapse to `or true` -- only an unset (nil) setting
	-- falls back to the default, the same shape as the tab width below.
	if box.setLive then
		local liveOn = WeakestAurasDB and WeakestAurasDB.codeEditorLive
		if liveOn == nil then liveOn = true end
		box.setLive(liveOn)
	end
	if box.setFontSize then
		box.setFontSize((WeakestAurasDB and WeakestAurasDB.codeEditorFontSize) or W.CODE_FONT_SIZE)
	end
	if box.setTabWidth then
		-- `false` means hard tabs, so this can't collapse to `or 2` -- only an
		-- unset (nil) value falls back to the default.
		local tw = WeakestAurasDB and WeakestAurasDB.codeEditorTabWidth
		if tw == nil then tw = 2 end
		box.setTabWidth(tw)
	end
	-- setDefault also disarms, so a Reset primed for the field this box served
	-- in the last paint can never commit against the one it lands on now.
	box.setDefault(f.default)
	-- A field that has never been configured opens *at* its Reset default rather
	-- than empty: an empty box runs nothing and teaches nothing, and the default
	-- is the signature the user has to start from either way. It is committed,
	-- not merely displayed -- a box showing logic the aura is not running is
	-- worse than an empty one -- so it goes through `set` once the binds are
	-- back.
	--
	-- "Never configured" is `get` returning nil, and the distinction from "" is
	-- load-bearing: seeding an empty *string* would put the default back every
	-- time the user cleared the box, which makes an emptied code field
	-- impossible to keep. A `code` field's `get` must therefore return the raw
	-- stored value, not `... or ""`.
	local stored = f.get()
	-- `noSeed` (a mass-edit merged field): nil there means the sources disagree
	-- at least as often as "never configured", and a seed would go through the
	-- merged set -- writing the default into every one of them on mere paint.
	local seeding = (stored == nil and f.default ~= nil and not f.noSeed)
	local text = stored or ""
	if seeding then
		text = (type(f.default) == "function" and f.default() or f.default) or ""
	end
	box.setText(text)
	box.bind.validate = f.validate
	box.bind.onCommit = f.set
	box.bind.onChange = f.onChange
	if seeding and f.set then f.set(text) end
	-- The seed above ran with no validator bound; drive the error line now that
	-- the real one is in place.
	box.revalidate()
	return box
end

local function poolMultiline(page, width, height, text, onCommit, onChange)
	local box = acquire(page, "multiline", function()
		local bind = {}
		local w = LibWidgets.NewMultiLineEditBox(page, {
			onChange = function(t) if bind.onChange then bind.onChange(t) end end,
		})
		w.bind = bind
		w.edit:SetScript("OnEditFocusLost", function()
			if bind.onCommit then bind.onCommit(w.getText()) end
		end)
		return w
	end)
	-- Unbound across the seed: SetText fires OnTextChanged, and the field being
	-- painted validates its own starting text below -- an echo here would only
	-- run the same check a second time (and, before the rebind, against the
	-- previous field's).
	box.bind.onChange = nil
	box.bind.onCommit = nil
	-- setSize, not SetWidth/SetHeight: the widget has to re-wrap and re-measure
	-- its text to keep the scroll range right.
	box.setSize(width, height)
	box.setText(text or "")
	box.bind.onChange = onChange
	box.bind.onCommit = onCommit
	return box
end

-- Boundary-move splice shared by the list editor's arrow buttons and its
-- drag-drop (see LibWidgets.lua's NewListEditor doc comment): `before` names an
-- original index the moved entry should land just ahead of.
local function spliceReorder(list, fromIndex, before)
	local v = table.remove(list, fromIndex)
	local insertAt = (fromIndex < before) and (before - 1) or before
	table.insert(list, insertAt, v)
end

local function poolListEditor(page, f, x, y, rightInset, visibleRows)
	local frame = acquire(page, "list" .. visibleRows, function()
		W._listSeq = (W._listSeq or 0) + 1
		local bind = {}
		local function list() return (bind.list and bind.list()) or EMPTY end
		local function changed(kind, first, second)
			if bind[kind] then
				if second ~= nil then bind[kind](first, second) else bind[kind](first) end
			elseif bind.onChange then
				bind.onChange()
			end
		end
		local editor = LibWidgets.NewListEditor(page, {
			nameFrame = "WeakestAurasOptList" .. W._listSeq,
			textureDir = W.LIBWIDGETS_TEXTURES,
			rowHeight = 20, visibleRows = visibleRows,
			list = list,
			reorder = function(fromIndex, before)
				spliceReorder(list(), fromIndex, before)
				changed("onReorder", fromIndex, before)
			end,
			remove = function(index)
				table.remove(list(), index)
				changed("onRemove", index)
			end,
			add = { onAdd = function(text)
				if text and text ~= "" then
					table.insert(list(), text)
					changed("onAdd", text)
				end
			end },
			nameGet = function(entry) return entry end,
		})
		editor.frame.editor = editor
		editor.frame.bind = bind
		return editor.frame
	end)
	frame.bind.list = f.get
	frame.bind.onChange = f.onChange
	frame.bind.onReorder = f.onReorder
	frame.bind.onRemove = f.onRemove
	frame.bind.onAdd = f.onAdd
	frame:SetPoint("TOPLEFT", page, "TOPLEFT", x, y)
	frame:SetPoint("RIGHT", page, "RIGHT", -rightInset, 0)
	frame.editor.refresh()
	return frame
end

-- ---------------------------------------------------------------------------
-- Declarative options-table renderer
-- ---------------------------------------------------------------------------

-- Distance from a field's top edge down to the top of its control body -- the
-- caption line a labelled field draws above its widget, zero for one that has
-- none. A two-column row aligns on this rather than on its top edge, so a bare
-- toggle or swatch sits level with the control beside it instead of level with
-- that control's caption. `range` is listed although `placeField` puts its
-- widget on the row's top edge: NewSpinBox draws its own caption inside the
-- frame, in the 14px it reserves above the track.
local FIELD_LEAD = {
	input = 16, multiline = 16, namelist = 16, select = 16, opnumber = 16,
	spell = 16, item = 16, talent = 16, icon = 16, texture = 16,
	anchorgrid = 16, anchorlayout = 16,
	code = 20,
	range = 14,
}

local function fieldLead(f) return FIELD_LEAD[f.type] or 0 end

-- A hover zone over a field's caption for `f.tooltip` ({ title, lines }) --
-- the per-member value listing a disagreeing mass-edit field carries.
-- FontStrings take no mouse events on this client, so the zone is its own
-- pooled button, sized to the caption text rather than the column so it can
-- never sit over a control (or a code field's Reset button) and steal its
-- clicks.
local function poolTipZone(page, f, label, x, y, h)
	if not f.tooltip then return end
	local zone = acquire(page, "tipzone", function()
		local z = CreateFrame("Button", nil, page)
		z:SetScript("OnEnter", function()
			GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
			GameTooltip:SetText(this.tipTitle or "", 1, 1, 1)
			local lines = this.tipLines or EMPTY
			for i = 1, table.getn(lines) do
				GameTooltip:AddLine(lines[i], 0.9, 0.9, 0.9, true)
			end
			GameTooltip:Show()
		end)
		z:SetScript("OnLeave", function() GameTooltip:Hide() end)
		return z
	end)
	zone.tipTitle = f.tooltip.title
	zone.tipLines = f.tooltip.lines
	local tw = label and label.GetStringWidth and label:GetStringWidth() or 0
	if not tw or tw < 24 then tw = 80 end
	zone:SetWidth(tw + 6)
	zone:SetHeight(h or 14)
	zone:ClearAllPoints()
	zone:SetPoint("TOPLEFT", x, y)
	return zone
end

-- Places one field at (x, y) with widget width `w` and returns the vertical
-- space it consumed. Headers are handled by the caller (they're always
-- full-width). Shared by the single-column and two-column paths so both stay
-- identical per field type.
local function placeField(page, f, x, y, w)
	local indent = (f.indent or 0) * OPTIONS_INDENT_W
	if indent > 0 then
		x = x + indent
		w = w - indent
		if w < 90 then w = 90 end
	end
	local lead = fieldLead(f)
	if f.type == "toggle" then
		local cb = poolCheck(page, f.name, f.set, f.get, f.tristate)
		cb:SetPoint("TOPLEFT", x, y)
		poolTipZone(page, f, cb.label, x + 24, y, 20)
		return 24
	elseif f.type == "space" then
		local line = 24
		return f.useHeight and (f.height or 1) * line or line
	elseif f.type == "input" then
		local label = poolLabel(page, f.name)
		label:SetPoint("TOPLEFT", x, y)
		poolTipZone(page, f, label, x, y, 14)
		local e = poolEditBox(page, w, f.set)
		local v = f.get()
		e:SetText(v ~= nil and tostring(v) or "")
		e:SetPoint("TOPLEFT", x, y - lead)
		return lead + 28
	elseif f.type == "multiline" then
		local label = poolLabel(page, f.name)
		label:SetPoint("TOPLEFT", x, y)
		poolTipZone(page, f, label, x, y, 14)
		-- Wants far more width than a normal field's capped column; size to the
		-- page rather than the passed `w`. Commits on focus lost, not per
		-- keystroke -- a custom-trigger `set` recompiles the aura, and Enter is a
		-- newline in a multi-line box, so mid-typing commits are wrong here.
		local mw = (page:GetWidth() or 400) - x - 16
		if mw < 120 then mw = 120 end
		local mh = f.height or 150
		local box = poolMultiline(page, mw, mh, f.get() or "", f.set)
		box:SetPoint("TOPLEFT", x, y - lead)
		return lead + mh + 8
	elseif f.type == "description" then
		-- Text only, no control: `name` is the whole body. Sized to the page
		-- rather than the capped column, since it is prose and wraps.
		local dw = f.half and w or ((page:GetWidth() or 400) - x - 16)
		if dw < 120 then dw = 120 end
		local fs = poolDescription(page, f.name, dw)
		fs:SetPoint("TOPLEFT", x, y)
		return (fs:GetHeight() or 12) + 8
	elseif f.type == "code" then
		local label = poolLabel(page, f.name)
		label:SetPoint("TOPLEFT", x, y)
		poolTipZone(page, f, label, x, y, 14)
		-- Same page-width sizing as `multiline`: code wants far more room than a
		-- normal field's capped column.
		local mw = (page:GetWidth() or 400) - x - 16
		if mw < 120 then mw = 120 end
		local mh = f.height or 150
		local box = poolCode(page, f, mw, mh)
		-- The lead is deeper here than a plain label needs: it also has to clear
		-- the widget's own Reset button, which sits above the box's top-right
		-- corner.
		box:SetPoint("TOPLEFT", x, y - lead)
		-- The label/Reset row, then the box, then the widget's own error line
		-- (14) -- which is always allotted, so the layout below doesn't shift as
		-- errors come and go while typing.
		return lead + mh + 8 + 14
	elseif f.type == "spell" or f.type == "item" or f.type == "talent" or f.type == "icon" or f.type == "texture" then
		local label = poolLabel(page, f.name)
		label:SetPoint("TOPLEFT", x, y)
		poolTipZone(page, f, label, x, y, 14)
		local icon = poolPreviewIcon(page)
		icon:SetPoint("TOPLEFT", x, y - lead)
		-- `spell`/`item` store what the user typed and preview whatever it
		-- resolves to; `icon` resolves at commit instead and stores the texture
		-- path itself, so the region can SetTexture it blindly.
		local function resolve(v)
			if f.type == "spell" then
				local id = WA.ResolveSpellID(v)
				if not id then return nil end
				local _, _, ic = GetSpellInfo(id)
				return ic
			elseif f.type == "item" then
				local id = WA.ResolveItemID(v)
				if not id then return nil end
				-- C_Item.GetItemInfo's 18-value tuple, not the stock global's short
				-- one: only the modern shape has the texture in slot 10.
				if not (C_Item and C_Item.GetItemInfo) then return nil end
				local _, _, _, _, _, _, _, _, _, ic = C_Item.GetItemInfo(id)
				return ic
			elseif f.type == "talent" then
				return f.resolve and f.resolve(v) or nil
			end
			local id = WA.ResolveSpellID(v)
			if id then local _, _, ic = GetSpellInfo(id); return ic end
			if v and v ~= "" then return v end
			return nil
		end
		-- An `icon` field additionally gets a Browse button opening the picker;
		-- typing a path by hand still works, it just stops being the only way.
		local browsable = f.type == "icon" or f.type == "texture"
		local browseW = browsable and 62 or 0
		local e = poolEditBox(page, w - 24 - browseW, function(v)
			local path = resolve(v)
			if browsable then f.set(path or "") else f.set(v) end
			icon:SetTexture(path or QUESTION_ICON)
			if WA.RefreshList then WA.RefreshList() end
		end)
		-- Only an item field takes a shift-clicked link; a spell, talent, or icon field has
		-- nothing to do with one.
		e.acceptsLinks = (f.type == "item")
		local v = f.get()
		e:SetText(v ~= nil and tostring(v) or "")
		e:SetPoint("TOPLEFT", x + 24, y - lead)
		if browsable then
			icon:SetTexture(WA.DrawableTexture(v) or QUESTION_ICON)
			local b = poolButton(page, "Browse", browseW - 4, function()
				local picker = f.type == "texture" and W.OpenTexturePicker or W.OpenIconPicker
				picker(f.get(), function(path)
					f.set(path or "")
					if WA.RefreshList then WA.RefreshList() end
					if WA.RefreshOptions then WA.RefreshOptions() end
				end)
			end)
			b:SetPoint("TOPLEFT", x + 24 + (w - 24 - browseW) + 4, y - lead)
		else
			icon:SetTexture(resolve(v) or QUESTION_ICON)
		end
		return lead + 28
	elseif f.type == "namelist" then
		local label = poolLabel(page, f.name)
		label:SetPoint("TOPLEFT", x, y)
		poolTipZone(page, f, label, x, y, 14)
		local n = table.getn(f.get() or EMPTY)
		local visibleRows = n < 2 and 2 or (n > 5 and 5 or n)
		local rightInset = (page:GetWidth() or 400) - (x + w)
		local frame = poolListEditor(page, f, x, y - lead, rightInset, visibleRows)
		return lead + frame.editor.height + 6
	elseif f.type == "range" then
		local s = acquire(page, "spin", function()
			-- The bind table *is* the widget's spec: NewSpinBox reads label/min/
			-- max/step/onChange out of it at call time, so rebinding is assignment.
			local bind
			bind = {
				min = 0, max = 1, step = 1, width = 220,
				textureDir = W.LIBWIDGETS_TEXTURES,
				onChange = function(v) if bind.set then bind.set(v) end end,
			}
			local sp = LibWidgets.NewSpinBox(page, bind)
			sp.bind = bind
			return sp
		end)
		-- Unbound across the rebind, because two things here can move the value:
		-- clearing a box that still holds focus from the edit which caused this
		-- repaint commits it, and a narrowed range clamps the carried-over number.
		-- Either would write into the field being painted rather than the one the
		-- user was actually editing.
		s.bind.set = nil
		s.edit:ClearFocus()
		s.bind.label, s.bind.fmt, s.bind.decimals = f.name, f.fmt, f.decimals
		s.bind.min, s.bind.max, s.bind.step = f.min, f.max, f.step
		s.bind.softMax = f.softMax
		s.setWidth(w)
		s.setValue(f.get())
		s.bind.set = f.set
		s:SetPoint("TOPLEFT", x, y)
		poolTipZone(page, f, s.label, x, y, 14)
		return 38
	elseif f.type == "disclosure" then
		-- A settings fold: a gear plus a one-line label, the whole line clickable.
		-- Deliberately not a `header` -- a header titles a region of the tab, this
		-- hides settings that get set once and then only get in the way, so it
		-- reads as a control rather than as a divider.
		local btn = poolIconButton(page, GEAR_ICON, f.onToggle or function() end)
		btn:SetPoint("TOPLEFT", x, y)
		if f.collapsed then btn.icon:SetVertexColor(0.6, 0.6, 0.6) end
		-- The summary says what the folded rows hold, so the closed state still
		-- carries the settings rather than merely naming them.
		local text = f.name or ""
		if f.summary and f.summary ~= "" then text = text .. "|cff9d9d9d: " .. f.summary .. "|r" end
		local label = poolLabel(page, text)
		label:SetPoint("TOPLEFT", x + 20, y - 2)
		local hit = poolHitArea(page, f.onToggle or function() end, f.tooltip)
		hit:SetPoint("TOPLEFT", x + 20, y)
		hit:SetPoint("TOPRIGHT", page, "TOPLEFT", x + 24 + (label:GetStringWidth() or 0), y)
		return 22
	elseif f.type == "select" then
		local label = poolLabel(page, f.name)
		label:SetPoint("TOPLEFT", x, y)
		poolTipZone(page, f, label, x, y, 14)
		local dw = w < 160 and w or 160
		local actionCount = table.getn(f.actions or {})
		if actionCount > 0 then
			local actionW = actionCount * 16 + (actionCount - 1) * 6
			local available = w - actionW - 6
			if available < 90 then available = 90 end
			dw = available < 160 and available or 160
		end
		local d = poolDropdown(page, dw, f.values, f.labels, f.set, f.get, f.swatches, f.previews, f.onPreview)
		d:SetPoint("TOPLEFT", x, y - lead)
		for i = 1, actionCount do
			local action = f.actions[i]
			local button = poolActionButton(page, action)
			button:SetPoint("TOPLEFT", x + dw + 6 + (i - 1) * 22, y - lead + 2)
		end
		return lead + 28
	elseif f.type == "opnumber" then
		local label = poolLabel(page, f.name)
		label:SetPoint("TOPLEFT", x, y)
		poolTipZone(page, f, label, x, y, 14)
		local op = poolDropdown(page, 52, W.OPERATORS, nil, f.setOp, f.getOp)
		op:SetPoint("TOPLEFT", x, y - lead)
		local e = poolEditBox(page, 60, function(v) f.setVal(tonumber(v)) end)
		local v = f.getVal()
		e:SetText(v ~= nil and tostring(v) or "")
		e:SetPoint("TOPLEFT", x + 58, y - lead)
		return lead + 28
	elseif f.type == "color" then
		local label = poolLabel(page, f.name)
		label:SetPoint("TOPLEFT", x, y - 3)
		poolTipZone(page, f, label, x, y - 3, 16)
		local sw = poolColor(page, f.get, f.set)
		sw:SetPoint("TOPLEFT", x + 100, y)
		return 26
	elseif f.type == "button" then
		local b = poolButton(page, f.name, f.width or w, f.onClick)
		b:SetPoint("TOPLEFT", x, y)
		return 28
	elseif f.type == "menu" then
		local d = poolMenuButton(page, f.width or w, f.name, f.values, f.labels, f.onSelect)
		d:SetPoint("TOPLEFT", x, y)
		return 28
	elseif f.type == "anchorgrid" then
		local label = poolLabel(page, f.name)
		label:SetPoint("TOPLEFT", x, y)
		poolTipZone(page, f, label, x, y, 14)
		local gw = f.width or w
		local grid = poolAnchorGrid(page, f, gw)
		grid:SetPoint("TOPLEFT", x, y - lead)
		return lead + (f.height or 50) + 8
	elseif f.type == "anchorlayout" then
		local grid = f.grid
		local gridW = grid.width or 100
		local gridH = grid.height or 50
		local anchor = poolLabel(page, grid.name)
		anchor:SetPoint("TOPLEFT", x, y)
		local anchorGrid = poolAnchorGrid(page, grid, gridW)
		anchorGrid:SetPoint("TOPLEFT", x, y - lead)
		local sideX = x + gridW + 12
		local sideW = w - gridW - 12
		if sideW < 90 then sideW = 90 end
		local sideY = y
		local sideHeight = 0
		for i = 1, table.getn(f.sideFields or {}) do
			local used = placeField(page, f.sideFields[i], sideX, sideY, sideW)
			sideY = sideY - used
			sideHeight = sideHeight + used
		end
		local gridHeight = lead + gridH + 8
		return gridHeight > sideHeight and gridHeight or sideHeight
	end
	return 0
end

-- (Re)paints `page` from `fields`, reusing the widgets already on it (see the
-- widget pool above). Fields flagged `half` pack two-per-row; columns size to
-- the page's current width so the layout follows a resized options window.
function W.BuildOptions(page, fields)
	page.widgetPools = page.widgetPools or {}
	page.widgetUsed = page.widgetUsed or {}
	-- A NewDropButton popup is parented to the window, not to its button or this
	-- page, so the sweep below can't take it down: an open menu would survive the
	-- repaint and float over the new controls. Closing it here rather than
	-- relying on the caller is what lets the invariant below hold for *every*
	-- widget this page owns. It also drops edit focus, which has to happen
	-- before anything below re-seeds a pooled box -- a commit-on-blur editor
	-- reached by the seed first would have the user's unsaved text overwritten
	-- by the stored value and only then be asked to commit it.
	LibWidgets.CloseAllMenus()
	-- Everything on the page goes down before anything comes back up, and
	-- `acquire` re-Shows only what this paint actually uses. Hiding up front
	-- rather than sweeping the unused tail at the end is what makes "a control
	-- from the previous tab is still on screen" structurally impossible: the
	-- sweep only holds if the paint runs to completion, so any error partway
	-- through (or an early return added later) stranded whatever the previous
	-- paint had put there. This ordering has no such precondition.
	for kind, pool in pairs(page.widgetPools) do
		page.widgetUsed[kind] = 0
		for i = 1, table.getn(pool) do pool[i]:Hide() end
	end

	local avail = page:GetWidth()
	if not avail or avail < 120 then avail = 400 end
	local gap = 12
	local colW = math.floor((avail - 16 - gap) / 2)
	if colW < 90 then colW = 90 end
	local leftX, rightX = 8, 8 + colW + gap
	local fullW = avail - 16
	if fullW > 240 then fullW = 240 end

	local y = -8
	-- A `half` field waits here for the partner it shares its row with, since
	-- where it goes depends on that partner's shape. A header, a full-width
	-- field, or the end of the list flushes it into the left column alone.
	local pending, pendingY

	local function flushPending()
		if not pending then return end
		y = pendingY - placeField(page, pending, leftX, pendingY, colW - 8)
		pending = nil
	end

	for i = 1, table.getn(fields) do
		local f = fields[i]
		if f.type == "header" then
			flushPending()
			y = y - 10
			-- Centered gold label flanked by horizontal rules (the WeakAuras
			-- section-divider look) -- plain size-differentiated text wasn't
			-- separating areas clearly enough.
			local h = poolHeaderLabel(page, f.name)
			local headerIndent = (f.indent or 0) * OPTIONS_INDENT_W
			h:SetPoint("TOP", page, "TOPLEFT", avail / 2 + headerIndent, y)

			-- Header actions occupy the right edge in descriptor order; placing them
			-- backwards keeps the first action leftmost.
			local leftEdge, rightEdge = 8 + headerIndent, avail - 8
			if f.onDelete then
				local del = poolDeleteButton(page, f.onDelete)
				del:SetPoint("TOPRIGHT", page, "TOPLEFT", rightEdge, y + 2)
				rightEdge = rightEdge - 16 - 6
			end
			for actionIndex = table.getn(f.actions or {}), 1, -1 do
				local action = f.actions[actionIndex]
				local button = poolActionButton(page, action)
				button:SetPoint("TOPRIGHT", page, "TOPLEFT", rightEdge, y + 2)
				rightEdge = rightEdge - 16 - 6
			end
			if f.collapsed ~= nil then
				-- The arrow points the way the section will move on click: down to
				-- unfold a collapsed one, up to fold an open one.
				local arrow = poolIconButton(page,
					W.LIBWIDGETS_TEXTURES .. (f.collapsed and "down" or "up"),
					f.onToggle or function() end)
				arrow:SetPoint("TOPLEFT", 8 + headerIndent, y + 2)
				leftEdge = 8 + headerIndent + 16 + 6
			end
			-- The whole title line toggles too, not just the small arrow. It's a
			-- bare mouse-enabled frame (no textures of its own) laid over the
			-- label, and it stops at rightEdge so it can never sit on top of the
			-- delete button and swallow its clicks.
			if f.collapsed ~= nil then
				local hit = poolHitArea(page, f.onToggle or function() end, f.tooltip)
				hit:SetPoint("TOPLEFT", leftEdge, y + 2)
				hit:SetPoint("TOPRIGHT", page, "TOPLEFT", rightEdge, y + 2)
			end

			local tw = h:GetStringWidth() or 0
			local midY, cx, pad = y - 6, avail / 2, 8
			-- Only draw the flanking rules when the label leaves room for them;
			-- otherwise the texture ends would cross and render inverted.
			if cx - tw / 2 - pad > leftEdge + 4 then
				local ll = poolRule(page)
				ll:SetPoint("LEFT", page, "TOPLEFT", leftEdge, midY)
				ll:SetPoint("RIGHT", page, "TOPLEFT", cx - tw / 2 - pad, midY)
				local rl = poolRule(page)
				rl:SetPoint("LEFT", page, "TOPLEFT", cx + tw / 2 + pad, midY)
				rl:SetPoint("RIGHT", page, "TOPLEFT", rightEdge, midY)
			end
			y = y - 18
		elseif f.half then
			if not pending then
				pending, pendingY = f, y
			else
				-- Both controls hang from the deeper of the two caption lines, so
				-- a one-line toggle lands beside the control of the labelled field
				-- next to it rather than beside that field's caption. The row is
				-- then as tall as the taller of the two bodies under that line.
				local leadL, leadR = fieldLead(pending), fieldLead(f)
				local top = leadL > leadR and leadL or leadR
				local lh = (top - leadL) + placeField(page, pending, leftX, pendingY - (top - leadL), colW - 8)
				local rh = (top - leadR) + placeField(page, f, rightX, pendingY - (top - leadR), colW - 8)
				y = pendingY - (lh > rh and lh or rh)
				pending = nil
			end
		else
			flushPending()
			y = y - placeField(page, f, 8, y, fullW)
		end
	end
	flushPending()

	-- Total laid-out height (y runs negative from the top), so a scroll-child
	-- container can size itself to the content -- see OptionsFrame.lua's content
	-- scroll frame.
	page.contentHeight = -y + 8
end

-- ---------------------------------------------------------------------------
-- Context menu
--
-- W.ContextMenu(parent) -> a frame with Open(items, anchor) and Close(). The
-- item list is passed to every Open, so one menu instance serves any number of
-- differently-shaped menus:
--   { text = "Duplicate", onClick = function() end }
--   { text = "Copy settings", submenu = { ...items... } }  -- one level only
--   { separator = true }
--   { text = "Delete", disabled = true }                   -- greyed, inert
--   { text = "Delete", confirm = true, onClick = ... }      -- two-click morph
-- Item buttons come from the same per-kind pool BuildOptions uses, so contents
-- that change per opening cost no new frames after the first paint.
-- ---------------------------------------------------------------------------

local MENU_ITEM_H = 16
local MENU_PAD = 3
local MENU_MIN_W, MENU_MAX_W = 120, 260

local paintMenu

local function menuItemClicked(b)
	local item = b.item
	if not item or item.disabled then return end
	-- A confirm item stays open across its first click: a menu that closed on
	-- every click could not show an armed state at all.
	if item.confirm and not b.confirming then
		b.confirming = true
		b.label:SetText("Confirm?")
		C_Timer.After(3, function()
			-- Buttons are pooled and rebound: only revert one still holding the
			-- item that armed it.
			if b.confirming and b.item == item then
				b.confirming = nil
				b.label:SetText(item.text or "")
			end
		end)
		return
	end
	b.confirming = nil
	b.menu.Root().Close()
	if item.onClick then item.onClick() end
end

local function menuItemEntered(b)
	local sub = b.menu.sub
	if not sub then return end
	-- Entering any item takes down whatever submenu the previous one opened, so
	-- at most one is ever up.
	sub:Hide()
	local item = b.item
	if not item or item.disabled or not item.submenu then return end
	paintMenu(sub, item.submenu)
	sub:ClearAllPoints()
	local right = b:GetRight()
	local screenW = UIParent:GetWidth()
	if not screenW or screenW <= 0 then screenW = GetScreenWidth() end
	if right and right + (sub:GetWidth() or 0) > screenW then
		sub:SetPoint("TOPRIGHT", b, "TOPLEFT", -2, MENU_PAD)
	else
		sub:SetPoint("TOPLEFT", b, "TOPRIGHT", 2, MENU_PAD)
	end
	sub:Show()
end

local function newMenuItem(f)
	local b = CreateFrame("Button", nil, f)
	b:SetHeight(MENU_ITEM_H)
	b.menu = f

	local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	fs:SetPoint("LEFT", 4, 0)
	fs:SetJustifyH("LEFT")
	b.label = fs

	local arrow = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	arrow:SetPoint("RIGHT", -4, 0)
	arrow:SetText(">")
	arrow:Hide()
	b.arrow = arrow

	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints(b)
	hl:SetTexture(0.3, 0.3, 0.8, 0.4)
	b.hl = hl

	b:SetScript("OnClick", function() menuItemClicked(b) end)
	b:SetScript("OnEnter", function() menuItemEntered(b) end)
	return b
end

function paintMenu(f, items)
	-- Same hide-first ordering BuildOptions uses: everything goes down before
	-- anything comes back up, so a paint that errors partway cannot leave an
	-- item from the previous opening on screen.
	for kind, pool in pairs(f.widgetPools) do
		f.widgetUsed[kind] = 0
		for i = 1, table.getn(pool) do pool[i]:Hide() end
	end

	local width = MENU_MIN_W
	local y = -MENU_PAD
	for i = 1, table.getn(items) do
		local item = items[i]
		if item.separator then
			local t = acquire(f, "menusep", function()
				local tex = f:CreateTexture(nil, "ARTWORK")
				tex:SetHeight(1)
				tex:SetTexture(0.4, 0.4, 0.4, 0.8)
				return tex
			end)
			t:SetPoint("TOPLEFT", f, "TOPLEFT", MENU_PAD + 2, y - 3)
			t:SetPoint("TOPRIGHT", f, "TOPRIGHT", -(MENU_PAD + 2), y - 3)
			y = y - 7
		else
			local b = acquire(f, "menuitem", function() return newMenuItem(f) end)
			b:SetPoint("TOPLEFT", f, "TOPLEFT", MENU_PAD, y)
			b:SetPoint("TOPRIGHT", f, "TOPRIGHT", -MENU_PAD, y)
			b.item = item
			-- Disarm on reuse, or a pooled button armed by the last opening would
			-- commit that click against whatever item it holds in this one.
			b.confirming = nil
			b.label:SetText(item.text or "")
			if item.disabled then
				b.label:SetTextColor(0.5, 0.5, 0.5)
				b.hl:SetTexture(0, 0, 0, 0)
			else
				b.label:SetTextColor(1, 1, 1)
				b.hl:SetTexture(0.3, 0.3, 0.8, 0.4)
			end
			if item.submenu then b.arrow:Show() else b.arrow:Hide() end
			local w = (b.label:GetStringWidth() or 0) + 2 * MENU_PAD + 12
			if item.submenu then w = w + 14 end
			if w > width then width = w end
			y = y - MENU_ITEM_H
		end
	end
	if width > MENU_MAX_W then width = MENU_MAX_W end
	f:SetWidth(width)
	f:SetHeight(-y + MENU_PAD)
end

local function newMenuFrame(parent)
	local f = CreateFrame("Frame", nil, parent)
	f:SetBackdrop(W.EDITBOX_BACKDROP)
	f:SetBackdropColor(0, 0, 0, 0.95)
	f:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.9)
	f:SetFrameStrata("FULLSCREEN_DIALOG")
	f:SetToplevel(true)
	-- Mouse-enabled so a click on the menu's own padding is swallowed here
	-- rather than falling through to the click-away catcher underneath.
	f:EnableMouse(true)
	f:Hide()
	f.widgetPools, f.widgetUsed = {}, {}
	return f
end

-- Places the menu at the cursor, flipping left/up against whichever screen edge
-- it would otherwise cross. `anchor` is the fallback for a client that gives no
-- cursor position, opening to the right of the frame that was clicked.
local function placeMenu(f, anchor)
	local x, y = GetCursorPosition()
	local scale = UIParent:GetEffectiveScale()
	f:ClearAllPoints()
	if not x or not scale or scale == 0 then
		f:SetPoint("TOPLEFT", anchor or UIParent, "TOPRIGHT", 4, 0)
		return
	end
	x, y = x / scale, y / scale
	local screenW = UIParent:GetWidth()
	if not screenW or screenW <= 0 then screenW = GetScreenWidth() end
	local horiz = (x + (f:GetWidth() or 0) > screenW) and "RIGHT" or "LEFT"
	local vert = (y - (f:GetHeight() or 0) < 0) and "BOTTOM" or "TOP"
	f:SetPoint(vert .. horiz, UIParent, "BOTTOMLEFT", x, y)
end

function W.ContextMenu(parent)
	local f = newMenuFrame(parent)
	f.sub = newMenuFrame(f)
	f.sub:SetFrameLevel(f:GetFrameLevel() + 5)
	f.Root = function() return f end
	f.sub.Root = f.Root

	-- Click-outside dismissal. LibWidgets.CloseAllMenus only reaches clicks that
	-- land on a LibWidgets control, so this needs its own full-screen catcher one
	-- strata below the menu to also close on a click into the aura list, the tab
	-- pane or the world.
	local catcher = CreateFrame("Frame", nil, UIParent)
	catcher:SetAllPoints(UIParent)
	catcher:EnableMouse(true)
	catcher:SetFrameStrata("FULLSCREEN")
	catcher:Hide()
	catcher:SetScript("OnMouseDown", function() f.Close() end)
	f.catcher = catcher

	f.Close = function()
		f.sub:Hide()
		f:Hide()
		catcher:Hide()
	end

	f.Open = function(items, anchor)
		-- A drop-button popup and a context menu must never be up at once.
		LibWidgets.CloseAllMenus()
		f.sub:Hide()
		paintMenu(f, items)
		placeMenu(f, anchor)
		catcher:Show()
		f:Show()
	end

	-- The catcher is a UIParent child, so nothing takes it down when the menu's
	-- own parent hides -- and a stranded catcher is a full-screen invisible
	-- mouse blocker over the whole UI.
	f:SetScript("OnHide", function()
		f.sub:Hide()
		catcher:Hide()
	end)
	return f
end
