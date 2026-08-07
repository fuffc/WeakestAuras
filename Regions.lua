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
		WA.ForEachClone(id, function(frame) if frame.toShow then shown = true end end)
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

-- The currently-shown child region frames of a dynamicgroup, in controlledChildren
-- order, one entry per visible clone. Each carries its size (from data, falling
-- back to the live frame). Order is the grower's input; sort reorders it below.
local function activeChildren(data)
	local list = {}
	local kids = data.controlledChildren or {}
	for i = 1, table.getn(kids) do
		local cd = WeakestAurasDB.displays[kids[i]]
		if cd then
			WA.ForEachClone(kids[i], function(frame)
				if frame.toShow then
					local w = cd.width or (frame:GetWidth() or 0)
					local h = cd.height or (frame:GetHeight() or 0)
					table.insert(list, { region = frame, width = w, height = h })
				end
			end)
		end
	end
	return list
end

-- Axis-aligned grower: assigns each visible child a CENTER-relative position,
-- stacking successive children by their own dimension + spacing (WA2's
-- DynamicGroup.lua growers, minus stagger/limit/anchor-per-unit/animation).
-- HORIZONTAL/VERTICAL center the run on the group's center; the four cardinals
-- grow from it. Returns the child list (with .x/.y set) and the box extents.
local function growChildren(data)
	local list = activeChildren(data)
	local sort = data.sort
	if sort == "ascending" or sort == "descending" then
		-- By time remaining; a child with no timer sorts last (ref the aura-bar
		-- convention). expirationTime is the region's live value.
		table.sort(list, function(a, b)
			local ta = a.region.expirationTime or WA.INF
			local tb = b.region.expirationTime or WA.INF
			if sort == "ascending" then return ta < tb else return ta > tb end
		end)
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

	if grow == "HORIZONTAL" or grow == "VERTICAL" then
		local total = 0
		for i = 1, n do
			total = total + (grow == "HORIZONTAL" and list[i].width or list[i].height)
		end
		if n > 1 then total = total + space * (n - 1) end
		local cursor = -total / 2
		for i = 1, n do
			local c = list[i]
			local dim = (grow == "HORIZONTAL") and c.width or c.height
			local center = cursor + dim / 2
			if grow == "HORIZONTAL" then c.x, c.y = center, 0 else c.x, c.y = crossX(c.width), -center end
			cursor = cursor + dim + space
		end
	else
		local cursor = 0
		for i = 1, n do
			local c = list[i]
			if grow == "LEFT" then
				c.x = cursor - c.width / 2; c.y = 0; cursor = cursor - c.width - space
			elseif grow == "RIGHT" then
				c.x = cursor + c.width / 2; c.y = 0; cursor = cursor + c.width + space
			elseif grow == "UP" then
				c.x = crossX(c.width); c.y = cursor + c.height / 2; cursor = cursor + c.height + space
			else -- DOWN
				c.x = crossX(c.width); c.y = cursor - c.height / 2; cursor = cursor - c.height - space
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

