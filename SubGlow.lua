-- WeakestAuras -- the "subglow" sub-region: an animated proc-glow (the
-- "IconAlert" ant-march) drawn over an icon. Mirrors WA2's Glow (§8).
-- Upstream section refs (§N) point at design/architecture/weakauras2-reference.md
--
-- Masque and LibCustomGlow don't port to 1.12, so the animation is driven here.
-- Opt-in and default-OFF, since a glow is almost always condition-driven.

if WeakestAuras.disabled then return end

local WA = WeakestAuras
local proto = WA.regionPrototype

local TEX_ALERT = "Interface\\AddOns\\WeakestAuras\\textures\\IconAlert"
local TEX_ANTS = "Interface\\AddOns\\WeakestAuras\\textures\\IconAlertAnts"
local TEX_SOLID = "Interface\\Buttons\\WHITE8X8"
local TEX_STAR = "Interface\\Buttons\\GlowStar"
local TEX_SOFT = "Interface\\Buttons\\CheckButtonGlow"
local FRAME_INTERVAL = 0.04

-- Regions are written as source pixels and normalised here rather than as
-- decimal literals, so they stay checkable against the artwork.
local function rect(x, y, w, h, sheetWidth, sheetHeight)
	return x / sheetWidth, (x + w) / sheetWidth, y / sheetHeight, (y + h) / sheetHeight
end

local ALERT_W, ALERT_H = 128, 256
local ANTS_W, ANTS_H = 256, 256
local GLOW_X, GLOW_Y, GLOW_W, GLOW_H = 0, 136, 66, 66
local GLOW_SCALE = 66 / 54
local SOFT_GLOW_SCALE = 64 / 34
local DEFAULT_GLOW_COLOR = { 248 / 255, 212 / 255, 72 / 255, 1 }

-- The ant sheet is a grid of 44px cells on a 48px pitch, inset 2px/1px from the
-- top-left corner; 22 frames form the loop. Cells 23-25 are the next cycle's
-- first three frames, so playing all 25 replays them and visibly hesitates.
local ANT_COLUMNS, ANT_FRAMES = 5, 22
local ANT_PITCH, ANT_CELL = 48, 44
local ANT_X0, ANT_Y0 = 2, 1

local antFrames = {}
do
	local col, row = 0, 0
	for i = 1, ANT_FRAMES do
		antFrames[i] = { rect(ANT_X0 + col * ANT_PITCH, ANT_Y0 + row * ANT_PITCH, ANT_CELL, ANT_CELL, ANTS_W, ANTS_H) }
		col = col + 1
		if col >= ANT_COLUMNS then col = 0; row = row + 1 end
	end
end

-- Frames cannot be destroyed, so a released overlay is pooled rather than
-- dropped.
local pools = {}
local numOverlays = 0

-- Every lit overlay advances off one shared ticker instead of carrying its own
-- OnUpdate: the cost stays one timer however many auras glow at once, and the
-- glows stay in phase rather than drifting apart. A newly lit overlay therefore
-- joins the cycle wherever it currently is, which is the point.
local lit = {}
local numLit = 0
local antIndex = 1
local ticker

local function applyButtonOverlay(overlay, now)
	overlay.bgFrame:Show()
	overlay.antTex:Show()
	for i = 1, table.getn(overlay.segments or {}) do
		overlay.segments[i]:Hide()
		if overlay.borders[i] then overlay.borders[i]:Hide() end
	end
	local f = antFrames[antIndex]
	overlay.antTex:SetTexCoord(f[1], f[2], f[3], f[4])
end

local function applyPixel(overlay, now)
	overlay.bgFrame:Hide()
	overlay.antTex:Hide()
	local p = overlay.params or {}
	local width = overlay:GetWidth() or 0
	local height = overlay:GetHeight() or 0
	local lines = p.lines or 8
	local frequency = p.frequency or 0
	local phase = now * math.abs(frequency)
	if frequency < 0 then phase = -phase end
	local length = p.length or 10
	local thickness = p.thickness or 1
	local borderEnabled = p.border and true or false
	local perimeter = 2 * (width + height)
	if perimeter <= 0 then return end
	for i = 1, lines do
		local fraction = math.mod(phase + (i - 1) / lines, 1)
		if fraction < 0 then fraction = fraction + 1 end
		local distance = fraction * perimeter
		local segment = overlay.segments[i]
		local border = overlay.borders[i]
		if border then border:Hide() end
		local side, along, sideLength
		if distance < width then
			side, along, sideLength = "TOP", distance, width
		elseif distance < width + height then
			side, along, sideLength = "RIGHT", distance - width, height
		elseif distance < width * 2 + height then
			side, along, sideLength = "BOTTOM", distance - width - height, width
		else
			side, along, sideLength = "LEFT", distance - width * 2 - height, height
		end
		if along < 0 then along = 0 elseif along > sideLength then along = sideLength end
		local vertical = side == "LEFT" or side == "RIGHT"
		local segmentLength = math.min(length, sideLength)
		segment:SetWidth(vertical and thickness or segmentLength)
		segment:SetHeight(vertical and segmentLength or thickness)
		segment:ClearAllPoints()
		local x, y = 0, 0
		if side == "TOP" then x, y = -width / 2 + along, height / 2
		elseif side == "RIGHT" then x, y = width / 2, height / 2 - along
		elseif side == "BOTTOM" then x, y = width / 2 - along, -height / 2
		else x, y = -width / 2, -height / 2 + along end
		segment:SetPoint("CENTER", overlay, "CENTER", x, y)
		segment:Show()
		if border and borderEnabled then
			border:SetWidth(vertical and thickness + 2 or segmentLength + 2)
			border:SetHeight(vertical and segmentLength + 2 or thickness + 2)
			border:ClearAllPoints()
			border:SetPoint("CENTER", overlay, "CENTER", x, y)
			border:Show()
		end
	end
	for i = lines + 1, table.getn(overlay.segments) do
		overlay.segments[i]:Hide()
		if overlay.borders[i] then overlay.borders[i]:Hide() end
	end
