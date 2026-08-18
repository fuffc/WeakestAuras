-- WeakestAuras -- region types (the visual side of a display). Each type
-- registers defaults, options, create/modify methods, and a properties registry
-- through WeakestAuras.RegisterRegionType. Mirrors WA2's region types (§6).
-- Upstream section refs (§N) point at design/architecture/weakauras2-reference.md
--
-- modify defines setter methods and applies saved config through them, so
-- conditions use the same path to override values. The region consumes a state
-- through region:Update(), which reads region.state and drives the shared
-- progress resolver. Groups are containers holding other auras through
-- controlledChildren; dynamic groups additionally arrange visible children.

if WeakestAuras.disabled then return end

local WA = WeakestAuras

-- Group border thickness. A WoW SetBackdrop edge is painted *inward* from the
-- frame boundary, so a border drawn on the exact content box would sit entirely
-- inside the children. GROUP_BORDER_PAD (half the edge) pushes the border frame
-- outward so the edge straddles the content boundary instead -- the usual
-- wraps-the-content look. The cached blx/bly/trx/try stay the tight content box.
local GROUP_BORDER_EDGE = 12
local GROUP_BORDER_PAD = GROUP_BORDER_EDGE / 2

-- One child's bounding box in its group's CENTER-relative coordinate space,
-- computed purely from data -- xOffset/yOffset is the child's anchor position,
-- selfPoint says which of the child's own corners sits there (WA2's Group.lua
-- getRect). No live frame coords, so it's stable regardless of layout timing.
local function childRect(cdata)
	local blx = cdata.xOffset or 0
	local bly = cdata.yOffset or 0
	local w, h = cdata.width, cdata.height
	if not w or not h then return blx, bly, blx, bly end
	local sp = cdata.selfPoint or "CENTER"
	local trx, try
	if string.find(sp, "LEFT") then trx = blx + w
	elseif string.find(sp, "RIGHT") then trx = blx; blx = blx - w
	else blx = blx - w / 2; trx = blx + w end
	if string.find(sp, "BOTTOM") then try = bly + h
	elseif string.find(sp, "TOP") then try = bly; bly = bly - h
	else bly = bly - h / 2; try = bly + h end
	return blx, bly, trx, try
end

-- Draws the group's border around the cached box (blx/bly/trx/try, in CENTER-
-- True if any leaf under this group is currently shown (a live clone with
-- toShow). The group frame is always shown (a transparent container children
-- parent to), so its *border* is what tracks child visibility -- otherwise an
-- empty/muted group would paint a box around nothing (WA2's UpdateBorder
-- childVisible check).
local function groupHasVisibleChild(data)
	local kids = data.controlledChildren or {}
	for i = 1, table.getn(kids) do
		local id = kids[i]
		local shown = false
		WA.ForEachClone(id, function(frame)
			if frame.toShow and not frame.limited then shown = true end
		end)
		if shown then return true end
		local cd = WeakestAurasDB.displays[id]
		if cd and WA.IsGroup(cd) and groupHasVisibleChild(cd) then return true end
	end
	return false
end

-- relative coords) and sizes the frame to it. Shared by the static and dynamic
-- paths, which each fill the box differently before calling this.
local function drawGroupBox(region, data, blx, bly, trx, try)
	region.blx, region.bly, region.trx, region.try = blx, bly, trx, try
	region:SetWidth(math.max(trx - blx, 8))
	region:SetHeight(math.max(try - bly, 8))
	local border = region.border
	border:ClearAllPoints()
	border:SetPoint("BOTTOMLEFT", region, "CENTER", blx - GROUP_BORDER_PAD, bly - GROUP_BORDER_PAD)
	border:SetPoint("TOPRIGHT", region, "CENTER", trx + GROUP_BORDER_PAD, try + GROUP_BORDER_PAD)
	local bc = data.borderColor or { 0, 0, 0, 1 }
	border:SetBackdropBorderColor(bc[1], bc[2], bc[3], bc[4])
	if data.border and groupHasVisibleChild(data) then border:Show() else border:Hide() end
end

-- Static group: the box is the union of children's data-defined rects (each
-- child keeps its own anchor/offset, so this is stable without live coords).
local function applyGroupBounds(region, data)
	local blx, bly, trx, try = 0, 0, 0, 0
	local kids = data.controlledChildren or {}
	for i = 1, table.getn(kids) do
		local cd = WeakestAurasDB.displays[kids[i]]
		if cd then
			local a, b, c, d = childRect(cd)
			if a < blx then blx = a end
			if b < bly then bly = b end
			if c > trx then trx = c end
			if d > try then try = d end
		end
	end
	drawGroupBox(region, data, blx, bly, trx, try)
end

