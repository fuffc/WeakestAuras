-- WeakestAuras -- the main config window: an aura list down the left (add/
-- delete), a tabbed editor on the right (Info/Display/Trigger). Built entirely
-- in Lua (no XML) since nothing here needs to survive a reload independent of
-- WeakestAurasDB -- follows the same shared config-panel pattern as sibling
-- config panel does the same.

if WeakestAuras.disabled then return end

local WA = WeakestAuras
local W = WA.Widgets

-- Friendly labels for WA.RegionTypeList()'s raw regionType strings -- shared by
-- the Info tab's Region type dropdown and the "+ New" type-picker menu
-- (buildPanel) so both read the same, rather than one showing raw
-- "dynamicgroup" text. Taken from each type's own spec.displayName so a new
-- region type names itself where it's registered instead of needing a second
-- entry here; safe to build at load, since this is the last file in the .toc
-- and every RegisterRegionType call has already run.
local REGION_TYPE_LABELS = {}
for name, spec in pairs(WA.regionTypes) do
	REGION_TYPE_LABELS[name] = spec.displayName or name
end

-- Lua 5.0 caps a function at 32 upvalues, and buildPanel below -- one large
-- function nesting a dozen+ button/row closures -- blew past that referencing
-- this many chunk-level locals directly (every constant/state var/forward-
-- declared function any nested closure touches counts against the *enclosing*
-- function too, not just the closure itself). Bundling all of it into one
-- table fixes it: a table costs ONE upvalue regardless of how many fields it
-- holds. Same fix as Quartermaster's listEditor and FearWardHelper's
-- buildConfig -- the table keeps the large builder within Lua 5.0's upvalue limit.
local S = {
	-- Two-row layout per WeakAuras2's AceGUIWidget-WeakAurasNewButton.lua: a
	-- full-height icon on the left, the aura name anchored to the row's top
	-- edge, and a trigger summary anchored to the row's bottom edge, both
	-- right of the icon.
	ROW_H = 34,
	VISIBLE = 10,
	-- Not the list's width -- the list is elastic (see buildPanel). This is the
	-- minimum MIN_W is sized to guarantee it.
	LIST_W = 200,
	-- The options pane's fixed width, and the one number the window's minimum is
	-- built from. Deliberately the width that pane had when it was the elastic
	-- side at the default window size, so pinning it changed no tab's layout.
	CONTENT_W = 442,
	INDENT_W = 14,
	STATUS_SIZE = 10,
	UNGROUP_W = 12,
	-- The New pane's rows: a 32px preview plus two lines of text.
	NEW_ROW_H = 40,
	-- A bucket header is one line of text, not a two-line aura row (WA2's is 20px
	-- against its own 42px rows). Rows are therefore *not* a uniform grid: every
	-- position below is accumulated from the heights actually painted.
	HEADER_H = 20,
	FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark",
	SEARCH_H = 26, -- search box height (20) + gap above the list (6)
	TOOLBAR_H = 26, -- toolbar button row (22 tall + 4 gap) above the search box
	BOTTOM_RESERVED = 12, -- bottom margin only; the list runs to the panel's edge
	-- MIN_W = left inset + LIST_W + gap + CONTENT_W + right inset, i.e. the
	-- narrowest window that still gives the list its minimum beside a
	-- full-width options pane.
	MIN_W = 12 + 200 + 12 + 442 + 14, MIN_H = 360,
	MAX_W = 1000, MAX_H = 800,
	TAB_DEFS = {
		{ key = "info", name = "Info" },
		{ key = "display", name = "Display" },
		{ key = "trigger", name = "Trigger" },
		{ key = "conditions", name = "Conditions" },
		{ key = "load", name = "Load" },
	},
	-- The context menu's Copy settings submenu, mirroring upstream's less the
	-- parts this addon has no subsystem for (actions, animations, author
	-- options, custom config). A group offers the single "Group" entry: it has
	-- no triggers, conditions or load of its own to copy.
	COPY_PARTS_LEAF = {
		{ text = "Everything", part = "all", paste = "Paste Settings" },
		{ text = "Display", part = "display", paste = "Paste Display Settings" },
		{ text = "Trigger", part = "trigger", paste = "Paste Trigger Settings" },
		{ text = "Conditions", part = "condition", paste = "Paste Condition Settings" },
		{ text = "Load", part = "load", paste = "Paste Load Settings" },
	},
	COPY_PARTS_GROUP = {
		{ text = "Group", part = "display", paste = "Paste Group Settings" },
	},
	-- Keys a "Display" copy never carries: the aura's identity, its place in the
	-- tree, and the parts that have their own entry. subRegions is deliberately
	-- absent -- the text/border/glow *are* the display here, and a copy that
	-- dropped them would surprise.
	COPY_IGNORE = {
		triggers = true, conditions = true, load = true,
		id = true, parent = true, controlledChildren = true,
		uid = true, internalVersion = true,
	},
	searchTerms = {},
	-- Per-group expand/collapse state, keyed by aura id. Absence means
	-- expanded -- only an explicit `false` collapses a group -- so newly
	-- created groups start open without needing to be added here.
	expanded = {},
	-- Loaded/Not Loaded bucket collapse state, keyed by "loaded"/"unloaded" --
	-- a separate table from S.expanded (which is keyed by aura id) since an
	-- aura literally named "loaded" would otherwise collide with the bucket's
	-- own entry. Same absence-means-expanded convention.
	bucketExpanded = {},
	-- Ordered array of selected aura ids (click/insertion order), replacing
	-- the old single S.selectedId scalar. Empty
	-- means nothing picked; a single entry is the ordinary case every
	-- existing single-aura code path reads via S.primaryId(); more than one means
	-- a multi-selection, which supports the placeholder pane and bulk actions,
	-- not per-field editing.
	selection = {},
}
S.DEFAULT_W, S.DEFAULT_H = 680, 440 + S.SEARCH_H + S.TOOLBAR_H
S.visibleRows = S.VISIBLE

-- Read-only handle for Debug.lua's /wa rows, which measures the list's laid-out
-- geometry -- the one thing the headless harness has no way to see.
WA.OptionsState = S

function S.trim(s)
	local t = string.gsub(s or "", "^%s*(.-)%s*$", "%1")
	return t
end

-- Same OR-search syntax as WeakAuras2's own filter box (GenericTrigger.lua's
-- splitAtOr): "|" or " or " between fragments broadens the match instead of
-- narrowing it, so e.g. "rend or thrash" matches either.
function S.splitFilterTerms(text)
	local terms = {}
	text = string.lower(S.trim(text or ""))
	if text == "" then return terms end
	text = string.gsub(text, " or ", "|")
	local start = 1
	while true do
		local s, e = string.find(text, "|", start, true)
		local piece = string.sub(text, start, s and (s - 1) or -1)
		if piece ~= "" then table.insert(terms, piece) end
		if not s then break end
		start = e + 1
	end
	return terms
end

function S.matchesFilter(id, terms)
	if table.getn(terms) == 0 then return true end
	local lower = string.lower(id)
	for i = 1, table.getn(terms) do
		if string.find(lower, terms[i], 1, true) then return true end
	end
	return false
end

function S.isSelected(id)
	for i = 1, table.getn(S.selection) do
		if S.selection[i] == id then return true end
	end
	return false
end

-- The single selected id, or nil when nothing or more than one is selected --
-- every pre-multi-select code path (Info/Display/Trigger tabs, Rename, the
-- Delete button) is single-aura-only and reads this instead of S.selection
-- directly, so it stays inert (rather than acting on an arbitrary member)
-- once a second aura joins the selection.
function S.primaryId()
	if table.getn(S.selection) == 1 then return S.selection[1] end
	return nil
end

-- Common refresh after any selection change -- was S.selectAura's body
-- before the single-id model became an array; every mutator below ends by
-- calling this instead of repeating the same three refreshes. Also closes
-- the context menu if it's open, so it can't linger over a
-- row after a plain click elsewhere changes the selection out from under it
-- -- S.menu doesn't exist until buildPanel runs, hence the guard.
function S.applySelectionChange()
	if S.menu then S.menu.Close() end
	S.searchBox:ClearFocus()
	-- Update the forced-visibility selection BEFORE refreshList: the row eyes
	-- render WA.ForcedState, which reads selectionLeaves, so painting the list
	-- first would show the previous selection's amber until the next refresh.
	-- Paints a dummy region for the aura being edited even when its real trigger
	-- doesn't currently match -- primaryId() is nil for no/multi (clears preview).
	WA.SetPreview(S.primaryId())
	-- Attach the in-world mover to the (now force-shown) single selection;
	-- nil/multi detaches it.
	WA.Mover.Attach(S.primaryId())
	S.refreshList()
	S.updateTabAvailability()
	-- Picking an aura leaves the New pane, since the pane is about the thing
	-- that doesn't exist yet -- except for an empty group, where offering to
	-- fill it is the whole point.
	local sole = S.primaryId() and WeakestAurasDB.displays[S.primaryId()]
	if sole and WA.IsGroup(sole) and table.getn(sole.controlledChildren or {}) == 0 then
		S.activeTab = "new"
	elseif S.activeTab == "new" and table.getn(S.selection) > 0 then
		S.activeTab = "info"
		for i = 1, table.getn(S.tabButtons or {}) do
			S.tabButtons[i].setSelected(S.tabButtons[i].key == "info")
		end
	end
	S.refreshTabContent()
end

function S.setSelection(id)
	S.selection = id and { id } or {}
	S.applySelectionChange()
end

function S.clearSelection()
	S.selection = {}
	S.applySelectionChange()
end

-- The ordered sibling list a given parentId's children live in -- top-level
-- WA.GetOrder() when nil, a group's own controlledChildren otherwise. Lets
-- the bulk drag-move code below (buildPanel's endDrag) translate a drop
-- position into WA.ReorderAura's numeric `before` index without duplicating
-- Data.lua's own private currentList/indexOf.
function S.siblingList(parentId)
	if parentId == nil then return WA.GetOrder() end
	local parent = WeakestAurasDB.displays[parentId]
	return (parent and parent.controlledChildren) or {}
end

function S.indexOfId(list, id)
	for i = 1, table.getn(list) do
		if list[i] == id then return i end
	end
	return nil
end

-- Recursively collects every non-group leaf under id (upstream's TraverseLeafs
-- pattern, WeakAuras.lua:6660-6748, applied to a new context: expanding a
-- ctrl-clicked group into the selection instead of a single-group export/
-- duplicate/move). A plain leaf just returns itself. This is what lets
-- S.selection keep its "always leaf ids, never a group" invariant even once
-- group rows become valid ctrl-click targets.
function S.leafDescendants(id, out)
	out = out or {}
	local data = WeakestAurasDB.displays[id]
	if not data then return out end
	if WA.IsGroup(data) then
		local children = data.controlledChildren or {}
		for i = 1, table.getn(children) do
			S.leafDescendants(children[i], out)
		end
	else
		table.insert(out, id)
	end
	return out
end

-- True only when id is a group with at least one leaf descendant and every
-- one of them is currently selected -- drives the group row's own highlight
-- in S.refreshList, since a group's id never itself enters S.selection (see
-- S.leafDescendants) and a collapsed group would otherwise show no feedback
-- at all after a ctrl-click selects its hidden children.
function S.allDescendantsSelected(id)
	local leaves = S.leafDescendants(id)
	if table.getn(leaves) == 0 then return false end
	for i = 1, table.getn(leaves) do
		if not S.isSelected(leaves[i]) then return false end
	end
	return true
end

-- Ctrl-click a leaf: add if not already selected, remove (from anywhere in
-- the list, not just the end) if it is -- unchanged from before groups could
-- be clicked here. Ctrl-click a group: same toggle, but applied to the
-- group's *entire* recursive leaf-descendant set at once (S.leafDescendants)
-- rather than the group's own id, which never enters S.selection. "Already
-- selected" for a group means every one of its descendants already is; any
-- other state (partial or none) adds whichever aren't selected yet, the
-- usual tri-state-parent-checkbox convention. Never called while the current
-- sole selection is a group -- see the row OnClick handler -- so id here can
-- be a group, but S.selection itself never ends up mixing a literal group id
-- into a multi-member selection.
function S.toggleSelection(id)
	local data = WeakestAurasDB.displays[id]
	local ids = (data and WA.IsGroup(data)) and S.leafDescendants(id) or { id }

	local allSelected = true
	for i = 1, table.getn(ids) do
		if not S.isSelected(ids[i]) then allSelected = false end
	end

	if allSelected then
		local remove = {}
		for i = 1, table.getn(ids) do remove[ids[i]] = true end
		local kept = {}
		for i = 1, table.getn(S.selection) do
			if not remove[S.selection[i]] then table.insert(kept, S.selection[i]) end
		end
		S.selection = kept
	else
		for i = 1, table.getn(ids) do
			if not S.isSelected(ids[i]) then table.insert(S.selection, ids[i]) end
		end
	end
	S.applySelectionChange()
end

-- Shift-click: extend the selection to every same-parent leaf between the
-- current anchor (the most-recently-added member -- derived on the fly
-- rather than tracked separately, same as upstream WeakAuras2) and the
-- clicked row, walking S.buildRows()'s current *rendered* output. That means
-- a search filter narrows what a range can span for free (filtered rows
-- never appear in buildRows), and a range can never cross a group boundary
-- (anchor and target must share .parent) -- both match upstream's own
-- shift-range-select rules. Adds to the existing selection rather than
-- replacing it, so ctrl-click picks plus a trailing shift-click compose.
function S.selectRange(id)
	local anchor = S.selection[table.getn(S.selection)]
	if not anchor or anchor == id then
		S.setSelection(id)
		return
	end
	local anchorData = WeakestAurasDB.displays[anchor]
	local targetData = WeakestAurasDB.displays[id]
	if not anchorData or not targetData or anchorData.parent ~= targetData.parent then return end

	local rows = S.buildRows()
	local anchorIdx, targetIdx
	for i = 1, table.getn(rows) do
		if rows[i].id == anchor then anchorIdx = i end
		if rows[i].id == id then targetIdx = i end
	end
	if not anchorIdx or not targetIdx then return end
	if anchorIdx > targetIdx then anchorIdx, targetIdx = targetIdx, anchorIdx end

	for i = anchorIdx, targetIdx do
		local entry = rows[i]
		local rowData = WeakestAurasDB.displays[entry.id]
		if rowData and rowData.parent == anchorData.parent and not WA.IsGroup(rowData)
			and not S.isSelected(entry.id) then
			table.insert(S.selection, entry.id)
		end
	end
	S.applySelectionChange()
end

-- Right-click menu for an active multi-selection. Both group entries are
-- refused when every member already shares one dynamic-group parent, since a
-- dynamic group lays out its own children and cannot own a nested group -- the
-- new group would silently land at top level instead. Upstream's other disabled
-- rule (a selected member being itself a group) is unreachable here: a group id
-- never enters a multi-member S.selection, see S.leafDescendants.
function S.showBulkMenu(row)
	local parent = S.commonParent()
	local nestBlocked = (parent and not WA.CanPlaceAura("group", parent)) and true or nil
	S.menu.Open({
		{ text = "Add to new Group", disabled = nestBlocked,
			onClick = function() S.groupSelection("group") end },
		{ text = "Add to new Dynamic Group", disabled = nestBlocked,
			onClick = function() S.groupSelection("dynamicgroup") end },
		{ text = "Duplicate All", onClick = S.duplicateSelection },
		{ separator = true },
		{ text = "Delete Selected", confirm = true, onClick = S.deleteSelection },
	}, row)
end

-- Opens the inline rename box on whichever painted row currently holds `id`.
-- Rows are pooled and rebound, so the row a menu was opened over is not
-- guaranteed to still hold the aura the menu was built for.
function S.renameById(id)
	for i = 1, table.getn(S.rows or {}) do
		local row = S.rows[i]
		if row.id == id and row:IsShown() then
			S.beginRename(row)
			return
		end
	end
end