end

local function applyPixelColor(overlay, color)
	local c = color or { 1, 1, 1, 1 }
	for i = 1, table.getn(overlay.segments or {}) do
		overlay.segments[i]:SetVertexColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1)
		if overlay.borders[i] then overlay.borders[i]:SetVertexColor(0, 0, 0, c[4] or 1) end
	end
end

-- Colours every art an overlay's renderer might be drawing with. `bg`/`antTex`
-- are buttonOverlay's and are the only two a caller reaches without this; the
-- other four types draw through textures created per pool type, so tinting the
-- pair alone leaves a Pixel or ACShine glow white whatever colour was asked for.
-- nil colour means "the default gold", which is not the same as white: the ants
-- texture is art rather than a tint surface and stays untinted there.
local function tintOverlay(overlay, color)
	if not overlay then return end
	if color then
		overlay.bg:SetVertexColor(color[1] or 1, color[2] or 1, color[3] or 1, color[4] or 1)
		overlay.antTex:SetVertexColor(color[1] or 1, color[2] or 1, color[3] or 1, color[4] or 1)
	else
		overlay.bg:SetVertexColor(DEFAULT_GLOW_COLOR[1], DEFAULT_GLOW_COLOR[2],
			DEFAULT_GLOW_COLOR[3], DEFAULT_GLOW_COLOR[4])
		overlay.antTex:SetVertexColor(1, 1, 1, 1)
	end
	local c = color or DEFAULT_GLOW_COLOR
	if overlay.poolType == "Pixel" then
		applyPixelColor(overlay, c)
	elseif overlay.poolType == "ACShine" then
		for i = 1, table.getn(overlay.particles or {}) do
			overlay.particles[i]:SetVertexColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1)
		end
	elseif overlay.poolType == "Soft" or overlay.poolType == "Pulse" then
		overlay.softTex:SetVertexColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1)
	end
end

local function applyACShine(overlay, now)
	overlay.bgFrame:Hide()
	overlay.antTex:Hide()
	local p = overlay.params or {}
	local count = p.lines or 8
	local frequency = p.frequency or 0
	local scale = p.scale or 1
	local width = overlay:GetWidth() or 0
	local height = overlay:GetHeight() or 0
	if p.shape ~= "circular" then
		local sizes = { 7, 6, 5, 4 }
		local perimeter = 2 * (width + height)
		if perimeter <= 0 then return end
		local textureIndex = 0
		for group = 1, 4 do
			local phase = now * frequency / group
			for i = 1, count do
				textureIndex = textureIndex + 1
				local fraction = math.mod(i / count + phase, 1)
				if fraction < 0 then fraction = fraction + 1 end
				local distance = fraction * perimeter
				local x, y
				if distance < width then
					x, y = -width / 2 + distance, -height / 2
				elseif distance < width + height then
					x, y = width / 2, -height / 2 + distance - width
				elseif distance < width * 2 + height then
					x, y = width / 2 - distance + width + height, height / 2
				else
					x, y = -width / 2, height / 2 - distance + width * 2 + height
				end
				local particle = overlay.particles[textureIndex]
				local size = sizes[group] * scale
				particle:SetWidth(size)
				particle:SetHeight(size)
				particle:ClearAllPoints()
				particle:SetPoint("CENTER", overlay, "CENTER", x, y)
				particle:SetTexCoord(0, 1, 0, 1)
				particle:Show()
			end
		end
		for i = textureIndex + 1, table.getn(overlay.particles) do overlay.particles[i]:Hide() end
		return
	end
	local radiusX = width / 2
	local radiusY = height / 2
	local size = 16 * scale
	local phase = now * frequency * 2 * math.pi
	for i = 1, count do
		local angle = phase + (i - 1) * 2 * math.pi / count
		local particle = overlay.particles[i]
		local x = math.cos(angle) * radiusX
		local y = math.sin(angle) * radiusY
		particle:SetWidth(size)
		particle:SetHeight(size)
		particle:ClearAllPoints()
		particle:SetPoint("CENTER", overlay, "CENTER", x, y)
		particle:SetTexCoord(0, 1, 0, 1)
		particle:Show()
	end
	for i = count + 1, table.getn(overlay.particles) do overlay.particles[i]:Hide() end
end

local function applySoft(overlay)
	overlay.bgFrame:Hide()
	overlay.antTex:Hide()
	for i = 1, table.getn(overlay.segments or {}) do
		overlay.segments[i]:Hide()
		if overlay.borders[i] then overlay.borders[i]:Hide() end
	end
	for i = 1, table.getn(overlay.particles or {}) do overlay.particles[i]:Hide() end
	overlay.softTex:SetAlpha(1)
	overlay.softTex:Show()