-- Dynamic group: run the grower, push each visible child's computed position
-- onto its region (CENTER-to-CENTER + offset, via the region's own offset slot
-- so UpdatePosition stays authoritative), then draw the box around the result.
local function layoutDynamicGroup(region, data)
	local list, blx, bly, trx, try = growChildren(data)
	for i = 1, table.getn(list) do
		local c = list[i]
		c.region:SetAnchor("CENTER", region, "CENTER")
		c.region:SetOffset(c.x, c.y)
	end
	drawGroupBox(region, data, blx, bly, trx, try)
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
	WA.regionPrototype.ApplyFrameStrata(region, data)
	if data.regionType == "dynamicgroup" then
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
	local path = data and data.groupIcon
	if path and path ~= "" then
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
		groupIcon = "",
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
				values = { "UP", "DOWN", "LEFT", "RIGHT", "HORIZONTAL", "VERTICAL" },
				get = function() return data.grow end,
				set = function(v) data.grow = v; WA.Add(data) end,
			},
			{
				type = "select", name = "Sort", key = "sort",
				values = { "none", "ascending", "descending" },
				labels = { none = "None", ascending = "Ascending", descending = "Descending" },
				get = function() return data.sort end,
				set = function(v) data.sort = v; WA.Add(data) end,
			},
			{
				type = "range", name = "Spacing", key = "space", min = 0, max = 20, step = 1,
				get = function() return data.space end,
				set = function(v) data.space = v; WA.Add(data) end,
			},
			{
				type = "select", name = "Align", key = "align",
				values = { "LEFT", "CENTER", "RIGHT" },
				get = function() return data.align end,
				set = function(v) data.align = v; WA.Add(data) end,
			},
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

		region.swipe = WA.regionPrototype.CreateSwipe(region)

		WA.regionPrototype.create(region)

		-- Reads region.state (set by the state machine) -- replaces the old
		-- updateState(region, state, data). Text (countdown/stacks) rides on
		-- subtext elements notified via the subRegionEvents "Update" bus.
		function region:Update()
			local state = self.state
			if not state then return end
			self:UpdateIcon()
			WA.regionPrototype.UpdateProgress(self)
		end

		-- UpdateProgress dispatches here after setting duration/expirationTime:
		-- a timed state drives the swipe (when enabled), a static one clears it.
		function region:UpdateTime()
			if self.cooldownSwipe then
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
		function region:SetRegionWidth(w) self.regionWidth = w; self:SetWidth(w); WA.regionPrototype.SizeSwipe(self.swipe, w, self.regionHeight) end
		function region:SetRegionHeight(h) self.regionHeight = h; self:SetHeight(h); WA.regionPrototype.SizeSwipe(self.swipe, self.regionWidth, h) end
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
			if path == "" then path = nil end
			self.iconTex:SetTexture(path or "Interface\\Icons\\INV_Misc_QuestionMark")
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
		WA.regionPrototype.ApplyFrameStrata(region, data)
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
local BAR_ORIENTATION_LABELS = {
	HORIZONTAL = "Right to Left",
	HORIZONTAL_INVERSE = "Left to Right",
	VERTICAL = "Bottom to Top",
	VERTICAL_INVERSE = "Top to Bottom",
}
local ICON_SIDES = { "LEFT", "RIGHT" }

-- Condition properties render `values` as a key -> label map (the key is what
-- gets stored and passed to the setter), unlike the options `select` widget's
-- plain array -- so this can't just point at LibWidgets.BAR_TEXTURES itself.
-- Texture names are their own labels; derived so the two lists can't drift.
local BAR_TEXTURE_LABELS = {}
for _, name in ipairs(LibWidgets.BAR_TEXTURES) do
	BAR_TEXTURE_LABELS[name] = name
end

local function isVertical(o)
	return o == "VERTICAL" or o == "VERTICAL_INVERSE"
end

local function isInverse(o)
	return string.find(o, "INVERSE") ~= nil
end

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
-- same number a snap would have used.
local function clampProgress(region, p)
	if not p or p < 0 then p = 0 elseif p > 1 then p = 1 end
	if region.inverse then p = 1 - p end
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
		sparkTexture = "Interface\\CastingBar\\UI-CastingBar-Spark",
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
				values = LibWidgets.BAR_TEXTURES, swatches = W.BarTextureSwatches(),
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

		-- Name/time text rides on %n/%p subtext elements; this only paints the
		-- icon + drives the fill (below).
		function region:Update()
			local state = self.state
			if not state then return end
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
			return self.inverse and true or false
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
		function region:SetSparkTexture(path) self.spark:SetTexture(path) end
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
			if path == "" then path = nil end
			self.iconTex:SetTexture(path or "Interface\\Icons\\INV_Misc_QuestionMark")
		end

		-- ApplyPosition may SetParent, which resets child frame levels (and
		-- strata, if inherited), so both are re-asserted right after it.
		WA.regionPrototype.ApplyPosition(region, data)
		WA.regionPrototype.ApplyFrameStrata(region, data)
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
	local row = TEXT_ANCHORS_BY_JUSTIFY[data.text_justifyV or D.justifyV]
		or TEXT_ANCHORS_BY_JUSTIFY.MIDDLE
	return row[data.text_justifyH or D.justifyH] or "CENTER"