-- Copies one part of `source` onto `dest` (upstream's copyAuraPart). Deep at
-- both ends -- copy and paste alike -- or the two auras end up sharing one
-- physical triggers table and an edit to either shows up in both.
function S.copyAuraPart(source, dest, part)
	local all = (part == "all")
	if part == "display" or all then
		for k, v in pairs(source) do
			if not S.COPY_IGNORE[k] then dest[k] = WA.DeepCopy(v) end
		end
	end
	if WA.IsGroup(source) then return end
	if part == "trigger" or all then dest.triggers = WA.DeepCopy(source.triggers) end
	if part == "condition" or all then dest.conditions = WA.DeepCopy(source.conditions) end
	if part == "load" or all then dest.load = WA.DeepCopy(source.load) end
end

-- S.clipboard holds the last copied part: { part, paste text, a snapshot of the
-- source }. Session-scoped and never written to WeakestAurasDB -- upstream's is
-- a file-local table too, and a settings copy is a gesture within one sitting.
function S.copySettings(data, part, pasteText)
	S.clipboard = { part = part, text = pasteText, source = WA.DeepCopy(data) }
end

-- Pasting a leaf's settings onto a group applies them to every leaf under it
-- (upstream does the same); anything else pastes onto the one aura.
-- MergeDefaults first, since the pasted part may predate a field the target's
-- type now expects.
function S.pasteSettings(id)
	local clip = S.clipboard
	local data = WeakestAurasDB.displays[id]
	if not clip or not data then return end

	local targets = { id }
	if not WA.IsGroup(clip.source) and WA.IsGroup(data) then
		targets = S.leafDescendants(id)
	end
	for i = 1, table.getn(targets) do
		local target = WeakestAurasDB.displays[targets[i]]
		if target then
			S.copyAuraPart(clip.source, target, clip.part)
			WA.MergeDefaults(target)
			WA.Add(target)
		end
	end
	S.refreshTabContent()
end

-- The per-aura right-click menu, built from that aura's own data: a leaf, a
-- child and a group each get a different list. `anchor` only positions the menu
-- when the client gives no cursor position, so a repaint rebinding that row
-- between the click and a pick costs nothing.
function S.showAuraMenu(id, anchor)
	local data = WeakestAurasDB.displays[id]
	if not data then return end
	local isGroup = WA.IsGroup(data)

	-- Same leaf/group categories the Info tab's Region type dropdown offers,
	-- less the type the aura already is.
	local convert = {}
	local types = WA.RegionTypeList(isGroup)
	for i = 1, table.getn(types) do
		local regionType = types[i]
		if regionType ~= data.regionType then
			table.insert(convert, {
				text = REGION_TYPE_LABELS[regionType] or regionType,
				onClick = function() S.convertRegionType(data, regionType) end,
			})
		end
	end

	local items = { { text = "Rename", onClick = function() S.renameById(id) end } }

	local parts = isGroup and S.COPY_PARTS_GROUP or S.COPY_PARTS_LEAF
	local copyItems = {}
	for i = 1, table.getn(parts) do
		local entry = parts[i]
		table.insert(copyItems, {
			text = entry.text,
			onClick = function() S.copySettings(data, entry.part, entry.paste) end,
		})
	end
	table.insert(items, { text = "Copy settings", submenu = copyItems })

	-- Paste appears only once something has been copied, and never from a group
	-- onto a leaf -- a group's settings have nothing a leaf can take.
	local clip = S.clipboard
	if clip and not (WA.IsGroup(clip.source) and not isGroup) then
		table.insert(items, { text = clip.text, onClick = function() S.pasteSettings(id) end })
	end

	if table.getn(convert) > 0 then
		table.insert(items, { text = "Convert to", submenu = convert })
	end
	table.insert(items, {
		text = "Duplicate",
		onClick = function()
			local newId = WA.DuplicateAura(id)
			if newId then S.setSelection(newId) end
		end,
	})
	table.insert(items, { text = "Export...", onClick = function() S.openExport(id) end })
	-- Shift-clicking a row with the editbox already open is undiscoverable, and
	-- from here the editbox can be opened for the user instead.
	table.insert(items, { text = "Link to Chat", onClick = function() WA.Comm.LinkAura(id) end })
	if data.parent then
		table.insert(items, {
			text = "Ungroup",
			onClick = function()
				WA.RemoveChildFromGroup(id)
				S.refreshList()
				S.refreshTabContent()
			end,
		})
	end
	table.insert(items, { separator = true })
	-- Delete promotes a group's children; the cascading variant is the entry
	-- below it, offered only where the distinction exists.
	table.insert(items, {
		text = "Delete", confirm = true,
		onClick = function()
			WA.DeleteAura(id)
			S.clearSelection()
		end,
	})
	if isGroup then
		table.insert(items, {
			text = "Delete children and group", confirm = true,
			onClick = function()
				WA.DeleteAuraTree(id)
				S.clearSelection()
			end,
		})
	end

	S.menu.Open(items, anchor)
end

-- Inline rename: which row currently has its box open, and the aura it was
-- opened *for*. Both are needed because rows are pooled by slot and rebound on
-- every repaint -- the captured id is re-checked at commit so an open box can
-- never rename whatever aura happens to occupy its slot by then.
S.renameRow, S.renameId = nil, nil

function S.beginRename(row)
	if not row or not row.id then return end
	S.closeRename()
	S.renameRow, S.renameId = row, row.id
	row.title:Hide()
	row.rename:SetText(row.id)
	row.rename:Show()
	row.rename:SetFocus()
	row.rename:HighlightText()
end

function S.closeRename()
	local row = S.renameRow
	S.renameRow, S.renameId = nil, nil
	if not row then return end
	row.rename:Hide()
	row.rename:ClearFocus()
	row.title:Show()
end

-- Enter. An empty name, an unchanged one, or one already taken reverts in
-- silence rather than erroring -- upstream does the same, and there is nowhere
-- on a list row to put an error message.
function S.commitRename()
	local row, id = S.renameRow, S.renameId
	if not row then return end
	local text = S.trim(row.rename:GetText() or "")
	S.closeRename()
	if not id or row.id ~= id then return end
	if text == "" or text == id or WeakestAurasDB.displays[text] then return end
	if WA.RenameAura(id, text) then S.setSelection(text) end
end

-- The toolbar's New: creates against whatever is picked, so a picked group takes
-- the new aura as a child and a picked leaf gets it as its next sibling
-- (WA.PlaceAura decides which). Expands the owning group before selecting, since
-- a child dropped into a collapsed group is invisible and reads as New having
-- done nothing. Returns nil for a placement the target refuses.
function S.createAura(regionType)
	local data = WA.NewAura(regionType, S.primaryId())
	if not data then return nil end
	if data.parent then S.expanded[data.parent] = true end
	S.setSelection(data.id)
	return data
end

-- The parent every selected aura shares, or nil when they disagree (or are all
-- top-level) -- the two cases behave identically everywhere this is read.
function S.commonParent()
	local first = WeakestAurasDB.displays[S.selection[1]]
	local parent = first and first.parent
	for i = 2, table.getn(S.selection) do
		local data = WeakestAurasDB.displays[S.selection[i]]
		if not data or data.parent ~= parent then return nil end
	end
	return parent
end

-- "Add to new Group"/"Add to new Dynamic Group" (the bulk menu): reuses the
-- same Groups primitives a manual drag-into-group would (WA.NewAura/
-- WA.AddChildToGroup) applied to every selected leaf instead of one. Nests the
-- new group inside the selection's shared parent if there is one (append --
-- controlledChildren order isn't otherwise meaningful yet beyond what the
-- user last dragged) and that parent will take a group; otherwise the new group
-- lands at top level, same as WA.NewAura's own default. Selects the new group
-- afterward so the user is looking at what they just made, matching upstream's
-- own habit.
function S.groupSelection(regionType)
	regionType = regionType or "group"
	local n = table.getn(S.selection)
	local commonParent = S.commonParent()

	local group = WA.NewAura(regionType)
	if not group then return end
	if commonParent and WA.CanPlaceAura(regionType, commonParent) then
		WA.AddChildToGroup(commonParent, group.id)
	end
	for i = 1, n do
		WA.AddChildToGroup(group.id, S.selection[i])
	end
	S.setSelection(group.id)
end

-- "Duplicate All" (the bulk menu). Selects the batch of copies afterward, so
-- the obvious next gesture -- dragging them somewhere -- acts on the new ones.
function S.duplicateSelection()
	local made = {}
	for i = 1, table.getn(S.selection) do
		local newId = WA.DuplicateAura(S.selection[i])
		if newId then table.insert(made, newId) end
	end
	S.selection = made
	S.applySelectionChange()
end

-- "Delete Selected" (the bulk menu): always leaf-only since groups
-- can never be selection members, so unlike the single Delete button
-- there's no cascade-vs-ungroup ambiguity to resolve here -- every call is
-- a plain leaf delete.
function S.deleteSelection()
	for i = 1, table.getn(S.selection) do
		WA.DeleteAura(S.selection[i])
	end
	S.clearSelection()
end

-- Re-types an aura in place, shared by the Info tab's Region type dropdown and
-- the context menu's "Convert to". MergeDefaults fills whatever the new type
-- needs; the tab has to be rebuilt because a different type offers different
-- fields.
function S.convertRegionType(data, regionType)
	data.regionType = regionType
	WA.MergeDefaults(data)
	WA.Add(data)
	S.updateTabAvailability()
	S.refreshTabContent()
end

