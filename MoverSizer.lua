-- WeakestAuras -- the in-world mover/sizer: drag the selected aura to
-- reposition or resize it, with a live anchor-chain visual showing its
-- selfPoint -> anchor relationship, and magnetic snapping to nearby auras.
-- Mirrors WA2's MoverSizer; no off-screen arrow.
--
-- Dragging is cursor-delta based rather than WA2's region:StartMoving()/GetPoint
-- translation -- our position is the composed offset (RegionPrototype
-- UpdatePosition), so writing data.xOffset/yOffset from the cursor delta and
-- re-applying through the region's own SetOffset keeps that composition
-- authoritative instead of fighting it.

if WeakestAuras.disabled then return end

local WA = WeakestAuras
WA.Mover = {}
local M = WA.Mover

-- math.* (radians) throughout -- the degree-based global atan2/cos/sin that
-- retail WA2 uses aren't evidenced on this 1.12 client (DoiteAuras/pfUI use
-- math.atan2/cos/sin); atan2's radian output feeds cos/sin directly, so the
-- chain math is internally consistent either way.
local atan2, cos, sin, sqrt, floor = math.atan2, math.cos, math.sin, math.sqrt, math.floor

local INTERIM_SPACING = 40 -- px between anchor-chain dots (matches WA2)

-- The outline's SetBackdrop edge is painted inward from the frame boundary, so
-- sizing the mover to the exact region would draw the outline on top of the
-- content (same reason the group border needs padding -- see Regions.lua). Pad
-- the outline outward by half the edge so it straddles the content edge.
local OUTLINE_EDGE = 12
local OUTLINE_PAD = OUTLINE_EDGE / 2

-- Magnetism: a dragged edge/center within this many *physical* pixels of another
-- aura's edge/center snaps onto it. WA2's AlignmentLines do the same, but its
-- lines are built on frame:CreateLine (absent on 1.12) -- since alignment lines
-- are always axis-aligned (vertical for an x-match, horizontal for a y-match),
-- plain thin textures replace it with no rotated-texture rebuild needed.
local SNAP_THRESHOLD = 8

local mover
local overlay -- holds the two alignment-line textures (screen-space, TOOLTIP strata)
local updateHandles
local ANCHOR_ICON_TEXTURE = "Interface\\GLUES\\CharacterSelect\\Glues-AddOn-Icons.blp"

local function ensureDot(m, i)
	if m.dots[i] then return m.dots[i] end
	local dot = m:CreateTexture(nil, "OVERLAY")
	dot:SetWidth(16)
	dot:SetHeight(16)
	dot:SetTexture(ANCHOR_ICON_TEXTURE)
	dot:SetTexCoord(0, 0.25, 0, 1)
	dot:SetVertexColor(1, 1, 1, 0.25)
	m.dots[i] = dot
	return dot
end

