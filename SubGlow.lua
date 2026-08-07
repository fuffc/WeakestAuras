-- WeakestAuras -- the "subglow" sub-region: an animated proc-glow (the
-- "IconAlert" ant-march) drawn over an icon. Mirrors WA2's Glow (§8).
-- Upstream section refs (§N) point at design/architecture/weakauras2-reference.md
--
-- Masque and LibCustomGlow don't port to 1.12, so the animation is driven here.
-- Opt-in and default-OFF, since a glow is almost always condition-driven.

if WeakestAuras.disabled then return end

local WA = WeakestAuras

local TEX_ALERT = "Interface\\AddOns\\WeakestAuras\\textures\\IconAlert"
local TEX_ANTS = "Interface\\AddOns\\WeakestAuras\\textures\\IconAlertAnts"
local FRAME_INTERVAL = 0.04

-- Both files are 256x256 sheets. Regions are written as source pixels and
-- normalised here rather than as decimal literals, so they stay checkable
-- against the artwork instead of being magic numbers.
local SHEET = 256
local function rect(x, y, w, h)
	return x / SHEET, (x + w) / SHEET, y / SHEET, (y + h) / SHEET
end

local GLOW_X, GLOW_Y, GLOW_W, GLOW_H = 14, 77, 104, 52

-- The ant sheet is a grid of 44px cells on a 48px pitch, inset 2px/1px from the
-- top-left corner; 22 of its 25 cells carry a frame.
local ANT_COLUMNS, ANT_FRAMES = 5, 22
local ANT_PITCH, ANT_CELL = 48, 44
local ANT_X0, ANT_Y0 = 2, 1

local antFrames = {}
do
	local col, row = 0, 0
	for i = 1, ANT_FRAMES do
		antFrames[i] = { rect(ANT_X0 + col * ANT_PITCH, ANT_Y0 + row * ANT_PITCH, ANT_CELL, ANT_CELL) }
		col = col + 1
		if col >= ANT_COLUMNS then col = 0; row = row + 1 end
	end
end

-- Frames cannot be destroyed, so a released overlay is pooled rather than
-- dropped.
local pool = {}
local numOverlays = 0

-- Every lit overlay advances off one shared ticker instead of carrying its own
-- OnUpdate: the cost stays one timer however many auras glow at once, and the
-- glows stay in phase rather than drifting apart. A newly lit overlay therefore
-- joins the cycle wherever it currently is, which is the point.
local lit = {}
local numLit = 0
local antIndex = 1
local ticker

local function applyFrame(overlay)
	local f = antFrames[antIndex]
	overlay.antTex:SetTexCoord(f[1], f[2], f[3], f[4])
end

local function step()
	antIndex = antIndex + 1
	if antIndex > ANT_FRAMES then antIndex = 1 end
	for overlay in pairs(lit) do applyFrame(overlay) end
end

local function light(overlay)
	if lit[overlay] then return end
	lit[overlay] = true
	numLit = numLit + 1
	applyFrame(overlay)
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

local function getOverlay()
	local overlay = table.remove(pool)
	if not overlay then
		numOverlays = numOverlays + 1
		overlay = CreateFrame("Frame", "WeakestAurasGlowOverlay" .. numOverlays)
		overlay:SetFrameStrata("TOOLTIP")

		overlay.bg = overlay:CreateTexture(nil, "ARTWORK")
		overlay.bg:SetTexture(TEX_ALERT)
		overlay.bg:SetTexCoord(rect(GLOW_X, GLOW_Y, GLOW_W, GLOW_H))
		overlay.bg:SetAllPoints(overlay)

		overlay.antTex = overlay:CreateTexture(nil, "OVERLAY")
		overlay.antTex:SetTexture(TEX_ANTS)
		overlay.antTex:SetAllPoints(overlay)
		overlay.antTex:SetBlendMode("ADD")
	end
	return overlay
end

-- Read-only pool stats for Debug.lua's glow-leak check (verification: a hidden
-- aura must release its overlay, not leave one ticking off-screen).
function WA.GetGlowPoolStats()
	return numOverlays, table.getn(pool)
end

WA.RegisterSubRegionType("subglow", {
	displayName = "Glow",
	-- Glow-on-a-bar is unusual; icon only for now.
	supports = function(regionType)
		return regionType == "icon"
	end,
	default = {
		type = "subglow",
		glow = false,
		glowColor = { 1, 1, 1, 1 },
		useGlowColor = false,
	},
	-- The point of the feature: conditionable on/off + colour.
	properties = {
		glow = { display = "Glow", setter = "SetVisible", type = "bool" },
		useGlowColor = { display = "Use Color", setter = "SetUseGlowColor", type = "bool" },
		glowColor = { display = "Color", setter = "SetGlowColor", type = "color" },
	},
	create = function(parent)
		local region = { parent = parent, host = parent }

		function region:ReapplyTint()
			if not self.overlay then return end
			if self.useGlowColor and self.glowColor then
				local c = self.glowColor
				self.overlay.antTex:SetVertexColor(c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1)
			else
				self.overlay.antTex:SetVertexColor(1, 1, 1, 1)
			end
		end
		function region:StartGlow()
			if self.overlay then return end
			local overlay = getOverlay()
			overlay:SetParent(self.host)
			overlay:SetAllPoints(self.host)
			self.overlay = overlay
			self:ReapplyTint()
			overlay:Show()
			light(overlay)
		end
		function region:StopGlow()
			if not self.overlay then return end
			local overlay = self.overlay
			douse(overlay)
			overlay:Hide()
			overlay:SetParent(UIParent)
			self.overlay = nil
			table.insert(pool, overlay)
		end
		function region:SetVisible(b)
			self.visible = b and true or false
			if self.visible then self:StartGlow() else self:StopGlow() end
		end
		function region:SetUseGlowColor(b) self.useGlowColor = b and true or false; self:ReapplyTint() end
		function region:SetGlowColor(r, g, b, a) self.glowColor = { r, g, b, a or 1 }; self:ReapplyTint() end
		-- modifyFinish's Show/Hide: honour the current visible flag, and always
		-- release on Hide so a removed/unsupported instance can't leak a ticking
		-- overlay.
		function region:Show() if self.visible then self:StartGlow() end end
		function region:Hide() self:StopGlow() end
		return region
	end,
	modify = function(parent, region, parentData, subData)
		region.host = parent
		region.useGlowColor = subData.useGlowColor and true or false
		region.glowColor = subData.glowColor or { 1, 1, 1, 1 }
		region.visible = subData.glow and true or false

		if region.visible then region:StartGlow() else region:StopGlow() end
		region:ReapplyTint()

		-- A hidden pooled overlay must leave the ticker's set or it animates
		-- forever. PreHide releases it; PreShow re-arms one that's still on.
		parent.subRegionEvents:AddSubscriber("PreHide", function() region:StopGlow() end)
		parent.subRegionEvents:AddSubscriber("PreShow", function()
			if region.visible then region:StartGlow() end
		end)
	end,
	options = function(parentData, subData, index)
		return {
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
	end,
})