function S.getInfoOptions(data)
	local fields = {
		{ type = "header", name = data.id },
		{
			type = "input", name = "Rename",
			get = function() return data.id end,
			set = function(v)
				v = S.trim(v)
				if WA.RenameAura(data.id, v) then S.setSelection(v) end
			end,
		},
		{
			type = "select", name = "Region type",
			-- Filtered to data's own leaf/group category -- see WA.RegionTypeList's
			-- comment for why converting across that boundary isn't offered here.
			values = WA.RegionTypeList(WA.IsGroup(data)),
			labels = REGION_TYPE_LABELS,
			get = function() return data.regionType end,
			set = function(v) S.convertRegionType(data, v) end,
		},
		-- data.uid is deliberately not shown: it's an internal identity for
		-- import/export and cross-references, not something the user acts on
		-- (upstream never surfaces it in the Information tab either).
		{ type = "button", name = "Export", onClick = function() S.openExport(data.id) end },
	}
	-- The only way to promote a grouped aura back to top level: the tree's
	-- drag-and-drop only ever reorders within the dragged item's current
	-- parent (see buildPanel's trackDrag) since a drop boundary between two
	-- different parents' rows is genuinely ambiguous once groups interleave
	-- their children into the flat list -- dropping *onto* a group row is
	-- the unambiguous way in, this button is the unambiguous way out.
	if data.parent then
		table.insert(fields, {
			type = "button", name = "Ungroup (remove from \"" .. data.parent .. "\")",
			onClick = function()
				WA.RemoveChildFromGroup(data.id)
				S.refreshList()
				S.refreshTabContent()
			end,
		})
	end
	-- Two-click confirm, the same morph-then-revert affordance the bulk menu
	-- uses. poolButton binds this field's onClick as the button's own OnClick
	-- script, so `this` is the button and the confirming flag can live on it;
	-- a tab repaint resets the label, which is the wanted behaviour -- a
	-- half-confirmed delete should not survive switching away and back.
	table.insert(fields, {
		type = "button", name = "Delete",
		onClick = function()
			if this.confirming then
				this.confirming = nil
				WA.DeleteAura(data.id)
				S.clearSelection()
			else
				this.confirming = true
				this.label:SetText("Confirm?")
				S.scheduleUnconfirm(this)
			end
		end,
	})
	return fields
end

-- ---------------------------------------------------------------------------
-- Collapse state for the Display/Trigger tabs' collapsible sections. Session-
-- only (upstream keeps it out of saved data too) and keyed by aura id as well
-- as section key, so one aura's folded triggers don't carry over onto the next
-- aura's. Collapsing itself is done by the field-list generators below --
-- a folded section simply omits its body fields -- so BuildOptions only ever
-- paints the arrow/delete affordance.
-- ---------------------------------------------------------------------------

S.collapsed = {}

function S.isCollapsed(data, key, default)
	local v = S.collapsed[data.id .. "::" .. key]
	if v == nil then return default end
	return v
end

function S.setCollapsed(data, key, v)
	S.collapsed[data.id .. "::" .. key] = v
end

-- Drops every collapse entry in a namespace ("trigger:"/"sub:") for this aura.
-- Removing an entry renumbers everything after it, so the saved fold states
-- would otherwise land on the wrong sections; resetting the namespace is the
-- honest answer for state that only lives for the session anyway.
function S.clearCollapsed(data, prefix)
	local full = data.id .. "::" .. prefix
	local n = string.len(full)
	for k in pairs(S.collapsed) do
		if string.sub(k, 1, n) == full then S.collapsed[k] = nil end
	end
end

-- Makes every plain header in `fields` collapsible, returning a new array with
-- folded sections' bodies dropped. For generated sections whose generator has
-- no fold state of its own (Regions.lua's Icon/Size/Position, which are the
-- same shape for every region type) -- a header that already carries
-- `collapsed`/`onDelete` manages itself and is passed through untouched.
-- A section runs from its header to the next one, so nesting isn't expressible
-- here; the generators that need it (triggers, display effects) build their own
-- headers instead. `prefix` namespaces the keys so two tabs' identically-named
-- sections don't share one fold state.
function S.collapsibleSections(fields, data, prefix)
	local out, folded = {}, false
	for i = 1, table.getn(fields) do
		local f = fields[i]
		if f.type == "header" then
			folded = false
			if f.collapsed ~= nil or f.onDelete then
				table.insert(out, f)
			else
				local key = prefix .. (f.name or tostring(i))
				local collapsed = S.isCollapsed(data, key, false)
				folded = collapsed
				-- Copied, not mutated: the generator may hand back a table it
				-- reuses, and fold state is ours rather than its.
				local hdr = {}
				for k, v in pairs(f) do hdr[k] = v end
				hdr.collapsed = collapsed
				hdr.onToggle = function()
					S.setCollapsed(data, key, not collapsed)
					S.refreshTabContent()
				end
				table.insert(out, hdr)
			end
		elseif not folded then
			table.insert(out, f)
		end
	end
	return out
end

-- Deep-copies a subregion type's `default` so a newly-added instance never
-- shares a table field (e.g. a colour array) with the registry default or
-- another instance.
local function copySubDefault(v)
	if type(v) ~= "table" then return v end
	local out = {}
	for k, vv in pairs(v) do out[k] = copySubDefault(vv) end
	return out
end

-- Appends the sub-region editor ("Display Effects") onto the Display tab's field
-- list (matching upstream, where subtext/border/glow live under Display, not a
-- separate tab): one block per instance in data.subRegions rendered from its own
-- spec.options field array, plus per-type add and per-instance remove. Walks
-- WA.subRegionTypes so a newly-registered subregion type shows up here for free;
-- the "+ Add" list is filtered to types that support this region type. Each
-- block's closures capture their own `sub`/`idx` locals (fresh per loop
-- iteration in Lua); per-field edits route through WA.Add (the live region
-- rebuilds its subregions via modifyFinish), structural add/remove additionally
-- re-render the tab.
function S.appendDisplayEffectsOptions(fields, data)
	table.insert(fields, { type = "header", name = "Display Effects" })
	local subs = data.subRegions or {}
	for i = 1, table.getn(subs) do
		local sub = subs[i]
		local idx = i
		local spec = WA.subRegionTypes[sub.type]
		if spec and spec.options then
			local label = (spec.displayName or sub.type) .. " " .. idx
			local key = "sub:" .. idx
			-- Unfolded by default. Upstream folds subregions instead
			-- (DisplayOptions.lua's __collapsed = true), but it can afford to:
			-- its Display tab is long enough that an effect's fields are clearly
			-- more content below, whereas here they're most of the tab, and a
			-- column of collapsed headers reads as an empty page.
			local collapsed = S.isCollapsed(data, key, false)
			table.insert(fields, {
				type = "header", name = label, collapsed = collapsed,
				onToggle = function()
					S.setCollapsed(data, key, not collapsed)
					S.refreshTabContent()
				end,
				onDelete = function()
					table.remove(data.subRegions, idx)
					S.clearCollapsed(data, "sub:")
					WA.Add(data)
					S.refreshTabContent()
				end,
			})
			if not collapsed then
				local typeFields = spec.options(data, sub, idx)
				for j = 1, table.getn(typeFields) do
					table.insert(fields, typeFields[j])
				end
			end
		end
	end

	-- One drop button covering every subregion type that supports this region
	-- type, in stable display order -- the alternative is a stack of near-
	-- identical "+ Add X" buttons that grows with each new subregion type.
	local addable, addLabels = {}, {}
	for name, spec in pairs(WA.subRegionTypes) do
		if spec.options and (not spec.supports or spec.supports(data.regionType)) then
			table.insert(addable, name)
			addLabels[name] = spec.displayName or name
		end
	end
	table.sort(addable)
	if table.getn(addable) > 0 then
		table.insert(fields, {
			type = "menu", name = "+ Add Display Effect", values = addable, labels = addLabels,
			onSelect = function(name)
				local spec = WA.subRegionTypes[name]
				if not spec then return end
				data.subRegions = data.subRegions or {}
				local default = spec.defaultFor and spec.defaultFor(data.regionType) or spec.default
				table.insert(data.subRegions, copySubDefault(default))
				-- Open the one just added -- it's what the user is about to edit.
				S.setCollapsed(data, "sub:" .. table.getn(data.subRegions), false)
				WA.Add(data)
				S.refreshTabContent()
			end,
		})
	end

	-- The %c function is one per *aura*, shared by the region's own text and
	-- every subtext of it, so its editor is one block here rather than a copy
	-- inside each text's section -- upstream shows one subtext at a time and can
	-- afford to repeat it; this page shows them all at once. Empty until
	-- something in the aura's text references %c.
	local customText = WA.regionPrototype.CustomTextOptionFields(data)
	for i = 1, table.getn(customText) do table.insert(fields, customText[i]) end
end

-- ---------------------------------------------------------------------------
-- Conditions tab: edits data.conditions -- each is a check
-- (trigger/variable/op/value) plus a list of property changes. The vocabulary
-- (checkable variables, changeable properties) is pulled from the engine
-- (WA.GetConditionTemplates / WA.GetProperties / WA.globalConditions) so a new
-- trigger or region property shows up here for free. Structural edits (add/
-- remove a condition or change, or switching a variable/property whose type
-- changes the value widget) re-render the tab via S.refreshTabContent.
-- ---------------------------------------------------------------------------

function S.sortedKeys(map)
	local out = {}
	for k in pairs(map) do table.insert(out, k) end
	table.sort(out)
	return out
end

-- (type, template) for a check's variable: a global condition when trigger is
-- -1, otherwise the trigger's condition template. Defaults keep the editor
-- functional even if a saved variable no longer exists.
function S.conditionVarType(check, templates)
	if check.trigger == -1 then
		local g = WA.globalConditions[check.variable]
		return g and g.type or "bool", g
	end
	local t = templates and templates[check.trigger]
	local v = t and t[check.variable]
	return v and v.type or "number", v
end

-- Sorted variable keys + display labels for a trigger (or the global set).
function S.conditionVariableList(trigger, templates)
	local map = (trigger == -1) and WA.globalConditions or ((templates and templates[trigger]) or {})
	local vals = S.sortedKeys(map)
	local labels = {}
	for i = 1, table.getn(vals) do labels[vals[i]] = (map[vals[i]] and map[vals[i]].display) or vals[i] end
	return vals, labels
end

-- Sensible starting op+value when a check's variable (hence its type) changes.
function S.defaultOpValue(vtype, template)
	if vtype == "timer" or vtype == "elapsedTimer" then return "<", 5
	elseif vtype == "number" then return ">=", 1
	elseif vtype == "bool" then return "==", true
	elseif vtype == "select" then return "==", (template and template.values and template.values[1]) or "" end
	return "==", ""
end

function S.defaultPropertyValue(pentry)
	if not pentry then return nil end
	if pentry.type == "bool" then return true
	elseif pentry.type == "color" then return { 1, 0, 0, 1 }
	elseif pentry.type == "number" then return pentry.min or 0
	elseif pentry.type == "list" then return pentry.default
	elseif pentry.type == "icon" then return pentry.default or "" end
	return nil
end

-- Appends the op/value editor for a check, picking the widget by variable type.
local function appendCheckValue(fields, data, check, vtype, template)
	if vtype == "number" or vtype == "timer" or vtype == "elapsedTimer" then
		local label = vtype == "timer" and "Remaining (s)"
			or (vtype == "elapsedTimer" and "Elapsed (s)" or "Value")
		table.insert(fields, {
			type = "opnumber", name = label,
			getOp = function() return check.op or ">=" end,
			setOp = function(v) check.op = v; WA.Add(data) end,
			getVal = function() return check.value end,
			setVal = function(v) check.value = v; WA.Add(data) end,
		})
	elseif vtype == "bool" then
		table.insert(fields, {
			type = "toggle", name = "Is true",
			get = function() return check.value == true or check.value == "true" end,
			set = function(v) check.op = "=="; check.value = v and true or false; WA.Add(data) end,
		})
	elseif vtype == "select" then
		table.insert(fields, {
			type = "select", name = "Value", values = (template and template.values) or {},
			get = function() return check.value end,
			set = function(v) check.op = "=="; check.value = v; WA.Add(data) end,
		})
	else -- string
		table.insert(fields, {
			type = "select", name = "Op", half = true, values = { "==", "~=" },
			get = function() return check.op or "==" end,
			set = function(v) check.op = v; WA.Add(data) end,
		})
		table.insert(fields, {
			type = "input", name = "Value", half = true,
			get = function() return check.value end,
			set = function(v) check.value = v; WA.Add(data) end,
		})
	end
end

-- Appends the value widget for one property change, picked by property type.
local function appendChangeValue(fields, data, change, pentry)
	local ptype = pentry and pentry.type
	if ptype == "bool" then
		table.insert(fields, {
			type = "toggle", name = "Value", half = true,
			get = function() return change.value and true or false end,
			set = function(v) change.value = v and true or false; WA.Add(data) end,
		})
	elseif ptype == "color" then
		table.insert(fields, {
			type = "color", name = "Value", half = true,
			get = function() return change.value end,
			set = function(v) change.value = v; WA.Add(data) end,
		})
	elseif ptype == "number" and pentry.min and pentry.max then
		table.insert(fields, {
			type = "range", name = "Value", half = true, min = pentry.min, max = pentry.max, step = pentry.step or 1,
			get = function() return change.value end,
			set = function(v) change.value = v; WA.Add(data) end,
		})
	elseif ptype == "list" then
		local vals, labels = {}, {}
		for k, lbl in pairs(pentry.values or {}) do table.insert(vals, k); labels[k] = lbl end
		table.sort(vals)
		table.insert(fields, {
			type = "select", name = "Value", half = true, values = vals, labels = labels,
			get = function() return change.value end,
			set = function(v) change.value = v; WA.Add(data) end,
		})
	else
		table.insert(fields, {
			type = "input", name = "Value", half = true,
			get = function() return change.value end,
			set = function(v) change.value = (ptype == "number") and tonumber(v) or v; WA.Add(data) end,
		})
	end
end

function S.appendConditionOptions(fields, data)
	table.insert(fields, { type = "header", name = "Conditions" })
	data.conditions = data.conditions or {}
	local templates = WA.GetConditionTemplates(data)
	local props = WA.GetProperties(data)
	local numTriggers = table.getn(data.triggers or {})

	-- Trigger dropdown: each trigger number, plus Global (-1).
	local trigVals, trigLabels = {}, {}
	for n = 1, numTriggers do
		table.insert(trigVals, tostring(n))
		trigLabels[tostring(n)] = "Trigger " .. n
	end
	table.insert(trigVals, "-1")
	trigLabels["-1"] = "Global"

	-- Property dropdown (shared by every change row).
	local propVals = S.sortedKeys(props)
	local propLabels = {}
	for i = 1, table.getn(propVals) do propLabels[propVals[i]] = props[propVals[i]].display end

	for ci = 1, table.getn(data.conditions) do
		local cond = data.conditions[ci]
		local idx = ci
		cond.check = cond.check or { trigger = numTriggers >= 1 and 1 or -1 }
		cond.changes = cond.changes or {}
		local check = cond.check

		-- Collapsible + deletable, same as a trigger/display-effect section. The
		-- delete lives in the header rather than as a trailing button precisely
		-- so a folded condition can still be removed.
		local key = "cond:" .. idx
		local collapsed = S.isCollapsed(data, key, table.getn(data.conditions) > 1)
		table.insert(fields, {
			type = "header", name = "Condition " .. idx, collapsed = collapsed,
			onToggle = function()
				S.setCollapsed(data, key, not collapsed)
				S.refreshTabContent()
			end,
			onDelete = function()
				table.remove(data.conditions, idx)
				S.clearCollapsed(data, "cond:")
				WA.Add(data); S.refreshTabContent()
			end,
		})
		if not collapsed then
			table.insert(fields, {
				type = "select", name = "Trigger", half = true, values = trigVals, labels = trigLabels,
				get = function() return tostring(check.trigger or 1) end,
				set = function(v)
					check.trigger = tonumber(v)
					local vars = S.conditionVariableList(check.trigger, templates)
					check.variable = vars[1]
					local vt, tmpl = S.conditionVarType(check, templates)
					check.op, check.value = S.defaultOpValue(vt, tmpl)
					WA.Add(data); S.refreshTabContent()
				end,
			})

			local varVals, varLabels = S.conditionVariableList(check.trigger, templates)
			table.insert(fields, {
				type = "select", name = "Variable", half = true, values = varVals, labels = varLabels,
				get = function() return check.variable end,
				set = function(v)
					check.variable = v
					local vt, tmpl = S.conditionVarType(check, templates)
					check.op, check.value = S.defaultOpValue(vt, tmpl)
					WA.Add(data); S.refreshTabContent()
				end,
			})

			local vtype, template = S.conditionVarType(check, templates)
			appendCheckValue(fields, data, check, vtype, template)

			for chi = 1, table.getn(cond.changes) do
				local change = cond.changes[chi]
				local cidx = chi
				table.insert(fields, {
					type = "select", name = "Change", half = true, values = propVals, labels = propLabels,
					get = function() return change.property end,
					set = function(v)
						change.property = v
						change.value = S.defaultPropertyValue(props[v])
						WA.Add(data); S.refreshTabContent()
					end,
				})
				appendChangeValue(fields, data, change, change.property and props[change.property])
				table.insert(fields, {
					type = "button", name = "Remove change",
					onClick = function()
						table.remove(cond.changes, cidx)
						WA.Add(data); S.refreshTabContent()
					end,
				})
			end
			table.insert(fields, {
				type = "button", name = "+ Add change",
				onClick = function()
					local firstProp = propVals[1]
					table.insert(cond.changes, { property = firstProp, value = S.defaultPropertyValue(props[firstProp]) })
					WA.Add(data); S.refreshTabContent()
				end,
			})
		end
	end

	table.insert(fields, {
		type = "button", name = "+ Add Condition",
		onClick = function()
			data.conditions = data.conditions or {}
			local trigger = numTriggers >= 1 and 1 or -1
			local check = { trigger = trigger }
			local vars = S.conditionVariableList(trigger, templates)
			check.variable = vars[1]
			local vt, tmpl = S.conditionVarType(check, templates)
			check.op, check.value = S.defaultOpValue(vt, tmpl)
			table.insert(data.conditions, { check = check, changes = {} })
			WA.Add(data); S.refreshTabContent()
		end,
	})
end

-- ---------------------------------------------------------------------------
-- Load tab: edits data.load -- the constraints (class/level/zone/
-- combat/group-size/stance) that decide whether the aura is active at all. The
-- editor is generated from WA.loadPrototype (Load.lua), so a new load constraint
-- shows up here for free. Every edit routes through WA.Add, which re-evaluates
-- load state and shows/hides the live region immediately.
-- ---------------------------------------------------------------------------

function S.appendLoadOptions(fields, data)
	table.insert(fields, { type = "header", name = "Load Conditions" })
	data.load = data.load or {}
	local L = data.load

	table.insert(fields, {
		type = "toggle", name = "Never load (disable)", key = "never",
		get = function() return L.never and true or false end,
		set = function(v) L.never = v and true or false; WA.Add(data) end,
	})

	local proto = WA.loadPrototype or {}
	for i = 1, table.getn(proto) do
		local arg = proto[i]
		local useKey = "use_" .. arg.name

		if arg.widget == "classtier" then
			-- Not a plain on/off gate: "off"/"single"/"multi" picks between a
			-- one-class dropdown and a multi-class checkbox list, matching WA2's
			-- multiselect single/multi tiering (see Load.lua's comment on this
			-- entry). `use_class` holds the mode string itself.
			table.insert(fields, {
				type = "select", name = arg.display, key = useKey,
				values = { "off", "single", "multi" },
				labels = { off = "Ignored", single = "Single Class", multi = "Multiple Classes" },
				get = function() return L[useKey] or "off" end,
				set = function(v)
					-- Branched, not `(v == "off") and nil or v` -- that idiom
					-- yields "off" for the very case it means to store nil, and a
					-- truthy use_class is an *enabled* constraint.
					if v == "off" then L[useKey] = nil else L[useKey] = v end
					if v == "single" and not L.class then
						local _, cls = UnitClass("player")
						L.class = cls
					elseif v == "multi" then
						L.classes = L.classes or {}
					end
					WA.Add(data); S.refreshTabContent()
				end,
			})
			if L[useKey] == "single" then
				table.insert(fields, {
					type = "select", name = "Class", key = "class",
					values = WA.CLASS_TOKENS, labels = WA.CLASS_COLOR_LABELS,
					get = function() return L.class or WA.CLASS_TOKENS[1] end,
					set = function(v) L.class = v; WA.Add(data) end,
				})
			elseif L[useKey] == "multi" then
				L.classes = L.classes or {}
				local tokens = WA.CLASS_TOKENS
				for i2 = 1, table.getn(tokens) do
					local token = tokens[i2]
					table.insert(fields, {
						type = "toggle", name = WA.CLASS_COLOR_LABELS[token] or token, key = "classes." .. token, half = true,
						get = function() return L.classes[token] and true or false end,
						set = function(v) L.classes[token] = v and true or nil; WA.Add(data) end,
					})
				end
			end
		else
			table.insert(fields, {
				type = "toggle", name = arg.display, key = useKey,
				get = function() return L[useKey] and true or false end,
				set = function(v)
					L[useKey] = v and true or false
					if v and L[arg.name] == nil then L[arg.name] = arg.default end
					WA.Add(data); S.refreshTabContent()
				end,
			})
			if L[useKey] then
				if arg.widget == "select" then
					table.insert(fields, {
						type = "select", name = arg.display, key = arg.name,
						values = arg.values, labels = arg.labels,
						get = function() return L[arg.name] or arg.default end,
						set = function(v) L[arg.name] = v; WA.Add(data) end,
					})
				elseif arg.widget == "opnumber" then
					table.insert(fields, {
						type = "opnumber", name = arg.display, key = arg.name,
						getOp = function() return L[arg.name .. "_operator"] or arg.operator or ">=" end,
						setOp = function(v) L[arg.name .. "_operator"] = v; WA.Add(data) end,
						getVal = function() return L[arg.name] or arg.default end,
						setVal = function(v) L[arg.name] = v; WA.Add(data) end,
					})
				elseif arg.widget == "range" then
					table.insert(fields, {
						type = "range", name = arg.display, key = arg.name,
						min = arg.min, max = arg.max, step = arg.step,
						get = function() return L[arg.name] or arg.default end,
						set = function(v) L[arg.name] = v; WA.Add(data) end,
					})
				elseif arg.widget == "spell" then
					table.insert(fields, {
						type = "spell", name = arg.display, key = arg.name,
						get = function() return L[arg.name] or "" end,
						set = function(v) L[arg.name] = v; WA.Add(data) end,
					})
				else -- input
					table.insert(fields, {
						type = "input", name = arg.display, key = arg.name,
						get = function() return L[arg.name] or "" end,
						set = function(v) L[arg.name] = v; WA.Add(data) end,
					})
				end
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Trigger tab: every trigger listed one under the other, each as a collapsible
-- section headed "Trigger n: <type>" with its own delete button, then "+ Add
-- Trigger" at the bottom -- the same layout as upstream's own trigger tab
-- (TriggerOptions.lua: combination options first, per-trigger groups, add at
-- order 5000). The combination controls above them (disjunctive,
-- activeTriggerMode) drive machinery the runtime already has -- StateMachine's
-- UpdatedTriggerState -- and only appear once there's more than one trigger.
-- ---------------------------------------------------------------------------

local DISJUNCTIVE_LABELS = { all = "All Triggers", any = "Any Trigger", custom = "Custom" }

function S.appendTriggerOptions(fields, data)
	local triggers = data.triggers or {}
	local numTriggers = table.getn(triggers)

	table.insert(fields, { type = "header", name = "Triggers" })

	-- Combination + active-trigger controls only matter once there's more than
	-- one trigger; a single-trigger aura keeps the tab uncluttered.
	if numTriggers > 1 then
		table.insert(fields, {
			type = "select", name = "Show If", half = true,
			values = { "all", "any", "custom" }, labels = DISJUNCTIVE_LABELS,
			get = function() return triggers.disjunctive or "all" end,
			set = function(v) triggers.disjunctive = v; WA.Add(data); S.refreshTabContent() end,
		})

		local modeVals, modeLabels = { "auto" }, { auto = "Automatic" }
		for n = 1, numTriggers do
			table.insert(modeVals, tostring(n))
			modeLabels[tostring(n)] = "Trigger " .. n
		end
		table.insert(fields, {
			type = "select", name = "Dynamic Info From", half = true, values = modeVals, labels = modeLabels,
			get = function()
				local atm = triggers.activeTriggerMode
				if atm == nil or atm == WA.trigger_modes.first_active then return "auto" end
				return tostring(atm)
			end,
			set = function(v)
				triggers.activeTriggerMode = (v == "auto") and WA.trigger_modes.first_active or tonumber(v)
				WA.Add(data)
			end,
		})

		if (triggers.disjunctive or "all") == "custom" then
			table.insert(fields, {
				type = "code", height = 60,
				name = "Custom Logic (e.g. function(t) return t[1] and not t[2] end)",
				-- Raw, not `or ""`: nil means never configured (open at the
				-- default below), "" means cleared and left cleared.
				get = function() return triggers.customTriggerLogic end,
				set = function(v) triggers.customTriggerLogic = v; WA.Add(data) end,
				-- Seeds a working expression rather than the empty string the
				-- field actually defaults to: "" is what you get before writing
				-- anything, not something worth resetting *to*.
				default = "function(t) return t[1] end",
				-- Asked of the compiler for its wrapper, so the reported line
				-- numbers match what the user is looking at.
				validate = function(txt)
					return W.LuaSyntaxError(WA.WrapFunctionSource(txt), "trigger logic")
				end,
			})
		end
	end

	for n = 1, numTriggers do
		local tn = n
		local t = WA.GetTrigger(data, tn)
		local spec = t and WA.triggerTypes[t.type]
		local title = "Trigger " .. tn
		if t then title = title .. ": " .. ((spec and spec.displayName) or t.type or "?") end
		local key = "trigger:" .. tn
		-- Folded by default once there's more than one, so a multi-trigger aura
		-- opens as a readable list instead of a wall of fields (upstream's own
		-- __collapsed = #data.triggers > 1).
		local collapsed = S.isCollapsed(data, key, numTriggers > 1)

		local header = {
			type = "header", name = title, collapsed = collapsed,
			onToggle = function()
				S.setCollapsed(data, key, not collapsed)
				S.refreshTabContent()
			end,
		}
		-- No delete on a lone trigger: a display always has trigger 1
		-- (WA.DeleteTrigger refuses the last one anyway).
		if numTriggers > 1 then
			header.onDelete = function()
				WA.DeleteTrigger(data, tn)
				S.clearCollapsed(data, "trigger:")
				WA.Add(data); S.refreshTabContent()
			end
		end
		table.insert(fields, header)

		if not collapsed then
			local typeFields = spec and spec.options(data, tn) or {}
			for i = 1, table.getn(typeFields) do
				table.insert(fields, typeFields[i])
			end
		end
	end

	table.insert(fields, {
		type = "button", name = "+ Add Trigger",
		onClick = function()
			local idx = WA.AddTrigger(data)
			-- Open the new one; the others keep whatever fold state they had.
			if idx then S.setCollapsed(data, "trigger:" .. idx, false) end
			WA.Add(data); S.refreshTabContent()
		end,
	})
end

-- Paints S.content and resizes it to fit, so the surrounding scroll frame gets
-- a correct range (BuildOptions records page.contentHeight). Scroll goes back to
-- the top on a tab or aura switch, and is held across a repaint of the same one.
local lastContentKey
local function paintContent(fields)
	local content = S.content
	-- A repaint of the same aura's same tab is a control revealing or hiding its
	-- dependent fields, not navigation. Every such toggle goes through
	-- WA.RefreshOptions, so resetting here unconditionally threw the user back to
	-- the top of a long tab on each click.
	local key = tostring(S.primaryId()) .. "|" .. tostring(S.activeTab)
	local keep = 0
	if key == lastContentKey then keep = S.contentScroll:GetVerticalScroll() or 0 end
	lastContentKey = key
	-- Leave a few px on the right for the slim slider so widgets never sit under it.
	content:SetWidth(S.contentScroll:GetWidth() - 8)
	-- pcall'd and reported: a field descriptor with a bad get/values/range takes
	-- down only the rest of that one paint, and says so. Unhandled, it would just
	-- leave a half-drawn tab with no explanation -- this client swallows script
	-- errors unless the user has turned them on.
	local ok, err = pcall(W.BuildOptions, content, fields)
	if not ok then
		DEFAULT_CHAT_FRAME:AddMessage("|cffff4040WeakestAuras:|r options paint failed -- " .. tostring(err))
	end
	content:SetHeight(content.contentHeight or 1)
	S.contentScroll.Update()
	-- A repaint that removed rows can leave the kept offset past the new end.
	local range = (content.contentHeight or 1) - S.contentScroll:GetHeight()
	if range < 0 then range = 0 end
	if keep > range then keep = range end
	S.contentScroll:SetVerticalScroll(keep)
	-- The slider holds its own value, so it has to be told too or the thumb
	-- parts company with the content it represents.
	if S.contentScroll.slider then S.contentScroll.slider:SetValue(keep) end
	-- Any ordinary tab paint puts the New pane away, including its thumbnails.
	S.clearNewPane()
end

-- ---------------------------------------------------------------------------
-- The New pane: a pseudo-tab (S.activeTab == "new") with no tab button, painted
-- into the same content area. Its rows carry a live thumbnail frame, which no
-- field descriptor describes, so it paints itself instead of going through
-- W.BuildOptions -- but it still runs BuildOptions once with nothing in it, or
-- the previous tab's pooled widgets would sit visible underneath.
-- ---------------------------------------------------------------------------

S.newRows = {}

function S.ensureNewRow(i)
	if S.newRows[i] then return S.newRows[i] end
	local row = CreateFrame("Button", nil, S.content)
	row:SetHeight(S.NEW_ROW_H)
	local hl = row:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints(row)
	hl:SetTexture(1, 1, 1, 0.12)

	local box = CreateFrame("Frame", nil, row)
	box:SetWidth(S.NEW_ROW_H - 8); box:SetHeight(S.NEW_ROW_H - 8)
	box:SetPoint("LEFT", row, "LEFT", 4, 0)
	row.box = box

	local icon = box:CreateTexture(nil, "ARTWORK")
	icon:SetAllPoints(box)
	row.icon = icon

	local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	name:SetPoint("TOPLEFT", box, "TOPRIGHT", 8, -2)
	name:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -2)
	name:SetJustifyH("LEFT")
	row.name = name

	local desc = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	desc:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 8, 2)
	desc:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -4, 2)
	desc:SetJustifyH("LEFT")
	desc:SetTextColor(0.7, 0.7, 0.7)
	row.desc = desc

	row:SetScript("OnClick", function() if row.onClick then row.onClick() end end)
	S.newRows[i] = row
	return row