end

local function applyPulse(overlay, now)
	applySoft(overlay)
	local frequency = (overlay.params and overlay.params.frequency) or 0.25
	local phase = now * frequency * 2 * math.pi
	overlay.softTex:SetAlpha(0.5 + 0.5 * math.sin(phase))
end

local function glowSummary(data)
	local color = data.useGlowColor and "Custom color" or "Default color"
	if data.glowType == "Pixel" then
		local border = data.glowBorder and ", Border" or ""
		return string.format("%s, %d lines, %.2f frequency, %d length, %d thickness%s",
			color, data.glowLines or 8, data.glowFrequency or 0.25,
			data.glowLength or 10, data.glowThickness or 1, border)
	elseif data.glowType == "ACShine" then
		return string.format("%s, %s, %d groups, %.2f frequency, %.2f scale",
			color, data.glowShape == "circular" and "Circular" or "Rectangular",
			data.glowLines or 8, data.glowFrequency or 0.25, data.glowScale or 1)
	elseif data.glowType == "Pulse" then
		return string.format("%s, %.2f frequency, %.2f scale",
			color, data.glowFrequency or 0.25, data.glowScale or 1)
	elseif data.glowType == "Soft" then
		return string.format("%s, %.2f scale", color, data.glowScale or 1)
	end
	return color
end

local function step()
	antIndex = antIndex + 1
	if antIndex > ANT_FRAMES then antIndex = 1 end
	local now = GetTime()
	for overlay in pairs(lit) do overlay.renderer.apply(overlay, now) end
end

local function light(overlay)
	if not overlay.renderer.animate then
		overlay.renderer.apply(overlay, GetTime())
		return
	end
	if lit[overlay] then return end
	lit[overlay] = true
	numLit = numLit + 1
	overlay.renderer.apply(overlay, GetTime())
	if not ticker then ticker = C_Timer.NewTicker(FRAME_INTERVAL, step) end
end

-- The ticker is stopped once nothing is glowing rather than left running, so an
-- idle session costs no timer at all.
local function douse(overlay)
	if not lit[overlay] then return end
	lit[overlay] = nil
	numLit = numLit - 1
	if numLit <= 0 then
		numLit = 0
		if ticker then ticker:Cancel(); ticker = nil end
	end
end

local function getOverlay(glowType)
	local pool = pools[glowType]
	local overlay = table.remove(pool)
	if not overlay then
		numOverlays = numOverlays + 1
		overlay = CreateFrame("Frame", "WeakestAurasGlowOverlay" .. numOverlays)
		overlay.bgFrame = CreateFrame("Frame", "WeakestAurasGlowBackground" .. numOverlays)

		overlay.bg = overlay.bgFrame:CreateTexture(nil, "ARTWORK")
		overlay.bg:SetTexture(TEX_ALERT)
		overlay.bg:SetTexCoord(rect(GLOW_X, GLOW_Y, GLOW_W, GLOW_H, ALERT_W, ALERT_H))
		overlay.bg:SetAllPoints(overlay.bgFrame)

		overlay.antTex = overlay:CreateTexture(nil, "OVERLAY")
		overlay.antTex:SetTexture(TEX_ANTS)
		overlay.antTex:SetAllPoints(overlay)
		overlay.antTex:SetBlendMode("ADD")
			overlay.antTex:SetVertexColor(1, 1, 1, 1)
	end
		if glowType == "Pixel" and not overlay.segments then
			overlay.segments, overlay.borders = {}, {}
			for i = 1, 30 do
				local border = overlay:CreateTexture(nil, "ARTWORK")
				border:SetTexture(TEX_SOLID)
				border:SetVertexColor(0, 0, 0, 1)
				overlay.borders[i] = border
				local segment = overlay:CreateTexture(nil, "OVERLAY")
				segment:SetTexture(TEX_SOLID)
				segment:SetVertexColor(1, 1, 1, 1)
				overlay.segments[i] = segment
			end
		end
		if glowType == "ACShine" and not overlay.particles then
			overlay.particles = {}
			for i = 1, 120 do
				local particle = overlay:CreateTexture(nil, "OVERLAY")
				particle:SetTexture(TEX_STAR)
				particle:SetBlendMode("ADD")
				particle:SetVertexColor(1, 1, 1, 1)
				overlay.particles[i] = particle
			end
		end
		if (glowType == "Soft" or glowType == "Pulse") and not overlay.softTex then
			overlay.softTex = overlay:CreateTexture(nil, "OVERLAY")
			overlay.softTex:SetTexture(TEX_SOFT)
			overlay.softTex:SetAllPoints(overlay)
			overlay.softTex:SetBlendMode("ADD")
			overlay.softTex:SetVertexColor(1, 1, 1, 1)
		end
	overlay.poolType = glowType
	return overlay
end

local function releaseOverlay(glowType, overlay)
	pools[glowType] = pools[glowType] or {}
	table.insert(pools[glowType], overlay)
end

WA.glow_types = {
	buttonOverlay = "Action Button Glow",
	Pixel = "Pixel Glow",
	ACShine = "Autocast Shine",
	Soft = "Soft Glow",
	Pulse = "Pulse Glow",
}