end

-- The default custom text function, seeded into a fresh field and restored by the
-- editor's Reset -- an emptied box is otherwise unrecoverable without remembering
-- the signature. Arguments are WA.RunCustomTextFunc's, and every return is a
-- %c: the first is %c or %c1, the second %c2, and so on.
local CUSTOM_TEXT_DEFAULT = [[function(expirationTime, duration, progress, dur, name, icon, stacks)
	return ""
end]]

-- Compiles a custom text function -- a whole `function(...) ... end` expression,
-- loadstring'd behind a `return`, the idiom GenericTrigger already uses for a
-- custom trigger and sharing that file's sandbox environment. A source that will
-- not compile reports and yields nil, so the rest of the text still renders.
local function compileCustomText(source, id)
	local function refuse(err)
		DEFAULT_CHAT_FRAME:AddMessage("|cffff0000WeakestAuras|r [" .. tostring(id)
			.. "] custom text: " .. tostring(err), 1, 0.3, 0.3)
		return nil
	end
	local chunk, err = loadstring("return " .. source)
	if not chunk then return refuse(err) end
	if WA.customEnv then setfenv(chunk, WA.customEnv) end
	local ok, fn = pcall(chunk)
	if not ok then return refuse(fn) end
	if type(fn) ~= "function" then return refuse("must be a function") end
	return fn
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
	-- bus -- a closure built per call could only ever be added.
	region.frameTick = function()
		if region.customTextMode == "update" then region:RefreshCustomText() end
		region:UpdateText()
	end

	-- The two custom-text update modes are different *call counts*, not "throttled
	-- or not" (WA2 Text.lua). `event` runs the function once per state update and
	-- ignores the throttle entirely -- that is what `force` means here. `update`
	-- runs it on FrameTick, and there the throttle is the difference between a
	-- feature and a frame-rate bug.
	function region:RefreshCustomText(force)
		if not self.customTextFunc then return end
		if not force then
			local last = self.lastCustomTextUpdate
			if last and last + (self.customTextThrottle or 0) >= GetTime() then return end
		end
		self.customValues = WA.RunCustomTextFunc(self, self.customTextFunc)
		self.lastCustomTextUpdate = GetTime()
	end

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
		WA.textCore.Apply(self.text, data, "text_", size)
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

	-- Compiled only when something actually references %c -- including a string
	-- only a condition supplies, which is why the whole set is asked rather than
	-- data.displayText alone. Nothing recompiles per frame: this is modify.
	region.customTextFunc = nil
	region.customValues = nil
	region.lastCustomTextUpdate = nil
	region.customTextMode = data.customTextUpdate or "event"
	region.customTextThrottle = data.customTextUpdateThrottle or 0
	if data.customText and data.customText ~= "" and WA.ContainsCustomPlaceHolder(texts) then
		region.customTextFunc = compileCustomText(data.customText, data.id)
	end

	WA.textCore.Apply(region.text, data, "text_")
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
	local col = data.text_color or { 1, 1, 1, 1 }
	region:Color(col[1], col[2], col[3], col[4])

	-- ApplyPosition may SetParent, which resets child frame levels, so the text
	-- frame's is asserted after it -- below SUB_LEVEL, where region internals live.
	WA.regionPrototype.ApplyPosition(region, data)
	WA.regionPrototype.ApplyFrameStrata(region, data)
	region.textFrame:SetFrameLevel(region:GetFrameLevel() + 1)

	-- The region's own FrameTick subscription is installed *after* modifyFinish,
	-- which drops every subscriber before rebuilding the sub-regions'.
	WA.regionPrototype.modifyFinish(region, data)
	region.displayText = data.displayText or ""
	region:ConfigureTextUpdate()
	region:ConfigureSubscribers()