end

-- Releases pane rows from `from` onward, thumbnails included -- the pools only
-- ever grow otherwise. Used both for the tail a repaint stopped using and for
-- the whole pane on the way out.
local function releaseNewRows(from)
	for i = from, table.getn(S.newRows) do
		local row = S.newRows[i]
		if row.thumb then
			WA.ReleaseThumbnail(row.thumb)
			row.thumb = nil
			row.thumbType = nil
		end
		row:Hide()
	end
end

-- Puts the whole pane away. The two headings are plain FontStrings parented to
-- the shared content frame, so they outlive an ordinary tab's paint unless they
-- are hidden here -- BuildOptions only sweeps the widget pools, which they are
-- not part of.
function S.clearNewPane()
	releaseNewRows(1)
	if S.newHeader then S.newHeader:Hide() end
	if S.newExternal then S.newExternal:Hide() end
end

-- group/dynamicgroup first, then alphabetically by display name -- upstream's
-- own ordering, and it puts the two containers where someone building a layout
-- looks for them.
local function newPaneTypes(targetId)
	local list = {}
	local names = WA.RegionTypeList()
	for i = 1, table.getn(names) do
		local name = names[i]
		if WA.CanPlaceAura(name, targetId) then table.insert(list, name) end
	end
	table.sort(list, function(a, b)
		local ga = WA.regionTypes[a].isGroup == true
		local gb = WA.regionTypes[b].isGroup == true
		if ga ~= gb then return ga end
		local la = WA.regionTypes[a].displayName or a
		local lb = WA.regionTypes[b].displayName or b
		if la == lb then return a < b end
		return la < lb
	end)
	return list
end

-- What a creation would do with the current selection, said out loud: New
-- behaving differently depending on what's picked is a bug report unless the
-- pane shows it.
function S.newPaneTargetText(targetId)
	local target = targetId and WeakestAurasDB.displays[targetId]
	if not target then return "New aura" end
	if WA.IsGroup(target) then return "New aura in \"" .. targetId .. "\"" end
	return "New aura after \"" .. targetId .. "\""
end

function S.paintNewPane()
	local content = S.content
	content:SetWidth(S.contentScroll:GetWidth() - 8)
	-- Hide-first sweep for the widget pools; this pane owns none of them.
	local ok, err = pcall(W.BuildOptions, content, {})
	if not ok then
		DEFAULT_CHAT_FRAME:AddMessage("|cffff4040WeakestAuras:|r options paint failed -- " .. tostring(err))
	end

	local targetId = S.primaryId()
	if not S.newHeader then
		S.newHeader = W.sectionHeader(content, "")
		S.newExternal = W.sectionHeader(content, "External")
	end
	S.newHeader:SetText(S.newPaneTargetText(targetId))
	S.newHeader:ClearAllPoints()
	S.newHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -8)
	S.newHeader:Show()

	local types = newPaneTypes(targetId)
	local y = 28
	local n = 0
	for i = 1, table.getn(types) do
		local rtype = types[i]
		local spec = WA.regionTypes[rtype]
		n = i
		local row = S.ensureNewRow(i)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -y)
		row:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, -y)
		row.name:SetText(spec.displayName or rtype)
		row.desc:SetText(spec.description or "")
		row.onClick = function() S.createAura(rtype) end

		-- The preview is of the *type*, so it renders against that type's own
		-- defaults rather than any saved aura.
		if row.thumbType ~= rtype then
			if row.thumb then WA.ReleaseThumbnail(row.thumb) end
			local sample = S.newPaneSample(rtype)
			row.thumb = WA.AcquireThumbnail(rtype, row, sample, S.NEW_ROW_H - 8)
			row.thumbType = row.thumb and rtype or nil
			if row.thumb then
				row.thumb:SetPoint("TOPLEFT", row.box, "TOPLEFT", 0, 0)
			end
		end
		if row.thumb then
			row.icon:Hide()
		else
			row.icon:Show()
			row.icon:SetTexture(spec.icon or S.FALLBACK_ICON)
		end
		row:Show()
		y = y + S.NEW_ROW_H + 2
	end

	y = y + 8
	S.newExternal:ClearAllPoints()
	S.newExternal:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -y)
	S.newExternal:Show()
	y = y + 20

	n = n + 1
	local importRow = S.ensureNewRow(n)
	importRow:ClearAllPoints()
	importRow:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -y)
	importRow:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, -y)
	importRow.name:SetText("Import from string")
	importRow.desc:SetText("Paste an aura exported from WeakAuras or WeakestAuras.")
	importRow.onClick = function() S.openImport() end
	if importRow.thumb then
		WA.ReleaseThumbnail(importRow.thumb)
		importRow.thumb = nil
		importRow.thumbType = nil
	end
	importRow.icon:Show()
	importRow.icon:SetTexture("Interface\\Buttons\\UI-GuildButton-PublicNote-Up")
	importRow:Show()
	y = y + S.NEW_ROW_H + 8

	releaseNewRows(n + 1)
	content:SetHeight(y)
	S.contentScroll:SetVerticalScroll(0)
	S.contentScroll.Update()
end

-- A throwaway display carrying nothing but a type's own defaults, cached per
-- type so the pane isn't rebuilding them on every repaint.
S.newPaneSamples = {}
function S.newPaneSample(regionType)
	local sample = S.newPaneSamples[regionType]
	if not sample then
		sample = { id = "", uid = "", regionType = regionType }
		WA.MergeDefaults(sample)
		S.newPaneSamples[regionType] = sample
	end
	return sample
end

function S.openNewPane()
	S.activeTab = "new"
	for i = 1, table.getn(S.tabButtons or {}) do
		S.tabButtons[i].setSelected(false)
	end
	S.refreshTabContent()
end

function S.refreshTabContent()
	-- Drop popups hosted on the panel (LibWidgets menus now float above the
	-- content ScrollFrame rather than being parented to their button) before a
	-- repaint hides their buttons, so none can survive a tab/aura switch.
	LibWidgets.CloseAllMenus()
	if S.activeTab == "new" then S.paintNewPane(); return end
	local n = table.getn(S.selection)
	if n > 1 then
		-- Per-field mass editing is not available --
		-- so a multi-selection just parks the content pane here regardless of
		-- which tab is active, rather than showing single-aura content for an
		-- arbitrary member.
		paintContent({ { type = "header", name = n .. " auras selected" } })
		return
	end
	local data = S.primaryId() and WeakestAurasDB.displays[S.primaryId()]
	if not data then
		-- Nothing picked: offer creation rather than a placeholder telling the
		-- reader to go and create something.
		S.activeTab = "new"
		S.paintNewPane()
		return
	end
	if S.activeTab == "display" then
		-- Resolved rather than looked up, so an aura naming a type this addon
		-- lacks gets the fallback's tab (which says so) instead of a blank one.
		local region = WA.RegionSpecFor(data)
		-- The region's own sections (Icon/Size/Position) fold too; done here
		-- rather than in each region generator so a new region type gets it for
		-- free. Applied before the effects are appended, which bring their own
		-- (nested, deletable) headers.
		local fields = S.collapsibleSections(region and region.options(data) or {}, data, "region:")
		-- Subregion (text/border/glow) editing lives under Display, matching
		-- upstream (appended to the region options, not a separate tab).
		if not WA.IsGroup(data) then S.appendDisplayEffectsOptions(fields, data) end
		paintContent(fields)
	elseif S.activeTab == "trigger" then
		local fields = {}
		S.appendTriggerOptions(fields, data)
		paintContent(fields)
	elseif S.activeTab == "conditions" then
		local fields = {}
		S.appendConditionOptions(fields, data)
		paintContent(fields)
	elseif S.activeTab == "load" then
		local fields = {}
		S.appendLoadOptions(fields, data)
		paintContent(fields)
	else
		paintContent(S.getInfoOptions(data))
	end
end

-- Groups have no trigger of their own (see WA.IsGroup in Data.lua), so the
-- Trigger tab doesn't apply to one -- hides the button, and steps off it back
-- to Info if it was the active tab when the selection changed onto a group.
-- (Text editing lives under Display, which every region -- group or leaf -- has.)
function S.updateTabAvailability()
	local data = S.primaryId() and WeakestAurasDB.displays[S.primaryId()]
	local isGroup = data and WA.IsGroup(data)
	for i = 1, table.getn(S.tabButtons) do
		local tb = S.tabButtons[i]
		-- Groups have no trigger and no runtime state, so the Trigger,
		-- Conditions and Load tabs don't apply to one.
		if tb.key == "trigger" or tb.key == "conditions" or tb.key == "load" then
			if isGroup then tb:Hide() else tb:Show() end
		end
	end
	if isGroup and (S.activeTab == "trigger" or S.activeTab == "conditions" or S.activeTab == "load") then
		S.activeTab = "info"
		for i = 1, table.getn(S.tabButtons) do
			S.tabButtons[i].setSelected(S.tabButtons[i].key == "info")
		end
	end
end

-- Status icons, pooled across every row rather than per row -- see the strip in
-- S.ensureRow for why. A released icon is hidden and reparented on its next
-- acquire; frames can't be destroyed on this client, so the pool is the only
-- way the count stays bounded by what's on screen.
S.statusPool = {}

function S.acquireStatusIcon(parent)
	local icon = table.remove(S.statusPool)
	if not icon then
		icon = CreateFrame("Button", nil, parent)
		icon:SetWidth(S.STATUS_SIZE); icon:SetHeight(S.STATUS_SIZE)
		local bg = icon:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints(icon)
		bg:SetTexture(0, 0, 0, 0.9)
		local fill = icon:CreateTexture(nil, "ARTWORK")
		fill:SetPoint("TOPLEFT", icon, "TOPLEFT", 1, -1)
		fill:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -1, 1)
		icon.fill = fill
		icon:SetScript("OnEnter", function()
			GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
			GameTooltip:SetText(this.tipTitle or "", 1, 1, 1)
			if this.tipDesc then GameTooltip:AddLine(this.tipDesc, 0.8, 0.8, 0.8, true) end
			GameTooltip:Show()
		end)
		icon:SetScript("OnLeave", function() GameTooltip:Hide() end)
		icon:SetScript("OnClick", function() if this.onClick then this.onClick() end end)
	end
	icon:SetParent(parent)
	icon:ClearAllPoints()
	return icon