local glowRenderers = {}
for glowType in pairs(WA.glow_types) do
	local typeName = glowType
	pools[glowType] = {}
	glowRenderers[glowType] = {
		acquire = function() return getOverlay(typeName) end,
		release = function(overlay) releaseOverlay(typeName, overlay) end,
		animate = typeName ~= "Soft",
		apply = typeName == "Pixel" and applyPixel
			or typeName == "ACShine" and applyACShine
			or typeName == "Soft" and applySoft
			or typeName == "Pulse" and applyPulse
			or applyButtonOverlay,
	}
end

local function getRenderer(glowType)
	return glowRenderers[glowType] or glowRenderers.buttonOverlay
end

local function glowAnchorArea(parentData, subData)
	local requested = subData.anchor_area
	local values = proto.GetSubRegionAnchors(parentData, "area")
	for i = 1, table.getn(values) do
		if values[i] == requested then return requested end
	end
	return parentData.regionType == "progressbar" and "bar" or "region"
end

local function glowTarget(parent, key)
	if parent.bar and parent.iconFrame then
		if key == "bar" then return parent.bar end
		if key == "icon" then return parent.iconFrame end
		return parent.bar
	end
	return proto.GetSubRegionAnchorTarget(parent, key)
end

local function glowGeometryTarget(parent, key, target)
	if parent.bar and (key == "region" or key == "bar") then
		return parent
	end
	return target
end

local function applyGeometry(region)
	local overlay = region.overlay
	if not overlay then return end
	local area = glowAnchorArea(region.parentData, region.anchorData)
	local target = glowTarget(region.parent, area)
	local geometryTarget = glowGeometryTarget(region.parent, area, target)
	if not target then target = region.host end
	if not geometryTarget then geometryTarget = target end
	local scale = region.glowScale or 1
	local x = region.glowXOffset or 0
	local y = region.glowYOffset or 0
	local width = geometryTarget:GetWidth() or 0
	local height = geometryTarget:GetHeight() or 0
	local anchorX = region.anchorData.anchorXOffset or 0
	local anchorY = region.anchorData.anchorYOffset or 0
	local artScale = overlay.poolType == "buttonOverlay" and GLOW_SCALE
		or (overlay.poolType == "Soft" or overlay.poolType == "Pulse") and SOFT_GLOW_SCALE
		or 1
	local geometryScale = overlay.poolType == "ACShine" and 1 or scale
	local glowWidth = (width + anchorX * 2) * artScale * geometryScale
	local glowHeight = (height + anchorY * 2) * artScale * geometryScale
	overlay:SetWidth(glowWidth)
	overlay:SetHeight(glowHeight)
	overlay:ClearAllPoints()
	overlay:SetPoint("CENTER", geometryTarget, "CENTER", x, y)
	overlay.bgFrame:SetWidth(glowWidth)
	overlay.bgFrame:SetHeight(glowHeight)
	overlay.bgFrame:ClearAllPoints()
	overlay.bgFrame:SetPoint("CENTER", geometryTarget, "CENTER", x, y)
	if overlay.renderer and (overlay.poolType == "Pixel" or overlay.poolType == "ACShine") then
		overlay.renderer.apply(overlay, GetTime())
	end
end

-- Read-only pool stats for Debug.lua's glow-leak check (verification: a hidden
-- aura must release its overlay, not leave one ticking off-screen).
function WA.GetGlowPoolStats(glowType)
	if glowType then
		return table.getn(pools[glowType] or {})
	end
	local free = 0
	for _, pool in pairs(pools) do free = free + table.getn(pool) end
	return numOverlays, free
end

local function glowDefault(regionType)
	local default = {
		type = "subglow",
		glow = false,
		glowType = "buttonOverlay",
		glowColor = { 1, 1, 1, 1 },
		useGlowColor = false,
		glowScale = 1,
		glowShape = "rectangular",
		glowXOffset = 0,
		glowYOffset = 0,
		glowLines = 8,
		glowFrequency = 0.25,
		glowLength = 10,
		glowThickness = 1,
		glowBorder = false,
		anchor_mode = "area",
		anchor_area = "region",
	}
	if regionType == "progressbar" then
		default.glowType = "Pixel"
		default.anchor_area = "bar"
	end
	return default
end