-- Draws the selfPoint icon, the anchorPoint icon, the dotted line between them,
-- and the (dx, dy) label -- all read live from the region's current anchor
-- (region.selfPoint/anchorFrame/anchorPoint, set by RegionPrototype SetAnchor).
-- Suppressed entirely for a dynamicgroup child: its position is grower-owned, so
-- the anchor relationship isn't user-actionable and the numbers would just be
-- noise (WA2 hides the two point symbols there; we hide the whole chain).
local function updateChain(m)
	local region = m.region
	if not region then return end

	if m.childOfDynamic then
		m.selfIcon:Hide()
		m.anchorIcon:Hide()
		m.label:Hide()
		for i = 1, table.getn(m.dots) do m.dots[i]:Hide() end
		return
	end
	m.selfIcon:Show()
	m.anchorIcon:Show()

	m.selfIcon:ClearAllPoints()
	m.selfIcon:SetPoint("CENTER", region, region.selfPoint or "CENTER")
	m.anchorIcon:ClearAllPoints()
	m.anchorIcon:SetPoint("CENTER", region.anchorFrame or UIParent, region.anchorPoint or "CENTER")

	local sx, sy = m.selfIcon:GetCenter()
	local ax, ay = m.anchorIcon:GetCenter()
	for i = 1, table.getn(m.dots) do m.dots[i]:Hide() end
	if not sx or not ax then
		m.label:Hide()
		return
	end

	local dX, dY = sx - ax, sy - ay
	local dist = sqrt(dX * dX + dY * dY)
	local angle = atan2(dY, dX)

	local num = floor(dist / INTERIM_SPACING)
	for i = 1, num do
		local dot = ensureDot(m, i)
		local x = (dist - i * INTERIM_SPACING) * cos(angle)
		local y = (dist - i * INTERIM_SPACING) * sin(angle)
		dot:ClearAllPoints()
		dot:SetPoint("CENTER", m.anchorIcon, "CENTER", x, y)
		dot:Show()
	end

	-- Report the offset in the region's own (unscaled) coordinates -- the same
	-- numbers the Position sliders and data.xOffset/yOffset carry.
	local scale = (region:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
	m.label:SetText(string.format("(%d, %d)", floor(dX / scale + 0.5), floor(dY / scale + 0.5)))
	m.label:ClearAllPoints()
	m.label:SetPoint("CENTER", m.anchorIcon, "CENTER", (dist / 2) * cos(angle), (dist / 2) * sin(angle))
	m.label:Show()
end

-- Positions/sizes the outline over the region: a leaf's outline tracks the frame
-- directly; a group's follows its bounding box (which changes as children come
-- and go). Split out so both Attach and the per-frame re-resolve reuse it.
local function anchorToRegion(m, region)
	m:ClearAllPoints()
	if m.isGroup then
		local blx, bly = (region.blx or 0) - OUTLINE_PAD, (region.bly or 0) - OUTLINE_PAD
		local trx, try = (region.trx or 0) + OUTLINE_PAD, (region.try or 0) + OUTLINE_PAD
		m:SetPoint("BOTTOMLEFT", region, "CENTER", blx, bly)
		m:SetWidth(math.max(trx - blx, 8))
		m:SetHeight(math.max(try - bly, 8))
	else
		-- Pad outward so the inward-painted outline straddles the region edge
		-- rather than sitting inside it.
		m:SetPoint("TOPLEFT", region, "TOPLEFT", -OUTLINE_PAD, OUTLINE_PAD)
		m:SetPoint("BOTTOMRIGHT", region, "BOTTOMRIGHT", OUTLINE_PAD, -OUTLINE_PAD)
	end
end

-- Keeps the outline synced and redraws the chain. Re-resolves the live frame by
-- id every tick so a regionType switch (which rebuilds the frame under the same
-- id, without a selection change) re-attaches the mover instead of stranding it
-- on the old hidden frame -- and so a display whose visible frame is a clone
-- rather than the base one is followed as its clone set changes.
local function moverOnUpdate()
	local m = mover
	if not m.id then return end
	local region = WA.MoverRegion(m.id)
	if not region then return end
	if region ~= m.region then
		m.region = region
		anchorToRegion(m, region)
		m.resizable = (not m.isGroup) and m.data and m.data.width ~= nil and region.SetRegionWidth ~= nil
		updateHandles(m)
	elseif m.isGroup then
		anchorToRegion(m, region)
	end
	updateChain(m)
end