end

function S.releaseStatusIcon(icon)
	if not icon then return end
	icon:Hide()
	icon.tipTitle, icon.tipDesc, icon.onClick = nil, nil, nil
	for i = 1, table.getn(S.statusPool) do
		if S.statusPool[i] == icon then return end
	end
	table.insert(S.statusPool, icon)
end

-- The load entry's three looks. Colours rather than art: at 10px a texture
-- reads as a smudge, and load state is the one status where the colour alone
-- carries the meaning.
local LOAD_STATUS = {
	loaded = { tex = { 0.3, 0.9, 0.3, 1 }, title = "Loaded",
		desc = "This aura's load conditions currently pass." },
	standby = { tex = { 0.95, 0.75, 0.2, 0.9 }, title = "Standby",
		desc = "This aura belongs to this character, but the moment doesn't qualify -- a combat, zone, group or form condition is holding it back." },
	unloaded = { tex = { 0.5, 0.5, 0.5, 1 }, title = "Not Loaded",
		desc = "This aura's load conditions don't currently pass, so it isn't active." },
}

-- "loaded"/"standby" share the upper bucket, "unloaded" is the lower one --
-- matching upstream's loaded[id] ~= nil test (WA.DisplayLoadState collapses
-- the same three-state read StateMachine.lua exposes).
local function loadBucket(id)
	return WA.DisplayLoadState(id) == "unloaded" and "unloaded" or "loaded"
end

-- Which bucket a rendered row index sits in: the nearest header at or above it.
-- nil above the first header, which is a position no aura occupies. Drag uses
-- this to keep a move inside the bucket it started in -- bucket membership is
-- derived from load state every repaint, so a drop that changed it would have
-- nothing to commit.
local function bucketAt(rows, index)
	for i = index, 1, -1 do
		local entry = rows[i]
		if entry and entry.header then return entry.header end
	end
	return nil
end

-- Flattens the display tree into the order rows actually render in: each
-- entry is { id = ..., depth = ... }. With no active search, this is
-- WA.GetOrder() depth-first, descending into a group's controlledChildren
-- right after it only while S.expanded[groupId] isn't explicitly false.
-- With an active search, hierarchy stops mattering -- every display (at any
-- depth) whose id matches is included flat at depth 0, same as the old
-- flat-list filter, just extended to search nested auras too.
--
-- `bucket`, when given, filters *top-level* (depth 0) entries to the ones
-- whose loadBucket matches -- a child never bucket-filters on its own, so once
-- a top-level id has been accepted for this pass every descendant renders
-- under it regardless of its own load state.
local function walkTree(ids, depth, rows, forceExpand, filterTerms, bucket)
	for i = 1, table.getn(ids) do
		local id = ids[i]
		local data = WeakestAurasDB.displays[id]
		if data and (not bucket or depth > 0 or loadBucket(id) == bucket) then
			if not filterTerms or S.matchesFilter(id, filterTerms) then
				table.insert(rows, { id = id, depth = filterTerms and 0 or depth })
			end
			if WA.IsGroup(data) and (forceExpand or S.expanded[id] ~= false) then
				walkTree(data.controlledChildren or {}, depth + 1, rows, forceExpand, filterTerms, bucket)
			end
		end
	end
end

-- Fallback texture for a row whose regionType registers no thumbnail (or a
-- group, which never gets one). WA.ResolveDisplayIcon (Data.lua) is the actual
-- resolution rule, shared with the icon/progressbar thumbnails' modifyThumbnail
-- so the two can't drift apart.
local function resolveRowIcon(data)
	return WA.ResolveDisplayIcon(data)
end

-- Two passes over the same tree, one per bucket, each fronted by its own
-- header entry ({ header = "loaded"/"unloaded" }, no `id` field at all --
-- bucket membership is derived here every repaint, never stored). Both
-- headers always render, filtering or not, so a filtered result still shows
-- which side of the divide it landed on.
function S.buildRows()
	local rows = {}
	local searching = table.getn(S.searchTerms) > 0
	local filterTerms = searching and S.searchTerms or nil

	table.insert(rows, { header = "loaded" })
	if S.bucketExpanded["loaded"] ~= false then
		walkTree(WA.GetOrder(), 0, rows, searching, filterTerms, "loaded")
	end

	table.insert(rows, { header = "unloaded" })
	if S.bucketExpanded["unloaded"] ~= false then
		walkTree(WA.GetOrder(), 0, rows, searching, filterTerms, "unloaded")
	end

	return rows
end

-- Frees whatever a row was holding on to before it goes dark or is rebound.
-- The thumbnail pool only ever grows, so a row that skips this leaks one frame
-- per type for every aura ever scrolled past.
local function releaseRow(row)
	if row.thumb then
		WA.ReleaseThumbnail(row.thumb)
		row.thumb = nil
		row.thumbType = nil
	end
	row.clearStatuses()
end

-- A bucket header is a mode of the pooled row, not a second pool: it drops
-- row.id (everything downstream keys off that staying non-nil for a real aura)
-- and shows only the expand toggle and the title, styled as a caption.
-- Every top-level aura currently in a bucket. The header's eye acts on all of
-- them at once, so it needs the membership the row list derives per repaint.
function S.bucketMembers(bucket)
	local ids = {}
	local order = WA.GetOrder()
	for i = 1, table.getn(order) do
		if loadBucket(order[i]) == bucket then table.insert(ids, order[i]) end
	end
	return ids
end

-- One line: caption on the left, then the eye and the collapse toggle against
-- the right edge (WA2's own header orders them the same way). The pooled row's
-- parts are shared with an aura row, so each one that moves is re-anchored here
-- and put back by paintAuraRow.
local function paintBucketHeader(row, bucket)
	row.header = true
	row.id = nil
	row.bucket = bucket
	row.title:ClearAllPoints()
	row.title:SetPoint("LEFT", row, "LEFT", 6, 0)
	row.title:SetPoint("RIGHT", row.eye, "LEFT", -4, 0)
	row.title:SetText(bucket == "loaded" and "Loaded" or "Not Loaded")
	row.title:SetTextColor(1, 0.82, 0)
	row.sub:SetText("")
	row.sel:Hide()
	row.icon:Hide()
	row.iconBox:Hide()
	row.ungroup:Hide()
	releaseRow(row)

	row.expand:ClearAllPoints()
	row.expand:SetPoint("RIGHT", row, "RIGHT", -3, 0)
	row.expand:Show()
	row.expand.label:SetText(S.bucketExpanded[bucket] == false and "+" or "-")

	-- Force-shows every aura in the bucket, so a whole set can be eyeballed at
	-- once; the tri-state rolls up the same way a group's does.
	row.eye:ClearAllPoints()
	row.eye:SetPoint("RIGHT", row.expand, "LEFT", -2, 0)
	row.eye:Show()
	local fs = WA.ForcedStateMany(S.bucketMembers(bucket))
	if fs == 2 then
		row.eye.fill:SetTexture(W.EYE_TEXTURES .. "full")
	elseif fs == 1 then
		row.eye.fill:SetTexture(W.EYE_TEXTURES .. "partial")
	else
		row.eye.fill:SetTexture(W.EYE_TEXTURES .. "empty")
	end
	row:Show()
end

local function paintAuraRow(row, entry)
	row.beginStatuses()
	local id = entry.id
	local data = WeakestAurasDB.displays[id]
	local isGroup = WA.IsGroup(data)
	row.header = false
	row.id = id
	-- Put back everything a header repaint moves: the two lines of text against
	-- the preview, and the eye in the row's bottom-right corner.
	row.title:ClearAllPoints()
	row.title:SetPoint("TOPLEFT", row.iconBox, "TOPRIGHT", 4, 0)
	row.title:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -2)
	row.title:SetTextColor(1, 1, 1)
	row.title:SetText(id)
	row.eye:ClearAllPoints()
	row.eye:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -3, 2)
	row.expand:ClearAllPoints()
	row.expand:SetPoint("BOTTOMLEFT", row.iconBox, "BOTTOMRIGHT", 2, 0)
	row.iconBox:Show()
	row.eye:Show()
	if isGroup then
		local n = table.getn(data.controlledChildren or {})
		row.sub:SetText(n == 1 and "1 aura" or (n .. " auras"))
		row.expand:Show()
		row.expand.label:SetText(S.expanded[id] == false and "+" or "-")
		-- The summary shares its line with the toggle, so it starts after it on a
		-- group row and against the preview on a leaf.
		row.sub:SetPoint("BOTTOMLEFT", row.expand, "BOTTOMRIGHT", 2, 0)
	else
		local t1 = WA.GetTrigger(data, 1)
		local trigger = t1 and WA.triggerTypes[t1.type]
		row.sub:SetText(trigger and trigger.summary and trigger.summary(data) or "")
		row.expand:Hide()
		row.expand.label:SetText("")
		row.sub:SetPoint("BOTTOMLEFT", row.iconBox, "BOTTOMRIGHT", 4, 0)
	end
	-- Indent, then the ungroup button on a child row, then the preview.
	local x = 2 + entry.depth * S.INDENT_W
	if data.parent then
		row.ungroup:ClearAllPoints()
		row.ungroup:SetPoint("LEFT", row, "LEFT", x, 0)
		row.ungroup:Show()
		x = x + S.UNGROUP_W + 2
	else
		row.ungroup:Hide()
	end
	row.iconBox:ClearAllPoints()
	row.iconBox:SetPoint("TOPLEFT", row, "TOPLEFT", x, -2)
	-- Real per-region-type preview when the type registers one (Regions.lua); a
	-- row is pooled by *slot* and rebound to a different aura on every scroll
	-- tick, so the thumbnail is only trustworthy while regionType hasn't changed
	-- underneath it -- a change releases and reacquires, an unchanged type just
	-- repaints the frame already sitting there.
	local regionSpec = WA.regionTypes[data.regionType]
	if regionSpec and regionSpec.createThumbnail then
		if row.thumbType ~= data.regionType then
			WA.ReleaseThumbnail(row.thumb)
			row.thumb = WA.AcquireThumbnail(data.regionType, row, data, S.ROW_H - 4)
			-- Only claim the type once a frame actually came back, or a failed
			-- acquire would look satisfied on every later repaint and the row
			-- would stay blank.
			row.thumbType = row.thumb and data.regionType or nil
			if row.thumb then
				row.thumb:SetPoint("TOPLEFT", row.iconBox, "TOPLEFT", 0, 0)
			end
		else
			WA.ModifyThumbnail(data.regionType, row.thumb, data)
		end
	elseif row.thumb then
		WA.ReleaseThumbnail(row.thumb)
		row.thumb = nil
		row.thumbType = nil
	end
	if row.thumb then
		row.icon:Hide()
	else
		row.icon:Show()
		row.icon:SetTexture(resolveRowIcon(data) or S.FALLBACK_ICON)
	end
	-- A group's own id never enters S.selection (see S.leafDescendants), so its
	-- row highlights instead when every one of its descendants is selected --
	-- otherwise a collapsed group ctrl-clicked into the selection would show no
	-- feedback at all.
	local highlighted = isGroup and S.allDescendantsSelected(id) or S.isSelected(id)
	if highlighted then row.sel:Show() else row.sel:Hide() end
	-- Eye tri-state (WA.ForcedState 2/1/0): full = eye-pinned (stays shown),
	-- partial = shown only because it's the current selection, empty =
	-- hidden/muted. For a group these roll up (all pinned / partly visible /
	-- dark). The frames stay Shown throughout -- an empty eye is a state, not an
	-- absence, so hiding it would read as the indicator being missing rather
	-- than as "not visible".
	local fs = WA.ForcedState(id)
	local fill = row.eye.fill
	if fs == 2 then
		fill:SetTexture(W.EYE_TEXTURES .. "full")
	elseif fs == 1 then
		fill:SetTexture(W.EYE_TEXTURES .. "partial")
	else
		fill:SetTexture(W.EYE_TEXTURES .. "empty")
	end
	-- Load state as the strip's first entry. A group takes the priority roll-up
	-- (any leaf loaded wins, else any standby), with the leaf counts in the
	-- tooltip so the "n of N" reading survives.
	local state, nLoaded, nStandby, nLeaves = WA.DisplayLoadState(id)
	if not (isGroup and nLeaves == 0) then
		local look = LOAD_STATUS[state]
		local desc = look.desc
		if isGroup then
			desc = nLoaded .. " of " .. nLeaves .. " auras loaded"
			if nStandby > 0 then desc = desc .. ", " .. nStandby .. " on standby" end
		end
		row.setStatus("load", 1, look.tex, look.title, desc)
	end
	-- Releases every entry this repaint didn't re-set, so a status that stopped
	-- applying doesn't ride the row into its next aura.
	row.layoutStatuses()
	row:Show()
end

local function entryHeight(entry)
	return entry.header and S.HEADER_H or S.ROW_H
end

-- Rows are not a uniform grid: a bucket header is shorter than an aura row, so
-- each row is placed at the running total of the heights above it and carries
-- that geometry (row.slotY/slotH) for the drag hit-test to read back. The paint
-- runs until the next entry wouldn't fit, which is what decides how many rows
-- are on screen -- S.visibleRows is only the pool's starting size.
function S.refreshList()
	-- Before anything rebinds: an open rename box belongs to the aura it was
	-- opened on, and this repaint may hand its row to a different one.
	S.closeRename()
	S.updateVisibleRows()
	local rows = S.buildRows()

	local offset = S.scroll.offset or 0
	local avail = (S.listAvail or 0) - 4
	local y, painted = 0, 0
	local i = 1
	while true do
		local entry = rows[offset + i]
		if not entry then break end
		local h = entryHeight(entry)
		if y + h > avail then break end
		local row = S.ensureRow(i)
		row:SetHeight(h)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", S.listBg, "TOPLEFT", 2, -2 - y)
		row:SetPoint("TOPRIGHT", S.scroll, "TOPRIGHT", 0, -y)
		row.slotY, row.slotH = y, h
		row.index = offset + i
		if entry.header then
			paintBucketHeader(row, entry.header)
		else
			paintAuraRow(row, entry)
		end
		y = y + h
		painted = i
		i = i + 1
	end
	S.paintedCount = painted
	-- Ends the border flush under the last row painted, whatever mix of header
	-- and aura heights that turned out to be.
	S.listBg:SetHeight(y + 4)

	-- The bar counts rows, not pixels. The largest offset is the one that still
	-- fills the view, so scrolling stops with the last entry at the bottom
	-- rather than running past it into blank space.
	local total = table.getn(rows)
	local maxOffset = total - painted
	if maxOffset < 0 then maxOffset = 0 end
	S.maxOffset = maxOffset
	if offset > maxOffset then
		S.scroll.offset = maxOffset
		return S.refreshList()
	end
	if S.listBar then
		S.barSyncing = true
		S.listBar.Fit(maxOffset, y, total > 0 and painted / total or 1)
		S.listBar:SetValue(offset)
		S.barSyncing = nil
	end
	-- Every row past what the paint used goes dark. A held thumbnail or status
	-- icon must be released on the way, or scrolling past an aura leaks one
	-- frame per type into nothing -- the pools only ever grow.
	for k = painted + 1, table.getn(S.rows) do
		local r = S.rows[k]
		releaseRow(r)
		r.slotY, r.slotH = nil, nil
		r:Hide()
	end
end

function S.selectTab(key)
	S.searchBox:ClearFocus()
	S.activeTab = key
	for i = 1, table.getn(S.tabButtons) do
		S.tabButtons[i].setSelected(S.tabButtons[i].key == key)
	end
	S.refreshTabContent()
end