WA.RegisterSubRegionType("subglow", {
	displayName = "Glow",
	supports = function(regionType)
		return regionType == "icon"
			or regionType == "progressbar"
			or regionType == "text"
			or regionType == "texture"
			or regionType == "progresstexture"
	end,
	default = glowDefault("icon"),
	defaultFor = glowDefault,
	-- The point of the feature: conditionable on/off + colour.
	properties = {
		glow = { display = "Glow", setter = "SetVisible", type = "bool" },
		glowType = { display = "Glow Type", setter = "SetGlowType", type = "list", values = WA.glow_types },
		glowLines = { display = "Lines", setter = "SetGlowLines", type = "number", min = 1, max = 30, step = 1 },
		glowFrequency = { display = "Frequency", setter = "SetGlowFrequency", type = "number", min = -2, max = 2, step = 0.05 },
		glowShape = { display = "Shape", setter = "SetGlowShape", type = "list", values = { rectangular = "Rectangular", circular = "Circular" } },
		glowLength = { display = "Length", setter = "SetGlowLength", type = "number", min = 1, max = 20, step = 1 },
		glowThickness = { display = "Thickness", setter = "SetGlowThickness", type = "number", min = 1, max = 20, step = 1 },
		glowBorder = { display = "Border", setter = "SetGlowBorder", type = "bool" },
		useGlowColor = { display = "Use Color", setter = "SetUseGlowColor", type = "bool" },
		glowColor = { display = "Color", setter = "SetGlowColor", type = "color" },
		glowScale = { display = "Scale", setter = "SetGlowScale", type = "number", min = 0.05, max = 10, step = 0.05 },
		glowXOffset = { display = "X Offset", setter = "SetGlowXOffset", type = "number", min = -100, max = 100, step = 1 },
		glowYOffset = { display = "Y Offset", setter = "SetGlowYOffset", type = "number", min = -100, max = 100, step = 1 },
	},
	create = function(parent)
		local region = { parent = parent, host = parent }

		function region:ReapplyTint()
			tintOverlay(self.overlay, self.useGlowColor and self.glowColor or nil)
		end
		-- The overlay comes from a shared pool and is acquired on demand, so the
		-- level has to be *stored* and re-applied to whatever the pool hands
		-- back -- being told it once, at modify time, would only reach an
		-- overlay that happened to already exist. The pair takes two levels
		-- (backdrop under art), which is what proto.SUB_STEP reserves.
		function region:ApplyFrameLevel(overlay)
			overlay = overlay or self.overlay
			if not overlay then return end
			local level = self.frameLevel
				or (proto.BaseFrameLevel(self.parent) + proto.SUB_LEVEL)
			overlay.bgFrame:SetFrameLevel(level)
			overlay:SetFrameLevel(level + 1)
		end
		function region:SetFrameLevel(level)
			self.frameLevel = level
			self:ApplyFrameLevel()
		end
		function region:StartGlow()
			local glowType = self.glowType or "buttonOverlay"
			local renderer = getRenderer(glowType)
			local overlay = self.overlay
			if overlay and overlay.poolType ~= glowType then
				self:StopGlow()
				overlay = nil
			end
			if not overlay then overlay = renderer.acquire() end
			local target = glowTarget(self.parent, glowAnchorArea(self.parentData, self.anchorData))
			overlay:SetParent(target or self.host)
			overlay.bgFrame:SetParent(target or self.host)
			self:ApplyFrameLevel(overlay)
			overlay.renderer = renderer
			self.overlay = overlay
			overlay.params = {
				lines = self.glowLines or 8,
				frequency = self.glowFrequency or 0.25,
				length = self.glowLength or 10,
				thickness = self.glowThickness or 1,
				border = self.glowBorder,
				scale = self.glowScale or 1,
				shape = self.glowShape or "rectangular",
			}
			overlay.target = target or self.host
			applyGeometry(self)
			self:ReapplyTint()
			overlay.bgFrame:Show()
			overlay:Show()
			light(overlay)
		end
		function region:StopGlow()
			if not self.overlay then return end
			local overlay = self.overlay
			local renderer = overlay.renderer or getRenderer(self.glowType)
			douse(overlay)
			overlay:Hide()
			overlay.bgFrame:Hide()
			overlay:SetParent(UIParent)
			overlay.bgFrame:SetParent(UIParent)
			self.overlay = nil
			renderer.release(overlay)
		end
		function region:SetGlowType(glowType)
			glowType = glowType or "buttonOverlay"
			if not glowRenderers[glowType] then glowType = "buttonOverlay" end
			if self.glowType == glowType then return end
			self.glowType = glowType
			if self.visible then self:StartGlow() end
		end
		function region:SetVisible(b)
			self.visible = b and true or false
			if self.visible then self:StartGlow() else self:StopGlow() end
		end
		function region:SetUseGlowColor(b) self.useGlowColor = b and true or false; self:ReapplyTint() end
		function region:SetGlowColor(r, g, b, a) self.glowColor = { r, g, b, a or 1 }; self:ReapplyTint() end
		function region:SetGlowScale(v) self.glowScale = v or 1; if self.overlay then self.overlay.params.scale = self.glowScale end; applyGeometry(self) end
		function region:SetGlowShape(v) self.glowShape = v == "circular" and "circular" or "rectangular"; if self.overlay then self.overlay.params.shape = self.glowShape; self.overlay.renderer.apply(self.overlay, GetTime()) end end
		function region:SetGlowXOffset(v) self.glowXOffset = v or 0; applyGeometry(self) end
		function region:SetGlowYOffset(v) self.glowYOffset = v or 0; applyGeometry(self) end
		function region:SetGlowLines(v) self.glowLines = v or 8; if self.overlay then self.overlay.params.lines = self.glowLines; self.overlay.renderer.apply(self.overlay, GetTime()) end end
		function region:SetGlowFrequency(v) self.glowFrequency = v or 0.25; if self.overlay then self.overlay.params.frequency = self.glowFrequency; self.overlay.renderer.apply(self.overlay, GetTime()) end end
		function region:SetGlowLength(v) self.glowLength = v or 10; if self.overlay then self.overlay.params.length = self.glowLength end end
		function region:SetGlowThickness(v) self.glowThickness = v or 1; if self.overlay then self.overlay.params.thickness = self.glowThickness end end
		function region:SetGlowBorder(v)
			self.glowBorder = v and true or false
			if self.overlay then
				self.overlay.params.border = self.glowBorder
				self.overlay.renderer.apply(self.overlay, GetTime())
			end
		end
		-- modifyFinish's Show/Hide: honour the current visible flag, and always
		-- release on Hide so a removed/unsupported instance can't leak a ticking
		-- overlay.
		function region:Show() if self.visible then self:StartGlow() end end
		function region:Hide() self:StopGlow() end
		return region
	end,
	modify = function(parent, region, parentData, subData)
		region.host = parent
		region.parentData = parentData
		region.anchorData = subData
		region.visible = subData.glow and true or false
		region.useGlowColor = subData.useGlowColor and true or false
		region.glowColor = subData.glowColor or { 1, 1, 1, 1 }
		region.glowScale = subData.glowScale or 1
		region.glowShape = subData.glowShape == "circular" and "circular" or "rectangular"
		region.glowXOffset = subData.glowXOffset or 0
		region.glowYOffset = subData.glowYOffset or 0
		region.glowLines = subData.glowLines or 8
		region.glowFrequency = subData.glowFrequency or 0.25
		region.glowLength = subData.glowLength or 10
		region.glowThickness = subData.glowThickness or 1
		region.glowBorder = subData.glowBorder and true or false
		region.glowType = nil
		region:SetGlowType(subData.glowType or "buttonOverlay")
		if region.visible then region:StartGlow() else region:StopGlow() end
		region:ReapplyTint()

		-- A hidden pooled overlay must leave the ticker's set or it animates
		-- forever. PreHide releases it; PreShow re-arms one that's still on.
		parent.subRegionEvents:AddSubscriber("PreHide", function() region:StopGlow() end)
		parent.subRegionEvents:AddSubscriber("PreShow", function()
			if region.visible then
				region:StartGlow()
				applyGeometry(region)
			end
		end)
	end,
	options = function(parentData, subData, index)
		local fields = {
			{
				type = "select", name = "Glow type", key = "glowType",
				values = { "buttonOverlay", "Pixel", "ACShine", "Soft", "Pulse" }, labels = WA.glow_types,
				get = function() return subData.glowType or "buttonOverlay" end,
				set = function(v)
					subData.glowType = v
					WA.Add(parentData, true)
					WA.RefreshOptions()
				end,
			},
			{
				type = "toggle", name = "Glow", key = "glow",
				get = function() return subData.glow and true or false end,
				set = function(v) subData.glow = v and true or false; WA.Add(parentData, true) end,
			},
			{
				type = "toggle", name = "Use custom color", key = "useGlowColor", half = true,
				get = function() return subData.useGlowColor and true or false end,
				set = function(v) subData.useGlowColor = v and true or false; WA.Add(parentData, true) end,
			},
			{
				type = "color", name = "Color", key = "glowColor", half = true,
				get = function() return subData.glowColor end,
				set = function(v) subData.glowColor = v; WA.Add(parentData, true) end,
			},
		}
		local S = WA.OptionsState
		local key = "sub:" .. index .. ":glowextra"
		local collapsed = S.isCollapsed(parentData, key, true)
		table.insert(fields, {
			type = "disclosure", name = "Extra Options", summary = glowSummary(subData),
			collapsed = collapsed,
			onToggle = function()
				S.setCollapsed(parentData, key, not collapsed)
				WA.RefreshOptions()
			end,
		})
		if not collapsed then
			if (subData.glowType or "buttonOverlay") == "Pixel"
				or (subData.glowType or "buttonOverlay") == "ACShine" then
				table.insert(fields, {
					type = "range", name = "Lines", key = "glowLines", min = 1, max = 30, step = 1, half = true,
					get = function() return subData.glowLines or 8 end,
					set = function(v) subData.glowLines = v; WA.Add(parentData, true) end,
				})
			end
			if (subData.glowType or "buttonOverlay") == "Pixel"
				or (subData.glowType or "buttonOverlay") == "ACShine"
				or (subData.glowType or "buttonOverlay") == "Pulse" then
				table.insert(fields, {
					type = "range", name = "Frequency", key = "glowFrequency", min = -2, max = 2, step = 0.05, half = true,
					get = function() return subData.glowFrequency or 0.25 end,
					set = function(v) subData.glowFrequency = v; WA.Add(parentData, true) end,
				})
			end
			if (subData.glowType or "buttonOverlay") == "Pixel" then
				table.insert(fields, {
					type = "range", name = "Length", key = "glowLength", min = 1, max = 20, step = 1, half = true,
					get = function() return subData.glowLength or 10 end,
					set = function(v) subData.glowLength = v; WA.Add(parentData, true) end,
				})
				table.insert(fields, {
					type = "range", name = "Thickness", key = "glowThickness", min = 1, max = 20, step = 1, half = true,
					get = function() return subData.glowThickness or 1 end,
					set = function(v) subData.glowThickness = v; WA.Add(parentData, true) end,
				})
				table.insert(fields, {
					type = "toggle", name = "Border", key = "glowBorder", half = true,
					get = function() return subData.glowBorder and true or false end,
					set = function(v) subData.glowBorder = v and true or false; WA.Add(parentData, true) end,
				})
			end
			table.insert(fields, {
				type = "range", name = "Scale", key = "glowScale", min = 0.05, max = 10, step = 0.05,
				get = function() return subData.glowScale or 1 end,
				set = function(v) subData.glowScale = v; WA.Add(parentData, true) end,
			})
			if (subData.glowType or "buttonOverlay") == "ACShine" then
				table.insert(fields, {
					type = "select", name = "Shape", key = "glowShape",
					values = { "rectangular", "circular" },
					labels = { rectangular = "Rectangular", circular = "Circular" },
					get = function() return subData.glowShape == "circular" and "circular" or "rectangular" end,
					set = function(v) subData.glowShape = v == "circular" and "circular" or "rectangular"; WA.Add(parentData, true) end,
				})
			end
			table.insert(fields, {
				type = "range", name = "X Offset", key = "glowXOffset", min = -100, max = 100, step = 1, half = true,
				get = function() return subData.glowXOffset or 0 end,
				set = function(v) subData.glowXOffset = v; WA.Add(parentData, true) end,
			})
			table.insert(fields, {
				type = "range", name = "Y Offset", key = "glowYOffset", min = -100, max = 100, step = 1, half = true,
				get = function() return subData.glowYOffset or 0 end,
				set = function(v) subData.glowYOffset = v; WA.Add(parentData, true) end,
			})
		end
		local anchorFields = proto.SubRegionAnchorFields(parentData, subData, {
			areaOnly = true,
			areaTarget = glowAnchorArea(parentData, subData),
		})
		for i = 1, table.getn(anchorFields) do
			if anchorFields[i].key == "anchor_area" then
				anchorFields[i].get = function() return glowAnchorArea(parentData, subData) end
			end
			table.insert(fields, anchorFields[i])
		end
		return fields
	end,
})