-- Deterministic clone ordering: the comparator algebra a dynamicgroup's `sort`
-- and a `customSort` are built from (WA2 DynamicGroup.lua's sort helpers,
-- ported onto WA under upstream's exact names so a user's customSort composes
-- the way upstream's own documentation shows). A comparator takes two values
-- and answers true/false/**nil** -- nil means "no opinion". That is what lets
-- WA.ComposeSorts fall through to the next comparator, and what stops
-- WA.InvertSort turning "no opinion" into an opinion. Every comparator here is
-- called with exactly two values, so `function(a, b)` replaces upstream's
-- `function(...)`.
function WA.InvertSort(sortFunc)
	if type(sortFunc) ~= "function" then
		error("InvertSort requires a function to invert.")
	end
	return function(a, b)
		local result = sortFunc(a, b)
		if result == nil then return nil end
		return not result
	end
end

-- Fixed parameters, not a vararg: this client has no `...` expression. Six is
-- the cap because nothing in this addon composes more than that; nil slots
-- are skipped without assuming they're contiguous.
function WA.ComposeSorts(f1, f2, f3, f4, f5, f6)
	local sorts = {}
	if type(f1) == "function" then table.insert(sorts, f1) end
	if type(f2) == "function" then table.insert(sorts, f2) end
	if type(f3) == "function" then table.insert(sorts, f3) end
	if type(f4) == "function" then table.insert(sorts, f4) end
	if type(f5) == "function" then table.insert(sorts, f5) end
	if type(f6) == "function" then table.insert(sorts, f6) end
	return function(a, b)
		for i = 1, table.getn(sorts) do
			local result = sorts[i](a, b)
			if result ~= nil then return result end
		end
		return nil
	end
end

function WA.SortNilLast(a, b)
	if a == nil and b == nil then
		return false
	elseif a == nil then
		return false
	elseif b == nil then
		return true
	else
		return nil
	end
end

local sortNilFirst = WA.InvertSort(WA.SortNilLast)
function WA.SortNilFirst(a, b)
	if a == nil and b == nil then
		return false
	else
		return sortNilFirst(a, b)
	end
end

function WA.SortGreaterLast(a, b)
	if a == b then return nil end
	if type(a) ~= type(b) then return type(a) > type(b) end
	if type(a) == "number" then
		if math.abs(b - a) < 0.001 then return nil end
		return a < b
	elseif type(a) == "string" then
		return a < b
	else
		return nil
	end
end

WA.SortGreaterFirst = WA.InvertSort(WA.SortGreaterLast)

function WA.SortRegionData(path, sortFunc)
	if type(path) ~= "table" then path = {} end
	if type(sortFunc) ~= "function" then sortFunc = WA.SortGreaterLast end
	return function(a, b)
		local aValue, bValue = a, b
		for i = 1, table.getn(path) do
			local key = path[i]
			if type(aValue) ~= "table" then return nil end
			if type(bValue) ~= "table" then return nil end
			aValue, bValue = aValue[key], bValue[key]
		end
		return sortFunc(aValue, bValue)
	end
end

function WA.SortAscending(path)
	return WA.SortRegionData(path, WA.ComposeSorts(WA.SortNilFirst, WA.SortGreaterLast))
end

-- Composed rather than upstream's `InvertSort(SortAscending(path))`, and this is
-- the one place the port deliberately parts company with it. Both nil-partition
-- helpers answer *false* for two nils on purpose -- "no swap", which is what
-- keeps equal entries stable -- but inverting that turns it into *true*, so
-- upstream's descending swaps two entries with no sort key on every pass and
-- never reaches the tiebreaker behind it. Ordering is identical for every other
-- pair; only the degenerate one is fixed.
function WA.SortDescending(path)
	return WA.SortRegionData(path, WA.ComposeSorts(WA.SortNilLast, WA.SortGreaterFirst))
end

-- Not table.sort: a comparator here may answer nil (no opinion), and
-- customSort is user code that can answer inconsistently -- 5.0's table.sort
-- raises "invalid order function for sorting" on either, where an insertion
-- pass just leaves the pair where it found it. That's the point: a pair the
-- comparator has no opinion about keeps the order the list arrived in.
local function stableSort(list, cmp)
	if not cmp then return end
	for i = 2, table.getn(list) do
		local item = list[i]
		local j = i
		while j > 1 and cmp(item, list[j - 1]) do
			list[j] = list[j - 1]
			j = j - 1
		end
		list[j] = item
	end
end

-- The currently-shown child region frames of a dynamicgroup, in controlledChildren
-- order, one entry per visible clone. Each carries its size (from data, falling
-- back to the live frame) plus the fields WA2's regionData carries (id, cloneId,
-- dataIndex, region, data) so a customSort can read them.
--
-- WA.ForEachClone walks entry.byClone with pairs(), a hash whose iteration order
-- can differ between two passes over the same set -- without this stableSort, a
-- clone the eventual sort key ties on would take whatever position the hash gave
-- it and drift between layouts. (dataIndex, cloneSeq) is the deterministic base
-- order every sort mode composes on top of: dataIndex groups by
-- controlledChildren order, cloneSeq (stamped on the frame at acquisition)
-- breaks ties within one display, base clone first.
--
-- Built once: this runs on every state update of every child, and each
-- SortAscending is six closures and two tables.
local baseOrder = WA.ComposeSorts(WA.SortAscending({ "dataIndex" }), WA.SortAscending({ "cloneSeq" }))

local function activeChildren(data)
	local list = {}
	local kids = data.controlledChildren or {}
	for i = 1, table.getn(kids) do
		local childId = kids[i]
		local dataIndex = i
		local cd = WeakestAurasDB.displays[childId]
		if cd then
			WA.ForEachClone(childId, function(frame, cloneId)
				if frame.toShow or frame.animatingFinish then
					local w = cd.width or (frame:GetWidth() or 0)
					local h = cd.height or (frame:GetHeight() or 0)
					table.insert(list, {
						region = frame, data = cd, id = childId, cloneId = cloneId,
						dataIndex = dataIndex, cloneSeq = frame.cloneSeq or 0,
						width = w, height = h,
					})
				end
			end)
		end
	end
	stableSort(list, baseOrder)
	return list
end

-- data.sort's comparator, one per mode. Each entry returns a comparator (or
-- nil for "no opinion", i.e. leave activeChildren's deterministic base order).
local sorters = {
	none = function(data)
		return WA.ComposeSorts(
			WA.SortAscending({ "dataIndex" }),
			WA.SortAscending({ "region", "state", "index" })
		)
	end,
	ascending = function(data)
		return WA.ComposeSorts(
			WA.SortAscending({ "region", "state", "expirationTime" }),
			WA.SortAscending({ "dataIndex" })
		)
	end,
	descending = function(data)
		return WA.ComposeSorts(
			WA.SortDescending({ "region", "state", "expirationTime" }),
			WA.SortAscending({ "dataIndex" })
		)
	end,
	hybrid = function(data)
		local sortHybridTable = data.sortHybridTable or {}
		local hybridSortAscending = data.hybridSortMode == "ascending"
		local hybridFirst = data.hybridPosition == "hybridFirst"
		local function sortHybridStatus(a, b)
			if not b then return true end
			if not a then return false end
			local aIsHybrid = sortHybridTable[a.id]
			local bIsHybrid = sortHybridTable[b.id]
			if aIsHybrid and not bIsHybrid then
				return hybridFirst
			elseif bIsHybrid and not aIsHybrid then
				return not hybridFirst
			else
				return nil
			end
		end
		local sortExpirationTime
		if hybridSortAscending then
			sortExpirationTime = WA.SortAscending({ "region", "state", "expirationTime" })
		else
			sortExpirationTime = WA.SortDescending({ "region", "state", "expirationTime" })
		end
		return WA.ComposeSorts(sortHybridStatus, sortExpirationTime, WA.SortAscending({ "dataIndex" }))
	end,
	custom = function(data)
		-- Blank is not broken: an aura arriving through import has `sort =
		-- "custom"` and an empty editor, and compiling that would report a
		-- failure on every WA.Add. Same whitespace test the generic trigger's
		-- optional code fields use.
		local source = data.customSort
		if not source or not string.find(source, "%S") then return nil end
		local errTag = tostring(data.id) .. ": custom sort"
		local sortFunc = WA.LoadFunction(source, errTag)
		if not sortFunc then return nil end
		-- A comparator is the only user-code site this addon calls O(n^2) times
		-- per pass, and the pass repeats on every state update -- so one that
		-- throws would bury its own first report under thousands of copies and
		-- take the chat frame with it. It is consulted until it throws and not
		-- again for the rest of that pass: exactly one report, and the pairs it
		-- never saw keep the deterministic base order. `WA.safecall` stays
		-- honest for every other site rather than growing a dedup nobody else
		-- needs.
		local broken = false
		return function(a, b)
			if broken then return nil end
			local ok, result = WA.RunAuraFunc(data.id, errTag, sortFunc, a, b)
			if ok then return result end
			broken = true
			return nil
		end, function() broken = false end
	end,
}

-- Returns the comparator, plus (custom sort only) the per-pass reset that
-- re-arms its one-report budget.
local function createSortFunc(data)
	local sorter = sorters[data.sort] or sorters.none
	return sorter(data)
end

-- Upstream's staggerCoefficient verbatim: which end of a staggered run sits at
-- offset 0. Upstream's alignment argument is direction-dependent (LEFT/RIGHT
-- name an edge of whichever axis is perpendicular to that grow); reused below
-- against our flat LEFT/CENTER/RIGHT align, which only carries meaning for the
-- vertical grows.
local function staggerCoefficient(align, stagger)
	if align == "LEFT" then
		if stagger < 0 then return 1 else return 0 end
	elseif align == "RIGHT" then
		if stagger > 0 then return 1 else return 0 end
	end
	return 0.5
end

-- Per-unit anchoring (WA2 DynamicGroup.lua's `anchorers`): each clone is placed
-- against the frame showing *its own* unit rather than against the group, so one
-- dynamic group can put an icon on every nameplate or party frame at once. The
-- clone's unit comes from the producer's `state.unit` -- Stage 10c's families
-- write it, and a clone with no unit has nothing to anchor to.
--
-- Upstream anchors a pooled control point per unit; ours anchors the child
-- region itself, which is why there is no control-point pool here. The child
-- stays parented to the group (scale, strata and dragging still cascade) and
-- only its SetPoint target changes -- an anchor tracks a moving nameplate by
-- itself, so a plate sliding across the screen costs nothing per frame.
local function regionUnit(entry)
	local state = entry.region and entry.region.state
	if not state then return nil, nil end
	return state.unit or state.unitId, state.guid
end

local anchorers = {
	NAMEPLATE = function(region, data, entry)
		local unit, guid = regionUnit(entry)
		return unit and WA.GetUnitNameplate and WA.GetUnitNameplate(unit, guid) or nil
	end,
	UNITFRAME = function(region, data, entry)
		local unit = regionUnit(entry)
		return unit and WA.GetUnitFrame and WA.GetUnitFrame(unit) or nil
	end,
}

-- The custom anchorer keeps upstream's signature -- function(frames,
-- activeRegions), filling frames[frame] with the regionDatas that belong to it
-- -- so an upstream custom anchor runs here unchanged.
local function customAnchorFrames(region, data, list)
	local source = data.customAnchorPerUnit
	if not source or not string.find(source, "%S") then return nil end
	local errTag = tostring(data.id) .. ": custom anchor"
	if not region.anchorFuncBuilt then
		region.anchorFunc = WA.LoadFunction(source, errTag)
		region.anchorFuncBuilt = true
	end
	if not region.anchorFunc then return nil end
	local frames = {}
	local ok = WA.RunAuraFunc(data.id, errTag, region.anchorFunc, frames, list)
	if not ok then
		-- The layout re-runs on every state update of every child, so an anchor
		-- that throws would report on every one. It is dropped for the rest of
		-- this compile instead: one report, and the next WA.Add -- which any edit
		-- to the aura is -- hands it back.
		region.anchorFunc = nil
		return nil
	end
	return frames
end

-- Groups the ordered child list by the frame each clone anchors to. Returns an
-- array of { frame, entries }, with `frame` nil for the run the group itself
-- anchors. Partition order follows the first entry of each run, so the layout
-- does not inherit the iteration order of a hash -- the same reason
-- activeChildren sorts before anything reads it.
local function anchorPartitions(region, data, list)
	local total = table.getn(list)
	if not data.useAnchorPerUnit then return { { entries = list } } end

	local buckets, order = {}, {}
	local function bucketFor(frame)
		local bucket = buckets[frame]
		if not bucket then
			bucket = { frame = frame, entries = {} }
			buckets[frame] = bucket
			table.insert(order, bucket)
		end
		return bucket
	end

	local mode = data.anchorPerUnit or "NAMEPLATE"
	if mode == "CUSTOM" then
		local frames = customAnchorFrames(region, data, list)
		if not frames then return { { entries = list } } end
		-- The custom anchorer hands back a frame-keyed hash, so the runs come out
		-- in whatever order `pairs` feels like. Ordering them by their earliest
		-- member, and letting the first run that claims a clone keep it, is what
		-- makes a custom anchor that assigns one clone to two frames lay out the
		-- same way twice running instead of flipping between them.
		local rank = {}
		for i = 1, total do rank[list[i]] = i end
		local ranked = {}
		for frame, entries in pairs(frames) do
			local first = total + 1
			for i = 1, table.getn(entries) do
				local at = rank[entries[i]]
				if at and at < first then first = at end
			end
			table.insert(ranked, { frame = frame, entries = entries, first = first })
		end
		stableSort(ranked, WA.SortAscending({ "first" }))
		local claimed = {}
		for r = 1, table.getn(ranked) do
			local entries = ranked[r].entries
			for i = table.getn(entries), 1, -1 do
				if claimed[entries[i]] then table.remove(entries, i)
				else claimed[entries[i]] = true end
			end
		end
		return ranked
	end

	-- A clone whose unit has no frame right now still exists and still holds its
	-- state; it parks on the hidden anchor frame rather than being dropped, so it
	-- reappears in place the moment the frame does. With the options window open
	-- there is no real unit behind a preview clone at all, so the group anchors
	-- its own children and the editor shows the layout instead of nothing.
	local anchorer = anchorers[mode] or anchorers.NAMEPLATE
	local fallback = WA.optionsOpen and nil or (WA.HiddenAnchorFrame and WA.HiddenAnchorFrame())
	for i = 1, total do
		local entry = list[i]
		local frame = anchorer(region, data, entry)
		table.insert(bucketFor(frame or fallback).entries, entry)
	end
	return order
end

-- Two-axis grower: `gridType` is a fill direction then a wrap direction -- "RD"
-- fills rightward and wraps down, "UL" upward then left -- with an H or V in
-- the first letter centering each finished row on the anchor and in the second
-- centering the whole block. Swapping the two descriptors is what lets one loop
-- serve all eighteen combinations.
--
-- Ours is CENTER-origin where upstream's is corner-origin, so each axis converts
-- by half the child's own dimension and the centering passes work on box edges.
-- Upstream's take min/max over corners instead, which leaves a row half its last
-- child's width off center -- identical for same-size icons, wrong for anything
-- else. `align` and `stagger` say nothing about a two-axis layout and are
-- ignored here, as they are upstream.
local function growGrid(data, list, n)
	local gridType = data.gridType or "RD"
	local perLine = tonumber(data.gridWidth) or 5
	if perLine < 1 then perLine = 1 end

	local primary = { axis = "x", dim = "width", space = data.columnSpace or 0,
		mul = string.find(gridType, "L", 1, true) and -1 or 1 }
	local secondary = { axis = "y", dim = "height", space = data.rowSpace or 0,
		mul = string.find(gridType, "D", 1, true) and -1 or 1 }
	if not string.find(gridType, "^[RLH]") then
		primary, secondary = secondary, primary
	end
	local first, second = string.sub(gridType, 1, 1), string.sub(gridType, 2, 2)
	local centerRows = (first == "H" or first == "V")
	local centerBlock = (second == "H" or second == "V")

	local function centerSpan(from, to, on)
		local low, high
		for i = from, to do
			local c = list[i]
			local half = c[on.dim] / 2
			if not low or c[on.axis] - half < low then low = c[on.axis] - half end
			if not high or c[on.axis] + half > high then high = c[on.axis] + half end
		end
		if not low then return end
		local shift = (low + high) / 2
		for i = from, to do
			local c = list[i]
			c[on.axis] = c[on.axis] - shift
		end
	end

	-- Every child of one line sits at the same secondary coordinate, so a line of
	-- mixed heights aligns on its leading edge; the line's own tallest child is
	-- what the secondary axis then advances by.
	local pCursor, sCursor, tallest, lineStart = 0, 0, 0, 1
	for i = 1, n do
		local c = list[i]
		local pDim, sDim = c[primary.dim], c[secondary.dim]
		c[primary.axis] = pCursor + primary.mul * pDim / 2
		c[secondary.axis] = sCursor + secondary.mul * sDim / 2
		if sDim > tallest then tallest = sDim end
		if math.mod(i, perLine) == 0 then
			if centerRows then centerSpan(lineStart, i, primary) end
			pCursor, lineStart = 0, i + 1
			sCursor = sCursor + (secondary.space + tallest) * secondary.mul
			tallest = 0
		else
			pCursor = pCursor + (primary.space + pDim) * primary.mul
		end
	end
	if centerRows and lineStart <= n then centerSpan(lineStart, n, primary) end
	if centerBlock then centerSpan(1, n, secondary) end
end

-- Axis-aligned grower: assigns each visible child of one run a position relative
-- to that run's anchor, stacking successive children by their own dimension +
-- spacing (WA2's DynamicGroup.lua growers, minus animation). HORIZONTAL/VERTICAL
-- center the run on the anchor; the four cardinals grow from it; GRID wraps
-- (growGrid). Shortens the list to the visible ones (parking the rest) and
-- returns the box extents.
local function growRun(data, list)
	local total = table.getn(list)
	local visible = total
	if data.useLimit then
		visible = tonumber(data.limit) or 0
		if visible < 0 then visible = 0 end
		if visible > total then visible = total end
	end
	-- A clone past the limit gives up its painted region without giving up its
	-- state (region:SetLimited) -- it comes back in place the moment the limit
	-- frees up rather than losing its spot in the order.
	for i = 1, total do
		list[i].region:SetLimited(i > visible)
	end
	for i = total, visible + 1, -1 do
		table.remove(list, i)
	end

	local space = data.space or 0
	local grow = data.grow or "DOWN"
	local n = table.getn(list)
	local blx, bly, trx, try = 0, 0, 0, 0

	-- Cross-axis alignment for the vertical grows (UP/DOWN/VERTICAL): line up the
	-- children's left/right edges (LEFT/RIGHT) or centers (CENTER) on x = 0.
	-- Only affects mixed-width children; identical widths land the same either
	-- way. The horizontal grows keep children centered on y (align n/a there).
	local align = data.align or "CENTER"
	local function crossX(w)
		if align == "LEFT" then return w / 2
		elseif align == "RIGHT" then return -w / 2
		else return 0 end
	end

	-- Perpendicular stagger offset for child i (1-based) of an n-run. Our
	-- grower is CENTER-origin where upstream's is corner-origin, and our align
	-- vocabulary is LEFT/CENTER/RIGHT only (upstream's is direction-dependent),
	-- so the vertical grows (UP/DOWN/VERTICAL) stagger on x via crossX using
	-- staggerCoefficient(align, stagger), while the horizontal grows (LEFT/
	-- RIGHT/HORIZONTAL) stagger on y with a flat 0.5 (run centred), since
	-- local align says nothing about that axis there.
	local stagger = data.stagger or 0
	local vertical = (grow == "UP" or grow == "DOWN" or grow == "VERTICAL")
	local staggerCoeff = vertical and staggerCoefficient(align, stagger) or 0.5
	local function perpOffset(i)
		return (i - 1) * stagger - (n - 1) * stagger * staggerCoeff
	end

	if grow == "GRID" then
		growGrid(data, list, n)
	elseif grow == "HORIZONTAL" or grow == "VERTICAL" then
		local runLength = 0
		for i = 1, n do
			runLength = runLength + (grow == "HORIZONTAL" and list[i].width or list[i].height)
		end
		if n > 1 then runLength = runLength + space * (n - 1) end
		local cursor = -runLength / 2
		for i = 1, n do
			local c = list[i]
			local dim = (grow == "HORIZONTAL") and c.width or c.height
			local center = cursor + dim / 2
			if grow == "HORIZONTAL" then
				c.x, c.y = center, perpOffset(i)
			else
				c.x, c.y = crossX(c.width) + perpOffset(i), -center
			end
			cursor = cursor + dim + space
		end
	else
		local cursor = 0
		for i = 1, n do
			local c = list[i]
			if grow == "LEFT" then
				c.x = cursor - c.width / 2; c.y = perpOffset(i); cursor = cursor - c.width - space
			elseif grow == "RIGHT" then
				c.x = cursor + c.width / 2; c.y = perpOffset(i); cursor = cursor + c.width + space
			elseif grow == "UP" then
				c.x = crossX(c.width) + perpOffset(i); c.y = cursor + c.height / 2; cursor = cursor + c.height + space
			else -- DOWN
				c.x = crossX(c.width) + perpOffset(i); c.y = cursor - c.height / 2; cursor = cursor - c.height - space
			end
		end
	end

	for i = 1, n do
		local c = list[i]
		if c.x - c.width / 2 < blx then blx = c.x - c.width / 2 end
		if c.x + c.width / 2 > trx then trx = c.x + c.width / 2 end
		if c.y - c.height / 2 < bly then bly = c.y - c.height / 2 end
		if c.y + c.height / 2 > try then try = c.y + c.height / 2 end
	end
	return list, blx, bly, trx, try
end

-- Orders the group's clones, splits them into anchor runs, and grows each run
-- from its own anchor. Returns every placed child (each carrying the frame it
-- anchors to) plus the box extents of the run the group itself holds -- with
-- per-unit anchoring nothing is anchored to the group, so the box collapses to
-- the group's own point, which is what a border around a set of nameplates
-- would have to mean anyway.
local function growChildren(region, data)
	local list = activeChildren(data)
	if not region.sortFuncBuilt then
		region.sortFunc, region.sortBeginPass = createSortFunc(data)
		region.sortFuncBuilt = true
	end
	if region.sortBeginPass then region.sortBeginPass() end
	stableSort(list, region.sortFunc)

	local placed = {}
	local blx, bly, trx, try = 0, 0, 0, 0
	local runs = anchorPartitions(region, data, list)
	for r = 1, table.getn(runs) do
		local run = runs[r]
		local entries, a, b, c, d = growRun(data, run.entries)
		for i = 1, table.getn(entries) do
			entries[i].anchorFrame = run.frame
			table.insert(placed, entries[i])
		end
		if not run.frame then blx, bly, trx, try = a, b, c, d end
	end
	return placed, blx, bly, trx, try
end

-- Dynamic group: run the grower, push each visible child's computed position
-- onto its region (CENTER-to-CENTER + offset, via the region's own offset slot
-- so UpdatePosition stays authoritative), then draw the box around the result.
local function layoutDynamicGroup(region, data)
	local list, blx, bly, trx, try = growChildren(region, data)
	for i = 1, table.getn(list) do
		local c = list[i]
		c.region:SetAnchor("CENTER", c.anchorFrame or region, "CENTER")
		c.region:SetOffset(c.x, c.y)
	end
	drawGroupBox(region, data, blx, bly, trx, try)
end

-- Every dynamic group anchoring per unit, re-laid-out because the frames it
-- anchors to changed -- a plate appearing or leaving, a roster shuffle moving a
-- unit to another party frame. A plate that merely *moves* needs nothing: the
-- child is anchored to it, so it travels along.
function WA.RelayoutUnitAnchoredGroups()
	for id, data in pairs(WeakestAurasDB and WeakestAurasDB.displays or {}) do
		if data.regionType == "dynamicgroup" and data.useAnchorPerUnit then
			WA.RelayoutGroup(id)
		end
	end
end

-- Refresh a group after a child's position/size/visibility/membership changed:
-- static groups just recompute the box, dynamic groups re-run the whole layout.
-- No-op until the group frame exists. The single relayout entry point the state
-- machine and reparent primitives call.
function WA.RelayoutGroup(groupId)
	local data = WeakestAurasDB.displays[groupId]
	if not data or not WA.IsGroup(data) then return end
	local region = WA.PeekRegion(groupId, "")
	if not region then return end
	if data.regionType == "dynamicgroup" then
		layoutDynamicGroup(region, data)
	else
		applyGroupBounds(region, data)
	end
end

-- group and dynamicgroup share one container implementation: a frame positioned
-- by its own anchor tuple, scaled by data.scale (children inherit via SetParent
-- in ApplyPosition), with an optional bounding-box border. A static group's
-- children keep their own anchor; a dynamicgroup's are arranged by the grower
-- (layoutDynamicGroup) whenever the visible set changes.
local function groupCreate(parent, data)
	local region = CreateFrame("Frame", nil, parent)
	local border = CreateFrame("Frame", nil, region)
	border:SetBackdrop({
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = GROUP_BORDER_EDGE,
		insets = { left = 0, right = 0, top = 0, bottom = 0 },
	})
	region.border = border
	WA.regionPrototype.create(region)
	function region:Update() end -- groups hold no state
	region:Hide()
	return region
end

local function groupModify(region, data)
	region:SetScale(data.scale and data.scale > 0 and data.scale or 1)
	WA.regionPrototype.ApplyPosition(region, data)
	if data.regionType == "dynamicgroup" then
		region.sortFunc, region.sortBeginPass = createSortFunc(data)
		region.sortFuncBuilt = true
		region.anchorFunc, region.anchorFuncBuilt = nil, false
		layoutDynamicGroup(region, data)
	else
		applyGroupBounds(region, data)
	end
	region:Show()
	WA.regionPrototype.modifyFinish(region, data)
end

-- List-row preview: data.groupIcon when it's set and loadable, else three
-- stacked coloured bars (WA2's own RegionOptions/Group.lua createDefaultIcon)
-- scaled to whatever box WA.AcquireThumbnail hands it rather than upstream's
-- fixed 24/20px. Both group and dynamicgroup share it, as they share the field.
local function groupCreateThumbnail(parent)
	local frame = CreateFrame("Frame", nil, parent)
	local t1 = frame:CreateTexture(nil, "ARTWORK")
	t1:SetTexture(0.8, 0, 0, 0.5)
	frame.t1 = t1
	local t2 = frame:CreateTexture(nil, "ARTWORK")
	t2:SetTexture(0.2, 0.8, 0.2, 0.5)
	frame.t2 = t2
	local t3 = frame:CreateTexture(nil, "ARTWORK")
	t3:SetTexture(0.1, 0.25, 1, 0.5)
	frame.t3 = t3
	local icon = frame:CreateTexture(nil, "OVERLAY")
	icon:SetAllPoints(frame)
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	icon:Hide()
	frame.icon = icon
	return frame
end

local function groupModifyThumbnail(frame, data)
	-- WA.DrawableTexture first, and the read-back second: a fileID or an atlas
	-- name is not a path at all, and `GetTexture` hands one straight back rather
	-- than reporting the failure, so the read-back alone let both through to the
	-- engine's missing-texture block. The stored value is left alone -- it is
	-- still what the author chose, and it is what the options tab shows.
	local path = WA.DrawableTexture(data and data.groupIcon)
	if path then
		frame.icon:SetTexture(path)
		-- SetTexture returns nothing here, so upstream's `if success` has no
		-- equivalent: a path the client can't load leaves GetTexture nil, and
		-- that read-back is the only signal that it failed. Without it a typo'd
		-- path gives a blank thumbnail with no way back to the bars.
		if frame.icon:GetTexture() then
			frame.t1:Hide()
			frame.t2:Hide()
			frame.t3:Hide()
			frame.icon:Show()
			return
		end
	end
	frame.icon:Hide()

	local size = frame:GetHeight() or 32
	local k = size / 32
	local t1, t2, t3 = frame.t1, frame.t2, frame.t3
	t1:ClearAllPoints()
	t1:SetWidth(24 * k)
	t1:SetHeight(8 * k)
	t1:SetPoint("TOP", frame, "TOP", 0, -6 * k)
	t2:ClearAllPoints()
	t2:SetWidth(20 * k)
	t2:SetHeight(20 * k)
	t2:SetPoint("TOP", t1, "BOTTOM", 0, 5 * k)
	t3:ClearAllPoints()
	t3:SetWidth(20 * k)
	t3:SetHeight(12 * k)
	t3:SetPoint("TOP", t2, "BOTTOM", -5 * k, 8 * k)
	t1:Show()
	t2:Show()
	t3:Show()
end

-- The one field group and dynamicgroup add for themselves: purely cosmetic,
-- read only by groupModifyThumbnail. Empty falls back to the default bars.
local function groupIconOption(data)
	return {
		type = "icon", name = "Group icon", key = "groupIcon",
		get = function() return data.groupIcon end,
		set = function(v) data.groupIcon = v; WA.Add(data) end,
	}
end

WA.RegisterRegionType("group", {
	displayName = "Group",
	description = "Holds other auras, moving and showing them together.",
	isGroup = true,
	icon = "Interface\\Icons\\INV_Misc_Bag_08",
	defaults = {
		controlledChildren = {},
		anchorFrameType = "SCREEN",
		selfPoint = "CENTER",
		anchorPoint = "CENTER",
		xOffset = 0,
		yOffset = 0,
		frameStrata = 1,
		border = false,
		borderColor = { 0, 0, 0, 1 },
		scale = 1,
		groupIcon = "",
	},
	create = groupCreate,
	modify = groupModify,
	createThumbnail = groupCreateThumbnail,
	modifyThumbnail = groupModifyThumbnail,
	options = function(data)
		local fields = {
			{ type = "header", name = "Group" },
			groupIconOption(data),
			{
				type = "toggle", name = "Border", key = "border",
				get = function() return data.border end,
				set = function(v) data.border = v; WA.Add(data) end,
			},
			{
				type = "range", name = "Scale", key = "scale", min = 0.1, max = 3, step = 0.05,
				get = function() return data.scale end,
				set = function(v) data.scale = v; WA.Add(data) end,
			},
		}
		for _, f in ipairs(WA.regionPrototype.PositionOptions(data)) do
			table.insert(fields, f)
		end
		return fields
	end,
})

-- Upstream's own eighteen (Types.lua's grid_types), verbatim, so an imported
-- grid keeps its author's value rather than landing on an approximation.
local GRID_TYPES = {
	"RD", "RU", "LD", "LU", "DR", "DL", "UR", "UL",
	"HD", "HU", "VR", "VL", "DH", "UH", "LV", "RV", "HV", "VH",
}
local GRID_TYPE_LABELS = {
	RD = "Right, then Down", RU = "Right, then Up",
	LD = "Left, then Down", LU = "Left, then Up",
	DR = "Down, then Right", DL = "Down, then Left",
	UR = "Up, then Right", UL = "Up, then Left",
	HD = "Centered Horizontal, then Down", HU = "Centered Horizontal, then Up",
	VR = "Centered Vertical, then Right", VL = "Centered Vertical, then Left",
	DH = "Down, then Centered Horizontal", UH = "Up, then Centered Horizontal",
	LV = "Left, then Centered Vertical", RV = "Right, then Centered Vertical",
	HV = "Centered Horizontal, then Centered Vertical",
	VH = "Centered Vertical, then Centered Horizontal",
}

WA.RegisterRegionType("dynamicgroup", {
	displayName = "Dynamic Group",
	description = "Arranges its children itself, closing the gaps as they come and go.",
	isGroup = true,
	icon = "Interface\\Icons\\INV_Misc_Bag_09",
	defaults = {
		controlledChildren = {},
		anchorFrameType = "SCREEN",
		selfPoint = "CENTER",
		anchorPoint = "CENTER",
		xOffset = 0,
		yOffset = 0,
		frameStrata = 1,
		border = false,
		borderColor = { 0, 0, 0, 1 },
		scale = 1,
		grow = "DOWN",
		sort = "none",
		space = 2,
		align = "CENTER",
		gridType = "RD",
		gridWidth = 5,
		rowSpace = 2,
		columnSpace = 2,
		groupIcon = "",
		stagger = 0,
		useLimit = false,
		limit = 5,
		useAnchorPerUnit = false,
		anchorPerUnit = "NAMEPLATE",
		customAnchorPerUnit = "",
	},
	create = groupCreate,
	modify = groupModify,
	createThumbnail = groupCreateThumbnail,
	modifyThumbnail = groupModifyThumbnail,
	options = function(data)
		local fields = {
			{ type = "header", name = "Dynamic Group" },
			groupIconOption(data),
			{
				type = "select", name = "Grow direction", key = "grow",
				values = { "UP", "DOWN", "LEFT", "RIGHT", "HORIZONTAL", "VERTICAL", "GRID" },
				get = function() return data.grow end,
				set = function(v) data.grow = v; WA.Add(data); WA.RefreshOptions() end,
			},
			{
				type = "select", name = "Sort", key = "sort",
				values = { "none", "ascending", "descending", "hybrid", "custom" },
				labels = { none = "None", ascending = "Ascending", descending = "Descending",
					hybrid = "Hybrid", custom = "Custom" },
				get = function() return data.sort end,
				set = function(v) data.sort = v; WA.Add(data); WA.RefreshOptions() end,
			},
		}
		-- A grid spaces its two axes separately and reads neither `space` nor
		-- `align`, so it offers its own pair and withholds both -- upstream hides
		-- the same three fields, `stagger` included, for the same reason.
		if data.grow == "GRID" then
			table.insert(fields, {
				type = "select", name = "Grid direction", key = "gridType",
				values = GRID_TYPES, labels = GRID_TYPE_LABELS,
				get = function() return data.gridType end,
				set = function(v) data.gridType = v; WA.Add(data); WA.RefreshOptions() end,
			})
			table.insert(fields, {
				type = "range", key = "gridWidth", min = 1, max = 20, step = 1,
				name = string.find(data.gridType or "RD", "^[RLH]") and "Row width"
					or "Column height",
				get = function() return data.gridWidth end,
				set = function(v) data.gridWidth = v; WA.Add(data) end,
			})
			table.insert(fields, {
				type = "range", name = "Row spacing", key = "rowSpace", min = 0, max = 20, step = 1,
				get = function() return data.rowSpace end,
				set = function(v) data.rowSpace = v; WA.Add(data) end,
			})
			table.insert(fields, {
				type = "range", name = "Column spacing", key = "columnSpace",
				min = 0, max = 20, step = 1,
				get = function() return data.columnSpace end,
				set = function(v) data.columnSpace = v; WA.Add(data) end,
			})
		else
			table.insert(fields, {
				type = "range", name = "Spacing", key = "space", min = 0, max = 20, step = 1,
				get = function() return data.space end,
				set = function(v) data.space = v; WA.Add(data) end,
			})
			table.insert(fields, {
				type = "select", name = "Align", key = "align",
				values = { "LEFT", "CENTER", "RIGHT" },
				get = function() return data.align end,
				set = function(v) data.align = v; WA.Add(data) end,
			})
		end
		if data.sort == "hybrid" then
			table.insert(fields, {
				type = "select", name = "Hybrid Position", key = "hybridPosition",
				values = { "hybridFirst", "hybridLast" },
				labels = { hybridFirst = "Marked First", hybridLast = "Marked Last" },
				get = function() return data.hybridPosition end,
				set = function(v) data.hybridPosition = v; WA.Add(data) end,
			})
			table.insert(fields, {
				type = "select", name = "Hybrid Sort Mode", key = "hybridSortMode",
				values = { "ascending", "descending" },
				get = function() return data.hybridSortMode end,
				set = function(v) data.hybridSortMode = v; WA.Add(data) end,
			})
			local kids = data.controlledChildren or {}
			for i = 1, table.getn(kids) do
				local childId = kids[i]
				table.insert(fields, {
					type = "toggle", name = childId, key = "sortHybrid_" .. childId,
					get = function() return data.sortHybridTable and data.sortHybridTable[childId] or false end,
					set = function(v)
						data.sortHybridTable = data.sortHybridTable or {}
						data.sortHybridTable[childId] = v
						WA.Add(data)
					end,
				})
			end
		elseif data.sort == "custom" then
			table.insert(fields, {
				type = "code", name = "Custom Sort", key = "customSort", height = 160,
				get = function() return data.customSort end,
				set = function(v) data.customSort = v; WA.Add(data) end,
				-- Seeded nil-safe on purpose: a comparator sees the options
				-- preview's synthesised state as well as the real ones, and that
				-- carries no producer fields at all. Answering nil is "no
				-- opinion", which leaves the pair in the deterministic base order.
				default = "function(a, b)\n"
					.. "    local x = a.region.state and a.region.state.index\n"
					.. "    local y = b.region.state and b.region.state.index\n"
					.. "    if x == nil or y == nil then return nil end\n"
					.. "    return x < y\nend",
				validate = function(txt)
					return WA.Widgets.LuaSyntaxError(WA.WrapFunctionSource(txt), "custom sort")
				end,
			})
		end
		if data.grow ~= "GRID" then
			table.insert(fields, {
				type = "range", name = "Stagger", key = "stagger", min = -50, max = 50, step = 1,
				get = function() return data.stagger end,
				set = function(v) data.stagger = v; WA.Add(data) end,
			})
		end
		table.insert(fields, {
			type = "toggle", name = "Limit visible clones", key = "useLimit",
			get = function() return data.useLimit end,
			set = function(v) data.useLimit = v; WA.Add(data); WA.RefreshOptions() end,
		})
		if data.useLimit then
			table.insert(fields, {
				type = "range", name = "Limit", key = "limit", min = 0, max = 20, step = 1,
				get = function() return data.limit end,
				set = function(v) data.limit = v; WA.Add(data) end,
			})
		end
		table.insert(fields, {
			type = "toggle", name = "Anchor per unit", key = "useAnchorPerUnit",
			get = function() return data.useAnchorPerUnit end,
			set = function(v) data.useAnchorPerUnit = v; WA.Add(data); WA.RefreshOptions() end,
		})
		if data.useAnchorPerUnit then
			table.insert(fields, {
				type = "select", name = "Anchor each clone to", key = "anchorPerUnit",
				values = { "NAMEPLATE", "UNITFRAME", "CUSTOM" },
				labels = { NAMEPLATE = "Its unit's nameplate", UNITFRAME = "Its unit's frame",
					CUSTOM = "Custom" },
				get = function() return data.anchorPerUnit end,
				set = function(v) data.anchorPerUnit = v; WA.Add(data); WA.RefreshOptions() end,
			})
			if data.anchorPerUnit == "CUSTOM" then
				table.insert(fields, {
					type = "code", name = "Custom Anchor", key = "customAnchorPerUnit", height = 160,
					get = function() return data.customAnchorPerUnit end,
					set = function(v) data.customAnchorPerUnit = v; WA.Add(data) end,
					-- Upstream's signature: fill `frames[frame]` with the clones that
					-- belong to that frame. Seeded with the nameplate the built-in
					-- anchorer would find, since that is the shape most custom
					-- anchors start from.
					default = "function(frames, regions)\n"
						.. "    for i = 1, table.getn(regions) do\n"
						.. "        local state = regions[i].region.state\n"
						.. "        local frame = state and state.unit\n"
						.. "            and WeakestAuras.GetUnitNameplate(state.unit)\n"
						.. "        if frame then\n"
						.. "            frames[frame] = frames[frame] or {}\n"
						.. "            table.insert(frames[frame], regions[i])\n"
						.. "        end\n"
						.. "    end\nend",
					validate = function(txt)
						return WA.Widgets.LuaSyntaxError(WA.WrapFunctionSource(txt), "custom anchor")
					end,
				})
			end
		end
		table.insert(fields, {
			type = "toggle", name = "Border", key = "border",
			get = function() return data.border end,
			set = function(v) data.border = v; WA.Add(data) end,
		})
		table.insert(fields, {
			type = "range", name = "Scale", key = "scale", min = 0.1, max = 3, step = 0.05,
			get = function() return data.scale end,
			set = function(v) data.scale = v; WA.Add(data) end,
		})
		for _, f in ipairs(WA.regionPrototype.PositionOptions(data)) do
			table.insert(fields, f)
		end
		return fields
	end,
})

local TEXTURE_BLEND_MODES = { "BLEND", "ADD" }
local TEXTURE_BLEND_LABELS = {
	BLEND = "Opaque", ADD = "Glow",
}

local TEXTURE_DEFAULT = "Interface\\AddOns\\WeakestAuras\\textures\\shapes\\arrows_target.tga"
local TEXTURE_SQRT2 = math.sqrt(2)

local function textureRotationCoords(degrees, mirror)
	local angle = math.pi * (135 - (degrees or 0)) / 180
	local vx = math.cos(angle) / TEXTURE_SQRT2
	local vy = math.sin(angle) / TEXTURE_SQRT2
	local ulx, uly = 0.5 + vx, 0.5 - vy
	local llx, lly = 0.5 - vy, 0.5 - vx
	local urx, ury = 0.5 + vy, 0.5 + vx
	local lrx, lry = 0.5 - vx, 0.5 + vy
	if mirror then return urx, ury, lrx, lry, ulx, uly, llx, lly end
	return ulx, uly, llx, lly, urx, ury, lrx, lry
end

local function applyTextureCoords(texture, mirror, rotation)
	texture:SetTexCoord(textureRotationCoords(rotation, mirror))
end

local TEXTURE_SUB_ANCHORS = {
	TOPLEFT = { display = "Edge / Top Left", point = true }, TOP = { display = "Edge / Top", point = true }, TOPRIGHT = { display = "Edge / Top Right", point = true },
	LEFT = { display = "Edge / Left", point = true }, CENTER = { display = "Center", point = true }, RIGHT = { display = "Edge / Right", point = true },
	BOTTOMLEFT = { display = "Edge / Bottom Left", point = true }, BOTTOM = { display = "Edge / Bottom", point = true }, BOTTOMRIGHT = { display = "Edge / Bottom Right", point = true },
}

local function textureCoords(mirror)
	if mirror then return 1, 0, 1, 1, 0, 0, 0, 1 end
	return 0, 0, 0, 1, 1, 0, 1, 1
end

local function textureThumbnailSize(frame, data)
	local size = frame:GetWidth() or 32
	local width, height = data.width or 1, data.height or 1
	local scale = size / math.max(width, height)
	return width * scale, height * scale
end

WA.RegisterRegionType("texture", {
	displayName = "Texture",
	description = "A custom texture with colour, mirroring and desaturation.",
	defaults = {
		texture = TEXTURE_DEFAULT,
		width = 200,
		height = 200,
		alpha = 1,
		desaturate = false,
		color = { 1, 1, 1, 1 },
		blendMode = "BLEND",
		mirror = false,
		anchorFrameType = "SCREEN",
		selfPoint = "CENTER",
		anchorPoint = "CENTER",
		xOffset = 0,
		yOffset = 0,
		frameStrata = 1,
	},
	icon = TEXTURE_DEFAULT,
	getSubRegionAnchors = function() return TEXTURE_SUB_ANCHORS end,
	properties = WA.regionPrototype.AddProperties({
		texture = { display = "Texture", setter = "SetTexture", type = "texture" },
		color = { display = "Color", setter = "Color", type = "color" },
		desaturate = { display = "Desaturate", setter = "SetDesaturated", type = "bool" },
		blendMode = { display = "Blend Mode", setter = "SetBlendMode", type = "list", values = TEXTURE_BLEND_LABELS },
		width = { display = "Width", setter = "SetRegionWidth", type = "number", min = 8, max = 512, step = 1 },
		height = { display = "Height", setter = "SetRegionHeight", type = "number", min = 8, max = 512, step = 1 },
		mirror = { display = "Mirror", setter = "SetMirror", type = "bool" },
	}),
	createThumbnail = function(parent)
		local frame = CreateFrame("Frame", nil, parent)
		local texture = frame:CreateTexture(nil, "ARTWORK")
		frame.texture = texture
		return frame
	end,
	modifyThumbnail = function(frame, data)
		local texture = frame.texture
		local width, height = textureThumbnailSize(frame, data)
		texture:ClearAllPoints()
		texture:SetPoint("CENTER", frame, "CENTER")
		texture:SetWidth(width)
		texture:SetHeight(height)
		texture:SetTexture(WA.DrawableTexture(data.texture) or TEXTURE_DEFAULT)
		local color = data.color or { 1, 1, 1, 1 }
		texture:SetVertexColor(color[1] or 1, color[2] or 1, color[3] or 1, color[4] or 1)
		texture:SetBlendMode(data.blendMode or "BLEND")
		texture:SetDesaturated(data.desaturate and true or false)
		applyTextureCoords(texture, data.mirror, data.rotation)
	end,
	options = function(data)
		local fields = {
			{ type = "header", name = "Texture" },
			{
				type = "texture", name = "Texture", key = "texture",
				get = function() return data.texture end,
				set = function(v) data.texture = v; WA.Add(data, true); WA.RefreshList() end,
			},
			{
				type = "color", name = "Color", key = "color",
				half = true,
				get = function() return data.color end,
				set = function(v) data.color = v; WA.Add(data, true) end,
			},
			{
				type = "toggle", name = "Desaturate", key = "desaturate",
				half = true,
				get = function() return data.desaturate end,
				set = function(v) data.desaturate = v; WA.Add(data, true) end,
			},
			{
				type = "range", name = "Alpha", key = "alpha", min = 0, max = 1, step = 0.05, half = true,
				get = function() return data.alpha end,
				set = function(v) data.alpha = v; WA.Add(data, true) end,
			},
			{
				type = "select", name = "Blend mode", key = "blendMode", half = true,
				values = TEXTURE_BLEND_MODES, labels = TEXTURE_BLEND_LABELS,
				get = function() return data.blendMode end,
				set = function(v) data.blendMode = v; WA.Add(data, true) end,
			},
			{
				type = "toggle", name = "Mirror", key = "mirror", half = true,
				get = function() return data.mirror end,
				set = function(v) data.mirror = v; WA.Add(data, true) end,
			},
			{
				type = "range", name = "Rotation", key = "rotation", min = 0, max = 360, step = 1, half = true,
				get = function() return data.rotation end,
				set = function(v) data.rotation = v; WA.Add(data, true) end,
			},
			{ type = "header", name = "Size" },
			{
				type = "range", name = "Width", key = "width", min = 8, max = 512, step = 1, half = true,
				get = function() return data.width end,
				set = function(v) data.width = v; WA.Add(data, true) end,
			},
			{
				type = "range", name = "Height", key = "height", min = 8, max = 512, step = 1, half = true,
				get = function() return data.height end,
				set = function(v) data.height = v; WA.Add(data, true) end,
			},
		}
		for _, field in ipairs(WA.regionPrototype.PositionOptions(data)) do table.insert(fields, field) end
		return fields
	end,
	create = function(parent)
		local region = CreateFrame("Frame", nil, parent)
		local texture = region:CreateTexture(nil, "ARTWORK")
		texture:SetAllPoints(region)
		region.texture = texture
		WA.regionPrototype.create(region)
		function region:Update()
			if self.state and self.state.texture then self:SetTexture(self.state.texture) end
		end
		region:Hide()
		return region
	end,
	modify = function(region, data)
		function region:SetRegionWidth(width) self.regionWidth = width; self:SetWidth(width) end
		function region:SetRegionHeight(height) self.regionHeight = height; self:SetHeight(height) end
		function region:SetTexture(path) self.texture:SetTexture(WA.DrawableTexture(path) or TEXTURE_DEFAULT) end
		function region:Color(r, g, b, a) self.texture:SetVertexColor(r, g, b, a or 1) end
		function region:SetDesaturated(value) self.texture:SetDesaturated(value and true or false) end
		function region:SetBlendMode(value) self.texture:SetBlendMode(value or "BLEND") end
		function region:SetMirror(value) self.mirror = value and true or false; applyTextureCoords(self.texture, self.mirror, self.rotation) end
		function region:SetRotation(value) self.rotation = value or 0; applyTextureCoords(self.texture, self.mirror, self.rotation) end
		function region:SetAnimRotation(value) self.animRotation = value; applyTextureCoords(self.texture, self.mirror, value or self.rotation) end
		function region:GetBaseRotation() return self.rotation or 0 end

		region:SetRegionWidth(data.width)
		region:SetRegionHeight(data.height)
		region:SetRegionAlpha(data.alpha)
		region:SetTexture(data.texture)
		local color = data.color or { 1, 1, 1, 1 }
		region:Color(color[1], color[2], color[3], color[4])
		region:SetDesaturated(data.desaturate)
		region:SetBlendMode(data.blendMode)
		region:SetMirror(data.mirror)
		region:SetRotation(data.rotation)
		WA.regionPrototype.ApplyPosition(region, data)
		WA.regionPrototype.modifyFinish(region, data)
	end,
})

local function regionAnchor(display, point, area)
	return { display = display, point = point, area = area }
end

-- Ahead of the registration below, not beside its sibling tables further down: a
-- local declared after the closure that names it is a different variable, so
-- getSubRegionAnchors would read a nil global and the icon would offer no
-- sub-region anchor but the whole region.
local ICON_SUB_ANCHORS = {
	TOPLEFT = regionAnchor("Edge / Top Left", true), TOP = regionAnchor("Edge / Top", true), TOPRIGHT = regionAnchor("Edge / Top Right", true),
	LEFT = regionAnchor("Edge / Left", true), CENTER = regionAnchor("Center", true), RIGHT = regionAnchor("Edge / Right", true),
	BOTTOMLEFT = regionAnchor("Edge / Bottom Left", true), BOTTOM = regionAnchor("Edge / Bottom", true), BOTTOMRIGHT = regionAnchor("Edge / Bottom Right", true),
	INNER_TOPLEFT = regionAnchor("Inner / Top Left", true), INNER_TOP = regionAnchor("Inner / Top", true), INNER_TOPRIGHT = regionAnchor("Inner / Top Right", true),
	INNER_LEFT = regionAnchor("Inner / Left", true), INNER_CENTER = regionAnchor("Inner / Center", true), INNER_RIGHT = regionAnchor("Inner / Right", true),
	INNER_BOTTOMLEFT = regionAnchor("Inner / Bottom Left", true), INNER_BOTTOM = regionAnchor("Inner / Bottom", true), INNER_BOTTOMRIGHT = regionAnchor("Inner / Bottom Right", true),
	OUTER_TOPLEFT = regionAnchor("Outer / Top Left", true), OUTER_TOP = regionAnchor("Outer / Top", true), OUTER_TOPRIGHT = regionAnchor("Outer / Top Right", true),
	OUTER_LEFT = regionAnchor("Outer / Left", true), OUTER_CENTER = regionAnchor("Outer / Center", true), OUTER_RIGHT = regionAnchor("Outer / Right", true),
	OUTER_BOTTOMLEFT = regionAnchor("Outer / Bottom Left", true), OUTER_BOTTOM = regionAnchor("Outer / Bottom", true), OUTER_BOTTOMRIGHT = regionAnchor("Outer / Bottom Right", true),
	ALL = regionAnchor("Whole area", nil, true),
}

WA.RegisterRegionType("icon", {
	displayName = "Icon",
	description = "A spell icon with a cooldown swipe, stacks and timer text.",
	defaults = {
		width = 32,
		height = 32,
		alpha = 1,
		desaturate = false,
		color = { 1, 1, 1, 1 },
		-- iconSource: -1 = automatic (the trigger's state.icon), 0 = manual
		-- (displayIcon). WA2 also has 1..N for per-trigger icons; we're
		-- single-trigger, so those append later without a migration (WA2's
		-- Private.IconSources). displayIcon doubles as the automatic-mode
		-- fallback for triggers that supply no icon (e.g. Mana/Health).
		iconSource = -1,
		displayIcon = "",
		zoom = 0,
		cooldownSwipe = true,
		useAdjustededMin = false,
		adjustedMin = "",
		useAdjustededMax = false,
		adjustedMax = "",
		progressSource = -1,
		progressSourceManualValue = 0,
		progressSourceManualTotal = 100,
		anchorFrameType = "SCREEN",
		selfPoint = "CENTER",
		anchorPoint = "CENTER",
		xOffset = 0,
		yOffset = 0,
		frameStrata = 1,
	},
	icon = "Interface\\Icons\\INV_Misc_QuestionMark",
	getSubRegionAnchors = function() return ICON_SUB_ANCHORS end,
	-- List-row preview: the resolved icon (WA.ResolveDisplayIcon, Data.lua) at
	-- the saved zoom, same texcoord rule as the runtime region's own SetZoom.
	createThumbnail = function(parent)
		local frame = CreateFrame("Frame", nil, parent)
		local tex = frame:CreateTexture(nil, "ARTWORK")
		tex:SetAllPoints(frame)
		frame.tex = tex
		return frame
	end,
	modifyThumbnail = function(frame, data)
		frame.tex:SetTexture(WA.ResolveDisplayIcon(data) or "Interface\\Icons\\INV_Misc_QuestionMark")
		local inset = 0.07 + (data.zoom or 0) * 0.20
		frame.tex:SetTexCoord(inset, 1 - inset, inset, 1 - inset)
	end,
	-- The overridable-property registry conditions and their editor read
	-- Setter names a region method defined in modify below.
	properties = WA.regionPrototype.AddProgressProperties(WA.regionPrototype.AddProperties({
		width = { display = "Width", setter = "SetRegionWidth", type = "number", min = 8, max = 128, step = 1 },
		height = { display = "Height", setter = "SetRegionHeight", type = "number", min = 8, max = 128, step = 1 },
		desaturate = { display = "Desaturate", setter = "SetDesaturated", type = "bool" },
		color = { display = "Color", setter = "Color", type = "color" },
		zoom = { display = "Zoom", setter = "SetZoom", type = "number", min = 0, max = 1, step = 0.05 },
		cooldownSwipe = { display = "Cooldown Swipe", setter = "SetCooldownSwipe", type = "bool" },
		iconSource = { display = "Icon Source", setter = "SetIconSource", type = "list", values = { [-1] = "Automatic", [0] = "Manual" }, default = 0 },
		displayIcon = { display = "Manual Icon", setter = "SetIcon", type = "icon" },
	})),
	options = function(data)
		local fields = {
			{ type = "header", name = "Icon" },
			{
				type = "select", name = "Icon source", key = "iconSource",
				values = { -1, 0 },
				labels = { [-1] = "Automatic (trigger)", [0] = "Manual" },
				get = function() return data.iconSource end,
				set = function(v) data.iconSource = v; WA.Add(data, true); WA.RefreshList() end,
			},
			{
				type = "icon", name = "Manual icon", key = "displayIcon",
				get = function() return data.displayIcon end,
				set = function(v) data.displayIcon = v; WA.Add(data, true); WA.RefreshList() end,
			},
			{
				type = "toggle", name = "Desaturate", key = "desaturate",
				get = function() return data.desaturate end,
				set = function(v) data.desaturate = v; WA.Add(data, true) end,
			},
			{
				type = "toggle", name = "Cooldown swipe", key = "cooldownSwipe",
				get = function() return data.cooldownSwipe end,
				set = function(v) data.cooldownSwipe = v; WA.Add(data, true) end,
			},
			{
				type = "range", name = "Zoom", key = "zoom", min = 0, max = 1, step = 0.05, half = true,
				get = function() return data.zoom end,
				set = function(v) data.zoom = v; WA.Add(data, true) end,
			},
			{
				type = "range", name = "Alpha", key = "alpha", min = 0, max = 1, step = 0.05, half = true,
				get = function() return data.alpha end,
				set = function(v) data.alpha = v; WA.Add(data, true) end,
			},
			{ type = "header", name = "Size" },
			{
				type = "range", name = "Width", key = "width", min = 8, max = 128, step = 1, half = true,
				get = function() return data.width end,
				set = function(v) data.width = v; WA.Add(data, true) end,
			},
			{
				type = "range", name = "Height", key = "height", min = 8, max = 128, step = 1, half = true,
				get = function() return data.height end,
				set = function(v) data.height = v; WA.Add(data, true) end,
			},
		}
		for _, f in ipairs(WA.regionPrototype.ProgressOptions(data)) do
			table.insert(fields, f)
		end
		for _, f in ipairs(WA.regionPrototype.PositionOptions(data)) do
			table.insert(fields, f)
		end
		return fields
	end,
	-- Frame + icon texture + a native cooldown swipe (regionPrototype.CreateSwipe;
	-- the radial spiral, built as a Model on this client -- see that helper).
	-- Countdown/stacks text rides on %p/%s subtext elements (SubText.lua) on top.
	create = function(parent, data)
		local region = CreateFrame("Frame", nil, parent)

		local iconTex = region:CreateTexture(nil, "ARTWORK")
		iconTex:SetAllPoints(region)
		iconTex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		region.iconTex = iconTex
		local inner = CreateFrame("Frame", nil, region)
		local outer = CreateFrame("Frame", nil, region)
		region.inner, region.outer = inner, outer
		function region:UpdateInnerOuterSize()
			local w, h = self.regionWidth or 0, self.regionHeight or 0
			inner:ClearAllPoints()
			inner:SetPoint("TOPLEFT", self, "TOPLEFT", w * 0.1, -h * 0.1)
			inner:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -w * 0.1, h * 0.1)
			outer:ClearAllPoints()
			outer:SetPoint("TOPLEFT", self, "TOPLEFT", -w * 0.05, h * 0.05)
			outer:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", w * 0.05, -h * 0.05)
		end

		region.swipe = WA.regionPrototype.CreateSwipe(region)

		WA.regionPrototype.create(region)
		function region:GetSubAnchorTarget(key)
			if key == "region" or key == "ALL" then return self end
			if string.find(key, "^INNER_") then return self.inner end
			if string.find(key, "^OUTER_") then return self.outer end
			return self.iconTex or self
		end

		-- Reads region.state (set by the state machine) -- replaces the old
		-- updateState(region, state, data). Text (countdown/stacks) rides on
		-- subtext elements notified via the subRegionEvents "Update" bus, and the
		-- %c refresh goes first so every one of them reads values computed once.
		function region:Update()
			local state = self.state
			if not state then return end
			self:RefreshCustomText(true)
			self:UpdateIcon()
			WA.regionPrototype.UpdateProgress(self)
		end

		-- UpdateProgress dispatches here after setting duration/expirationTime:
		-- a timed state drives the swipe (when enabled), a static one clears it.
		function region:UpdateTime()
			-- The swipe is a 3D Model armed with a start and duration, not a value
			-- it can hold part-way -- a paused aura clears it rather than leaving a
			-- swipe running on regardless of the freeze.
			if self.paused then
				WA.regionPrototype.ArmSwipe(self.swipe, 0, 0)
			elseif self.cooldownSwipe then
				WA.regionPrototype.ArmSwipe(self.swipe, self.expirationTime, self.duration)
			else
				WA.regionPrototype.ArmSwipe(self.swipe, 0, 0)
			end
		end
		function region:UpdateValue()
			WA.regionPrototype.ArmSwipe(self.swipe, 0, 0)
		end

		region:Hide()
		return region
	end,
	modify = function(region, data)
		-- Both dimensions feed the swipe's square sizing (SizeSwipe centers a
		-- min(width,height) square rather than stretching non-uniformly), so
		-- either setter re-runs it with the latest known value of the other.
		function region:SetRegionWidth(w) self.regionWidth = w; self:SetWidth(w); self:UpdateInnerOuterSize(); WA.regionPrototype.SizeSwipe(self.swipe, w, self.regionHeight) end
		function region:SetRegionHeight(h) self.regionHeight = h; self:SetHeight(h); self:UpdateInnerOuterSize(); WA.regionPrototype.SizeSwipe(self.swipe, self.regionWidth, h) end
		function region:SetDesaturated(b) self.iconTex:SetDesaturated(b and true or false) end
		function region:Color(r, g, b, a) self.iconTex:SetVertexColor(r, g, b, a or 1) end
		-- Off clears the swipe now; on re-drives from the current state (if any).
		function region:SetCooldownSwipe(b)
			self.cooldownSwipe = b and true or false
			if not self.cooldownSwipe then
				WA.regionPrototype.ArmSwipe(self.swipe, 0, 0)
			elseif self.state then
				WA.regionPrototype.UpdateProgress(self)
			end
		end
		-- Zoom crops the texcoords inward from the fixed 0.07 border trim (zoom=0
		-- keeps the default look; zoom=1 shows the center ~46%).
		function region:SetZoom(z)
			local inset = 0.07 + (z or 0) * 0.20
			self.iconTex:SetTexCoord(inset, 1 - inset, inset, 1 - inset)
		end

		-- Icon resolution (WA2's Icon.lua region:UpdateIcon): manual mode uses
		-- displayIcon; automatic falls back to it when the trigger gives no icon.
		function region:SetIconSource(source) self.iconSource = source; self:UpdateIcon() end
		function region:SetIcon(path) self.displayIcon = path; self:UpdateIcon() end
		function region:UpdateIcon()
			local path
			if self.iconSource == 0 then
				path = self.displayIcon
			else
				path = (self.state and self.state.icon) or self.displayIcon
			end
			self.iconTex:SetTexture(WA.DrawableTexture(path) or "Interface\\Icons\\INV_Misc_QuestionMark")
		end

		region:SetRegionWidth(data.width)
		region:SetRegionHeight(data.height)
		region:SetRegionAlpha(data.alpha)
		region:SetDesaturated(data.desaturate)
		region:SetZoom(data.zoom)
		region.cooldownSwipe = data.cooldownSwipe and true or false
		local col = data.color or { 1, 1, 1, 1 }
		region:Color(col[1], col[2], col[3], col[4])
		region.iconSource = data.iconSource
		region.displayIcon = data.displayIcon
		region:UpdateIcon()
		WA.regionPrototype.ApplyPosition(region, data)
		WA.regionPrototype.ApplyProgressConfig(region, data)
		WA.regionPrototype.modifyFinish(region, data)
	end,
})

-- Follows WeakAuras2's AuraBar.lua (icon beside the bar rather than over it, a
-- bar texture, a background behind the fill, orientation + inverse, a spark),
-- minus upstream's SmoothStatusBarMixin/LibSharedMedia, which don't exist here.
--
-- The fill is two plain textures (bg + fg) rather than a native StatusBar, for
-- the same reason upstream hand-rolls its own `barPrototype`: a StatusBar owns
-- its texture's coordinates -- it recomputes them on every SetValue to crop the
-- fill -- so a bar texture can never be *rotated* inside one, and this client
-- has no SetRotatesTexture to ask for it either (absent from ClassicAPI, unused
-- by every other addon here). Bar art is a horizontal grain, so a vertical bar
-- drawn through a StatusBar stretches that grain the wrong way. Owning the crop
-- means the 90-degree rotation is just the texcoords we hand it, and it also
-- makes the two _INVERSE orientations free -- no SetReverseFill needed.
--
-- The 8-argument SetTexCoord form the rotation needs is the corner form
-- (ULx,ULy, LLx,LLy, URx,URy, LRx,LRy); it works on this client.
local BAR_ORIENTATIONS = { "HORIZONTAL", "HORIZONTAL_INVERSE", "VERTICAL", "VERTICAL_INVERSE" }
-- Upstream's own wording (Types.lua orientation_types): the label names the
-- direction the *leading edge travels as the bar drains*, not where the fill
-- sits -- so "Right to Left" is the familiar left-anchored bar.
-- The client's own casting-bar spark, and what an unusable one falls back to:
-- an atlas name or a foreign addon's file would otherwise paint the engine's
-- missing-texture block at the full spark width and height.
local SPARK_DEFAULT = "Interface\\CastingBar\\UI-CastingBar-Spark"

local BAR_ORIENTATION_LABELS = {
	HORIZONTAL = "Right to Left",
	HORIZONTAL_INVERSE = "Left to Right",
	VERTICAL = "Bottom to Top",
	VERTICAL_INVERSE = "Top to Bottom",
}
local ICON_SIDES = { "LEFT", "RIGHT" }

-- Condition properties render `values` as a key -> label map (the key is what
-- gets stored and passed to the setter), unlike the options `select` widget's
-- plain array -- so this can't just point at W.BarTextures() itself.
-- Texture names are their own labels; derived so the two lists can't drift.
local BAR_TEXTURE_LABELS = {}
for _, name in ipairs(WA.Widgets.BarTextures()) do
	BAR_TEXTURE_LABELS[name] = name
end

local function isVertical(o)
	return o == "VERTICAL" or o == "VERTICAL_INVERSE"
end

local function isInverse(o)
	return string.find(o, "INVERSE") ~= nil
end

local function progressbarAnchor(display, point, area)
	return { display = display, point = point, area = area }
end

local PROGRESSBAR_SUB_ANCHORS = {
	TOPLEFT = progressbarAnchor("Background / Top Left", true), TOP = progressbarAnchor("Background / Top", true), TOPRIGHT = progressbarAnchor("Background / Top Right", true),
	LEFT = progressbarAnchor("Background / Left", true), CENTER = progressbarAnchor("Background / Center", true), RIGHT = progressbarAnchor("Background / Right", true),
	BOTTOMLEFT = progressbarAnchor("Background / Bottom Left", true), BOTTOM = progressbarAnchor("Background / Bottom", true), BOTTOMRIGHT = progressbarAnchor("Background / Bottom Right", true),
	INNER_TOPLEFT = progressbarAnchor("Background inner / Top Left", true), INNER_TOP = progressbarAnchor("Background inner / Top", true), INNER_TOPRIGHT = progressbarAnchor("Background inner / Top Right", true),
	INNER_LEFT = progressbarAnchor("Background inner / Left", true), INNER_CENTER = progressbarAnchor("Background inner / Center", true), INNER_RIGHT = progressbarAnchor("Background inner / Right", true),
	INNER_BOTTOMLEFT = progressbarAnchor("Background inner / Bottom Left", true), INNER_BOTTOM = progressbarAnchor("Background inner / Bottom", true), INNER_BOTTOMRIGHT = progressbarAnchor("Background inner / Bottom Right", true),
	ICON_TOPLEFT = progressbarAnchor("Icon / Top Left", true), ICON_TOP = progressbarAnchor("Icon / Top", true), ICON_TOPRIGHT = progressbarAnchor("Icon / Top Right", true),
	ICON_LEFT = progressbarAnchor("Icon / Left", true), ICON_CENTER = progressbarAnchor("Icon / Center", true), ICON_RIGHT = progressbarAnchor("Icon / Right", true),
	ICON_BOTTOMLEFT = progressbarAnchor("Icon / Bottom Left", true), ICON_BOTTOM = progressbarAnchor("Icon / Bottom", true), ICON_BOTTOMRIGHT = progressbarAnchor("Icon / Bottom Right", true),
	SPARK = progressbarAnchor("Spark", true),
	bar = progressbarAnchor("Full bar", true, true), icon = progressbarAnchor("Icon", true, true),
	fg = progressbarAnchor("Foreground", true, true), bg = progressbarAnchor("Background", true, true),
}

-- Which two corners of the bar the fill is pinned to. The pair is always the
-- edge the texture's u = 0 lands on below, so the fill grows away from it.
local BAR_ALIGN = {
	HORIZONTAL = { "TOPLEFT", "BOTTOMLEFT" },
	HORIZONTAL_INVERSE = { "TOPRIGHT", "BOTTOMRIGHT" },
	VERTICAL = { "TOPLEFT", "TOPRIGHT" },
	VERTICAL_INVERSE = { "BOTTOMLEFT", "BOTTOMRIGHT" },
}

-- Corner texcoords cropping the texture to u in [0, p], rotated 90 degrees for
-- the vertical orientations so the art's grain runs along the fill axis (ref
-- WA2 AuraBar GetTexCoordFunctions, ported as-is). Returns the eight corner
-- values in SetTexCoord's order.
local BAR_TEXCOORDS = {
	HORIZONTAL = function(p)
		return 0, 0, 0, 1, p, 0, p, 1
	end,
	HORIZONTAL_INVERSE = function(p)
		return p, 0, p, 1, 0, 0, 0, 1
	end,
	VERTICAL = function(p)
		return 0, 1, p, 1, 0, 0, p, 0
	end,
	VERTICAL_INVERSE = function(p)
		return p, 0, 0, 0, p, 1, 0, 1
	end,
}

-- Which edge of `region.bar` a texture placed along the fill axis rides for
-- each orientation -- the same edge BAR_ALIGN pins the fill to, since the fill
-- grows away from that edge and anything riding the fill axis measures its
-- distance from it too.
local SPARK_ANCHOR = {
	HORIZONTAL = "LEFT",
	HORIZONTAL_INVERSE = "RIGHT",
	VERTICAL = "TOP",
	VERTICAL_INVERSE = "BOTTOM",
}

-- Corner texcoords for a manual (non-AUTO) spark rotation -- only multiples of
-- 90 degrees, pure texcoord shuffling, no rotation API needed (ref WA2 AuraBar
-- GetTexCoordSpark). Upstream's version returns TL,TR,BL,BR and reorders to
-- TL,BL,TR,BR at its call site for SetTexCoord; this returns already in
-- SetTexCoord order (TL,BL,TR,BR), matching BAR_TEXCOORDS' convention, so a
-- caller passes the result straight through.
local SPARK_CORNER_COORDS = { 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1 }
local function GetTexCoordSpark(degree, mirror)
	local offset = (degree or 0) / 90
	local TLx, TLy = SPARK_CORNER_COORDS[2 + offset], SPARK_CORNER_COORDS[1 + offset]
	local TRx, TRy = SPARK_CORNER_COORDS[3 + offset], SPARK_CORNER_COORDS[2 + offset]
	local BLx, BLy = SPARK_CORNER_COORDS[1 + offset], SPARK_CORNER_COORDS[4 + offset]
	local BRx, BRy = SPARK_CORNER_COORDS[4 + offset], SPARK_CORNER_COORDS[3 + offset]

	if mirror then
		TLx, TRx = TRx, TLx
		TLy, TRy = TRy, TLy
		BLx, BRx = BRx, BLx
		BLy, BRy = BRy, BLy
	end

	return TLx, TLy, BLx, BLy, TRx, TRy, BRx, BRy
end
-- Published so subtick can reuse the same 90-degree-step texcoord shuffle
-- instead of a second copy of the same math.
WA.GetTexCoordSpark = GetTexCoordSpark

-- Recomputes the spark's texcoords. AUTO reuses the bar's own corner coords
-- (the art turns with the bar, same as bg/fg); MANUAL is the ported rotation
-- above. Depends on orientation as well as the spark fields, so this runs from
-- layoutBar (geometry/orientation changes) as well as the spark setters.
local function updateSparkRotation(region)
	local spark = region.spark
	if not spark then return end
	local o = region.orientation or "HORIZONTAL"
	if (region.sparkRotationMode or "AUTO") == "AUTO" then
		local coords = BAR_TEXCOORDS[o] or BAR_TEXCOORDS.HORIZONTAL
		spark:SetTexCoord(coords(1))
	else
		spark:SetTexCoord(GetTexCoordSpark(tonumber(region.sparkRotation) or 0, region.sparkMirror))
	end
end

-- Fraction of the remaining distance closed per second once smoothProgress
-- ticks the static path toward a new target; EPSILON is how close counts as
-- arrived, snapping the last sliver instead of crawling toward it forever.
local SMOOTH_RATE = 8
local SMOOTH_EPSILON = 0.001

-- Clamps a raw 0..1 fraction and applies `inverse` -- shared by SetProgress
-- and the static path's smoothing target, so a tween settles on exactly the
-- same number a snap would have used. The aura's configured inverse and the
-- active state's inverse combine by XOR, matching upstream's effectiveInverse.
local function clampProgress(region, p)
	if not p or p < 0 then p = 0 elseif p > 1 then p = 1 end
	if (region.inverse and true or false) ~= (region.stateInverse and true or false) then p = 1 - p end
	return p
end

-- Centers `texture` on `bar`, `distance` out along the fill axis from the
-- orientation's anchor edge, plus a cross/along offset (ox, oy). The one copy
-- of the four-case sign/axis choice -- both the spark and any sub-region
-- riding the fill axis go through this, so the two can never drift apart on a
-- vertical bar.
local function placeOnBar(bar, o, texture, distance, ox, oy)
	local anchor = SPARK_ANCHOR[o] or SPARK_ANCHOR.HORIZONTAL
	texture:ClearAllPoints()
	if o == "HORIZONTAL" then
		texture:SetPoint("CENTER", bar, anchor, distance + ox, oy)
	elseif o == "HORIZONTAL_INVERSE" then
		texture:SetPoint("CENTER", bar, anchor, -distance + ox, oy)
	elseif o == "VERTICAL" then
		texture:SetPoint("CENTER", bar, anchor, ox, -distance + oy)
	else -- VERTICAL_INVERSE
		texture:SetPoint("CENTER", bar, anchor, ox, distance + oy)
	end
end

-- Shows/hides and places the spark at the fill's leading edge, `extent` along
-- the fill axis from region.bar's origin corner (fillBar's own coordinate, so
-- the two can never disagree about where the leading edge is). Placement runs
-- even at extent == 0 -- the spark can legitimately sit at the origin edge --
-- so this cannot be folded into fillBar's extent <= 0 early return, which
-- leaves fg unresized (and its rect stale) at zero progress.
local function placeSpark(region, o, extent, p)
	local spark = region.spark
	if not spark then return end
	if not region.sparkEnabled then spark:Hide(); return end

	local hidden = region.sparkHidden or "NEVER"
	local visible = hidden == "NEVER"
		or (hidden == "FULL" and p < 1)
		or (hidden == "EMPTY" and p > 0)
		or (hidden == "BOTH" and p > 0 and p < 1)
	if not visible then spark:Hide(); return end

	placeOnBar(region.bar, o, spark, extent, region.sparkOffsetX or 0, region.sparkOffsetY or 0)
	spark:Show()
end

-- The fill orientations that grow in the same screen direction their gradient
-- runs -- SetGradientAlpha's HORIZONTAL goes left to right and its VERTICAL
-- bottom to top, so a left-anchored horizontal fill and a bottom-anchored
-- vertical one advance *with* the ramp while the other two advance against it.
-- Which end of the colour pair sits at the fill's leading edge follows from that.
local GRADIENT_WITH_FILL = {
	HORIZONTAL = true,
	VERTICAL_INVERSE = true,
}

-- Whether the gradient axis is the fill axis, and so whether the fill fraction
-- changes the colours (below). A perpendicular gradient never has its axis
-- shortened and needs no correction at all.
local function gradientTracksFill(region)
	if not region.enableGradient then return false end
	return isVertical(region.gradientOrientation or "HORIZONTAL")
		== isVertical(region.orientation or "HORIZONTAL")
end

local function lerp4(r1, g1, b1, a1, r2, g2, b2, a2, t)
	return r1 + (r2 - r1) * t, g1 + (g2 - g1) * t, b1 + (b2 - b1) * t, a1 + (a2 - a1) * t
end

-- Applies the fill's tint: a plain vertex colour, or the gradient pair.
--
-- SetGradientAlpha interpolates across the texture's *geometry*, and fillBar
-- shrinks that geometry to the fill fraction -- so handing it the configured
-- pair would squeeze the whole start-to-end ramp into however much of the bar is
-- filled. Upstream keeps its fg texture full-size and reveals a window onto it
-- with a mask, which is unavailable here: 1.12 has neither CreateMaskTexture
-- (ClassicAPI stubs CreateMaskTexturePool precisely because of that) nor
-- SetClipsChildren. Since the interpolation is linear, the same picture comes
-- out of interpolating the *colours* on the shrunk texture instead -- whichever
-- end of the pair falls on the fill's leading edge is replaced by the colour the
-- full-bar ramp would have had there. Alpha rides along with RGB.
local function updateForegroundColor(region)
	local c = region.barColor or { 1, 1, 1, 1 }
	if not region.enableGradient then
		region.fg:SetVertexColor(c[1], c[2], c[3], c[4] or 1)
		return
	end

	local c2 = region.barColor2 or { 1, 1, 0, 1 }
	local r1, g1, b1, a1 = c[1], c[2], c[3], c[4] or 1
	local r2, g2, b2, a2 = c2[1], c2[2], c2[3], c2[4] or 1
	if gradientTracksFill(region) then
		local p = region.progress or 0
		if p < 0 then p = 0 elseif p > 1 then p = 1 end
		if GRADIENT_WITH_FILL[region.orientation or "HORIZONTAL"] then
			r2, g2, b2, a2 = lerp4(r1, g1, b1, a1, r2, g2, b2, a2, p)
		else
			r1, g1, b1, a1 = lerp4(r1, g1, b1, a1, r2, g2, b2, a2, 1 - p)
		end
	end
	region.fg:SetGradientAlpha(region.gradientOrientation or "HORIZONTAL",
		r1, g1, b1, a1, r2, g2, b2, a2)
end

-- Sizes and crops the fill texture to region.progress. Both have to move
-- together: the texture is cropped to the same fraction it is scaled to, or the
-- art would squash instead of being revealed.
local function fillBar(region)
	local o = region.orientation or "HORIZONTAL"
	local align = BAR_ALIGN[o] or BAR_ALIGN.HORIZONTAL
	local coords = BAR_TEXCOORDS[o] or BAR_TEXCOORDS.HORIZONTAL
	local p = region.progress or 0
	local fg = region.fg

	local vertical = isVertical(o)
	local extent = (vertical and (region.barH or 0) or (region.barW or 0)) * p
	-- A zero-dimension texture is not worth asking the client to draw.
	if extent <= 0 then
		fg:Hide()
	else
		fg:ClearAllPoints()
		fg:SetPoint(align[1], region.bar, align[1])
		fg:SetPoint(align[2], region.bar, align[2])
		-- Two corners on one edge fix the cross axis, leaving the fill axis free
		-- to be set explicitly.
		if vertical then fg:SetHeight(extent) else fg:SetWidth(extent) end
		fg:SetTexCoord(coords(p))
		-- Resizing means a gradient along the fill axis spans only the drawn
		-- portion, so its colours have to be re-derived from the new fraction
		-- (see updateForegroundColor). Gated, so a bar without such a gradient
		-- keeps the zero-extra-work path through this hot function.
		if gradientTracksFill(region) then updateForegroundColor(region) end
		fg:Show()
	end

	placeSpark(region, o, extent, p)
end

-- The static path's smoothProgress OnUpdate. A single shared function value
-- rather than a fresh closure per call, so re-installing it on every
-- UpdateValue is free -- and, since all the animation state lives on the
-- region (progress/targetProgress) rather than in an upvalue, it must be
-- installed unconditionally: a GetScript guard meant to avoid replacing an
-- in-flight ease can't tell this handler apart from UpdateTime's countdown
-- OnUpdate, and would leave that countdown running against a state that no
-- longer has a meaningful expiration.
local function smoothOnUpdate()
	local delta = this.targetProgress - this.progress
	local absDelta = delta < 0 and -delta or delta
	if absDelta < SMOOTH_EPSILON then
		this.progress = this.targetProgress
		this:SetScript("OnUpdate", nil)
	else
		this.progress = this.progress + delta * math.min(1, arg1 * SMOOTH_RATE)
	end
	fillBar(this)
end

-- Lays the icon and the bar out so they share the region's box without
-- overlapping: the icon takes a square off one end of the *fill* axis, the bar
	-- takes the rest (WA2's AuraBar orientHorizontal/orientVertical). icon_side's
-- stored LEFT/RIGHT means top/bottom on a vertical bar -- upstream reuses the
-- one field the same way, so the labels change but the data doesn't.
--
-- One divergence from upstream: the bar's *cross* axis is pinned to the region's
-- own edges, not to the icon square's corners. Upstream anchors the bar corner
-- to the icon corner, which is identical whenever the region is shaped for its
-- orientation (the square is then exactly the cross-axis extent) but insets the
-- bar by an arbitrary amount when it isn't -- e.g. a vertical bar left at the
-- default 200x18 loses its left edge to the 18px square's own centering.
local function layoutBar(region)
	local bar, iconFrame = region.bar, region.iconFrame
	iconFrame:ClearAllPoints()
	bar:ClearAllPoints()

	local w, h = region.regionWidth or 0, region.regionHeight or 0
	local vertical = isVertical(region.orientation)

	if region.iconVisible then
		-- Square, sized to the smaller dimension so it can never overflow the
		-- region (WA2's own `math.min(self.height, self.width)`). For a
		-- region shaped for its orientation that smaller dimension *is* the
		-- cross axis.
		local size = math.min(w, h)
		iconFrame:SetWidth(size)
		iconFrame:SetHeight(size)
		if not vertical then
			region.barW, region.barH = w - size, h
			if region.iconSide == "RIGHT" then
				iconFrame:SetPoint("RIGHT", region, "RIGHT")
				bar:SetPoint("TOPLEFT", region, "TOPLEFT")
				bar:SetPoint("BOTTOMRIGHT", region, "BOTTOMRIGHT", -size, 0)
			else
				iconFrame:SetPoint("LEFT", region, "LEFT")
				bar:SetPoint("TOPLEFT", region, "TOPLEFT", size, 0)
				bar:SetPoint("BOTTOMRIGHT", region, "BOTTOMRIGHT")
			end
		else
			region.barW, region.barH = w, h - size
			if region.iconSide == "RIGHT" then
				iconFrame:SetPoint("BOTTOM", region, "BOTTOM")
				bar:SetPoint("TOPLEFT", region, "TOPLEFT")
				bar:SetPoint("BOTTOMRIGHT", region, "BOTTOMRIGHT", 0, size)
			else
				iconFrame:SetPoint("TOP", region, "TOP")
				bar:SetPoint("TOPLEFT", region, "TOPLEFT", 0, -size)
				bar:SetPoint("BOTTOMRIGHT", region, "BOTTOMRIGHT")
			end
		end
		iconFrame:Show()
	else
		iconFrame:Hide()
		region.barW, region.barH = w, h
		bar:SetAllPoints(region)
	end

	-- The background is the whole texture, rotated the same way as the fill so
	-- the empty part of the bar shares its grain.
	local coords = BAR_TEXCOORDS[region.orientation or "HORIZONTAL"] or BAR_TEXCOORDS.HORIZONTAL
	region.bg:SetTexCoord(coords(1))
	updateSparkRotation(region)
	fillBar(region)
end

WA.RegisterRegionType("progressbar", {
	displayName = "Progress Bar",
	description = "A bar that drains or fills with the time left, with an optional icon.",
	defaults = {
		width = 200,
		height = 18,
		alpha = 1,
		texture = "Blizzard",
		textureSource = "LSM",
		textureInput = "",
		barColor = { 0.2, 0.6, 1, 1 },
		barColor2 = { 1, 1, 0, 1 },
		enableGradient = false,
		gradientOrientation = "HORIZONTAL",
		backgroundColor = { 0, 0, 0, 0.5 },
		orientation = "HORIZONTAL",
		inverse = false,
		smoothProgress = false,
		icon = true,
		icon_side = "LEFT",
		icon_color = { 1, 1, 1, 1 },
		desaturate = false,
		iconSource = -1,
		displayIcon = "",
		zoom = 0,
		useAdjustededMin = false,
		adjustedMin = "",
		useAdjustededMax = false,
		adjustedMax = "",
		progressSource = -1,
		progressSourceManualValue = 0,
		progressSourceManualTotal = 100,
		spark = false,
		sparkTexture = SPARK_DEFAULT,
		sparkColor = { 1, 1, 1, 1 },
		sparkWidth = 10,
		sparkHeight = 30,
		sparkBlendMode = "ADD",
		sparkOffsetX = 0,
		sparkOffsetY = 0,
		sparkRotationMode = "AUTO",
		sparkRotation = 0,
		sparkMirror = false,
		sparkDesaturate = false,
		sparkHidden = "NEVER",
		anchorFrameType = "SCREEN",
		selfPoint = "CENTER",
		anchorPoint = "CENTER",
		xOffset = 0,
		yOffset = -100,
		frameStrata = 1,
	},
	icon = "Interface\\Icons\\Spell_Nature_TimeStop",
	getSubRegionAnchors = function() return PROGRESSBAR_SUB_ANCHORS end,
	-- List-row preview: a background + a fill sized to a fraction of the bar
	-- along the orientation's axis, an icon square carved out on icon_side when
	-- shown. Not the runtime's cropped-texcoord bar (layoutBar/fillBar above) --
	-- this box is too small for that fidelity to read, so it's plain
	-- width/height + SetPoint.
	createThumbnail = function(parent)
		local frame = CreateFrame("Frame", nil, parent)
		local bg = frame:CreateTexture(nil, "BACKGROUND")
		frame.bg = bg
		local fill = frame:CreateTexture(nil, "ARTWORK")
		frame.fill = fill
		local icon = frame:CreateTexture(nil, "OVERLAY")
		frame.icon = icon
		return frame
	end,
	modifyThumbnail = function(frame, data)
		local W = WA.Widgets
		local size = frame:GetHeight() or 0
		local o = data.orientation or "HORIZONTAL"
		local vertical = isVertical(o)

		-- The mock bar is a rectangle centred in the square box, not the box
		-- itself (WA2's thumbnail draws a 26x15 bar in a 32px frame). A bar
		-- filling the square would read as an icon, which is the one thing this
		-- preview exists to tell apart -- and a full-box icon carve-out would
		-- then leave the fill no length at all.
		local long, thick = size * 0.82, size * 0.47
		local barW, barH = long, thick
		if vertical then barW, barH = thick, long end

		local bgc = data.backgroundColor or { 0, 0, 0, 0.5 }
		frame.bg:ClearAllPoints()
		frame.bg:SetWidth(barW)
		frame.bg:SetHeight(barH)
		frame.bg:SetPoint("CENTER", frame, "CENTER")
		frame.bg:SetTexture(bgc[1], bgc[2], bgc[3], bgc[4] or 1)

		-- The icon square eats one end of the bar's long axis. icon_side is
		-- LEFT/RIGHT only, so a vertical bar carves from its bottom.
		local iconLen = 0
		frame.icon:ClearAllPoints()
		if data.icon then
			iconLen = thick
			frame.icon:SetWidth(thick)
			frame.icon:SetHeight(thick)
			frame.icon:SetTexture(WA.ResolveDisplayIcon(data) or "Interface\\Icons\\INV_Misc_QuestionMark")
			if vertical then
				frame.icon:SetPoint("BOTTOM", frame.bg, "BOTTOM")
			elseif data.icon_side == "RIGHT" then
				frame.icon:SetPoint("RIGHT", frame.bg, "RIGHT")
			else
				frame.icon:SetPoint("LEFT", frame.bg, "LEFT")
			end
			frame.icon:Show()
		else
			frame.icon:Hide()
		end

		local path = (data.textureSource == "Picker") and data.textureInput or W.BarTexturePath(data.texture)
		frame.fill:SetTexture(path)
		local bc = data.barColor or { 0.2, 0.6, 1, 1 }
		frame.fill:SetVertexColor(bc[1], bc[2], bc[3], bc[4] or 1)

		local extent = (long - iconLen) * 0.6
		frame.fill:ClearAllPoints()
		if extent <= 0 then
			frame.fill:Hide()
		else
			if not vertical then
				frame.fill:SetWidth(extent)
				frame.fill:SetHeight(thick)
				if o == "HORIZONTAL_INVERSE" then
					if data.icon and data.icon_side == "RIGHT" then
						frame.fill:SetPoint("RIGHT", frame.icon, "LEFT")
					else
						frame.fill:SetPoint("RIGHT", frame.bg, "RIGHT")
					end
				else
					if data.icon and data.icon_side ~= "RIGHT" then
						frame.fill:SetPoint("LEFT", frame.icon, "RIGHT")
					else
						frame.fill:SetPoint("LEFT", frame.bg, "LEFT")
					end
				end
			else
				frame.fill:SetWidth(thick)
				frame.fill:SetHeight(extent)
				if o == "VERTICAL_INVERSE" then
					frame.fill:SetPoint("TOP", frame.bg, "TOP")
				elseif data.icon then
					frame.fill:SetPoint("BOTTOM", frame.icon, "TOP")
				else
					frame.fill:SetPoint("BOTTOM", frame.bg, "BOTTOM")
				end
			end
			frame.fill:Show()
		end
	end,
	properties = WA.regionPrototype.AddProgressProperties(WA.regionPrototype.AddProperties({
		-- Both axes share one range: a VERTICAL bar is a tall narrow region, so a
		-- height capped near a horizontal bar's thickness would make that
		-- orientation unbuildable from the options tab.
		width = { display = "Width", setter = "SetRegionWidth", type = "number", min = 8, max = 400, step = 1 },
		height = { display = "Height", setter = "SetRegionHeight", type = "number", min = 8, max = 400, step = 1 },
		texture = { display = "Bar Texture", setter = "SetBarTexture", type = "list", values = BAR_TEXTURE_LABELS },
		textureSource = { display = "Texture Source", setter = "SetBarTextureSource", type = "list", values = { LSM = "Bundled", Picker = "Custom path" } },
		textureInput = { display = "Texture Path", setter = "SetBarTextureInput", type = "string" },
		barColor = { display = "Bar Color", setter = "Color", type = "color" },
		barColor2 = { display = "Gradient End Color", setter = "SetBarColor2", type = "color" },
		enableGradient = { display = "Gradient Enabled", setter = "SetGradientEnabled", type = "bool" },
		gradientOrientation = { display = "Gradient Orientation", setter = "SetGradientOrientation", type = "list", values = { HORIZONTAL = "Horizontal", VERTICAL = "Vertical" } },
		backgroundColor = { display = "Background Color", setter = "SetBackgroundColor", type = "color" },
		orientation = { display = "Orientation", setter = "SetOrientation", type = "list", values = BAR_ORIENTATION_LABELS },
		inverse = { display = "Inverse", setter = "SetInverse", type = "bool" },
		icon = { display = "Show Icon", setter = "SetIconVisible", type = "bool" },
		icon_side = { display = "Icon Side", setter = "SetIconSide", type = "list", values = { LEFT = "Left", RIGHT = "Right" } },
		icon_color = { display = "Icon Color", setter = "SetIconColor", type = "color" },
		desaturate = { display = "Desaturate", setter = "SetDesaturated", type = "bool" },
		zoom = { display = "Zoom", setter = "SetZoom", type = "number", min = 0, max = 1, step = 0.05 },
		iconSource = { display = "Icon Source", setter = "SetIconSource", type = "list", values = { [-1] = "Automatic", [0] = "Manual" }, default = 0 },
		displayIcon = { display = "Manual Icon", setter = "SetIcon", type = "icon" },
		sparkColor = { display = "Spark Color", setter = "SetSparkColor", type = "color" },
		sparkWidth = { display = "Spark Width", setter = "SetSparkWidth", type = "number", min = 1, max = 400, step = 1 },
		sparkHeight = { display = "Spark Height", setter = "SetSparkHeight", type = "number", min = 1, max = 400, step = 1 },
	})),
	options = function(data)
		local W = WA.Widgets
		local fields = {
			{ type = "header", name = "Progress Bar" },
			{
				type = "select", name = "Texture source", key = "textureSource",
				values = { "LSM", "Picker" },
				labels = { LSM = "Bundled", Picker = "Custom path" },
				get = function() return data.textureSource or "LSM" end,
				set = function(v)
					data.textureSource = v
					WA.Add(data, true)
					-- Repaints the tab: the field below swaps between the swatch
					-- dropdown and the free-text path box.
					WA.RefreshOptions()
				end,
			},
			(data.textureSource or "LSM") == "Picker" and {
				type = "input", name = "Texture path", key = "textureInput",
				get = function() return data.textureInput end,
				set = function(v) data.textureInput = v; WA.Add(data, true) end,
			} or {
				type = "select", name = "Bar texture", key = "texture",
				values = W.BarTextures(), swatches = W.BarTextureSwatches(),
				get = function() return data.texture end,
				set = function(v) data.texture = v; WA.Add(data, true) end,
			},
			{
				type = "color", name = "Bar color", key = "barColor",
				get = function() return data.barColor end,
				set = function(v) data.barColor = v; WA.Add(data, true) end,
			},
			{
				type = "toggle", name = "Gradient", key = "enableGradient",
				get = function() return data.enableGradient end,
				set = function(v)
					data.enableGradient = v
					WA.Add(data, true)
					-- Repaints the tab: the gradient end colour and direction
					-- fields below only apply with the gradient on.
					WA.RefreshOptions()
				end,
			},
		}
		if data.enableGradient then
			table.insert(fields, {
				type = "color", name = "Gradient end colour", key = "barColor2",
				get = function() return data.barColor2 end,
				set = function(v) data.barColor2 = v; WA.Add(data, true) end,
			})
			table.insert(fields, {
				type = "select", name = "Gradient direction", key = "gradientOrientation",
				values = { "HORIZONTAL", "VERTICAL" },
				labels = { HORIZONTAL = "Horizontal", VERTICAL = "Vertical" },
				get = function() return data.gradientOrientation end,
				set = function(v) data.gradientOrientation = v; WA.Add(data, true) end,
			})
		end
		local barFields = {
			{
				type = "color", name = "Background color", key = "backgroundColor",
				get = function() return data.backgroundColor end,
				set = function(v) data.backgroundColor = v; WA.Add(data, true) end,
			},
			{
				type = "select", name = "Orientation", key = "orientation", half = true,
				values = BAR_ORIENTATIONS,
				labels = BAR_ORIENTATION_LABELS,
				get = function() return data.orientation end,
				set = function(v)
					-- An INVERSE flip reverses which end the fill grows from, so
					-- the icon has to jump sides to stay on the same physical end
					-- of the bar.
					if isInverse(v) ~= isInverse(data.orientation) then
						data.icon_side = data.icon_side == "LEFT" and "RIGHT" or "LEFT"
					end
					-- Swap the dimensions when the *axis* changes (not on a mere
					-- direction flip): the default 200x18 becomes a bar 18px tall
					-- whose icon square (min(w,h), also 18) eats the entire fill
					-- axis otherwise, leaving nothing to draw. Flipping back swaps
					-- again, so this is self-inverse rather than a one-way edit of
					-- saved data. The axis change also moves the icon to the bar's
					-- other physical end, same as the INVERSE case above -- both
					-- can fire on one change and cancel out.
					if isVertical(v) ~= isVertical(data.orientation) then
						data.width, data.height = data.height, data.width
						data.icon_side = data.icon_side == "LEFT" and "RIGHT" or "LEFT"
					end
					data.orientation = v
					WA.Add(data, true)
					-- Repaints the tab: the icon-side labels and the size sliders
					-- below all read off what just changed.
					WA.RefreshOptions()
				end,
			},
			{
				type = "range", name = "Alpha", key = "alpha", min = 0, max = 1, step = 0.05, half = true,
				get = function() return data.alpha end,
				set = function(v) data.alpha = v; WA.Add(data, true) end,
			},
			{
				type = "toggle", name = "Inverse (fill as it expires)", key = "inverse",
				get = function() return data.inverse end,
				set = function(v) data.inverse = v; WA.Add(data, true) end,
			},
			{
				type = "toggle", name = "Smooth progress", key = "smoothProgress",
				get = function() return data.smoothProgress end,
				set = function(v) data.smoothProgress = v; WA.Add(data, true) end,
			},
			{ type = "header", name = "Icon" },
			{
				type = "toggle", name = "Show icon", key = "icon", half = true,
				get = function() return data.icon end,
				set = function(v)
					data.icon = v
					WA.Add(data, true)
					-- Repaints the tab: the icon fields below only apply with the
					-- icon on, so they appear/disappear with this toggle.
					WA.RefreshOptions()
				end,
			},
		}
		for _, f in ipairs(barFields) do
			table.insert(fields, f)
		end
		if data.icon ~= false then
			local iconFields = {
				{
					type = "toggle", name = "Desaturate", key = "desaturate", half = true,
					get = function() return data.desaturate end,
					set = function(v) data.desaturate = v; WA.Add(data, true) end,
				},
				{
					type = "select", name = "Icon side", key = "icon_side", half = true,
					values = ICON_SIDES,
					-- A vertical bar keeps the same two stored values; only how they
					-- read changes, so the labels follow the orientation.
					labels = isVertical(data.orientation)
						and { LEFT = "Top", RIGHT = "Bottom" }
						or { LEFT = "Left", RIGHT = "Right" },
					get = function() return data.icon_side end,
					set = function(v) data.icon_side = v; WA.Add(data, true) end,
				},
				{
					type = "range", name = "Zoom", key = "zoom", min = 0, max = 1, step = 0.05, half = true,
					get = function() return data.zoom end,
					set = function(v) data.zoom = v; WA.Add(data, true) end,
				},
				{
					type = "select", name = "Icon source", key = "iconSource",
					values = { -1, 0 },
					labels = { [-1] = "Automatic (trigger)", [0] = "Manual" },
					get = function() return data.iconSource end,
					set = function(v) data.iconSource = v; WA.Add(data, true); WA.RefreshList() end,
				},
				{
					type = "icon", name = "Manual icon", key = "displayIcon",
					get = function() return data.displayIcon end,
					set = function(v) data.displayIcon = v; WA.Add(data, true); WA.RefreshList() end,
				},
				{
					type = "color", name = "Icon color", key = "icon_color",
					get = function() return data.icon_color end,
					set = function(v) data.icon_color = v; WA.Add(data, true) end,
				},
			}
			for _, f in ipairs(iconFields) do
				table.insert(fields, f)
			end
		end
		local sparkFields = {
			{ type = "header", name = "Spark" },
			{
				type = "toggle", name = "Show spark", key = "spark", half = true,
				get = function() return data.spark end,
				set = function(v)
					data.spark = v
					WA.Add(data, true)
					-- Repaints the tab: every other spark field below only applies
					-- with the spark on, so they appear/disappear with this toggle.
					WA.RefreshOptions()
				end,
			},
		}
		for _, f in ipairs(sparkFields) do
			table.insert(fields, f)
		end
		if data.spark then
			local sparkDetailFields = {
				{
					type = "input", name = "Spark texture", key = "sparkTexture",
					get = function() return data.sparkTexture end,
					set = function(v) data.sparkTexture = v; WA.Add(data, true) end,
				},
				{
					type = "color", name = "Spark color", key = "sparkColor",
					get = function() return data.sparkColor end,
					set = function(v) data.sparkColor = v; WA.Add(data, true) end,
				},
				{
					type = "range", name = "Spark width", key = "sparkWidth", min = 1, max = 200, step = 1, half = true,
					get = function() return data.sparkWidth end,
					set = function(v) data.sparkWidth = v; WA.Add(data, true) end,
				},
				{
					type = "range", name = "Spark height", key = "sparkHeight", min = 1, max = 200, step = 1, half = true,
					get = function() return data.sparkHeight end,
					set = function(v) data.sparkHeight = v; WA.Add(data, true) end,
				},
				{
					type = "range", name = "Spark X offset", key = "sparkOffsetX", min = -100, max = 100, step = 1, half = true,
					get = function() return data.sparkOffsetX end,
					set = function(v) data.sparkOffsetX = v; WA.Add(data, true) end,
				},
				{
					type = "range", name = "Spark Y offset", key = "sparkOffsetY", min = -100, max = 100, step = 1, half = true,
					get = function() return data.sparkOffsetY end,
					set = function(v) data.sparkOffsetY = v; WA.Add(data, true) end,
				},
				{
					type = "select", name = "Spark blend mode", key = "sparkBlendMode",
					values = { "BLEND", "ADD" },
					labels = { BLEND = "Blend", ADD = "Add" },
					get = function() return data.sparkBlendMode end,
					set = function(v) data.sparkBlendMode = v; WA.Add(data, true) end,
				},
				{
					type = "toggle", name = "Desaturate", key = "sparkDesaturate", half = true,
					get = function() return data.sparkDesaturate end,
					set = function(v) data.sparkDesaturate = v; WA.Add(data, true) end,
				},
				{
					type = "toggle", name = "Mirror", key = "sparkMirror", half = true,
					get = function() return data.sparkMirror end,
					set = function(v) data.sparkMirror = v; WA.Add(data, true) end,
				},
				{
					type = "select", name = "Spark rotation mode", key = "sparkRotationMode",
					values = { "AUTO", "MANUAL" },
					labels = { AUTO = "Automatic", MANUAL = "Manual" },
					get = function() return data.sparkRotationMode end,
					set = function(v)
						data.sparkRotationMode = v
						WA.Add(data, true)
						-- Repaints the tab: the rotation field below is meaningless
						-- (and hidden) unless the mode is Manual.
						WA.RefreshOptions()
					end,
				},
			}
			for _, f in ipairs(sparkDetailFields) do
				table.insert(fields, f)
			end
			if data.sparkRotationMode == "MANUAL" then
				table.insert(fields, {
					type = "select", name = "Spark rotation", key = "sparkRotation",
					values = { 0, 90, 180, 270 },
					labels = { [0] = "0", [90] = "90", [180] = "180", [270] = "270" },
					get = function() return data.sparkRotation end,
					set = function(v) data.sparkRotation = v; WA.Add(data, true) end,
				})
			end
			table.insert(fields, {
				type = "select", name = "Spark visibility", key = "sparkHidden",
				values = { "NEVER", "FULL", "EMPTY", "BOTH" },
				labels = { NEVER = "Always", FULL = "Hide when full", EMPTY = "Hide when empty", BOTH = "Hide at full and empty" },
				get = function() return data.sparkHidden end,
				set = function(v) data.sparkHidden = v; WA.Add(data, true) end,
			})
		end
		local sizeFields = {
			{ type = "header", name = "Size" },
			{
				type = "range", name = "Width", key = "width", min = 8, max = 400, step = 1, half = true,
				get = function() return data.width end,
				set = function(v) data.width = v; WA.Add(data, true) end,
			},
			{
				type = "range", name = "Height", key = "height", min = 8, max = 400, step = 1, half = true,
				get = function() return data.height end,
				set = function(v) data.height = v; WA.Add(data, true) end,
			},
		}
		for _, f in ipairs(sizeFields) do
			table.insert(fields, f)
		end
		for _, f in ipairs(WA.regionPrototype.ProgressOptions(data)) do
			table.insert(fields, f)
		end
		for _, f in ipairs(WA.regionPrototype.PositionOptions(data)) do
			table.insert(fields, f)
		end
		return fields
	end,
	create = function(parent, data)
		local region = CreateFrame("Frame", nil, parent)

		-- A plain Frame holding the two fill textures, not a StatusBar -- see the
		-- header comment above layoutBar for why we crop the fill ourselves.
		-- Both textures live on it rather than on the region: a texture on the
		-- region would be covered by any child frame (a child's draw layers all
		-- sit above its parent's).
		local bar = CreateFrame("Frame", nil, region)
		region.bar = bar
		local bg = bar:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints(bar)
		region.bg = bg
		local fg = bar:CreateTexture(nil, "ARTWORK")
		region.fg = fg

		-- OVERLAY draws above the fill's ARTWORK layer, so the spark rides on
		-- top of the fill rather than being covered by it.
		local spark = bar:CreateTexture(nil, "OVERLAY")
		region.spark = spark

		-- The icon gets a frame of its own so it can be levelled above the bar --
		-- otherwise a texture on the region sits under it, and the icon disappears
		-- wherever the two overlap.
		local iconFrame = CreateFrame("Frame", nil, region)
		local iconTex = iconFrame:CreateTexture(nil, "ARTWORK")
		iconTex:SetAllPoints(iconFrame)
		iconTex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		region.iconFrame = iconFrame
		region.iconTex = iconTex

		-- Subtext anchors to the bar, not the whole region, so "%p at RIGHT"
		-- tracks the end of the fill rather than sitting past the icon.
		region.subRegionAnchor = bar

		WA.regionPrototype.create(region)
		function region:GetSubAnchorTarget(key)
			if key == "region" or key == "bar" then return self.bar end
			if key == "icon" then return self.iconFrame end
			if key == "fg" then return self.fg end
			if key == "bg" then return self.bg end
			if key == "spark" or key == "SPARK" then return self.spark end
			if string.find(key, "^ICON_") then return self.iconFrame end
			return self.bar
		end

		-- Name/time text rides on %n/%p subtext elements; this only paints the
		-- icon + drives the fill (below). The %c refresh goes first so every
		-- subtext that follows reads values computed once.
		function region:Update()
			local state = self.state
			if not state then return end
			self:RefreshCustomText(true)
			self:UpdateIcon()
			WA.regionPrototype.UpdateProgress(self)
		end

		-- Progress is always a 0..1 fraction, so `inverse` is a single
		-- subtraction and the timed/static paths share one setter.
		function region:SetProgress(p)
			self.progress = clampProgress(self, p)
			fillBar(self)
		end

		-- Static progress (a Health/Power generic trigger, or the manual
		-- progress source): a fixed value/total fill. With smoothProgress off
		-- this snaps like before, clearing any OnUpdate. With it on, an
		-- OnUpdate eases region.progress toward the target and clears itself
		-- once it converges.
		--
		-- Only this path is smoothed. The timed path below recomputes progress
		-- from the clock on every frame of its own OnUpdate, so it is already
		-- smooth; a frame has one OnUpdate script, and installing a second one
		-- here would fight the countdown for it instead of complementing it.
		function region:UpdateValue()
			local total = self.total or 0
			local target = clampProgress(self, total > 0 and (self.value or 0) / total or 1)

			if not self.smoothProgress then
				self:SetScript("OnUpdate", nil)
				self.progress = target
				fillBar(self)
				return
			end

			self.targetProgress = target
			self:SetScript("OnUpdate", smoothOnUpdate)
		end

		-- The bar *fill* still needs a per-frame recompute (pfUI's
		-- StatusBarOnUpdate) -- that's the region's own animation, separate from
		-- the %p subtext (which repaints via FrameTick). Text no longer lives here.
		function region:UpdateTime()
			if self.paused then
				local remain = self.remaining or 0
				if self.duration and self.duration > 0 then
					self:SetProgress(remain / self.duration)
				else
					self:SetProgress(1)
				end
				self:SetScript("OnUpdate", nil)
				return
			end
			if self.duration and self.duration > 0 then
				self:SetScript("OnUpdate", function()
					if not this:IsShown() then this:SetScript("OnUpdate", nil); return end
					local remain = this.expirationTime - GetTime()
					this:SetProgress(remain / this.duration)
					if remain <= 0 then this:SetScript("OnUpdate", nil) end
				end)
			else
				self:SetProgress(1)
				self:SetScript("OnUpdate", nil)
			end
		end

		-- The one door a sub-region restricted to progressbar (via its own
		-- `supports`) may use to reach the bar's geometry: orientation, the
		-- usable width/height layoutBar already carved out for the icon, and
		-- the frame to parent onto.
		function region:GetBarGeometry()
			return self.orientation or "HORIZONTAL", self.barW or 0, self.barH or 0, self.bar
		end

		function region:PlaceOnBar(texture, distance, ox, oy)
			placeOnBar(self.bar, self.orientation or "HORIZONTAL", texture, distance, ox, oy)
		end

		-- The third door: whether the fill is reading backwards. `PlaceOnBar`
		-- doesn't apply this itself -- the spark rides region.progress, which
		-- clampProgress has already flipped, and flipping again there would be
		-- double-counted.
		function region:GetInverse()
			return (self.inverse and true or false) ~= (self.stateInverse and true or false)
		end

		-- The fourth door: the displayed fill fraction, 0..1, with `inverse`
		-- already applied by clampProgress -- not the raw progress value.
		function region:GetProgress()
			return self.progress or 0
		end

		region:Hide()
		return region
	end,
	modify = function(region, data)
		local W = WA.Widgets

		function region:SetRegionWidth(w) self.regionWidth = w; self:SetWidth(w); layoutBar(self) end
		function region:SetRegionHeight(h) self.regionHeight = h; self:SetHeight(h); layoutBar(self) end
		function region:SetOrientation(o) self.orientation = o; layoutBar(self) end
		function region:SetIconVisible(b) self.iconVisible = b and true or false; layoutBar(self) end
		function region:SetIconSide(s) self.iconSide = s; layoutBar(self) end

		-- SetTexture drops the tint with the old texture object, so the fg colour
		-- is re-applied after through UpdateForegroundColor -- calling
		-- SetVertexColor directly here would silently flatten an active gradient
		-- back to a solid tint on every texture change. The background has no
		-- gradient state, so it keeps re-applying its own copy directly; its
		-- texcoords are per-orientation and layoutBar restores those.
		function region:SetBarTexture(name)
			self.barTexture = name
			local path = (self.textureSource == "Picker") and self.textureInput or W.BarTexturePath(name)
			self.fg:SetTexture(path)
			self:UpdateForegroundColor()
			-- The background is the same art tinted dark, so the empty part of
			-- the bar reads as the same object as the filled part.
			self.bg:SetTexture(path)
			local b = self.backgroundColor or { 0, 0, 0, 0.5 }
			self.bg:SetVertexColor(b[1], b[2], b[3], b[4] or 1)
			layoutBar(self)
		end
		function region:SetBarTextureSource(v) self.textureSource = v; self:SetBarTexture(self.barTexture) end
		function region:SetBarTextureInput(v) self.textureInput = v; self:SetBarTexture(self.barTexture) end
		-- Gradient and vertex tint replace each other on the same texture object,
		-- not layers -- SetGradientAlpha and SetVertexColor both stomp whatever
		-- the other last set. Every caller that would have tinted self.fg routes
		-- through here instead, so enabling/disabling the gradient always leaves
		-- the texture in one consistent state.
		function region:UpdateForegroundColor() updateForegroundColor(self) end
		function region:Color(r, g, b, a)
			self.barColor = { r, g, b, a or 1 }
			self:UpdateForegroundColor()
		end
		function region:SetBarColor2(r, g, b, a)
			self.barColor2 = { r, g, b, a or 1 }
			self:UpdateForegroundColor()
		end
		function region:SetGradientEnabled(b)
			self.enableGradient = b and true or false
			self:UpdateForegroundColor()
		end
		function region:SetGradientOrientation(o)
			self.gradientOrientation = o
			self:UpdateForegroundColor()
		end
		function region:SetBackgroundColor(r, g, b, a)
			self.backgroundColor = { r, g, b, a or 1 }
			self.bg:SetVertexColor(r, g, b, a or 1)
		end
		function region:SetInverse(b)
			self.inverse = b and true or false
			-- Re-derive the fill from the live state so the flip is immediate
			-- rather than waiting for the next OnUpdate tick or state change.
			if self.state then WA.regionPrototype.UpdateProgress(self) end
		end

		function region:SetSparkEnabled(b) self.sparkEnabled = b and true or false; fillBar(self) end
		function region:SetSparkTexture(path) self.spark:SetTexture(WA.DrawableTexture(path) or SPARK_DEFAULT) end
		function region:SetSparkColor(r, g, b, a) self.spark:SetVertexColor(r, g, b, a or 1) end
		function region:SetSparkWidth(w) self.spark:SetWidth(w) end
		function region:SetSparkHeight(h) self.spark:SetHeight(h) end
		function region:SetSparkBlendMode(mode) self.spark:SetBlendMode(mode) end
		function region:SetSparkDesaturate(b) self.spark:SetDesaturated(b and true or false) end
		function region:SetSparkOffsetX(x) self.sparkOffsetX = x; fillBar(self) end
		function region:SetSparkOffsetY(y) self.sparkOffsetY = y; fillBar(self) end
		function region:SetSparkRotationMode(mode) self.sparkRotationMode = mode; updateSparkRotation(self) end
		function region:SetSparkRotation(deg) self.sparkRotation = deg; updateSparkRotation(self) end
		function region:SetSparkMirror(b) self.sparkMirror = b and true or false; updateSparkRotation(self) end
		function region:SetSparkHidden(mode) self.sparkHidden = mode; fillBar(self) end

		function region:SetDesaturated(b) self.iconTex:SetDesaturated(b and true or false) end
		function region:SetIconColor(r, g, b, a) self.iconTex:SetVertexColor(r, g, b, a or 1) end
		function region:SetZoom(z)
			local inset = 0.07 + (z or 0) * 0.20
			self.iconTex:SetTexCoord(inset, 1 - inset, inset, 1 - inset)
		end

		-- Same icon resolution as the icon region (WA2's Icon.lua UpdateIcon).
		function region:SetIconSource(source) self.iconSource = source; self:UpdateIcon() end
		function region:SetIcon(path) self.displayIcon = path; self:UpdateIcon() end
		function region:UpdateIcon()
			local path
			if self.iconSource == 0 then
				path = self.displayIcon
			else
				path = (self.state and self.state.icon) or self.displayIcon
			end
			self.iconTex:SetTexture(WA.DrawableTexture(path) or "Interface\\Icons\\INV_Misc_QuestionMark")
		end

		-- ApplyPosition may SetParent, which resets child frame levels (and
		-- strata, if inherited), so both are re-asserted right after it.
		WA.regionPrototype.ApplyPosition(region, data)
		local base = region:GetFrameLevel()
		region.bar:SetFrameLevel(base + 1)
		region.iconFrame:SetFrameLevel(base + 2)

		region.inverse = data.inverse and true or false
		region.smoothProgress = data.smoothProgress and true or false
		region.orientation = data.orientation
		region.iconVisible = data.icon ~= false
		region.iconSide = data.icon_side

		region.sparkEnabled = data.spark and true or false
		region.sparkOffsetX = data.sparkOffsetX or 0
		region.sparkOffsetY = data.sparkOffsetY or 0
		region.sparkRotationMode = data.sparkRotationMode or "AUTO"
		region.sparkRotation = data.sparkRotation or 0
		region.sparkMirror = data.sparkMirror and true or false
		region.sparkHidden = data.sparkHidden or "NEVER"
		region:SetSparkTexture(data.sparkTexture)
		local spc = data.sparkColor or { 1, 1, 1, 1 }
		region:SetSparkColor(spc[1], spc[2], spc[3], spc[4])
		region:SetSparkWidth(data.sparkWidth or 10)
		region:SetSparkHeight(data.sparkHeight or 30)
		region:SetSparkBlendMode(data.sparkBlendMode or "ADD")
		region:SetSparkDesaturate(data.sparkDesaturate)
		updateSparkRotation(region)

		-- Full until a state supplies a real fraction, so a display being
		-- configured (or previewed) isn't an empty box. Preserved across a
		-- re-modify so a config edit can't blank a running bar.
		region.progress = region.progress or 1
		region:SetRegionWidth(data.width)
		region:SetRegionHeight(data.height)
		region:SetRegionAlpha(data.alpha)

		region.barColor = data.barColor or { 0.2, 0.6, 1, 1 }
		region.barColor2 = data.barColor2 or { 1, 1, 0, 1 }
		region.enableGradient = data.enableGradient and true or false
		region.gradientOrientation = data.gradientOrientation or "HORIZONTAL"
		region.backgroundColor = data.backgroundColor or { 0, 0, 0, 0.5 }
		region.textureSource = data.textureSource
		region.textureInput = data.textureInput
		region:SetBarTexture(data.texture)

		region:SetZoom(data.zoom)
		region:SetDesaturated(data.desaturate)
		local ic = data.icon_color or { 1, 1, 1, 1 }
		region:SetIconColor(ic[1], ic[2], ic[3], ic[4])
		region.iconSource = data.iconSource
		region.displayIcon = data.displayIcon
		region:UpdateIcon()

		WA.regionPrototype.ApplyProgressConfig(region, data)
		WA.regionPrototype.modifyFinish(region, data)
	end,
})

-- Follows WeakAuras2's Text.lua: a region that *is* its text, where icon and
-- progressbar merely carry text as sub-regions. The font block -- face, size,
-- outline, both justifications, spacing, shadow -- is TextCore.lua's, shared with
-- subtext, so what lives here is the string, the frame around it, and the
-- decision about when to re-resolve.
--
-- Per-symbol format settings sit under upstream's key layout for this region,
-- displayText_format_<symbol>_<setting>, the region-side twin of subtext's
-- text_text_format_*.
local TEXT_FORMAT_PREFIX = "displayText_format_"

local function textFormatGetter(data)
	return function(key, default)
		local v = data[TEXT_FORMAT_PREFIX .. key]
		if v == nil then return default end
		return v
	end
end

-- Every string this region might end up showing: the configured one, plus any a
-- condition can swap in through the displayText property. A condition-supplied
-- string has to format identically to a typed one, so its symbols need formatters
-- built alongside (WA2's Text.lua walks data.conditions for the same reason).
-- The options rows stay one per symbol of the text being edited -- these are only
-- for the formatter build.
local function displayTexts(data)
	local texts = { data.displayText or "" }
	local conditions = data.conditions or {}
	for i = 1, table.getn(conditions) do
		local changes = conditions[i].changes or {}
		for c = 1, table.getn(changes) do
			local change = changes[c]
			if change.property == "displayText" and type(change.value) == "string" then
				table.insert(texts, change.value)
			end
		end
	end
	return texts
end

-- Where the string sits inside a region larger than it. SetJustifyH/V decide only
-- how wrapped lines align against the string's *own* box, so without anchoring at
-- the justify point a left-justified text still floats in the middle of a wide
-- region -- WA2's Text.lua anchors at data.justify for exactly this. Our justify
-- is the shared font block's pair, so both axes are honoured rather than
-- upstream's horizontal one alone.
local TEXT_ANCHORS_BY_JUSTIFY = {
	TOP = { LEFT = "TOPLEFT", CENTER = "TOP", RIGHT = "TOPRIGHT" },
	MIDDLE = { LEFT = "LEFT", CENTER = "CENTER", RIGHT = "RIGHT" },
	BOTTOM = { LEFT = "BOTTOMLEFT", CENTER = "BOTTOM", RIGHT = "BOTTOMRIGHT" },
}

local function textAnchorPoint(data)
	local D = WA.textCore.DEFAULTS
	local row = TEXT_ANCHORS_BY_JUSTIFY[data.justifyV or D.justifyV]
		or TEXT_ANCHORS_BY_JUSTIFY.MIDDLE
	return row[data.justify or D.justifyH] or "CENTER"
end

-- Auto mode: size the region to whatever the string just rendered as. Both
-- dimensions are measured, since GetStringHeight is absent here and GetHeight
-- stands in for it -- a FontString with no explicit height reports its own text's,
-- wrapping included.
--
-- The result is written back to `data`, not merely onto the frame: group layout
-- (childRect) computes a child's box from data.width/height and returns a
-- degenerate point for a child that has neither, so a size living only on the
-- frame would let a dynamic group stack its siblings straight through this one.
-- The equality check is what keeps that affordable -- writing and relaying out
-- unconditionally would be a group relayout on every frame of a ticking %p.
--
-- The floor is the same recoverability argument as the " " substitution above: a
-- measurement can legitimately come back 0 (a font the client refused renders
-- nothing and measures nothing), and a region of no size cannot be clicked, which
-- is how one is dragged or resized back into existence.
local MIN_TEXT_DIM = 8

local function textAutoSize(region, data)
	local fs = region.text
	-- Measured detached, so an enclosing group's scale doesn't inflate the
	-- reading, then put back (WA2 Text.lua).
	local host = fs:GetParent()
	fs:SetParent(UIParent)
	local w = fs:GetStringWidth() or 0
	local h = fs:GetHeight() or 0
	fs:SetParent(host)
	if w < MIN_TEXT_DIM then w = MIN_TEXT_DIM end
	if h < MIN_TEXT_DIM then h = MIN_TEXT_DIM end

	if w == data.width and h == data.height then return end
	data.width, data.height = w, h
	region:SetWidth(w)
	region:SetHeight(h)
	if data.parent then WA.RelayoutGroup(data.parent) end
end

local function textCreate(parent, data)
	local region = CreateFrame("Frame", nil, parent)

	-- The FontString sits on a child frame rather than on the region, the trap
	-- SubText.lua documents: a child frame's draw layers all sit above its
	-- parent's, so a border sub-region built as a child frame would paint over
	-- text created directly on the region. The level is asserted in modify, since
	-- SetParent resets it.
	local textFrame = CreateFrame("Frame", nil, region)
	textFrame:SetAllPoints(region)
	region.textFrame = textFrame
	region.text = textFrame:CreateFontString(nil, "OVERLAY")

	WA.regionPrototype.create(region)

	-- One stable function object, so ConfigureSubscribers can take it back off the
	-- bus -- a closure built per call could only ever be added. The custom-text
	-- refresh is *not* here: modifyFinish subscribes the prototype's own tick
	-- ahead of this one, so the values are already fresh by the time this
	-- re-resolves the string.
	region.frameTick = function() region:UpdateText() end

	function region:UpdateText()
		local str = WA.ReplacePlaceHolders(self.displayText or "", self, self.formatters)
		-- An empty resolved string is substituted rather than shown: a zero-width
		-- region can't be clicked, and clicking it is how one is dragged or resized
		-- back into existence (WA2 Text.lua).
		if str == "" then str = " " end
		self:SetDisplayString(str)
	end

	function region:Update()
		self:RefreshCustomText(true)
		self:UpdateText()
	end

	region:Hide()
	return region
end

local function textModify(region, data)
	function region:Color(r, g, b, a) self.text:SetTextColor(r, g, b, a or 1) end

	-- Not merely SetTextHeight: upstream re-calls SetFont at the new size first
	-- (Text.lua), so a condition-driven size change re-enters the read-back that
	-- keeps a face the client refuses from leaving the string unrendered. Routed
	-- through textCore rather than opening a second SetFont call site.
	function region:SetTextHeight(size)
		WA.textCore.Apply(self.text, data, "", size, WA.textCore.REGION_KEYS)
		self.text:SetTextHeight(size)
	end

	-- A condition can replace the whole string, and that changes two answers, not
	-- one: what the resolved text is, and whether this region belongs on the
	-- per-frame bus at all. WA2 keeps them as ConfigureTextUpdate and
	-- ConfigureSubscribers; without the second, a condition swapping in a %p
	-- renders a countdown once and then freezes.
	function region:ChangeText(msg)
		self.displayText = msg or ""
		self:ConfigureTextUpdate()
		self:ConfigureSubscribers()
	end

	function region:ConfigureTextUpdate()
		self.needsFrameTick = WA.TextNeedsFrameTick(self.displayText, self.everyFrameFormatters)
			or (self.customTextFunc ~= nil and self.customTextMode == "update"
				and WA.ContainsCustomPlaceHolder(self.displayText))
			or false
	end

	function region:ConfigureSubscribers()
		self.subRegionEvents:RemoveSubscriber("FrameTick", self.frameTick)
		if self.needsFrameTick then
			self.subRegionEvents:AddSubscriber("FrameTick", self.frameTick)
		end
		WA.regionPrototype.RefreshFrameTick(self)
		self:RefreshCustomText(true)
		self:UpdateText()
	end

	local texts = displayTexts(data)
	region.formatters, region.everyFrameFormatters =
		WA.CreateFormatters(texts, textFormatGetter(data), data)

	WA.textCore.Apply(region.text, data, "", nil, WA.textCore.REGION_KEYS)
	local point = textAnchorPoint(data)
	region.text:ClearAllPoints()
	region.text:SetPoint(point, region, point)

	-- Two sizing modes, and they differ in who owns the box. Fixed is a region
	-- like any other -- its width and height are settings, the string wraps inside
	-- them, and the mover resizes it. Auto has no size of its own: the string is
	-- measured after every SetText and the region follows it, so the setters are
	-- deliberately *absent*, which is what turns the mover's resize handles off
	-- (MoverSizer gates on region.SetRegionWidth). They are cleared rather than
	-- left alone, since one modify can follow another in the other mode.
	if data.automaticWidth == "Fixed" then
		function region:SetRegionWidth(w) self:SetWidth(w); self.text:SetWidth(w) end
		function region:SetRegionHeight(h) self:SetHeight(h) end
		function region:SetDisplayString(str) WA.textCore.SetText(self.text, str) end
		region:SetRegionWidth(data.width)
		region:SetRegionHeight(data.height)
	else
		region.SetRegionWidth = nil
		region.SetRegionHeight = nil
		function region:SetDisplayString(str)
			WA.textCore.SetText(self.text, str)
			textAutoSize(self, data)
		end
		-- Unbinds a width a previous Fixed pass left on the string, or it would
		-- keep wrapping at that column and measure short.
		region.text:SetWidth(0)
	end

	region:SetRegionAlpha(data.alpha)
	local col = data.color or { 1, 1, 1, 1 }
	region:Color(col[1], col[2], col[3], col[4])

	-- ApplyPosition may SetParent, which resets child frame levels, so the text
	-- frame's is asserted after it -- below SUB_LEVEL, where region internals live.
	WA.regionPrototype.ApplyPosition(region, data)
	region.textFrame:SetFrameLevel(region:GetFrameLevel() + 1)

	-- The region's own FrameTick subscription is installed *after* modifyFinish,
	-- which drops every subscriber before rebuilding the sub-regions'.
	WA.regionPrototype.modifyFinish(region, data)
	region.displayText = data.displayText or ""
	region:ConfigureTextUpdate()
	region:ConfigureSubscribers()
end

local PROGTEX_ORIENTATIONS = { "HORIZONTAL", "HORIZONTAL_INVERSE", "VERTICAL", "VERTICAL_INVERSE" }
local PROGTEX_ORIENTATION_LABELS = {
	HORIZONTAL = "Right to Left", HORIZONTAL_INVERSE = "Left to Right",
	VERTICAL = "Bottom to Top", VERTICAL_INVERSE = "Top to Bottom",
}
local PROGTEX_DEFAULT = "Interface\\AddOns\\WeakestAuras\\textures\\shapes\\Square_FullWhite.tga"

-- Corner texcoords cropping the source to the drawn fraction, in SetTexCoord's
-- (UL, LL, UR, LR) order. Ported from WA2 LinearProgressTextureBase's
-- ApplyProgressToCoordFunctions with startProgress pinned at 0, since there are
-- no overlays here to occupy a sub-range.
--
-- These deliberately do *not* match BAR_TEXCOORDS: the bar rotates its source
-- 90 degrees for the vertical pair, and a progress texture must not. Bar art is
-- a grain that has to run along the fill axis; a progress texture is a picture
-- the user chose, and standing it on its side is a bug. Rotating also crops the
-- wrong source axis -- the drawn rect then shrinks on one axis while the crop
-- shrinks the other, so the art squashes instead of being revealed.
local PROGTEX_TEXCOORDS = {
	HORIZONTAL = function(p)
		return 0, 0, 0, 1, p, 0, p, 1
	end,
	HORIZONTAL_INVERSE = function(p)
		return 1 - p, 0, 1 - p, 1, 1, 0, 1, 1
	end,
	VERTICAL = function(p)
		return 0, 1 - p, 0, 1, 1, 1 - p, 1, 1
	end,
	VERTICAL_INVERSE = function(p)
		return 0, 0, 0, p, 1, 0, 1, p
	end,
}

-- Rotates/mirrors one source corner about the texture's centre (WA2
-- TextureCoords.TransformPoint, minus the crop and user-offset terms this
-- region type exposes no options for). Upstream's 1/sqrt(2) shrink is absent
-- with it: that shrink exists to be cancelled by upstream's default crop of
-- 1.41, so reproducing only half the pair would silently zoom the art. A
-- rotation therefore runs the corners outside [0, 1], which reads as
-- transparent margins on this client rather than as wrapped or clamped art.
local function progTexPoint(x, y, cosR, sinR, mirror, userX, userY)
	x, y = x - 0.5, y - 0.5
	if mirror then x = -x end
	x, y = cosR * x - sinR * y, sinR * x + cosR * y
	return x + 0.5 + (userX or 0), y + 0.5 + (userY or 0)
end

-- The crop above, then the rotation/mirror on top of it -- upstream's order in
-- LinearProgressTextureBase.UpdateTextures, and it is load-bearing: rotating
-- first would spin the axis the crop then measures along.
local function progTexCoords(o, p, rotation, mirror, cropX, cropY, userX, userY)
	local coords = PROGTEX_TEXCOORDS[o] or PROGTEX_TEXCOORDS.HORIZONTAL
	local ULx, ULy, LLx, LLy, URx, URy, LRx, LRy = coords(p)
	cropX, cropY = cropX or 0, cropY or 0
	local sx, sy = 1 - cropX * 2, 1 - cropY * 2
	local function crop(x, y) return cropX + x * sx, cropY + y * sy end
	ULx, ULy = crop(ULx, ULy); LLx, LLy = crop(LLx, LLy)
	URx, URy = crop(URx, URy); LRx, LRy = crop(LRx, LRy)
	if not mirror and math.mod(rotation or 0, 360) == 0 then
		return ULx + (userX or 0), ULy + (userY or 0), LLx + (userX or 0), LLy + (userY or 0), URx + (userX or 0), URy + (userY or 0), LRx + (userX or 0), LRy + (userY or 0)
	end
	local r = math.rad(rotation or 0)
	local cosR, sinR = math.cos(r), math.sin(r)
	ULx, ULy = progTexPoint(ULx, ULy, cosR, sinR, mirror, userX, userY)
	LLx, LLy = progTexPoint(LLx, LLy, cosR, sinR, mirror, userX, userY)
	URx, URy = progTexPoint(URx, URy, cosR, sinR, mirror, userX, userY)
	LRx, LRy = progTexPoint(LRx, LRy, cosR, sinR, mirror, userX, userY)
	return ULx, ULy, LLx, LLy, URx, URy, LRx, LRy
end

-- Which two corners of the region the fill is pinned to -- the edge the crop
-- above keeps, so the art stays put and the fill grows away from it. WA2's
-- LinearProgressTextureBase orientationToAnchorPoint, as a corner pair. The
-- vertical entries are the opposite edge from BAR_ALIGN's, for the same reason
-- PROGTEX_TEXCOORDS is not BAR_TEXCOORDS.
local PROGTEX_ALIGN = {
	HORIZONTAL = { "TOPLEFT", "BOTTOMLEFT" },
	HORIZONTAL_INVERSE = { "TOPRIGHT", "BOTTOMRIGHT" },
	VERTICAL = { "BOTTOMLEFT", "BOTTOMRIGHT" },
	VERTICAL_INVERSE = { "TOPLEFT", "TOPRIGHT" },
}

-- Sizes and crops the fill texture to region.progress. Both have to move
-- together, exactly as in fillBar: the texture is cropped to the same fraction
-- of the same axis it is scaled to, or the art squashes instead of revealing.
local function progTexFill(region)
	-- SetTexCoord(progTexCoords(o, p, region.rotation, region.mirror, region.crop_x, region.crop_y, region.user_x, region.user_y))
	local o = region.orientation or "HORIZONTAL"
	local align = PROGTEX_ALIGN[o] or PROGTEX_ALIGN.HORIZONTAL
	local p = region.progress or 0
	if p < 0 then p = 0 elseif p > 1 then p = 1 end
	local fg = region.foreground
	if not fg then return end

	local vertical = isVertical(o)
	local extent = (vertical and (region.regionHeight or 0) or (region.regionWidth or 0)) * p
	-- A zero-dimension texture is not worth asking the client to draw.
	if extent <= 0 then fg:Hide(); return end

	fg:ClearAllPoints()
	fg:SetPoint(align[1], region, align[1])
	fg:SetPoint(align[2], region, align[2])
	-- Two corners on one edge fix the cross axis, leaving the fill axis free to
	-- be set explicitly.
	if vertical then fg:SetHeight(extent) else fg:SetWidth(extent) end
	fg:SetTexCoord(progTexCoords(o, p, region.animRotation or region.rotation, region.mirror, region.crop_x, region.crop_y, region.user_x, region.user_y))
	fg:Show()
end

local function progTexBackground(region)
	local background = region.background
	if not background then return end
	local o = region.orientation or "HORIZONTAL"
	background:SetTexCoord(progTexCoords(o, 1, region.animRotation or region.rotation, region.mirror, region.crop_x, region.crop_y, region.user_x, region.user_y))
end

WA.RegisterRegionType("progresstexture", {
	displayName = "Progress Texture",
	description = "A linear texture that fills from a progress value.",
	defaults = {
		foregroundTexture = PROGTEX_DEFAULT,
		backgroundTexture = PROGTEX_DEFAULT,
		sameTexture = true,
		foregroundColor = { 1, 1, 1, 1 },
		backgroundColor = { 0.5, 0.5, 0.5, 0.5 },
		desaturateForeground = false,
		desaturateBackground = false,
		width = 200, height = 32, alpha = 1,
		orientation = "HORIZONTAL", inverse = false, mirror = false, rotation = 0,
		crop_x = 0, crop_y = 0, user_x = 0, user_y = 0,
		progressSource = -1, progressSourceManualValue = 0, progressSourceManualTotal = 100,
		anchorFrameType = "SCREEN", selfPoint = "CENTER", anchorPoint = "CENTER",
		xOffset = 0, yOffset = 0, frameStrata = 1,
	},
	icon = PROGTEX_DEFAULT,
	getSubRegionAnchors = function() return TEXTURE_SUB_ANCHORS end,
	properties = WA.regionPrototype.AddProgressProperties(WA.regionPrototype.AddProperties({
		foregroundColor = { display = "Foreground Color", setter = "Color", type = "color" },
		backgroundColor = { display = "Background Color", setter = "SetBackgroundColor", type = "color" },
		desaturateForeground = { display = "Desaturate Foreground", setter = "SetForegroundDesaturated", type = "bool" },
		desaturateBackground = { display = "Desaturate Background", setter = "SetBackgroundDesaturated", type = "bool" },
		orientation = { display = "Orientation", setter = "SetOrientation", type = "list", values = PROGTEX_ORIENTATION_LABELS },
		inverse = { display = "Inverse", setter = "SetInverse", type = "bool" },
		mirror = { display = "Mirror", setter = "SetMirror", type = "bool" },
		rotation = { display = "Texture Rotation", setter = "SetTexRotation", type = "number", min = 0, max = 360, step = 1 },
		crop_x = { display = "Crop X", setter = "SetCropX", type = "number", min = 0, max = 0.5, step = 0.01 },
		crop_y = { display = "Crop Y", setter = "SetCropY", type = "number", min = 0, max = 0.5, step = 0.01 },
		user_x = { display = "Re-center X", setter = "SetUserX", type = "number", min = -0.5, max = 0.5, step = 0.01 },
		user_y = { display = "Re-center Y", setter = "SetUserY", type = "number", min = -0.5, max = 0.5, step = 0.01 },
		foregroundTexture = { display = "Foreground Texture", setter = "SetForegroundTexture", type = "texture" },
		backgroundTexture = { display = "Background Texture", setter = "SetBackgroundTexture", type = "texture" },
	})),
	createThumbnail = function(parent)
		local frame = CreateFrame("Frame", nil, parent)
		frame.bg = frame:CreateTexture(nil, "BACKGROUND")
		frame.fg = frame:CreateTexture(nil, "ARTWORK")
		return frame
	end,
	modifyThumbnail = function(frame, data)
		local size = frame:GetHeight() or 32
		local o = data.orientation or "HORIZONTAL"
		local vertical = isVertical(o)
		local long, thick = size * 0.82, size * 0.35
		frame.bg:SetWidth(vertical and thick or long); frame.bg:SetHeight(vertical and long or thick)
		frame.bg:SetPoint("CENTER", frame, "CENTER")
		frame.bg:SetTexture((data.backgroundColor or { 0.5, 0.5, 0.5, 0.5})[1], (data.backgroundColor or { 0.5, 0.5, 0.5, 0.5})[2], (data.backgroundColor or { 0.5, 0.5, 0.5, 0.5})[3], (data.backgroundColor or { 0.5, 0.5, 0.5, 0.5})[4])
		frame.fg:SetTexture(WA.DrawableTexture(data.foregroundTexture) or PROGTEX_DEFAULT)
		local c = data.foregroundColor or { 1, 1, 1, 1 }
		frame.fg:SetVertexColor(c[1], c[2], c[3], c[4] or 1)
		local p = 0.6
		frame.fg:SetWidth(vertical and thick or long * p); frame.fg:SetHeight(vertical and long * p or thick)
		frame.fg:SetPoint(vertical and "BOTTOM" or "LEFT", frame.bg, vertical and "BOTTOM" or "LEFT")
		frame.fg:Show()
	end,
	options = function(data)
		local fields = {
			{ type = "header", name = "Progress Texture" },
			{ type = "texture", name = "Foreground texture", key = "foregroundTexture", get = function() return data.foregroundTexture end, set = function(v) data.foregroundTexture = v; WA.Add(data, true); WA.RefreshList() end },
			{ type = "toggle", name = "Same texture", key = "sameTexture", get = function() return data.sameTexture end, set = function(v) data.sameTexture = v; WA.Add(data, true); WA.RefreshOptions() end },
			{ type = "color", name = "Foreground color", key = "foregroundColor", half = true, get = function() return data.foregroundColor end, set = function(v) data.foregroundColor = v; WA.Add(data, true) end },
			{ type = "color", name = "Background color", key = "backgroundColor", half = true, get = function() return data.backgroundColor end, set = function(v) data.backgroundColor = v; WA.Add(data, true) end },
			{ type = "toggle", name = "Desaturate foreground", key = "desaturateForeground", half = true, get = function() return data.desaturateForeground end, set = function(v) data.desaturateForeground = v; WA.Add(data, true) end },
			{ type = "toggle", name = "Desaturate background", key = "desaturateBackground", half = true, get = function() return data.desaturateBackground end, set = function(v) data.desaturateBackground = v; WA.Add(data, true) end },
			{ type = "select", name = "Orientation", key = "orientation", get = function() return data.orientation end, set = function(v) data.orientation = v; WA.Add(data, true); WA.RefreshOptions() end, values = PROGTEX_ORIENTATIONS, labels = PROGTEX_ORIENTATION_LABELS },
			{ type = "toggle", name = "Inverse", key = "inverse", half = true, get = function() return data.inverse end, set = function(v) data.inverse = v; WA.Add(data, true) end },
			{ type = "toggle", name = "Mirror", key = "mirror", half = true, get = function() return data.mirror end, set = function(v) data.mirror = v; WA.Add(data, true) end },
			{ type = "range", name = "Texture rotation", key = "rotation", min = 0, max = 360, step = 1, half = true, get = function() return data.rotation end, set = function(v) data.rotation = v; WA.Add(data, true) end },
			{ type = "range", name = "Alpha", key = "alpha", min = 0, max = 1, step = 0.05, half = true, get = function() return data.alpha end, set = function(v) data.alpha = v; WA.Add(data, true) end },
			{ type = "range", name = "Crop X", key = "crop_x", min = 0, max = 0.5, step = 0.01, half = true, get = function() return data.crop_x end, set = function(v) data.crop_x = v; WA.Add(data, true) end },
			{ type = "range", name = "Crop Y", key = "crop_y", min = 0, max = 0.5, step = 0.01, half = true, get = function() return data.crop_y end, set = function(v) data.crop_y = v; WA.Add(data, true) end },
			{ type = "range", name = "Re-center X", key = "user_x", min = -0.5, max = 0.5, step = 0.01, half = true, get = function() return data.user_x end, set = function(v) data.user_x = v; WA.Add(data, true) end },
			{ type = "range", name = "Re-center Y", key = "user_y", min = -0.5, max = 0.5, step = 0.01, half = true, get = function() return data.user_y end, set = function(v) data.user_y = v; WA.Add(data, true) end },
			{ type = "header", name = "Size" },
			{ type = "range", name = "Width", key = "width", min = 8, max = 512, step = 1, half = true, get = function() return data.width end, set = function(v) data.width = v; WA.Add(data, true) end },
			{ type = "range", name = "Height", key = "height", min = 8, max = 512, step = 1, half = true, get = function() return data.height end, set = function(v) data.height = v; WA.Add(data, true) end },
		}
		if not data.sameTexture then
			table.insert(fields, 3, { type = "texture", name = "Background texture", key = "backgroundTexture", get = function() return data.backgroundTexture end, set = function(v) data.backgroundTexture = v; WA.Add(data, true); WA.RefreshList() end })
		end
		for _, f in ipairs(WA.regionPrototype.ProgressOptions(data)) do table.insert(fields, f) end
		for _, f in ipairs(WA.regionPrototype.PositionOptions(data)) do table.insert(fields, f) end
		return fields
	end,
	create = function(parent)
		local region = CreateFrame("Frame", nil, parent)
		local bg = region:CreateTexture(nil, "BACKGROUND")
		-- The fill is a plain texture anchored to the region and resized, not a
		-- clipped viewport onto a full-size one: a ScrollFrame clips to a
		-- rectangle, which is the shape the resize already gives, so it bought
		-- nothing but a second coordinate space to keep in step.
		local fg = region:CreateTexture(nil, "ARTWORK")
		bg:SetAllPoints(region)
		region.background, region.foreground = bg, fg
		WA.regionPrototype.create(region)
		function region:Update()
			if self.state then WA.regionPrototype.UpdateProgress(self) end
		end
		function region:SetProgress(p)
			self.progress = clampProgress(self, p)
			progTexFill(self)
		end
		function region:UpdateValue()
			local total = self.total or 0
			self:SetProgress(total > 0 and (self.value or 0) / total or 1)
		end
		-- The fill is this region's own animation and has to be recomputed from
		-- the clock every frame, exactly as the progressbar's does -- deriving
		-- the fraction once per state change leaves a timed aura frozen at
		-- whatever fraction it held when the state arrived.
		function region:UpdateTime()
			if self.paused then
				local remain = self.remaining or 0
				if self.duration and self.duration > 0 then
					self:SetProgress(remain / self.duration)
				else
					self:SetProgress(1)
				end
				self:SetScript("OnUpdate", nil)
				return
			end
			if self.duration and self.duration > 0 then
				self:SetScript("OnUpdate", function()
					if not this:IsShown() then this:SetScript("OnUpdate", nil); return end
					local remain = this.expirationTime - GetTime()
					this:SetProgress(remain / this.duration)
					if remain <= 0 then this:SetScript("OnUpdate", nil) end
				end)
			else
				self:SetProgress(1)
				self:SetScript("OnUpdate", nil)
			end
		end
		region:Hide()
		return region
	end,
	modify = function(region, data)
		function region:SetRegionWidth(v) self.regionWidth = v; self:SetWidth(v); progTexFill(self) end
		function region:SetRegionHeight(v) self.regionHeight = v; self:SetHeight(v); progTexFill(self) end
		function region:SetForegroundTexture(v) self.foreground:SetTexture(WA.DrawableTexture(v) or PROGTEX_DEFAULT); progTexFill(self) end
		function region:SetBackgroundTexture(v) self.background:SetTexture(WA.DrawableTexture(v) or PROGTEX_DEFAULT); progTexBackground(self) end
		function region:Color(r, g, b, a) self.foreground:SetVertexColor(r, g, b, a or 1) end
		function region:SetBackgroundColor(r, g, b, a) self.background:SetVertexColor(r, g, b, a or 1) end
		function region:SetForegroundDesaturated(v) self.foreground:SetDesaturated(v and true or false) end
		function region:SetBackgroundDesaturated(v) self.background:SetDesaturated(v and true or false) end
		function region:SetOrientation(v) self.orientation = v; progTexBackground(self); progTexFill(self) end
		function region:SetInverse(v) self.inverse = v and true or false; if self.state then WA.regionPrototype.UpdateProgress(self) end end
		function region:SetMirror(v) self.mirror = v and true or false; progTexBackground(self); progTexFill(self) end
		function region:SetTexRotation(v) self.rotation = v or 0; progTexBackground(self); progTexFill(self) end
		function region:SetAnimRotation(v) self.animRotation = v; progTexBackground(self); progTexFill(self) end
		function region:GetBaseRotation() return self.rotation or 0 end
		function region:SetCropX(v) self.crop_x = math.max(0, math.min(0.5, v or 0)); progTexBackground(self); progTexFill(self) end
		function region:SetCropY(v) self.crop_y = math.max(0, math.min(0.5, v or 0)); progTexBackground(self); progTexFill(self) end
		function region:SetUserX(v) self.user_x = math.max(-0.5, math.min(0.5, v or 0)); progTexBackground(self); progTexFill(self) end
		function region:SetUserY(v) self.user_y = math.max(-0.5, math.min(0.5, v or 0)); progTexBackground(self); progTexFill(self) end
		region:SetRegionWidth(data.width); region:SetRegionHeight(data.height)
		region:SetRegionAlpha(data.alpha)
		region:SetForegroundTexture(data.foregroundTexture); region:SetBackgroundTexture(data.sameTexture and data.foregroundTexture or data.backgroundTexture)
		local fc = data.foregroundColor or { 1, 1, 1, 1 }; region:Color(fc[1], fc[2], fc[3], fc[4])
		local bc = data.backgroundColor or { 0.5, 0.5, 0.5, 0.5 }; region:SetBackgroundColor(bc[1], bc[2], bc[3], bc[4])
		region:SetForegroundDesaturated(data.desaturateForeground); region:SetBackgroundDesaturated(data.desaturateBackground)
		region.orientation = data.orientation; region.inverse = data.inverse
		region.rotation = data.rotation; region.mirror = data.mirror and true or false
		region.crop_x = data.crop_x or 0; region.crop_y = data.crop_y or 0
		region.user_x = data.user_x or 0; region.user_y = data.user_y or 0
		region.progress = region.progress or 1
		progTexBackground(region)
		progTexFill(region)
		WA.regionPrototype.ApplyPosition(region, data)
		WA.regionPrototype.ApplyProgressConfig(region, data); WA.regionPrototype.modifyFinish(region, data)
	end,
})

WA.RegisterRegionType("text", {
	displayName = "Text",
	description = "A line of text on its own, driven by the same placeholders.",
	icon = "Interface\\Icons\\INV_Misc_Note_01",
	defaults = {
		displayText = "%p",
		-- Auto is upstream's default and the reason the region type is worth
		-- having: a box that hugs its own glyphs. width/height are still seeded
		-- because Auto writes its measurements back into them and group layout
		-- reads them from there.
		automaticWidth = "Auto",
		width = 200,
		height = 20,
		alpha = 1,
		-- The rest of the font block is deliberately absent: TextCore reads every
		-- one of its keys through a default, so a saved aura needs no migration to
		-- pick up a key added later. Size and colour are here because a condition
		-- restores a property's base from data, and a nil base is not a size.
		fontSize = 12,
		color = { 1, 1, 1, 1 },
		-- The three customText* keys are deliberately absent, not seeded. Their
		-- defaults belong to the region prototype, which owns the function for
		-- every region type -- and for the source itself a nil is what tells the
		-- options renderer this has never been configured, where "" means the user
		-- cleared it and it stays cleared.
		anchorFrameType = "SCREEN",
		selfPoint = "CENTER",
		anchorPoint = "CENTER",
		xOffset = 0,
		yOffset = 0,
		frameStrata = 1,
	},
	-- No width/height here, unlike the other leaf types and matching upstream: in
	-- Auto mode the box is a measurement rather than a setting, and a condition
	-- offering to change it would silently do nothing.
	properties = WA.regionPrototype.AddProperties({
		color = { display = "Color", setter = "Color", type = "color" },
		fontSize = { display = "Font Size", setter = "SetTextHeight", type = "number", min = 6, max = 72, step = 1 },
		displayText = { display = "Text", setter = "ChangeText", type = "string" },
	}),
	-- List-row preview: the configured string, not a resolved one -- there is no
	-- state behind a list row, and showing "%p" is what tells the reader what the
	-- aura will say. A FontString isn't clipped by the frame it sits on, so the
	-- box's width is imposed on it and the string is cut rather than left to run
	-- out across the row. Upstream masks a live preview with a self-scrolling
	-- ScrollFrame; that is a lot of machinery for a 32px square.
	createThumbnail = function(parent)
		local frame = CreateFrame("Frame", nil, parent)
		local fs = frame:CreateFontString(nil, "ARTWORK")
		fs:SetPoint("CENTER", frame, "CENTER")
		frame.fs = fs
		return frame
	end,
	modifyThumbnail = function(frame, data)
		local box = frame:GetHeight() or 32
		local fs = frame.fs
		local size = math.floor(box / 3)
		if size < 6 then size = 6 end
		WA.textCore.Apply(fs, data, "", size, WA.textCore.REGION_KEYS)
		fs:SetJustifyH("CENTER")
		fs:SetJustifyV("MIDDLE")
		fs:SetWidth(box)
		WA.textCore.SetText(fs, WA.Utf8Sub(data.displayText or "", 12))
	end,
	create = textCreate,
	modify = textModify,
	options = function(data)
		local fields = {
			{ type = "header", name = "Text" },
			{
				-- %i is absent from the label deliberately: it resolves to nothing
				-- here, this client's FontString having no inline texture escape.
				type = "multiline", name = "Display text (%p %t %n %s %c)", key = "displayText", height = 60,
				get = function() return data.displayText end,
				-- Re-renders the tab: the Format rows below are one per symbol in
				-- this string, so editing it changes which rows exist.
				set = function(v)
					data.displayText = v
					WA.SetDefaultFormatters(v, textFormatGetter(data),
						function(key, value) data[TEXT_FORMAT_PREFIX .. key] = value end, data)
					WA.Add(data, true)
					WA.RefreshOptions()
				end,
			},
			{
				type = "range", name = "Size", key = "fontSize", min = 6, max = 72, step = 1, half = true,
				get = function() return data.fontSize end,
				set = function(v) data.fontSize = v; WA.Add(data, true) end,
			},
			{
				type = "range", name = "Alpha", key = "alpha", min = 0, max = 1, step = 0.05, half = true,
				get = function() return data.alpha end,
				set = function(v) data.alpha = v; WA.Add(data, true) end,
			},
			{
				type = "color", name = "Color", key = "color",
				get = function() return data.color end,
				set = function(v) data.color = v; WA.Add(data, true) end,
			},
		}

		-- Directly under the text field, whose label can only name the built-in
		-- symbols.
		local hint = WA.TextSymbolHint(data)
		if hint then table.insert(fields, 2, { type = "description", name = hint }) end

		local fontFields = WA.textCore.OptionFields(data, "region:textfont",
			function(key) return data[key] end,
			function(key, v) data[key] = v; WA.Add(data, true) end, WA.textCore.REGION_KEYS)
		for i = 1, table.getn(fontFields) do table.insert(fields, fontFields[i]) end

		local get = textFormatGetter(data)
		local formatFields = WA.FormatOptionFields(data.displayText, get,
			function(key, v) data[TEXT_FORMAT_PREFIX .. key] = v; WA.Add(data, true) end,
			data, TEXT_FORMAT_PREFIX)
		if table.getn(formatFields) > 0 then
			-- Folded for the reason subtext folds its own: every %symbol grows a
			-- row, and with two or three symbols those rows bury the text field
			-- being edited under settings that get chosen once.
			local S = WA.OptionsState
			local key = "region:textformat"
			local collapsed = S.isCollapsed(data, key, true)
			table.insert(fields, {
				type = "disclosure", name = "Format Options",
				summary = WA.FormatSummary(data.displayText, get, data),
				collapsed = collapsed,
				onToggle = function()
					S.setCollapsed(data, key, not collapsed)
					WA.RefreshOptions()
				end,
			})
			if not collapsed then
				for i = 1, table.getn(formatFields) do table.insert(fields, formatFields[i]) end
			end
		end

		table.insert(fields, { type = "header", name = "Size" })
		table.insert(fields, {
			type = "select", name = "Sizing", key = "automaticWidth",
			values = { "Auto", "Fixed" },
			labels = { Auto = "Fit to the text", Fixed = "Fixed, text wraps inside" },
			get = function() return data.automaticWidth or "Auto" end,
			set = function(v)
				data.automaticWidth = v
				WA.Add(data, true)
				-- Repaints the tab: the two sliders below exist only in Fixed mode,
				-- Auto's box being a measurement rather than a setting.
				WA.RefreshOptions()
			end,
		})
		if data.automaticWidth == "Fixed" then
			table.insert(fields, {
				type = "range", name = "Width", key = "width", min = 8, max = 400, step = 1, half = true,
				get = function() return data.width end,
				set = function(v) data.width = v; WA.Add(data, true) end,
			})
			table.insert(fields, {
				type = "range", name = "Height", key = "height", min = 8, max = 400, step = 1, half = true,
				get = function() return data.height end,
				set = function(v) data.height = v; WA.Add(data, true) end,
			})
		end

		for _, f in ipairs(WA.regionPrototype.PositionOptions(data)) do
			table.insert(fields, f)
		end
		return fields
	end,
})

-- Upstream registers a second region type out of the same file (Text.lua L393):
-- a text region that renders "Region type %s not supported" and nothing else.
-- WA.RegionSpecFor routes an aura naming a type this addon lacks here, at the
-- point a region is built -- so an imported progresstexture is a box on screen
-- saying what is wrong, rather than a row in the list that is silently never
-- drawn.
--
-- `internal`, so nothing offers to create one or convert to it: it stands in for
-- an absence, and an absence is not a thing to pick.
--
-- Nothing here may read the type's own defaults. MergeDefaults resolves them
-- through WA.regionTypes and finds none for an unknown type, so every field this
-- modify touches carries its own fallback.
WA.RegisterRegionType("fallback", {
	displayName = "Unsupported",
	description = "Stands in for a region type this addon does not have.",
	internal = true,
	icon = "Interface\\Icons\\INV_Misc_QuestionMark",
	create = textCreate,
	modify = function(region, data)
		function region:SetDisplayString(str) WA.textCore.SetText(self.text, str) end
		-- One static string with no state behind it, so the region never resolves
		-- a placeholder and never joins the per-frame bus.
		function region:Update() end
		region.displayText = ""
		region.formatters, region.everyFrameFormatters = nil, nil
		region.customTextFunc = nil

		WA.textCore.Apply(region.text, data, "", nil, WA.textCore.REGION_KEYS)
		region.text:SetWidth(0)
		region.text:ClearAllPoints()
		region.text:SetPoint("CENTER", region, "CENTER")

		region:SetRegionAlpha(data.alpha or 1)
		WA.regionPrototype.ApplyPosition(region, data)
		region.textFrame:SetFrameLevel(region:GetFrameLevel() + 1)
		WA.regionPrototype.modifyFinish(region, data)

		local requested = data.regionType
		if requested == "progresstexture"
			and (data.orientation == "CLOCKWISE" or data.orientation == "ANTICLOCKWISE") then
			requested = requested .. " orientation " .. tostring(data.orientation)
		end
		WA.textCore.SetText(region.text, "Region type " .. tostring(requested) .. " not supported")
		region:SetWidth(math.max(region.text:GetStringWidth() or 0, MIN_TEXT_DIM))
		region:SetHeight(math.max(region.text:GetHeight() or 0, MIN_TEXT_DIM))
	end,
	options = function(data)
		local fields = {
			{ type = "header", name = "Unsupported region" },
			{ type = "description", name = "This aura asks for a \"" .. tostring(data.regionType)
				.. "\" display, which WeakestAuras does not have. Its triggers, conditions and load "
				.. "settings are intact -- pick another Region type on the Info tab to show it as "
				.. "something this addon can draw." },
		}
		for _, f in ipairs(WA.regionPrototype.PositionOptions(data)) do
			table.insert(fields, f)
		end
		return fields
	end,
})