function S.scheduleUnconfirm(button, text)
	text = text or "Delete"
	C_Timer.After(3, function()
		if button.confirming then
			button.confirming = nil
			button.label:SetText(text)
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Import/Export dialog: one lazily-built toplevel window reused for
-- both directions -- a multi-line editbox plus a Load button shown only in
-- import mode. Independent of buildPanel (its own frame), so /wa export|import
-- work whether or not the main panel is open.
-- ---------------------------------------------------------------------------

function S.ensureIEDialog()
	if S.ieDialog then return S.ieDialog end
	local f = CreateFrame("Frame", "WeakestAurasIEDialog", UIParent)
	f:SetWidth(480); f:SetHeight(360)
	f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	f:SetBackdrop(W.PANEL_BACKDROP)
	f:SetBackdropColor(0, 0, 0, 1)
	f:SetFrameStrata("FULLSCREEN_DIALOG")
	f:SetToplevel(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function() f:StartMoving() end)
	f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
	f:Hide()

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -14)
	title:SetTextColor(1, 0.82, 0)
	f.title = title

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)
	close:SetScript("OnClick", function() f:Hide() end)

	local box = LibWidgets.NewMultiLineEditBox(f, {
		width = 456, height = 250,
		onChange = function(text) S.refreshImportNotice(f, text) end,
	})
	box:SetPoint("TOPLEFT", 12, -40)
	f.box = box

	local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	status:SetPoint("BOTTOMLEFT", 14, 18)
	status:SetPoint("RIGHT", f, "RIGHT", -104, 0)
	status:SetJustifyH("LEFT")
	f.status = status

	local loadBtn = W.button(f, "Import", nil)
	loadBtn:SetWidth(84)
	loadBtn:SetPoint("BOTTOMRIGHT", -12, 12)
	loadBtn:SetScript("OnClick", function()
		local newId, err = WA.Import(f.box.getText())
		if newId then
			f:Hide()
			S.setSelection(newId)
		else
			f.status:SetText("Import failed: " .. (err or "unknown"))
			f.status:SetTextColor(1, 0.4, 0.4)
		end
	end)
	f.loadBtn = loadBtn

	local updateBtn = W.button(f, "Update", nil)
	updateBtn:SetWidth(84)
	updateBtn:SetPoint("RIGHT", loadBtn, "LEFT", -8, 0)
	updateBtn:SetScript("OnClick", function()
		local id, err = WA.ImportOverwrite(f.box.getText())
		if id then
			f:Hide()
			S.refreshList()
			S.setSelection(id)
		else
			f.status:SetText("Update failed: " .. (err or "unknown"))
			f.status:SetTextColor(1, 0.4, 0.4)
		end
	end)
	updateBtn:Hide()
	f.updateBtn = updateBtn

	S.ieDialog = f
	return f
end

-- Says whether the pasted or received string is one we already hold, and
-- renames the button to match. Only ever advice: importing adds a display and
-- never touches the one it recognises. Memoised on the exact text because
-- onChange fires per keystroke and the check has to decode the whole blob.
-- A long aura name would otherwise push the notice under the buttons.
local function shortId(id)
	if string.len(id) > 26 then return string.sub(id, 1, 25) .. "..." end
	return id
end

function S.refreshImportNotice(f, text)
	if f.exporting then return end
	text = text or f.box.getText() or ""
	if f.noticeFor == text then return end
	f.noticeFor = text

	local existing, canUpdate
	if text ~= "" then existing, canUpdate = WA.ImportInfo(text) end
	f.duplicateOf = existing

	if not existing then
		f.updateBtn:Hide()
		f.loadBtn.setText("Import")
		f.loadBtn:SetWidth(84)
		f.status:SetText(f.baseStatus or "")
		f.status:SetTextColor(0.7, 0.7, 0.7)
	else
		f.loadBtn.setText("Import as Copy")
		f.loadBtn:SetWidth(112)
		f.status:SetTextColor(1, 0.82, 0)
		-- The button labels say what each choice does; repeating it here is what
		-- made this line long enough to run under them.
		if canUpdate then
			f.updateBtn:Show()
			f.status:SetText("You already have this as \"" .. shortId(existing) .. "\".")
		else
			f.updateBtn:Hide()
			f.status:SetText("You already have \"" .. shortId(existing)
				.. "\". Groups can only be copied.")
		end
	end

	-- Re-reserve the right edge from the buttons actually showing, rather than a
	-- constant sized for the one button this dialog used to have.
	local reserve = 24 + f.loadBtn:GetWidth()
	if f.updateBtn:IsShown() then reserve = reserve + 8 + f.updateBtn:GetWidth() end
	f.status:SetPoint("RIGHT", f, "RIGHT", -reserve, 0)
end

function S.openExport(id)
	local f = S.ensureIEDialog()
	f.title:SetText("Export Aura")
	f.exporting = true
	f.noticeFor = nil
	f.loadBtn:Hide()
	f.updateBtn:Hide()
	local blob, err = WA.Export(id)
	f.box.setText(blob or ("-- export failed: " .. (err or "unknown")))
	f.status:SetText(blob and "Ctrl-C to copy this string." or (err or ""))
	f.status:SetTextColor(0.7, 0.7, 0.7)
	f:Show()
	if blob then f.box.focusSelectAll() end
end

function S.openImport()
	local f = S.ensureIEDialog()
	f.title:SetText("Import Aura")
	f.exporting = nil
	f.noticeFor = nil
	f.loadBtn:Show()
	f.box.setText("")
	if WA.hasImportExport then
		f.baseStatus = "Paste an exported string, then Import."
	else
		f.baseStatus = "C_EncodingUtil unavailable -- import/export disabled on this client."
	end
	S.refreshImportNotice(f, "")
	f:Show()
	f.box.focusSelectAll()
end

-- A received aura lands in the ordinary import dialog rather than importing
-- itself: the user still confirms, and the string stays inspectable and
-- copyable if the import goes wrong.
function S.openReceived(sender, name, blob)
	local f = S.ensureIEDialog()
	f.title:SetText(sender .. " sent you \"" .. name .. "\"")
	f.exporting = nil
	f.noticeFor = nil
	-- Nothing to say: the title names the sender and the aura, and the box holds
	-- an opaque blob there is no way to read. A duplicate notice may fill this.
	f.baseStatus = ""
	f.loadBtn:Show()
	f.box.setText(blob)
	-- setText fires onChange, but not on a client where it doesn't; ask directly
	-- so the duplicate notice is up before the user reads the dialog.
	S.refreshImportNotice(f, blob)
	f:Show()
	f.box.focusSelectAll()
end

WA.Comm.OnPayload = S.openReceived

