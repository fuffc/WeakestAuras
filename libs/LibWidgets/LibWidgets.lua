-- LibWidgets -- a small, addon-agnostic UI widget library for 1.12 WoW
-- addons. Currently houses fourteen widgets: NewButton (a flat action button),
-- NewTabButton (a NewButton carrying the lit "selected" look), NewTabStrip (a
-- row of NewTabButtons that measures, wraps and reflows itself),
-- NewIconButton (a small texture-faced button),
-- NewCheckBox (a labelled checkbox), NewColorSwatch (a ColorPickerFrame swatch),
-- NewSlider (a value-carrying OptionsSliderTemplate slider), NewSpinBox (a
-- drag/type/step number control), NewTextBox (a
-- tooltip-backdrop-styled edit box), NewMultiLineEditBox (a scrollable
-- multi-line edit box on this library's own slim slider, sized to its text),
-- NewScrollFrame (a chrome-free content scroller), NewDropButton (a
-- value-picker popup button)
-- NewIconPicker (a searchable icon-browser dialog)
-- and NewListEditor (a bordered FauxScrollFrame-backed row pool with
-- an optional leading tristate/checkbox control, a class/priority-coloured
-- name label, optional trailing per-column widgets, reorder -- arrows + full
-- drag-to-reorder with a ghost row, insertion indicator and cursor-edge
-- auto-scroll -- and an optional add row built from NewButton + NewTextBox).
-- Further widgets are expected to join it under the same library name.
--
-- NewAnchorGrid is a nine-point anchor picker: a bordered 3x3 grid of small
-- buttons whose selected point is highlighted. spec:
--   values       -- ordered nine point values, row-major
--   get()        -- optional initial value
--   onSelect(v)  -- called when a point is picked
--   width/height -- optional outer size (defaults to 100x50)
-- Returns the frame with `.setValue(v)` and `.setSize(width, height)` methods.
--
-- NewTabStrip is a row of tab buttons that lays itself out: each tab is sized
-- to its own label rather than to an equal share, and the row wraps onto as
-- many lines as it needs. spec:
--   tabs        -- ordered { { value = <any>, text = <string>, hidden = <bool> }, ... }
--   width       -- the width to wrap within (required in practice; default 100)
--   rowHeight   -- tab height, default 22
--   gap         -- horizontal space between tabs, default 4
--   rowGap      -- vertical space between rows, default 4
--   padding     -- added to each measured label to get the tab's width, default 16
--   minWidth    -- floor for a very short label, default 24
--   fillRatio   -- a row at or above this fraction of `width` is stretched to
--                  fill it; a sparser one keeps its natural widths and is left-
--                  aligned. Default 0.75
--   onSelect(value)      -- a tab was clicked
--   onReflow(rows, height) -- the row count or height changed; the consumer
--                            re-anchors whatever sits below the strip
-- Returns the frame with `.setTabs(list)`, `.select(value)` (nil deselects
-- every tab), `.getSelected()`, `.getRows()`, `.setWidth(w)` and `.buttons`
-- (index-stable, one per entry in the last `setTabs` list, hidden ones
-- included).
--
-- NewCodeEditBox decorates NewMultiLineEditBox into a syntax-coloured Lua
-- editor: it colours on blur (never while typing, so the caret never lands
-- inside a colour escape), carries its own red error line under the box, and
-- with `spec.default` a two-click-confirm Reset button above it. Its spec:
--   width, height, text, colors, font = {path, size, flags},
--   onChange(code)   -- every keystroke, uncommitted
--   onCommit(code)   -- focus lost, or a confirmed reset
--   validate(code)   -- returns an error string or nil; drives the error line
--   default          -- string or function; Reset appears only when set
--   live             -- colour per keystroke instead of on blur (see below)
--   tabWidth         -- spaces per indent level, or false for hard tabs
-- Tab re-indents the whole buffer. Methods: setText/getText/clearFocus/setSize/
-- indent, plus setValidate/setDefault/setHandlers/setLive/setTabWidth for a
-- consumer that pools and rebinds one instance.
--
-- `live` colours under the caret while typing, which needs the caret saved and
-- restored around every recolour; it is off unless asked for.
--
-- It also carries one non-widget group, at the bottom of this file: a Lua
-- source tokenizer and the syntax-colouring helpers built on it (LuaColorize,
-- LuaEncode/LuaDecode, LuaStripColors, LuaPadWithLinebreaks). They live here
-- because the code edit box that uses them is library code; they are pure
-- string -> string and touch no frame.
--
-- Every caller-specific bit of NewListEditor -- the backing list, how to
-- reorder/remove an entry, how to paint the name/leading control/any
-- trailing columns, and the absolute path to this library's own textures --
-- comes through the `spec` table (documented below), so this file has no
-- knowledge of any particular addon's data model and holds no addon-specific
-- state of its own.
--
-- Registered through LibStub (as "LibWidgets-1.0") so multiple addons
-- vendoring their own copy of this file coexist safely: whichever copy
-- declares the highest MINOR becomes the one shared instance regardless of
-- load order, and every other copy's body no-ops immediately below.
--
-- Vendored as its own Libs\LibWidgets\ folder (own .lua, own textures)
-- rather than a loose file in the addon root. A consuming addon's .toc must
-- list every .lua file this library is made of directly (today just this
-- one) -- there is no single manifest file a consumer can reference once to
-- pull in the whole library, since this client does not process nested
-- <Script>/<Include> directives from a referenced .xml file. manifest.ps1
-- (beside this file) is a packaging-time helper only: it lists this
-- library's shippable files (.lua + textures) so a consumer's own packaging
-- script can include exactly those files without recursively copying this
-- whole folder, which would also capture files that don't belong in a
-- shipped addon (such as version-control metadata now that this folder is a
-- git submodule).
--
-- NewButton(parent, spec) -- a flat, tooltip-backdrop-styled action button (the
-- same look as the list editor's reorder/delete/leading-control buttons). spec:
--   text, width, height (default 22), onClick
-- Returns the button with a `.label` FontString and a `.setText(text)` method for
-- relabeling later (e.g. a button whose face shows a live value).
--
-- NewIconButton(parent, spec) -- the small texture-faced button the list editor's
-- own rows use (reorder/delete), for a caller needing the same control outside a
-- list (e.g. a collapse arrow or a delete affordance on a section header). spec:
--   icon      -- texture path (LibWidgets.ICON_DELETE is the list editor's own
--                delete art, published so both read the same)
--   width (default 20), height (default 18), iconSize (default 11)
--   onClick
-- Returns the button with its texture as `.icon`, so a toggle can re-SetTexture it.
--
-- NewCheckBox(parent, spec) -- a standalone labelled checkbox (UICheckButtonTemplate
-- plus a right-hand label). spec:
--   text, width/height (default 22)
--   onClick(checked) -- called on a user toggle with the new boolean state
--   get()            -- optional: seeds the initial checked state
-- Returns the CheckButton with a `.label` FontString and a `.setChecked(on)` method
-- that resyncs from external state without firing onClick.
--
-- NewColorSwatch(parent, spec) -- a swatch button that opens the stock
-- ColorPickerFrame (with opacity). spec:
--   get() -> {r,g,b,a}   -- current colour (a defaults to 1 if absent)
--   set({r,g,b,a})       -- store a picked colour
--   width/height (default 20), swatchSize (inner fill, default 14)
-- Returns the button with a `.repaint()` method to re-read get() after an
-- external change.
--
-- NewTextBox(parent, spec) -- a single-line edit box with a tooltip-style backdrop
-- (not InputBoxTemplate -- that template's border textures render a black bar at
-- small heights). spec:
--   width (omit to size purely from the caller's own anchors, e.g. a box anchored
--   on both TOPLEFT and RIGHT), height (default 22), text (initial contents)
--   onCommit(text) -- called on Enter (the box then clears focus); Escape clears
--                     focus with no commit. Omit for a read-only display box.
--   onChange(text) -- optional: called on every keystroke (live filtering); fires
--                     on user edits, not on the initial `text` seed.
--   hint           -- optional: greyed placeholder text shown while the box is empty.
--
-- NewMultiLineEditBox(parent, spec) -- a scrollable multi-line edit box (a
-- UIPanelScrollFrameTemplate ScrollFrame wrapping a SetMultiLine EditBox) with
-- the same tooltip-style backdrop, for paste-in/copy-out blobs (import/export).
-- spec:
--   width (default 300), height (default 150), text (initial contents)
--   onChange(text) -- optional: called on every edit
-- Returns the outer frame with methods `.setText(t)`, `.getText()`,
-- `.focusSelectAll()` (focus + highlight everything, so the user can Ctrl-C an
-- export immediately) and `.clearFocus()`, plus the `.edit` EditBox itself.
--
-- NewSlider(parent, spec) -- a horizontal OptionsSliderTemplate slider whose title
-- carries the live value instead of the template's Low/High end labels. spec:
--   name          -- unique global frame name (the template needs one to address
--                    "<name>Low"/"<name>High"/"<name>Text")
--   min, max, step, width (default 150)
--   onChange(v)   -- called on every user drag, and on a committed edit-box entry
--                    when `editable` is set
--   format(v)     -- optional: -> the full title text (defaults to the number
--                    rounded to `decimals` places)
--   decimals      -- max decimal places shown in the default title format and the
--                    editable box's display (default 2); trailing zeros are
--                    trimmed (1 shows as "1", not "1.00"). The same rounding is
--                    available standalone as LibWidgets.FormatNumber(v, decimals)
--                    for a caller building its own `format`.
--   get()         -- optional: seeds the initial value through the same guard
--                    `.setValue` uses, so seeding never echoes through onChange
--   editable      -- optional: adds a small edit box to the right of the slider
--                    bar showing the current value, editable directly (commits on
--                    Enter, clamped to min/max, rounded to `decimals`); the bar
--                    itself narrows by `inputWidth` + gap to keep the total
--                    footprint at `width`
--   inputWidth    -- width of that edit box (default 44)
-- Returns the slider with a `.setValue(v)` method: sets the value and repaints the
-- title (and the edit box, if any) without firing onChange, for resyncing the
-- widget from external state.
--
-- NewSpinBox(parent, spec) -- a number control that can be dragged, typed into or
-- stepped: a caption above a filled track, the value centred inside the track as
-- an edit box, and a step button just outside each end of it. Drag for coarse,
-- type for exact, step for fine, in one control the width of the row -- a plain
-- slider can only be dragged, which cannot reach a specific number across a wide
-- range. spec:
--   label         -- caption above the track
--   min, max, step, width (default 150)
--   softMax       -- optional: the top of the *track*, where that is lower than
--                    the highest value the field accepts. Dragging and stepping
--                    stay within min..softMax; a typed number may go past it, up
--                    to `max` where one is given and without limit where it is
--                    not. A value already above the track keeps the fill pinned
--                    full and the up-step disabled, and a move may not raise it
--                    further. Without a softMax the track spans min..max, so a
--                    field that wants a hard ceiling simply omits it.
--   textureDir    -- absolute path to this library's textures\ (see the
--                    no-self-path note below); the two step buttons are the
--                    shared `up` arrow given a quarter turn each
--   onChange(v)   -- called on a user drag, a step, and a committed typed value;
--                    never on `.setValue` or the `get` seed, and never for an
--                    edit that lands on the value already shown
--   fmt(v)        -- optional: -> the text shown in the box (defaults to the
--                    number rounded to `decimals` places). A format the box
--                    cannot parse back makes it read-only in practice, since a
--                    typed value that fails tonumber reverts.
--   decimals      -- max decimal places in the default box text (default 2)
--   get()         -- optional: seeds the initial value through `.setValue`
-- Typing commits on Enter and on focus loss, reverts on Escape, and snaps and
-- clamps to min/max/step -- so the box can never hold a value the slider half of
-- the control could not have produced, `softMax` above being the one deliberate
-- exception to that. Returns the frame with `.setValue(v)`
-- (resync without firing onChange), `.getValue()`, `.setWidth(w)` (the whole
-- control, buttons included -- the track takes what is left), `.edit` (the edit
-- box, for a pooling consumer that must clear focus before rebinding), `.label`
-- and `.stepDown`/`.stepUp`.
--
-- NewScrollFrame(parent, spec) -- a chrome-free vertical content scroller: a plain
-- ScrollFrame (no Blizzard scroll template) with a slim tinted right-edge slider
-- and mouse wheel, for scrolling arbitrary content that can outgrow its frame.
-- spec:
--   wheelStep   -- pixels scrolled per wheel notch (default 30)
--   sliderInset -- x-nudge of the slider from the frame's right edge (default 0)
-- The caller anchors the returned ScrollFrame, parents its content into the
-- `.content` scroll child (managing that child's width itself -- reserve a few px
-- on the right for the slider), sets `.content`'s height, then calls `.Update()`
-- so the slider re-fits (again after any later content-height or frame-size
-- change). `.Update(viewH)` takes the viewport height explicitly, which a caller
-- sizing this frame by anchors rather than SetHeight must do -- see the comment
-- on Update. Also exposes `.slider` and `.wheel` (the wheel handler, so a child
-- that captures wheel focus -- e.g. a button -- can forward to it via SetScript).
--
-- NewDropButton(parent, spec) -- a button showing the current value that drops a
-- popup list of options to change it (no cycling). spec:
--   width, height (button size; height defaults to 20)
--   menuWidth (defaults to width), itemHeight (defaults to 14)
--   maxVisibleItems -- popup caps at this many rows (default 8) and scrolls the
--                    rest via a slim right-edge slider + mouse wheel; shorter
--                    menus size to fit with no slider
--   values        -- ordered array of stored values (menu order), or a function
--                    returning one: the menu rebuilds on every open (dynamic sets,
--                    e.g. profile names)
--   labels        -- value -> display label; optional (defaults to the raw value)
--   tips          -- value -> tooltip line; optional
--   previews      -- value -> true; adds a per-row preview button
--   previewTexture -- texture path for the preview button; optional, and defaults
--                    to PREVIEW_TEXTURE below
--   onPreview(v)  -- called by a row preview without selecting or closing
--   swatches      -- optional: value -> texture path. Turns the picker into a
--                    preview picker: the button's face and every menu entry draw
--                    that texture as a filled green bar behind the label, so a
--                    bar-texture choice is judged by how it actually looks rather
--                    than by its name. Menu rows grow to `itemHeight` 20 by
--                    default so a swatch is legible. (Lookups go through the table
--                    on every paint, so a caller recycling one button across
--                    fields can hand in a proxy table that forwards to whichever
--                    field is currently bound, the same way `labels` does.)
--   onSelect(v)   -- called when a menu entry is picked
--   textureDir    -- optional: absolute path to this library's textures folder. When
--                    given, a down-arrow (grey at rest, green on hover) is drawn on
--                    the button's right edge to signal it opens a menu.
--   get()         -- optional: when given, the button self-paints from it on build
--                    and after each pick via `.setValue`. Omit it for a caller that
--                    repaints recycled instances itself each draw (`.setValue(v)`
--                    works either way).
--   menuParent, menuStrata -- override the popup's parent/strata. By default the
--                    popup is hosted on the button's top-level ancestor frame (the
--                    one parented straight to UIParent) at "FULLSCREEN_DIALOG",
--                    NOT on the button: parented under the button, a popup dropped
--                    from a control inside a ScrollFrame gets clipped where it
--                    overflows the scroll region and shares the rows' strata,
--                    landing behind the controls below it. It still anchors its
--                    position to the button, so it tracks it.
-- The popup is toplevel'd so it orders above sibling same-strata popups on
-- interaction; its high strata already puts it above the host panel. It is
-- deliberately NOT re-levelled on open -- see the open handler for why.
-- The live value is stashed on `.value` for the button's own hover tooltip. At
-- most one NewDropButton popup is ever open at once -- see CloseAllMenus below.
--
-- CloseAllMenus() -- hides whichever NewDropButton popup is currently open, if
-- any, and drops edit focus. Every widget this library builds calls it on
-- interaction (see the comment above its definition for why -- there is no
-- generic focus-lost event to hook instead), so a menu closes and a focused
-- edit box commits the moment anything else in the library is touched. A
-- consuming addon's own panel can call it too (e.g. on OnMouseDown for a
-- blank-area click, or OnHide so a menu left open under a closed panel doesn't
-- pop back up still expanded next time it opens).
--
-- ClearFocus() -- the focus half of CloseAllMenus on its own, for a caller that
-- must leave an open menu alone.
--
-- NewIconPicker(parent, spec) -- a modal icon browser: a live search box over a
-- scrolling grid of every icon the client knows, with a preview of the current
-- pick and Okay/Cancel/Clear. Built once and reused -- `.Open(current)` refills
-- and shows it, `.Close()` hides it. Only columns*visibleRows cell buttons ever
-- exist; they are repainted as the grid scrolls, so a ~5000-icon database costs
-- a fixed number of frames. spec:
--   nameFrame    -- REQUIRED: global frame name for the FauxScrollFrame (its
--                   scrollbar child is addressed by name); the dialog itself
--                   takes "<nameFrame>Dialog"
--   onAccept(path, name) -- the pick, as a full texture path and as the bare
--                   uppercase basename; called with ("", nil) for Clear
--   icons()      -- optional: the array to browse (paths or basenames), for a
--                   caller with its own source. Defaults to the client's macro
--                   icon database (LibWidgets.GetIconDatabase)
--   title, searchHint, acceptText, cancelText, clearText -- captions
--   columns (10), visibleRows (7), iconSize (30)
--   dialogParent -- parent frame (default UIParent); pass the owning panel so
--                   closing it takes the dialog down too
--   strata (FULLSCREEN_DIALOG), onClose()
--
-- LibWidgets.GetIconDatabase() -- the client's icon list as uppercase basenames
-- (no path, no extension), built once per session. Prefers ClassicAPI's
-- GetMacroIcons/GetMacroItemIcons/GetLoose* enumerators and falls back to
-- vanilla's GetNumMacroIcons/GetMacroIconInfo, which only knows Ability_*/
-- Spell_* and lists no item icons at all.
-- LibWidgets.IconPath(name) -- that basename back to a texture path.
--
-- LibWidgets.BAR_TEXTURES -- the ordered status-bar texture names a bar-texture
-- picker offers ("Flat" and "Blizzard" first, then the bundled set). Pair with
-- LibWidgets.BarTexturePath(dir, name) -> a texture path, where `dir` is the
-- caller's own bars folder ("Interface\AddOns\<addon>\textures\bars\"); "Flat"
-- (a solid fill, no grain) and "Blizzard" resolve to stock client art and ignore
-- `dir`. Feed the list to
-- NewDropButton's `values` and a name->path map built from it to `swatches` for a
-- previewing texture picker. Same reasoning as `textureDir`: this file cannot
-- discover its own path at runtime, so the art location is the caller's to supply.
--
-- NewListEditor(parent, spec) -- spec fields:
--   nameFrame     -- unique string naming the internal ScrollFrame (1.12's
--                    FauxScrollFrameTemplate needs an addressable global name
--                    for its scrollbar child, "<nameFrame>ScrollBar")
--   textureDir    -- absolute path to this library's own textures folder
--                    (e.g. "Interface\AddOns\<addon>\Libs\LibWidgets\textures\").
--                    WoW texture paths are always absolute and this file has
--                    no way to discover its own path at runtime, so each
--                    caller supplies it like any other spec field.
--   x, y          -- TOPLEFT offset from `parent`
--   rightInset    -- RIGHT inset from `parent` (default 16)
--   rowHeight, visibleRows -- when visibleRows >= #list() the scrollbar just
--                    stays inert, so a "fixed, never scrolls" list (e.g. one
--                    row per class) needs no special casing here.
--   list()                     -> the live ordered array, read fresh each refresh
--   reorder(fromIndex, before) -- before is a boundary in 1..n+1: the entry
--                    ends up just before whatever currently sits at original
--                    index `before`. Used by both the arrow buttons and
--                    drag-drop.
--   remove(index)              -- optional; omit to hide the delete button
--   add = { onAdd(text) }      -- optional; builds an edit box + Add button
--                    below the list (children of the returned `frame`, so
--                    hiding it hides them too)
--   leadingControl             -- optional:
--       { kind = "tristate", states = { {key=,color={r,g,b},tooltip=}, ... },
--         get(entry) -> key, cycle(entry) }
--     or
--       { kind = "checkbox", get(entry) -> bool, set(entry, bool) }
--   nameGet(entry) -> text
--   nameColor(entry, index) -> r, g, b               -- optional
--   columns = { { width, build(row) -> widget, update(widget, entry, index, count) }, ... }
--                    -- optional trailing per-row widgets; not used by any
--                    current caller, but the hook for future per-row data.
--
-- Returns { height = <total pixel height used below (x,y)>, refresh = fn,
--           frame = <the list's outer frame> }.

local MAJOR, MINOR = "LibWidgets-1.0", 21
-- Bind the global only on the winning copy. NewLibrary returns nil for a copy
-- that loses the version race; assigning that nil straight to the global would
-- wipe out the winner's binding (an older/equal copy loading last nulls it),
-- so keep the return in a local and publish only when we actually won.
-- Registration diagnostics, captured before the call and published below for a
-- consumer's own version report: what was already registered under this major,
-- and how this MINOR survives each of the two pattern functions LibStub
-- implementations use to parse it. Worth keeping because the failure they
-- describe is silent -- a copy that loses the race and doesn't load presents as
-- a library inexplicably missing a function, never as a version problem.
local preMinor = LibStub.minors and LibStub.minors[MAJOR]
local parseMatch = string.match and tonumber(string.match(MINOR, "%d+"))
local _, _, findCapture = string.find(MINOR, "(%d+)")

local lib, displaced = LibStub:NewLibrary(MAJOR, MINOR)
local overridden = false   -- LIBWIDGETS_DEV forced this copy in
local repaired = false     -- LibStub's verdict contradicted its own bookkeeping

if not lib then
	local existing, recordedMinor = LibStub:GetLibrary(MAJOR, true)
	if existing then
		-- LibStub's verdict is not trustworthy on every client. One in the wild
		-- assigns the minor a constant before comparing, discarding what it was
		-- handed: every major records that same constant, every registration
		-- after the first is refused, and `minors` says nothing about what is
		-- actually loaded. Version arbitration therefore can't be delegated to
		-- LibStub -- each copy publishes its own version as `.MINOR` on the
		-- shared table, and that is the number compared here. A copy predating
		-- that field publishes nothing and is treated as older than anything,
		-- which is correct: it is.
		local liveMinor = existing.MINOR or recordedMinor or 0
		if liveMinor < MINOR then
			-- Strictly newer than what's loaded: take over. This is the normal
			-- upgrade path, not a workaround, and it is safe to ship precisely
			-- because it never displaces an equal or newer copy.
			lib, displaced, repaired = existing, liveMinor, true
			LibStub.minors[MAJOR] = MINOR
		elseif LIBWIDGETS_DEV then
			-- Dev override: take over even from an equal or newer copy. Needed
			-- because addons sharing one submodule normally sit at *equal*
			-- MINOR, where nothing above applies and edits to this checkout
			-- appear to do nothing -- everything still working, from someone
			-- else's copy. Don't ship with it set.
			lib, displaced, overridden = existing, liveMinor, true
			LibStub.minors[MAJOR] = MINOR
		end
	end
end
if not lib then return end
LibWidgets = lib
-- Published so a consumer can report which copy actually won (a mismatch is
-- otherwise invisible until a missing function blows up mid-call).
-- DEV_OVERRIDE distinguishes the two ways this copy can end up live: won the
-- version race on its own, or only because LIBWIDGETS_DEV forced it. Without
-- that flag recorded, the two are indistinguishable after the fact -- the
-- override sets the registered minor to this copy's own, so the numbers look
-- identical either way.
LibWidgets.MINOR = MINOR
LibWidgets.DEV_OVERRIDE = overridden
LibWidgets.REPAIRED = repaired
-- The minor that was registered before this copy took over (nil = none).
LibWidgets.DISPLACED_MINOR = displaced
LibWidgets.PRE_MINOR = preMinor
LibWidgets.PARSE_MATCH = parseMatch
LibWidgets.PARSE_FIND = tonumber(findCapture)

local BTN_W   = 20
local BTN_GAP = 2
local COL_GAP = 6
local STATE_W = 20

-- Rounds to `decimals` places and trims trailing zeros (and a bare trailing
-- "." if decimals rounded away entirely), so an integer value reads as "1"
-- rather than "1.00" while a fractional one still shows up to `decimals`
-- places -- NewSlider's default title/edit-box formatting.
local function formatNumber(v, decimals)
	local s = string.format("%." .. (decimals or 2) .. "f", v)
	if string.find(s, "%.") then
		s = string.gsub(s, "0+$", "")
		s = string.gsub(s, "%.$", "")
	end
	return s
end
LibWidgets.FormatNumber = formatNumber

local WIDGET_BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 9,
	insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

local ICON_DELETE = "Interface\\Buttons\\UI-GroupLoot-Pass-Up"

-- NewDropButton's default row-preview glyph: the client's guild-MOTD horn, which
-- reads as "play this" and is 16x16, the size a preview button draws it at.
--
-- A client path rather than a file under `textures\`, and deliberately so. This
-- library cannot resolve its own location (see the self-path note in the header),
-- so anything it ships is reachable only through a `spec.textureDir` the caller
-- has to supply -- which a *default* cannot require. It also lives in the base
-- `interface.MPQ` rather than a patch archive, so it is present on any client this
-- library runs on.
local PREVIEW_TEXTURE = "Interface\\Buttons\\UI-GuildButton-MOTD-Up"

local MOVE_OK   = { 0.2, 0.9, 0.2 }
local MOVE_NONE = { 0.5, 0.5, 0.5 }

-- Only one NewDropButton popup is ever open at a time. 1.12 has no generic
-- focus-lost event for a plain Button/Slider/CheckButton (only EditBox has
-- OnEditFocusGained/Lost), so there is no reliable way to detect "some other
-- control just gained focus" from the outside. Instead every interactive
-- widget this library builds calls CloseAllMenus() as the first thing it
-- does on interaction (a click, a drag-start, an edit box gaining focus), so
-- touching *anything* else in the library always closes a still-open menu --
-- this is an explicit, not passive, close rather than a screen-covering
-- click-catcher, so it never costs the "click a different drop button"
-- case an extra click the way a catcher would. The one gap this doesn't
-- cover is a click that lands on nothing interactive at all (bare panel
-- background, or outside the addon's own frames entirely); a consuming
-- addon can close that gap too by wiring its own panel's OnMouseDown to
-- LibWidgets.CloseAllMenus().
--
-- Edit focus rides the same signal, for the same reason. Only an EditBox is
-- told it lost focus, so a box the user clicked away from keeps focus -- and
-- with it whatever it commits on blur -- indefinitely. CloseAllMenus therefore
-- drops it too: "the user touched something else" is one event here, and every
-- call site that wants a menu closed wants a stale caret gone as well.
local activeMenu = nil
local focusedEdit = nil

-- Drops edit focus alone, for a caller that must not disturb an open menu.
-- Clearing focus on a box that no longer has it does nothing, so a stale
-- `focusedEdit` (a consumer replacing an OnEditFocusLost handler, say) costs
-- nothing beyond a wasted call.
function LibWidgets.ClearFocus()
	local e = focusedEdit
	focusedEdit = nil
	if e then e:ClearFocus() end
end

function LibWidgets.CloseAllMenus()
	if activeMenu then activeMenu:Hide() end
	activeMenu = nil
	LibWidgets.ClearFocus()
end

-- What every OnEditFocusGained in this file calls. The recorded box is dropped
-- *before* the menus close, not cleared: the engine has already taken focus off
-- whoever held it, and clearing a recorded box that is the one now gaining
-- focus would fire its own focus-lost handler underneath it -- an inline rename
-- box reopened on a second row closes itself that way.
local function takeFocus(e)
	focusedEdit = nil
	LibWidgets.CloseAllMenus()
	focusedEdit = e
end

-- Flat, tooltip-backdrop-styled button base shared by the reorder/delete/
-- leading-control buttons.
local function styleFlatButton(b)
	b:SetBackdrop(WIDGET_BACKDROP)
	b:SetBackdropColor(0, 0, 0, 0.7)
	b:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
	b:SetScript("OnEnter", function() this:SetBackdropBorderColor(0.9, 0.8, 0.2, 1) end)
	b:SetScript("OnLeave", function() this:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8) end)
end

-- Reorder/delete icon button. Overrides styleFlatButton's hover so a disabled
-- button (row 1's "up", the last row's "down") doesn't brighten on hover.
local function iconButton(parent, icon, onClick, width, height, iconSize)
	local b = CreateFrame("Button", nil, parent)
	b:SetWidth(width or BTN_W); b:SetHeight(height or 18)
	styleFlatButton(b)
	local t = b:CreateTexture(nil, "ARTWORK")
	t:SetWidth(iconSize or 11); t:SetHeight(iconSize or 11)
	t:SetPoint("CENTER", 0, 0)
	t:SetTexture(icon)
	b.icon = t
	b:SetScript("OnEnter", function() if this:IsEnabled() == 1 then this:SetBackdropBorderColor(0.9, 0.8, 0.2, 1) end end)
	b:SetScript("OnLeave", function() this:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8) end)
	b:SetScript("OnMouseDown", function() this.icon:SetPoint("CENTER", 1, -1) end)
	b:SetScript("OnMouseUp", function() this.icon:SetPoint("CENTER", 0, 0) end)
	b:SetScript("OnClick", function() LibWidgets.CloseAllMenus(); onClick() end)
	return b
end

-- The same small icon button the list editor's own rows use, as a public
-- widget; see the header comment for spec. `.icon` is the texture, so a caller
-- repainting a toggle (an expand/collapse arrow) just re-SetTextures it.
function LibWidgets.NewIconButton(parent, spec)
	spec = spec or {}
	return iconButton(parent, spec.icon, spec.onClick or function() end,
		spec.width, spec.height, spec.iconSize)
end

-- The delete-row art the list editor uses, published so a consumer's own
-- delete affordance outside a list reads as the same control.
LibWidgets.ICON_DELETE = ICON_DELETE
LibWidgets.PREVIEW_TEXTURE = PREVIEW_TEXTURE

-- Leading tristate chip: a colour-tinted circle swatch that cycles through
-- leadingControl.states on click. iconPath is the caller's spec.textureDir-
-- resolving helper (see LibWidgets.NewListEditor), passed in rather than closed over
-- since this factory is shared across every instance.
local function buildTristate(row, lc, iconPath)
	local b = CreateFrame("Button", nil, row)
	b:SetWidth(STATE_W); b:SetHeight(18)
	styleFlatButton(b)
	local sw = b:CreateTexture(nil, "ARTWORK")
	sw:SetWidth(12); sw:SetHeight(12)
	sw:SetPoint("CENTER", 0, 0)
	sw:SetTexture(iconPath("circle"))
	b:SetScript("OnClick", function()
		LibWidgets.CloseAllMenus()
		if row.entry ~= nil then lc.cycle(row.entry) end
	end)
	b:SetScript("OnEnter", function()
		this:SetBackdropBorderColor(0.9, 0.8, 0.2, 1)
		if b.tip then
			GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
			GameTooltip:AddLine(b.tip)
			GameTooltip:AddLine("Click to change", 0.5, 0.5, 0.5)
			GameTooltip:Show()
		end
	end)
	b:SetScript("OnLeave", function() this:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8); GameTooltip:Hide() end)
	b.paint = function(entry)
		local key = lc.get(entry)
		for i = 1, table.getn(lc.states) do
			local st = lc.states[i]
			if st.key == key then
				sw:SetVertexColor(st.color[1], st.color[2], st.color[3])
				b.tip = st.tooltip
			end
		end
	end
	return b
end

-- Leading checkbox: a plain enable/disable toggle.
local function buildCheckbox(row, lc)
	local b = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
	b:SetWidth(STATE_W); b:SetHeight(18)
	b:SetScript("OnClick", function()
		LibWidgets.CloseAllMenus()
		if row.entry ~= nil then lc.set(row.entry, this:GetChecked() and true or false) end
	end)
	b.paint = function(entry) b:SetChecked(lc.get(entry) and true or false) end
	return b
end

-- A flat action button in the shared style; see the header comment for spec.
function LibWidgets.NewButton(parent, spec)
	spec = spec or {}
	local b = CreateFrame("Button", nil, parent)
	b:SetWidth(spec.width or 80); b:SetHeight(spec.height or 22)
	styleFlatButton(b)
	local fs = b:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	fs:SetPoint("CENTER", 0, 0)
	fs:SetText(spec.text or "")
	b.label = fs
	function b.setText(text) fs:SetText(text or "") end
	b:SetScript("OnMouseDown", function()
		LibWidgets.CloseAllMenus()
		this.label:SetPoint("CENTER", 1, -1)
	end)
	b:SetScript("OnMouseUp", function() this.label:SetPoint("CENTER", 0, 0) end)
	if spec.onClick then b:SetScript("OnClick", spec.onClick) end
	return b
end

-- A NewButton carrying the lit "selected" look a tab needs, plus the `value`
-- identifying it to its strip. The selected tab ignores hover, so the active
-- one stays lit rather than dimming when the pointer crosses it.
function LibWidgets.NewTabButton(parent, spec)
	spec = spec or {}
	local b = LibWidgets.NewButton(parent, {
		text = spec.text, onClick = spec.onClick,
		width = spec.width, height = spec.height or 22,
	})
	b.value = spec.value
	function b.setSelected(on)
		b.selected = on and true or false
		if b.selected then
			b:SetBackdropColor(0.22, 0.20, 0.05, 0.95)
			b:SetBackdropBorderColor(0.9, 0.8, 0.2, 1)
			b.label:SetTextColor(1, 1, 1)
		else
			b:SetBackdropColor(0, 0, 0, 0.7)
			b:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
			b.label:SetTextColor(0.7, 0.7, 0.7)
		end
	end
	b:SetScript("OnEnter", function() if not this.selected then this:SetBackdropBorderColor(0.9, 0.8, 0.2, 1) end end)
	b:SetScript("OnLeave", function() if not this.selected then this:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8) end end)
	b.setSelected(false)
	return b
end

-- A self-laying-out row of tab buttons; see the header comment for spec.
--
-- The layout is AceGUI's TabGroup:BuildTabs: measure each tab from its own
-- text, wrap greedily, pull a lone last tab up beside its neighbours, then
-- stretch a row to fill. Dividing the width equally instead is the obvious
-- alternative and it does not survive a strip growing past a handful of tabs --
-- every tab shrinks to the narrowest one's needs, and a label with no width set
-- does not clip on this client, it overflows into its neighbours.
function LibWidgets.NewTabStrip(parent, spec)
	spec = spec or {}
	local frame = CreateFrame("Frame", nil, parent)
	local gap = spec.gap or 4
	local rowGap = spec.rowGap or 4
	local rowHeight = spec.rowHeight or 22
	local padding = spec.padding or 16
	local minWidth = spec.minWidth or 24
	local fillRatio = spec.fillRatio or 0.75
	local width = spec.width or 100
	frame:SetWidth(width)
	frame:SetHeight(rowHeight)

	local buttons, tabs = {}, {}
	local rows, selected = 0, nil
	frame.buttons = buttons

	local function layout()
		local shown, w = {}, {}
		for i = 1, table.getn(tabs) do
			if tabs[i].hidden then
				buttons[i]:Hide()
			else
				buttons[i]:Show()
				table.insert(shown, buttons[i])
			end
		end
		local n = table.getn(shown)
		for i = 1, n do
			local sw = (shown[i].label:GetStringWidth() or 0) + padding
			if sw < minWidth then sw = minWidth end
			w[i] = sw
		end

		-- Greedy wrap. A row never breaks before its own first tab, so one too
		-- wide for the strip gets a row to itself instead of disappearing.
		local rowEnd, rowWidth = {}, {}
		local used, r = 0, 1
		for i = 1, n do
			if used ~= 0 and used + gap + w[i] > width then
				rowWidth[r] = used
				rowEnd[r] = i - 1
				r = r + 1
				used = w[i]
			else
				used = used + (used == 0 and 0 or gap) + w[i]
			end
		end
		rowWidth[r] = used
		rowEnd[r] = n
		local numRows = n > 0 and r or 0

		-- A single tab alone on the last row reads as a mistake rather than as a
		-- second row, so pull one down to keep it company when the row above can
		-- spare it and the last row has room. (Ace's own second guard here is
		-- redundant given the first; this is the intent, not a transcription.)
		if numRows > 1 and rowEnd[numRows] - rowEnd[numRows - 1] == 1 then
			local prevStart = numRows > 2 and rowEnd[numRows - 2] or 0
			local prevCount = rowEnd[numRows - 1] - prevStart
			local moving = w[rowEnd[numRows - 1]]
			if prevCount > 2 and rowWidth[numRows] + gap + moving <= width then
				rowEnd[numRows - 1] = rowEnd[numRows - 1] - 1
				rowWidth[numRows] = rowWidth[numRows] + gap + moving
				rowWidth[numRows - 1] = rowWidth[numRows - 1] - gap - moving
			end
		end

		local first = 1
		for row = 1, numRows do
			local last = rowEnd[row]
			local count = last - first + 1
			-- Stretching a nearly-full row to the edge tidies it; stretching a
			-- sparse one balloons two tabs across the whole strip, which is worse
			-- than a ragged right edge. Ace applies this test only to a lone row;
			-- per row is the same rule read one level down, and it is what keeps a
			-- short second row looking like tabs.
			-- Never negative: a row can hold one tab wider than the whole strip
			-- (it cannot break before its first), and sharing that overrun out as
			-- a squeeze would push every label back outside its own button --
			-- the failure measuring the labels exists to avoid. Let it overhang.
			local extra = 0
			if rowWidth[row] >= width * fillRatio and width > rowWidth[row] then
				extra = math.floor((width - rowWidth[row]) / count)
			end
			local x = 0
			for i = first, last do
				local b = shown[i]
				b:SetWidth(w[i] + extra)
				b:SetHeight(rowHeight)
				b:ClearAllPoints()
				b:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -(row - 1) * (rowHeight + rowGap))
				x = x + w[i] + extra + gap
			end
			first = last + 1
		end

		rows = numRows
		local h = numRows > 0 and (numRows * rowHeight + (numRows - 1) * rowGap) or 0
		frame:SetHeight(h > 0 and h or 1)
		if spec.onReflow then spec.onReflow(numRows, h) end
	end

	-- Buttons are pooled by index and rebound rather than rebuilt: frames cannot
	-- be destroyed on this client, so a strip rebuilt per selection change would
	-- leak one button per tab every time.
	function frame.setTabs(list)
		tabs = list or {}
		for i = 1, table.getn(tabs) do
			local b = buttons[i]
			if not b then
				b = LibWidgets.NewTabButton(frame, {
					height = rowHeight,
					onClick = function()
						if spec.onSelect then spec.onSelect(b.value) end
					end,
				})
				buttons[i] = b
			end
			b.setText(tabs[i].text or "")
			b.value = tabs[i].value
		end
		for i = table.getn(tabs) + 1, table.getn(buttons) do
			buttons[i]:Hide()
		end
		layout()
		frame.select(selected)
	end

	-- nil deselects every tab, which is a real state: a panel showing something
	-- that belongs to no tab has no tab to light.
	function frame.select(value)
		selected = value
		for i = 1, table.getn(buttons) do
			buttons[i].setSelected(value ~= nil and buttons[i].value == value)
		end
	end

	function frame.getSelected() return selected end
	function frame.getRows() return rows end

	function frame.setWidth(w)
		width = w
		frame:SetWidth(w)
		layout()
	end

	if spec.tabs then frame.setTabs(spec.tabs) end
	return frame
end

-- A standalone labelled checkbox; see the header comment for spec.
function LibWidgets.NewCheckBox(parent, spec)
	spec = spec or {}
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetWidth(spec.width or 22); cb:SetHeight(spec.height or 22)
	local fs = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	fs:SetText(spec.text or "")
	cb.label = fs
	cb:SetScript("OnClick", function()
		LibWidgets.CloseAllMenus()
		if spec.onClick then spec.onClick(this:GetChecked() and true or false) end
	end)
	-- Resync from external state without echoing back through onClick (OnClick
	-- fires only on a user click, not SetChecked).
	function cb.setChecked(on) cb:SetChecked(on and true or false) end
	if spec.get then cb:SetChecked(spec.get() and true or false) end
	return cb
end

-- A compact nine-point anchor picker. The outer frame owns the border and the
-- buttons are created once; repainting only changes their points, colour and
-- selected state, so a consumer can safely pool the whole widget.
function LibWidgets.NewAnchorGrid(parent, spec)
	spec = spec or {}
	local frame = CreateFrame("Frame", nil, parent)
	frame:SetWidth(spec.width or 100)
	frame:SetHeight(spec.height or 50)
	frame:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		tile = true, tileEdge = true, edgeSize = 1,
	})
	frame:SetBackdropColor(0.2, 0.2, 0.2, 0.5)
	frame:SetBackdropBorderColor(1, 1, 1, 0.6)
	local buttons = {}
	local values = spec.values or {}
	local bindValue = spec.get
	local bindSelect = spec.onSelect
	for i = 1, 9 do
		local index = i
		local b = CreateFrame("Button", nil, frame)
		b:SetWidth(10); b:SetHeight(10)
		local t = b:CreateTexture(nil, "ARTWORK")
		t:SetAllPoints(b)
		b.texture = t
		b:SetScript("OnClick", function()
			LibWidgets.CloseAllMenus()
			local value = values[index]
			if frame.setValue then frame.setValue(value) end
			if bindSelect then bindSelect(value) end
		end)
		buttons[i] = b
	end
	local function layout()
		local width, height = frame:GetWidth(), frame:GetHeight()
		for i = 1, 9 do
			local b = buttons[i]
			b:ClearAllPoints()
			b:SetPoint("CENTER", frame, values[i])
		end
	end
	local function paint(value)
		for i = 1, 9 do
			local selected = values[i] == value
			if selected then
				buttons[i].texture:SetTexture(0.95, 0.75, 0.15, 1)
			else
				buttons[i].texture:SetTexture(0.5, 0.5, 0.5, 0.9)
			end
		end
		frame.value = value
	end
	function frame.setValue(value) paint(value) end
	function frame.setBindings(newValues, get, onSelect)
		values = newValues or values
		bindValue, bindSelect = get, onSelect
	end
	function frame.setSize(width, height)
		frame:SetWidth(width); frame:SetHeight(height); layout()
	end
	frame.buttons = buttons
	layout()
	paint(bindValue and bindValue())
	return frame
end

-- A colour swatch opening the stock ColorPickerFrame; see the header comment
-- for spec. OpacitySliderFrame reports 1-alpha, hence the inversions.
function LibWidgets.NewColorSwatch(parent, spec)
	spec = spec or {}
	local get, set = spec.get, spec.set
	local sz = spec.swatchSize or 14
	local b = CreateFrame("Button", nil, parent)
	b:SetWidth(spec.width or 20); b:SetHeight(spec.height or 20)
	b:SetBackdrop(WIDGET_BACKDROP)
	b:SetBackdropColor(0, 0, 0, 1)
	b:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
	local tex = b:CreateTexture(nil, "OVERLAY")
	tex:SetPoint("CENTER", 0, 0); tex:SetWidth(sz); tex:SetHeight(sz)
	local function paint()
		local c = get() or { 1, 1, 1, 1 }
		tex:SetTexture(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1)
	end
	paint()
	b.repaint = paint
	b:SetScript("OnClick", function()
		LibWidgets.CloseAllMenus()
		local c = get() or { 1, 1, 1, 1 }
		local cr, cg, cbl, ca = c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1
		ColorPickerFrame.func = function()
			local r, g, bl = ColorPickerFrame:GetColorRGB()
			local a = OpacitySliderFrame and (1 - OpacitySliderFrame:GetValue()) or 1
			set({ r, g, bl, a }); paint()
		end
		ColorPickerFrame.opacityFunc = ColorPickerFrame.func
		ColorPickerFrame.cancelFunc = function() set({ cr, cg, cbl, ca }); paint() end
		ColorPickerFrame.opacity = 1 - ca
		ColorPickerFrame.hasOpacity = 1
		ColorPickerFrame:SetColorRGB(cr, cg, cbl)
		ColorPickerFrame:SetFrameStrata("DIALOG")
		ShowUIPanel(ColorPickerFrame)
	end)
	return b
end

-- A tooltip-backdrop-styled edit box; see the header comment for spec.
function LibWidgets.NewTextBox(parent, spec)
	spec = spec or {}
	local e = CreateFrame("EditBox", nil, parent)
	if spec.width then e:SetWidth(spec.width) end
	e:SetHeight(spec.height or 22)
	e:SetAutoFocus(false)
	e:SetFontObject(GameFontHighlightSmall)
	e:SetTextInsets(5, 5, 2, 2)
	e:SetBackdrop(WIDGET_BACKDROP)
	e:SetBackdropColor(0, 0, 0, 0.7)
	e:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)

	-- Greyed placeholder shown only while the box is empty (1.12 has no native
	-- placeholder/SearchBoxTemplate to borrow one from).
	local hint
	if spec.hint then
		hint = e:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		hint:SetPoint("LEFT", 5, 0)
		hint:SetText(spec.hint)
	end
	local function updateHint()
		if hint then
			if e:GetText() == "" then hint:Show() else hint:Hide() end
		end
	end

	-- Seed before wiring OnTextChanged so the initial value doesn't echo through
	-- spec.onChange (matches NewSlider's seed-doesn't-fire-onChange contract).
	if spec.text then e:SetText(spec.text) end
	updateHint()
	if spec.onChange or hint then
		e:SetScript("OnTextChanged", function()
			updateHint()
			if spec.onChange then spec.onChange(this:GetText()) end
		end)
	end

	e:SetScript("OnEditFocusGained", function() takeFocus(this) end)
	e:SetScript("OnEnterPressed", function()
		if spec.onCommit then spec.onCommit(this:GetText()) end
		this:ClearFocus()
	end)
	e:SetScript("OnEscapePressed", function() this:ClearFocus() end)
	return e
end

-- A scrollable multi-line edit box; see the header comment for spec.
--
-- Scrolled by this library's own NewScrollFrame (the slim tinted slider every
-- other scroller here uses) rather than UIPanelScrollFrameTemplate's chunky
-- Blizzard scrollbar, so it reads as part of the same widget set.
--
-- That swap brings a real fix with it. A multi-line EditBox does not size
-- itself to its text on this client, which is why the old version pinned the
-- child at a flat 2000px and let the template clip it -- leaving the scroll
-- range permanently wrong. The content height is instead *measured*, with a
-- zero-alpha FontString carrying the same font and wrap width as the edit box,
-- so the slider's range and thumb match the text that is actually there.
local SCROLL_PAD = 5     -- inset from the box's border to the scroll viewport
local SLIDER_GUTTER = 10 -- room kept clear on the right for the slider
function LibWidgets.NewMultiLineEditBox(parent, spec)
	spec = spec or {}
	local w = spec.width or 300
	local h = spec.height or 150

	local box = CreateFrame("Frame", nil, parent)
	box:SetWidth(w); box:SetHeight(h)
	box:SetBackdrop(WIDGET_BACKDROP)
	box:SetBackdropColor(0, 0, 0, 0.7)
	box:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)

	local edit, measure
	local scroll = LibWidgets.NewScrollFrame(box, {
		wheelStep = 20,
		child = function(sf)
			edit = CreateFrame("EditBox", nil, sf)
			edit:SetMultiLine(true)
			edit:SetAutoFocus(false)
			edit:SetFontObject(GameFontHighlightSmall)
			edit:SetTextInsets(4, 4, 4, 4)
			return edit
		end,
	})
	scroll:SetPoint("TOPLEFT", box, "TOPLEFT", SCROLL_PAD, -SCROLL_PAD)
	scroll:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -SCROLL_PAD, SCROLL_PAD)

	-- Parented to the box, not the scroll child, so it is never scrolled.
	measure = box:CreateFontString(nil, "BACKGROUND")
	measure:SetFontObject(GameFontHighlightSmall)
	measure:SetAlpha(0)
	measure:SetJustifyH("LEFT")
	measure:SetPoint("TOPLEFT", box, "TOPLEFT", SCROLL_PAD, -SCROLL_PAD)

	local function innerWidth() return box:GetWidth() - SCROLL_PAD * 2 - SLIDER_GUTTER end

	-- Height of the measuring FontString's current text.
	--
	-- `GetStringHeight` does NOT exist on this client -- it is a 3.3.5 method,
	-- and calling it errors. A FontString sizes its own region to its text, so
	-- `GetHeight` is the reading that works here; the method check keeps a
	-- client that does have it (or does not have either) from erroring.
	local function measuredHeight()
		if measure.GetStringHeight then
			local h = measure:GetStringHeight()
			if h and h > 0 then return h end
		end
		if measure.GetHeight then
			local h = measure:GetHeight()
			if h and h > 0 then return h end
		end
		return nil
	end

	-- Line count times the font's size, as a floor under the measurement above.
	-- It cannot see wrapping, so it under-counts long lines -- it exists so a
	-- failed measurement degrades to "scrolls a bit short" rather than to a
	-- collapsed box.
	local function estimatedHeight()
		local t = edit:GetText() or ""
		local lines, at = 1, 1
		while true do
			-- string.find, not the strfind upvalue: that one is declared with
			-- the tokenizer further down this file and is not in scope here.
			local nl = string.find(t, "\n", at, true)
			if not nl then break end
			lines = lines + 1
			at = nl + 1
		end
		local size
		if edit.GetFont then local _, s = edit:GetFont(); size = s end
		return lines * ((tonumber(size) or 12) + 2)
	end

	-- Resizes the edit box to the height its text actually needs, then refits
	-- the slider. Floored at the viewport height so clicking the empty area
	-- below short text still lands on the edit box.
	local function fit()
		local iw = innerWidth()
		edit:SetWidth(iw)
		measure:SetWidth(iw)
		-- A trailing newline measures short, and empty text measures zero; a
		-- space keeps both cases from collapsing the box.
		measure:SetText((edit:GetText() or "") .. " ")

		local textH = measuredHeight()
		local est = estimatedHeight()
		if not textH or textH < est then textH = est end

		local viewH = scroll:GetHeight() or 0
		local target = textH + 8
		if target < viewH then target = viewH end
		edit:SetHeight(target)
		scroll.Update()
	end
	box.fit = fit

	if spec.text then edit:SetText(spec.text) end
	edit:SetScript("OnEditFocusGained", function() takeFocus(this) end)
	edit:SetScript("OnEscapePressed", function() this:ClearFocus() end)
	edit:SetScript("OnTextChanged", function()
		fit()
		if spec.onChange then spec.onChange(this:GetText()) end
	end)

	box.edit = edit
	box.scroll = scroll
	-- Refits here rather than trusting SetText to raise OnTextChanged: whether
	-- it does is an engine detail, and a wrong scroll range is silent.
	function box.setText(t) edit:SetText(t or ""); fit() end
	function box.getText() return edit:GetText() end
	function box.clearFocus() edit:ClearFocus() end
	function box.focusSelectAll()
		edit:SetFocus()
		edit:HighlightText()
	end
	-- Resizing has to re-wrap and re-measure, so it goes through here rather
	-- than a bare SetWidth/SetHeight on the outer frame.
	function box.setSize(width, height)
		box:SetWidth(width); box:SetHeight(height)
		fit()
	end
	-- Keeps the measuring FontString in step: a different face or size changes
	-- how the text wraps, and a stale measure means a wrong scroll range.
	function box.setFont(path, size, flags)
		local ok = edit:SetFont(path, size, flags or "")
		if not ok then
			edit:SetFontObject(GameFontHighlightSmall)
			measure:SetFontObject(GameFontHighlightSmall)
		else
			measure:SetFont(path, size, flags or "")
		end
		fit()
		return ok
	end
	fit()
	return box
end

-- A value-carrying slider; see the header comment for spec.
function LibWidgets.NewSlider(parent, spec)
	local decimals = spec.decimals or 2
	-- editable's edit box eats into the slider bar's share of `width` rather
	-- than extending the total footprint, so a caller that opts in doesn't
	-- also need to re-budget its own layout math.
	local totalW = spec.width or 150
	local inputW = spec.editable and (spec.inputWidth or 44) or 0
	local gap = spec.editable and 6 or 0
	local sliderW = totalW - inputW - gap
	if sliderW < 40 then sliderW = 40 end

	local s = CreateFrame("Slider", spec.name, parent, "OptionsSliderTemplate")
	s:SetMinMaxValues(spec.min, spec.max)
	s:SetValueStep(spec.step)
	s:SetWidth(sliderW); s:SetHeight(16)
	getglobal(spec.name .. "Low"):SetText("")
	getglobal(spec.name .. "High"):SetText("")
	local title = getglobal(spec.name .. "Text")
	local guarding = false

	local input
	if spec.editable then
		input = LibWidgets.NewTextBox(parent, { width = inputW, height = 18 })
		input:SetPoint("LEFT", s, "RIGHT", gap, 0)
	end

	local function paint(v)
		title:SetText(spec.format and spec.format(v) or formatNumber(v, decimals))
		if input then input:SetText(formatNumber(v, decimals)) end
	end

	s:SetScript("OnValueChanged", function()
		if guarding then return end
		LibWidgets.CloseAllMenus()
		if spec.onChange then spec.onChange(this:GetValue()) end
		paint(this:GetValue())
	end)

	if input then
		-- Commits on Enter only (matches NewTextBox's own contract elsewhere in
		-- this library) -- typing doesn't move the slider live, so there's no
		-- feedback loop to guard against mid-edit.
		input:SetScript("OnEnterPressed", function()
			local v = tonumber(this:GetText())
			if v then
				if spec.min and v < spec.min then v = spec.min end
				if spec.max and v > spec.max then v = spec.max end
				s:SetValue(v) -- fires OnValueChanged -> onChange + paint
			else
				paint(s:GetValue()) -- unparseable entry: revert the box
			end
			this:ClearFocus()
		end)
		input:SetScript("OnEscapePressed", function() paint(s:GetValue()); this:ClearFocus() end)
	end

	function s.setValue(v)
		-- Callers can be one step ahead of the value they read (a field added to
		-- a data model after some saved entries predate it, before their next
		-- MergeDefaults pass): SetValue throws a hard "Usage:" error on a
		-- non-number, which would otherwise take down the whole options panel
		-- over one stale field instead of just that slider.
		v = tonumber(v) or spec.min or 0
		guarding = true
		s:SetValue(v)
		guarding = false
		paint(v)
	end
	if spec.get then s.setValue(spec.get()) end
	return s
end

local SPIN_BTN_W    = 16   -- step button edge
local SPIN_GAP      = 2    -- step button <-> track
local SPIN_TRACK_H  = 18
local SPIN_LABEL_H  = 14
local SPIN_INSET    = 3    -- WIDGET_BACKDROP's own border inset
local SPIN_HANDLE_W = 9    -- grab area at the fill's leading edge
local SPIN_GRIP_W   = 3    -- the visible line inside it

-- The two step buttons are the library's one `up` arrow turned a quarter turn
-- each, so a consumer ships one arrow file rather than four. SetTexCoord takes
-- its corners in UL, LL, UR, LR order; these map the source's right edge onto
-- the screen's top edge (and its left edge onto the top, respectively), which is
-- a 90-degree turn each way.
local SPIN_ARROW_LEFT  = { 1, 0, 0, 0, 1, 1, 0, 1 }
local SPIN_ARROW_RIGHT = { 0, 1, 1, 1, 0, 0, 1, 0 }

local SPIN_GRIP_IDLE   = { 0.85, 0.75, 0.2, 0.8 }
local SPIN_GRIP_ACTIVE = { 1, 0.95, 0.5, 1 }

-- A drag/type/step number control; see the header comment for spec.
function LibWidgets.NewSpinBox(parent, spec)
	spec = spec or {}
	local value = spec.min or 0
	local focused, escaping, dragging = false, false, false
	local dragStartX, dragStartValue

	local f = CreateFrame("Frame", nil, parent)
	f:SetHeight(SPIN_LABEL_H + SPIN_TRACK_H)

	local label = f:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	label:SetJustifyH("LEFT")
	label:SetHeight(SPIN_LABEL_H)
	label:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
	f.label = label

	-- Read out of `spec` on every use rather than captured, so a consumer pooling
	-- one instance across fields rebinds by assigning to the spec table it passed
	-- in (the same contract NewSlider's onChange/format follow).
	local function bounds()
		local lo, hi = spec.min or 0, spec.softMax or spec.max or 1
		if hi < lo then hi = lo end
		return lo, hi, spec.step or 1
	end

	-- To the nearest step, then into range. Everything that can set the value --
	-- drag, step, typed entry, the external resync -- goes through this, so the
	-- box can never show a number off the step grid.
	--
	-- `cap` is the ceiling this particular move may reach, and is what makes a
	-- `softMax` field work: the track's top for a drag or a step, `spec.max` for
	-- a typed value or a resync -- which is nil on a field that names only a
	-- softMax, and nil here means no ceiling at all.
	local function snap(v, cap)
		v = tonumber(v)
		if v == nil then return value end
		local lo, _, step = bounds()
		if step and step > 0 then v = lo + math.floor((v - lo) / step + 0.5) * step end
		if v < lo then v = lo elseif cap and v > cap then v = cap end
		return v
	end

	-- The ceiling for a move starting at `from`. A value sitting above the track
	-- keeps its own, so the first pixel of a drag doesn't yank a typed 96 back
	-- down to the track's 72 -- it can only be dragged or stepped downwards.
	local function trackCeiling(from)
		local _, hi = bounds()
		if from > hi then return from end
		return hi
	end

	local paint, setValue

	local function nudge(dir)
		local _, _, step = bounds()
		setValue(value + dir * (step or 1), true, trackCeiling(value))
	end

	local arrow = (spec.textureDir or "") .. "up"
	local left = iconButton(f, arrow, function() nudge(-1) end, SPIN_BTN_W, SPIN_TRACK_H, 8)
	local right = iconButton(f, arrow, function() nudge(1) end, SPIN_BTN_W, SPIN_TRACK_H, 8)
	left.icon:SetTexCoord(unpack(SPIN_ARROW_LEFT))
	right.icon:SetTexCoord(unpack(SPIN_ARROW_RIGHT))
	left:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -SPIN_LABEL_H)
	right:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -SPIN_LABEL_H)

	local track = CreateFrame("Frame", nil, f)
	track:SetHeight(SPIN_TRACK_H)
	track:SetPoint("TOPLEFT", left, "TOPRIGHT", SPIN_GAP, 0)
	track:SetBackdrop(WIDGET_BACKDROP)
	track:SetBackdropColor(0, 0, 0, 0.7)
	track:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)

	local fill = track:CreateTexture(nil, "ARTWORK")
	fill:SetTexture(0.20, 0.42, 0.65, 0.85)
	fill:SetPoint("TOPLEFT", track, "TOPLEFT", SPIN_INSET, -SPIN_INSET)
	fill:SetPoint("BOTTOMLEFT", track, "BOTTOMLEFT", SPIN_INSET, SPIN_INSET)

	local edit = CreateFrame("EditBox", nil, track)
	edit:SetPoint("TOPLEFT", track, "TOPLEFT", SPIN_INSET, -SPIN_INSET)
	edit:SetPoint("BOTTOMRIGHT", track, "BOTTOMRIGHT", -SPIN_INSET, SPIN_INSET)
	edit:SetAutoFocus(false)
	edit:SetFontObject(GameFontHighlightSmall)
	edit:SetJustifyH("CENTER")
	edit:SetTextInsets(2, 2, 0, 0)
	f.edit = edit

	-- The drag target rides the fill's leading edge, above the edit box, and is
	-- always visible: it doubles as the read-out of where the value sits, and a
	-- handle that only appears on hover would have to be driven by enter/leave
	-- pairs that interleave (the edit box covers the track, this covers the edit
	-- box) or by polling MouseIsOver every frame.
	local handle = CreateFrame("Frame", nil, track)
	handle:SetWidth(SPIN_HANDLE_W)
	handle:EnableMouse(true)
	handle:SetFrameLevel(edit:GetFrameLevel() + 1)
	local grip = handle:CreateTexture(nil, "OVERLAY")
	grip:SetWidth(SPIN_GRIP_W)
	grip:SetPoint("TOP", handle, "TOP", 0, 0)
	grip:SetPoint("BOTTOM", handle, "BOTTOM", 0, 0)

	local function gripColor(c) grip:SetTexture(c[1], c[2], c[3], c[4]) end
	gripColor(SPIN_GRIP_IDLE)

	paint = function()
		local lo, hi, step = bounds()
		local span = f.trackSpan or 0
		local p = (hi > lo) and (value - lo) / (hi - lo) or 0
		if p < 0 then p = 0 elseif p > 1 then p = 1 end
		local w = p * span
		if w < 1 then fill:Hide() else fill:SetWidth(w); fill:Show() end
		handle:ClearAllPoints()
		handle:SetPoint("TOP", track, "TOPLEFT", SPIN_INSET + w, -SPIN_INSET)
		handle:SetPoint("BOTTOM", track, "BOTTOMLEFT", SPIN_INSET + w, SPIN_INSET)

		label:SetText(spec.label or "")
		-- Never while the box has focus: that would overwrite what is being typed.
		if not focused then
			edit:SetText(spec.fmt and spec.fmt(value) or formatNumber(value, spec.decimals or 2))
		end

		-- Half a step of slack, so a value sitting exactly on an end still reads
		-- as "no further this way" through float error.
		local slack = (step or 1) * 0.5
		if value - lo < slack then
			left:Disable(); left.icon:SetVertexColor(0.35, 0.35, 0.35)
		else
			left:Enable(); left.icon:SetVertexColor(1, 1, 1)
		end
		if hi - value < slack then
			right:Disable(); right.icon:SetVertexColor(0.35, 0.35, 0.35)
		else
			right:Enable(); right.icon:SetVertexColor(1, 1, 1)
		end
	end

	-- onChange fires only on a real move, which is what lets Enter commit through
	-- the focus-lost path as well without reporting the same edit twice.
	setValue = function(v, fire, cap)
		if cap == nil then cap = spec.max end
		v = snap(v, cap)
		local changed = (v ~= value)
		value = v
		paint()
		if fire and changed and spec.onChange then spec.onChange(value) end
	end

	local function commitText()
		if tonumber(edit:GetText()) == nil then paint(); return end
		setValue(edit:GetText(), true)
	end

	edit:SetScript("OnEditFocusGained", function() takeFocus(this); focused = true end)
	-- Committing on focus lost as well as on Enter is what makes clicking away
	-- keep a typed number instead of silently discarding it; Escape is the way
	-- out. Enter still commits directly rather than leaning on ClearFocus to
	-- raise OnEditFocusLost, and the pair is harmless because the second commit
	-- lands on the value the first one just set.
	edit:SetScript("OnEnterPressed", function()
		focused = false
		commitText()
		this:ClearFocus()
	end)
	edit:SetScript("OnEscapePressed", function() escaping = true; this:ClearFocus() end)
	edit:SetScript("OnEditFocusLost", function()
		focused = false
		if escaping then escaping = false; paint() else commitText() end
	end)

	-- The button is not necessarily still under the cursor when it is released,
	-- so the drag ends on the button's own state rather than on an OnMouseUp
	-- that may land somewhere else entirely.
	local function dragUpdate()
		if not IsMouseButtonDown("LeftButton") then
			dragging = false
			handle:SetScript("OnUpdate", nil)
			gripColor(SPIN_GRIP_IDLE)
			return
		end
		local lo, hi = bounds()
		local span = f.trackSpan or 0
		if span <= 0 then return end
		local x = GetCursorPosition() / handle:GetEffectiveScale()
		setValue(dragStartValue + ((x - dragStartX) / span) * (hi - lo), true,
			trackCeiling(dragStartValue))
	end

	handle:SetScript("OnMouseDown", function()
		if arg1 and arg1 ~= "LeftButton" then return end
		LibWidgets.CloseAllMenus()
		edit:ClearFocus()
		dragging = true
		dragStartX = GetCursorPosition() / handle:GetEffectiveScale()
		dragStartValue = value
		gripColor(SPIN_GRIP_ACTIVE)
		this:SetScript("OnUpdate", dragUpdate)
	end)
	handle:SetScript("OnEnter", function() gripColor(SPIN_GRIP_ACTIVE) end)
	handle:SetScript("OnLeave", function() if not dragging then gripColor(SPIN_GRIP_IDLE) end end)

	-- Sizes the whole control: the two step buttons take a fixed bite and the
	-- track keeps the rest, so a caller budgets one number for the row. The
	-- track's usable span is carried rather than read back -- this client
	-- answers GetWidth with 0 for a frame that has never been shown.
	function f.setWidth(w)
		f:SetWidth(w)
		local tw = w - 2 * (SPIN_BTN_W + SPIN_GAP)
		if tw < 24 then tw = 24 end
		track:SetWidth(tw)
		f.trackSpan = tw - 2 * SPIN_INSET
		paint()
	end

	-- Resyncs from external state without echoing through onChange. Falls back to
	-- min on a non-number for the same reason NewSlider's setValue does: a field
	-- can predate the value a caller reads for it, and one stale entry must not
	-- take down the panel it sits on.
	function f.setValue(v)
		setValue(tonumber(v) or (spec.min or 0), false)
	end
	function f.getValue() return value end
	f.stepDown, f.stepUp = left, right

	f.setWidth(spec.width or 150)
	if spec.get then f.setValue(spec.get()) end
	return f
end

-- The top-level frame in `frame`'s parent chain (the one parented straight to
-- UIParent). A popup hosted here escapes any ScrollFrame that would clip it and
-- the local strata/level stacking of the controls it drops over.
local function topLevelAncestor(frame)
	local f = frame
	while f do
		local p = f:GetParent()
		if not p or p == UIParent or p == WorldFrame then return f end
		f = p
	end
	return frame
end

-- A bare content scroller; see the header comment for spec. The caller anchors
-- the returned ScrollFrame, fills `.content` and sets its height, then calls
-- `.Update()` so the slim right-edge slider re-fits.
-- NewScrollBar(parent, spec) -- the slim tinted vertical slider this library
-- scrolls everything with: no track, no arrow buttons, a thumb sized to the
-- visible fraction. Pinned down the parent's right edge (`spec.inset` nudges it
-- across) and hidden while there is nothing to scroll.
--
-- Split out of NewScrollFrame so a caller that scrolls by its own units -- a
-- virtualised list stepping whole rows rather than pixels -- gets the same bar
-- instead of a lookalike. `bar.Fit(range, track, fraction)` is the shared
-- sizing: range is the largest value the bar may take, `fraction` is how much of
-- the whole is on screen (0..1), and `track` is the bar's own pixel length --
-- passed in rather than read back, because this client answers GetHeight with 0
-- for a frame that has never been shown and with the *previous* size for one
-- whose anchor target was just resized.
function LibWidgets.NewScrollBar(parent, spec)
	spec = spec or {}
	local bar = CreateFrame("Slider", nil, parent)
	bar:SetOrientation("VERTICAL")
	bar:SetWidth(6)
	bar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", spec.inset or 0, 0)
	bar:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", spec.inset or 0, 0)
	bar:SetThumbTexture(WIDGET_BACKDROP.bgFile)   -- recoloured solid below
	bar.thumb = bar:GetThumbTexture()
	bar.thumb:SetTexture(0.5, 0.5, 0.5, 0.9)
	bar.thumb:SetWidth(6)
	bar:Hide()

	function bar.Fit(range, track, fraction)
		if range < 0 then range = 0 end
		bar:SetMinMaxValues(0, range)
		if range > 0 and track > 0 then
			-- Thumb sized to the visible fraction, floored so it stays grabbable.
			local th = math.floor(track * (fraction or 1))
			bar.thumb:SetHeight(th < 16 and 16 or th)
			bar:Show()
		else
			bar:SetValue(0)
			bar:Hide()
		end
	end

	return bar
end

function LibWidgets.NewScrollFrame(parent, spec)
	spec = spec or {}
	local wheelStep = spec.wheelStep or 30

	local frame = CreateFrame("ScrollFrame", nil, parent)
	-- `spec.child` is a factory, not a frame: the scroll child has to be
	-- parented to this ScrollFrame, which does not exist until here. A caller
	-- that wants to scroll something other than a plain content frame (an edit
	-- box, say) builds it inside the factory.
	local content
	if spec.child then
		content = spec.child(frame)
	else
		content = CreateFrame("Frame", nil, frame)
		content:SetWidth(1); content:SetHeight(1)
	end
	frame:SetScrollChild(content)
	frame.content = content

	local slider = LibWidgets.NewScrollBar(frame, { inset = spec.sliderInset })
	slider:SetScript("OnValueChanged", function() frame:SetVerticalScroll(this:GetValue()) end)
	frame.slider = slider

	-- Refit the slider to the current content vs viewport height. Call after
	-- changing the content's height or the frame's own size.
	--
	-- `viewH` overrides the viewport height instead of reading it back off the
	-- frame. A caller whose ScrollFrame takes its size from anchors rather than
	-- SetHeight must pass it: this client resolves anchor-derived geometry at
	-- layout time, so GetHeight answers 0 for a frame that has never been shown
	-- and the *previous* size for one whose anchor target was just resized --
	-- either way the slider gets sized against a viewport that isn't the one on
	-- screen, or hidden when it is needed.
	function frame.Update(viewH)
		local view = viewH or frame:GetHeight()
		local total = content:GetHeight()
		-- The bar runs the frame's full height, so the viewport height is also
		-- the track length.
		slider.Fit(total - view, view, total > 0 and view / total or 1)
	end

	-- arg1 is +1 up / -1 down. Exposed as `.wheel` so children that capture the
	-- wheel focus (item buttons) can forward to it.
	local function wheel()
		local range = content:GetHeight() - frame:GetHeight()
		if range <= 0 then return end
		local new = frame:GetVerticalScroll() - arg1 * wheelStep
		if new < 0 then new = 0 elseif new > range then new = range end
		frame:SetVerticalScroll(new); slider:SetValue(new)
	end
	frame:EnableMouseWheel(true)
	frame:SetScript("OnMouseWheel", wheel)
	frame.wheel = wheel

	return frame
end

-- A value-picker drop button; see the header comment for spec. `previews` marks
-- rows with a side button that invokes `onPreview` without selecting or closing.
function LibWidgets.NewDropButton(parent, spec)
	local values   = spec.values
	local labels   = spec.labels or {}
	local tips     = spec.tips
	local swatches = spec.swatches
	local previews = spec.previews
	local previewTexture = spec.previewTexture
	local width    = spec.width or 92
	local itemH    = spec.itemHeight or (swatches and 20 or 14)

	local b = CreateFrame("Button", nil, parent)
	b:SetWidth(width); b:SetHeight(spec.height or 20)
	styleFlatButton(b)

	-- A swatch picker previews the candidate as a full green bar drawn in that
	-- texture. On the face it's a StatusBar (the same widget the choice will
	-- eventually drive), inset so the button's own border still reads.
	local faceSwatch
	if swatches then
		faceSwatch = CreateFrame("StatusBar", nil, b)
		faceSwatch:SetPoint("TOPLEFT", 3, -3); faceSwatch:SetPoint("BOTTOMRIGHT", -3, 3)
		faceSwatch:SetMinMaxValues(0, 1); faceSwatch:SetValue(1)
		faceSwatch:SetStatusBarColor(0.2, 0.7, 0.2)
		b.faceSwatch = faceSwatch
	end
	-- The label goes on the swatch, not the button: a child frame draws above its
	-- parent's own regions, so a label on the button would sit under the preview.
	local fs = (faceSwatch or b):CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	fs:SetPoint("CENTER", b, "CENTER", 0, 0)
	b.label = fs

	-- A down-arrow on the right edge signals the button opens a menu. It needs
	-- the library's own textures path, so it only appears when spec.textureDir is
	-- given. Desaturated grey at rest, green on hover -- the same enabled/disabled
	-- cue the list editor's reorder arrows use.
	if spec.textureDir then
		-- Drawn on the face swatch when there is one, for the same reason the label
		-- is: a texture on the button itself would be covered by that child frame.
		local arrow = (faceSwatch or b):CreateTexture(nil, "OVERLAY")
		arrow:SetWidth(9); arrow:SetHeight(9)
		arrow:SetPoint("RIGHT", b, "RIGHT", -5, 0)
		arrow:SetTexture(spec.textureDir .. "down")
		arrow:SetVertexColor(MOVE_NONE[1], MOVE_NONE[2], MOVE_NONE[3])
		b.arrow = arrow
		-- Span the label from the left edge to the arrow and centre-justify, so it
		-- sits centred in the space left of the arrow rather than centred on the
		-- whole button (which the arrow would then crowd off-centre).
		fs:ClearAllPoints()
		fs:SetPoint("LEFT", b, "LEFT", 2, 0)
		fs:SetPoint("RIGHT", arrow, "LEFT", -2, 0)
		fs:SetJustifyH("CENTER")
	end

	function b.setValue(v)
		b.value = v
		fs:SetText(labels[v] or v or "")
		if faceSwatch then
			local path = v ~= nil and swatches[v] or nil
			if path then faceSwatch:SetStatusBarTexture(path) end
			-- SetStatusBarTexture replaces the bar's texture object, dropping the
			-- tint set at build; re-apply it so the preview stays a green fill.
			faceSwatch:SetStatusBarColor(0.2, 0.7, 0.2)
		end
	end

	-- Hosted on the button's top-level ancestor (not the button) so a ScrollFrame
	-- in between can't clip it and it doesn't share the rows' strata; still anchored
	-- to the button below so it tracks position.
	local menu = CreateFrame("Frame", nil, spec.menuParent or topLevelAncestor(b))
	menu:SetBackdrop(WIDGET_BACKDROP)
	menu:SetBackdropColor(0, 0, 0, 0.95)
	menu:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.9)
	menu:SetWidth(spec.menuWidth or width)
	menu:SetPoint("TOPLEFT", b, "BOTTOMLEFT", 0, 0)
	menu:SetFrameStrata(spec.menuStrata or "FULLSCREEN_DIALOG")
	menu:SetToplevel(true)
	menu:Hide()
	b.menu = menu

	-- Long menus (e.g. a condition's property list) cap at maxVisible items and
	-- scroll the rest through a NewScrollFrame (its ScrollFrame clips overflow to
	-- the menu border, and its slim slider reads the same as a short menu).
	local maxVisible = spec.maxVisibleItems or 8
	local bodyW = (spec.menuWidth or width) - 8
	local scroll = LibWidgets.NewScrollFrame(menu, { wheelStep = itemH * 2 })
	scroll:SetPoint("TOPLEFT", menu, "TOPLEFT", 4, -4)
	scroll:SetPoint("BOTTOMRIGHT", menu, "BOTTOMRIGHT", -4, 4)
	menu.scroll = scroll
	local content = scroll.content
	content:SetWidth(bodyW)

	-- Entry buttons are pooled so a dynamic menu (spec.values as a function) can be
	-- rebuilt on every open; a static menu builds once below.
	menu.items = {}
	local function menuItem(i)
		local item = menu.items[i]
		if item then return item end
		item = CreateFrame("Button", nil, content)
		item:SetHeight(itemH)
		item:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(i - 1) * itemH)
		item:SetPoint("RIGHT", content, "RIGHT", 0, 0)
		item:EnableMouseWheel(true)
		item:SetScript("OnMouseWheel", scroll.wheel)
		-- A plain ARTWORK texture rather than a nested StatusBar: the entry is
		-- always a full bar, and staying on the button's own regions keeps the
		-- label (OVERLAY) and the auto HIGHLIGHT layering over it.
		if swatches then
			local sw = item:CreateTexture(nil, "ARTWORK")
			sw:SetPoint("TOPLEFT", 1, -1); sw:SetPoint("BOTTOMRIGHT", -1, 1)
			sw:SetVertexColor(0.2, 0.7, 0.2)
			item.swatch = sw
		end
		local ifs = item:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		ifs:SetPoint("LEFT", item, "LEFT", 2, 0)
		item.label = ifs
		if previews then
			local preview = CreateFrame("Button", nil, item)
			preview:SetWidth(16); preview:SetHeight(itemH - 2)
			preview:SetPoint("RIGHT", item, "RIGHT", -1, 0)
			local previewIcon = preview:CreateTexture(nil, "ARTWORK")
			previewIcon:SetAllPoints(preview)
			previewIcon:SetTexture(previewTexture or PREVIEW_TEXTURE)
			previewIcon:SetVertexColor(1, 0.82, 0.15, 1)
			preview.icon = previewIcon
			preview:SetScript("OnClick", function()
				if spec.onPreview and this.value then spec.onPreview(this.value) end
			end)
			item.preview = preview
		end
		local hl = item:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints(item); hl:SetTexture(0.3, 0.3, 0.8, 0.5)
		item:SetScript("OnClick", function()
			LibWidgets.CloseAllMenus()
			if spec.onSelect then spec.onSelect(this.value) end
			if spec.get then b.setValue(this.value) end
		end)
		if tips then
			item:SetScript("OnEnter", function()
				GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
				GameTooltip:AddLine(tips[this.value] or "")
				GameTooltip:Show()
			end)
			item:SetScript("OnLeave", function() GameTooltip:Hide() end)
		end
		menu.items[i] = item
		return item
	end

	local function buildItems(vals)
		local n = table.getn(vals)
		for i = 1, n do
			local item = menuItem(i)
			item.value = vals[i]
			item.label:SetText(labels[vals[i]] or vals[i])
			if item.preview then
				item.preview.value = vals[i]
				if previews[vals[i]] then item.preview:Show() else item.preview:Hide() end
			end
			if item.swatch then
				local path = swatches[vals[i]]
				if path then
					item.swatch:SetTexture(path)
					item.swatch:SetVertexColor(0.2, 0.7, 0.2)
					item.swatch:Show()
				else
					item.swatch:Hide()
				end
			end
			item:Show()
		end
		for i = n + 1, table.getn(menu.items) do menu.items[i]:Hide() end

		local visible = n < maxVisible and n or maxVisible
		menu:SetHeight(visible * itemH + 8)
		content:SetHeight(n * itemH)
		scroll:SetVerticalScroll(0)
		-- The scroll frame is inset 4px into the menu on every side, so the
		-- viewport is exactly the rows it shows. Handing that to Update is what
		-- keeps the slider correct on a menu the height was only just set on --
		-- see the note on Update itself.
		menu.viewH = visible * itemH
		scroll.Update(menu.viewH)
	end
	if type(values) ~= "function" then buildItems(values) end

	b:SetScript("OnEnter", function()
		this:SetBackdropBorderColor(0.9, 0.8, 0.2, 1)
		if this.arrow then this.arrow:SetVertexColor(MOVE_OK[1], MOVE_OK[2], MOVE_OK[3]) end
		if tips and this.value then
			GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
			GameTooltip:AddLine(tips[this.value] or "")
			GameTooltip:Show()
		end
	end)
	b:SetScript("OnLeave", function()
		this:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8); GameTooltip:Hide()
		if this.arrow then this.arrow:SetVertexColor(MOVE_NONE[1], MOVE_NONE[2], MOVE_NONE[3]) end
	end)
	b:SetScript("OnClick", function()
		if menu:IsShown() then
			LibWidgets.CloseAllMenus()
			return
		end
		-- Don't pop an empty menu -- there's nothing to select.
		local vals = (type(values) == "function") and values() or values
		if not vals or table.getn(vals) == 0 then return end
		if type(values) == "function" then buildItems(vals) end
		LibWidgets.CloseAllMenus()   -- at most one popup open at a time
		-- The high strata alone (above the host panel's) puts the popup over the
		-- controls it covers; SetToplevel handles ordering against sibling
		-- same-strata popups. Deliberately NOT re-levelling the menu on this
		-- client: SetFrameLevel doesn't carry a frame's children with it here, so
		-- bumping the menu would leave its item buttons below the menu's own
		-- near-opaque backdrop, greying them out.
		scroll:SetVerticalScroll(0)   -- always open at the top
		activeMenu = menu
		menu:Show()
	end)

	if spec.get then b.setValue(spec.get()) end
	return b
end

function LibWidgets.NewListEditor(parent, spec)
	local rowH  = spec.rowHeight or 18
	local vis   = spec.visibleRows or 5
	local pad   = 4
	local listH = vis * rowH + pad * 2
	local function iconPath(name) return (spec.textureDir or "") .. name end

	local listBox = CreateFrame("Frame", nil, parent)
	listBox:SetPoint("TOPLEFT", parent, "TOPLEFT", spec.x or 0, spec.y or 0)
	listBox:SetPoint("RIGHT", parent, "RIGHT", -(spec.rightInset or 16), 0)
	listBox:SetHeight(listH)
	listBox:SetBackdrop(WIDGET_BACKDROP)
	listBox:SetBackdropColor(0, 0, 0, 0.5)
	listBox:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)

	local scroll = CreateFrame("ScrollFrame", spec.nameFrame, listBox, "FauxScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", listBox, "TOPLEFT", pad, -pad)
	scroll:SetPoint("BOTTOMRIGHT", listBox, "BOTTOMRIGHT", -(pad + 18), pad)

	local rows = {}
	local refresh   -- forward decl; row buttons + the drag tracker call it/spec through closures

	-- ---- drag-to-reorder -- ghost row, insertion indicator, cursor-edge
	-- auto-scroll ----
	local drag = { active = false, from = nil, before = nil }
	local trackDrag, endDrag

	local dragLayer = CreateFrame("Frame", nil, listBox)
	dragLayer:SetAllPoints(scroll)
	dragLayer:SetFrameLevel(listBox:GetFrameLevel() + 25)
	local indicator = dragLayer:CreateTexture(nil, "OVERLAY")
	indicator:SetHeight(3)
	indicator:SetTexture(0.95, 0.82, 0.2, 0.95)
	indicator:Hide()

	local ghost = CreateFrame("Frame", nil, UIParent)
	ghost:SetFrameStrata("TOOLTIP")
	ghost:SetWidth(160); ghost:SetHeight(rowH)
	ghost:EnableMouse(false)
	ghost:SetBackdrop(WIDGET_BACKDROP)
	ghost:SetBackdropColor(0, 0, 0, 0.85)
	ghost:SetBackdropBorderColor(0.9, 0.8, 0.2, 0.9)
	ghost:Hide()
	local gName = ghost:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	gName:SetPoint("LEFT", 6, 0)
	gName:SetPoint("RIGHT", ghost, "RIGHT", -6, 0)
	gName:SetJustifyH("LEFT")

	local AUTOSCROLL_EDGE    = rowH
	local AUTOSCROLL_MIN_RPS = 4
	local AUTOSCROLL_MAX_RPS = 20
	local scrollAccum = 0

	trackDrag = function(elapsed)
		local scale  = scroll:GetEffectiveScale()
		local top    = scroll:GetTop() or 0
		local bottom = scroll:GetBottom() or 0
		local _, cyraw = GetCursorPosition()
		local cy = cyraw / scale

		if elapsed and elapsed > 0 then
			local dir, intensity = 0, 0
			if cy > top - AUTOSCROLL_EDGE then
				dir = -1; intensity = (cy - (top - AUTOSCROLL_EDGE)) / AUTOSCROLL_EDGE
			elseif cy < bottom + AUTOSCROLL_EDGE then
				dir = 1; intensity = ((bottom + AUTOSCROLL_EDGE) - cy) / AUTOSCROLL_EDGE
			end
			if dir == 0 then
				scrollAccum = 0
			else
				if intensity > 1 then intensity = 1 end
				local rps = AUTOSCROLL_MIN_RPS + (AUTOSCROLL_MAX_RPS - AUTOSCROLL_MIN_RPS) * intensity
				scrollAccum = scrollAccum + dir * rps * elapsed
				local steps = (scrollAccum >= 0) and math.floor(scrollAccum) or math.ceil(scrollAccum)
				if steps ~= 0 then
					scrollAccum = scrollAccum - steps
					local bar = getglobal(spec.nameFrame .. "ScrollBar")
					if bar then
						local v = bar:GetValue() + steps * rowH
						local lo, hi = bar:GetMinMaxValues()
						if v < lo then v = lo elseif v > hi then v = hi end
						bar:SetValue(v)   -- triggers the scroll + refresh
					end
				end
			end
		end

		local list = spec.list() or {}
		local n = table.getn(list)
		local offset = FauxScrollFrame_GetOffset(scroll)
		local count = n - offset
		if count > vis then count = vis end

		local p = math.floor((top - cy) / rowH + 0.5)
		if p < 0 then p = 0 elseif p > count then p = count end
		drag.before = offset + p + 1

		indicator:ClearAllPoints()
		indicator:SetPoint("TOPLEFT", dragLayer, "TOPLEFT", 0, -p * rowH + 1)
		indicator:SetPoint("TOPRIGHT", dragLayer, "TOPRIGHT", -4, -p * rowH + 1)
		indicator:Show()

		local gscale = ghost:GetEffectiveScale()
		local cx, gcy = GetCursorPosition()
		ghost:ClearAllPoints()
		ghost:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cx / gscale + 14, gcy / gscale + 8)
	end

	local function beginDrag(row)
		if not row.index then return end
		LibWidgets.CloseAllMenus()
		drag.active = true
		drag.from   = row.index
		drag.before = row.index
		scrollAccum = 0
		GameTooltip:Hide()
		gName:SetText(row.name:GetText())
		ghost:Show()
		trackDrag()
	end

	-- Safety net: a release over some frames (e.g. a focused edit box) can
	-- swallow OnDragStop and strand the drag until reload -- the OnUpdate
	-- poll below finishes it via IsMouseButtonDown instead.
	endDrag = function()
		if not drag.active then return end
		drag.active = false
		scrollAccum = 0
		indicator:Hide()
		ghost:Hide()
		if drag.from and drag.before then
			spec.reorder(drag.from, drag.before)
		end
		drag.from, drag.before = nil, nil
	end

	listBox:SetScript("OnUpdate", function()
		if drag.active then
			trackDrag(arg1)
			if not IsMouseButtonDown("LeftButton") then endDrag() end
		end
	end)

	-- ---- rows ----

	-- Single-step reorder (the arrow buttons): expressed as a boundary move so
	-- it shares spec.reorder's one splice implementation with drag-drop.
	-- Removing the entry first shifts every later index down by one, so
	-- landing it just before index-1 (up) or index+2 (down) both resolve to
	-- a plain swap with the adjacent row once that shift is accounted for.
	local function moveStep(index, dir)
		if dir < 0 then spec.reorder(index, index - 1)
		else spec.reorder(index, index + 2) end
	end

	local function makeRow(i)
		local row = CreateFrame("Frame", nil, listBox)
		row:SetHeight(rowH)
		row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(i - 1) * rowH)
		row:SetPoint("RIGHT", scroll, "RIGHT", -4, 0)

		if spec.remove then
			row.del = iconButton(row, ICON_DELETE, function() spec.remove(row.index) end)
			row.del:SetPoint("RIGHT", 0, 0)
		end
		row.down = iconButton(row, iconPath("down"), function() moveStep(row.index, 1) end)
		if row.del then row.down:SetPoint("RIGHT", row.del, "LEFT", -BTN_GAP, 0)
		else row.down:SetPoint("RIGHT", 0, 0) end
		row.up = iconButton(row, iconPath("up"), function() moveStep(row.index, -1) end)
		row.up:SetPoint("RIGHT", row.down, "LEFT", -BTN_GAP, 0)

		local rightAnchor = row.up
		row.cols = {}
		if spec.columns then
			for ci = table.getn(spec.columns), 1, -1 do
				local coldef = spec.columns[ci]
				local w = coldef.build(row)
				w:SetWidth(coldef.width)
				w:SetPoint("RIGHT", rightAnchor, "LEFT", -COL_GAP, 0)
				row.cols[ci] = w
				rightAnchor = w
			end
		end

		if spec.leadingControl then
			if spec.leadingControl.kind == "checkbox" then
				row.leading = buildCheckbox(row, spec.leadingControl)
			else
				row.leading = buildTristate(row, spec.leadingControl, iconPath)
			end
			row.leading:SetPoint("LEFT", row, "LEFT", 0, 0)
		end

		row.name = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		if row.leading then row.name:SetPoint("LEFT", row.leading, "RIGHT", 4, 0)
		else row.name:SetPoint("LEFT", row, "LEFT", 2, 0) end
		row.name:SetPoint("RIGHT", rightAnchor, "LEFT", -6, 0)
		row.name:SetJustifyH("LEFT")

		-- Drag handle spans just the name label -- the leading control keeps
		-- its own click-to-cycle/toggle, so it's excluded from the drag
		-- hit-zone.
		local hover = CreateFrame("Frame", nil, row)
		hover:SetPoint("TOPLEFT", row.name, "TOPLEFT", -2, 0)
		hover:SetPoint("BOTTOMRIGHT", row.name, "BOTTOMRIGHT", 0, 0)
		hover:EnableMouse(true)
		hover:RegisterForDrag("LeftButton")
		hover:SetScript("OnDragStart", function() beginDrag(row) end)
		hover:SetScript("OnDragStop", function() endDrag() end)
		row.hover = hover

		rows[i] = row
		return row
	end

	local function paintArrows(row, i, n)
		local canUp, canDown = i > 1, i < n
		local up   = canUp   and MOVE_OK or MOVE_NONE
		local down = canDown and MOVE_OK or MOVE_NONE
		row.up.icon:SetVertexColor(up[1], up[2], up[3])
		row.down.icon:SetVertexColor(down[1], down[2], down[3])
		if canUp then row.up:Enable() else row.up:Disable(); row.up:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8) end
		if canDown then row.down:Enable() else row.down:Disable(); row.down:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8) end
	end

	refresh = function()
		local list = spec.list() or {}
		local n = table.getn(list)
		FauxScrollFrame_Update(scroll, n, vis, rowH)
		local offset = FauxScrollFrame_GetOffset(scroll)
		for i = 1, vis do
			local row = rows[i] or makeRow(i)
			local di = i + offset
			if di <= n then
				local e = list[di]
				row.index = di
				row.entry = e
				row.name:SetText(spec.nameGet(e))
				if spec.nameColor then row.name:SetTextColor(spec.nameColor(e, di)) end
				if row.leading then row.leading.paint(e) end
				if spec.columns then
					for ci = 1, table.getn(spec.columns) do
						spec.columns[ci].update(row.cols[ci], e, di, n)
					end
				end
				paintArrows(row, di, n)
				row:Show()
			else
				row:Hide()
			end
		end
	end

	scroll:SetScript("OnVerticalScroll", function()
		FauxScrollFrame_OnVerticalScroll(rowH, refresh)
	end)
	local function wheel()
		local bar = getglobal(spec.nameFrame .. "ScrollBar")
		if bar then bar:SetValue(bar:GetValue() - arg1 * rowH) end
	end
	scroll:EnableMouseWheel(true); scroll:SetScript("OnMouseWheel", wheel)
	listBox:EnableMouseWheel(true); listBox:SetScript("OnMouseWheel", wheel)

	local totalH = listH
	if spec.add then
		-- Parented to listBox (not `parent`) even though it sits below it: the
		-- add row is part of this editor, so hiding the returned `.frame` --
		-- what a caller repainting a panel does -- must take it down too.
		local addBtn = LibWidgets.NewButton(listBox, { text = "Add", width = 50, height = 22 })
		addBtn:SetPoint("TOPRIGHT", listBox, "BOTTOMRIGHT", 0, -8)

		-- Forward-declared so `commit` (needed as both addBox's onCommit and
		-- addBtn's onClick) can read the box back regardless of which one fired.
		local addBox
		local function commit()
			local text = addBox:GetText()
			if text and text ~= "" then spec.add.onAdd(text); addBox:SetText("") end
		end
		addBox = LibWidgets.NewTextBox(listBox, { onCommit = commit })
		addBox:SetPoint("TOPLEFT", listBox, "BOTTOMLEFT", 0, -8)
		addBox:SetPoint("RIGHT", addBtn, "LEFT", -6, 0)
		addBtn:SetScript("OnClick", commit)

		totalH = totalH + 8 + 22
	end

	refresh()
	return { height = totalH, refresh = refresh, frame = listBox }
end

-- ---------------------------------------------------------------------------
-- Status bar textures
--
-- The names of the bar texture set addons on this client conventionally bundle
-- (the LibSharedMedia default pack, which no 1.12 client has a media registry
-- for). Only the names live here: the .tga files sit in the consuming addon's
-- own textures\bars\ folder, since this file can't resolve a path relative to
-- itself -- same constraint as NewListEditor's textureDir.
-- ---------------------------------------------------------------------------

LibWidgets.BAR_TEXTURES = {
	"Flat", "Blizzard", "Aluminium", "BantoBar", "Gloss", "Graphite", "Healbot",
	"Minimalist", "Otravi", "Perl", "Round", "Smooth",
}

-- Two names resolve to stock client art rather than a bundled file, so they
-- work even for a caller shipping none of the rest:
--   Flat     -- the solid white 8x8, i.e. no grain at all: whatever the caller
--               tints it is exactly what shows.
--   Blizzard -- the client's own status bar texture.
function LibWidgets.BarTexturePath(dir, name)
	if name == "Flat" then
		return "Interface\\Buttons\\WHITE8X8"
	elseif not name or name == "Blizzard" then
		return "Interface\\TargetingFrame\\UI-StatusBar"
	end
	return (dir or "") .. name
end

-- ---------------------------------------------------------------------------
-- Icon picker
-- ---------------------------------------------------------------------------

local ICON_PREFIX = "Interface\\Icons\\"

-- Icons are stored as uppercase basenames (no path, no extension): it halves
-- the string weight of a ~5000-entry DB, makes the search a plain uppercase
-- substring test, and lets entries that differ only in case or prefix dedup
-- against each other. Texture paths are rebuilt on demand -- WoW resolves them
-- case-insensitively, so the uppercasing is free.
local function iconBaseName(name)
	local s, e = string.find(string.upper(name), "INTERFACE\\ICONS\\", 1, true)
	if s == 1 then name = string.sub(name, e + 1) end
	return string.upper(name)
end
LibWidgets.IconPath = function(name) return ICON_PREFIX .. name end

-- The client's own macro-icon database. ClassicAPI surfaces modern Classic
-- Era's four append-to-table enumerators; prefer them, because the vanilla
-- GetMacroIconInfo DB they replace is filtered to Ability_*/Spell_* and never
-- lists a single INV_* item icon. Scanning walks thousands of files, so the
-- result is built once and cached for the session.
local iconDB
function LibWidgets.GetIconDatabase()
	if iconDB then return iconDB end
	iconDB = {}
	local seen = {}
	local function add(name)
		if not name or name == "" then return end
		name = iconBaseName(name)
		if not seen[name] then
			seen[name] = true
			table.insert(iconDB, name)
		end
	end
	if type(GetMacroIcons) == "function" and type(GetMacroItemIcons) == "function" then
		-- Modern's canonical order (loose drop-ins before MPQ-resident, spells
		-- before items). The four calls don't dedup against each other -- an icon
		-- present both loose and in an MPQ is returned twice -- hence `seen`.
		local spells, items = {}, {}
		if type(GetLooseMacroIcons) == "function" then GetLooseMacroIcons(spells) end
		if type(GetLooseMacroItemIcons) == "function" then GetLooseMacroItemIcons(items) end
		GetMacroIcons(spells)
		GetMacroItemIcons(items)
		for i = 1, table.getn(spells) do add(spells[i]) end
		for i = 1, table.getn(items) do add(items[i]) end
	elseif type(GetNumMacroIcons) == "function" then
		for i = 1, GetNumMacroIcons() do add(GetMacroIconInfo(i)) end
	end
	return iconDB
end

-- A modal icon browser; see the header comment for spec. Built once per caller
-- and reused: `.Open(current)` refills and shows it, so the several thousand
-- cell buttons a non-virtualised grid would need never get created -- only
-- columns*visibleRows exist, repainted as the list scrolls (the same row-pool
-- approach NewListEditor uses).
function LibWidgets.NewIconPicker(parent, spec)
	spec = spec or {}
	local hasCategories = spec.categories ~= nil
	local cols    = spec.columns or 10
	local vis     = spec.visibleRows or 7
	local iconSz  = spec.iconSize or 30
	local cell    = iconSz + 6
	local pad     = 10
	-- Cell columns, the grid's own 4px insets, and the FauxScrollFrame
	-- scrollbar's gutter on the right.
	local gridW   = cols * cell + 8 + 22
	local gridH   = vis * cell + 8
	local scrollName = spec.nameFrame or error("NewIconPicker: spec.nameFrame is required")

	local frame = CreateFrame("Frame", scrollName .. "Dialog", spec.dialogParent or UIParent)
	frame:SetWidth(gridW + pad * 2)
	frame:SetHeight(gridH + 118 + (hasCategories and 26 or 0))
	frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	frame:SetBackdrop(WIDGET_BACKDROP)
	frame:SetBackdropColor(0, 0, 0, 0.92)
	frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.9)
	frame:SetFrameStrata(spec.strata or "FULLSCREEN_DIALOG")
	frame:SetToplevel(true)
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function() this:StartMoving() end)
	frame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
	-- A click on the dialog's own background is the one gap CloseAllMenus'
	-- interaction-driven closing doesn't cover (see this file's header).
	frame:SetScript("OnMouseDown", function() LibWidgets.CloseAllMenus() end)
	frame:Hide()

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", pad, -pad)
	title:SetText(spec.title or "Select Icon")

	-- Preview of what Okay would accept, so the choice is legible even when the
	-- selected cell has scrolled out of view.
	local preview = frame:CreateTexture(nil, "ARTWORK")
	preview:SetWidth(26); preview:SetHeight(26)
	preview:SetPoint("TOPLEFT", pad, -pad - 20)
	preview:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	local previewLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	previewLabel:SetPoint("LEFT", preview, "RIGHT", 6, 0)
	previewLabel:SetJustifyH("LEFT")

	local count = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	count:SetPoint("TOPRIGHT", -pad, -pad - 2)
	count:SetJustifyH("RIGHT")

	local filtered, selected = {}, nil
	local refresh, applyFilter
	local normalize = spec.normalize or iconBaseName
	local pathFor = spec.pathFor or LibWidgets.IconPath
	local labelFor = spec.labelFor or function(value) return value end
	local categoryValues = spec.categoryValues
	if not categoryValues and spec.categories then
		categoryValues = {}
		for category in pairs(spec.categories) do table.insert(categoryValues, category) end
		table.sort(categoryValues)
	end
	local selectedCategory = spec.defaultCategory or (categoryValues and categoryValues[1])
	local function valuesForCategory(category)
		if spec.categories then return spec.categories[category] or {} end
		if spec.icons then return spec.icons(category) end
		return LibWidgets.GetIconDatabase()
	end

	local search = LibWidgets.NewTextBox(frame, {
		width = 160, height = 20, hint = spec.searchHint or "Search",
		onChange = function(text) applyFilter(text) end,
	})
	search:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -pad, -pad - 18)
	search:SetScript("OnEscapePressed", function() this:SetText(""); this:ClearFocus() end)
	frame.search = search

	local categoryButton
	if categoryValues then
		categoryButton = LibWidgets.NewDropButton(frame, {
			values = categoryValues,
			labels = spec.categoryLabels or {},
			width = spec.categoryWidth or 130,
			height = 20,
			menuParent = frame,
			get = function() return selectedCategory end,
			onSelect = function(value)
				selectedCategory = value
				applyFilter(search:GetText() or "")
			end,
		})
		categoryButton:SetPoint("TOPLEFT", frame, "TOPLEFT", pad, -pad - 52)
		frame.categoryButton = categoryButton
	end

	local grid = CreateFrame("Frame", nil, frame)
	grid:SetPoint("TOPLEFT", pad, -pad - (hasCategories and 80 or 54))
	grid:SetWidth(gridW); grid:SetHeight(gridH)
	grid:SetBackdrop(WIDGET_BACKDROP)
	grid:SetBackdropColor(0, 0, 0, 0.5)
	grid:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)

	local scroll = CreateFrame("ScrollFrame", scrollName, grid, "FauxScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", grid, "TOPLEFT", 4, -4)
	scroll:SetPoint("BOTTOMRIGHT", grid, "BOTTOMRIGHT", -22, 4)

	local cells = {}
	local function cellAt(i)
		local c = cells[i]
		if c then return c end
		c = CreateFrame("Button", nil, grid)
		c:SetWidth(cell - 2); c:SetHeight(cell - 2)
		local col = math.mod(i - 1, cols)
		local row = math.floor((i - 1) / cols)
		c:SetPoint("TOPLEFT", grid, "TOPLEFT", 4 + col * cell, -4 - row * cell)
		c:SetBackdrop(WIDGET_BACKDROP)
		c:SetBackdropColor(0, 0, 0, 0.4)
		c:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.6)
		local t = c:CreateTexture(nil, "ARTWORK")
		t:SetWidth(iconSz - 4); t:SetHeight(iconSz - 4)
		t:SetPoint("CENTER", 0, 0)
		t:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		c.icon = t
		local hl = c:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints(c); hl:SetTexture(1, 0.82, 0, 0.25)
		c:SetScript("OnClick", function()
			LibWidgets.CloseAllMenus()
			if not this.name then return end
			selected = this.name
			refresh()
		end)
		c:SetScript("OnEnter", function()
			if not this.name then return end
			GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
			GameTooltip:AddLine(labelFor(this.name))
			GameTooltip:Show()
		end)
		c:SetScript("OnLeave", function() GameTooltip:Hide() end)
		cells[i] = c
		return c
	end

	refresh = function()
		local n = table.getn(filtered)
		local rows = math.ceil(n / cols)
		FauxScrollFrame_Update(scroll, rows, vis, cell)
		local offset = FauxScrollFrame_GetOffset(scroll)
		for i = 1, cols * vis do
			local c = cellAt(i)
			local index = offset * cols + i
			local name = filtered[index]
			if name then
				c.name = name
				c.icon:SetTexture(pathFor(name, selectedCategory))
				c.icon:Show()
				if name == selected then
					c:SetBackdropBorderColor(1, 0.82, 0, 1)
					c:SetBackdropColor(0.3, 0.25, 0.05, 0.8)
				else
					c:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.6)
					c:SetBackdropColor(0, 0, 0, 0.4)
				end
				c:Show()
			else
				-- Kept shown but blanked: hiding trailing cells would make the
				-- last partial row's grid stop mid-air instead of reading as an
				-- empty slot.
				c.name = nil
				c.icon:Hide()
				c:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.3)
				c:SetBackdropColor(0, 0, 0, 0.2)
				c:Show()
			end
		end
		count:SetText(n .. (n == 1 and " icon" or " icons"))
		if selected then
			preview:SetTexture(pathFor(selected, selectedCategory))
			previewLabel:SetText(labelFor(selected))
		else
			preview:SetTexture(nil)
			previewLabel:SetText("")
		end
	end

	scroll:SetScript("OnVerticalScroll", function()
		FauxScrollFrame_OnVerticalScroll(cell, refresh)
	end)
	local function wheel()
		local bar = getglobal(scrollName .. "ScrollBar")
		if bar then bar:SetValue(bar:GetValue() - arg1 * cell) end
	end
	scroll:EnableMouseWheel(true); scroll:SetScript("OnMouseWheel", wheel)
	grid:EnableMouseWheel(true); grid:SetScript("OnMouseWheel", wheel)

	local function allIcons()
		return valuesForCategory(selectedCategory)
	end

	applyFilter = function(text)
		local all = allIcons()
		filtered = {}
		if not text or text == "" then
			for i = 1, table.getn(all) do filtered[i] = normalize(all[i]) end
		else
			local needle = string.upper(text)
			for i = 1, table.getn(all) do
				local name = normalize(all[i])
				if string.find(string.upper(labelFor(name)), needle, 1, true) then table.insert(filtered, name) end
			end
		end
		local bar = getglobal(scrollName .. "ScrollBar")
		if bar then bar:SetValue(0) end
		refresh()
	end

	-- Scrolls the selection into view; called on open so reopening the dialog
	-- lands on the icon already in use rather than back at the top.
	local function scrollToSelected()
		if not selected then return end
		for i = 1, table.getn(filtered) do
			if filtered[i] == selected then
				local row = math.floor((i - 1) / cols)
				local bar = getglobal(scrollName .. "ScrollBar")
				if bar then
					local target = (row - math.floor(vis / 2)) * cell
					local lo, hi = bar:GetMinMaxValues()
					if target < lo then target = lo elseif target > hi then target = hi end
					bar:SetValue(target)
				end
				return
			end
		end
	end

	local cancel = LibWidgets.NewButton(frame, {
		text = spec.cancelText or "Cancel", width = 90,
		onClick = function() frame.Close() end,
	})
	cancel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -pad, pad)

	local accept = LibWidgets.NewButton(frame, {
		text = spec.acceptText or "Okay", width = 90,
		onClick = function()
			local pick = selected
			frame.Close()
			if pick and spec.onAccept then spec.onAccept(pathFor(pick, selectedCategory), pick) end
		end,
	})
	accept:SetPoint("RIGHT", cancel, "LEFT", -6, 0)

	local clear = LibWidgets.NewButton(frame, {
		text = spec.clearText or "Clear", width = 90,
		onClick = function()
			frame.Close()
			if spec.onAccept then spec.onAccept("", nil) end
		end,
	})
	clear:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", pad, pad)

	function frame.Open(current)
		if categoryValues and spec.categoryFor then
			selectedCategory = spec.categoryFor(current) or selectedCategory
		end
		selected = current and current ~= "" and normalize(current) or nil
		search:SetText("")
		applyFilter("")
		scrollToSelected()
		refresh()
		frame:Show()
	end

	function frame.Close()
		LibWidgets.CloseAllMenus()
		search:ClearFocus()
		frame:Hide()
		if spec.onClose then spec.onClose() end
	end

	frame:SetScript("OnHide", function() LibWidgets.CloseAllMenus() end)

	-- Escape closes, the same as any Blizzard dialog.
	if UISpecialFrames then table.insert(UISpecialFrames, scrollName .. "Dialog") end

	return frame
end

-- A syntax-coloured Lua code editor; see the header comment for spec. Built by
-- decorating NewMultiLineEditBox rather than rebuilding one.
--
-- Colouring happens on blur, never while typing. That is a deliberate limit,
-- not a stopgap: the plain code lives in a private upvalue and the edit box
-- holds the display form, so a focused box contains exactly what the user
-- typed and the caret can never land inside a colour escape.
--
-- The error line and the reset button belong to the widget because both have
-- to sit relative to the box and share its lifetime. What stays with the
-- consumer is the *policy*: `validate` decides what counts as an error (only
-- the consumer knows what wrapper the code is compiled behind) and `default`
-- supplies the reset content.
function LibWidgets.NewCodeEditBox(parent, spec)
	spec = spec or {}
	local w = spec.width or 300
	local h = spec.height or 150
	local colors = spec.colors or LibWidgets.DEFAULT_LUA_COLORS

	local box = LibWidgets.NewMultiLineEditBox(parent, { width = w, height = h })
	local edit = box.edit

	-- Colouring roughly triples the buffer; at the default cap the engine would
	-- silently truncate the user's code the moment it is coloured.
	edit:SetMaxBytes(0)
	edit:SetMaxLetters(0)

	-- Font is settable after construction, not baked in: a pooled box gets
	-- rebound to whatever the consumer's current setting is on every paint.
	-- box.setFont falls back to GameFontHighlightSmall when the file is missing
	-- (SetFont returns falsy) rather than leaving an invisible edit box.
	local fontPath = spec.font and spec.font.path
	local fontSize = (spec.font and spec.font.size) or 12
	local fontFlags = (spec.font and spec.font.flags) or ""
	local baseSetFont = box.setFont
	if fontPath then baseSetFont(fontPath, fontSize, fontFlags) end

	function box.setFontSize(size)
		if not size or size == fontSize then return end
		fontSize = size
		if fontPath then baseSetFont(fontPath, fontSize, fontFlags) end
	end
	function box.getFontSize() return fontSize end
	function box.setFont(path, size, flags)
		fontPath, fontSize, fontFlags = path, size or fontSize, flags or fontFlags
		return baseSetFont(fontPath, fontSize, fontFlags)
	end

	-- The plain, decoded source. The edit box's own text is private: it is
	-- either the encoded-plain form (focused) or the coloured form (blurred).
	local code = ""
	local suppress = false
	-- Tracked rather than read back with HasFocus: the focus state is only ever
	-- changed by the two handlers below, and this needs no API beyond them.
	local focused = false

	local errText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	errText:SetJustifyH("LEFT")
	errText:SetTextColor(1, 0.35, 0.35)
	errText:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 2, -3)
	box.errText = errText

	local function runValidate()
		if not spec.validate then return end
		errText:SetText(spec.validate(code) or "")
	end

	-- Live colouring: off unless the consumer asks for it. When on, the box
	-- holds coloured text even while focused, so the caret has to be saved and
	-- restored around every recolour (see the caret block below).
	local live = spec.live and true or false
	local dirty, lastColored

	local function showPlain()
		suppress = true
		edit:SetText(LibWidgets.LuaEncode(code))
		box.fit()
		suppress = false
		lastColored = nil
	end

	local function showColored()
		suppress = true
		-- Padded like the live path: an unterminated string swallows every
		-- token after it, and the blurred box is where most code is looked at.
		local t = LibWidgets.LuaPadWithLinebreaks(
			LibWidgets.LuaColorize(LibWidgets.LuaEncode(code), colors))
		edit:SetText(t)
		box.fit()
		suppress = false
		lastColored = t
	end

	-- Which form the box should be showing right now.
	local function refresh()
		if live or not focused then showColored() else showPlain() end
	end

	edit:SetScript("OnEditFocusGained", function()
		takeFocus(this)
		focused = true
		refresh()
	end)

	edit:SetScript("OnTextChanged", function()
		-- This handler replaces the base widget's, so it owns the refit too --
		-- and it has to run even when suppressed, because colouring changes how
		-- the text wraps and therefore how tall the box needs to be.
		box.fit()
		if suppress then return end
		code = LibWidgets.LuaDecode(this:GetText())
		runValidate()
		if live then dirty = GetTime() end
		if spec.onChange then spec.onChange(code) end
	end)

	edit:SetScript("OnEditFocusLost", function()
		focused = false
		dirty = nil
		if spec.onCommit then spec.onCommit(code) end
		showColored()
	end)

	-- -----------------------------------------------------------------------
	-- Caret save/restore, for live colouring only.
	--
	-- This client has no GetCursorPosition/SetCursorPosition, so the caret is
	-- read by inserting a byte the text cannot contain and finding it, and
	-- written by inserting a throwaway character at the target and selecting it
	-- away. Both are confirmed working here: \1 survives a GetText round-trip,
	-- and HighlightText/Insert index in raw bytes (escapes counted), which is
	-- what the offsets below assume.
	--
	-- OnTextSet is nil'd across each critical section so a handler cannot
	-- re-enter this while the text is in a half-written state.
	local CARET_SENTINEL = "\1"

	local function criticalEnter()
		local script = edit:GetScript("OnTextSet")
		if script then edit:SetScript("OnTextSet", nil) end
		return script
	end

	local function criticalLeave(script)
		if script then edit:SetScript("OnTextSet", script) end
	end

	local function setCaretPos(pos)
		local text = edit:GetText() or ""
		if string.len(text) == 0 then return end
		suppress = true
		edit:SetText(string.sub(text, 1, pos) .. "a" .. string.sub(text, pos + 1))
		edit:HighlightText(pos, pos + 1)
		edit:Insert("\0")
		suppress = false
	end

	local function getCaretPos()
		local script = criticalEnter()
		local text = edit:GetText() or ""
		suppress = true
		edit:Insert(CARET_SENTINEL)
		local pos = string.find(edit:GetText() or "", CARET_SENTINEL, 1, true)
		edit:SetText(text)
		suppress = false
		-- SetText drops the caret to the end, so put it back where it was.
		if pos then setCaretPos(pos - 1) end
		criticalLeave(script)
		return (pos or 1) - 1
	end

	-- Recolours in place, keeping the caret where the user left it. Throttled
	-- by the OnUpdate below rather than run per keystroke: the tokenizer walks
	-- the whole buffer, and a caret round-trip costs three SetTexts.
	local function recolorLive()
		local orgCode = edit:GetText() or ""
		if orgCode == lastColored then return end

		local pos = getCaretPos()
		local plain, plainPos = LibWidgets.LuaStripColorsWithPos(orgCode, pos)

		-- Bracket matching rides on this pass, which is why it needs live mode:
		-- it depends on knowing where the caret is, and the caret only exists
		-- while the box is focused. LuaMatchBracket takes a 0-based offset,
		-- plainPos is 1-based.
		local highlight
		if spec.matchBrackets ~= false then
			local a, b = LibWidgets.LuaMatchBracket(plain, plainPos - 1)
			if a then highlight = { [a] = true, [b] = true } end
		end

		local newCode, newPos = LibWidgets.LuaColorize(plain, colors, plainPos, highlight)
		-- Contains a runaway colour from an unterminated string, which would
		-- otherwise bleed over everything after it.
		newCode = LibWidgets.LuaPadWithLinebreaks(newCode)
		lastColored = newCode

		if orgCode == newCode then return end
		local script = criticalEnter()
		suppress = true
		edit:SetText(newCode)
		suppress = false
		if newPos then
			if newPos < 0 then newPos = 0 end
			local maxPos = string.len(newCode)
			if newPos > maxPos then newPos = maxPos end
			setCaretPos(newPos)
		end
		criticalLeave(script)
	end

	box:SetScript("OnUpdate", function()
		if not dirty then return end
		if GetTime() - dirty < 0.2 then return end
		dirty = nil
		recolorLive()
	end)

	-- Tab re-indents the whole buffer. Unlike live colouring this is safe to
	-- ship on by default: it is a discrete action the user asked for, so a
	-- caret hiccup is something they can see and undo by retyping, not a
	-- per-keystroke defect. Colours are only re-applied when the box is
	-- currently showing them.
	local tabWidth = spec.tabWidth or 2

	local function indentNow()
		local orgCode = edit:GetText() or ""
		if orgCode == "" then return end

		local pos = getCaretPos()
		local plain, plainPos = LibWidgets.LuaStripColorsWithPos(orgCode, pos)
		local newCode, newPos = LibWidgets.LuaIndent(plain, tabWidth, live and colors or nil, plainPos)
		if live then newCode = LibWidgets.LuaPadWithLinebreaks(newCode) end
		if newCode == orgCode then return end

		local script = criticalEnter()
		suppress = true
		edit:SetText(newCode)
		suppress = false
		code = LibWidgets.LuaDecode(newCode)
		lastColored = live and newCode or nil
		if newPos then
			if newPos < 0 then newPos = 0 end
			local maxPos = string.len(newCode)
			if newPos > maxPos then newPos = maxPos end
			setCaretPos(newPos)
		end
		criticalLeave(script)

		runValidate()
		if spec.onChange then spec.onChange(code) end
	end

	edit:SetScript("OnTabPressed", function() indentNow() end)
	box.indent = indentNow
	function box.setTabWidth(n) tabWidth = n end
	function box.getTabWidth() return tabWidth end

	-- Reset is two-click confirm, the same as any other irreversible action
	-- here: it discards whatever the user wrote, and this client has no undo.
	-- Always built, shown only while a default is bound, so a pooling consumer
	-- can rebind one instance between fields that do and don't have one.
	local reset = LibWidgets.NewButton(box, { text = "Reset", width = 60, height = 18 })
	reset:SetPoint("BOTTOMRIGHT", box, "TOPRIGHT", -2, 2)
	box.resetButton = reset

	local function disarm()
		reset.armed = nil
		reset.setText("Reset")
		reset:SetBackdropColor(0, 0, 0, 0.7)
		reset:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
	end
	reset.disarm = disarm

	reset:SetScript("OnClick", function()
		LibWidgets.CloseAllMenus()
		if spec.default == nil then return end
		if reset.armed then
			disarm()
			box.setText(type(spec.default) == "function" and spec.default() or spec.default)
			if spec.onCommit then spec.onCommit(code) end
			if spec.onChange then spec.onChange(code) end
		else
			reset.armed = true
			reset.setText("Sure?")
			reset:SetBackdropColor(0.65, 0.06, 0.06, 1)
			reset:SetBackdropBorderColor(1, 0.3, 0.3, 1)
			if C_Timer then
				C_Timer.After(3, function() if reset.armed then disarm() end end)
			end
		end
	end)
	disarm()

	-- Mirrors NewMultiLineEditBox's surface so a pooling consumer can treat the
	-- two nearly identically.
	function box.setText(t)
		code = t or ""
		dirty = nil
		refresh()
		runValidate()
	end

	-- Toggling live mode repaints into the other form immediately, so a
	-- consumer flipping the setting doesn't leave a half-coloured box behind.
	function box.setLive(on)
		local want = on and true or false
		if want == live then return end
		live = want
		dirty = nil
		refresh()
	end
	function box.isLive() return live end
	function box.getText() return code end
	function box.clearFocus() edit:ClearFocus() end


	-- Re-runs the validator against the current code without touching the text.
	-- A pooling consumer needs this: it seeds the box before binding the new
	-- field's validator, so the error line is a beat behind until this runs.
	box.revalidate = runValidate

	function box.setValidate(fn) spec.validate = fn; runValidate() end
	function box.setHandlers(onChange, onCommit) spec.onChange = onChange; spec.onCommit = onCommit end

	-- nil hides Reset entirely; the button is never destroyed, only parked.
	function box.setDefault(d)
		spec.default = d
		disarm()
		if d == nil then reset:Hide() else reset:Show() end
	end

	box.setDefault(spec.default)
	box.setText(spec.text or "")
	return box
end

-- ---------------------------------------------------------------------------
-- Lua source tokenizer + syntax colouring
--
-- Ported from "For All Indents And Purposes", Copyright (c) 2007 Kristofer
-- Karlsson <kristofer.karlsson@gmail.com>, under the MIT licence reproduced in
-- this library's LICENSE.
--
-- Pure string -> string: no frames, no per-edit-box state, so a consumer can
-- colour a buffer with no widget involved (and so this half is testable off
-- the client, which the rest of this file is not).
--
-- Two encodings live here and must never be confused:
--   1. Pipe doubling -- a literal "|" in user code has to reach the engine as
--      "||" or the engine reads it as the start of an escape.
--   2. Colour wrapping -- "|cAARRGGBB" .. token .. "|r" around each token.
-- The order is fixed: writing is Colorize(Encode(code)), reading is
-- Decode(text), which undoes the colours and the doubling in that order.
-- ---------------------------------------------------------------------------

local strbyte, strsub, strlen, strfind, strgsub = string.byte, string.sub, string.len, string.find, string.gsub

local T = {
	TOKEN_UNKNOWN = 0, TOKEN_NUMBER = 1, TOKEN_LINEBREAK = 2,
	TOKEN_WHITESPACE = 3, TOKEN_IDENTIFIER = 4, TOKEN_ASSIGNMENT = 5,
	TOKEN_EQUALITY = 6, TOKEN_MINUS = 7, TOKEN_COMMENT_SHORT = 8,
	TOKEN_COMMENT_LONG = 9, TOKEN_STRING = 10, TOKEN_LEFTBRACKET = 11,
	TOKEN_PERIOD = 12, TOKEN_DOUBLEPERIOD = 13, TOKEN_TRIPLEPERIOD = 14,
	TOKEN_LTE = 15, TOKEN_LT = 16, TOKEN_GTE = 17, TOKEN_GT = 18,
	TOKEN_NOTEQUAL = 19, TOKEN_COMMA = 20, TOKEN_SEMICOLON = 21,
	TOKEN_COLON = 22, TOKEN_LEFTPAREN = 23, TOKEN_RIGHTPAREN = 24,
	TOKEN_PLUS = 25, TOKEN_SLASH = 27, TOKEN_LEFTWING = 28,
	TOKEN_RIGHTWING = 29, TOKEN_CIRCUMFLEX = 30, TOKEN_ASTERISK = 31,
	TOKEN_RIGHTBRACKET = 32, TOKEN_KEYWORD = 33, TOKEN_SPECIAL = 34,
	TOKEN_VERTICAL = 35, TOKEN_TILDE = 36,
	-- WoW colour escapes, so the tokenizer can skip over its own output.
	TOKEN_COLORCODE_START = 37, TOKEN_COLORCODE_STOP = 38,
}
LibWidgets.LuaTokens = T

local B = {}
local function byteOf(c) B[c] = strbyte(c); return B[c] end
local BYTE_LF, BYTE_CR = byteOf("\n"), byteOf("\r")
local BYTE_SQUOTE, BYTE_DQUOTE = byteOf("'"), byteOf('"')
local BYTE_0, BYTE_9 = byteOf("0"), byteOf("9")
local BYTE_PERIOD, BYTE_SPACE, BYTE_TAB = byteOf("."), byteOf(" "), byteOf("\t")
local BYTE_E, BYTE_e, BYTE_MINUS = byteOf("E"), byteOf("e"), byteOf("-")
local BYTE_EQUALS, BYTE_LBRACKET, BYTE_RBRACKET = byteOf("="), byteOf("["), byteOf("]")
local BYTE_BACKSLASH, BYTE_LT, BYTE_GT = byteOf("\\"), byteOf("<"), byteOf(">")
local BYTE_TILDE, BYTE_VERTICAL = byteOf("~"), byteOf("|")
local BYTE_r, BYTE_c = byteOf("r"), byteOf("c")

local linebreakChars = {}
linebreakChars[BYTE_LF] = 1
linebreakChars[BYTE_CR] = 1

local whitespaceChars = {}
whitespaceChars[BYTE_SPACE] = 1
whitespaceChars[BYTE_TAB] = 1

-- -1 means "needs a closer look in nextToken"; anything else is the token type
-- that single character produces outright.
local specialChars = {}
specialChars[BYTE_PERIOD] = -1
specialChars[BYTE_LT] = -1
specialChars[BYTE_GT] = -1
specialChars[BYTE_LBRACKET] = -1
specialChars[BYTE_EQUALS] = -1
specialChars[BYTE_MINUS] = -1
specialChars[BYTE_SQUOTE] = -1
specialChars[BYTE_DQUOTE] = -1
specialChars[BYTE_TILDE] = -1
specialChars[BYTE_VERTICAL] = -1
specialChars[BYTE_RBRACKET] = T.TOKEN_RIGHTBRACKET
specialChars[byteOf(",")] = T.TOKEN_COMMA
specialChars[byteOf(":")] = T.TOKEN_COLON
specialChars[byteOf(";")] = T.TOKEN_SEMICOLON
specialChars[byteOf("(")] = T.TOKEN_LEFTPAREN
specialChars[byteOf(")")] = T.TOKEN_RIGHTPAREN
specialChars[byteOf("+")] = T.TOKEN_PLUS
specialChars[byteOf("/")] = T.TOKEN_SLASH
specialChars[byteOf("{")] = T.TOKEN_LEFTWING
specialChars[byteOf("}")] = T.TOKEN_RIGHTWING
specialChars[byteOf("^")] = T.TOKEN_CIRCUMFLEX
specialChars[byteOf("*")] = T.TOKEN_ASTERISK
-- `#` and `%` are not operators in 5.0, so they get no token type of their own
-- -- but they still have to *bound* a token, or "a%b" lexes as one identifier.
specialChars[byteOf("#")] = T.TOKEN_SPECIAL
specialChars[byteOf("%")] = T.TOKEN_SPECIAL

local function nextNumberExponentPartInt(text, pos)
	while true do
		local byte = strbyte(text, pos)
		if not byte then return T.TOKEN_NUMBER, pos end
		if byte >= BYTE_0 and byte <= BYTE_9 then
			pos = pos + 1
		else
			return T.TOKEN_NUMBER, pos
		end
	end
end

local function nextNumberExponentPart(text, pos)
	local byte = strbyte(text, pos)
	if not byte then return T.TOKEN_NUMBER, pos end
	if byte == BYTE_MINUS then
		-- "1.2e-- a comment": the exponent's sign turns out to be a comment
		-- start, so "1.2e" ends the number here.
		byte = strbyte(text, pos + 1)
		if byte == BYTE_MINUS then return T.TOKEN_NUMBER, pos end
		return nextNumberExponentPartInt(text, pos + 1)
	end
	return nextNumberExponentPartInt(text, pos)
end

local function nextNumberFractionPart(text, pos)
	while true do
		local byte = strbyte(text, pos)
		if not byte then return T.TOKEN_NUMBER, pos end
		if byte >= BYTE_0 and byte <= BYTE_9 then
			pos = pos + 1
		elseif byte == BYTE_E or byte == BYTE_e then
			return nextNumberExponentPart(text, pos + 1)
		else
			return T.TOKEN_NUMBER, pos
		end
	end
end

local function nextNumberIntPart(text, pos)
	while true do
		local byte = strbyte(text, pos)
		if not byte then return T.TOKEN_NUMBER, pos end
		if byte >= BYTE_0 and byte <= BYTE_9 then
			pos = pos + 1
		elseif byte == BYTE_PERIOD then
			return nextNumberFractionPart(text, pos + 1)
		elseif byte == BYTE_E or byte == BYTE_e then
			return nextNumberExponentPart(text, pos + 1)
		else
			return T.TOKEN_NUMBER, pos
		end
	end
end

local function nextIdentifier(text, pos)
	while true do
		local byte = strbyte(text, pos)
		if not byte or linebreakChars[byte] or whitespaceChars[byte] or specialChars[byte] then
			return T.TOKEN_IDENTIFIER, pos
		end
		pos = pos + 1
	end
end

-- false, or: true, position after the opening bracket, number of "=" in it.
local function isBracketStringNext(text, pos)
	local byte = strbyte(text, pos)
	if byte ~= BYTE_LBRACKET then return false end
	local pos2 = pos + 1
	byte = strbyte(text, pos2)
	while byte == BYTE_EQUALS do
		pos2 = pos2 + 1
		byte = strbyte(text, pos2)
	end
	if byte == BYTE_LBRACKET then
		return true, pos2 + 1, (pos2 - 1) - pos
	end
	return false
end

-- The "[==[" is already consumed; find the matching close of the same level.
local function nextBracketString(text, pos, equalsCount)
	local state = 0
	while true do
		local byte = strbyte(text, pos)
		if not byte then return T.TOKEN_STRING, pos end
		if byte == BYTE_RBRACKET then
			if state == 0 then
				state = 1
			elseif state == equalsCount + 1 then
				return T.TOKEN_STRING, pos + 1
			else
				state = 0
			end
		elseif byte == BYTE_EQUALS then
			if state > 0 then state = state + 1 end
		else
			state = 0
		end
		pos = pos + 1
	end
end

-- The "--" is already consumed.
local function nextComment(text, pos)
	local isBracketString, nextPos, equalsCount = isBracketStringNext(text, pos)
	if isBracketString then
		local _, nextPos2 = nextBracketString(text, nextPos, equalsCount)
		return T.TOKEN_COMMENT_LONG, nextPos2
	end
	while true do
		local byte = strbyte(text, pos)
		if not byte or linebreakChars[byte] then return T.TOKEN_COMMENT_SHORT, pos end
		pos = pos + 1
	end
end

local function nextString(text, pos, character)
	local even = true
	while true do
		local byte = strbyte(text, pos)
		if not byte then return T.TOKEN_STRING, pos end
		if byte == character and even then return T.TOKEN_STRING, pos + 1 end
		if byte == BYTE_BACKSLASH then even = not even else even = true end
		pos = pos + 1
	end
end

-- Returns the token type and the position one past the token's last character,
-- or nil once `pos` is past the end of `text`.
local function nextToken(text, pos)
	local byte = strbyte(text, pos)
	if not byte then return nil end

	if linebreakChars[byte] then return T.TOKEN_LINEBREAK, pos + 1 end

	if whitespaceChars[byte] then
		while true do
			pos = pos + 1
			byte = strbyte(text, pos)
			if not byte or not whitespaceChars[byte] then return T.TOKEN_WHITESPACE, pos end
		end
	end

	local token = specialChars[byte]
	if token then
		if token ~= -1 then return token, pos + 1 end

		-- A colour escape this function's own output may contain: skipped as
		-- one token so re-colouring already-coloured text is idempotent.
		if byte == BYTE_VERTICAL then
			byte = strbyte(text, pos + 1)
			if byte == BYTE_VERTICAL then return T.TOKEN_VERTICAL, pos + 2 end
			if byte == BYTE_c then return T.TOKEN_COLORCODE_START, pos + 10 end
			if byte == BYTE_r then return T.TOKEN_COLORCODE_STOP, pos + 2 end
			return T.TOKEN_UNKNOWN, pos + 1
		end

		if byte == BYTE_MINUS then
			byte = strbyte(text, pos + 1)
			if byte == BYTE_MINUS then return nextComment(text, pos + 2) end
			return T.TOKEN_MINUS, pos + 1
		end

		if byte == BYTE_SQUOTE then return nextString(text, pos + 1, BYTE_SQUOTE) end
		if byte == BYTE_DQUOTE then return nextString(text, pos + 1, BYTE_DQUOTE) end

		if byte == BYTE_LBRACKET then
			local isBracketString, nextPos, equalsCount = isBracketStringNext(text, pos)
			if isBracketString then return nextBracketString(text, nextPos, equalsCount) end
			return T.TOKEN_LEFTBRACKET, pos + 1
		end

		if byte == BYTE_EQUALS then
			if strbyte(text, pos + 1) == BYTE_EQUALS then return T.TOKEN_EQUALITY, pos + 2 end
			return T.TOKEN_ASSIGNMENT, pos + 1
		end

		if byte == BYTE_PERIOD then
			byte = strbyte(text, pos + 1)
			if not byte then return T.TOKEN_PERIOD, pos + 1 end
			if byte == BYTE_PERIOD then
				if strbyte(text, pos + 2) == BYTE_PERIOD then return T.TOKEN_TRIPLEPERIOD, pos + 3 end
				return T.TOKEN_DOUBLEPERIOD, pos + 2
			elseif byte >= BYTE_0 and byte <= BYTE_9 then
				return nextNumberFractionPart(text, pos + 2)
			end
			return T.TOKEN_PERIOD, pos + 1
		end

		if byte == BYTE_LT then
			if strbyte(text, pos + 1) == BYTE_EQUALS then return T.TOKEN_LTE, pos + 2 end
			return T.TOKEN_LT, pos + 1
		end

		if byte == BYTE_GT then
			if strbyte(text, pos + 1) == BYTE_EQUALS then return T.TOKEN_GTE, pos + 2 end
			return T.TOKEN_GT, pos + 1
		end

		if byte == BYTE_TILDE then
			if strbyte(text, pos + 1) == BYTE_EQUALS then return T.TOKEN_NOTEQUAL, pos + 2 end
			return T.TOKEN_TILDE, pos + 1
		end

		return T.TOKEN_UNKNOWN, pos + 1
	elseif byte >= BYTE_0 and byte <= BYTE_9 then
		return nextNumberIntPart(text, pos + 1)
	else
		return nextIdentifier(text, pos + 1)
	end
end
LibWidgets.LuaNextToken = nextToken

-- Each keyword maps to {before, after}: how it shifts the indent level of the
-- line it appears on, and of the lines after it. Truthiness alone is what the
-- colouriser needs; the pair is what LuaIndent needs.
local noIndentEffect = { 0, 0 }
local indentLeft = { -1, 0 }
local indentRight = { 0, 1 }
local indentBoth = { -1, 1 }

local luaKeywords = {}
LibWidgets.LuaKeywords = luaKeywords
do
	local plain = { "and", "break", "false", "for", "if", "in", "local", "nil",
		"not", "or", "return", "true", "while" }
	for i = 1, table.getn(plain) do luaKeywords[plain[i]] = noIndentEffect end
	luaKeywords["until"] = indentLeft
	luaKeywords["elseif"] = indentLeft
	luaKeywords["end"] = indentLeft
	luaKeywords["do"] = indentRight
	luaKeywords["then"] = indentRight
	luaKeywords["repeat"] = indentRight
	luaKeywords["function"] = indentRight
	luaKeywords["else"] = indentBoth
end

local tokenIndentation = {}
LibWidgets.LuaTokenIndentation = tokenIndentation
tokenIndentation[T.TOKEN_LEFTPAREN] = indentRight
tokenIndentation[T.TOKEN_LEFTBRACKET] = indentRight
tokenIndentation[T.TOKEN_LEFTWING] = indentRight
tokenIndentation[T.TOKEN_RIGHTPAREN] = indentLeft
tokenIndentation[T.TOKEN_RIGHTBRACKET] = indentLeft
tokenIndentation[T.TOKEN_RIGHTWING] = indentLeft

-- Alpha is "ff", not upstream's "00": a fully transparent alpha is ignored by
-- the retail text engine but is not worth relying on here.
local DEFAULT_LUA_COLORS = {}
LibWidgets.DEFAULT_LUA_COLORS = DEFAULT_LUA_COLORS
do
	local C = DEFAULT_LUA_COLORS
	C[T.TOKEN_SPECIAL] = "|cffff99ff"
	C[T.TOKEN_KEYWORD] = "|cff6666ff"
	C[T.TOKEN_COMMENT_SHORT] = "|cff999999"
	C[T.TOKEN_COMMENT_LONG] = "|cff999999"
	local stringColor = "|cffffff77"
	C[T.TOKEN_STRING] = stringColor
	C[".."] = stringColor
	local tableColor = "|cffff9900"
	C["..."] = tableColor
	C["{"] = tableColor; C["}"] = tableColor; C["["] = tableColor; C["]"] = tableColor
	local arithmeticColor = "|cff33ff55"
	C[T.TOKEN_NUMBER] = arithmeticColor
	C["+"] = arithmeticColor; C["-"] = arithmeticColor
	C["/"] = arithmeticColor; C["*"] = arithmeticColor
	local logicColor1 = "|cff55ff88"
	C["=="] = logicColor1; C["<"] = logicColor1; C["<="] = logicColor1
	C[">"] = logicColor1; C[">="] = logicColor1; C["~="] = logicColor1
	local logicColor2 = "|cff88ffbb"
	C["and"] = logicColor2; C["or"] = logicColor2; C["not"] = logicColor2
	-- The matched bracket pair under the caret. White, because every other
	-- colour here is already spoken for and the point is that it stands out.
	C.match = "|cffffffff"
	-- Key 0 is the "stop colour"; its absence disables colouring entirely.
	C[0] = "|r"
end

-- Reused across calls to keep a tokenizer pass from generating a table per
-- token. Safe because nothing here is re-entrant: LuaColorize never calls
-- LuaStripColors and vice versa.
local workingTable = {}
local workingTable2 = {}
local function tableclear(t)
	for k in next, t do t[k] = nil end
end

-- Wraps every token in its colour. Returns the coloured string, the caret
-- position translated into it (when `caretPosition` is given), and the line
-- count. Pure: no widget is touched.
-- `highlight`, when given, is a set of 1-based token start positions to paint
-- in colorTable.match instead of their usual colour -- how bracket matching is
-- drawn (see LuaMatchBracket).
function LibWidgets.LuaColorize(code, colorTable, caretPosition, highlight)
	colorTable = colorTable or DEFAULT_LUA_COLORS
	local stopColor = colorTable[0]
	if not stopColor then return code, caretPosition end
	local stopColorLen = strlen(stopColor)

	tableclear(workingTable)
	local tsize, totalLen, numLines = 0, 0, 0
	local newCaretPosition
	local prevTokenWasColored, prevTokenWidth = false, 0
	local pos = 1

	while true do
		if caretPosition and not newCaretPosition and pos >= caretPosition then
			newCaretPosition = totalLen
			if pos ~= caretPosition then
				local diff = pos - caretPosition
				if diff > prevTokenWidth then diff = prevTokenWidth end
				if prevTokenWasColored then diff = diff + stopColorLen end
				newCaretPosition = newCaretPosition - diff
			end
		end

		prevTokenWasColored, prevTokenWidth = false, 0

		local tokenType, nextPos = nextToken(code, pos)
		if not tokenType then break end

		if tokenType == T.TOKEN_COLORCODE_START or tokenType == T.TOKEN_COLORCODE_STOP
			or tokenType == T.TOKEN_UNKNOWN then
			-- Drop colour codes already in the text rather than colouring them.
		elseif tokenType == T.TOKEN_LINEBREAK or tokenType == T.TOKEN_WHITESPACE then
			if tokenType == T.TOKEN_LINEBREAK then numLines = numLines + 1 end
			local str = strsub(code, pos, nextPos - 1)
			prevTokenWidth = nextPos - pos
			tsize = tsize + 1
			workingTable[tsize] = str
			totalLen = totalLen + strlen(str)
		else
			local str = strsub(code, pos, nextPos - 1)
			prevTokenWidth = nextPos - pos
			if luaKeywords[str] then tokenType = T.TOKEN_KEYWORD end

			-- Exact-text colours win over per-token-type ones, which is how
			-- "and"/"or"/"not" get their own colour despite being keywords.
			-- A highlighted position outranks both.
			local color
			if highlight and highlight[pos] then color = colorTable.match end
			if not color then
				color = colorTable[str] or colorTable[tokenType] or colorTable[T.TOKEN_SPECIAL]
			end

			if color then
				tsize = tsize + 1; workingTable[tsize] = color
				tsize = tsize + 1; workingTable[tsize] = str
				tsize = tsize + 1; workingTable[tsize] = stopColor
				totalLen = totalLen + strlen(color) + (nextPos - pos) + stopColorLen
				prevTokenWasColored = true
			else
				tsize = tsize + 1; workingTable[tsize] = str
				totalLen = totalLen + strlen(str)
			end
		end

		pos = nextPos
	end
	return table.concat(workingTable), newCaretPosition, numLines
end

-- Bracket pairing. Runs over the token stream, not the raw bytes, so a bracket
-- inside a string or a comment is correctly not a bracket.
local bracketCloser = {}
bracketCloser[T.TOKEN_LEFTPAREN] = T.TOKEN_RIGHTPAREN
bracketCloser[T.TOKEN_LEFTBRACKET] = T.TOKEN_RIGHTBRACKET
bracketCloser[T.TOKEN_LEFTWING] = T.TOKEN_RIGHTWING
local bracketOpener = {}
for open, close in pairs(bracketCloser) do bracketOpener[close] = open end

-- Given a caret as a 0-based byte offset, returns the 1-based positions of the
-- bracket next to it and of its partner, or nil when the caret isn't beside a
-- matched bracket. A bracket counts as "beside" the caret on either side, which
-- is what every editor does and what makes the affordance feel right when you
-- have just typed a closer.
function LibWidgets.LuaMatchBracket(code, pos)
	local stack, sn, matched = {}, 0, {}
	local p = 1
	while true do
		local tt, np = nextToken(code, p)
		if not tt then break end
		if bracketCloser[tt] then
			sn = sn + 1
			stack[sn] = { tt = tt, at = p }
		elseif bracketOpener[tt] then
			-- Only pair like with like; a mismatched closer stays unmatched
			-- rather than swallowing an opener of another kind.
			if sn > 0 and stack[sn].tt == bracketOpener[tt] then
				matched[stack[sn].at] = p
				matched[p] = stack[sn].at
				sn = sn - 1
			end
		end
		p = np
	end
	-- Brackets are one byte, so the one left of the caret starts at `pos` and
	-- the one right of it starts at `pos + 1`.
	local at
	if matched[pos] then at = pos elseif matched[pos + 1] then at = pos + 1 end
	if not at then return nil end
	return at, matched[at]
end

-- Re-indents whole lines and colours in one pass (colouring is skipped when
-- `colorTable` is nil, which is what an uncoloured box wants). `tabWidth` is a
-- number of spaces per level; pass `false` for hard tabs. Returns the new code
-- and the translated caret position.
--
-- Two buffers: `workingTable` is the finished output, `workingTable2` holds the
-- current line until its indent level is known -- the level can still move
-- while the line is being read (an "end" pulls its own line left), so a line
-- can't be emitted until its last token is in.
function LibWidgets.LuaIndent(code, tabWidth, colorTable, caretPosition)
	if tabWidth == nil then tabWidth = 2 end
	local function fill(level)
		if tabWidth == false then return string.rep("\t", level) end
		return string.rep(" ", level * tabWidth)
	end

	tableclear(workingTable)
	tableclear(workingTable2)
	local tsize, totalLen = 0, 0
	local tsize2, totalLen2 = 0, 0

	local stopColor = colorTable and colorTable[0]
	local stopColorLen = stopColor and strlen(stopColor) or 0

	local newCaretPosition, newCaretPositionFinalized
	local prevTokenWasColored, prevTokenWidth = false, 0

	local pos, level = 1, 0
	local hitNonWhitespace, hitIndentRight = false, false
	local preIndent, postIndent = 0, 0

	while true do
		if caretPosition and not newCaretPosition and pos >= caretPosition then
			newCaretPosition = totalLen + totalLen2
			if pos ~= caretPosition then
				local diff = pos - caretPosition
				if diff > prevTokenWidth then diff = prevTokenWidth end
				if prevTokenWasColored then diff = diff + stopColorLen end
				newCaretPosition = newCaretPosition - diff
			end
		end

		prevTokenWasColored, prevTokenWidth = false, 0

		local tokenType, nextPos = nextToken(code, pos)

		if not tokenType or tokenType == T.TOKEN_LINEBREAK then
			-- End of a line: its indent is finally known, so emit the padding
			-- and then the line that was buffered behind it.
			level = level + preIndent
			if level < 0 then level = 0 end

			local s = fill(level)
			tsize = tsize + 1
			workingTable[tsize] = s
			totalLen = totalLen + strlen(s)

			if newCaretPosition and not newCaretPositionFinalized then
				newCaretPosition = newCaretPosition + strlen(s)
				newCaretPositionFinalized = true
			end

			-- Indexed, not `next`: this appends to an ordered output buffer and
			-- `next` does not promise array order.
			for i = 1, tsize2 do
				tsize = tsize + 1
				workingTable[tsize] = workingTable2[i]
				totalLen = totalLen + strlen(workingTable2[i])
			end

			if not tokenType then break end

			tsize = tsize + 1
			workingTable[tsize] = strsub(code, pos, nextPos - 1)
			totalLen = totalLen + nextPos - pos

			level = level + postIndent
			if level < 0 then level = 0 end

			tableclear(workingTable2)
			tsize2, totalLen2 = 0, 0
			hitNonWhitespace, hitIndentRight = false, false
			preIndent, postIndent = 0, 0
		elseif tokenType == T.TOKEN_WHITESPACE then
			-- Leading whitespace is dropped -- that's the re-indent. Whitespace
			-- after the first real token is the user's own spacing, so it stays.
			if hitNonWhitespace then
				prevTokenWidth = nextPos - pos
				local s = strsub(code, pos, nextPos - 1)
				tsize2 = tsize2 + 1
				workingTable2[tsize2] = s
				totalLen2 = totalLen2 + strlen(s)
			end
		elseif tokenType == T.TOKEN_COLORCODE_START or tokenType == T.TOKEN_COLORCODE_STOP
			or tokenType == T.TOKEN_UNKNOWN then
			-- Dropped; re-coloured below if a colour table is in play.
		else
			hitNonWhitespace = true
			local str = strsub(code, pos, nextPos - 1)
			prevTokenWidth = nextPos - pos

			local indentTable
			if tokenType == T.TOKEN_IDENTIFIER then
				indentTable = luaKeywords[str]
			else
				indentTable = tokenIndentation[tokenType]
			end
			if indentTable then
				-- Once something has opened a block on this line, anything else
				-- on it can only affect the lines *after* it -- otherwise
				-- "function() return {" would pull its own line left again.
				if hitIndentRight then
					postIndent = postIndent + indentTable[1] + indentTable[2]
				else
					if indentTable[2] > 0 then hitIndentRight = true end
					preIndent = preIndent + indentTable[1]
					postIndent = postIndent + indentTable[2]
				end
			end

			if luaKeywords[str] then tokenType = T.TOKEN_KEYWORD end

			local color
			if stopColor then
				color = colorTable[str] or colorTable[tokenType] or colorTable[T.TOKEN_SPECIAL]
			end

			if color then
				tsize2 = tsize2 + 1; workingTable2[tsize2] = color
				tsize2 = tsize2 + 1; workingTable2[tsize2] = str
				tsize2 = tsize2 + 1; workingTable2[tsize2] = stopColor
				totalLen2 = totalLen2 + strlen(color) + (nextPos - pos) + stopColorLen
				prevTokenWasColored = true
			else
				tsize2 = tsize2 + 1; workingTable2[tsize2] = str
				totalLen2 = totalLen2 + (nextPos - pos)
			end
		end

		pos = nextPos
	end
	return table.concat(workingTable), newCaretPosition
end

-- Removes every "|cAARRGGBB" / "|r" escape, leaving literal "||" alone.
function LibWidgets.LuaStripColors(code)
	-- An unterminated string makes a colour run to the end of the buffer, and
	-- the trailing "|r\n\n" it leaves behind would otherwise accumulate a pair
	-- of blank lines on every pass. See LuaPadWithLinebreaks, which adds them.
	code = strgsub(code, "|r\n\n$", "|r")

	tableclear(workingTable)
	local tsize = 0
	local pos = 1
	local prevVertical, even, selectionStart = false, true, 1

	while true do
		local byte = strbyte(code, pos)
		if not byte then break end
		if byte == BYTE_VERTICAL then
			even = not even
			prevVertical = true
		else
			if prevVertical and not even then
				if byte == BYTE_c then
					if pos - 2 >= selectionStart then
						tsize = tsize + 1
						workingTable[tsize] = strsub(code, selectionStart, pos - 2)
					end
					pos = pos + 8
					selectionStart = pos + 1
				elseif byte == BYTE_r then
					if pos - 2 >= selectionStart then
						tsize = tsize + 1
						workingTable[tsize] = strsub(code, selectionStart, pos - 2)
					end
					selectionStart = pos + 1
				end
			end
			prevVertical = false
			even = true
		end
		pos = pos + 1
	end
	if pos >= selectionStart then
		tsize = tsize + 1
		workingTable[tsize] = strsub(code, selectionStart, pos - 1)
	end
	return table.concat(workingTable)
end

-- Strips colours while carrying a caret offset through the change: a marker
-- byte rides along at `pos` so the position can be found again afterwards
-- rather than recomputed. \2 is used here because \1 is the caret sentinel a
-- consumer may already have in flight.
--
-- The bases differ on purpose, and the chain depends on it: `pos` in is a
-- 0-based offset (what the caret read produces), the returned position is
-- 1-based (what LuaColorize's `caretPosition` expects), and LuaColorize hands
-- back a 0-based offset again for the caret write. Don't "fix" one end.
function LibWidgets.LuaStripColorsWithPos(code, pos)
	code = strsub(code, 1, pos) .. "\2" .. strsub(code, pos + 1)
	code = LibWidgets.LuaStripColors(code)
	local at = strfind(code, "\2", 1, true)
	if not at then return code, pos end
	return strsub(code, 1, at - 1) .. strsub(code, at + 1), at
end

-- Doubles literal pipes so the engine renders them instead of reading them as
-- an escape. Always the *first* step on the way into an edit box.
function LibWidgets.LuaEncode(code)
	if not code then return "" end
	return (strgsub(code, "|", "||"))
end

-- Undoes both the colouring and the pipe doubling, in that order -- the whole
-- read path out of an edit box.
function LibWidgets.LuaDecode(code)
	if not code then return "" end
	return (strgsub(LibWidgets.LuaStripColors(code), "||", "|"))
end

-- Returns the code with up to two trailing linebreaks added, plus whether it
-- changed. An unterminated string swallows the rest of the buffer when
-- coloured; the trailing blank lines give that runaway colour somewhere to end
-- that isn't the user's last line.
function LibWidgets.LuaPadWithLinebreaks(code)
	local len = strlen(code)
	local linebreakcount = 0
	while len > 0 and linebreakcount < 2 do
		local b = strbyte(code, len)
		if b == BYTE_LF then
			linebreakcount = linebreakcount + 1
		elseif not whitespaceChars[b] then
			break
		end
		len = len - 1
	end
	if linebreakcount == 0 then return code .. "\n\n", true end
	if linebreakcount == 1 then return code .. "\n", true end
	return code, false
end