-- ---------------------------------------------------------------------------
-- Magnetism (WA2's AlignmentLines, scaled). Guides are
-- snapshotted once at drag start (other auras don't move mid-drag); each frame
-- the dragged region's left/center/right and bottom/center/top are tested
-- against them and the nearest within SNAP_THRESHOLD wins per axis. All math is
-- in physical pixels so regions at different effective scales compare correctly.
-- ---------------------------------------------------------------------------

-- Both toggles persist (WA2 keeps its equivalents in WeakAurasOptionsSaved) and
-- default on/unlocked. Magnetism is additionally suppressed by holding Shift
-- during a drag, the WA2 convention. M.locked gates startDragging/startSizing,
-- so it disables moving *and* resizing from the in-world mover.
M.magnetism = WA.Options().magnetism ~= false
M.locked = WA.Options().locked == true

function M.SetMagnetism(v)
	M.magnetism = v and true or false
	WA.Options().magnetism = M.magnetism
end

function M.SetLocked(v)
	M.locked = v and true or false
	WA.Options().locked = M.locked
	if mover then updateHandles(mover) end
end

local function ensureOverlay()
	if overlay then return overlay end
	overlay = CreateFrame("Frame", nil, UIParent)
	overlay:SetAllPoints(UIParent)
	overlay:SetFrameStrata("TOOLTIP")
	local v = overlay:CreateTexture(nil, "OVERLAY")
	v:SetTexture(0.2, 0.9, 1, 0.85); v:Hide()
	overlay.vLine = v
	local h = overlay:CreateTexture(nil, "OVERLAY")
	h:SetTexture(0.2, 0.9, 1, 0.85); h:Hide()
	overlay.hLine = h
	return overlay
end

local function hideLines()
	if overlay then overlay.vLine:Hide(); overlay.hLine:Hide() end
end

-- Lines span the full screen dimension (vertical = top-to-bottom at x,
-- horizontal = left-to-right at y), matching WA2 -- the two-anchor stretch fixes
-- the extent while SetWidth/SetHeight sets the thin dimension. A texture's
-- coordinates are in its parent's (UIParent) space, so a physical pixel value
-- divides back down by UIParent's scale to position it.
local function drawVLine(x)
	local ov = ensureOverlay()
	local us = UIParent:GetEffectiveScale() or 1
	local v = ov.vLine
	v:ClearAllPoints()
	v:SetWidth(2)
	v:SetPoint("TOP", UIParent, "TOPLEFT", x / us, 0)
	v:SetPoint("BOTTOM", UIParent, "BOTTOMLEFT", x / us, 0)
	v:Show()
end

local function drawHLine(y)
	local ov = ensureOverlay()
	local us = UIParent:GetEffectiveScale() or 1
	local h = ov.hLine
	h:ClearAllPoints()
	h:SetHeight(2)
	h:SetPoint("LEFT", UIParent, "BOTTOMLEFT", 0, y / us)
	h:SetPoint("RIGHT", UIParent, "BOTTOMRIGHT", 0, y / us)
	h:Show()
end

-- A frame's edges in physical pixels (nil until it has been laid out).
local function regionBoundsPhys(frame)
	local s = frame:GetEffectiveScale() or 1
	local l, r, t, b = frame:GetLeft(), frame:GetRight(), frame:GetTop(), frame:GetBottom()
	if not l or not r or not t or not b then return nil end
	return l * s, r * s, t * s, b * s
end

local function collectDescendants(id, set)
	set[id] = true
	local data = WeakestAurasDB.displays[id]
	local kids = data and data.controlledChildren
	if kids then
		for i = 1, table.getn(kids) do collectDescendants(kids[i], set) end
	end
end

-- Snapshot every other visible leaf clone's edge/center coordinates as snap
-- targets, plus the screen center. Skips the dragged region and (if it's a
-- group) its whole subtree -- those move with the drag. Coordinates only: the
-- lines are full-screen (WA2), so a guide needs no perpendicular extent.
local function buildGuides(m)
	local xg, yg = {}, {}
	local excl = {}
	if m.id then collectDescendants(m.id, excl) end
	for id, data in pairs(WeakestAurasDB.displays) do
		if not excl[id] and not WA.IsGroup(data) then
			WA.ForEachClone(id, function(frame)
				if frame:IsShown() then
					local l, r, t, b = regionBoundsPhys(frame)
					if l then
						table.insert(xg, l); table.insert(xg, (l + r) / 2); table.insert(xg, r)
						table.insert(yg, b); table.insert(yg, (t + b) / 2); table.insert(yg, t)
					end
				end
			end)
		end
	end
	local us = UIParent:GetEffectiveScale() or 1
	local cx, cy = UIParent:GetCenter()
	if cx then
		table.insert(xg, cx * us)
		table.insert(yg, cy * us)
	end
	m.xGuides = xg
	m.yGuides = yg
end

-- Nearest guide (smallest absolute gap) within threshold across the three
-- dragged candidates, or nil. Returns the signed delta to close the gap and the
-- guide coordinate (where the line is drawn).
local function nearestGuide(guides, cands)
	local bestAbs, bestDelta, bestCoord
	for gi = 1, table.getn(guides) do
		local gc = guides[gi]
		for ci = 1, table.getn(cands) do
			local delta = gc - cands[ci]
			local a = delta < 0 and -delta or delta
			if a <= SNAP_THRESHOLD and (not bestAbs or a < bestAbs) then
				bestAbs, bestDelta, bestCoord = a, delta, gc
			end
		end
	end
	return bestDelta, bestCoord
end

-- Snap the just-computed offset onto the nearest guide per axis and draw the
-- alignment line(s). Deltas are in physical px; dividing by the region's scale
-- converts back to its own offset units.
-- Cursor deltas are continuous, so a drag would otherwise write 37.4213 into
-- data.width and leave the options sliders showing it. Everything the mover and
-- sizer store is snapped to whole pixels: a fractional edge only buys a blurry
-- half-pixel seam, and the sliders all step by 1 anyway. (Deliberately NOT
-- applied after applySnap -- an exact guide alignment is the one case that
-- should win over the grid.)
local function round(v)
	return math.floor(v + 0.5)
end

local function applySnap(m, region, data, scale)
	local l, r, t, b = regionBoundsPhys(region)
	if not l then hideLines(); return end
	local hc, vc = (l + r) / 2, (t + b) / 2

	local dxDelta, xCoord = nearestGuide(m.xGuides, { l, hc, r })
	local dyDelta, yCoord = nearestGuide(m.yGuides, { b, vc, t })

	if dxDelta then
		data.xOffset = data.xOffset + dxDelta / scale
	end
	if dyDelta then
		data.yOffset = data.yOffset + dyDelta / scale
	end
	if dxDelta or dyDelta then
		region:SetOffset(data.xOffset, data.yOffset)
	end

	if xCoord then
		drawVLine(xCoord)
	elseif overlay then
		overlay.vLine:Hide()
	end
	if yCoord then
		drawHLine(yCoord)
	elseif overlay then
		overlay.hLine:Hide()
	end
end

local function onDragUpdate()
	local m = mover
	local region, data = m.region, m.data
	if not region or not data then return end
	local cx, cy = GetCursorPosition()
	local scale = region:GetEffectiveScale() or 1
	local dx = (cx - m.startCx) / scale
	local dy = (cy - m.startCy) / scale
	data.xOffset = round(m.startX + dx)
	data.yOffset = round(m.startY + dy)
	region:SetOffset(data.xOffset, data.yOffset)

	if M.magnetism and not IsShiftKeyDown() then
		applySnap(m, region, data, scale)
	else
		hideLines()
	end
end

local function startDragging()
	local m = mover
	local region, data = m.region, m.data
	if region and WA.CancelAnimation then WA.CancelAnimation(region, true, true, true, true, true, false) end
	if not region or not data then return end
	if M.locked then return end
	-- A dynamicgroup owns its children's positions; dragging one is meaningless.
	if m.childOfDynamic then return end
	m.dragging = true
	m.startCx, m.startCy = GetCursorPosition()
	m.startX, m.startY = data.xOffset or 0, data.yOffset or 0
	buildGuides(m) -- snapshot snap targets once; they don't move mid-drag
	m:SetScript("OnUpdate", function() onDragUpdate(); moverOnUpdate() end)
end

local function stopDragging()
	local m = mover
	if not m.dragging then return end
	m.dragging = false
	m:SetScript("OnUpdate", moverOnUpdate)
	hideLines()
	if m.data then
		WA.Add(m.data, true)
		if WA.Animate and m.region then WA.Animate("display", m.data.uid, "main", m.data.animation and m.data.animation.main, m.region, false, nil, true, m.region.cloneId) end
	end
end

-- ---------------------------------------------------------------------------
-- Sizer: eight edge/corner handles that resize the region. Like the mover,
-- cursor-delta driven (avoids the unverified StartSizing/SetResizable). The
-- selfPoint-aware offset adjustment keeps the non-dragged edge anchored while
-- the dragged one follows the cursor (WA2's SizingSetData). A group isn't
-- resizable (its box follows its children); a dynamicgroup *child* is (its size
-- is its own even though the grower owns its position -- so the handles show for
-- it while the body drag doesn't).
-- ---------------------------------------------------------------------------

local MIN_DIM = 4
local HANDLE_POINTS = { "TOPLEFT", "TOP", "TOPRIGHT", "RIGHT", "BOTTOMRIGHT", "BOTTOM", "BOTTOMLEFT", "LEFT" }
local HANDLE_TEXTURE = "Interface\\AddOns\\WeakestAuras\\textures\\UI-Listbox-Highlight.tga"
local CORNER_SIZE = 16
local EDGE_SIZE = 8

local function resizeSnap(m, region, width, height, hasL, hasR, hasT, hasB, scale)
	local l, r, t, b = regionBoundsPhys(region)
	if not l then hideLines(); return width, height end
	local xEdge = hasL and l or (hasR and r)
	local yEdge = hasB and b or (hasT and t)
	local xDelta, xCoord
	local yDelta, yCoord
	if xEdge then xDelta, xCoord = nearestGuide(m.xGuides or {}, { xEdge }) end
	if yEdge then yDelta, yCoord = nearestGuide(m.yGuides or {}, { yEdge }) end
	if not xDelta and not yDelta then hideLines(); return width, height, false end
	local useX = xDelta and (not yDelta or math.abs(xDelta) <= math.abs(yDelta))
	if useX then
		width = round(width + (hasR and xDelta or -xDelta) / scale)
		if m.preserveAspect then height = width / m.aspectRatio end
	elseif yDelta then
		height = round(height + (hasT and yDelta or -yDelta) / scale)
		if m.preserveAspect then width = height * m.aspectRatio end
	end
	if width < MIN_DIM then width = MIN_DIM end
	if height < MIN_DIM then height = MIN_DIM end
	if useX then drawVLine(xCoord) elseif xDelta then hideLines() end
	if not m.preserveAspect and yDelta and not useX then drawHLine(yCoord) end
	return width, height, true
end

local function onSizeUpdate()
	local m = mover
	local region, data = m.region, m.data
	if not region or not data then return end
	local cx, cy = GetCursorPosition()
	local scale = region:GetEffectiveScale() or 1
	local dx = (cx - m.startCx) / scale
	local dy = (cy - m.startCy) / scale
	local sp = m.sizePoint
	local hasL, hasR = string.find(sp, "LEFT"), string.find(sp, "RIGHT")
	local hasT, hasB = string.find(sp, "TOP"), string.find(sp, "BOTTOM")

	-- Rounded before the clamp so MIN_DIM stays the real floor, and before the
	-- offset math below reads dW/dH -- an edge that lands on a whole pixel must
	-- shift the opposite edge by a whole pixel too.
	local newW = m.startW
	if hasR then newW = m.startW + dx elseif hasL then newW = m.startW - dx end
	newW = round(newW)
	if newW < MIN_DIM then newW = MIN_DIM end
	local newH = m.startH
	if hasT then newH = m.startH + dy elseif hasB then newH = m.startH - dy end
	if m.preserveAspect then
		local ratio = m.aspectRatio
		local dW, dH = newW - m.startW, newH - m.startH
		if math.abs(dW) >= math.abs(dH * ratio) then
			newW = round(newW)
			newH = newW / ratio
		else
			newH = round(newH)
			newW = newH * ratio
		end
		if newW < MIN_DIM then
			newW = MIN_DIM
			newH = newW / ratio
		elseif newH < MIN_DIM then
			newH = MIN_DIM
			newW = newH * ratio
		end
	end
	if not m.preserveAspect then
		newH = round(newH)
		if newH < MIN_DIM then newH = MIN_DIM end
	elseif newW < MIN_DIM or newH < MIN_DIM then
		newW, newH = MIN_DIM, MIN_DIM / m.aspectRatio
	end

	data.width, data.height = newW, newH
	region:SetRegionWidth(newW)
	region:SetRegionHeight(newH)

	-- A dynamicgroup child's position is grower-owned; only resize it (the grower
	-- repositions it with the new size when we commit on release). For everything
	-- else, shift the offset so the anchored (selfPoint) edge stays put -- only
	-- when the dragged edge is on the same side as the anchor does it move.
	if m.childOfDynamic then return end
	local dW, dH = newW - m.startW, newH - m.startH
	local asp = region.selfPoint or "CENTER"
	local xoff = m.startXOff
	if string.find(asp, "LEFT") then
		if hasL then xoff = m.startXOff - dW end
	elseif string.find(asp, "RIGHT") then
		if hasR then xoff = m.startXOff + dW end
	else -- CENTER
		if hasL then xoff = m.startXOff - dW / 2 elseif hasR then xoff = m.startXOff + dW / 2 end
	end
	local yoff = m.startYOff
	if string.find(asp, "BOTTOM") then
		if hasB then yoff = m.startYOff - dH end
	elseif string.find(asp, "TOP") then
		if hasT then yoff = m.startYOff + dH end
	else -- CENTER
		if hasB then yoff = m.startYOff - dH / 2 elseif hasT then yoff = m.startYOff + dH / 2 end
	end

	-- A CENTER-anchored resize halves dW/dH, so the offset can still land on a
	-- half pixel even though both dimensions are whole. Recomputed from
	-- startXOff every frame rather than accumulated, so rounding it can't drift.
	xoff, yoff = round(xoff), round(yoff)
	data.xOffset, data.yOffset = xoff, yoff
	region:SetOffset(xoff, yoff)

	if M.magnetism and (m.preserveAspect or not IsShiftKeyDown()) then
		local snapW, snapH, snapped = resizeSnap(m, region, newW, newH, hasL, hasR, hasT, hasB, scale)
		if snapped then
			newW, newH = snapW, snapH
			data.width, data.height = newW, newH
			region:SetRegionWidth(newW)
			region:SetRegionHeight(newH)
			local ndW, ndH = newW - m.startW, newH - m.startH
			if string.find(asp, "LEFT") then
				if hasL then xoff = m.startXOff - ndW end
			elseif string.find(asp, "RIGHT") then
				if hasR then xoff = m.startXOff + ndW end
			else
				if hasL then xoff = m.startXOff - ndW / 2 elseif hasR then xoff = m.startXOff + ndW / 2 end
			end
			if string.find(asp, "BOTTOM") then
				if hasB then yoff = m.startYOff - ndH end
			elseif string.find(asp, "TOP") then
				if hasT then yoff = m.startYOff + ndH end
			else
				if hasB then yoff = m.startYOff - ndH / 2 elseif hasT then yoff = m.startYOff + ndH / 2 end
			end
			xoff, yoff = round(xoff), round(yoff)
			data.xOffset, data.yOffset = xoff, yoff
			region:SetOffset(xoff, yoff)
		end
	else
		hideLines()
	end
end

local function startSizing(point)
	local m = mover
	local region, data = m.region, m.data
	if region and WA.CancelAnimation then WA.CancelAnimation(region, true, true, true, true, true, false) end
	if not region or not data then return end
	if M.locked then return end
	m.sizing = true
	m.sizePoint = point
	m.preserveAspect = (string.find(point, "LEFT") or string.find(point, "RIGHT"))
		and (string.find(point, "TOP") or string.find(point, "BOTTOM"))
		and IsShiftKeyDown() and true or false
	m.startCx, m.startCy = GetCursorPosition()
	m.startW = data.width or (region:GetWidth() or 8)
	m.startH = data.height or (region:GetHeight() or 8)
	m.aspectRatio = m.startW > 0 and m.startH > 0 and m.startW / m.startH or 1
	m.startXOff = data.xOffset or 0
	m.startYOff = data.yOffset or 0
	buildGuides(m)
	m:SetScript("OnUpdate", function() onSizeUpdate(); moverOnUpdate() end)
end

local function stopSizing()
	local m = mover
	if not m.sizing then return end
	m.sizing = false
	m:SetScript("OnUpdate", moverOnUpdate)
	if m.data then
		WA.Add(m.data, true)
		if WA.Animate and m.region then WA.Animate("display", m.data.uid, "main", m.data.animation and m.data.animation.main, m.region, false, nil, true, m.region.cloneId) end
	end
end

local function makeHandleTexture(handle, coords)
	local tex = handle:CreateTexture(nil, "OVERLAY")
	tex:SetTexture(HANDLE_TEXTURE)
	tex:SetBlendMode("ADD")
	if coords then tex:SetTexCoord(unpack(coords)) end
	tex:Hide()
	return tex
end

local function hideHandleVisuals(handle)
	for i = 1, table.getn(handle.visuals or {}) do handle.visuals[i]:Hide() end
end

local function showHandleVisuals(handle)
	if not handle._active then return end
	for i = 1, table.getn(handle.visuals or {}) do handle.visuals[i]:Show() end
end

updateHandles = function(m)
	local active = m.resizable and not M.locked
	for i = 1, table.getn(m.handles or {}) do
		local handle = m.handles[i]
		handle._active = active
		if active then handle:Show() else handle:Hide() end
		hideHandleVisuals(handle)
	end
end

local function addCorner(handle, firstCoords, firstPoints, secondCoords, secondPoints)
	local first = makeHandleTexture(handle, firstCoords)
	first:SetPoint(unpack(firstPoints[1]))
	first:SetPoint(unpack(firstPoints[2]))
	local second = makeHandleTexture(handle, secondCoords)
	second:SetPoint(unpack(secondPoints[1]))
	second:SetPoint(unpack(secondPoints[2]))
	handle.visuals = { first, second }
end

local function addEdge(handle, coords, firstPoint, secondPoint)
	local tex = makeHandleTexture(handle, coords)
	tex:SetPoint(unpack(firstPoint))
	tex:SetPoint(unpack(secondPoint))
	handle.visuals = { tex }
end

local function configureCorner(handle, parent, point, firstCoords, secondCoords)
	handle:SetWidth(CORNER_SIZE)
	handle:SetHeight(CORNER_SIZE)
	handle:SetPoint(point, parent, point)
	local first, second
	if point == "TOPRIGHT" then
		first = makeHandleTexture(handle, firstCoords)
		first:SetPoint("TOPRIGHT", handle, "TOPRIGHT", -3, -3)
		first:SetPoint("BOTTOMLEFT", handle, "BOTTOM")
		second = makeHandleTexture(handle, secondCoords)
		second:SetPoint("TOPRIGHT", first, "TOPLEFT")
		second:SetPoint("BOTTOMLEFT", handle, "LEFT")
	elseif point == "BOTTOMRIGHT" then
		first = makeHandleTexture(handle, firstCoords)
		first:SetPoint("BOTTOMRIGHT", handle, "BOTTOMRIGHT", -3, 3)
		first:SetPoint("TOPLEFT", handle, "TOP")
		second = makeHandleTexture(handle, secondCoords)
		second:SetPoint("BOTTOMRIGHT", first, "BOTTOMLEFT")
		second:SetPoint("TOPLEFT", handle, "LEFT")
	elseif point == "BOTTOMLEFT" then
		first = makeHandleTexture(handle, firstCoords)
		first:SetPoint("BOTTOMLEFT", handle, "BOTTOMLEFT", 3, 3)
		first:SetPoint("TOPRIGHT", handle, "TOP")
		second = makeHandleTexture(handle, secondCoords)
		second:SetPoint("BOTTOMLEFT", first, "BOTTOMRIGHT")
		second:SetPoint("TOPRIGHT", handle, "RIGHT")
	else
		first = makeHandleTexture(handle, firstCoords)
		first:SetPoint("TOPLEFT", handle, "TOPLEFT", 3, -3)
		first:SetPoint("BOTTOMRIGHT", handle, "BOTTOM")
		second = makeHandleTexture(handle, secondCoords)
		second:SetPoint("TOPLEFT", first, "TOPRIGHT")
		second:SetPoint("BOTTOMRIGHT", handle, "RIGHT")
	end
	handle.visuals = { first, second }
end

local function configureEdge(handle, point, leftOrTop, rightOrBottom, coords)
	if point == "TOP" then
		handle:SetHeight(EDGE_SIZE)
		handle:SetPoint("TOPRIGHT", rightOrBottom, "TOPLEFT")
		handle:SetPoint("TOPLEFT", leftOrTop, "TOPRIGHT")
		addEdge(handle, coords, { "TOPRIGHT", rightOrBottom, "TOPRIGHT", -3, -3 }, { "BOTTOMLEFT", leftOrTop, "LEFT", 3, 0 })
	elseif point == "RIGHT" then
		handle:SetWidth(EDGE_SIZE)
		handle:SetPoint("BOTTOMRIGHT", rightOrBottom, "TOPRIGHT")
		handle:SetPoint("TOPRIGHT", leftOrTop, "BOTTOMRIGHT")
		addEdge(handle, coords, { "BOTTOMRIGHT", rightOrBottom, "BOTTOMRIGHT", -3, 3 }, { "TOPLEFT", leftOrTop, "TOP", 0, -3 })
	elseif point == "BOTTOM" then
		handle:SetHeight(EDGE_SIZE)
		handle:SetPoint("BOTTOMLEFT", leftOrTop, "BOTTOMRIGHT")
		handle:SetPoint("BOTTOMRIGHT", rightOrBottom, "BOTTOMLEFT")
		addEdge(handle, coords, { "BOTTOMLEFT", leftOrTop, "BOTTOMLEFT", 3, 3 }, { "TOPRIGHT", rightOrBottom, "RIGHT", -3, 0 })
	else
		handle:SetWidth(EDGE_SIZE)
		handle:SetPoint("TOPLEFT", leftOrTop, "BOTTOMLEFT")
		handle:SetPoint("BOTTOMLEFT", rightOrBottom, "TOPLEFT")
		addEdge(handle, coords, { "BOTTOMLEFT", rightOrBottom, "BOTTOMLEFT", 3, 3 }, { "TOPRIGHT", leftOrTop, "TOP", 0, -3 })
	end
end

local function ensureMover()
	if mover then return mover end
	local m = CreateFrame("Frame", nil, UIParent)
	m:SetFrameStrata("HIGH")
	m:EnableMouse(true)
	m:SetBackdrop({
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = OUTLINE_EDGE,
		insets = { left = 0, right = 0, top = 0, bottom = 0 },
	})
	m:SetBackdropBorderColor(1, 0.82, 0, 0.9)
	m.dots = {}

	local selfIcon = m:CreateTexture(nil, "OVERLAY")
	selfIcon:SetWidth(16); selfIcon:SetHeight(16)
	selfIcon:SetTexture(ANCHOR_ICON_TEXTURE)
	selfIcon:SetTexCoord(0, 0.25, 0, 1)
	m.selfIcon = selfIcon

	local anchorIcon = m:CreateTexture(nil, "OVERLAY")
	anchorIcon:SetWidth(16); anchorIcon:SetHeight(16)
	anchorIcon:SetTexture(ANCHOR_ICON_TEXTURE)
	anchorIcon:SetTexCoord(0, 0.25, 0, 1)
	m.anchorIcon = anchorIcon

	local label = m:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	label:Hide()
	m.label = label

	-- Eight resize handles, one per edge/corner. The buttons remain the hit areas;
	-- their child textures carry WA2's L-shaped visual treatment and stay hidden
	-- until the pointer enters a live handle.
	m.handles = {}
	local corners = {}
	local cornerCoords = {
		TOPLEFT = { { 0.5, 0, 0, 0, 0.5, 1, 0, 1 }, { 0.5, 0, 0.5, 1, 1, 0, 1, 1 } },
		TOPRIGHT = { { 0.5, 0, 0, 0, 0.5, 1, 0, 1 }, { 0, 0, 0, 1, 0.5, 0, 0.5, 1 } },
		BOTTOMRIGHT = { { 1, 0, 0.5, 0, 1, 1, 0.5, 1 }, { 0, 0, 0, 1, 0.5, 0, 0.5, 1 } },
		BOTTOMLEFT = { { 1, 0, 0.5, 0, 1, 1, 0.5, 1 }, { 0.5, 0, 0.5, 1, 1, 0, 1, 1 } },
	}
	for i = 1, table.getn(HANDLE_POINTS) do
		local point = HANDLE_POINTS[i]
		local h = CreateFrame("Button", nil, m)
		h:SetWidth(CORNER_SIZE)
		h:SetHeight(CORNER_SIZE)
		if point == "TOPLEFT" then
			corners[point] = h
			configureCorner(h, m, point, cornerCoords[point][1], cornerCoords[point][2])
		elseif point == "TOPRIGHT" then
			corners[point] = h
			configureCorner(h, m, point, cornerCoords[point][1], cornerCoords[point][2])
		elseif point == "BOTTOMRIGHT" then
			corners[point] = h
			configureCorner(h, m, point, cornerCoords[point][1], cornerCoords[point][2])
		elseif point == "BOTTOMLEFT" then
			corners[point] = h
			configureCorner(h, m, point, cornerCoords[point][1], cornerCoords[point][2])
		end
		m.handles[i] = h
	end
	for i = 1, table.getn(HANDLE_POINTS) do
		local point = HANDLE_POINTS[i]
		local h = m.handles[i]
		if point == "TOP" then
			configureEdge(h, point, corners.TOPLEFT, corners.TOPRIGHT, nil)
		elseif point == "RIGHT" then
			configureEdge(h, point, corners.TOPRIGHT, corners.BOTTOMRIGHT, nil)
		elseif point == "BOTTOM" then
			configureEdge(h, point, corners.BOTTOMLEFT, corners.BOTTOMRIGHT, { 1, 0, 0, 0, 1, 1, 0, 1 })
		elseif point == "LEFT" then
			configureEdge(h, point, corners.TOPLEFT, corners.BOTTOMLEFT, { 1, 0, 0, 0, 1, 1, 0, 1 })
		end
		h:EnableMouse(true)
		h:SetScript("OnEnter", function() showHandleVisuals(h) end)
		h:SetScript("OnLeave", function() hideHandleVisuals(h) end)
		h:SetScript("OnMouseDown", function() startSizing(point) end)
		h:SetScript("OnMouseUp", stopSizing)
		hideHandleVisuals(h)
	end

	m:SetScript("OnMouseDown", startDragging)
	m:SetScript("OnMouseUp", stopDragging)
	m:Hide()
	m.resizable = false
	mover = m
	return m
end

-- Attach the mover to a display's live region (the base "" clone). Called by the
-- options list on every selection change; the selection is force-shown (see
-- WA.SetPreview) so there's always a visible region to grab. nil/unrenderable
-- detaches.
function M.Attach(id)
	local m = ensureMover()
	local data = id and WeakestAurasDB.displays[id]
	local region = id and WA.MoverRegion(id)
	if not data or not region then
		M.Detach()
		return
	end
	m.id = id
	m.region = region
	m.data = data
	m.isGroup = WA.IsGroup(data) or false
	local pdata = data.parent and WeakestAurasDB.displays[data.parent]
	m.childOfDynamic = (pdata and pdata.regionType == "dynamicgroup") or false

	anchorToRegion(m, region)
	-- A dynamicgroup child can't be dragged; make that visible by dimming the
	-- outline (green = movable, grey = layout-controlled).
	if m.childOfDynamic then
		m:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.7)
	else
		m:SetBackdropBorderColor(1, 0.82, 0, 0.9)
	end
	-- Resize handles show for a leaf that carries width/height + the setters
	-- (icon/progressbar) -- including a dynamicgroup child (its size is its own);
	-- a group's box is derived from its children, so it isn't resizable.
	m.resizable = (not m.isGroup) and data.width ~= nil and region.SetRegionWidth ~= nil
	updateHandles(m)
	m:SetScript("OnUpdate", moverOnUpdate)
	m:Show()
end

function M.Detach()
	if not mover then return end
	mover.dragging = false
	mover.id = nil
	mover.region = nil
	mover.data = nil
	mover.resizable = false
	updateHandles(mover)
	mover:SetScript("OnUpdate", nil)
	mover:Hide()
	hideLines()
end