local function buildPanel()
	local panel = CreateFrame("Frame", "WeakestAurasOptions", UIParent)
	S.panel = panel
	panel:SetWidth(S.DEFAULT_W); panel:SetHeight(S.DEFAULT_H)
	panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	panel:SetBackdrop(W.PANEL_BACKDROP)
	panel:SetBackdropColor(0, 0, 0, 1)
	panel:SetFrameStrata("DIALOG")
	panel:SetToplevel(true)
	panel:SetMovable(true)
	panel:SetResizable(true)
	panel:SetMinResize(S.MIN_W, S.MIN_H)
	panel:SetMaxResize(S.MAX_W, S.MAX_H)
	panel:EnableMouse(true)
	panel:Hide()
	-- Closing the window (the X button, or /wa toggling it shut) should stop
	-- painting a dummy preview for whatever aura was selected -- otherwise it'd
	-- keep showing a fake state in-world with no config window open to explain why.
	-- Also close any open LibWidgets dropdown: hiding the panel only suppresses a
	-- child menu's visibility, not its Shown flag, so one left open would pop back
	-- up expanded next time the panel reopens.
	-- ClearForced drops the fakes; SetOptionsOpen(false) lifts the config-mode
	-- mute so every aura's real state resumes in-world.
	panel:SetScript("OnHide", function()
		S.closeRename()
		WA.ClearForced()
		WA.SetOptionsOpen(false)
		WA.Mover.Detach()
		LibWidgets.CloseAllMenus()
		-- The icon picker is a UIParent-level dialog (it has to outrank the panel
		-- to sit over it), so nothing takes it down with the panel unless we do.
		W.CloseIconPicker()
		W.CloseTexturePicker()
		-- Same for the context menu's click-away catcher, which is a UIParent
		-- child so that it can cover the whole screen.
		if S.menu then S.menu.Close() end
	end)
	-- A click on bare panel background (no interactive widget under the cursor)
	-- closes an open dropdown and drops edit focus -- the one case LibWidgets'
	-- interaction-driven auto-close can't catch on its own. The content pane and
	-- its backdrop take no clicks, so a click into the empty space beside a code
	-- editor lands here, which is what commits and re-colours it.
	panel:SetScript("OnMouseDown", function()
		LibWidgets.CloseAllMenus()
		if S.menu then S.menu.Close() end
	end)

	-- Dragging the panel by its body/title, exactly like the sibling
	-- Quartermaster's own main panel (Config.lua's build()) -- registered on
	-- the panel itself rather than a separate invisible strip. That strip
	-- (this file's previous approach) sat on top of the close button's
	-- top-right corner and was intercepting clicks meant for it; a plain
	-- RegisterForDrag on the panel doesn't shadow child frames like close,
	-- since a topmost mouse-enabled child still wins hit-testing at its pixels.
	panel:RegisterForDrag("LeftButton")
	panel:SetScript("OnDragStart", function() panel:StartMoving() end)
	panel:SetScript("OnDragStop", function() panel:StopMovingOrSizing() end)

	-- Title + close button styled exactly like Quartermaster's: plain title
	-- text, and a close button left at its UIPanelCloseButton template default
	-- size rather than resized.
	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -14)
	title:SetText("WeakestAuras")
	title:SetTextColor(1, 0.82, 0)

	local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)
	close:SetScript("OnClick", function() panel:Hide() end)

	-- Bottom-right resize grip, using the same stock chat-frame resize art every
	-- 1.12 client ships (no custom texture asset needed).
	local grip = CreateFrame("Button", nil, panel)
	grip:SetWidth(16); grip:SetHeight(16)
	grip:SetPoint("BOTTOMRIGHT", -4, 4)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight", "ADD")
	grip:SetScript("OnMouseDown", function() panel:StartSizing("BOTTOMRIGHT") end)
	grip:SetScript("OnMouseUp", function() panel:StopMovingOrSizing() end)

	-- The content pane is the *fixed*-width column and the list absorbs a resize,
	-- not the other way round -- WA2 anchors its options container a constant
	-- distance in from the window's right edge for the same reason. BuildOptions
	-- caps a full-width field at 240px and never lays out more than two columns,
	-- so width past S.CONTENT_W becomes whitespace; an aura list, by contrast,
	-- shows more of a truncated name with every pixel it gains.
	--
	-- S.CONTENT_W is deliberately the width this pane already had at the default
	-- window size, so no tab's layout shifts at any window width -- only the
	-- list grows.
	local contentScroll = LibWidgets.NewScrollFrame(panel, { wheelStep = 28 })
	S.contentScroll = contentScroll
	contentScroll:SetWidth(S.CONTENT_W)
	contentScroll:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -14, -36 - S.SEARCH_H - S.TOOLBAR_H - 28)
	contentScroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -14, 12)

	-- The options pane reads as its own surface rather than as fields floating on
	-- the window, matching the list's box. Held at the panel's own frame level so
	-- it stays behind the scroll frame it frames -- a sibling created later would
	-- otherwise sit on top of the controls.
	local contentBg = CreateFrame("Frame", nil, panel)
	S.contentBg = contentBg
	contentBg:SetFrameLevel(panel:GetFrameLevel())
	contentBg:SetPoint("TOPLEFT", contentScroll, "TOPLEFT", -6, 6)
	contentBg:SetPoint("BOTTOMRIGHT", contentScroll, "BOTTOMRIGHT", 6, -6)
	contentBg:SetBackdrop(W.EDITBOX_BACKDROP)
	contentBg:SetBackdropColor(0, 0, 0, 0.6)
	contentBg:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)

	-- Left: aura list
	local listBg = CreateFrame("Frame", nil, panel)
	S.listBg = listBg
	listBg:SetPoint("TOPLEFT", 12, -36 - S.SEARCH_H - S.TOOLBAR_H)
	-- Bottom pinned to the panel's own bottom edge rather than a fixed height,
	-- so growing the panel grows the list instead of leaving dead space -- row
	-- count is recalculated from the live height in updateVisibleRows.
	-- No bottom anchor: S.updateVisibleRows sets the height to the rows that fit,
	-- so the border ends flush under the last one instead of stretching to the
	-- panel's bottom margin with a partial row's slack left inside it.
	listBg:SetPoint("RIGHT", contentScroll, "LEFT", -12, 0)
	listBg:SetBackdrop(W.EDITBOX_BACKDROP)
	listBg:SetBackdropColor(0, 0, 0, 0.6)
	listBg:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)

	-- The search box and the toolbar span whatever width the list currently has,
	-- so both track a resize with it. S.LIST_W survives only as the minimum the
	-- window's MIN_W is sized to guarantee.
	local searchBox = W.searchbox(panel, S.LIST_W, function(text)
		S.searchTerms = S.splitFilterTerms(text)
		S.scroll.offset = 0
		S.refreshList()
	end)
	S.searchBox = searchBox
	searchBox:SetPoint("BOTTOMLEFT", listBg, "TOPLEFT", 0, 6)
	searchBox:SetPoint("RIGHT", listBg, "RIGHT", 0, 0)

	-- The list virtualises: a fixed pool of rows is repainted at a row offset
	-- rather than one frame per aura, so the ScrollFrame here is only a viewport
	-- and a set of bounds. Its own scrollbar is retired in favour of the shared
	-- library's slim bar (the same one the options pane and the code editor use),
	-- driven in *rows* rather than pixels -- a row is the smallest thing this
	-- list can show, so a half-scrolled row would be a lie the paint can't tell.
	local scroll = CreateFrame("ScrollFrame", "WeakestAurasOptionsListScroll", listBg, "FauxScrollFrameTemplate")
	S.scroll = scroll
	scroll:SetPoint("TOPLEFT", 2, -2)
	scroll:SetPoint("BOTTOMRIGHT", -12, 2)
	scroll.offset = 0
	local defaultBar = getglobal("WeakestAurasOptionsListScrollScrollBar")
	if defaultBar then
		defaultBar:Hide()
		defaultBar:SetScript("OnValueChanged", nil)
	end

	local listBar = LibWidgets.NewScrollBar(scroll, { inset = 8 })
	S.listBar = listBar
	listBar:SetValueStep(1)
	listBar:SetScript("OnValueChanged", function()
		-- Guarded: refreshList sets this bar's value back, which would otherwise
		-- re-enter here on every repaint.
		if S.barSyncing then return end
		local v = math.floor(this:GetValue() + 0.5)
		if v == S.scroll.offset then return end
		S.scroll.offset = v
		S.refreshList()
	end)

	local function wheelList()
		local maxOffset = S.maxOffset or 0
		local v = (S.scroll.offset or 0) - arg1
		if v < 0 then v = 0 elseif v > maxOffset then v = maxOffset end
		if v == S.scroll.offset then return end
		S.scroll.offset = v
		S.refreshList()
	end
	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", wheelList)
	listBg:EnableMouseWheel(true)
	listBg:SetScript("OnMouseWheel", wheelList)

	-- Drag-to-reorder: an insertion indicator tracked off the live cursor position,
	-- resolved to a boundary index and committed via WA.ReorderAura on release. Mirrors
	-- the pattern validated in the sibling Quartermaster's own drag-reorder list
	-- (Config.lua's beginDrag/endDrag/trackDrag) rather than reinventing hit-testing --
	-- there's no cursor-move event on 1.12 to key off of otherwise.
	--
	-- Two drop modes, chosen by where the cursor lands: near a row boundary
	-- reorders among the dragged item's *current* siblings only (a boundary
	-- straddling two different parents -- e.g. between a group's last child
	-- and the next top-level item -- is genuinely ambiguous once an expanded
	-- group's children interleave into the flat rendered list, so boundary
	-- drags never cross parents); hovering over a group row's body instead
	-- drops *into* that group. Moving a child back out to top level has no
	-- corresponding drag gesture -- see the Info tab's Ungroup button
	-- (S.getInfoOptions) for that direction instead.
	local dragLayer = CreateFrame("Frame", nil, listBg)
	dragLayer:SetAllPoints(scroll)
	dragLayer:SetFrameLevel(listBg:GetFrameLevel() + 10)
	local indicator = dragLayer:CreateTexture(nil, "OVERLAY")
	indicator:SetHeight(3)
	indicator:SetTexture(0.95, 0.82, 0.2, 0.95)
	indicator:Hide()
	-- Where a drop would land, as the drag sees it. On S so the headless harness
	-- can read back a refusal that leaves the tree untouched either way.
	S.dropIndicator = indicator
	local groupHighlight = dragLayer:CreateTexture(nil, "OVERLAY")
	groupHighlight:SetHeight(S.ROW_H)
	groupHighlight:SetTexture(0.2, 0.8, 0.3, 0.35)
	groupHighlight:Hide()

	local reorder = { active = false, fromId = nil, parentId = nil, before = nil, hoverGroupId = nil, bulk = false }
	local trackDrag, beginDrag, endDrag -- forward decl: the row loop below and the
	-- OnUpdate poll further down both need to close over these before they're assigned.

	trackDrag = function()
		local scale = scroll:GetEffectiveScale()
		local top = scroll:GetTop() or 0
		local _, cy = GetCursorPosition()
		cy = cy / scale

		local rows = S.buildRows()
		local n = table.getn(rows)
		local offset = S.scroll.offset or 0
		local count = S.paintedCount or 0

		-- Rows have two different heights, so the cursor is resolved against the
		-- geometry the paint actually laid down instead of a division.
		local depth = top - cy
		local slot, frac = -1, 0
		for k = 1, count do
			local r = S.rows[k]
			if r.slotY and depth < r.slotY + r.slotH then
				slot = k - 1
				frac = (depth - r.slotY) / r.slotH
				break
			end
		end
		if slot < 0 then slot = count end -- past the last painted row
		local hoverEntry = (slot >= 0 and slot < count) and rows[offset + slot + 1] or nil
		-- A header is not a drop target of any kind: it owns no aura to drop
		-- beside and no list to drop into. Clearing both targets makes the
		-- release a no-op rather than a move to wherever they last pointed.
		if hoverEntry and hoverEntry.header then
			reorder.hoverGroupId = nil
			reorder.before = nil
			indicator:Hide()
			groupHighlight:Hide()
			return
		end
		local hoverData = hoverEntry and WeakestAurasDB.displays[hoverEntry.id]
		local hoverIsGroup = hoverData and WA.IsGroup(hoverData) and hoverEntry.id ~= reorder.fromId
			and frac > 0.25 and frac < 0.75

		if hoverIsGroup then
			reorder.hoverGroupId = hoverEntry.id
			reorder.before = nil
			indicator:Hide()
			local hovered = S.rows[slot + 1]
			groupHighlight:SetHeight(hovered.slotH or S.ROW_H)
			groupHighlight:ClearAllPoints()
			groupHighlight:SetPoint("TOPLEFT", dragLayer, "TOPLEFT", 0, -(hovered.slotY or 0))
			groupHighlight:SetPoint("TOPRIGHT", dragLayer, "TOPRIGHT", 0, -(hovered.slotY or 0))
			groupHighlight:Show()
			return
		end

		reorder.hoverGroupId = nil
		groupHighlight:Hide()

		-- Nearest boundary: the top of the hovered row, or the bottom of it.
		local p = (frac < 0.5) and slot or (slot + 1)
		if p < 0 then p = 0 elseif p > count then p = count end
		-- The boundary's pixel position, again from the painted geometry.
		local py
		if p == 0 then
			py = 0
		elseif S.rows[p] and S.rows[p].slotY then
			py = S.rows[p].slotY + S.rows[p].slotH
		else
			py = 0
		end

		-- A boundary that would land the aura in the other bucket is refused
		-- outright: it reads as "drag into Loaded", which has no meaning to
		-- commit, and the row would snap straight back on the next repaint.
		if bucketAt(rows, offset + p) ~= reorder.bucket then
			reorder.before = nil
			indicator:Hide()
			return
		end

		-- Convert the boundary (an index into the full rendered rows list) into
		-- an index among just reorder.parentId's own children, so any other
		-- parent's rows interleaved above it in the view don't shift the count.
		local siblingCount = 0
		for i = 1, offset + p do
			local entry = rows[i]
			local data = entry and WeakestAurasDB.displays[entry.id]
			if data and data.parent == reorder.parentId then siblingCount = siblingCount + 1 end
		end
		reorder.before = siblingCount + 1

		indicator:ClearAllPoints()
		indicator:SetPoint("TOPLEFT", dragLayer, "TOPLEFT", 0, -py + 1)
		indicator:SetPoint("TOPRIGHT", dragLayer, "TOPRIGHT", 0, -py + 1)
		indicator:Show()
	end

	beginDrag = function(row)
		-- Reordering while a search narrows/flattens the rows shown would
		-- silently move the wrong aura, so just don't start a drag then --
		-- same reasoning as before the tree existed.
		if not row.id or table.getn(S.searchTerms) > 0 then return end
		local data = WeakestAurasDB.displays[row.id]
		if not data then return end
		-- Dragging a row that isn't already part of the current multi-selection
		-- collapses to a plain single-select first -- mirrors upstream
		-- WeakAurasDisplayButton's OnDragStart re-pick check (see
		-- bulk drag-move behavior) -- otherwise an
		-- unrelated selection would stay highlighted after only this one row
		-- actually moved. Skipped when row.id is already the sole selection,
		-- so an ordinary single-row drag doesn't pay for a redundant refresh.
		local partOfMultiSelection = S.isSelected(row.id) and table.getn(S.selection) > 1
		local alreadySoleSelection = table.getn(S.selection) == 1 and S.selection[1] == row.id
		if not partOfMultiSelection and not alreadySoleSelection then
			S.setSelection(row.id)
		end
		reorder.active = true
		reorder.fromId = row.id
		reorder.parentId = data.parent
		reorder.hoverGroupId = nil
		reorder.before = row.index
		-- The bucket this drag is confined to, read off the rendered list rather
		-- than recomputed from load state -- a child's bucket is its top-level
		-- ancestor's, which the row order already encodes.
		reorder.bucket = bucketAt(S.buildRows(), row.index)
		-- Bulk drag whenever the dragged row is (still) part of a >1
		-- selection after the collapse-check above -- everything past this
		-- point (trackDrag's hover targeting) is unchanged and shared with
		-- the single-item case; only endDrag branches on it.
		reorder.bulk = table.getn(S.selection) > 1
		-- Dim every row actually being dragged (the whole selection in bulk
		-- mode, just this row otherwise) so the drop target reads clearly
		-- underneath. Only rendered rows can be dimmed; that's fine, same
		-- "currently rendered only" scope selectRange already accepts.
		for i = 1, table.getn(S.rows) do
			local r = S.rows[i]
			if r.id and (r.id == row.id or (reorder.bulk and S.isSelected(r.id))) then
				r:SetAlpha(0.4)
			end
		end
		trackDrag()
	end

	endDrag = function()
		if not reorder.active then return end
		reorder.active = false
		indicator:Hide()
		groupHighlight:Hide()
		for i = 1, table.getn(S.rows) do S.rows[i]:SetAlpha(1) end

		if reorder.bulk then
			-- Top-down rendered order of the dragged selection, computed fresh
			-- (pre-move) -- this is what determines relative order at the drop
			-- site, same role as upstream's CompareButtonOrder sort before its
			-- own per-item Ungroup+Group loop.
			local ordered = {}
			local rowsNow = S.buildRows()
			for i = 1, table.getn(rowsNow) do
				if S.isSelected(rowsNow[i].id) then table.insert(ordered, rowsNow[i].id) end
			end
			local n = table.getn(ordered)
			if reorder.hoverGroupId then
				-- Append each in top-down order -- WA.AddChildToGroup with no
				-- index always lands at the end, so doing this forward
				-- naturally preserves relative order, same as the single-item
				-- drop-into-group-body case below.
				for i = 1, n do
					WA.AddChildToGroup(reorder.hoverGroupId, ordered[i])
				end
			elseif reorder.before then
				-- WA.ReorderAura already reparents a single id correctly
				-- regardless of where it currently lives, so a mixed-parent
				-- selection doesn't need special-casing here -- only the
				-- *order* of N individual moves needs care. Walking `ordered`
				-- back-to-front and re-deriving each numeric `before` from a
				-- stable anchor *id* (not a numeric index, which would go
				-- stale as soon as the first move mutates the list) means
				-- every later (earlier-in-order) item just inserts right
				-- before whichever item was placed immediately after it,
				-- chaining up to the original drop anchor with no index-math
				-- to keep in sync across iterations.
				local list = S.siblingList(reorder.parentId)
				local anchorId = list[reorder.before] -- nil = drop at list's end
				for i = n, 1, -1 do
					local idx = anchorId and S.indexOfId(list, anchorId)
					if not idx then idx = table.getn(list) + 1 end
					WA.ReorderAura(ordered[i], reorder.parentId, idx)
					anchorId = ordered[i]
				end
			end
		elseif reorder.fromId then
			if reorder.hoverGroupId then
				WA.AddChildToGroup(reorder.hoverGroupId, reorder.fromId)
			elseif reorder.before then
				WA.ReorderAura(reorder.fromId, reorder.parentId, reorder.before)
			end
		end

		reorder.fromId, reorder.parentId, reorder.before, reorder.hoverGroupId, reorder.bulk = nil, nil, nil, nil, nil
		S.refreshList()
	end

	-- No cursor-release event either -- poll so a release the row's own OnDragStop
	-- misses (e.g. outside the list) still ends the drag instead of leaving it stuck
	-- with the row dimmed until a reload.
	listBg:SetScript("OnUpdate", function()
		if reorder.active then
			trackDrag()
			if not IsMouseButtonDown("LeftButton") then endDrag() end
		end
	end)

	-- The aura list's right-click menu, repainted per opening from whichever item
	-- list the clicked row calls for (S.showBulkMenu and friends). Assigned onto
	-- S (not a local) so nested row closures reference it via table lookup
	-- instead of adding another upvalue to buildPanel's already-tight budget.
	S.menu = W.ContextMenu(panel)

	-- Row frames are created lazily and the pool only ever grows: a resize can
	-- ask for more rows than currently exist, but never needs to destroy any --
	-- refreshList just hides whatever's beyond the current visibleRows count.
	local rows = {}
	S.rows = rows
	S.ensureRow = function(i)
		if rows[i] then return rows[i] end
		local row = CreateFrame("Button", nil, listBg)
		row:SetHeight(S.ROW_H)
		-- Placed by refreshList, which accumulates each row's own height rather
		-- than multiplying by a fixed one. Both points there are TOP-anchored on
		-- purpose: a plain RIGHT point pins the frame's vertical *centre* as well
		-- as its right edge, which over-constrains a frame that already has a top
		-- and a height -- and the row's highlight/selection textures are
		-- SetAllPoints(row), so anything that moves that rect off the laid-out
		-- content shows up as a highlight not covering the whole row.
		row:SetPoint("TOPLEFT", 2, -2)

		local sel = row:CreateTexture(nil, "ARTWORK")
		sel:SetAllPoints(row)
		sel:SetTexture(0.9, 0.8, 0.2, 0.2)
		sel:Hide()
		row.sel = sel

		local hl = row:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints(row)
		hl:SetTexture(1, 1, 1, 0.1)

		-- Forced-visibility (fake state) toggle. The fill's colour shows whether
		-- this row is eye-pinned visible; for a group it reflects all/some/none
		-- of its leaves. Clicking cycles WA.ToggleForced, which cascades to a
		-- group's children -- so an inactive dynamic group can be fake-shown and
		-- its layout debugged. refreshList sets the fill colour.
		--
		-- 16px in the row's bottom-right corner, matching WA2's own view button.
		-- Sitting on the bottom line rather than centred is what lets the title
		-- above run the row's full width, which a 200px list needs more than
		-- WA2's much wider one does.
		local eye = CreateFrame("Button", nil, row)
		eye:SetWidth(16); eye:SetHeight(16)
		eye:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -3, 2)
		local eyeFill = eye:CreateTexture(nil, "ARTWORK")
		eyeFill:SetAllPoints(eye)
		-- The frames carry their own padding, cropped the same amount WA2 crops
		-- them by so the eye fills its 16px box.
		eyeFill:SetTexCoord(0.1, 0.9, 0.1, 0.9)
		eyeFill:SetTexture(W.EYE_TEXTURES .. "empty")
		eye.fill = eyeFill
		eye:SetScript("OnClick", function()
			if row.header then
				WA.ToggleForcedMany(S.bucketMembers(row.bucket))
				S.refreshList()
				return
			end
			if not row.id then return end
			WA.ToggleForced(row.id)
			S.refreshList()
		end)
		row.eye = eye

		-- The preview box is a frame, not the texture that paints it. Everything
		-- to its right (title, summary, badge, the expand toggle) anchors to the
		-- box, because the texture is hidden whenever a region type supplies a
		-- real thumbnail -- and a hidden region's rect stops being recomputed,
		-- dragging whatever hangs off it to a stale position.
		--
		-- This is also the row's one indent anchor: refreshList re-points it by
		-- depth and the whole row follows.
		local iconBox = CreateFrame("Frame", nil, row)
		iconBox:SetWidth(S.ROW_H - 4); iconBox:SetHeight(S.ROW_H - 4)
		iconBox:SetPoint("TOPLEFT", row, "TOPLEFT", 2, -2)
		row.iconBox = iconBox

		-- Expand/collapse toggle for a group row, on the summary line beside the
		-- preview rather than in a gutter of its own (WA2 anchors its own expand
		-- BOTTOM/LEFT off the icon the same way). A gutter costs every row 14px
		-- of title width to serve the few rows that are groups; indentation is
		-- the iconBox offset above instead.
		local expand = CreateFrame("Button", nil, row)
		expand:SetWidth(S.INDENT_W); expand:SetHeight(S.INDENT_W)
		expand:SetPoint("BOTTOMLEFT", iconBox, "BOTTOMRIGHT", 2, 0)
		local expandFs = expand:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		expandFs:SetPoint("CENTER", 0, 0)
		expand.label = expandFs
		expand:SetScript("OnClick", function()
			if row.header then
				S.bucketExpanded[row.bucket] = (S.bucketExpanded[row.bucket] == false) and true or false
				S.refreshList()
				return
			end
			if not row.id then return end
			S.expanded[row.id] = (S.expanded[row.id] == false) and true or false
			S.refreshList()
		end)
		row.expand = expand

		local icon = iconBox:CreateTexture(nil, "ARTWORK")
		icon:SetAllPoints(iconBox)
		row.icon = icon

		-- Ungroup, left of the preview on a child row (WA2 puts its own there,
		-- between the indent and the icon). A glyph rather than upstream's
		-- MoneyFrame arrow: no addon on this client uses that texture, so it is
		-- unconfirmed art, and the eye already cost us a round of vendoring.
		local ungroup = CreateFrame("Button", nil, row)
		ungroup:SetWidth(S.UNGROUP_W); ungroup:SetHeight(S.UNGROUP_W)
		local ungroupFs = ungroup:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		ungroupFs:SetPoint("CENTER", 0, 0)
		ungroupFs:SetText("<")
		local ungroupHl = ungroup:CreateTexture(nil, "HIGHLIGHT")
		ungroupHl:SetAllPoints(ungroup)
		ungroupHl:SetTexture(1, 1, 1, 0.2)
		ungroup:SetScript("OnEnter", function()
			GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
			GameTooltip:SetText("Ungroup", 1, 1, 1)
			GameTooltip:AddLine("Move this aura out of its group, back to the top level.", 0.8, 0.8, 0.8, true)
			GameTooltip:Show()
		end)
		ungroup:SetScript("OnLeave", function() GameTooltip:Hide() end)
		ungroup:SetScript("OnClick", function()
			if not row.id then return end
			WA.RemoveChildFromGroup(row.id)
			S.refreshList()
		end)
		ungroup:Hide()
		row.ungroup = ungroup

		-- Status strip: keyed, prioritised indicators on the summary line's right,
		-- just inside the eye. Mirrors WA2's DisplayButton statusIcons; load state
		-- is its only occupant so far, which is why the priorities are banded
		-- (load 1-3, warnings 5+) rather than a bare ordering.
		--
		-- The icons come from a pool shared by *every* row, not one per row: rows
		-- are pooled by slot and rebound on each scroll tick, so a per-row pool
		-- would grow to (rows x statuses) frames and strand nearly all of them.
		local strip = CreateFrame("Frame", nil, row)
		strip:SetHeight(S.STATUS_SIZE)
		strip:SetWidth(1)
		strip:SetPoint("BOTTOMRIGHT", eye, "BOTTOMLEFT", -2, 0)
		row.statusStrip = strip
		row.statuses = {}

		-- Marks every entry stale. layoutStatuses releases the ones a repaint
		-- didn't re-set, which is what keeps a status from riding a pooled row
		-- into the next aura it gets bound to.
		row.beginStatuses = function()
			for _, entry in pairs(row.statuses) do entry.stale = true end
		end

		row.setStatus = function(key, prio, tex, title, desc, onClick)
			local entry = row.statuses[key]
			if not entry then
				entry = { icon = S.acquireStatusIcon(strip) }
				row.statuses[key] = entry
			end
			entry.stale = nil
			entry.prio = prio or 5
			local icon = entry.icon
			icon.tipTitle, icon.tipDesc, icon.onClick = title, desc, onClick
			icon.fill:SetTexture(tex[1], tex[2], tex[3], tex[4] or 1)
		end

		row.clearStatus = function(key)
			local entry = row.statuses[key]
			if not entry then return end
			S.releaseStatusIcon(entry.icon)
			row.statuses[key] = nil
		end

		row.clearStatuses = function()
			for key in pairs(row.statuses) do row.clearStatus(key) end
		end

		-- Releases what this repaint left stale, then lays the survivors out
		-- left-to-right by ascending priority and sizes the strip to them -- the
		-- summary line's right edge is pinned to the strip, so it truncates
		-- before the icons rather than running underneath them.
		row.layoutStatuses = function()
			local live = {}
			for key, entry in pairs(row.statuses) do
				if entry.stale then
					S.releaseStatusIcon(entry.icon)
					row.statuses[key] = nil
				else
					table.insert(live, entry)
				end
			end
			table.sort(live, function(a, b) return a.prio < b.prio end)
			local n = table.getn(live)
			for i = 1, n do
				local icon = live[i].icon
				icon:ClearAllPoints()
				icon:SetPoint("BOTTOMLEFT", strip, "BOTTOMLEFT", (i - 1) * (S.STATUS_SIZE + 2), 0)
				icon:Show()
			end
			-- Never zero: a zero-width frame is an anchor the summary can't be
			-- pinned against meaningfully.
			strip:SetWidth(n > 0 and (n * (S.STATUS_SIZE + 2) - 2) or 1)
		end

		-- The title spans to the row's own right edge; only the summary line
		-- below stops short of the eye.
		-- Each line pins one horizontal edge on its *own* vertical edge (TOP with
		-- TOP, BOTTOM with BOTTOM). A bare RIGHT point would pin the string's
		-- vertical centre too, stretching it against the point that already fixes
		-- its top or bottom.
		local rtitle = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		rtitle:SetPoint("TOPLEFT", iconBox, "TOPRIGHT", 4, 0)
		rtitle:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -2)
		rtitle:SetJustifyH("LEFT")
		row.title = rtitle

		-- Rename box, overlaying the title. Built with the row and hidden until a
		-- double-click on it; the row pool is small, so one box per slot costs
		-- little and avoids handing a shared box between rows.
		local rename = LibWidgets.NewTextBox(row, { height = 18 })
		rename:SetPoint("TOPLEFT", iconBox, "TOPRIGHT", 2, 0)
		rename:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -1)
		rename:Hide()
		rename:SetScript("OnEnterPressed", function() S.commitRename() end)
		rename:SetScript("OnEscapePressed", function() S.closeRename() end)
		rename:SetScript("OnEditFocusLost", function() S.closeRename() end)
		row.rename = rename

		local sub = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		sub:SetPoint("BOTTOMLEFT", iconBox, "BOTTOMRIGHT", 4, 0)
		sub:SetPoint("BOTTOMRIGHT", strip, "BOTTOMLEFT", -4, 0)
		sub:SetJustifyH("LEFT")
		sub:SetTextColor(0.6, 0.6, 0.6)
		row.sub = sub

		-- Ctrl-click toggles (a group expands to its leaf descendants -- see
		-- S.toggleSelection/S.leafDescendants), shift-click range-selects
		-- leaves only, plain left click replaces the whole selection with
		-- whatever was clicked (leaf or group). Both modifiers still force a
		-- plain single-select instead whenever the *current* sole selection
		-- is a group, matching upstream WeakAuras2's "wasGroup" fallback
		-- (PickDisplayMultiple): a group can be the sole single-selection
		-- (needed to edit its own border/anchor/scale fields), but its literal
		-- id can never sit inside a multi-member S.selection. Without this
		-- check, ctrl/shift-clicking anything while a group was the last
		-- plain-clicked row would silently mix that group id in. Shift-click
		-- additionally still refuses a group as its own target (unextended
		-- range-selecting *through* a group boundary is a
		-- harder, more ambiguous problem than a ctrl-click toggle, and
		-- upstream doesn't attempt it either even for its plain leaf-only
		-- case). Right-click opens the bulk menu when the clicked row is
		-- already part of an active multi-selection, and the per-aura menu
		-- otherwise -- picking that row first, the same rule upstream uses.
		-- Note a group row itself never reads as "already selected" here even
		-- when every one of its children is, since S.isSelected checks literal
		-- membership; right-click one of the highlighted child rows instead.
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		row:SetScript("OnClick", function()
			if row.header then
				-- The header row's body is a big easy target for the same toggle
				-- the expand button drives -- it must never fall through to the
				-- selection logic below, which keys off row.id.
				S.bucketExpanded[row.bucket] = (S.bucketExpanded[row.bucket] == false) and true or false
				S.refreshList()
				return
			end
			if not row.id then return end
			-- Double-click opens the rename box. 1.12 has no OnDoubleClick, so the
			-- gap between clicks is measured here -- keyed by the *id* as well as
			-- the time, or two quick clicks either side of a scroll would count as
			-- a double-click on whatever aura the slot ended up holding.
			local now = GetTime()
			if arg1 ~= "RightButton" and not IsControlKeyDown() and not IsShiftKeyDown()
				and row.lastClickId == row.id and (now - (row.lastClickAt or 0)) < 0.4 then
				row.lastClickAt = nil
				S.beginRename(row)
				return
			end
			row.lastClickId, row.lastClickAt = row.id, now
			if arg1 == "RightButton" then
				local id = row.id
				if table.getn(S.selection) > 1 and S.isSelected(id) then
					S.showBulkMenu(row)
				else
					S.setSelection(id)
					S.showAuraMenu(id, row)
				end
				return
			end
			local data = WeakestAurasDB.displays[row.id]
			local isGroup = data and WA.IsGroup(data)
			local soleId = S.primaryId()
			local soleData = soleId and WeakestAurasDB.displays[soleId]
			local soleIsGroup = soleData and WA.IsGroup(soleData)
			if IsControlKeyDown() and not soleIsGroup then
				S.toggleSelection(row.id)
			-- Shift means two things, and an open chat editbox is what tells them
			-- apart: upstream's own rule, and the only signal available here since
			-- this client has no GetCurrentKeyBoardFocus.
			elseif IsShiftKeyDown() and ChatFrameEditBox and ChatFrameEditBox:IsVisible() then
				WA.Comm.LinkAura(row.id)
			elseif IsShiftKeyDown() and not isGroup and not soleIsGroup then
				S.selectRange(row.id)
			else
				S.setSelection(row.id)
			end
		end)
		row:RegisterForDrag("LeftButton")
		row:SetScript("OnDragStart", function() beginDrag(row) end)
		row:SetScript("OnDragStop", function() endDrag() end)
		rows[i] = row
		return row
	end

	S.updateVisibleRows = function()
		-- Measured from the panel, not from listBg: the box is sized to a whole
		-- number of rows below, so reading its own height back would feed each
		-- snap into the next one.
		local avail = (panel:GetHeight() or 0) - (36 + S.SEARCH_H + S.TOOLBAR_H) - S.BOTTOM_RESERVED
		-- The room the list may use. The box itself is sized by refreshList to
		-- the rows it actually laid out -- with two row heights in play, the only
		-- way the border ends flush under the last one is to measure the paint
		-- rather than predict it.
		S.listAvail = avail
		local n = math.floor((avail - 4) / S.ROW_H)
		if n < 1 then n = 1 end
		S.visibleRows = n
	end

	-- Toolbar strip above the search box, mirroring WA2's own: icon plus caption,
	-- in two groups as upstream splits them -- what *creates* an aura on the left,
	-- the mode toggles pushed to the right edge, reading their lit state back from
	-- WA.Mover, which owns the flags and persists them. Each button sizes itself
	-- to its caption, so the two groups re-flow from their own anchors.
	--
	-- Undo/Redo are deliberately absent: upstream backs them with a TimeMachine
	-- edit-history subsystem that has no counterpart here.
	local toolbar = CreateFrame("Frame", nil, panel)
	toolbar:SetPoint("TOPLEFT", 12, -36)
	-- Spans the whole window, not just the list column: the toolbar acts on the
	-- window rather than on the list, and WA2's own runs the full width too.
	toolbar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -14, -36)
	toolbar:SetHeight(22)

	-- "New" opens the New pane, which offers every registered region type with a
	-- preview of each.
	local newBtn = W.toolbarButton(toolbar, "Interface\\Buttons\\UI-PlusButton-Up", "New aura",
		nil, "New Aura")
	newBtn:SetPoint("LEFT", 0, 0)

	local importBtn = W.toolbarButton(toolbar, "Interface\\Buttons\\UI-GuildButton-PublicNote-Up",
		"Import from string", function() S.openImport() end, "Import")
	importBtn:SetPoint("LEFT", newBtn, "RIGHT", 4, 0)

	local lockBtn = W.toolbarButton(toolbar, "Interface\\Icons\\INV_Misc_Key_03", "Lock positions",
		nil, "Lock Positions")
	lockBtn.tipDesc = "Stops the in-world mover from dragging or resizing an aura."
	lockBtn.setToggled(WA.Mover.locked)
	lockBtn:SetScript("OnClick", function()
		WA.Mover.SetLocked(not WA.Mover.locked)
		lockBtn.setToggled(WA.Mover.locked)
	end)

	local magnetBtn = W.toolbarButton(toolbar, "Interface\\Icons\\Spell_Frost_FrostArmor",
		"Magnetically align", nil, "Magnetically Align")
	magnetBtn:SetPoint("RIGHT", toolbar, "RIGHT", 0, 0)
	lockBtn:SetPoint("RIGHT", magnetBtn, "LEFT", -4, 0)
	magnetBtn.tipDesc = "Snaps a dragged aura's edges to nearby auras. Hold Shift during a drag to suppress it."
	magnetBtn.setToggled(WA.Mover.magnetism)
	magnetBtn:SetScript("OnClick", function()
		WA.Mover.SetMagnetism(not WA.Mover.magnetism)
		magnetBtn.setToggled(WA.Mover.magnetism)
	end)

	-- Lit unless explicitly switched off, so an install that predates the setting
	-- gets the notice. It silences only the chat line: the version we broadcast is
	-- what tells everyone else, and withholding it helps nobody.
	local notifyBtn = W.toolbarButton(toolbar, "Interface\\Icons\\INV_Misc_Note_01",
		"Update notices", nil, "Update Notices")
	notifyBtn:SetPoint("RIGHT", lockBtn, "LEFT", -4, 0)
	notifyBtn.tipDesc = "Says once per session when someone in your guild or group is running a newer release."
	notifyBtn.setToggled(WA.Options().updateNotify ~= false)
	notifyBtn:SetScript("OnClick", function()
		local opts = WA.Options()
		if opts.updateNotify == false then opts.updateNotify = nil else opts.updateNotify = false end
		notifyBtn.setToggled(opts.updateNotify ~= false)
	end)
	S.updateNotifyBtn = notifyBtn

	newBtn:SetScript("OnClick", function()
		searchBox:ClearFocus()
		S.openNewPane()
	end)

	-- Right: tab strip + content
	local tabButtons = {}
	S.tabButtons = tabButtons
	local prevTab
	for i = 1, table.getn(S.TAB_DEFS) do
		local def = S.TAB_DEFS[i]
		local tb = W.toggleButton(panel, def.name, function() S.selectTab(def.key) end)
		tb.key = def.key
		tb:SetWidth(80)
		if prevTab then
			tb:SetPoint("LEFT", prevTab, "RIGHT", 4, 0)
		else
			tb:SetPoint("BOTTOMLEFT", contentScroll, "TOPLEFT", 0, 6)
		end
		prevTab = tb
		tabButtons[i] = tb
	end

	-- The content pane scrolls: a region's Display tab (including its subtext
	-- editors) can run taller than the window. Built above, where its width has
	-- to be established before the list can anchor its right edge to it. The
	-- painted frame (S.content) is the scroll child, sized to its content by
	-- paintContent so the scroll range is correct.
	local content = contentScroll.content
	S.content = content

	-- Recompute the row pool whenever the panel's live size actually changes
	-- (grip drag or otherwise). Only the list changes width now, so the content
	-- pane needs nothing re-fitted here.
	panel:SetScript("OnSizeChanged", function()
		S.refreshList()
	end)

	S.activeTab = "info"
	tabButtons[1].setSelected(true)