end

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
		text_size = 12,
		text_color = { 1, 1, 1, 1 },
		customText = "",
		customTextUpdate = "event",
		-- Upstream defaults this to 0, which in `update` mode is the custom
		-- function running on every frame. A default that costs frame rate is not
		-- a default.
		customTextUpdateThrottle = 0.2,
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
		text_color = { display = "Color", setter = "Color", type = "color" },
		text_size = { display = "Font Size", setter = "SetTextHeight", type = "number", min = 6, max = 72, step = 1 },
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
		WA.textCore.Apply(fs, data, "text_", size)
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
				type = "range", name = "Size", key = "text_size", min = 6, max = 72, step = 1, half = true,
				get = function() return data.text_size end,
				set = function(v) data.text_size = v; WA.Add(data, true) end,
			},
			{
				type = "range", name = "Alpha", key = "alpha", min = 0, max = 1, step = 0.05, half = true,
				get = function() return data.alpha end,
				set = function(v) data.alpha = v; WA.Add(data, true) end,
			},
			{
				type = "color", name = "Color", key = "text_color",
				get = function() return data.text_color end,
				set = function(v) data.text_color = v; WA.Add(data, true) end,
			},
		}

		-- Directly under the text field, whose label can only name the built-in
		-- symbols.
		local hint = WA.TextSymbolHint(data)
		if hint then table.insert(fields, 2, { type = "description", name = hint }) end

		local fontFields = WA.textCore.OptionFields(data, "region:textfont",
			function(key) return data["text_" .. key] end,
			function(key, v) data["text_" .. key] = v; WA.Add(data, true) end)
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

		-- The custom-text editor appears once something in the text asks for it,
		-- which is also how the connection between %c and this block is taught.
		if WA.ContainsCustomPlaceHolder(data.displayText) then
			table.insert(fields, { type = "header", name = "Custom Text" })
			table.insert(fields, {
				type = "code", name = "Custom Text Function", key = "customText", height = 160,
				get = function() return data.customText or "" end,
				set = function(v) data.customText = v; WA.Add(data, true) end,
				default = CUSTOM_TEXT_DEFAULT,
				-- The same wrapper compileCustomText uses, so the reported line
				-- numbers match what the user is looking at ("return " carries no
				-- newline).
				validate = function(txt)
					return WA.Widgets.LuaSyntaxError("return " .. (txt or ""), "custom text")
				end,
			})
			table.insert(fields, {
				type = "select", name = "Update on", key = "customTextUpdate",
				values = { "event", "update" },
				labels = { event = "Every state change", update = "Every frame" },
				get = function() return data.customTextUpdate or "event" end,
				set = function(v)
					data.customTextUpdate = v
					WA.Add(data, true)
					-- Repaints the tab: the throttle below decides nothing outside
					-- the per-frame mode.
					WA.RefreshOptions()
				end,
			})
			if data.customTextUpdate == "update" then
				table.insert(fields, {
					type = "range", name = "Throttle (seconds)", key = "customTextUpdateThrottle",
					min = 0, max = 2, step = 0.05,
					get = function() return data.customTextUpdateThrottle end,
					set = function(v) data.customTextUpdateThrottle = v; WA.Add(data, true) end,
				})
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

		WA.textCore.Apply(region.text, data, "text_")
		region.text:SetWidth(0)
		region.text:ClearAllPoints()
		region.text:SetPoint("CENTER", region, "CENTER")

		region:SetRegionAlpha(data.alpha or 1)
		WA.regionPrototype.ApplyPosition(region, data)
		WA.regionPrototype.ApplyFrameStrata(region, data)
		region.textFrame:SetFrameLevel(region:GetFrameLevel() + 1)
		WA.regionPrototype.modifyFinish(region, data)

		WA.textCore.SetText(region.text,
			"Region type " .. tostring(data.regionType) .. " not supported")
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