function WA.CreateExternalGlow(frame)
	if not frame then return nil end
	local glow = getOverlay("buttonOverlay")
	local region = {
		parent = frame, host = frame, parentData = { regionType = "icon" },
		anchorData = { anchor_area = "region", anchorXOffset = 0, anchorYOffset = 0 },
		glowType = "buttonOverlay", glowScale = 1, glowShape = "rectangular",
		glowXOffset = 0, glowYOffset = 0, glowLines = 8, glowFrequency = 0.25,
		glowLength = 10, glowThickness = 1, glowBorder = false,
		useGlowColor = false, glowColor = DEFAULT_GLOW_COLOR,
		overlay = glow,
	}
	glow:SetParent(frame)
	glow.bgFrame:SetParent(frame)
	glow.renderer = getRenderer("buttonOverlay")
	function region:StartGlow(options)
		local types = { buttonOverlay = true, Pixel = true, ACShine = true, Soft = true, Pulse = true }
		local glowType = types[options.glow_type] and options.glow_type or "buttonOverlay"
		if self.overlay.poolType ~= glowType then
			self:StopGlow()
			self.overlay = getOverlay(glowType)
		end
		self.glowType = glowType
		self.useGlowColor = options.use_glow_color and true or false
		self.glowColor = options.glow_color or DEFAULT_GLOW_COLOR
		self.glowScale = options.glow_scale or 1
		self.glowXOffset = options.glow_XOffset or 0
		self.glowYOffset = options.glow_YOffset or 0
		-- Per-axis size trim, the one lever a foreign frame really needs: a
		-- nameplate's frame is its bar *and* its name text, so a glow matching it
		-- stands well clear of the bar the user was aiming at, and by a different
		-- amount on each axis than scale can express. applyGeometry grows the box
		-- by twice each of these, so a negative pulls the glow in.
		self.anchorData.anchorXOffset = options.glow_extraWidth or 0
		self.anchorData.anchorYOffset = options.glow_extraHeight or 0
		self.glowLines = options.glow_lines or 8
		self.glowFrequency = options.glow_frequency or 0.25
		self.glowLength = options.glow_length or 10
		self.glowThickness = options.glow_thickness or 1
		self.glowBorder = options.glow_border and true or false
		self.overlay.renderer = getRenderer(glowType)
		self.overlay.params = { lines = self.glowLines, frequency = self.glowFrequency,
			length = self.glowLength, thickness = self.glowThickness, border = self.glowBorder,
			scale = self.glowScale, shape = "rectangular" }
		applyGeometry(self)
		self:ReapplyTint()
		self.overlay:Show(); self.overlay.bgFrame:Show()
		light(self.overlay)
	end
	function region:ReapplyTint()
		tintOverlay(self.overlay, self.useGlowColor and self.glowColor or nil)
	end
	function region:StopGlow()
		if not self.overlay then return end
		douse(self.overlay)
		self.overlay:Hide(); self.overlay.bgFrame:Hide()
		self.overlay:SetParent(UIParent); self.overlay.bgFrame:SetParent(UIParent)
		releaseOverlay(self.overlay.poolType, self.overlay)
		self.overlay = nil
	end
	function region:Destroy()
		self:StopGlow()
	end
	return region