end

function WeakestAuras.ToggleOptions()
	-- Reported here rather than at file load (chat output during load is
	-- unreliable on this client) and only once, on the first open: without it a
	-- displaced LibWidgets shows up as an unexplained nil call mid-repaint.
	if not S.libWarned then
		S.libWarned = true
		local problem = W.LibWidgetsProblem()
		if problem then
			DEFAULT_CHAT_FRAME:AddMessage("|cffff4040WeakestAuras:|r " .. problem)
		end
	end
	if not S.panel then buildPanel() end
	if S.panel:IsShown() then
		S.panel:Hide()
	else
		S.panel:Show()
		-- Mute all live auras (WA2 config behavior) before revealing the current
		-- selection, so opening /wa starts from a blank board and shows only what
		-- you're editing.
		WA.SetOptionsOpen(true)
		S.refreshList()
		S.updateTabAvailability()
		S.refreshTabContent()
		S.applySelectionChange()
	end
end

-- Let option `set` callbacks (in Regions.lua/Triggers.lua) re-render the tab
-- after a reveal-toggle changes which fields apply. Wrapped so it late-binds
-- S.refreshTabContent and no-ops safely if the window was never built.
WA.RefreshOptions = function()
	if S.panel and S.panel:IsShown() then S.refreshTabContent() end
end

-- Cheaper sibling of WA.RefreshOptions for setters that change a display's
-- name/icon (spell fields, manual icon) but don't need the whole tab rebuilt
-- (which would drop editbox focus mid-typing) -- just the list row's icon/
-- summary text.
WA.RefreshList = function()
	if S.panel and S.panel:IsShown() then S.refreshList() end
end

-- Slash entry points for the import/export dialog (Debug.lua's /wa
-- export|import). buildPanel is ensured first so a successful import's
-- S.setSelection has the (possibly still-hidden) list frames to refresh.
WA.ShowExport = function(id)
	if not S.panel then buildPanel() end
	id = (id and id ~= "" and id) or S.primaryId()
	if not id then
		WA.Debug.Log("[export] usage: /wa export <aura id> (or select an aura first)")
		return
	end
	S.openExport(id)
end
WA.ShowImport = function()
	if not S.panel then buildPanel() end
	S.openImport()
end

SLASH_WEAKESTAURAS1 = "/weakestauras"
SLASH_WEAKESTAURAS2 = "/wa"
SlashCmdList["WEAKESTAURAS"] = function(msg)
	if msg and msg ~= "" then
		WA.Debug.HandleSlash(msg)
	else
		WeakestAuras.ToggleOptions()
	end
end

-- Runs only once every RegisterRegionType/RegisterTriggerType/
-- RegisterTriggerSystem call has happened (this is the last file in the .toc)
-- AND WeakestAurasDB has actually been populated from the SavedVariables file.
-- The latter is NOT guaranteed yet at plain top-level file-load time on this
-- client -- confirmed via in-game tracing (2026-07): WeakestAurasDB.displays
-- read back 0 entries here despite saved auras existing, meaning every
-- session silently started with nothing compiled/loaded until the user
-- touched an aura through the UI (which calls WA.Add directly). ADDON_LOADED
-- for this addon fires only after this file (the last one in the .toc) has
-- already finished executing, so waiting for it here is safe -- it cannot
-- have already fired by the time this registers.
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
-- The client-side spell cache that name->ID resolution reads (C_Spell.GetSpellInfo
-- by name, via WA.ResolveSpellID) is still cold at ADDON_LOADED, so any trigger
-- keyed by spell name compiles to a 0 id / never starts its watcher on a fresh
-- login (only re-typing the name or a later /reload fixes it). Recompile once the
-- spellbook populates and on later talent/spell changes -- same two events
-- DoiteAuras rebuilds its own spell caches on.
initFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
initFrame:RegisterEvent("SPELLS_CHANGED")
-- Item data arrives asynchronously for the same reason: GetItemInfo (via
-- WA.ResolveItemID) answers nil for any item the client has not seen this
-- session, and the resolved id is baked into the generated source at compile
-- time, so an item trigger built against an uncached item stays dead until
-- something recompiles it. ClassicAPI fires this once the server answers.
initFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
local didInit = false
local recompilePending = false
local function doRecompile()
	recompilePending = false
	if didInit then WeakestAuras.AddAllDisplays() end
end
initFrame:SetScript("OnEvent", function()
	if event == "ADDON_LOADED" then
		if arg1 ~= "WeakestAuras" then return end
		initFrame:UnregisterEvent("ADDON_LOADED")
		WeakestAuras.NormalizeAll()
		WeakestAuras.AddAllDisplays()
		didInit = true
		return
	end
	-- Debounced: the login burst of PLAYER_ENTERING_WORLD + SPELLS_CHANGED, and the
	-- run of GET_ITEM_INFO_RECEIVED a bagful of uncached items produces, coalesce
	-- into a single recompile.
	if not didInit or recompilePending then return end
	recompilePending = true
	C_Timer.After(1, doRecompile)
end)