end

-- The editor for one `glowexternal` condition change. It lives here rather than
-- in OptionsFrame.lua because which fields a glow type offers is decided by what
-- CreateExternalGlow's StartGlow above actually reads: `lines` means nothing to
-- Soft, `length`/`thickness`/`border` mean nothing to anything but Pixel, and a
-- field offered for a type that ignores it is a control that does nothing.
local GLOW_TYPE_ORDER = { "buttonOverlay", "Pixel", "ACShine", "Soft", "Pulse" }
local GLOW_FRAME_TYPES = { "PARENTFRAME", "FRAMESELECTOR", "UNITFRAME", "NAMEPLATE" }
local GLOW_FRAME_LABELS = {
	PARENTFRAME = "This Aura", FRAMESELECTOR = "Named Frame",
	UNITFRAME = "Unit Frame", NAMEPLATE = "Nameplate",
}

-- The same editor over an action block, whose glow keys sit on the block itself
-- rather than under a `value`. `finish` alone offers "Hide all glows": on show
-- there is nothing lit yet to clear.
function WA.ActionGlowFields(fields, data, block, when)
	table.insert(fields, { type = "toggle", name = "Glow External Element", key = "do_glow",
		get = function() return block.do_glow and true or false end,
		set = function(v)
			block.do_glow = v and true or false
			WA.Add(data)
			WA.RefreshOptions()
		end })
	if not block.do_glow then return end
	WA.ConditionGlowFields(fields, data, { value = block })
	if when == "finish" then
		table.insert(fields, { type = "toggle", name = "Hide all glows", key = "hide_all_glows",
			get = function() return block.hide_all_glows and true or false end,
			set = function(v) block.hide_all_glows = v and true or false; WA.Add(data) end })
	end
end

function WA.ConditionGlowFields(fields, data, change)
	local function get(key, default)
		local v = change.value and change.value[key]
		if v == nil then return default end
		return v
	end
	local function set(key, refresh)
		return function(v)
			change.value = change.value or {}
			change.value[key] = v
			WA.Add(data)
			if refresh then WA.RefreshOptions() end
		end
	end

	table.insert(fields, { type = "select", name = "Glow Action", key = "glow_action", values = { "show", "hide" },
		labels = { show = "Show", hide = "Hide" },
		get = function() return get("glow_action", "show") end,
		set = set("glow_action", true) })
	table.insert(fields, { type = "select", name = "Frame Type", key = "glow_frame_type",
		values = GLOW_FRAME_TYPES, labels = GLOW_FRAME_LABELS,
		get = function() return get("glow_frame_type", "PARENTFRAME") end,
		set = set("glow_frame_type", true) })
	if get("glow_frame_type", "PARENTFRAME") == "FRAMESELECTOR" then
		table.insert(fields, { type = "input", name = "Frame Name", key = "glow_frame",
			get = function() return get("glow_frame", "") end,
			set = set("glow_frame") })
	end
	-- A hide carries no art: it puts out whatever the matching show started.
	if get("glow_action", "show") ~= "show" then return end

	local glowType = get("glow_type", "buttonOverlay")
	table.insert(fields, { type = "select", name = "Glow Type", key = "glow_type",
		values = GLOW_TYPE_ORDER, labels = WA.glow_types,
		get = function() return glowType end,
		set = set("glow_type", true) })
	table.insert(fields, { type = "toggle", name = "Use custom color", key = "use_glow_color", half = true,
		get = function() return get("use_glow_color", false) and true or false end,
		set = set("use_glow_color", true) })
	if get("use_glow_color", false) then
		table.insert(fields, { type = "color", name = "Color", key = "glow_color", half = true,
			get = function() return get("glow_color", nil) end,
			set = set("glow_color") })
	end
	if glowType == "Pixel" or glowType == "ACShine" then
		table.insert(fields, { type = "range", name = "Lines", key = "glow_lines", min = 1, max = 30, step = 1, half = true,
			get = function() return get("glow_lines", 8) end,
			set = set("glow_lines") })
	end
	if glowType == "Pixel" or glowType == "ACShine" or glowType == "Pulse" then
		table.insert(fields, { type = "range", name = "Frequency", key = "glow_frequency", min = -2, max = 2, step = 0.05, half = true,
			get = function() return get("glow_frequency", 0.25) end,
			set = set("glow_frequency") })
	end
	if glowType == "Pixel" then
		table.insert(fields, { type = "range", name = "Length", key = "glow_length", min = 1, max = 20, step = 1, half = true,
			get = function() return get("glow_length", 10) end,
			set = set("glow_length") })
		table.insert(fields, { type = "range", name = "Thickness", key = "glow_thickness", min = 1, max = 20, step = 1, half = true,
			get = function() return get("glow_thickness", 1) end,
			set = set("glow_thickness") })
		table.insert(fields, { type = "toggle", name = "Border", key = "glow_border", half = true,
			get = function() return get("glow_border", false) and true or false end,
			set = set("glow_border") })
	end
	table.insert(fields, { type = "range", name = "Scale", key = "glow_scale", min = 0.05, max = 10, step = 0.05,
		get = function() return get("glow_scale", 1) end,
		set = set("glow_scale") })
	table.insert(fields, { type = "range", name = "Extra width", key = "glow_extraWidth", min = -200, max = 200, step = 1, half = true,
		get = function() return get("glow_extraWidth", 0) end,
		set = set("glow_extraWidth") })
	table.insert(fields, { type = "range", name = "Extra height", key = "glow_extraHeight", min = -200, max = 200, step = 1, half = true,
		get = function() return get("glow_extraHeight", 0) end,
		set = set("glow_extraHeight") })
	table.insert(fields, { type = "range", name = "X Offset", key = "glow_XOffset", min = -100, max = 100, step = 1, half = true,
		get = function() return get("glow_XOffset", 0) end,
		set = set("glow_XOffset") })
	table.insert(fields, { type = "range", name = "Y Offset", key = "glow_YOffset", min = -100, max = 100, step = 1, half = true,
		get = function() return get("glow_YOffset", 0) end,
		set = set("glow_YOffset") })
end
